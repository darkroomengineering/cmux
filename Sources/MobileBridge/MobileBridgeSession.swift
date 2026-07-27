import Darwin
import Foundation

/// One phone connection's admission and relay to Programa's terminal
/// control dispatch. Ported from
/// `tools/mobile-spike/Sources/iroh-spike/Bridge.swift`'s `admit`/`relay`/
/// `forwardPhoneLine`, with one substitution: instead of opening an
/// `AF_UNIX` connection to Programa's control socket (`UnixSocketPipe`),
/// each admitted phone gets a `socketpair` wired directly in-process to
/// `TerminalController.handleClient` (see `MobileBridgeLocalPipe` below).
///
/// Note: `TerminalController.handleClient`'s read loop only runs while
/// `TerminalController` considers itself started (i.e. Socket Control Mode
/// is not Off, which is the default). The mobile bridge does not start or
/// otherwise touch the real Unix socket listener -- see
/// `MobileBridgeListener.start(tabManager:)`, which only assigns
/// `TerminalController.shared.tabManager`. In the out-of-the-box
/// configuration (Socket Control Mode defaults to `cmuxOnly`) this is
/// already satisfied; a Mac with Socket Control Mode explicitly set to Off
/// will admit and relay-connect phones, but `handleClient` will return
/// immediately without processing any commands.
enum MobileBridgeSession {
    /// Admission order: trusted devices are admitted outright; otherwise,
    /// if a pairing window is open and unexpired, the first line is read
    /// and checked as a `{"pair":"<token>"}` frame; otherwise the
    /// connection is rejected as not paired. Returns `true` if the
    /// connection should proceed to relay.
    static func admit(
        idString: String,
        reader: MobileBridgeStreamLineReader,
        writer: MobileBridgeFrameWriter,
        pairingWindow: MobileBridgePairingWindow?
    ) async throws -> Bool {
        if await MobileBridgeTrustedDeviceStore.shared.isTrusted(idString) {
            return true
        }

        if let pairingWindow, await pairingWindow.isOpen {
            guard let firstLine = try await reader.nextLine() else {
                return false
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
                let presentedToken = object["pair"] as? String
            else {
                try? await writer.writeLine(errorFrame(id: nil, code: "pairing_failed"))
                return false
            }

            let matched = await pairingWindow.attemptConsume(Data(presentedToken.utf8))
            if matched {
                // The phone may send a human-readable name alongside the
                // token so the device list reads "Franco's iPhone" rather
                // than 64 hex characters. Optional on the wire. Trim and
                // bound it: this string comes from a remote peer and gets
                // persisted and displayed.
                let label = (object["label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(64)
                    .description
                let resolvedLabel = (label?.isEmpty == false) ? label! : "paired-device"
                await MobileBridgeTrustedDeviceStore.shared.add(endpointId: idString, label: resolvedLabel)
                try await writer.writeLine(Data(#"{"ok":true,"paired":true}"#.utf8))
                return true
            } else {
                try? await writer.writeLine(errorFrame(id: nil, code: "pairing_failed"))
                return false
            }
        }

        try? await writer.writeLine(errorFrame(id: nil, code: "not_paired"))
        return false
    }

    /// Creates a connected `socketpair`, hands one end to
    /// `TerminalController.handleClient` on a dedicated thread (the same
    /// per-connection thread model the real Unix socket listener uses), and
    /// pumps bytes on the other end for this connection's lifetime.
    /// Phone-originated lines are checked against
    /// `MobileBridgeMethodAllowList` before being forwarded; Programa's
    /// replies and pushed subscription events are forwarded to the phone
    /// unfiltered. Ends (and cancels the other direction) as soon as either
    /// side closes.
    static func relay(
        reader: MobileBridgeStreamLineReader,
        writer: MobileBridgeFrameWriter,
        idString: String
    ) async {
        // Greet every admitted phone, pairing and trusted reconnect alike, so a
        // renamed Mac corrects itself on the next connect instead of staying
        // stale until re-pair. Shaped as an event frame ("event" key, no "id")
        // so it rides the client's existing demux for unsolicited frames.
        let hello: [String: Any] = [
            "event": "bridge_hello",
            "mac_name": mobileBridgeLocalMacName(),
        ]
        if let helloData = try? JSONSerialization.data(withJSONObject: hello) {
            try? await writer.writeLine(helloData)
        }

        guard let pipe = MobileBridgeLocalPipe.make() else {
            NSLog("MobileBridge: failed to create socketpair for %@", idString)
            return
        }
        defer { pipe.closeLocalEnd() }

        // `handleClient` owns and closes `remoteFD` itself (its own
        // `defer { close(socket) }`); this relay never touches it again
        // after handing it off.
        let remoteFD = pipe.remoteFD
        Thread.detachNewThread {
            TerminalController.shared.handleClient(remoteFD, peerPid: getpid(), ignoresListenerState: true)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while let line = try await reader.nextLine() {
                        await forwardPhoneLine(line, pipe: pipe, writer: writer, idString: idString)
                    }
                } catch {
                    NSLog("MobileBridge: phone read error for %@: %@", idString, "\(error)")
                }
                // Signal the local side's blocking read to unblock (EOF)
                // once the phone has disconnected, so `handleClient`'s
                // read loop can also observe the peer going away.
                pipe.closeLocalEnd()
            }
            group.addTask {
                do {
                    while let line = try await pipe.nextLine() {
                        try await writer.writeLine(line)
                    }
                } catch {
                    NSLog("MobileBridge: local read error for %@: %@", idString, "\(error)")
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private static func forwardPhoneLine(
        _ line: Data,
        pipe: MobileBridgeLocalPipe,
        writer: MobileBridgeFrameWriter,
        idString: String
    ) async {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            try? await writer.writeLine(errorFrame(id: nil, code: "invalid_json"))
            return
        }
        let requestId = object["id"]
        guard let method = object["method"] as? String else {
            try? await writer.writeLine(errorFrame(id: requestId, code: "invalid_json"))
            return
        }
        guard MobileBridgeMethodAllowList.isAllowed(method) else {
            try? await writer.writeLine(errorFrame(
                id: requestId,
                code: "forbidden",
                message: "method not permitted over mobile bridge"
            ))
            return
        }
        do {
            try await pipe.send(line + Data("\n".utf8))
        } catch {
            NSLog("MobileBridge: forwarding to terminal control failed for %@: %@", idString, "\(error)")
        }
    }

    private static func errorFrame(id: Any?, code: String, message: String? = nil) -> Data {
        var errorObject: [String: Any] = ["code": code]
        if let message { errorObject["message"] = message }
        var frame: [String: Any] = ["ok": false, "error": errorObject]
        if let id, !(id is NSNull) {
            frame["id"] = id
        }
        if let data = try? JSONSerialization.data(withJSONObject: frame) {
            return data
        }
        return Data(#"{"ok":false,"error":{"code":"\#(code)"}}"#.utf8)
    }
}

/// A connected `AF_UNIX`/`SOCK_STREAM` pair created via `socketpair(2)` --
/// no filesystem path, no listener, no auth boundary of its own (the
/// phone's authorization already happened upstream: the iroh admission
/// handshake plus `MobileBridgeMethodAllowList`). One end (`remoteFD`) is
/// handed to `TerminalController.handleClient`; the other (`localFD`,
/// private) is driven by this relay's reader/writer tasks.
///
/// Mirrors `tools/mobile-spike/Sources/iroh-spike/UnixSocketPipe.swift`'s
/// blocking read/write bridged onto a background dispatch queue, since
/// `handleClient` and this pipe's local end both perform blocking
/// `read`/`write` syscalls that must never run on Swift Concurrency's
/// cooperative thread pool.
final class MobileBridgeLocalPipe: @unchecked Sendable {
    let remoteFD: Int32
    private let localFD: Int32
    private var buffer = Data()
    private let closeLock = NSLock()
    private var localClosed = false

    private init(localFD: Int32, remoteFD: Int32) {
        self.localFD = localFD
        self.remoteFD = remoteFD
    }

    static func make() -> MobileBridgeLocalPipe? {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else { return nil }
        return MobileBridgeLocalPipe(localFD: fds[0], remoteFD: fds[1])
    }

    /// Closes this relay's own end of the pair. `TerminalController.handleClient`
    /// closes `remoteFD` itself via its own `defer`, so this must never
    /// touch `remoteFD`.
    func closeLocalEnd() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !localClosed else { return }
        localClosed = true
        Darwin.close(localFD)
    }

    private func readLineBlocking() throws -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newlineIndex])
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let bytesRead = chunk.withUnsafeMutableBytes { rawPointer in
                Darwin.read(localFD, rawPointer.baseAddress, rawPointer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw MobileBridgePipeError(message: "read from local pipe failed: \(String(cString: strerror(errno)))")
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

    private func writeAllBlocking(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(localFD, base + offset, data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MobileBridgePipeError(message: "write to local pipe failed: \(String(cString: strerror(errno)))")
                }
                if written == 0 {
                    throw MobileBridgePipeError(message: "local pipe closed during write")
                }
                offset += written
            }
        }
    }

    /// Reads the next newline-delimited line. Returns `nil` at end of
    /// stream. Blocking -- always awaited, never called directly, from
    /// async contexts.
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

    /// Writes `data` in full. Blocking -- always awaited, never called
    /// directly, from async contexts.
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

struct MobileBridgePipeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}


/// The Mac's user-facing computer name ("Franco's MacBook Pro") -- what System
/// Settings shows and what a person recognises on their phone. Falls back to
/// the network hostname, then a generic label.
func mobileBridgeLocalMacName() -> String {
    if let localized = Host.current().localizedName, !localized.isEmpty {
        return localized
    }
    let hostName = ProcessInfo.processInfo.hostName
    return hostName.isEmpty ? "Mac" : hostName
}
