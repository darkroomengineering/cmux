import Foundation

/// Persists a stable 32-byte Iroh secret key in UserDefaults so this
/// device's node identity survives relaunch. Spike-grade only — real
/// pairing (next milestone) needs Keychain, not UserDefaults.
enum SecretKeyStore {
    private static let defaultsKey = "programa.spike.secretKey"

    static func loadOrCreate() throws -> Data {
        let defaults = UserDefaults.standard
        if let existing = defaults.data(forKey: defaultsKey), existing.count == 32 {
            return existing
        }
        let bytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        defaults.set(bytes, forKey: defaultsKey)
        return bytes
    }
}
