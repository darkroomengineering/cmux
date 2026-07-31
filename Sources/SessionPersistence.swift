import CoreGraphics
import CryptoKit
import Foundation
import Bonsplit

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum SessionPersistencePolicy {
    static let defaultSidebarWidth: Double = 200
    static let minimumSidebarWidth: Double = 180
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000
    static let maxSnapshotHistoryEntries: Int = 10

    static func sanitizedSidebarWidth(_ candidate: Double?) -> Double {
        let fallback = defaultSidebarWidth
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, minimumSidebarWidth), maximumSidebarWidth)
    }

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SessionRestorePolicy {
    static func isRunningUnderAutomatedTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["PROGRAMA_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("PROGRAMA_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func shouldAttemptRestore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["PROGRAMA_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests(environment: environment) {
            return false
        }

        let extraArgs = arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }

        // Any explicit launch argument is treated as an explicit open intent.
        return extraArgs.isEmpty
    }
}

struct SessionRectSnapshot: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SessionDisplaySnapshot: Codable, Sendable {
    var displayID: UInt32?
    var stableID: String?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
        }
    }
}

struct SessionSidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SessionSidebarSelection
    var width: Double?
}

struct SessionStatusEntrySnapshot: Codable, Sendable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
}

struct SessionLogEntrySnapshot: Codable, Sendable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct SessionProgressSnapshot: Codable, Sendable {
    var value: Double
    var label: String?
}

struct SessionGitBranchSnapshot: Codable, Sendable {
    var branch: String
    var isDirty: Bool
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
}

struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
}

/// Session-restore snapshot for a review panel. Deliberately does NOT persist `files`/
/// `comments`: restoring a review panel re-runs `git diff` fresh (always-correct, simpler than
/// persisting stale diff content), at the cost of comments-in-flight not surviving an app
/// restart -- a known, accepted v1 limitation. See docs/plans/diff-review-panel.md §6 step 8.
/// `sourceSurfaceId` is the OLD (pre-restore) panel id of the reviewed terminal; it is remapped
/// to the newly-restored panel id in a post-restore fixup pass (`Workspace+Persistence.swift`,
/// since the source terminal may live in a pane restored after this one).
struct SessionReviewPanelSnapshot: Codable, Sendable {
    var sourceSurfaceId: UUID
    var mode: String
    var baseBranch: String
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var review: SessionReviewPanelSnapshot?
}

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

struct SessionPaneLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]
    var selectedPanelId: UUID?
}

struct SessionSplitLayoutSnapshot: Codable, Sendable {
    var orientation: SessionSplitOrientation
    var dividerPosition: Double
    var first: SessionWorkspaceLayoutSnapshot
    var second: SessionWorkspaceLayoutSnapshot
}

indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(SessionPaneLayoutSnapshot)
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    var processTitle: String
    var customTitle: String?
    var customDescription: String?
    var customColor: String?
    var isPinned: Bool
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
}

struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
}

struct SessionWindowSnapshot: Codable, Sendable {
    var frame: SessionRectSnapshot?
    var display: SessionDisplaySnapshot?
    var tabManager: SessionTabManagerSnapshot
    var sidebar: SessionSidebarSnapshot
}

struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
    /// `nil` for snapshots written before this field existed -- treat as "unknown", not "unclean".
    var cleanShutdown: Bool?
}

enum SessionPersistenceStore {
    static func load(fileURL: URL? = nil) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(AppSessionSnapshot.self, from: data) else { return nil }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else { return nil }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    @discardableResult
    static func save(_ snapshot: AppSessionSnapshot, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func contentIdentity(for snapshot: AppSessionSnapshot) -> Data? {
        var normalized = snapshot
        normalized.createdAt = 0
        return canonicalContentIdentity(for: normalized)
    }

    static func canonicalContentIdentity<Value: Encodable>(for value: Value) -> Data? {
        guard let data = try? encodedData(value) else { return nil }
        return Data(SHA256.hash(data: data))
    }

    private static func encodedSnapshotData(_ snapshot: AppSessionSnapshot) throws -> Data {
        try encodedData(snapshot)
    }

    private static func encodedData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func defaultSnapshotFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        return resolvedAppSupport
            .appendingPathComponent("programa", isDirectory: true)
            .appendingPathComponent("session-\(sanitizedBundleIdentifier(bundleIdentifier)).json", isDirectory: false)
    }

    static func historyDirectoryURL(fileURL: URL? = nil) -> URL? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        return fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("session-history", isDirectory: true)
    }

    /// Newest-first list of archived snapshot files, or `[]` if none exist yet.
    static func historyFileURLs(fileURL: URL? = nil) -> [URL] {
        guard let historyDirectory = historyDirectoryURL(fileURL: fileURL) else { return [] }
        return historyEntries(in: historyDirectory)
    }

    /// Decodes an archived (or live) snapshot file's bytes without enforcing the current
    /// schema version, so a caller can inspect `version`/`cleanShutdown` on an older file
    /// before deciding whether it is restorable.
    static func decodeSnapshot(from data: Data) -> AppSessionSnapshot? {
        try? JSONDecoder().decode(AppSessionSnapshot.self, from: data)
    }

    /// Archives the current snapshot file into `session-history/` before anything else can
    /// overwrite it, so a launch that clobbers `session-<bundleId>.json` (a cold boot with no
    /// clean shutdown, or an explicit-open-intent launch that skips restore entirely) never
    /// destroys the previous layout for good. Copies rather than moves: the normal same-launch
    /// restore path still reads the live file afterward, unchanged. Best-effort throughout --
    /// every failure mode here must leave launch unaffected.
    @discardableResult
    static func rotateIntoHistory(
        fileURL: URL? = nil,
        now: Date = Date(),
        maxHistoryEntries: Int = SessionPersistencePolicy.maxSnapshotHistoryEntries
    ) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL(),
              let historyDirectory = historyDirectoryURL(fileURL: fileURL),
              let data = try? Data(contentsOf: fileURL) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        if let newestEntry = historyEntries(in: historyDirectory).first,
           let newestData = try? Data(contentsOf: newestEntry),
           newestData == data {
            return false
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modifiedAt = (attributes?[.modificationDate] as? Date) ?? now
        let filename = "\(historyTimestampFormatter.string(from: modifiedAt))-\(sanitizedBundleIdentifier(Bundle.main.bundleIdentifier)).json"
        let destination = historyDirectory.appendingPathComponent(filename, isDirectory: false)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
        } catch {
            return false
        }

        pruneHistory(in: historyDirectory, keeping: maxHistoryEntries)
        return true
    }

    private static func historyEntries(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        // Filenames are `<yyyyMMdd-HHmmss>-<bundleId>.json`; the fixed-width timestamp prefix
        // sorts newest-first lexicographically without needing to parse it back into a Date.
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func pruneHistory(in directory: URL, keeping maxEntries: Int) {
        let entries = historyEntries(in: directory)
        guard entries.count > maxEntries else { return }
        for staleEntry in entries.dropFirst(maxEntries) {
            try? FileManager.default.removeItem(at: staleEntry)
        }
    }

    private static let historyTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func sanitizedBundleIdentifier(_ bundleIdentifier: String?) -> String {
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.darkroom.programa"
        return bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }
}

enum SessionScrollbackReplayStore {
    static let environmentKey = "PROGRAMA_RESTORE_SCROLLBACK_FILE"
    private static let directoryName = "programa-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedScrollback(scrollback) else { return [:] }
        guard let replayFileURL = writeReplayFile(
            contents: replayText,
            tempDirectory: tempDirectory
        ) else {
            return [:]
        }
        return [environmentKey: replayFileURL.path]
    }

    private static func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(scrollback) else { return nil }
        return ansiSafeReplayText(truncated)
    }

    /// Preserve ANSI color state safely across replay boundaries.
    private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
