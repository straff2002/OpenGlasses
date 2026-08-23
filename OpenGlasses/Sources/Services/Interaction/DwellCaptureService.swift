import Foundation
import Combine
import UIKit
import Vision

/// Dwell capture (Plan CG): hold your gaze on an object for ~2 s and it's captured —
/// hands-free, wake-word-free. Vision objectness saliency supplies candidate boxes on a
/// throttled tap of the camera frame stream; the pure `DwellTracker` decides when to fire.
/// Off by default (`Config.dwellCaptureEnabled`) — the saliency loop costs battery.
@MainActor
final class DwellCaptureService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastCapture: UIImage?

    /// Spoken confirmation sink, injected so this service doesn't own a TTS dependency.
    var announce: ((String) async -> Void)?

    private var tracker = DwellTracker()
    private var frameSubscription: AnyCancellable?
    private var isProcessingFrame = false
    private let startDate = Date()

    /// Saliency runs at most this often — dwell needs coarse cadence, not video rate.
    private let frameInterval: TimeInterval = 0.5

    func start(cameraService: CameraService) {
        guard frameSubscription == nil else { return }
        isRunning = true
        frameSubscription = cameraService.framePublisher
            .throttle(for: .seconds(frameInterval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] image in
                self?.handleFrame(image)
            }
    }

    func stop() {
        frameSubscription?.cancel()
        frameSubscription = nil
        tracker.reset()
        isRunning = false
    }

    // MARK: - Frame loop

    private func handleFrame(_ image: UIImage) {
        guard Config.dwellCaptureEnabled else { return }
        // Saliency is slower than the frame cadence; never queue behind ourselves.
        guard !isProcessingFrame, let cgImage = image.cgImage else { return }
        isProcessingFrame = true
        let now = Date().timeIntervalSince(startDate)

        Task.detached(priority: .utility) { [weak self] in
            let boxes = Self.salientBoxes(in: cgImage)
            await self?.advance(boxes: boxes, at: now, frame: image)
        }
    }

    private func advance(boxes: [CGRect], at time: TimeInterval, frame: UIImage) async {
        isProcessingFrame = false
        guard case .fired(let box) = tracker.process(boxes: boxes, at: time) else { return }

        let captured = Self.crop(frame, to: box) ?? frame
        lastCapture = captured
        GlassesPhotoAlbum.saveImage(captured)
        await announce?("Captured that.")
    }

    /// Objectness saliency → normalized boxes (Vision convention, origin bottom-left —
    /// the tracker is convention-agnostic, the crop converts to image space).
    nonisolated private static func salientBoxes(in cgImage: CGImage) -> [CGRect] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNSaliencyImageObservation,
              let objects = observation.salientObjects
        else { return [] }
        return objects.map { $0.boundingBox }
    }

    nonisolated private static func crop(_ image: UIImage, to normalizedBox: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // Vision boxes are bottom-left origin; CGImage cropping is top-left.
        let margin: CGFloat = 0.05
        let expanded = normalizedBox.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rect = CGRect(x: expanded.minX * width,
                          y: (1 - expanded.maxY) * height,
                          width: expanded.width * width,
                          height: expanded.height * height)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
