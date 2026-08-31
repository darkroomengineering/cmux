import Foundation
import Testing
@testable import ProgramaSpike

private final class MemoryKeychain: KeychainAccess {
    private(set) var values: [String: Data] = [:]

    func data(service: String, account: String) throws -> Data? {
        values["\(service):\(account)"]
    }

    func set(_ data: Data, service: String, account: String) throws {
        values["\(service):\(account)"] = data
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service):\(account)")
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "CredentialStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func migratesTheLegacyIrohSecretOnlyAfterKeychainPersistence() throws {
    let keychain = MemoryKeychain()
    let defaults = isolatedDefaults()
    let legacy = Data(repeating: 0x5A, count: 32)
    defaults.set(legacy, forKey: "programa.spike.secretKey")

    let loaded = try SecretKeyStore.loadOrCreate(keychain: keychain, defaults: defaults)

    #expect(loaded == legacy)
    #expect(defaults.data(forKey: "programa.spike.secretKey") == nil)
    #expect(keychain.values.values.first == legacy)
}

@Test func replacesACorruptKeychainSecretWithSecurelyGeneratedBytes() throws {
    let keychain = MemoryKeychain()
    try keychain.set(
        Data([0x01]),
        service: ProgramaCredentialKeychain.service,
        account: ProgramaCredentialKeychain.irohSecretAccount
    )

    let loaded = try SecretKeyStore.loadOrCreate(
        keychain: keychain,
        defaults: isolatedDefaults()
    )

    #expect(loaded.count == 32)
    #expect(loaded != Data([0x01]))
}

@Test func migratesTheLegacyPairingTicketToKeychain() throws {
    let keychain = MemoryKeychain()
    let defaults = isolatedDefaults()
    defaults.set("iroh-ticket", forKey: "programa.spike.pairingTicket")

    let loaded = try PairingStore.loadTicket(keychain: keychain, defaults: defaults)

    #expect(loaded == "iroh-ticket")
    #expect(defaults.string(forKey: "programa.spike.pairingTicket") == nil)
    #expect(keychain.values.values.first == Data("iroh-ticket".utf8))
}

@Test func deletesACorruptPairingTicketInsteadOfReturningIt() throws {
    let keychain = MemoryKeychain()
    try keychain.set(
        Data([0xFF]),
        service: ProgramaCredentialKeychain.service,
        account: ProgramaCredentialKeychain.pairingTicketAccount
    )

    let loaded = try PairingStore.loadTicket(
        keychain: keychain,
        defaults: isolatedDefaults()
    )

    #expect(loaded == nil)
    #expect(keychain.values.isEmpty)
}
