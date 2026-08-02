import XCTest
@testable import OpenGlasses

/// Tests for the retrieve-or-silence citation gate (Plan CJ item 3): explicit-citation
/// filtering, and citation-shaped-claim scrubbing of LLM advisory prose.
final class CitationGateTests: XCTestCase {

    // MARK: - filter(proposed:retrieved:)

    func testRetrievedCitationsSpeakUnretrievedQueue() {
        let result = CitationGate.filter(
            proposed: ["medications", "ERC Guidelines 2025"],
            retrieved: ["medications", "conditions"])
        XCTAssertEqual(result.spoken, ["medications"])
        XCTAssertEqual(result.queued, ["ERC Guidelines 2025"])
    }

    func testFilterMatchesCaseInsensitively() {
        let result = CitationGate.filter(proposed: ["Medications "], retrieved: ["medications"])
        XCTAssertEqual(result.spoken, ["Medications "])
        XCTAssertTrue(result.queued.isEmpty)
    }

    func testEmptyProposedIsEmptyResult() {
        let result = CitationGate.filter(proposed: [], retrieved: ["anything"])
        XCTAssertTrue(result.spoken.isEmpty)
        XCTAssertTrue(result.queued.isEmpty)
    }

    // MARK: - scrub: what must be withheld

    func testAuthorityGuidelineClaimRemovedAndQueued() {
        let result = CitationGate.scrub(
            "Ibuprofen can upset the stomach. According to the FDA guidelines, take it with food.")
        XCTAssertEqual(result.spokenText, "Ibuprofen can upset the stomach.")
        XCTAssertEqual(result.queuedCitations, ["According to the FDA guidelines, take it with food."])
    }

    func testHealthAuthorityNameRemoved() {
        let result = CitationGate.scrub("The WHO recommends caution here. Watch for drowsiness.")
        XCTAssertEqual(result.spokenText, "Watch for drowsiness.")
        XCTAssertEqual(result.queuedCitations.count, 1)
    }

    func testSectionReferenceRemoved() {
        let result = CitationGate.scrub("See section 4.2 of the prescribing information. Rest today.")
        XCTAssertEqual(result.spokenText, "Rest today.")
    }

    func testGuidelinesStateClaimRemoved() {
        let result = CitationGate.scrub("The NICE guidelines recommend a lower dose. Stay hydrated.")
        XCTAssertEqual(result.spokenText, "Stay hydrated.")
    }

    func testEntirelyCitationTextScrubsToEmpty() {
        let result = CitationGate.scrub("Per the AHA protocol, compressions come first.")
        XCTAssertEqual(result.spokenText, "")
        XCTAssertEqual(result.queuedCitations.count, 1)
    }

    // MARK: - scrub: what must survive

    func testPlainAdvisoryPassesUntouched() {
        let text = "Your vault lists a blood thinner, so avoid this without asking your pharmacist."
        let result = CitationGate.scrub(text)
        XCTAssertEqual(result.spokenText, text)
        XCTAssertTrue(result.queuedCitations.isEmpty)
    }

    func testUserDirectedPhrasingIsNotACitation() {
        let text = "Check with your doctor first. Your medications entry mentions warfarin."
        let result = CitationGate.scrub(text)
        XCTAssertEqual(result.spokenText, text)
    }

    func testEmptyInputIsEmptyOutput() {
        let result = CitationGate.scrub("")
        XCTAssertEqual(result.spokenText, "")
        XCTAssertTrue(result.queuedCitations.isEmpty)
    }

    func testMultipleSentencesEachJudgedIndependently() {
        let result = CitationGate.scrub(
            "Take it after eating. Per FDA labeling, doses differ. Your conditions entry mentions reflux.")
        XCTAssertEqual(result.spokenText, "Take it after eating. Your conditions entry mentions reflux.")
        XCTAssertEqual(result.queuedCitations, ["Per FDA labeling, doses differ."])
    }
}
