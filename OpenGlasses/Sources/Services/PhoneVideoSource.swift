import AVFoundation
import CoreImage
import UIKit

/// Plan BS P3 — continuous phone-camera frames for broadcasting (front or back).
///
/// `PhoneCameraSource` is still-capture only; this is its video sibling: an
/// `AVCaptureVideoDataOutput` session delivering `UIImage` frames via a callback, sized
/// and paced for the broadcast pipeline (the caller throttles). Deliberately does NOT
/// configure the app audio session (`automaticallyConfiguresApplicationAudioSession =
/// false`) so starting the phone camera can't tear down the wake-word mic.
final class PhoneVideoSource: NSObject, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "phone.video.source")
    private let captureSession = AVCaptureSession()
    private var frameHandler: (@Sendable (UIImage) -> Void)?

    /// One reusable context; intermediate caching disabled — per-frame CIContext churn
    /// exhausts IOSurfaces on iOS.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func start(
        position: AVCaptureDevice.Position,
        onFrame: @escaping @Sendable (UIImage) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameHandler = onFrame
            self.captureSession.beginConfiguration()
            self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }
            self.captureSession.sessionPreset = .hd1280x720
            self.captureSession.automaticallyConfiguresApplicationAudioSession = false

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: position),
                let input = try? AVCaptureDeviceInput(device: device),
                self.captureSession.canAddInput(input) else {
                PrivacyLog.camera(.phone, .unavailable, count: position.rawValue)
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.sessionQueue)
            guard self.captureSession.canAddOutput(output) else {
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addOutput(output)
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            PrivacyLog.camera(.phone, .started,
                              detail: PrivacyToken(position == .front ? "front" : "back"))
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameHandler = nil
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            PrivacyLog.camera(.phone, .stopped)
        }
    }
}

extension PhoneVideoSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let handler = frameHandler,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        handler(UIImage(cgImage: cgImage))
    }
}
