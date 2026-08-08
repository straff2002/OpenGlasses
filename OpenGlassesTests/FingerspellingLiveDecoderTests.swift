import XCTest
@testable import OpenGlasses

/// Synthetic-stream tests for the live decode engine (Plan CK P2): stub inference, no
/// MediaPipe, no Core ML — frames in, policy events out.
final class FingerspellingLiveDecoderTests: XCTestCase {

    // MARK: - Helpers

    private func presentFrame(_ value: Float = 0.5,
                              timestamp: TimeInterval = 0) -> HolisticFrame {
        HolisticFrame(timestamp: timestamp,
                      points: Array(repeating: SIMD3(value, value, 0),
                                    count: HolisticLayout.landmarkCount))
    }

    private var allNaNFrame: HolisticFrame {
        HolisticFrame(timestamp: 0,
                      points: Array(repeating: SIMD3(x: .nan, y: .nan, z: .nan),
                                    count: HolisticLayout.landmarkCount))
    }

    private func logitRow(_ letter: Character?) -> [Float] {
        var row = [Float](repeating: 0, count: 62)
        if let letter, let index = FingerspellingCTCDecoder.charset.firstIndex(of: letter) {
            row[index + 1] = 12
        } else {
            row[FingerspellingCTCDecoder.blankClass] = 12
        }
        return row
    }

    /// Stub inference: emits the given per-row letters (nil = blank) for the valid rows,
    /// blank rows beyond.
    private func stub(_ letters: [Character?]) -> FingerspellingLiveDecoder.Inference {
        { input in
            let validRows = (input.frameCount + 1) / 2
            return (0..<max(validRows, letters.count)).map { row in
                self.logitRow(row < letters.count ? letters[row] : nil)
            }
        }
    }

    /// Appends `count` present frames (they produce ⌈count/2⌉ decode rows).
    private func appendFrames(_ decoder: inout FingerspellingLiveDecoder, _ count: Int) {
        for index in 0..<count {
            XCTAssertTrue(decoder.append(presentFrame(0.4 + Float(index % 3) * 0.1,
                                                      timestamp: TimeInterval(index) / 30))
                .isEmpty)
        }
    }

    // MARK: - Display + commit flow

    func testLettersDisplayAndGapCommits() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 8) // 4 rows
        let events = try decoder.tick(infer: stub(["h", "h", nil, "i"]))
        XCTAssertEqual(events, [.display("h"), .display("hi")],
                       "adjacent repeats collapse; blank-separated letters append")

        // 8 all-NaN frames = 8 blank observations → the word-gap commit fires.
        var commit: [DecodeStabilityPolicy.Event] = []
        for _ in 0..<8 { commit.append(contentsOf: decoder.append(allNaNFrame)) }
        XCTAssertEqual(commit, [.commit("hi")])
    }

    func testBlankSeparatedRepeatDoublesLetter() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 8)
        let events = try decoder.tick(infer: stub(["l", nil, "l", nil]))
        XCTAssertEqual(events, [.display("l"), .display("ll")])
    }

    func testConsumedRowsAreNotReFed() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 8)
        _ = try decoder.tick(infer: stub(["a", nil, nil, nil]))
        // Same window, second tick: nothing new to consume — inference isn't even run.
        var inferenceRan = false
        let events = try decoder.tick(infer: { input in
            inferenceRan = true
            return try self.stub(["a", nil, nil, nil])(input)
        })
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(inferenceRan)

        // Two more frames → one new row → only that row is fed ("a" again after blanks).
        appendFrames(&decoder, 2)
        let more = try decoder.tick(infer: stub(["a", nil, nil, nil, "a"]))
        XCTAssertEqual(more, [.display("aa")])
    }

    func testSpaceActsAsWordBoundary() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 4)
        var events = try decoder.tick(infer: stub(["h", " "]))
        XCTAssertEqual(events, [.display("h")], "a decoded space must not enter the word")

        // Spaces keep accruing blank time until the gap commits the word.
        appendFrames(&decoder, 14)
        events = try decoder.tick(infer: stub(["h", " ", " ", " ", " ", " ", " ", " ", " "]))
        XCTAssertEqual(events, [.commit("h")])
    }

    func testLowConfidenceLettersAreBlanks() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 4)
        // A three-way tie between letters: the argmax is a letter but its softmax
        // probability ≈ 1/3 — under the 0.5 confidence floor, so it must count as blank.
        let events = decoder.tick(infer: { input in
            let validRows = (input.frameCount + 1) / 2
            var tied = [Float](repeating: -20, count: 62)
            tied[33] = 5; tied[34] = 5; tied[35] = 5 // 'a', 'b', 'c'
            return (0..<validRows).map { _ in tied }
        })
        XCTAssertEqual(events, [])
        XCTAssertEqual(decoder.currentWord, "")
    }

    func testValidatorRejectionIsReported() throws {
        var decoder = FingerspellingLiveDecoder(
            rules: FingerspellingLiveDecoder.ctcRules(validateWord: { $0.count > 2 }))
        appendFrames(&decoder, 4)
        _ = try decoder.tick(infer: stub(["h", "i"]))
        var events: [DecodeStabilityPolicy.Event] = []
        for _ in 0..<8 { events.append(contentsOf: decoder.append(allNaNFrame)) }
        XCTAssertEqual(events, [.rejected("hi")])
    }

    // MARK: - Window management

    func testAllNaNFramesNeverEnterTheWindow() {
        var decoder = FingerspellingLiveDecoder()
        for _ in 0..<5 { _ = decoder.append(allNaNFrame) }
        XCTAssertEqual(decoder.windowedFrameCount, 0)
    }

    func testMalformedFramesAreIgnored() {
        var decoder = FingerspellingLiveDecoder()
        _ = decoder.append(HolisticFrame(timestamp: 0, points: [SIMD3(0.5, 0.5, 0)]))
        XCTAssertEqual(decoder.windowedFrameCount, 0)
    }

    func testWindowOverflowEvictsInPairsAndKeepsRowAlignment() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, HolisticWindower.windowLength)
        XCTAssertEqual(decoder.windowedFrameCount, HolisticWindower.windowLength)
        _ = try decoder.tick(infer: stub([])) // consume all 384 rows as blanks

        // Two more frames: the window slides by one pair; exactly one new row shows up.
        appendFrames(&decoder, 2)
        XCTAssertEqual(decoder.windowedFrameCount, HolisticWindower.windowLength)
        var fedRows = 0
        _ = decoder.tick(infer: { input in
            fedRows = (input.frameCount + 1) / 2
            return (0..<fedRows).map { _ in self.logitRow(nil) }
        })
        // The engine consumed only the single new row (evicted 1 pair + 384 valid − 384
        // already consumed): observable as no duplicate letter events over a letter run.
        XCTAssertEqual(fedRows, HolisticWindower.windowLength / 2)

        var letterDecoder = FingerspellingLiveDecoder()
        appendFrames(&letterDecoder, HolisticWindower.windowLength)
        _ = try letterDecoder.tick(infer: stub(Array(repeating: "x", count: 384)))
        appendFrames(&letterDecoder, 2)
        let events = try letterDecoder.tick(infer: stub(Array(repeating: "x", count: 384)))
        XCTAssertEqual(events, [], "a continuing letter run must not re-append after a slide")
    }

    // MARK: - Flush / reset

    func testFlushFinishesPendingWord() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 4)
        _ = try decoder.tick(infer: stub(["o", "k"]))
        XCTAssertEqual(decoder.flush(), .commit("ok"))
        XCTAssertEqual(decoder.flush(), .none)
    }

    func testResetClearsWindowAndState() throws {
        var decoder = FingerspellingLiveDecoder()
        appendFrames(&decoder, 6)
        _ = try decoder.tick(infer: stub(["a"]))
        decoder.reset()
        XCTAssertEqual(decoder.windowedFrameCount, 0)
        XCTAssertEqual(decoder.currentWord, "")
        // After reset the same rows are fresh again.
        appendFrames(&decoder, 2)
        XCTAssertEqual(try decoder.tick(infer: stub(["a"])), [.display("a")])
    }
}
