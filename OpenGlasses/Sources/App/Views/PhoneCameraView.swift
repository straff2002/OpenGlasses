import SwiftUI
import AVFoundation

/// A pending phone-camera capture, carrying the prompt to run once a still is taken.
struct PhoneCameraRequest: Identifiable {
    let id = UUID()
    let prompt: String
    let userLog: String
}

/// A full-screen camera sheet that captures a single still from the iPhone's own
/// camera. Used as a fallback for photo quick actions (Describe / Event / Task /
/// Translate Sign) when the glasses are disconnected, so they stay useful with a
/// live preview to aim — unlike the glasses path, the phone needs the user to frame.
struct PhoneCameraView: View {
    let prompt: String
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = PhoneCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isReady {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button {
                        camera.stop()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                }
                .padding()

                Spacer()

                if let error = camera.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 24)
                } else if !camera.isReady {
                    ProgressView().tint(.white).padding(.bottom, 24)
                }

                // Shutter
                Button {
                    camera.capture { data in
                        camera.stop()
                        if let data { onCapture(data) } else { onCancel() }
                    }
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 4).frame(width: 84, height: 84))
                }
                .disabled(!camera.isReady || camera.isCapturing)
                .opacity(camera.isReady ? 1 : 0.4)
                .padding(.bottom, 40)
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }
}

/// Live preview backed by an AVCaptureVideoPreviewLayer.
private struct CameraPreview: UIViewRepresentable {
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

/// Owns the AVCaptureSession for the phone-camera fallback. Intentionally NOT
/// @MainActor: session configuration / start / stop must run off the main thread,
/// while @Published UI state is hopped back to main.
// @unchecked Sendable: thread safety is maintained by discipline — all AVCaptureSession
// work runs on `sessionQueue`, and every @Published mutation is hopped to the main queue.
final class PhoneCameraController: NSObject, ObservableObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.openglasses.phone-camera.session")
    private var captureHandler: ((Data?) -> Void)?

    @Published var isReady = false
    @Published var isCapturing = false
    @Published var error: String?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { await setError("Camera access is needed to take a photo."); return }
        case .denied, .restricted:
            await setError("Camera access is off. Enable it in Settings → OpenGlasses.")
            return
        default:
            break
        }

        sessionQueue.async { [self] in
            // Don't let the capture session tear down the app's playAndRecord audio
            // session (used for wake word / TTS).
            session.automaticallyConfiguresApplicationAudioSession = false
            session.beginConfiguration()
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.error = "No camera is available on this device." }
                return
            }
            session.addInput(input)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()

            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            DispatchQueue.main.async { self.isReady = running }
        }
    }

    func capture(_ completion: @escaping (Data?) -> Void) {
        guard isReady, !isCapturing else { completion(nil); return }
        isCapturing = true
        captureHandler = completion
        sessionQueue.async { [self] in
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    @MainActor private func setError(_ message: String) { self.error = message }
}

extension PhoneCameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async { [self] in
            isCapturing = false
            let handler = captureHandler
            captureHandler = nil
            handler?(data)
        }
    }
}
