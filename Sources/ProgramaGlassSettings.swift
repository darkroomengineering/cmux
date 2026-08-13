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

    static let sidebarMigrationVersionKey = "sidebarAppearanceDefaultsVersion"

    /// One-time sidebar appearance migration, version-gated via
    /// `sidebarAppearanceDefaultsVersion`. Values that the app itself stamped are
    /// migratable; values the user changed by hand are an explicit choice and win.
    static func migrateSidebarAppearanceDefaultsIfNeeded(
        defaults: UserDefaults,
        nativeGlassAvailable: Bool
    ) {
        let targetVersion = 3
        guard defaults.integer(forKey: sidebarMigrationVersionKey) < targetVersion else { return }

        let material = defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue
        let blendMode = defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.behindWindow.rawValue
        let state = defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue
        let tintHex = defaults.string(forKey: "sidebarTintHex") ?? "#101010"
        let tintOpacity = defaults.object(forKey: "sidebarTintOpacity") as? Double ?? 0.54
        let blurOpacity = defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 0.79
        let cornerRadius = defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0

        let usesLegacyDefaults =
            material == SidebarMaterialOption.sidebar.rawValue &&
            blendMode == SidebarBlendModeOption.behindWindow.rawValue &&
            state == SidebarStateOption.followWindow.rawValue &&
            normalizeHex(tintHex) == "101010" &&
            approximatelyEqual(tintOpacity, 0.54) &&
            approximatelyEqual(blurOpacity, 0.79) &&
            approximatelyEqual(cornerRadius, 0.0)

        // Migration v1 stamped every stock install with the nativeSidebar preset,
        // so on any machine that ran a post-v1 build the legacy fingerprint above
        // can no longer match — the Liquid Glass default would only ever reach
        // clean installs. The exact stamp is programmatic, not a user choice, so
        // v3 treats it as migratable too. Any hand-tuned value breaks the match
        // and keeps the user's setup.
        let v1Stamp = SidebarPresetOption.nativeSidebar
        let usesV1NativeSidebarStamp =
            material == v1Stamp.material.rawValue &&
            blendMode == v1Stamp.blendMode.rawValue &&
            state == v1Stamp.state.rawValue &&
            normalizeHex(tintHex) == normalizeHex(v1Stamp.tintHex) &&
            approximatelyEqual(tintOpacity, v1Stamp.tintOpacity) &&
            approximatelyEqual(blurOpacity, v1Stamp.blurOpacity) &&
            approximatelyEqual(cornerRadius, v1Stamp.cornerRadius)

        if usesLegacyDefaults || usesV1NativeSidebarStamp {
            applySidebarPreset(
                defaultSidebarPreset(nativeGlassAvailable: nativeGlassAvailable),
                defaults: defaults
            )
        } else if material == SidebarMaterialOption.liquidGlass.rawValue,
                  approximatelyEqual(cornerRadius, 0.0) {
            // Version 1 shipped the local glass sidebar flush on all four corners. Version 2
            // rounds only its terminal-facing edge; the NSWindow still masks the outer edge.
            defaults.set(SidebarPresetOption.liquidGlass.cornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(targetVersion, forKey: sidebarMigrationVersionKey)
    }

    private static func applySidebarPreset(
        _ preset: SidebarPresetOption,
        defaults: UserDefaults
    ) {
        defaults.set(preset.rawValue, forKey: "sidebarPreset")
        defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
        defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
        defaults.set(preset.state.rawValue, forKey: "sidebarState")
        defaults.set(preset.tintHex, forKey: "sidebarTintHex")
        defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
        defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
        defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
    }

    private static func normalizeHex(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    /// Registers platform defaults without overwriting an explicit user choice. Only surfaces
    /// that have passed their independent gate are enabled here; later phases extend this map.
    static func platformDefaults(nativeGlassAvailable: Bool) -> [String: Any] {
        [
            windowEnabledKey: nativeGlassAvailable,
            tabBarEnabledKey: false,
            browserToolbarEnabledKey: false,
            overlaysEnabledKey: nativeGlassAvailable,
        ]
    }

    static func registerPlatformDefaults(
        defaults: UserDefaults = .standard,
        nativeGlassAvailable: Bool
    ) {
        defaults.register(defaults: platformDefaults(nativeGlassAvailable: nativeGlassAvailable))
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
            defaults.set(
                enabled ? SidebarPresetOption.liquidGlass.cornerRadius : SidebarPresetOption.nativeSidebar.cornerRadius,
                forKey: "sidebarCornerRadius"
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
