import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner, Dynamic Island (compact/expanded/minimal), all driven
/// by `AgentActivityAttributes.ContentState` pushed from `AppStore` on the
/// app side (see that file's "Live Activity" section for the update/
/// coalescing contract). Blocked is the story everywhere: a human being
/// needed right now is the only state worth interrupting someone for, so it
/// always leads and uses the one non-quiet color (red); the resting state
/// (working or all-clear) stays visually quiet so it doesn't become Lock
/// Screen noise.
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: AgentActivityPresentation.symbolName(for: context.state))
                        .font(.title2)
                        .foregroundStyle(AgentActivityPresentation.tint(for: context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(AgentActivityPresentation.countLabel(for: context.state))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AgentActivityPresentation.tint(for: context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AgentActivityPresentation.headline(for: context.state))
                            .font(.headline)
                            .foregroundStyle(AgentActivityPresentation.tint(for: context.state))
                        if let subheadline = AgentActivityPresentation.subheadline(for: context.state) {
                            Text(subheadline)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(AgentActivityPresentation.workingSubheadline(for: context.state))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: AgentActivityPresentation.symbolName(for: context.state))
                    .foregroundStyle(AgentActivityPresentation.tint(for: context.state))
            } compactTrailing: {
                Text(AgentActivityPresentation.countLabel(for: context.state))
                    .foregroundStyle(AgentActivityPresentation.tint(for: context.state))
            } minimal: {
                Image(systemName: AgentActivityPresentation.symbolName(for: context.state))
                    .foregroundStyle(AgentActivityPresentation.tint(for: context.state))
            }
            .keylineTint(AgentActivityPresentation.tint(for: context.state))
        }
    }
}

/// Lock Screen / banner presentation.
private struct AgentActivityLockScreenView: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AgentActivityPresentation.symbolName(for: state))
                .font(.title2)
                .foregroundStyle(AgentActivityPresentation.tint(for: state))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(AgentActivityPresentation.headline(for: state))
                    .font(.headline)
                    .foregroundStyle(AgentActivityPresentation.tint(for: state))
                if let subheadline = AgentActivityPresentation.subheadline(for: state) {
                    Text(subheadline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// Shared string/symbol/color logic for every presentation size (Lock
/// Screen, banner, Dynamic Island compact/expanded/minimal) so they all
/// agree on what "blocked" looks like. All user-facing strings are
/// localizable via `String(localized:)` and now resolve for real: the
/// catalog at `ProgramaSpike/Shared/Localizable.xcstrings` is a member of
/// both this extension and the app, since `Shared/` is a `sources:` path for
/// each target in `project.yml`. A widget extension resolves
/// `String(localized:)` against its own bundle, so a catalog visible only to
/// the app would have left these keys falling back to `defaultValue:`.
enum AgentActivityPresentation {
    static func symbolName(for state: AgentActivityAttributes.ContentState) -> String {
        state.blockedCount > 0 ? "bell.badge.fill" : "circle.dotted"
    }

    /// Semantic colors only: red-orange is reserved for "blocked" so the
    /// resting state stays visually quiet instead of becoming Lock Screen
    /// noise. `.secondary` and `.primary` both adapt to light/dark
    /// automatically.
    static func tint(for state: AgentActivityAttributes.ContentState) -> Color {
        state.blockedCount > 0 ? .red : .secondary
    }

    /// Dynamic Island compact/expanded trailing count: the blocked count
    /// when something needs attention, otherwise the working count.
    static func countLabel(for state: AgentActivityAttributes.ContentState) -> String {
        state.blockedCount > 0 ? "\(state.blockedCount)" : "\(state.workingCount)"
    }

    static func headline(for state: AgentActivityAttributes.ContentState) -> String {
        if state.blockedCount > 0 {
            return blockedHeadline(count: state.blockedCount)
        }
        if state.workingCount > 0 {
            return workingHeadline(count: state.workingCount)
        }
        return String(localized: "live_activity.headline.allClear", defaultValue: "All clear")
    }

    /// Lock Screen subheadline -- only shown for the blocked state, where it
    /// is the workspace that most recently needed a human.
    static func subheadline(for state: AgentActivityAttributes.ContentState) -> String? {
        guard state.blockedCount > 0 else { return nil }
        return state.headlineWorkspace
    }

    /// Dynamic Island expanded-bottom fallback line when nothing is
    /// blocked -- restates the working count since there is no headline
    /// workspace to show in that state.
    static func workingSubheadline(for state: AgentActivityAttributes.ContentState) -> String {
        workingHeadline(count: state.workingCount)
    }

    private static func blockedHeadline(count: Int) -> String {
        if count == 1 {
            return String(localized: "live_activity.headline.blocked.one", defaultValue: "1 agent needs you")
        }
        return String(localized: "live_activity.headline.blocked.other", defaultValue: "\(count) agents need you")
    }

    private static func workingHeadline(count: Int) -> String {
        if count == 1 {
            return String(localized: "live_activity.headline.working.one", defaultValue: "1 working")
        }
        return String(localized: "live_activity.headline.working.other", defaultValue: "\(count) working")
    }
}
