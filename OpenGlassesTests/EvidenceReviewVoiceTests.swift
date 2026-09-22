import XCTest
@testable import OpenGlasses

/// Choosing the evidence without touching the phone (Plan FO P2a).
///
/// The same shape `JobIntakeStateTests` has: a pure machine driven by the app, so a technician
/// wearing gloves in front of a machine gets the same three decisions the grid offers — and an
/// utterance that is not one of them reaches the model untouched.
final class EvidenceReviewVoiceTests: XCTestCase {

    private func items(_ count: Int, origin: JobMediaItem.Origin = .capture) -> [JobMediaItem] {
        (0..<count).map { index in
            JobMediaItem(id: "p\(index)", capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                         origin: origin, caption: "picture \(index)", filterWasOn: false)
        }
    }

    private func state(_ media: [JobMediaItem]) -> EvidenceReviewVoiceState {
        EvidenceReviewVoiceState(selection: EvidenceSelection.proposed(for: media))
    }

    // MARK: - Classifying

    func testTheThreeAnswersAreRecognisedInTheWaysTheyAreSaid() {
        for phrase in ["Include all", "include them all", "Send them all.", "all of them"] {
            XCTAssertEqual(EvidenceReviewClassifier.classify(phrase), .includeAll, phrase)
        }
        for phrase in ["Skip photos", "no photos", "just the text", "text only"] {
            XCTAssertEqual(EvidenceReviewClassifier.classify(phrase), .skip, phrase)
        }
        for phrase in ["Yes", "yep", "keep it", "include that"] {
            XCTAssertEqual(EvidenceReviewClassifier.classify(phrase), .include, phrase)
        }
        for phrase in ["No", "nope", "leave it out", "skip that one"] {
            XCTAssertEqual(EvidenceReviewClassifier.classify(phrase), .exclude, phrase)
        }
        for phrase in ["done", "that's it", "send it"] {
            XCTAssertEqual(EvidenceReviewClassifier.classify(phrase), .finish, phrase)
        }
    }

    /// Whole phrases, not substrings. "No" inside a sentence about a pressure switch is a
    /// technician talking, and treating it as an answer would quietly drop a photograph.
    func testASentenceThatMerelyContainsAnAnswerWordIsNotAnAnswer() {
        for phrase in ["no pressure on the switch", "yes I'll get to that after the filter",
                       "what was that part number?", "skip the flame sensor for now"] {
            XCTAssertNil(EvidenceReviewClassifier.classify(phrase), phrase)
        }
    }

    func testFillerAndPunctuationAreIgnored() {
        XCTAssertEqual(EvidenceReviewClassifier.classify("Um, yes please"), .include)
        XCTAssertEqual(EvidenceReviewClassifier.classify("okay — include all, thanks"), .includeAll)
    }

    // MARK: - Driving it

    func testAnUnrelatedUtteranceChangesNothingAndPassesThrough() {
        let media = items(3)
        let start = state(media)
        let step = start.hearing("what's the superheat meant to be?", items: media)

        XCTAssertFalse(step.consumed)
        XCTAssertNil(step.spoken)
        XCTAssertEqual(step.state, start)
        XCTAssertFalse(step.isSettled)
    }

    func testIncludeAllTicksEverythingAndSettlesIt() {
        let media = items(4)
        let step = state(media).advance(.includeAll, items: media)

        XCTAssertTrue(step.consumed)
        XCTAssertTrue(step.isSettled)
        XCTAssertEqual(step.state.outcome.includedCount, 4)
        XCTAssertTrue(step.state.outcome.reviewed)
        XCTAssertEqual(step.spoken, "All 4 going with the report.")
    }

    /// "Skip photos" is the text-only record, not an empty selection — the two produce different
    /// documents, so they are different values.
    func testSkipPhotosProducesTheTextOnlyRecord() {
        let media = items(4)
        let step = state(media).advance(.skip, items: media)

        XCTAssertTrue(step.isSettled)
        XCTAssertFalse(step.state.outcome.reviewed)
        XCTAssertEqual(step.state.outcome, EvidenceSelection.skipped())
    }

    func testTheWalkReadsEachPictureOutAndTakesYesOrNo() {
        let media = items(3)
        var step = state(media).beginWalk(items: media)
        XCTAssertEqual(step.spoken, "Photo 1 of 3, picture 0. Include it?")
        XCTAssertEqual(step.state.currentItemId(in: media), "p0")
        XCTAssertFalse(step.isSettled)

        step = step.state.hearing("yes", items: media)
        XCTAssertTrue(step.consumed)
        XCTAssertEqual(step.spoken, "Keeping it. Photo 2 of 3, picture 1. Include it?")

        step = step.state.hearing("no", items: media)
        XCTAssertEqual(step.spoken, "Leaving it out. Photo 3 of 3, picture 2. Include it?")

        step = step.state.hearing("yes", items: media)
        XCTAssertTrue(step.isSettled, "the walk ends when the last picture is answered")
        XCTAssertEqual(step.spoken, "Keeping it. 2 going with the report.")
        XCTAssertEqual(step.state.outcome.includedItemIds, ["p0", "p2"])
    }

    /// A yes with nothing being read out is not an answer to this step. The technician was
    /// answering something else, and the utterance carries on to the model.
    func testYesWithNothingBeingReadOutIsNotConsumed() {
        let media = items(2)
        let step = state(media).hearing("yes", items: media)
        XCTAssertFalse(step.consumed)
    }

    /// The walk must not stop on a picture whose file has gone between the review opening and the
    /// technician answering.
    func testTheWalkSkipsEvidenceThatIsNoLongerThere() {
        let media = items(3)
        let vanished = [media[0], media[2]]
        var step = state(media).beginWalk(items: vanished)
        XCTAssertEqual(step.state.currentItemId(in: vanished), "p0")

        step = step.state.hearing("yes", items: vanished)
        XCTAssertEqual(step.state.currentItemId(in: vanished), "p2")
    }

    func testFinishStopsWhereverTheTechnicianGotTo() {
        let media = items(5)
        var step = state(media).beginWalk(items: media)
        step = step.state.hearing("yes", items: media)
        step = step.state.hearing("that's it", items: media)

        XCTAssertTrue(step.isSettled)
        XCTAssertEqual(step.spoken, "One going with the report.")
        XCTAssertEqual(step.state.outcome.includedItemIds, ["p0"])
    }

    func testAJobWithNoPhotosSettlesImmediatelyAndSaysSo() {
        let step = state([]).beginWalk(items: [])
        XCTAssertTrue(step.isSettled)
        XCTAssertEqual(step.spoken, "Nothing going with the report, then — just the record.")
    }

    /// Every picture `photo_log` took is already ticked when the walk begins, so a technician who
    /// says nothing at all still sends what they logged.
    func testLoggedPicturesAreAlreadyTickedBeforeAWordIsSaid() {
        let media = items(2, origin: .photoLog)
        let step = state(media).advance(.finish, items: media)
        XCTAssertEqual(step.state.outcome.includedItemIds, ["p0", "p1"])
    }
}
