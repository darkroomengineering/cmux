import Foundation

/// Shared identity/state directory for the mobile spike tooling, overridable
/// via `PROGRAMA_SPIKE_HOME` so `listen`/`dial`/`bridge`/`dial-rpc` can run as
/// distinct identities from the same machine during local verification.
///
/// Extracted from `SecretKeyStore` (which used to compute this privately) so
/// `TrustedDeviceStore` can share the exact same directory instead of
/// duplicating the override/default logic.
enum SpikeHome {
    static func directory() -> URL {
        if let override = ProcessInfo.processInfo.environment["PROGRAMA_SPIKE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".programa/mobile-spike", isDirectory: true)
    }
}
