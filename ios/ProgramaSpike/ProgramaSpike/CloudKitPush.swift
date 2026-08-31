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

    /// Reconciles the desired subscription against the private database. A local flag cannot
    /// represent server truth: the user may switch iCloud accounts or delete subscriptions
    /// remotely while the app remains installed.
    static func ensureSubscription() async {
        let database = container.privateCloudDatabase
        do {
            let existing = try await database.subscription(for: subscriptionID)
            if subscriptionMatchesDesiredState(existing) { return }
            try await deleteSubscription(from: database)
        } catch let error as CKError where error.code == .unknownItem {
            // Missing is the normal first-run/server-deletion path; create below.
        } catch {
            NSLog("CloudKitPush: subscription reconciliation failed: %@", "\(error)")
            return
        }

        do {
            try await saveSubscription(to: database)
        } catch {
            // No local success bit is recorded. Every foreground/connect retries.
            NSLog("CloudKitPush: subscription save failed: %@", "\(error)")
        }
    }

    private static var desiredOptions: CKQuerySubscription.Options {
        [.firesOnRecordCreation, .firesOnRecordUpdate]
    }

    private static func makeDesiredSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: desiredOptions
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
        return subscription
    }

    private static func subscriptionMatchesDesiredState(_ subscription: CKSubscription) -> Bool {
        guard let query = subscription as? CKQuerySubscription,
              query.recordType == recordType,
              query.querySubscriptionOptions == desiredOptions,
              let info = query.notificationInfo
        else {
            return false
        }
        return info.alertBody == String(
            localized: "cloudKit.push.alertBody",
            defaultValue: "An agent needs you"
        )
            && info.soundName == nil
            && info.shouldSendContentAvailable
    }

    private static func deleteSubscription(from database: CKDatabase) async throws {
        let result = try await database.modifySubscriptions(
            saving: [],
            deleting: [subscriptionID]
        )
        guard let deletion = result.deleteResults[subscriptionID] else {
            throw CloudKitPushError.missingModificationResult
        }
        try deletion.get()
    }

    private static func saveSubscription(to database: CKDatabase) async throws {
        let result = try await database.modifySubscriptions(
            saving: [makeDesiredSubscription()],
            deleting: []
        )
        guard let save = result.saveResults[subscriptionID] else {
            throw CloudKitPushError.missingModificationResult
        }
        _ = try save.get()
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

private enum CloudKitPushError: Error {
    case missingModificationResult
}
