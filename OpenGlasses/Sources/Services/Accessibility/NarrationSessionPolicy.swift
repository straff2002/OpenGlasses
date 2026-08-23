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

    /// Something that overrides what the wearer asked for. Two kinds, and the difference matters:
    /// one takes the ear, the other takes the whole loop.
    enum Interruption: String, Equatable, CaseIterable {
        /// The wearer asked something and the answer owns the floor. A scene description cutting
        /// into a reply is worse than no description at all.
        case userTurn
        /// A live realtime voice session — two voices in the ear is chaos.
        case realtimeSession
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
            case .userTurn, .realtimeSession: return false
            case .backgrounded, .cameraUnavailable: return true
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

        static let off = State(mode: .off, isPerceiving: false, isSpeaking: false, haltReason: nil)
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

    /// The result of applying an event: the two states, plus the two things the caller has to act
    /// on beyond simply starting or stopping the loop.
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
            return State(mode: .off, isPerceiving: false, isSpeaking: false, haltReason: blocking)
        }
        if !interruptions.isEmpty {
            // Speech-only interruption: keep watching, stay quiet.
            return State(mode: .watching, isPerceiving: true, isSpeaking: false, haltReason: nil)
        }
        return State(mode: requestedMode,
                     isPerceiving: true,
                     isSpeaking: requestedMode == .narrating,
                     haltReason: nil)
    }

    /// The halting interruption to report, picked in `allCases` order so the reason is stable when
    /// two are active at once.
    private var blockingInterruption: Interruption? {
        Interruption.allCases.first { interruptions.contains($0) && $0.haltsPerception }
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
                ? from.haltReason : nil
        )
    }

    /// Clear everything, including the environment flags (a fresh session, not a resume).
    mutating func reset() {
        requestedMode = .off
        interruptions = []
    }
}
