import Foundation
import Security

protocol KeychainAccess {
    func data(service: String, account: String) throws -> Data?
    func set(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

enum CredentialStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case verificationFailed
    case randomGeneration(OSStatus)

    var description: String {
        switch self {
        case let .keychain(status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? String.localizedStringWithFormat(
                    String(localized: "credential.error.keychain", defaultValue: "Keychain error %d"),
                    status
                )
        case .verificationFailed:
            return String(
                localized: "credential.error.verificationFailed",
                defaultValue: "Keychain verification failed"
            )
        case let .randomGeneration(status):
            return String.localizedStringWithFormat(
                String(
                    localized: "credential.error.randomGenerationFailed",
                    defaultValue: "Secure random generation failed (%d)"
                ),
                status
            )
        }
    }
}

struct SystemKeychainAccess: KeychainAccess {
    func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CredentialStoreError.verificationFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    func set(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

enum ProgramaCredentialKeychain {
    static let service = "com.darkroom.programa.spike.credentials"
    static let irohSecretAccount = "iroh-secret-key"
    static let pairingTicketAccount = "pairing-ticket"
}
