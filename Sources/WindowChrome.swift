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
    static let sidebarHeaderHeight: CGFloat = 38
    /// Vertical midline of the header row measured from the window top.
    static var sidebarHeaderCenterFromWindowTop: CGFloat { sidebarPanelInset + sidebarHeaderHeight / 2 }

    /// The stock tint (#000000 @ 0.03) is effectively clear, which lets the
    /// desktop color wash through every translucent region and corner. Stock
    /// resolves to a terminal-toned grounding tint; explicit user tints win.
    static func resolvedWindowTint(hex: String, opacity: Double) -> NSColor {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "").uppercased()
        let isStock = normalized == "000000" && abs(opacity - 0.03) < 0.001
        if isStock {
            return GhosttyBackgroundTheme.currentColor().withAlphaComponent(0.55)
        }
        return (NSColor(hex: hex) ?? .black).withAlphaComponent(opacity)
    }
    private static var fullScreenObserverKey: UInt8 = 0

    @available(macOS 26.0, *)
    private static func applyWindowCornerMask(to glassView: NSView, rounded: Bool) {
        glassView.layer?.cornerRadius = rounded ? windowCornerRadius : 0
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.masksToBounds = rounded
    }

    /// The transparent titlebar still hosts a material backdrop that peeks out
    /// in the crescent between our large corner mask and the legacy frame shape
    /// at the two top corners — a lighter glitchy wedge. Hide the material; the
    /// buttons and accessories are separate views and stay visible.
    private static func hideTitlebarBackdrop(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        for child in frameView.subviews
        where String(describing: type(of: child)).contains("NSTitlebarContainerView") {
            for titlebarChild in descendants(of: child)
            where titlebarChild is NSVisualEffectView {
                titlebarChild.isHidden = true
            }
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @available(macOS 26.0, *)
    private static func installFullScreenRadiusObservers(for window: NSWindow, glassView: NSView) {
        let center = NotificationCenter.default
        let tokens: [NSObjectProtocol] = [
            center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
            ) { [weak glassView] _ in
                guard let glassView else { return }
                applyWindowCornerMask(to: glassView, rounded: false)
            },
            center.addObserver(
                forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
            ) { [weak glassView] _ in
                guard let glassView else { return }
                applyWindowCornerMask(to: glassView, rounded: true)
            },
            // Shadow must re-derive from content alpha after size/shape changes.
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak window] _ in
                window?.invalidateShadow()
            },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak window] _ in
                DispatchQueue.main.async { window?.invalidateShadow() }
            },
        ]
        objc_setAssociatedObject(window, &fullScreenObserverKey, tokens, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func apply(to window: NSWindow, tintColor: NSColor? = nil) {
        guard let originalContentView = window.contentView else { return }

        // Check if we already applied glass (avoid re-wrapping)
        if let existingGlass = objc_getAssociatedObject(window, &glassViewKey) as? NSView {
            // Already applied, just update the tint
            updateTint(on: existingGlass, color: tintColor, window: window)
            return
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            applyGlass(to: window, originalContentView: originalContentView, tintColor: tintColor)
            return
        }
        #endif
        applyVisualEffectFallback(to: window, originalContentView: originalContentView, tintColor: tintColor)
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func applyGlass(to window: NSWindow, originalContentView: NSView, tintColor: NSColor?) {
        let glassView = NSGlassEffectView(frame: originalContentView.bounds)
        glassView.wantsLayer = true
        // Match the modern large window radius (Maps-style); the sidebar panel's
        // radius is derived as this minus its inset to stay concentric. Shape via
        // a plain layer mask, not NSGlassEffectView.cornerRadius: the glass draws
        // a specular rim at its own rounded boundary, which reads as a ghost
        // border against dark content. A layer cut has no rim.
        glassView.cornerRadius = 0
        // Opaque terminal-colored backing: backdrop sampling bleeds the desktop
        // into a rim wherever fills are translucent, which reads as a glitchy
        // inconsistent border. In-window glass elements are unaffected — they
        // sample window content, not the desktop.
        glassView.layer?.backgroundColor =
            GhosttyBackgroundTheme.currentColor().withAlphaComponent(1.0).cgColor
        applyWindowCornerMask(to: glassView, rounded: !window.styleMask.contains(.fullScreen))
        installFullScreenRadiusObservers(for: window, glassView: glassView)
        // The system window backdrop keeps its own smaller-radius shape; between
        // it and our larger mask it peeks out as a ghost arc in each corner.
        // A clear window lets the shadow and edge follow the masked shape only.
        window.isOpaque = false
        window.backgroundColor = .clear
        // A non-opaque window's shadow only re-derives from content alpha on
        // explicit invalidation; without it the old square-ish shadow rings the
        // corner crescents and they read as transparent holes.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            hideTitlebarBackdrop(in: window)
            window.invalidateShadow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            guard let window else { return }
            hideTitlebarBackdrop(in: window)
            window.invalidateShadow()
        }
        glassView.tintColor = tintColor
        glassView.autoresizingMask = [.width, .height]

        // NSGlassEffectView is a full replacement for the contentView.
        objc_setAssociatedObject(window, &originalContentViewKey, originalContentView, .OBJC_ASSOCIATION_RETAIN)
        window.contentView = glassView

        // AppKit only guarantees correct control placement when the controls are owned by
        // NSGlassEffectView.contentView. Portal-hosted terminal surfaces remain siblings below
        // this host, where they continue to provide the source pixels sampled by the effect.
        originalContentView.frame = glassView.bounds
        originalContentView.autoresizingMask = [.width, .height]
        originalContentView.wantsLayer = true
        originalContentView.layer?.backgroundColor = NSColor.clear.cgColor
        glassView.contentView = originalContentView

        objc_setAssociatedObject(window, &glassViewKey, glassView, .OBJC_ASSOCIATION_RETAIN)
    }
    #endif

    private static func applyVisualEffectFallback(to window: NSWindow, originalContentView: NSView, tintColor: NSColor?) {
        let bounds = originalContentView.bounds
        let glassView = NSVisualEffectView(frame: bounds)
        glassView.blendingMode = .behindWindow
        // Favor a lighter fallback so behind-window glass reads more transparent.
        glassView.material = .underWindowBackground
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.autoresizingMask = [.width, .height]

        // For the NSVisualEffectView fallback, do NOT replace window.contentView.
        // Replacing contentView can break traffic light rendering with
        // `.fullSizeContentView` + `titlebarAppearsTransparent`.
        glassView.translatesAutoresizingMaskIntoConstraints = false
        originalContentView.addSubview(glassView, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: originalContentView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: originalContentView.bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: originalContentView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: originalContentView.trailingAnchor)
        ])

        // Add tint overlay between glass and content
        if let tintColor {
            let tintOverlay = NSView(frame: bounds)
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = tintColor.cgColor
            glassView.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: glassView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
            ])
            objc_setAssociatedObject(window, &tintOverlayKey, tintOverlay, .OBJC_ASSOCIATION_RETAIN)
        }

        objc_setAssociatedObject(window, &glassViewKey, glassView, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Update the tint color on an existing glass effect
    static func updateTint(to window: NSWindow, color: NSColor?) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else { return }
        updateTint(on: glassView, color: color, window: window)
    }

    private static func updateTint(on glassView: NSView, color: NSColor?, window: NSWindow) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.tintColor = color
            // Keep the opaque backing in step with the terminal theme.
            glass.layer?.backgroundColor =
                GhosttyBackgroundTheme.currentColor().withAlphaComponent(1.0).cgColor
            return
        }
        #endif
        // For NSVisualEffectView fallback, update the tint overlay
        if let tintOverlay = objc_getAssociatedObject(window, &tintOverlayKey) as? NSView {
            tintOverlay.layer?.backgroundColor = color?.cgColor
        }
    }

    static func remove(from window: NSWindow) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else {
            return
        }

        if isGlassEffectView(glassView) {
            if let originalContentView = objc_getAssociatedObject(window, &originalContentViewKey) as? NSView {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
                    glass.contentView = nil
                }
                #endif
                originalContentView.removeFromSuperview()
                originalContentView.autoresizingMask = [.width, .height]
                originalContentView.frame = glassView.bounds
                window.contentView = originalContentView
            }
        } else {
            glassView.removeFromSuperview()
        }

        if let tokens = objc_getAssociatedObject(window, &fullScreenObserverKey) as? [NSObjectProtocol] {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
        objc_setAssociatedObject(window, &fullScreenObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
