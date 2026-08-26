import Bonsplit
import Foundation
import IrohLib

/// Programa's mobile-bridge ALPN (M1). Deliberately distinct from any other
/// iroh ALPN this Mac might speak, mirroring
/// `tools/mobile-spike/Sources/iroh-spike/App.swift`'s `spikeALPN`.
private let mobileBridgeALPN = Data("programa/mobile-bridge/1".utf8)

private let mobileBridgePairingWindowDuration: Duration = .seconds(300)

private extension Duration {
    /// `Duration` has no direct `TimeInterval` conversion; used to derive a
    /// wall-clock `Date` expiry from `mobileBridgePairingWindowDuration` for
    /// display in Settings, without hardcoding the 300s figure a second time.
    var timeIntervalValue: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Everything Settings needs to show a pairing invitation: the two payloads
/// to transfer plus the wall-clock deadline for the live countdown.
struct MobileBridgePairingInfo: Sendable {
    let ticket: String
    let token: String
    let expiresAt: Date
}

enum MobileBridgeDeviceRevocationOutcome: Sendable, Equatable {
    case revoked
    case persistenceFailed
}

final class MobileBridgeConnectionRegistry: @unchecked Sendable {
    typealias CloseAction = @Sendable () -> Void

    struct PendingAdmissionLease: Sendable {
        fileprivate let id: UUID
        fileprivate let listenerGeneration: UInt64
    }

    struct AdmissionTicket: Sendable {
        fileprivate let endpointId: String
        fileprivate let endpointGeneration: UInt64
        fileprivate let listenerGeneration: UInt64
        fileprivate let pendingAdmissionID: UUID?
    }

    struct ListenerLifecycle: Sendable {
        fileprivate let listenerGeneration: UInt64
    }

    enum RegistrationResult: Sendable {
        case registered(superseded: [CloseAction])
        case rejected(CloseAction)
    }

    private struct IdentifiedPendingAdmission {
        let endpointId: String
        let endpointGeneration: UInt64
        let listenerGeneration: UInt64
        let close: CloseAction
    }

    private static let maximumPendingAdmissions = 10
    private static let maximumLiveConnections = 10
    private static let noOpClose: CloseAction = {}

    private let lock = NSLock()
    private var isAccepting = false
    private var listenerGeneration: UInt64 = 0
    private var endpointGenerations: [String: UInt64] = [:]
    private var anonymousPendingAdmissions: [UUID: UInt64] = [:]
    private var identifiedPendingAdmissions: [UUID: IdentifiedPendingAdmission] = [:]
    private var liveRecords: [String: [ObjectIdentifier: CloseAction]] = [:]

    func start() -> ListenerLifecycle {
        lock.withLock {
            if !isAccepting {
                listenerGeneration &+= 1
                isAccepting = true
            }
            return ListenerLifecycle(listenerGeneration: listenerGeneration)
        }
    }

    func beginAdmission(endpointId: String, lifecycle: ListenerLifecycle) -> AdmissionTicket? {
        lock.withLock {
            guard isAccepting, lifecycle.listenerGeneration == listenerGeneration else { return nil }
            return AdmissionTicket(
                endpointId: endpointId,
                endpointGeneration: endpointGenerations[endpointId] ?? 0,
                listenerGeneration: listenerGeneration,
                pendingAdmissionID: nil
            )
        }
    }

    func reservePending(lifecycle: ListenerLifecycle) -> PendingAdmissionLease? {
        lock.withLock {
            guard isAccepting,
                  lifecycle.listenerGeneration == listenerGeneration,
                  anonymousPendingAdmissions.count + identifiedPendingAdmissions.count
                      < Self.maximumPendingAdmissions
            else {
                return nil
            }

            let lease = PendingAdmissionLease(
                id: UUID(),
                listenerGeneration: listenerGeneration
            )
            anonymousPendingAdmissions[lease.id] = listenerGeneration
            return lease
        }
    }

    func identifyPending(
        _ lease: PendingAdmissionLease,
        endpointId: String,
        close: @escaping CloseAction
    ) -> AdmissionTicket? {
        lock.withLock {
            guard let reservedGeneration = anonymousPendingAdmissions.removeValue(forKey: lease.id),
                  reservedGeneration == lease.listenerGeneration,
                  isAccepting,
                  lease.listenerGeneration == listenerGeneration,
                  !identifiedPendingAdmissions.values.contains(where: { $0.endpointId == endpointId })
            else {
                return nil
            }

            let endpointGeneration = endpointGenerations[endpointId] ?? 0
            identifiedPendingAdmissions[lease.id] = IdentifiedPendingAdmission(
                endpointId: endpointId,
                endpointGeneration: endpointGeneration,
                listenerGeneration: listenerGeneration,
                close: close
            )
            return AdmissionTicket(
                endpointId: endpointId,
                endpointGeneration: endpointGeneration,
                listenerGeneration: listenerGeneration,
                pendingAdmissionID: lease.id
            )
        }
    }

    func expireAdmission(_ ticket: AdmissionTicket) -> CloseAction? {
        claimPendingAdmission(ticket)
    }

    @discardableResult
    func abandonPending(_ lease: PendingAdmissionLease) -> Bool {
        lock.withLock {
            guard anonymousPendingAdmissions[lease.id] == lease.listenerGeneration else { return false }
            anonymousPendingAdmissions[lease.id] = nil
            return true
        }
    }

    func abandonAdmission(_ ticket: AdmissionTicket) -> CloseAction? {
        claimPendingAdmission(ticket)
    }

    func registerIfCurrent(
        connectionID: ObjectIdentifier,
        ticket: AdmissionTicket,
        close: @escaping CloseAction,
        beforeRegister: () -> Bool = { true }
    ) -> RegistrationResult {
        lock.withLock {
            let candidateClose: CloseAction
            if let pendingAdmissionID = ticket.pendingAdmissionID {
                guard let pending = identifiedPendingAdmissions[pendingAdmissionID] else {
                    return .rejected(Self.noOpClose)
                }
                guard isAccepting,
                      ticket.listenerGeneration == listenerGeneration,
                      ticket.endpointGeneration == (endpointGenerations[ticket.endpointId] ?? 0),
                      pending.endpointId == ticket.endpointId,
                      pending.endpointGeneration == ticket.endpointGeneration,
                      pending.listenerGeneration == ticket.listenerGeneration
                else {
                    identifiedPendingAdmissions[pendingAdmissionID] = nil
                    return .rejected(pending.close)
                }
                candidateClose = pending.close
            } else {
                guard isAccepting,
                      ticket.listenerGeneration == listenerGeneration,
                      ticket.endpointGeneration == (endpointGenerations[ticket.endpointId] ?? 0)
                else {
                    return .rejected(close)
                }
                candidateClose = close
            }

            let liveConnectionCount = liveRecords.values.reduce(into: 0) {
                $0 += $1.count
            }
            let replacesCurrentEndpoint = liveRecords[ticket.endpointId]?.isEmpty == false
            guard liveConnectionCount < Self.maximumLiveConnections || replacesCurrentEndpoint else {
                if let pendingAdmissionID = ticket.pendingAdmissionID {
                    identifiedPendingAdmissions[pendingAdmissionID] = nil
                }
                return .rejected(candidateClose)
            }
            guard beforeRegister() else {
                if let pendingAdmissionID = ticket.pendingAdmissionID {
                    identifiedPendingAdmissions[pendingAdmissionID] = nil
                }
                return .rejected(candidateClose)
            }

            if let pendingAdmissionID = ticket.pendingAdmissionID {
                identifiedPendingAdmissions[pendingAdmissionID] = nil
            }
            let superseded = liveRecords.removeValue(forKey: ticket.endpointId).map {
                Array($0.values)
            } ?? []
            liveRecords[ticket.endpointId] = [connectionID: candidateClose]
            return .registered(superseded: superseded)
        }
    }

    func unregister(connectionID: ObjectIdentifier, endpointId: String) {
        lock.withLock {
            liveRecords[endpointId]?[connectionID] = nil
            if liveRecords[endpointId]?.isEmpty == true {
                liveRecords[endpointId] = nil
            }
        }
    }

    func revoke(endpointId: String, beforeClaim: () -> Void = {}) -> [CloseAction] {
        lock.withLock {
            endpointGenerations[endpointId] = (endpointGenerations[endpointId] ?? 0) &+ 1
            beforeClaim()

            let pendingIDs = identifiedPendingAdmissions.compactMap { id, admission in
                admission.endpointId == endpointId ? id : nil
            }
            let pendingActions = pendingIDs.compactMap {
                identifiedPendingAdmissions.removeValue(forKey: $0)?.close
            }
            let liveActions = liveRecords.removeValue(forKey: endpointId).map {
                Array($0.values)
            } ?? []
            return pendingActions + liveActions
        }
    }

    func stop() -> [CloseAction] {
        lock.withLock {
            if isAccepting {
                isAccepting = false
                listenerGeneration &+= 1
            }
            let actions = identifiedPendingAdmissions.values.map(\.close)
                + liveRecords.values.flatMap { Array($0.values) }
            anonymousPendingAdmissions.removeAll(keepingCapacity: true)
            identifiedPendingAdmissions.removeAll(keepingCapacity: true)
            liveRecords.removeAll(keepingCapacity: true)
            return actions
        }
    }

    private func claimPendingAdmission(_ ticket: AdmissionTicket) -> CloseAction? {
        lock.withLock {
            guard let pendingAdmissionID = ticket.pendingAdmissionID,
                  let pending = identifiedPendingAdmissions[pendingAdmissionID],
                  pending.endpointId == ticket.endpointId,
                  pending.endpointGeneration == ticket.endpointGeneration,
                  pending.listenerGeneration == ticket.listenerGeneration
            else {
                return nil
            }
            identifiedPendingAdmissions[pendingAdmissionID] = nil
            return pending.close
        }
    }
}

/// Owns the in-process iroh endpoint that lets a paired iPhone reach this
/// Mac's terminal control dispatch without the user ever running the
/// `tools/mobile-spike bridge` CLI in a terminal. Ported from
/// `tools/mobile-spike/Sources/iroh-spike/Bridge.swift`'s `runBridge`/
/// `handleBridgeConnection`, with connection admission/relay delegated to
/// `MobileBridgeSession` (which substitutes an in-process `socketpair` for
/// the CLI's `UnixSocketPipe`).
///
/// All accept/relay work runs off the main thread. `start()` returns
/// immediately and binds the endpoint on a detached background task, so
/// toggling this on from Settings (or at app launch) never blocks the UI
/// or app startup; bind failures are logged, never thrown to the caller.
final class MobileBridgeListener: @unchecked Sendable {
    static let shared = MobileBridgeListener()

    private let stateLock = NSLock()
    private let endpointBinder: @Sendable () async throws -> Endpoint
    private var endpoint: Endpoint?
    private var acceptTask: Task<Void, Never>?
    private var pairingWindow: MobileBridgePairingWindow?
    private var isStarting = false
    private var generation: UInt64 = 0
    private let connectionRegistry = MobileBridgeConnectionRegistry()

    init(
        endpointBinder: @escaping @Sendable () async throws -> Endpoint = {
            try await MobileBridgeListener.bindEndpoint()
        }
    ) {
        self.endpointBinder = endpointBinder
    }

    /// Starts the endpoint if it is not already running or starting.
    /// Idempotent. Never blocks the caller.
    ///
    /// Also assigns `TerminalController.shared.tabManager` so admitted
    /// phone sessions can dispatch commands -- this does NOT start or
    /// otherwise touch Programa's real Unix socket listener/access mode
    /// (see `MobileBridgeSession`'s doc comment for the one runtime
    /// precondition this implies).
    @MainActor
    func start(tabManager: TabManager) {
        TerminalController.shared.tabManager = tabManager

        let startState = stateLock.withLock {
            guard endpoint == nil, !isStarting else {
                return nil as (generation: UInt64, lifecycle: MobileBridgeConnectionRegistry.ListenerLifecycle)?
            }
            isStarting = true
            generation &+= 1
            return (
                generation: generation,
                lifecycle: connectionRegistry.start()
            )
        }
        guard let startState else { return }

        Task { [weak self] in
            await self?.bindAndAccept(
                generation: startState.generation,
                lifecycle: startState.lifecycle
            )
        }
    }

    /// Stops the listener and closes the endpoint. Safe to call whether or
    /// not the listener is currently running.
    func stop() {
        let stoppedState = stateLock.withLock {
            let task = acceptTask
            let ep = endpoint
            pairingWindow?.invalidate()
            acceptTask = nil
            endpoint = nil
            pairingWindow = nil
            isStarting = false
            generation &+= 1
            return (
                task: task,
                endpoint: ep,
                closeActions: connectionRegistry.stop()
            )
        }

        stoppedState.task?.cancel()
        stoppedState.closeActions.forEach { $0() }
        if let ep = stoppedState.endpoint {
            Task { try? await ep.close() }
        }
    }

    /// Opens a single-use, 5-minute pairing window and returns the pairing
    /// payload (ticket) and token to display in Settings. Returns `nil` if
    /// the endpoint isn't bound yet (mode just enabled, still binding) --
    /// the caller should show a brief error and let the user retry.
    func beginPairing() async -> MobileBridgePairingInfo? {
        let snapshot = stateLock.withLock {
            endpoint.map { (endpoint: $0, generation: generation) }
        }
        guard let snapshot else { return nil }

        let tokenBytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        let tokenString = MobileBridgeBase64URL.encode(tokenBytes)
        let window = MobileBridgePairingWindow(token: Data(tokenString.utf8), duration: mobileBridgePairingWindowDuration)
        let expiresAt = Date().addingTimeInterval(mobileBridgePairingWindowDuration.timeIntervalValue)

        guard let ticket = try? EndpointTicket.fromAddr(addr: snapshot.endpoint.addr()) else {
            window.invalidate()
            return nil
        }

        let published = stateLock.withLock {
            guard generation == snapshot.generation, endpoint === snapshot.endpoint else {
                return false
            }
            pairingWindow?.invalidate()
            pairingWindow = window
            return true
        }
        guard published else {
            window.invalidate()
            return nil
        }

        return MobileBridgePairingInfo(ticket: ticket.description, token: tokenString, expiresAt: expiresAt)
    }

    /// Revokes a previously paired device after its removal is durably stored:
    /// reconnects are then rejected at `admit()`, and every registered
    /// connection is closed so a long-lived relay session cannot keep running
    /// on borrowed trust until the phone disconnects on its own.
    func revoke(endpointId: String) async -> MobileBridgeDeviceRevocationOutcome {
        let result = await MobileBridgeTrustedDeviceStore.shared.revokeAndClaimConnections(
            endpointId: endpointId,
            registry: connectionRegistry
        )
        if let persistenceFailure = result.persistenceFailure {
            NSLog(
                "MobileBridge: failed to persist device revocation; connection remains active: %@",
                persistenceFailure
            )
            return .persistenceFailed
        }

        result.closeActions.forEach { $0() }
        return .revoked
    }

    private static func bindEndpoint() async throws -> Endpoint {
        let secretKey = try MobileBridgeSecretKeyStore.loadOrCreate()
        // Mirrors `makeEndpointOptions` in
        // `tools/mobile-spike/Sources/iroh-spike/App.swift` exactly --
        // see that file's doc comment for why each field matters
        // (`presetN0()`, `RelayMode.defaultMode()`, `0.0.0.0:0` bind,
        // `portMappingEnabled: true`).
        let options = EndpointOptions(
            preset: presetN0(),
            bindAddr: "0.0.0.0:0",
            secretKey: secretKey,
            alpns: [mobileBridgeALPN],
            relayMode: RelayMode.defaultMode(),
            portMappingEnabled: true,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        )
        return try await Endpoint.bind(options: options)
    }

    private func bindAndAccept(
        generation: UInt64,
        lifecycle: MobileBridgeConnectionRegistry.ListenerLifecycle
    ) async {
        do {
            let ep = try await endpointBinder()

            let published = stateLock.withLock {
                guard self.generation == generation else { return false }
                self.endpoint = ep
                self.isStarting = false
                return true
            }
            guard published else {
                // `stop()` (or a subsequent `start()`) ran while we were
                // binding -- this bind is stale, close it without publishing
                // state.
                try? await ep.close()
                return
            }

#if DEBUG
            // Log the dialable ticket, not just the node id: without it there is
            // no way to reach this bridge except by opening Settings and
            // starting a pairing window, which makes the bridge untestable from
            // a script. The ticket is an address, not a secret -- admission
            // still requires the pairing token or an allowlisted device.
            let debugTicket = (try? EndpointTicket.fromAddr(addr: ep.addr()))?.description ?? "<unavailable>"
            dlog("mobileBridge.listening node=\(ep.id()) ticket=\(debugTicket)")
#endif

            let task = Task { [weak self] in
                guard let self else { return }
                await self.acceptLoop(
                    endpoint: ep,
                    generation: generation,
                    lifecycle: lifecycle
                )
            }
            let installed = stateLock.withLock {
                guard self.generation == generation else { return false }
                acceptTask = task
                return true
            }
            if !installed {
                task.cancel()
            }
        } catch {
            NSLog("MobileBridge: failed to bind endpoint: %@", "\(error)")
            stateLock.withLock {
                if self.generation == generation {
                    isStarting = false
                }
            }
        }
    }

    private func acceptLoop(
        endpoint: Endpoint,
        generation: UInt64,
        lifecycle: MobileBridgeConnectionRegistry.ListenerLifecycle
    ) async {
        while let incoming = await endpoint.acceptNext() {
            let stillCurrent = stateLock.withLock { self.generation == generation }
            guard stillCurrent else {
                try? await incoming.refuse()
                break
            }

            guard let pendingLease = connectionRegistry.reservePending(lifecycle: lifecycle) else {
                try? await incoming.refuse()
                let remainsCurrent = stateLock.withLock { self.generation == generation }
                if !remainsCurrent {
                    break
                }
                continue
            }

            let registry = connectionRegistry
            let pendingDeadline = Self.startPendingAdmissionDeadline(
                registry: registry,
                lease: pendingLease,
                timeout: .seconds(15)
            ) {
                try? await incoming.refuse()
            }
            Task { [weak self] in
                guard let self else {
                    pendingDeadline.cancel()
                    if registry.abandonPending(pendingLease) {
                        try? await incoming.refuse()
                    }
                    return
                }
                await self.handleIncoming(
                    incoming,
                    pendingLease: pendingLease,
                    pendingDeadline: pendingDeadline
                )
            }
        }
    }

    static func startPendingAdmissionDeadline(
        registry: MobileBridgeConnectionRegistry,
        lease: MobileBridgeConnectionRegistry.PendingAdmissionLease,
        timeout: Duration,
        onTimeout: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard registry.abandonPending(lease) else { return }
            await onTimeout()
        }
    }

    private func handleIncoming(
        _ incoming: Incoming,
        pendingLease initialPendingLease: MobileBridgeConnectionRegistry.PendingAdmissionLease,
        pendingDeadline: Task<Void, Never>
    ) async {
        var pendingLease: MobileBridgeConnectionRegistry.PendingAdmissionLease? = initialPendingLease
        var admissionTicket: MobileBridgeConnectionRegistry.AdmissionTicket?
        var admissionDeadline: Task<Void, Never>?
        defer {
            pendingDeadline.cancel()
            admissionDeadline?.cancel()
            if let admissionTicket {
                connectionRegistry.abandonAdmission(admissionTicket)?()
            } else if let pendingLease {
                connectionRegistry.abandonPending(pendingLease)
            }
        }

        do {
            let accepting = try await incoming.accept()
            let remoteALPN = try await accepting.alpn()
            guard remoteALPN == mobileBridgeALPN else {
#if DEBUG
                dlog("mobileBridge.rejected reason=unexpected_alpn")
#endif
                return
            }

            let connection = try await accepting.connect()
            let connectionClose = MobileBridgeCloseOnce {
                try? connection.close(
                    errorCode: 0,
                    reason: Data("bridge session closed".utf8)
                )
            }
            let closeAction: MobileBridgeConnectionRegistry.CloseAction = {
                connectionClose.close()
            }
            defer { closeAction() }

            let idString = connection.remoteId().description
            let ticket = connectionRegistry.identifyPending(
                initialPendingLease,
                endpointId: idString,
                close: closeAction
            )
            pendingLease = nil
            pendingDeadline.cancel()
            guard let ticket else {
                closeAction()
                return
            }
            admissionTicket = ticket

            let registry = connectionRegistry
            admissionDeadline = Task {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                registry.expireAdmission(ticket)?()
            }

            try connection.setMaxConcurrentBiStreams(count: 1)
            try connection.setMaxConcurrentUniStreams(count: 0)

            let stream = try await connection.acceptBi()
            let reader = MobileBridgeStreamLineReader(stream: stream.recv())
            let writer = MobileBridgeFrameWriter(stream: stream.send())

            let window = stateLock.withLock { pairingWindow }

            guard let admissionOutcome = try await MobileBridgeSession.admit(
                idString: idString,
                reader: reader,
                writer: writer,
                pairingWindow: window
            ) else {
                return
            }

            let connectionID = ObjectIdentifier(connection)
            let registrationResult: MobileBridgeConnectionRegistry.RegistrationResult
            switch admissionOutcome {
            case .trusted:
                registrationResult = connectionRegistry.registerIfCurrent(
                    connectionID: connectionID,
                    ticket: ticket,
                    close: closeAction
                )
            case .paired(let label):
                registrationResult = await MobileBridgeTrustedDeviceStore.shared.registerPairedIfCurrent(
                    endpointId: idString,
                    label: label,
                    registry: connectionRegistry,
                    connectionID: connectionID,
                    ticket: ticket,
                    close: closeAction
                )
            }
            admissionDeadline?.cancel()

            switch registrationResult {
            case .registered(let superseded):
                superseded.forEach { $0() }
            case .rejected(let close):
                close()
                return
            }
            defer {
                connectionRegistry.unregister(connectionID: connectionID, endpointId: idString)
            }

            if case .paired = admissionOutcome {
                try await writer.writeLine(Data(#"{"ok":true,"paired":true}"#.utf8))
            }
            try await connection.authorizeNatTraversal()

#if DEBUG
            dlog("mobileBridge.connected id=\(idString)")
#endif
            await MobileBridgeSession.relay(
                reader: reader,
                writer: writer,
                idString: idString,
                closeRemote: closeAction
            )
#if DEBUG
            dlog("mobileBridge.disconnected id=\(idString)")
#endif
        } catch {
            NSLog("MobileBridge: connection handling error: %@", "\(error)")
        }
    }
}
