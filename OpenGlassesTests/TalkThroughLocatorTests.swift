import XCTest
@testable import OpenGlasses

/// Plan JI §7a (P6b): where the technician is, from what they say. Pure, over an invented
/// garden-pump procedure.
final class TalkThroughLocatorTests: XCTestCase {

    private var procedure: Procedure!
    private let at = Date(timeIntervalSinceReferenceDate: 810_000_000)

    override func setUpWithError() throws {
        procedure = try TalkThroughFixtures.procedure()
    }

    private func final(_ text: String) -> HintCaption {
        HintCaption(text: text, languageCode: "en-GB", timestamp: at)
    }

    private func read(_ locator: inout TalkThroughLocator, _ text: String, visited: [String],
                      similarity: (String, String) -> Double? = { _, _ in nil }) -> TalkThroughDecision {
        locator.read(final(text), procedure: procedure, visited: visited, similarity: similarity)
    }

    // MARK: - Candidates

    func testCandidatesAreThePreviousTheCurrentAndTheNextTwoOnly() {
        let atIsolate = TalkThroughLocator.candidates(procedure: procedure, visited: ["isolate"])
        XCTAssertEqual(atIsolate.map(\.stepId), ["isolate", "drain", "filter"])
        XCTAssertEqual(atIsolate.map(\.role), [.current, .ahead, .ahead])
        XCTAssertEqual(atIsolate[2].path, ["drain", "filter"])

        let atFilter = TalkThroughLocator.candidates(procedure: procedure, visited: ["isolate", "drain", "filter"])
        XCTAssertEqual(Set(atFilter.map(\.stepId)), ["filter", "prime", "run", "reseal", "drain"])
        XCTAssertEqual(atFilter.first { $0.stepId == "drain" }?.role, .previous)
        XCTAssertFalse(atFilter.contains { $0.stepId == "isolate" }, "never the whole procedure")
    }

    func testBothBranchesCountAsTheNextSteps() {
        let atPrime = TalkThroughLocator.candidates(procedure: procedure, visited: ["isolate", "drain", "filter", "prime"])
        XCTAssertTrue(atPrime.contains { $0.stepId == "run" && $0.path == ["run"] })
        XCTAssertTrue(atPrime.contains { $0.stepId == "reseal" && $0.path == ["reseal"] })
    }

    func testAStepBeyondTheNextTwoIsNeverPointedAt() {
        var locator = TalkThroughLocator()
        // Priming words, said while still isolating: the prime step is not a candidate.
        XCTAssertEqual(read(&locator, "Closing the priming cap hand tight.", visited: ["isolate"]), .stay(.offTopic))
        XCTAssertEqual(read(&locator, "Priming cap is closed, hand tight.", visited: ["isolate"]), .stay(.offTopic))
    }

    // MARK: - Agreement

    func testTwoAgreeingSentencesBeforeAProposal() {
        var locator = TalkThroughLocator()
        XCTAssertEqual(read(&locator, "Opening the drain plug now.", visited: ["isolate"]), .stay(.waitingForAgreement))
        XCTAssertEqual(read(&locator, "Letting the chamber empty into the bucket.", visited: ["isolate"]),
                       .propose(stepId: "drain", path: ["drain"]))
    }

    func testOffTopicTalkBetweenTwoSentencesStartsTheCountAgain() {
        var locator = TalkThroughLocator()
        XCTAssertEqual(read(&locator, "Opening the drain plug now.", visited: ["isolate"]), .stay(.waitingForAgreement))
        XCTAssertEqual(read(&locator, "The weather has turned cold this afternoon.", visited: ["isolate"]), .stay(.offTopic))
        XCTAssertEqual(read(&locator, "Drain plug is out.", visited: ["isolate"]), .stay(.waitingForAgreement))
        XCTAssertEqual(read(&locator, "Chamber is draining into the bucket.", visited: ["isolate"]),
                       .propose(stepId: "drain", path: ["drain"]))
    }

    func testFillerAndSilenceHoldWithoutBreakingTheCount() {
        var locator = TalkThroughLocator()
        XCTAssertEqual(read(&locator, "Opening the drain plug now.", visited: ["isolate"]), .stay(.waitingForAgreement))
        XCTAssertEqual(read(&locator, "Okay, right.", visited: ["isolate"]), .stay(.nothingToGoOn))
        XCTAssertEqual(read(&locator, "Chamber is draining into the bucket.", visited: ["isolate"]),
                       .propose(stepId: "drain", path: ["drain"]))
    }

    func testTalkAboutTheCurrentStepHolds() {
        var locator = TalkThroughLocator()
        XCTAssertEqual(read(&locator, "Isolator is off and the lead is unplugged.", visited: ["isolate"]),
                       .stay(.onCurrentStep))
        XCTAssertEqual(read(&locator, "Unplugging the lead from the isolator.", visited: ["isolate"]),
                       .stay(.onCurrentStep))
        XCTAssertEqual(locator.streakCount, 0)
    }

    func testTalkAboutThePreviousStepIsNotABackwardJump() {
        var locator = TalkThroughLocator()
        let visited = ["isolate", "drain"]
        XCTAssertEqual(read(&locator, "Isolator is off and the lead is unplugged.", visited: visited), .stay(.onPreviousStep))
        XCTAssertEqual(read(&locator, "Unplugged the lead at the isolator.", visited: visited), .stay(.onPreviousStep))
    }

    func testPartialsAreIgnored() {
        var locator = TalkThroughLocator()
        let partial = HintCaption(text: "Opening the drain plug", languageCode: "en-GB", timestamp: at, isFinal: false)
        XCTAssertEqual(locator.read(partial, procedure: procedure, visited: ["isolate"]), .stay(.notFinal))
        XCTAssertEqual(locator.read(partial, procedure: procedure, visited: ["isolate"]), .stay(.notFinal))
        XCTAssertEqual(locator.streakCount, 0, "a partial never counts toward agreement")
        XCTAssertEqual(read(&locator, "Opening the drain plug now.", visited: ["isolate"]), .stay(.waitingForAgreement))
    }

    func testADeclinedStepIsNotAskedAgainOnTheSameStep() {
        var locator = TalkThroughLocator()
        _ = read(&locator, "Opening the drain plug now.", visited: ["isolate"])
        XCTAssertEqual(read(&locator, "Letting the chamber empty into the bucket.", visited: ["isolate"]),
                       .propose(stepId: "drain", path: ["drain"]))
        locator.noteDeclined("drain")
        _ = read(&locator, "Opening the drain plug now.", visited: ["isolate"])
        XCTAssertEqual(read(&locator, "Chamber is draining into the bucket.", visited: ["isolate"]), .stay(.alreadyAsked))
        // On another step, what was asked is forgotten.
        XCTAssertEqual(read(&locator, "Rinsing the filter basket mesh.", visited: ["isolate", "drain"]),
                       .stay(.waitingForAgreement))
    }

    // MARK: - Out of order

    func testALaterStepPastAnOpenReadingOffersTheDeviationPhrase() {
        var locator = TalkThroughLocator()
        // Drain expects a reading ("chamber empty"); the narration skips straight to the filter.
        XCTAssertEqual(read(&locator, "Lifting out the filter basket.", visited: ["isolate"]), .stay(.waitingForAgreement))
        XCTAssertEqual(read(&locator, "Rinsing the filter mesh under the tap.", visited: ["isolate"]),
                       .offOrder(stepId: "filter", openStepId: "drain"))
        // Offered once on this step: never a nag.
        _ = read(&locator, "Lifting out the filter basket.", visited: ["isolate"])
        XCTAssertEqual(read(&locator, "Rinsing the filter mesh under the tap.", visited: ["isolate"]), .stay(.alreadyAsked))
    }

    func testALaterStepPastAStepThatAsksForNothingIsProposedAlongThePath() {
        var locator = TalkThroughLocator()
        let visited = ["isolate", "drain"]
        // Filter asks for nothing, so going on to prime past it is proposed, two hops.
        XCTAssertEqual(read(&locator, "Filling the priming chamber with water.", visited: visited), .stay(.waitingForAgreement))
        XCTAssertEqual(read(&locator, "Closing the priming cap hand tight.", visited: visited),
                       .propose(stepId: "prime", path: ["filter", "prime"]))
    }

    func testWhatAStepAsksFor() throws {
        XCTAssertTrue(TalkThroughLocator.asksForSomething(try XCTUnwrap(procedure.step(id: "drain"))))
        XCTAssertTrue(TalkThroughLocator.asksForSomething(try XCTUnwrap(procedure.step(id: "run"))))
        XCTAssertFalse(TalkThroughLocator.asksForSomething(try XCTUnwrap(procedure.step(id: "filter"))))
        XCTAssertTrue(TalkThroughLocator.asksForSomething(TalkThroughFixtures.yesNoProcedure().steps[0]))
    }

    // MARK: - Score

    func testTheCalculationsNamesCount() throws {
        let prime = try XCTUnwrap(procedure.step(id: "prime"))
        let words = TalkThroughLocator.stepWords(prime)
        XCTAssertTrue(words.body.contains(TalkThroughLocator.stem("flow")))
        XCTAssertTrue(words.body.contains(TalkThroughLocator.stem("rate")))
        XCTAssertTrue(words.title.contains(TalkThroughLocator.stem("pump")))
    }

    func testStemsMeetAcrossTheEndingsOfRunningSpeech() {
        XCTAssertEqual(TalkThroughLocator.stem("isolating"), TalkThroughLocator.stem("isolate"))
        XCTAssertEqual(TalkThroughLocator.stem("gauges"), TalkThroughLocator.stem("gauge"))
        XCTAssertEqual(TalkThroughLocator.stem("draining"), TalkThroughLocator.stem("drain"))
        XCTAssertEqual(TalkThroughLocator.stem("cap"), "cap", "short words stay whole")
    }

    func testSimilarityCanCarryASentenceOverlapAloneCannot() {
        let similar: (String, String) -> Double? = { sentence, step in
            sentence.contains("water out") && step.hasPrefix("Drain") ? 1.0 : 0.1
        }
        var withEmbedder = TalkThroughLocator()
        XCTAssertEqual(read(&withEmbedder, "Getting all the water out.", visited: ["isolate"], similarity: similar),
                       .stay(.waitingForAgreement))
        XCTAssertEqual(read(&withEmbedder, "Most of the water out now.", visited: ["isolate"], similarity: similar),
                       .propose(stepId: "drain", path: ["drain"]))

        var overlapOnly = TalkThroughLocator()
        XCTAssertEqual(read(&overlapOnly, "Getting all the water out.", visited: ["isolate"]), .stay(.offTopic))
    }

    func testWithoutAnEmbedderOverlapAloneStillWorks() {
        var locator = TalkThroughLocator()
        let none: (String, String) -> Double? = { _, _ in nil }
        _ = read(&locator, "Opening the drain plug now.", visited: ["isolate"], similarity: none)
        XCTAssertEqual(read(&locator, "Letting the chamber empty into the bucket.", visited: ["isolate"], similarity: none),
                       .propose(stepId: "drain", path: ["drain"]))
    }

    func testNoProcedureHolds() {
        var locator = TalkThroughLocator()
        XCTAssertEqual(locator.read(final("Opening the drain plug."), procedure: nil, visited: []), .stay(.noProcedure))
    }

    func testTheSameNarrationGivesTheSamePositionsEveryTime() {
        let narration = ["Isolator off, lead unplugged.", "Opening the drain plug now.",
                         "Letting the chamber empty into the bucket.", "Weather's turned.", "Rinsing the filter mesh."]
        func run() -> [TalkThroughDecision] {
            var locator = TalkThroughLocator()
            return narration.map { read(&locator, $0, visited: ["isolate"]) }
        }
        XCTAssertEqual(run(), run())
    }
}
