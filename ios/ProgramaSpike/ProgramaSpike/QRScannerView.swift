import AVFoundation
import SwiftUI

/// A sheet that scans a QR code with `AVCaptureMetadataOutput` and calls
/// `onCode` with the decoded string on the first successful scan. Uses
/// `AVCaptureMetadataOutput` rather than `DataScannerViewController` --
/// simpler API, needs only the one `NSCameraUsageDescription` key, and
/// avoids `DataScannerViewController`'s own separate availability checks.
///
/// Degrades gracefully rather than crashing when no camera is available
/// (the simulator, or a device whose camera failed to initialize), and
/// surfaces a clear message rather than a silent dead end when the user has
/// denied camera permission.
struct QRScannerView: View {
    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameraUnavailable = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "pairing.scanner.title", defaultValue: "Scan QR Code"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch authorizationStatus {
        case .authorized:
            if cameraUnavailable {
                unavailableView(
                    message: String(
                        localized: "pairing.scanner.unavailable.noCamera",
                        defaultValue: "No camera is available on this device. Paste the pairing code instead."
                    )
                )
            } else {
                QRCaptureRepresentable(
                    onCode: { code in
                        onCode(code)
                        dismiss()
                    },
                    onUnavailable: { cameraUnavailable = true }
                )
                .ignoresSafeArea()
            }
        case .notDetermined:
            ProgressView()
                .task { await requestAccess() }
        case .denied, .restricted:
            unavailableView(
                message: String(
                    localized: "pairing.scanner.unavailable.accessDenied",
                    defaultValue: "Camera access is off for Programa. Enable it in Settings ▸ Programa to scan the pairing code, or paste it instead."
                )
            )
        @unknown default:
            unavailableView(
                message: String(
                    localized: "pairing.scanner.unavailable.generic",
                    defaultValue: "Camera unavailable. Paste the pairing code instead."
                )
            )
        }
    }

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorizationStatus = granted ? .authorized : .denied
    }

    @ViewBuilder
    private func unavailableView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }
}

/// Wraps a bare `AVCaptureSession` in a `UIViewControllerRepresentable`.
private struct QRCaptureRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

// `@preconcurrency` on the delegate conformance: the callback is delivered
// on `.main` (set explicitly below via `setMetadataObjectsDelegate(_:queue:)`),
// so it is genuinely main-actor-safe even though the protocol itself
// predates Swift concurrency and isn't annotated as such.
private final class QRScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard previewLayer != nil, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    /// No camera hardware (the simulator) or a camera that fails to open
    /// both land here -- `onUnavailable()` is the one path back to a
    /// non-crashing UI state either way.
    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onUnavailable?()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onUnavailable?()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmit else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue
        else { return }
        didEmit = true
        session.stopRunning()
        onCode?(value)
    }
}

#Preview {
    QRScannerView(onCode: { _ in })
}
