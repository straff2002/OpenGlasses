import XCTest
@testable import OpenGlasses

/// A finished reply said in parts (b705 report: the answer was on the screen ten seconds before
/// the cloud voice read it). The first part is one sentence, so the first request is short; the
/// rest are packed; nothing is lost or reordered.
@MainActor
final class WholeReplyPartsTests: XCTestCase {

    private let reply = """
        The compressor is short cycling because the low pressure switch is tripping. \
        Check the suction pressure with your gauges first. If it is below the cut-out, look for a \
        restriction at the filter drier. A frosted drier means it is blocked. Replace it, pull a \
        vacuum and recharge to the nameplate weight. Then run it for fifteen minutes and watch \
        whether the cycling stops.
        """

    func testFirstPartIsTheFirstSentenceAlone() {
        let parts = WholeReplyParts.parts(of: reply)
        XCTAssertEqual(parts.first,
                       "The compressor is short cycling because the low pressure switch is tripping.")
        XCTAssertGreaterThan(parts.count, 1)
    }

    func testPartsKeepEveryWordInOrder() {
        let parts = WholeReplyParts.parts(of: reply)
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace) }
        XCTAssertEqual(words(parts.joined(separator: " ")), words(reply))
    }

    func testLaterPartsArePackedUpToTheLimit() {
        let parts = WholeReplyParts.parts(of: reply, laterPartLimit: 120)
        for part in parts.dropFirst() {
            // A single sentence longer than the limit stands alone; packed parts stay within it.
            let sentenceCount = part.filter { $0 == "." }.count
            if sentenceCount > 1 { XCTAssertLessThanOrEqual(part.count, 120, part) }
        }
        XCTAssertLessThan(parts.count, 7, "six sentences after the first are packed, not one each")
    }

    func testAOneSentenceReplyIsOnePart() {
        XCTAssertEqual(WholeReplyParts.parts(of: "It is twenty two degrees and sunny."),
                       ["It is twenty two degrees and sunny."])
        XCTAssertEqual(WholeReplyParts.parts(of: "   "), [])
    }

    func testOutcomeIsCompletedOnlyWhenEveryPartPlayed() {
        XCTAssertEqual(WholeReplyParts.outcome(of: .init(sentenceCount: 3, heardCount: 3,
                                                         interruption: nil, unheardSentences: [])),
                       .completed)
        XCTAssertEqual(WholeReplyParts.outcome(of: .init(sentenceCount: 3, heardCount: 1,
                                                         interruption: .bargeIn, unheardSentences: ["b", "c"])),
                       .interrupted(by: .bargeIn))
        if case .failed = WholeReplyParts.outcome(of: .init(sentenceCount: 3, heardCount: 2,
                                                             interruption: nil, unheardSentences: ["c"])) {
        } else { XCTFail("a part that did not play is not a completed reply") }
    }

    /// The parts of a finished reply are not mirrored to the lens one by one: it went there whole.
    func testAQueueThatDoesNotMirrorPassesThatToEverySentence() async {
        let speech = RecordingStreamedSpeech()
        let queue = speech.beginStreamedReply(isCurrent: { true })
        queue.mirrorsSentences = false
        for part in WholeReplyParts.parts(of: reply) { queue.enqueue(part) }
        let record = await queue.finish()
        XCTAssertEqual(record.heardCount, record.sentenceCount)
        XCTAssertEqual(speech.played, WholeReplyParts.parts(of: reply))
        XCTAssertEqual(Set(speech.mirrored), [false])
    }
}
