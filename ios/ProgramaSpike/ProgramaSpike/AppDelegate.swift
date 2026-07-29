import CloudKit
import UIKit
import UserNotifications

/// M3: the parts of CloudKit push delivery that must work even before any SwiftUI scene
/// exists -- see `LiveActivityCloudKitBridge`'s doc comment for why the background-wake path
/// cannot depend on `AppStore`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Required for the OS to hold an APNs token at all -- CloudKit registers that token
        // with its own servers internally; Programa never sees or stores it directly.
        application.registerForRemoteNotifications()

        // Only needed so the subscription's generic `alertBody` can actually show a lock-screen
        // line. The `shouldSendContentAvailable` background wake works regardless of this
        // authorization -- it is a separate iOS mechanism gated only by `UIBackgroundModes`.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error {
                NSLog("AppDelegate: notification authorization request failed: %@", "\(error)")
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // No-op by design: CloudKit owns device-token registration with its own servers.
        // Programa never persists or transmits this token.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("AppDelegate: remote notification registration failed: %@", "\(error)")
    }

    /// The ~30-second background-wake budget Apple grants for a `content-available` push.
    /// `LiveActivityCloudKitBridge.reconcile()` is one CloudKit record fetch plus (at most) one
    /// local `Activity.update()` -- comfortably inside that window.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }

        Task {
            let result = await LiveActivityCloudKitBridge.reconcile()
            completionHandler(result)
        }
    }
}
