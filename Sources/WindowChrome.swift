import AppKit
import ObjectiveC
import SwiftUI

/// Applies NSGlassEffectView (macOS 26+) to a window, falling back to NSVisualEffectView.
/// The glass path requires both a macOS 26 SDK at build time and macOS 26 at runtime.
enum WindowGlassEffect {
    private static var glassViewKey: UInt8 = 0
    private static var originalContentViewKey: UInt8 = 0
    private static var tintOverlayKey: UInt8 = 0

    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    /// True when `view` is the native macOS 26 glass view.
    static func isGlassEffectView(_ view: NSView) -> Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return view is NSGlassEffectView
        }
        #endif
        return false
    }

    /// Returns the control host owned by a native glass view. Source content such as
    /// portal-hosted terminal surfaces intentionally remains outside this host so AppKit
    /// can sample it through the effect.
    static func hostedContentView(in view: NSView) -> NSView? {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            return glass.contentView
        }
        #endif
        return nil
    }

    /// The Maps-style large window radius; the sidebar panel derives its own
    /// radius from this minus its inset so the two curves stay concentric.
    static let windowCornerRadius: CGFloat = 26
    /// Uniform inset of the sidebar glass panel from the window edges.
    static let sidebarPanelInset: CGFloat = 6
    /// Concentric with the window corner at the panel inset.
    static var sidebarPanelCornerRadius: CGFloat { windowCornerRadius - sidebarPanelInset }
    /// Height of the sidebar header row shared by the traffic lights and controls.
    /// On the glass path this is calibrated to the system traffic-light center
    /// under `mainWindowTitlebarSpacerHeight` -- see that constant's doc comment.
    /// Off the glass path no spacer toolbar is installed, so the pre-calibration
    /// height still applies.
    static var sidebarHeaderHeight: CGFloat { isAvailable ? 40 : 38 }
    /// Vertical midline of the header row measured from the window top.
    static var sidebarHeaderCenterFromWindowTop: CGFloat { sidebarPanelInset + sidebarHeaderHeight / 2 }
    /// Height of the invisible spacer item given to the main window's unified
    /// toolbar (`AppDelegate.configureMainWindow` / `MainWindowToolbarDelegate`)
    /// so AppKit computes a taller titlebar and re-centers the traffic lights on
    /// `sidebarHeaderCenterFromWindowTop`. An empty `NSToolbar` (zero items) and
    /// a `.top`-attribute `NSTitlebarAccessoryViewController` were both measured
    /// to have no effect on titlebar height -- only a real, sized toolbar item
    /// grows it. That item also painted a persistent vertical divider next to
    /// the traffic lights until `NSToolbarItem.isBordered = false` was set,
    /// which suppresses it with no other visible chrome. Calibrated empirically
    /// against the measured system center (measured: spacer height 20 ->
    /// traffic-light center 25.75pt, matching the 25pt design target within
    /// 0.75pt), not derived from a formula.
    static let mainWindowTitlebarSpacerHeight: CGFloat = 20

    /// Inverted (Aside-style) layout: the window backdrop is the sidebar's
    /// material, sampling the desktop and following the system appearance.
    /// Stock (#000000 @ 0.03) means untinted system glass; explicit user
    /// tints still win.
    static func resolvedWindowTint(hex: String, opacity: Double) -> NSColor? {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "").uppercased()
        let isStock = normalized == "000000" && abs(opacity - 0.03) < 0.001
        if isStock {
            return nil
        }
        return (NSColor(hex: hex) ?? .black).withAlphaComponent(opacity)
    }

    /// Corner radius of the elevated content card (terminal/browser panes).
    /// Concentric with the window corner at the card inset, same rule as
    /// `sidebarPanelCornerRadius` -- a fixed smaller value makes the card's
    /// curve visibly diverge from the window's inside the corner gap.
    static var contentCardCornerRadius: CGFloat { windowCornerRadius - contentCardInset }
    /// Radius for floating glass controls: tab pills, icon capsule clusters.
    static let controlCornerRadius: CGFloat = 10
    /// Shared "lit surface" tint for selected pills and control capsules.
    /// A white lift reads as selection in dark mode, but the equivalent black
    /// wash in light mode is muddy and drags the glass edge lensing into
    /// visible gray rims at the capsule ends — light mode lifts with white too.
    static func surfaceLiftTint(for appearance: NSAppearance, hover: Bool = false) -> NSColor {
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(hover ? 0.06 : 0.12)
        }
        return NSColor.white.withAlphaComponent(hover ? 0.3 : 0.55)
    }
    /// Gap between the content card and the window edges / sidebar.
    static let contentCardInset: CGFloat = 8
    /// Inverted (Aside-style) backdrop. The window stays a completely standard
    /// opaque AppKit window — system corner radius, system shadow, system frame.
    /// The sidebar material is an NSVisualEffectView underlay that AppKit rounds
    /// to the window shape itself, exactly like every native sidebar. No custom
    /// corner mask, no non-opaque window, no contentView replacement: those were
    /// the source of every "transparent corner" artifact, so they are gone, not
    /// patched.
    static func apply(to window: NSWindow, tintColor: NSColor? = nil) {
        guard let originalContentView = window.contentView else { return }

        if let existing = objc_getAssociatedObject(window, &glassViewKey) as? NSView {
            updateTint(on: existing, color: tintColor, window: window)
            return
        }

        let bounds = originalContentView.bounds
        let backdrop: NSView
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Liquid Glass backdrop: samples the desktop through the transparent
            // window and blurs it — the mechanism proven to work on macOS 26.
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = tintColor
            backdrop = glass
        } else {
            backdrop = Self.makeVisualEffectBackdrop(frame: bounds)
        }
        #else
        backdrop = Self.makeVisualEffectBackdrop(frame: bounds)
        #endif

        // Never replace window.contentView — that breaks traffic-light rendering
        // with `.fullSizeContentView` + `titlebarAppearsTransparent`, and it is
        // what forced the old custom-mask architecture. The backdrop also cannot
        // be a SUBVIEW of the hosting view: NSHostingView draws pure-SwiftUI
        // content into its own layer, and any subview — even positioned .below —
        // sits above that drawing, occluding the sidebar. Install it as a theme-
        // frame sibling below the contentView instead (the terminal portal's
        // proven pattern), pinned to the contentView's geometry.
        guard let themeFrame = originalContentView.superview else { return }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(backdrop, positioned: .below, relativeTo: originalContentView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: originalContentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: originalContentView.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: originalContentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: originalContentView.trailingAnchor)
        ])

        if let tintColor, !isGlassEffectView(backdrop) {
            installTintOverlay(on: backdrop, color: tintColor, window: window)
        }

        objc_setAssociatedObject(window, &glassViewKey, backdrop, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func makeVisualEffectBackdrop(frame: NSRect) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: frame)
        view.blendingMode = .behindWindow
        view.material = .sidebar
        view.state = .active
        return view
    }

    private static func installTintOverlay(on backdrop: NSView, color: NSColor, window: NSWindow) {
        let tintOverlay = NSView(frame: backdrop.bounds)
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = color.cgColor
        backdrop.addSubview(tintOverlay)
        NSLayoutConstraint.activate([
            tintOverlay.topAnchor.constraint(equalTo: backdrop.topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            tintOverlay.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor)
        ])
        objc_setAssociatedObject(window, &tintOverlayKey, tintOverlay, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Update the tint color on an existing glass effect
    static func updateTint(to window: NSWindow, color: NSColor?) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else { return }
        updateTint(on: glassView, color: color, window: window)
    }

    private static func updateTint(on backdrop: NSView, color: NSColor?, window: NSWindow) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.tintColor = color
            return
        }
        #endif
        if let tintOverlay = objc_getAssociatedObject(window, &tintOverlayKey) as? NSView {
            tintOverlay.layer?.backgroundColor = color?.cgColor
        } else if let color {
            installTintOverlay(on: backdrop, color: color, window: window)
        }
    }

    static func remove(from window: NSWindow) {
        guard let backdrop = objc_getAssociatedObject(window, &glassViewKey) as? NSView else {
            return
        }
        backdrop.removeFromSuperview()
        objc_setAssociatedObject(window, &glassViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &originalContentViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &tintOverlayKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// AppKit-backed Liquid Glass host for compact in-window surfaces such as browser chrome and
/// find controls. The complete SwiftUI subtree is installed as `NSGlassEffectView.contentView`
/// so controls participate in AppKit's glass interaction and hit-testing contract.
struct ProgramaNativeGlassContentHost<Content: View>: NSViewRepresentable {
    let content: Content
    var tintColor: NSColor?
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator {
        let hostingView: NSHostingView<Content>

        init(content: Content) {
            hostingView = NSHostingView(rootView: content)
            // Glass overlays live inside pane/window chrome, never under a safe
            // area; leaving safe-area observation on recurses into the layout-loop
            // guard on ambient display events (issue #307, fix shape from #308).
            hostingView.safeAreaRegions = []
            hostingView.sizingOptions = [.intrinsicContentSize]
            hostingView.autoresizingMask = [.width, .height]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> NSView {
        let hostingView = context.coordinator.hostingView

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            glass.appearance = resolvedAppearance

            // NSGlassEffectView otherwise centers an intrinsic-size NSHostingView when the
            // glass surface is taller than its content (most visible in suggestion popups).
            // Use a fill container as the official contentView and pin the interactive SwiftUI
            // subtree to all four edges inside it.
            let contentView = NSView(frame: glass.bounds)
            contentView.autoresizingMask = [.width, .height]
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
            glass.contentView = contentView
            return glass
        }
        #endif

        return hostingView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView.rootView = content

        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            glass.appearance = resolvedAppearance
        }
        #endif
    }

    private var resolvedAppearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        let fittingSize = context.coordinator.hostingView.fittingSize
        return CGSize(
            width: proposal.width ?? fittingSize.width,
            height: proposal.height ?? fittingSize.height
        )
    }
}

/// CALayer-backed titlebar background. Uses layer-level opacity (not per-pixel alpha)
/// to match how the terminal's Metal surface composites its background.
struct TitlebarLayerBackground: NSViewRepresentable {
    var backgroundColor: NSColor
    var opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        view.layer?.opacity = Float(opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        nsView.layer?.opacity = Float(opacity)
    }
}
