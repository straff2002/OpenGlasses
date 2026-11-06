import XCTest
@testable import OpenGlasses

/// Plan KP P1 — collecting one turn's answer for the card: streamed sentences, the final reply,
/// and a turn that ends early. The text only grows, so pages already read keep their words.
final class HUDAnswerTurnTests: XCTestCase {

    func testAWholeReplyIsTheAnswerAsWritten() {
        var turn = HUDAnswerTurn()
        turn.finish(reply: "  Line one.\nLine two.  ")
        XCTAssertTrue(turn.isFinished)
        XCTAssertEqual(turn.text, "Line one.\nLine two.")
    }

    func testStreamedSentencesThenTheFinalReplyAddOnlyTheRest() {
        var turn = HUDAnswerTurn()
        turn.append("Check the fuse.")
        turn.append("Then the breaker.")
        XCTAssertFalse(turn.isFinished)
        XCTAssertEqual(turn.text, "Check the fuse. Then the breaker.")

        turn.finish(reply: "Check the fuse. Then the breaker. If both are fine, call it in.")
        XCTAssertEqual(turn.text, "Check the fuse. Then the breaker. If both are fine, call it in.")
        XCTAssertTrue(turn.text.hasPrefix("Check the fuse. Then the breaker."), "append-only")
    }

    func testAPreambleBeforeAToolStaysAndTheReplyFollows() {
        var turn = HUDAnswerTurn()
        turn.append("Let me look that up.")         // said before the tool ran
        turn.append("The part is in stock.")         // the reply's first sentence
        turn.finish(reply: "The part is in stock. It ships tomorrow.")
        XCTAssertEqual(turn.text, "Let me look that up. The part is in stock. It ships tomorrow.")
    }

    func testAReplyThatReplacedWhatWasStreamedFollowsIt() {
        var turn = HUDAnswerTurn()
        turn.append("Working on it.")
        turn.finish(reply: "Done. The timer is set for ten minutes.")
        XCTAssertEqual(turn.text, "Working on it. Done. The timer is set for ten minutes.")
    }

    func testOnceFinishedNothingMoreIsAdded() {
        var turn = HUDAnswerTurn()
        turn.finish(reply: "It is twelve degrees.")
        turn.append("It is twelve degrees.")
        turn.finish(reply: "Something else.")
        XCTAssertEqual(turn.text, "It is twelve degrees.")
    }

    func testSealKeepsWhatWasSaid() {
        var turn = HUDAnswerTurn()
        XCTAssertTrue(turn.isEmpty)
        turn.append("   ")
        XCTAssertTrue(turn.isEmpty, "blank sentences are not collected")
        turn.append("The first thing to check is the fuse.")
        turn.seal()
        XCTAssertTrue(turn.isFinished)
        XCTAssertEqual(turn.text, "The first thing to check is the fuse.")
    }

    func testPagesAlreadySettledSurviveTheFinalReply() {
        let sentences = [
            "Turn the isolator off before you open the panel.",
            "Check the capacitor with a meter, because it can hold a charge.",
            "If the reading is above five volts, discharge it with a resistor.",
            "Then swap the contactor.",
        ]
        var turn = HUDAnswerTurn()
        sentences.forEach { turn.append($0) }
        let streamed = HUDAnswerPager.pages(for: turn.text, geometry: .raybanDisplay)
        let settled = HUDAnswerPager.settledPageCount(streamed)
        XCTAssertGreaterThan(settled, 0)

        turn.finish(reply: sentences.joined(separator: " ") + " Refit the cover and restore the power.")
        let final = HUDAnswerPager.pages(for: turn.text, geometry: .raybanDisplay)
        for index in 0..<settled {
            XCTAssertEqual(final[index].lines, streamed[index].lines, "page \(index + 1)")
        }
    }
}
