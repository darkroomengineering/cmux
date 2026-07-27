import Foundation

/// A phone identity that has completed the `--pair` token flow and may
/// connect to `bridge` without re-presenting a token.
struct TrustedDevice: Codable, Equatable {
    let endpointId: String
    let label: String
    let pairedAt: Date
}

/// Persisted allow-list of previously paired phone identities, so pairing is
/// a one-time step per device rather than something repeated on every
/// connection. Same storage convention as `SecretKeyStore`: plaintext JSON
/// under `PROGRAMA_SPIKE_HOME` (see `SpikeHome`), owner-only (0600)
/// permissions. Spike-grade, not Keychain-backed.
actor TrustedDeviceStore {
    private var devices: [TrustedDevice]
    private let fileURL: URL

    private init(devices: [TrustedDevice], fileURL: URL) {
        self.devices = devices
        self.fileURL = fileURL
    }

    static func load() throws -> TrustedDeviceStore {
        let directory = SpikeHome.directory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("trusted-devices.json")
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([TrustedDevice].self, from: data)
        else {
            return TrustedDeviceStore(devices: [], fileURL: fileURL)
        }
        return TrustedDeviceStore(devices: decoded, fileURL: fileURL)
    }

    func isTrusted(_ endpointId: String) -> Bool {
        devices.contains { $0.endpointId == endpointId }
    }

    /// Persists `endpointId` as trusted. Idempotent: re-adding an
    /// already-trusted device is a no-op (no duplicate entries, no rewrite).
    func add(endpointId: String, label: String) throws {
        guard !isTrusted(endpointId) else { return }
        devices.append(TrustedDevice(endpointId: endpointId, label: label, pairedAt: Date()))
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(devices)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
