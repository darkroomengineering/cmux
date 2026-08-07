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

    /// The windows a restore should actually reconstruct. Startup restore already clamps to
    /// `maxWindowsPerSnapshot`; manual `snapshot restore` reads the same archives and must
    /// clamp identically, or a corrupt or hand-edited history file with thousands of windows
    /// freezes the app on the one command you reach for when recovering.
    static func windowsToRestore(
        from snapshot: AppSessionSnapshot,
        limit: Int = SessionPersistencePolicy.maxWindowsPerSnapshot
    ) -> [SessionWindowSnapshot] {
        Array(snapshot.windows.prefix(max(0, limit)))
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

        // Stage the copy beside the destination and swap it in, rather than deleting the
        // existing archive first. Second-resolution filenames mean two launches can land on
        // the same name, and a delete-then-copy that fails midway (full disk) would leave
        // neither the old archive nor the new one -- the exact loss this file exists to
        // prevent. The staging name is hidden and not `.json`, so it never reads back as a
        // history entry if we die before the swap.
        let staging = historyDirectory.appendingPathComponent(
            ".\(filename).staging-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try FileManager.default.copyItem(at: fileURL, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
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

/// Disarms terminal modes that replayed scrollback can leave stuck "on".
///
/// Restored scrollback is a historical transcript, not a live stream. Every
/// `DECSET` in it was meant to be balanced by a `DECRST` from the program that
/// set it — but that program was killed by the relaunch and never got to send
/// one. Replaying those bytes into a fresh terminal therefore re-arms the mode
/// permanently.
///
/// Mouse tracking is the mode where this is visible: with 1003 (any-event
/// motion) and 1006 (SGR encoding) armed and no TUI left to consume the
/// reports, every mouse move is encoded and written to the pty as input. At a
/// bare zsh prompt ZLE swallows the `ESC[<` prefix, so the prompt fills with
/// literal `35;16;54M35;33;53M…` — the symptom seen after an update relaunch.
///
/// These sequences are fed into the terminal parser (never the pty), so the
/// revived shell is undisturbed.
enum TerminalReplayModeReset {
    /// `DECRST` for every mouse tracking mode — X10 (9), VT200/normal (1000),
    /// highlight (1001), button/cell-motion (1002), any-event/all-motion
    /// (1003) — and every mouse report encoding — UTF-8 (1005), SGR (1006),
    /// urxvt (1015), SGR-pixel (1016).
    static let mouseReportingReset =
        "\u{001B}[?9l"
        + "\u{001B}[?1000l"
        + "\u{001B}[?1001l"
        + "\u{001B}[?1002l"
        + "\u{001B}[?1003l"
        + "\u{001B}[?1005l"
        + "\u{001B}[?1006l"
        + "\u{001B}[?1015l"
        + "\u{001B}[?1016l"
        // Focus reporting (1004) is the same failure shape as mouse tracking:
        // left armed by a dead TUI, every focus change injects CSI I / CSI O
        // into the revived shell as input.
        + "\u{001B}[?1004l"

    /// State that makes the grid itself render wrong when a transcript leaves
    /// it armed. Ordered deliberately: leave the alternate screen first, so
    /// everything after it applies to the primary screen the shell is on.
    ///
    /// A window resize clears only one of these. `Terminal.resize()` in ghostty
    /// unconditionally resets the scrolling region, which is why a stuck
    /// `DECSTBM` (tmux's constant companion) heals when you drag the window.
    /// It never touches the active screen key, the wraparound bit, or the
    /// charset — so a shell stranded on the alternate screen, or with autowrap
    /// off, or with G0 left on line-drawing, stays broken through any number of
    /// resizes. That asymmetry is the whole reason this bug looks unfixable to
    /// some people and self-healing to others.
    /// Two sequences here move the cursor, and both are handled deliberately.
    ///
    /// `ESC[?1047l` rather than `ESC[?1049l`: ghostty's 1049-disable branch
    /// calls `restoreCursor()` unconditionally (`Terminal.zig:3022`), and
    /// `restoreCursor` with nothing previously saved homes the cursor to (0,0)
    /// (`Terminal.zig:1100`). Since most restarts involve no alternate screen
    /// at all, emitting 1049l would drop the revived prompt on top of the
    /// restored scrollback every time. 1047's switch is gated on the screen
    /// actually changing (`switchScreen` returns null otherwise,
    /// `Terminal.zig:2891`), so it is a true no-op when we are already on the
    /// primary screen and still rescues a shell stranded on the alternate one.
    ///
    /// `ESC[r` ends with `setCursorPos(1, 1)` (`Terminal.zig:1619`), so the
    /// margin reset is bracketed in DECSC/DECRC. The charset and origin resets
    /// must come BEFORE the DECSC, because DECRC restores both from the save
    /// (`Terminal.zig:1123-1124`) and would otherwise reinstate the bad ones.
    static let layoutStateReset =
        "\u{001B}[?1047l"   // leave the alternate screen if stranded on it
        + "\u{001B}(B"      // G0 back to ASCII (undo line-drawing)
        + "\u{001B})B"      // G1 back to ASCII
        + "\u{001B}[?6l"    // DECOM: origin mode off
        + "\u{001B}7"       // DECSC: save cursor, now with clean charset/origin
        + "\u{001B}[?69l"   // DECLRMM: left/right margin mode off
        + "\u{001B}[r"      // DECSTBM: full screen again (this homes the cursor)
        + "\u{001B}8"       // DECRC: put the cursor back where the replay left it
        + "\u{001B}[?7h"    // DECAWM: autowrap back on
        + "\u{001B}[?25h"   // cursor visible

    /// Everything a replayed transcript can leave armed, in one sequence.
    static let disableSequence = layoutStateReset + mouseReportingReset
}

/// Prepares fallback-restore scrollback text (pre-crash / clean-quit
/// transcript for a session whose child did not survive to be reattached)
/// for injection into a freshly spawned surface's revive-seed path
/// (`TerminalSurface.pendingReviveSeed` / `seedRevivedScrollbackIfPending`),
/// instead of the old temp-file + `PROGRAMA_RESTORE_SCROLLBACK_FILE` +
/// shell-rc-`cat` mechanism this replaces (formerly
/// `SessionScrollbackReplayStore`). A pure text transform now -- no temp
/// files, no environment variables, no shell integration involved -- because
/// the seed path bypasses the pty entirely (`ghostty_surface_process_output`)
/// exactly like the escrow-revive path already does. See
/// `TerminalSurface.createSurface`'s fresh-seed arm for how the result is
/// consumed and why `resetModes: false` is passed there (the mode reset is
/// already baked into this text, below).
enum SessionFreshSpawnScrollbackSeed {
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    /// Returns nil when there is nothing usable to seed (missing, blank, or
    /// only whitespace) -- callers should treat nil as "spawn a plain fresh
    /// terminal, no seed".
    static func preparedText(for scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(scrollback) else { return nil }
        let sanitized = positioningSanitizedText(truncated)
        // Captured on the PRE-sanitization text, not the sanitized result:
        // `positioningSanitizedText` strips every DEC private mode sequence
        // (`ESC[?1003h` and friends are CSI) as width-dependent, which can
        // leave a line with zero escape bytes even though the raw WAL text
        // armed a mode that still needs undoing. See `ansiSafeReplayText`'s
        // doc comment for why the mode reset must fire independently of
        // what survives sanitization.
        return ansiSafeReplayText(sanitized, forceModeReset: truncated.contains(ansiEscape))
    }

    /// Neutralizes width-dependent cursor-positioning escapes before replay.
    ///
    /// `SessionWALStore.readFallbackScrollbackText` (used whenever a session's
    /// child did not survive to be reattached -- e.g. after a reboot, which is
    /// the case this exists for) returns the *raw* PTY byte stream: the exact
    /// bytes the child wrote, unmodified. That stream carries absolute cursor
    /// moves (`ESC[r;cH`), relative moves, erase-line/-screen sequences, and
    /// `\r` overwrite runs (spinners, progress bars) -- all of which are only
    /// meaningful when replayed into a grid of the *exact* width/height they
    /// were captured at. The freshly spawned surface this text is seeded into
    /// is very likely a different width: the window frame has not yet settled
    /// when the seed is applied (see `TerminalSurface
    /// .isSessionRestoreSettling`'s doc comment for that race). Replaying
    /// position-dependent bytes into the wrong width scatters words to the
    /// wrong columns and superimposes distinct rows on top of each other --
    /// and no later resize can repair it, because the position data itself
    /// was wrong relative to the new grid the moment it landed.
    ///
    /// This walks each line as a virtual single-row cell buffer -- `\r`
    /// resets the write column to 0 (a real overwrite, not a clear: shorter
    /// replacement text leaves the tail of a longer previous write in place,
    /// exactly like a real terminal), `\b` moves it back one column, and
    /// erase-line escapes clear cells outright -- rather than trying to
    /// preserve any position-dependent escape verbatim. SGR (`ESC[...m`)
    /// color/attribute state is the one exception: it is width-independent,
    /// so it is tracked as per-cell state DURING the walk (`ReplayCell.sgr`)
    /// rather than stripped -- a later redraw's color correctly overwrites
    /// the color of the frame it overwrites, and a line's color sequences
    /// stay adjacent to the text they actually color instead of all being
    /// hoisted to the front (which would cancel out any balanced
    /// enable/reset pair before a single character was ever colored).
    /// Everything else -- OSC (hyperlink/title) sequences and all other CSI,
    /// including DEC private mode set/reset like `ESC[?1049h` -- is dropped
    /// outright: OSC carries no width dependence but also no value in a
    /// historical transcript, and a partial-match regex risks swallowing the
    /// rest of the line if its terminator was cut off by
    /// `SessionPersistencePolicy.truncatedScrollback`. DEC private modes are
    /// CSI too and are removed the same way, which means the replayed enable
    /// (`ESC[?1003h`) no longer survives to arm anything -- but that does
    /// NOT make `TerminalReplayModeReset.disableSequence` (appended by
    /// `ansiSafeReplayText` below) redundant: the disable list also
    /// neutralizes state that never went through this sanitizer's CSI/OSC
    /// removal in the first place (charset designation like `ESC(0` is a
    /// two-character escape, not CSI, and survives untouched -- exactly what
    /// `layoutStateReset`'s `ESC(B`/`ESC)B` exists to undo), so the reset
    /// must fire independent of whatever the sanitizer left behind. See
    /// `forceModeReset` in `preparedText(for:)`. The clean-quit snapshot path
    /// (`TerminalController.readTerminalTextForSnapshot`) only ever produces
    /// already-rendered rows carrying SGR, so this is a no-op there -- it is
    /// applied unconditionally rather than gated behind a "which path did
    /// this come from" flag.
    private static func positioningSanitizedText(_ text: String) -> String {
        // `split(omittingEmptySubsequences: false)` + `joined` round-trips a
        // trailing newline (and any blank lines) exactly, so no separate
        // trailing-newline bookkeeping is needed here.
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { sanitizedLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func sanitizedLine(_ line: String) -> String {
        // Cheap bypass: the overwhelming majority of lines in a scrollback
        // transcript are plain text with none of the three signals below.
        guard line.contains(where: { $0 == "\u{001B}" || $0 == "\r" || $0 == "\u{8}" }) else {
            return line
        }

        // A trailing `\r` immediately before the line boundary is the CR
        // half of a `\r\n` line ending written by the pty's ONLCR
        // translation, not an overwrite -- there is nothing after it to
        // overwrite with, so treating it as a real cursor move (which would
        // just reset the column to 0 right before the line ends) is
        // harmless either way, but stripping it here keeps the intent
        // explicit and matches the CRLF handling this function has always
        // had.
        var line = line
        while line.hasSuffix("\r") {
            line.removeLast()
        }

        let working = sanitizedWorkingText(line)
        return replayedLine(from: replayTokens(in: working))
    }

    /// Produces a working string safe to tokenize for the cell walk:
    /// erase-line escapes become one of two sentinel control characters
    /// (`U{0}` = erase-to-end-of-line, `U{1}` = erase-entire-line), OSC and
    /// every other CSI are removed outright, and SGR (`ESC[...m`) is left
    /// entirely alone -- `replayTokens(in:)` recognizes it inline instead.
    /// `csiRegex`'s final-byte class deliberately excludes `m` so it never
    /// competes with SGR for the same bytes. The erase-line translation MUST
    /// run before the generic CSI strip, since `ESC[K`/`ESC[2K`/etc. are
    /// themselves valid CSI sequences and would otherwise be deleted before
    /// they could be turned into sentinels.
    private static func sanitizedWorkingText(_ line: String) -> String {
        var text = line
        text = replacingMatches(of: eraseToEndOfLineRegex, in: text, with: "\u{0}")
        text = replacingMatches(of: eraseEntireLineRegex, in: text, with: "\u{1}")
        text = replacingMatches(of: oscRegex, in: text, with: "")
        text = replacingMatches(of: csiRegex, in: text, with: "")
        text = replacingMatches(of: saveRestoreCursorRegex, in: text, with: "")
        return text
    }

    private static func replacingMatches(of regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let nsText = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: replacement
        )
    }

    /// One unit of replay input: either a single plain/control character, or
    /// one whole SGR escape sequence recognized as a unit (never split
    /// character-by-character, so a `\b` immediately after an SGR sequence
    /// -- see `replayedLine` -- can only ever delete a previously-written
    /// plain character, never a byte belonging to the escape itself).
    private enum ReplayToken {
        case char(Character)
        case sgr(String)
    }

    /// Splits `text` into `ReplayToken`s by locating every SGR match and
    /// treating everything between/around them as plain characters. SGR was
    /// deliberately left in place by `sanitizedWorkingText`, so this is the
    /// one point that recognizes it.
    private static func replayTokens(in text: String) -> [ReplayToken] {
        let nsText = text as NSString
        let matches = sgrRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text.map(ReplayToken.char) }

        var tokens: [ReplayToken] = []
        var searchIndex = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if searchIndex < range.lowerBound {
                tokens.append(contentsOf: text[searchIndex..<range.lowerBound].map(ReplayToken.char))
            }
            tokens.append(.sgr(String(text[range])))
            searchIndex = range.upperBound
        }
        if searchIndex < text.endIndex {
            tokens.append(contentsOf: text[searchIndex...].map(ReplayToken.char))
        }
        return tokens
    }

    /// A single replayed grid cell: the character last written there, and
    /// the SGR state active at the moment it was written. Overwriting a cell
    /// replaces both fields together, so a later redraw's color correctly
    /// wins over the frame it overwrites.
    private struct ReplayCell {
        var sgr: String
        var char: Character
    }

    /// Replays a line's tokens (see `replayTokens`) against a virtual
    /// single-row cell buffer, then re-emits it as text with SGR reinserted
    /// only where it actually changes cell-to-cell -- never re-stated on
    /// every cell, and never dropped when it changes back to "no color"
    /// (that transition emits a real `ESC[0m`, not silence, since a later
    /// terminal has no notion of an "empty" SGR state to fall back to). `\r`
    /// and `\b` move the write column without touching cell content -- a
    /// real terminal overwrite, not a clear -- so a shorter redraw correctly
    /// leaves the tail of a longer previous one in place.
    private static func replayedLine(from tokens: [ReplayToken]) -> String {
        var cells: [ReplayCell] = []
        var cursor = 0
        var currentSGR = ""

        for token in tokens {
            switch token {
            case .sgr(let sequence):
                if sequence == "\u{001B}[0m" || sequence == "\u{001B}[m" {
                    currentSGR = ""
                } else {
                    currentSGR += sequence
                }
            case .char(let char):
                switch char {
                case "\r":
                    cursor = 0
                case "\u{8}":
                    cursor = max(0, cursor - 1)
                case "\u{0}":
                    if cursor < cells.count {
                        cells.removeSubrange(cursor..<cells.count)
                    }
                case "\u{1}":
                    cells.removeAll()
                    cursor = 0
                default:
                    let cell = ReplayCell(sgr: currentSGR, char: char)
                    if cursor < cells.count {
                        cells[cursor] = cell
                    } else {
                        if cursor > cells.count {
                            cells.append(contentsOf: repeatElement(ReplayCell(sgr: "", char: " "), count: cursor - cells.count))
                        }
                        cells.append(cell)
                    }
                    cursor += 1
                }
            }
        }

        var output = ""
        var lastEmittedSGR = ""
        for cell in cells {
            if cell.sgr != lastEmittedSGR {
                output += cell.sgr.isEmpty ? ansiReset : cell.sgr
                lastEmittedSGR = cell.sgr
            }
            output.append(cell.char)
        }
        if currentSGR != lastEmittedSGR {
            output += currentSGR.isEmpty ? ansiReset : currentSGR
        }
        return output
    }

    /// `ESC[K` / `ESC[0K`: erase from the cursor to the end of the line.
    private static let eraseToEndOfLineRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[0?K"#)
    }()

    /// `ESC[1K` / `ESC[2K`: erase the whole line, cursor to column 0. (EL1
    /// technically erases only up to the cursor, not the whole line, but a
    /// scrollback replay has no reason to preserve that distinction -- both
    /// forms exist here only so a dead TUI's status-line redraw doesn't leave
    /// stale characters behind.)
    private static let eraseEntireLineRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[[12]K"#)
    }()

    /// Matches SGR (`ESC[...m`, including the bare `ESC[m` shorthand for
    /// reset). Used by `replayTokens(in:)` to recognize SGR as a unit within
    /// otherwise-plain text -- `sanitizedWorkingText` deliberately does not
    /// strip these, and `csiRegex` deliberately excludes them.
    private static let sgrRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[[0-9;]*m"#)
    }()

    /// OSC (`ESC]...`) terminated by BEL or ST (`ESC\`). Requiring the
    /// terminator (rather than matching greedily to end-of-line) means a
    /// truncated/unterminated OSC left behind by
    /// `SessionPersistencePolicy.truncatedScrollback`'s cut simply fails to
    /// match and is left in place for the generic CSI/escape cleanup to
    /// ignore, instead of swallowing the rest of the line.
    private static let oscRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\][^\x07\x1B]*(?:\x07|\x1B\\)"#)
    }()

    /// Generic CSI: `ESC[`, parameter bytes (`0x30`-`0x3F`: digits, `;`,
    /// `:`, `<=>?`), intermediate bytes (`0x20`-`0x2F`), one final byte
    /// (`0x40`-`0x7E`, i.e. `@`-`~`) -- EXCLUDING `m` (`0x6D`), which is SGR
    /// and is deliberately left for `replayTokens(in:)` to recognize inline
    /// rather than being stripped here. Matches every other CSI form --
    /// cursor moves, erase, scroll region, and DEC private mode set/reset
    /// alike -- which is why this must run after the erase-line translation
    /// above has already pulled those out.
    private static let csiRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x6C\x6E-\x7E]"#)
    }()

    /// DECSC/DECRC (`ESC7`/`ESC8`), the two-character escapes not shaped
    /// like CSI or OSC and so not covered by either regex above.
    private static let saveRestoreCursorRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"[78]"#)
    }()

    /// Preserve ANSI color state safely across replay boundaries, disarm any
    /// terminal mode the replayed transcript leaves set (see
    /// `TerminalReplayModeReset`), and guarantee a trailing newline so the
    /// fresh shell's own first prompt lands on its own line below the
    /// replayed text rather than concatenated onto its last line.
    ///
    /// `forceModeReset` exists because `text.contains(ansiEscape)` is no
    /// longer sufficient on its own to decide whether a mode reset is
    /// needed: `positioningSanitizedText` can legitimately reduce a line to
    /// zero escape bytes (every CSI it contained, including DEC private mode
    /// sequences like `ESC[?1003h`, was width-dependent and got stripped),
    /// while the ORIGINAL pre-sanitization text still proves the transcript
    /// could have armed a mode that needs disarming. The reset is cheap and
    /// idempotent, so callers should pass `true` whenever the untouched
    /// source text contained any escape at all, regardless of what survived
    /// sanitization -- see `preparedText(for:)`.
    private static func ansiSafeReplayText(_ text: String, forceModeReset: Bool) -> String {
        guard text.contains(ansiEscape) || forceModeReset else { return ensuringTrailingNewline(text) }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        output += TerminalReplayModeReset.disableSequence
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return ensuringTrailingNewline(output)
    }

    private static func ensuringTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}
