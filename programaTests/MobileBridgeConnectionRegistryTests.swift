import Foundation
import IrohLib
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

private final class FakeConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCloseCount = 0

    var connectionID: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    var closeAction: MobileBridgeConnectionRegistry.CloseAction {
        { [self] in
            lock.lock()
            storedCloseCount += 1
            lock.unlock()
        }
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCount
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class FragmentingRecvStream: RecvStream, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let maximumBytesPerRead: Int
    private var offset = 0

    init(data: Data, maximumBytesPerRead: Int) {
        precondition(maximumBytesPerRead > 0)
        self.data = data
        self.maximumBytesPerRead = maximumBytesPerRead
        super.init(noHandle: RecvStream.NoHandle())
    }

    required init(unsafeFromHandle _: UInt64) {
        fatalError("FragmentingRecvStream is test-only and never owns an FFI handle")
    }

    override func read(sizeLimit: UInt32) async throws -> Data {
        lock.withLock {
            guard offset < data.count else { return Data() }
            let byteCount = min(
                Int(sizeLimit),
                maximumBytesPerRead,
                data.count - offset
            )
            let end = offset + byteCount
            let chunk = data.subdata(in: offset ..< end)
            offset = end
            return chunk
        }
    }
}

private final class CancellationBlindOnlineEndpoint: Endpoint, @unchecked Sendable {
    private let lock = NSLock()
    private let onAcceptNext: () -> Void
    private let fakeID: EndpointId
    private let fakeAddress: EndpointAddr
    private var onlineContinuation: CheckedContinuation<Void, Never>?
    private var isOnlineReleased = false

    init(onAcceptNext: @escaping () -> Void) throws {
        let id = try EndpointId.fromBytes(bytes: Data([
            0x52, 0x3c, 0x79, 0x96, 0xba, 0xd7, 0x74, 0x24,
            0xe9, 0x67, 0x86, 0xcf, 0x7a, 0x72, 0x05, 0x11,
            0x53, 0x37, 0xa5, 0xb4, 0x56, 0x5c, 0xd2, 0x55,
            0x06, 0xa0, 0xf2, 0x97, 0xb1, 0x91, 0xa5, 0xea,
        ]))
        self.onAcceptNext = onAcceptNext
        fakeID = id
        fakeAddress = EndpointAddr(id: id, relayUrl: nil, addresses: [])
        super.init(noHandle: Endpoint.NoHandle())
    }

    required init(unsafeFromHandle _: UInt64) {
        fatalError("CancellationBlindOnlineEndpoint is test-only and never owns an FFI handle")
    }

    override func online() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !isOnlineReleased else { return true }
                onlineContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    override func addr() -> EndpointAddr {
        fakeAddress
    }

    override func id() -> EndpointId {
        fakeID
    }

    override func acceptNext() async -> Incoming? {
        onAcceptNext()
        return nil
    }

    override func close() async throws {}

    func releaseOnlineForTest() {
        let continuation = lock.withLock {
            isOnlineReleased = true
            let continuation = onlineContinuation
            onlineContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private enum PersistenceFailure: Error {
    case expected
}

private final class ParkingRelayLineSource: @unchecked Sendable {
    private let lock = NSLock()
    private let onFirstWait: () -> Void
    private var didAnnounceWait = false
    private var isFinished = false
    private var continuations: [CheckedContinuation<Data?, Error>] = []

    init(onFirstWait: @escaping () -> Void = {}) {
        self.onFirstWait = onFirstWait
    }

    func nextLine() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let shouldAnnounce: Bool = lock.withLock {
                guard !isFinished else {
                    continuation.resume(returning: nil)
                    return false
                }
                continuations.append(continuation)
                guard !didAnnounceWait else { return false }
                didAnnounceWait = true
                return true
            }
            if shouldAnnounce {
                onFirstWait()
            }
        }
    }

    func finish() {
        let parkedContinuations: [CheckedContinuation<Data?, Error>] = lock.withLock {
            guard !isFinished else { return [] }
            isFinished = true
            let parkedContinuations = continuations
            continuations.removeAll()
            return parkedContinuations
        }
        parkedContinuations.forEach { $0.resume(returning: nil) }
    }
}

private final class ParkingRelayPhoneReader: MobileBridgeRelayLineReading, @unchecked Sendable {
    private let source: ParkingRelayLineSource

    init(source: ParkingRelayLineSource) {
        self.source = source
    }

    func nextLine() async throws -> Data? {
        try await source.nextLine()
    }
}

private final class RecordingRelayWriter: MobileBridgeRelayFrameWriting, @unchecked Sendable {
    func writeLine(_: Data) async throws {}
}

private final class ParkingRelayLocalPipe: MobileBridgeRelayLocalPiping, @unchecked Sendable {
    private let lock = NSLock()
    private let source: ParkingRelayLineSource
    private var storedShutdownCount = 0

    init(source: ParkingRelayLineSource) {
        self.source = source
    }

    var shutdownCount: Int {
        lock.withLock { storedShutdownCount }
    }

    func nextLine() async throws -> Data? {
        try await source.nextLine()
    }

    func send(_: Data) async throws {}

    func shutdownLocalEnd() {
        lock.withLock {
            storedShutdownCount += 1
        }
        source.finish()
    }

    /// Test cleanup must be able to release a deliberately cancellation-blind
    /// continuation without being counted as production shutdown behavior.
    func forceUnblockForTest() {
        source.finish()
    }
}

final class MobileBridgeConnectionRegistryTests: XCTestCase {
    @discardableResult
    private func assertRegistered(
        _ result: MobileBridgeConnectionRegistry.RegistrationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [MobileBridgeConnectionRegistry.CloseAction] {
        guard case .registered(let superseded) = result else {
            XCTFail("Expected the current admission ticket to register", file: file, line: line)
            return []
        }
        return superseded
    }

    private func executeRejectedClose(
        _ result: MobileBridgeConnectionRegistry.RegistrationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let close) = result else {
            XCTFail("Expected a stale admission ticket to be rejected", file: file, line: line)
            return
        }
        close()
    }

    private func execute(_ actions: [MobileBridgeConnectionRegistry.CloseAction]) {
        actions.forEach { $0() }
    }

    @MainActor
    func testBoundEndpointStartsAcceptingWithoutWaitingForRelayReadiness() async throws {
        let acceptStarted = expectation(description: "bound endpoint started accepting connections")
        let endpoint = try CancellationBlindOnlineEndpoint {
            acceptStarted.fulfill()
        }
        let listener = MobileBridgeListener(endpointBinder: { endpoint })
        let previousTabManager = TerminalController.shared.tabManager
        defer {
            listener.stop()
            endpoint.releaseOnlineForTest()
            TerminalController.shared.tabManager = previousTabManager
        }

        listener.start(tabManager: TabManager())

        await fulfillment(of: [acceptStarted], timeout: 1)
    }

    func testRevocationRejectsAnAdmissionThatStartedBeforeTrustWasRemoved() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()

        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))
        let revokedActions = registry.revoke(endpointId: "endpoint-E")
        XCTAssertTrue(revokedActions.isEmpty)

        let result = registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction
        )
        executeRejectedClose(result)

        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E").isEmpty)
    }

    func testRevocationClaimsARegisteredConnectionExactlyOnce() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()

        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction
        ))

        let claimedActions = registry.revoke(endpointId: "endpoint-E")
        XCTAssertEqual(claimedActions.count, 1)
        execute(claimedActions)
        XCTAssertEqual(connection.closeCount, 1)

        registry.unregister(connectionID: connection.connectionID, endpointId: "endpoint-E")
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E").isEmpty)
        XCTAssertEqual(connection.closeCount, 1)
    }

    func testRetrustCreatesANewGenerationWithoutRevalidatingOldTickets() throws {
        let registry = MobileBridgeConnectionRegistry()
        let staleConnection = FakeConnection()
        let currentConnection = FakeConnection()

        let lifecycle = registry.start()
        let staleTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E").isEmpty)
        let currentTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        executeRejectedClose(registry.registerIfCurrent(
            connectionID: staleConnection.connectionID,
            ticket: staleTicket,
            close: staleConnection.closeAction
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: currentConnection.connectionID,
            ticket: currentTicket,
            close: currentConnection.closeAction
        ))

        XCTAssertEqual(staleConnection.closeCount, 1)
        XCTAssertEqual(currentConnection.closeCount, 0)
        let currentActions = registry.revoke(endpointId: "endpoint-E")
        XCTAssertEqual(currentActions.count, 1)
        execute(currentActions)
        XCTAssertEqual(currentConnection.closeCount, 1)
    }

    func testStopInvalidatesPendingAdmissionsUntilANewListenerGenerationStarts() throws {
        let registry = MobileBridgeConnectionRegistry()
        let staleConnection = FakeConnection()
        let restartedConnection = FakeConnection()

        let staleLifecycle = registry.start()
        let staleTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: staleLifecycle
        ))
        XCTAssertTrue(registry.stop().isEmpty)

        executeRejectedClose(registry.registerIfCurrent(
            connectionID: staleConnection.connectionID,
            ticket: staleTicket,
            close: staleConnection.closeAction
        ))
        XCTAssertEqual(staleConnection.closeCount, 1)
        XCTAssertNil(registry.beginAdmission(endpointId: "endpoint-E", lifecycle: staleLifecycle))

        let restartedLifecycle = registry.start()
        let restartedTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: restartedLifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: restartedConnection.connectionID,
            ticket: restartedTicket,
            close: restartedConnection.closeAction
        ))
        XCTAssertEqual(restartedConnection.closeCount, 0)

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 1)
        execute(stoppedActions)
        XCTAssertEqual(restartedConnection.closeCount, 1)
    }

    func testHandlerFromStoppedLifecycleCannotBeginAdmissionAfterRestart() throws {
        let registry = MobileBridgeConnectionRegistry()
        let currentConnection = FakeConnection()

        let stoppedLifecycle = registry.start()
        XCTAssertTrue(registry.stop().isEmpty)
        let currentLifecycle = registry.start()

        XCTAssertNil(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: stoppedLifecycle
        ))
        let currentTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: currentLifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: currentConnection.connectionID,
            ticket: currentTicket,
            close: currentConnection.closeAction
        ))
        XCTAssertEqual(currentConnection.closeCount, 0)

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 1)
        execute(stoppedActions)
        XCTAssertEqual(currentConnection.closeCount, 1)
    }

    func testDisconnectAndRevocationHaveExactlyOneClaimantInEitherOrder() throws {
        let registry = MobileBridgeConnectionRegistry()
        let disconnectedFirst = FakeConnection()
        let revokedFirst = FakeConnection()

        let lifecycle = registry.start()

        let disconnectedTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "disconnect-first",
            lifecycle: lifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: disconnectedFirst.connectionID,
            ticket: disconnectedTicket,
            close: disconnectedFirst.closeAction
        ))
        registry.unregister(
            connectionID: disconnectedFirst.connectionID,
            endpointId: "disconnect-first"
        )
        XCTAssertTrue(registry.revoke(endpointId: "disconnect-first").isEmpty)
        XCTAssertEqual(disconnectedFirst.closeCount, 0)

        let revokedTicket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "revoke-first",
            lifecycle: lifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: revokedFirst.connectionID,
            ticket: revokedTicket,
            close: revokedFirst.closeAction
        ))
        let claimedActions = registry.revoke(endpointId: "revoke-first")
        XCTAssertEqual(claimedActions.count, 1)
        registry.unregister(connectionID: revokedFirst.connectionID, endpointId: "revoke-first")
        execute(claimedActions)
        XCTAssertEqual(revokedFirst.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "revoke-first").isEmpty)
    }

    func testInvalidatedPairingWindowRejectsItsCapturedToken() {
        let token = Data("single-use-secret".utf8)
        let window = MobileBridgePairingWindow(token: token, duration: .seconds(60))

        XCTAssertTrue(window.isOpen)
        window.invalidate()

        XCTAssertFalse(window.isOpen)
        XCTAssertFalse(window.attemptConsume(token))
    }

    func testPairingWindowConsumesMatchingTokenOnlyOnceAndSurvivesMismatch() {
        let token = Data("single-use-secret".utf8)
        let window = MobileBridgePairingWindow(token: token, duration: .seconds(60))

        XCTAssertFalse(window.attemptConsume(Data("wrong-secret".utf8)))
        XCTAssertTrue(window.isOpen)
        XCTAssertTrue(window.attemptConsume(token))
        XCTAssertFalse(window.isOpen)
        XCTAssertFalse(window.attemptConsume(token))
    }

    func testStaleRegistrationRejectsBeforeInvokingTrustCommit() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let commitCount = LockedValue(0)
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E", beforeClaim: {}).isEmpty)
        let result = registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction,
            beforeRegister: {
                commitCount.withLock { $0 += 1 }
                return true
            }
        )
        executeRejectedClose(result)

        XCTAssertEqual(commitCount.withLock { $0 }, 0)
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E", beforeClaim: {}).isEmpty)
    }

    func testFailedTrustCommitRejectsWithoutRegisteringConnection() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let commitCount = LockedValue(0)
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        let result = registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction,
            beforeRegister: {
                commitCount.withLock { $0 += 1 }
                return false
            }
        )
        executeRejectedClose(result)

        XCTAssertEqual(commitCount.withLock { $0 }, 1)
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E", beforeClaim: {}).isEmpty)
    }

    func testSuccessfulTrustCommitRegistersAndTransfersCloseOwnershipExactlyOnce() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let commitCount = LockedValue(0)
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        assertRegistered(registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction,
            beforeRegister: {
                commitCount.withLock { $0 += 1 }
                return true
            }
        ))

        XCTAssertEqual(commitCount.withLock { $0 }, 1)
        XCTAssertEqual(connection.closeCount, 0)
        let claimedActions = registry.revoke(endpointId: "endpoint-E", beforeClaim: {})
        XCTAssertEqual(claimedActions.count, 1)
        execute(claimedActions)
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E", beforeClaim: {}).isEmpty)
        XCTAssertEqual(connection.closeCount, 1)
    }

    func testCommitBeforeRevokeRemovesTrustBeforeClaimingConnection() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let trustedEndpoints = LockedValue(Set<String>())
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        assertRegistered(registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction,
            beforeRegister: {
                trustedEndpoints.withLock { _ = $0.insert("endpoint-E") }
                return true
            }
        ))
        let claimedActions = registry.revoke(
            endpointId: "endpoint-E",
            beforeClaim: {
                trustedEndpoints.withLock { _ = $0.remove("endpoint-E") }
            }
        )

        XCTAssertFalse(trustedEndpoints.withLock { $0.contains("endpoint-E") })
        XCTAssertEqual(claimedActions.count, 1)
        execute(claimedActions)
        XCTAssertEqual(connection.closeCount, 1)
    }

    func testRevokeBeforeCommitRejectsWithoutWritingTrust() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let trustedEndpoints = LockedValue(Set<String>())
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        XCTAssertTrue(registry.revoke(
            endpointId: "endpoint-E",
            beforeClaim: {
                trustedEndpoints.withLock { _ = $0.remove("endpoint-E") }
            }
        ).isEmpty)
        let result = registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction,
            beforeRegister: {
                trustedEndpoints.withLock { _ = $0.insert("endpoint-E") }
                return true
            }
        )
        executeRejectedClose(result)

        XCTAssertFalse(trustedEndpoints.withLock { $0.contains("endpoint-E") })
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E", beforeClaim: {}).isEmpty)
    }

    func testStopBeforeCommitRejectsWithoutWritingTrust() throws {
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let trustedEndpoints = LockedValue(Set<String>())
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        XCTAssertTrue(registry.stop().isEmpty)
        let result = registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction,
            beforeRegister: {
                trustedEndpoints.withLock { _ = $0.insert("endpoint-E") }
                return true
            }
        )
        executeRejectedClose(result)

        XCTAssertFalse(trustedEndpoints.withLock { $0.contains("endpoint-E") })
        XCTAssertEqual(connection.closeCount, 1)
    }

    func testPersistenceFailureLeavesNoTrustAndNoLiveConnection() async throws {
        let persistenceCount = LockedValue(0)
        let store = MobileBridgeTrustedDeviceStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mobile-bridge-persistence-failure-\(UUID().uuidString).json"),
            persistence: { _, _ in
                persistenceCount.withLock { $0 += 1 }
                throw PersistenceFailure.expected
            }
        )
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: "endpoint-E",
            lifecycle: lifecycle
        ))

        let result = await store.registerPairedIfCurrent(
            endpointId: "endpoint-E",
            label: "Test Phone",
            registry: registry,
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction
        )
        executeRejectedClose(result)
        let isTrusted = await store.isTrusted("endpoint-E")

        XCTAssertEqual(persistenceCount.withLock { $0 }, 1)
        XCTAssertFalse(isTrusted)
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E", beforeClaim: {}).isEmpty)
    }

    func testRevokePersistenceFailurePreservesTrustAndLiveConnection() async throws {
        let endpointId = "endpoint-revoke-failure"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-bridge-revoke-failure-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let device = MobileBridgeTrustedDevice(
            endpointId: endpointId,
            label: "Failure Test Phone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try JSONEncoder().encode([device]).write(to: fileURL, options: .atomic)

        let store = MobileBridgeTrustedDeviceStore(
            fileURL: fileURL,
            persistence: { _, _ in throw PersistenceFailure.expected }
        )
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: endpointId,
            lifecycle: lifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction
        ))

        let result = await store.revokeAndClaimConnections(
            endpointId: endpointId,
            registry: registry
        )
        let remainsTrusted = await store.isTrusted(endpointId)

        XCTAssertNotNil(result.persistenceFailure)
        XCTAssertTrue(result.closeActions.isEmpty)
        XCTAssertTrue(remainsTrusted)
        XCTAssertEqual(connection.closeCount, 0)

        let retainedActions = registry.revoke(endpointId: endpointId)
        XCTAssertEqual(retainedActions.count, 1)
        execute(retainedActions)
        XCTAssertEqual(connection.closeCount, 1)
    }

    func testSuccessfulRevokePersistsRemovalAndClosesLiveConnection() async throws {
        let endpointId = "endpoint-revoke-success"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-bridge-revoke-success-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let device = MobileBridgeTrustedDevice(
            endpointId: endpointId,
            label: "Success Test Phone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try JSONEncoder().encode([device]).write(to: fileURL, options: .atomic)

        let persistedData = LockedValue<Data?>(nil)
        let store = MobileBridgeTrustedDeviceStore(
            fileURL: fileURL,
            persistence: { data, _ in
                persistedData.withLock { $0 = data }
            }
        )
        let registry = MobileBridgeConnectionRegistry()
        let connection = FakeConnection()
        let lifecycle = registry.start()
        let ticket = try XCTUnwrap(registry.beginAdmission(
            endpointId: endpointId,
            lifecycle: lifecycle
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction
        ))

        let result = await store.revokeAndClaimConnections(
            endpointId: endpointId,
            registry: registry
        )
        let remainsTrusted = await store.isTrusted(endpointId)

        XCTAssertNil(result.persistenceFailure)
        XCTAssertFalse(remainsTrusted)
        XCTAssertEqual(result.closeActions.count, 1)
        execute(result.closeActions)
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: endpointId).isEmpty)

        let writtenData = try XCTUnwrap(persistedData.withLock { $0 })
        let persistedDevices = try JSONDecoder().decode(
            [MobileBridgeTrustedDevice].self,
            from: writtenData
        )
        XCTAssertFalse(persistedDevices.contains { $0.endpointId == endpointId })
    }

    func testAnonymousAdmissionsCannotExceedTheListenerResourceBudget() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        var leases: [MobileBridgeConnectionRegistry.PendingAdmissionLease] = []

        for _ in 0 ..< 10 {
            leases.append(try XCTUnwrap(registry.reservePending(lifecycle: lifecycle)))
        }
        XCTAssertNil(
            registry.reservePending(lifecycle: lifecycle),
            "An eleventh unauthenticated peer must not allocate another admission task"
        )

        registry.abandonPending(leases.removeLast())
        let replacement = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        XCTAssertNil(
            registry.reservePending(lifecycle: lifecycle),
            "Replacing an abandoned lease must consume exactly one released slot"
        )

        leases.forEach { registry.abandonPending($0) }
        registry.abandonPending(replacement)
    }

    func testAnonymousAdmissionDeadlineReleasesStalledPreIdentificationCapacityExactlyOnce() async throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        let timedOutLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        var heldLeases: [MobileBridgeConnectionRegistry.PendingAdmissionLease] = []
        for _ in 0 ..< 9 {
            heldLeases.append(try XCTUnwrap(registry.reservePending(lifecycle: lifecycle)))
        }
        XCTAssertNil(registry.reservePending(lifecycle: lifecycle))

        let timeoutClose = FakeConnection()
        let timeoutFired = expectation(description: "stalled anonymous admission timed out")
        let deadline = MobileBridgeListener.startPendingAdmissionDeadline(
            registry: registry,
            lease: timedOutLease,
            timeout: .milliseconds(10)
        ) {
            timeoutClose.closeAction()
            timeoutFired.fulfill()
        }

        await fulfillment(of: [timeoutFired], timeout: 1)
        XCTAssertEqual(timeoutClose.closeCount, 1)
        XCTAssertFalse(
            registry.abandonPending(timedOutLease),
            "Timeout must own and release the stalled anonymous lease exactly once"
        )

        let replacement = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        XCTAssertNil(
            registry.reservePending(lifecycle: lifecycle),
            "A single timeout must release exactly one admission slot"
        )
        deadline.cancel()
        XCTAssertEqual(timeoutClose.closeCount, 1)

        heldLeases.forEach { registry.abandonPending($0) }
        registry.abandonPending(replacement)
    }

    func testIdentifiedAdmissionsLimitEachEndpointWithoutBlockingOtherDevices() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        let firstConnection = FakeConnection()
        let duplicateConnection = FakeConnection()
        let otherConnection = FakeConnection()

        let firstLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let firstTicket = try XCTUnwrap(registry.identifyPending(
            firstLease,
            endpointId: "endpoint-E",
            close: firstConnection.closeAction
        ))

        let duplicateLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        XCTAssertNil(registry.identifyPending(
            duplicateLease,
            endpointId: "endpoint-E",
            close: duplicateConnection.closeAction
        ))
        duplicateConnection.closeAction()

        let otherLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let otherTicket = try XCTUnwrap(registry.identifyPending(
            otherLease,
            endpointId: "endpoint-F",
            close: otherConnection.closeAction
        ))

        XCTAssertEqual(firstConnection.closeCount, 0)
        XCTAssertEqual(duplicateConnection.closeCount, 1)
        XCTAssertEqual(otherConnection.closeCount, 0)

        let firstClose = try XCTUnwrap(registry.abandonAdmission(firstTicket))
        let otherClose = try XCTUnwrap(registry.abandonAdmission(otherTicket))
        firstClose()
        otherClose()
        XCTAssertEqual(firstConnection.closeCount, 1)
        XCTAssertEqual(duplicateConnection.closeCount, 1)
        XCTAssertEqual(otherConnection.closeCount, 1)
    }

    func testExpiredAdmissionReleasesCapacityWithoutRestoringCloseOwnership() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        let expiredConnection = FakeConnection()

        let lease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let ticket = try XCTUnwrap(registry.identifyPending(
            lease,
            endpointId: "endpoint-E",
            close: expiredConnection.closeAction
        ))
        let expiredClose = try XCTUnwrap(registry.expireAdmission(ticket))
        expiredClose()
        XCTAssertEqual(expiredConnection.closeCount, 1)

        let registration = registry.registerIfCurrent(
            connectionID: expiredConnection.connectionID,
            ticket: ticket,
            close: expiredConnection.closeAction
        )
        executeRejectedClose(registration)
        XCTAssertNil(registry.abandonAdmission(ticket))
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E").isEmpty)
        XCTAssertEqual(
            expiredConnection.closeCount,
            1,
            "Every path retaining a stale ticket must share the admission's exactly-once close ownership"
        )

        var replacements: [MobileBridgeConnectionRegistry.PendingAdmissionLease] = []
        for _ in 0 ..< 10 {
            replacements.append(try XCTUnwrap(registry.reservePending(lifecycle: lifecycle)))
        }
        XCTAssertNil(registry.reservePending(lifecycle: lifecycle))
        replacements.forEach { registry.abandonPending($0) }
    }

    func testRegistrationTransfersIdentifiedAdmissionOwnershipToTheLiveConnection() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        let connection = FakeConnection()

        let lease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let ticket = try XCTUnwrap(registry.identifyPending(
            lease,
            endpointId: "endpoint-E",
            close: connection.closeAction
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: connection.connectionID,
            ticket: ticket,
            close: connection.closeAction
        ))

        XCTAssertNil(registry.expireAdmission(ticket))
        XCTAssertNil(registry.abandonAdmission(ticket))
        let revokedActions = registry.revoke(endpointId: "endpoint-E")
        XCTAssertEqual(revokedActions.count, 1)
        execute(revokedActions)
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertTrue(registry.revoke(endpointId: "endpoint-E").isEmpty)
        XCTAssertEqual(connection.closeCount, 1)
    }

    func testStopClaimsOwnedConnectionsAndInvalidatesEveryPendingLease() throws {
        let registry = MobileBridgeConnectionRegistry()
        let stoppedLifecycle = registry.start()
        let anonymousConnection = FakeConnection()
        let pendingConnection = FakeConnection()
        let liveConnection = FakeConnection()

        let anonymousLease = try XCTUnwrap(registry.reservePending(lifecycle: stoppedLifecycle))

        let pendingLease = try XCTUnwrap(registry.reservePending(lifecycle: stoppedLifecycle))
        _ = try XCTUnwrap(registry.identifyPending(
            pendingLease,
            endpointId: "pending-endpoint",
            close: pendingConnection.closeAction
        ))

        let liveLease = try XCTUnwrap(registry.reservePending(lifecycle: stoppedLifecycle))
        let liveTicket = try XCTUnwrap(registry.identifyPending(
            liveLease,
            endpointId: "live-endpoint",
            close: liveConnection.closeAction
        ))
        assertRegistered(registry.registerIfCurrent(
            connectionID: liveConnection.connectionID,
            ticket: liveTicket,
            close: liveConnection.closeAction
        ))

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 2)
        execute(stoppedActions)
        XCTAssertEqual(pendingConnection.closeCount, 1)
        XCTAssertEqual(liveConnection.closeCount, 1)

        XCTAssertNil(registry.identifyPending(
            anonymousLease,
            endpointId: "anonymous-endpoint",
            close: anonymousConnection.closeAction
        ))
        anonymousConnection.closeAction()
        XCTAssertEqual(anonymousConnection.closeCount, 1)
        XCTAssertNil(registry.reservePending(lifecycle: stoppedLifecycle))

        let restartedLifecycle = registry.start()
        let restartedLease = try XCTUnwrap(registry.reservePending(lifecycle: restartedLifecycle))
        registry.abandonPending(restartedLease)
        XCTAssertTrue(registry.stop().isEmpty)
        XCTAssertEqual(pendingConnection.closeCount, 1)
        XCTAssertEqual(liveConnection.closeCount, 1)
    }

    func testStaleListenerLifecycleCannotAcquireOrPromoteAdmissionCapacity() throws {
        let registry = MobileBridgeConnectionRegistry()
        let anonymousConnection = FakeConnection()
        let identifiedConnection = FakeConnection()
        let currentConnection = FakeConnection()
        let staleLifecycle = registry.start()
        let staleLease = try XCTUnwrap(registry.reservePending(lifecycle: staleLifecycle))
        let identifiedLease = try XCTUnwrap(registry.reservePending(lifecycle: staleLifecycle))
        let staleTicket = try XCTUnwrap(registry.identifyPending(
            identifiedLease,
            endpointId: "identified-endpoint",
            close: identifiedConnection.closeAction
        ))

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 1)
        execute(stoppedActions)
        let currentLifecycle = registry.start()

        XCTAssertNil(registry.reservePending(lifecycle: staleLifecycle))
        XCTAssertNil(registry.identifyPending(
            staleLease,
            endpointId: "anonymous-endpoint",
            close: anonymousConnection.closeAction
        ))
        anonymousConnection.closeAction()
        executeRejectedClose(registry.registerIfCurrent(
            connectionID: identifiedConnection.connectionID,
            ticket: staleTicket,
            close: identifiedConnection.closeAction
        ))
        XCTAssertEqual(anonymousConnection.closeCount, 1)
        XCTAssertEqual(identifiedConnection.closeCount, 1)

        let currentLease = try XCTUnwrap(registry.reservePending(lifecycle: currentLifecycle))
        let currentTicket = try XCTUnwrap(registry.identifyPending(
            currentLease,
            endpointId: "endpoint-E",
            close: currentConnection.closeAction
        ))
        let currentClose = try XCTUnwrap(registry.abandonAdmission(currentTicket))
        currentClose()
        XCTAssertEqual(currentConnection.closeCount, 1)
        XCTAssertTrue(registry.stop().isEmpty)
        XCTAssertEqual(identifiedConnection.closeCount, 1)
    }

    func testDistinctEndpointsCannotExceedTheLiveConnectionBudget() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        var liveConnections: [FakeConnection] = []

        for index in 0 ..< 10 {
            let connection = FakeConnection()
            let lease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
            let ticket = try XCTUnwrap(registry.identifyPending(
                lease,
                endpointId: "endpoint-\(index)",
                close: connection.closeAction
            ))
            XCTAssertTrue(assertRegistered(registry.registerIfCurrent(
                connectionID: connection.connectionID,
                ticket: ticket,
                close: connection.closeAction
            )).isEmpty)
            liveConnections.append(connection)
        }

        let overflow = FakeConnection()
        let overflowCommitCount = LockedValue(0)
        let overflowLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let overflowTicket = try XCTUnwrap(registry.identifyPending(
            overflowLease,
            endpointId: "endpoint-overflow",
            close: overflow.closeAction
        ))
        executeRejectedClose(registry.registerIfCurrent(
            connectionID: overflow.connectionID,
            ticket: overflowTicket,
            close: overflow.closeAction,
            beforeRegister: {
                overflowCommitCount.withLock { $0 += 1 }
                return true
            }
        ))

        XCTAssertEqual(overflowCommitCount.withLock { $0 }, 0)
        XCTAssertEqual(overflow.closeCount, 1)
        XCTAssertTrue(liveConnections.allSatisfy { $0.closeCount == 0 })

        var reusablePendingCapacity: [MobileBridgeConnectionRegistry.PendingAdmissionLease] = []
        for _ in 0 ..< 10 {
            reusablePendingCapacity.append(try XCTUnwrap(
                registry.reservePending(lifecycle: lifecycle)
            ))
        }
        XCTAssertNil(registry.reservePending(lifecycle: lifecycle))
        reusablePendingCapacity.forEach { registry.abandonPending($0) }

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 10)
        execute(stoppedActions)
        XCTAssertTrue(liveConnections.allSatisfy { $0.closeCount == 1 })
        XCTAssertEqual(overflow.closeCount, 1)
    }

    func testAuthenticatedReconnectAtCapacitySupersedesOnlyItsPriorConnection() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        var originalConnections: [FakeConnection] = []

        for index in 0 ..< 10 {
            let connection = FakeConnection()
            let lease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
            let ticket = try XCTUnwrap(registry.identifyPending(
                lease,
                endpointId: "endpoint-\(index)",
                close: connection.closeAction
            ))
            XCTAssertTrue(assertRegistered(registry.registerIfCurrent(
                connectionID: connection.connectionID,
                ticket: ticket,
                close: connection.closeAction
            )).isEmpty)
            originalConnections.append(connection)
        }

        let replacement = FakeConnection()
        let commitCount = LockedValue(0)
        let replacementLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let replacementTicket = try XCTUnwrap(registry.identifyPending(
            replacementLease,
            endpointId: "endpoint-0",
            close: replacement.closeAction
        ))
        let superseded = assertRegistered(registry.registerIfCurrent(
            connectionID: replacement.connectionID,
            ticket: replacementTicket,
            close: replacement.closeAction,
            beforeRegister: {
                commitCount.withLock { $0 += 1 }
                return true
            }
        ))

        XCTAssertEqual(commitCount.withLock { $0 }, 1)
        XCTAssertEqual(superseded.count, 1)
        XCTAssertTrue(originalConnections.allSatisfy { $0.closeCount == 0 })
        XCTAssertEqual(replacement.closeCount, 0)

        execute(superseded)
        XCTAssertEqual(originalConnections[0].closeCount, 1)
        XCTAssertTrue(originalConnections.dropFirst().allSatisfy { $0.closeCount == 0 })
        XCTAssertEqual(replacement.closeCount, 0)

        let revokedActions = registry.revoke(endpointId: "endpoint-0")
        XCTAssertEqual(revokedActions.count, 1)
        execute(revokedActions)
        XCTAssertEqual(originalConnections[0].closeCount, 1)
        XCTAssertEqual(replacement.closeCount, 1)

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 9)
        execute(stoppedActions)
        XCTAssertTrue(originalConnections.allSatisfy { $0.closeCount == 1 })
        XCTAssertEqual(replacement.closeCount, 1)
    }

    func testFailedReconnectAtCapacityCannotDisruptTheActiveConnection() throws {
        let registry = MobileBridgeConnectionRegistry()
        let lifecycle = registry.start()
        var originalConnections: [FakeConnection] = []

        for index in 0 ..< 10 {
            let connection = FakeConnection()
            let lease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
            let ticket = try XCTUnwrap(registry.identifyPending(
                lease,
                endpointId: "endpoint-\(index)",
                close: connection.closeAction
            ))
            XCTAssertTrue(assertRegistered(registry.registerIfCurrent(
                connectionID: connection.connectionID,
                ticket: ticket,
                close: connection.closeAction
            )).isEmpty)
            originalConnections.append(connection)
        }

        let failedReplacement = FakeConnection()
        let failedCommitCount = LockedValue(0)
        let replacementLease = try XCTUnwrap(registry.reservePending(lifecycle: lifecycle))
        let replacementTicket = try XCTUnwrap(registry.identifyPending(
            replacementLease,
            endpointId: "endpoint-0",
            close: failedReplacement.closeAction
        ))
        executeRejectedClose(registry.registerIfCurrent(
            connectionID: failedReplacement.connectionID,
            ticket: replacementTicket,
            close: failedReplacement.closeAction,
            beforeRegister: {
                failedCommitCount.withLock { $0 += 1 }
                return false
            }
        ))

        XCTAssertEqual(failedCommitCount.withLock { $0 }, 1)
        XCTAssertEqual(failedReplacement.closeCount, 1)
        XCTAssertTrue(originalConnections.allSatisfy { $0.closeCount == 0 })

        let revokedActions = registry.revoke(endpointId: "endpoint-0")
        XCTAssertEqual(revokedActions.count, 1)
        execute(revokedActions)
        XCTAssertEqual(originalConnections[0].closeCount, 1)
        XCTAssertEqual(failedReplacement.closeCount, 1)

        let stoppedActions = registry.stop()
        XCTAssertEqual(stoppedActions.count, 9)
        execute(stoppedActions)
        XCTAssertTrue(originalConnections.allSatisfy { $0.closeCount == 1 })
        XCTAssertEqual(failedReplacement.closeCount, 1)
    }

    func testLineReaderReassemblesAFrameFromSingleByteReads() async throws {
        let stream = FragmentingRecvStream(
            data: Data("fragmented payload\nnext frame\n".utf8),
            maximumBytesPerRead: 1
        )
        let reader = MobileBridgeStreamLineReader(stream: stream)

        let first = try await reader.nextLine()
        let second = try await reader.nextLine()
        let end = try await reader.nextLine()

        XCTAssertEqual(first, Data("fragmented payload".utf8))
        XCTAssertEqual(second, Data("next frame".utf8))
        XCTAssertNil(end)
    }

    func testLineReaderAcceptsExactlyEightMiBWithoutTruncatingTheFrame() async throws {
        let maximumLineByteCount = 8 * 1024 * 1024
        var framed = Data(repeating: 0x61, count: maximumLineByteCount)
        framed.append(0x0A)
        let reader = MobileBridgeStreamLineReader(stream: FragmentingRecvStream(
            data: framed,
            maximumBytesPerRead: 65_536
        ))

        let receivedLine = try await reader.nextLine()
        let line = try XCTUnwrap(receivedLine)

        XCTAssertEqual(line.count, maximumLineByteCount)
        XCTAssertEqual(line.first, 0x61)
        XCTAssertEqual(line.last, 0x61)
        let end = try await reader.nextLine()
        XCTAssertNil(end)
    }

    func testLineReaderRejectsAFrameOneByteBeyondEightMiB() async throws {
        let maximumLineByteCount = 8 * 1024 * 1024
        var framed = Data(repeating: 0x61, count: maximumLineByteCount + 1)
        framed.append(0x0A)
        let reader = MobileBridgeStreamLineReader(stream: FragmentingRecvStream(
            data: framed,
            maximumBytesPerRead: 65_536
        ))

        do {
            _ = try await reader.nextLine()
            XCTFail("A frame above the bridge's memory bound must be rejected")
        } catch MobileBridgeStreamLineReaderError.frameTooLarge {
            // Expected: an unauthenticated peer cannot grow the framing buffer beyond its cap.
        } catch {
            XCTFail("Expected frameTooLarge, got \(error)")
        }
    }

    func testLineReaderReturnsAnUnterminatedFinalFrameThenStableEOF() async throws {
        let reader = MobileBridgeStreamLineReader(stream: FragmentingRecvStream(
            data: Data("final frame without newline".utf8),
            maximumBytesPerRead: 3
        ))

        let finalFrame = try await reader.nextLine()
        let firstEOF = try await reader.nextLine()
        let secondEOF = try await reader.nextLine()

        XCTAssertEqual(finalFrame, Data("final frame without newline".utf8))
        XCTAssertNil(firstEOF)
        XCTAssertNil(secondEOF)
    }

    func testRelayPumpClosesBothBlockingDirectionsWhenLocalControlReachesEOF() async {
        let phoneParked = expectation(description: "phone read parked")
        let localParked = expectation(description: "local read parked")
        let pumpCompleted = expectation(description: "relay pump completed")
        let phoneSource = ParkingRelayLineSource { phoneParked.fulfill() }
        let localSource = ParkingRelayLineSource { localParked.fulfill() }
        let pipe = ParkingRelayLocalPipe(source: localSource)
        let remoteCloseCount = LockedValue(0)

        let task = Task {
            await MobileBridgeSession.pump(
                reader: ParkingRelayPhoneReader(source: phoneSource),
                writer: RecordingRelayWriter(),
                pipe: pipe,
                closeRemote: {
                    remoteCloseCount.withLock { $0 += 1 }
                    phoneSource.finish()
                }
            )
            pumpCompleted.fulfill()
        }

        await fulfillment(of: [phoneParked, localParked], timeout: 1)
        localSource.finish()
        await fulfillment(of: [pumpCompleted], timeout: 1)

        // Keep a broken implementation from retaining parked continuations
        // after XCTest records the bounded timeout failure.
        phoneSource.finish()
        pipe.forceUnblockForTest()
        task.cancel()
        _ = await task.result

        XCTAssertEqual(
            remoteCloseCount.withLock { $0 },
            1,
            "Local EOF must close the cancellation-blind phone read exactly once"
        )
        XCTAssertEqual(
            pipe.shutdownCount,
            1,
            "Local EOF cleanup must not race the pump into shutting down its local end twice"
        )
    }

    func testRelayPumpClosesBothBlockingDirectionsWhenPhoneReachesEOF() async {
        let phoneParked = expectation(description: "phone read parked")
        let localParked = expectation(description: "local read parked")
        let pumpCompleted = expectation(description: "relay pump completed")
        let phoneSource = ParkingRelayLineSource { phoneParked.fulfill() }
        let localSource = ParkingRelayLineSource { localParked.fulfill() }
        let pipe = ParkingRelayLocalPipe(source: localSource)
        let remoteCloseCount = LockedValue(0)

        let task = Task {
            await MobileBridgeSession.pump(
                reader: ParkingRelayPhoneReader(source: phoneSource),
                writer: RecordingRelayWriter(),
                pipe: pipe,
                closeRemote: {
                    remoteCloseCount.withLock { $0 += 1 }
                    phoneSource.finish()
                }
            )
            pumpCompleted.fulfill()
        }

        await fulfillment(of: [phoneParked, localParked], timeout: 1)
        phoneSource.finish()
        await fulfillment(of: [pumpCompleted], timeout: 1)

        phoneSource.finish()
        pipe.forceUnblockForTest()
        task.cancel()
        _ = await task.result

        XCTAssertEqual(
            remoteCloseCount.withLock { $0 },
            1,
            "Phone EOF cleanup must not race the pump into closing the remote side twice"
        )
        XCTAssertEqual(
            pipe.shutdownCount,
            1,
            "Phone EOF must unblock the cancellation-blind local read exactly once"
        )
    }

    func testCancellingRelayPumpClosesBothBlockingDirectionsAndCompletes() async {
        let phoneParked = expectation(description: "phone read parked")
        let localParked = expectation(description: "local read parked")
        let pumpCompleted = expectation(description: "cancelled relay pump completed")
        let phoneSource = ParkingRelayLineSource { phoneParked.fulfill() }
        let localSource = ParkingRelayLineSource { localParked.fulfill() }
        let pipe = ParkingRelayLocalPipe(source: localSource)
        let remoteCloseCount = LockedValue(0)

        let task = Task {
            await MobileBridgeSession.pump(
                reader: ParkingRelayPhoneReader(source: phoneSource),
                writer: RecordingRelayWriter(),
                pipe: pipe,
                closeRemote: {
                    remoteCloseCount.withLock { $0 += 1 }
                    phoneSource.finish()
                }
            )
            pumpCompleted.fulfill()
        }

        await fulfillment(of: [phoneParked, localParked], timeout: 1)
        task.cancel()
        await fulfillment(of: [pumpCompleted], timeout: 1)

        phoneSource.finish()
        pipe.forceUnblockForTest()
        task.cancel()
        _ = await task.result

        XCTAssertEqual(
            remoteCloseCount.withLock { $0 },
            1,
            "Cancellation cleanup and normal pump cleanup must share remote close ownership"
        )
        XCTAssertEqual(
            pipe.shutdownCount,
            1,
            "Cancellation cleanup and normal pump cleanup must share local shutdown ownership"
        )
    }
}
