import Foundation

enum ProgramaGlassSurface: String, CaseIterable, Sendable {
    case window
    case sidebar
    case tabBar
    case browserToolbar
    case overlays

    var environmentKey: String {
        switch self {
        case .window:
            return "PROGRAMA_TEST_FORCE_WINDOW_GLASS"
        case .sidebar:
            return "PROGRAMA_TEST_FORCE_SIDEBAR_GLASS"
        case .tabBar:
            return "PROGRAMA_TEST_FORCE_TAB_BAR_GLASS"
        case .browserToolbar:
            return "PROGRAMA_TEST_FORCE_BROWSER_TOOLBAR_GLASS"
        case .overlays:
            return "PROGRAMA_TEST_FORCE_OVERLAY_GLASS"
        }
    }

    init?(commandValue: String) {
        switch commandValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "window": self = .window
        case "sidebar": self = .sidebar
        case "tabbar", "tab-bar", "tab_bar": self = .tabBar
        case "browsertoolbar", "browser-toolbar", "browser_toolbar": self = .browserToolbar
        case "overlay", "overlays": self = .overlays
        default: return nil
        }
    }
}

enum ProgramaGlassSettings {
    static let windowEnabledKey = "bgGlassEnabled"
    static let tabBarEnabledKey = "tabBarLiquidGlassEnabled"
    static let browserToolbarEnabledKey = "browserToolbarLiquidGlassEnabled"
    static let overlaysEnabledKey = "overlayLiquidGlassEnabled"

    /// Environment is snapshotted once. The perf harness launches a fresh process for each
    /// ON/OFF sample, so glass selection never adds environment reads to a rendering hot path.
    private static let startupEnvironment = ProcessInfo.processInfo.environment

    static func parseOverride(
        for surface: ProgramaGlassSurface,
        environment: [String: String]
    ) -> Bool? {
        guard let rawValue = environment[surface.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    static func startupOverride(for surface: ProgramaGlassSurface) -> Bool? {
        #if DEBUG
        parseOverride(for: surface, environment: startupEnvironment)
        #else
        nil
        #endif
    }

    static func resolvedEnabled(
        for surface: ProgramaGlassSurface,
        persistedValue: Bool
    ) -> Bool {
        startupOverride(for: surface) ?? persistedValue
    }

    /// A clean install uses the native inset panel only where AppKit can provide real Liquid
    /// Glass. Existing persisted sidebar choices continue to win over this startup default.
    static func defaultSidebarPreset(nativeGlassAvailable: Bool) -> SidebarPresetOption {
        nativeGlassAvailable ? .liquidGlass : .nativeSidebar
    }

    /// Registers platform defaults without overwriting an explicit user choice. Only surfaces
    /// that have passed their independent gate are enabled here; later phases extend this map.
    static func registerPlatformDefaults(
        defaults: UserDefaults = .standard,
        nativeGlassAvailable: Bool
    ) {
        defaults.register(defaults: [
            windowEnabledKey: nativeGlassAvailable,
            tabBarEnabledKey: false,
            browserToolbarEnabledKey: false,
            overlaysEnabledKey: false,
        ])
    }

    #if DEBUG
    /// Mutates only debug-build preferences. This is used by the footprint script against a
    /// tagged app and intentionally performs no app activation or focus-changing work.
    static func setDebugEnabled(
        _ enabled: Bool,
        for surface: ProgramaGlassSurface,
        defaults: UserDefaults = .standard
    ) {
        switch surface {
        case .window:
            if enabled {
                defaults.set(SidebarBlendModeOption.behindWindow.rawValue, forKey: "sidebarBlendMode")
            }
            defaults.set(enabled, forKey: windowEnabledKey)
        case .sidebar:
            defaults.set(false, forKey: windowEnabledKey)
            defaults.set(SidebarBlendModeOption.withinWindow.rawValue, forKey: "sidebarBlendMode")
            defaults.set(
                enabled ? SidebarMaterialOption.liquidGlass.rawValue : SidebarMaterialOption.sidebar.rawValue,
                forKey: "sidebarMaterial"
            )
        case .tabBar:
            defaults.set(enabled, forKey: tabBarEnabledKey)
        case .browserToolbar:
            defaults.set(enabled, forKey: browserToolbarEnabledKey)
        case .overlays:
            defaults.set(enabled, forKey: overlaysEnabledKey)
        }
    }
    #endif
}
