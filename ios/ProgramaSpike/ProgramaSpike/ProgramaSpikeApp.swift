import SwiftUI

@main
struct ProgramaSpikeApp: App {
    // M3: registers for remote notifications and handles the background-wake half of the
    // CloudKit push path (`didReceiveRemoteNotification`) -- see `AppDelegate`'s doc comment
    // for why that logic lives outside the SwiftUI `AppStore`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
