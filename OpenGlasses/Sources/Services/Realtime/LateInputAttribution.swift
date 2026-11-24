import Foundation

/// Which wearer turn a live input-transcription fragment belongs to, for a provider that streams
/// the wearer's words in pieces (`RealtimeProviderSession.inputTranscriptionIsDelta`, Gemini Live).
///
/// # Why a turn is held open
///
/// A streaming provider can send the last pieces of the wearer's words *after* it has said the
/// turn is complete. Read as they arrive, those pieces land in a transcript the turn boundary has
/// just cleared and become the opening words of the next turn: a trailing "bye" misses the
/// goodbye check for the turn it ended and is then read as the next turn's, the job record gets
/// half a sentence, and the handover record files it as a turn of its own.
///
/// So the finished turn is held for ``grace`` after its boundary. A fragment inside the grace,
/// before anything says a new turn has begun, is the finished turn's. The turn is finalised —
/// voice-end check, job transcript, handover record, new-topic backstop — when the grace runs out,
/// or at once when a new turn clearly begins (model audio, a tool call, the model being
/// interrupted, another turn boundary). The model's transcript is not such a sign: it lags its
/// audio, and its last words can arrive after the boundary as the wearer's do.
///
/// Pure and clock-free: time is passed in, so every case is a unit test. A provider that delivers
/// one complete transcript per turn never comes here; its behaviour is unchanged.
struct LateInputAttribution: Equatable {

    /// How long after a turn boundary a fragment is still taken to be that turn's. Short on
    /// purpose: it delays the finished turn's checks by this much, and the wearer starting a new
    /// sentence this soon after the model stops is rare.
    static let grace: TimeInterval = 0.6

    /// A finished wearer turn, held open for words still on their way.
    struct FinishedTurn: Equatable {
        /// Everything the wearer said in the turn, late pieces included.
        var wearer: String
        /// Whether the model said anything in the turn.
        let modelReplied: Bool
        /// The conversation-reset generation the wearer's turn began under, when known.
        let resetGeneration: UInt64?
        /// When the provider said the turn was complete.
        let endedAt: Date
        /// Identifies this hold, so a grace timer can only finalise its own turn.
        let token: Int
        /// How many fragments arrived after the boundary and were joined to this turn.
        var lateFragments = 0
        /// How many characters those fragments carried. Counted, never logged as text.
        var lateCharacters = 0
    }

    /// Where a fragment goes.
    enum FragmentRoute: Equatable {
        /// Joined to the finished turn. Nothing else is told about it.
        case finishedTurn
        /// Part of the turn under way. `finaliseFirst` is a held turn whose grace had already run
        /// out, which must be finalised before this fragment is handled.
        case currentTurn(finaliseFirst: FinishedTurn?)
    }

    private(set) var held: FinishedTurn?
    private var lastToken = 0

    var isHolding: Bool { held != nil }

    /// The provider said the turn is complete. The turn is held from `now`.
    ///
    /// - Returns: the token for this hold (its grace timer finalises with it), and a turn still
    ///   held from an earlier boundary, which must be finalised first: a second boundary is a new
    ///   turn's event.
    mutating func turnCompleted(wearer: String, modelReplied: Bool, resetGeneration: UInt64?,
                                now: Date) -> (token: Int, finaliseFirst: FinishedTurn?) {
        let earlier = held
        lastToken += 1
        held = FinishedTurn(wearer: wearer, modelReplied: modelReplied,
                            resetGeneration: resetGeneration, endedAt: now, token: lastToken)
        return (lastToken, earlier)
    }

    /// An input-transcription fragment arrived at `now`.
    mutating func fragment(_ text: String, now: Date) -> FragmentRoute {
        guard var turn = held else { return .currentTurn(finaliseFirst: nil) }
        guard now.timeIntervalSince(turn.endedAt) <= Self.grace else {
            held = nil
            return .currentTurn(finaliseFirst: turn)
        }
        turn.wearer = ScriptAwareJoiner.join(turn.wearer, text)
        turn.lateFragments += 1
        turn.lateCharacters += text.count
        held = turn
        return .finishedTurn
    }

    /// Something showed that a new turn has begun. The held turn, if any, is finalised now.
    mutating func newTurnBegan() -> FinishedTurn? {
        defer { held = nil }
        return held
    }

    /// The grace timer for `token` fired. Returns the turn to finalise, or nil when that turn was
    /// already finalised (a new turn began first) or a later boundary replaced it.
    mutating func graceElapsed(token: Int) -> FinishedTurn? {
        guard let turn = held, turn.token == token else { return nil }
        held = nil
        return turn
    }

    /// The session is stopping. The held turn, if any, is handed back to be flushed with the
    /// session's teardown; see `RealtimeSessionManager.stopSession(reason:)` for what runs.
    mutating func sessionEnded() -> FinishedTurn? {
        defer { held = nil }
        return held
    }
}
