// SwiftUI replacement for the hand-rolled AppKit `ImportWizardWindowController`
// (nuclear-review audit finding N3). The 3-step flow, validation rules, and
// resolver/importer call contract are preserved exactly; only the widget
// layer (NSStackView/NSPopUpButton/NSButton) changed to SwiftUI.
//
// Frozen call contract (must not change): BrowserImportPlanResolver.defaultPlan,
// BrowserImportPlanResolver.separateProfilesPlan, BrowserImportScope.fromSelection,
// BrowserDataImporter.parseDomainFilters, InstalledBrowserDetector.summaryText,
// BrowserProfileStore.shared (profiles/effectiveLastUsedProfileID/displayName(for:)).
// BrowserImportPlanResolver.realize(plan:) and BrowserDataImporter.importData(...)
// are invoked by BrowserDataImportCoordinator after this wizard returns a selection
// and are unaffected by this file.

import AppKit
import SwiftUI

// MARK: - View Model

@MainActor
final class BrowserImportWizardViewModel: ObservableObject {
    enum Step {
        case source
        case sourceProfiles
        case dataTypes
    }

    let browsers: [InstalledBrowserCandidate]
    let destinationProfiles: [BrowserProfileDefinition]
    let initialDestinationProfileID: UUID

    @Published private(set) var step: Step = .source
    @Published var selectedBrowserIndex: Int = 0 {
        didSet { validationMessage = nil }
    }
    @Published var destinationMode: BrowserImportDestinationMode = .singleDestination
    @Published var separateExecutionEntries: [BrowserImportExecutionEntry] = []
    @Published var mergeDestinationProfileID: UUID
    @Published var includeCookies = true
    @Published var includeHistory = true
    @Published var includeAdditionalData = false
    @Published var domainFilterText = ""
    @Published var validationMessage: String?

    private var selectedSourceProfileIDsByBrowserID: [String: Set<String>] = [:]

    private(set) var selection: BrowserDataImportCoordinator.ImportSelection?
    var onFinish: ((NSApplication.ModalResponse) -> Void)?

    init(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?
    ) {
        let resolvedDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
        let fallbackDestinationProfileID = resolvedDestinationProfiles.first?.id
            ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        self.browsers = browsers
        self.destinationProfiles = resolvedDestinationProfiles
        self.initialDestinationProfileID = defaultDestinationProfileID
            .flatMap { candidateID in resolvedDestinationProfiles.first(where: { $0.id == candidateID })?.id }
            ?? fallbackDestinationProfileID
        self.mergeDestinationProfileID = self.initialDestinationProfileID
    }

    // MARK: Derived state

    func selectedBrowser() -> InstalledBrowserCandidate {
        let index = max(0, min(selectedBrowserIndex, browsers.count - 1))
        return browsers[index]
    }

    func selectedSourceProfiles() -> [InstalledBrowserProfile] {
        let browser = selectedBrowser()
        let selectedIDs = storedSelectedSourceProfileIDs(for: browser)
        return browser.profiles.filter { selectedIDs.contains($0.id) }
    }

    func isSourceProfileSelected(_ profile: InstalledBrowserProfile) -> Bool {
        storedSelectedSourceProfileIDs(for: selectedBrowser()).contains(profile.id)
    }

    func toggleSourceProfile(_ profile: InstalledBrowserProfile, isOn: Bool) {
        let browser = selectedBrowser()
        var selectedIDs = storedSelectedSourceProfileIDs(for: browser)
        if isOn {
            selectedIDs.insert(profile.id)
        } else {
            selectedIDs.remove(profile.id)
        }
        selectedSourceProfileIDsByBrowserID[browser.id] = selectedIDs
        validationMessage = nil
    }

    private func storedSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
        if let existing = selectedSourceProfileIDsByBrowserID[browser.id] {
            return existing
        }
        let defaultSelection = defaultSelectedSourceProfileIDs(for: browser)
        selectedSourceProfileIDsByBrowserID[browser.id] = defaultSelection
        return defaultSelection
    }

    private func defaultSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
        if let defaultProfile = browser.profiles.first(where: \.isDefault) {
            return [defaultProfile.id]
        }
        if let firstProfile = browser.profiles.first {
            return [firstProfile.id]
        }
        return []
    }

    var sourceProfilesPresentation: BrowserImportSourceProfilesPresentation {
        BrowserImportSourceProfilesPresentation(profileCount: selectedBrowser().profiles.count)
    }

    var step3Presentation: BrowserImportStep3Presentation {
        BrowserImportStep3Presentation(plan: currentExecutionPlan())
    }

    func currentExecutionPlan() -> BrowserImportExecutionPlan {
        let selectedProfiles = selectedSourceProfiles()
        guard !selectedProfiles.isEmpty else {
            return BrowserImportExecutionPlan(mode: .singleDestination, entries: [])
        }

        guard selectedProfiles.count > 1 else {
            return BrowserImportExecutionPlan(
                mode: .singleDestination,
                entries: [
                    BrowserImportExecutionEntry(
                        sourceProfiles: selectedProfiles,
                        destination: .existing(resolvedMergeDestinationProfileID)
                    )
                ]
            )
        }

        switch destinationMode {
        case .separateProfiles:
            let entriesBySourceID = Dictionary(
                uniqueKeysWithValues: separateExecutionEntries.compactMap { entry in
                    entry.sourceProfiles.first.map { ($0.id, entry.destination) }
                }
            )
            let entries = selectedProfiles.map { profile in
                BrowserImportExecutionEntry(
                    sourceProfiles: [profile],
                    destination: entriesBySourceID[profile.id] ?? defaultSeparateDestinationRequest(for: profile)
                )
            }
            return BrowserImportExecutionPlan(mode: .separateProfiles, entries: entries)
        case .singleDestination, .mergeIntoOne:
            return BrowserImportExecutionPlan(
                mode: .mergeIntoOne,
                entries: [
                    BrowserImportExecutionEntry(
                        sourceProfiles: selectedProfiles,
                        destination: .existing(resolvedMergeDestinationProfileID)
                    )
                ]
            )
        }
    }

    func destinationOptions(
        for entry: BrowserImportExecutionEntry,
        sourceProfile: InstalledBrowserProfile
    ) -> [BrowserImportDestinationRequest] {
        var options = destinationProfiles.map { BrowserImportDestinationRequest.existing($0.id) }
        let createName: String
        switch entry.destination {
        case .createNamed(let name):
            createName = name
        case .existing:
            createName = sourceProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !createName.isEmpty,
           !destinationProfiles.contains(where: {
               $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                   .localizedCaseInsensitiveCompare(createName) == .orderedSame
           }) {
            options.append(.createNamed(createName))
        }
        return options
    }

    func title(for request: BrowserImportDestinationRequest) -> String {
        switch request {
        case .existing(let id):
            return destinationProfiles.first(where: { $0.id == id })?.displayName
                ?? BrowserProfileStore.shared.displayName(for: id)
        case .createNamed(let name):
            return String(
                format: String(
                    localized: "browser.import.destinationProfile.create",
                    defaultValue: "Create \"%@\""
                ),
                name
            )
        }
    }

    func accessibilitySlug(for profile: InstalledBrowserProfile, index: Int) -> String {
        let base = profile.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "profile-\(index)" : base
    }

    func setSeparateDestination(at index: Int, to destination: BrowserImportDestinationRequest) {
        guard separateExecutionEntries.indices.contains(index) else { return }
        separateExecutionEntries[index].destination = destination
        validationMessage = nil
    }

    func setMergeDestination(profileID: UUID) {
        guard destinationProfiles.contains(where: { $0.id == profileID }) else { return }
        mergeDestinationProfileID = profileID
        validationMessage = nil
    }

    func setDestinationMode(_ mode: BrowserImportDestinationMode) {
        guard selectedSourceProfiles().count > 1 else { return }
        destinationMode = mode
    }

    private func destinationProfileID(for entry: BrowserImportExecutionEntry) -> UUID? {
        guard case .existing(let id) = entry.destination else { return nil }
        return id
    }

    var resolvedMergeDestinationProfileID: UUID {
        if destinationProfiles.contains(where: { $0.id == mergeDestinationProfileID }) {
            return mergeDestinationProfileID
        }
        return initialDestinationProfileID
    }

    private func defaultSeparateDestinationRequest(
        for profile: InstalledBrowserProfile
    ) -> BrowserImportDestinationRequest {
        BrowserImportPlanResolver.separateProfilesPlan(
            selectedSourceProfiles: [profile],
            destinationProfiles: destinationProfiles
        ).entries.first?.destination ?? .createNamed(profile.displayName)
    }

    private func resetStep3State() {
        let selectedProfiles = selectedSourceProfiles()
        let defaultPlan = BrowserImportPlanResolver.defaultPlan(
            selectedSourceProfiles: selectedProfiles,
            destinationProfiles: destinationProfiles,
            preferredSingleDestinationProfileID: initialDestinationProfileID
        )
        destinationMode = defaultPlan.mode
        separateExecutionEntries = BrowserImportPlanResolver.separateProfilesPlan(
            selectedSourceProfiles: selectedProfiles,
            destinationProfiles: destinationProfiles
        ).entries
        if let initialDestination = defaultPlan.entries.first.flatMap(destinationProfileID(for:)) {
            mergeDestinationProfileID = initialDestination
        } else {
            mergeDestinationProfileID = initialDestinationProfileID
        }
    }

    // MARK: Actions

    func handleBack() {
        switch step {
        case .source:
            return
        case .sourceProfiles:
            step = .source
        case .dataTypes:
            step = .sourceProfiles
        }
        validationMessage = nil
    }

    func handleCancel() {
        onFinish?(.cancel)
    }

    func handlePrimary() {
        switch step {
        case .source:
            step = .sourceProfiles
            validationMessage = nil
        case .sourceProfiles:
            guard !selectedSourceProfiles().isEmpty else {
                validationMessage = String(
                    localized: "browser.import.validation.sourceProfiles",
                    defaultValue: "Choose at least one source profile to import."
                )
                return
            }
            resetStep3State()
            step = .dataTypes
            validationMessage = nil
        case .dataTypes:
            guard let scope = BrowserImportScope.fromSelection(
                includeCookies: includeCookies,
                includeHistory: includeHistory,
                includeAdditionalData: includeAdditionalData
            ) else {
                validationMessage = String(
                    localized: "browser.import.validation.scope",
                    defaultValue: "Select Cookies, History, or both before starting import."
                )
                return
            }

            let domainFilters = BrowserDataImporter.parseDomainFilters(domainFilterText)
            selection = BrowserDataImportCoordinator.ImportSelection(
                browser: selectedBrowser(),
                executionPlan: currentExecutionPlan(),
                scope: scope,
                domainFilters: domainFilters
            )
            onFinish?(.OK)
        }
    }

    var primaryButtonTitle: String {
        switch step {
        case .source, .sourceProfiles:
            return String(localized: "browser.import.next", defaultValue: "Next")
        case .dataTypes:
            return String(localized: "browser.import.start", defaultValue: "Start Import")
        }
    }

    var isPrimaryButtonEnabled: Bool {
        switch step {
        case .source:
            return true
        case .sourceProfiles:
            return !selectedBrowser().profiles.isEmpty
        case .dataTypes:
            return true
        }
    }

    var stepLabelText: String {
        switch step {
        case .source:
            return String(localized: "browser.import.step.source", defaultValue: "Step 1 of 3")
        case .sourceProfiles:
            return String(localized: "browser.import.step.sourceProfiles", defaultValue: "Step 2 of 3")
        case .dataTypes:
            return String(localized: "browser.import.step.dataTypes", defaultValue: "Step 3 of 3")
        }
    }
}

// MARK: - Root View

struct BrowserImportWizardView: View {
    @ObservedObject var viewModel: BrowserImportWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.import.title", defaultValue: "Import Browser Data"))
                .font(.system(size: 22, weight: .semibold))

            Text(viewModel.stepLabelText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            switch viewModel.step {
            case .source:
                BrowserImportSourceStepView(viewModel: viewModel)
            case .sourceProfiles:
                BrowserImportSourceProfilesStepView(viewModel: viewModel)
            case .dataTypes:
                BrowserImportDataTypesStepView(viewModel: viewModel)
            }

            if let validationMessage = viewModel.validationMessage {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                if viewModel.step != .source {
                    Button(String(localized: "browser.import.back", defaultValue: "Back")) {
                        viewModel.handleBack()
                    }
                }
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.handleCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(viewModel.primaryButtonTitle) {
                    viewModel.handlePrimary()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.isPrimaryButtonEnabled)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

private struct BrowserImportSourceStepView: View {
    @ObservedObject var viewModel: BrowserImportWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(localized: "browser.import.source", defaultValue: "Source"))
                    .frame(width: 64, alignment: .trailing)
                Picker("", selection: $viewModel.selectedBrowserIndex) {
                    ForEach(Array(viewModel.browsers.enumerated()), id: \.offset) { index, browser in
                        Text(browser.displayName).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Text(InstalledBrowserDetector.summaryText(for: viewModel.browsers))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BrowserImportSourceProfilesStepView: View {
    @ObservedObject var viewModel: BrowserImportWizardViewModel

    var body: some View {
        let browser = viewModel.selectedBrowser()
        let presentation = viewModel.sourceProfilesPresentation

        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.import.sourceProfiles", defaultValue: "Source Profiles"))
                .font(.system(size: 12, weight: .semibold))

            if browser.profiles.isEmpty {
                Text(
                    String(
                        format: String(
                            localized: "browser.import.sourceProfiles.empty",
                            defaultValue: "No source profiles detected for %@."
                        ),
                        browser.displayName
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(browser.profiles) { profile in
                            Toggle(
                                profile.displayName,
                                isOn: Binding(
                                    get: { viewModel.isSourceProfileSelected(profile) },
                                    set: { viewModel.toggleSourceProfile(profile, isOn: $0) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        }
                    }
                }
                .frame(height: presentation.scrollHeight)
            }

            if presentation.showsHelpText {
                Text(
                    String(
                        localized: "browser.import.sourceProfiles.help",
                        defaultValue: "Choose one or more source profiles. Step 3 lets you keep them separate or merge them into one Programa profile."
                    )
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct BrowserImportDataTypesStepView: View {
    @ObservedObject var viewModel: BrowserImportWizardViewModel

    var body: some View {
        let plan = viewModel.currentExecutionPlan()
        let presentation = viewModel.step3Presentation

        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "browser.import.destination.cmux", defaultValue: "Programa destination"))
                .font(.system(size: 12, weight: .semibold))

            if presentation.showsModeSelector {
                Picker(
                    "",
                    selection: Binding(
                        get: { viewModel.destinationMode == .separateProfiles ? 0 : 1 },
                        set: { viewModel.setDestinationMode($0 == 0 ? .separateProfiles : .mergeIntoOne) }
                    )
                ) {
                    Text(
                        String(
                            localized: "browser.import.destinationMode.separate",
                            defaultValue: "Keep profiles separate"
                        )
                    ).tag(0)
                    Text(
                        String(
                            localized: "browser.import.destinationMode.merge",
                            defaultValue: "Merge all into one Programa profile"
                        )
                    ).tag(1)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if presentation.showsSeparateRows {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { index, entry in
                        if let sourceProfile = entry.sourceProfiles.first {
                            BrowserImportSeparateDestinationRow(
                                viewModel: viewModel,
                                index: index,
                                entry: entry,
                                sourceProfile: sourceProfile
                            )
                        }
                    }
                }
            }

            if presentation.showsSingleDestinationPicker {
                HStack(spacing: 6) {
                    Text(String(localized: "browser.import.destinationProfile", defaultValue: "Import into"))
                        .frame(width: 110, alignment: .trailing)
                    Picker(
                        "",
                        selection: Binding(
                            get: {
                                viewModel.destinationProfiles.firstIndex(
                                    where: { $0.id == viewModel.resolvedMergeDestinationProfileID }
                                ) ?? 0
                            },
                            set: { index in
                                guard viewModel.destinationProfiles.indices.contains(index) else { return }
                                viewModel.setMergeDestination(profileID: viewModel.destinationProfiles[index].id)
                            }
                        )
                    ) {
                        ForEach(Array(viewModel.destinationProfiles.enumerated()), id: \.offset) { index, profile in
                            Text(profile.displayName).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("BrowserImportDestinationPopup-merge")
                }
            }

            if presentation.showsSeparateRows {
                Text(
                    String(
                        localized: "browser.import.destinationProfile.separateHelp",
                        defaultValue: "Missing Programa profiles are created when import starts."
                    )
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if plan.entries.count > 1 {
                Text(
                    String(
                        localized: "browser.import.destinationProfile.mergeHelp",
                        defaultValue: "All selected source profiles will be merged into the chosen Programa browser profile."
                    )
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                String(localized: "browser.import.cookies", defaultValue: "Cookies (site sign-ins)"),
                isOn: $viewModel.includeCookies
            )
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("BrowserImportCookiesCheckbox")
            .onChange(of: viewModel.includeCookies) { _ in viewModel.validationMessage = nil }

            Toggle(
                String(localized: "browser.import.history", defaultValue: "History (visited pages)"),
                isOn: $viewModel.includeHistory
            )
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("BrowserImportHistoryCheckbox")
            .onChange(of: viewModel.includeHistory) { _ in viewModel.validationMessage = nil }

            Toggle(
                String(
                    localized: "browser.import.additionalData",
                    defaultValue: "Additional data (bookmarks, settings, extensions)"
                ),
                isOn: $viewModel.includeAdditionalData
            )
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("BrowserImportAdditionalDataCheckbox")
            .onChange(of: viewModel.includeAdditionalData) { _ in viewModel.validationMessage = nil }

            if viewModel.includeAdditionalData {
                Text(
                    String(
                        localized: "browser.import.additionalData.note",
                        defaultValue: "Bookmarks, settings, and extensions import are not available yet."
                    )
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(String(localized: "browser.import.domain", defaultValue: "Limit to"))
                    .frame(width: 72, alignment: .trailing)
                TextField(
                    String(
                        localized: "browser.import.domain.placeholder",
                        defaultValue: "Optional domains only (e.g. github.com, openai.com)"
                    ),
                    text: $viewModel.domainFilterText
                )
            }
        }
    }
}

private struct BrowserImportSeparateDestinationRow: View {
    @ObservedObject var viewModel: BrowserImportWizardViewModel
    let index: Int
    let entry: BrowserImportExecutionEntry
    let sourceProfile: InstalledBrowserProfile

    var body: some View {
        let options = viewModel.destinationOptions(for: entry, sourceProfile: sourceProfile)
        HStack(spacing: 6) {
            Text(sourceProfile.displayName)
                .frame(width: 110, alignment: .trailing)
            Picker(
                "",
                selection: Binding(
                    get: { options.firstIndex(of: entry.destination) ?? 0 },
                    set: { newIndex in
                        guard options.indices.contains(newIndex) else { return }
                        viewModel.setSeparateDestination(at: index, to: options[newIndex])
                    }
                )
            ) {
                ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                    Text(viewModel.title(for: option)).tag(optionIndex)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(
                "BrowserImportDestinationPopup-\(viewModel.accessibilitySlug(for: sourceProfile, index: index))"
            )
        }
    }
}

// MARK: - Window Controller

@MainActor
final class BrowserImportWizardWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let viewModel: BrowserImportWizardViewModel
    private var didFinishModal = false

    init(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?
    ) {
        let viewModel = BrowserImportWizardViewModel(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        )
        self.viewModel = viewModel

        let hostingController = NSHostingController(rootView: BrowserImportWizardView(viewModel: viewModel))
        hostingController.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 292),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(
            localized: "browser.import.title",
            defaultValue: "Import Browser Data"
        )
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = hostingController
        self.panel = panel

        super.init()
        panel.delegate = self
        viewModel.onFinish = { [weak self] response in
            self?.finishModal(with: response)
        }
    }

    func runModal() -> BrowserDataImportCoordinator.ImportSelection? {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let response = NSApp.runModal(for: panel)
        if panel.isVisible {
            panel.orderOut(nil)
        }

        guard response == .OK else { return nil }
        return viewModel.selection
    }

#if DEBUG
    var debugPanelWindow: NSWindow { panel }
#endif

    func windowWillClose(_ notification: Notification) {
        finishModal(with: .cancel)
    }

    private func finishModal(with response: NSApplication.ModalResponse) {
        guard !didFinishModal else { return }
        didFinishModal = true

        if NSApp.modalWindow == panel {
            NSApp.stopModal(withCode: response)
        }
        panel.orderOut(nil)
    }
}
