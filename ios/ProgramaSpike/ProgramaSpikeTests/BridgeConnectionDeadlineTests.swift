import Foundation
import Testing
@testable import ProgramaSpike

private actor SilentPairingPeer {
    private var readContinuation: CheckedContinuation<Data?, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var closeCount = 0

    func read() async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilReadStarts() async {
        if readContinuation != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func close() {
        closeCount += 1
        readContinuation?.resume(throwing: BridgeError.disconnected)
        readContinuation = nil
    }
}

@Test func initialPairingReplyTimeoutClosesSilentPeerWithoutPendingRequests() async {
    let peer = SilentPairingPeer()
    let connection = BridgeConnection()
    let deadline = InitialPairingReplyDeadline()
    let startedAt = ContinuousClock.now

    do {
        _ = try await deadline.run(
            timeout: .milliseconds(25),
            read: { try await peer.read() },
            abort: { await peer.close() }
        )
        Issue.record("silent pairing peer unexpectedly returned a reply")
    } catch let error as BridgeError {
        guard case .timedOut = error else {
            Issue.record("unexpected bridge error: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    let closeCount = await peer.closeCount
    let pendingRequestCount = await connection.pendingRequestCountForTesting()
    #expect(ContinuousClock.now - startedAt < .seconds(1))
    #expect(closeCount == 1)
    #expect(pendingRequestCount == 0)
}

@Test func cancellingInitialPairingReplyClosesSilentPeerWithoutPendingRequests() async {
    let peer = SilentPairingPeer()
    let connection = BridgeConnection()
    let deadline = InitialPairingReplyDeadline()
    let task = Task {
        try await deadline.run(
            timeout: .seconds(5),
            read: { try await peer.read() },
            abort: { await peer.close() }
        )
    }

    await peer.waitUntilReadStarts()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("cancelled pairing read unexpectedly succeeded")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("unexpected cancellation error: \(error)")
    }

    let closeCount = await peer.closeCount
    let pendingRequestCount = await connection.pendingRequestCountForTesting()
    #expect(closeCount == 1)
    #expect(pendingRequestCount == 0)
}
