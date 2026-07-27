import Foundation
import IrohLib

/// Buffers reads from a QUIC `RecvStream` and splits them on `\n`, mirroring
/// the newline-delimited JSON-RPC framing Programa's own control socket
/// uses. `RecvStream` only exposes size-limited/whole-buffer reads (`read`,
/// `readExact`, `readToEnd`) — no line API — so this reimplements the same
/// buffered-chunk-then-split approach `UnixSocketPipe` uses for the Programa
/// socket side of the relay, just against the iroh stream instead of a raw
/// fd.
///
/// Not safe to call `nextLine()` concurrently from two callers — each
/// instance is driven by exactly one reader task for its lifetime.
final class StreamLineReader: @unchecked Sendable {
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

/// Serializes writes to a QUIC `SendStream` so the two directions that share
/// one bridged connection — forwarding Programa's replies/pushed events, and
/// replying inline to rejected/forbidden requests — never interleave partial
/// frames on the wire.
actor FrameWriter {
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

enum ConstantTime {
    /// Manual accumulate-XOR comparison (no `==`) so a mismatching pairing
    /// token doesn't leak timing information via early-exit comparison.
    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in 0 ..< lhs.count {
            diff |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return diff == 0
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
