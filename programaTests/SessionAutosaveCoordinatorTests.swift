import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Drives `SessionAutosaveCoordinator` directly with fake injected dependencies to exercise the
/// stateful orchestration (timer/debounce/deferred-retry behaviour) that GitHub issue #187's
/// extraction out of `AppDelegate` makes testable for the first time. See
/// `SessionPersistenceTests` for the pure static helpers this coordinator also exposes.
final class SessionAutosaveCoordinatorTests: XCTestCase {
    private static let fakeSnapshot = AppSessionSnapshot(
        version: SessionSnapshotSchema.currentVersion,
        createdAt: 0,
        windows: [],
        cleanShutdown: false
    )

    @MainActor
    func testAutosaveTickDefersDuringTypingQuietPeriodInsteadOfSaving() {
        var snapshotCallCount = 0
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.quiet-period"),
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return Self.fakeSnapshot
            },
            saveSnapshot: { _, _ in
                saveCallCount += 1
                return true
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        coordinator.recordTypingActivity()
        coordinator.runSessionAutosaveTick(source: "test")

        XCTAssertEqual(
            snapshotCallCount,
            0,
            "a tick during the typing quiet period should defer before ever building a snapshot"
        )
        XCTAssertEqual(
            saveCallCount,
            0,
            "a tick during the typing quiet period should defer rather than save"
        )
    }

    @MainActor
    func testDeferredAutosaveRetryIsScheduledOnceNotRepeatedlyPerQuietPeriod() {
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.deferred-retry"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _ in
                saveCallCount += 1
                return true
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        coordinator.recordTypingActivity()
        // Two ticks land back-to-back inside the same quiet period. Only one deferred retry
        // should ever be scheduled; the second call must not queue a duplicate.
        coordinator.runSessionAutosaveTick(source: "first")
        coordinator.runSessionAutosaveTick(source: "second")

        let retryFired = expectation(description: "deferred retry executes after the quiet period elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            retryFired.fulfill()
        }
        wait(for: [retryFired], timeout: 3.0)

        XCTAssertEqual(
            saveCallCount,
            1,
            "the deferred retry should fire and save exactly once, not once per queued tick"
        )
    }

    @MainActor
    func testAutosaveTickSkipsWriteWhenFingerprintUnchanged() {
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.fingerprint"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _ in
                saveCallCount += 1
                return true
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        coordinator.runSessionAutosaveTick(source: "first")
        XCTAssertEqual(saveCallCount, 1, "the first tick with no prior fingerprint should save")

        coordinator.runSessionAutosaveTick(source: "second")
        XCTAssertEqual(
            saveCallCount,
            1,
            "a second tick with an unchanged fingerprint should skip the write"
        )
    }

    @MainActor
    func testAutosaveTickDoesNotSaveWhileTerminating() {
        var snapshotCallCount = 0
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.terminating"),
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return Self.fakeSnapshot
            },
            saveSnapshot: { _, _ in
                saveCallCount += 1
                return true
            },
            isTerminating: { true },
            isRunningUnderXCTest: { true }
        )

        coordinator.runSessionAutosaveTick(source: "terminating")

        XCTAssertEqual(snapshotCallCount, 0, "a tick while terminating should bail before building a snapshot")
        XCTAssertEqual(saveCallCount, 0, "a tick while terminating should never save")
    }

    @MainActor
    func testRequestPromptSaveCoalescesBurstIntoSingleSave() {
        var saveCallCount = 0
        let saved = expectation(description: "prompt save ran")
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.prompt-save"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _ in
                saveCallCount += 1
                saved.fulfill()
                return true
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        // A burst — one request per pane finishing escrow registration during a
        // multi-pane restore — must fold into a single scheduled snapshot build.
        for _ in 0..<5 {
            coordinator.requestPromptSave(source: "test", after: 0.05)
        }

        wait(for: [saved], timeout: 2.0)
        // Let any erroneously-scheduled extra ticks fire before counting.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(
            saveCallCount,
            1,
            "a burst of prompt-save requests must coalesce into exactly one save"
        )
    }
}
