import XCTest
@testable import OpenGlasses

/// Plan NA P2 — the live watch: what the session manager is told to do, per provider kind, when an
/// answer's transcript trips the check; the latch released at the turn boundary; the note sent
/// once at the boundary; a hazard sentence let play and corrected at the end; the interpreter
/// never watched; a late wearer transcript.
final class LiveReplyWatchTests: XCTestCase {

    private let blind = BlindReplyScreen.Scope(phrases: true, numbers: true)

    private func feed(_ watch: inout LiveReplyWatch, _ deltas: [String], question: String? = nil,
                      evidence: ReadingEvidence? = nil) -> [LiveReplyWatch.Effect] {
        var transcript = ""
        var effects: [LiveReplyWatch.Effect] = []
        for delta in deltas {
            transcript += delta
            effects += watch.outputTranscript(transcript, question: question, evidence: evidence)
        }
        return effects
    }

    private func actions(_ effects: [LiveReplyWatch.Effect]) -> [LiveReplyWatch.Effect] {
        effects.filter { if case .record = $0 { return false } else { return true } }
    }

    // MARK: - Per provider

    func testOpenAIStopsCancelsAndCorrects() {
        var watch = LiveReplyWatch(provider: .json, scope: blind)
        let effects = feed(&watch, ["There's a bench on your left side. ", "The path is clear, so you can ",
                                    "walk on now. And then"])
        XCTAssertEqual(effects, [.stopPlayback, .cancelResponse, .muteUntilTurnEnd, .markInterrupted,
                                 .speakLine(.safety)])
        XCTAssertTrue(watch.isMuted)
    }

    func testGeminiHasNoCancelAndLatches() {
        var watch = LiveReplyWatch(provider: .gemini, scope: blind)
        let effects = feed(&watch, ["The way ahead is clear for now. ", "Keep going"])
        XCTAssertEqual(effects, [.stopPlayback, .muteUntilTurnEnd, .markInterrupted, .speakLine(.safety)])
        XCTAssertTrue(watch.isMuted)
        // Further transcript is dropped until the turn ends.
        XCTAssertEqual(watch.outputTranscript("The way ahead is clear for now. Keep going, it's all clear. More",
                                              question: nil, evidence: nil), [])
    }

    // MARK: - The boundary

    func testTheLatchIsReleasedAndTheModelNotedOnceAtTheBoundary() {
        var watch = LiveReplyWatch(provider: .gemini, scope: blind)
        _ = feed(&watch, ["The way ahead is clear for now. ", "Go"])
        let boundary = watch.turnComplete(question: nil, evidence: nil)
        XCTAssertEqual(actions(boundary), [.noteForModel(.safety)], "the line was already said at the stop")
        XCTAssertTrue(boundary.contains { if case .record(let items) = $0 { return items.count == 1 } else { return false } })
        XCTAssertFalse(watch.isMuted)
        // The next answer is watched afresh and nothing is owed.
        XCTAssertEqual(actions(watch.turnComplete(question: nil, evidence: nil)), [])
        XCTAssertEqual(feed(&watch, ["There's a bench on your left side. ", "A door"]), [])
    }

    func testAnInterruptionGivesTheNoteToo() {
        var watch = LiveReplyWatch(provider: .json, scope: blind)
        _ = feed(&watch, ["You can cross the road now, go on. ", "And"])
        XCTAssertEqual(actions(watch.interrupted()), [.noteForModel(.safety)])
        XCTAssertFalse(watch.isMuted)
    }

    func testTheLastSentenceIsCheckedAtTurnComplete() {
        var watch = LiveReplyWatch(provider: .json, scope: blind)
        XCTAssertEqual(feed(&watch, ["There's a bench on your left side. ", "The street is empty now."]), [])
        XCTAssertEqual(actions(watch.turnComplete(question: nil, evidence: nil)),
                       [.stopPlayback, .cancelResponse, .muteUntilTurnEnd, .markInterrupted, .speakLine(.safety),
                        .noteForModel(.safety)])
    }

    // MARK: - Hazards and numbers

    func testAHazardSentenceIsLetPlayAndCorrectedAtTheEnd() {
        var watch = LiveReplyWatch(provider: .gemini, scope: blind)
        XCTAssertEqual(feed(&watch, ["There's a kerb at one o'clock, then the way is clear. ", "Step"]), [])
        XCTAssertFalse(watch.isMuted)
        XCTAssertEqual(actions(watch.turnComplete(question: nil, evidence: nil)),
                       [.speakLine(.safety), .noteForModel(.safety)])
    }

    func testAReadingNumberIsStoppedWithItsOwnLine() throws {
        let evidence = try XCTUnwrap(ReadingEvidence(text: "Amoxicillin take", source: .lookClosely))
        var watch = LiveReplyWatch(provider: .json, scope: .init(phrases: false, numbers: true))
        let effects = feed(&watch, ["It's 500 mg, twice a day with food. ", "Then"], evidence: evidence)
        XCTAssertEqual(effects, [.stopPlayback, .cancelResponse, .muteUntilTurnEnd, .markInterrupted,
                                 .speakLine(.readingNumber)])
        XCTAssertEqual(actions(watch.turnComplete(question: nil, evidence: evidence)), [.noteForModel(.readingNumber)])
    }

    // MARK: - Scope and the wearer's words

    func testTheInterpreterIsNeverWatched() {
        let scope = BlindReplyScreen.Scope.forTurn(activeModeId: LiveAIMode.interpreterID, enabled: true)
        var watch = LiveReplyWatch(provider: .gemini, scope: scope)
        XCTAssertFalse(watch.isWatching)
        XCTAssertEqual(feed(&watch, ["The path is clear, you can cross now. ", "Go"]), [])
        XCTAssertEqual(watch.turnComplete(question: nil, evidence: nil), [])
    }

    func testOutsideBlindAssistantOnlyNumbersAreWatched() {
        var watch = LiveReplyWatch(provider: .json,
                                   scope: .forTurn(activeModeId: "standard", enabled: true))
        XCTAssertEqual(feed(&watch, ["The path is clear, you can cross now. ", "Go"]), [])
    }

    func testTheQuestionIsReadForTheFirstSentence() {
        var watch = LiveReplyWatch(provider: .gemini, scope: blind)
        let effects = feed(&watch, ["No, nothing at all, carry on as you were. ", "I'll"],
                           question: "Is anything in my way?")
        XCTAssertEqual(effects.last, .speakLine(.safety))
    }

    /// A JSON provider can deliver the wearer's words after the answer started: the sentences
    /// already checked are not checked again, and nothing is stopped after the fact.
    func testALateWearerTranscriptChangesNothingAlreadyChecked() {
        var watch = LiveReplyWatch(provider: .json, scope: blind)
        var transcript = "No, nothing at all, carry on as you were. "
        XCTAssertEqual(watch.outputTranscript(transcript + "I'll", question: nil, evidence: nil), [])
        transcript += "I'll keep watching for you as you go. "
        XCTAssertEqual(watch.outputTranscript(transcript + "And", question: "Is anything in my way?", evidence: nil), [])
        XCTAssertEqual(actions(watch.turnComplete(question: "Is anything in my way?", evidence: nil)), [])
    }

    func testANewTranscriptStartsOver() {
        var watch = LiveReplyWatch(provider: .json, scope: blind)
        _ = watch.outputTranscript("There's a bench on your left side. A", question: nil, evidence: nil)
        // The manager reset its transcript (the wearer spoke): the watch follows it.
        XCTAssertEqual(watch.outputTranscript("You can cross the road now, go on. Then", question: nil, evidence: nil).last,
                       .speakLine(.safety))
    }
}
