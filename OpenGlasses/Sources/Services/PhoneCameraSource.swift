import AVFoundation
import UIKit

/// Headless iPhone back-camera capture, used as a fallback for the AI vision tools when
/// the glasses camera is unavailable (glasses offline / not connected / not registered).
///
/// Unlike `PhoneCameraController` (which drives a visible preview sheet so the user can
/// aim), this captures with no UI: it starts the back camera on demand, grabs a single
/// still, and stops — so the camera indicator is only lit during the brief capture.
///
/// Not @MainActor: AVCaptureSession config/start/stop run on `sessionQueue`. The single
/// in-flight capture continuation is set and resumed on the main queue for thread safety
/// (same discipline as PhoneCameraController).
/// The phone camera as `CameraService` sees it — one still, on demand.
///
/// A seam rather than a concrete reference because this is the branch the coordinator takes
/// whenever the glasses camera *can't* serve a capture, so any test that exercises that decision
/// lands in real AVFoundation. On a simulator whose camera privacy decision is still unresolved,
/// `requestAccess` then waits forever for a prompt no test runner can answer — the test hangs
/// rather than fails. Injecting the source keeps the fallback decision testable without a camera,
/// mirroring `GlassesCameraBackend` on the glasses side.
protocol PhoneCameraCapturing: AnyObject {
    /// Capture a single still as JPEG data.
    func capturePhoto() async throws -> Data
}

final class PhoneCameraSource: NSObject, PhoneCameraCapturing, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.openglasses.phone-camera.source")
    private var configured = false
    private var photoContinuation: CheckedContinuation<Data, Error>?

    /// Capture a single still from the iPhone back camera as JPEG data.
    func capturePhoto() async throws -> Data {
        try await ensureRunning()
        // Let auto-exposure / focus settle so the first frame isn't dark/blurry.
        try? await Task.sleep(nanoseconds: 350_000_000)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async { [self] in
                photoContinuation = cont
                sessionQueue.async { [self] in
                    photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
                }
            }
        }
        stop()
        PrivacyLog.camera(.phone, .photoCaptured, bytes: data.count)
        return data
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func ensureRunning() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CameraError.permissionDenied }
        case .denied, .restricted:
            throw CameraError.permissionDenied
        default:
            break
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                if session.isRunning { cont.resume(); return }
                if !configured {
                    // Don't let the capture session tear down the app's playAndRecord audio
                    // session (wake word / TTS).
                    session.automaticallyConfiguresApplicationAudioSession = false
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: device),
                          session.canAddInput(input) else {
                        session.commitConfiguration()
                        cont.resume(throwing: CameraError.captureFailed)
                        return
                    }
                    session.addInput(input)
                    if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
                    session.commitConfiguration()
                    configured = true
                }
                session.startRunning()
                cont.resume()
            }
        }
    }
}

extension PhoneCameraSource: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let raw = photo.fileDataRepresentation()
        DispatchQueue.main.async { [self] in
            let cont = photoContinuation
            photoContinuation = nil
            if let error {
                cont?.resume(throwing: error)
                return
            }
            // Normalize to JPEG so it matches the glasses path (capturePhoto returns JPEG)
            // regardless of the device's default photo codec (HEIC).
            guard let raw, let jpeg = UIImage(data: raw)?.jpegData(compressionQuality: 0.85) else {
                cont?.resume(throwing: CameraError.captureFailed)
                return
            }
            cont?.resume(returning: jpeg)
        }
    }
}
