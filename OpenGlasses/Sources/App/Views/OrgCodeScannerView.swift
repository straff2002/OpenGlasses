import SwiftUI
import AVFoundation

/// Plan CT PR 3 — the one new piece of UI the plan called for: a live phone-camera QR scanner.
///
/// It does nothing but read one code and hand the text back. Whether that text is an organisation
/// profile, and what happens next, is `OrgEnrolmentService`'s business — the scanner never fetches,
/// verifies or applies anything, and it stops the camera the moment it has a code.
struct OrgCodeScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRCodeScanController()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch scanner.state {
                case .starting:
                    ProgressView().tint(.white)
                case .scanning:
                    QRCodePreview(session: scanner.session)
                        .ignoresSafeArea()
                        .accessibilityLabel(Text("Camera view"))
                    VStack {
                        Spacer()
                        Text("Point the camera at your organisation's code.")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 32)
                    }
                case .denied:
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle)
                            .accessibilityHidden(true)
                        Text("Camera access is off for OpenGlasses. Turn it on in Settings to scan a code, or open the code with the iPhone Camera app instead.")
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding()
                case .unavailable:
                    Text("This device has no camera that can scan a code.")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .navigationTitle("Organisation Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if scanner.torchAvailable {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            scanner.toggleTorch()
                        } label: {
                            Image(systemName: scanner.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                        .accessibilityLabel(scanner.torchOn ? Text("Turn light off") : Text("Turn light on"))
                    }
                }
            }
        }
        .task {
            await scanner.start { code in
                onCode(code)
                dismiss()
            }
        }
        .onDisappear { scanner.stop() }
    }
}

/// Live preview backed by an `AVCaptureVideoPreviewLayer`.
private struct QRCodePreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Owns the capture session for the scanner.
///
/// `@unchecked Sendable` on the same discipline as `PhoneCameraController`: all `AVCaptureSession`
/// work runs on `sessionQueue`, and every `@Published` mutation is hopped to the main queue.
final class QRCodeScanController: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate,
                                  @unchecked Sendable {
    enum State: Equatable {
        case starting, scanning, denied, unavailable
    }

    let session = AVCaptureSession()
    @Published private(set) var state: State = .starting
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false

    private let sessionQueue = DispatchQueue(label: "com.openglasses.org-code-scanner.session")
    private var device: AVCaptureDevice?
    private var onCode: (@MainActor (String) -> Void)?
    private var delivered = false

    @MainActor
    func start(onCode: @escaping @MainActor (String) -> Void) async {
        self.onCode = onCode
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        default:
            state = .denied
            return
        }
        sessionQueue.async { [self] in
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                DispatchQueue.main.async { self.state = .unavailable }
                return
            }
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.state = .unavailable }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            session.startRunning()
            device = camera
            let hasTorch = camera.hasTorch
            DispatchQueue.main.async {
                self.torchAvailable = hasTorch
                self.state = .scanning
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func toggleTorch() {
        let on = !torchOn
        sessionQueue.async { [self] in
            guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn = on }
        }
    }

    // Called on the main queue (see `setMetadataObjectsDelegate`).
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered,
              let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              !code.isEmpty else { return }
        delivered = true
        stop()
        let deliver = onCode
        MainActor.assumeIsolated { deliver?(code) }
    }
}
