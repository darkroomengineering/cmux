import Foundation

/// Persists a stable 32-byte Iroh secret key across process relaunches so a
/// device's node identity survives restarts. This is a spike-grade store —
/// plaintext file with owner-only permissions, not Keychain. Real pairing
/// (next milestone) will need proper secure storage.
enum SecretKeyStore {
    /// Loads the persisted secret key, generating and persisting a new one
    /// on first run.
    ///
    /// The storage directory defaults to `~/.programa/mobile-spike` and can
    /// be overridden with the `PROGRAMA_SPIKE_HOME` environment variable —
    /// this is what lets `listen` and `dial` run as two distinct identities
    /// from the same machine during local verification.
    static func loadOrCreate() throws -> Data {
        let directory = homeDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("secret-key")
        if let existing = try? Data(contentsOf: file), existing.count == 32 {
            return existing
        }

        let bytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        try bytes.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return bytes
    }

    private static func homeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["PROGRAMA_SPIKE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".programa/mobile-spike", isDirectory: true)
    }
}
