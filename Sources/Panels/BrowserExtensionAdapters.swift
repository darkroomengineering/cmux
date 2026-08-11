import AppKit
import Bonsplit
import Foundation
import WebKit

/// Adapters that expose Programa's browser panels to web extensions as windows and tabs.
///
/// Extensions drive dynamic script injection through `tabs.query` + `scripting.executeScript`
/// (1Password's autofill works exactly this way), and both APIs resolve against the objects
/// registered here. Without these adapters an extension sees a browser with zero tabs and
/// can inject nothing.
///
/// Mapping (deliberately simple for this slice):
/// - One `WKWebExtensionWindow` representing the app — every live `BrowserPanel` across all
///   workspaces is a tab of it. Programa's real model (workspaces → panes → tabs mixing
///   terminals and browsers) has no clean analog in the extension world; a single flat
///   window is honest enough for tab targeting, which is what injection needs.
/// - The "active" tab is the browser panel the user most recently selected/focused.
/// - Popup windows (`BrowserPopupWindowController`) are not represented yet; their content
///   scripts still run (shared configuration), but tab-targeted APIs skip them.
///
/// Both WebKit protocols are fully `@optional`. CAUTION: an implementation whose Swift
/// signature does not exactly match the protocol's is silently ignored — no compiler error,
/// the method just never gets called. Watch for "nearly matches optional requirement"
/// warnings when touching this file, and re-run the tabs-poc probe (see PR #284) after.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionTabAdapter: NSObject, WKWebExtensionTab {
    private(set) weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
        super.init()
    }

    nonisolated func webView(for context: WKWebExtensionContext) -> WKWebView? {
        MainActor.assumeIsolated { panel?.webView }
    }

    nonisolated func url(for context: WKWebExtensionContext) -> URL? {
        MainActor.assumeIsolated { panel?.webView.url }
    }

    nonisolated func title(for context: WKWebExtensionContext) -> String? {
        MainActor.assumeIsolated { panel?.webView.title }
    }

    nonisolated func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        MainActor.assumeIsolated { !(panel?.webView.isLoading ?? true) }
    }

    nonisolated func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        MainActor.assumeIsolated { BrowserExtensionManager.shared.windowAdapter }
    }

    nonisolated func indexInWindow(for context: WKWebExtensionContext) -> Int {
        MainActor.assumeIsolated {
            BrowserExtensionManager.shared.tabAdapters.firstIndex(where: { $0 === self }) ?? 0
        }
    }

    nonisolated func isSelected(for context: WKWebExtensionContext) -> Bool {
        MainActor.assumeIsolated { BrowserExtensionManager.shared.activeTabAdapter === self }
    }
}

/// The single app-level window presented to extensions; tabs are all live browser panels.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionWindowAdapter: NSObject, WKWebExtensionWindow {

    nonisolated func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        MainActor.assumeIsolated { BrowserExtensionManager.shared.tabAdapters }
    }

    nonisolated func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        MainActor.assumeIsolated { BrowserExtensionManager.shared.activeTabAdapter }
    }

    nonisolated func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    nonisolated func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    nonisolated func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    nonisolated func frame(for context: WKWebExtensionContext) -> CGRect {
        MainActor.assumeIsolated { NSApp.mainWindow?.frame ?? .zero }
    }

    nonisolated func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        MainActor.assumeIsolated { NSApp.mainWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero }
    }
}

/// Answers the controller's world-state queries. The delegate's `openWindowsFor` reply is
/// what initially populates each extension context's `openWindows`/`openTabs` — the
/// incremental `didOpenTab`/`didActivateTab` notifications only build on that baseline.
@available(macOS 15.4, *)
final class BrowserExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        MainActor.assumeIsolated { [BrowserExtensionManager.shared.windowAdapter] }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        MainActor.assumeIsolated { BrowserExtensionManager.shared.windowAdapter }
    }
}
