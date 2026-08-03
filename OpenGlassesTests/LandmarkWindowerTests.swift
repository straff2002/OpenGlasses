import XCTest
@testable import OpenGlasses

/// Fixture tests for the pure fingerspelling feature pipeline (Plan CK P0): wrist-origin
/// centring, palm-size scaling, handedness mirroring, y-flip, NaN cleaning, CMVN, windowing.
final class LandmarkWindowerTests: XCTestCase {

    /// A synthetic frame: wrist at `wrist`, middle-finger MCP a known offset away, everything
    /// else at wrist + (1, 2, 0).
    private func frame(wrist: SIMD3<Float> = SIMD3(0.5, 0.5, 0),
                       middleMCPOffset: SIMD3<Float> = SIMD3(0, 0.2, 0),
                       isLeft: Bool = false,
                       timestamp: TimeInterval = 0) -> HandLandmarkFrame {
        var points = [SIMD3<Float>](repeating: wrist + SIMD3(1, 2, 0), count: HandJoint.count)
        points[HandJoint.wrist.rawValue] = wrist
        points[HandJoint.middleMCP.rawValue] = wrist + middleMCPOffset
        return HandLandmarkFrame(timestamp: timestamp, points: points, isLeftHand: isLeft)
    }

    private var noFlip: LandmarkWindower.Configuration {
        var config = LandmarkWindower.Configuration()
        config.flipYAxis = false
        return config
    }

    // MARK: - Normalisation

    func testWristBecomesOriginAndPalmBecomesUnit() throws {
        let features = try XCTUnwrap(LandmarkWindower.normalize(frame(), config: noFlip))
        XCTAssertEqual(features.count, 63)
        // Wrist (joints 0..2 of the flattened features) is exactly the origin.
        XCTAssertEqual(Array(features[0..<3]), [0, 0, 0])
        // Middle MCP sits at unit distance (it defines the palm scale).
        let mcp = HandJoint.middleMCP.rawValue * 3
        let norm = sqrt(features[mcp] * features[mcp]
            + features[mcp + 1] * features[mcp + 1]
            + features[mcp + 2] * features[mcp + 2])
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
    }

    func testTranslationAndScaleInvariance() throws {
        // The same hand shifted and doubled in size must produce identical features.
        let small = try XCTUnwrap(LandmarkWindower.normalize(frame(), config: noFlip))
        let bigPoints = frame().points.map { SIMD3(2, 2, 2) + $0 * 2 }
        let big = try XCTUnwrap(LandmarkWindower.normalize(
            HandLandmarkFrame(timestamp: 0, points: bigPoints), config: noFlip))
        for (a, b) in zip(small, big) {
            XCTAssertEqual(a, b, accuracy: 1e-4)
        }
    }

    func testLeftHandIsMirroredToRightHandGeometry() throws {
        let right = try XCTUnwrap(LandmarkWindower.normalize(frame(isLeft: false), config: noFlip))
        let left = try XCTUnwrap(LandmarkWindower.normalize(frame(isLeft: true), config: noFlip))
        // x components negate; y and z are untouched.
        for joint in 0..<HandJoint.count {
            XCTAssertEqual(left[joint * 3], -right[joint * 3], accuracy: 1e-5)
            XCTAssertEqual(left[joint * 3 + 1], right[joint * 3 + 1], accuracy: 1e-5)
        }
    }

    func testYFlipNegatesYOnly() throws {
        let flat = try XCTUnwrap(LandmarkWindower.normalize(frame(), config: noFlip))
        let flipped = try XCTUnwrap(LandmarkWindower.normalize(frame()))   // default flips y
        for joint in 0..<HandJoint.count {
            XCTAssertEqual(flipped[joint * 3], flat[joint * 3], accuracy: 1e-5)
            XCTAssertEqual(flipped[joint * 3 + 1], -flat[joint * 3 + 1], accuracy: 1e-5)
        }
    }

    func testNaNLandmarksBecomeZero() throws {
        var bad = frame()
        bad.points[HandJoint.indexTip.rawValue] = SIMD3(Float.nan, Float.nan, 0)
        let features = try XCTUnwrap(LandmarkWindower.normalize(bad, config: noFlip))
        let tip = HandJoint.indexTip.rawValue * 3
        XCTAssertEqual(Array(features[tip..<(tip + 3)]), [0, 0, 0])
    }

    func testDegeneratePalmDoesNotExplode() throws {
        // Middle MCP collapsed onto the wrist: scale clamps to the epsilon, output stays finite.
        let features = try XCTUnwrap(LandmarkWindower.normalize(
            frame(middleMCPOffset: SIMD3(0, 0, 0)), config: noFlip))
        XCTAssertTrue(features.allSatisfy(\.isFinite))
    }

    func testWrongJointCountRejected() {
        let malformed = HandLandmarkFrame(timestamp: 0, points: [SIMD3<Float>](repeating: .zero, count: 20))
        XCTAssertNil(LandmarkWindower.normalize(malformed))
        XCTAssertTrue(LandmarkWindower.features(for: [malformed]).isEmpty)
    }

    // MARK: - CMVN

    func testCMVNStandardises() {
        let features: [[Float]] = [[Float](repeating: 2, count: 63)]
        let mean = [Float](repeating: 1, count: 63)
        let std = [Float](repeating: 2, count: 63)
        let out = LandmarkWindower.applyCMVN(features, mean: mean, std: std)
        XCTAssertEqual(out[0][0], 0.5, accuracy: 1e-6)
    }

    func testCMVNWithBadStatsIsIdentity() {
        let features: [[Float]] = [[Float](repeating: 2, count: 63)]
        let out = LandmarkWindower.applyCMVN(features, mean: [0], std: [1])   // wrong lengths
        XCTAssertEqual(out, features)
    }

    // MARK: - Windowing

    func testWindowingLengthAndStride() {
        let frames = (0..<10).map { [Float](repeating: Float($0), count: 63) }
        let windows = LandmarkWindower.windows(of: frames, length: 4, stride: 3)
        XCTAssertEqual(windows.count, 3)                      // starts at 0, 3, 6
        XCTAssertEqual(windows[0].first?.first, 0)
        XCTAssertEqual(windows[1].first?.first, 3)
        XCTAssertEqual(windows[2].last?.first, 9)
    }

    func testWindowingUnderflowAndBadParameters() {
        let frames = [[Float](repeating: 0, count: 63)]
        XCTAssertTrue(LandmarkWindower.windows(of: frames, length: 4, stride: 1).isEmpty)
        XCTAssertTrue(LandmarkWindower.windows(of: frames, length: 0, stride: 1).isEmpty)
        XCTAssertTrue(LandmarkWindower.windows(of: frames, length: 1, stride: 0).isEmpty)
    }
}
