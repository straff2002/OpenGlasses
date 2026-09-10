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

    /// Where a fired capture is written. Injectable for the same reason `announce` is, and because
    /// the privacy behaviour below has to be testable without a Photos library.
    var saveCapture: (UIImage) async -> Void = { _ = await GlassesPhotoAlbum.saveImage($0) }

    /// The bystander blur, for the crop only (W04.1).
    ///
    /// The saliency loop above reads raw pixels and stays exempt — it emits candidate boxes and
    /// nothing else. The crop it produces is a different matter: the Photos library is shared with
    /// every app the wearer has granted it to and syncs off the device, so a bystander in a saved
    /// capture has left this app entirely. Absent, or unable to filter, nothing is saved.
    weak var privacyFilter: (any StillImageFiltering)?

    private var tracker = DwellTracker()
    private var frameSubscription: AnyCancellable?
    private var isProcessingFrame = false
    private let startDate = Date()

    /// Saliency runs at most this often — dwell needs coarse cadence, not video rate.
    private let frameInterval: TimeInterval = 0.5

    func start(cameraService: CameraService, privacyFilter: (any StillImageFiltering)? = nil) {
        self.privacyFilter = privacyFilter
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

    /// Internal rather than private so the privacy behaviour can be driven headless — the frame
    /// loop above needs a camera, this does not.
    func advance(boxes: [CGRect], at time: TimeInterval, frame: UIImage) async {
        isProcessingFrame = false
        guard case .fired(let box) = tracker.process(boxes: boxes, at: time) else { return }

        // The on-screen preview of what was just captured stays raw: it is drawn on the phone the
        // wearer is holding and goes nowhere else, the same reasoning `onDevicePreview` records.
        lastCapture = Self.crop(frame, to: box) ?? frame

        // Blur the whole frame and crop the result, not the other way round: face rectangles are
        // detected in frame coordinates, and a crop that clips a face would otherwise hand the
        // detector a fragment it may not recognise as one.
        guard let filtered = privacyFilter?.filteredOrUnavailable(frame, for: .photoLibrary) else {
            await announce?("I couldn't save that one.")
            return
        }
        let captured = Self.crop(filtered, to: box) ?? filtered

        // Same album, same one prompt, as every other capture — a dwell capture used to land
        // loose in the camera roll and ask for the library on its own. Not awaited: the very
        // first save can sit on a permission prompt, and the wearer should hear the confirmation
        // when the capture happened, not when they answer it.
        let save = saveCapture
        Task { await save(captured) }
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
