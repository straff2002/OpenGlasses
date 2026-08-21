import Foundation

/// Which pipeline answered a turn (Plan CU P1 tag).
///
/// Direct mode carries its provider because a Groq turn and an on-device MLX turn share the code
/// path and nothing else. The two realtime backends are separate cases rather than providers
/// because they endpoint server-side — their `commitAt` means something different, and pooling
/// them with Direct mode would average away the one comparison worth having.
enum TurnBackend: Hashable {
    case direct(LLMProvider)
    /// **Not produced yet.** `GeminiLiveSessionManager` has no turn boundaries wired to
    /// `TurnRecorder`, so no realtime turn is recorded and this case is unreachable in the app.
    /// Kept — with the grouping rule that goes with it — because P1's deliverable is the taxonomy,
    /// and the Direct-vs-realtime comparison the plan calls "the most useful baseline we have"
    /// needs the case to exist before the session managers can be taught to fill it.
    case geminiLive
    /// **Not produced yet** — see `geminiLive`.
    case openAIRealtime

    /// Compact form. This is a grouping key before it is a label, so it stays stable and terse.
    var label: String {
        switch self {
        case .direct(let provider): return provider.rawValue
        case .geminiLive: return "geminiLive"
        case .openAIRealtime: return "openAIRealtime"
        }
    }
}

/// Plan CU P1 — the marks of one voice turn, and the durations derived from them.
///
/// We could not previously verify a single latency claim about this app: `SubsystemTestRunner`
/// covers cold-start probes and nothing measured a live turn. Slowness was attributed by feel, and
/// feel gets this exactly wrong — a fixed endpointing window is identical on every turn, so it
/// reads as "the app's speed" rather than as one stage you could delete.
///
/// Pure value type: no `Date()` inside, no I/O, no singletons. Time is injected at every mark, so
/// each derivation below is a fixture test rather than a stopwatch session.
///
/// **Every stage is optional and stays optional.** A turn can stop anywhere — barge-in,
/// supersession, a backend error — and the partial timeline is still the most informative thing we
/// have about that turn. Nothing here requires a turn to have finished, or even to have spoken.
struct TurnTimeline: Identifiable, Equatable {

    /// The nine marks, in canonical order. `allCases` *is* that order, so a panel can walk it.
    enum Stage: String, CaseIterable {
        /// Utterance parked by `TurnAdmissionPolicy.deferToQueue` while another turn was in flight.
        case held
        /// The mic went quiet — the end-of-turn decision point, and where perceived latency starts.
        case speechEnd
        /// Handed to a backend.
        case commit
        /// The backend produced its first output — *"is the model slow?"*
        case firstToken
        /// The model finished the reply.
        case generationDone
        /// Text handed to the speech engine.
        case ttsRequested
        /// The wearer actually hears something — perceived latency ends here.
        case firstAudio
        /// The reply mirrored to the lens.
        case hudRendered
        /// Playback finished.
        case spokeDone

        var label: String {
            switch self {
            case .held: return "Held"
            case .speechEnd: return "Speech end"
            case .commit: return "Commit"
            case .firstToken: return "First token"
            case .generationDone: return "Generation done"
            case .ttsRequested: return "TTS requested"
            case .firstAudio: return "First audio"
            case .hudRendered: return "HUD rendered"
            case .spokeDone: return "Playback done"
            }
        }
    }

    /// The tuple aggregates are grouped by, and the reason the ledger never reports a pooled mean.
    ///
    /// An 8 kHz Bluetooth HFP mic and the phone's 48 kHz mic are two populations for every timing
    /// here. So are a cloud TTS whose first byte crosses a network and an on-device one that
    /// synthesises on the GPU — and Kokoro on the GPU measurably slows local decode, so even tok/s
    /// is comparable only *within* one engine. An average across them describes neither.
    struct Cohort: Hashable {
        let backend: TurnBackend?
        let ttsEngine: TTSEngine?
        let micRoute: MicRoute?
    }

    /// One gap between consecutive marks, labelled by the stage it ends at.
    struct Segment: Equatable, Identifiable {
        let stage: Stage
        let seconds: TimeInterval
        var id: Stage { stage }
    }

    let id: UUID

    // MARK: - Marks
    //
    // Marks are **first-wins**: `mark(.firstToken, …)` called on every streamed delta records only
    // the first, which is the one every derivation here is about. The tags below are last-wins for
    // the opposite reason — a model name or a TTS engine is a fact about the turn that is often
    // only settled once the fallback chain has stopped falling back.

    private(set) var heldAt: Date?
    private(set) var speechEndAt: Date?
    private(set) var commitAt: Date?
    private(set) var firstTokenAt: Date?
    private(set) var generationDoneAt: Date?
    private(set) var ttsRequestedAt: Date?
    private(set) var firstAudioAt: Date?
    private(set) var hudRenderedAt: Date?
    private(set) var spokeDoneAt: Date?

    // MARK: - Tags

    var backend: TurnBackend?
    var model: String?
    var ttsEngine: TTSEngine?
    var micRoute: MicRoute?

    /// The turn never delivered — a backend error, a supersession, a wearer who walked away.
    var abandoned: Bool
    /// The wearer barged in over playback. Deliberately distinct from `abandoned`: this turn worked
    /// and its stage times are sound data, the wearer simply stopped wanting the rest of it.
    var interrupted: Bool

    // MARK: - Accumulated spans
    //
    // These sit *inside* the marked stages and have to be visible separately, or the marks lie
    // about the most common turn shapes we have.

    /// Seconds spent waiting on a frame from the glasses. Falls inside commit → firstToken.
    private(set) var frameGrabSeconds: TimeInterval
    /// Seconds spent executing tools, accumulated across the whole tool loop.
    private(set) var toolSeconds: TimeInterval
    /// How many tool round trips this turn took.
    private(set) var toolIterations: Int
    /// Seconds this utterance spent parked by `TurnAdmissionPolicy` before its own turn began.
    private(set) var heldSeconds: TimeInterval
    /// Seconds inside the backend leg that the app spent on its own work rather than on the model.
    ///
    /// Two contributors today, and the rule generalises to any third: the spoken model-switch
    /// notice (`narrateModelSwitch` blocks until the whole "switching to Groq" utterance has
    /// *played*, 2–4 s, mid-cascade) and the cold location fix (up to 1.5 s, after commit and
    /// before the backend is touched). Neither is a tool call and neither is a frame grab, so
    /// without a bucket of their own they land in `modelSeconds` and in TTFT and read as a slow
    /// model — the same mis-attribution `toolSeconds` exists to prevent, one layer over, and it
    /// fires exactly when someone is looking at the panel. **Any `await` between `commit` and the
    /// backend call that isn't the model belongs here.**
    private(set) var nonModelSeconds: TimeInterval

    /// Output tokens as **reported by the backend**, accumulated across every generation pass.
    private(set) var tokenCount: Int
    /// Decode time as **reported by the backend**, accumulated across every generation pass.
    ///
    /// Not the same quantity as the mark-derived `modelSeconds`, and never interchangeable with it:
    /// this one pairs with `tokenCount` and is the only input `tokensPerSecond` will accept.
    private(set) var generationSeconds: TimeInterval

    init(id: UUID = UUID(),
         backend: TurnBackend? = nil,
         model: String? = nil,
         ttsEngine: TTSEngine? = nil,
         micRoute: MicRoute? = nil,
         abandoned: Bool = false,
         interrupted: Bool = false) {
        self.id = id
        self.backend = backend
        self.model = model
        self.ttsEngine = ttsEngine
        self.micRoute = micRoute
        self.abandoned = abandoned
        self.interrupted = interrupted
        self.frameGrabSeconds = 0
        self.toolSeconds = 0
        self.toolIterations = 0
        self.heldSeconds = 0
        self.nonModelSeconds = 0
        self.tokenCount = 0
        self.generationSeconds = 0
    }

    // MARK: - Recording

    /// Record `stage` at `time`. First-wins — a repeated mark is a later event of the same kind,
    /// and the first is the one the metric names.
    mutating func mark(_ stage: Stage, at time: Date) {
        switch stage {
        case .held: if heldAt == nil { heldAt = time }
        case .speechEnd: if speechEndAt == nil { speechEndAt = time }
        case .commit: if commitAt == nil { commitAt = time }
        case .firstToken: if firstTokenAt == nil { firstTokenAt = time }
        case .generationDone: if generationDoneAt == nil { generationDoneAt = time }
        case .ttsRequested: if ttsRequestedAt == nil { ttsRequestedAt = time }
        case .firstAudio: if firstAudioAt == nil { firstAudioAt = time }
        case .hudRendered: if hudRenderedAt == nil { hudRenderedAt = time }
        case .spokeDone: if spokeDoneAt == nil { spokeDoneAt = time }
        }
    }

    /// Record one generation pass's reported output.
    ///
    /// Tokens and their window travel in one call because separating them *is* the bug. A tool turn
    /// runs the model more than once, and an API that lets a caller add pass 2's tokens without
    /// pass 2's window will eventually be called exactly that way — which is how a turn ends up
    /// reporting pass 2's token count over pass 1's time. Both accumulate, so `tokensPerSecond`
    /// always divides the whole turn's tokens by the whole turn's decode time.
    mutating func addGeneration(tokens: Int, seconds: TimeInterval) {
        tokenCount += max(0, tokens)
        generationSeconds += max(0, seconds)
    }

    /// Record one tool round trip. `iterations` defaults to one because the common case is one call
    /// per round trip; pass the real count when a round trip fanned out.
    mutating func addToolTime(_ seconds: TimeInterval, iterations: Int = 1) {
        toolSeconds += max(0, seconds)
        toolIterations += max(0, iterations)
    }

    /// Record time spent waiting on a frame. Accumulates — a multi-image turn grabs more than one.
    mutating func addFrameGrabTime(_ seconds: TimeInterval) {
        frameGrabSeconds += max(0, seconds)
    }

    /// Record time this utterance spent parked by `TurnAdmissionPolicy`.
    ///
    /// Recorded rather than derived from `heldAt → speechEndAt`, because the release is where the
    /// duration is exactly known and an abandoned turn can lose either mark without losing the fact
    /// that it waited.
    mutating func addHoldTime(_ seconds: TimeInterval) {
        heldSeconds += max(0, seconds)
    }

    /// Record app-side work that ran inside the backend leg. Accumulates — a cascade can narrate
    /// once and still have waited on a location fix before it started.
    mutating func addNonModelTime(_ seconds: TimeInterval) {
        nonModelSeconds += max(0, seconds)
    }

    // MARK: - Access

    /// The mark for `stage`, or `nil` if it never landed.
    subscript(stage: Stage) -> Date? {
        switch stage {
        case .held: return heldAt
        case .speechEnd: return speechEndAt
        case .commit: return commitAt
        case .firstToken: return firstTokenAt
        case .generationDone: return generationDoneAt
        case .ttsRequested: return ttsRequestedAt
        case .firstAudio: return firstAudioAt
        case .hudRendered: return hudRenderedAt
        case .spokeDone: return spokeDoneAt
        }
    }

    /// The turn's place on the wall clock: the first mark in canonical order that landed.
    var startedAt: Date? {
        Stage.allCases.compactMap { self[$0] }.first
    }

    var cohort: Cohort {
        Cohort(backend: backend, ttsEngine: ttsEngine, micRoute: micRoute)
    }

    /// The landed marks reduced to consecutive gaps — the panel's stage breakdown.
    ///
    /// Stages that never landed are absorbed into the following segment rather than reported as
    /// zero. A non-streaming backend has no first token of its own, and a zero-width bar there
    /// would read as *"that stage was instant"* when it means *"we never saw it"*. Segments stay
    /// signed so a backwards mark shows up in the breakdown instead of being quietly smoothed away.
    var segments: [Segment] {
        var result: [Segment] = []
        var previous: Date?
        for stage in Stage.allCases {
            guard let at = self[stage] else { continue }
            if let previous {
                result.append(Segment(stage: stage, seconds: at.timeIntervalSince(previous)))
            }
            previous = at
        }
        return result
    }

    // MARK: - Derived: the headline

    /// **speechEnd → firstAudio.** Everything inside it is dead air from the wearer's point of
    /// view, and it is the number Plan CU exists to move.
    ///
    /// Measured from *this turn's* speech end, never from `heldAt`. A deferred utterance was parked
    /// before its own turn began, so charging that wait to the pipeline would make every held turn
    /// look like a backend problem. `heldSeconds` and `waitIncludingHold` carry it separately.
    var perceivedLatency: TimeInterval? { Self.span(speechEndAt, firstAudioAt) }

    /// What the wearer actually waited when their words were parked: the hold plus this turn's own
    /// latency. Reported *next to* `perceivedLatency`, never instead of it — one is the wearer's
    /// experience, the other is what the pipeline is answerable for.
    var waitIncludingHold: TimeInterval? {
        guard let perceived = perceivedLatency else { return nil }
        return heldSeconds + perceived
    }

    // MARK: - Derived: stage spans

    /// speechEnd → commit. Today this is almost entirely the silence window
    /// (`SpeechContinuationPolicy.baseWindow`) — the fixed floor P2 exists to remove.
    var endpointingDelay: TimeInterval? { Self.span(speechEndAt, commitAt) }

    /// commit → firstToken, **including** any frame grab. Deliberately uncorrected: this is what
    /// the turn cost. Ask `modelTimeToFirstToken` about the model alone.
    var timeToFirstToken: TimeInterval? { Self.span(commitAt, firstTokenAt) }

    /// `timeToFirstToken` with the frame grab and the app's own work taken back out.
    ///
    /// A vision turn waits on the glasses' Bluetooth stream between commit and first token, so its
    /// raw TTFT contains seconds the model never saw. Compare that against a text turn's TTFT and
    /// the conclusion is *"the vision model is slow"* — the wrong model, and then the wrong fix.
    /// `nonModelSeconds` comes out for the same reason: a cold location fix or a spoken model-switch
    /// notice sits in the same window and belongs to neither the radio nor the model. Floored at
    /// zero: a negative here means the accounting overlapped the window, not that the model answered
    /// before it was asked.
    var modelTimeToFirstToken: TimeInterval? {
        guard let ttft = timeToFirstToken else { return nil }
        return max(0, ttft - frameGrabSeconds - nonModelSeconds)
    }

    /// commit → generationDone: the whole backend leg, tool round trips and frame grab included.
    var backendSeconds: TimeInterval? { Self.span(commitAt, generationDoneAt) }

    /// `backendSeconds` with the non-model work removed — tool execution, the frame grab, and the
    /// app's own work inside the leg.
    ///
    /// We have 36+ native tools behind `ToolLoopDriver`, so one turn is routinely several LLM round
    /// trips with execution between them. Uncorrected, a turn that spent four seconds inside a
    /// HomeKit call reports four seconds of model latency and we go and optimise the model.
    var modelSeconds: TimeInterval? {
        guard let backend = backendSeconds else { return nil }
        return max(0, backend - toolSeconds - frameGrabSeconds - nonModelSeconds)
    }

    /// generationDone → firstAudio, **signed on purpose**.
    ///
    /// Negative is the good case: speech started while the model was still generating, which is the
    /// entire point of sentence-streaming TTS. Every other span here clamps a backwards result to
    /// `nil`, because backwards usually means clock skew. This one must not — clamping would delete
    /// the metric on exactly the turns it exists to characterise, and "no lead-in recorded" would
    /// be indistinguishable from "TTS never started".
    ///
    /// **Not reachable as the app is wired today, and that is worth saying out loud.** Every Direct
    /// mode spine hands the *whole* reply to the speech engine after `generationDone`, and
    /// `TurnRecorder.markPlaybackStart` only accepts audio once that hand-off has happened — so
    /// every recorded turn currently reports a positive lead-in. The signed form is kept because it
    /// is the metric a streaming hand-off is judged by, not because P1 can already produce one;
    /// reading a panel full of positives as "sentence streaming is off" would be the wrong
    /// conclusion from the right number.
    var ttsLeadIn: TimeInterval? {
        guard let from = generationDoneAt, let to = firstAudioAt else { return nil }
        return to.timeIntervalSince(from)
    }

    /// ttsRequested → firstAudio — *how slow is synthesis?*, which is a different question from
    /// `ttsLeadIn` and answered by a different pair of marks.
    ///
    /// On a streamed reply the first sentence reaches the engine long before generation ends, so
    /// lead-in goes negative while this stays firmly positive. Reading either one as the other is
    /// the mistake the separation exists to prevent.
    var ttsTimeToFirstByte: TimeInterval? { Self.span(ttsRequestedAt, firstAudioAt) }

    /// firstAudio → spokeDone.
    var playbackSeconds: TimeInterval? { Self.span(firstAudioAt, spokeDoneAt) }

    /// speechEnd → hudRendered: `perceivedLatency` for the wearer reading the lens rather than
    /// listening. On Display glasses the two channels can diverge by seconds.
    var hudLatency: TimeInterval? { Self.span(speechEndAt, hudRenderedAt) }

    /// speechEnd → spokeDone: the turn end to end.
    var totalSeconds: TimeInterval? { Self.span(speechEndAt, spokeDoneAt) }

    // MARK: - Derived: generation rate

    /// Below this, a decode window is not a measurement.
    ///
    /// Not a filter on fast turns — even a local pass that emits four tokens occupies far more than
    /// this. It catches the window that is effectively zero, where the division reports millions of
    /// tokens per second and someone believes it.
    static let minimumRateWindow: TimeInterval = 0.05

    /// Tokens per second, from the backend-reported pair only: `tokenCount` over
    /// `generationSeconds`, both accumulated across every pass of the turn.
    ///
    /// **Never from the marks.** Marks are first-wins and get backfilled for non-streaming
    /// backends, so a rate taken from `firstTokenAt → generationDoneAt` can silently cover a
    /// different span than the tokens it divides. Two failure modes live here and each costs a bug
    /// to learn: a microsecond window dividing into millions of tok/s, and pass 2's token count
    /// paired with pass 1's window. Accumulation defeats the second, `minimumRateWindow` the first.
    /// Returning `nil` is the point — **no rate is better than a fictional one.**
    var tokensPerSecond: Double? {
        guard tokenCount > 0, generationSeconds >= Self.minimumRateWindow else { return nil }
        return Double(tokenCount) / generationSeconds
    }

    // MARK: - Internals

    /// Clamps a backwards span to `nil`. These marks sit on the wall clock and the wall clock can
    /// step backwards, so a negative span is far likelier to be skew or an out-of-order mark than a
    /// real ordering. `ttsLeadIn` is the one deliberate exception and computes its own.
    private static func span(_ from: Date?, _ to: Date?) -> TimeInterval? {
        guard let from, let to else { return nil }
        let seconds = to.timeIntervalSince(from)
        return seconds >= 0 ? seconds : nil
    }
}
