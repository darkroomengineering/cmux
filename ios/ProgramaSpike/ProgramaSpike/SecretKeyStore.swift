import Foundation
import Security

/// Persists a stable 32-byte Iroh secret in the device-only Keychain so this
/// device's node identity survives relaunch without syncing or entering a backup.
enum SecretKeyStore {
    private static let legacyDefaultsKey = "programa.spike.secretKey"

    static func loadOrCreate(
        keychain: any KeychainAccess = SystemKeychainAccess(),
        defaults: UserDefaults = .standard
    ) throws -> Data {
        if let stored = try keychain.data(
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.irohSecretAccount
        ) {
            if stored.count == 32 { return stored }
            try keychain.delete(
                service: ProgramaCredentialKeychain.service,
                account: ProgramaCredentialKeychain.irohSecretAccount
            )
        }

        let legacy = defaults.data(forKey: legacyDefaultsKey)
        let secret: Data
        if let legacy, legacy.count == 32 {
            secret = legacy
        } else {
            secret = try generateSecret()
        }
        try persistAndVerify(secret, keychain: keychain)
        if legacy != nil {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
        return secret
    }

    private static func generateSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.randomGeneration(status)
        }
        return Data(bytes)
    }

    private static func persistAndVerify(
        _ secret: Data,
        keychain: any KeychainAccess
    ) throws {
        try keychain.set(
            secret,
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.irohSecretAccount
        )
        guard try keychain.data(
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.irohSecretAccount
        ) == secret else {
            throw CredentialStoreError.verificationFailed
        }
    }
}
