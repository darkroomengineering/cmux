import Foundation

public enum BoundedLineFramerError: Error, Equatable, Sendable {
    case frameTooLarge
}

/// Incrementally splits a byte stream on newlines while enforcing a hard
/// frame-size ceiling. Each byte is scanned at most once. One owner must
/// serialize calls to `nextLine`; both current clients have exactly one reader.
public final class BoundedLineFramer: @unchecked Sendable {
    public static let maximumLineByteCount = 8 * 1024 * 1024

    private var buffer = Data()
    private var scannedByteCount = 0
    private let chunkSize = 65_536

    public init() {}

    /// Returns the next line without its newline, or the remaining bytes at
    /// EOF. The read closure is never asked for enough bytes to let the buffer
    /// grow beyond the maximum frame size plus one delimiter byte.
    public func nextLine(
        readChunk: (_ sizeLimit: UInt32) async throws -> Data
    ) async throws -> Data? {
        while true {
            let searchStartIndex = buffer.index(
                buffer.startIndex,
                offsetBy: scannedByteCount
            )
            if let newlineIndex = buffer[searchStartIndex...].firstIndex(of: 0x0A) {
                guard buffer.distance(from: buffer.startIndex, to: newlineIndex)
                    <= Self.maximumLineByteCount
                else {
                    throw BoundedLineFramerError.frameTooLarge
                }
                let line = Data(buffer[buffer.startIndex ..< newlineIndex])
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                scannedByteCount = 0
                return line
            }
            scannedByteCount = buffer.count
            guard buffer.count <= Self.maximumLineByteCount else {
                throw BoundedLineFramerError.frameTooLarge
            }

            let bytesUntilOverflow = Self.maximumLineByteCount + 1 - buffer.count
            let readLimit = UInt32(min(chunkSize, bytesUntilOverflow))
            let chunk = try await readChunk(readLimit)
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer.removeAll()
                    scannedByteCount = 0
                    return remaining
                }
                scannedByteCount = 0
                return nil
            }
            buffer.append(chunk)
        }
    }
}
