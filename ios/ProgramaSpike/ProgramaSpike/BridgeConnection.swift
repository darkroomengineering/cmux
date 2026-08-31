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
    // Must match the in-app bridge's ALPN exactly
    // (Sources/MobileBridge/MobileBridgeListener.swift). A mismatch is not a
    // soft failure: iroh aborts the handshake with "peer doesn't support any
    // known protocol", which reads like a transport fault rather than a
    // version skew between the two halves of this feature.
    private static let alpn = Data("programa/mobile-bridge/1".utf8)
    private static let pathPollInterval: Duration = .seconds(3)
    private static let pairingReplyTimeout: Duration = .seconds(15)

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
    private var lineFramer = BoundedLineFramer()

    private var readLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pathLoopTask: Task<Void, Never>?

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var nextRequestId = 1
    private var pending: [Int: PendingRequest] = [:]

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

    func pendingRequestCountForTesting() -> Int {
        pending.count
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
            setPhase(.failed(String(localized: "bridge.error.invalidTicket", defaultValue: "invalid pairing ticket")))
            throw BridgeError.invalidTicket
        }
        let targetAddress = ticket.endpointAddr()

        let secretKey: Data
        do {
            secretKey = try SecretKeyStore.loadOrCreate()
        } catch {
            setPhase(.failed(String(localized: "bridge.error.deviceIdentityFailed", defaultValue: "could not load device identity")))
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
            // Bound the dial. A ticket that points at a bridge which no longer
            // exists -- a Mac that restarted, or an old pairing -- otherwise
            // parks here indefinitely and the UI sits on "Connecting…" forever
            // with no error and no way out. `Endpoint.connect` routes through
            // `irohConnectWithTaskCancellation`, so unlike the raw stream reads
            // it genuinely honours cancellation.
            let newConnection = try await withCooperativeTimeout(seconds: 20) {
                try await newEndpoint.connect(addr: targetAddress, alpn: Self.alpn)
            }
            establishedConnection = newConnection
            try newConnection.setMaxConcurrentBiStreams(count: 1)
            try newConnection.setMaxConcurrentUniStreams(count: 0)
            try await newConnection.authorizeNatTraversal()
        } catch {
            if let establishedConnection {
                try? establishedConnection.close(errorCode: 0, reason: Data())
            }
            if case BridgeError.timedOut = error {
                if let boundEndpoint { try? await boundEndpoint.close() }
                setPhase(.failed(
                    String(
                        localized: "bridge.error.unreachable",
                        defaultValue: "could not reach that Mac — is Programa running with Settings ▸ Phone turned on?"
                    )
                ))
                throw error
            }
            if let boundEndpoint {
                try? await boundEndpoint.close()
            }
            setPhase(.failed("\(error)"))
            throw error
        }

        guard let newEndpoint = boundEndpoint, let newConnection = establishedConnection else {
            setPhase(.failed(String(localized: "bridge.error.setupFailed", defaultValue: "connection setup failed")))
            throw BridgeError.disconnected
        }

        do {
            let stream = try await newConnection.openBi()
            endpoint = newEndpoint
            connection = newConnection
            sendStream = stream.send()
            recvStream = stream.recv()
            lineFramer = BoundedLineFramer()
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
                let replyDeadline = InitialPairingReplyDeadline()
                guard let replyLine = try await replyDeadline.run(
                    timeout: Self.pairingReplyTimeout,
                    read: { [weak self] in
                        guard let self else { return nil }
                        return try await self.nextBufferedLine()
                    },
                    abort: { [weak self] in
                        await self?.teardownConnection()
                    }
                ) else {
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
            _ = try await performRequestUnchecked(method: "system.ping", params: [:])
        } catch {
            await teardownConnection()
            setPhase(.failed(
                String.localizedStringWithFormat(
                    String(localized: "bridge.error.notAdmitted", defaultValue: "not admitted by the Mac: %@"),
                    "\(error)"
                )
            ))
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

    /// Races only cancellation-cooperative operations against a deadline.
    /// RPC requests use ID-owned deadlines below because cancelling a task
    /// suspended on a checked continuation does not resume that continuation.
    private func withCooperativeTimeout<T: Sendable>(
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
            _ = try await performRequestUnchecked(method: "system.ping", params: [:])
        } catch {
            // The read loop owns disconnect handling; surface the phase here so
            // a silently dead connection doesn't keep looking healthy.
            setPhase(.failed(
                String.localizedStringWithFormat(
                    String(localized: "bridge.error.connectionLost", defaultValue: "connection lost: %@"),
                    "\(error)"
                )
            ))
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
                    await handleDisconnect(
                        reason: String(localized: "bridge.error.connectionClosed", defaultValue: "connection closed")
                    )
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

    // MARK: - Framing

    private func nextBufferedLine() async throws -> Data? {
        guard let recvStream else { return nil }
        return try await lineFramer.nextLine { sizeLimit in
            try await recvStream.read(sizeLimit: sizeLimit)
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
        // A frame with no `id` and no `event` is a CONNECTION-level rejection,
        // not a reply to anything: the bridge sends `{"ok":false,"error":
        // {"code":"not_paired"}}` and hangs up before this client has sent a
        // single request. Previously this fell through the `id` guard below and
        // was silently dropped, so the app sat on "Connecting…" until an
        // unrelated 15s ping timeout fired, then retried forever -- never
        // surfacing the one fact that mattered: this device is not paired.
        if object["id"] == nil,
           let ok = object["ok"] as? Bool, ok == false {
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? "rejected"
            failAllPending(with: BridgeError.rpc(code: code, message: nil))
            setPhase(.failed(code))
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
        guard let id, let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(returning: line)
    }

    private func failAllPending(with error: Error) {
        let outstanding = pending
        pending.removeAll()
        for (_, request) in outstanding {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func emitEvent(name: String, line: Data) {
        let decoder = JSONDecoder()
        switch name {
        case "bridge_hello":
            guard let payload = try? decoder.decode(WireBridgeHelloEvent.self, from: line) else { return }
            eventContinuation.yield(.bridgeHello(payload))
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
        lineFramer = BoundedLineFramer()

        let pendingCopy = pending
        pending.removeAll()
        for (_, request) in pendingCopy {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: BridgeError.disconnected)
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
    private func performRequestUnchecked(
        method: String,
        params: [String: RPCParam],
        timeout: Duration = .seconds(15)
    ) async throws -> Data {
        let id = nextRequestId
        nextRequestId += 1
        let request = RPCRequest(id: id, method: method, params: params)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw BridgeError.encodingFailed
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.failPendingRequest(id: id, error: BridgeError.timedOut)
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.performWrite(id: id, payload: payload)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPendingRequest(id: id, error: CancellationError())
            }
        }
    }

    private func failPendingRequest(id: Int, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func performWrite(id: Int, payload: Data) async {
        do {
            try await writeLine(payload)
        } catch {
            failPendingRequest(id: id, error: error)
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

/// Races the initial pairing reply against timeout and caller cancellation without relying on
/// the underlying iroh read to cooperate with task cancellation. The abort action closes the
/// transport before the winning error is resumed, which releases a read blocked on a silent peer.
final class InitialPairingReplyDeadline: @unchecked Sendable {
    private enum Completion: @unchecked Sendable {
        case value(Data?)
        case failure(Error)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    private var completion: Completion?
    private var completionRequiresAbort = false
    private var abortAction: (@Sendable () async -> Void)?
    private var readTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        timeout: Duration,
        read: @escaping @Sendable () async throws -> Data?,
        abort: @escaping @Sendable () async -> Void
    ) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation: continuation, abort: abort) else { return }
                storeReadTask(Task { [weak self] in
                    do {
                        let value = try await read()
                        self?.resolve(.value(value), abort: false)
                    } catch {
                        self?.resolve(.failure(error), abort: false)
                    }
                })
                storeTimeoutTask(Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.resolve(.failure(BridgeError.timedOut), abort: true)
                })
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()), abort: true)
        }
    }

    private func install(
        continuation: CheckedContinuation<Data?, Error>,
        abort: @escaping @Sendable () async -> Void
    ) -> Bool {
        lock.lock()
        if let completion {
            let shouldAbort = completionRequiresAbort
            lock.unlock()
            Task {
                if shouldAbort { await abort() }
                Self.resume(continuation, with: completion)
            }
            return false
        }
        self.continuation = continuation
        abortAction = abort
        lock.unlock()
        return true
    }

    private func storeReadTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completion == nil {
            readTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func storeTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completion == nil {
            timeoutTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func resolve(_ completion: Completion, abort shouldAbort: Bool) {
        lock.lock()
        guard self.completion == nil else {
            lock.unlock()
            return
        }
        self.completion = completion
        completionRequiresAbort = shouldAbort
        let continuation = self.continuation
        self.continuation = nil
        let abortAction = self.abortAction
        self.abortAction = nil
        let readTask = self.readTask
        self.readTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        readTask?.cancel()
        timeoutTask?.cancel()
        guard let continuation else { return }
        Task {
            if shouldAbort, let abortAction {
                await abortAction()
            }
            Self.resume(continuation, with: completion)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Data?, Error>,
        with completion: Completion
    ) {
        switch completion {
        case .value(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Data?, Error>,
        with completion: Completion
    ) {
        Self.resume(continuation, with: completion)
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
