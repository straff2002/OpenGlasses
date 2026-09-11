import Foundation
import Combine
import UIKit
import CoreImage

/// Plan CP — one blur pass, shared by every consumer that sends frames off the device.
///
/// Sits between `CameraService.framePublisher` and the outbound consumers (recording, RTMP
/// broadcast, WebRTC browser streaming, both expert transports). Blurring per consumer would run
/// Vision up to five times on the same frame; this runs it once and republishes.
///
/// It also puts "which consumers receive filtered pixels" in one wiring decision instead of five
/// independent ones — the property whose absence let the blur ship uncalled in the first place.
///
/// # Cost discipline
///
/// - **Filter off ⇒ true passthrough.** Forwarded on the spot, no queue hop, no copy, no latency.
///   Someone who never enables this pays nothing for its existence.
/// - **On ⇒** coalesced (never queued — see `FrameCoalescer`), composited on a serial queue, and
///   republished on the main actor where every consumer expects to receive.
/// - Detection runs on an interval, not per frame; the blur composites cached rectangles in
///   between (see `FaceRectCache`, including the residual that trade-off leaves).
@MainActor
final class OutboundFrameRelay: ObservableObject {

    /// What outbound consumers subscribe to instead of `CameraService.framePublisher`.
    let publisher = PassthroughSubject<UIImage, Never>()

    /// Frames discarded to keep up. Surfaced for the device measurement in CP P3 — a blur pipeline
    /// that silently drops most of the stream should be visible, not inferred. Includes coalescing
    /// and privacy-failure drops; `privacyDroppedFrameCount` separates the latter for diagnosis.
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var privacyDroppedFrameCount = 0

    /// No frame in flight and none pending — every frame this relay has accepted has been either
    /// published or counted as dropped. Read-only; lets a caller (in practice the tests) wait for
    /// the background detector/compositor hops to finish instead of guessing how long they take.
    var isIdle: Bool { !coalescer.isProcessing }

    private let filter: PrivacyFilterService
    private var coalescer = FrameCoalescer<UIImage>()
    private var rectCache: FaceRectCache
    private var subscription: AnyCancellable?

    /// The last availability generation this relay has reconciled with. When the filter becomes
    /// available again after a background/lock window, the generation moves and every cached face
    /// rectangle is thrown away: it describes the scene the wearer was looking at before the app
    /// went away, which is exactly the scene they are least likely to still be in. Publication then
    /// resumes only once a fresh detection has succeeded.
    private var lastResumeGeneration: Int

    /// Injectable clock. Frame ages are the whole basis of the staleness rule, so a test has to be
    /// able to make time pass without sleeping — and a slow-detector simulation has to be able to
    /// make it pass *during* a detection.
    private let now: @Sendable () -> TimeInterval

    typealias FaceDetector = (CGImage) -> PrivacyFaceDetectionResult
    typealias FaceCompositor = (UIImage, [CGRect], CIContext) -> UIImage?
    private let detector: FaceDetector
    private let compositor: FaceCompositor

    /// One Metal-backed context for the process. Building a `CIContext` per frame is a classic
    /// per-frame GPU cost; the sibling in `PrivacyFilterService` exists for the same reason.
    private nonisolated let ciContext = CIContext()

    /// Serial: the blur must not run concurrently with itself, and ordering must hold.
    private nonisolated let queue = DispatchQueue(label: "outbound.frame.blur", qos: .userInitiated)

    init(filter: PrivacyFilterService,
         detector: @escaping FaceDetector = PrivacyFilterService.detectFaces,
         compositor: @escaping FaceCompositor = OutboundFrameRelay.composite,
         rectCache: FaceRectCache = FaceRectCache(),
         now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.filter = filter
        self.detector = detector
        self.compositor = compositor
        self.rectCache = rectCache
        self.now = now
        self.lastResumeGeneration = filter.resumeGeneration
    }

    /// Begin relaying from `source`. Safe to call again; the previous subscription is replaced.
    func attach(to source: PassthroughSubject<UIImage, Never>) {
        subscription = source.sink { [weak self] image in
            self?.ingest(image)
        }
    }

    func detach() {
        subscription = nil
        coalescer.reset()
        rectCache.reset()
    }

    // MARK: - Ingest

    private func ingest(_ image: UIImage) {
        // Privacy-off remains a true, explicit passthrough. Suspension while enabled means the
        // filter is unavailable, not permission to put the source pixels on an outbound stream.
        guard filter.isEnabled else {
            publisher.send(image)
            return
        }
        guard !filter.isSuspendedForBackground else {
            dropForPrivacy(reason: filter.unavailableReason?.rawValue ?? "suspended")
            return
        }
        reconcileAvailabilityGeneration()

        switch coalescer.submit(image) {
        case .process(let frame):
            blur(frame)
        case .madePending(let dropped):
            droppedFrameCount += dropped
        }
    }

    private func blur(_ image: UIImage) {
        let now = self.now()
        let needsDetection = rectCache.shouldDetect(now: now)
        let context = ciContext

        // Detection returns **pixel** rects (from `cgImage.width/height`) and `composite` flips
        // them against the CIImage extent, which is also pixels. `image.size` is points, so
        // clamping against it would truncate every rect on a 2x/3x frame. Everything downstream
        // of here stays in pixel space.
        guard let cgImage = image.cgImage else {
            finishDropping(reason: "conversionFailed")
            return
        }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let detector = self.detector
        let compositor = self.compositor

        queue.async { [weak self] in
            let detection: PrivacyFaceDetectionResult? = needsDetection ? detector(cgImage) : nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failure? = detection {
                    self.finishDropping(reason: "detectionFailed")
                    return
                }
                if case .success(let detected)? = detection {
                    self.rectCache.record(detected, at: now)
                }

                let rects: [CGRect]
                switch self.rectCache.masking(now: now, frameSize: pixelSize) {
                case .stale:
                    // The only detection available is older than `maxDetectionAge` — it describes
                    // a scene that may have people in it who were not there when it ran. An empty
                    // mask here is ignorance, not a clean bill of health. Forget it, so the next
                    // frame is re-detected rather than dropped against the same dead cache.
                    self.rectCache.reset()
                    self.finishDropping(reason: "staleDetection")
                    return
                case .verifiedClear:
                    // Vision verified there was nobody, recently enough to still be about this
                    // frame. Publish untouched — compositing nothing would still cost a render.
                    self.finish(with: image, maskedFor: pixelSize)
                    return
                case .rects(let masks):
                    rects = masks
                }

                // `[weak self]` here as well as on the inner `Task`: after the `guard let self`
                // above, `self` is a strong local, so an unannotated closure would capture it
                // strongly and the inner `[weak self]` would be decorative — a relay released
                // mid-pipeline would be held alive to composite and publish one more frame.
                self.queue.async { [weak self] in
                    let blurred = compositor(image, rects, context)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard let blurred else {
                            self.finishDropping(reason: "compositeFailed")
                            return
                        }
                        self.finish(with: blurred, maskedFor: pixelSize)
                    }
                }
            }
        }
    }

    /// Publish `image`.
    ///
    /// `maskedFor` carries the pixel extent of the frame whose mask authorised this publication;
    /// pass `nil` only on the filter-off passthrough, where no mask was involved. When it is
    /// supplied, the detection's age is re-tested here rather than only where the mask was chosen,
    /// because everything between those two points — the Vision pass, the queue hop, the Core Image
    /// composite — takes wall-clock time under load. Under real CPU pressure that is precisely when
    /// a mask goes from current to obsolete, and this is the last moment the frame can still be
    /// stopped.
    private func finish(with image: UIImage, maskedFor pixelSize: CGSize? = nil) {
        // Suspension can race a frame already on the detector/compositor queue. Recheck at the
        // publication boundary so a successful no-face result cannot release its source pixels
        // after the app has declared protected filtering unavailable in the background.
        guard !filter.isEnabled || !filter.isSuspendedForBackground else {
            finishDropping(reason: "suspendedBeforePublish")
            return
        }
        if filter.isEnabled, let pixelSize,
           rectCache.masking(now: now(), frameSize: pixelSize) == .stale {
            rectCache.reset()
            finishDropping(reason: "staleBeforePublish")
            return
        }
        publisher.send(image)
        continueWithPendingFrame()
    }

    private func finishDropping(reason: String) {
        dropForPrivacy(reason: reason)
        continueWithPendingFrame()
    }

    private func dropForPrivacy(reason: String) {
        droppedFrameCount += 1
        privacyDroppedFrameCount += 1
        PrivacyLog.camera(.privacyFilter, .frameRejected, detail: PrivacyToken(reason))
    }

    /// Throw away detections made before the app last lost and regained the ability to filter.
    private func reconcileAvailabilityGeneration() {
        let generation = filter.resumeGeneration
        guard generation != lastResumeGeneration else { return }
        lastResumeGeneration = generation
        rectCache.reset()
    }

    private func continueWithPendingFrame() {
        if let next = coalescer.finishedProcessing() {
            // This frame entered while another was running, so its policy state must be evaluated
            // now. `ingest` cannot be reused while the coalescer deliberately remains busy.
            if filter.isEnabled, filter.isSuspendedForBackground {
                finishDropping(reason: filter.unavailableReason.map { "\($0.rawValue)Pending" }
                                       ?? "suspendedPending")
            } else if filter.isEnabled {
                blur(next)
            } else {
                finish(with: next)
            }
        }
    }

    // MARK: - Core Image (off the main actor)

    private nonisolated static func composite(_ image: UIImage,
                                              rects: [CGRect],
                                              context: CIContext) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(20.0, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage?.cropped(to: extent) else { return nil }

        var result = ciImage
        for rect in rects {
            // Into CIImage coordinates (bottom-left origin).
            let ciRect = CGRect(x: rect.origin.x,
                                y: extent.height - rect.origin.y - rect.height,
                                width: rect.width, height: rect.height)

            guard let gradient = CIFilter(name: "CIRadialGradient") else { return nil }
            gradient.setValue(CIVector(x: ciRect.midX, y: ciRect.midY), forKey: "inputCenter")
            gradient.setValue(min(ciRect.width, ciRect.height) * 0.4, forKey: "inputRadius0")
            gradient.setValue(max(ciRect.width, ciRect.height) * 0.55, forKey: "inputRadius1")
            gradient.setValue(CIColor.white, forKey: "inputColor0")
            gradient.setValue(CIColor.clear, forKey: "inputColor1")
            guard let mask = gradient.outputImage else { return nil }

            guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
            blend.setValue(blurred, forKey: kCIInputImageKey)
            blend.setValue(result, forKey: kCIInputBackgroundImageKey)
            blend.setValue(mask, forKey: kCIInputMaskImageKey)
            guard let blended = blend.outputImage else { return nil }
            result = blended.cropped(to: extent)
        }

        guard let output = context.createCGImage(result, from: extent) else { return nil }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }
}
