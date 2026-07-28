import CloudKit
import Foundation

/// Reads the small agent-activity summary the Mac's `MobileBridgePush`
/// (`Sources/MobileBridge/MobileBridgePush.swift`) writes to the user's own iCloud private
/// database, and owns the `CKQuerySubscription` that lets Apple wake this app with a push when
/// that record changes.
///
/// Record shape (container id, record type/name, field names) is duplicated here rather than
/// shared with the Mac target -- separate build graphs, same convention already used for the
/// mobile-bridge ALPN (`BridgeConnection.alpn` vs `MobileBridgeListener`'s
/// `mobileBridgeALPN`). Any change to the Mac's field names must be mirrored here by hand.
enum CloudKitPush {
    static let containerIdentifier = "iCloud.com.darkroom.programa"
    static let recordType = "AgentStatus"
    static let recordName = "agent-status-summary"
    static let subscriptionID = "agent-status-subscription"

    /// A `CKQuerySubscription` persists server-side once saved, so re-creating it on every
    /// launch would be a wasted round trip. Tracked in `UserDefaults` per Apple's documented
    /// "save once" pattern for query subscriptions.
    private static let subscriptionSavedDefaultsKey = "cloudKitSubscriptionSaved"

    struct Summary: Sendable, Equatable {
        var blockedCount: Int
        var workingCount: Int
        var mostRecentBlockedWorkspaceTitle: String?
    }

    private static let container = CKContainer(identifier: containerIdentifier)

    /// Whether this iPhone is signed into iCloud at all. Does **not** detect a mismatched
    /// Apple ID between this phone and the paired Mac -- CloudKit exposes no API for that, so a
    /// wrong-account pairing still reports `.available` here and silently receives nothing.
    /// The UI must say this explicitly (see `PairConnectView`) rather than imply this check is
    /// a full guarantee.
    static func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    /// Idempotent: no-ops once a subscription has been saved (tracked locally). Safe to call
    /// on every successful connect/pairing.
    static func ensureSubscription() async {
        guard !UserDefaults.standard.bool(forKey: subscriptionSavedDefaultsKey) else { return }

        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        let info = CKSubscription.NotificationInfo()
        // Generic on purpose -- workspace names must never transit Apple's push payload, only
        // the record inside the user's own private database. A visible alertBody (with no
        // sound) promotes delivery to the reliable high-priority channel and shows a
        // lock-screen line without buzzing.
        info.alertBody = String(localized: "cloudKit.push.alertBody", defaultValue: "An agent needs you")
        info.soundName = nil
        // The same delivery also wakes the app in the background so it can refresh the Live
        // Activity locally -- see `AppDelegate.didReceiveRemoteNotification`.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        let operation = CKModifySubscriptionsOperation(
            subscriptionsToSave: [subscription],
            subscriptionIDsToDelete: nil
        )
        operation.qualityOfService = .utility

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            operation.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    UserDefaults.standard.set(true, forKey: subscriptionSavedDefaultsKey)
                case let .failure(error):
                    NSLog("CloudKitPush: subscription save failed: %@", "\(error)")
                }
                continuation.resume()
            }
            container.privateCloudDatabase.add(operation)
        }
    }

    /// Fetches the current summary record. Returns `nil` if the record doesn't exist yet (the
    /// Mac hasn't written anything), the account is unavailable, or the fetch failed --
    /// callers should treat all three identically: no-op, keep whatever local state exists.
    static func fetchSummary() async -> Summary? {
        let recordID = CKRecord.ID(recordName: recordName)
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            return Summary(
                blockedCount: record["blockedCount"] as? Int ?? 0,
                workingCount: record["workingCount"] as? Int ?? 0,
                mostRecentBlockedWorkspaceTitle: record["mostRecentBlockedWorkspaceTitle"] as? String
            )
        } catch {
            NSLog("CloudKitPush: fetch failed: %@", "\(error)")
            return nil
        }
    }
}
