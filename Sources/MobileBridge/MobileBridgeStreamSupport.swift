import Foundation
import IrohLib

/// Buffers reads from a QUIC `RecvStream` and splits them on `\n`, mirroring
/// the newline-delimited JSON-RPC framing Programa's own control socket
/// uses. Ported verbatim (renamed) from
/// `tools/mobile-spike/Sources/iroh-spike/StreamFraming.swift`'s
/// `StreamLineReader` -- see that file for the full rationale.
///
/// Not safe to call `nextLine()` concurrently from two callers -- each
/// instance is driven by exactly one reader task for its lifetime.
final class MobileBridgeStreamLineReader: @unchecked Sendable {
    private let stream: RecvStream
    private var buffer = Data()
    private let chunkSize: UInt32 = 65536

    init(stream: RecvStream) {
        self.stream = stream
    }

    /// Returns the next line (without its trailing `\n`), or `nil` at end of
    /// stream.
    func nextLine() async throws -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newlineIndex])
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                return line
            }
            let chunk = try await stream.read(sizeLimit: chunkSize)
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer.removeAll()
                    return remaining
                }
                return nil
            }
            buffer.append(chunk)
        }
    }
}

/// Serializes writes to a QUIC `SendStream`. Ported verbatim (renamed) from
/// `tools/mobile-spike/Sources/iroh-spike/StreamFraming.swift`'s
/// `FrameWriter`.
actor MobileBridgeFrameWriter {
    private let stream: SendStream

    init(stream: SendStream) {
        self.stream = stream
    }

    func writeLine(_ data: Data) async throws {
        var framed = data
        framed.append(0x0A)
        try await stream.writeAll(buf: framed)
    }
}

enum MobileBridgeConstantTime {
    /// Manual accumulate-XOR comparison (no `==`) so a mismatching pairing
    /// token doesn't leak timing information via early-exit comparison.
    /// Ported verbatim from
    /// `tools/mobile-spike/Sources/iroh-spike/StreamFraming.swift`.
    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in 0 ..< lhs.count {
            diff |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return diff == 0
    }
}

enum MobileBridgeBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A single-use, time-boxed pairing invitation opened from Settings. Holds
/// the freshly generated token in memory only (never persisted) and closes
/// itself the moment a matching token is presented, so a displayed token
/// can't be replayed later to pair a second device once the intended one
/// has paired. Ported verbatim (renamed) from
/// `tools/mobile-spike/Sources/iroh-spike/PairingWindow.swift`.
actor MobileBridgePairingWindow {
    private var tokenData: Data?
    private let expiresAt: ContinuousClock.Instant

    init(token: Data, duration: Duration) {
        tokenData = token
        expiresAt = ContinuousClock.now.advanced(by: duration)
    }

    var isOpen: Bool {
        tokenData != nil && ContinuousClock.now < expiresAt
    }

    /// Compares `presented` against the window's token in constant time. On
    /// match, consumes (closes) the window and returns `true`. On mismatch,
    /// leaves the window open -- a mistyped attempt shouldn't lock out a
    /// legitimate retry within the 5-minute window -- and returns `false`.
    func attemptConsume(_ presented: Data) -> Bool {
        guard let tokenData, ContinuousClock.now < expiresAt else { return false }
        guard MobileBridgeConstantTime.equal(tokenData, presented) else { return false }
        self.tokenData = nil
        return true
    }
}

/// The only JSON-RPC methods the mobile bridge will forward to Programa's
/// terminal control dispatch. Everything else -- including destructive
/// methods like `worktree.remove` and `browser.navigate` -- is rejected
/// before it ever reaches `TerminalController.handleClient`.
///
/// This is the bridge's core security boundary: the control dispatch has no
/// notion of a restricted "mobile" client, so enforcement lives entirely
/// here. Ported verbatim from
/// `tools/mobile-spike/Sources/iroh-spike/MethodAllowList.swift` -- do not
/// widen without a matching change to the M1 plan.
enum MobileBridgeMethodAllowList {
    static let allowed: Set<String> = [
        "system.ping",
        "workspace.list",
        "surface.list",
        "subscribe",
        "unsubscribe",
        "agent.prompt",
        "surface.send_text",
        "surface.send_key",
    ]

    static func isAllowed(_ method: String) -> Bool {
        allowed.contains(method)
    }
}
