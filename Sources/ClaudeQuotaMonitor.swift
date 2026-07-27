import AppKit
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

/// Watches `~/.claude/tmp/rate-limits.json` (written by the user's cc-settings
/// statusline, if installed) and publishes its parsed contents. Read-only, local-only:
/// no network calls, no telemetry. `snapshot` is `nil` whenever the file is absent or
/// unparseable, which is expected and silent for users who don't run cc-settings.
@MainActor
final class ClaudeQuotaMonitor: ObservableObject {
    static let shared = ClaudeQuotaMonitor()

    @Published private(set) var snapshot: ClaudeQuotaSnapshot?

    private let filePath: String
    private let directoryPath: String
    private let watchQueue = DispatchQueue(label: "com.darkroom.programa.claude-quota-watch")
    private let fileWatcher: FileWatcher
    private var activationObserver: NSObjectProtocol?

    private init() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/tmp/rate-limits.json")
        filePath = fileURL.path
        directoryPath = fileURL.deletingLastPathComponent().path
        fileWatcher = FileWatcher(queue: watchQueue)

        startWatchingFile()
        reloadFromDisk()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureWatchingOnActivate()
        }
    }

    deinit {
        fileWatcher.stop()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Tries to watch the file directly; if it doesn't exist yet, falls back to
    /// watching its parent directory so we notice it appearing later. No polling
    /// timer: everything here is event-driven off `DispatchSource`.
    private func startWatchingFile() {
        let started = fileWatcher.start(
            path: filePath,
            eventMask: [.write, .delete, .rename, .extend]
        ) { [weak self] flags in
            guard let self else { return }
            DispatchQueue.main.async {
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.startWatchingDirectory()
                    return
                }
                self.reloadFromDisk()
            }
        }
        if !started {
            startWatchingDirectory()
        }
    }

    private func startWatchingDirectory() {
        let started = fileWatcher.start(
            path: directoryPath,
            eventMask: [.write, .link, .rename]
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: self.filePath) else { return }
                self.startWatchingFile()
            }
        }
        if started {
            reloadFromDisk()
        }
    }

    /// Cheap, event-driven re-check for the case where `~/.claude/tmp` itself did not
    /// exist yet at startup (so even directory-level watching could not be installed).
    /// This only runs on app activation, never on a timer.
    private func ensureWatchingOnActivate() {
        if FileManager.default.fileExists(atPath: filePath) {
            startWatchingFile()
        } else if FileManager.default.fileExists(atPath: directoryPath) {
            startWatchingDirectory()
        }
        reloadFromDisk()
    }

    /// Reads and parses the file off the main thread, then publishes the result on main.
    private func reloadFromDisk() {
        let path = filePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = FileManager.default.contents(atPath: path)
            let parsed = data.flatMap(ClaudeQuotaSnapshotParser.parse)
            DispatchQueue.main.async {
                self?.snapshot = parsed
            }
        }
    }
}
