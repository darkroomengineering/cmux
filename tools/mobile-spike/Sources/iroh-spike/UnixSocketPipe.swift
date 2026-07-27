import Darwin
import Foundation

/// A dedicated `AF_UNIX` `SOCK_STREAM` connection to Programa's control
/// socket, one per bridged iroh connection (never shared/pooled — Programa
/// pushes unsolicited subscription frames on this same connection for the
/// connection's whole lifetime).
///
/// The underlying `read`/`write` syscalls block, so callers must not invoke
/// them directly from Swift Concurrency's cooperative thread pool. Use
/// `nextLine()`/`send(_:)`, which hop onto a background dispatch queue via
/// a checked continuation — the same "blocking call off the cooperative
/// pool" pattern every async-over-sync bridge needs.
///
/// Each instance is driven by exactly one reader task and one writer task
/// (the two halves of the relay pump); `readLine`/`writeAll` are not safe to
/// call concurrently with themselves, only with each other.
final class UnixSocketPipe: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw SpikeError(message: "could not create unix socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(socketFD)
            throw SpikeError(message: "Programa socket path too long (\(pathBytes.count) bytes, max \(capacity - 1)): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPointer in
            let base = rawPointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (index, byte) in pathBytes.enumerated() {
                base[index] = byte
            }
            base[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, addrLen)
            }
        }
        guard connectResult == 0 else {
            let failure = errno
            Darwin.close(socketFD)
            throw SpikeError(
                message: "could not connect to Programa socket at \(path): \(String(cString: strerror(failure)))"
            )
        }

        fd = socketFD
    }

    func close() {
        Darwin.close(fd)
    }

    /// Reads the next newline-delimited line. Returns `nil` at end of
    /// stream. Blocking — call via `nextLine()`, not directly, from async
    /// contexts.
    private func readLineBlocking() throws -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newlineIndex])
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let bytesRead = chunk.withUnsafeMutableBytes { rawPointer in
                Darwin.read(fd, rawPointer.baseAddress, rawPointer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw SpikeError(message: "read from Programa socket failed: \(String(cString: strerror(errno)))")
            }
            if bytesRead == 0 {
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer.removeAll()
                    return remaining
                }
                return nil
            }
            buffer.append(contentsOf: chunk[0 ..< bytesRead])
        }
    }

    /// Writes `data` in full. Blocking — call via `send(_:)`, not directly,
    /// from async contexts.
    private func writeAllBlocking(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(fd, base + offset, data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SpikeError(message: "write to Programa socket failed: \(String(cString: strerror(errno)))")
                }
                if written == 0 {
                    throw SpikeError(message: "Programa socket closed during write")
                }
                offset += written
            }
        }
    }

    func nextLine() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.readLineBlocking())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.writeAllBlocking(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
