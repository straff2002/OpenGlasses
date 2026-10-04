import XCTest
@testable import OpenGlasses

/// Logged turns moved to where their words were spoken, or left at their log time and marked so.
final class TurnAlignerTests: XCTestCase {
    private typealias U = TimedTranscript.Utterance
    private typealias Turn = TurnAligner.LoggedTurn
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private func technician(_ ref: String, at stamp: Double, _ text: String) -> Turn {
        Turn(ref: ref, speaker: SessionTimeline.Speaker.technician, stamp: t(stamp), text: text)
    }

    private let transcript = TimedTranscript.numbered([
        TimedTranscript.Utterance(start: SessionTime(seconds: 100), end: SessionTime(seconds: 103),
                                  text: "What's the torque for the flange bolts?"),
        TimedTranscript.Utterance(start: SessionTime(seconds: 120), end: SessionTime(seconds: 122),
                                  text: "Okay and what about"),
        TimedTranscript.Utterance(start: SessionTime(seconds: 122.3), end: SessionTime(seconds: 125),
                                  text: "the gasket, is it reusable?"),
        TimedTranscript.Utterance(start: SessionTime(seconds: 150), end: SessionTime(seconds: 151), text: "Yes."),
        TimedTranscript.Utterance(start: SessionTime(seconds: 170), end: SessionTime(seconds: 171), text: "Yes."),
    ])

    func testATurnIsMovedToWhereItsWordsBegin() {
        // Logged four seconds after the words ended; the live recogniser heard it a little differently.
        let aligned = TurnAligner.align([technician("turn-1", at: 107, "what is the torque for the flange bolts")],
                                        to: transcript)
        XCTAssertEqual(aligned.count, 1)
        XCTAssertEqual(aligned[0].t, t(100))
        XCTAssertEqual(aligned[0].precision, .aligned)
        XCTAssertEqual(aligned[0].utteranceIDs, ["u1"])
    }

    func testATurnSpokenAcrossTwoUtterancesTakesBothAndStartsAtTheFirst() {
        let aligned = TurnAligner.align([technician("turn-2", at: 128, "Okay, and what about the gasket, is it reusable?")],
                                        to: transcript)
        XCTAssertEqual(aligned[0].t, t(120))
        XCTAssertEqual(aligned[0].utteranceIDs, ["u2", "u3"])
    }

    func testATurnThatMatchesNothingKeepsItsLogTimeAndSaysSo() {
        let aligned = TurnAligner.align([technician("turn-3", at: 140, "Show me the wiring diagram.")], to: transcript)
        XCTAssertEqual(aligned[0].t, t(140))
        XCTAssertEqual(aligned[0].precision, .coarse)
        XCTAssertEqual(aligned[0].utteranceIDs, [])
    }

    func testWordsOutsideTheWindowBeforeTheStampAreNotTheTurn() {
        // The same words, but said more than a minute before the stamp…
        XCTAssertEqual(TurnAligner.align([technician("late", at: 161, "What's the torque for the flange bolts?")],
                                         to: transcript)[0].precision, .coarse)
        XCTAssertEqual(TurnAligner.align([technician("in", at: 160, "What's the torque for the flange bolts?")],
                                         to: transcript)[0].precision, .aligned)
        // …or still being said after it, beyond the slack between the two clocks.
        XCTAssertEqual(TurnAligner.align([technician("early", at: 101.9, "What's the torque for the flange bolts?")],
                                         to: transcript)[0].precision, .coarse)
        XCTAssertEqual(TurnAligner.align([technician("slack", at: 102, "What's the torque for the flange bolts?")],
                                         to: transcript)[0].precision, .aligned)
    }

    func testTwoTurnsWithTheSameWordsEachGetTheirOwnUtterance() {
        let aligned = TurnAligner.align([technician("second", at: 173, "Yes."), technician("first", at: 153, "Yes.")],
                                        to: transcript)
        // Given out of order; matched in stamp order; returned in the order given.
        XCTAssertEqual(aligned.map(\.turn.ref), ["second", "first"])
        XCTAssertEqual(aligned.map(\.utteranceIDs), [["u5"], ["u4"]])
        XCTAssertEqual(aligned.map(\.t), [t(170), t(150)])
    }

    func testOfTwoEquallyGoodMatchesTheOneNearerTheStampIsTaken() {
        let aligned = TurnAligner.align([technician("turn", at: 175, "Yes.")], to: transcript)
        XCTAssertEqual(aligned[0].utteranceIDs, ["u5"])
    }

    func testAnUtteranceThatOnlySharesAWordOrTwoIsNotTheTurn() {
        // "the" and "is" are in the transcript; that is not enough of the turn.
        let aligned = TurnAligner.align([technician("turn", at: 126, "Is the isolator the red one on the left?")],
                                        to: transcript)
        XCTAssertEqual(aligned[0].precision, .coarse)
    }

    func testTheAssistantsTurnsAreNeverMatchedToTheAudio() {
        let reply = Turn(ref: "turn-4", speaker: SessionTimeline.Speaker.assistant, stamp: t(104),
                         text: "What's the torque for the flange bolts?")
        let aligned = TurnAligner.align([reply], to: transcript)
        XCTAssertEqual(aligned[0].precision, .coarse)
        XCTAssertEqual(aligned[0].t, t(104))
    }

    func testATurnWithNoWordsIsCoarse() {
        XCTAssertEqual(TurnAligner.align([technician("turn", at: 104, "…")], to: transcript)[0].precision, .coarse)
        XCTAssertEqual(TurnAligner.align([], to: transcript), [])
    }

    func testAnAlignmentBecomesTheTimelinesTurnLoggedEvent() {
        let aligned = TurnAligner.align([technician("turn-1", at: 107, "What's the torque for the flange bolts?")],
                                        to: transcript)
        XCTAssertEqual(aligned[0].event,
                       SessionTimeline.Event(t: t(100), kind: .turnLogged, ref: "turn-1",
                                             text: "What's the torque for the flange bolts?",
                                             speaker: "technician", precision: .aligned))
    }
}
