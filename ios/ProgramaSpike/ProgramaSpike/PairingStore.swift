import Foundation

/// Persists the pairing ticket in the device-only Keychain so relaunching the app
/// reconnects without retyping it. The pairing token is intentionally never
/// persisted here — it is single-use and only needed the first time a
/// device pairs; every reconnect after that sends no pair line at all (the
/// bridge's allowlist already has this device's iroh EndpointID).
enum PairingStore {
    private static let legacyTicketKey = "programa.spike.pairingTicket"

    static func loadTicket(
        keychain: any KeychainAccess = SystemKeychainAccess(),
        defaults: UserDefaults = .standard
    ) throws -> String? {
        if let stored = try keychain.data(
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.pairingTicketAccount
        ) {
            guard let ticket = String(data: stored, encoding: .utf8),
                  !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try keychain.delete(
                    service: ProgramaCredentialKeychain.service,
                    account: ProgramaCredentialKeychain.pairingTicketAccount
                )
                return nil
            }
            return ticket
        }

        guard let legacy = defaults.string(forKey: legacyTicketKey) else { return nil }
        guard !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.removeObject(forKey: legacyTicketKey)
            return nil
        }
        try saveTicket(legacy, keychain: keychain)
        defaults.removeObject(forKey: legacyTicketKey)
        return legacy
    }

    static func saveTicket(
        _ ticket: String,
        keychain: any KeychainAccess = SystemKeychainAccess()
    ) throws {
        let data = Data(ticket.utf8)
        guard !data.isEmpty else { throw CredentialStoreError.verificationFailed }
        try keychain.set(
            data,
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.pairingTicketAccount
        )
        guard try keychain.data(
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.pairingTicketAccount
        ) == data else {
            throw CredentialStoreError.verificationFailed
        }
    }

    private static let macNameKey = "pairedMacName"

    /// Persisted because the Mac only sends its name on the pairing frame;
    /// every later connection is a trusted reconnect that sends none.
    static func loadMacName() -> String? {
        UserDefaults.standard.string(forKey: macNameKey)
    }

    static func saveMacName(_ name: String) {
        UserDefaults.standard.set(name, forKey: macNameKey)
    }

    static func clearTicket(
        keychain: any KeychainAccess = SystemKeychainAccess(),
        defaults: UserDefaults = .standard
    ) throws {
        try keychain.delete(
            service: ProgramaCredentialKeychain.service,
            account: ProgramaCredentialKeychain.pairingTicketAccount
        )
        defaults.removeObject(forKey: legacyTicketKey)
    }
}
