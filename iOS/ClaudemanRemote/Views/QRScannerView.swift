import AVFoundation
import SwiftUI

/// Full-screen camera that reports the first QR code it reads.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    var onScan: (String) -> Void

    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if permissionDenied {
                ContentUnavailableView {
                    Label("Camera Access Needed", systemImage: "camera")
                } description: {
                    Text("Allow camera access in Settings to scan the pairing code, or enter the 6-digit code instead.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                .foregroundStyle(.white)
            } else {
                CameraPreview { value in
                    Haptics.notify(.success)
                    onScan(value)
                    dismiss()
                }
                .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 250, height: 250)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                Text("Point at the QR code in Claudeman › Settings › Remote on your Mac")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .task { await checkPermission() }
    }

    private func checkPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permissionDenied = false
        case .notDetermined: permissionDenied = !(await AVCaptureDevice.requestAccess(for: .video))
        default: permissionDenied = true
        }
    }
}

private struct CameraPreview: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didScan,
              let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        didScan = true
        session.stopRunning()
        onScan?(value)
    }
}
