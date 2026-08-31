import AppKit
import Bonsplit
import CryptoKit
import Foundation
import WebKit

enum BrowserExtensionConsentDecision: String, Codable, Equatable {
    case approved
    case denied
}

/// Persists authority for one exact extension manifest. A decision only applies when both
/// the stable candidate identity and the complete authority fingerprint still match.
struct BrowserExtensionConsentStore {
    struct Record: Codable, Equatable {
        let fingerprint: String
        let decision: BrowserExtensionConsentDecision
    }

    private static let defaultsKey = "browser.webExtensions.consent.v1"
    private let defaults: UserDefaults
    private let defaultsKey: String

    init(defaults: UserDefaults = .standard, defaultsKey: String = Self.defaultsKey) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    func decision(candidateID: String, fingerprint: String) -> BrowserExtensionConsentDecision? {
        guard let record = records()[candidateID], record.fingerprint == fingerprint else { return nil }
        return record.decision
    }

    func setDecision(_ decision: BrowserExtensionConsentDecision, candidateID: String, fingerprint: String) {
        var current = records()
        current[candidateID] = Record(fingerprint: fingerprint, decision: decision)
        guard let data = try? JSONEncoder().encode(current) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func fingerprint(
        candidateID: String,
        version: String?,
        permissions: [String],
        hostPatterns: [String]
    ) -> String {
        let canonical = ([candidateID, version ?? ""] + permissions.sorted() + ["\u{0}"] + hostPatterns.sorted())
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func records() -> [String: Record] {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return decoded
    }
}

/// Loads explicitly approved unpacked Web Extensions from
/// `~/.config/programa/extensions/` on macOS 15.4 and later.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionManager {
    static let shared = BrowserExtensionManager()

    /// Fixed so extension storage (`chrome.storage`, IndexedDB, service-worker state)
    /// lands in the same WebKit container every launch. Changing it orphans that data.
    private static let controllerIdentifier = UUID(uuidString: "8B1F4F62-3A6C-4E5D-9D5B-2F0C7A9E41D3")!

    @MainActor
    private struct Candidate {
        let id: String
        let sourceURL: URL
        let extensionObject: WKWebExtension
        let context: WKWebExtensionContext
        let fingerprint: String

        var name: String { extensionObject.displayName ?? sourceURL.lastPathComponent }
        var version: String { extensionObject.displayVersion ?? extensionObject.version ?? "?" }
        var permissions: [String] { extensionObject.requestedPermissions.map(\.rawValue).sorted() }
        var hostPatterns: [String] { extensionObject.allRequestedMatchPatterns.map(\.string).sorted() }
    }

    static var extensionsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/programa/extensions", isDirectory: true)
    }

    let controller: WKWebExtensionController

    private(set) var loadedExtensions: [WKWebExtension] = []
    private(set) var loadErrors: [(candidate: String, error: any Error)] = []
    private var candidates: [Candidate] = []
    private var loadedContexts: [String: WKWebExtensionContext] = [:]
    private var loadingTask: Task<Void, Never>?
    private let consentStore: BrowserExtensionConsentStore

    let windowAdapter = BrowserExtensionWindowAdapter()
    private(set) var tabAdapters: [BrowserExtensionTabAdapter] = []
    private(set) var activeTabAdapter: BrowserExtensionTabAdapter?
    private var announcedWindow = false

    private let controllerDelegate = BrowserExtensionControllerDelegate()

    private init(consentStore: BrowserExtensionConsentStore = BrowserExtensionConsentStore()) {
        self.consentStore = consentStore
        controller = WKWebExtensionController(
            configuration: WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        )
        controller.delegate = controllerDelegate
    }

    func registerTab(for panel: BrowserPanel) {
        guard tabAdapter(for: panel) == nil else { return }
        if !announcedWindow {
            announcedWindow = true
            controller.didOpenWindow(windowAdapter)
            controller.didFocusWindow(windowAdapter)
        }
        let adapter = BrowserExtensionTabAdapter(panel: panel)
        tabAdapters.append(adapter)
        controller.didOpenTab(adapter)
        #if DEBUG
        dlog("browser.extensions.tab.open panel=\(panel.id.uuidString.prefix(5)) total=\(tabAdapters.count)")
        #endif
    }

    func unregisterTab(for panel: BrowserPanel) {
        guard let index = tabAdapters.firstIndex(where: { $0.panel === panel }) else { return }
        let adapter = tabAdapters.remove(at: index)
        if activeTabAdapter === adapter { activeTabAdapter = nil }
        controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func noteTabActivated(_ panel: BrowserPanel) {
        pruneDeadTabs()
        registerTab(for: panel)
        guard let adapter = tabAdapter(for: panel), activeTabAdapter !== adapter else { return }
        let previous = activeTabAdapter
        activeTabAdapter = adapter
        controller.didActivateTab(adapter, previousActiveTab: previous)
        controller.didSelectTabs([adapter])
    }

    private func tabAdapter(for panel: BrowserPanel) -> BrowserExtensionTabAdapter? {
        tabAdapters.first(where: { $0.panel === panel })
    }

    func pruneDeadTabs() {
        for adapter in tabAdapters where adapter.panel == nil {
            tabAdapters.removeAll { $0 === adapter }
            if activeTabAdapter === adapter { activeTabAdapter = nil }
            controller.didCloseTab(adapter, windowIsClosing: false)
        }
    }

    func loadInstalledExtensionsIfNeeded() {
        _ = beginLoadingIfNeeded()
    }

    func presentManagementUI() {
        Task {
            await beginLoadingIfNeeded().value
            presentCandidatePicker()
        }
    }

    private func beginLoadingIfNeeded() -> Task<Void, Never> {
        if let loadingTask { return loadingTask }
        let task = Task { await scanAndLoadApprovedExtensions() }
        loadingTask = task
        return task
    }

    private func scanAndLoadApprovedExtensions() async {
        let directory = Self.extensionsDirectoryURL
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sourceURLs = entries.filter { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
            return url.pathExtension.lowercased() == "zip"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for sourceURL in sourceURLs {
            do {
                let extensionObject = try await WKWebExtension(resourceBaseURL: sourceURL)
                let candidate = makeCandidate(sourceURL: sourceURL, extensionObject: extensionObject)
                candidates.append(candidate)
                switch consentStore.decision(candidateID: candidate.id, fingerprint: candidate.fingerprint) {
                case .approved:
                    try load(candidate)
                case .denied:
                    break
                case nil:
                    let approved = presentConsent(for: candidate)
                    consentStore.setDecision(
                        approved ? .approved : .denied,
                        candidateID: candidate.id,
                        fingerprint: candidate.fingerprint
                    )
                    if approved { try load(candidate) }
                }
            } catch {
                loadErrors.append((candidate: sourceURL.lastPathComponent, error: error))
            }
        }
    }

    private func makeCandidate(sourceURL: URL, extensionObject: WKWebExtension) -> Candidate {
        let id = sourceURL.standardizedFileURL.path
        let permissions = extensionObject.requestedPermissions.map(\.rawValue).sorted()
        let hosts = extensionObject.allRequestedMatchPatterns.map(\.string).sorted()
        return Candidate(
            id: id,
            sourceURL: sourceURL,
            extensionObject: extensionObject,
            context: WKWebExtensionContext(for: extensionObject),
            fingerprint: BrowserExtensionConsentStore.fingerprint(
                candidateID: id,
                version: extensionObject.version,
                permissions: permissions,
                hostPatterns: hosts
            )
        )
    }

    private func load(_ candidate: Candidate) throws {
        guard loadedContexts[candidate.id] == nil else { return }
        let never = Date.distantFuture
        candidate.context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: candidate.extensionObject.requestedPermissions.map { ($0, never) }
        )
        candidate.context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: candidate.extensionObject.allRequestedMatchPatterns.map { ($0, never) }
        )
        try controller.load(candidate.context)
        loadedContexts[candidate.id] = candidate.context
        loadedExtensions.append(candidate.extensionObject)
    }

    private func revoke(_ candidate: Candidate) {
        guard let context = loadedContexts.removeValue(forKey: candidate.id) else { return }
        do {
            try controller.unload(context)
        } catch {
            loadErrors.append((candidate: candidate.sourceURL.lastPathComponent, error: error))
        }
        context.grantedPermissions = [:]
        context.grantedPermissionMatchPatterns = [:]
        loadedExtensions.removeAll { $0 === candidate.extensionObject }
        consentStore.setDecision(.denied, candidateID: candidate.id, fingerprint: candidate.fingerprint)
    }

    private func presentCandidatePicker() {
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "browser.extensions.none.title", defaultValue: "No Browser Extensions")
            alert.informativeText = String(
                localized: "browser.extensions.none.message",
                defaultValue: "Add an unpacked extension or ZIP archive to ~/.config/programa/extensions/."
            )
            alert.runModal()
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for candidate in candidates {
            let state = loadedContexts[candidate.id] == nil
                ? String(localized: "browser.extensions.disabled", defaultValue: "Disabled")
                : String(localized: "browser.extensions.enabled", defaultValue: "Enabled")
            popup.addItem(withTitle: "\(candidate.name) \(candidate.version) — \(state)")
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.extensions.manage.title", defaultValue: "Manage Browser Extensions")
        alert.informativeText = String(
            localized: "browser.extensions.manage.message",
            defaultValue: "Select an extension to enable it or revoke its access."
        )
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "browser.extensions.change", defaultValue: "Change Access"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let candidate = candidates[popup.indexOfSelectedItem]
        if loadedContexts[candidate.id] != nil {
            revoke(candidate)
        } else if presentConsent(for: candidate) {
            consentStore.setDecision(.approved, candidateID: candidate.id, fingerprint: candidate.fingerprint)
            do { try load(candidate) } catch {
                loadErrors.append((candidate: candidate.sourceURL.lastPathComponent, error: error))
            }
        }
    }

    private func presentConsent(for candidate: Candidate) -> Bool {
        let none = String(localized: "browser.extensions.noneRequested", defaultValue: "None")
        let permissions = candidate.permissions.isEmpty ? none : candidate.permissions.joined(separator: "\n• ")
        let hosts = candidate.hostPatterns.isEmpty ? none : candidate.hostPatterns.joined(separator: "\n• ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "browser.extensions.consent.title",
            defaultValue: "Enable \(candidate.name)?"
        )
        alert.informativeText = String(
            localized: "browser.extensions.consent.message",
            defaultValue: "Version: \(candidate.version)\n\nPermissions:\n• \(permissions)\n\nWebsite access:\n• \(hosts)"
        )
        alert.addButton(withTitle: String(localized: "browser.extensions.enable", defaultValue: "Enable"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
