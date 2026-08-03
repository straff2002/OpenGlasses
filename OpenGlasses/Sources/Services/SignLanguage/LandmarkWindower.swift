import Foundation

/// The 21 hand joints in the canonical (MediaPipe-style) order the fingerspelling model was
/// trained on (Plan CK). Vision's `VNHumanHandPoseRequest` provides the same 21 joints under
/// its own names — the P2 extractor enumerates them **in this order**, so the pure pipeline
/// below never sees framework types. Index 0 is the wrist; 9 (middle-finger MCP) anchors the
/// palm-size scale normalisation.
enum HandJoint: Int, CaseIterable {
    case wrist = 0
    case thumbCMC, thumbMCP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case pinkyMCP, pinkyPIP, pinkyDIP, pinkyTip

    static let count = 21
}

/// One timestamped set of hand landmarks, already in `HandJoint` order.
struct HandLandmarkFrame: Equatable {
    var timestamp: TimeInterval
    /// Exactly `HandJoint.count` points. Vision supplies normalised 2-D positions (z = 0);
    /// missing/low-confidence joints may be NaN — normalisation cleans them.
    var points: [SIMD3<Float>]
    /// Landmark handedness; left hands are mirrored so one model serves both.
    var isLeftHand: Bool = false
}

/// Pure feature pipeline for fingerspelling recognition (Plan CK P0): timestamped landmark
/// frames → normalised, fixed-length feature windows matching the model's training contract —
/// wrist-origin centred, palm-size scale-normalised, handedness-mirrored, NaN-cleaned,
/// optional CMVN. 63 features per frame (21 joints × 3). No Vision, no Core ML, no clock:
/// fixture-testable end to end.
enum LandmarkWindower {

    struct Configuration: Equatable {
        /// Vision's normalised coordinates have a bottom-left origin; the model's training
        /// data uses top-left. Flipping the y sign (about the wrist origin) reconciles them.
        var flipYAxis = true
        /// Mirror left hands about the wrist so the model only ever sees right-hand geometry.
        var mirrorLeftHands = true
        /// Floor for the palm-size divisor, so a degenerate frame can't explode the scale.
        var minimumPalmSize: Float = 1e-6

        init() {}
    }

    /// Feature count per frame.
    static let featuresPerFrame = HandJoint.count * 3

    /// Normalise one frame to its 63 features. Returns nil when the joint count is wrong
    /// (a malformed extractor output must fail loudly in tests, not silently mis-shape).
    static func normalize(_ frame: HandLandmarkFrame,
                          config: Configuration = Configuration()) -> [Float]? {
        guard frame.points.count == HandJoint.count else { return nil }

        let wrist = frame.points[HandJoint.wrist.rawValue]
        var centered = frame.points.map { $0 - wrist }

        if config.flipYAxis {
            centered = centered.map { SIMD3(x: $0.x, y: -$0.y, z: $0.z) }
        }
        if config.mirrorLeftHands && frame.isLeftHand {
            centered = centered.map { SIMD3(x: -$0.x, y: $0.y, z: $0.z) }
        }

        let palm = centered[HandJoint.middleMCP.rawValue]
        let palmSize = max(sqrt(palm.x * palm.x + palm.y * palm.y + palm.z * palm.z),
                           config.minimumPalmSize)

        var features = [Float]()
        features.reserveCapacity(featuresPerFrame)
        for point in centered {
            for value in [point.x / palmSize, point.y / palmSize, point.z / palmSize] {
                features.append(value.isFinite ? value : 0)
            }
        }
        return features
    }

    /// Normalise a frame sequence, dropping malformed frames.
    static func features(for frames: [HandLandmarkFrame],
                         config: Configuration = Configuration()) -> [[Float]] {
        frames.compactMap { normalize($0, config: config) }
    }

    /// Apply per-feature mean/variance normalisation (the stats ship with the model).
    /// Mismatched stat lengths return the input unchanged — bad stats must not corrupt.
    static func applyCMVN(_ features: [[Float]], mean: [Float], std: [Float]) -> [[Float]] {
        guard mean.count == featuresPerFrame, std.count == featuresPerFrame else { return features }
        return features.map { frame in
            guard frame.count == featuresPerFrame else { return frame }
            return frame.enumerated().map { index, value in
                let deviation = max(std[index], 1e-6)
                return (value - mean[index]) / deviation
            }
        }
    }

    /// Slice normalised frame features into fixed-length windows with the given stride.
    /// Frames arrive at capture rate; the model consumes `length`-frame windows. Returns an
    /// empty array until enough frames exist; invalid parameters return no windows.
    static func windows(of features: [[Float]], length: Int, stride: Int) -> [[[Float]]] {
        guard length > 0, stride > 0, features.count >= length else { return [] }
        var result: [[[Float]]] = []
        var start = 0
        while start + length <= features.count {
            result.append(Array(features[start..<(start + length)]))
            start += stride
        }
        return result
    }
}
