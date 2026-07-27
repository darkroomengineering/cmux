import Foundation

/// Manages trusted directories for programa.json command execution.
///
/// Trust is the only thing that lets a `programa.json` entry run without asking first. In an
/// untrusted directory every entry is confirmed, whatever the config file itself says; in a
/// trusted one entries run straight away unless the author marked them `confirm: true`. See
/// `ProgramaConfigExecutor.requiresConfirmation` for the full table.
///
/// (This used to read "`confirm: true` commands skip the dialog", which described the older
/// behaviour where the config file decided whether it got checked at all. It no longer does.)
///
/// Global config (~/.config/programa/programa.json) is always trusted.
///
/// Known limitation: trust is granted per directory (or git repo root) and is not pinned to the
/// file's contents, so a later edit to an already-trusted programa.json runs without re-asking.
/// Tracked in https://github.com/darkroomengineering/programa/issues/188.
final class ProgramaDirectoryTrust {
    static let shared = ProgramaDirectoryTrust()
    static let didChangeNotification = Notification.Name("programa.directoryTrustDidChange")

    private let storePath: String
    private var trustedPaths: Set<String>

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("programa")
        storePath = appSupport.appendingPathComponent("trusted-directories.json").path

        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(atPath: appSupport.path, withIntermediateDirectories: true)
        }

        if let data = fm.contents(atPath: storePath),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            trustedPaths = Set(paths)
        } else {
            trustedPaths = []
        }
    }

    /// Check if a programa.json path is trusted.
    /// Global config is always trusted. For local configs, check the git repo root
    /// (or the programa.json parent directory if not in a git repo).
    func isTrusted(configPath: String, globalConfigPath: String) -> Bool {
        if configPath == globalConfigPath { return true }
        let trustKey = Self.trustKey(for: configPath)
        return trustedPaths.contains(trustKey)
    }

    /// Trust the directory containing a programa.json. If the programa.json is inside a git
    /// repo, trusts the repo root (covering all subdirectories).
    func trust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        trustedPaths.insert(trustKey)
        save()
    }

    /// Remove trust for a directory.
    func revokeTrust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        trustedPaths.remove(trustKey)
        save()
    }

    /// Remove trust by the trust key directly (as stored/displayed in settings).
    func revokeTrustByPath(_ path: String) {
        trustedPaths.remove(path)
        save()
    }

    /// All currently trusted paths.
    var allTrustedPaths: [String] {
        Array(trustedPaths).sorted()
    }

    /// Replace all trusted paths (used by Settings textarea save).
    func replaceAll(with paths: [String]) {
        trustedPaths = Set(paths)
        save()
    }

    /// Clear all trusted directories.
    func clearAll() {
        trustedPaths.removeAll()
        save()
    }

    // MARK: - Private

    /// Resolve the trust key for a programa.json path: git repo root if inside a repo,
    /// otherwise the programa.json's parent directory.
    static func trustKey(for configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if let gitRoot = findGitRoot(from: configDir) {
            return gitRoot
        }
        return configDir
    }

    /// Walk up from `directory` looking for a `.git` directory or file.
    private static func findGitRoot(from directory: String) -> String? {
        let fm = FileManager.default
        var current = directory
        while true {
            let gitPath = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private func save() {
        let sorted = trustedPaths.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
