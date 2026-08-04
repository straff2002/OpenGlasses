import XCTest
@testable import OpenGlasses

/// Synthetic-logit tests for greedy CTC decoding (Plan CK P2) — collapse rules, blank and
/// auxiliary-class handling, vocabulary sidecar parsing, per-row observations. The golden
/// fixtures in `HolisticWindowerTests` additionally hold `decode` to the Python reference.
final class FingerspellingCTCDecoderTests: XCTestCase {

    /// A logit row whose argmax is `classIndex` (with a configurable margin).
    private func row(_ classIndex: Int, margin: Float = 10) -> [Float] {
        var logits = [Float](repeating: 0, count: 62)
        logits[classIndex] = margin
        return logits
    }

    private func classIndex(of character: Character) -> Int {
        FingerspellingCTCDecoder.charset.firstIndex(of: character)! + 1
    }

    // MARK: - Charset

    func testCharsetIsTheTrainingContract() {
        XCTAssertEqual(FingerspellingCTCDecoder.charset.count, 59)
        XCTAssertEqual(String(FingerspellingCTCDecoder.charset),
                       " !#$%&'()*+,-./0123456789:;=?@[_abcdefghijklmnopqrstuvwxyz~")
    }

    func testVocabularySidecarRoundTrip() {
        let sidecar = "<blank>\n"
            + FingerspellingCTCDecoder.charset.map(String.init).joined(separator: "\n") + "\n"
        XCTAssertEqual(FingerspellingCTCDecoder.vocabulary(fromSidecar: sidecar),
                       FingerspellingCTCDecoder.charset)
    }

    func testMalformedVocabularySidecarsAreRejected() {
        XCTAssertNil(FingerspellingCTCDecoder.vocabulary(fromSidecar: ""))
        XCTAssertNil(FingerspellingCTCDecoder.vocabulary(fromSidecar: "a\nb\n"))
        XCTAssertNil(FingerspellingCTCDecoder.vocabulary(fromSidecar: "<blank>\nab\nc\n"))
        XCTAssertNil(FingerspellingCTCDecoder.vocabulary(fromSidecar: "<blank>\n"))
    }

    // MARK: - Greedy decode

    func testDecodeCollapsesAdjacentRepeats() {
        let rows = [row(classIndex(of: "h")), row(classIndex(of: "h")),
                    row(classIndex(of: "i"))]
        XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: rows), "hi")
    }

    func testBlankSeparatedRepeatsSurvive() {
        let rows = [row(classIndex(of: "l")), row(FingerspellingCTCDecoder.blankClass),
                    row(classIndex(of: "l"))]
        XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: rows), "ll")
    }

    func testBlanksAndAuxiliaryClassesAreDropped() {
        let rows = [row(FingerspellingCTCDecoder.blankClass), row(60), row(61),
                    row(classIndex(of: "7")), row(FingerspellingCTCDecoder.blankClass)]
        XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: rows), "7")
    }

    func testDecodeOfEmptyRowsIsEmpty() {
        XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: []), "")
        XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: [[]]), "")
    }

    // MARK: - Per-row observations

    func testObservationMapsLetterWithConfidence() {
        let observation = FingerspellingCTCDecoder.observation(forRow: row(classIndex(of: "a")))
        XCTAssertEqual(observation.letter, "a")
        XCTAssertGreaterThan(observation.confidence, 0.99)
    }

    func testObservationForBlankAndAuxiliaryClassesIsNil() {
        XCTAssertNil(FingerspellingCTCDecoder.observation(
            forRow: row(FingerspellingCTCDecoder.blankClass)).letter)
        XCTAssertNil(FingerspellingCTCDecoder.observation(forRow: row(60)).letter)
        XCTAssertNil(FingerspellingCTCDecoder.observation(forRow: row(61)).letter)
    }

    func testObservationConfidenceReflectsMargin() {
        // A near-tie between two classes: the winner's softmax probability is ≈ 0.5.
        var logits = [Float](repeating: -20, count: 62)
        logits[classIndex(of: "a")] = 5
        logits[classIndex(of: "b")] = 5
        let observation = FingerspellingCTCDecoder.observation(forRow: logits)
        XCTAssertEqual(observation.confidence, 0.5, accuracy: 0.01)
    }
}
