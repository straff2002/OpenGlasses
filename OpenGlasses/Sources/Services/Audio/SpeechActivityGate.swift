import Foundation

/// Plan CU P2 — turns a stream of per-hop voice-activity scores into two events, with the
/// hysteresis that keeps a breath from ending a sentence. Pure: scores and timestamps in, events
/// out, no clock and no audio.
///
/// Two thresholds rather than one, because a single threshold makes the two mistakes symmetric and
/// they are not. Crossing **up** through `onsetThreshold` starts speech; only falling **below**
/// `releaseThreshold` — lower — begins silence. A mid-sentence dip (an unvoiced consonant, a
/// breath, the wearer turning their head off-axis of a temple mic) sits between the two and changes
/// nothing.
///
/// `onsetThreshold` sits above the usual library default deliberately: an 8 kHz HFP link from a
/// pair of glasses carries a noise floor that a default threshold reads as speech, and a detector
/// that believes speech never stops is a hot mic held to `EndOfTurnPolicy`'s backstop. The
/// protection against the *expensive* mistake — cutting the wearer off mid-sentence — is not a low
/// onset but `minSilenceDuration` plus the lower release threshold, which is what makes the
/// asymmetry hold at the point where it matters.
///
/// **All four numbers are provisional.** They are structured so they can be tuned as a set on
/// device (CU P5) against a false-cut rate, and they are deliberately not tuned here, where the only
/// available evidence would be taste.
struct SpeechActivityGate {

    struct Configuration: Equatable {
        /// Score at or above which a hop counts as the start of speech.
        var onsetThreshold: Float = 0.6
        /// Score below which a hop counts as silence. Lower than `onsetThreshold` — see above.
        var releaseThreshold: Float = 0.35
        /// Speech must persist this long before it is announced. Rejects a single noisy hop.
        var minSpeechDuration: TimeInterval = 0.12
        /// Silence must persist this long before the turn may end. This is the number that decides
        /// whether a wearer gets cut off mid-sentence, and the one CU P5 exists to set.
        var minSilenceDuration: TimeInterval = 0.5

        static let `default` = Configuration()
    }

    enum Event: Equatable {
        /// Stamped at the **onset** hop, not at the confirmation — the difference is
        /// `minSpeechDuration`, and the barge-in rider wants the earlier of the two.
        case speechStarted(at: Date)
        /// Stamped at the moment the silence **began**, not when it was confirmed. Stamping the
        /// confirmation would fold `minSilenceDuration` into the wearer's dead air and hide it
        /// inside `perceivedLatency` — the same mistake P1 documents for `lastSpeechObservedAt`,
        /// one layer down.
        case speechEnded(at: Date)
    }

    private(set) var isSpeaking = false
    private var candidateSpeechStart: Date?
    private var candidateSilenceStart: Date?

    let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Feed one hop's score. Returns an event only on a transition.
    mutating func observe(score: Float, at time: Date) -> Event? {
        if isSpeaking {
            guard score < configuration.releaseThreshold else {
                candidateSilenceStart = nil        // still talking; the dip was not the end
                return nil
            }
            let began = candidateSilenceStart ?? time
            candidateSilenceStart = began
            guard time.timeIntervalSince(began) >= configuration.minSilenceDuration else { return nil }
            isSpeaking = false
            candidateSilenceStart = nil
            candidateSpeechStart = nil
            return .speechEnded(at: began)
        } else {
            guard score >= configuration.onsetThreshold else {
                candidateSpeechStart = nil
                return nil
            }
            let began = candidateSpeechStart ?? time
            candidateSpeechStart = began
            guard time.timeIntervalSince(began) >= configuration.minSpeechDuration else { return nil }
            isSpeaking = true
            candidateSpeechStart = nil
            candidateSilenceStart = nil
            return .speechStarted(at: began)
        }
    }

    /// Start of a new utterance, or a route/format change — no state survives either.
    mutating func reset() {
        isSpeaking = false
        candidateSpeechStart = nil
        candidateSilenceStart = nil
    }
}
