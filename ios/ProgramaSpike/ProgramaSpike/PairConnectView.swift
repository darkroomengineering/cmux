import SwiftUI

/// Screen 1: paste the ticket, paste the token (first time only), connect.
struct PairConnectView: View {
    @Bindable var store: AppStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing ticket") {
                    TextField(
                        "Paste the ticket from Programa's pairing screen",
                        text: $store.pairingTicketDraft,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section("Pairing token") {
                    TextField("Only needed the first time", text: $store.pairingTokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Once this device is paired it stays trusted — you won't need the token again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Connect") {
                        Task { await store.connectManually() }
                    }
                    .disabled(
                        store.pairingTicketDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.isConnecting
                    )
                }

                Section("Status") {
                    LabeledContent("State", value: store.connectionBanner.label)
                    // The observed network path stays visible even on this
                    // screen — it remains diagnostically useful.
                    LabeledContent("Network path", value: store.observedPathDescription)
                    if let lastSyncError = store.lastSyncError {
                        Text(lastSyncError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Connect to Programa")
        }
    }
}

#Preview {
    PairConnectView(store: AppStore())
}
