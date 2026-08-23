import XCTest
@testable import OpenGlasses

/// Plan CX P1 — the spoken way in and out. While the mode is on there is no wake word, so every
/// utterance is a command candidate, which makes false positives the hazard rather than misses.
final class VisionModeGrammarTests: XCTestCase {

    func testTheObviousPhrasesWork() {
        XCTAssertEqual(VisionModeGrammar.command(for: "start video"), .start)
        XCTAssertEqual(VisionModeGrammar.command(for: "stop video"), .stop)
        XCTAssertEqual(VisionModeGrammar.command(for: "Stop Video."), .stop)
        XCTAssertEqual(VisionModeGrammar.command(for: "  start   vision  "), .start)
    }

    /// The one that matters. With no wake word, a passing mention must not end the mode —
    /// "I had to stop video calls at work" is a sentence, not a command.
    func testAPassingMentionIsNotACommand() {
        XCTAssertNil(VisionModeGrammar.command(for: "I had to stop video calls at work"))
        XCTAssertNil(VisionModeGrammar.command(for: "can you start video in a minute"))
        XCTAssertNil(VisionModeGrammar.command(for: "what does stop video mean"))
    }

    func testOrdinaryQuestionsPassStraightThrough() {
        for question in ["what am I looking at", "read this label", "how much is that"] {
            XCTAssertNil(VisionModeGrammar.command(for: question))
        }
    }

    func testEmptyAndNoiseAreNotCommands() {
        XCTAssertNil(VisionModeGrammar.command(for: ""))
        XCTAssertNil(VisionModeGrammar.command(for: "   "))
        XCTAssertNil(VisionModeGrammar.command(for: "..."))
    }

    /// Normalising must not drop anything from the middle — that would reintroduce the substring
    /// matching the whole-utterance rule exists to avoid.
    func testNormalisationKeepsTheWholeUtterance() {
        XCTAssertEqual(VisionModeGrammar.normalise("Stop, video!"), "stop video")
        XCTAssertEqual(VisionModeGrammar.normalise("I had to stop video calls"),
                       "i had to stop video calls")
    }
}
