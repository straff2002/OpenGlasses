import Foundation

/// What the narration loop is doing right now.
///
/// `.watching` is the default and the point: perception is **context**, not narration. The loop
/// watches without speaking and the descriptions accumulate as grounding, so a later *"what's
/// that?"* is answered against a scene the model has already looked at instead of paying a fresh
/// capture-and-describe round trip. Speech is a separate, explicit mode — continuous narration is
/// a specific accessibility need, not a default anyone would want — which keeps the expensive half
/// opt-in and the cheap half universal.
enum NarrationMode: String, Equatable, CaseIterable {
    /// Not watching at all.
    case off
    /// Watching silently; descriptions accumulate as grounding context.
    case watching
    /// Watching and speaking.
    case narrating
}

/// The mode state machine for continuous scene narration (Plan CV P1): what "start narrating" and
/// "stop narrating" do, and what happens when something else needs the ear or the camera.
///
/// Pure value type — no clock, no services, no I/O. It answers three questions the loop asks every
/// tick: should we be perceiving, may we speak, and does the wearer need to be told why not.
struct NarrationSessionPolicy: Equatable {

    /// Something that overrides what the wearer asked for. Two axes, and both matter:
    /// `haltsPerception` says whether it takes the ear or the whole loop, and
    /// `isStandingCondition` says whether the wearer needs to be told it happened.
    enum Interruption: String, Equatable, CaseIterable {
        /// The wearer asked something and the answer owns the floor. A scene description cutting
        /// into a reply is worse than no description at all.
        case userTurn
        /// A live realtime voice session — two voices in the ear is chaos.
        case realtimeSession
        /// Live ambient captions are running (Plan CV, caption/narration arbitration).
        ///
        /// Captions and narration are not, as it turned out, two streams fighting for one ear —
        /// `AmbientCaptionService` never speaks; it writes the phone overlay and the in-lens HUD.
        /// Narration yields anyway, for two reasons that survive that correction:
        ///
        /// 1. **The transcript.** Narration speaks over the same shared audio engine the caption
        ///    recognizer listens on, and that path runs `.playAndRecord`/`.default` with no voice
        ///    processing — so narration's own voice is transcribed as if a person in the room had
        ///    said it, and flows on into summaries, the Spotlight index and Brain. That is silent
        ///    corruption of a record, which is worse than noise because nobody can hear it happen.
        /// 2. **Attention.** Captions are language and narration is language. The channels are
        ///    physically separate; the wearer's language faculty is not, and nobody reads one
        ///    sentence while hearing a different one.
        ///
        /// Captions win rather than narration because a caption is *another person talking* —
        /// time-critical and unrepeatable — while a description of a room is neither, and if the
        /// room does change `FrameGate` will notice and describe the new one. Narration is the
        /// self-healing half of the pair.
        case ambientCaptions
        /// The app is backgrounded or the phone is locked. On-device MLX cannot run there, so
        /// perception genuinely stops rather than merely going quiet.
        case backgrounded
        /// No live camera frames (glasses without a streaming tier, camera unavailable).
        case cameraUnavailable

        /// Whether perception stops too, or only speech.
        ///
        /// The speech-only ones keep watching deliberately: grounding context is the cheap half
        /// and there is no reason to lose it because the wearer asked a question.
        var haltsPerception: Bool {
            switch self {
            case .userTurn, .realtimeSession, .ambientCaptions: return false
            case .backgrounded, .cameraUnavailable: return true
            }
        }

        /// Whether this is a **standing condition** rather than a moment the wearer created.
        ///
        /// The distinction is the one that decides whether silence needs explaining, and it is a
        /// different axis from `haltsPerception`. `.userTurn` and `.realtimeSession` are moments:
        /// the wearer started them, they end on their own, and the wearer hears them end — a
        /// spoken "narration paused" there would be the app narrating its own bookkeeping. A
        /// standing condition can silence narration for an entire walk with nothing for the
        /// wearer to attribute the silence to, which is the failure P3 exists to prevent.
        var isStandingCondition: Bool {
            switch self {
            case .userTurn, .realtimeSession: return false
            case .ambientCaptions, .backgrounded, .cameraUnavailable: return true
            }
        }
    }

    /// What the wearer asked for, and what actually follows from it.
    struct State: Equatable {
        let mode: NarrationMode
        /// Whether the capture-and-describe loop should be running.
        let isPerceiving: Bool
        /// Whether narration may put an utterance on the floor.
        let isSpeaking: Bool
        /// Non-nil when perception is halted by something the wearer did not ask for.
        let haltReason: Interruption?
        /// `haltReason`'s quieter sibling: non-nil when the wearer asked to be narrated to and the
        /// loop is still watching, but a **standing condition** has taken the ear.
        ///
        /// Only ever set for a requested mode of `.narrating` — you cannot be silenced if you were
        /// not going to speak — and never for the moment-shaped interruptions, which end on their
        /// own and need no explanation.
        let silenceReason: Interruption?

        static let off = State(mode: .off, isPerceiving: false, isSpeaking: false,
                               haltReason: nil, silenceReason: nil)
    }

    enum Event: Equatable {
        /// Enter the mode. Lands in `.watching` — silent — by design.
        case start
        case startNarrating
        /// Back to silent watching; grounding continues.
        case stopNarrating
        /// Leave the mode entirely.
        case stop
        case interruption(Interruption, active: Bool)
    }

    /// The result of applying an event: the two states, plus everything the caller has to act on
    /// beyond simply starting or stopping the loop — the queue flush, and the two grades of
    /// explanation the wearer may be owed (a halt took the loop; a standing condition took only
    /// the ear).
    struct Transition: Equatable {
        let from: State
        let to: State
        /// Drop anything queued for speech now. Whatever was waiting is stale by the time the ear
        /// is free again, and a description of a room the wearer has already left, delivered late,
        /// is worse than the silence it replaced.
        let flushSpeechQueue: Bool
        /// Perception just stopped for a reason the wearer must be told.
        ///
        /// For someone *relying* on narration, silence that isn't explained is indistinguishable
        /// from silence because nothing changed — the worst failure this feature has available.
        /// Plan CV P3 renders the copy; the policy only decides that it is owed.
        let haltBegan: Interruption?
        /// Perception just resumed after such a halt.
        let haltEnded: Interruption?
        /// A standing condition just took the ear while the loop kept watching. Same debt as
        /// `haltBegan`, smaller in scope: the wearer asked for descriptions and stopped getting
        /// them, and nothing they did in that moment explains it.
        let silenceBegan: Interruption?
        /// That standing condition just cleared and narration may speak again.
        let silenceEnded: Interruption?

        var didChange: Bool { from != to }
    }

    /// What the wearer last asked for. Interruptions never overwrite it, so clearing one restores
    /// the mode rather than dropping the wearer somewhere they didn't choose.
    private(set) var requestedMode: NarrationMode = .off
    private(set) var interruptions: Set<Interruption> = []

    init() {}

    /// The effective state: the requested mode with the active interruptions applied.
    var state: State {
        guard requestedMode != .off else { return .off }

        if let blocking = blockingInterruption {
            return State(mode: .off, isPerceiving: false, isSpeaking: false,
                         haltReason: blocking, silenceReason: nil)
        }
        if !interruptions.isEmpty {
            // Speech-only interruption: keep watching, stay quiet.
            return State(mode: .watching, isPerceiving: true, isSpeaking: false,
                         haltReason: nil, silenceReason: silencingCondition)
        }
        return State(mode: requestedMode,
                     isPerceiving: true,
                     isSpeaking: requestedMode == .narrating,
                     haltReason: nil,
                     silenceReason: nil)
    }

    /// The halting interruption to report, picked in `allCases` order so the reason is stable when
    /// two are active at once.
    private var blockingInterruption: Interruption? {
        Interruption.allCases.first { interruptions.contains($0) && $0.haltsPerception }
    }

    /// The standing ear-only condition to report, or nil. Gated on `.narrating` because being
    /// silenced only means something to a wearer who asked to be spoken to; a watching wearer was
    /// already silent by design and owes nobody an explanation for it.
    private var silencingCondition: Interruption? {
        guard requestedMode == .narrating else { return nil }
        return Interruption.allCases.first {
            interruptions.contains($0) && !$0.haltsPerception && $0.isStandingCondition
        }
    }

    // MARK: - Events

    @discardableResult
    mutating func apply(_ event: Event) -> Transition {
        let from = state

        switch event {
        case .start:
            // Silent by default: entering the mode never starts speaking on its own.
            if requestedMode == .off { requestedMode = .watching }
        case .startNarrating:
            requestedMode = .narrating
        case .stopNarrating:
            // Back to grounding, not off — the cheap half keeps running.
            if requestedMode == .narrating { requestedMode = .watching }
        case .stop:
            // Interruptions are facts about the world, not state we own, so they stay set. With
            // `.off` requested they can't resurrect the session when they clear.
            requestedMode = .off
        case let .interruption(interruption, active):
            if active { interruptions.insert(interruption) } else { interruptions.remove(interruption) }
        }

        let to = state
        return Transition(
            from: from,
            to: to,
            flushSpeechQueue: from.isSpeaking && !to.isSpeaking,
            haltBegan: to.haltReason != nil && to.haltReason != from.haltReason ? to.haltReason : nil,
            // Not a resumption when the wearer is the one who stopped it.
            haltEnded: from.haltReason != nil && to.haltReason == nil && to.mode != .off
                ? from.haltReason : nil,
            silenceBegan: to.silenceReason != nil && to.silenceReason != from.silenceReason
                ? to.silenceReason : nil,
            // Keyed on the *requested* mode rather than `to.mode != .off`, because the wearer
            // saying "stop narrating" clears the silence too — and that is them choosing quiet,
            // not narration coming back.
            silenceEnded: from.silenceReason != nil && to.silenceReason == nil
                && requestedMode == .narrating ? from.silenceReason : nil
        )
    }

    /// Clear everything, including the environment flags (a fresh session, not a resume).
    mutating func reset() {
        requestedMode = .off
        interruptions = []
    }
}
