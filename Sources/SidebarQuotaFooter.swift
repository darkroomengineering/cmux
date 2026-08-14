import SwiftUI

/// Compact, read-only readout of Claude Code rate-limit headroom (5h / 7d windows),
/// sourced from `~/.claude/tmp/rate-limits.json` via `ClaudeQuotaMonitor`. Renders
/// nothing at all when that file is absent (e.g. the user doesn't run cc-settings) or
/// when the user has turned the readout off in Settings.
struct SidebarQuotaFooter: View {
    @ObservedObject private var monitor = ClaudeQuotaMonitor.shared
    @AppStorage("sidebarShowClaudeQuota") private var showClaudeQuota = true

    var body: some View {
        if showClaudeQuota, let snapshot = monitor.snapshot {
            VStack(alignment: .leading, spacing: 3) {
                quotaRow(
                    label: String(localized: "sidebar.quota.fiveHour", defaultValue: "5h"),
                    window: snapshot.fiveHour
                )
                quotaRow(
                    label: String(localized: "sidebar.quota.sevenDay", defaultValue: "7d"),
                    window: snapshot.sevenDay
                )
            }
            // Sidebar spacing grid: 4pt base, edges on 8.
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func quotaRow(label: String, window: ClaudeQuotaWindow) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Self.barColor(for: window.usedPercent))
                        .frame(width: proxy.size.width * CGFloat(window.usedPercent) / 100)
                }
            }
            .frame(height: 3)

            Text(Self.percentText(window.usedPercent))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            Text(Self.resetText(window.resetsAt))
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
        }
    }

    private static func barColor(for usedPercent: Int) -> Color {
        switch usedPercent {
        case ..<60:
            return .secondary
        case 60..<85:
            return .orange
        default:
            return .red
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

        let totalDays = totalHours / 24
        return String.localizedStringWithFormat(
            String(localized: "sidebar.quota.resetDays", defaultValue: "%@d"),
            String(totalDays)
        )
    }
}
