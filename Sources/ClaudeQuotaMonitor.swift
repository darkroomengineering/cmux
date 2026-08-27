import Combine
import CoreFoundation
import Darwin
import Foundation

/// One rate-limit window ("5h" or "7d") read from `~/.claude/tmp/rate-limits.json`.
struct ClaudeQuotaWindow: Equatable {
    /// Percent of the window's quota already USED (0-100), not remaining.
    let usedPercent: Int
    let resetsAt: Date
}

/// A single point-in-time read of the cc-settings statusline's local rate-limit file.
struct ClaudeQuotaSnapshot: Equatable {
    let fiveHour: ClaudeQuotaWindow
    let sevenDay: ClaudeQuotaWindow
    let updatedAt: Date
}

/// Parses `~/.claude/tmp/rate-limits.json` contents into a `ClaudeQuotaSnapshot`.
///
/// Parsing is total: any missing key, wrong type, or unparseable timestamp yields `nil`
/// rather than throwing or producing a partial/garbage value. The file is written by an
/// external tool (cc-settings) we don't control, so this must never crash on malformed
/// input.
enum ClaudeQuotaSnapshotParser {
    static func parse(data: Data) -> ClaudeQuotaSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard
            let fiveHourRaw = json["five_hour"] as? [String: Any],
            let sevenDayRaw = json["seven_day"] as? [String: Any],
            let fiveHour = parseWindow(fiveHourRaw),
            let sevenDay = parseWindow(sevenDayRaw),
            let updatedAtMillis = json["updated_at"] as? Int
        else {
            return nil
        }

        let updatedAt = Date(timeIntervalSince1970: Double(updatedAtMillis) / 1000)
        return ClaudeQuotaSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt)
    }

    private static func parseWindow(_ raw: [String: Any]) -> ClaudeQuotaWindow? {
        guard
            let usedPercentage = raw["used_percentage"] as? Int,
            let resetsAtString = raw["resets_at"] as? String,
            let resetsAtEpochSeconds = Double(resetsAtString)
        else {
            return nil
        }

        let clampedPercent = min(max(usedPercentage, 0), 100)
        return ClaudeQuotaWindow(
            usedPercent: clampedPercent,
            resetsAt: Date(timeIntervalSince1970: resetsAtEpochSeconds)
        )
    }
}

enum ProviderUsageProvider: Int, CaseIterable, Comparable, Sendable {
    case claude
    case codex

    static func < (lhs: ProviderUsageProvider, rhs: ProviderUsageProvider) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProviderUsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let usedPercent: Int
    let resetsAt: Date
}

enum ProviderUsageDurationLabel {
    static func format(minutes: Int) -> String {
        let value: Int
        let format: String
        if minutes.isMultiple(of: 1_440) {
            value = minutes / 1_440
            format = String(localized: "sidebar.usage.duration.days", defaultValue: "%@d")
        } else if minutes.isMultiple(of: 60) {
            value = minutes / 60
            format = String(localized: "sidebar.usage.duration.hours", defaultValue: "%@h")
        } else {
            value = minutes
            format = String(localized: "sidebar.usage.duration.minutes", defaultValue: "%@m")
        }
        return String.localizedStringWithFormat(format, String(value))
    }
}

struct ProviderUsageSnapshot: Equatable, Sendable {
    let provider: ProviderUsageProvider
    let windows: [ProviderUsageWindow]
}

enum ProviderUsageResult: Equatable, Sendable {
    case available(ProviderUsageSnapshot)
    case unavailable(ProviderUsageProvider)
    case failed(ProviderUsageProvider, String)

    var provider: ProviderUsageProvider {
        switch self {
        case let .available(snapshot):
            snapshot.provider
        case let .unavailable(provider), let .failed(provider, _):
            provider
        }
    }
}

protocol ProviderUsageFetching: Sendable {
    var provider: ProviderUsageProvider { get }
    func fetch() async -> ProviderUsageResult
}

@MainActor
final class ProviderUsageStore: ObservableObject {
    @Published private(set) var results: [ProviderUsageResult] = []
    @Published private(set) var isRefreshing = false

    private let fetchers: [any ProviderUsageFetching]
    private var refreshGeneration = 0
    private var refreshTask: Task<[(Int, ProviderUsageResult)], Never>?

    init(fetchers: [any ProviderUsageFetching]) {
        self.fetchers = fetchers
    }

    convenience init() {
        self.init(fetchers: [ClaudeProviderUsageFetcher(), CodexProviderUsageFetcher()])
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        let fetchers = self.fetchers

        refreshTask?.cancel()
        let task = Task {
            await withTaskGroup(
                of: (Int, ProviderUsageResult).self,
                returning: [(Int, ProviderUsageResult)].self
            ) { group in
                for (index, fetcher) in fetchers.enumerated() {
                    group.addTask {
                        (index, await fetcher.fetch())
                    }
                }

                var collected: [(Int, ProviderUsageResult)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
        }
        refreshTask = task
        let fetchedResults = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        guard generation == refreshGeneration else { return }
        refreshTask = nil
        guard !task.isCancelled else {
            isRefreshing = false
            return
        }

        var resultByProvider: [ProviderUsageProvider: ProviderUsageResult] = [:]
        for (_, result) in fetchedResults.sorted(by: { $0.0 < $1.0 }) {
            resultByProvider[result.provider] = result
        }
        results = ProviderUsageProvider.allCases.compactMap { resultByProvider[$0] }
        isRefreshing = false
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }
}

enum ClaudeUsageSnapshotParser {
    static func parse(data: Data) -> ProviderUsageResult {
        guard let snapshot = ClaudeQuotaSnapshotParser.parse(data: data) else {
            return .failed(
                .claude,
                String(
                    localized: "sidebar.usage.error.claudeInvalid",
                    defaultValue: "Claude usage data is invalid."
                )
            )
        }

        return .available(
            ProviderUsageSnapshot(
                provider: .claude,
                windows: [
                    ProviderUsageWindow(
                        id: "claude.five_hour",
                        label: ProviderUsageDurationLabel.format(minutes: 300),
                        usedPercent: snapshot.fiveHour.usedPercent,
                        resetsAt: snapshot.fiveHour.resetsAt
                    ),
                    ProviderUsageWindow(
                        id: "claude.seven_day",
                        label: ProviderUsageDurationLabel.format(minutes: 10_080),
                        usedPercent: snapshot.sevenDay.usedPercent,
                        resetsAt: snapshot.sevenDay.resetsAt
                    ),
                ]
            )
        )
    }
}

struct ClaudeProviderUsageFetcher: ProviderUsageFetching {
    let provider = ProviderUsageProvider.claude

    private static let maximumCacheBytes = 1_048_576
    private static let maximumAuthResponseBytes = 65_536
    private static let maximumCacheAge: TimeInterval = 3_600

    func fetch() async -> ProviderUsageResult {
        guard let executableURL = Self.resolveClaudeExecutable() else {
            return .unavailable(.claude)
        }
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/tmp/rate-limits.json")
        return await Self.fetch(
            executableURL: executableURL,
            cacheURL: cacheURL,
            timeout: 5,
            now: Date()
        )
    }

    private static func fetch(
        executableURL: URL,
        cacheURL: URL,
        timeout: TimeInterval,
        now: Date
    ) async -> ProviderUsageResult {
        switch await authStatus(executableURL: executableURL, timeout: timeout) {
        case .loggedOut:
            return .unavailable(.claude)
        case .failed:
            return .failed(
                .claude,
                String(
                    localized: "sidebar.usage.error.claudeRead",
                    defaultValue: "Claude usage could not be read."
                )
            )
        case .loggedIn:
            return await fetchCache(fileURL: cacheURL, now: now)
        }
    }

    private static func fetchCache(fileURL: URL, now: Date) async -> ProviderUsageResult {
        await Task.detached(priority: .utility) {
            guard let data = readSafeCache(at: fileURL),
                  let snapshot = ClaudeQuotaSnapshotParser.parse(data: data),
                  snapshot.updatedAt <= now.addingTimeInterval(60),
                  now.timeIntervalSince(snapshot.updatedAt) <= maximumCacheAge else {
                return .unavailable(.claude)
            }
            return ClaudeUsageSnapshotParser.parse(data: data)
        }.value
    }

    private enum AuthStatus {
        case loggedIn
        case loggedOut
        case failed
    }

    private actor BoundedCapture {
        private var data = Data()
        private var isFinished = false
        private var failed = false

        func append(_ byte: UInt8) {
            guard !failed else { return }
            guard data.count < ClaudeProviderUsageFetcher.maximumAuthResponseBytes else {
                data.removeAll(keepingCapacity: false)
                failed = true
                return
            }
            data.append(byte)
        }

        func finish(readFailed: Bool) {
            failed = failed || readFailed
            isFinished = true
        }

        func snapshot() -> (data: Data, isFinished: Bool, failed: Bool) {
            (data, isFinished, failed)
        }
    }

    private static func authStatus(executableURL: URL, timeout: TimeInterval) async -> AuthStatus {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["auth", "status", "--json"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try? stdout.fileHandleForWriting.close()
        } catch {
            return .failed
        }

        let capture = BoundedCapture()
        let reader = Task {
            do {
                for try await byte in stdout.fileHandleForReading.bytes {
                    await capture.append(byte)
                }
                await capture.finish(readFailed: false)
            } catch {
                await capture.finish(readFailed: !Task.isCancelled)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(max(timeout, 0) * 1_000)))
        var snapshot = await capture.snapshot()
        while !snapshot.isFinished, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
            snapshot = await capture.snapshot()
        }

        if process.isRunning {
            terminate(process)
        }
        if !snapshot.isFinished {
            try? stdout.fileHandleForReading.close()
        }
        reader.cancel()
        _ = await reader.value

        guard !Task.isCancelled,
              snapshot.isFinished,
              !snapshot.failed,
              !process.isRunning,
              process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            return .failed
        }
        return loggedIn ? .loggedIn : .loggedOut
    }

    private static func readSafeCache(at url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumCacheBytes else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= maximumCacheBytes else { return nil }
            data.append(buffer, count: count)
        }
        return data
    }

    #if DEBUG
    static func fetchForTesting(
        executableURL: URL,
        cacheURL: URL,
        timeout: TimeInterval,
        now: Date
    ) async -> ProviderUsageResult {
        await fetch(
            executableURL: executableURL,
            cacheURL: cacheURL,
            timeout: timeout,
            now: now
        )
    }
#endif

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func resolveClaudeExecutable() -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/claude",
            "\(home)/.bun/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])

        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

enum CodexUsageSnapshotParser {
    private struct ParsedBucket {
        let limitID: String
        let limitName: String?
        let primary: [String: Any]?
        let secondary: [String: Any]?
    }

    static func parse(accountData: Data, rateLimitsData: Data) -> ProviderUsageResult {
        guard
            let accountEnvelope = jsonObject(accountData),
            accountEnvelope["error"] == nil,
            accountEnvelope.keys.contains("result"),
            let accountResult = accountEnvelope["result"] as? [String: Any],
            accountResult.keys.contains("account")
        else {
            return failure()
        }

        if accountResult["account"] is NSNull {
            return .unavailable(.codex)
        }
        guard accountResult["account"] is [String: Any] else {
            return failure()
        }

        guard
            let rateEnvelope = jsonObject(rateLimitsData),
            rateEnvelope["error"] == nil,
            rateEnvelope.keys.contains("result"),
            let rateResult = rateEnvelope["result"] as? [String: Any],
            rateResult.keys.contains("rateLimits") || rateResult.keys.contains("rateLimitsByLimitId")
        else {
            return failure()
        }

        let byLimit: [String: Any]
        if let rawByLimit = rateResult["rateLimitsByLimitId"] {
            if rawByLimit is NSNull {
                byLimit = [:]
            } else if let parsedByLimit = rawByLimit as? [String: Any] {
                byLimit = parsedByLimit
            } else {
                return failure()
            }
        } else {
            byLimit = [:]
        }

        var windows: [ProviderUsageWindow] = []
        var aggregateLimitID: String?

        if let rawAggregate = rateResult["rateLimits"], !(rawAggregate is NSNull) {
            guard let aggregate = parseBucket(rawAggregate, fallbackLimitID: "codex") else {
                return failure()
            }
            aggregateLimitID = aggregate.limitID
            guard append(bucket: aggregate, isAggregate: true, to: &windows) else {
                return failure()
            }
        } else if let mappedAggregate = byLimit["codex"] {
            guard let aggregate = parseBucket(mappedAggregate, fallbackLimitID: "codex") else {
                return failure()
            }
            aggregateLimitID = aggregate.limitID
            guard append(bucket: aggregate, isAggregate: true, to: &windows) else {
                return failure()
            }
        }

        for limitID in byLimit.keys.sorted() {
            guard let rawBucket = byLimit[limitID],
                  let bucket = parseBucket(rawBucket, fallbackLimitID: limitID) else {
                return failure()
            }
            if limitID == "codex" || bucket.limitID == aggregateLimitID {
                continue
            }
            guard append(bucket: bucket, isAggregate: false, to: &windows) else {
                return failure()
            }
        }

        guard !windows.isEmpty else {
            return .unavailable(.codex)
        }
        return .available(ProviderUsageSnapshot(provider: .codex, windows: windows))
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parseBucket(_ raw: Any, fallbackLimitID: String) -> ParsedBucket? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        let limitID = (dictionary["limitId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLimitID = limitID.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLimitID

        let limitName: String?
        if let rawName = dictionary["limitName"] {
            if rawName is NSNull {
                limitName = nil
            } else if let name = rawName as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                limitName = trimmed.isEmpty ? nil : trimmed
            } else {
                return nil
            }
        } else {
            limitName = nil
        }

        guard
            let primary = optionalWindow(dictionary["primary"]),
            let secondary = optionalWindow(dictionary["secondary"])
        else {
            return nil
        }
        return ParsedBucket(
            limitID: resolvedLimitID,
            limitName: limitName,
            primary: primary,
            secondary: secondary
        )
    }

    /// An outer optional distinguishes an absent/null window from a malformed value.
    private static func optionalWindow(_ raw: Any?) -> [String: Any]?? {
        guard let raw, !(raw is NSNull) else { return .some(nil) }
        guard let window = raw as? [String: Any] else { return nil }
        return .some(window)
    }

    private static func append(
        bucket: ParsedBucket,
        isAggregate: Bool,
        to windows: inout [ProviderUsageWindow]
    ) -> Bool {
        for (name, rawWindow) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
            guard let rawWindow else { continue }
            guard let window = parseWindow(
                rawWindow,
                id: "\(isAggregate ? "codex" : bucket.limitID).\(name)",
                limitName: isAggregate ? nil : (bucket.limitName ?? bucket.limitID)
            ) else {
                return false
            }
            if !windows.contains(where: { $0.id == window.id }) {
                windows.append(window)
            }
        }
        return true
    }

    private static func parseWindow(
        _ raw: [String: Any],
        id: String,
        limitName: String?
    ) -> ProviderUsageWindow? {
        guard
            let usedPercentNumber = finiteNumber(raw["usedPercent"]),
            let durationNumber = finiteNumber(raw["windowDurationMins"]),
            let resetsAt = finiteNumber(raw["resetsAt"])
        else {
            return nil
        }

        let durationMinutes = Int(durationNumber.rounded())
        guard durationMinutes > 0, resetsAt >= 0 else { return nil }
        let duration = ProviderUsageDurationLabel.format(minutes: durationMinutes)
        return ProviderUsageWindow(
            id: id,
            label: limitName.map { "\($0) · \(duration)" } ?? duration,
            usedPercent: min(max(Int(usedPercentNumber.rounded()), 0), 100),
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func failure() -> ProviderUsageResult {
        .failed(
            .codex,
            String(
                localized: "sidebar.usage.error.codexInvalid",
                defaultValue: "Codex returned invalid usage data."
            )
        )
    }
}

struct CodexProviderUsageFetcher: ProviderUsageFetching {
    let provider = ProviderUsageProvider.codex

    func fetch() async -> ProviderUsageResult {
        guard let executableURL = Self.resolveCodexExecutable() else {
            return .unavailable(.codex)
        }

        return await Self.fetch(executableURL: executableURL, timeout: 5)
    }

    private static func fetch(executableURL: URL, timeout: TimeInterval) async -> ProviderUsageResult {
        switch await Self.runAppServer(executableURL: executableURL, timeout: timeout) {
        case let .responses(account, rateLimits):
            return CodexUsageSnapshotParser.parse(accountData: account, rateLimitsData: rateLimits)
        case .unavailable:
            return .unavailable(.codex)
        case .failed:
            return .failed(
                .codex,
                String(
                    localized: "sidebar.usage.error.codexRead",
                    defaultValue: "Codex usage could not be read."
                )
            )
        }
    }

    #if DEBUG
    static func fetchForTesting(executableURL: URL, timeout: TimeInterval) async -> ProviderUsageResult {
        await fetch(executableURL: executableURL, timeout: timeout)
    }
    #endif

    private enum AppServerOutcome {
        case responses(account: Data, rateLimits: Data)
        case unavailable
        case failed
    }

    private enum InitializeState: Equatable, Sendable {
        case pending
        case succeeded
        case failed
    }

    private struct CollectedResponses: Sendable {
        var initializeState = InitializeState.pending
        var account: Data?
        var rateLimits: Data?
        var exceededCaptureLimit = false
        var readFailed = false
        var finished = false
    }

    private actor AppServerResponseInbox {
        private var responses = CollectedResponses()

        func consume(_ line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let responseID = CodexProviderUsageFetcher.rpcID(object["id"]) else {
                return
            }

            switch responseID {
            case 0:
                if object["error"] != nil {
                    responses.initializeState = .failed
                } else if object["result"] is [String: Any] {
                    responses.initializeState = .succeeded
                } else {
                    responses.initializeState = .failed
                }
            case 1 where responses.initializeState == .succeeded:
                responses.account = CodexProviderUsageFetcher.sanitizedAccountEnvelope(object)
            case 2 where responses.initializeState == .succeeded:
                responses.rateLimits = try? JSONSerialization.data(withJSONObject: object)
            default:
                break
            }
        }

        func markExceededCaptureLimit() {
            responses.exceededCaptureLimit = true
        }

        func finish(readFailed: Bool) {
            responses.readFailed = responses.readFailed || readFailed
            responses.finished = true
        }

        func snapshot() -> CollectedResponses {
            responses
        }
    }

    private static func runAppServer(
        executableURL: URL,
        timeout: TimeInterval
    ) async -> AppServerOutcome {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        } catch {
            return .failed
        }

        let inbox = AppServerResponseInbox()
        let responseReader = Task {
            await collectResponses(from: stdout.fileHandleForReading, into: inbox)
        }
        let stderrReader = Task {
            await drain(stderr.fileHandleForReading)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(max(timeout, 0) * 1_000)))
        var outcome = AppServerOutcome.failed

        do {
            try stdin.fileHandleForWriting.write(contentsOf: initializeRequestPayload())

            var responses = await inbox.snapshot()
            while responses.initializeState == .pending,
                  !responses.exceededCaptureLimit,
                  !responses.readFailed,
                  !responses.finished,
                  clock.now < deadline,
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                responses = await inbox.snapshot()
            }

            if responses.initializeState == .succeeded,
               !responses.exceededCaptureLimit,
               !responses.readFailed,
               !Task.isCancelled,
               clock.now < deadline {
                try stdin.fileHandleForWriting.write(contentsOf: usageRequestPayload())

                responses = await inbox.snapshot()
                while (responses.account == nil || responses.rateLimits == nil),
                      !responses.exceededCaptureLimit,
                      !responses.readFailed,
                      clock.now < deadline,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    responses = await inbox.snapshot()
                }

                if let account = responses.account,
                   let rateLimits = responses.rateLimits,
                   !responses.exceededCaptureLimit,
                   !responses.readFailed,
                   !Task.isCancelled {
                    outcome = .responses(account: account, rateLimits: rateLimits)
                }
            }
        } catch {
            outcome = .failed
        }

        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            terminate(process)
        }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        responseReader.cancel()
        stderrReader.cancel()
        _ = await responseReader.value
        _ = await stderrReader.value

        return Task.isCancelled ? .failed : outcome
    }

    /// Reads JSONL incrementally and retains only the two bounded response envelopes.
    /// The account envelope is reduced to an authenticated/null marker before storage,
    /// so email and other account identifiers never leave the transient input line.
    private static func collectResponses(
        from handle: FileHandle,
        into inbox: AppServerResponseInbox
    ) async {
        let maximumCapturedBytes = 1_048_576
        var line = Data()
        var receivedBytes = 0

        do {
            for try await byte in handle.bytes {
                receivedBytes += 1
                if receivedBytes > maximumCapturedBytes {
                    await inbox.markExceededCaptureLimit()
                    break
                }

                if byte == 0x0A {
                    await inbox.consume(line)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty, receivedBytes <= maximumCapturedBytes {
                await inbox.consume(line)
            }
            await inbox.finish(readFailed: false)
        } catch {
            await inbox.finish(readFailed: !Task.isCancelled)
        }
    }

    private static func sanitizedAccountEnvelope(_ envelope: [String: Any]) -> Data? {
        let sanitized: [String: Any]
        if envelope["error"] != nil {
            sanitized = ["id": 1, "error": [String: Any]()]
        } else if let result = envelope["result"] as? [String: Any],
                  result.keys.contains("account") {
            let accountMarker: Any
            if result["account"] is NSNull {
                accountMarker = NSNull()
            } else if result["account"] is [String: Any] {
                accountMarker = [String: Any]()
            } else {
                accountMarker = "invalid"
            }
            sanitized = ["id": 1, "result": ["account": accountMarker]]
        } else {
            sanitized = ["id": 1]
        }
        return try? JSONSerialization.data(withJSONObject: sanitized)
    }

    private static func drain(_ handle: FileHandle) async {
        do {
            for try await _ in handle.bytes {}
        } catch {
            // Stderr is intentionally discarded and never surfaced or stored.
        }
    }

    private static func initializeRequestPayload() throws -> Data {
        var payload = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "programa",
                    "title": "Programa",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                ],
                "capabilities": [String: Any](),
            ],
        ])
        payload.append(0x0A)
        return payload
    }

    private static func usageRequestPayload() throws -> Data {
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [String: Any](),
            ],
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "account/read",
                "params": ["refreshToken": false],
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/rateLimits/read",
                "params": [String: Any](),
            ],
        ]

        var payload = Data()
        for message in messages {
            payload.append(try JSONSerialization.data(withJSONObject: message))
            payload.append(0x0A)
        }
        return payload
    }

    private static func rpcID(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        if let string = raw as? String {
            return Int(string)
        }
        return nil
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.1)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.1)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private static func resolveCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ])

        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
