import Foundation
import IrohLib

/// Long-lived connection actor for the Programa mobile bridge wire protocol:
/// newline-delimited JSON-RPC plus unsolicited event frames, all over one
/// iroh bidirectional stream. Supersedes the earlier one-shot probe
/// (`SpikeClient.performProbe`): this owns the iroh `Connection`/stream for
/// as long as the app is connected, runs a continuous read loop that
/// demultiplexes response lines (matched by `id`) from event frames
/// (`"event"` key, no `id`), and exposes typed async request methods plus
/// an `AsyncStream` of decoded events.
///
/// Concurrency note: every iroh type (`Endpoint`, `Connection`, `SendStream`,
/// `RecvStream`) lives entirely in this actor's isolated storage and is
/// never handed across an isolation boundary. Background loops are spawned
/// as `Task { [weak self] in await self?.someActorMethod() }`, which re-read
/// actor-isolated state fresh inside that method rather than capturing a
/// local non-Sendable value directly in the closure. That is the fix for
/// the class of error the original spike's `performProbe` hit (a
/// non-Sendable `self` crossing an isolation boundary from a `@MainActor`
/// call site) — solved here with actor isolation instead of
/// `@unchecked Sendable`.
actor BridgeConnection {
    enum Phase: Sendable {
        case disconnected
        case connecting
        case pairing
        case connected
        case failed(String)
    }

    // Matches the ALPN the bridge (tools/mobile-spike/Sources/iroh-spike/
    // Bridge.swift, `spikeALPN`) currently listens on. Duplicated rather
    // than imported -- separate build graphs, same convention already used
    // by this target's `SpikeError`/`PathClassifier` duplication.
    private static let alpn = Data("programa/spike/1".utf8)
    private static let pathPollInterval: Duration = .seconds(3)

    private(set) var phase: Phase = .disconnected
    private(set) var observedPath: ObservedPath = .unavailable

    nonisolated let phaseStream: AsyncStream<Phase>
    nonisolated let pathStream: AsyncStream<ObservedPath>
    nonisolated let events: AsyncStream<BridgeEvent>

    private let phaseContinuation: AsyncStream<Phase>.Continuation
    private let pathContinuation: AsyncStream<ObservedPath>.Continuation
    private let eventContinuation: AsyncStream<BridgeEvent>.Continuation

    private var endpoint: Endpoint?
    private var connection: Connection?
    private var sendStream: SendStream?
    private var recvStream: RecvStream?
    private var readBuffer = Data()

    private var readLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pathLoopTask: Task<Void, Never>?

    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    init() {
        var phaseContinuation: AsyncStream<Phase>.Continuation!
        phaseStream = AsyncStream { phaseContinuation = $0 }
        self.phaseContinuation = phaseContinuation

        var pathContinuation: AsyncStream<ObservedPath>.Continuation!
        pathStream = AsyncStream { pathContinuation = $0 }
        self.pathContinuation = pathContinuation

        var eventContinuation: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream { eventContinuation = $0 }
        self.eventContinuation = eventContinuation
    }

    // MARK: - Connection lifecycle

    /// Connects (or reconnects) to a bridge. `pairingToken` is only needed
    /// the first time a device pairs — pass `nil` on later connections and
    /// the phone's already-allowlisted EndpointID skips the pairing frame
    /// entirely, per the wire contract.
    func connect(pairingPayload: String, pairingToken: String?, deviceLabel: String? = nil) async throws {
        await teardownConnection()
        setPhase(.connecting)

        let ticket: EndpointTicket
        do {
            ticket = try EndpointTicket.fromString(str: pairingPayload)
        } catch {
            setPhase(.failed("invalid pairing ticket"))
            throw BridgeError.invalidTicket
        }
        let targetAddress = ticket.endpointAddr()

        let secretKey: Data
        do {
            secretKey = try SecretKeyStore.loadOrCreate()
        } catch {
            setPhase(.failed("could not load device identity"))
            throw error
        }

        let options = EndpointOptions(
            preset: presetN0(),
            bindAddr: "0.0.0.0:0",
            secretKey: secretKey,
            alpns: [Self.alpn],
            relayMode: RelayMode.defaultMode(),
            portMappingEnabled: true,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        )

        var boundEndpoint: Endpoint?
        var establishedConnection: Connection?
        do {
            let newEndpoint = try await Endpoint.bind(options: options)
            boundEndpoint = newEndpoint
            let newConnection = try await newEndpoint.connect(addr: targetAddress, alpn: Self.alpn)
            establishedConnection = newConnection
            try newConnection.setMaxConcurrentBiStreams(count: 1)
            try newConnection.setMaxConcurrentUniStreams(count: 0)
            try await newConnection.authorizeNatTraversal()
        } catch {
            if let establishedConnection {
                try? establishedConnection.close(errorCode: 0, reason: Data())
            }
            if let boundEndpoint {
                try? await boundEndpoint.close()
            }
            setPhase(.failed("\(error)"))
            throw error
        }

        guard let newEndpoint = boundEndpoint, let newConnection = establishedConnection else {
            setPhase(.failed("connection setup failed"))
            throw BridgeError.disconnected
        }

        do {
            let stream = try await newConnection.openBi()
            endpoint = newEndpoint
            connection = newConnection
            sendStream = stream.send()
            recvStream = stream.recv()
            readBuffer.removeAll()
        } catch {
            try? newConnection.close(errorCode: 0, reason: Data())
            try? await newEndpoint.close()
            setPhase(.failed("\(error)"))
            throw error
        }

        if let pairingToken, !pairingToken.isEmpty {
            setPhase(.pairing)
            do {
                let pairPayload = try JSONEncoder().encode(PairRequest(pair: pairingToken, label: deviceLabel))
                try await writeLine(pairPayload)
                guard let replyLine = try await nextBufferedLine() else {
                    throw BridgeError.disconnected
                }
                let reply = try JSONDecoder().decode(PairResponse.self, from: replyLine)
                guard reply.ok else {
                    throw BridgeError.rpc(code: reply.error?.code ?? "pairing_failed", message: reply.error?.message)
                }
            } catch {
                await teardownConnection()
                setPhase(.failed("\(error)"))
                throw error
            }
        }

        let initialPath = await PathClassifier.waitForSelectedPath(connection: newConnection, timeout: .seconds(5))
        observedPath = initialPath
        pathContinuation.yield(initialPath)

        startReadLoop()
        startPathLoop()

        // Do NOT report `.connected` merely because the QUIC stream opened.
        // On the already-trusted path no pairing frame is sent, so an
        // unrecognised device would sit here looking "connected" while the
        // bridge had actually answered `not_paired` -- the failure only
        // surfaced later, on the first real request. That false positive cost
        // real debugging time.
        //
        // A round-trip `system.ping` proves the whole chain in one call: the
        // stream works, the bridge admitted this device, the relay to
        // Programa's socket is up, and Programa answered. Only then is
        // "connected" true in any sense the user cares about.
        do {
            _ = try await withRequestTimeout(seconds: 15) {
                try await self.performRequestUnchecked(method: "system.ping", params: [:])
            }
        } catch {
            await teardownConnection()
            setPhase(.failed("not admitted by the Mac: \(error)"))
            throw error
        }

        setPhase(.connected)
        startHeartbeat()
    }

    func disconnect() async {
        await teardownConnection()
        setPhase(.disconnected)
    }

    // MARK: - Typed requests
    // Only the methods this app's three screens actually use. Every method
    // name below is in the wire contract's permitted list; the bridge
    // rejects anything else with `forbidden`.

    func listWorkspaces() async throws -> [WireWorkspace] {
        let data = try await performRequest(method: "workspace.list", params: [:])
        let result = try decodeEnvelope(data, as: WireWorkspaceListResult.self)
        return result.workspaces ?? []
    }

    func listSurfaces(workspaceID: String) async throws -> [WireSurface] {
        let data = try await performRequest(
            method: "surface.list",
            params: ["workspace_id": .string(workspaceID)]
        )
        let result = try decodeEnvelope(data, as: WireSurfaceListResult.self)
        return result.surfaces ?? []
    }

    func subscribe(classes: [String]) async throws {
        let data = try await performRequest(method: "subscribe", params: ["classes": .stringArray(classes)])
        _ = try decodeEnvelope(data, as: WireSubscribeResult.self)
    }

    @discardableResult
    func sendPrompt(surfaceID: String, text: String) async throws -> WireAgentPromptResult {
        let data = try await performRequest(
            method: "agent.prompt",
            params: ["surface_id": .string(surfaceID), "text": .string(text)]
        )
        return try decodeEnvelope(data, as: WireAgentPromptResult.self)
    }

    // MARK: - Phase / path helpers

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        phaseContinuation.yield(newPhase)
    }

    /// Races an operation against a deadline. Needed because a request whose
    /// reply never arrives would otherwise park its continuation forever --
    /// which is what left the app wedged on "Connecting". Teardown resumes any
    /// still-pending continuation, so a timed-out request cannot leak.
    private func withRequestTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BridgeError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BridgeError.timedOut }
            return first
        }
    }

    /// A subscribed dashboard sends nothing and may receive nothing for long
    /// stretches -- no agent changing state means no event frames. QUIC closes
    /// an idle connection, which showed up in the bridge log as repeated
    /// `ConnectionLost(TimedOut)` shortly after every `subscribe`. A cheap
    /// periodic ping keeps the path warm and doubles as liveness detection.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                await self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard case .connected = phase else { return }
        do {
            _ = try await withRequestTimeout(seconds: 15) {
                try await self.performRequestUnchecked(method: "system.ping", params: [:])
            }
        } catch {
            // The read loop owns disconnect handling; surface the phase here so
            // a silently dead connection doesn't keep looking healthy.
            setPhase(.failed("connection lost: \(error)"))
        }
    }

    private func startReadLoop() {
        readLoopTask?.cancel()
        readLoopTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    private func startPathLoop() {
        pathLoopTask?.cancel()
        pathLoopTask = Task { [weak self] in
            await self?.runPathLoop()
        }
    }

    private func runReadLoop() async {
        while !Task.isCancelled {
            do {
                guard let line = try await nextBufferedLine() else {
                    await handleDisconnect(reason: "connection closed")
                    return
                }
                handleLine(line)
            } catch {
                if Task.isCancelled { return }
                await handleDisconnect(reason: "\(error)")
                return
            }
        }
    }

    private func runPathLoop() async {
        while !Task.isCancelled {
            guard case .connected = phase, let connection else { return }
            let classified = PathClassifier.classify(connection.paths())
            if classified != observedPath {
                observedPath = classified
                pathContinuation.yield(classified)
            }
            do {
                try await Task.sleep(for: Self.pathPollInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - Framing (buffered read, split on '\n' — mirrors
    // tools/mobile-spike/Sources/iroh-spike/StreamFraming.swift's
    // StreamLineReader, inlined here as actor-isolated state instead of a
    // separate `@unchecked Sendable` reader class).

    private func nextBufferedLine() async throws -> Data? {
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[readBuffer.startIndex ..< newlineIndex])
                readBuffer.removeSubrange(readBuffer.startIndex ... newlineIndex)
                return line
            }
            guard let recvStream else { return nil }
            let chunk = try await recvStream.read(sizeLimit: 65536)
            if chunk.isEmpty {
                if !readBuffer.isEmpty {
                    let remaining = readBuffer
                    readBuffer.removeAll()
                    return remaining
                }
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        if let eventName = object["event"] as? String {
            emitEvent(name: eventName, line: line)
            return
        }
        guard let rawId = object["id"] else { return }
        let id: Int?
        if let intId = rawId as? Int {
            id = intId
        } else if let numberId = rawId as? NSNumber {
            id = numberId.intValue
        } else {
            id = nil
        }
        guard let id, let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: line)
    }

    private func emitEvent(name: String, line: Data) {
        let decoder = JSONDecoder()
        switch name {
        case "agent_state":
            guard let payload = try? decoder.decode(WireAgentStateEvent.self, from: line) else { return }
            eventContinuation.yield(.agentState(payload))
        case "output":
            guard let payload = try? decoder.decode(WireOutputEvent.self, from: line) else { return }
            eventContinuation.yield(.output(payload))
        case "workspace_lifecycle":
            guard let payload = try? decoder.decode(WireWorkspaceLifecycleEvent.self, from: line) else { return }
            eventContinuation.yield(.workspaceLifecycle(payload))
        case "dropped":
            guard let payload = try? decoder.decode(WireDroppedEvent.self, from: line) else { return }
            eventContinuation.yield(.dropped(payload.count))
        default:
            break
        }
    }

    private func handleDisconnect(reason: String) async {
        await teardownConnection()
        setPhase(.failed(reason))
    }

    private func teardownConnection() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readLoopTask?.cancel()
        readLoopTask = nil
        pathLoopTask?.cancel()
        pathLoopTask = nil

        if let connection {
            try? connection.close(errorCode: 0, reason: Data("client_teardown".utf8))
        }
        if let endpoint {
            try? await endpoint.close()
        }
        connection = nil
        endpoint = nil
        sendStream = nil
        recvStream = nil
        readBuffer.removeAll()

        let pendingCopy = pending
        pending.removeAll()
        for (_, continuation) in pendingCopy {
            continuation.resume(throwing: BridgeError.disconnected)
        }
    }

    private func writeLine(_ data: Data) async throws {
        guard let sendStream else { throw BridgeError.notConnected }
        var framed = data
        framed.append(0x0A)
        try await sendStream.writeAll(buf: framed)
    }

    // MARK: - Request/response plumbing

    private func performRequest(method: String, params: [String: RPCParam]) async throws -> Data {
        guard case .connected = phase else { throw BridgeError.notConnected }
        return try await performRequestUnchecked(method: method, params: params)
    }

    /// Same as `performRequest` but without the `.connected` phase guard, so
    /// the admission ping issued during `connect()` -- which by definition runs
    /// before the phase is `.connected` -- can use the normal request/response
    /// machinery. Everything else must go through `performRequest`.
    private func performRequestUnchecked(method: String, params: [String: RPCParam]) async throws -> Data {
        let id = nextRequestId
        nextRequestId += 1
        let request = RPCRequest(id: id, method: method, params: params)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw BridgeError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pending[id] = continuation
            Task { [weak self] in
                await self?.performWrite(id: id, payload: payload)
            }
        }
    }

    private func performWrite(id: Int, payload: Data) async {
        do {
            try await writeLine(payload)
        } catch {
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            }
        }
    }

    private func decodeEnvelope<R: Decodable>(_ data: Data, as type: R.Type) throws -> R {
        let envelope = try JSONDecoder().decode(ResponseEnvelope<R>.self, from: data)
        guard envelope.ok else {
            throw BridgeError.rpc(code: envelope.error?.code ?? "unknown_error", message: envelope.error?.message)
        }
        guard let result = envelope.result else {
            throw BridgeError.malformedResponse
        }
        return result
    }
}

private struct ResponseEnvelope<R: Decodable>: Decodable {
    let ok: Bool
    let result: R?
    let error: WireErrorPayload?
}

private struct PairRequest: Encodable {
    let pair: String
    /// Human-readable device name so the Mac's paired-device list can show
    /// "Franco's iPhone" instead of a 64-char hex EndpointID. Optional on the
    /// wire -- the bridge falls back to a placeholder when absent.
    let label: String?
}

private struct PairResponse: Decodable {
    let ok: Bool
    let paired: Bool?
    let error: WireErrorPayload?
}

private struct RPCRequest: Encodable {
    let id: Int
    let method: String
    let params: [String: RPCParam]
}
