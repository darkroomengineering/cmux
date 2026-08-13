import AppKit
import Bonsplit

final class WindowDecorationsController {
    /// Injected by AppDelegate: NSWindow.identifier alone can't distinguish the
    /// SwiftUI-created main terminal windows.
    var isMainTerminalWindow: ((NSWindow) -> Bool)?
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private var trafficLightBaseFrames: [ObjectIdentifier: [NSWindow.ButtonType: NSRect]] = [:]

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
    }

    func apply(to window: NSWindow) {
        let shouldHideButtons = shouldHideTrafficLights(for: window)
        hideStandardButtons(on: window, hidden: shouldHideButtons)
        applyTrafficLightOffset(on: window, hidden: shouldHideButtons)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            self.apply(to: window)
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main, using: handler))
        // Titlebar layout resets button positions on resize and fullscreen churn.
        observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main, using: handler))
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }

    private func hideStandardButtons(on window: NSWindow, hidden: Bool) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func applyTrafficLightOffset(on window: NSWindow, hidden: Bool) {
        // Titlebar accessory sizing keeps relayouting the button row for a beat
        // after a window becomes key; a single async pass gets reverted. Re-apply
        // on a short settle ladder.
        for delay in [0.0, 0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window else { return }
                let offset = hidden ? NSPoint.zero : self.trafficLightOffset(for: window)
                self.applyTrafficLightOffsetNow(on: window, offset: offset)
            }
        }
    }

    private func applyTrafficLightOffsetNow(on window: NSWindow, offset: NSPoint) {
        let key = ObjectIdentifier(window)
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var baseFrames = trafficLightBaseFrames[key] ?? [:]

        for type in buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            if baseFrames[type] == nil || (baseFrames[type]?.isEmpty ?? true) {
                baseFrames[type] = button.frame
            }
        }

        trafficLightBaseFrames[key] = baseFrames

        for (index, type) in buttonTypes.enumerated() {
            guard let button = window.standardWindowButton(type), let base = baseFrames[type] else { continue }
            var target = NSPoint(x: base.origin.x + offset.x, y: base.origin.y + offset.y)
            if isMainTerminalWindow?(window) == true,
               let container = button.superview {
                // Match Maps' Tahoe-style metrics: first light 15pt in, 24pt
                // pitch (the hidden-titlebar default keeps the cramped legacy
                // 20pt pitch), centered on the panel header's midline
                // (panel top inset 6 + 38pt header row -> 25pt from window top).
                let firstButtonX: CGFloat = 17
                let buttonPitch: CGFloat = 24
                let rowCenterFromTop: CGFloat = 25
                target.x = firstButtonX + CGFloat(index) * buttonPitch
                let targetMidY = container.bounds.height - rowCenterFromTop
                target.y = targetMidY - base.height / 2
            }
            button.setFrameOrigin(target)
#if DEBUG
            if type == .closeButton {
                dlog(
                    "decor.lights ident=\(window.identifier?.rawValue.prefix(12) ?? "nil") " +
                    "base=\(base) target=\(target) offset=\(offset) " +
                    "containerH=\(button.superview?.bounds.height ?? -1)"
                )
            }
#endif
        }
    }

    private func trafficLightOffset(for window: NSWindow) -> NSPoint {
        if window.identifier?.rawValue == "cmux.settings" {
            // Nudge controls slightly right/down to align with the custom Settings title row.
            return NSPoint(x: 7, y: -4)
        }
        if isMainTerminalWindow?(window) == true {
            // Horizontal seat inside the glass panel; the vertical position is
            // computed geometrically in applyTrafficLightOffsetNow.
            return NSPoint(x: 6, y: 0)
        }
        return .zero
    }

    private func shouldHideTrafficLights(for window: NSWindow) -> Bool {
        if window.isSheet {
            return true
        }
        if window.styleMask.contains(.docModalWindow) {
            return true
        }
        if window.styleMask.contains(.nonactivatingPanel) {
            return true
        }
        return false
    }
}
