import Foundation
import Darwin

struct TerminalThemeSelection: Equatable {
    let rawValue: String?
    let light: String?
    let dark: String?
    let sourcePath: String?
}

struct TerminalThemeMutation: Equatable {
    let configURL: URL
    let didChange: Bool
}

/// Owns Programa's managed `theme` block so the app and CLI cannot drift.
///
/// User Ghostty configuration remains untouched. Programa only replaces the block delimited by
/// `managedBlockStart`/`managedBlockEnd` in its Application Support config and preserves every
/// unrelated directive in that file.
struct TerminalThemeStore {
    static let overrideBundleIdentifier = "com.darkroom.programa"
    static let managedBlockStart = "# programa themes start"
    static let managedBlockEnd = "# programa themes end"
    static let reloadNotificationName = "com.darkroom.programa.themes.reload-config"

    private static let managedBlockPattern = #"(?ms)\n?# programa themes start\r?\n(.*?)\r?\n# programa themes end\n?"#

    let fileManager: FileManager
    let managedConfigURL: URL
    let configSearchURLs: [URL]

    init(
        fileManager: FileManager = .default,
        managedConfigURL: URL,
        configSearchURLs: [URL]
    ) {
        self.fileManager = fileManager
        self.managedConfigURL = managedConfigURL
        self.configSearchURLs = configSearchURLs
    }

    static func live(fileManager: FileManager = .default) -> TerminalThemeStore {
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let programaDirectory = applicationSupport
            .appendingPathComponent(overrideBundleIdentifier, isDirectory: true)
        let managedConfigURL = programaDirectory
            .appendingPathComponent("config.ghostty", isDirectory: false)
        let ghosttyDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
        let ghosttyApplicationSupport = applicationSupport
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)

        return TerminalThemeStore(
            fileManager: fileManager,
            managedConfigURL: managedConfigURL,
            configSearchURLs: [
                ghosttyDirectory.appendingPathComponent("config", isDirectory: false),
                ghosttyDirectory.appendingPathComponent("config.ghostty", isDirectory: false),
                ghosttyApplicationSupport.appendingPathComponent("config", isDirectory: false),
                ghosttyApplicationSupport.appendingPathComponent("config.ghostty", isDirectory: false),
                programaDirectory.appendingPathComponent("config", isDirectory: false),
                managedConfigURL,
            ]
        )
    }

    func currentSelection() -> TerminalThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in configSearchURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = Self.lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return Self.parseSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    func managedRawThemeValue() -> String? {
        guard let contents = try? String(contentsOf: managedConfigURL, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: Self.managedBlockPattern),
              let match = regex.matches(
                in: contents,
                range: NSRange(contents.startIndex..<contents.endIndex, in: contents)
              ).last,
              match.numberOfRanges > 1,
              let bodyRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        return Self.lastThemeDirective(in: String(contents[bodyRange]))
    }

    func set(light: String?, dark: String?) throws -> TerminalThemeMutation {
        guard let rawThemeValue = Self.encodedThemeValue(light: light, dark: dark) else {
            return try clear()
        }
        return try set(rawThemeValue: rawThemeValue)
    }

    func set(rawThemeValue: String) throws -> TerminalThemeMutation {
        let trimmedThemeValue = rawThemeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThemeValue.isEmpty else { return try clear() }

        let existingContents = try readOptionalContents(at: managedConfigURL) ?? ""
        let strippedContents = Self.removingManagedBlock(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        \(Self.managedBlockStart)
        theme = \(trimmedThemeValue)
        \(Self.managedBlockEnd)
        """
        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"

        guard nextContents != existingContents else {
            return TerminalThemeMutation(configURL: managedConfigURL, didChange: false)
        }

        try fileManager.createDirectory(
            at: managedConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try nextContents.write(to: managedConfigURL, atomically: true, encoding: .utf8)
        return TerminalThemeMutation(configURL: managedConfigURL, didChange: true)
    }

    func clear() throws -> TerminalThemeMutation {
        guard let existingContents = try readOptionalContents(at: managedConfigURL) else {
            return TerminalThemeMutation(configURL: managedConfigURL, didChange: false)
        }

        let contentsWithoutManagedBlock = Self.removingManagedBlock(from: existingContents)
        guard contentsWithoutManagedBlock != existingContents else {
            return TerminalThemeMutation(configURL: managedConfigURL, didChange: false)
        }

        let strippedContents = contentsWithoutManagedBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: managedConfigURL)
            } catch {
                guard Self.isFileNotFoundError(error) else { throw error }
            }
        } else {
            try strippedContents.appending("\n").write(
                to: managedConfigURL,
                atomically: true,
                encoding: .utf8
            )
        }

        return TerminalThemeMutation(configURL: managedConfigURL, didChange: true)
    }

    static func parseSelection(rawValue: String?, sourcePath: String?) -> TerminalThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return TerminalThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil { fallbackTheme = entry }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil { lightTheme = value }
            case "dark":
                if darkTheme == nil { darkTheme = value }
            default:
                if fallbackTheme == nil { fallbackTheme = value }
            }
        }

        return TerminalThemeSelection(
            rawValue: rawValue,
            light: lightTheme ?? fallbackTheme ?? darkTheme,
            dark: darkTheme ?? fallbackTheme ?? lightTheme,
            sourcePath: sourcePath
        )
    }

    static func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = normalizedThemeName(light)
        let normalizedDark = normalizedThemeName(dark)

        switch (normalizedLight, normalizedDark) {
        case let (lightTheme?, darkTheme?):
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme)"
        case let (nil, darkTheme?):
            return "dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }

    static func requestReload(targetBundleIdentifier: String) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name(reloadNotificationName),
            object: nil,
            userInfo: ["bundleIdentifier": targetBundleIdentifier]
        )
    }

    private static func normalizedThemeName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else {
                continue
            }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { lastValue = value }
        }

        return lastValue
    }

    private static func removingManagedBlock(from contents: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: managedBlockPattern) else {
            return contents
        }
        return regex.stringByReplacingMatches(
            in: contents,
            range: NSRange(contents.startIndex..<contents.endIndex, in: contents),
            withTemplate: ""
        )
    }

    private func readOptionalContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard Self.isFileNotFoundError(error) else { throw error }
            return nil
        }
    }

    private static func isFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }
}
