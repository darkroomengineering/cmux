import AppKit

/// Shared lifecycle base for the window-level, anchor-bound hosted-view registries:
/// `WindowTerminalPortal` (hosts `GhosttySurfaceScrollView`) and `WindowBrowserPortal`
/// (hosts `WKWebView`). Extracted per nuclear-review finding N4/WP3 to remove the
/// line-for-line duplication between the two registries.
///
/// Only the slice of the lifecycle that is provably identical between the two portals
/// lives here: installed-target bookkeeping storage, host-frame synchronization to a
/// reference view, anchor-frame-in-window resolution, geometry-observer teardown, and a
/// handful of pure NSRect/NSView helpers. Everything else — bind/detach/hide/visibility,
/// entry pruning, transient-recovery retry budgeting, deferred-sync coalescing,
/// `ensureInstalled()`, and `installGeometryObservers(for:)` — stays in each subclass
/// because their semantics differ in ways that are load-bearing (documented in the PR
/// that introduced this file). `WindowTerminalHostView` and `WindowBrowserHostView`
/// themselves are untouched by this refactor.
@MainActor
class HostedViewPortalRegistry: NSObject {
    weak var window: NSWindow?
    var installedContainerView: NSView?
    var installedReferenceView: NSView?
    var geometryObservers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    /// Subclasses override to expose their concrete hosted container view
    /// (`WindowTerminalHostView` / `WindowBrowserHostView`) upcast to `NSView` so the
    /// shared geometry bookkeeping below can read/write its frame and subviews without
    /// this base class needing to know the concrete host view type.
    var hostViewForGeometry: NSView {
        preconditionFailure("HostedViewPortalRegistry subclasses must override hostViewForGeometry")
    }

    func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor
    /// clipping. SwiftUI/AppKit hosting layers can report an anchor bounds rect wider
    /// than its split pane when intrinsic-size content overflows; intersecting through
    /// ancestor bounds gives the effective visible rect that should drive portal geometry.
    func effectiveAnchorFrameInWindow(for anchorView: NSView) -> NSRect {
        var frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        var current = anchorView.superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds =
                ancestorBoundsInWindow.origin.x.isFinite &&
                ancestorBoundsInWindow.origin.y.isFinite &&
                ancestorBoundsInWindow.size.width.isFinite &&
                ancestorBoundsInWindow.size.height.isFinite
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === installedReferenceView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }

    @discardableResult
    func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostViewForGeometry.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostViewForGeometry.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            logHostFrameUpdate(frameInContainer)
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

#if DEBUG
    /// No-op by default; each subclass overrides to emit its own dlog line verbatim so
    /// the existing greppable per-class diagnostic tokens/prefixes are unchanged.
    func logHostFrameUpdate(_ frame: NSRect) {}

    func debugHostedSubviewCount() -> Int {
        hostViewForGeometry.subviews.count
    }
#endif

    static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }

    static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    /// H1: shared teardown loop shape. Removes geometry observers, then detaches every
    /// currently-tracked id via the subclass-supplied `detach` closure (which already
    /// owns per-entry cleanup, including reverse-map removal). Subclass-specific cleanup
    /// that isn't provably identical between the two portals — Terminal's
    /// `NSLayoutConstraint` deactivation, Browser's overlay/rendering-state teardown,
    /// `hostView.removeFromSuperview()`, and nil'ing `installedContainerView`/
    /// `installedReferenceView` — stays in each subclass's own `tearDown()`, called
    /// around this helper.
    func tearDownEntries<ID: Hashable>(ids: [ID], detach: (ID) -> Void) {
        removeGeometryObservers()
        for id in ids {
            detach(id)
        }
    }

    /// H2: declarative notification-registration helper. Collapses the
    /// `NotificationCenter.default.addObserver(...) { MainActor.assumeIsolated { ... } }`
    /// boilerplate that both `installGeometryObservers(for:)` implementations repeated
    /// per-notification. Each subclass passes its own notification list as data — there
    /// is no shared/default list, since Terminal and Browser observe different
    /// notifications for different reasons.
    struct GeometryNotificationSpec {
        let name: Notification.Name
        let object: NSObject?
        let handler: (Notification) -> Void
    }

    func observeGeometryAffectingNotifications(_ specs: [GeometryNotificationSpec]) {
        guard geometryObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for spec in specs {
            geometryObservers.append(center.addObserver(
                forName: spec.name,
                object: spec.object,
                queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    spec.handler(notification)
                }
            })
        }
    }

    /// H3: shared hit-scan skeleton for `viewAtWindowPoint`/`webViewAtWindowPoint`.
    /// Converts `windowPoint` into `hostViewForGeometry`'s coordinate space once, then
    /// walks its subviews back-to-front (topmost first). `map` type-casts a subview and
    /// applies any subclass-specific eligibility check (entry tracked, not hidden, ...),
    /// returning `nil` to skip it. `resolve` receives the matched value and the
    /// already-converted point and performs the frame-containment check plus the final
    /// hit-test/lookup; returning `nil` continues the scan to the next subview instead of
    /// stopping. `terminalViewAtWindowPoint` has no Browser counterpart and is not routed
    /// through this helper.
    func hitScanReversedSubviews<Match, Result>(
        at windowPoint: NSPoint,
        map: (NSView) -> Match?,
        resolve: (Match, NSPoint) -> Result?
    ) -> Result? {
        let point = hostViewForGeometry.convert(windowPoint, from: nil)
        for subview in hostViewForGeometry.subviews.reversed() {
            guard let matched = map(subview) else { continue }
            if let result = resolve(matched, point) {
                return result
            }
        }
        return nil
    }

    /// H4: generic dead-entry pruning skeleton. The base owns the iterate/detach shape;
    /// each subclass's `isDead` closure captures its own (load-bearing, never-harmonized)
    /// dead-entry policy. Notably: Terminal treats a fully deallocated anchor
    /// (`anchorView == nil`) as dead, while Browser deliberately treats it as *not* dead
    /// so a hidden `WKWebView` survives a workspace switch instead of forcing a reload —
    /// see the divergent `isDead` closures at each call site.
    static func pruneEntries<ID: Hashable>(
        ids: [ID],
        isDead: (ID) -> Bool,
        detach: (ID) -> Void
    ) {
        for id in ids where isDead(id) {
            detach(id)
        }
    }
}

/// Pure transient-recovery retry-budget state, shared by `WindowTerminalPortal` and
/// `WindowBrowserPortal`. Both subclasses hide a hosted view/web view when a geometry
/// sync pass can't place it (missing anchor, host bounds not ready, tiny frame, ...),
/// but grant a bounded number of retries before treating the hide as final, so a
/// genuinely-transient hiccup doesn't get stuck hidden. Only the counter/reason
/// bookkeeping lives here — the actual "schedule a deferred re-sync" side effect stays
/// in each subclass's wrapper around `scheduleRetryIfNeeded`.
struct TransientRecoveryRetryState {
    var remaining: Int
    var reason: String?
}

/// The reset-budget policy differs between the two portals and is never harmonized:
/// Terminal only tracks a bare retry counter (no reason), so it resets the budget once
/// it's fully spent. Browser tracks the retry *reason* too, and resets the budget
/// whenever the reason changes — so a different kind of transient hiccup (e.g.
/// `anchorHidden` following `tinyFrame`) gets its own full budget rather than sharing
/// leftover retries from an unrelated cause.
enum TransientRecoveryResetPolicy {
    /// Terminal: reset only when `remaining == 0`.
    case whenExhausted
    /// Browser: reset whenever the incoming reason differs from the stored one.
    case whenReasonChanges
}

/// Returns `true` if a retry was scheduled (and decrements `state.remaining`), `false`
/// if the budget is exhausted for the current reason. Mutates `state` in place; has no
/// view/window/notification access, so it is directly unit-testable.
@discardableResult
func scheduleRetryIfNeeded(
    state: inout TransientRecoveryRetryState,
    newReason: String,
    budget: Int,
    resetPolicy: TransientRecoveryResetPolicy
) -> Bool {
    let shouldReset: Bool
    switch resetPolicy {
    case .whenExhausted:
        shouldReset = state.remaining == 0
    case .whenReasonChanges:
        shouldReset = state.reason != newReason
    }
    if shouldReset {
        state.remaining = budget
    }
    state.reason = newReason
    guard state.remaining > 0 else { return false }
    state.remaining -= 1
    return true
}
