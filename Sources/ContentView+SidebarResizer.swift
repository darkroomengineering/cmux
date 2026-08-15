import AppKit
import SwiftUI

/// Owns the complete pointer lifecycle for the sidebar divider. AppKit keeps the
/// drag capture after the pointer crosses a portal-hosted terminal or browser,
/// so the SwiftUI root no longer needs a window-wide event monitor or cursor timer.
private final class NativeSidebarDividerView: NSView {
    private static let resizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )

    var currentWidth: CGFloat = 0
    var onResizeBegan: () -> Void = {}
    var onWidthChanged: (CGFloat) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    private var trackingArea: NSTrackingArea?
    private var windowResignObserver: NSObjectProtocol?
    private var dragStartWidth: CGFloat = 0
    private var dragStartWindowX: CGFloat = 0
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("SidebarResizer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.resizeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        guard let window else {
            cancelActiveResize()
            return
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.cancelActiveResize()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDragging else { return }
        isDragging = true
        dragStartWidth = currentWidth
        dragStartWindowX = event.locationInWindow.x
        Self.resizeCursor.set()
        onResizeBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        Self.resizeCursor.set()
        onWidthChanged(dragStartWidth + event.locationInWindow.x - dragStartWindowX)
    }

    override func mouseUp(with event: NSEvent) {
        finishResize()
    }

    func cancelActiveResize() {
        finishResize()
    }

    private func finishResize() {
        guard isDragging else { return }
        isDragging = false
        onResizeEnded()
    }
}

private struct NativeSidebarDividerRepresentable: NSViewRepresentable {
    let currentWidth: CGFloat
    let onResizeBegan: () -> Void
    let onWidthChanged: (CGFloat) -> Void
    let onResizeEnded: () -> Void

    func makeNSView(context: Context) -> NativeSidebarDividerView {
        NativeSidebarDividerView(frame: .zero)
    }

    func updateNSView(_ nsView: NativeSidebarDividerView, context: Context) {
        nsView.currentWidth = currentWidth
        nsView.onResizeBegan = onResizeBegan
        nsView.onWidthChanged = onWidthChanged
        nsView.onResizeEnded = onResizeEnded
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    static func dismantleNSView(_ nsView: NativeSidebarDividerView, coordinator: Void) {
        nsView.cancelActiveResize()
        nsView.onResizeBegan = {}
        nsView.onWidthChanged = { _ in }
        nsView.onResizeEnded = {}
    }
}

extension ContentView {
    private static let minimumSidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0

    private var sidebarResizerSidebarHitWidth: CGFloat {
        SidebarResizeInteraction.sidebarSideHitWidth
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return max(Self.minimumSidebarWidth, resolvedAvailableWidth * Self.maximumSidebarWidthRatio)
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1920
        return max(Self.minimumSidebarWidth, fallbackScreenWidth * Self.maximumSidebarWidthRatio)
    }

    static func clampedSidebarWidth(_ candidate: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        let minimumWidth = Self.minimumSidebarWidth
        let sanitizedMaximumWidth = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        }
        return max(minimumWidth, min(sanitizedMaximumWidth, candidate))
    }

    func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = Self.clampedSidebarWidth(
            sidebarWidth,
            maximumWidth: maxSidebarWidth(availableWidth: availableWidth)
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        Self.clampedSidebarWidth(candidate, maximumWidth: maxSidebarWidth())
    }

    var sidebarResizerOverlay: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let dividerX = min(max(sidebarWidth, 0), totalWidth)
            let leadingWidth = max(0, dividerX - sidebarResizerSidebarHitWidth)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                NativeSidebarDividerRepresentable(
                    currentWidth: sidebarWidth,
                    onResizeBegan: {
                        isSidebarResizerDragging = true
                        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
                    },
                    onWidthChanged: { candidate in
                        let nextWidth = Self.clampedSidebarWidth(
                            candidate,
                            maximumWidth: maxSidebarWidth(availableWidth: totalWidth)
                        )
                        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
                        withTransaction(Transaction(animation: nil)) {
                            sidebarWidth = nextWidth
                        }
                    },
                    onResizeEnded: {
                        isSidebarResizerDragging = false
                        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    }
                )
                .frame(width: SidebarResizeInteraction.totalHitWidth)
                .frame(maxHeight: .infinity)

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
            .onAppear {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
            .onChange(of: totalWidth) {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
        }
    }
}
