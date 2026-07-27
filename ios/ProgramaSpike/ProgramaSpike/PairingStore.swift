import Foundation

/// Persists the pairing ticket in `UserDefaults` so relaunching the app
/// reconnects without retyping it. The pairing token is intentionally never
/// persisted here — it is single-use and only needed the first time a
/// device pairs; every reconnect after that sends no pair line at all (the
/// bridge's allowlist already has this device's iroh EndpointID).
enum PairingStore {
    private static let ticketKey = "programa.spike.pairingTicket"

    static func loadTicket() -> String? {
        UserDefaults.standard.string(forKey: ticketKey)
    }

    static func saveTicket(_ ticket: String) {
        UserDefaults.standard.set(ticket, forKey: ticketKey)
    }

    static func clearTicket() {
        UserDefaults.standard.removeObject(forKey: ticketKey)
    }
}
