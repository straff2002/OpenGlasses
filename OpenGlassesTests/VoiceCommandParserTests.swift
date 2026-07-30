import XCTest
@testable import OpenGlasses

/// Plan BG P2 groundwork (docs/plans/BG-spine-refactor.md): the pure pre-LLM command recognition
/// lifted out of `AppState.handleTranscription`. These are the first tests over the flow's decision
/// logic — the state machine's side effects stay in AppState and are device-verified.
final class VoiceCommandParserTests: XCTestCase {

    private let parser = VoiceCommandParser.default

    // MARK: - Stop (whole-word)

    func testStopMatchesWholeWordAndLeadingToken() {
        XCTAssertTrue(parser.isStop("stop"))
        XCTAssertTrue(parser.isStop("Stop"))
        XCTAssertTrue(parser.isStop("stop the timer"))
        XCTAssertTrue(parser.isStop("cancel"))
        XCTAssertTrue(parser.isStop("never mind"))
        // Now tokenised, so ASR punctuation no longer defeats the match (Plan CD P2).
        XCTAssertTrue(parser.isStop("stop."))
        XCTAssertTrue(parser.isStop("please stop"))
    }

    func testStopDoesNotMatchInsideAnotherWord() {
        XCTAssertFalse(parser.isStop("nonstop music"), "'stop' inside a word must not trigger")
        XCTAssertFalse(parser.isStop("what's the weather"))
    }

    // MARK: - Goodbye

    func testGoodbyeMatchesPaddedPhrases() {
        XCTAssertTrue(parser.isGoodbye("goodbye"))
        XCTAssertTrue(parser.isGoodbye("okay, thanks Claude, bye"))
        XCTAssertTrue(parser.isGoodbye("I'm done"))
        XCTAssertTrue(parser.isGoodbye("go to sleep"))
    }

    func testGoodbyeDoesNotMatchUnrelated() {
        XCTAssertFalse(parser.isGoodbye("what time is it"))
    }

    /// A sign-off has to end the utterance (Plan CD P2, Rule B). This inverts the earlier
    /// characterization of the substring matcher — same input, opposite expectation — rather than
    /// weakening it. Detail and positive controls live in `PhraseMatchingTests`.
    func testGoodbyeDoesNotMatchWhenTheSignOffIsNotFinal() {
        XCTAssertFalse(parser.isGoodbye("that's all i wanted to ask about the weather"))
    }

    // MARK: - Photo

    func testPhotoMatchesVariants() {
        for phrase in ["take a picture", "take a photo", "snap a picture", "capture photo"] {
            XCTAssertTrue(parser.isPhoto(phrase), phrase)
        }
        XCTAssertTrue(parser.isPhoto("hey, take a photo of this"))
    }

    func testPhotoDoesNotMatchUnrelated() {
        XCTAssertFalse(parser.isPhoto("what do you see"))
    }

    /// Asking how the camera works must not fire it (Plan CD P2, Rule A).
    func testPhotoDoesNotMatchAQuestionAboutTakingPhotos() {
        XCTAssertFalse(parser.isPhoto("how do i take a photo with these glasses"))
    }

    // MARK: - Persona wake-prefix

    private let personas = [
        VoiceCommandParser.PersonaPhrases(id: "claude", phrases: ["hey claude", "claude"]),
        VoiceCommandParser.PersonaPhrases(id: "chef", phrases: ["hey chef", "chef"]),
    ]

    func testDetectPersonaStripsPrefix() {
        let match = parser.detectPersona(in: "Hey Claude, what's the weather", personas: personas)
        XCTAssertEqual(match, .init(personaId: "claude", query: "what's the weather"))
    }

    func testDetectPersonaKeepsOriginalWhenPhraseIsWholeUtterance() {
        // "Claude" alone leaves no query — fall back to the original text rather than empty.
        let match = parser.detectPersona(in: "Claude", personas: personas)
        XCTAssertEqual(match?.personaId, "claude")
        XCTAssertEqual(match?.query, "Claude")
    }

    func testDetectPersonaPicksFirstMatchInOrder() {
        let match = parser.detectPersona(in: "hey chef, what's for dinner", personas: personas)
        XCTAssertEqual(match?.personaId, "chef")
        XCTAssertEqual(match?.query, "what's for dinner")
    }

    func testDetectPersonaReturnsNilWhenNoneMatch() {
        XCTAssertNil(parser.detectPersona(in: "what's the weather", personas: personas))
    }

    func testDefaultPhrasesArePresent() {
        // Guard against an accidental empty phrase list silently disabling recognition.
        XCTAssertFalse(VoiceCommandParser.default.stopPhrases.isEmpty)
        XCTAssertFalse(VoiceCommandParser.default.goodbyePhrases.isEmpty)
        XCTAssertFalse(VoiceCommandParser.default.photoPhrases.isEmpty)
    }
}
