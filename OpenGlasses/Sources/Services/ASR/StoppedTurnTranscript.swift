import Foundation

/// The words of an Apple Speech turn that has been stopped but not yet delivered.
///
/// A partial result lags the audio: the recogniser holds the word being spoken until it is sure of
/// it, and settles it only in the final result that follows `endAudio()`. Delivering the last
/// partial at the moment of the stop — which is what dictation used to do — drops that word, most
/// of all when the wearer presses stop as they finish speaking.
///
/// So a stopped turn starts from what was on screen and takes whatever the recogniser says after
/// it, until the final result, an error or the wait's bound settles it. A result that comes back
/// empty never erases words already heard. Pure, so the rule is tested without a recogniser.
struct StoppedTurnTranscript: Equatable {

    /// How the transcript was settled, for the log.
    enum Settlement: String, Equatable {
        /// The recogniser's final result arrived.
        case final
        /// The recogniser ended with an error before a final — commonly "no speech" after
        /// `endAudio()`. The words already heard stand.
        case ended
        /// The wait's bound passed first. The words already heard stand.
        case timedOut
    }

    /// How long a stopped turn waits for the final result. The same bound the Deepgram stream
    /// waits for its last final on `CloseStream`; an on-device final usually lands well inside it.
    static let finalResultTimeout: TimeInterval = 1.5

    private(set) var text: String
    private(set) var settlement: Settlement?

    var isSettled: Bool { settlement != nil }

    /// - Parameter shown: the latest partial at the moment of the stop.
    init(shown: String) {
        self.text = shown
    }

    /// A result from the recogniser after the stop.
    mutating func noteResult(_ transcript: String, isFinal: Bool) {
        guard !isSettled else { return }
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = transcript
        }
        if isFinal { settlement = .final }
    }

    /// The recogniser ended without a final result.
    mutating func noteEnded() {
        guard !isSettled else { return }
        settlement = .ended
    }

    /// The wait's bound passed.
    mutating func noteTimedOut() {
        guard !isSettled else { return }
        settlement = .timedOut
    }
}
