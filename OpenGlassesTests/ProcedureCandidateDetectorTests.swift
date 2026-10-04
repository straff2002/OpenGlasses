import XCTest
@testable import OpenGlasses

/// Where a procedure probably happened: certain from the procedure runner and from a spoken mark,
/// likely from a run of narrated steps.
final class ProcedureCandidateDetectorTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias T = SessionTimeline
    private typealias D = ProcedureCandidateDetector
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private func timeline(_ events: [T.Event], recordedFor seconds: Double? = 600) -> T {
        T(wallStart: 0,
          tracks: seconds.map { [T.Track(track: .video, parts: [T.Part(partID: "v1", tZero: .zero, duration: t($0))])] } ?? [],
          events: events)
    }

    private func step(_ number: Int, _ start: Double, _ end: Double, like: Bool = true) -> WalkthroughSegmenter.Segment {
        WalkthroughSegmenter.Segment(id: "s\(number)", start: t(start), end: t(end), text: "…", utteranceIDs: [],
                                     opening: like ? .marker : .silence)
    }

    private func candidate(_ from: Double, _ to: Double, _ certainty: T.Certainty, _ reason: String) -> T.Candidate {
        T.Candidate(from: t(from), to: t(to), certainty: certainty, reason: reason)
    }

    // MARK: - The golden job

    func testTheGoldenTimelinesCandidatesAreWhatTheDetectorFinds() throws {
        let golden = try F.goldenTimeline()
        var bare = golden
        bare.candidates = []
        let segments = WalkthroughSegmenter.segments(try F.goldenTranscript())
        XCTAssertEqual(D.candidates(timeline: bare, segments: segments), golden.candidates)
        XCTAssertEqual(golden.candidates, [candidate(12, 143, .likely, "step_run"),
                                           candidate(40, 110, .certain, "procedure_run"),
                                           candidate(210, 270, .certain, "user_marker")])
    }

    // MARK: - Certain

    func testAProcedureRunFromStartToCompletionIsCertain() {
        let found = D.candidates(timeline: timeline([
            T.Event(t: t(40), kind: .procedureStarted, ref: "a"),
            T.Event(t: t(60), kind: .procedureStep, ref: "one"),
            T.Event(t: t(110), kind: .procedureCompleted, ref: "a"),
        ]), segments: [])
        XCTAssertEqual(found, [candidate(40, 110, .certain, "procedure_run")])
    }

    func testARunThatWasNeverCompletedEndsAtTheLastStepReached() {
        let found = D.candidates(timeline: timeline([
            T.Event(t: t(40), kind: .procedureStarted, ref: "a"),
            T.Event(t: t(60), kind: .procedureStep, ref: "one"),
            T.Event(t: t(95), kind: .procedureStep, ref: "two"),
            // A second procedure is started without the first being completed.
            T.Event(t: t(200), kind: .procedureStarted, ref: "b"),
            T.Event(t: t(230), kind: .procedureStep, ref: "one"),
        ]), segments: [])
        XCTAssertEqual(found, [candidate(40, 95, .certain, "procedure_run"), candidate(200, 230, .certain, "procedure_run")])
    }

    func testAProcedureStartedAndNothingMoreIsNoCandidate() {
        XCTAssertEqual(D.candidates(timeline: timeline([T.Event(t: t(40), kind: .procedureStarted, ref: "a")]),
                                    segments: []), [])
        // Steps and a completion with no start belong to no run.
        XCTAssertEqual(D.candidates(timeline: timeline([T.Event(t: t(40), kind: .procedureStep, ref: "one"),
                                                        T.Event(t: t(50), kind: .procedureCompleted, ref: "a")]),
                                    segments: []), [])
    }

    func testASpokenMarkIsCertainAndReachesHalfAMinuteEachWay() {
        XCTAssertEqual(D.candidates(timeline: timeline([T.Event(t: t(240), kind: .userMarker)]), segments: []),
                       [candidate(210, 270, .certain, "user_marker")])
    }

    func testAMarkNearEitherEndOfTheRecordingStaysInsideIt() {
        XCTAssertEqual(D.candidates(timeline: timeline([T.Event(t: t(10), kind: .userMarker),
                                                        T.Event(t: t(590), kind: .userMarker)]), segments: []),
                       [candidate(0, 40, .certain, "user_marker"), candidate(560, 600, .certain, "user_marker")])
        // With no media in the timeline there is no end to hold it to.
        XCTAssertEqual(D.candidates(timeline: timeline([T.Event(t: t(590), kind: .userMarker)], recordedFor: nil),
                                    segments: []),
                       [candidate(560, 620, .certain, "user_marker")])
    }

    // MARK: - Likely

    func testThreeNarratedStepsInARowAreLikelyAndTwoAreNot() {
        XCTAssertEqual(D.candidates(timeline: timeline([]), segments: [step(1, 10, 20), step(2, 30, 40)]), [])
        XCTAssertEqual(D.candidates(timeline: timeline([]), segments: [step(1, 10, 20), step(2, 30, 40), step(3, 50, 65)]),
                       [candidate(10, 65, .likely, "step_run")])
    }

    func testSegmentsThatAreNotStepsLieBetweenStepsWithoutBreakingTheRunOrCountingTowardsIt() {
        let found = D.candidates(timeline: timeline([]), segments: [
            step(1, 10, 20), step(2, 22, 28, like: false), step(3, 30, 40), step(4, 42, 48, like: false), step(5, 50, 65),
            step(6, 66, 70, like: false),
        ])
        XCTAssertEqual(found, [candidate(10, 65, .likely, "step_run")])
        XCTAssertEqual(D.candidates(timeline: timeline([]), segments: [
            step(1, 10, 20), step(2, 22, 28, like: false), step(3, 30, 40), step(4, 42, 48, like: false),
        ]), [], "two steps and two remarks are not three steps")
    }

    func testAStepThatBeginsTooLongAfterTheLastStartsANewRun() {
        // 180 seconds after the last step ended is still the same run; a millisecond more is not.
        XCTAssertEqual(D.candidates(timeline: timeline([]),
                                    segments: [step(1, 10, 20), step(2, 30, 40), step(3, 220, 230)]),
                       [candidate(10, 230, .likely, "step_run")])
        XCTAssertEqual(D.candidates(timeline: timeline([]),
                                    segments: [step(1, 10, 20), step(2, 30, 40), step(3, 220.001, 230)]), [])
        XCTAssertEqual(D.candidates(timeline: timeline([]), segments: [
            step(1, 10, 20), step(2, 30, 40), step(3, 50, 60),
            step(4, 400, 410), step(5, 420, 430), step(6, 440, 450),
        ]), [candidate(10, 60, .likely, "step_run"), candidate(400, 450, .likely, "step_run")])
    }

    func testARunOfStepsWhollyInsideACertainCandidateAddsNothing() {
        let run = [T.Event(t: t(5), kind: .procedureStarted, ref: "a"), T.Event(t: t(70), kind: .procedureCompleted, ref: "a")]
        let steps = [step(1, 10, 20), step(2, 30, 40), step(3, 50, 65)]
        XCTAssertEqual(D.candidates(timeline: timeline(run), segments: steps), [candidate(5, 70, .certain, "procedure_run")])
        // Reaching past it, the narration is its own advice.
        let longer = steps + [step(4, 80, 90)]
        XCTAssertEqual(D.candidates(timeline: timeline(run), segments: longer),
                       [candidate(5, 70, .certain, "procedure_run"), candidate(10, 90, .likely, "step_run")])
    }

    func testCandidatesComeInTimeOrder() {
        let found = D.candidates(timeline: timeline([
            T.Event(t: t(500), kind: .userMarker),
            T.Event(t: t(300), kind: .procedureStarted, ref: "a"),
            T.Event(t: t(350), kind: .procedureCompleted, ref: "a"),
        ]), segments: [step(1, 10, 20), step(2, 30, 40), step(3, 50, 65)])
        XCTAssertEqual(found.map(\.from), [t(10), t(300), t(470)])
    }

    func testTheThresholdsCanBeChanged() {
        var strict = D.Configuration()
        strict.minimumSteps = 4
        XCTAssertEqual(D.candidates(timeline: timeline([]), segments: [step(1, 10, 20), step(2, 30, 40), step(3, 50, 65)],
                                    configuration: strict), [])
        XCTAssertEqual(D.Configuration.standard, D.Configuration())
    }
}
