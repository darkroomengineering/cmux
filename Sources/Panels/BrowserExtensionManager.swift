import AppKit
import Bonsplit
import Foundation
import WebKit

/// Loads unpacked Web Extensions (Chrome-style, manifest v2/v3) into the built-in browser
/// through WebKit's `WKWebExtension` API (macOS 15.4+; the app still runs on 14.0, where
/// this whole type is unavailable and the browser simply has no extensions).
///
/// Proof-of-concept scope, deliberately narrow:
/// - Extensions are read from `~/.config/programa/extensions/`, one subdirectory (containing
///   `manifest.json`) or `.zip` archive per extension. No store, no install flow.
/// - Every permission and host match pattern the manifest requests is granted up front —
///   there is no consent UI yet, so this directory is trusted input by definition.
/// - No toolbar button, popup, or options UI, and no `WKWebExtensionTab`/`Window` adapters
///   yet: content scripts and background service workers run, but extension APIs that
///   enumerate tabs or windows see none.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionManager {
    static let shared = BrowserExtensionManager()

    /// Fixed so extension storage (`chrome.storage`, IndexedDB, service-worker state)
    /// lands in the same WebKit container every launch. Changing it orphans that data.
    private static let controllerIdentifier = UUID(uuidString: "8B1F4F62-3A6C-4E5D-9D5B-2F0C7A9E41D3")!

    static var extensionsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/programa/extensions", isDirectory: true)
    }

    let controller: WKWebExtensionController

    private(set) var loadedExtensions: [WKWebExtension] = []
    private(set) var loadErrors: [(candidate: String, error: any Error)] = []
    private var didStartLoading = false

    private init() {
        controller = WKWebExtensionController(
            configuration: WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        )
    }

    /// Idempotent kickoff; called from `BrowserPanel.configureWebViewConfiguration`, so the
    /// first browser panel of the session triggers the scan. Loading is async, but contexts
    /// loaded into the controller inject into already-attached web views, so a panel created
    /// before loading finishes still gets its content scripts.
    func loadInstalledExtensionsIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true
        Task { await self.loadInstalledExtensions() }
    }

    private func loadInstalledExtensions() async {
        let directory = Self.extensionsDirectoryURL
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidates = entries.filter { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
            return url.pathExtension.lowercased() == "zip"
        }

        guard !candidates.isEmpty else {
            #if DEBUG
            dlog("browser.extensions.scan dir=\(directory.path) none-found")
            #endif
            return
        }

        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: candidate)
                let context = WKWebExtensionContext(for: webExtension)
                grantAllRequestedPermissions(of: webExtension, to: context)
                try controller.load(context)
                loadedExtensions.append(webExtension)
                #if DEBUG
                dlog("browser.extensions.loaded name=\(webExtension.displayName ?? candidate.lastPathComponent) version=\(webExtension.displayVersion ?? "?") mv=\(Int(webExtension.manifestVersion)) background=\(webExtension.hasBackgroundContent) injected=\(webExtension.hasInjectedContent)")
                dlog("browser.extensions.access requestedPatterns=\(webExtension.allRequestedMatchPatterns.count) grantedPatterns=\(context.currentPermissionMatchPatterns.count) allURLs=\(context.hasAccessToAllURLs) example=\(context.hasAccess(to: URL(string: "https://example.com/")!)) errors=\(webExtension.errors.count)")
                #endif
            } catch {
                loadErrors.append((candidate: candidate.lastPathComponent, error: error))
                #if DEBUG
                dlog("browser.extensions.loadFailed candidate=\(candidate.lastPathComponent) error=\(error.localizedDescription)")
                #endif
            }
        }
    }

    /// PoC-only trust model: everything the manifest asks for is granted. A consent UI
    /// replaces this before extensions are exposed to users.
    private func grantAllRequestedPermissions(of webExtension: WKWebExtension, to context: WKWebExtensionContext) {
        // The dictionary values are EXPIRATION dates ("now" would expire immediately and
        // the grant silently vanishes); distantFuture means never expires, per the header.
        let never = Date.distantFuture
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, never) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.allRequestedMatchPatterns.map { ($0, never) }
        )
    }
}
