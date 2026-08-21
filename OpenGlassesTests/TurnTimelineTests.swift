import XCTest
@testable import OpenGlasses

/// Plan CU P1 — the pure core that has to be right before any latency claim about this app means
/// anything. Each test below pins one of the derivation invariants; several of them are corrections
/// that cost a bug to learn elsewhere, so they are written to fail loudly if the invariant is
/// relaxed rather than to merely exercise the code.
final class TurnTimelineTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Marks are injected as offsets from a fixed epoch — the whole point of the type being pure.
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    // MARK: - Invariant 1: tok/s comes from the reported pair, accumulated

    /// The trap: `firstTokenAt → generationDoneAt` looks like a decode window and is not one. Marks
    /// are first-wins and get backfilled for non-streaming backends, so a rate taken from them can
    /// cover a different span than the tokens it divides.
    func testTokensPerSecondComesFromTheReportedPairNotTheMarks() {
        var timeline = TurnTimeline()
        timeline.mark(.firstToken, at: at(1.0))
        timeline.mark(.generationDone, at: at(1.5))   // a 0.5 s window, if you believed the marks
        timeline.addGeneration(tokens: 100, seconds: 5.0)

        XCTAssertEqual(timeline.tokensPerSecond ?? 0, 20.0, accuracy: 0.001,
                       "the reported pair says 100 tokens over 5 s; the marks' 0.5 s window would say 200 tok/s")
    }

    /// Historical failure mode one: a window that rounds to nothing divides into millions of tok/s,
    /// and a fictional rate is worse than no rate at all.
    func testMicrosecondGenerationWindowReportsNoRateRatherThanAFictionalOne() {
        var timeline = TurnTimeline()
        timeline.addGeneration(tokens: 512, seconds: 0.000_002)

        XCTAssertNil(timeline.tokensPerSecond,
                     "a 2 µs window would divide into 256 million tok/s; the guard must return nil instead")
        XCTAssertEqual(timeline.tokenCount, 512, "the raw counts are still recorded — only the rate is withheld")
    }

    /// Historical failure mode two: a tool turn runs the model more than once, and pass 2's token
    /// count paired with pass 1's window produces a plausible-looking lie. Accumulating both halves
    /// makes that pairing impossible to express.
    func testGenerationPassesAccumulateSoPassTwoTokensCannotRidePassOnesWindow() {
        var timeline = TurnTimeline()
        timeline.addGeneration(tokens: 20, seconds: 4.0)     // pass 1: choose the tool
        timeline.addGeneration(tokens: 180, seconds: 1.0)    // pass 2: write the answer

        XCTAssertEqual(timeline.tokenCount, 200)
        XCTAssertEqual(timeline.generationSeconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(timeline.tokensPerSecond ?? 0, 40.0, accuracy: 0.001,
                       "200 tokens over 5 s. Overwriting would say 180; pass-2 tokens on pass-1's window, 45")
    }

    func testAddGenerationAccumulatesRatherThanOverwrites() {
        var timeline = TurnTimeline()
        timeline.addGeneration(tokens: 10, seconds: 1.0)
        timeline.addGeneration(tokens: 10, seconds: 1.0)

        XCTAssertEqual(timeline.tokenCount, 20)
        XCTAssertEqual(timeline.generationSeconds, 2.0, accuracy: 0.001)
    }

    func testNoTokensMeansNoRate() {
        var timeline = TurnTimeline()
        timeline.addGeneration(tokens: 0, seconds: 3.0)
        XCTAssertNil(timeline.tokensPerSecond)
    }

    // MARK: - Invariant 2: TTS lead-in is signed

    /// Negative lead-in is the *good* case — playback began while the model was still generating,
    /// which is the entire point of sentence-streaming. Clamping it away (as every other span does)
    /// would delete the metric on exactly the turns it exists to characterise.
    func testNegativeTTSLeadInIsPreserved() {
        var timeline = TurnTimeline()
        timeline.mark(.firstAudio, at: at(8.5))
        timeline.mark(.generationDone, at: at(10.0))

        XCTAssertEqual(timeline.ttsLeadIn ?? .nan, -1.5, accuracy: 0.001,
                       "streaming TTS started 1.5 s before generation finished; that must survive as a negative")
    }

    func testPositiveTTSLeadInIsTheNonStreamingCase() {
        var timeline = TurnTimeline()
        timeline.mark(.generationDone, at: at(10.0))
        timeline.mark(.firstAudio, at: at(10.8))
        XCTAssertEqual(timeline.ttsLeadIn ?? .nan, 0.8, accuracy: 0.001)
    }

    /// The asymmetry stated outright. Marks are stamped from several queues and sit on a wall clock
    /// that can step, so a backwards pair means a late or skewed mark rather than a real ordering —
    /// everywhere except lead-in, which is allowed to be genuinely negative.
    func testBackwardsMarksClampToNilEverywhereExceptLeadIn() {
        var timeline = TurnTimeline()
        timeline.mark(.speechEnd, at: at(12.0))          // stamped late; everything after reads earlier
        timeline.mark(.commit, at: at(4.0))
        timeline.mark(.ttsRequested, at: at(9.0))
        timeline.mark(.generationDone, at: at(10.0))
        timeline.mark(.firstAudio, at: at(8.5))

        XCTAssertNil(timeline.endpointingDelay, "a backwards stage span is skew, not a measurement")
        XCTAssertNil(timeline.perceivedLatency)
        XCTAssertNil(timeline.ttsTimeToFirstByte)
        XCTAssertEqual(timeline.ttsLeadIn ?? .nan, -1.5, accuracy: 0.001,
                       "lead-in is the one span that keeps its sign")
    }

    // MARK: - Invariant 3: time-to-first-byte is a distinct metric

    /// The streamed-reply shape both metrics exist for: the first sentence reaches the engine long
    /// before generation ends, so lead-in is negative while synthesis latency is plainly positive.
    /// One answers "did streaming help?", the other "how slow is the engine?".
    func testStreamedTurnHasNegativeLeadInAndPositiveTimeToFirstByte() {
        var timeline = TurnTimeline(ttsEngine: .elevenLabs)
        timeline.mark(.ttsRequested, at: at(3.0))
        timeline.mark(.firstAudio, at: at(3.4))
        timeline.mark(.generationDone, at: at(6.0))

        XCTAssertEqual(timeline.ttsTimeToFirstByte ?? .nan, 0.4, accuracy: 0.001,
                       "the cloud round trip took 400 ms")
        XCTAssertEqual(timeline.ttsLeadIn ?? .nan, -2.6, accuracy: 0.001,
                       "speech started 2.6 s before generation finished")
        XCTAssertNotEqual(timeline.ttsLeadIn ?? .nan, timeline.ttsTimeToFirstByte ?? .nan,
                          "the two must never collapse into one number")
    }

    // MARK: - Invariant 4: frame-grab time is held separately

    /// Vision TTFT contains the wait on the glasses' Bluetooth stream. Raw TTFT keeps it, because
    /// that is what the turn cost; the model-only derivation removes it, because comparing raw
    /// vision TTFT against text TTFT blames the model for the radio.
    func testRawTimeToFirstTokenKeepsTheFrameGrabAndModelTTFTRemovesIt() {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: at(2.0))
        timeline.mark(.firstToken, at: at(4.0))
        timeline.addFrameGrabTime(1.2)

        XCTAssertEqual(timeline.timeToFirstToken ?? .nan, 2.0, accuracy: 0.001,
                       "the raw stage span is never silently corrected")
        XCTAssertEqual(timeline.modelTimeToFirstToken ?? .nan, 0.8, accuracy: 0.001,
                       "the model only had 0.8 s of it; the rest was waiting on a frame")
    }

    func testFrameGrabTimeAccumulatesAcrossGrabs() {
        var timeline = TurnTimeline()
        timeline.addFrameGrabTime(0.4)
        timeline.addFrameGrabTime(0.6)
        XCTAssertEqual(timeline.frameGrabSeconds, 1.0, accuracy: 0.001,
                       "a multi-image turn grabs more than one frame")
    }

    func testModelTimeToFirstTokenIsFlooredRatherThanNegative() {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: at(0))
        timeline.mark(.firstToken, at: at(0.5))
        timeline.addFrameGrabTime(2.0)   // accounting overlapped the window
        XCTAssertEqual(timeline.modelTimeToFirstToken ?? .nan, 0, accuracy: 0.001)
    }

    // MARK: - Invariant 5: tool time accumulates and stays out of model time

    /// One turn, two tool round trips. Without the split, the six seconds spent inside the tools
    /// report as model latency and the next afternoon goes into optimising the wrong thing.
    func testTwoToolTurnKeepsToolExecutionOutOfModelSeconds() {
        var timeline = TurnTimeline(backend: .direct(.anthropic))
        timeline.mark(.commit, at: at(0))
        timeline.addToolTime(2.5)
        timeline.addToolTime(3.5)
        timeline.mark(.generationDone, at: at(10.0))

        XCTAssertEqual(timeline.toolIterations, 2)
        XCTAssertEqual(timeline.toolSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual(timeline.backendSeconds ?? .nan, 10.0, accuracy: 0.001,
                       "the backend leg is reported whole")
        XCTAssertEqual(timeline.modelSeconds ?? .nan, 4.0, accuracy: 0.001,
                       "only 4 s of the 10 was the model")
    }

    func testToolTimeAndIterationsAccumulateRatherThanOverwrite() {
        var timeline = TurnTimeline()
        timeline.addToolTime(1.0)
        timeline.addToolTime(1.0, iterations: 3)
        XCTAssertEqual(timeline.toolSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(timeline.toolIterations, 4)
    }

    /// Frame grab and tool time both sit inside the backend leg, so both come out of model time.
    func testModelSecondsRemovesFrameGrabAsWellAsToolTime() {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: at(0))
        timeline.mark(.generationDone, at: at(9.0))
        timeline.addToolTime(3.0)
        timeline.addFrameGrabTime(1.5)
        XCTAssertEqual(timeline.modelSeconds ?? .nan, 4.5, accuracy: 0.001)
    }

    // MARK: - Invariant 6: a held turn is measured from its own speech end

    /// `TurnAdmissionPolicy.deferToQueue` parks an utterance while another turn runs and replays it
    /// afterwards. Perceived latency must start at *this* turn's speech end — charging the hold to
    /// the pipeline would make every deferred turn look like a backend problem, and the hold is a
    /// queueing decision, not a slow model.
    func testHeldTurnMeasuresPerceivedLatencyFromItsOwnSpeechEnd() {
        var timeline = TurnTimeline()
        timeline.mark(.held, at: at(0))
        timeline.addHoldTime(7.0)
        timeline.mark(.speechEnd, at: at(7.2))
        timeline.mark(.firstAudio, at: at(9.2))

        XCTAssertEqual(timeline.perceivedLatency ?? .nan, 2.0, accuracy: 0.001,
                       "measured from speechEnd, not from heldAt — that would have said 9.2")
        XCTAssertEqual(timeline.waitIncludingHold ?? .nan, 9.0, accuracy: 0.001,
                       "the wearer's actual wait is reported next to it, never instead of it")
    }

    func testHoldTimeAccumulates() {
        var timeline = TurnTimeline()
        timeline.addHoldTime(3.0)
        timeline.addHoldTime(4.0)
        XCTAssertEqual(timeline.heldSeconds, 7.0, accuracy: 0.001)
    }

    func testUnheldTurnHasNoHoldAndReportsTheSameWaitEitherWay() {
        var timeline = TurnTimeline()
        timeline.mark(.speechEnd, at: at(0))
        timeline.mark(.firstAudio, at: at(1.4))
        XCTAssertEqual(timeline.heldSeconds, 0)
        XCTAssertEqual(timeline.waitIncludingHold ?? .nan, timeline.perceivedLatency ?? .nan, accuracy: 0.001)
    }

    // MARK: - Invariant 7: perceived latency is the headline, and honest about absence

    func testPerceivedLatencyIsTheSpeechEndToFirstAudioWindow() {
        var timeline = TurnTimeline()
        timeline.mark(.speechEnd, at: at(0))
        timeline.mark(.commit, at: at(2.0))          // the silence window P2 exists to remove
        timeline.mark(.firstToken, at: at(2.9))
        timeline.mark(.generationDone, at: at(4.1))
        timeline.mark(.ttsRequested, at: at(3.1))
        timeline.mark(.firstAudio, at: at(3.6))
        timeline.mark(.spokeDone, at: at(7.0))

        XCTAssertEqual(timeline.perceivedLatency ?? .nan, 3.6, accuracy: 0.001)
        XCTAssertEqual(timeline.endpointingDelay ?? .nan, 2.0, accuracy: 0.001)
        XCTAssertEqual(timeline.playbackSeconds ?? .nan, 3.4, accuracy: 0.001)
        XCTAssertEqual(timeline.totalSeconds ?? .nan, 7.0, accuracy: 0.001)
    }

    /// A turn that errored after commit never reached audio. There is no perceived latency to
    /// report and inventing one — from generation done, from the last mark — would put a number in
    /// the aggregate for a turn the wearer never heard.
    func testPerceivedLatencyIsNilWhenTheTurnNeverReachedAudio() {
        var timeline = TurnTimeline()
        timeline.mark(.speechEnd, at: at(0))
        timeline.mark(.commit, at: at(2.0))
        timeline.mark(.firstToken, at: at(3.0))
        timeline.abandoned = true

        XCTAssertNil(timeline.perceivedLatency)
        XCTAssertNil(timeline.waitIncludingHold)
        XCTAssertNil(timeline.ttsTimeToFirstByte)
        XCTAssertNil(timeline.ttsLeadIn)
    }

    // MARK: - Partial timelines, marks, and the panel's view of them

    /// The abandoned turn is not a write-off: what it did reach is the most informative record we
    /// have of where it stopped.
    func testAbandonedTurnStillYieldsAUsablePartialTimeline() {
        var timeline = TurnTimeline(backend: .direct(.local), micRoute: .glasses)
        timeline.mark(.speechEnd, at: at(0))
        timeline.mark(.commit, at: at(2.0))
        timeline.mark(.firstToken, at: at(6.5))
        timeline.abandoned = true

        XCTAssertEqual(timeline.timeToFirstToken ?? .nan, 4.5, accuracy: 0.001,
                       "TTFT is exactly the number that explains why this turn was abandoned")
        XCTAssertEqual(timeline.startedAt, at(0))
        XCTAssertNil(timeline.backendSeconds, "generation never finished; no span to report")
    }

    /// A caller marking `.firstToken` on every streamed delta must not walk the mark forward — the
    /// metric is about the *first* one.
    func testMarksAreFirstWins() {
        var timeline = TurnTimeline()
        timeline.mark(.firstToken, at: at(3.0))
        timeline.mark(.firstToken, at: at(3.9))
        timeline.mark(.firstToken, at: at(4.4))
        XCTAssertEqual(timeline.firstTokenAt, at(3.0))
        XCTAssertEqual(timeline[.firstToken], at(3.0))
    }

    func testUnmarkedStagesReadAsNil() {
        let timeline = TurnTimeline()
        for stage in TurnTimeline.Stage.allCases {
            XCTAssertNil(timeline[stage], stage.rawValue)
        }
        XCTAssertNil(timeline.startedAt)
        XCTAssertEqual(timeline.segments, [])
    }

    func testStartedAtIsTheFirstMarkInCanonicalOrder() {
        var held = TurnTimeline()
        held.mark(.speechEnd, at: at(7.2))
        held.mark(.held, at: at(0))
        XCTAssertEqual(held.startedAt, at(0), "a held turn's clock starts when it was parked")

        var direct = TurnTimeline()
        direct.mark(.speechEnd, at: at(7.2))
        XCTAssertEqual(direct.startedAt, at(7.2))
    }

    /// A non-streaming backend has no first token of its own. The breakdown absorbs the missing
    /// stages into the next segment rather than drawing zero-width bars that would read as
    /// "instant" when they mean "never observed".
    func testSegmentsSkipStagesThatNeverLanded() {
        var timeline = TurnTimeline()
        timeline.mark(.speechEnd, at: at(0))
        timeline.mark(.commit, at: at(2.0))
        timeline.mark(.firstAudio, at: at(5.0))

        XCTAssertEqual(timeline.segments,
                       [TurnTimeline.Segment(stage: .commit, seconds: 2.0),
                        TurnTimeline.Segment(stage: .firstAudio, seconds: 3.0)])
    }

    // MARK: - Cohorts

    /// The tagging rule made structural: two turns that differ only in mic route are two
    /// populations, and an aggregate that pools them describes neither.
    func testCohortsSeparateMicRoutesAndTTSEngines() {
        var phone = TurnTimeline(backend: .direct(.anthropic), ttsEngine: .elevenLabs, micRoute: .phone)
        var glasses = TurnTimeline(backend: .direct(.anthropic), ttsEngine: .elevenLabs, micRoute: .glasses)
        var kokoro = TurnTimeline(backend: .direct(.anthropic), ttsEngine: .kokoro, micRoute: .phone)

        XCTAssertNotEqual(phone.cohort, glasses.cohort)
        XCTAssertNotEqual(phone.cohort, kokoro.cohort)
        XCTAssertEqual(Set([phone.cohort, glasses.cohort, kokoro.cohort]).count, 3)

        // Marks and spans are not part of the grouping key — two turns of different length still
        // belong to the same cohort.
        phone.mark(.speechEnd, at: at(0))
        glasses.mark(.speechEnd, at: at(0))
        kokoro.mark(.speechEnd, at: at(0))
        var otherPhoneTurn = TurnTimeline(backend: .direct(.anthropic), ttsEngine: .elevenLabs, micRoute: .phone)
        otherPhoneTurn.mark(.speechEnd, at: at(100))
        XCTAssertEqual(phone.cohort, otherPhoneTurn.cohort)
    }

    func testRealtimeBackendsAreTheirOwnCohorts() {
        XCTAssertNotEqual(TurnBackend.geminiLive, TurnBackend.openAIRealtime)
        XCTAssertNotEqual(TurnBackend.direct(.gemini), TurnBackend.geminiLive)
        XCTAssertEqual(TurnBackend.direct(.groq).label, "groq")
    }
}
