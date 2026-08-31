import CryptoKit
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
/// Trust is pinned to the config's *executable content* at the moment it was approved, not just
/// to the directory: each trusted entry records a SHA-256 digest of the config with JSONC
/// comments/trailing commas stripped and keys canonically sorted, so editing a comment or
/// reformatting the file does not re-prompt, but changing an actual command does. A later pull
/// that changes an already-trusted `programa.json` therefore surfaces `.changed` instead of
/// silently running the new content. See `trustState(configPath:globalConfigPath:)`. Formerly
/// tracked in https://github.com/darkroomengineering/programa/issues/188.
final class ProgramaDirectoryTrust: @unchecked Sendable {
    static let shared = ProgramaDirectoryTrust()
    static let didChangeNotification = Notification.Name("programa.directoryTrustDidChange")

    /// Outcome of comparing a config's current content against what was trusted.
    enum TrustState {
        /// Trusted and, if a digest was recorded, the content still matches it.
        case trusted
        /// Trusted at some point, but the config's executable content has changed since.
        case changed
        /// Never trusted (or the trusted config can no longer be read/digested).
        case untrusted
    }

    /// On-disk shape, version 2. Value is the SHA-256 hex digest of the config's executable
    /// content at approval time, or `nil` for a legacy entry that predates digesting (adopted
    /// silently on first query, see `trustState`).
    private struct TrustStoreV2: Codable {
        var version: Int
        var directories: [String: String?]
    }

    private let storePath: String
    private let stateLock = NSLock()
    private var trustedDirectories: [String: String?]

    private convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("programa")

        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(atPath: appSupport.path, withIntermediateDirectories: true)
        }

        self.init(storePath: appSupport.appendingPathComponent("trusted-directories.json").path)
    }

    /// Testing seam: lets tests point the store at a temp file instead of the real per-user
    /// Application Support store. Production code must always go through `.shared`.
    init(storePath: String) {
        self.storePath = storePath
        self.trustedDirectories = Self.load(fromStorePath: storePath)
    }

    /// Check if a programa.json path is trusted and its content has not changed since approval.
    /// Global config is always trusted. For local configs, check the git repo root
    /// (or the programa.json parent directory if not in a git repo).
    func isTrusted(configPath: String, globalConfigPath: String) -> Bool {
        trustState(configPath: configPath, globalConfigPath: globalConfigPath) == .trusted
    }

    /// Three-state trust query: `.trusted`, `.changed` (trusted before, content differs now), or
    /// `.untrusted`.
    ///
    /// A legacy entry (trusted under the pre-digest scheme, so its stored digest is `nil`) is
    /// adopted silently here: the current digest is computed and persisted with no prompt, then
    /// enforced from then on. A trusted entry whose config can no longer be read or digested
    /// fails closed to `.untrusted` rather than treating an unreadable file as still-trusted.
    func trustState(configPath: String, globalConfigPath: String) -> TrustState {
        if configPath == globalConfigPath { return .trusted }

        let trustKey = Self.trustKey(for: configPath)
        guard let currentDigest = Self.executableDigest(forConfigAt: configPath) else {
            return .untrusted
        }

        stateLock.lock()
        guard let storedDigest = trustedDirectories[trustKey] else {
            stateLock.unlock()
            return .untrusted
        }

        guard let storedDigest else {
            // Legacy entry with no digest -- adopt silently, no prompt.
            trustedDirectories[trustKey] = currentDigest
            saveLocked()
            stateLock.unlock()
            postDidChangeNotification()
            return .trusted
        }

        let result: TrustState = storedDigest == currentDigest ? .trusted : .changed
        stateLock.unlock()
        return result
    }

    /// Trust the directory containing a programa.json. If the programa.json is inside a git
    /// repo, trusts the repo root (covering all subdirectories). Records the config's current
    /// executable-content digest so a later edit to the file is detected.
    func trust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        let digest = Self.executableDigest(forConfigAt: configPath)
        stateLock.lock()
        defer {
            stateLock.unlock()
            postDidChangeNotification()
        }
        // An unreadable config has no digest and must not create a trusted entry.
        trustedDirectories[trustKey] = digest
        saveLocked()
    }

    /// Remove trust for a directory.
    func revokeTrust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        stateLock.lock()
        defer {
            stateLock.unlock()
            postDidChangeNotification()
        }
        trustedDirectories.removeValue(forKey: trustKey)
        saveLocked()
    }

    /// Remove trust by the trust key directly (as stored/displayed in settings).
    func revokeTrustByPath(_ path: String) {
        stateLock.lock()
        defer {
            stateLock.unlock()
            postDidChangeNotification()
        }
        trustedDirectories.removeValue(forKey: path)
        saveLocked()
    }

    /// All currently trusted paths.
    var allTrustedPaths: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(trustedDirectories.keys).sorted()
    }

    /// Replace all trusted paths (used by Settings textarea save and settings-backup restore).
    /// Entries arriving this way carry no digest -- they go through the same silent-adoption
    /// path as a legacy entry the first time their config is queried.
    func replaceAll(with paths: [String]) {
        var replacement: [String: String?] = [:]
        for path in paths {
            // `replacement[path] = nil` would REMOVE the key: on a dictionary with an optional
            // value type, assigning nil through the subscript deletes the entry rather than
            // storing a nil value. `updateValue` is the only way to store "present, no digest".
            replacement.updateValue(nil, forKey: path)
        }
        stateLock.lock()
        trustedDirectories = replacement
        saveLocked()
        stateLock.unlock()
        postDidChangeNotification()
    }

    /// Clear all trusted directories.
    func clearAll() {
        stateLock.lock()
        trustedDirectories.removeAll()
        saveLocked()
        stateLock.unlock()
        postDidChangeNotification()
    }

    // MARK: - Digesting

    /// SHA-256 of the config's executable content: JSONC comments and trailing commas
    /// stripped, then re-serialized canonically with sorted keys, so comment edits and
    /// reformatting do not invalidate trust but a changed command does.
    static func executableDigest(forConfigAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        guard let sanitized = try? JSONCParser.preprocess(data: data) else { return nil }
        let canonical: Data
        if let object = try? JSONSerialization.jsonObject(with: sanitized),
           let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            canonical = encoded
        } else {
            canonical = sanitized
        }
        return Data(SHA256.hash(data: canonical)).map { String(format: "%02x", $0) }.joined()
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

    /// Decode the on-disk store. Tries the versioned object shape first (current format), then
    /// falls back to the flat `[String]` array that is live on every existing user's disk
    /// (mapping each path to a nil/legacy digest). Never crashes and never wipes the file on a
    /// decode error -- an empty result just means "nothing trusted yet".
    private static func load(fromStorePath path: String) -> [String: String?] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [:] }

        if let versioned = try? JSONDecoder().decode(TrustStoreV2.self, from: data) {
            return versioned.directories
        }

        if let paths = try? JSONDecoder().decode([String].self, from: data) {
            var map: [String: String?] = [:]
            for path in paths {
                // Must be `updateValue`, not `map[path] = nil` -- see the note in `replaceAll`.
                // Subscript-assigning nil here would delete every key and silently drop the
                // trust set of every user upgrading from the flat-array format.
                map.updateValue(nil, forKey: path)
            }
            return map
        }

        return [:]
    }

    /// Caller holds `stateLock`; notification is deliberately posted after unlocking so a
    /// synchronous observer can safely query or replace trust without deadlocking this store.
    private func saveLocked() {
        let store = TrustStoreV2(version: 2, directories: trustedDirectories)
        guard let data = try? JSONEncoder().encode(store) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
    }

    private func postDidChangeNotification() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
