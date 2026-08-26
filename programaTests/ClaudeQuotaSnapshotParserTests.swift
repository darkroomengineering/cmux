import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// `~/.claude/tmp/rate-limits.json` is written by an external tool (cc-settings) that we do
/// not control, so the parser has to be total: malformed input yields `nil`, never a crash
/// and never a partially-filled snapshot.
///
/// The payload also mixes time units in a single object -- `resets_at` is epoch SECONDS
/// (as a string) while `updated_at` is epoch MILLISECONDS (as a number). Getting that
/// backwards silently renders reset countdowns that are wrong by a factor of 1000, which is
/// exactly the kind of bug that looks fine in review, so it is pinned here.
final class ClaudeQuotaSnapshotParserTests: XCTestCase {
    /// Verbatim shape of a real file observed on disk.
    private func payload(
        fiveHourPercent: String = "17",
        fiveHourResets: String = "\"1785171600\"",
        sevenDayPercent: String = "3",
        sevenDayResets: String = "\"1785664800\"",
        updatedAt: String = "1785168986314"
    ) -> Data {
        Data("""
        {"five_hour":{"used_percentage":\(fiveHourPercent),"resets_at":\(fiveHourResets)},
         "seven_day":{"used_percentage":\(sevenDayPercent),"resets_at":\(sevenDayResets)},
         "updated_at":\(updatedAt)}
        """.utf8)
    }

    func testParsesRealPayload() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.fiveHour.usedPercent, 17)
        XCTAssertEqual(snapshot.sevenDay.usedPercent, 3)
    }

    /// `resets_at` is a string holding epoch SECONDS.
    func testResetsAtIsParsedAsEpochSeconds() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.fiveHour.resetsAt.timeIntervalSince1970, 1_785_171_600, accuracy: 1)
        XCTAssertEqual(snapshot.sevenDay.resetsAt.timeIntervalSince1970, 1_785_664_800, accuracy: 1)
    }

    /// `updated_at` is a number holding epoch MILLISECONDS -- a different unit from
    /// `resets_at` in the same payload.
    func testUpdatedAtIsParsedAsEpochMilliseconds() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, 1_785_168_986.314, accuracy: 1)
    }

    /// The three timestamps come from one file; if units were confused, `updated_at` would
    /// land ~55 years past the reset times instead of just before them.
    func testUpdatedAtPrecedesResetTimes() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertLessThan(snapshot.updatedAt, snapshot.fiveHour.resetsAt)
        XCTAssertLessThan(snapshot.fiveHour.resetsAt, snapshot.sevenDay.resetsAt)
    }

    func testReturnsNilForMalformedJSON() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: Data("{not json".utf8)))
    }

    func testReturnsNilForEmptyData() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: Data()))
    }

    func testReturnsNilWhenAWindowIsMissing() {
        let data = Data("""
        {"five_hour":{"used_percentage":17,"resets_at":"1785171600"},
         "updated_at":1785168986314}
        """.utf8)

        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: data))
    }

    func testReturnsNilWhenPercentageHasWrongType() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourPercent: "\"seventeen\"")))
    }

    func testReturnsNilWhenResetTimestampIsNotNumeric() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourResets: "\"soon\"")))
    }

    func testClampsPercentagesFromTheExternalClaudeCache() throws {
        let snapshot = try XCTUnwrap(
            ClaudeQuotaSnapshotParser.parse(
                data: payload(fiveHourPercent: "-12", sevenDayPercent: "145")
            )
        )

        XCTAssertEqual(snapshot.fiveHour.usedPercent, 0)
        XCTAssertEqual(snapshot.sevenDay.usedPercent, 100)
    }

    func testMapsTheExistingClaudeCacheIntoTheNormalizedProviderModel() {
        let result = ClaudeUsageSnapshotParser.parse(data: payload())

        guard case let .available(snapshot) = result else {
            return XCTFail("A valid Claude cache must be available through the shared provider model, got \(result)")
        }
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.windows.map(\.id), ["claude.five_hour", "claude.seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [17, 3])
        XCTAssertEqual(
            snapshot.windows.map { $0.resetsAt.timeIntervalSince1970 },
            [1_785_171_600, 1_785_664_800]
        )
    }

    func testNormalizedClaudeParserSurfacesMalformedCacheAsAProviderFailure() {
        let result = ClaudeUsageSnapshotParser.parse(data: Data("{not json".utf8))

        guard case let .failed(.claude, message) = result else {
            return XCTFail("A malformed Claude cache must surface an explicit provider error, got \(result)")
        }
        XCTAssertFalse(message.isEmpty)
    }
}

/// Codex account state is intentionally read through the documented app-server RPCs. These
/// fixtures are complete JSON-RPC responses so the parser cannot accidentally become coupled to
/// auth files or to the private ChatGPT usage endpoint.
final class CodexUsageSnapshotParserTests: XCTestCase {
    private func accountResponse(_ account: String) -> Data {
        Data("""
        {"id":1,"result":{"account":\(account),"requiresOpenaiAuth":true}}
        """.utf8)
    }

    private var chatGPTAccountResponse: Data {
        accountResponse(#"{"type":"chatgpt","email":"person@example.com","planType":"pro"}"#)
    }

    private func rateLimitsResponse(_ result: String) -> Data {
        Data("""
        {"id":2,"result":\(result)}
        """.utf8)
    }

    func testNullAccountIsExplicitlyUnavailable() {
        let result = CodexUsageSnapshotParser.parse(
            accountData: accountResponse("null"),
            rateLimitsData: rateLimitsResponse(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#)
        )

        guard case .unavailable(.codex) = result else {
            return XCTFail("A signed-out app-server account must be reported as unavailable, got \(result)")
        }
    }

    func testParsesPrimaryAndSecondaryWindowsAndClampsBackendPercentages() throws {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":-4,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":124,"windowDurationMins":10080,"resetsAt":1785664800},"rateLimitReachedType":null},"rateLimitsByLimitId":{}}"#
            )
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("Expected an available Codex quota snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.windows.map(\.id), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 100])
        XCTAssertEqual(
            snapshot.windows.map { $0.resetsAt.timeIntervalSince1970 },
            [1_785_171_600, 1_785_664_800]
        )
    }

    func testIncludesNamedPerLimitBucketsWithoutDuplicatingTheAggregateBucket() throws {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785171600},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785171600},"secondary":null},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":35,"windowDurationMins":300,"resetsAt":1785175200},"secondary":null}}}"#
            )
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("Expected per-limit buckets to remain displayable, got \(result)")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["codex.primary", "codex_bengalfox.primary"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["5h", "GPT-5.3-Codex-Spark · 5h"])
    }

    func testAuthenticatedAccountWithNoQuotaWindowsIsExplicitlyUnavailable() {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","primary":null,"secondary":null},"rateLimitsByLimitId":{}}"#
            )
        )

        guard case .unavailable(.codex) = result else {
            return XCTFail("An authenticated account without an authoritative quota must not render invented usage, got \(result)")
        }
    }

    func testMalformedOrPartialRPCResponsesBecomeFailuresInsteadOfCrashes() {
        let malformedAccount = CodexUsageSnapshotParser.parse(
            accountData: Data("{not json".utf8),
            rateLimitsData: rateLimitsResponse(#"{"rateLimits":null}"#)
        )
        let missingReset = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":null}}"#
            )
        )

        for result in [malformedAccount, missingReset] {
            guard case let .failed(.codex, message) = result else {
                return XCTFail("Malformed or partial authoritative responses must surface a Codex error, got \(result)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }
}

private actor CountingProviderUsageFetcher: ProviderUsageFetching {
    nonisolated let provider: ProviderUsageProvider
    private let result: ProviderUsageResult
    private(set) var callCount = 0

    init(provider: ProviderUsageProvider, result: ProviderUsageResult) {
        self.provider = provider
        self.result = result
    }

    func fetch() async -> ProviderUsageResult {
        callCount += 1
        return result
    }
}

private actor ControllableProviderUsageFetcher: ProviderUsageFetching {
    nonisolated let provider: ProviderUsageProvider
    private var nextCallID = 0
    private var continuations: [Int: CheckedContinuation<ProviderUsageResult, Never>] = [:]
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(provider: ProviderUsageProvider) {
        self.provider = provider
    }

    func fetch() async -> ProviderUsageResult {
        return await withCheckedContinuation { continuation in
            let callID = nextCallID
            nextCallID += 1
            continuations[callID] = continuation
            resumeSatisfiedCallWaiters()
        }
    }

    func waitUntilCallCount(_ count: Int) async {
        guard nextCallID < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func complete(callID: Int, with result: ProviderUsageResult) {
        continuations.removeValue(forKey: callID)?.resume(returning: result)
    }

    private func resumeSatisfiedCallWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if nextCallID >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        callWaiters = pending
    }
}

private actor CancellationObservingProviderUsageFetcher: ProviderUsageFetching {
    nonisolated let provider: ProviderUsageProvider
    private var hasStarted = false
    private var observedCancellation = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: ProviderUsageProvider) {
        self.provider = provider
    }

    func fetch() async -> ProviderUsageResult {
        hasStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        do {
            try await Task.sleep(for: .seconds(60))
            return .failed(provider, "Fetcher unexpectedly completed without cancellation")
        } catch {
            observedCancellation = Task.isCancelled
            cancellationWaiters.forEach { $0.resume() }
            cancellationWaiters.removeAll()
            return .unavailable(provider)
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationIsObserved() async {
        guard !observedCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }
}

@MainActor
final class ProviderUsageStoreTests: XCTestCase {
    func testConstructionDoesNoProviderWorkAndEachExplicitRefreshFetchesOnce() async {
        let claude = CountingProviderUsageFetcher(
            provider: .claude,
            result: .unavailable(.claude)
        )
        let codex = CountingProviderUsageFetcher(
            provider: .codex,
            result: .unavailable(.codex)
        )
        let store = ProviderUsageStore(fetchers: [claude, codex])

        let initialClaudeCallCount = await claude.callCount
        let initialCodexCallCount = await codex.callCount
        XCTAssertEqual(initialClaudeCallCount, 0)
        XCTAssertEqual(initialCodexCallCount, 0)
        XCTAssertTrue(store.results.isEmpty)

        await store.refresh()

        let firstClaudeCallCount = await claude.callCount
        let firstCodexCallCount = await codex.callCount
        XCTAssertEqual(firstClaudeCallCount, 1)
        XCTAssertEqual(firstCodexCallCount, 1)

        await store.refresh()

        let secondClaudeCallCount = await claude.callCount
        let secondCodexCallCount = await codex.callCount
        XCTAssertEqual(secondClaudeCallCount, 2)
        XCTAssertEqual(secondCodexCallCount, 2)
    }

    func testRefreshPublishesStableProviderOrderAndDeduplicatesByProvider() async {
        let codex = CountingProviderUsageFetcher(
            provider: .codex,
            result: .failed(.codex, "first Codex result")
        )
        let firstClaude = CountingProviderUsageFetcher(
            provider: .claude,
            result: .failed(.claude, "stale Claude result")
        )
        let lastClaude = CountingProviderUsageFetcher(
            provider: .claude,
            result: .unavailable(.claude)
        )
        let store = ProviderUsageStore(fetchers: [codex, firstClaude, lastClaude])

        await store.refresh()

        XCTAssertEqual(store.results.map(\.provider), [.claude, .codex])
        guard case .unavailable(.claude) = store.results.first else {
            return XCTFail("The last result for a duplicate provider must win within one refresh")
        }
    }

    func testOlderRefreshCannotOverwriteANewerGeneration() async {
        let fetcher = ControllableProviderUsageFetcher(provider: .codex)
        let store = ProviderUsageStore(fetchers: [fetcher])

        let olderRefresh = Task { await store.refresh() }
        await fetcher.waitUntilCallCount(1)
        let newerRefresh = Task { await store.refresh() }
        await fetcher.waitUntilCallCount(2)

        await fetcher.complete(callID: 1, with: .unavailable(.codex))
        await newerRefresh.value
        await fetcher.complete(callID: 0, with: .failed(.codex, "stale failure"))
        await olderRefresh.value

        XCTAssertFalse(store.isRefreshing)
        guard case .unavailable(.codex) = store.results.first else {
            return XCTFail("A late completion from an older refresh must not overwrite newer provider state")
        }
    }

    func testCancellingRefreshStopsProviderWorkWithoutPublishingItsCancellationResult() async {
        let fetcher = CancellationObservingProviderUsageFetcher(provider: .codex)
        let store = ProviderUsageStore(fetchers: [fetcher])

        let refresh = Task { await store.refresh() }
        await fetcher.waitUntilStarted()
        XCTAssertTrue(store.isRefreshing)

        store.cancelRefresh()
        await fetcher.waitUntilCancellationIsObserved()
        await refresh.value

        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(
            store.results.isEmpty,
            "A provider result produced while unwinding cancellation must not become visible after the popover closes"
        )
    }
}

final class SidebarQuotaPresentationTests: XCTestCase {
    func testUnavailableProviderRemainsVisibleBesideAnotherProvidersUsage() {
        let claude = ProviderUsageSnapshot(
            provider: .claude,
            windows: [
                ProviderUsageWindow(
                    id: "claude.five_hour",
                    label: "5h",
                    usedPercent: 17,
                    resetsAt: Date(timeIntervalSince1970: 1_785_171_600)
                ),
            ]
        )

        let presentation = SidebarQuotaPresentation(
            results: [.available(claude), .unavailable(.codex)]
        )

        XCTAssertEqual(presentation.availableSnapshots.map(\.provider), [.claude])
        XCTAssertEqual(presentation.unavailableProviders, [.codex])
        XCTAssertTrue(presentation.failures.isEmpty)
    }
}
