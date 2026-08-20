import AppKit
import WebKit

/// Shared subview-selection and reparenting logic for moving a browser
/// `WKWebView`'s docked-inspector companion views into a new host container.
///
/// This used to be two near-identical copy/paste implementations:
/// `BrowserWindowPortal.moveWebKitRelatedSubviewsIfNeeded` (external-window
/// portal reparenting) and `WebViewRepresentable.moveWebKitRelatedSubviewsIntoHostIfNeeded`
/// (local-inline host reparenting). The subview-selection half
/// (`relatedSubviews`/`directTransferChild`) was byte-identical between the
/// two files, but the move/frame-conversion half had diverged:
/// `WebViewRepresentable` picked up a `preserveSlotLocalFrames` fast path in
/// commit efc759ecb9 ("fix: DevTools pane breaks after workspace switch
/// round-trips") that reuses a related subview's existing local frame
/// directly when it is still parented under the same `WindowBrowserSlotView`
/// as the primary web view — skipping the window-relative frame conversion —
/// then reconciles via `resizeSubviews(withOldSize:)` if the slot's bounds
/// size changed across the move. `BrowserWindowPortal`'s copy never received
/// that fix and always performed the window-relative
/// `convert(to: nil)`/`convert(from: nil)` round trip, even when both
/// endpoints were slot views.
///
/// This type unifies both call sites onto the newer, deliberate behavior: the
/// fast path applies whenever it qualifies (source is a `WindowBrowserSlotView`
/// and a given related view's current superview still matches `sourceSuperview`
/// at the moment it is processed); everything else falls back to the
/// window-relative conversion, matching both originals' non-slot behavior.
///
/// Behavioral notes vs. the two originals:
/// - `removeFromSuperview()` -> `addSubview(_:positioned:.above,relativeTo:nil)`
///   call order and `.above` z-position are preserved exactly, so z-order and
///   first-responder side effects match both originals (neither original did
///   anything special with first responder, and AppKit does not resign first
///   responder on an in-window reparent).
/// - The per-view `view === destination || view.isDescendant(of: destination)`
///   skip (from the same April 2026 fix) is kept as the sole no-op guard for
///   the `sourceSuperview === destination` case. `BrowserWindowPortal`'s old
///   copy had a redundant top-level `guard sourceSuperview !== containerView`
///   early return, but that guard was dead code at both of its call sites
///   (each only calls the move helper when `webView.superview !== containerView`
///   holds), so dropping it changes nothing there. `WebViewRepresentable`
///   deliberately calls this with `sourceSuperview === destination` from its
///   "reconcile" call sites (`localInline.reconcile.existingHost` /
///   `.async`) to safely re-run the same no-op path; keeping only the
///   per-view skip (and no top-level early return) preserves that call
///   pattern unchanged.
/// - Debug log tokens are unified to a single `browser.webKitTransfer.reparent.*`
///   prefix instead of each call site's own prefix
///   (`browser.portal.reparent.batch*` / `browser.localHost.reparent.batch*`).
///   This is DEBUG-log-only; no runtime behavior reads these strings.
enum WebKitSubviewTransfer {
    static func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    static func relatedSubviews(
        from sourceSuperview: NSView,
        primaryWebView: WKWebView
    ) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== sourceSuperview else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        append(directTransferChild(of: sourceSuperview, containing: primaryWebView) ?? primaryWebView)

        if let inspectorFrontend = primaryWebView.programaInspectorFrontendWebView() {
            append(directTransferChild(of: sourceSuperview, containing: inspectorFrontend) ?? inspectorFrontend)
        }

        for view in sourceSuperview.subviews {
            if view === primaryWebView { continue }
            let className = String(describing: type(of: view))
            guard className.contains("WK") else { continue }
            if InspectorDock.isInspectorView(view) && !InspectorDock.isVisibleCandidate(view) {
                continue
            }
            append(view)
        }

        return relatedSubviews
    }

    /// Moves `primaryWebView`'s related WebKit companion subviews (e.g. a
    /// docked Web Inspector frontend) from `sourceSuperview` into
    /// `destination`, using the slot-local fast path when both endpoints
    /// qualify and falling back to a window-relative frame conversion
    /// otherwise. See the type-level doc comment for the full behavioral
    /// contract vs. the two call sites this replaces.
    static func move(
        from sourceSuperview: NSView,
        to destination: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String,
        debugLog: ((String) -> Void)? = nil
    ) {
        let related = relatedSubviews(from: sourceSuperview, primaryWebView: primaryWebView)
        guard !related.isEmpty else { return }

        let preserveSlotLocalFrames = sourceSuperview is WindowBrowserSlotView
        let sourceSlotBoundsSize = sourceSuperview.bounds.size
        var movedCount = 0
        var reusedSourceLocalFrames = false

        debugLog?(
            "browser.webKitTransfer.reparent.batch reason=\(reason) count=\(related.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) " +
            "targetType=\(String(describing: type(of: destination)))"
        )

        for view in related {
            if view === destination || view.isDescendant(of: destination) {
                continue
            }
            let className = String(describing: type(of: view))
            let targetFrame: NSRect
            let currentSuperview = view.superview
            if preserveSlotLocalFrames && currentSuperview === sourceSuperview {
                targetFrame = view.frame
                reusedSourceLocalFrames = true
            } else {
                let frameInWindow = currentSuperview?.convert(view.frame, to: nil)
                    ?? sourceSuperview.convert(view.frame, to: nil)
                targetFrame = destination.convert(frameInWindow, from: nil)
            }
            view.removeFromSuperview()
            destination.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = targetFrame
            movedCount += 1
            debugLog?("browser.webKitTransfer.reparent.item reason=\(reason) class=\(className)")
        }

        guard movedCount > 0 else { return }
        if reusedSourceLocalFrames, sourceSlotBoundsSize != destination.bounds.size {
            destination.resizeSubviews(withOldSize: sourceSlotBoundsSize)
            destination.needsLayout = true
            destination.layoutSubtreeIfNeeded()
        }
    }
}
