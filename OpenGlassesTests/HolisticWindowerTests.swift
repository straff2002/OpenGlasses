import XCTest
@testable import OpenGlasses

/// Tests for the holistic feature pipeline (Plan CK P2). Two layers: synthetic frames for
/// the structural rules (mirror table, NaN handling, padding), and golden fixtures exported
/// from the Python reference pipeline (`Scripts/export-fingerspelling-fixtures.py`) that
/// hold `HolisticWindower` + `FingerspellingCTCDecoder` to the training contract
/// end-to-end: raw landmarks → features (tolerance: the reference reduces in float32) →
/// logits → decoded text (exact).
final class HolisticWindowerTests: XCTestCase {

    // MARK: - Helpers

    /// A frame with every landmark at `value` (finite everywhere).
    private func uniformFrame(_ value: SIMD3<Float>, timestamp: TimeInterval = 0) -> HolisticFrame {
        HolisticFrame(timestamp: timestamp,
                      points: Array(repeating: value, count: HolisticLayout.landmarkCount))
    }

    private var allNaNFrame: HolisticFrame {
        uniformFrame(SIMD3(x: .nan, y: .nan, z: .nan))
    }

    /// A frame whose left-hand block is present and right-hand block is NaN (a left-handed
    /// signer), with face/pose present so the frame isn't all-NaN.
    private func leftHandedFrame(handValue: SIMD3<Float> = SIMD3(0.3, 0.6, 0.1)) -> HolisticFrame {
        var frame = uniformFrame(SIMD3(0.5, 0.5, 0))
        for index in HolisticLayout.rightHandRange {
            frame.points[index] = SIMD3(x: .nan, y: .nan, z: .nan)
        }
        for index in HolisticLayout.leftHandRange {
            frame.points[index] = handValue
        }
        return frame
    }

    // MARK: - Mirror table invariants

    func testMirrorTableIsSelfInversePermutation() {
        let table = HolisticLayout.mirrorSource
        XCTAssertEqual(table.count, HolisticLayout.landmarkCount)
        XCTAssertEqual(Set(table).count, HolisticLayout.landmarkCount, "must be a permutation")
        for (index, source) in table.enumerated() {
            XCTAssertEqual(table[source], index, "mirroring twice must restore landmark \(index)")
        }
    }

    func testMirrorTableSwapsHandBlocksExactly() {
        for offset in 0..<21 {
            XCTAssertEqual(HolisticLayout.mirrorSource[468 + offset], 522 + offset)
            XCTAssertEqual(HolisticLayout.mirrorSource[522 + offset], 468 + offset)
        }
        // Nose (pose landmark 0, index 489) is on the centreline and maps to itself.
        XCTAssertEqual(HolisticLayout.mirrorSource[489], 489)
    }

    func testMirroredFlipsXAndSwapsHands() {
        let frame = leftHandedFrame(handValue: SIMD3(0.3, 0.6, 0.1))
        let mirrored = HolisticWindower.mirrored(frame)
        // The left hand's data lands in the right-hand block, x-flipped, y/z untouched.
        for index in HolisticLayout.rightHandRange {
            XCTAssertEqual(mirrored.points[index].x, 0.7, accuracy: 1e-6)
            XCTAssertEqual(mirrored.points[index].y, 0.6, accuracy: 1e-6)
            XCTAssertEqual(mirrored.points[index].z, 0.1, accuracy: 1e-6)
        }
        // The (NaN) right hand lands in the left-hand block.
        for index in HolisticLayout.leftHandRange {
            XCTAssertTrue(mirrored.points[index].x.isNaN)
        }
    }

    // MARK: - Handedness vote

    func testLeftHandedWhenLeftBlockHasFewerNaNs() {
        XCTAssertTrue(HolisticWindower.isLeftHanded([leftHandedFrame()]))
        XCTAssertFalse(HolisticWindower.isLeftHanded([uniformFrame(SIMD3(0.5, 0.5, 0))]))
        XCTAssertFalse(HolisticWindower.isLeftHanded([]))
    }

    // MARK: - Window cleaning + shape

    func testAllNaNFramesAreDropped() {
        let frames = [allNaNFrame, uniformFrame(SIMD3(0.4, 0.4, 0)), allNaNFrame]
        XCTAssertEqual(HolisticWindower.features(for: frames).count, 1)
    }

    func testMalformedFramesAreDropped() {
        let malformed = HolisticFrame(timestamp: 0, points: [SIMD3(0.5, 0.5, 0)])
        XCTAssertTrue(HolisticWindower.features(for: [malformed]).isEmpty)
        XCTAssertNil(HolisticWindower.modelInput(for: [malformed]))
    }

    func testWindowTruncatesAtFixedLength() {
        let frames = (0..<(HolisticWindower.windowLength + 40)).map {
            uniformFrame(SIMD3(0.5, Float($0) / 1000, 0), timestamp: TimeInterval($0))
        }
        XCTAssertEqual(HolisticWindower.features(for: frames).count,
                       HolisticWindower.windowLength)
    }

    func testModelInputPadsAndMasks() throws {
        let input = try XCTUnwrap(HolisticWindower.modelInput(
            for: [uniformFrame(SIMD3(0.2, 0.4, 0)), uniformFrame(SIMD3(0.6, 0.8, 0))]))
        XCTAssertEqual(input.frameCount, 2)
        XCTAssertEqual(input.features.count,
                       HolisticWindower.windowLength * HolisticLayout.featuresPerFrame)
        XCTAssertEqual(input.mask.count, HolisticWindower.windowLength)
        XCTAssertEqual(Array(input.mask.prefix(2)), [1, 1])
        XCTAssertTrue(input.mask.dropFirst(2).allSatisfy { $0 == 0 })
        // Padding rows are exactly zero.
        let padStart = 2 * HolisticLayout.featuresPerFrame
        XCTAssertTrue(input.features[padStart...].allSatisfy { $0 == 0 })
    }

    func testStandardisationMatchesHandComputedValues() throws {
        // Two frames, all landmarks identical within a frame: per-channel mean/std are
        // exactly computable. x: 0.2 / 0.6 → mean 0.4, std 0.2; y: 0.4 / 0.8 → mean 0.6,
        // std 0.2; z all zero → std 0 → cleaned to 0.
        let rows = HolisticWindower.features(
            for: [uniformFrame(SIMD3(0.2, 0.4, 0)), uniformFrame(SIMD3(0.6, 0.8, 0))])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], -1, accuracy: 1e-5) // (0.2 − 0.4) / 0.2
        XCTAssertEqual(rows[0][1], -1, accuracy: 1e-5)
        XCTAssertEqual(rows[0][2], 0)                  // zero-std channel → cleaned
        XCTAssertEqual(rows[1][0], 1, accuracy: 1e-5)
        XCTAssertEqual(rows[1][1], 1, accuracy: 1e-5)
    }

    func testNaNLandmarksBecomeZeroFeatures() {
        var frame = uniformFrame(SIMD3(0.2, 0.4, 0.1))
        frame.points[0] = SIMD3(x: .nan, y: .nan, z: .nan)
        let rows = HolisticWindower.features(for: [frame, uniformFrame(SIMD3(0.6, 0.8, 0.3))])
        XCTAssertEqual(rows[0][0], 0)
        XCTAssertEqual(rows[0][1], 0)
        XCTAssertEqual(rows[0][2], 0)
        XCTAssertTrue(rows.allSatisfy { row in row.allSatisfy(\.isFinite) })
    }

    // MARK: - Golden fixtures (Python reference parity)

    private struct Fixture: Decodable {
        var sequenceId: Int
        var phrase: String
        var leftHanded: Bool
        var rawFrameCount: Int
        var processedFrameCount: Int
        var raw: String
        var features: String
        var logits: String
        var decoded: String

        func floats(_ base64: String) throws -> [Float] {
            let data = try XCTUnwrap(Data(base64Encoded: base64))
            return data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self)) // little-endian float32, host is LE
            }
        }

        func rawFrames() throws -> [HolisticFrame] {
            let values = try floats(raw)
            let perFrame = HolisticLayout.featuresPerFrame
            XCTAssertEqual(values.count, rawFrameCount * perFrame)
            return (0..<rawFrameCount).map { frameIndex in
                let base = frameIndex * perFrame
                let points = (0..<HolisticLayout.landmarkCount).map { landmark in
                    SIMD3(x: values[base + landmark * 3],
                          y: values[base + landmark * 3 + 1],
                          z: values[base + landmark * 3 + 2])
                }
                return HolisticFrame(timestamp: TimeInterval(frameIndex) / 30, points: points)
            }
        }

        func logitRows() throws -> [[Float]] {
            let values = try floats(logits)
            XCTAssertEqual(values.count % 62, 0)
            return stride(from: 0, to: values.count, by: 62).map {
                Array(values[$0..<($0 + 62)])
            }
        }
    }

    private func loadFixture(_ name: String) throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: HolisticWindowerTests.self).url(forResource: name, withExtension: "json"),
            "\(name).json missing from the test bundle")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func assertPipelineMatches(_ fixture: Fixture,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) throws {
        let frames = try fixture.rawFrames()
        XCTAssertEqual(HolisticWindower.isLeftHanded(frames.filter { !$0.isAllNaN }),
                       fixture.leftHanded, file: file, line: line)

        let rows = HolisticWindower.features(for: frames)
        XCTAssertEqual(rows.count, fixture.processedFrameCount, file: file, line: line)

        let expected = try fixture.floats(fixture.features)
        var maxDifference: Float = 0
        for (frameIndex, row) in rows.enumerated() {
            let base = frameIndex * HolisticLayout.featuresPerFrame
            for (featureIndex, value) in row.enumerated() {
                maxDifference = max(maxDifference, abs(value - expected[base + featureIndex]))
            }
        }
        // The reference standardises with float32 reductions; Swift accumulates in double.
        XCTAssertLessThan(maxDifference, 2e-3, "features diverge from the reference",
                          file: file, line: line)

        // Decode parity is exact: the reference's greedy collapse over its own logits.
        XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: try fixture.logitRows()),
                       fixture.decoded, file: file, line: line)
    }

    func testPlainFixtureMatchesReference() throws {
        let fixture = try loadFixture("fingerspelling_plain")
        XCTAssertFalse(fixture.leftHanded)
        try assertPipelineMatches(fixture)
    }

    func testLeftHandedFixtureMatchesReference() throws {
        let fixture = try loadFixture("fingerspelling_left_handed")
        XCTAssertTrue(fixture.leftHanded)
        try assertPipelineMatches(fixture)
    }

    /// The gate corpus contains no all-NaN frames (signers stay in view), so the frame-drop
    /// rule is exercised by construction: the reference drops all-NaN frames before every
    /// other step, so injecting them into a fixture's raw stream must leave the whole
    /// pipeline output — features and decode — byte-for-byte unchanged.
    func testInjectedAllNaNFramesChangeNothing() throws {
        let fixture = try loadFixture("fingerspelling_plain")
        var frames = try fixture.rawFrames()
        frames.insert(allNaNFrame, at: 0)
        frames.insert(allNaNFrame, at: frames.count / 2)
        frames.append(allNaNFrame)

        let rows = HolisticWindower.features(for: frames)
        XCTAssertEqual(rows.count, fixture.processedFrameCount)
        XCTAssertEqual(rows, HolisticWindower.features(for: try fixture.rawFrames()))
    }
}
