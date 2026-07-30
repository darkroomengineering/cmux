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
    private var endpoint: Endpoint?
    private var acceptTask: Task<Void, Never>?
    private var pairingWindow: MobileBridgePairingWindow?
    private var isStarting = false
    private var generation: UInt64 = 0

    private init() {}

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

        stateLock.lock()
        guard endpoint == nil, !isStarting else {
            stateLock.unlock()
            return
        }
        isStarting = true
        generation += 1
        let currentGeneration = generation
        stateLock.unlock()

        Task { [weak self] in
            await self?.bindAndAccept(generation: currentGeneration)
        }
    }

    /// Stops the listener and closes the endpoint. Safe to call whether or
    /// not the listener is currently running.
    func stop() {
        stateLock.lock()
        let task = acceptTask
        let ep = endpoint
        acceptTask = nil
        endpoint = nil
        pairingWindow = nil
        isStarting = false
        generation += 1
        stateLock.unlock()

        task?.cancel()
        if let ep {
            Task { try? await ep.close() }
        }
    }

    /// Opens a single-use, 5-minute pairing window and returns the pairing
    /// payload (ticket) and token to display in Settings. Returns `nil` if
    /// the endpoint isn't bound yet (mode just enabled, still connecting to
    /// relays) -- the caller should show a brief error and let the user
    /// retry.
    func beginPairing() async -> MobileBridgePairingInfo? {
        stateLock.lock()
        let ep = endpoint
        stateLock.unlock()
        guard let ep else { return nil }

        let tokenBytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        let tokenString = MobileBridgeBase64URL.encode(tokenBytes)
        let window = MobileBridgePairingWindow(token: Data(tokenString.utf8), duration: mobileBridgePairingWindowDuration)
        let expiresAt = Date().addingTimeInterval(mobileBridgePairingWindowDuration.timeIntervalValue)

        stateLock.lock()
        pairingWindow = window
        stateLock.unlock()

        guard let ticket = try? EndpointTicket.fromAddr(addr: ep.addr()) else { return nil }
        return MobileBridgePairingInfo(ticket: ticket.description, token: tokenString, expiresAt: expiresAt)
    }

    /// Revokes a previously paired device immediately.
    func revoke(endpointId: String) async {
        await MobileBridgeTrustedDeviceStore.shared.remove(endpointId: endpointId)
    }

    private func bindAndAccept(generation: UInt64) async {
        do {
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
            let ep = try await Endpoint.bind(options: options)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await ep.online() }
                group.addTask { try? await Task.sleep(for: .seconds(10)) }
                await group.next()
                group.cancelAll()
            }

            stateLock.lock()
            guard self.generation == generation else {
                // `stop()` (or a subsequent `start()`) ran while we were
                // binding/waiting for relay connectivity -- this bind is
                // stale, close it without publishing state.
                stateLock.unlock()
                try? await ep.close()
                return
            }
            self.endpoint = ep
            self.isStarting = false
            stateLock.unlock()

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
                await self.acceptLoop(endpoint: ep, generation: generation)
            }
            stateLock.lock()
            if self.generation == generation {
                acceptTask = task
            } else {
                task.cancel()
            }
            stateLock.unlock()
        } catch {
            NSLog("MobileBridge: failed to bind endpoint: %@", "\(error)")
            stateLock.lock()
            if self.generation == generation {
                isStarting = false
            }
            stateLock.unlock()
        }
    }

    private func acceptLoop(endpoint: Endpoint, generation: UInt64) async {
        while let incoming = await endpoint.acceptNext() {
            stateLock.lock()
            let stillCurrent = self.generation == generation
            stateLock.unlock()
            guard stillCurrent else { break }

            Task { [weak self] in
                await self?.handleIncoming(incoming)
            }
        }
    }

    private func handleIncoming(_ incoming: Incoming) async {
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
            try connection.setMaxConcurrentBiStreams(count: 1)
            try connection.setMaxConcurrentUniStreams(count: 0)
            try await connection.authorizeNatTraversal()

            let idString = connection.remoteId().description

            let stream = try await connection.acceptBi()
            let reader = MobileBridgeStreamLineReader(stream: stream.recv())
            let writer = MobileBridgeFrameWriter(stream: stream.send())

            stateLock.lock()
            let window = pairingWindow
            stateLock.unlock()

            let admitted = try await MobileBridgeSession.admit(
                idString: idString,
                reader: reader,
                writer: writer,
                pairingWindow: window
            )
            guard admitted else {
                _ = await connection.closed()
                return
            }

#if DEBUG
            dlog("mobileBridge.connected id=\(idString)")
#endif
            await MobileBridgeSession.relay(reader: reader, writer: writer, idString: idString)
            _ = await connection.closed()
#if DEBUG
            dlog("mobileBridge.disconnected id=\(idString)")
#endif
        } catch {
            NSLog("MobileBridge: connection handling error: %@", "\(error)")
        }
    }
}
