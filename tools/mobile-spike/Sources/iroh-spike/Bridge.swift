import Foundation
import IrohLib

/// Default location of Programa's control socket if `$PROGRAMA_SOCKET_PATH`
/// is not set — matches the path Programa itself binds to.
private func defaultProgramaSocketPath() -> String {
    NSHomeDirectory() + "/Library/Application Support/programa/programa.sock"
}

private let pairingWindowDuration: Duration = .seconds(300)

struct BridgeOptions {
    let pair: Bool
}

func runBridge(options: BridgeOptions) async throws {
    let socketPath = ProcessInfo.processInfo.environment["PROGRAMA_SOCKET_PATH"]
        ?? defaultProgramaSocketPath()
    guard FileManager.default.fileExists(atPath: socketPath) else {
        throw SpikeError(
            message: "Programa socket not found at \(socketPath). Is Programa running?"
        )
    }

    let store = try TrustedDeviceStore.load()
    let endpoint = try await bindEndpoint()

    print("Binding endpoint and waiting for relay connectivity...")
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await endpoint.online() }
        group.addTask { try? await Task.sleep(for: .seconds(10)) }
        await group.next()
        group.cancelAll()
    }

    let address = endpoint.addr()
    let ticket = try EndpointTicket.fromAddr(addr: address)

    var pairingWindow: PairingWindow?
    if options.pair {
        let tokenBytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        let tokenString = Base64URL.encode(tokenBytes)
        pairingWindow = PairingWindow(token: Data(tokenString.utf8), duration: pairingWindowDuration)

        print("=======================================================")
        print("Pairing payload (paste into the dialing device):")
        print(ticket.description)
        print("Pairing token (single use, 5 minute window):")
        print(tokenString)
        print("=======================================================")
    } else {
        print("=======================================================")
        print("No pairing window open (run with --pair to admit a new device).")
        print("Only already-trusted devices may connect.")
        print("=======================================================")
    }

    print("Local node id: \(endpoint.id())")
    print("Relay URL: \(address.relayUrl() ?? "none")")
    print("Bridging to Programa socket at \(socketPath)")
    print("Listening for connections. Press Ctrl-C to stop.")

    while let incoming = await endpoint.acceptNext() {
        Task {
            await handleBridgeConnection(
                incoming,
                store: store,
                pairingWindow: pairingWindow,
                socketPath: socketPath
            )
        }
    }
    print("Endpoint closed.")
}

private func handleBridgeConnection(
    _ incoming: Incoming,
    store: TrustedDeviceStore,
    pairingWindow: PairingWindow?,
    socketPath: String
) async {
    do {
        let accepting = try await incoming.accept()
        let remoteALPN = try await accepting.alpn()
        guard remoteALPN == spikeALPN else {
            FileHandle.standardError.write(Data("bridge: rejected connection: unexpected ALPN\n".utf8))
            return
        }

        let connection = try await accepting.connect()
        try connection.setMaxConcurrentBiStreams(count: 1)
        try connection.setMaxConcurrentUniStreams(count: 0)
        try await connection.authorizeNatTraversal()

        let remoteIdentity = connection.remoteId()
        let idString = remoteIdentity.description
        print("-------------------------------------------------------")
        print("Bridge: connection from \(idString)")

        let stream = try await connection.acceptBi()
        let reader = StreamLineReader(stream: stream.recv())
        let writer = FrameWriter(stream: stream.send())

        let admitted = try await admit(
            idString: idString,
            reader: reader,
            writer: writer,
            store: store,
            pairingWindow: pairingWindow
        )
        guard admitted else {
            _ = await connection.closed()
            print("-------------------------------------------------------")
            return
        }

        print("Bridge: relaying \(idString) <-> \(socketPath)")
        let socket = try UnixSocketPipe(path: socketPath)
        defer { socket.close() }

        await relay(reader: reader, writer: writer, socket: socket, idString: idString)

        _ = await connection.closed()
        print("Bridge: connection from \(idString) closed")
        print("-------------------------------------------------------")
    } catch {
        FileHandle.standardError.write(Data("bridge: connection handling error: \(error)\n".utf8))
    }
}

/// Implements the admission order from the M1 plan: trusted devices are
/// admitted outright; otherwise, if a pairing window is open and unexpired,
/// the first line is read and checked as a `{"pair":"<token>"}` frame;
/// otherwise the connection is rejected as not paired. Returns `true` if the
/// connection should proceed to relay.
private func admit(
    idString: String,
    reader: StreamLineReader,
    writer: FrameWriter,
    store: TrustedDeviceStore,
    pairingWindow: PairingWindow?
) async throws -> Bool {
    if await store.isTrusted(idString) {
        print("Bridge: admitted trusted device \(idString)")
        return true
    }

    if let pairingWindow, await pairingWindow.isOpen {
        guard let firstLine = try await reader.nextLine() else {
            print("Bridge: rejected \(idString): connection closed before sending a pairing frame")
            return false
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
            let presentedToken = object["pair"] as? String
        else {
            try? await writer.writeLine(errorFrame(id: nil, code: "pairing_failed"))
            print("Bridge: rejected \(idString): malformed pairing frame")
            return false
        }

        let matched = await pairingWindow.attemptConsume(Data(presentedToken.utf8))
        if matched {
            // The phone may send a human-readable name alongside the token so
            // the device list reads "Franco's iPhone" rather than 64 hex
            // characters. Optional on the wire — older clients and the
            // dial-rpc test helper send only `pair`. Trim and bound it: this
            // string comes from a remote peer and gets persisted and displayed.
            let label = (object["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(64)
                .description
            let resolvedLabel = (label?.isEmpty == false) ? label! : "paired-device"
            try await store.add(endpointId: idString, label: resolvedLabel)
            try await writer.writeLine(Data(#"{"ok":true,"paired":true}"#.utf8))
            print("Bridge: paired new device \(idString) as \"\(resolvedLabel)\"")
            return true
        } else {
            try? await writer.writeLine(errorFrame(id: nil, code: "pairing_failed"))
            print("Bridge: rejected \(idString): pairing token mismatch")
            return false
        }
    }

    try? await writer.writeLine(errorFrame(id: nil, code: "not_paired"))
    print("Bridge: rejected \(idString): not paired")
    return false
}

/// Pumps both directions of the relay for an admitted connection: phone
/// lines are allow-list checked before being forwarded to Programa's socket;
/// Programa's replies and unsolicited subscription pushes are forwarded to
/// the phone unfiltered. Ends (and cancels the other direction) as soon as
/// either side closes.
private func relay(
    reader: StreamLineReader,
    writer: FrameWriter,
    socket: UnixSocketPipe,
    idString: String
) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            do {
                while let line = try await reader.nextLine() {
                    await forwardPhoneLine(line, socket: socket, writer: writer, idString: idString)
                }
            } catch {
                FileHandle.standardError.write(Data("bridge: phone read error: \(error)\n".utf8))
            }
        }
        group.addTask {
            do {
                while let line = try await socket.nextLine() {
                    try await writer.writeLine(line)
                }
            } catch {
                FileHandle.standardError.write(Data("bridge: Programa socket read error: \(error)\n".utf8))
            }
        }
        await group.next()
        group.cancelAll()
    }
}

private func forwardPhoneLine(
    _ line: Data,
    socket: UnixSocketPipe,
    writer: FrameWriter,
    idString: String
) async {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        try? await writer.writeLine(errorFrame(id: nil, code: "invalid_json"))
        print("Bridge: \(idString): rejected unparseable line (invalid_json)")
        return
    }
    let requestId = object["id"]
    guard let method = object["method"] as? String else {
        try? await writer.writeLine(errorFrame(id: requestId, code: "invalid_json"))
        print("Bridge: \(idString): rejected line without a method (invalid_json)")
        return
    }
    guard MethodAllowList.isAllowed(method) else {
        try? await writer.writeLine(errorFrame(
            id: requestId,
            code: "forbidden",
            message: "method not permitted over mobile bridge"
        ))
        print("Bridge: \(idString): forbidden method \"\(method)\" rejected, not forwarded")
        return
    }
    do {
        try await socket.send(line + Data("\n".utf8))
        print("Bridge: \(idString): forwarded \"\(method)\"")
    } catch {
        FileHandle.standardError.write(Data("bridge: forwarding to Programa failed: \(error)\n".utf8))
    }
}

private func errorFrame(id: Any?, code: String, message: String? = nil) -> Data {
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
