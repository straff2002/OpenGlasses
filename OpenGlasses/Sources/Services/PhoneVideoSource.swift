import AVFoundation
import Combine
import CoreImage
import UIKit

/// What the phone camera is doing, for whatever is drawing it.
enum PhoneCaptureStatus: Equatable, Sendable {
    case stopped
    case running
    /// iOS took the camera for now: the app left the foreground, or a call or another session has it.
    case interrupted
    /// There is no camera to run, as on a simulator, or the session would not start.
    case unavailable
}

/// Who needs the phone camera, and what that asks of the one session (Plan KH, pure).
///
/// A viewfinder and a stream sharing a session is the whole design: a second session on the same
/// camera would interrupt the first. So nothing starts or stops the session directly. Each holds a
/// claim, and the session follows the claims, which is why going live from the viewfinder restarts
/// nothing, and why closing the preview during a stream, or ending a stream with the preview open,
/// leaves the camera running for whoever still wants it.
///
/// The stream's camera wins: the viewfinder shows what is on air.
struct PhoneCaptureClaims: Equatable {
    var preview: AVCaptureDevice.Position?
    var stream: AVCaptureDevice.Position?

    var wanted: AVCaptureDevice.Position? { stream ?? preview }

    enum Step: Equatable {
        case none
        case start(AVCaptureDevice.Position)
        case switchCamera(AVCaptureDevice.Position)
        case stop
    }

    /// What the session has to do, from the camera it is running now (`nil` when stopped).
    func step(from running: AVCaptureDevice.Position?) -> Step {
        switch (running, wanted) {
        case (nil, nil): return .none
        case (nil, let wanted?): return .start(wanted)
        case (_?, nil): return .stop
        case (let running?, let wanted?): return running == wanted ? .none : .switchCamera(wanted)
        }
    }
}

/// Plan BS P3 — continuous phone-camera frames for broadcasting (front or back).
///
/// `PhoneCameraSource` is still-capture only; this is its video sibling: an
/// `AVCaptureVideoDataOutput` session delivering `UIImage` frames via a callback, sized
/// and paced for the broadcast pipeline (the caller throttles). Deliberately does NOT
/// configure the app audio session (`automaticallyConfiguresApplicationAudioSession =
/// false`) so starting the phone camera can't tear down the wake-word mic.
///
/// Plan KH: also the session behind the live preview's viewfinder (`PhoneViewfinder`), which draws
/// it through a preview layer, so the picture never enters app code. Frames are only converted
/// while a stream holds a claim: a viewfinder on its own costs no CPU here.
final class PhoneVideoSource: NSObject, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "phone.video.source")
    private let captureSession = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var claims = PhoneCaptureClaims()
    private var runningPosition: AVCaptureDevice.Position?
    private var frameHandler: (@Sendable (UIImage) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// One reusable context; intermediate caching disabled — per-frame CIContext churn
    /// exhausts IOSurfaces on iOS.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Sent from the session's queue. Replays the current value to a new subscriber.
    let statusPublisher = CurrentValueSubject<PhoneCaptureStatus, Never>(.stopped)

    /// For a preview layer to draw. Everything else about the session stays in here.
    var sessionForPreview: AVCaptureSession { captureSession }

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                               object: captureSession, queue: nil) { [weak self] _ in
                self?.noteInterruption(true)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                               object: captureSession, queue: nil) { [weak self] _ in
                self?.noteInterruption(false)
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Claims

    /// The viewfinder is on screen. Starts the camera unless a stream already has it.
    func claimPreview(position: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.claims.preview = position
            self.follow()
        }
    }

    /// The viewfinder has gone. The camera stops unless a stream still has it.
    func releasePreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.claims.preview = nil
            self.follow()
        }
    }

    /// `releasePreview()` that returns once the session has stopped, so a still can have the camera.
    func releasePreviewAndWait() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.claims.preview = nil
                self?.follow()
                done.resume()
            }
        }
    }

    /// A stream wants frames from `position`. Claiming again moves it to another camera.
    func claimStream(position: AVCaptureDevice.Position,
                     onFrame: @escaping @Sendable (UIImage) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameHandler = onFrame
            self.claims.stream = position
            self.follow()
        }
    }

    func releaseStream() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameHandler = nil
            self.claims.stream = nil
            self.follow()
        }
    }

    // MARK: - The session

    /// Bring the session into line with the claims. On `sessionQueue`.
    private func follow() {
        switch claims.step(from: runningPosition) {
        case .none:
            break
        case .start(let position):
            guard useCamera(position) else { return }
            captureSession.startRunning()
            runningPosition = captureSession.isRunning ? position : nil
            statusPublisher.send(captureSession.isRunning ? .running : .unavailable)
            logStarted(position)
        case .switchCamera(let position):
            if useCamera(position) {
                runningPosition = position
                logStarted(position)
            }
        case .stop:
            captureSession.stopRunning()
            runningPosition = nil
            rotationObservation = nil
            rotation = nil
            statusPublisher.send(.stopped)
            PrivacyLog.camera(.phone, .stopped)
        }
    }

    /// Put `position` on the session. Reconfigures a running session without stopping it. A camera
    /// that cannot be had leaves the current one in place.
    private func useCamera(_ position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let next = try? AVCaptureDeviceInput(device: device) else {
            return cameraUnavailable(position)
        }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if let input { captureSession.removeInput(input) }
        captureSession.sessionPreset = .hd1280x720
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        guard captureSession.canAddInput(next) else {
            if let input { captureSession.addInput(input) }
            return cameraUnavailable(position)
        }
        captureSession.addInput(next)
        input = next

        if !captureSession.outputs.contains(output) {
            guard captureSession.canAddOutput(output) else { return cameraUnavailable(position) }
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            captureSession.addOutput(output)
        }
        followRotation(of: device)
        return true
    }

    /// Plan KH: keep frames upright as the phone turns. The output's buffers are the sensor's
    /// landscape otherwise, which put a phone held upright on air sideways, and the viewfinder now
    /// shows the wearer an upright picture. The encoder fits whatever comes to its canvas, so a
    /// turn costs a letterbox and never a restart.
    private func followRotation(of device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.rotateFrames(to: angle) }
        }
    }

    private func rotateFrames(to angle: CGFloat) {
        guard let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func cameraUnavailable(_ position: AVCaptureDevice.Position) -> Bool {
        PrivacyLog.camera(.phone, .unavailable, count: position.rawValue)
        statusPublisher.send(.unavailable)
        return false
    }

    private func logStarted(_ position: AVCaptureDevice.Position) {
        PrivacyLog.camera(.phone, .started, detail: PrivacyToken(position == .front ? "front" : "back"))
    }

    private func noteInterruption(_ interrupted: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.runningPosition != nil else { return }
            self.statusPublisher.send(interrupted ? .interrupted : .running)
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
