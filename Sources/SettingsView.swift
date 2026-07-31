import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins


struct SettingsView: View {
    // The header overlay now carries a tab strip under the title, so content has
    // to start below both rather than just below the title.
    private let contentTopInset: CGFloat = 42
    private let headerHeight: CGFloat = 96

    @State private var selectedTab: SettingsTab = .general
    private let pickerColumnWidth: CGFloat = 196
    private let notificationSoundControlWidth: CGFloat = 280
    private let shortcutChordsDocsURL = URL(string: "https://github.com/darkroomengineering/programa/tree/main/docs")!

    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(MobileBridgeSettings.appStorageKey) private var mobileBridgeMode = MobileBridgeSettings.defaultMode.rawValue
    @AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)
    private var claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
    @AppStorage(ClaudeCodeIntegrationSettings.customClaudePathKey)
    private var customClaudePath = ""
    @AppStorage(AgentScreenDetectionSettings.enabledKey)
    private var agentScreenDetectionEnabled = AgentScreenDetectionSettings.defaultEnabled
    @AppStorage(PreferredEditorSettings.key) private var preferredEditorCommand = ""
    @AppStorage("cmuxPortBase") private var programaPortBase = 9100
    @AppStorage("cmuxPortRange") private var programaPortRange = 10
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankTabsKey) private var showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintSettings.dismissedKey) private var isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
    @AppStorage(BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey) private var openTerminalLinksInProgramaBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInProgramaBrowser
    @AppStorage(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowserKey)
    private var interceptTerminalOpenCommandInProgramaBrowser = BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInProgramaBrowserValue()
    @AppStorage(BrowserLinkOpenSettings.browserHostWhitelistKey) private var browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
    @AppStorage(BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
    private var browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
    @AppStorage(BrowserInsecureHTTPSettings.allowlistKey) private var browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
    @AppStorage(NotificationSoundSettings.key) private var notificationSound = NotificationSoundSettings.defaultValue
    @AppStorage(NotificationSoundSettings.customFilePathKey)
    private var notificationSoundCustomFilePath = NotificationSoundSettings.defaultCustomFilePath
    @AppStorage(NotificationSoundSettings.customCommandKey) private var notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
    @AppStorage(MenuBarExtraSettings.showInMenuBarKey) private var showMenuBarExtra = MenuBarExtraSettings.defaultShowInMenuBar
    @AppStorage(LongCommandNotificationSettings.thresholdSecondsKey)
    private var longCommandThresholdSeconds = LongCommandNotificationSettings.defaultThresholdSeconds
    @AppStorage(QuitWarningSettings.warnBeforeQuitKey) private var warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
    @AppStorage(ScrollbackPersistenceSettings.persistScrollbackKey) private var sessionPersistScrollback = ScrollbackPersistenceSettings.defaultPersistScrollback
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey)
    private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?
    @AppStorage("sidebarNotificationBadgeColorHex") private var sidebarNotificationBadgeColorHex: String?
    @AppStorage(ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
    private var showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false
    @AppStorage("sidebarShowClaudeQuota") private var showClaudeQuota = true

    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var shortcutResetToken = UUID()
    @State private var topBlurOpacity: Double = 0
    @State private var topBlurBaselineOffset: CGFloat?
    @State private var settingsTitleLeadingInset: CGFloat = 92
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var browserHistoryEntryCount: Int = 0
    @State private var detectedImportBrowsers: [InstalledBrowserCandidate] = []
    @State private var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    @State private var socketPasswordDraft = ""
    @State private var socketPasswordStatusMessage: String?
    @State private var socketPasswordStatusIsError = false
    @State private var notificationCustomSoundStatusMessage: String?
    @State private var notificationCustomSoundStatusIsError = false
    @State private var showNotificationCustomSoundErrorAlert = false
    @State private var notificationCustomSoundErrorAlertMessage = ""
    @State private var trustedDirectoriesDraft: String = ProgramaDirectoryTrust.shared.allTrustedPaths.joined(separator: "\n")
    @State private var mobileBridgePairedDevices: [MobileBridgeTrustedDevice] = []
    @State private var mobileBridgePairingTicket: String?
    @State private var mobileBridgePairingToken: String?
    @State private var mobileBridgePairingExpiresAt: Date?
    @State private var mobileBridgePairingErrorMessage: String?
    @State private var isPairingMobileBridgeDevice = false

    private var selectedWorkspacePlacement: NewWorkspacePlacement {
        NewWorkspacePlacement(rawValue: newWorkspacePlacement) ?? WorkspacePlacementSettings.defaultPlacement
    }

    private var minimalModeEnabled: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var minimalModeSubtitle: String {
        if minimalModeEnabled {
            return String(
                localized: "settings.app.minimalMode.subtitleOn",
                defaultValue: "Hide the workspace title bar and move workspace controls into the sidebar."
            )
        }
        return String(
            localized: "settings.app.minimalMode.subtitleOff",
            defaultValue: "Use the standard workspace title bar and controls."
        )
    }

    private var selectedSidebarActiveTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    private var selectedSocketControlMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var selectedBrowserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeMode)
    }

    private var browserThemeModeSelection: Binding<String> {
        Binding(
            get: { browserThemeMode },
            set: { newValue in
                browserThemeMode = BrowserThemeSettings.mode(for: newValue).rawValue
            }
        )
    }

    private var browserImportHintPresentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            showOnBlankTabs: showBrowserImportHintOnBlankTabs,
            isDismissed: isBrowserImportHintDismissed
        )
    }

    private var browserImportHintVisibilityBinding: Binding<Bool> {
        Binding(
            get: { showBrowserImportHintOnBlankTabs },
            set: { newValue in
                showBrowserImportHintOnBlankTabs = newValue
                if newValue {
                    isBrowserImportHintDismissed = false
                }
            }
        )
    }

    private var socketModeSelection: Binding<String> {
        Binding(
            get: { socketControlMode },
            set: { newValue in
                let normalized = SocketControlSettings.migrateMode(newValue)
                if normalized == .allowAll && selectedSocketControlMode != .allowAll {
                    pendingOpenAccessMode = normalized
                    showOpenAccessConfirmation = true
                    return
                }
                socketControlMode = normalized.rawValue
                if normalized != .password {
                    socketPasswordStatusMessage = nil
                    socketPasswordStatusIsError = false
                }
            }
        )
    }

    private var minimalModeBinding: Binding<Bool> {
        Binding(
            get: { minimalModeEnabled },
            set: { newValue in
                workspacePresentationMode = newValue
                    ? WorkspacePresentationModeSettings.Mode.minimal.rawValue
                    : WorkspacePresentationModeSettings.Mode.standard.rawValue
                SettingsWindowController.shared.preserveFocusAfterPreferenceMutation()
            }
        )
    }

    private var hasSocketPasswordConfigured: Bool {
        SocketControlPasswordStore.hasConfiguredPassword()
    }

    private var browserHistorySubtitle: String {
        switch browserHistoryEntryCount {
        case 0:
            return String(localized: "settings.browser.history.subtitleEmpty", defaultValue: "No saved pages yet.")
        case 1:
            return String(localized: "settings.browser.history.subtitleOne", defaultValue: "1 saved page appears in omnibar suggestions.")
        default:
            return String(localized: "settings.browser.history.subtitleMany", defaultValue: "\(browserHistoryEntryCount) saved pages appear in omnibar suggestions.")
        }
    }

    private var browserImportHintSettingsNote: String {
        switch browserImportHintPresentation.settingsStatus {
        case .visible:
            return String(localized: "settings.browser.import.hint.note.visible", defaultValue: "Blank browser tabs can show this import suggestion. Hide or re-enable it here.")
        case .hidden:
            return String(localized: "settings.browser.import.hint.note.hidden", defaultValue: "The blank-tab import hint is hidden. Turn it back on here any time.")
        }
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlist
    }

    private func saveTrustedDirectories() {
        let paths = trustedDirectoriesDraft
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        ProgramaDirectoryTrust.shared.replaceAll(with: paths)
    }

    private var hasCustomNotificationSoundFilePath: Bool {
        !notificationSoundCustomFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var notificationSoundCustomFileDisplayName: String {
        guard hasCustomNotificationSoundFilePath else {
            return String(
                localized: "settings.notifications.sound.custom.file.none",
                defaultValue: "No file selected"
            )
        }
        return URL(fileURLWithPath: notificationSoundCustomFilePath).lastPathComponent
    }

    private var canPreviewNotificationSound: Bool {
        switch notificationSound {
        case "none":
            return false
        case NotificationSoundSettings.customFileValue:
            return hasCustomNotificationSoundFilePath
        default:
            return true
        }
    }

    private var notificationPermissionStatusText: String {
        notificationStore.authorizationState.statusLabel
    }

    private var notificationPermissionStatusColor: Color {
        switch notificationStore.authorizationState {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        case .unknown, .notDetermined:
            return .secondary
        }
    }

    private var notificationPermissionSubtitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return "Desktop notifications are not enabled yet."
        case .authorized:
            return "Desktop notifications are enabled."
        case .denied:
            return "Desktop notifications are disabled in System Settings."
        case .provisional:
            return "Desktop notifications are enabled with quiet delivery."
        case .ephemeral:
            return "Desktop notifications are temporarily enabled."
        }
    }

    private var notificationPermissionActionTitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return "Enable"
        case .authorized, .denied, .provisional, .ephemeral:
            return "Open Settings"
        }
    }

    private func blurOpacity(forContentOffset offset: CGFloat) -> Double {
        guard let baseline = topBlurBaselineOffset else { return 0 }
        let reveal = (baseline - offset) / 24
        return Double(min(max(reveal, 0), 1))
    }

    private func previewNotificationSound() {
        if notificationSound == NotificationSoundSettings.customFileValue {
            NotificationSoundSettings.playCustomFileSound(path: notificationSoundCustomFilePath)
            return
        }
        NotificationSoundSettings.previewSound(value: notificationSound)
    }

    private func notificationCustomSoundIssueMessage(_ issue: NotificationSoundSettings.CustomSoundPreparationIssue) -> String {
        switch issue {
        case .emptyPath:
            return String(
                localized: "settings.notifications.sound.custom.status.empty",
                defaultValue: "Choose a custom audio file first."
            )
        case .missingFile(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return String(
                localized: "settings.notifications.sound.custom.status.missingFilePrefix",
                defaultValue: "File not found: "
            ) + fileName
        case .missingFileExtension(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return String(
                localized: "settings.notifications.sound.custom.status.missingExtensionPrefix",
                defaultValue: "File needs an extension: "
            ) + fileName
        case .stagingFailed(_, let details):
            let prefix = String(
                localized: "settings.notifications.sound.custom.status.prepareFailed",
                defaultValue: "Could not prepare this file for notifications. Try WAV, AIFF, or CAF."
            )
            return "\(prefix) (\(details))"
        }
    }

    private func notificationCustomSoundReadyStatusMessage(for path: String) -> String {
        let sourceExtension = URL(fileURLWithPath: path).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stagedExtension = NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)
        if !sourceExtension.isEmpty, stagedExtension != sourceExtension {
            return String(
                localized: "settings.notifications.sound.custom.status.readyConverted",
                defaultValue: "Prepared for notifications (converted to CAF)."
            )
        }
        return String(
            localized: "settings.notifications.sound.custom.status.ready",
            defaultValue: "Ready for notifications."
        )
    }

    private func refreshNotificationCustomSoundStatus(showAlertOnFailure: Bool = false) {
        guard notificationSound == NotificationSoundSettings.customFileValue else {
            notificationCustomSoundStatusMessage = nil
            notificationCustomSoundStatusIsError = false
            return
        }
        let pathSnapshot = notificationSoundCustomFilePath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotificationSoundSettings.prepareCustomFileForNotifications(path: pathSnapshot)
            DispatchQueue.main.async {
                guard notificationSound == NotificationSoundSettings.customFileValue else {
                    notificationCustomSoundStatusMessage = nil
                    notificationCustomSoundStatusIsError = false
                    return
                }
                guard notificationSoundCustomFilePath == pathSnapshot else { return }
                switch result {
                case .success:
                    notificationCustomSoundStatusMessage = notificationCustomSoundReadyStatusMessage(for: pathSnapshot)
                    notificationCustomSoundStatusIsError = false
                case .failure(let issue):
                    let message = notificationCustomSoundIssueMessage(issue)
                    notificationCustomSoundStatusMessage = message
                    notificationCustomSoundStatusIsError = true
                    if showAlertOnFailure {
                        notificationCustomSoundErrorAlertMessage = message
                        showNotificationCustomSoundErrorAlert = true
                    }
                }
            }
        }
    }

    private func chooseNotificationSoundFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.title = String(
            localized: "settings.notifications.sound.custom.choose.title",
            defaultValue: "Choose Notification Sound"
        )
        panel.prompt = String(
            localized: "settings.notifications.sound.custom.choose.prompt",
            defaultValue: "Choose"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selectedPath = url.path
        switch NotificationSoundSettings.prepareCustomFileForNotifications(path: selectedPath) {
        case .success:
            notificationSoundCustomFilePath = selectedPath
            notificationSound = NotificationSoundSettings.customFileValue
            notificationCustomSoundStatusMessage = notificationCustomSoundReadyStatusMessage(for: selectedPath)
            notificationCustomSoundStatusIsError = false
            previewNotificationSound()
        case .failure(let issue):
            let message = notificationCustomSoundIssueMessage(issue)
            notificationCustomSoundErrorAlertMessage = message
            showNotificationCustomSoundErrorAlert = true
            refreshNotificationCustomSoundStatus()
        }
    }

    private func handleNotificationPermissionAction() {
        let state = notificationStore.authorizationState.statusLabel
#if DEBUG
        dlog("notification.ui enableTapped state=\(state)")
#endif
        NSLog("notification.ui enableTapped state=%@", state)
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            notificationStore.requestAuthorizationFromSettings()
        case .authorized, .denied, .provisional, .ephemeral:
            notificationStore.openNotificationSettings()
        }
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.enterFirst", defaultValue: "Enter a password first.")
            socketPasswordStatusIsError = true
            return
        }

        do {
            try SocketControlPasswordStore.savePassword(trimmed)
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saved", defaultValue: "Password saved.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saveFailed", defaultValue: "Failed to save password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    private func clearSocketPassword() {
        do {
            try SocketControlPasswordStore.clearPassword()
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Password cleared.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.clearFailed", defaultValue: "Failed to clear password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    var body: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedTab {
                    case .general:
                        appSection
                        resetSection
                    case .appearance:
                        workspaceColorsSection
                        sidebarAppearanceSection
                    case .automation:
                        automationSection
                        customCommandsSection
                    case .phone:
                        phoneSection
                    case .browser:
                        browserSection
                    case .shortcuts:
                        keyboardShortcutsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, contentTopInset)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SettingsTopOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("SettingsScrollArea")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "SettingsScrollArea")
            .onPreferenceChange(SettingsTopOffsetPreferenceKey.self) { value in
                if topBlurBaselineOffset == nil {
                    topBlurBaselineOffset = value
                }
                topBlurOpacity = blurOpacity(forContentOffset: value)
            }

            ZStack(alignment: .top) {
                SettingsTitleLeadingInsetReader(inset: $settingsTitleLeadingInset)
                    .frame(width: 0, height: 0)

                AboutVisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                    .mask(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.9),
                                Color.black.opacity(0.64),
                                Color.black.opacity(0.36),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.52)

                AboutVisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                    .mask(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.98),
                                Color.black.opacity(0.78),
                                Color.black.opacity(0.42),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.14 + (topBlurOpacity * 0.86))

                VStack(spacing: 8) {
                    HStack {
                        Text(String(localized: "settings.title", defaultValue: "Settings"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.92))
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            SettingsHeaderActionButton(
                                title: String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open settings.json"),
                                helpText: KeyboardShortcutSettings.settingsFileStore.settingsFileDisplayPath(),
                                accessibilityIdentifier: "SettingsFileOpenButton",
                                action: openProgramaSettingsFileInTextEdit
                            )
                        }
                    }
                    .padding(.leading, settingsTitleLeadingInset)
                    .padding(.trailing, 20)

                    // Lives in the header overlay rather than the scroll content so
                    // it stays put while a tab's rows scroll under the blur.
                    Picker("", selection: $selectedTab) {
                        ForEach(SettingsTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .padding(.leading, settingsTitleLeadingInset)
                    .padding(.trailing, 20)
                    .accessibilityIdentifier("SettingsTabPicker")
                }
                .padding(.top, 12)
            }
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.07))
                        .frame(height: 1),
                    alignment: .bottom
                )
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .toggleStyle(.switch)
        .onAppear {
            BrowserHistoryStore.shared.loadIfNeeded()
            notificationStore.refreshAuthorizationStatus()
            browserThemeMode = BrowserThemeSettings.mode(defaults: .standard).rawValue
            browserHistoryEntryCount = BrowserHistoryStore.shared.entries.count
            browserInsecureHTTPAllowlistDraft = browserInsecureHTTPAllowlist
            refreshDetectedImportBrowsers()
            refreshNotificationCustomSoundStatus()
            Task { await refreshMobileBridgePairedDevices() }
        }
        .onChange(of: notificationSound) { _, _ in
            refreshNotificationCustomSoundStatus()
        }
        .onChange(of: notificationSoundCustomFilePath) { _, _ in
            refreshNotificationCustomSoundStatus()
        }
        .onChange(of: browserInsecureHTTPAllowlist) { oldValue, newValue in
            // Keep draft in sync with external changes unless the user has local unsaved edits.
            if browserInsecureHTTPAllowlistDraft == oldValue {
                browserInsecureHTTPAllowlistDraft = newValue
            }
        }
        .onReceive(BrowserHistoryStore.shared.$entries) { entries in
            browserHistoryEntryCount = entries.count
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
            guard let target = SettingsNavigationRequest.target(from: notification) else { return }
            // Select the owning tab first. The anchor only exists while its tab is
            // the selected one, so scrolling in the same pass would find nothing.
            selectedTab = SettingsTab.owning(target)
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
        .confirmationDialog(
            String(localized: "settings.browser.history.clearDialog.title", defaultValue: "Clear browser history?"),
            isPresented: $showClearBrowserHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.browser.history.clearDialog.confirm", defaultValue: "Clear History"), role: .destructive) {
                BrowserHistoryStore.shared.clearHistory()
            }
            Button(String(localized: "settings.browser.history.clearDialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.browser.history.clearDialog.message", defaultValue: "This removes visited-page suggestions from the browser omnibar."))
        }
        .confirmationDialog(
            String(localized: "settings.automation.openAccess.dialog.title", defaultValue: "Enable full open access?"),
            isPresented: $showOpenAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.automation.openAccess.dialog.confirm", defaultValue: "Enable Full Open Access"), role: .destructive) {
                socketControlMode = (pendingOpenAccessMode ?? .allowAll).rawValue
                pendingOpenAccessMode = nil
            }
            Button(String(localized: "settings.automation.openAccess.dialog.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingOpenAccessMode = nil
            }
        } message: {
            Text(String(localized: "settings.automation.openAccess.dialog.message", defaultValue: "This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk."))
        }
        .alert(
            String(
                localized: "settings.notifications.sound.custom.error.title",
                defaultValue: "Custom Notification Sound Error"
            ),
            isPresented: $showNotificationCustomSoundErrorAlert
        ) {
            Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(notificationCustomSoundErrorAlertMessage)
        }
        }
    }

    @ViewBuilder
    private var appSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.app", defaultValue: "App"))
        SettingsCard {
            ThemePickerRow(
                selectedMode: appearanceMode,
                onSelect: { mode in
                    appearanceMode = mode.rawValue
                }
            )

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                subtitle: selectedWorkspacePlacement.description,
                controlWidth: pickerColumnWidth,
                selection: $newWorkspacePlacement
            ) {
                ForEach(NewWorkspacePlacement.allCases) { placement in
                    Text(placement.displayName).tag(placement.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"),
                subtitle: minimalModeSubtitle
            ) {
                Toggle("", isOn: minimalModeBinding)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsMinimalModeToggle")
                    .accessibilityLabel(
                        String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode")
                    )
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"),
                subtitle: String(localized: "settings.app.preferredEditor.subtitle", defaultValue: "Command to open files on Cmd-click. Leave empty for system default.")
            ) {
                TextField(
                    String(localized: "settings.app.preferredEditor.placeholder", defaultValue: "e.g. code, zed, subl"),
                    text: $preferredEditorCommand
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
            ) {
                Toggle("", isOn: $workspaceAutoReorder)
                    .labelsHidden()
                    .controlSize(.small)
            }


            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"),
                subtitle: String(localized: "settings.app.showInMenuBar.subtitle", defaultValue: "Keep Programa in the menu bar for unread notifications and quick actions.")
            ) {
                Toggle("", isOn: $showMenuBarExtra)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar")
                    )
            }


            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.desktop.title", defaultValue: "Desktop Notifications"),
                subtitle: notificationPermissionSubtitle
            ) {
                HStack(spacing: 6) {
                    Text(notificationPermissionStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(notificationPermissionStatusColor)
                        .frame(width: 98, alignment: .trailing)

                    Button(notificationPermissionActionTitle) {
                        handleNotificationPermissionAction()
                    }
                    .controlSize(.small)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"),
                subtitle: String(localized: "settings.notifications.sound.subtitle", defaultValue: "Sound played when a notification arrives."),
                controlWidth: notificationSoundControlWidth
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Picker("", selection: $notificationSound) {
                            ForEach(NotificationSoundSettings.systemSounds, id: \.value) { sound in
                                Text(sound.label).tag(sound.value)
                            }
                        }
                        .labelsHidden()
                        Button {
                            previewNotificationSound()
                        } label: {
                            Image(systemName: "play.fill")
                                .symbolRasterSize(9)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canPreviewNotificationSound)
                    }

                    if notificationSound == NotificationSoundSettings.customFileValue {
                        HStack(spacing: 6) {
                            Text(notificationSoundCustomFileDisplayName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 170, alignment: .trailing)
                            Button(
                                String(
                                    localized: "settings.notifications.sound.custom.choose.button",
                                    defaultValue: "Choose..."
                                )
                            ) {
                                chooseNotificationSoundFile()
                            }
                            .controlSize(.small)
                            Button(
                                String(
                                    localized: "settings.notifications.sound.custom.clear.button",
                                    defaultValue: "Clear"
                                )
                            ) {
                                notificationSoundCustomFilePath = NotificationSoundSettings.defaultCustomFilePath
                                refreshNotificationCustomSoundStatus()
                            }
                            .controlSize(.small)
                            .disabled(!hasCustomNotificationSoundFilePath)
                        }
                        if let notificationCustomSoundStatusMessage {
                            Text(notificationCustomSoundStatusMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(notificationCustomSoundStatusIsError ? Color.red : Color.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 260, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.command.title", defaultValue: "Notification Command"),
                subtitle: String(
                    localized: "settings.notifications.command.subtitle",
                    defaultValue: "Run a shell command when a notification arrives. $PROGRAMA_NOTIFICATION_TITLE, $PROGRAMA_NOTIFICATION_SUBTITLE, $PROGRAMA_NOTIFICATION_BODY are set."
                )
            ) {
                TextField(
                    String(localized: "settings.notifications.command.placeholder", defaultValue: "say \"done\""),
                    text: $notificationCustomCommand
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.longCommandThreshold.title", defaultValue: "Long Command Notification"),
                subtitle: String(
                    localized: "settings.notifications.longCommandThreshold.subtitle",
                    defaultValue: "Notify when a command finishes in a pane you're not looking at, if it ran at least this long. Set to 0 to disable."
                ),
                controlWidth: pickerColumnWidth
            ) {
                HStack(spacing: 4) {
                    TextField("", value: $longCommandThresholdSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .accessibilityLabel(
                            String(localized: "settings.notifications.longCommandThreshold.title", defaultValue: "Long Command Notification")
                        )
                    Text(String(localized: "settings.notifications.longCommandThreshold.unit", defaultValue: "sec"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                subtitle: warnBeforeQuitShortcut
                    ? String(localized: "settings.app.warnBeforeQuit.subtitleOn", defaultValue: "Show a confirmation before quitting with Cmd+Q.")
                    : String(localized: "settings.app.warnBeforeQuit.subtitleOff", defaultValue: "Cmd+Q quits immediately without confirmation.")
            ) {
                Toggle("", isOn: $warnBeforeQuitShortcut)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.persistScrollback", defaultValue: "Save Scrollback on Quit"),
                subtitle: sessionPersistScrollback
                    ? String(localized: "settings.app.persistScrollback.subtitleOn", defaultValue: "Terminal scrollback is saved and restored on next launch.")
                    : String(localized: "settings.app.persistScrollback.subtitleOff", defaultValue: "Terminal scrollback is not written to disk.")
            ) {
                Toggle("", isOn: $sessionPersistScrollback)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"),
                subtitle: commandPaletteSearchAllSurfaces
                    ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches terminal, browser, and markdown surfaces across workspaces.")
                    : String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOff", defaultValue: "Cmd+P matches workspace rows only.")
            ) {
                Toggle("", isOn: $commandPaletteSearchAllSurfaces)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
                    .accessibilityLabel(
                        String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces")
                    )
            }

        }

    }

    @ViewBuilder
    private var workspaceColorsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"),
                controlWidth: pickerColumnWidth,
                selection: sidebarIndicatorStyleSelection
            ) {
                ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            // Selection-highlight and notification-badge hex pickers, the inline
            // palette editor and a section-local Reset Palette used to follow. The
            // editor duplicated settings.json, which its own note already pointed at
            // as the way to manage named colors, and the two hex pickers were the
            // same per-pixel tuning as the sidebar tints. "Reset all settings" still
            // calls WorkspaceTabColorSettings.reset() and nils both hex keys, so
            // anything set while these rows existed is still recoverable.
        }

    }

    @ViewBuilder
    private var sidebarAppearanceSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar Appearance"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"),
                subtitle: String(localized: "settings.sidebarAppearance.matchTerminalBackground.subtitle", defaultValue: "Use the same background color and transparency as the terminal.")
            ) {
                Toggle("", isOn: $sidebarMatchTerminalBackground)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.sidebarAppearance.showClaudeQuota", defaultValue: "Show Claude Quota"),
                subtitle: String(localized: "settings.sidebarAppearance.showClaudeQuota.subtitle", defaultValue: "Show remaining Claude Code usage quota in the sidebar footer.")
            ) {
                Toggle("", isOn: $showClaudeQuota)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.sidebarAppearance.showClaudeQuota", defaultValue: "Show Claude Quota")
                    )
            }
            // Light/dark tint hex, tint opacity and a section-local reset used to
            // live here. They were per-pixel tuning of one surface, shipped to
            // every user, and the same four keys are already bound by the Debug
            // window (DebugWindows.swift) where that kind of tuning belongs. The
            // bindings stay on this view because "Reset all settings" below still
            // restores them for anyone who set a value while the rows existed.
        }
    }

    @ViewBuilder
    private var automationSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.automation", defaultValue: "Automation"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                subtitle: selectedSocketControlMode.description,
                controlWidth: pickerColumnWidth,
                selection: socketModeSelection,
                accessibilityId: "AutomationSocketModePicker"
            ) {
                ForEach(SocketControlMode.uiCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.socketMode.note", defaultValue: "Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model."))
            if selectedSocketControlMode == .password {
                SettingsCardDivider()
                SettingsCardRow(
                    String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                    subtitle: hasSocketPasswordConfigured
                        ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                        : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"), text: $socketPasswordDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Button(hasSocketPasswordConfigured ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change") : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")) {
                            saveSocketPassword()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasSocketPasswordConfigured {
                            Button(String(localized: "settings.automation.socketPassword.clear", defaultValue: "Clear")) {
                                clearSocketPassword()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if let message = socketPasswordStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(socketPasswordStatusIsError ? Color.red : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            if selectedSocketControlMode == .allowAll {
                SettingsCardDivider()
                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: PROGRAMA_SOCKET_ENABLE, PROGRAMA_SOCKET_MODE, and PROGRAMA_SOCKET_PATH (set PROGRAMA_ALLOW_SOCKET_OVERRIDE=1 for release builds)."))
        }

        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                subtitle: claudeCodeHooksEnabled
                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without Programa integration.")
            ) {
                Toggle("", isOn: $claudeCodeHooksEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, Programa wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))
        }

        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.agentScreenDetection", defaultValue: "Screen-Based Agent Detection"),
                subtitle: agentScreenDetectionEnabled
                    ? String(localized: "settings.automation.agentScreenDetection.subtitleOn", defaultValue: "Infers working/blocked/idle status for agent CLIs without an installed integration by reading the terminal screen.")
                    : String(localized: "settings.automation.agentScreenDetection.subtitleOff", defaultValue: "Agent status is only shown for CLIs with an installed integration.")
            ) {
                Toggle("", isOn: $agentScreenDetectionEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAgentScreenDetectionToggle")
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.agentScreenDetection.note", defaultValue: "Applies to agents such as Gemini CLI and GitHub Copilot CLI that have no installed hooks. A hooks-managed session (Claude Code, Codex, OpenCode) always takes priority over this."))
        }

        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                    text: $customClaudePath
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }

        SettingsCard {
            SettingsCardRow(String(localized: "settings.automation.portBase", defaultValue: "Port Base"), subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for PROGRAMA_PORT env var."), controlWidth: pickerColumnWidth) {
                TextField("", value: $programaPortBase, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."), controlWidth: pickerColumnWidth) {
                TextField("", value: $programaPortRange, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets PROGRAMA_PORT and PROGRAMA_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }

    }

    private var selectedMobileBridgeMode: MobileBridgeMode {
        MobileBridgeSettings.mode(for: mobileBridgeMode)
    }

    private var mobileBridgeModeSelection: Binding<String> {
        Binding(
            get: { mobileBridgeMode },
            set: { mobileBridgeMode = $0 }
        )
    }

    private func beginMobileBridgePairing() {
        isPairingMobileBridgeDevice = true
        mobileBridgePairingErrorMessage = nil
        Task {
            if let pairing = await MobileBridgeListener.shared.beginPairing() {
                mobileBridgePairingTicket = pairing.ticket
                mobileBridgePairingToken = pairing.token
                mobileBridgePairingExpiresAt = pairing.expiresAt
            } else {
                mobileBridgePairingTicket = nil
                mobileBridgePairingToken = nil
                mobileBridgePairingExpiresAt = nil
                mobileBridgePairingErrorMessage = String(
                    localized: "settings.phone.pair.error",
                    defaultValue: "Could not start pairing. The phone companion may still be connecting — try again in a moment."
                )
            }
            isPairingMobileBridgeDevice = false
        }
    }

    private func revokeMobileBridgeDevice(_ device: MobileBridgeTrustedDevice) {
        Task {
            await MobileBridgeListener.shared.revoke(endpointId: device.endpointId)
            await refreshMobileBridgePairedDevices()
        }
    }

    private func refreshMobileBridgePairedDevices() async {
        mobileBridgePairedDevices = await MobileBridgeTrustedDeviceStore.shared.allDevices()
    }

    private func mobileBridgePairedOnSubtitle(_ device: MobileBridgeTrustedDevice) -> String {
        let formattedDate = device.pairedAt.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "settings.phone.devices.pairedOn", defaultValue: "Paired \(formattedDate)")
    }

    /// Renders `string` as a fixed-size QR code using CoreImage's built-in
    /// generator (no third-party dependency). Regenerated on demand rather
    /// than cached in `@State` -- this only runs while the pairing card is
    /// visible in Settings, not on any hot path.
    private func mobileBridgeQRImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }

        let targetSize: CGFloat = 512
        let scale = targetSize / outputImage.extent.width
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func mobileBridgePairingRemainingSeconds(at date: Date) -> Int? {
        guard let expiresAt = mobileBridgePairingExpiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(date).rounded(.up)))
    }

    private func mobileBridgePairingIsExpired(at date: Date) -> Bool {
        (mobileBridgePairingRemainingSeconds(at: date) ?? 0) <= 0
    }

    private func mobileBridgePairingCountdownLabel(at date: Date) -> String {
        guard let remaining = mobileBridgePairingRemainingSeconds(at: date) else { return "" }
        if remaining <= 0 {
            return String(localized: "settings.phone.pair.expired", defaultValue: "Expired. Start a new pairing.")
        }
        let timeString = String(format: "%d:%02d", remaining / 60, remaining % 60)
        return String(localized: "settings.phone.pair.expiresIn", defaultValue: "Single use. Expires in \(timeString).")
    }

    @ViewBuilder
    private var phoneSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.phone", defaultValue: "Phone"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.phone.mode", defaultValue: "Mobile Companion"),
                subtitle: selectedMobileBridgeMode == .pairedDevicesOnly
                    ? String(localized: "settings.phone.mode.subtitleOn", defaultValue: "Paired iPhones can reach this Mac over a private peer-to-peer connection.")
                    : String(localized: "settings.phone.mode.subtitleOff", defaultValue: "The phone companion is off. No device can connect."),
                controlWidth: pickerColumnWidth,
                selection: mobileBridgeModeSelection,
                accessibilityId: "MobileBridgeModePicker"
            ) {
                ForEach(MobileBridgeMode.uiCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            if selectedMobileBridgeMode == .pairedDevicesOnly {
                SettingsCardDivider()

                SettingsCardRow(
                    String(localized: "settings.phone.pair.title", defaultValue: "Pair a Device"),
                    subtitle: String(localized: "settings.phone.pair.subtitleV2", defaultValue: "Opens a single-use, 5-minute pairing window. Scan the QR code with the Programa iOS app, or copy the code it shows.")
                ) {
                    Button(String(localized: "settings.phone.pair.button", defaultValue: "Pair a Device…")) {
                        beginMobileBridgePairing()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPairingMobileBridgeDevice)
                    .accessibilityIdentifier("MobileBridgePairButton")
                }

                if let ticket = mobileBridgePairingTicket, let token = mobileBridgePairingToken,
                   let pairingURL = MobileBridgePairingCode.makeURL(ticket: ticket, token: token) {
                    SettingsCardDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 14) {
                            if let qrImage = mobileBridgeQRImage(for: pairingURL.absoluteString) {
                                Image(nsImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 168, height: 168)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .accessibilityIdentifier("MobileBridgePairingQRCode")
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "settings.phone.pair.scanLabel", defaultValue: "Scan this with the Programa iOS app's \u{201c}Scan QR Code\u{201d} button."))
                                    .font(.system(size: 12, weight: .semibold))

                                Text(pairingURL.absoluteString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )

                                HStack(spacing: 10) {
                                    Button(String(localized: "settings.phone.pair.copy", defaultValue: "Copy")) {
                                        let pasteboard = NSPasteboard.general
                                        pasteboard.clearContents()
                                        pasteboard.setString(pairingURL.absoluteString, forType: .string)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    TimelineView(.periodic(from: mobileBridgePairingExpiresAt ?? Date(), by: 1)) { context in
                                        Text(mobileBridgePairingCountdownLabel(at: context.date))
                                            .font(.caption)
                                            .foregroundStyle(mobileBridgePairingIsExpired(at: context.date) ? .red : .secondary)
                                    }
                                }
                            }
                        }

                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                if let mobileBridgePairingErrorMessage {
                    SettingsCardDivider()
                    Text(mobileBridgePairingErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }

                SettingsCardDivider()

                SettingsCardNote(String(localized: "settings.phone.note", defaultValue: "Programa runs no server. Your phone connects directly to this Mac over a private peer-to-peer link, and only a small allow-list of methods can be sent over it."))
            }
        }

        if selectedMobileBridgeMode == .pairedDevicesOnly {
            SettingsCard {
                SettingsCardRow(String(localized: "settings.phone.devices.title", defaultValue: "Paired Devices")) {
                    EmptyView()
                }

                if mobileBridgePairedDevices.isEmpty {
                    SettingsCardDivider()
                    SettingsCardNote(String(localized: "settings.phone.devices.empty", defaultValue: "No devices paired yet."))
                } else {
                    ForEach(mobileBridgePairedDevices) { device in
                        SettingsCardDivider()
                        SettingsCardRow(device.label, subtitle: mobileBridgePairedOnSubtitle(device)) {
                            Button(String(localized: "settings.phone.devices.revoke", defaultValue: "Remove")) {
                                revokeMobileBridgeDevice(device)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var customCommandsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.customCommands", defaultValue: "Custom Commands"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                SettingsCardRow(
                    String(localized: "settings.customCommands.trustedDirectories", defaultValue: "Trusted Directories"),
                    subtitle: String(localized: "settings.customCommands.trustedDirectories.subtitle", defaultValue: "Commands from programa.json in these directories run without confirmation. One path per line.")
                ) {
                    EmptyView()
                }

                TextEditor(text: $trustedDirectoriesDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .onChange(of: trustedDirectoriesDraft) {
                        saveTrustedDirectories()
                    }
            }

            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.customCommands.trustedDirectories.note", defaultValue: "Place a programa.json in your project root to define custom commands. Trust a directory from the confirmation dialog, or add paths here. For git repos, trusting the root covers all subdirectories."))
        }

    }

    @ViewBuilder
    private var browserSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.browser", defaultValue: "Browser"))
            .id(SettingsNavigationTarget.browser)
            .accessibilityIdentifier("SettingsBrowserSection")
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"),
                subtitle: String(localized: "settings.browser.searchEngine.subtitle", defaultValue: "Used by the browser address bar when input is not a URL."),
                controlWidth: pickerColumnWidth,
                selection: $browserSearchEngine
            ) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")) {
                Toggle("", isOn: $browserSearchSuggestionsEnabled)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
                subtitle: selectedBrowserThemeMode == .system
                    ? String(localized: "settings.browser.theme.subtitleSystem", defaultValue: "System follows app and macOS appearance.")
                    : String(localized: "settings.browser.theme.subtitleForced", defaultValue: "\(selectedBrowserThemeMode.displayName) forces that color scheme for compatible pages."),
                controlWidth: pickerColumnWidth,
                selection: browserThemeModeSelection
            ) {
                ForEach(BrowserThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in Programa Browser"),
                subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
            ) {
                Toggle("", isOn: $openTerminalLinksInProgramaBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
                subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
            ) {
                Toggle("", isOn: $interceptTerminalOpenCommandInProgramaBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if openTerminalLinksInProgramaBrowser || interceptTerminalOpenCommandInProgramaBrowser {
                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingsCardRow(
                        String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"),
                        subtitle: String(localized: "settings.browser.hostWhitelist.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in Programa. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in Programa.")
                    ) {
                        EmptyView()
                    }

                    TextEditor(text: $browserHostWhitelist)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingsCardRow(
                        String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"),
                        subtitle: String(localized: "settings.browser.externalPatterns.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. One rule per line. Plain text matches any URL substring, or prefix with `re:` for regex (for example: openai.com/usage, re:^https?://[^/]*\\.example\\.com/(billing|usage)).")
                    ) {
                        EmptyView()
                    }

                    TextEditor(text: $browserExternalOpenPatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }

            SettingsCardDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in Programa without a warning prompt. Defaults include localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $browserInsecureHTTPAllowlistDraft)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(minHeight: 86)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityIdentifier("SettingsBrowserHTTPAllowlistField")

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                            saveBrowserInsecureHTTPAllowlist()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer(minLength: 0)
                            Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                                saveBrowserInsecureHTTPAllowlist()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                            .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsCardDivider()

            VStack(alignment: .leading, spacing: 12) {
                // A mock of the blank-tab import hint used to be rendered here,
                // reusing the hint's own strings -- including its footnote saying
                // "You can always find this in Settings > Browser", shown inside
                // Settings. The buttons below do the same job without restating
                // the hint. The real card still lives in BrowserToolbarViews.
                Text(String(localized: "settings.browser.import", defaultValue: "Import Browser Data"))
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 8) {
                    Button(String(localized: "settings.browser.import.choose", defaultValue: "Choose…")) {
                        DispatchQueue.main.async {
                            BrowserDataImportCoordinator.shared.presentImportDialog()
                            refreshDetectedImportBrowsers()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserImportChooseButton")

                    Button(String(localized: "settings.browser.import.refresh", defaultValue: "Refresh")) {
                        refreshDetectedImportBrowsers()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .accessibilityIdentifier("SettingsBrowserImportActions")

                Toggle(
                    String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"),
                    isOn: browserImportHintVisibilityBinding
                )
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBrowserImportHintToggle")

                Text(browserImportHintSettingsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(SettingsNavigationTarget.browserImport)
            .accessibilityIdentifier("SettingsBrowserImportSection")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.browser.history", defaultValue: "Browsing History"), subtitle: browserHistorySubtitle) {
                Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                    showClearBrowserHistoryConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(browserHistoryEntryCount == 0)
            }
        }

    }

    @ViewBuilder
    private var keyboardShortcutsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
            .id(SettingsNavigationTarget.keyboardShortcuts)
            .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
                subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in settings.json, for example [\"ctrl+b\", \"c\"].")
            ) {
                HStack(spacing: 8) {
                    Link(String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"), destination: shortcutChordsDocsURL)
                        .font(.caption)
                        .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                    Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open settings.json")) {
                        openProgramaSettingsFileInTextEdit()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.shortcuts.showHints", defaultValue: "Show Cmd/Ctrl-Hold Shortcut Hints"),
                subtitle: showShortcutHintsOnCommandHold
                    ? String(localized: "settings.shortcuts.showHints.subtitleOn", defaultValue: "Holding Cmd (sidebar/titlebar) or Ctrl/Cmd (pane tabs) shows shortcut hint pills.")
                    : String(localized: "settings.shortcuts.showHints.subtitleOff", defaultValue: "Holding Cmd or Ctrl keeps shortcut hint pills hidden.")
            ) {
                Toggle("", isOn: $showShortcutHintsOnCommandHold)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            let actions = KeyboardShortcutSettings.Action.allCases
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                ShortcutSettingRow(action: action)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                if index < actions.count - 1 {
                    SettingsCardDivider()
                }
            }
        }
        .id(shortcutResetToken)

        Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record a new shortcut."))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .accessibilityIdentifier("ShortcutRecordingHint")

    }

    @ViewBuilder
    private var resetSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.reset", defaultValue: "Reset"))
        SettingsCard {
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings")) {
                    resetAllSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func resetAllSettings() {
        appearanceMode = AppearanceSettings.defaultMode.rawValue
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
        customClaudePath = ""
        agentScreenDetectionEnabled = AgentScreenDetectionSettings.defaultEnabled
        preferredEditorCommand = ""
        browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
        browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
        browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
        showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
        isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
        openTerminalLinksInProgramaBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInProgramaBrowser
        interceptTerminalOpenCommandInProgramaBrowser = BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInProgramaBrowser
        browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
        browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
        browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
        browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
        notificationSound = NotificationSoundSettings.defaultValue
        notificationSoundCustomFilePath = NotificationSoundSettings.defaultCustomFilePath
        notificationCustomSoundStatusMessage = nil
        notificationCustomSoundStatusIsError = false
        showNotificationCustomSoundErrorAlert = false
        notificationCustomSoundErrorAlertMessage = ""
        notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
        showMenuBarExtra = MenuBarExtraSettings.defaultShowInMenuBar
        warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
        sessionPersistScrollback = ScrollbackPersistenceSettings.defaultPersistScrollback
        commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
        ShortcutHintDebugSettings.resetVisibilityDefaults()
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
        newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
        workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
        workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
        sidebarSelectionColorHex = nil
        sidebarNotificationBadgeColorHex = nil
        showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
        sidebarTintHex = SidebarTintDefaults.hex
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
        sidebarTintOpacity = SidebarTintDefaults.opacity
        sidebarMatchTerminalBackground = false
        showClaudeQuota = true
        showOpenAccessConfirmation = false
        pendingOpenAccessMode = nil
        socketPasswordDraft = ""
        socketPasswordStatusMessage = nil
        socketPasswordStatusIsError = false
        refreshDetectedImportBrowsers()
        KeyboardShortcutSettings.resetAll()
        WorkspaceTabColorSettings.reset()
        shortcutResetToken = UUID()
    }

    private func saveBrowserInsecureHTTPAllowlist() {
        browserInsecureHTTPAllowlist = browserInsecureHTTPAllowlistDraft
    }

    private func refreshDetectedImportBrowsers() {
        detectedImportBrowsers = InstalledBrowserDetector.detectInstalledBrowsers()
    }
}

private struct SettingsTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SettingsTitleLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let maxX = buttons
                .compactMap { window.standardWindowButton($0)?.frame.maxX }
                .max() ?? 78
            let nextInset = maxX + 14
            if abs(nextInset - inset) > 0.5 {
                inset = nextInset
            }
        }
    }
}

private struct ThemeWindowThumbnail: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // Wallpaper background
                if isDark {
                    LinearGradient(
                        colors: [Color(red: 0.1, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.05, blue: 0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.5))
                        path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width * 0.5, y: height * 0.2))
                        path.addLine(to: CGPoint(x: width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.2, blue: 0.6).opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.6, green: 0.8, blue: 0.95), Color(red: 0.2, green: 0.4, blue: 0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.5))
                        path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width * 0.5, y: height * 0.2))
                        path.addLine(to: CGPoint(x: width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.8, green: 0.9, blue: 1.0).opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                // Menu bar
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "applelogo")
                            .symbolRasterSize(max(height * 0.08, 6))
                            .foregroundColor(isDark ? .white : .black)
                            .opacity(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, max(width * 0.04, 4))
                    .frame(height: max(height * 0.12, 8))
                    .background(.ultraThinMaterial)
                    Spacer()
                }

                // Back window
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(isDark ? Color(white: 0.2) : Color(white: 0.9))
                        .frame(height: max(height * 0.15, 8))
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(isDark ? Color(white: 0.15) : Color(white: 0.98))
                        RoundedRectangle(cornerRadius: max(width * 0.02, 2), style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: max(height * 0.12, 6))
                            .padding(max(width * 0.04, 4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: max(width * 0.04, 4), style: .continuous))
                .frame(width: width * 0.65, height: height * 0.45)
                .shadow(color: .black.opacity(isDark ? 0.4 : 0.15), radius: 4, x: 0, y: 2)
                .offset(x: -width * 0.08, y: -height * 0.1)

                // Front window with traffic lights
                VStack(spacing: 0) {
                    ZStack {
                        Rectangle()
                            .fill(isDark ? Color(white: 0.18) : Color(white: 0.92))
                        HStack(spacing: max(width * 0.025, 2)) {
                            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: max(width * 0.04, 3))
                            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: max(width * 0.04, 3))
                            Circle().fill(Color(red: 0.15, green: 0.79, blue: 0.25)).frame(width: max(width * 0.04, 3))
                            Spacer()
                        }
                        .padding(.horizontal, max(width * 0.04, 4))
                    }
                    .frame(height: max(height * 0.18, 10))
                    Rectangle()
                        .fill(isDark ? Color(white: 0.1) : .white)
                }
                .clipShape(RoundedRectangle(cornerRadius: max(width * 0.05, 5), style: .continuous))
                .shadow(color: .black.opacity(isDark ? 0.5 : 0.2), radius: 6, x: 0, y: 3)
                .frame(width: width * 0.75, height: height * 0.55)
                .offset(x: width * 0.12, y: height * 0.2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ThemePickerRow: View {
    let selectedMode: String
    let onSelect: (AppearanceMode) -> Void

    private let thumbWidth: CGFloat = 76
    private let thumbHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(localized: "settings.app.theme", defaultValue: "Theme"))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppearanceMode.visibleCases) { mode in
                    let isSelected = selectedMode == mode.rawValue
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .system {
                                    ZStack {
                                        ThemeWindowThumbnail(isDark: false)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width / 4, y: geo.size.height / 2)
                                                }
                                            )
                                        ThemeWindowThumbnail(isDark: true)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width * 0.75, y: geo.size.height / 2)
                                                }
                                            )
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.15))
                                                .frame(width: 1, height: geo.size.height)
                                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                        }
                                    }
                                } else {
                                    ThemeWindowThumbnail(isDark: mode == .dark)
                                }
                            }
                            .frame(width: thumbWidth, height: thumbHeight)

                            Text(mode.displayName)
                                .font(.system(size: 10))
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct ShortcutSettingRow: View {
    let action: KeyboardShortcutSettings.Action
    @State private var shortcut: StoredShortcut

    init(action: KeyboardShortcutSettings.Action) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.shortcut(for: action))
    }

    var body: some View {
        KeyboardShortcutRecorder(
            label: action.label,
            subtitle: KeyboardShortcutSettings.settingsFileManagedSubtitle(for: action),
            shortcut: $shortcut,
            displayString: { action.displayedShortcutString(for: $0) },
            transformRecordedShortcut: { action.normalizedRecordedShortcut($0) },
            isDisabled: KeyboardShortcutSettings.isManagedBySettingsFile(action)
        )
            .onChange(of: shortcut) { _, newValue in
                KeyboardShortcutSettings.setShortcut(newValue, for: action)
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
                let latest = KeyboardShortcutSettings.shortcut(for: action)
                if latest != shortcut {
                    shortcut = latest
                }
            }
    }
}

struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .background(WindowAccessor { window in
                configureSettingsWindow(window)
            })
    }

    private func configureSettingsWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        applyCurrentSettingsWindowStyle(to: window)

        let accessories = window.titlebarAccessoryViewControllers
        for index in accessories.indices.reversed() {
            guard let identifier = accessories[index].view.identifier?.rawValue else { continue }
            guard identifier.hasPrefix("cmux.") else { continue }
            window.removeTitlebarAccessoryViewController(at: index)
        }
        AppDelegate.shared?.applyWindowDecorations(to: window)
    }

    private func applyCurrentSettingsWindowStyle(to window: NSWindow) {
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
    }
}
