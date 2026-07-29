import ActivityKit
import Foundation
import UIKit

/// Background-wake half of M3's push path. Deliberately independent of `AppStore`: a silent
/// (`content-available`) CloudKit push can launch this app fully in the background before any
/// SwiftUI scene exists, and `AppStore` is only a `@State` owned by `ContentView` -- it may not
/// exist yet when `AppDelegate.didReceiveRemoteNotification` fires. This type re-resolves any
/// already-running Live Activity via `Activity<AgentActivityAttributes>.activities` instead,
/// exactly like `AppStore`'s own `nonisolated static` Live Activity helpers do (see that file's
/// doc comment on why `Activity` must be resolved locally rather than captured across an
/// isolation boundary).
///
/// Only ever *updates* an existing Live Activity -- never starts a new one. Starting one is
/// `AppStore.ensureLiveActivityStarted()`'s job, which requires a live bridge-connected session
/// this path does not have.
enum LiveActivityCloudKitBridge {
    private static let staleInterval: TimeInterval = 5 * 60

    @discardableResult
    static func reconcile() async -> UIBackgroundFetchResult {
        guard let summary = await CloudKitPush.fetchSummary() else { return .failed }
        guard let activity = Activity<AgentActivityAttributes>.activities.first else { return .noData }

        let newState = AgentActivityAttributes.ContentState(
            blockedCount: summary.blockedCount,
            workingCount: summary.workingCount,
            headlineWorkspace: summary.blockedCount > 0 ? summary.mostRecentBlockedWorkspaceTitle : nil
        )
        guard newState != activity.content.state else { return .noData }

        await activity.update(
            ActivityContent(state: newState, staleDate: Date().addingTimeInterval(staleInterval))
        )
        return .newData
    }
}
