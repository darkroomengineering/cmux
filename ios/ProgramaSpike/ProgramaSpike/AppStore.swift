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

    var pairingTicketDraft: String
    var pairingTokenDraft: String = ""

    private let connection = BridgeConnection()
    private var currentTicket: String?
    private var reconnectTask: Task<Void, Never>?

    init() {
        let savedTicket = PairingStore.loadTicket()
        pairingTicketDraft = savedTicket ?? ""
        currentTicket = (savedTicket?.isEmpty == false) ? savedTicket : nil

        Task { [weak self] in await self?.consumePhase() }
        Task { [weak self] in await self?.consumePath() }
        Task { [weak self] in await self?.consumeEvents() }

        if let ticket = currentTicket {
            Task { [weak self] in await self?.attemptConnect(ticket: ticket, token: nil) }
        }
    }

    // MARK: - User actions

    func connectManually() async {
        let ticket = pairingTicketDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticket.isEmpty else { return }
        let token = pairingTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        PairingStore.saveTicket(ticket)
        currentTicket = ticket
        pairingTokenDraft = ""
        await attemptConnect(ticket: ticket, token: token.isEmpty ? nil : token)
    }

    func manualResync() async {
        do {
            try await resyncAll()
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
            case .connecting, .pairing:
                connectionBanner = .connecting
            case .connected:
                connectionBanner = .connected
                lastSyncError = nil
                reconnectTask?.cancel()
                reconnectTask = nil
                await handleConnected()
            case let .failed(reason):
                connectionBanner = .reconnecting
                lastSyncError = reason
                scheduleReconnect()
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
        rows[index].agentState = payload.state
        rows[index].agentStateSource = payload.source
        surfacesByWorkspace[payload.workspaceId] = rows
    }

    private func handleConnected() async {
        do {
            try await resyncAll()
            try await connection.subscribe(classes: ["agent_state", "workspace_lifecycle"])
            stage = .workspaces
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

    private func scheduleReconnect() {
        guard reconnectTask == nil, let ticket = currentTicket, !ticket.isEmpty else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            await self.attemptConnect(ticket: ticket, token: nil)
            self.reconnectTask = nil
        }
    }
}
