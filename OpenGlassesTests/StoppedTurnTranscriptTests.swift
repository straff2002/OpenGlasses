import XCTest
@testable import OpenGlasses

/// The rule a stopped Apple Speech turn follows while it waits for the recogniser's final result.
///
/// `TranscriptionService` cannot be driven headlessly with a real recogniser, so the rule it
/// delegates to is tested as the pure value it is: `init(shown:)` at the stop, then `noteResult`,
/// `noteEnded` and `noteTimedOut` exactly as the service calls them.
final class StoppedTurnTranscriptTests: XCTestCase {

    func testTheFinalResultCarriesTheLastWord() {
        // The partial on screen at the stop is still holding the word being spoken.
        var turn = StoppedTurnTranscript(shown: "what's the superheat on")
        XCTAssertFalse(turn.isSettled)
        turn.noteResult("what's the superheat on unit four", isFinal: true)
        XCTAssertEqual(turn.text, "what's the superheat on unit four")
        XCTAssertEqual(turn.settlement, .final)
    }

    func testLatePartialsUpdateTheTextWithoutSettlingIt() {
        var turn = StoppedTurnTranscript(shown: "set a timer for")
        turn.noteResult("set a timer for ten", isFinal: false)
        XCTAssertEqual(turn.text, "set a timer for ten")
        XCTAssertFalse(turn.isSettled, "only a final, an error or the bound settles it")
    }

    func testAnEmptyResultNeverErasesWordsAlreadyHeard() {
        var turn = StoppedTurnTranscript(shown: "call the office")
        turn.noteResult("", isFinal: true)
        XCTAssertEqual(turn.text, "call the office")
        turn = StoppedTurnTranscript(shown: "call the office")
        turn.noteResult("  ", isFinal: false)
        XCTAssertEqual(turn.text, "call the office")
    }

    func testAnErrorAfterTheStopKeepsWhatWasHeard() {
        // After `endAudio()` the recogniser commonly ends with "no speech" rather than a final.
        var turn = StoppedTurnTranscript(shown: "read me the next step")
        turn.noteEnded()
        XCTAssertEqual(turn.text, "read me the next step")
        XCTAssertEqual(turn.settlement, .ended)
    }

    func testTheBoundKeepsWhatWasHeard() {
        var turn = StoppedTurnTranscript(shown: "what's the weather")
        turn.noteResult("what's the weather like", isFinal: false)
        turn.noteTimedOut()
        XCTAssertEqual(turn.text, "what's the weather like")
        XCTAssertEqual(turn.settlement, .timedOut)
    }

    func testNothingMovesItOnceSettled() {
        var turn = StoppedTurnTranscript(shown: "open the manual")
        turn.noteResult("open the manual", isFinal: true)
        turn.noteResult("open the manual page two", isFinal: true)
        turn.noteEnded()
        turn.noteTimedOut()
        XCTAssertEqual(turn.text, "open the manual")
        XCTAssertEqual(turn.settlement, .final)
    }

    func testANoSpeechTurnStaysEmpty() {
        // Delivery sends an empty, never-heard turn down the no-speech path, as before.
        var turn = StoppedTurnTranscript(shown: "")
        turn.noteEnded()
        XCTAssertEqual(turn.text, "")
    }

    func testTheWaitIsBoundedLikeTheCloudStream() {
        // A stop must never hang on the recogniser: the same bound as Deepgram's last-final wait.
        XCTAssertEqual(StoppedTurnTranscript.finalResultTimeout, 1.5)
        XCTAssertLessThan(TranscriptionService.wearerStopTail, 0.5,
                          "the tail after a press must stay too short to feel")
    }
}
