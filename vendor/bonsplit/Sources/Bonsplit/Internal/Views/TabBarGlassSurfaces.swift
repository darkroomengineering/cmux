import AppKit
import SwiftUI

enum TabBarGlassStyling {
    static let pillCornerRadius: CGFloat = 10
    static let pillSpacing: CGFloat = 5
    static let horizontalInset: CGFloat = 5
    static let verticalInset: CGFloat = 4
    static let barHeight: CGFloat = TabBarMetrics.tabHeight + (verticalInset * 2)
    static let mergeSpacing: CGFloat = 8

    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    static func tintColor(isSelected: Bool) -> NSColor? {
        isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : nil
    }
}

/// Makes one tab bar the AppKit parent for its peer glass pills. The container has no glass of
/// its own; it only batches and fluidly merges descendant `NSGlassEffectView` instances.
struct TabBarGlassContainerHost<Content: View>: NSViewRepresentable {
    let content: Content
    let spacing: CGFloat

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
            let container = NSGlassEffectContainerView(frame: .zero)
            container.autoresizingMask = [.width, .height]
            container.spacing = spacing
            hostingView.frame = container.bounds
            container.contentView = hostingView
            return container
        }
        #endif

        return hostingView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView.rootView = content

        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let container = nsView as? NSGlassEffectContainerView {
            container.spacing = spacing
        }
        #endif
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

/// Hosts every interactive pill inside its own glass content view, preserving AppKit's required
/// content ownership instead of painting SwiftUI controls as arbitrary siblings above glass.
struct TabPillGlassHost<Content: View>: NSViewRepresentable {
    let content: Content
    let tintColor: NSColor?
    let cornerRadius: CGFloat

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
            hostingView.frame = glass.bounds
            glass.contentView = hostingView
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
        }
        #endif
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
