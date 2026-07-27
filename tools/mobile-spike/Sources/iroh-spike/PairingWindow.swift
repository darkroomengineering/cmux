import Foundation

/// A single-use, time-boxed pairing invitation opened by `bridge --pair`.
/// Holds the freshly generated token in memory only (never persisted) and
/// closes itself the moment a matching token is presented, so a printed
/// token can't be replayed later to pair a second device once the intended
/// one has paired.
actor PairingWindow {
    private var tokenData: Data?
    private let expiresAt: ContinuousClock.Instant

    init(token: Data, duration: Duration) {
        tokenData = token
        expiresAt = ContinuousClock.now.advanced(by: duration)
    }

    var isOpen: Bool {
        tokenData != nil && ContinuousClock.now < expiresAt
    }

    /// Compares `presented` against the window's token in constant time
    /// (manual accumulate-XOR — see `ConstantTime`). On match, consumes
    /// (closes) the window and returns `true`. On mismatch, leaves the
    /// window open — a mistyped attempt shouldn't lock out a legitimate
    /// retry within the 5-minute window — and returns `false`.
    func attemptConsume(_ presented: Data) -> Bool {
        guard let tokenData, ContinuousClock.now < expiresAt else { return false }
        guard ConstantTime.equal(tokenData, presented) else { return false }
        self.tokenData = nil
        return true
    }
}
