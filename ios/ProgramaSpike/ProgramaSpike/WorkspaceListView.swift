import SwiftUI

/// Screen 2 — the glance screen: one row per workspace, worst-of state
/// badge, blocked workspaces sorted to the top, live updates from
/// `agent_state` events, pull-to-refresh triggers a full resync.
struct WorkspaceListView: View {
    @Bindable var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: store.connectionBanner.symbolName)
                        Text(store.connectionBanner.label)
                        Spacer()
                        Text(store.observedPathDescription)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(String(localized: "workspaceList.title", defaultValue: "Workspaces")) {
                    if store.sortedWorkspaces.isEmpty {
                        Text(String(localized: "workspaceList.empty", defaultValue: "No workspaces yet."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sortedWorkspaces) { workspace in
                        NavigationLink(value: workspace.id) {
                            WorkspaceRowView(workspace: workspace, badge: store.badge(for: workspace.id))
                        }
                    }
                }

                Section {
                    AppVersionRow()
                }
            }
            .navigationTitle(String(localized: "workspaceList.title", defaultValue: "Workspaces"))
            .navigationDestination(for: String.self) { workspaceID in
                AgentDetailView(store: store, workspaceID: workspaceID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "workspaceList.changePairing.button", defaultValue: "Change Pairing")) { store.returnToPairing() }
                }
            }
            .refreshable {
                await store.manualResync()
            }
        }
    }
}

private struct WorkspaceRowView: View {
    let workspace: WorkspaceRow
    let badge: AgentBadge

    var body: some View {
        HStack {
            Image(systemName: badge.symbolName)
                .foregroundStyle(badge.tint)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(workspace.title)
                    .font(.body)
                Text(badge.label)
                    .font(.caption)
                    .foregroundStyle(badge.tint)
            }
            Spacer()
        }
    }
}

#Preview {
    WorkspaceListView(store: AppStore())
}
