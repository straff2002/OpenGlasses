import Foundation

/// Plan GU §3 — what handing the audio session back after a conversation may do.
///
/// The only call that tells a paused Podcasts or Music to resume is a **deactivation** with
/// `.notifyOthersOnDeactivation`. The old hand-back passed that option to `setActive(true)`, where
/// the SDK documents it as valid only on deactivation, so it did nothing and paused apps were never
/// told. Deactivating, though, ends everything on the session — so it is only safe when nothing
/// else is using it. Pure: the ledger's view and the tap's consumers in, a decision out.
enum HandBackDecision: Equatable {
    /// Wake word or dictation was the last owner and nothing else rides the session: stop the
    /// engine, deactivate with notify, and let the idle plan reactivate it.
    case deactivate
    /// Something still needs the session running, so it cannot be deactivated. Reconfigure in
    /// place to the idle (mixable) shape instead — the old behaviour, minus the HFP hold.
    case reconfigureInPlace(Reason)
    /// Another subsystem owns the session (a realtime session, an expert call). Not ours to touch.
    case leaveToOwner(AudioSessionOwner)

    enum Reason: Equatable {
        /// A coexisting rider is live: TTS still playing, the temple-tap claim's silent loop,
        /// live translation listening.
        case coexistingRider(AudioSessionOwner)
        /// Shared-tap consumers (a recording, captions, rewind) are still being fed by the engine.
        case sharedConsumers
    }

    /// Owners a conversation's hand-back may deactivate on behalf of.
    static let handBackOwners: Set<AudioSessionOwner> = [.wakeWord, .transcription]

    static func decide(owner: AudioSessionOwner?,
                       coexisting: [AudioSessionOwner],
                       sharedConsumersActive: Bool) -> HandBackDecision {
        if let owner, !handBackOwners.contains(owner) {
            return .leaveToOwner(owner)
        }
        if let rider = coexisting.first {
            return .reconfigureInPlace(.coexistingRider(rider))
        }
        if sharedConsumersActive {
            return .reconfigureInPlace(.sharedConsumers)
        }
        return .deactivate
    }
}

/// Plan GU §2 — where a turn's audio engine comes from, and whether the end of the turn must stop it.
///
/// Push-to-talk and listening-off turns used to start no shared engine (the listener refused to
/// start) and fell to `TranscriptionService`'s dedicated engine, which was silent on the glasses;
/// and the end of an explicit turn with listening off tore nothing down, so an engine started for
/// it could stay up. The rule now: a turn always uses the shared engine — the wake listener's if it
/// wants one, otherwise a consumer engine started for this turn — and when the turn ends with no
/// listener wanted and nobody else on the tap, nothing is left running.
struct TurnEngineOwnership: Equatable {

    enum Source: Equatable {
        /// An engine is already running (the idle listener's, or a consumer's): reuse it.
        case reuseRunning
        /// Start the wake listener's engine (and pause its recognizer for dictation), as before.
        case wakeListener
        /// No listener is wanted: start the shared engine for consumers only, for this turn.
        case consumerEngineForTurn
    }

    /// Whether the engine running now was started for the turn in progress.
    private(set) var startedForTurn = false

    static func source(engineRunning: Bool, silentMode: Bool, listeningEnabled: Bool) -> Source {
        if engineRunning { return .reuseRunning }
        if silentMode || !listeningEnabled { return .consumerEngineForTurn }
        return .wakeListener
    }

    mutating func noteStarted(_ source: Source) {
        if source == .consumerEngineForTurn { startedForTurn = true }
    }

    /// The turn is over. Returns whether the engine must be stopped now: whenever no listener is
    /// wanted and no other consumer is on the tap — whoever started it. The guarantee the tests
    /// hold is about the state left behind, not about who is to blame for it.
    mutating func endTurn(listenerWanted: Bool, consumersActive: Bool) -> Bool {
        defer { startedForTurn = false }
        return !listenerWanted && !consumersActive
    }
}
