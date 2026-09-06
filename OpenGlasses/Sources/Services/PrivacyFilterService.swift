import Foundation
import Vision
import UIKit
import CoreImage
import Combine

/// Which frame consumers the bystander blur is applied to (Plan CO Item 0).
///
/// The blur was written and then never called — `processFrame` had no call sites anywhere in the
/// app, so the Settings toggle was inert and the promise it made was false. Wiring it back raises
/// the question the original never answered: *which* consumers? Two constraints decide it.
///
/// 1. **Face recognition must see raw pixels.** The blur is indiscriminate (the known-contact
///    exemption list was removed in BK P6 as dead code), so filtering ahead of recognition would
///    blur the very faces the user deliberately enrolled and break the feature outright.
/// 2. **Blurring costs a Vision pass plus a Core Image composite per frame.** The model-facing
///    paths are already throttled; camera-rate consumers share the off-main `OutboundFrameRelay`.
///
/// Every egress scope is covered. When the filter is enabled, a processing failure never returns
/// the source image: camera-rate consumers drop it in `OutboundFrameRelay`, while this service's
/// nonoptional still-image API returns an opaque replacement.
///
/// A third constraint arrived with Plan CV: **not every model-facing consumer is an egress.** A
/// frame handed to an on-device VLM never leaves the device, so there is nothing to filter, and
/// constraint 1 applies to it unchanged — the blur would degrade exactly the descriptions the
/// feature exists to produce. That decision is stated as a case below rather than left implicit,
/// because CO exists in the first place because an unstated scope decision became a toggle that
/// did nothing.
enum PrivacyFilterScope: String, CaseIterable {
    /// Frames pushed or polled into a live realtime session (Gemini Live, OpenAI Realtime).
    case liveSession
    /// Stills attached to a Direct-mode LLM turn.
    case directModelTurn
    /// The frozen frame taken by Plan CE — filtered once at pin time, not per resend.
    case pinnedFrame
    /// A still attached to a delegated remote-agent task (Plan CN).
    case agentAttachment
    /// Face enrolment and matching. Never filtered — see constraint 1.
    case faceRecognition
    /// Continuous scene narration on the **on-device** VLM (Plan CV). Never filtered, and the
    /// reason is the same as constraint 1 rather than an oversight: frames never leave the device,
    /// so there is no egress to filter, and the blur is indiscriminate — it would degrade exactly
    /// the descriptions a blind wearer depends on ("someone is standing near the door" is the
    /// *point*). Narration pointed at a **cloud** model is an egress like any other and belongs on
    /// `directModelTurn`, filtered; it is not covered by this case.
    case sceneNarration
    /// Video recording to disk. Covered as of Plan CP, via `OutboundFrameRelay`.
    case recording
    /// RTMP broadcast and WebRTC browser streaming. Covered as of Plan CP.
    case broadcast
    /// Expert streaming (peer-to-peer and meeting-link transports). Covered as of Plan CP.
    case expertStream

    /// Whether the bystander blur is applied to this consumer when the setting is on.
    var isFiltered: Bool {
        switch self {
        case .liveSession, .directModelTurn, .pinnedFrame, .agentAttachment,
             .recording, .broadcast, .expertStream:
            return true
        case .faceRecognition, .sceneNarration:
            return false
        }
    }

    /// Consumers fed by the shared `OutboundFrameRelay` (Plan CP) rather than filtered at their own
    /// chokepoint. They run at camera rate, so they share one blur pass instead of each paying for
    /// their own — which also means adding a consumer here is a wiring change, not a new call site.
    var usesOutboundRelay: Bool {
        switch self {
        case .recording, .broadcast, .expertStream: return true
        case .liveSession, .directModelTurn, .pinnedFrame, .agentAttachment, .faceRecognition,
             .sceneNarration: return false
        }
    }
}

/// Vision must distinguish a verified empty result from an execution failure. Treating both as
/// `[]` makes an unavailable detector indistinguishable from “safe to send the original pixels.”
enum PrivacyFaceDetectionResult: Equatable {
    case success([CGRect])
    case failure
}

/// Automatically detects and blurs bystander faces in video frames.
///
/// Applied at the model-facing chokepoints listed in `PrivacyFilterScope` — the same
/// gate-at-the-chokepoint shape `FramePin` uses, and for the same reason: filtering inside
/// `CameraService` would catch consumers that must not be filtered.
@MainActor
class PrivacyFilterService: ObservableObject {
    @Published var isEnabled = false
    @Published var facesBlurredCount: Int = 0

    /// Blur radius for face anonymization
    var blurRadius: Double = 20.0

    // BK P6: `exemptFaceprints` (a "don't blur known contacts" list) was declared but never
    // populated or read — the blur path blurs every detected face. Removed the dead field rather
    // than ship a config surface that does nothing; wiring real known-contact exemption would need
    // face-matching in the blur path (a Plan-level feature, not a mechanical honesty fix).

    /// Shared render context — `nonisolated` so the off-main `blurFaces` reuses this one Metal
    /// pipeline instead of building a fresh CIContext per frame (a classic per-frame GPU cost).
    private nonisolated let ciContext = CIContext()

    /// Whether processing is suspended (background optimization for streaming).
    private var isSuspended = false

    /// Read-only view of the suspend state for `OutboundFrameRelay` (Plan CP), which has to make
    /// the same passthrough decision per frame.
    var isSuspendedForBackground: Bool { isSuspended }

    // MARK: - Public API

    /// Suspend face blurring (background optimization — no UI visible, save CPU).
    func suspend() {
        isSuspended = true
        PrivacyLog.camera(.privacyFilter, .suspended)
    }

    /// Resume face blurring after returning to foreground.
    func resume() {
        isSuspended = false
        PrivacyLog.camera(.privacyFilter, .resumed)
    }

    /// Process a protected still-image path. With the filter off this is a true passthrough; with
    /// it on, the source image is returned only after Vision successfully reports no faces.
    /// Suspension or any conversion/detection/composite failure returns an opaque replacement.
    func processFrame(_ image: UIImage) -> UIImage {
        guard isEnabled else { return image }
        guard !isSuspended else { return failClosedFrame(like: image, reason: "suspended") }
        guard let cgImage = image.cgImage else {
            return failClosedFrame(like: image, reason: "conversionFailed")
        }

        let faceRects: [CGRect]
        switch Self.detectFaces(in: cgImage) {
        case .success(let detected):
            faceRects = detected
        case .failure:
            return failClosedFrame(like: image, reason: "detectionFailed")
        }
        guard !faceRects.isEmpty else { return image }  // verified no-face result

        guard let blurred = blurFaces(in: image, faceRects: faceRects) else {
            return failClosedFrame(like: image, reason: "compositeFailed")
        }
        facesBlurredCount += faceRects.count
        return blurred
    }

    /// The single entry point for call sites: blur for `scope`, or hand the frame back untouched
    /// when that consumer is exempt (`PrivacyFilterScope.isFiltered`) or the filter is off.
    ///
    /// Callers pass their scope rather than deciding for themselves, so "is face recognition
    /// exempt?" is answered in one tested place instead of at each chokepoint.
    func filtered(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage {
        guard scope.isFiltered else { return image }
        return processFrame(image)
    }

    // MARK: - Face Detection

    nonisolated static func detectFaces(in cgImage: CGImage) -> PrivacyFaceDetectionResult {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let results = request.results else { return .failure }

            // Convert normalized rects to image coordinates
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)

            return .success(results.map { face in
                let box = face.boundingBox
                // Vision uses bottom-left origin, flip to top-left
                return CGRect(
                    x: box.origin.x * imageWidth,
                    y: (1 - box.origin.y - box.height) * imageHeight,
                    width: box.width * imageWidth,
                    height: box.height * imageHeight
                )
            })
        } catch {
            return .failure
        }
    }

    /// A failure marker that contains none of the source pixels. The lower-rate filtering API is
    /// intentionally nonoptional because live-session and pin call sites expect an image. An opaque
    /// frame preserves that contract while making encoder success safe; zero-size/non-renderable
    /// inputs become an empty `UIImage`, which downstream encoders reject rather than expose.
    private func failClosedFrame(like image: UIImage, reason: String) -> UIImage {
        PrivacyLog.camera(.privacyFilter, .frameRejected, detail: PrivacyToken(reason))
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return UIImage()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(image.scale, 1)
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Face Blurring

    private nonisolated func blurFaces(in image: UIImage, faceRects: [CGRect]) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let imageSize = ciImage.extent.size

        // Create a blurred version of the entire image
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(20.0, forKey: kCIInputRadiusKey)

        guard let blurredImage = blurFilter.outputImage else { return nil }

        // Crop blurred image to original bounds (blur expands edges)
        let croppedBlurred = blurredImage.cropped(to: ciImage.extent)

        // Create a composite: original image with blurred face regions
        var result = ciImage

        for faceRect in faceRects {
            // Expand face rect slightly for better coverage
            let expanded = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)

            // Convert to CIImage coordinates (flip Y)
            let ciRect = CGRect(
                x: expanded.origin.x,
                y: imageSize.height - expanded.origin.y - expanded.height,
                width: expanded.width,
                height: expanded.height
            )

            // Create an oval mask for natural face shape
            _ = CIVector(x: ciRect.origin.x, y: ciRect.origin.y,
                         z: ciRect.width, w: ciRect.height)

            // Use a radial gradient as an elliptical mask
            guard let radialGradient = CIFilter(name: "CIRadialGradient") else { return nil }
            let center = CIVector(x: ciRect.midX, y: ciRect.midY)
            radialGradient.setValue(center, forKey: "inputCenter")
            radialGradient.setValue(min(ciRect.width, ciRect.height) * 0.4, forKey: "inputRadius0")
            radialGradient.setValue(max(ciRect.width, ciRect.height) * 0.55, forKey: "inputRadius1")
            radialGradient.setValue(CIColor.white, forKey: "inputColor0")
            radialGradient.setValue(CIColor.clear, forKey: "inputColor1")

            guard let maskImage = radialGradient.outputImage else { return nil }

            // Blend blurred face region with original using mask
            guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
            blendFilter.setValue(croppedBlurred, forKey: kCIInputImageKey)
            blendFilter.setValue(result, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)

            guard let blended = blendFilter.outputImage else { return nil }
            result = blended.cropped(to: ciImage.extent)
        }

        // Render final image
        guard let outputCGImage = ciContext.createCGImage(result, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
