import SwiftUI

/// Screen 1: scan or paste the pairing code shown on Programa's Mac
/// Settings ▸ Phone screen, then connect. The legacy separate ticket/token
/// fields stay as a fallback for testers who can't scan or whose combined
/// code paste didn't parse.
struct PairConnectView: View {
    @Bindable var store: AppStore

    @State private var showScanner = false
    @State private var pairingCodeDraft = ""
    @State private var pairingCodeError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "pairing.connect.section.code", defaultValue: "Pairing code")) {
                    Button {
                        showScanner = true
                    } label: {
                        Label(
                            String(localized: "pairing.connect.scanButton", defaultValue: "Scan QR Code"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }

                    TextField(
                        String(
                            localized: "pairing.connect.codeField.placeholder",
                            defaultValue: "Or paste the code from Programa ▸ Settings ▸ Phone"
                        ),
                        text: $pairingCodeDraft,
                        axis: .vertical
                    )
                    .lineLimit(1 ... 4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button(String(localized: "pairing.connect.useCodeButton", defaultValue: "Use This Code")) {
                        applyPairingCodeDraft()
                    }
                    .disabled(pairingCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let pairingCodeError {
                        Text(pairingCodeError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section(
                    String(
                        localized: "pairing.connect.section.advanced",
                        defaultValue: "Advanced: paste ticket and token separately"
                    )
                ) {
                    TextField(
                        String(
                            localized: "pairing.connect.ticketField.placeholder",
                            defaultValue: "Paste the ticket from Programa's pairing screen"
                        ),
                        text: $store.pairingTicketDraft,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        String(localized: "pairing.connect.tokenField.placeholder", defaultValue: "Only needed the first time"),
                        text: $store.pairingTokenDraft
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(
                        String(
                            localized: "pairing.connect.tokenField.footnote",
                            defaultValue: "Once this device is paired it stays trusted — you won't need the token again."
                        )
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(String(localized: "pairing.connect.connectButton", defaultValue: "Connect")) {
                        Task { await store.connectManually() }
                    }
                    .disabled(
                        store.pairingTicketDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.isConnecting
                    )
                }

                Section(String(localized: "pairing.connect.section.status", defaultValue: "Status")) {
                    LabeledContent(String(localized: "State", defaultValue: "State"), value: store.connectionBanner.label)
                    // The observed network path stays visible even on this
                    // screen — it remains diagnostically useful.
                    LabeledContent(
                        String(localized: "pairing.connect.networkPath.label", defaultValue: "Network path"),
                        value: store.observedPathDescription
                    )
                    if let lastSyncError = store.lastSyncError {
                        Text(lastSyncError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    // Shown before pairing too: "which build am I on" is most
                    // often asked when the phone will not connect at all.
                    AppVersionRow()
                }

                Section(String(localized: "notifications.title", defaultValue: "Notifications")) {
                    if let message = store.iCloudStatusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text(String(localized: "pairing.connect.icloud.signedIn", defaultValue: "iCloud is signed in on this iPhone."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // CloudKit has no API to detect this, so the app cannot warn about it
                    // directly -- it can only ever report "signed in" or "not signed in" on
                    // this device. A mismatch delivers nothing and raises no error.
                    Text(
                        String(
                            localized: "pairing.connect.icloud.accountMismatchNotice",
                            defaultValue: "This iPhone and your Mac must be signed into the same iCloud account for background notifications to arrive. Programa can't detect a mismatch — check the Apple ID on both devices if notifications never show up."
                        )
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "pairing.connect.title", defaultValue: "Connect to Programa"))
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    handleScannedCode(code)
                }
            }
        }
    }

    private func applyPairingCodeDraft() {
        let trimmed = pairingCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.applyPairingCode(trimmed) else {
            pairingCodeError = String(
                localized: "pairing.connect.error.invalidPastedCode",
                defaultValue: "That doesn't look like a Programa pairing code. Scan the QR code, or paste the ticket and token below instead."
            )
            return
        }
        pairingCodeError = nil
        Task { await store.connectManually() }
    }

    private func handleScannedCode(_ code: String) {
        guard store.applyPairingCode(code) else {
            pairingCodeError = String(
                localized: "pairing.connect.error.invalidScannedCode",
                defaultValue: "That QR code wasn't a valid Programa pairing code."
            )
            return
        }
        pairingCodeError = nil
        Task { await store.connectManually() }
    }
}

#Preview {
    PairConnectView(store: AppStore())
}
