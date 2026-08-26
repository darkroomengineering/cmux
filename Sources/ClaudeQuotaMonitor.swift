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

    func fetch() async -> ProviderUsageResult {
        await Task.detached(priority: .utility) {
            let fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/tmp/rate-limits.json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return .unavailable(.claude)
            }

            do {
                return ClaudeUsageSnapshotParser.parse(data: try Data(contentsOf: fileURL))
            } catch {
                return .failed(
                    .claude,
                    String(
                        localized: "sidebar.usage.error.claudeRead",
                        defaultValue: "Claude usage could not be read."
                    )
                )
            }
        }.value
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

        switch await Self.runAppServer(executableURL: executableURL) {
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

    private enum AppServerOutcome {
        case responses(account: Data, rateLimits: Data)
        case unavailable
        case failed
    }

    private struct CollectedResponses: Sendable {
        var account: Data?
        var rateLimits: Data?
        var exceededCaptureLimit = false
        var readFailed = false
    }

    private static func runAppServer(executableURL: URL) async -> AppServerOutcome {
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
        } catch {
            return .failed
        }

        async let collectedResponses = collectResponses(from: stdout.fileHandleForReading)
        async let drainedStderr: Void = drain(stderr.fileHandleForReading)

        do {
            let input = try requestPayload()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            terminate(process)
            _ = await collectedResponses
            await drainedStderr
            return .failed
        }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            terminate(process)
        }
        let responses = await collectedResponses
        await drainedStderr

        guard !Task.isCancelled,
              !responses.exceededCaptureLimit,
              !responses.readFailed else {
            return .failed
        }
        guard let accountResponse = responses.account,
              let rateLimitsResponse = responses.rateLimits else {
            return process.terminationStatus == 127 ? .unavailable : .failed
        }
        return .responses(account: accountResponse, rateLimits: rateLimitsResponse)
    }

    /// Reads JSONL incrementally and retains only the two bounded response envelopes.
    /// The account envelope is reduced to an authenticated/null marker before storage,
    /// so email and other account identifiers never leave the transient input line.
    private static func collectResponses(from handle: FileHandle) async -> CollectedResponses {
        let maximumCapturedBytes = 1_048_576
        var result = CollectedResponses()
        var line = Data()
        var receivedBytes = 0

        do {
            for try await byte in handle.bytes {
                receivedBytes += 1
                if receivedBytes > maximumCapturedBytes {
                    result.exceededCaptureLimit = true
                    line.removeAll(keepingCapacity: false)
                    continue
                }

                if byte == 0x0A {
                    consumeResponseLine(line, into: &result)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty, !result.exceededCaptureLimit {
                consumeResponseLine(line, into: &result)
            }
        } catch {
            result.readFailed = true
        }
        return result
    }

    private static func consumeResponseLine(_ line: Data, into responses: inout CollectedResponses) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let responseID = rpcID(object["id"]),
              responseID == 1 || responseID == 2 else {
            return
        }

        if responseID == 1 {
            responses.account = sanitizedAccountEnvelope(object)
        } else {
            responses.rateLimits = try? JSONSerialization.data(withJSONObject: object)
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

    private static func requestPayload() throws -> Data {
        let messages: [[String: Any]] = [
            [
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
            ],
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
        let graceDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.25)
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
