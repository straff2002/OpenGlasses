import XCTest
@testable import OpenGlasses

/// Plan JI §7a (P6b): an author's words to catch bring up the step's safety note, at once. Only an
/// author's phrase does; the field is optional and older procedures read as before.
@MainActor
final class CautionPhraseTests: XCTestCase {

    private let phrases = ["leave it plugged in", "skip the isolator"]

    // MARK: - Matching

    func testWholeWordsOnly() {
        XCTAssertEqual(CautionPhraseMatcher.firstMatch(in: "I'll just skip the isolator today.", phrases: phrases),
                       "skip the isolator")
        XCTAssertNil(CautionPhraseMatcher.firstMatch(in: "Skipping the isolators is not on.", phrases: phrases))
        XCTAssertNil(CautionPhraseMatcher.firstMatch(in: "I'll leave it plugged into the bench.", phrases: phrases),
                     "\"plugged into\" is not \"plugged in\"")
        XCTAssertNil(CautionPhraseMatcher.firstMatch(in: "Skip, the isolator is off.", phrases: ["skip it"]))
    }

    func testCaseAndPunctuationAreIgnored() {
        XCTAssertEqual(CautionPhraseMatcher.firstMatch(in: "SKIP THE ISOLATOR!", phrases: phrases), "skip the isolator")
        XCTAssertEqual(CautionPhraseMatcher.firstMatch(in: "Fine, leave it, plugged in.", phrases: phrases),
                       "leave it plugged in")
    }

    func testNoPhrasesNoMatch() {
        XCTAssertNil(CautionPhraseMatcher.firstMatch(in: "skip the isolator", phrases: nil))
        XCTAssertNil(CautionPhraseMatcher.firstMatch(in: "skip the isolator", phrases: []))
        XCTAssertNil(CautionPhraseMatcher.firstMatch(in: "skip the isolator", phrases: ["  "]))
    }

    func testAPhraseCountsOnlyOnAStepWithASafetyNoteToShow() throws {
        let procedure = try TalkThroughFixtures.procedure()
        let caught = try XCTUnwrap(CautionPhraseMatcher.caught(in: "I'll skip the isolator", procedure: procedure,
                                                               visited: ["isolate"]))
        XCTAssertEqual(caught.step.id, "isolate")
        XCTAssertEqual(caught.phrase, "skip the isolator")

        let noNote = Procedure(id: "p", title: "P", version: "1", steps: [
            Procedure.Step(id: "a", title: "A", instruction: "Do it.", terminal: true, outcome: "done",
                           cautionPhrases: ["skip the isolator"]),
        ])
        XCTAssertNil(CautionPhraseMatcher.caught(in: "skip the isolator", procedure: noNote, visited: ["a"]))
    }

    // MARK: - Only authored phrases fire

    func testWordsThatSoundDangerousButAreNoAuthorsPhraseDoNothing() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        let before = rig.ear.spoken.count
        rig.say("This is dangerous, the whole thing is live and sparking.")
        rig.say("I'm going to bypass the safety switch.")
        XCTAssertEqual(rig.ear.spoken.count, before, "only an author's phrase brings the safety note up")
        rig.service.stop()
    }

    // MARK: - At once, whatever the pause

    func testACaughtPhraseSpeaksTheSafetyNoteAtOnceWhileTheyAreStillTalking() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        let note = "Unplug the lead before opening the housing."
        // The technician is mid-sentence: an ordinary hint would wait for a pause.
        rig.voice.onChange?(true)
        let stopsBefore = rig.ear.stops
        rig.say("Nah, I'll leave it plugged in for this bit.")
        XCTAssertEqual(rig.ear.spoken.last, note, "the whole note, not a few words of it")
        XCTAssertGreaterThan(rig.ear.stops, stopsBefore, "whatever was playing gives way")
        // Still talking: an urgent line is not cut short by their speech.
        let stopsAfter = rig.ear.stops
        rig.voice.onChange?(true)
        rig.clock.advance(by: 0.1)
        XCTAssertEqual(rig.ear.stops, stopsAfter)
        rig.service.stop()
    }

    func testACaughtPhraseShowsOnTheLensEvenOverADismissedOne() throws {
        let rig = try TalkThroughRig(lensAvailable: true)
        rig.service.start()
        rig.lens.accepts = false
        rig.say("Skip the isolator, it's fine.")
        XCTAssertEqual(rig.lens.reshown.last?.line, "Safety: Unplug the lead before opening the housing.")
        XCTAssertEqual(rig.lens.reshown.last?.keyword, "Isolate the pump")
        rig.service.stop()
    }

    func testNeverThroughThePhoneSpeaker() throws {
        let rig = try TalkThroughRig()
        rig.ear.isPhoneSpeaker = true
        rig.service.start()
        rig.say("Skip the isolator.")
        XCTAssertFalse(rig.ear.spoken.contains("Unplug the lead before opening the housing."))
        rig.service.stop()
    }

    // MARK: - The field

    func testOlderProceduresDecodeUnchanged() throws {
        let json = #"{"id":"s","title":"Fill","instruction":"Fill the chamber."}"#
        let step = try JSONDecoder().decode(Procedure.Step.self, from: Data(json.utf8))
        XCTAssertNil(step.cautionPhrases)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(step), encoding: .utf8))
        XCTAssertFalse(encoded.contains("caution_phrases"), "absent stays absent when written back")
    }

    func testTheFieldDecodesAndRoundTrips() throws {
        let procedure = try TalkThroughFixtures.procedure()
        XCTAssertEqual(procedure.step(id: "isolate")?.cautionPhrases, ["leave it plugged in", "skip the isolator"])
        let again = try JSONDecoder().decode(Procedure.self, from: JSONEncoder().encode(procedure))
        XCTAssertEqual(again, procedure)
    }

    func testEditingAStepsRulesKeepsItsPhrases() throws {
        let step = try XCTUnwrap(TalkThroughFixtures.procedure().step(id: "isolate"))
        XCTAssertEqual(step.with(branches: []).cautionPhrases, step.cautionPhrases)
        XCTAssertEqual(step.with(answer: nil).cautionPhrases, step.cautionPhrases)
    }
}
