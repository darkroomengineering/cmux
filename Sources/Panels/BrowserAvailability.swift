// Which browsers exist on this machine: backs PROGRAMA_DEFAULT_BROWSER /
// PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID (TerminalSurface.swift) and the
// app.browsers socket command (TerminalController+System.swift).

import Foundation
import AppKit

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

    static let knownBrowsers: [BrowserAvailabilityDescriptor] = [
        BrowserAvailabilityDescriptor(
            shortKey: "safari",
            displayName: "Safari",
            bundleIdentifiers: ["com.apple.Safari"],
            appNames: ["Safari.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "chrome",
            displayName: "Google Chrome",
            bundleIdentifiers: ["com.google.Chrome"],
            appNames: ["Google Chrome.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "firefox",
            displayName: "Firefox",
            bundleIdentifiers: ["org.mozilla.firefox"],
            appNames: ["Firefox.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "arc",
            displayName: "Arc",
            bundleIdentifiers: ["company.thebrowser.Browser", "company.thebrowser.arc"],
            appNames: ["Arc.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "brave",
            displayName: "Brave",
            bundleIdentifiers: ["com.brave.Browser"],
            appNames: ["Brave Browser.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "edge",
            displayName: "Microsoft Edge",
            bundleIdentifiers: ["com.microsoft.edgemac", "com.microsoft.Edge"],
            appNames: ["Microsoft Edge.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "zen",
            displayName: "Zen Browser",
            bundleIdentifiers: ["app.zen-browser.zen", "app.zen-browser.Zen"],
            appNames: ["Zen Browser.app", "Zen.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "vivaldi",
            displayName: "Vivaldi",
            bundleIdentifiers: ["com.vivaldi.Vivaldi"],
            appNames: ["Vivaldi.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "opera",
            displayName: "Opera",
            bundleIdentifiers: ["com.operasoftware.Opera"],
            appNames: ["Opera.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "opera-gx",
            displayName: "Opera GX",
            bundleIdentifiers: ["com.operasoftware.OperaGX"],
            appNames: ["Opera GX.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "orion",
            displayName: "Orion",
            bundleIdentifiers: ["com.kagi.kagimacOS", "com.kagi.kagimacos", "com.kagi.orion"],
            appNames: ["Orion.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "dia",
            displayName: "Dia",
            bundleIdentifiers: ["company.thebrowser.Dia", "company.thebrowser.dia"],
            appNames: ["Dia.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "comet",
            displayName: "Perplexity Comet",
            bundleIdentifiers: ["ai.perplexity.comet"],
            appNames: ["Perplexity Comet.app", "Comet.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "floorp",
            displayName: "Floorp",
            bundleIdentifiers: ["one.ablaze.floorp"],
            appNames: ["Floorp.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "waterfox",
            displayName: "Waterfox",
            bundleIdentifiers: ["net.waterfox.waterfox"],
            appNames: ["Waterfox.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "sigmaos",
            displayName: "SigmaOS",
            bundleIdentifiers: ["com.feralcat.sigmaos"],
            appNames: ["SigmaOS.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "sidekick",
            displayName: "Sidekick",
            bundleIdentifiers: ["com.meetsidekick.Sidekick", "com.pushplaylabs.sidekick"],
            appNames: ["Sidekick.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "helium",
            displayName: "Helium",
            bundleIdentifiers: ["net.imput.helium", "com.jadenGeller.Helium", "com.jaden.geller.helium"],
            appNames: ["Helium.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "atlas",
            displayName: "Atlas",
            bundleIdentifiers: ["com.atlas.browser"],
            appNames: ["Atlas.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "ladybird",
            displayName: "Ladybird",
            bundleIdentifiers: ["org.ladybird.Browser", "org.serenityos.ladybird"],
            appNames: ["Ladybird.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "chromium",
            displayName: "Chromium",
            bundleIdentifiers: ["org.chromium.Chromium"],
            appNames: ["Chromium.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "ungoogled-chromium",
            displayName: "Ungoogled Chromium",
            bundleIdentifiers: ["org.chromium.ungoogled"],
            appNames: ["Ungoogled Chromium.app"]
        ),
        BrowserAvailabilityDescriptor(
            shortKey: "aside",
            displayName: "Aside",
            bundleIdentifiers: ["at.studio.AsideBrowser"],
            appNames: ["Aside.app"]
        ),
    ]

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
            let resolved = resolveApplicationPresence(
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

    private static func bundleIdentifier(for appURL: URL) -> String? {
        Bundle(url: appURL)?.bundleIdentifier
    }

    private static func resolveApplicationPresence(
        bundleIdentifiers: [String],
        appNames: [String]
    ) -> (url: URL?, bundleIdentifier: String?) {
        for knownBundleIdentifier in bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: knownBundleIdentifier) {
                return (appURL, bundleIdentifier(for: appURL) ?? knownBundleIdentifier)
            }
        }
        let searchDirectories = defaultApplicationSearchDirectories()
        for appName in appNames {
            for directory in searchDirectories {
                let appURL = directory.appendingPathComponent(appName, isDirectory: true)
                if FileManager.default.fileExists(atPath: appURL.path) {
                    return (appURL, bundleIdentifier(for: appURL))
                }
            }
        }
        return (nil, nil)
    }

    private static func defaultApplicationSearchDirectories() -> [URL] {
        let homeDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications/Setapp", isDirectory: true),
        ]
    }
}
