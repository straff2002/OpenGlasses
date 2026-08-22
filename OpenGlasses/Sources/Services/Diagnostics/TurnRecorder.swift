import AVFoundation
import Foundation

/// Plan CU P1 — the seam between the live turn path and `TurnLedger`.
///
/// `TurnTimeline` is pure and `TurnLedger` is a store; neither knows which turn is happening right
/// now, and the turn path has no way to tell them. The marks come from a dozen sites that cannot
/// hand an id to one another: `TextToSpeechService` is a singleton that is passed a string,
/// `GlassesDisplayService` drains a latest-wins render queue, `runToolLoop` is deliberately
/// provider-neutral. This holds the one id they all mean, so each of those sites is a single
/// statement instead of a new parameter threaded through four layers.
///
/// **Everything here is instrumentation and behaves like it.** Every entry point returns on its
/// first line when recording is off or no turn is in flight; nothing throws; nothing suspends
/// (every call site is already on the main actor); no call reads or writes state the turn path
/// depends on. A voice turn must not be able to fail *because* we were measuring it.
///
/// One turn at a time, which is what the app already enforces through `isProcessing` /
/// `TurnAdmissionPolicy`. `beginTurn()` seals whatever was still open rather than trusting every
/// exit path in `handleTranscription` to have been found.
@MainActor
enum TurnRecorder {

    /// How the live mic route is read. A named type because it is both a stored seam and a
    /// parameter of `reset(ledger:now:micRoutePorts:)`.
    typealias MicRoutePortsReader = () -> [(name: String, type: AVAudioSession.Port)]

    /// The ledger every mark lands in, and the object the Developer panel observes.
    ///
    /// A `var` for one reason: the decisions below — which utterance a turn claims, the staleness
    /// ceilings, the hand-off window — are only testable against a ledger the test owns. Production
    /// never reassigns it; `TurnLedger.shared` is this object.
    static var ledger = TurnLedger()

    /// Where wall-clock time enters the recorder. `TurnTimeline` is pure precisely so every
    /// derivation is a fixture test; this is the matching seam for the recorder's own arithmetic,
    /// which is otherwise only reachable by sleeping in a test.
    static var now: () -> Date = { Date() }

    /// The session's current input ports, as `MicRoutePolicy.resolvedRoute(from:)` wants them.
    static var micRoutePorts: MicRoutePortsReader = liveMicRoutePorts

    static let liveMicRoutePorts: MicRoutePortsReader = {
        AVAudioSession.sharedInstance().currentRoute.inputs.map { (name: $0.portName, type: $0.portType) }
    }

    /// Work the app started for itself — a scheduled agent run, notification triage, a background
    /// summarisation — rather than for the turn in flight.
    ///
    /// These traverse the very code a turn does (`LLMService.sendMessage`, `runToolLoop`), so an
    /// unguarded tag or span written from one of them lands on whichever turn happens to be open: a
    /// scheduled Groq run re-tags a live on-device turn into the Groq cohort, and a background tool
    /// loop adds its seconds to that turn's `toolSeconds` until `modelSeconds` clamps to 0.00 s and
    /// reads as "the model took no time at all". A task-local rather than a flag because the two
    /// overlap *in time* on the same actor — which task the work runs on is the only thing that
    /// tells them apart.
    @TaskLocal static var isOffTurnWork = false

    /// Run `body` as off-turn work: nothing inside it can mark, tag, or accumulate onto the turn in
    /// flight. Wrap the app's own background completions in this; the turn path never does.
    static func offTurn<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $isOffTurnWork.withValue(true) { try await body() }
    }

    /// Recording is on by default: the ledger is a bounded ring buffer with no sink at all (Plan CU
    /// P1 item 5), so leaving it on costs a few hundred bytes per turn, and a panel that stays empty
    /// until someone finds a switch measures nothing. Off makes every call below return immediately.
    static var isEnabled: Bool {
        get { enabled }
        set {
            enabled = newValue
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue {
                endTurn()
                pendingSpeechEndAt = nil
                pendingHeld = nil
            }
        }
    }

    /// Backing store, so `reset(…)` can put the recorder in a known state without writing the user's
    /// real preference from a test.
    private static var enabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true

    private static let enabledKey = "turnLatencyRecordingEnabled"

    /// The turn currently being recorded. `nil` between turns *and* whenever recording is off,
    /// which is why the mark helpers only need to check `targetID`.
    private static var currentID: UUID?

    /// The turn a mark should land on, or `nil` when there is nothing to record: no turn in flight,
    /// or this code path is running as off-turn work.
    private static var targetID: UUID? { isOffTurnWork ? nil : currentID }

    /// Set once per turn so the per-token `markFirstToken()` is a boolean test after the first.
    private static var sawFirstToken = false

    /// True between the turn handing its reply to the speech engine and playback ending — see
    /// `handOffToSpeech(at:)`.
    private static var speechHandedOff = false

    /// When the mic last went quiet, waiting for the turn that will answer it.
    private static var pendingSpeechEndAt: Date?

    /// Which signal ended that speech (Plan CU P2). Kept alongside `pendingSpeechEndAt` and cleared
    /// with it, so a reason can never outlive the utterance it describes and be claimed by the next.
    private static var pendingEndOfTurnReason: EndOfTurnPolicy.Reason?

    /// The utterance parked by `TurnAdmissionPolicy`, and when the replay that should claim it was
    /// announced. Both halves are needed: the park time is what the turn records, while `notedAt` is
    /// what the staleness ceiling is measured against — bounding the *park* would refuse a
    /// legitimate 19 s hold for having been long, which is exactly the case `maxHoldAge` allows.
    private static var pendingHeld: (parkedAt: Date, notedAt: Date)?

    /// How long an unclaimed utterance stamp — a speech-end or a hold — stays attachable to the
    /// next turn.
    ///
    /// A stamp is set when the utterance is ready and claimed by the turn that answers it, normally
    /// within the same fraction of a second. But `handleTranscription` returns several times before
    /// any turn begins: a voice command consumed by the pre-LLM chain ("stop", "next slide") leaves
    /// a speech-end nobody claims, and a *held* utterance replayed into that same chain leaves a
    /// hold nobody claims. With no ceiling the next turn — possibly a typed one, hours later —
    /// inherits it and reports a preposterous perceived latency, or an hours-long wait with its own
    /// speech-end overwritten at the begin instant. Generous enough that no real turn is ever
    /// refused its own stamp.
    private static let stampStaleness: TimeInterval = 30

    // MARK: - The utterance, before it is a turn

    /// The mic went quiet. Recorded here rather than marked on a turn because the turn does not
    /// exist yet — `handleTranscription` may still route this utterance to the teleprompter, a
    /// launcher, or nothing at all, and only the ones that reach a backend or the speech engine
    /// become turns.
    static func noteSpeechEnd(at time: Date) {
        guard isEnabled else { return }
        pendingSpeechEndAt = time
    }

    /// A new utterance is being captured, so any unclaimed stamp belongs to something that has
    /// already been dealt with.
    ///
    /// Both stamps, not just the speech-end: a held utterance is replayed straight into
    /// `handleTranscription` and can be consumed by the pre-LLM chain exactly as a fresh one can, and
    /// the leftover hold would otherwise rewrite the next turn's speech-end at its own begin instant
    /// and report the intervening minutes as `heldSeconds`.
    static func forgetPendingUtterance() {
        pendingSpeechEndAt = nil
        pendingEndOfTurnReason = nil
        pendingHeld = nil
    }

    /// An utterance parked by `TurnAdmissionPolicy.deferToQueue` is being replayed now. The turn it
    /// starts owns both the park time and the wait.
    static func noteHeldUtterance(parkedAt time: Date) {
        guard isEnabled else { return }
        pendingHeld = (parkedAt: time, notedAt: now())
    }

    // MARK: - Turn lifecycle

    /// Start recording a turn, claiming whatever the utterance left behind.
    ///
    /// Seals any turn still open first. That is not tidiness: `handleTranscription` has half a dozen
    /// early exits and the barge-in path starts a replacement turn from inside the old one's
    /// teardown, so "the previous turn always called `endTurn()`" is an assumption that would be
    /// wrong eventually. A displaced turn seals with exactly the marks it had.
    static func beginTurn() {
        guard isEnabled else { return }
        endTurn()

        let startedAt = now()
        var timeline = TurnTimeline(micRoute: resolvedMicRoute())
        if let held = pendingHeld, startedAt.timeIntervalSince(held.notedAt) <= stampStaleness {
            timeline.mark(.held, at: held.parkedAt)
            timeline.addHoldTime(startedAt.timeIntervalSince(held.parkedAt))
            // The wearer stopped talking before the park, but this turn's own clock starts at the
            // release. Marking speech-end back at the park would charge the hold to
            // `perceivedLatency` and make every deferred utterance read as a slow backend;
            // `heldSeconds` / `waitIncludingHold` carry that wait instead.
            timeline.mark(.speechEnd, at: startedAt)
        } else if let speechEnd = pendingSpeechEndAt,
                  startedAt.timeIntervalSince(speechEnd) <= stampStaleness {
            timeline.mark(.speechEnd, at: speechEnd)
            // Only on this branch: a held utterance's speech-end is deliberately re-stamped at the
            // release above, so the reason that ended speech no longer describes the mark it would
            // sit beside. A held turn reports no endpointing reason rather than a misleading one.
            timeline.endOfTurnReason = pendingEndOfTurnReason
        }

        pendingHeld = nil
        pendingSpeechEndAt = nil
        pendingEndOfTurnReason = nil
        sawFirstToken = false
        speechHandedOff = false
        currentID = ledger.start(timeline)
    }

    /// Seal the current turn. Idempotent, so it can sit in a `finish` stage that also runs on the
    /// error and cancellation paths.
    static func endTurn() {
        guard let id = currentID else { return }
        currentID = nil
        sawFirstToken = false
        speechHandedOff = false
        ledger.seal(id)
    }

    /// Seal a turn that failed before it reached a backend, handing its utterance back so the thing
    /// about to answer the same words can claim it.
    ///
    /// The tier-0 direct-tool path is the case this exists for: on a tool error it falls straight
    /// through to the normal LLM path, which begins a turn of its own. Without this the failed
    /// attempt never seals at all (its caller clears `isProcessing` first, and the seal is gated
    /// behind that flag) and, worse, the replacement finds the stamps already spent — so
    /// `perceivedLatency` comes out nil on precisely the slowest turns the app has, a failed tool
    /// call *plus* a full LLM round trip. Dropping those biases the headline aggregate fast, which
    /// is the mirror image of the bias tier-0 recording was added to prevent.
    static func abandonTurnReleasingUtterance() {
        noteAbandoned()
        if let id = currentID, let timeline = ledger.turn(id) {
            pendingSpeechEndAt = timeline.speechEndAt
            if let heldAt = timeline.heldAt {
                pendingHeld = (parkedAt: heldAt, notedAt: now())
            }
        }
        endTurn()
    }

    // MARK: - Marks

    static func mark(_ stage: TurnTimeline.Stage, at time: Date? = nil) {
        guard let id = targetID else { return }
        ledger.mark(id, stage, at: time ?? now())
    }

    /// Record the turn's first streamed token.
    ///
    /// Separate from `mark(.firstToken)` because this one is called on every delta of a fast stream,
    /// and the timeline's own first-wins check sits behind a dictionary lookup and a struct copy.
    /// The local flag makes every token after the first a single boolean test.
    static func markFirstToken() {
        guard !sawFirstToken, targetID != nil else { return }
        sawFirstToken = true
        mark(.firstToken)
    }

    // MARK: - Tags and accumulated spans

    /// Apply an arbitrary mutation to the current turn — the escape hatch for anything
    /// `TurnTimeline`'s own mutating API already expresses.
    static func update(_ mutate: (inout TurnTimeline) -> Void) {
        guard let id = targetID else { return }
        ledger.update(id, mutate)
    }

    /// Which pipeline and which model are about to serve this turn.
    ///
    /// Read at dispatch, never afterwards: `sendMessageCascading` restores the pre-turn active model
    /// in a `defer` before it returns, so anything that asks *after* the turn names the model that
    /// did not answer. Tags are last-wins, so a cascade's final attempt is the one that sticks —
    /// which is also why `update`'s off-turn gate matters here more than anywhere else: this is the
    /// cohort key, and a background completion re-tagging it files the turn under a backend that
    /// never served it.
    static func noteBackend(_ backend: TurnBackend, model: String?) {
        update {
            $0.backend = backend
            $0.model = model
        }
    }

    /// Which signal ended the wearer's speech (Plan CU P2). Recorded against the *pending*
    /// utterance rather than the turn, because the endpointer decides before `beginTurn()` runs —
    /// the same reason `noteSpeechEnd` works that way.
    static func noteEndOfTurnReason(_ reason: EndOfTurnPolicy.Reason) {
        pendingEndOfTurnReason = reason
    }

    /// Seconds spent waiting on a frame from the glasses, timed from `start`.
    static func addFrameGrabTime(since start: Date) {
        update { $0.addFrameGrabTime(now().timeIntervalSince(start)) }
    }

    /// One tool round trip, timed from `start`.
    static func addToolTime(since start: Date) {
        update { $0.addToolTime(now().timeIntervalSince(start)) }
    }

    /// App-side work inside the backend leg — a spoken model-switch notice, a cold location fix —
    /// timed from `start`. See `TurnTimeline.nonModelSeconds` for why it is held apart.
    static func addNonModelTime(since start: Date) {
        update { $0.addNonModelTime(now().timeIntervalSince(start)) }
    }

    /// One generation pass as the backend reported it — the only pair `tokensPerSecond` accepts.
    static func addGeneration(tokens: Int, seconds: TimeInterval) {
        update { $0.addGeneration(tokens: tokens, seconds: seconds) }
    }

    /// The turn never delivered: a backend error, a cancellation, a supersession.
    static func noteAbandoned() {
        update { $0.abandoned = true }
    }

    /// The wearer barged in over playback.
    static func noteInterrupted() {
        update { $0.interrupted = true }
    }

    // MARK: - Speech hand-off
    //
    // The speech marks cannot simply hang off `TextToSpeechService.speak`, because a turn speaks
    // more than its reply: `narrateModelSwitch` says "switching to Groq" while the model is still
    // generating, and that utterance would claim `firstAudio` — the exact mark the headline metric
    // ends at, and the one every stage before it is measured against. So the turn path opens a
    // window when it hands *the reply* to the engine, and the TTS and HUD marks below only land
    // while that window is open.

    /// The turn's reply is going to the speech engine now.
    static func handOffToSpeech(at time: Date? = nil) {
        guard targetID != nil else { return }
        speechHandedOff = true
        mark(.ttsRequested, at: time)
    }

    /// Which engine of the ElevenLabs → Kokoro → iOS chain actually spoke. Not the configured
    /// preference: any engine in the chain can fall through to the next at runtime (no network, no
    /// quota, no model), and a cloud round trip and an on-device synthesis are not comparable
    /// numbers.
    static func noteSpeechEngine(_ engine: TTSEngine) {
        guard speechHandedOff else { return }
        update { $0.ttsEngine = engine }
    }

    /// Audio started reaching the wearer — where `perceivedLatency` ends.
    static func markPlaybackStart(at time: Date) {
        guard speechHandedOff else { return }
        mark(.firstAudio, at: time)
    }

    /// Playback finished.
    ///
    /// Does *not* close the hand-off window — `beginTurn`/`endTurn` do that. The HUD mirror is
    /// enqueued at the top of `speak` but rendered by a queue that can be slower than the audio it
    /// accompanies, and closing here would drop the lens mark on exactly the slow link that made it
    /// worth measuring. Every mark inside the window is first-wins, so leaving it open until the
    /// turn ends costs nothing.
    static func markPlaybackEnd(at time: Date) {
        guard speechHandedOff else { return }
        mark(.spokeDone, at: time)
    }

    /// The reply reached the lens. Marked where content actually reaches the display backend, not
    /// where it was requested — the render queue is latest-wins, so a requested frame can be
    /// superseded and never rendered at all.
    static func markHUDRendered(at time: Date) {
        guard speechHandedOff else { return }
        mark(.hudRendered, at: time)
    }

    // MARK: - Internals

    /// Which mic route this turn is actually being captured on.
    ///
    /// Not `Config.micRoute`: that is a preference, and `WakeWordService.preferConfiguredMicIfAvailable`
    /// leaves capture on the phone whenever the preferred port is absent — glasses flat, asleep, or
    /// out of range — and says so in the log. Tagging those turns `.glasses` would put 8 kHz HFP
    /// samples and 48 kHz phone-mic ones in one cohort and report a median describing neither, which
    /// is the pooling `TurnTimeline.Cohort` exists to make impossible. The session's live input is
    /// the observation; the preference is the fallback only when there is no input port to read.
    private static func resolvedMicRoute() -> MicRoute? {
        MicRoutePolicy.resolvedRoute(from: micRoutePorts()) ?? Config.micRoute
    }

    /// Point the recorder at a ledger, clock, and route the caller controls, and drop every scrap of
    /// per-turn state. Tests only.
    ///
    /// The recorder's own decisions are the half of Plan CU P1 that determines whether the pure
    /// core's invariants mean anything in production — which utterance a turn claims, the staleness
    /// ceilings, the hand-off window that stops a model-switch notice claiming `firstAudio`. None of
    /// them is reachable without a way to start from a known state, and every one of them can be
    /// mutated away with the whole suite still green if it is not pinned.
    /// Each argument is optional rather than defaulted to the production value because a default
    /// argument is evaluated outside the main actor, and both of those values are isolated to it.
    static func reset(ledger: TurnLedger? = nil,
                      now: (() -> Date)? = nil,
                      micRoutePorts: MicRoutePortsReader? = nil) {
        self.ledger = ledger ?? TurnLedger()
        self.now = now ?? { Date() }
        self.micRoutePorts = micRoutePorts ?? liveMicRoutePorts
        enabled = true
        currentID = nil
        sawFirstToken = false
        speechHandedOff = false
        pendingSpeechEndAt = nil
        pendingEndOfTurnReason = nil
        pendingHeld = nil
    }
}

extension TurnLedger {
    /// The app's one ledger, under the name a view reaches for. Same object as
    /// `TurnRecorder.ledger` — the recorder owns it, because a ledger with no recorder writing to
    /// it is an empty panel.
    static var shared: TurnLedger { TurnRecorder.ledger }
}
