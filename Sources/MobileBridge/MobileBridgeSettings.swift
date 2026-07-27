import Foundation

/// Access mode for Programa's mobile companion bridge (M1): whether the
/// in-process iroh listener that lets a paired iPhone reach this Mac's
/// terminal control dispatch is running at all, and if so, whether only
/// devices that completed the one-time pairing handshake may connect.
/// Mirrors the shape of `SocketControlMode` (see `SocketControlSettings.swift`)
/// but is a wholly separate on/off switch from Programa's local Unix
/// control socket -- turning this on never changes the local socket's
/// access mode.
enum MobileBridgeMode: String, CaseIterable, Identifiable {
    case off
    case pairedDevicesOnly

    var id: String { rawValue }

    static var uiCases: [MobileBridgeMode] { [.off, .pairedDevicesOnly] }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "settings.phone.mode.off", defaultValue: "Off")
        case .pairedDevicesOnly:
            return String(localized: "settings.phone.mode.pairedDevicesOnly", defaultValue: "Paired Devices Only")
        }
    }
}

struct MobileBridgeSettings {
    static let appStorageKey = "mobileBridgeMode"

    static var defaultMode: MobileBridgeMode { .off }

    static func mode(for raw: String) -> MobileBridgeMode {
        MobileBridgeMode(rawValue: raw) ?? defaultMode
    }
}

/// Shared storage directory for mobile-bridge identity/trust state, under
/// the same `~/Library/Application Support/programa` directory Programa's
/// control socket uses (see `SocketControlSettings`'s `stableSocketDirectoryURL`)
/// -- never the app bundle, so identity and pairings survive reinstalls and
/// version updates.
enum MobileBridgeHome {
    static func directory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("programa", isDirectory: true)
    }
}

/// A phone identity that has completed the pairing token flow and may
/// connect to the mobile bridge without re-presenting a token. Ported from
/// `tools/mobile-spike/Sources/iroh-spike/TrustedDeviceStore.swift`.
struct MobileBridgeTrustedDevice: Codable, Equatable, Identifiable {
    let endpointId: String
    let label: String
    let pairedAt: Date

    var id: String { endpointId }
}

/// Persisted allow-list of previously paired phone identities, so pairing is
/// a one-time step per device. Same storage convention as the CLI spike:
/// plaintext JSON under `MobileBridgeHome`, owner-only (0600) permissions.
/// Unlike the spike, devices can also be removed (Settings "Remove" action).
actor MobileBridgeTrustedDeviceStore {
    static let shared = MobileBridgeTrustedDeviceStore()

    private var devices: [MobileBridgeTrustedDevice] = []
    private var didLoad = false
    private let fileURL: URL

    private init(fileURL: URL = MobileBridgeHome.directory().appendingPathComponent("mobile-bridge-trusted-devices.json")) {
        self.fileURL = fileURL
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([MobileBridgeTrustedDevice].self, from: data)
        else { return }
        devices = decoded
    }

    func isTrusted(_ endpointId: String) -> Bool {
        loadIfNeeded()
        return devices.contains { $0.endpointId == endpointId }
    }

    /// Persists `endpointId` as trusted. Idempotent: re-adding an
    /// already-trusted device is a no-op (no duplicate entries, no rewrite).
    @discardableResult
    func add(endpointId: String, label: String) -> Bool {
        loadIfNeeded()
        guard !devices.contains(where: { $0.endpointId == endpointId }) else { return false }
        devices.append(MobileBridgeTrustedDevice(endpointId: endpointId, label: label, pairedAt: Date()))
        persist()
        return true
    }

    /// Revokes a paired device immediately (Settings "Remove" action).
    func remove(endpointId: String) {
        loadIfNeeded()
        devices.removeAll { $0.endpointId == endpointId }
        persist()
    }

    func allDevices() -> [MobileBridgeTrustedDevice] {
        loadIfNeeded()
        return devices.sorted { $0.pairedAt > $1.pairedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

/// Persists a stable 32-byte Iroh secret key across app relaunches so this
/// Mac's mobile-bridge node identity survives restarts. Ported from
/// `tools/mobile-spike/Sources/iroh-spike/SecretKeyStore.swift`; stored
/// under Application Support (never in the app bundle), owner-only (0600).
enum MobileBridgeSecretKeyStore {
    static func loadOrCreate(fileManager: FileManager = .default) throws -> Data {
        let directory = MobileBridgeHome.directory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("mobile-bridge-secret-key")
        if let existing = try? Data(contentsOf: file), existing.count == 32 {
            return existing
        }

        let bytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        try bytes.write(to: file, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return bytes
    }
}
