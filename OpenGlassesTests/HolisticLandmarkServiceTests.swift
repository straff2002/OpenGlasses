import XCTest
@testable import OpenGlasses

/// Assembly tests for the landmark seam (Plan CK P2): per-part arrays in, the canonical
/// 543-landmark frame out. `HolisticFrame.assembled` is the pure half of
/// `HolisticLandmarkService` — no MediaPipe types, no graph runtime, no `.task` file.
final class HolisticLandmarkServiceTests: XCTestCase {

    /// `count` landmarks whose x encodes the index (x = base + i/1000) for order checks.
    private func landmarks(count: Int, base: Float) -> [SIMD3<Float>] {
        (0..<count).map { SIMD3(x: base + Float($0) / 1000, y: base + 0.1, z: 0) }
    }

    func testFullResultAssemblesInCanonicalOrder() {
        // The tasks-API face landmarker can emit 478 points (468 mesh + iris) — only the
        // first 468 belong to the training contract.
        let frame = HolisticFrame.assembled(face: landmarks(count: 478, base: 0.1),
                                            leftHand: landmarks(count: 21, base: 0.3),
                                            pose: landmarks(count: 33, base: 0.5),
                                            rightHand: landmarks(count: 21, base: 0.7),
                                            timestamp: 0.033)

        XCTAssertEqual(frame.points.count, HolisticLayout.landmarkCount)
        XCTAssertEqual(frame.timestamp, 0.033)
        XCTAssertEqual(frame.points[0].x, 0.1, accuracy: 1e-6)           // face 0
        XCTAssertEqual(frame.points[467].x, 0.1 + 0.467, accuracy: 1e-6) // face 467
        XCTAssertEqual(frame.points[468].x, 0.3, accuracy: 1e-6)         // left hand 0
        XCTAssertEqual(frame.points[488].x, 0.3 + 0.020, accuracy: 1e-6) // left hand 20
        XCTAssertEqual(frame.points[489].x, 0.5, accuracy: 1e-6)         // pose 0 (nose)
        XCTAssertEqual(frame.points[521].x, 0.5 + 0.032, accuracy: 1e-6) // pose 32
        XCTAssertEqual(frame.points[522].x, 0.7, accuracy: 1e-6)         // right hand 0
        XCTAssertEqual(frame.points[542].x, 0.7 + 0.020, accuracy: 1e-6) // right hand 20
        XCTAssertFalse(frame.isAllNaN)
    }

    func testMissingPartsBecomeNaNBlocks() {
        let frame = HolisticFrame.assembled(face: [],
                                            leftHand: [],
                                            pose: landmarks(count: 33, base: 0.5),
                                            rightHand: landmarks(count: 21, base: 0.7),
                                            timestamp: 0)

        XCTAssertTrue(HolisticLayout.faceRange.allSatisfy { frame.points[$0].x.isNaN })
        XCTAssertTrue(HolisticLayout.leftHandRange.allSatisfy { frame.points[$0].x.isNaN })
        XCTAssertTrue(HolisticLayout.poseRange.allSatisfy { frame.points[$0].x.isFinite })
        XCTAssertTrue(HolisticLayout.rightHandRange.allSatisfy { frame.points[$0].x.isFinite })
    }

    func testEmptyResultIsAllNaN() {
        XCTAssertTrue(HolisticFrame.assembled(face: [], leftHand: [], pose: [],
                                              rightHand: [], timestamp: 0).isAllNaN)
    }

    func testUndersizedPartIsLeftNaN() {
        // A malformed part (fewer landmarks than its block) must not partially fill.
        let frame = HolisticFrame.assembled(face: landmarks(count: 100, base: 0.1),
                                            leftHand: [], pose: [], rightHand: [],
                                            timestamp: 0)
        XCTAssertTrue(frame.isAllNaN)
    }
}
