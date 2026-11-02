import AVFoundation
import SwiftUI

/// The phone camera's picture in the live preview (Plan KH).
///
/// A preview layer on the session the stream uses (`PhoneVideoSource`), so going live changes
/// nothing about the camera, and the layer is composited by the system: the picture never enters
/// app code and costs the stream's frame path nothing. Aspect-fit, so the framing is what goes out.
struct PhoneViewfinder: UIViewRepresentable {
    let session: AVCaptureSession
    let position: AVCaptureDevice.Position
    /// Redraws when the session starts: a preview layer has no connection to rotate until then.
    let isRunning: Bool

    func makeUIView(context: Context) -> ViewfinderLayerView {
        let view = ViewfinderLayerView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ view: ViewfinderLayerView, context: Context) {
        view.follow(position)
    }

    static func dismantleUIView(_ view: ViewfinderLayerView, coordinator: ()) {
        view.previewLayer.session = nil
    }
}

/// Keeps the picture upright as the phone turns, through iOS's own rotation coordinator.
final class ViewfinderLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    // The layer class above is what makes this cast safe.
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var position: AVCaptureDevice.Position?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    func follow(_ next: AVCaptureDevice.Position) {
        if next != position,
           let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next) {
            position = next
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotation = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: .new) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            }
        }
        applyRotation()
    }

    private func applyRotation() {
        guard let rotation, let connection = previewLayer.connection else { return }
        let angle = rotation.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
}
