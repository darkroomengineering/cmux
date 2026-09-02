// Extracted from BrowserDataImport.swift when the browser data import
// wizard was removed (2026-09-02). This file holds only the general
// "which browsers exist on this system" utilities that other features
// depend on: PROGRAMA_DEFAULT_BROWSER / PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID
// (TerminalSurface.swift) and the app.browsers socket command
// (TerminalController+System.swift). Deliberately independent of any
// import-wizard leftover-profile-data detection (removed; see
// docs/removed/browser-data-import.md).

import Foundation
import AppKit

enum BrowserImportEngineFamily: String, Hashable {
    case chromium
    case firefox
    case webkit
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

struct BrowserAvailabilityDescriptor {
    let shortKey: String
    let displayName: String
    let bundleIdentifiers: [String]
    let appNames: [String]
}

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

    private static func bundleIdentifier(for appURL: URL) -> String? {
        Bundle(url: appURL)?.bundleIdentifier
    }

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

    private static func defaultApplicationSearchDirectories(homeDirectoryURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications/Setapp", isDirectory: true),
        ]
    }
}
