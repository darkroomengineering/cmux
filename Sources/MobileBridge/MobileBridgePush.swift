import Bonsplit
import CloudKit
import Foundation

/// M3: publishes a small, low-sensitivity agent-activity summary to the user's own iCloud
/// private database via CloudKit, so a `CKQuerySubscription` on the paired iPhone can wake it
/// with a push while the mobile bridge's iroh connection is dead (backgrounded/suspended --
/// see `MobileBridgeListener`). No server Programa operates: each user's Mac writes only to
/// *their own* private database, under container `iCloud.com.darkroom.programa`. The record
/// carries nothing sensitive beyond counts and a workspace title -- never prompt/output text,
/// mirroring the mobile bridge's own "never put prompt or output text in a notification
/// payload" rule (see `plans/golden-tumbling-gray.md`'s "Security implications" section).
///
/// Gated on:
/// - `MobileBridgeSettings` being anything other than `.off` -- users who never turned on the
///   phone companion generate zero CloudKit traffic.
/// - `CKContainer.accountStatus == .available` -- silently no-ops (logs once) otherwise, e.g.
///   not signed into iCloud on this Mac, or (today) the container entitlement not yet present
///   -- see the macOS entitlements note in this milestone's report.
///
/// Trigger point: called directly from `Workspace.updatePanelAgentState` /
/// `clearPanelAgentState` / `resetSidebarContext` (`Workspace+SidebarTelemetry.swift`),
/// alongside the existing `SocketEventBroadcaster.shared.publishAgentState(...)` calls at each
/// site. Chosen over adding an observer mechanism to `SocketEventBroadcaster` itself: that
/// class is shared, hot-path infrastructure for the entire v2 subscription fan-out, and giving
/// it a second consumer channel is a materially bigger, riskier change than three one-line
/// calls at the existing telemetry funnel that already fires on every transition.
final class MobileBridgePush: @unchecked Sendable {
    static let shared = MobileBridgePush()

    static let containerIdentifier = "iCloud.com.darkroom.programa"
    static let recordType = "AgentStatus"
    /// Stable record name (default zone, no custom `recordID.zoneID`) so every write updates
    /// the same record in place rather than accumulating new ones in the user's iCloud quota.
    static let recordName = "agent-status-summary"

    /// Never write more than once every this many seconds -- every CloudKit write is a push
    /// delivered to the user's phone.
    private static let minimumWriteInterval: TimeInterval = 5

    struct Summary: Equatable {
        var blockedCount: Int
        var workingCount: Int
        var mostRecentBlockedWorkspaceTitle: String?
    }

    private let container: CKContainer

    /// Serializes all mutable state below (`trackedBlockedTitle` through
    /// `didLogAccountUnavailable`). Every access to that state -- including from CloudKit's
    /// own completion-handler callbacks, which run on an arbitrary system queue -- is
    /// dispatched through this queue rather than guarded by a lock, since the coalescing
    /// timer (`asyncAfter`) is native to `DispatchQueue` and this avoids mixing a lock with
    /// queue-hopping.
    private let queue = DispatchQueue(label: "com.darkroom.programa.mobileBridgePush")

    private var trackedBlockedTitle: String?
    private var lastWrittenSummary: Summary?
    private var pendingSummary: Summary?
    private var lastWriteAt: Date = .distantPast
    private var coalesceScheduled = false
    private var didLogAccountUnavailable = false

    /// **Hard build-time kill switch -- must stay `false` until the release pipeline can
    /// safely ship the CloudKit entitlement.**
    ///
    /// Adding `com.apple.developer.icloud-container-identifiers` /
    /// `com.apple.developer.icloud-services` to `programa.entitlements` is *not* done as part
    /// of this milestone: those are Apple-restricted, App-ID-level capability entitlements
    /// that must be present in an embedded provisioning profile to survive AMFI's launch-time
    /// check. `scripts/sign-release-app.sh` signs the notarized release build with a bare
    /// `codesign --entitlements` pass and embeds no provisioning profile at all -- the exact
    /// gap that bricked launch for every user in the 2026-07-14 incident (POSIX 163, see
    /// `memory/restricted-entitlements-brick-app.md`) over a different restricted entitlement.
    /// `main` auto-ships every green CI run, so there is no safe way to "try it and see";
    /// notarization does not catch this class of failure, only a real launch does.
    ///
    /// This flag is the second, independent gate (on top of `MobileBridgeSettings` and
    /// `CKContainer.accountStatus`) that keeps this file inert in a shipped build even though
    /// it already compiles and links against CloudKit: `CKContainer.accountStatus` alone would
    /// still report `.available` on any Mac signed into iCloud, entitlement or not, so relying
    /// on that gate alone is not sufficient to keep this dark. Flip to `true` only after the
    /// release pipeline embeds a provisioning profile carrying the iCloud capability (see this
    /// milestone's report for exactly what that requires) and a real Developer-ID-signed,
    /// notarized build has been launch-tested outside CI with the entitlement present.
    static let releaseProvisioningComplete = false

    private init(container: CKContainer = CKContainer(identifier: MobileBridgePush.containerIdentifier)) {
        self.container = container
    }

    /// Call on every agent-state transition (set or clear) that already calls
    /// `SocketEventBroadcaster.shared.publishAgentState`. Must be called from the main thread
    /// -- it reads `TabManager.tabs` / `Workspace.aggregateAgentState` synchronously, both of
    /// which ARE main-actor isolated (the compiler rejects reading them from a nonisolated
    /// context). Annotated `@MainActor` to match; the call sites in
    /// `Workspace+SidebarTelemetry.swift` already run there, alongside the existing
    /// `publishAgentState` calls, so this adds no hop. Only the derived counts cross to the
    /// background queue below -- plain Ints and an optional String.
    @MainActor
    func noteAgentStateChanged(workspaceId: UUID, workspaceTitle: String, changedState: AgentActivityState?) {
        guard Self.releaseProvisioningComplete else { return }
        guard Self.bridgeEnabled else { return }

        let workspaces = TerminalController.shared.tabManager?.tabs ?? []
        var blockedCount = 0
        var workingCount = 0
        for workspace in workspaces {
            switch workspace.aggregateAgentState {
            case .blocked: blockedCount += 1
            case .working: workingCount += 1
            case .idle, nil: break
            }
        }
        let newlyBlockedWorkspaceTitle = (changedState == .blocked) ? workspaceTitle : nil

        queue.async { [weak self] in
            self?.handleChange(
                blockedCount: blockedCount,
                workingCount: workingCount,
                newlyBlockedWorkspaceTitle: newlyBlockedWorkspaceTitle
            )
        }
    }

    private static var bridgeEnabled: Bool {
        let raw = UserDefaults.standard.string(forKey: MobileBridgeSettings.appStorageKey)
            ?? MobileBridgeSettings.defaultMode.rawValue
        return MobileBridgeSettings.mode(for: raw) != .off
    }

    // MARK: - `queue`-confined

    private func handleChange(blockedCount: Int, workingCount: Int, newlyBlockedWorkspaceTitle: String?) {
        if let newlyBlockedWorkspaceTitle {
            trackedBlockedTitle = newlyBlockedWorkspaceTitle
        }
        if blockedCount == 0 {
            trackedBlockedTitle = nil
        }

        let summary = Summary(
            blockedCount: blockedCount,
            workingCount: workingCount,
            mostRecentBlockedWorkspaceTitle: trackedBlockedTitle
        )
        guard summary != lastWrittenSummary, summary != pendingSummary else { return }
        pendingSummary = summary
        scheduleCoalescedWriteIfNeeded()
    }

    private func scheduleCoalescedWriteIfNeeded() {
        guard !coalesceScheduled else { return }
        coalesceScheduled = true
        let elapsed = Date().timeIntervalSince(lastWriteAt)
        let delay = max(0, Self.minimumWriteInterval - elapsed)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushPendingWrite()
        }
    }

    private func flushPendingWrite() {
        coalesceScheduled = false
        guard let summary = pendingSummary, summary != lastWrittenSummary else {
            pendingSummary = nil
            return
        }
        pendingSummary = nil
        lastWriteAt = Date()
        checkAccountStatusAndSave(summary)
    }

    private func checkAccountStatusAndSave(_ summary: Summary) {
        container.accountStatus { [weak self] status, error in
            guard let self else { return }
            self.queue.async {
                guard status == .available, error == nil else {
                    if !self.didLogAccountUnavailable {
                        self.didLogAccountUnavailable = true
#if DEBUG
                        dlog(
                            "mobileBridge.push.accountUnavailable status=\(status.rawValue) " +
                            "error=\(String(describing: error))"
                        )
#endif
                    }
                    return
                }
                self.didLogAccountUnavailable = false
                self.performSave(summary)
            }
        }
    }

    /// Runs on `queue`. Always constructs a fresh `CKRecord` (never fetches first) and saves
    /// with `.changedKeys` -- correct for this record's single-writer-per-account semantics
    /// (only this Mac, under this iCloud account, ever writes `agent-status-summary`), and
    /// avoids the `.ifServerRecordUnchanged` default's change-tag conflict since we never hold
    /// a server-issued tag.
    private func performSave(_ summary: Summary) {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["blockedCount"] = summary.blockedCount as CKRecordValue
        record["workingCount"] = summary.workingCount as CKRecordValue
        if let title = summary.mostRecentBlockedWorkspaceTitle {
            record["mostRecentBlockedWorkspaceTitle"] = title as CKRecordValue
        } else {
            // Explicit nil clears the field server-side (and counts as a "changed key") --
            // omitting the key entirely would leave a stale title from a previous block.
            record["mostRecentBlockedWorkspaceTitle"] = nil
        }

        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.qualityOfService = .utility
        operation.modifyRecordsResultBlock = { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success:
                    self.lastWrittenSummary = summary
#if DEBUG
                    dlog(
                        "mobileBridge.push.wrote blocked=\(summary.blockedCount) " +
                        "working=\(summary.workingCount)"
                    )
#endif
                case let .failure(error):
                    NSLog("MobileBridgePush: CloudKit write failed: %@", "\(error)")
                }
            }
        }
        container.privateCloudDatabase.add(operation)
    }
}
