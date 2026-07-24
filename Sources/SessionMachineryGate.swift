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
}
