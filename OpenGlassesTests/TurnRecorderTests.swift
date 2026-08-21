import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan CU P1 — the seam, not the value type. `TurnTimelineTests` pins the derivations and
/// `TurnLedgerTests` the store; everything that decides whether those numbers describe the right
/// turn lives here, and only here: which utterance a turn claims, the staleness ceilings that stop
/// an unclaimed stamp poisoning a later turn, the hand-off window that keeps a model-switch notice
/// from claiming `firstAudio`, and the off-turn gate that keeps a background completion out of a
/// live turn's cohort. Every one of those can be deleted with the rest of the suite still green if
/// it is not pinned here.
@MainActor
final class TurnRecorderTests: XCTestCase {

    /// The recorder's clock, held in a plain class so the closure handed to `TurnRecorder.now` and
    /// the test body see the same instant — advancing it is how a staleness ceiling is reached
    /// without sleeping.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private var ledger = TurnLedger()
    private var clock = Clock(Date())

    override func setUp() {
        super.setUp()
        ledger = TurnLedger()
        clock = Clock(at(0))
        // No input ports by default: the mic-route tests below supply their own, and everything
        // else falls back to the configured preference rather than to whatever the simulator's
        // audio session happens to be routed to.
        TurnRecorder.reset(ledger: ledger, now: { [clock] in clock.now }, micRoutePorts: { [] })
    }

    override func tearDown() {
        TurnRecorder.reset()
        super.tearDown()
    }

    /// Seal the turn in flight and hand back what it recorded.
    private func sealAndRead() -> TurnTimeline? {
        TurnRecorder.endTurn()
        return ledger.sealed.last
    }

    // MARK: - Claiming the utterance

    func testTurnClaimsTheSpeechEndStampLeftByTheUtteranceThatStartedIt() {
        TurnRecorder.noteSpeechEnd(at: at(0))
        clock.now = at(2.0)
        TurnRecorder.beginTurn()
        clock.now = at(3.4)
        TurnRecorder.handOffToSpeech()
        TurnRecorder.markPlaybackStart(at: at(3.4))

        let turn = sealAndRead()
        XCTAssertEqual(turn?.speechEndAt, at(0), "the turn is measured from when the mic went quiet")
        XCTAssertEqual(turn?.perceivedLatency ?? .nan, 3.4, accuracy: 0.001)
    }

    /// The stamp is claimed by the turn that answers it — but `handleTranscription` returns several
    /// times before any turn begins, so a voice command consumed by the pre-LLM chain ("stop",
    /// "next slide") leaves one nobody will ever claim. Without a ceiling the next turn — possibly
    /// a typed one, minutes later — inherits it and reports a preposterous perceived latency.
    func testAnUnclaimedSpeechEndStampGoesStaleRatherThanPoisoningALaterTurn() {
        TurnRecorder.noteSpeechEnd(at: at(0))          // consumed by the pre-LLM chain; no turn began

        clock.now = at(600)                            // ten minutes later, a fresh turn
        TurnRecorder.beginTurn()
        TurnRecorder.handOffToSpeech()
        TurnRecorder.markPlaybackStart(at: at(601))

        let turn = sealAndRead()
        XCTAssertNil(turn?.speechEndAt, "a ten-minute-old stamp belongs to no turn")
        XCTAssertNil(turn?.perceivedLatency, "and no latency is far better than a 601 s one")
    }

    /// The boundary the ceiling is actually made of — a stamp just inside it is still this turn's.
    func testASpeechEndStampJustInsideTheCeilingIsStillClaimed() {
        TurnRecorder.noteSpeechEnd(at: at(0))
        clock.now = at(29)
        TurnRecorder.beginTurn()
        XCTAssertEqual(sealAndRead()?.speechEndAt, at(0))
    }

    func testCapturingANewUtteranceForgetsBothPendingStamps() {
        TurnRecorder.noteSpeechEnd(at: at(0))
        TurnRecorder.noteHeldUtterance(parkedAt: at(-5))

        TurnRecorder.forgetPendingUtterance()

        clock.now = at(1)
        TurnRecorder.beginTurn()
        let turn = sealAndRead()
        XCTAssertNil(turn?.speechEndAt)
        XCTAssertNil(turn?.heldAt)
        XCTAssertEqual(turn?.heldSeconds, 0)
    }

    // MARK: - Held utterances

    /// A parked utterance's turn carries the park time and the wait, but is *measured* from its own
    /// release — charging the hold to `perceivedLatency` would make every deferred turn read as a
    /// slow backend when it was a queueing decision.
    func testHeldUtteranceRecordsTheParkAndTheWaitButStartsItsClockAtTheRelease() {
        TurnRecorder.noteHeldUtterance(parkedAt: at(0))
        clock.now = at(7.0)
        TurnRecorder.beginTurn()
        TurnRecorder.handOffToSpeech()
        TurnRecorder.markPlaybackStart(at: at(9.0))

        let turn = sealAndRead()
        XCTAssertEqual(turn?.heldAt, at(0))
        XCTAssertEqual(turn?.heldSeconds ?? .nan, 7.0, accuracy: 0.001)
        XCTAssertEqual(turn?.speechEndAt, at(7.0), "this turn's clock starts at the release")
        XCTAssertEqual(turn?.perceivedLatency ?? .nan, 2.0, accuracy: 0.001)
        XCTAssertEqual(turn?.waitIncludingHold ?? .nan, 9.0, accuracy: 0.001,
                       "the wearer's real wait is reported next to it, never instead of it")
    }

    /// The sibling of the stale-speech-end case, and the one that bites harder: a held utterance is
    /// replayed straight into `handleTranscription`, where the pre-LLM chain can consume it exactly
    /// as it consumes a fresh one. The leftover hold would otherwise rewrite an unrelated later
    /// turn's speech-end at its own begin instant — destroying that turn's perceived latency — and
    /// report the intervening hours as `heldSeconds`.
    func testAnUnclaimedHoldGoesStaleRatherThanRewritingALaterTurnsSpeechEnd() {
        TurnRecorder.noteHeldUtterance(parkedAt: at(0))   // replayed, then consumed by "next slide"

        clock.now = at(600)                                // an unrelated turn, ten minutes on
        TurnRecorder.noteSpeechEnd(at: at(598))
        TurnRecorder.beginTurn()
        TurnRecorder.handOffToSpeech()
        TurnRecorder.markPlaybackStart(at: at(601))

        let turn = sealAndRead()
        XCTAssertNil(turn?.heldAt, "a ten-minute-old park belongs to no turn")
        XCTAssertEqual(turn?.heldSeconds, 0, "and certainly not to this one, as a ten-minute wait")
        XCTAssertEqual(turn?.speechEndAt, at(598),
                       "the stale hold must not displace this turn's own speech-end stamp")
        XCTAssertEqual(turn?.perceivedLatency ?? .nan, 3.0, accuracy: 0.001)
    }

    /// The ceiling is measured against the *replay*, not the park: `TurnAdmissionPolicy` allows a
    /// hold of up to 20 s, and bounding the park itself would refuse a legitimate long one.
    func testALongButLegitimateHoldIsStillClaimedByItsOwnTurn() {
        clock.now = at(19)
        TurnRecorder.noteHeldUtterance(parkedAt: at(0))
        TurnRecorder.beginTurn()

        let turn = sealAndRead()
        XCTAssertEqual(turn?.heldAt, at(0))
        XCTAssertEqual(turn?.heldSeconds ?? .nan, 19.0, accuracy: 0.001)
    }

    // MARK: - Turn lifecycle

    /// `handleTranscription` has half a dozen early exits and barge-in starts a replacement turn
    /// from inside the old one's teardown, so "the previous turn always called `endTurn()`" is an
    /// assumption that would be wrong eventually. A displaced turn seals with the marks it had.
    func testBeginningATurnSealsOneThatWasStillOpen() {
        TurnRecorder.beginTurn()
        TurnRecorder.mark(.commit, at: at(1.0))

        TurnRecorder.beginTurn()

        XCTAssertEqual(ledger.sealed.count, 1, "the displaced turn is sealed, not dropped")
        XCTAssertEqual(ledger.sealed[0].commitAt, at(1.0), "with exactly the marks it had")
        XCTAssertEqual(ledger.inFlightCount, 1, "and exactly one turn is left in flight")
    }

    func testEndTurnIsIdempotent() {
        TurnRecorder.beginTurn()
        TurnRecorder.endTurn()
        TurnRecorder.endTurn()
        XCTAssertEqual(ledger.sealed.count, 1)
        XCTAssertEqual(ledger.inFlightCount, 0)
    }

    func testMarksArrivingAfterTheTurnEndedGoNowhere() {
        TurnRecorder.beginTurn()
        TurnRecorder.endTurn()
        TurnRecorder.mark(.commit, at: at(5.0))
        TurnRecorder.noteBackend(.direct(.groq), model: "late")

        XCTAssertNil(ledger.sealed[0].commitAt)
        XCTAssertNil(ledger.sealed[0].backend)
    }

    func testRecordingDisabledRecordsNothingAtAll() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "turnLatencyRecordingEnabled")
        defer { defaults.set(saved, forKey: "turnLatencyRecordingEnabled") }

        TurnRecorder.isEnabled = false
        TurnRecorder.noteSpeechEnd(at: at(0))
        TurnRecorder.beginTurn()
        TurnRecorder.mark(.commit, at: at(1.0))
        TurnRecorder.endTurn()

        XCTAssertEqual(ledger.sealed.count, 0)
        XCTAssertEqual(ledger.inFlightCount, 0)
    }

    // MARK: - Releasing an utterance to whatever answers it next

    /// The tier-0 direct-tool path falls through to the normal LLM path when a tool throws, and the
    /// LLM turn answers the same words. Without the release, that turn finds the stamp already spent
    /// and reports no perceived latency at all — on the slowest turn shape the app has (a failed
    /// tool call *plus* a full round trip), which biases the headline aggregate fast.
    func testAbandoningATurnHandsItsUtteranceToTheTurnThatAnswersItNext() {
        TurnRecorder.noteSpeechEnd(at: at(0))
        clock.now = at(2.0)
        TurnRecorder.beginTurn()

        clock.now = at(2.5)
        TurnRecorder.abandonTurnReleasingUtterance()

        XCTAssertEqual(ledger.sealed.count, 1, "the failed attempt is sealed, not left in flight")
        XCTAssertTrue(ledger.sealed[0].abandoned)
        XCTAssertEqual(ledger.inFlightCount, 0)

        clock.now = at(2.6)
        TurnRecorder.beginTurn()
        TurnRecorder.handOffToSpeech()
        TurnRecorder.markPlaybackStart(at: at(6.0))

        let replacement = sealAndRead()
        XCTAssertEqual(replacement?.speechEndAt, at(0),
                       "the replacement turn inherits the utterance the abandoned one claimed")
        XCTAssertEqual(replacement?.perceivedLatency ?? .nan, 6.0, accuracy: 0.001,
                       "which is what the wearer actually waited for the tool that failed")
    }

    func testAbandoningAHeldTurnHandsBackTheHoldAsWell() {
        TurnRecorder.noteHeldUtterance(parkedAt: at(0))
        clock.now = at(5.0)
        TurnRecorder.beginTurn()
        TurnRecorder.abandonTurnReleasingUtterance()

        clock.now = at(5.5)
        TurnRecorder.beginTurn()
        let replacement = sealAndRead()
        XCTAssertEqual(replacement?.heldAt, at(0))
        XCTAssertEqual(replacement?.heldSeconds ?? .nan, 5.5, accuracy: 0.001)
    }

    // MARK: - First token

    func testFirstTokenIsRecordedOncePerTurnAndReArmsForTheNext() {
        TurnRecorder.beginTurn()
        clock.now = at(1.0)
        TurnRecorder.markFirstToken()
        clock.now = at(1.1)
        TurnRecorder.markFirstToken()
        XCTAssertEqual(sealAndRead()?.firstTokenAt, at(1.0), "every delta calls this; only the first counts")

        TurnRecorder.beginTurn()
        clock.now = at(9.0)
        TurnRecorder.markFirstToken()
        XCTAssertEqual(sealAndRead()?.firstTokenAt, at(9.0), "the next turn gets its own first token")
    }

    // MARK: - The speech hand-off window

    /// A turn speaks more than its reply: `narrateModelSwitch` says "switching to Groq" while the
    /// model is still generating. That utterance reaching `markPlaybackStart` would claim
    /// `firstAudio` — the mark the headline metric *ends* at — and report the turn as far faster
    /// than the wearer experienced it.
    func testAModelSwitchNoticeSpokenMidTurnCannotClaimFirstAudio() {
        TurnRecorder.noteSpeechEnd(at: at(0))
        TurnRecorder.beginTurn()

        TurnRecorder.markPlaybackStart(at: at(1.0))     // the "switching to Groq" notice
        TurnRecorder.noteSpeechEngine(.system)
        TurnRecorder.markPlaybackEnd(at: at(3.0))
        TurnRecorder.markHUDRendered(at: at(1.2))

        TurnRecorder.handOffToSpeech(at: at(8.0))        // now the reply goes to the engine
        TurnRecorder.noteSpeechEngine(.elevenLabs)
        TurnRecorder.markPlaybackStart(at: at(8.4))

        let turn = sealAndRead()
        XCTAssertEqual(turn?.firstAudioAt, at(8.4), "the reply's audio, not the notice's")
        XCTAssertEqual(turn?.perceivedLatency ?? .nan, 8.4, accuracy: 0.001)
        XCTAssertNil(turn?.spokeDoneAt, "the notice's playback end is not this turn's")
        XCTAssertNil(turn?.hudRenderedAt, "nor is the notice's HUD mirror")
        XCTAssertEqual(turn?.ttsEngine, .elevenLabs, "nor is the engine that spoke it")
    }

    /// The window is per-turn: the next turn starts closed, so a stray late callback from the last
    /// one's playback cannot hand it a first-audio it never had.
    func testTheHandOffWindowDoesNotSurviveIntoTheNextTurn() {
        TurnRecorder.beginTurn()
        TurnRecorder.handOffToSpeech(at: at(1.0))
        TurnRecorder.endTurn()

        TurnRecorder.beginTurn()
        TurnRecorder.markPlaybackStart(at: at(2.0))
        XCTAssertNil(sealAndRead()?.firstAudioAt)
    }

    // MARK: - Off-turn work

    /// `AgentScheduler`, the notification digest and the OpenClaw triage all reach
    /// `LLMService.sendMessage` and `runToolLoop` on their own timers, through the very code a voice
    /// turn is using. Ungated, a scheduled Groq run re-tags a live on-device turn into the Groq
    /// cohort and adds its tool seconds until `modelSeconds` clamps to zero — "the model took no
    /// time at all".
    func testBackgroundWorkCannotRetagOrAccumulateOntoTheLiveTurn() async {
        TurnRecorder.beginTurn()
        TurnRecorder.mark(.commit, at: at(0))
        TurnRecorder.noteBackend(.direct(.local), model: "gemma-on-device")

        await TurnRecorder.offTurn {
            TurnRecorder.noteBackend(.direct(.groq), model: "llama-in-the-cloud")
            TurnRecorder.addToolTime(since: at(-4.0))
            TurnRecorder.addGeneration(tokens: 500, seconds: 1.0)
            TurnRecorder.markFirstToken()
        }

        clock.now = at(3.0)
        TurnRecorder.markFirstToken()
        TurnRecorder.mark(.generationDone, at: at(10.0))

        let turn = sealAndRead()
        XCTAssertEqual(turn?.backend, .direct(.local), "the scheduled run must not own this cohort")
        XCTAssertEqual(turn?.model, "gemma-on-device")
        XCTAssertEqual(turn?.toolSeconds, 0, "nor charge this turn for its own tool round trips")
        XCTAssertEqual(turn?.tokenCount, 0)
        XCTAssertEqual(turn?.firstTokenAt, at(3.0),
                       "and a suppressed token must not burn the turn's own first-token slot")
        XCTAssertEqual(turn?.modelSeconds ?? .nan, 10.0, accuracy: 0.001,
                       "ungated, the background loop's 4 s would come straight out of model time")
    }

    func testOffTurnSuppressionEndsWithTheWorkThatDeclaredIt() async {
        TurnRecorder.beginTurn()
        await TurnRecorder.offTurn { TurnRecorder.mark(.commit, at: self.at(1.0)) }
        TurnRecorder.mark(.commit, at: at(2.0))
        XCTAssertEqual(sealAndRead()?.commitAt, at(2.0))
    }

    // MARK: - Non-model work inside the backend leg

    /// The model-switch notice blocks until it has finished *playing*, inside commit →
    /// generationDone. Charged to the model, a cascade turn reports ~8 s of "model latency" when 3 s
    /// of it was the app talking to the wearer.
    func testAppWorkInsideTheBackendLegIsHeldOutOfModelTime() {
        TurnRecorder.beginTurn()
        TurnRecorder.mark(.commit, at: at(0))
        clock.now = at(3.0)
        TurnRecorder.addNonModelTime(since: at(0))      // the spoken "switching to Groq"
        TurnRecorder.mark(.firstToken, at: at(4.0))
        TurnRecorder.mark(.generationDone, at: at(8.0))

        let turn = sealAndRead()
        XCTAssertEqual(turn?.nonModelSeconds ?? .nan, 3.0, accuracy: 0.001)
        XCTAssertEqual(turn?.backendSeconds ?? .nan, 8.0, accuracy: 0.001, "the leg is still reported whole")
        XCTAssertEqual(turn?.modelSeconds ?? .nan, 5.0, accuracy: 0.001)
        XCTAssertEqual(turn?.timeToFirstToken ?? .nan, 4.0, accuracy: 0.001)
        XCTAssertEqual(turn?.modelTimeToFirstToken ?? .nan, 1.0, accuracy: 0.001,
                       "the model had 1 s of the 4 s; the rest was the app speaking")
    }

    // MARK: - Mic route

    /// `Config.micRoute` is a preference. `WakeWordService` leaves capture on the phone whenever the
    /// preferred port is absent — glasses flat, asleep, out of range — so tagging from the
    /// preference files 48 kHz phone-mic turns in the 8 kHz HFP cohort and reports a median that
    /// describes neither population.
    func testTurnIsTaggedWithTheRouteThatActuallyCapturedIt() {
        TurnRecorder.reset(ledger: ledger,
                           now: { [clock] in clock.now },
                           micRoutePorts: { [(name: "Ray-Ban Meta Glasses", type: .bluetoothHFP)] })
        TurnRecorder.beginTurn()
        XCTAssertEqual(sealAndRead()?.micRoute, .glasses)

        TurnRecorder.reset(ledger: ledger,
                           now: { [clock] in clock.now },
                           micRoutePorts: { [(name: "iPhone Microphone", type: .builtInMic)] })
        TurnRecorder.beginTurn()
        XCTAssertEqual(sealAndRead()?.micRoute, .phone,
                       "the glasses being the preference does not make them the mic")

        TurnRecorder.reset(ledger: ledger,
                           now: { [clock] in clock.now },
                           micRoutePorts: { [(name: "AirPods Pro", type: .bluetoothHFP)] })
        TurnRecorder.beginTurn()
        XCTAssertEqual(sealAndRead()?.micRoute, .headset)
    }

    func testASessionWithNoInputPortFallsBackToTheConfiguredPreference() {
        TurnRecorder.beginTurn()   // setUp supplies no ports
        XCTAssertEqual(sealAndRead()?.micRoute, Config.micRoute,
                       "nothing was observed, so the preference is the only answer available")
    }
}
