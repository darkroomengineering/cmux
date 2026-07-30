import ActivityKit
import CloudKit
import Foundation
import Observation
import UIKit

/// The single `@Observable` store the views read. Owns the `BridgeConnection`
/// actor and keeps iroh types entirely out of the views: everything the UI
/// sees here is a plain, `Sendable` value type (`WorkspaceRow`/`SurfaceRow`/
/// `AgentBadge`).
@MainActor
@Observable
final class AppStore {
    enum Stage: Sendable {
        case pairing
        case workspaces
    }

    enum ConnectionBanner: Sendable, Equatable {
        case connecting
        case connected
        case reconnecting
        case disconnected

        var label: String {
            switch self {
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .reconnecting: "Reconnecting…"
            case .disconnected: "Not connected"
            }
        }

        var symbolName: String {
            switch self {
            case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
            case .connected: "checkmark.circle.fill"
            case .disconnected: "xmark.circle"
            }
        }
    }

    private(set) var stage: Stage = .pairing
    private(set) var connectionBanner: ConnectionBanner = .disconnected
    private(set) var observedPathDescription: String = "unknown"
    private(set) var workspaces: [WorkspaceRow] = []
    private(set) var surfacesByWorkspace: [String: [SurfaceRow]] = [:]
    private(set) var lastSyncError: String?
    private(set) var isConnecting = false

    /// M3: this iPhone's iCloud sign-in state, refreshed on init and on every foreground
    /// reconciliation. Does **not** detect a mismatched Apple ID between this phone and the
    /// paired Mac -- see `CloudKitPush.accountStatus()`'s doc comment.
    private(set) var iCloudAccountStatus: CKAccountStatus = .couldNotDetermine

    var pairingTicketDraft: String
    var pairingTokenDraft: String = ""

    private let connection = BridgeConnection()
    private var currentTicket: String?
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Live Activity state
    // See the "Live Activity" section below for the full lifecycle. Kept as
    // plain stored properties (not `@Observable`-tracked) since none of this
    // is read by any view -- it only drives ActivityKit updates.

    private static let liveActivityUpdateInterval: TimeInterval = 2
    private static let liveActivityStaleInterval: TimeInterval = 5 * 60

    private var liveActivity: Activity<AgentActivityAttributes>?
    private var lastPushedActivityState: AgentActivityAttributes.ContentState?
    private var lastActivityPushAt: Date = .distantPast
    private var pendingActivityContentState: AgentActivityAttributes.ContentState?
    private var pendingActivityUpdateTask: Task<Void, Never>?
    private var mostRecentBlockedWorkspaceID: String?
    /// Name of the paired Mac, shown in the Live Activity. Learned from the
    /// pairing response and persisted, since trusted reconnects never resend it.
    private var pairedMacName: String = PairingStore.loadMacName()
        ?? String(localized: "liveActivity.macName", defaultValue: "your Mac")
    // `nonisolated(unsafe)` because `deinit` on a @MainActor type runs
    // nonisolated and must still unregister this. Written exactly once during
    // init and read once in deinit, never concurrently, so the unsafe opt-out
    // is accurate rather than a way to silence the checker.
    private nonisolated(unsafe) var willTerminateObserver: NSObjectProtocol?
    // `nonisolated(unsafe)` for the same reason as `willTerminateObserver` above.
    private nonisolated(unsafe) var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        let savedTicket = PairingStore.loadTicket()
        pairingTicketDraft = savedTicket ?? ""
        currentTicket = (savedTicket?.isEmpty == false) ? savedTicket : nil

        Task { [weak self] in await self?.consumePhase() }
        Task { [weak self] in await self?.consumePath() }
        Task { [weak self] in await self?.consumeEvents() }

        // Best-effort signal for "the app is torn down": iOS almost always
        // suspends rather than terminates a backgrounded app, so this fires
        // less often in practice than a desktop app's quit, but it is the
        // only such notification available without an AppDelegate adaptor.
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.endLiveActivity()
            }
        }

        if let ticket = currentTicket {
            Task { [weak self] in await self?.attemptConnect(ticket: ticket, token: nil) }
        }

        // M3 mandatory foreground reconciliation: silent CloudKit pushes are coalesced,
        // throttled, and dropped entirely after a force-quit, so re-reading the record on
        // every foreground is the only thing that guarantees the Live Activity (and the
        // iCloud status banner) reflect reality rather than whatever pushes happened to land.
        Task { [weak self] in await self?.reconcileFromCloudKit() }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.reconcileFromCloudKit()
            }
        }
    }

    // `deinit` is nonisolated even on a @MainActor type, so it cannot read
    // main-actor state. The observer token is captured at registration time
    // and handed to a nonisolated static so teardown needs no isolated access.
    deinit {
        Self.removeObserver(willTerminateObserver)
        Self.removeObserver(didBecomeActiveObserver)
    }

    private nonisolated static func removeObserver(_ token: NSObjectProtocol?) {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - User actions

    func connectManually() async {
        var ticket = pairingTicketDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var token = pairingTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A combined `programa-pair://` code pasted straight into the
        // legacy ticket field is handled here rather than sent to iroh as a
        // malformed ticket, which would otherwise fail with an opaque error.
        if let parsed = PairingCode.parse(ticket) {
            ticket = parsed.ticket
            if token.isEmpty { token = parsed.token }
        }
        guard !ticket.isEmpty else { return }
        PairingStore.saveTicket(ticket)
        currentTicket = ticket
        pairingTicketDraft = ticket
        pairingTokenDraft = ""
        await attemptConnect(ticket: ticket, token: token.isEmpty ? nil : token)
    }

    /// Fills the legacy ticket/token fields from a combined `programa-pair://`
    /// code -- scanned via `QRScannerView` or pasted into the "Pairing code"
    /// field. Returns `false` (leaving the legacy fields untouched) if `raw`
    /// isn't a recognised combined code, so the caller can show a clear
    /// error instead of silently doing nothing.
    @discardableResult
    func applyPairingCode(_ raw: String) -> Bool {
        guard let parsed = PairingCode.parse(raw) else { return false }
        pairingTicketDraft = parsed.ticket
        pairingTokenDraft = parsed.token
        return true
    }

    func manualResync() async {
        do {
            try await resyncAll()
            recomputeLiveActivity()
        } catch {
            lastSyncError = "\(error)"
        }
    }

    func sendPrompt(surfaceID: String, text: String) async throws {
        _ = try await connection.sendPrompt(surfaceID: surfaceID, text: text)
    }

    func returnToPairing() {
        stage = .pairing
    }

    // MARK: - Derived state for views

    var sortedWorkspaces: [WorkspaceRow] {
        workspaces.sorted { lhs, rhs in
            let lhsBadge = badge(for: lhs.id)
            let rhsBadge = badge(for: rhs.id)
            if lhsBadge != rhsBadge { return lhsBadge > rhsBadge }
            return lhs.index < rhs.index
        }
    }

    /// Worst-of a workspace's surfaces: blocked > working > idle.
    func badge(for workspaceID: String) -> AgentBadge {
        let surfaceBadges = surfacesByWorkspace[workspaceID]?.map(\.badge) ?? []
        if surfaceBadges.contains(.blocked) { return .blocked }
        if surfaceBadges.contains(.working) { return .working }
        return .idle
    }

    func surfaces(for workspaceID: String) -> [SurfaceRow] {
        surfacesByWorkspace[workspaceID] ?? []
    }

    func workspaceTitle(for workspaceID: String) -> String {
        workspaces.first(where: { $0.id == workspaceID })?.title ?? "Workspace"
    }

    /// `nil` when iCloud is signed in and everything should work; otherwise a message to show
    /// on the pairing screen. See `iCloudAccountStatus`'s doc comment for what this can't catch
    /// (a mismatched Apple ID between this phone and the paired Mac).
    var iCloudStatusMessage: String? {
        switch iCloudAccountStatus {
        case .available:
            return nil
        case .noAccount:
            return "Sign in to iCloud on this iPhone (Settings > [your name]) to get notified when an agent needs you while Programa is in the background."
        case .restricted:
            return "iCloud is restricted on this iPhone, so background notifications won't work."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable, so background notifications may be delayed."
        case .couldNotDetermine:
            return "Could not check this iPhone's iCloud status."
        @unknown default:
            return "Could not check this iPhone's iCloud status."
        }
    }

    // MARK: - Connection plumbing

    private func attemptConnect(ticket: String, token: String?) async {
        isConnecting = true
        lastSyncError = nil
        defer { isConnecting = false }
        do {
            // Sent only on the pairing frame, so the Mac's device list can
            // show a name instead of a 64-char hex EndpointID. Read here
            // rather than inside the connection actor because UIDevice is
            // main-actor bound and this store already is.
            let deviceLabel = UIDevice.current.name
            try await connection.connect(
                pairingPayload: ticket,
                pairingToken: token,
                deviceLabel: deviceLabel.isEmpty ? nil : deviceLabel
            )
        } catch {
            lastSyncError = "\(error)"
        }
    }

    private func consumePhase() async {
        for await phase in connection.phaseStream {
            switch phase {
            case .disconnected:
                connectionBanner = .disconnected
                await endLiveActivity()
            case .connecting, .pairing:
                connectionBanner = .connecting
            case .connected:
                connectionBanner = .connected
                lastSyncError = nil
                reconnectTask?.cancel()
                reconnectTask = nil
                await handleConnected()
            case let .failed(reason):
                lastSyncError = reason
                if Self.isPairingRejection(reason) {
                    // Permanent, not transient: this device is not on the Mac's
                    // allowlist, so reconnecting with the same (tokenless)
                    // ticket will be refused every time. Worse, while the retry
                    // loop runs the Connect button stays disabled, so the user
                    // cannot enter the token that would actually fix it. Stop,
                    // and put them back on the pairing screen.
                    reconnectTask?.cancel()
                    reconnectTask = nil
                    connectionBanner = .disconnected
                    stage = .pairing
                } else {
                    connectionBanner = .reconnecting
                    scheduleReconnect()
                }
            }
        }
    }

    private func consumePath() async {
        for await path in connection.pathStream {
            observedPathDescription = path.description
        }
    }

    private func consumeEvents() async {
        for await event in connection.events {
            switch event {
            case let .bridgeHello(payload):
                // Arrives on every admission, so a renamed Mac corrects itself
                // on the next connect rather than staying stale until re-pair.
                if let name = payload.macName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty, name != pairedMacName {
                    pairedMacName = name
                    PairingStore.saveMacName(name)
                    recomputeLiveActivity()
                }
            case let .agentState(payload):
                applyAgentState(payload)
            case .workspaceLifecycle:
                // A workspace was created/closed/renamed — cheapest correct
                // response is the same full resync a `dropped` event or a
                // reconnect triggers.
                await manualResync()
            case .dropped:
                // Per the wire contract: the server's event queue overflowed,
                // so rebuild state from scratch instead of trusting the
                // (partial) event stream.
                await manualResync()
            case .output:
                break // Out of scope for the glance/unblock screens.
            }
        }
    }

    private func applyAgentState(_ payload: WireAgentStateEvent) {
        guard var rows = surfacesByWorkspace[payload.workspaceId] else { return }
        guard let index = rows.firstIndex(where: { $0.id == payload.surfaceId }) else { return }
        let wasBlocked = rows[index].badge == .blocked
        rows[index].agentState = payload.state
        rows[index].agentStateSource = payload.source
        surfacesByWorkspace[payload.workspaceId] = rows

        let isBlockedNow = rows[index].badge == .blocked
        let newlyBlocked = isBlockedNow && !wasBlocked
        if newlyBlocked {
            mostRecentBlockedWorkspaceID = payload.workspaceId
        }
        // A transition into "blocked" is the one case that must not sit
        // behind the 2s coalescing window -- see `recomputeLiveActivity`.
        recomputeLiveActivity(highPriority: newlyBlocked)
    }

    private func handleConnected() async {
        do {
            try await resyncAll()
            try await connection.subscribe(classes: ["agent_state", "workspace_lifecycle"])
            stage = .workspaces
            recomputeLiveActivity()
            // M3: (re)create the CloudKit query subscription once this device is trusted and
            // talking to the Mac -- idempotent, so this is cheap on every reconnect.
            await CloudKitPush.ensureSubscription()
        } catch {
            lastSyncError = "\(error)"
        }
    }

    /// Full resync: re-fetch `workspace.list` and, per workspace,
    /// `surface.list`, then rebuild local state from that. Used on first
    /// connect, on every reconnect, on a `dropped` event, on a
    /// `workspace_lifecycle` event, and on pull-to-refresh — the wire
    /// contract's documented recovery path, and there is no cheaper partial
    /// alternative (no replay/resume-from-cursor).
    private func resyncAll() async throws {
        let wireWorkspaces = try await connection.listWorkspaces()
        var newWorkspaces: [WorkspaceRow] = []
        var newSurfaces: [String: [SurfaceRow]] = [:]
        for (offset, wireWorkspace) in wireWorkspaces.enumerated() {
            let row = WorkspaceRow(
                id: wireWorkspace.id,
                title: wireWorkspace.title ?? "Untitled workspace",
                selected: wireWorkspace.selected ?? false,
                index: wireWorkspace.index ?? offset
            )
            newWorkspaces.append(row)

            let wireSurfaces = try await connection.listSurfaces(workspaceID: wireWorkspace.id)
            newSurfaces[wireWorkspace.id] = wireSurfaces.map { surface in
                SurfaceRow(
                    id: surface.id,
                    title: surface.title ?? "Surface",
                    focused: surface.focused ?? false,
                    agentState: surface.agentState,
                    agentStateSource: surface.agentStateSource
                )
            }
        }
        workspaces = newWorkspaces
        surfacesByWorkspace = newSurfaces
    }

    /// `not_paired` / `pairing_failed` from the bridge, in whatever wrapping
    /// the error arrives with. Matched on substring because the reason reaches
    /// here as an interpolated error description rather than a typed code.
    private nonisolated static func isPairingRejection(_ reason: String) -> Bool {
        reason.contains("not_paired") || reason.contains("pairing_failed")
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let ticket = currentTicket, !ticket.isEmpty else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            await self.attemptConnect(ticket: ticket, token: nil)
            self.reconnectTask = nil
        }
    }

    // MARK: - Live Activity
    //
    // Lifecycle: started the first time `handleConnected()`/`manualResync()`
    // sees at least one workspace while connected; updated as `agent_state`
    // events land; ended on an explicit disconnect or app teardown.
    //
    // Coalescing: ActivityKit budgets update frequency, and `agent_state`
    // events can churn quickly (an agent flipping working/idle/blocked in a
    // tight loop). `recomputeLiveActivity` only ever pushes a genuinely
    // different `ContentState` (`Hashable` equality against the last pushed
    // value), and rate-limits pushes to once per
    // `liveActivityUpdateInterval` (2s), coalescing any intermediate changes
    // into the single latest value sent when the window elapses. The one
    // exception is a transition into `blockedCount > 0`, which is high
    // priority and always sent immediately -- a human is needed right now,
    // and that must not sit behind the coalescing window.
    //
    // Known limitation: while the app is suspended, the iroh connection
    // drops and no further updates can be pushed, so the Live Activity
    // freezes on its last known state. `staleDate` (5 minutes out) lets the
    // system visually de-emphasize it once it goes stale. Fixing this for
    // real needs a remote-push (APNs) update path -- ActivityKit supports
    // `pushType: .token` plus a server that POSTs content updates to Apple's
    // Live Activity push endpoint -- which does not exist yet for Programa.

    private func ensureLiveActivityStarted() {
        guard liveActivity == nil else { return }
        guard !workspaces.isEmpty else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // Record rather than crash -- the user simply disabled Live
            // Activities (Settings > Face ID & Passcode, or per-app), which
            // is a normal, expected state, not a bridge/sync failure.
            lastSyncError = "Live Activities are disabled; agent status won't appear on the Lock Screen."
            return
        }

        let attributes = AgentActivityAttributes(
            // The wire contract has no field for the paired Mac's device
            // name today (only an opaque pairing ticket) -- this is a
            // placeholder until a future milestone plumbs one through, e.g.,
            // `system.ping`.
            macName: pairedMacName
        )
        let initialState = deriveActivityContentState()
        let content = ActivityContent(
            state: initialState,
            staleDate: Date().addingTimeInterval(Self.liveActivityStaleInterval)
        )

        do {
            // No `pushType:` -- there is no APNs push path yet (see the
            // limitation noted above), so this activity can only be updated
            // locally, for as long as the app process is alive to do so.
            liveActivity = try Activity<AgentActivityAttributes>.request(
                attributes: attributes,
                content: content
            )
            lastPushedActivityState = initialState
            lastActivityPushAt = Date()
        } catch {
            lastSyncError = "Could not start Live Activity: \(error)"
        }
    }

    private func recomputeLiveActivity(highPriority: Bool = false) {
        ensureLiveActivityStarted()
        guard let liveActivity else { return }

        let newState = deriveActivityContentState()
        guard newState != lastPushedActivityState else { return }

        let elapsedSinceLastPush = Date().timeIntervalSince(lastActivityPushAt)
        if highPriority || elapsedSinceLastPush >= Self.liveActivityUpdateInterval {
            pendingActivityUpdateTask?.cancel()
            pendingActivityUpdateTask = nil
            pendingActivityContentState = nil
            pushActivityUpdate(newState, activityID: liveActivity.id)
        } else {
            // Coalesce: remember the latest desired state and let the
            // already-scheduled (or newly-scheduled) flush send it once the
            // rate-limit window elapses.
            pendingActivityContentState = newState
            scheduleCoalescedActivityUpdate(delay: Self.liveActivityUpdateInterval - elapsedSinceLastPush)
        }
    }

    private func scheduleCoalescedActivityUpdate(delay: TimeInterval) {
        guard pendingActivityUpdateTask == nil else { return }
        pendingActivityUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard let self, !Task.isCancelled else { return }
            await self.flushPendingActivityUpdate()
        }
    }

    private func flushPendingActivityUpdate() async {
        pendingActivityUpdateTask = nil
        guard let liveActivity, let pending = pendingActivityContentState else { return }
        pendingActivityContentState = nil
        guard pending != lastPushedActivityState else { return }
        pushActivityUpdate(pending, activityID: liveActivity.id)
    }

    private func pushActivityUpdate(
        _ state: AgentActivityAttributes.ContentState,
        activityID: String
    ) {
        lastPushedActivityState = state
        lastActivityPushAt = Date()
        let staleDate = Date().addingTimeInterval(Self.liveActivityStaleInterval)
        // Only the id and a Sendable ContentState cross into the task; see
        // `updateActivity` for why the `Activity` handle itself cannot.
        Task {
            await Self.updateActivity(id: activityID, state: state, staleDate: staleDate)
        }
    }

    private func endLiveActivity() async {
        pendingActivityUpdateTask?.cancel()
        pendingActivityUpdateTask = nil
        pendingActivityContentState = nil
        guard let activityID = liveActivity?.id else { return }
        liveActivity = nil
        let finalState = lastPushedActivityState ?? deriveActivityContentState()
        lastPushedActivityState = nil
        mostRecentBlockedWorkspaceID = nil
        await Self.endActivity(id: activityID, finalState: finalState)
    }

    // ActivityKit calls live in nonisolated statics that take only `Sendable`
    // values (an id and a ContentState) and re-resolve the `Activity` locally.
    // `Activity` is not Sendable, so awaiting one of its methods from this
    // @MainActor class sends actor-isolated state out of its region and Swift 6
    // rejects it. Resolving inside a nonisolated context keeps the handle local.
    private nonisolated static func endActivity(
        id: String,
        finalState: AgentActivityAttributes.ContentState
    ) async {
        guard let live = Activity<AgentActivityAttributes>.activities
            .first(where: { $0.id == id })
        else { return }
        await live.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
    }

    private nonisolated static func updateActivity(
        id: String,
        state: AgentActivityAttributes.ContentState,
        staleDate: Date
    ) async {
        guard let live = Activity<AgentActivityAttributes>.activities
            .first(where: { $0.id == id })
        else { return }
        await live.update(ActivityContent(state: state, staleDate: staleDate))
    }

    // MARK: - CloudKit reconciliation (M3)
    //
    // The bridge-driven path above (`recomputeLiveActivity`, fed by live `agent_state` events)
    // is the precise, real-time source of truth while connected. CloudKit is the backstop for
    // when it isn't: a silent push wakes the app (`AppDelegate`/`LiveActivityCloudKitBridge`)
    // or, failing that, this reconciliation runs on every foreground regardless. Both paths
    // write through the same `liveActivity`/`lastPushedActivityState` bookkeeping so the
    // bridge-driven coalescing above stays correct afterward.

    /// Called on `AppStore` init and on every `UIApplication.didBecomeActiveNotification`.
    /// Refreshes the iCloud status banner and rebuilds Live Activity state from the last
    /// summary the Mac wrote, independent of whether the iroh bridge is currently connected.
    func reconcileFromCloudKit() async {
        iCloudAccountStatus = await CloudKitPush.accountStatus()
        guard let summary = await CloudKitPush.fetchSummary() else { return }
        applyCloudKitSummary(summary)
    }

    private func applyCloudKitSummary(_ summary: CloudKitPush.Summary) {
        ensureLiveActivityStarted()
        guard let liveActivity else { return }

        let newState = AgentActivityAttributes.ContentState(
            blockedCount: summary.blockedCount,
            workingCount: summary.workingCount,
            headlineWorkspace: summary.blockedCount > 0 ? summary.mostRecentBlockedWorkspaceTitle : nil
        )
        guard newState != lastPushedActivityState else { return }
        // CloudKit reconciliation always wins immediately rather than going through the 2s
        // coalescing window -- it only runs at most once per foreground/background-wake, so
        // there's no churn to coalesce against.
        pendingActivityUpdateTask?.cancel()
        pendingActivityUpdateTask = nil
        pendingActivityContentState = nil
        pushActivityUpdate(newState, activityID: liveActivity.id)
    }

    private func deriveActivityContentState() -> AgentActivityAttributes.ContentState {
        let allSurfaces = surfacesByWorkspace.values.flatMap { $0 }
        let blockedCount = allSurfaces.filter { $0.badge == .blocked }.count
        let workingCount = allSurfaces.filter { $0.badge == .working }.count
        return AgentActivityAttributes.ContentState(
            blockedCount: blockedCount,
            workingCount: workingCount,
            headlineWorkspace: blockedCount > 0 ? headlineWorkspaceTitle() : nil
        )
    }

    /// The workspace that most recently transitioned into `blocked`, as long
    /// as it is still blocked. If that workspace has since cleared (or was
    /// never set -- e.g. right after a full resync, which has no transition
    /// history), falls back to any currently-blocked workspace and adopts it
    /// as the new sticky pointer.
    private func headlineWorkspaceTitle() -> String? {
        if let id = mostRecentBlockedWorkspaceID, badge(for: id) == .blocked {
            return workspaceTitle(for: id)
        }
        guard let fallback = sortedWorkspaces.first(where: { badge(for: $0.id) == .blocked }) else {
            mostRecentBlockedWorkspaceID = nil
            return nil
        }
        mostRecentBlockedWorkspaceID = fallback.id
        return fallback.title
    }
}
