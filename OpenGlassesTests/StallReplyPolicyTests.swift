import XCTest
@testable import OpenGlasses

/// A reply that promises to look something up instead of answering, after a tool already has.
final class StallReplyPolicyTests: XCTestCase {

    /// The tester's own turn: a search had returned and this was spoken as the answer.
    func testThePortugueseStallThatWasSpokenAsAnAnswer() {
        XCTAssertTrue(StallReplyPolicy.isStall(
            "Vou pesquisar a programação atual dos canais de cinema para te poder informar. Um momento, por favor."))
    }

    func testStallsInTheShippedLanguages() {
        for text in [
            "One moment, let me check that for you.",
            "Hold on, I'll look that up.",
            "Só um instante, vou verificar.",
            "Un momento, voy a buscar la programación.",
            "Un instant, je vais vérifier.",
            "Einen Moment, ich schaue nach.",
            "Un attimo, vado a controllare.",
        ] {
            XCTAssertTrue(StallReplyPolicy.isStall(text), text)
        }
    }

    func testAnAnswerWithAFigureIsNeverSecondGuessed() {
        XCTAssertFalse(StallReplyPolicy.isStall("Um momento: às 15:30 dá Eliminators e às 20:55 Showtime."))
        XCTAssertFalse(StallReplyPolicy.isStall("Hold on, that's 2 degrees warmer than yesterday."))
    }

    func testALongReplyIsAnAnswerWhateverItOpensWith() {
        let long = "One moment ago the channel's listing was updated, and here is what it shows for tonight: "
            + "a documentary first, then the late film, followed by the news round-up and a repeat of the "
            + "morning programme, all of which you can watch without a box."
        XCTAssertGreaterThan(long.count, StallReplyPolicy.maxStallLength)
        XCTAssertFalse(StallReplyPolicy.isStall(long))
    }

    func testPlainAnswersAreNotStalls() {
        XCTAssertFalse(StallReplyPolicy.isStall("Não encontrei a programação de hoje para esse canal."))
        XCTAssertFalse(StallReplyPolicy.isStall("It's mostly clear with no rain expected."))
        XCTAssertFalse(StallReplyPolicy.isStall(""))
        XCTAssertFalse(StallReplyPolicy.isStall("   "))
    }

    func testDiacriticsAndCaseDoNotHideAStall() {
        XCTAssertTrue(StallReplyPolicy.isStall("SÓ UM MOMENTO."))
        XCTAssertTrue(StallReplyPolicy.isStall("Déjame ver."))
    }

    func testTheNudgeTellsTheModelToAnswerFromTheResultsAlreadyInHistory() {
        XCTAssertTrue(StallReplyPolicy.nudge.contains("already in"))
        XCTAssertTrue(StallReplyPolicy.nudge.contains("answer now"))
    }

    // MARK: A reply with no words in it

    func testABlankReplyIsSilent() {
        for text in ["", " ", "\n\t  \n"] {
            XCTAssertTrue(StallReplyPolicy.isSilent(text), "blank")
        }
        XCTAssertFalse(StallReplyPolicy.isSilent("Done."))
    }

    /// The reset tool tells the model to say nothing, because the app confirms it aloud.
    @MainActor
    func testABlankReplyAfterAToolThatAskedForSilenceIsWhatItAskedFor() {
        XCTAssertFalse(StallReplyPolicy.isSilent("", toolsRun: ["web_search", "new_topic"]))
        XCTAssertTrue(StallReplyPolicy.isSilent("", toolsRun: ["web_search"]))
        XCTAssertTrue(StallReplyPolicy.toolsThatEndInSilence.contains(NewTopicTool(currentUtterance: { nil }).name))
    }

    /// No tool may have run, so the note cannot say that their results are in.
    func testTheSilenceNoteClaimsNoToolResults() {
        XCTAssertFalse(StallReplyPolicy.silenceNudge.lowercased().contains("result"))
        XCTAssertFalse(StallReplyPolicy.silenceNudge.lowercased().contains("tool"))
        XCTAssertTrue(StallReplyPolicy.silenceNudge.contains("answer now"))
    }
}
