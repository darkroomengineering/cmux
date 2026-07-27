import Foundation
import IrohLib

/// Programa-specific ALPN for this spike. Deliberately not shared with any
/// other iroh ALPN (including cmux's own `cmux/direct-transport-gate/1`).
let spikeALPN = Data("programa/spike/1".utf8)

/// The exact bytes `dial` sends and expects to see echoed back verbatim.
let probeMessage = Data("programa-spike-probe".utf8)

struct SpikeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@main
struct IrohSpike {
    static func main() async {
        // Swift fully buffers stdout when it is not a TTY, so piping or
        // redirecting this tool would otherwise show nothing until exit —
        // useless for a listener that runs until Ctrl-C and prints the
        // pairing payload up front. Line-buffer so captured runs stream.
        setvbuf(stdout, nil, _IOLBF, 0)

        // Writing to a socket whose peer has hung up raises SIGPIPE, whose
        // default disposition kills the process (observed: bridge died with
        // exit 141 the moment a client disconnected). A relay has two sockets
        // per session and peers disconnect constantly, so this must be ignored
        // and surfaced as an EPIPE write error instead.
        signal(SIGPIPE, SIG_IGN)

        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var arguments = CommandLine.arguments
        arguments.removeFirst()
        guard let command = arguments.first else {
            printUsage()
            exit(1)
        }
        switch command {
        case "listen":
            try await runListen()
        case "dial":
            guard arguments.count >= 2 else {
                printUsage()
                exit(1)
            }
            try await runDial(payload: arguments[1])
        case "bridge":
            let pair = arguments.dropFirst().contains("--pair")
            try await runBridge(options: BridgeOptions(pair: pair))
        case "dial-rpc":
            let rest = Array(arguments.dropFirst())
            switch rest.count {
            case 2:
                try await runDialRPC(ticket: rest[0], token: nil, requestJSON: rest[1])
            case 3:
                try await runDialRPC(ticket: rest[0], token: rest[1], requestJSON: rest[2])
            default:
                printUsage()
                exit(1)
            }
        default:
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage:
          iroh-spike listen
          iroh-spike dial <pairing-payload>
          iroh-spike bridge [--pair]
          iroh-spike dial-rpc <pairing-payload> [<pairing-token>] <json-request>

        Env:
          PROGRAMA_SPIKE_HOME   Override the identity storage directory
                                 (default: ~/.programa/mobile-spike). Set this
                                 to distinct paths when running listen/dial/
                                 bridge/dial-rpc as distinct identities on one
                                 machine.
          PROGRAMA_SOCKET_PATH  Programa control socket to bridge to
                                 (default: ~/Library/Application Support/
                                 programa/programa.sock).
        """)
    }
}

/// Bypasses `CmxIrohLibEndpointFactory` entirely: that factory's relay
/// selection is gated by cmux's hosted broker (`CmxIrohRelayConfiguration`
/// requires an authenticated JWT), and its `directOnly` verification mode
/// forces `RelayMode.disabled()`, which can never traverse NAT. This spike
/// needs relays reachable across networks, so it constructs `EndpointOptions`
/// directly against the public IrohLib API, mirroring every field the
/// factory sets (see `CmxIrohLibEndpointFactory.endpointOptions`) except:
///   - `relayMode`: `RelayMode.defaultMode()` (iroh's free n0 relays) instead
///     of `.disabled()` / a broker-gated custom map.
///   - `bindAddr`: `0.0.0.0:0` instead of loopback, so real interfaces bind.
///   - `secretKey`: a persisted per-device key instead of a fixed test byte,
///     so identity survives relaunch (see `SecretKeyStore`).
///   - `preset`: `presetN0()` (iroh's production preset — relays *and*
///     discovery) instead of `presetMinimal()`, which iroh documents as "no
///     external dependencies; good for tests / offline". The factory uses the
///     minimal preset because cmux supplies its own discovery via their hosted
///     broker. We have no broker, and with the minimal preset a connection
///     never upgrades off the relay — measured: two peers on the *same machine*
///     stayed relayed for a full 10s window.
///   - `portMappingEnabled`: `true` so UPnP/NAT-PMP can assist traversal.
func makeEndpointOptions(secretKey: Data) -> EndpointOptions {
    EndpointOptions(
        preset: presetN0(),
        bindAddr: "0.0.0.0:0",
        secretKey: secretKey,
        alpns: [spikeALPN],
        relayMode: RelayMode.defaultMode(),
        portMappingEnabled: true,
        deferNatTraversalUntilAuthorized: true,
        initialMaxConcurrentBiStreams: 0,
        initialMaxConcurrentUniStreams: 0
    )
}

func bindEndpoint() async throws -> Endpoint {
    let secretKey = try SecretKeyStore.loadOrCreate()
    let options = makeEndpointOptions(secretKey: secretKey)
    return try await Endpoint.bind(options: options)
}

// MARK: - listen

func runListen() async throws {
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

    print("=======================================================")
    print("Pairing payload (paste into the dialing device):")
    print(ticket.description)
    print("=======================================================")
    print("Local node id: \(endpoint.id())")
    print("Relay URL: \(address.relayUrl() ?? "none")")
    print("Direct addresses: \(address.directAddresses())")
    print("Listening for connections. Press Ctrl-C to stop.")

    while let incoming = await endpoint.acceptNext() {
        Task {
            await handleIncoming(incoming)
        }
    }
    print("Endpoint closed.")
}

func handleIncoming(_ incoming: Incoming) async {
    do {
        let accepting = try await incoming.accept()
        let remoteALPN = try await accepting.alpn()
        guard remoteALPN == spikeALPN else {
            FileHandle.standardError.write(
                Data("rejected connection: unexpected ALPN\n".utf8)
            )
            return
        }

        let connection = try await accepting.connect()
        try connection.setMaxConcurrentBiStreams(count: 1)
        try connection.setMaxConcurrentUniStreams(count: 0)
        try await connection.authorizeNatTraversal()

        let remoteIdentity = connection.remoteId()
        print("-------------------------------------------------------")
        print("Accepted connection from: \(remoteIdentity)")

        let stream = try await connection.acceptBi()
        let receiveStream = stream.recv()
        let sendStream = stream.send()

        let payload = try await receiveStream.readToEnd(sizeLimit: 4_096)
        try await sendStream.writeAll(buf: payload)
        try await sendStream.finish()

        let observedPath = await PathClassifier.waitForSelectedPath(
            connection: connection,
            timeout: .seconds(10)
        )

        print("Echoed \(payload.count) bytes back to \(remoteIdentity)")
        print("Observed path: \(observedPath)")
        print("-------------------------------------------------------")

        // `finish()` only signals FIN — it does not wait for the peer to drain.
        // Returning here drops the connection handle, which closes the QUIC
        // connection with ApplicationClosed(0) and makes the dialer's read fail
        // with ConnectionLost even though every byte was already echoed. Hold
        // the connection open until the dialer closes it. The accept loop
        // spawns each handler in its own Task, so this blocks nothing.
        _ = await connection.closed()
    } catch {
        FileHandle.standardError.write(Data("connection handling error: \(error)\n".utf8))
    }
}

// MARK: - dial

func runDial(payload: String) async throws {
    let ticket: EndpointTicket
    do {
        ticket = try EndpointTicket.fromString(str: payload)
    } catch {
        throw SpikeError(message: "could not parse pairing payload: \(error)")
    }
    let targetAddress = ticket.endpointAddr()

    let endpoint = try await bindEndpoint()

    print("Dialing \(targetAddress.id())...")
    let connection = try await endpoint.connect(addr: targetAddress, alpn: spikeALPN)
    try connection.setMaxConcurrentBiStreams(count: 1)
    try connection.setMaxConcurrentUniStreams(count: 0)
    try await connection.authorizeNatTraversal()

    let stream = try await connection.openBi()
    let sendStream = stream.send()
    let receiveStream = stream.recv()

    let start = ContinuousClock.now
    try await sendStream.writeAll(buf: probeMessage)
    try await sendStream.finish()
    let echoed = try await receiveStream.readToEnd(sizeLimit: 4_096)
    let elapsed = ContinuousClock.now - start

    guard echoed == probeMessage else {
        throw SpikeError(
            message: "echo mismatch: sent \(probeMessage.count) bytes, got back \(echoed.count) bytes"
        )
    }

    let observedPath = await PathClassifier.waitForSelectedPath(
        connection: connection,
        timeout: .seconds(10)
    )

    print("=======================================================")
    print("Probe succeeded: echo matched exactly.")
    print("Remote node id: \(connection.remoteId())")
    print("Round-trip latency: \(elapsed)")
    print("Observed path: \(observedPath)")
    print("=======================================================")

    try? connection.close(errorCode: 0, reason: Data("spike_complete".utf8))
    try? await endpoint.close()
}
