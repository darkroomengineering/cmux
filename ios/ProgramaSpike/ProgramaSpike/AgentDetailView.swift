import SwiftUI

/// Screen 3 — the "unblock it" screen: per-surface state for one workspace,
/// plus a prompt field that issues `agent.prompt` to the chosen surface.
struct AgentDetailView: View {
    @Bindable var store: AppStore
    let workspaceID: String

    @State private var promptText: String = ""
    @State private var selectedSurfaceID: String?
    @State private var sendResultDescription: String?
    @State private var isSending = false

    var body: some View {
        List {
            Section("Surfaces") {
                if store.surfaces(for: workspaceID).isEmpty {
                    Text("No surfaces in this workspace.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.surfaces(for: workspaceID)) { surface in
                    Button {
                        selectedSurfaceID = surface.id
                    } label: {
                        SurfaceRowView(surface: surface, isSelected: surface.id == selectedSurfaceID)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Unblock it") {
                TextField("Prompt text", text: $promptText, axis: .vertical)
                    .lineLimit(2 ... 6)
                Button("Send") {
                    Task { await send() }
                }
                .disabled(
                    selectedSurfaceID == nil
                        || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSending
                )
                if let sendResultDescription {
                    Text(sendResultDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(store.workspaceTitle(for: workspaceID))
        .onAppear {
            if selectedSurfaceID == nil {
                selectedSurfaceID = store.surfaces(for: workspaceID).first?.id
            }
        }
    }

    private func send() async {
        guard let surfaceID = selectedSurfaceID else { return }
        isSending = true
        sendResultDescription = nil
        let textToSend = promptText
        do {
            try await store.sendPrompt(surfaceID: surfaceID, text: textToSend)
            sendResultDescription = "Sent."
            promptText = ""
        } catch {
            sendResultDescription = "Failed: \(error)"
        }
        isSending = false
    }
}

private struct SurfaceRowView: View {
    let surface: SurfaceRow
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: surface.badge.symbolName)
                .foregroundStyle(surface.badge.tint)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(surface.title)
                Text(surface.badge.label)
                    .font(.caption)
                    .foregroundStyle(surface.badge.tint)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    AgentDetailView(store: AppStore(), workspaceID: "preview")
}
