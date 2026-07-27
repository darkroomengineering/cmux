import SwiftUI

struct ContentView: View {
    @State private var pairingPayload: String = ""
    @State private var client = SpikeClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing payload") {
                    TextField(
                        "Paste the payload printed by `iroh-spike listen`",
                        text: $pairingPayload,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button("Connect") {
                        Task { await client.connect(pairingPayload: pairingPayload) }
                    }
                    .disabled(
                        pairingPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || client.state == .connecting
                    )
                }

                Section("Result") {
                    LabeledContent("State", value: stateDescription)

                    // The observed path is the single most important output
                    // of this spike — kept large and first among results.
                    if let observedPathDescription = client.observedPathDescription {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Observed path")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(observedPathDescription)
                                .font(.title2.bold())
                        }
                    }

                    if let roundTripLatencyDescription = client.roundTripLatencyDescription {
                        LabeledContent("Round-trip latency", value: roundTripLatencyDescription)
                    }

                    if let errorText = client.errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Programa Spike")
        }
    }

    private var stateDescription: String {
        switch client.state {
        case .idle: "idle"
        case .connecting: "connecting…"
        case .succeeded: "connected"
        case .failed: "failed"
        }
    }
}

#Preview {
    ContentView()
}
