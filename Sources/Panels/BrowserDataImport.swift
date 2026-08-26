// Extracted from BrowserPanel.swift (nuclear-review N6): the browser data
// import subsystem is self-contained — nothing here references the
// BrowserPanel class.

import Foundation
import Combine
import WebKit
import AppKit
import Network
import CFNetwork
import SQLite3
import CryptoKit
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

fileprivate func dedupedCanonicalURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if seen.insert(canonical).inserted {
            result.append(url)
        }
    }
    return result
}

enum BrowserImportScope: String, CaseIterable, Identifiable {
    case cookiesOnly
    case historyOnly
    case cookiesAndHistory
    case everything

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cookiesOnly:
            return String(localized: "browser.import.scope.cookiesOnly", defaultValue: "Cookies only")
        case .historyOnly:
            return String(localized: "browser.import.scope.historyOnly", defaultValue: "History only")
        case .cookiesAndHistory:
            return String(localized: "browser.import.scope.cookiesAndHistory", defaultValue: "Cookies + history")
        case .everything:
            return String(localized: "browser.import.scope.everything", defaultValue: "Everything")
        }
    }

    var includesCookies: Bool {
        switch self {
        case .cookiesOnly, .cookiesAndHistory, .everything:
            return true
        case .historyOnly:
            return false
        }
    }

    var includesHistory: Bool {
        switch self {
        case .cookiesOnly:
            return false
        case .historyOnly, .cookiesAndHistory, .everything:
            return true
        }
    }

    static func fromSelection(
        includeCookies: Bool,
        includeHistory: Bool,
        includeAdditionalData: Bool
    ) -> BrowserImportScope? {
        if includeAdditionalData {
            return .everything
        }
        guard includeCookies || includeHistory else { return nil }
        if includeCookies && includeHistory {
            return .cookiesAndHistory
        }
        if includeCookies {
            return .cookiesOnly
        }
        return .historyOnly
    }
}

enum BrowserImportEngineFamily: String, Hashable {
    case chromium
    case firefox
    case webkit
}

struct InstalledBrowserProfile: Identifiable, Hashable {
    let displayName: String
    let rootURL: URL
    let isDefault: Bool

    var id: String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct BrowserImportBrowserDescriptor: Hashable {
    let id: String
    let displayName: String
    let family: BrowserImportEngineFamily
    let tier: Int
    let bundleIdentifiers: [String]
    let appNames: [String]
    let dataRootRelativePaths: [String]
    let dataArtifactRelativePaths: [String]
    let supportsDataOnlyDetection: Bool
}

struct InstalledBrowserCandidate: Identifiable, Hashable {
    let descriptor: BrowserImportBrowserDescriptor
    let resolvedFamily: BrowserImportEngineFamily
    let homeDirectoryURL: URL
    let appURL: URL?
    let dataRootURL: URL?
    let profiles: [InstalledBrowserProfile]
    let detectionSignals: [String]
    let detectionScore: Int

    var id: String { descriptor.id }
    var displayName: String { descriptor.displayName }
    var family: BrowserImportEngineFamily { resolvedFamily }
    var profileURLs: [URL] { profiles.map(\.rootURL) }
}

struct BrowserAvailabilityDescriptor {
    let shortKey: String
    let displayName: String
    let bundleIdentifiers: [String]
    let appNames: [String]
}

/// Availability info for `PROGRAMA_DEFAULT_BROWSER` (env var injected at shell
/// spawn, see `TerminalSurface.swift`) and the `app.browsers` socket command
/// (see `TerminalController+System.swift`). Deliberately independent of
/// `InstalledBrowserDetector.allBrowserDescriptors`/`detectInstalledBrowsers`,
/// which drive the browser data-import wizard: adding a browser here (Aside,
/// for instance) must never change what the import wizard offers, and
/// "installed" here means only "the app itself resolves" -- never the
/// wizard's leftover-profile-data scoring in `detectData`.
enum BrowserAvailability {
    /// Bundle id -> short key used by both `PROGRAMA_DEFAULT_BROWSER` and the
    /// `key` field of `app.browsers`. Falls back to the raw bundle id for
    /// anything not listed here.
    static let shortKeysByBundleIdentifier: [String: String] = [
        "com.apple.Safari": "safari",
        "com.google.Chrome": "chrome",
        "org.mozilla.firefox": "firefox",
        "company.thebrowser.Browser": "arc",
        "company.thebrowser.arc": "arc",
        "com.brave.Browser": "brave",
        "com.microsoft.edgemac": "edge",
        "com.microsoft.Edge": "edge",
        "app.zen-browser.zen": "zen",
        "app.zen-browser.Zen": "zen",
        "com.vivaldi.Vivaldi": "vivaldi",
        "com.operasoftware.Opera": "opera",
        "com.operasoftware.OperaGX": "opera-gx",
        "com.kagi.kagimacOS": "orion",
        "com.kagi.kagimacos": "orion",
        "com.kagi.orion": "orion",
        "company.thebrowser.Dia": "dia",
        "company.thebrowser.dia": "dia",
        "ai.perplexity.comet": "comet",
        "one.ablaze.floorp": "floorp",
        "net.waterfox.waterfox": "waterfox",
        "com.feralcat.sigmaos": "sigmaos",
        "com.meetsidekick.Sidekick": "sidekick",
        "com.pushplaylabs.sidekick": "sidekick",
        "net.imput.helium": "helium",
        "com.jadenGeller.Helium": "helium",
        "com.jaden.geller.helium": "helium",
        "com.atlas.browser": "atlas",
        "org.ladybird.Browser": "ladybird",
        "org.serenityos.ladybird": "ladybird",
        "org.chromium.Chromium": "chromium",
        "org.chromium.ungoogled": "ungoogled-chromium",
        "at.studio.AsideBrowser": "aside",
    ]

    static func shortKey(forBundleIdentifier bundleIdentifier: String) -> String {
        shortKeysByBundleIdentifier[bundleIdentifier] ?? bundleIdentifier
    }

    /// Browsers `app.browsers` reports on: mirrored from
    /// `InstalledBrowserDetector.allBrowserDescriptors` (bundle ids and app
    /// names only -- never that list's data-directory paths or scoring), plus
    /// Aside, which the import wizard does not know about.
    static let knownBrowsers: [BrowserAvailabilityDescriptor] = {
        let mirrored = InstalledBrowserDetector.allBrowserDescriptors.map { descriptor in
            BrowserAvailabilityDescriptor(
                shortKey: shortKey(forBundleIdentifier: descriptor.bundleIdentifiers.first ?? descriptor.id),
                displayName: descriptor.displayName,
                bundleIdentifiers: descriptor.bundleIdentifiers,
                appNames: descriptor.appNames
            )
        }
        let aside = BrowserAvailabilityDescriptor(
            shortKey: "aside",
            displayName: "Aside",
            bundleIdentifiers: ["at.studio.AsideBrowser"],
            appNames: ["Aside.app"]
        )
        return mirrored + [aside]
    }()

    struct BrowserStatus {
        let key: String
        let name: String
        let bundleId: String
        let path: String?
        let installed: Bool
        let running: Bool
    }

    /// Resolves every known browser's install/running status. Read-only
    /// (`NSWorkspace` + filesystem lookups); safe off-main.
    static func detectStatuses(
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> [BrowserStatus] {
        var runningByBundleId: [String: NSRunningApplication] = [:]
        for app in runningApplications {
            guard let bundleId = app.bundleIdentifier else { continue }
            runningByBundleId[bundleId] = app
        }
        return knownBrowsers.map { descriptor in
            let resolved = InstalledBrowserDetector.resolveApplicationPresence(
                bundleIdentifiers: descriptor.bundleIdentifiers,
                appNames: descriptor.appNames
            )
            let bundleId = resolved.bundleIdentifier ?? descriptor.bundleIdentifiers.first ?? descriptor.shortKey
            let runningApp = descriptor.bundleIdentifiers.compactMap { runningByBundleId[$0] }.first
                ?? runningByBundleId[bundleId]
            // A running app is authoritative proof of install even when the LS/path
            // lookup misses it (nonstandard install location, mounted DMG, not yet
            // Spotlight-indexed) -- otherwise running=true, installed=false is
            // possible, which contradicts what "installed" means to callers.
            return BrowserStatus(
                key: descriptor.shortKey,
                name: descriptor.displayName,
                bundleId: bundleId,
                path: resolved.url?.path ?? runningApp?.bundleURL?.path,
                installed: resolved.url != nil || runningApp != nil,
                running: runningApp != nil
            )
        }
    }

    /// Short key of the system default browser, resolved the same way for
    /// both `PROGRAMA_DEFAULT_BROWSER` and `app.browsers`' `default` field:
    /// one Launch Services call via `NSWorkspace.urlForApplication(toOpen:)`,
    /// mapped through `shortKeysByBundleIdentifier`.
    static func resolveDefaultBrowser() -> (shortKey: String, bundleIdentifier: String)? {
        guard let exampleURL = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: exampleURL),
              let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
            return nil
        }
        return (shortKey(forBundleIdentifier: bundleIdentifier), bundleIdentifier)
    }
}

enum InstalledBrowserDetector {
    typealias BundleLookup = (String) -> URL?

    static let allBrowserDescriptors: [BrowserImportBrowserDescriptor] = [
        BrowserImportBrowserDescriptor(
            id: "safari",
            displayName: "Safari",
            family: .webkit,
            tier: 1,
            bundleIdentifiers: ["com.apple.Safari"],
            appNames: ["Safari.app"],
            dataRootRelativePaths: ["Library/Safari"],
            dataArtifactRelativePaths: [
                "Library/Safari/History.db",
                "Library/Cookies/Cookies.binarycookies",
            ],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "google-chrome",
            displayName: "Google Chrome",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["com.google.Chrome"],
            appNames: ["Google Chrome.app"],
            dataRootRelativePaths: ["Library/Application Support/Google/Chrome"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "firefox",
            displayName: "Firefox",
            family: .firefox,
            tier: 1,
            bundleIdentifiers: ["org.mozilla.firefox"],
            appNames: ["Firefox.app"],
            dataRootRelativePaths: ["Library/Application Support/Firefox"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "arc",
            displayName: "Arc",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["company.thebrowser.Browser", "company.thebrowser.arc"],
            appNames: ["Arc.app"],
            dataRootRelativePaths: ["Library/Application Support/Arc"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "brave",
            displayName: "Brave",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["com.brave.Browser"],
            appNames: ["Brave Browser.app"],
            dataRootRelativePaths: ["Library/Application Support/BraveSoftware/Brave-Browser"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "microsoft-edge",
            displayName: "Microsoft Edge",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["com.microsoft.edgemac", "com.microsoft.Edge"],
            appNames: ["Microsoft Edge.app"],
            dataRootRelativePaths: ["Library/Application Support/Microsoft Edge"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "zen",
            displayName: "Zen Browser",
            family: .firefox,
            tier: 2,
            bundleIdentifiers: ["app.zen-browser.zen", "app.zen-browser.Zen"],
            appNames: ["Zen Browser.app", "Zen.app"],
            dataRootRelativePaths: ["Library/Application Support/Zen", "Library/Application Support/zen"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "vivaldi",
            displayName: "Vivaldi",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["com.vivaldi.Vivaldi"],
            appNames: ["Vivaldi.app"],
            dataRootRelativePaths: ["Library/Application Support/Vivaldi"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "opera",
            displayName: "Opera",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["com.operasoftware.Opera"],
            appNames: ["Opera.app"],
            dataRootRelativePaths: [
                "Library/Application Support/com.operasoftware.Opera",
                "Library/Application Support/Opera",
            ],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "opera-gx",
            displayName: "Opera GX",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["com.operasoftware.OperaGX"],
            appNames: ["Opera GX.app"],
            dataRootRelativePaths: [
                "Library/Application Support/com.operasoftware.OperaGX",
                "Library/Application Support/Opera GX Stable",
            ],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "orion",
            displayName: "Orion",
            family: .webkit,
            tier: 2,
            bundleIdentifiers: ["com.kagi.kagimacOS", "com.kagi.kagimacos", "com.kagi.orion"],
            appNames: ["Orion.app"],
            dataRootRelativePaths: ["Library/Application Support/Orion"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "dia",
            displayName: "Dia",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["company.thebrowser.Dia", "company.thebrowser.dia"],
            appNames: ["Dia.app"],
            dataRootRelativePaths: ["Library/Application Support/Dia"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "perplexity-comet",
            displayName: "Perplexity Comet",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["ai.perplexity.comet"],
            appNames: ["Perplexity Comet.app", "Comet.app"],
            dataRootRelativePaths: ["Library/Application Support/Comet"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "floorp",
            displayName: "Floorp",
            family: .firefox,
            tier: 3,
            bundleIdentifiers: ["one.ablaze.floorp"],
            appNames: ["Floorp.app"],
            dataRootRelativePaths: ["Library/Application Support/Floorp"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "waterfox",
            displayName: "Waterfox",
            family: .firefox,
            tier: 3,
            bundleIdentifiers: ["net.waterfox.waterfox"],
            appNames: ["Waterfox.app"],
            dataRootRelativePaths: ["Library/Application Support/Waterfox"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "sigmaos",
            displayName: "SigmaOS",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["com.feralcat.sigmaos"],
            appNames: ["SigmaOS.app"],
            dataRootRelativePaths: ["Library/Application Support/SigmaOS"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "sidekick",
            displayName: "Sidekick",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["com.meetsidekick.Sidekick", "com.pushplaylabs.sidekick"],
            appNames: ["Sidekick.app"],
            dataRootRelativePaths: ["Library/Application Support/Sidekick"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "helium",
            displayName: "Helium",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["net.imput.helium", "com.jadenGeller.Helium", "com.jaden.geller.helium"],
            appNames: ["Helium.app"],
            dataRootRelativePaths: [
                "Library/Application Support/net.imput.helium",
                "Library/Application Support/Helium",
            ],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "atlas",
            displayName: "Atlas",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["com.atlas.browser"],
            appNames: ["Atlas.app"],
            dataRootRelativePaths: ["Library/Application Support/Atlas"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "ladybird",
            displayName: "Ladybird",
            family: .webkit,
            tier: 3,
            bundleIdentifiers: ["org.ladybird.Browser", "org.serenityos.ladybird"],
            appNames: ["Ladybird.app"],
            dataRootRelativePaths: ["Library/Application Support/Ladybird"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "chromium",
            displayName: "Chromium",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["org.chromium.Chromium"],
            appNames: ["Chromium.app"],
            dataRootRelativePaths: ["Library/Application Support/Chromium"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "ungoogled-chromium",
            displayName: "Ungoogled Chromium",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["org.chromium.ungoogled"],
            appNames: ["Ungoogled Chromium.app"],
            dataRootRelativePaths: ["Library/Application Support/Chromium"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: false
        ),
    ]

    static func detectInstalledBrowsers(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        bundleLookup: BundleLookup? = nil,
        applicationSearchDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [InstalledBrowserCandidate] {
        let lookup = bundleLookup ?? { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        let appSearchDirectories = applicationSearchDirectories ?? defaultApplicationSearchDirectories(homeDirectoryURL: homeDirectoryURL)

        let candidates = allBrowserDescriptors.compactMap { descriptor -> InstalledBrowserCandidate? in
            let appDetection = detectApplication(
                descriptor: descriptor,
                appSearchDirectories: appSearchDirectories,
                bundleLookup: lookup,
                fileManager: fileManager
            )

            let dataDetection = detectData(
                descriptor: descriptor,
                homeDirectoryURL: homeDirectoryURL,
                appBundleIdentifier: appDetection.bundleIdentifier,
                fileManager: fileManager
            )

            if appDetection.url == nil,
               !descriptor.supportsDataOnlyDetection {
                return nil
            }

            let hasData = dataDetection.dataRootURL != nil || !dataDetection.profiles.isEmpty || !dataDetection.artifactHits.isEmpty
            guard appDetection.url != nil || hasData else {
                return nil
            }

            var score = 0
            if appDetection.url != nil {
                score += 80
            }
            if dataDetection.dataRootURL != nil {
                score += 24
            }
            score += min(24, dataDetection.profiles.count * 6)
            score += min(16, dataDetection.artifactHits.count * 4)

            var signals: [String] = []
            signals.append(contentsOf: appDetection.signals)
            if let root = dataDetection.dataRootURL {
                signals.append("data:\(root.lastPathComponent)")
            }
            if !dataDetection.profiles.isEmpty {
                signals.append("profiles:\(dataDetection.profiles.count)")
            }
            if !dataDetection.artifactHits.isEmpty {
                signals.append(contentsOf: dataDetection.artifactHits.map { "artifact:\($0)" })
            }

            return InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: dataDetection.family,
                homeDirectoryURL: homeDirectoryURL,
                appURL: appDetection.url,
                dataRootURL: dataDetection.dataRootURL,
                profiles: dataDetection.profiles,
                detectionSignals: signals,
                detectionScore: score
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.detectionScore != rhs.detectionScore {
                return lhs.detectionScore > rhs.detectionScore
            }
            if lhs.descriptor.tier != rhs.descriptor.tier {
                return lhs.descriptor.tier < rhs.descriptor.tier
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func summaryText(for browsers: [InstalledBrowserCandidate], limit: Int = 4) -> String {
        guard !browsers.isEmpty else {
            return String(
                localized: "browser.import.detected.none",
                defaultValue: "No supported browsers detected."
            )
        }
        let names = browsers.map(\.displayName)
        if names.count <= limit {
            return String(
                format: String(
                    localized: "browser.import.detected.all",
                    defaultValue: "Detected: %@."
                ),
                names.joined(separator: ", ")
            )
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        let remaining = names.count - limit
        if remaining == 1 {
            return String(
                format: String(
                    localized: "browser.import.detected.more.one",
                    defaultValue: "Detected: %@, +1 more."
                ),
                shown
            )
        }
        return String(
            format: String(
                localized: "browser.import.detected.more.other",
                defaultValue: "Detected: %@, +%ld more."
            ),
            shown,
            remaining
        )
    }

    private static func detectApplication(
        descriptor: BrowserImportBrowserDescriptor,
        appSearchDirectories: [URL],
        bundleLookup: BundleLookup,
        fileManager: FileManager
    ) -> (url: URL?, signals: [String], bundleIdentifier: String?) {
        for knownBundleIdentifier in descriptor.bundleIdentifiers {
            if let appURL = bundleLookup(knownBundleIdentifier) {
                return (appURL, ["bundle:\(knownBundleIdentifier)"], bundleIdentifier(for: appURL) ?? knownBundleIdentifier)
            }
        }

        for appName in descriptor.appNames {
            for directory in appSearchDirectories {
                let appURL = directory.appendingPathComponent(appName, isDirectory: true)
                if fileManager.fileExists(atPath: appURL.path) {
                    return (appURL, ["app:\(appName)"], bundleIdentifier(for: appURL))
                }
            }
        }

        return (nil, [], nil)
    }

    private static func detectData(
        descriptor: BrowserImportBrowserDescriptor,
        homeDirectoryURL: URL,
        appBundleIdentifier: String?,
        fileManager: FileManager
    ) -> (dataRootURL: URL?, family: BrowserImportEngineFamily, profiles: [InstalledBrowserProfile], artifactHits: [String]) {
        var bestRootURL: URL?
        var bestFamily = descriptor.family
        var bestProfiles: [InstalledBrowserProfile] = []
        var bestArtifacts: [String] = []
        let candidateRootPaths = candidateDataRootRelativePaths(
            descriptor: descriptor,
            appBundleIdentifier: appBundleIdentifier
        )

        for relativePath in candidateRootPaths {
            let rootURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }

            let detectedProfiles = detectProfiles(
                descriptor: descriptor,
                rootURL: rootURL,
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )

            let score = scoreProfileDetection(
                family: detectedProfiles.family,
                profiles: detectedProfiles.profiles,
                preferredFamily: descriptor.family
            ) + 8
            let currentScore = scoreProfileDetection(
                family: bestFamily,
                profiles: bestProfiles,
                preferredFamily: descriptor.family
            ) + (bestRootURL == nil ? 0 : 8)
            if score > currentScore {
                bestRootURL = rootURL
                bestFamily = detectedProfiles.family
                bestProfiles = detectedProfiles.profiles
            }
        }

        var artifactHits: [String] = []
        for relativePath in descriptor.dataArtifactRelativePaths {
            let artifactURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: artifactURL.path) {
                artifactHits.append(artifactURL.lastPathComponent)
            }
        }

        if !artifactHits.isEmpty {
            bestArtifacts = artifactHits
            if bestRootURL == nil,
               let rootPath = candidateRootPaths.first {
                let rootURL = homeDirectoryURL.appendingPathComponent(rootPath, isDirectory: true)
                if fileManager.fileExists(atPath: rootURL.path) {
                    bestRootURL = rootURL
                }
            }
        }

        if bestProfiles.isEmpty, let bestRootURL {
            bestProfiles = [
                InstalledBrowserProfile(
                    displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
                    rootURL: bestRootURL,
                    isDefault: true
                )
            ]
        }

        return (
            dataRootURL: bestRootURL,
            family: bestFamily,
            profiles: sortProfiles(dedupedProfiles(bestProfiles)),
            artifactHits: bestArtifacts
        )
    }

    private static func detectProfiles(
        descriptor: BrowserImportBrowserDescriptor,
        rootURL: URL,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> (family: BrowserImportEngineFamily, profiles: [InstalledBrowserProfile]) {
        let candidates: [(BrowserImportEngineFamily, [InstalledBrowserProfile])] = [
            (.chromium, chromiumProfiles(rootURL: rootURL, fileManager: fileManager)),
            (.firefox, firefoxProfiles(rootURL: rootURL, fileManager: fileManager)),
            (.webkit, webKitProfiles(
                descriptor: descriptor,
                rootURL: rootURL,
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )),
        ]

        return candidates.max { lhs, rhs in
            let lhsScore = scoreProfileDetection(
                family: lhs.0,
                profiles: lhs.1,
                preferredFamily: descriptor.family
            )
            let rhsScore = scoreProfileDetection(
                family: rhs.0,
                profiles: rhs.1,
                preferredFamily: descriptor.family
            )
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return lhs.0.rawValue > rhs.0.rawValue
        } ?? (descriptor.family, [])
    }

    private static func bundleIdentifier(for appURL: URL) -> String? {
        Bundle(url: appURL)?.bundleIdentifier
    }

    /// App-presence half of `detectApplication` above, mirrored (not shared
    /// via refactor) for `BrowserAvailability` -- deliberately excludes
    /// `detectData`'s leftover-profile-data scoring below. "Installed" here
    /// means only that the app itself resolves, by bundle identifier first
    /// then by app name across the standard search directories.
    static func resolveApplicationPresence(
        bundleIdentifiers: [String],
        appNames: [String],
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        bundleLookup: BundleLookup? = nil,
        fileManager: FileManager = .default
    ) -> (url: URL?, bundleIdentifier: String?) {
        let lookup = bundleLookup ?? { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        for knownBundleIdentifier in bundleIdentifiers {
            if let appURL = lookup(knownBundleIdentifier) {
                return (appURL, bundleIdentifier(for: appURL) ?? knownBundleIdentifier)
            }
        }
        let searchDirectories = defaultApplicationSearchDirectories(homeDirectoryURL: homeDirectoryURL)
        for appName in appNames {
            for directory in searchDirectories {
                let appURL = directory.appendingPathComponent(appName, isDirectory: true)
                if fileManager.fileExists(atPath: appURL.path) {
                    return (appURL, bundleIdentifier(for: appURL))
                }
            }
        }
        return (nil, nil)
    }

    private static func candidateDataRootRelativePaths(
        descriptor: BrowserImportBrowserDescriptor,
        appBundleIdentifier: String?
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ relativePath: String) {
            if seen.insert(relativePath).inserted {
                result.append(relativePath)
            }
        }

        for relativePath in descriptor.dataRootRelativePaths {
            append(relativePath)
        }

        let bundleIdentifiers = [appBundleIdentifier].compactMap { $0 } + descriptor.bundleIdentifiers
        for bundleIdentifier in bundleIdentifiers {
            append("Library/Application Support/\(bundleIdentifier)")
            append("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/\(bundleIdentifier)")
        }

        return result
    }

    private static func scoreProfileDetection(
        family: BrowserImportEngineFamily,
        profiles: [InstalledBrowserProfile],
        preferredFamily: BrowserImportEngineFamily
    ) -> Int {
        var score = profiles.count * 10
        if family == preferredFamily {
            score += 3
        }
        if profiles.contains(where: \.isDefault) {
            score += 1
        }
        return score
    }

    private static func chromiumProfiles(
        rootURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        let nameMap = chromiumProfileNameMap(rootURL: rootURL)
        var profiles: [InstalledBrowserProfile] = []
        if looksLikeChromiumProfile(rootURL: rootURL, fileManager: fileManager) {
            profiles.append(
                InstalledBrowserProfile(
                    displayName: chromiumProfileDisplayName(
                        directoryName: rootURL.lastPathComponent,
                        nameMap: nameMap,
                        isDefault: true
                    ),
                    rootURL: rootURL,
                    isDefault: true
                )
            )
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = child.lastPathComponent
            let isLikelyProfile =
                name == "Default" ||
                name.hasPrefix("Profile ") ||
                name.hasPrefix("Guest Profile") ||
                name.hasPrefix("Person ") ||
                nameMap[name] != nil
            if isLikelyProfile && looksLikeChromiumProfile(rootURL: child, fileManager: fileManager) {
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: chromiumProfileDisplayName(
                            directoryName: name,
                            nameMap: nameMap,
                            isDefault: name == "Default"
                        ),
                        rootURL: child,
                        isDefault: name == "Default"
                    )
                )
            }
        }

        return sortProfiles(dedupedProfiles(profiles))
    }

    private static func firefoxProfiles(
        rootURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        var profiles = firefoxProfilesFromINI(rootURL: rootURL, fileManager: fileManager)

        let likelyProfileRoots = [
            rootURL.appendingPathComponent("Profiles", isDirectory: true),
            rootURL,
        ]

        for directory in likelyProfileRoots where fileManager.fileExists(atPath: directory.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if looksLikeFirefoxProfile(rootURL: child, fileManager: fileManager) {
                    let directoryName = child.lastPathComponent
                    profiles.append(
                        InstalledBrowserProfile(
                            displayName: directoryName,
                            rootURL: child,
                            isDefault: directoryName.localizedCaseInsensitiveContains("default")
                        )
                    )
                }
            }
        }

        return sortProfiles(dedupedProfiles(profiles))
    }

    private static func firefoxProfilesFromINI(
        rootURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        let iniURL = rootURL.appendingPathComponent("profiles.ini", isDirectory: false)
        guard let contents = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return []
        }

        let sections = parseINISections(contents: contents)
        var profiles: [InstalledBrowserProfile] = []
        for section in sections {
            guard let pathValue = section["Path"], !pathValue.isEmpty else { continue }
            let isRelative = section["IsRelative"] != "0"
            let profileURL: URL
            if isRelative {
                profileURL = rootURL.appendingPathComponent(pathValue, isDirectory: true)
            } else {
                profileURL = URL(fileURLWithPath: pathValue, isDirectory: true)
            }
            if looksLikeFirefoxProfile(rootURL: profileURL, fileManager: fileManager) {
                let displayName = section["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: (displayName?.isEmpty == false ? displayName! : profileURL.lastPathComponent),
                        rootURL: profileURL,
                        isDefault: section["Default"] == "1"
                    )
                )
            }
        }
        return profiles
    }

    private static func parseINISections(contents: String) -> [[String: String]] {
        var sections: [[String: String]] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            if !current.isEmpty {
                sections.append(current)
                current.removeAll()
            }
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                flushCurrent()
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            current[key] = value
        }
        flushCurrent()
        return sections
    }

    private static func looksLikeChromiumProfile(rootURL: URL, fileManager: FileManager) -> Bool {
        let historyURL = rootURL.appendingPathComponent("History", isDirectory: false)
        let cookiesURL = rootURL.appendingPathComponent("Cookies", isDirectory: false)
        return fileManager.fileExists(atPath: historyURL.path) || fileManager.fileExists(atPath: cookiesURL.path)
    }

    private static func looksLikeFirefoxProfile(rootURL: URL, fileManager: FileManager) -> Bool {
        let historyURL = rootURL.appendingPathComponent("places.sqlite", isDirectory: false)
        let cookiesURL = rootURL.appendingPathComponent("cookies.sqlite", isDirectory: false)
        return fileManager.fileExists(atPath: historyURL.path) || fileManager.fileExists(atPath: cookiesURL.path)
    }

    private static func webKitProfiles(
        descriptor: BrowserImportBrowserDescriptor,
        rootURL: URL,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        var profiles: [InstalledBrowserProfile] = []
        if looksLikeWebKitProfile(rootURL: rootURL, fileManager: fileManager) {
            profiles.append(
                InstalledBrowserProfile(
                    displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
                    rootURL: rootURL,
                    isDefault: true
                )
            )
        }

        var profileRoots = [rootURL.appendingPathComponent("Profiles", isDirectory: true)]
        if descriptor.id == "safari" {
            profileRoots.append(
                homeDirectoryURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Containers", isDirectory: true)
                    .appendingPathComponent("com.apple.Safari", isDirectory: true)
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Safari", isDirectory: true)
                    .appendingPathComponent("Profiles", isDirectory: true)
            )
        }

        var profileIndex = 1
        for profileRoot in dedupedCanonicalURLs(profileRoots) where fileManager.fileExists(atPath: profileRoot.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard looksLikeWebKitProfile(rootURL: child, fileManager: fileManager) else { continue }
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: webKitProfileDisplayName(
                            directoryName: child.lastPathComponent,
                            fallbackIndex: profileIndex
                        ),
                        rootURL: child,
                        isDefault: false
                    )
                )
                profileIndex += 1
            }
        }

        return sortProfiles(dedupedProfiles(profiles))
    }

    private static func chromiumProfileNameMap(rootURL: URL) -> [String: String] {
        let localStateURL = rootURL.appendingPathComponent("Local State", isDirectory: false)
        guard let data = try? Data(contentsOf: localStateURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileSection = jsonObject["profile"] as? [String: Any],
              let infoCache = profileSection["info_cache"] as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (directoryName, rawProfileInfo) in infoCache {
            guard let profileInfo = rawProfileInfo as? [String: Any],
                  let name = profileInfo["name"] as? String else {
                continue
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                result[directoryName] = trimmedName
            }
        }
        return result
    }

    private static func chromiumProfileDisplayName(
        directoryName: String,
        nameMap: [String: String],
        isDefault: Bool
    ) -> String {
        if let mappedName = nameMap[directoryName], !mappedName.isEmpty {
            return mappedName
        }
        if isDefault {
            return String(localized: "browser.profile.default", defaultValue: "Default")
        }
        return directoryName
    }

    private static func looksLikeWebKitProfile(rootURL: URL, fileManager: FileManager) -> Bool {
        let candidatePaths = [
            "History.db",
            "Cookies.binarycookies",
            "Cookies.sqlite",
            "WebsiteData",
            "LocalStorage",
        ]

        for candidatePath in candidatePaths {
            let url = rootURL.appendingPathComponent(candidatePath, isDirectory: candidatePath != "History.db" && candidatePath != "Cookies.binarycookies" && candidatePath != "Cookies.sqlite")
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
        }
        return false
    }

    private static func webKitProfileDisplayName(directoryName: String, fallbackIndex: Int) -> String {
        if directoryName.caseInsensitiveCompare("Default") == .orderedSame {
            return String(localized: "browser.profile.default", defaultValue: "Default")
        }
        if UUID(uuidString: directoryName) != nil {
            return String(
                format: String(
                    localized: "browser.import.sourceProfile.fallback",
                    defaultValue: "Profile %ld"
                ),
                fallbackIndex
            )
        }
        return directoryName
    }

    private static func defaultApplicationSearchDirectories(homeDirectoryURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications/Setapp", isDirectory: true),
        ]
    }

    private static func dedupedProfiles(_ profiles: [InstalledBrowserProfile]) -> [InstalledBrowserProfile] {
        var seen = Set<String>()
        var result: [InstalledBrowserProfile] = []
        for profile in profiles {
            if seen.insert(profile.id).inserted {
                result.append(profile)
            }
        }
        return result
    }

    private static func sortProfiles(_ profiles: [InstalledBrowserProfile]) -> [InstalledBrowserProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

struct BrowserImportOutcomeEntry: Sendable {
    let sourceProfileNames: [String]
    let destinationProfileName: String
    let importedCookies: Int
    let skippedCookies: Int
    let importedHistoryEntries: Int
    let warnings: [String]
}

struct BrowserImportOutcome: Sendable {
    let browserName: String
    let scope: BrowserImportScope
    let domainFilters: [String]
    let createdDestinationProfileNames: [String]
    let entries: [BrowserImportOutcomeEntry]
    let warnings: [String]

    var totalImportedCookies: Int {
        entries.reduce(0) { $0 + $1.importedCookies }
    }

    var totalSkippedCookies: Int {
        entries.reduce(0) { $0 + $1.skippedCookies }
    }

    var totalImportedHistoryEntries: Int {
        entries.reduce(0) { $0 + $1.importedHistoryEntries }
    }
}

struct RealizedBrowserImportExecutionEntry: Sendable {
    let sourceProfiles: [InstalledBrowserProfile]
    let destinationProfileID: UUID
    let destinationProfileName: String
}

struct RealizedBrowserImportExecutionPlan: Sendable {
    let mode: BrowserImportDestinationMode
    let entries: [RealizedBrowserImportExecutionEntry]
    let createdProfiles: [BrowserProfileDefinition]
}

enum BrowserImportPlanRealizationError: LocalizedError {
    case missingDestinationProfile(UUID)
    case profileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDestinationProfile:
            return String(
                localized: "browser.import.error.destinationMissing",
                defaultValue: "The selected Programa browser profile no longer exists. Pick a destination profile again."
            )
        case .profileCreationFailed(let name):
            return String(
                format: String(
                    localized: "browser.import.error.destinationCreateFailed",
                    defaultValue: "Programa could not create the destination profile \"%@\"."
                ),
                name
            )
        }
    }
}

enum BrowserImportOutcomeFormatter {
    static func lines(for outcome: BrowserImportOutcome) -> [String] {
        var lines: [String] = []
        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.browser",
                    defaultValue: "Browser: %@"
                ),
                outcome.browserName
            )
        )

        if outcome.entries.count == 1, let entry = outcome.entries.first {
            if !entry.sourceProfileNames.isEmpty {
                lines.append(
                    String(
                        format: String(
                            localized: "browser.import.complete.sourceProfiles",
                            defaultValue: "Source profiles: %@"
                        ),
                        entry.sourceProfileNames.joined(separator: ", ")
                    )
                )
            }
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.destinationProfile",
                        defaultValue: "Destination profile: %@"
                    ),
                    entry.destinationProfileName
                )
            )
        } else if !outcome.entries.isEmpty {
            lines.append(
                String(
                    localized: "browser.import.complete.profileMappings",
                    defaultValue: "Profile mappings:"
                )
            )
            for entry in outcome.entries {
                let sourceNames = entry.sourceProfileNames.joined(separator: ", ")
                lines.append(
                    String(
                        format: String(
                            localized: "browser.import.complete.profileMapping",
                            defaultValue: "%@ -> %@"
                        ),
                        sourceNames,
                        entry.destinationProfileName
                    )
                )
            }
        }

        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.scope",
                    defaultValue: "Scope: %@"
                ),
                outcome.scope.displayName
            )
        )
        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.importedCookies",
                    defaultValue: "Imported cookies: %ld"
                ),
                outcome.totalImportedCookies
            )
        )
        if outcome.totalSkippedCookies > 0 {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.skippedCookies",
                        defaultValue: "Skipped cookies: %ld"
                    ),
                    outcome.totalSkippedCookies
                )
            )
        }
        if outcome.scope.includesHistory {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.importedHistory",
                        defaultValue: "Imported history entries: %ld"
                    ),
                    outcome.totalImportedHistoryEntries
                )
            )
        }
        if !outcome.domainFilters.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.domainFilter",
                        defaultValue: "Domain filter: %@"
                    ),
                    outcome.domainFilters.joined(separator: ", ")
                )
            )
        }
        if !outcome.createdDestinationProfileNames.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.createdProfiles",
                        defaultValue: "Created Programa profiles: %@"
                    ),
                    outcome.createdDestinationProfileNames.joined(separator: ", ")
                )
            )
        }
        if !outcome.warnings.isEmpty {
            lines.append("")
            lines.append(
                String(
                    localized: "browser.import.complete.warnings",
                    defaultValue: "Warnings:"
                )
            )
            for warning in outcome.warnings {
                lines.append("- \(warning)")
            }
        }

        return lines
    }
}

enum BrowserImportDestinationMode: Equatable, Sendable {
    case singleDestination
    case separateProfiles
    case mergeIntoOne
}

enum BrowserImportDestinationRequest: Equatable, Sendable {
    case existing(UUID)
    case createNamed(String)
}

struct BrowserImportExecutionEntry: Equatable, Sendable {
    var sourceProfiles: [InstalledBrowserProfile]
    var destination: BrowserImportDestinationRequest
}

struct BrowserImportExecutionPlan: Equatable, Sendable {
    var mode: BrowserImportDestinationMode
    var entries: [BrowserImportExecutionEntry]
}

struct BrowserImportStep3Presentation: Equatable {
    let showsModeSelector: Bool
    let showsSeparateRows: Bool
    let showsSingleDestinationPicker: Bool

    init(plan: BrowserImportExecutionPlan) {
        showsModeSelector = plan.entries.count > 1 || plan.entries.contains { $0.sourceProfiles.count > 1 }
        showsSeparateRows = plan.mode == .separateProfiles
        showsSingleDestinationPicker = plan.mode != .separateProfiles
    }
}

struct BrowserImportSourceProfilesPresentation: Equatable {
    let scrollHeight: CGFloat
    let showsHelpText: Bool

    init(profileCount: Int) {
        let visibleRows = min(max(profileCount, 1), 5)
        let contentHeight = CGFloat(visibleRows * 26 + 14)
        scrollHeight = max(76, contentHeight)
        showsHelpText = profileCount > 1
    }
}

enum BrowserImportPlanResolver {
    @MainActor
    static func defaultPlan(
        selectedSourceProfiles: [InstalledBrowserProfile],
        destinationProfiles: [BrowserProfileDefinition],
        preferredSingleDestinationProfileID: UUID
    ) -> BrowserImportExecutionPlan {
        let resolvedSourceProfiles = selectedSourceProfiles.isEmpty ? [] : selectedSourceProfiles

        guard resolvedSourceProfiles.count > 1 else {
            let destinationRequest: BrowserImportDestinationRequest
            if let sourceProfile = resolvedSourceProfiles.first,
               let matchingProfile = matchingDestinationProfile(
                for: sourceProfile.displayName,
                destinationProfiles: destinationProfiles
               ) {
                destinationRequest = .existing(matchingProfile.id)
            } else {
                destinationRequest = .existing(preferredSingleDestinationProfileID)
            }

            return BrowserImportExecutionPlan(
                mode: .singleDestination,
                entries: resolvedSourceProfiles.map {
                    BrowserImportExecutionEntry(
                        sourceProfiles: [$0],
                        destination: destinationRequest
                    )
                }
            )
        }

        return separateProfilesPlan(
            selectedSourceProfiles: resolvedSourceProfiles,
            destinationProfiles: destinationProfiles
        )
    }

    static func separateProfilesPlan(
        selectedSourceProfiles: [InstalledBrowserProfile],
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserImportExecutionPlan {
        var reservedNames = Set(destinationProfiles.map { normalizedProfileName($0.displayName) })

        return BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: selectedSourceProfiles.map { profile in
                if let matchingProfile = matchingDestinationProfile(
                    for: profile.displayName,
                    destinationProfiles: destinationProfiles
                ) {
                    return BrowserImportExecutionEntry(
                        sourceProfiles: [profile],
                        destination: .existing(matchingProfile.id)
                    )
                }

                let createName = nextCreateName(
                    baseName: profile.displayName,
                    takenNames: reservedNames
                )
                reservedNames.insert(normalizedProfileName(createName))
                return BrowserImportExecutionEntry(
                    sourceProfiles: [profile],
                    destination: .createNamed(createName)
                )
            }
        )
    }

    private static func matchingDestinationProfile(
        for sourceProfileName: String,
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserProfileDefinition? {
        let normalizedSourceName = normalizedProfileName(sourceProfileName)
        guard !normalizedSourceName.isEmpty else { return nil }
        return destinationProfiles.first {
            normalizedProfileName($0.displayName) == normalizedSourceName
        }
    }

    private static func nextCreateName(
        baseName: String,
        takenNames: Set<String>
    ) -> String {
        let trimmedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseName = trimmedBaseName.isEmpty ? "Profile" : trimmedBaseName
        if !takenNames.contains(normalizedProfileName(resolvedBaseName)) {
            return resolvedBaseName
        }

        var suffix = 2
        while true {
            let candidate = "\(resolvedBaseName) (\(suffix))"
            if !takenNames.contains(normalizedProfileName(candidate)) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func normalizedProfileName(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @MainActor
    static func realize(
        plan: BrowserImportExecutionPlan,
        profileStore: BrowserProfileStore
    ) throws -> RealizedBrowserImportExecutionPlan {
        var realizedEntries: [RealizedBrowserImportExecutionEntry] = []
        var createdProfiles: [BrowserProfileDefinition] = []

        for entry in plan.entries {
            let destinationProfile: BrowserProfileDefinition
            switch entry.destination {
            case .existing(let id):
                guard let existingProfile = profileStore.profileDefinition(id: id) else {
                    throw BrowserImportPlanRealizationError.missingDestinationProfile(id)
                }
                destinationProfile = existingProfile
            case .createNamed(let name):
                if let existingProfile = matchingDestinationProfile(
                    for: name,
                    destinationProfiles: profileStore.profiles
                ) {
                    destinationProfile = existingProfile
                } else if let createdProfile = profileStore.createProfile(named: name) {
                    createdProfiles.append(createdProfile)
                    destinationProfile = createdProfile
                } else {
                    throw BrowserImportPlanRealizationError.profileCreationFailed(name)
                }
            }

            realizedEntries.append(
                RealizedBrowserImportExecutionEntry(
                    sourceProfiles: entry.sourceProfiles,
                    destinationProfileID: destinationProfile.id,
                    destinationProfileName: destinationProfile.displayName
                )
            )
        }

        return RealizedBrowserImportExecutionPlan(
            mode: plan.mode,
            entries: realizedEntries,
            createdProfiles: createdProfiles
        )
    }

    @MainActor
    static func realize(plan: BrowserImportExecutionPlan) throws -> RealizedBrowserImportExecutionPlan {
        try realize(plan: plan, profileStore: .shared)
    }
}

#if canImport(CommonCrypto) && canImport(Security)
private struct ChromiumCookieKeychainItem: Hashable {
    let service: String
    let account: String
}

private final class ChromiumCookieDecryptor {
    private enum KeychainLookupResult {
        case success(Data)
        case failure(OSStatus)
    }

    enum FailureReason {
        case keychain(OSStatus)
        case itemNotFound
        case unreadableSecret
        case decrypt
        case unsupportedFormat
    }

    private let browser: InstalledBrowserCandidate
    private var cachedKeychainItem: ChromiumCookieKeychainItem?
    private var cachedPasswordData: Data?
    private var attemptedLookup = false
    private(set) var lastFailureReason: FailureReason?

    init(browser: InstalledBrowserCandidate) {
        self.browser = browser
    }

    var resolvedKeychainItemName: String? {
        cachedKeychainItem?.service
    }

    func decryptCookieValue(encryptedValue: Data, host: String) -> String? {
        guard let versionPrefix = chromiumVersionPrefix(in: encryptedValue) else {
            lastFailureReason = .unsupportedFormat
            return nil
        }

        guard let passwordData = passwordData() else {
            return nil
        }

        let ciphertext = encryptedValue.dropFirst(versionPrefix.count)
        guard let key = deriveKey(from: passwordData),
              let plaintext = decrypt(ciphertext: Data(ciphertext), key: key),
              let cookieValue = decodePlaintext(plaintext, host: host) else {
            lastFailureReason = .decrypt
            return nil
        }

        lastFailureReason = nil
        return cookieValue
    }

    func warningMessage(browserName: String, skippedCount: Int) -> String? {
        guard skippedCount > 0, let failure = lastFailureReason else { return nil }
        switch failure {
        case .keychain, .itemNotFound, .unreadableSecret:
            let itemName = resolvedKeychainItemName ?? suggestedKeychainItems().first?.service ?? "\(browserName) Storage Key"
            return String(
                format: String(
                    localized: "browser.import.warning.keychainDecryptFailed",
                    defaultValue: "Skipped %ld encrypted %@ cookies because %@ could not be unlocked from Keychain."
                ),
                skippedCount,
                browserName,
                itemName
            )
        case .decrypt, .unsupportedFormat:
            return String(
                format: String(
                    localized: "browser.import.warning.encryptedCookiesSkipped",
                    defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
                ),
                skippedCount
            )
        }
    }

    private func passwordData() -> Data? {
        if let cachedPasswordData {
            return cachedPasswordData
        }
        guard !attemptedLookup else {
            return nil
        }
        attemptedLookup = true

        for item in suggestedKeychainItems() {
            switch readPasswordData(item: item) {
            case .success(let passwordData):
                guard !passwordData.isEmpty else {
                    cachedKeychainItem = item
                    lastFailureReason = .unreadableSecret
                    return nil
                }
                cachedKeychainItem = item
                cachedPasswordData = passwordData
                lastFailureReason = nil
                return passwordData
            case .failure(let status):
                if status == errSecItemNotFound {
                    continue
                }
                cachedKeychainItem = item
                lastFailureReason = .keychain(status)
                return nil
            }
        }

        lastFailureReason = .itemNotFound
        return nil
    }

    private func suggestedKeychainItems() -> [ChromiumCookieKeychainItem] {
        var result: [ChromiumCookieKeychainItem] = []
        var seen = Set<ChromiumCookieKeychainItem>()

        func append(service: String, account: String) {
            let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedService.isEmpty, !trimmedAccount.isEmpty else { return }
            let item = ChromiumCookieKeychainItem(service: trimmedService, account: trimmedAccount)
            if seen.insert(item).inserted {
                result.append(item)
            }
        }

        for baseName in keychainBaseNames() {
            append(service: "\(baseName) Storage Key", account: baseName)
            append(service: "\(baseName) Safe Storage", account: baseName)
        }

        for baseName in keychainBaseNames() {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: baseName,
                kSecReturnAttributes: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            var rawResult: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
            guard status == errSecSuccess else { continue }
            let attributesList = rawResult as? [[String: Any]] ?? []
            for attributes in attributesList {
                guard let service = attributes[kSecAttrService as String] as? String else { continue }
                guard service.contains("Storage Key") || service.contains("Safe Storage") else { continue }
                append(service: service, account: baseName)
            }
        }

        return result
    }

    private func keychainBaseNames() -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ rawName: String?) {
            guard let rawName else { return }
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return }
            if seen.insert(trimmedName).inserted {
                result.append(trimmedName)
            }
        }

        append(browser.displayName)
        append(browser.appURL?.deletingPathExtension().lastPathComponent)
        append(browser.descriptor.appNames.first?.replacingOccurrences(of: ".app", with: ""))

        if let appURL = browser.appURL,
           let bundle = Bundle(url: appURL) {
            append(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            append(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        }

        for name in Array(result) {
            if name.hasPrefix("Google ") {
                append(String(name.dropFirst("Google ".count)))
            }
            if name.hasSuffix(" Browser") {
                append(String(name.dropLast(" Browser".count)))
            }
        }

        switch browser.descriptor.id {
        case "google-chrome":
            append("Chrome")
        case "chromium":
            append("Chromium")
        case "brave":
            append("Brave")
        case "helium":
            append("Helium")
        default:
            break
        }

        return result
    }

    private func readPasswordData(item: ChromiumCookieKeychainItem) -> KeychainLookupResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: item.service,
            kSecAttrAccount: item.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let passwordData = rawResult as? Data else {
            return .failure(errSecDecode)
        }
        return .success(passwordData)
    }

    private func chromiumVersionPrefix(in encryptedValue: Data) -> Data? {
        for prefix in [Data("v10".utf8), Data("v11".utf8)] where encryptedValue.starts(with: prefix) {
            return prefix
        }
        return nil
    }

    private func deriveKey(from passwordData: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: kCCKeySizeAES128)

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        kCCKeySizeAES128
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return derivedKey
    }

    private func decrypt(ciphertext: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var plaintextLength = 0
        let plaintextCapacity = plaintext.count

        let status = plaintext.withUnsafeMutableBytes { plaintextBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            plaintextBytes.baseAddress,
                            plaintextCapacity,
                            &plaintextLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        plaintext.removeSubrange(plaintextLength...)
        return plaintext
    }

    private func decodePlaintext(_ plaintext: Data, host: String) -> String? {
        if let value = String(data: plaintext, encoding: .utf8) {
            return value
        }

        let hostDigest = Data(SHA256.hash(data: Data(host.utf8)))
        if plaintext.starts(with: hostDigest) {
            return String(data: plaintext.dropFirst(hostDigest.count), encoding: .utf8)
        }

        return nil
    }
}
#else
private final class ChromiumCookieDecryptor {
    init(browser: InstalledBrowserCandidate) {}

    func decryptCookieValue(encryptedValue: Data, host: String) -> String? { nil }

    func warningMessage(browserName: String, skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        return String(
            format: String(
                localized: "browser.import.warning.encryptedCookiesSkipped",
                defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
            ),
            skippedCount
        )
    }
}
#endif

enum BrowserDataImporter {
    private struct CookieImportResult {
        var importedCount: Int = 0
        var skippedCount: Int = 0
        var warnings: [String] = []
    }

    private struct HistoryImportResult {
        var importedCount: Int = 0
        var warnings: [String] = []
    }

    private struct HistoryRow {
        let url: String
        let title: String?
        let visitCount: Int
        let lastVisited: Date
    }

    static func parseDomainFilters(_ raw: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        for token in raw.components(separatedBy: separators) {
            var value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("*.") {
                value.removeFirst(2)
            }
            while value.hasPrefix(".") {
                value.removeFirst()
            }
            guard let canonicalValue = canonicalDomain(value) else { continue }
            guard seen.insert(canonicalValue).inserted else { continue }
            result.append(canonicalValue)
        }
        return result
    }

    static func importData(
        from browser: InstalledBrowserCandidate,
        plan: RealizedBrowserImportExecutionPlan,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcome {
        var outcomeEntries: [BrowserImportOutcomeEntry] = []
        var warnings: [String] = []
        var seenWarnings = Set<String>()

        for entry in plan.entries {
            let outcomeEntry = await importEntry(
                from: browser,
                sourceProfiles: entry.sourceProfiles,
                destinationProfileID: entry.destinationProfileID,
                destinationProfileName: entry.destinationProfileName,
                scope: scope,
                domainFilters: domainFilters
            )
            outcomeEntries.append(outcomeEntry)
            for warning in outcomeEntry.warnings where seenWarnings.insert(warning).inserted {
                warnings.append(warning)
            }
        }

        if scope == .everything {
            let unavailableWarning = String(
                localized: "browser.import.warning.additionalDataUnavailable",
                defaultValue: "Bookmarks, settings, and extensions import are not available yet. Imported cookies and history only."
            )
            if seenWarnings.insert(unavailableWarning).inserted {
                warnings.append(unavailableWarning)
            }
        }

        return BrowserImportOutcome(
            browserName: browser.displayName,
            scope: scope,
            domainFilters: domainFilters,
            createdDestinationProfileNames: plan.createdProfiles.map(\.displayName),
            entries: outcomeEntries,
            warnings: warnings
        )
    }

    private static func importEntry(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        destinationProfileName: String,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcomeEntry {
        let resolvedSourceProfiles = sourceProfiles.isEmpty ? browser.profiles : sourceProfiles
        var cookieResult = CookieImportResult()
        if scope.includesCookies {
            cookieResult = await importCookies(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var historyResult = HistoryImportResult()
        if scope.includesHistory {
            historyResult = await importHistory(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var warnings = cookieResult.warnings
        warnings.append(contentsOf: historyResult.warnings)
        return BrowserImportOutcomeEntry(
            sourceProfileNames: resolvedSourceProfiles.map(\.displayName),
            destinationProfileName: destinationProfileName,
            importedCookies: cookieResult.importedCount,
            skippedCookies: cookieResult.skippedCount,
            importedHistoryEntries: historyResult.importedCount,
            warnings: warnings
        )
    }

    private static func importCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxCookies(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .chromium:
            return await importChromiumCookies(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .webkit:
            if browser.descriptor.id == "safari" {
                return CookieImportResult(
                    importedCount: 0,
                    skippedCount: 0,
                    warnings: [
                        String(
                            localized: "browser.import.warning.safariCookiesUnsupported",
                            defaultValue: "Safari cookies are stored in Cookies.binarycookies and are not yet supported by this importer."
                        )
                    ]
                )
            }
            return CookieImportResult(
                importedCount: 0,
                skippedCount: 0,
                warnings: [
                    String(
                        format: String(
                            localized: "browser.import.warning.cookieImportUnsupported",
                            defaultValue: "%@ cookie import is not implemented yet."
                        ),
                        browser.displayName
                    )
                ]
            )
        }
    }

    private static func importHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .chromium:
            return await importChromiumHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .webkit:
            return await importWebKitHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }
    }

    private static func importFirefoxCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("cookies.sqlite", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies"
                ) { statement in
                    let host = sqliteColumnText(statement, index: 0) ?? ""
                    let name = sqliteColumnText(statement, index: 1) ?? ""
                    let value = sqliteColumnText(statement, index: 2) ?? ""
                    let path = sqliteColumnText(statement, index: 3) ?? "/"
                    let expiry = sqliteColumnInt64(statement, index: 4)
                    let isSecure = sqliteColumnInt64(statement, index: 5) != 0

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    var properties: [HTTPCookiePropertyKey: Any] = [
                        .domain: host,
                        .path: path.isEmpty ? "/" : path,
                        .name: name,
                        .value: value,
                    ]
                    if isSecure {
                        properties[.secure] = "TRUE"
                    }
                    if expiry > 0 {
                        properties[.expires] = Date(timeIntervalSince1970: TimeInterval(expiry))
                    }
                    if let cookie = HTTPCookie(properties: properties) {
                        cookies.append(cookie)
                    }
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.firefoxCookiesReadFailed",
                            defaultValue: "Failed reading Firefox cookies at %@: %@"
                        ),
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies, destinationProfileID: destinationProfileID)
        return CookieImportResult(importedCount: importedCount, skippedCount: max(0, dedupedCookies.count - importedCount), warnings: warnings)
    }

    private static func importChromiumCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []
        var skippedEncryptedCookies = 0
        let decryptor = ChromiumCookieDecryptor(browser: browser)

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("Cookies", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: "SELECT host_key, name, value, path, expires_utc, is_secure, encrypted_value FROM cookies"
                ) { statement in
                    let host = sqliteColumnText(statement, index: 0) ?? ""
                    let name = sqliteColumnText(statement, index: 1) ?? ""
                    let value = sqliteColumnText(statement, index: 2) ?? ""
                    let path = sqliteColumnText(statement, index: 3) ?? "/"
                    let expiresUTC = sqliteColumnInt64(statement, index: 4)
                    let isSecure = sqliteColumnInt64(statement, index: 5) != 0
                    let encryptedValue = sqliteColumnData(statement, index: 6)

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    var usableValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if usableValue.isEmpty && !encryptedValue.isEmpty {
                        if let decryptedValue = decryptor.decryptCookieValue(
                            encryptedValue: encryptedValue,
                            host: host
                        ) {
                            usableValue = decryptedValue
                        } else {
                            skippedEncryptedCookies += 1
                            return
                        }
                    }

                    var properties: [HTTPCookiePropertyKey: Any] = [
                        .domain: host,
                        .path: path.isEmpty ? "/" : path,
                        .name: name,
                        .value: usableValue,
                    ]
                    if isSecure {
                        properties[.secure] = "TRUE"
                    }
                    if let expiresDate = chromiumDate(fromWebKitMicroseconds: expiresUTC) {
                        properties[.expires] = expiresDate
                    }
                    if let cookie = HTTPCookie(properties: properties) {
                        cookies.append(cookie)
                    }
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserCookiesReadFailed",
                            defaultValue: "Failed reading %@ cookies at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies, destinationProfileID: destinationProfileID)
        if let warning = decryptor.warningMessage(
            browserName: browser.displayName,
            skippedCount: skippedEncryptedCookies
        ) {
            warnings.append(warning)
        }
        let skippedCount = max(0, dedupedCookies.count - importedCount) + skippedEncryptedCookies
        return CookieImportResult(importedCount: importedCount, skippedCount: skippedCount, warnings: warnings)
    }

    private static func importFirefoxHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("places.sqlite", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT url, title, visit_count, last_visit_date
                    FROM moz_places
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_date DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitMicros = sqliteColumnInt64(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = firefoxDate(fromUnixMicroseconds: lastVisitMicros) ?? .distantPast
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.firefoxHistoryReadFailed",
                            defaultValue: "Failed reading Firefox history at %@: %@"
                        ),
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importChromiumHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("History", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT url, title, visit_count, last_visit_time
                    FROM urls
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitMicros = sqliteColumnInt64(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = chromiumDate(fromWebKitMicroseconds: lastVisitMicros) ?? .distantPast
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserHistoryReadFailed",
                            defaultValue: "Failed reading %@ history at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importWebKitHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        var candidateDatabaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("History.db", isDirectory: false)
        }
        if browser.descriptor.id == "safari" {
            candidateDatabaseURLs.append(
                browser.homeDirectoryURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Safari", isDirectory: true)
                    .appendingPathComponent("History.db", isDirectory: false)
            )
        }
        let uniqueURLs = dedupedCanonicalURLs(candidateDatabaseURLs).filter { fileManager.fileExists(atPath: $0.path) }

        if uniqueURLs.isEmpty {
            return HistoryImportResult(
                importedCount: 0,
                warnings: [
                    String(
                        format: String(
                            localized: "browser.import.warning.noHistoryDatabase",
                            defaultValue: "No history database found for %@."
                        ),
                        browser.displayName
                    )
                ]
            )
        }

        for databaseURL in uniqueURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT history_items.url,
                           history_items.title,
                           COUNT(history_visits.id) AS visit_count,
                           MAX(history_visits.visit_time) AS last_visit_time
                    FROM history_items
                    JOIN history_visits
                      ON history_items.id = history_visits.history_item
                    GROUP BY history_items.url
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitReferenceSeconds = sqliteColumnDouble(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = Date(timeIntervalSinceReferenceDate: lastVisitReferenceSeconds)
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserHistoryReadFailed",
                            defaultValue: "Failed reading %@ history at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func mergeHistoryRows(_ rows: [HistoryRow], destinationProfileID: UUID) async -> Int {
        guard !rows.isEmpty else { return 0 }
        return await MainActor.run {
            let entries = rows.compactMap { row -> BrowserHistoryStore.Entry? in
                guard let parsedURL = URL(string: row.url),
                      let scheme = parsedURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    return nil
                }
                let trimmedTitle = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return BrowserHistoryStore.Entry(
                    id: UUID(),
                    url: parsedURL.absoluteString,
                    title: trimmedTitle,
                    lastVisited: row.lastVisited,
                    visitCount: max(1, row.visitCount)
                )
            }
            let historyStore = BrowserProfileStore.shared.historyStore(for: destinationProfileID)
            return historyStore.mergeImportedEntries(entries)
        }
    }

    private static func setCookiesInStore(_ cookies: [HTTPCookie], destinationProfileID: UUID) async -> Int {
        guard !cookies.isEmpty else { return 0 }
        let store = await MainActor.run {
            BrowserProfileStore.shared.websiteDataStore(for: destinationProfileID).httpCookieStore
        }
        var importedCount = 0
        for cookie in cookies {
            await setCookie(cookie, in: store)
            importedCount += 1
        }
        return importedCount
    }

    @MainActor
    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private static func dedupeCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var dedupedByKey: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let key = "\(cookie.name.lowercased())|\(cookie.domain.lowercased())|\(cookie.path)"
            if let existing = dedupedByKey[key] {
                let existingExpiry = existing.expiresDate ?? .distantPast
                let candidateExpiry = cookie.expiresDate ?? .distantPast
                if candidateExpiry >= existingExpiry {
                    dedupedByKey[key] = cookie
                }
            } else {
                dedupedByKey[key] = cookie
            }
        }
        return Array(dedupedByKey.values)
    }

    private static func canonicalDomain(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }
        guard let components = URLComponents(string: "https://\(value)"),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let host = components.host else {
            return value
        }
        return host.lowercased()
    }

    static func domainMatches(host: String, filters: [String]) -> Bool {
        if filters.isEmpty { return true }
        guard let normalizedHost = canonicalDomain(host) else { return false }
        for filter in filters {
            guard let normalizedFilter = canonicalDomain(filter) else { continue }
            if normalizedHost == normalizedFilter { return true }
            if normalizedHost.hasSuffix(".\(normalizedFilter)") { return true }
        }
        return false
    }

    private static func chromiumDate(fromWebKitMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let unixSeconds = (Double(rawValue) / 1_000_000.0) - 11_644_473_600.0
        guard unixSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func firefoxDate(fromUnixMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let seconds = Double(rawValue) / 1_000_000.0
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func querySQLiteRows(
        sourceDatabaseURL: URL,
        sql: String,
        rowHandler: (OpaquePointer) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-browser-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let snapshotURL = tempRoot.appendingPathComponent(sourceDatabaseURL.lastPathComponent, isDirectory: false)
        try fileManager.copyItem(at: sourceDatabaseURL, to: snapshotURL)

        let walSourceURL = URL(fileURLWithPath: "\(sourceDatabaseURL.path)-wal")
        let walSnapshotURL = URL(fileURLWithPath: "\(snapshotURL.path)-wal")
        if fileManager.fileExists(atPath: walSourceURL.path) {
            try? fileManager.copyItem(at: walSourceURL, to: walSnapshotURL)
        }
        let shmSourceURL = URL(fileURLWithPath: "\(sourceDatabaseURL.path)-shm")
        let shmSnapshotURL = URL(fileURLWithPath: "\(snapshotURL.path)-shm")
        if fileManager.fileExists(atPath: shmSourceURL.path) {
            try? fileManager.copyItem(at: shmSourceURL, to: shmSnapshotURL)
        }

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(snapshotURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            let message = sqliteMessage(from: database) ?? "unknown SQLite open failure"
            sqlite3_close(database)
            throw NSError(domain: "BrowserDataImporter", code: Int(openCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            let message = sqliteMessage(from: database) ?? "unknown SQLite prepare failure"
            sqlite3_finalize(statement)
            throw NSError(domain: "BrowserDataImporter", code: Int(prepareCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_ROW {
                try rowHandler(statement)
                continue
            }
            if stepCode == SQLITE_DONE {
                break
            }
            let message = sqliteMessage(from: database) ?? "unknown SQLite step failure"
            throw NSError(domain: "BrowserDataImporter", code: Int(stepCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private static func sqliteMessage(from database: OpaquePointer?) -> String? {
        guard let database, let cString = sqlite3_errmsg(database) else { return nil }
        return String(cString: cString)
    }

    private static func sqliteColumnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cValue = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cValue)
    }

    private static func sqliteColumnInt64(_ statement: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private static func sqliteColumnDouble(_ statement: OpaquePointer, index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    private static func sqliteColumnBytes(_ statement: OpaquePointer, index: Int32) -> Int {
        Int(sqlite3_column_bytes(statement, index))
    }

    private static func sqliteColumnData(_ statement: OpaquePointer, index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: length)
    }
}

#if DEBUG
enum BrowserImportUITestFixtureLoader {
    private struct BrowserFixture: Decodable {
        let browserName: String
        let profiles: [String]
    }

    static func browsers(from environment: [String: String]) -> [InstalledBrowserCandidate]? {
        guard let rawFixture = environment["PROGRAMA_UI_TEST_BROWSER_IMPORT_FIXTURE"],
              let data = rawFixture.data(using: .utf8),
              let fixture = try? JSONDecoder().decode(BrowserFixture.self, from: data) else {
            return nil
        }

        let resolvedProfiles = fixture.profiles.enumerated().map { index, name in
            InstalledBrowserProfile(
                displayName: name,
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-ui-test-browser-import")
                    .appendingPathComponent(
                        fixture.browserName
                            .lowercased()
                            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                    )
                    .appendingPathComponent("\(index)-\(name)")
                    .standardizedFileURL,
                isDefault: index == 0
            )
        }

        let descriptor = InstalledBrowserDetector.allBrowserDescriptors.first(where: {
            $0.displayName == fixture.browserName
        }) ?? BrowserImportBrowserDescriptor(
            id: fixture.browserName
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            displayName: fixture.browserName,
            family: .chromium,
            tier: 0,
            bundleIdentifiers: [],
            appNames: [],
            dataRootRelativePaths: [],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: false
        )

        return [
            InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: descriptor.family,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                appURL: nil,
                dataRootURL: nil,
                profiles: resolvedProfiles,
                detectionSignals: ["ui-test-fixture"],
                detectionScore: Int.max
            )
        ]
    }

    static func destinationProfiles(from environment: [String: String]) -> [BrowserProfileDefinition]? {
        guard let rawDestinations = environment["PROGRAMA_UI_TEST_BROWSER_IMPORT_DESTINATIONS"],
              let data = rawDestinations.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data),
              !names.isEmpty else {
            return nil
        }

        return names.enumerated().map { index, rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.localizedCaseInsensitiveCompare("Default") == .orderedSame {
                return BrowserProfileDefinition(
                    id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
                    displayName: "Default",
                    createdAt: .distantPast,
                    isBuiltInDefault: true
                )
            }
            return BrowserProfileDefinition(
                id: UUID(),
                displayName: name.isEmpty ? "Profile \(index + 1)" : name,
                createdAt: .distantPast,
                isBuiltInDefault: false
            )
        }
    }
}
#endif

@MainActor
final class BrowserDataImportCoordinator {
    static let shared = BrowserDataImportCoordinator()

    private var importInProgress = false

    private init() {}

    func presentImportDialog(defaultDestinationProfileID: UUID? = nil) {
        presentImportDialog(prefilledBrowsers: nil, defaultDestinationProfileID: defaultDestinationProfileID)
    }

    struct ImportSelection {
        let browser: InstalledBrowserCandidate
        let executionPlan: BrowserImportExecutionPlan
        let scope: BrowserImportScope
        let domainFilters: [String]
    }

    private func presentImportDialog(
        prefilledBrowsers: [InstalledBrowserCandidate]?,
        defaultDestinationProfileID: UUID?
    ) {
        guard !importInProgress else { return }
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let fixtureBrowsers = BrowserImportUITestFixtureLoader.browsers(from: environment)
        let fixtureDestinationProfiles = BrowserImportUITestFixtureLoader.destinationProfiles(from: environment)
        let browsers = prefilledBrowsers ?? fixtureBrowsers ?? InstalledBrowserDetector.detectInstalledBrowsers()
#else
        let fixtureDestinationProfiles: [BrowserProfileDefinition]? = nil
        let browsers = prefilledBrowsers ?? InstalledBrowserDetector.detectInstalledBrowsers()
#endif
        guard !browsers.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.noBrowsers.title",
                defaultValue: "No importable browsers found"
            )
            alert.informativeText = String(
                localized: "browser.import.noBrowsers.message",
                defaultValue: "Programa could not find browser profiles to import from on this Mac."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }

        guard let selection = promptForSelection(
            browsers: browsers,
            destinationProfiles: fixtureDestinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        ) else { return }

#if DEBUG
        if captureSelectionIfRequested(selection, destinationProfiles: fixtureDestinationProfiles) {
            return
        }
#endif
        let realizedPlan: RealizedBrowserImportExecutionPlan
        do {
            realizedPlan = try BrowserImportPlanResolver.realize(plan: selection.executionPlan)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.error.title",
                defaultValue: "Import could not start"
            )
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }
        importInProgress = true

        let progressWindow = showProgressWindow(
            title: String(
                localized: "browser.import.progress.title",
                defaultValue: "Importing Browser Data"
            ),
            message: String(
                format: String(
                    localized: "browser.import.progress.message",
                    defaultValue: "Importing %@ from %@…"
                ),
                selection.scope.displayName.lowercased(),
                selection.browser.displayName
            )
        )

        Task.detached(priority: .userInitiated) {
            let outcome = await BrowserDataImporter.importData(
                from: selection.browser,
                plan: realizedPlan,
                scope: selection.scope,
                domainFilters: selection.domainFilters
            )

            await MainActor.run {
                self.hideProgressWindow(progressWindow)
                self.presentOutcome(outcome)
                self.importInProgress = false
            }
        }
    }

    private func promptForSelection(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?
    ) -> ImportSelection? {
        guard !browsers.isEmpty else { return nil }
        let wizard = BrowserImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        )
        return wizard.runModal()
    }

#if DEBUG
    func debugMakeImportWizardWindow(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]? = nil,
        defaultDestinationProfileID: UUID? = nil
    ) -> NSWindow {
        let wizard = BrowserImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        )
        return wizard.debugPanelWindow
    }
#endif

#if DEBUG
    private struct CapturedImportSelection: Encodable {
        struct Entry: Encodable {
            let sourceProfiles: [String]
            let destinationKind: String
            let destinationName: String
        }

        let browserName: String
        let mode: String
        let scope: String
        let domainFilters: [String]
        let entries: [Entry]
    }

    private func captureSelectionIfRequested(
        _ selection: ImportSelection,
        destinationProfiles: [BrowserProfileDefinition]?
    ) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PROGRAMA_UI_TEST_BROWSER_IMPORT_MODE"] == "capture-only" else { return false }
        guard let path = environment["PROGRAMA_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH"], !path.isEmpty else {
            return true
        }

        let availableDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
        let payload = CapturedImportSelection(
            browserName: selection.browser.displayName,
            mode: captureModeName(selection.executionPlan.mode),
            scope: selection.scope.rawValue,
            domainFilters: selection.domainFilters,
            entries: selection.executionPlan.entries.map { entry in
                let destinationKind: String
                let destinationName: String
                switch entry.destination {
                case .existing(let id):
                    destinationKind = "existing"
                    destinationName = availableDestinationProfiles.first(where: { $0.id == id })?.displayName
                        ?? BrowserProfileStore.shared.displayName(for: id)
                case .createNamed(let name):
                    destinationKind = "create"
                    destinationName = name
                }
                return CapturedImportSelection.Entry(
                    sourceProfiles: entry.sourceProfiles.map(\.displayName),
                    destinationKind: destinationKind,
                    destinationName: destinationName
                )
            }
        )

        guard let data = try? JSONEncoder().encode(payload) else { return true }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: url)
        return true
    }

    private func captureModeName(_ mode: BrowserImportDestinationMode) -> String {
        switch mode {
        case .singleDestination:
            return "singleDestination"
        case .separateProfiles:
            return "separateProfiles"
        case .mergeIntoOne:
            return "mergeIntoOne"
        }
    }
#endif

    private func showProgressWindow(title: String, message: String) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 122),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 122))

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        content.addSubview(spinner)

        let titleLabel = NSTextField(labelWithString: message)
        titleLabel.frame = NSRect(x: 52, y: 56, width: 340, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        content.addSubview(titleLabel)

        let subtitleLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.progress.subtitle",
                defaultValue: "This can take a few seconds for large profiles."
            )
        )
        subtitleLabel.frame = NSRect(x: 52, y: 34, width: 340, height: 16)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        content.addSubview(subtitleLabel)

        window.contentView = content

        if let keyWindow = NSApp.keyWindow {
            keyWindow.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        return window
    }

    private func hideProgressWindow(_ window: NSWindow) {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    private func presentOutcome(_ outcome: BrowserImportOutcome) {
        let lines = BrowserImportOutcomeFormatter.lines(for: outcome)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.import.complete.title",
            defaultValue: "Browser data import complete"
        )
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}

// MARK: - User Proxy Settings

/// Persists and reads user-configured proxy settings (config-file only; no Settings UI).
///
/// When `browser.proxy` is present in `settings.json`, the config-file parser writes
/// host/port/type into UserDefaults via these keys. `BrowserPanel` reads them back
/// through `descriptor()` when building `WKWebsiteDataStore.proxyConfigurations`.
