import SwiftUI

extension ProviderUsageProvider {
    var localizedDisplayName: String {
        switch self {
        case .claude:
            String(localized: "sidebar.usage.provider.claude", defaultValue: "Claude")
        case .codex:
            String(localized: "sidebar.usage.provider.codex", defaultValue: "Codex")
        }
    }
}

struct SidebarQuotaPresentation {
    struct Failure: Identifiable, Equatable {
        let provider: ProviderUsageProvider
        let message: String

        var id: ProviderUsageProvider { provider }
    }

    let availableSnapshots: [ProviderUsageSnapshot]
    let failures: [Failure]
    let unavailableProviders: [ProviderUsageProvider] = []

    var showsEmptyState: Bool {
        availableSnapshots.isEmpty && failures.isEmpty
    }

    init(results: [ProviderUsageResult]) {
        availableSnapshots = results.compactMap { result in
            guard case let .available(snapshot) = result else { return nil }
            return snapshot
        }
        failures = results.compactMap { result in
            guard case let .failed(provider, message) = result else { return nil }
            return Failure(provider: provider, message: message)
        }
    }
}

/// Provider usage content hosted by the sidebar footer's on-demand popover.
struct SidebarQuotaFooter: View {
    static let showsManualRefreshControl = false

    @ObservedObject var store: ProviderUsageStore

    private var presentation: SidebarQuotaPresentation {
        SidebarQuotaPresentation(results: store.results)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "sidebar.usage.title", defaultValue: "Provider Usage"))
                    .font(.headline)
                Spacer(minLength: 8)
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            String(localized: "sidebar.usage.refreshing", defaultValue: "Refreshing usage")
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.results.isEmpty, store.isRefreshing {
                        loadingState
                    } else {
                        if presentation.showsEmptyState {
                            emptyState
                        }

                        ForEach(presentation.availableSnapshots, id: \.provider) { snapshot in
                            providerSection(snapshot)
                        }

                        ForEach(presentation.failures) { failure in
                            failureSection(provider: failure.provider, message: failure.message)
                        }

                    }
                }
                .padding(14)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 480, alignment: .top)
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "sidebar.usage.loading", defaultValue: "Loading usage…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "sidebar.usage.empty.title", defaultValue: "No usage available"))
                .font(.system(size: 12, weight: .semibold))
            Text(
                String(
                    localized: "sidebar.usage.empty.subtitle",
                    defaultValue: "Sign in to a supported provider to view usage."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func providerSection(_ snapshot: ProviderUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.provider.localizedDisplayName)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(snapshot.windows) { window in
                usageRow(window)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }

    private func usageRow(_ window: ProviderUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.percentText(window.usedPercent))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Text(Self.resetText(window.resetsAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Self.barColor(for: window.usedPercent))
                        .frame(width: proxy.size.width * CGFloat(window.usedPercent) / 100)
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(
                    localized: "sidebar.usage.window.accessibility",
                    defaultValue: "%1$@, %2$@ used, resets in %3$@"
                ),
                window.label,
                Self.percentText(window.usedPercent),
                Self.resetText(window.resetsAt)
            )
        )
    }

    private func failureSection(provider: ProviderUsageProvider, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.localizedDisplayName)
                .font(.system(size: 12, weight: .semibold))
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .accessibilityElement(children: .combine)
    }

    private static func barColor(for usedPercent: Int) -> Color {
        switch usedPercent {
        case ..<60:
            .secondary
        case 60..<85:
            .orange
        default:
            .red
        }
    }

    private static func percentText(_ usedPercent: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "sidebar.quota.percent", defaultValue: "%@%%"),
            String(usedPercent)
        )
    }

    private static func resetText(_ resetsAt: Date) -> String {
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else {
            return String(localized: "sidebar.quota.resetNow", defaultValue: "now")
        }

        let totalMinutes = Int(remaining / 60)
        if totalMinutes < 60 {
            return String.localizedStringWithFormat(
                String(localized: "sidebar.quota.resetMinutes", defaultValue: "%@m"),
                String(max(totalMinutes, 1))
            )
        }

        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            return String.localizedStringWithFormat(
                String(localized: "sidebar.quota.resetHours", defaultValue: "%@h"),
                String(totalHours)
            )
        }

        return String.localizedStringWithFormat(
            String(localized: "sidebar.quota.resetDays", defaultValue: "%@d"),
            String(totalHours / 24)
        )
    }
}
