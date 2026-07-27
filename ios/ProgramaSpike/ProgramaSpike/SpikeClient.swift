import Foundation
import IrohLib
import Observation

/// Same probe/echo exchange as `tools/mobile-spike`'s `dial` subcommand,
/// driven from a pasted pairing payload instead of `CommandLine.arguments`.
@Observable
final class SpikeClient {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case succeeded
        case failed
    }

    private(set) var state: ConnectionState = .idle
    private(set) var roundTripLatencyDescription: String?
    private(set) var observedPathDescription: String?
    private(set) var errorText: String?

    private static let alpn = Data("programa/spike/1".utf8)
    private static let probeMessage = Data("programa-spike-probe".utf8)

    @MainActor
    func connect(pairingPayload: String) async {
        state = .connecting
        roundTripLatencyDescription = nil
        observedPathDescription = nil
        errorText = nil

        do {
            let result = try await Self.performProbe(
                pairingPayload: pairingPayload.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            roundTripLatencyDescription = result.latencyDescription
            observedPathDescription = result.observedPath.description
            state = .succeeded
        } catch {
            errorText = "\(error)"
            state = .failed
        }
    }

    private struct ProbeResult {
        let latencyDescription: String
        let observedPath: ObservedPath
    }

    private static func performProbe(pairingPayload: String) async throws -> ProbeResult {
        let ticket: EndpointTicket
        do {
            ticket = try EndpointTicket.fromString(str: pairingPayload)
        } catch {
            throw SpikeError(message: "could not parse pairing payload: \(error)")
        }
        let targetAddress = ticket.endpointAddr()

        let secretKey = try SecretKeyStore.loadOrCreate()
        let options = EndpointOptions(
            // presetN0() is iroh's production preset (relays + discovery).
            // presetMinimal() is documented as "no external dependencies; good
            // for tests / offline" — with it, a connection never upgrades off
            // the relay (measured: 385ms relayed vs 1.1ms peer-to-peer for the
            // same exchange). cmux's factory uses minimal because their hosted
            // broker supplies discovery; we have no broker.
            preset: presetN0(),
            bindAddr: "0.0.0.0:0",
            secretKey: secretKey,
            alpns: [alpn],
            relayMode: RelayMode.defaultMode(),
            portMappingEnabled: true,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        )
        let endpoint = try await Endpoint.bind(options: options)

        let connection = try await endpoint.connect(addr: targetAddress, alpn: alpn)
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

        try? connection.close(errorCode: 0, reason: Data("spike_complete".utf8))
        try? await endpoint.close()

        return ProbeResult(
            latencyDescription: elapsed.formatted(),
            observedPath: observedPath
        )
    }
}
