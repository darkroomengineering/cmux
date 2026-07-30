import Foundation

/// Combines the mobile-bridge pairing ticket + token into a single URL so a
/// tester can transfer both by scanning one QR code (or pasting one string)
/// instead of hand-copying two long opaque strings between devices.
///
/// `programa-pair` (not the bare `programa`) was chosen as the scheme after
/// confirming no `CFBundleURLTypes`/URL scheme is registered anywhere in this
/// repo today (`Resources/Info.plist`, `Sources/`, `ios/ProgramaSpike/project.yml`) --
/// either name would have been free, but the more specific scheme makes the
/// pairing URL self-describing and leaves `programa://` open for some other
/// future purpose without a collision.
///
/// Kept in sync by hand with
/// `ios/ProgramaSpike/ProgramaSpike/PairingCode.swift` -- the two app
/// targets share no module, so there is no compiler-enforced tie between
/// them. Any format change here must be mirrored there.
enum MobileBridgePairingCode {
    static let scheme = "programa-pair"
    private static let host = "pair"

    /// The only format version this build understands. Bumping it is a breaking
    /// change for every already-installed phone: the companion ships through
    /// TestFlight and lags the Mac app, so a Mac that emits `v=2` while a phone
    /// still understands `v=1` must be rejected loudly rather than mis-parsed.
    /// Ship phone-side support for a new version BEFORE the Mac starts emitting it.
    static let currentVersion = "1"

    /// Builds the combined `programa-pair://pair?v=1&t=<ticket>&k=<token>`
    /// URL. `URLComponents` percent-encodes both query values, so neither
    /// the iroh ticket nor the base64url token needs manual escaping.
    static func makeURL(ticket: String, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "v", value: currentVersion),
            URLQueryItem(name: "t", value: ticket),
            URLQueryItem(name: "k", value: token),
        ]
        return components.url
    }

    struct Parsed {
        let ticket: String
        let token: String
    }

    /// Parses a combined pairing code back into its ticket/token. Returns
    /// `nil` for anything that isn't a well-formed `programa-pair://` URL
    /// with both `t` and `k` present -- callers should fall back to treating
    /// the input as a bare ticket in that case.
    static func parse(_ string: String) -> Parsed? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == scheme
        else { return nil }
        guard let items = components.queryItems else { return nil }
        // Reject an unrecognised version rather than reading `t`/`k` out of a
        // format we do not actually understand. A missing `v` is also rejected:
        // every code this app has ever emitted carries one.
        guard items.first(where: { $0.name == "v" })?.value == currentVersion else { return nil }
        guard
            let ticket = items.first(where: { $0.name == "t" })?.value, !ticket.isEmpty,
            let token = items.first(where: { $0.name == "k" })?.value, !token.isEmpty
        else { return nil }
        return Parsed(ticket: ticket, token: token)
    }
}
