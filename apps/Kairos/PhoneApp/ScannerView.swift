import SwiftUI
import AVFoundation

/// QR scanner over `AVCaptureMetadataOutput`.
///
/// Nothing captured here is written anywhere: no photo is taken, no frame is
/// retained, and the decoded string goes straight to the parser and then to the
/// watch. That is worth stating in the review notes, because a camera
/// permission on an authenticator app invites scrutiny.
struct ScannerView: UIViewControllerRepresentable {

    enum ScanError: LocalizedError {
        case cameraUnavailable
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: "No camera is available on this device."
            case .permissionDenied: "Kairos needs camera access to scan a setup code."
            }
        }
    }

    let onResult: (Result<String, ScanError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onResult: (Result<String, ScanError>) -> Void
        /// A QR code in frame fires this delegate many times a second. Without
        /// a latch the user gets a stack of identical confirmation sheets.
        private var hasDelivered = false

        init(onResult: @escaping (Result<String, ScanError>) -> Void) {
            self.onResult = onResult
        }

        func report(_ error: ScanError) { onResult(.failure(error)) }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasDelivered else { return }
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue
            else { return }

            hasDelivered = true
            onResult(.success(value))

            // Re-arm after a beat so a second account can be scanned without
            // leaving the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.hasDelivered = false
            }
        }
    }
}

final class ScannerViewController: UIViewController {
    weak var coordinator: ScannerView.Coordinator?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configure() : self?.coordinator?.report(.permissionDenied)
                }
            }
        default:
            coordinator?.report(.permissionDenied)
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            coordinator?.report(.cameraUnavailable)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            coordinator?.report(.cameraUnavailable)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        // Set *after* adding to the session, or the type is not yet available
        // and this throws.
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        // startRunning blocks; keeping it off the main thread avoids the
        // hitch on presenting this screen.
        Task.detached { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Task.detached { [session] in session.stopRunning() }
    }
}
