import Foundation

/// Mirrors `Sources/MobileBridge/MobileBridgePairingCode.swift` on the macOS
/// app. Kept in sync by hand -- this iOS target and the macOS app share no
/// module, so there is no compiler-enforced tie between the two copies. Any
/// format change here must be mirrored there.
enum PairingCode {
    static let scheme = "programa-pair"

    /// Must match `MobileBridgePairingCode.currentVersion` on the Mac. This app
    /// ships through TestFlight and so lags the Mac app: if a newer Mac starts
    /// emitting a version this build does not know, rejecting is correct — the
    /// alternative is reading `t`/`k` out of a format that may have moved.
    static let currentVersion = "1"

    struct Parsed {
        let ticket: String
        let token: String
    }

    /// Parses a combined `programa-pair://pair?v=1&t=<ticket>&k=<token>`
    /// code (scanned or pasted) back into its ticket/token. Returns `nil`
    /// for anything that isn't a well-formed code with both `t` and `k`
    /// present -- callers should fall back to treating the input as a bare
    /// ticket in that case.
    static func parse(_ string: String) -> Parsed? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == scheme
        else { return nil }
        guard let items = components.queryItems else { return nil }
        guard items.first(where: { $0.name == "v" })?.value == currentVersion else { return nil }
        guard
            let ticket = items.first(where: { $0.name == "t" })?.value, !ticket.isEmpty,
            let token = items.first(where: { $0.name == "k" })?.value, !token.isEmpty
        else { return nil }
        return Parsed(ticket: ticket, token: token)
    }
}
