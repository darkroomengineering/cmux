import Foundation

enum SessionMachineryGate {
    /// Single cached flag for deciding whether to run session persistence machinery.
    /// True when XCTest is present in the current process environment.
    static let isUnitTesting: Bool = {
        let env = ProcessInfo.processInfo.environment

        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        return false
    }()

    /// True once the app has begun terminating. Mirrors `AppDelegate`'s
    /// private `isTerminatingApp` for the session machinery, which has to
    /// tell a surface closed by the user apart from one that merely stopped
    /// existing because the process is going away.
    ///
    /// The distinction matters to escrow: a user-closed session must be
    /// released so the holder stops keeping its pty master open, while a
    /// session that is open at quit must stay escrowed so the next launch can
    /// reattach it. Set on the main thread during termination and read from
    /// surface teardown, which also runs on main.
    nonisolated(unsafe) static var isApplicationTerminating = false
}
