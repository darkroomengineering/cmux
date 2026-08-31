import Foundation
import Testing
@testable import ProgramaSpike

private final class PathPollingScenario {
    private(set) var now = ContinuousClock.now
    private(set) var sleepCount = 0
    private var observations: [ObservedPath]

    init(observations: [ObservedPath]) {
        self.observations = observations
    }

    func selectedPath() -> ObservedPath {
        guard observations.count > 1 else { return observations.first ?? .unavailable }
        return observations.removeFirst()
    }

    func sleep(for duration: Duration) async throws {
        sleepCount += 1
        now = now.advanced(by: duration)
    }
}

private actor SleepStartSignal {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Test func selectedPathWaiterReturnsWhenRelayBecomesDirect() async {
    let scenario = PathPollingScenario(
        observations: [.relay(url: "https://relay.example"), .direct]
    )

    let result = await PathClassifier.waitForSelectedPath(
        timeout: .seconds(5),
        now: { scenario.now },
        selectedPath: { scenario.selectedPath() },
        sleep: { try await scenario.sleep(for: $0) }
    )

    #expect(result == .direct)
    #expect(scenario.sleepCount == 1)
}

@Test func selectedPathWaiterReturnsLastRelayAtDeadline() async {
    let relay = ObservedPath.relay(url: "https://relay.example")
    let scenario = PathPollingScenario(observations: [relay])

    let result = await PathClassifier.waitForSelectedPath(
        timeout: .milliseconds(250),
        now: { scenario.now },
        selectedPath: { scenario.selectedPath() },
        sleep: { try await scenario.sleep(for: $0) }
    )

    #expect(result == relay)
    #expect(scenario.sleepCount == 3)
}

@Test func selectedPathWaiterStopsAfterCancelledSleep() async {
    let relay = ObservedPath.relay(url: "https://relay.example")
    let sleepStart = SleepStartSignal()

    let task = Task {
        await PathClassifier.waitForSelectedPath(
            timeout: .seconds(5),
            now: { ContinuousClock.now },
            selectedPath: { relay },
            sleep: { _ in
                await sleepStart.markStarted()
                try await Task.sleep(for: .seconds(60))
            }
        )
    }

    await sleepStart.waitUntilStarted()
    let cancelledAt = ContinuousClock.now
    task.cancel()
    let result = await task.value

    #expect(ContinuousClock.now - cancelledAt < .seconds(1))
    #expect(result == relay)
}
