import Foundation
import MediaPipeTasksShim
import UIKit

/// Seam between the camera pipeline and the fingerspelling cores (Plan CK P2): one video
/// frame in, one canonical 543-landmark `HolisticFrame` out. The pure pipeline
/// (`HolisticWindower` → model → `DecodeStabilityPolicy`) only ever sees this protocol, so
/// unit tests drive it with synthetic frames and never touch the MediaPipe runtime.
///
/// Frames arrive as `UIImage` because that is what `CameraService.framePublisher` emits —
/// its listener copies pixel data out of the VideoToolbox pool immediately (holding the
/// SDK's buffers across async boundaries exhausts the pool), so the already-safe `UIImage`
/// is the natural handoff and `MPImage` consumes it directly.
protocol HolisticLandmarkProviding {
    /// Extract landmarks from one camera frame. `timestampMilliseconds` must be
    /// monotonically increasing across calls (video running-mode requirement).
    func holisticFrame(for image: UIImage,
                       timestampMilliseconds: Int) throws -> HolisticFrame
}

/// Live implementation over MediaPipe's holistic landmarker — the same extractor family
/// that produced the model's training corpus, i.e. its native input distribution (the
/// 2026-08-03 ablation ruled out Apple Vision: 19 body joints vs the 33 expected, no face
/// mesh). One task bundle (`holistic_landmarker.task`, downloaded with the model, not
/// app-bundled) yields face + pose + both hands in a single video-mode call.
final class HolisticLandmarkService: HolisticLandmarkProviding {

    private let landmarker: HolisticLandmarker

    /// `taskModelURL` is the downloaded `holistic_landmarker.task` file.
    init(taskModelURL: URL) throws {
        let options = HolisticLandmarkerOptions()
        options.baseOptions.modelAssetPath = taskModelURL.path
        options.runningMode = .video
        landmarker = try HolisticLandmarker(options: options)
    }

    func holisticFrame(for image: UIImage,
                       timestampMilliseconds: Int) throws -> HolisticFrame {
        let image = try MPImage(uiImage: image)
        let result = try landmarker.detect(videoFrame: image,
                                           timestampInMilliseconds: timestampMilliseconds)
        // The canonical-order assembly itself is pure (`HolisticFrame.assembled`, covered
        // by SDK-free unit tests); this wrapper only unwraps the SDK's landmark types.
        func vectors(_ landmarks: [NormalizedLandmark]) -> [SIMD3<Float>] {
            landmarks.map { SIMD3(x: $0.x, y: $0.y, z: $0.z) }
        }
        return HolisticFrame.assembled(face: vectors(result.faceLandmarks),
                                       leftHand: vectors(result.leftHandLandmarks),
                                       pose: vectors(result.poseLandmarks),
                                       rightHand: vectors(result.rightHandLandmarks),
                                       timestamp: TimeInterval(timestampMilliseconds) / 1000)
    }
}
