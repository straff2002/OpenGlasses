import XCTest
@testable import OpenGlasses

/// Plan KP P0 — the `<next>…</next>` follow-ups tail (§4).
final class FollowUpTailTests: XCTestCase {

    private let answer = "Swap the contactor, then restore the power."

    // MARK: - Well-formed

    func testAWellFormedTailOnItsOwnLine() {
        let tail = FollowUpTail.parse(answer + "\n<next>How long does it take?|What tools?|Is it safe?</next>")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, ["How long does it take?", "What tools?", "Is it safe?"])
        XCTAssertTrue(tail.removedTail)
    }

    func testAWellFormedTailOnTheAnswersLastLineWithTrailingWhitespace() {
        let tail = FollowUpTail.parse(answer + " <next> Why? | And then? </next>\n\n ")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, ["Why?", "And then?"])
    }

    func testTagsMatchCaseInsensitively() {
        let tail = FollowUpTail.parse(answer + "\n<NEXT>Why?</Next>")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, ["Why?"])
    }

    func testNewlinesInsideTheTailSeparateQuestionsToo() {
        let tail = FollowUpTail.parse(answer + "\n<next>\nWhy?\nHow?\n</next>")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, ["Why?", "How?"])
    }

    func testInnerWhitespaceIsCollapsed() {
        let tail = FollowUpTail.parse(answer + "\n<next>What   tools\tdo I need?</next>")
        XCTAssertEqual(tail.followUps, ["What tools do I need?"])
    }

    func testAMultiParagraphAnswerKeepsItsShape() {
        let body = "First paragraph.\n\nSecond paragraph."
        let tail = FollowUpTail.parse(body + "\n<next>More?</next>")
        XCTAssertEqual(tail.answer, body)
    }

    // MARK: - Missing / empty

    func testAMissingTailLeavesTheReplyUnchanged() {
        let reply = answer + "  \n"
        let tail = FollowUpTail.parse(reply)
        XCTAssertEqual(tail.answer, reply)
        XCTAssertEqual(tail.followUps, [])
        XCTAssertFalse(tail.removedTail)
    }

    func testAnEmptyTailIsRemovedWithNoFollowUps() {
        for reply in [answer + "\n<next></next>", answer + "\n<next> | | </next>"] {
            let tail = FollowUpTail.parse(reply)
            XCTAssertEqual(tail.answer, answer)
            XCTAssertEqual(tail.followUps, [])
            XCTAssertTrue(tail.removedTail)
        }
    }

    func testAnEmptyReply() {
        let tail = FollowUpTail.parse("")
        XCTAssertEqual(tail.answer, "")
        XCTAssertEqual(tail.followUps, [])
    }

    // MARK: - Malformed

    func testAnUnclosedTailOnItsOwnLineIsRemovedWithNoFollowUps() {
        let tail = FollowUpTail.parse(answer + "\n<next>How long?|What to")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, [])
        XCTAssertTrue(tail.removedTail)
    }

    func testAnUnclosedTailAfterASentenceStopIsRemoved() {
        let tail = FollowUpTail.parse(answer + " <next>Why?")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, [])
    }

    func testAnUnclosedTagInsideASentenceIsLeft() {
        let reply = "Wrap each question in a <next> tag"
        let tail = FollowUpTail.parse(reply)
        XCTAssertEqual(tail.answer, reply)
        XCTAssertEqual(tail.followUps, [])
        XCTAssertFalse(tail.removedTail)
    }

    func testAnUnclosedTagFollowedByMoreLinesIsLeft() {
        let reply = answer + "\n<next> starts the list.\nAnd this is more of the answer."
        let tail = FollowUpTail.parse(reply)
        XCTAssertEqual(tail.answer, reply)
        XCTAssertFalse(tail.removedTail)
    }

    func testAStrayCloseTagIsLeft() {
        let reply = answer + " </next>"
        let tail = FollowUpTail.parse(reply)
        XCTAssertEqual(tail.answer, reply)
        XCTAssertEqual(tail.followUps, [])
        XCTAssertFalse(tail.removedTail)
    }

    func testANestedTailIsRemovedWithNoFollowUps() {
        let tail = FollowUpTail.parse(answer + "\n<next>Why?|<next>How?</next>")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, [])
        XCTAssertTrue(tail.removedTail)
    }

    func testADoubleCloseIsRemovedWithNoFollowUps() {
        let tail = FollowUpTail.parse(answer + "\n<next>Why?</next>How?</next>")
        XCTAssertEqual(tail.answer, answer)
        XCTAssertEqual(tail.followUps, [])
    }

    func testAnEarlierTagInsideASentenceIsNotTakenAsATail() {
        let body = "Use the <next> tag."
        let tail = FollowUpTail.parse(body + "<next>Why?</next>")
        XCTAssertEqual(tail.answer, body)
        XCTAssertEqual(tail.followUps, ["Why?"])
    }

    func testAMalformedTailNeverRemovesAnswerText() {
        let replies = [
            answer + "\n<next>Why?|How",
            answer + "\n<next>Why?|<next>How?</next>",
            answer + "\n<next>Why?</next>How?</next>",
            answer + " </next>",
        ]
        for reply in replies {
            XCTAssertTrue(FollowUpTail.parse(reply).answer.hasPrefix(answer), reply)
        }
    }

    // MARK: - Limits

    func testQuestionsOverSixWordsAreDroppedNotCut() {
        let tail = FollowUpTail.parse(answer + "\n<next>Why?|What is the best way to do it?|How?</next>")
        XCTAssertEqual(tail.followUps, ["Why?", "How?"])
    }

    func testSixWordsIsAllowed() {
        let tail = FollowUpTail.parse(answer + "\n<next>What is the best way now?</next>")
        XCTAssertEqual(tail.followUps, ["What is the best way now?"])
    }

    func testQuestionsOverTheButtonLengthAreDropped() {
        let long = "Supercalifragilisticexpialidocious antidisestablishmentarianism?"  // 2 words, 64 chars
        XCTAssertGreaterThan(long.count, FollowUpTail.maxCharacters)
        let tail = FollowUpTail.parse(answer + "\n<next>\(long)|Why?</next>")
        XCTAssertEqual(tail.followUps, ["Why?"])
        XCTAssertEqual(FollowUpTail.maxCharacters, 40)
    }

    func testMoreThanThreeKeepsTheFirstThree() {
        let tail = FollowUpTail.parse(answer + "\n<next>One?|Two?|Three?|Four?|Five?</next>")
        XCTAssertEqual(tail.followUps, ["One?", "Two?", "Three?"])
    }

    func testDroppedQuestionsDontCountTowardsThree() {
        let tail = FollowUpTail.parse(answer + "\n<next>One?|this one has far too many words in it|Two?|Three?|Four?</next>")
        XCTAssertEqual(tail.followUps, ["One?", "Two?", "Three?"])
    }

    func testQuestionsCarryingMarkupAreDropped() {
        let tail = FollowUpTail.parse(answer + "\n<next>Why <b>now</b>?|How?</next>")
        XCTAssertEqual(tail.followUps, ["How?"])
    }

    // MARK: - Not at the end

    func testABlockMidReplyIsNotATail() {
        let reply = "Here you go. <next>Why?|How?</next> And there is more answer after it."
        let tail = FollowUpTail.parse(reply)
        XCTAssertEqual(tail.answer, reply)
        XCTAssertEqual(tail.followUps, [])
        XCTAssertFalse(tail.removedTail)
    }

    func testOnlyTheBlockAtTheEndIsTheTail() {
        let body = "Say <next>x</next> to start."
        let tail = FollowUpTail.parse(body + "\n<next>Why?</next>")
        XCTAssertEqual(tail.answer, body)
        XCTAssertEqual(tail.followUps, ["Why?"])
    }

    // MARK: - Streaming helpers

    func testBeginsTail() {
        XCTAssertTrue(FollowUpTail.beginsTail("<next>How long?"))
        XCTAssertTrue(FollowUpTail.beginsTail("\n  <NEXT>How long?|Why?</next>"))
        XCTAssertTrue(FollowUpTail.beginsTail("<next>"))
        XCTAssertFalse(FollowUpTail.beginsTail("Swap the contactor."))
        XCTAssertFalse(FollowUpTail.beginsTail("Use the <next> tag."))
        XCTAssertFalse(FollowUpTail.beginsTail("|What tools?"))
        XCTAssertFalse(FollowUpTail.beginsTail(""))
    }

    func testTextBeforeTail() {
        XCTAssertEqual(FollowUpTail.textBeforeTail(in: "Restore the power. <next>Why?"), "Restore the power.")
        XCTAssertEqual(FollowUpTail.textBeforeTail(in: "Restore the power.\n<next>Why?"), "Restore the power.")
        XCTAssertEqual(FollowUpTail.textBeforeTail(in: "<next>Why?"), "")
        XCTAssertNil(FollowUpTail.textBeforeTail(in: "Restore the power."))
        XCTAssertNil(FollowUpTail.textBeforeTail(in: "Use the <next> tag."))
    }
}
