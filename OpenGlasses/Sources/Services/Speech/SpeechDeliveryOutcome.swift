import Foundation

/// How one spoken utterance actually ended (Plan FE P4).
///
/// `TextToSpeechService.speak` returns `Void`, so every caller that wanted to know whether the
/// wearer got the words had to assume they did. This is the value that replaces the assumption.
///
/// **It is a terminal state.** There is deliberately no `queued` or `playing` case: a caller
/// awaiting this has already got past both, and a "queued" answer handed back from an `await`
/// would be a state that had ceased to be true by the time it was read. The queued/playing half
/// of the story lives where it belongs — in the delivery record kept by whoever asked for the
/// utterance (`AgentResultDelivery`), which is written *before* the await and updated after it.
///
/// **`completed` means playback ran to its end.** It does not mean the wearer heard it, was
/// wearing the glasses, was paying attention, or understood it. Nothing on this device can know
/// any of that, so nothing here claims it — which is the whole reason the type exists: an
/// acknowledgement sent to a backend on the strength of `completed` is an acknowledgement that
/// audio finished playing, and the wire contract says exactly that.
enum SpeechDeliveryOutcome: Equatable {
    /// Playback reached the end of the utterance.
    case completed
    /// Playback started (or was about to) and was cut short.
    case interrupted(by: Interruption)
    /// Nothing was played, and the reason was a route/policy decision rather than a fault.
    case suppressed(reason: SuppressionReason)
    /// Nothing was played, or playback broke, because something went wrong.
    case failed(reason: String)

    /// What cut an utterance short. Three causes rather than one flag, because "the wearer talked
    /// over it" and "the app tore the audio down" call for different follow-ups: the first means
    /// they chose not to hear the rest, the second means they never got the chance.
    enum Interruption: String, Equatable, Codable {
        /// The wearer spoke over the assistant.
        case bargeIn
        /// An explicit stop — a stop phrase, a control, a disconnect, a scene teardown.
        case stop
        /// A newer utterance replaced this one before (or during) playback.
        case newUtterance
    }

    /// Why an utterance was withheld. A suppression is not a failure: the app did the right thing,
    /// and the words are still owed to the wearer, which is why a suppressed result is replayable.
    enum SuppressionReason: String, Equatable, Codable {
        /// Output is muted for speech.
        case muted
        /// There is no permitted output route — today: glasses-only audio with no glasses on.
        case noRoute
        /// The wearer has the app in silent / push-to-talk mode.
        case silentMode
        /// The app is not in the foreground and this caller does not speak from the background.
        case backgrounded
    }

    /// Whether the utterance was played to its end. The only state an acknowledgement may be sent
    /// for, and still only as "audio finished", never as "they heard it".
    var isCompleted: Bool { self == .completed }

    /// Whether the words are still owed to the wearer — the replay condition.
    var owesReplay: Bool {
        switch self {
        case .interrupted, .suppressed: return true
        case .completed, .failed: return false
        }
    }

    /// A short, fixed token for the privacy log and the delivery record. Never carries the
    /// utterance or a system error message.
    var token: String {
        switch self {
        case .completed: return "completed"
        case .interrupted(let by): return "interrupted-\(by.rawValue)"
        case .suppressed(let reason): return "suppressed-\(reason.rawValue)"
        case .failed: return "failed"
        }
    }
}

/// The bookkeeping behind `SpeechDeliveryOutcome` (Plan FE P4): which utterance the engine
/// callbacks belong to, what each one ended as, and the rule that the **first** terminal state
/// wins.
///
/// It is a separate value for two reasons. The first is that the derivation is a decision table
/// and decision tables belong somewhere they can be read: `didCancel` alone does not know whether
/// the wearer talked over the answer or the app tore the audio down, and getting that wrong is the
/// difference between offering a replay and not. The second is testability — a simulator has no
/// speech engine and no audio route, so a test that could only exercise this through real playback
/// would exercise it nowhere.
struct SpeechDeliveryLedger {

    /// What an engine (or the code around it) reported about one utterance.
    enum EngineSignal: Equatable {
        /// `AVSpeechSynthesizerDelegate.didFinish` — the iOS voice reached the end.
        case systemFinished
        /// `AVSpeechSynthesizerDelegate.didCancel` — the synthesizer was stopped.
        case systemCancelled
        /// `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying`, with its own success flag.
        case playerFinished(success: Bool)
        /// `AVAudioPlayerDelegate.audioPlayerDecodeErrorDidOccur`.
        case playerDecodeFailed
        /// `AVAudioPlayer.play()` refused, so no delegate callback is coming.
        case playbackDidNotStart
        /// We stopped it, and we know why.
        case tornDown(SpeechDeliveryOutcome.Interruption)
        /// A newer utterance took the floor.
        case superseded
        /// The engine chain was cancelled between engines.
        case cancelledMidChain
        /// Every engine in the chain refused.
        case noEngineAvailable
        /// The route said not to play it at all.
        case withheld(SpeechDeliveryOutcome.SuppressionReason)
    }

    /// The generation the engine callbacks currently belong to. Distinct from the service's live
    /// `speechGeneration`, which a newer `speak` may already have claimed while a previous
    /// utterance's callback is still hopping to the main actor — the reason a late `didFinish`
    /// cannot mark a *successor* completed.
    private(set) var utteranceGeneration = 0

    /// Why the current teardown is happening, when this side caused it. Set before the teardown so
    /// the engine callback that follows can be attributed rather than guessed at.
    var teardownCause: SpeechDeliveryOutcome.Interruption?

    private var outcomes: [Int: SpeechDeliveryOutcome] = [:]

    /// Hand the engine callbacks to a new utterance.
    mutating func beginUtterance(generation: Int) {
        utteranceGeneration = generation
        teardownCause = nil
    }

    /// The decision table. Pure, so every branch can be read and asserted in one place.
    ///
    /// `teardownCause` only reaches the branches that need it — the ones where the engine is
    /// reporting *our* stop back to us and has no idea why it happened. `.newUtterance` is the
    /// fallback there because a cancellation with no recorded cause is a `speak` that replaced it.
    static func outcome(for signal: EngineSignal,
                        teardownCause: SpeechDeliveryOutcome.Interruption?) -> SpeechDeliveryOutcome {
        switch signal {
        case .systemFinished:
            return .completed
        case .playerFinished(let success):
            // The player's own flag. `false` means playback stopped short for a reason the player
            // owns — a failure, not a completion, and not an interruption we caused either.
            return success ? .completed : .failed(reason: "playback ended early")
        case .systemCancelled, .superseded:
            return .interrupted(by: teardownCause ?? .newUtterance)
        case .cancelledMidChain:
            return .interrupted(by: teardownCause ?? .stop)
        case .tornDown(let cause):
            return .interrupted(by: cause)
        case .playerDecodeFailed:
            return .failed(reason: "audio could not be decoded")
        case .playbackDidNotStart:
            return .failed(reason: "playback could not start")
        case .noEngineAvailable:
            return .failed(reason: "no speech engine was available")
        case .withheld(let reason):
            return .suppressed(reason: reason)
        }
    }

    /// Record a signal against the utterance the engine callbacks belong to.
    @discardableResult
    mutating func record(_ signal: EngineSignal, liveGeneration: Int) -> SpeechDeliveryOutcome? {
        record(signal, for: utteranceGeneration, liveGeneration: liveGeneration)
    }

    /// Record a signal against a named generation.
    ///
    /// Two guards, both load-bearing. A generation older than the one before the live one cannot
    /// matter any more and is dropped, which is what keeps this from growing. And the **first**
    /// terminal state wins: the teardown that caused an engine callback knows why it happened and
    /// the callback that follows does not, so the later one must never overwrite the earlier.
    @discardableResult
    mutating func record(_ signal: EngineSignal, for generation: Int,
                         liveGeneration: Int) -> SpeechDeliveryOutcome? {
        guard generation >= liveGeneration - 1 else { return nil }
        guard outcomes[generation] == nil else { return outcomes[generation] }
        let outcome = Self.outcome(for: signal, teardownCause: teardownCause)
        outcomes[generation] = outcome
        if outcomes.count > 4 { prune(liveGeneration: liveGeneration) }
        return outcome
    }

    /// What was recorded for a generation, if anything.
    func outcome(for generation: Int) -> SpeechDeliveryOutcome? { outcomes[generation] }

    /// Take the recorded outcome for a generation, or `fallback` when nothing recorded one.
    mutating func take(generation: Int, fallback: SpeechDeliveryOutcome,
                       liveGeneration: Int) -> SpeechDeliveryOutcome {
        let outcome = outcomes.removeValue(forKey: generation) ?? fallback
        prune(liveGeneration: liveGeneration)
        return outcome
    }

    private mutating func prune(liveGeneration: Int) {
        outcomes = outcomes.filter { $0.key >= liveGeneration - 1 }
    }
}
