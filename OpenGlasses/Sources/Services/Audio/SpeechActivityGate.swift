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

        /// Plan GU §5 — the idle wake-word gate over `EnergySpeechScorer`. The scorer maps its dB
        /// thresholds onto these same two score levels, so the gate's onset/release mean "+onset
        /// dB / +release dB over the noise floor". Shorter speech (0.10 s) than dictation: a wake
        /// phrase starts with a short syllable and the pre-roll covers the lag. Shorter silence
        /// too: the recognition tail (1.5 s) is what keeps the recognizer for a final partial.
        static let wakeIdle = Configuration(onsetThreshold: 0.6, releaseThreshold: 0.35,
                                            minSpeechDuration: 0.10, minSilenceDuration: 0.3)

        /// Plan CU P2 PR2 — the gate over the Silero model's speech probability, scored in
        /// 256 ms chunks (`SpeechHopChunker.hopDuration`). **Provisional**: CU P5 tunes it on
        /// device against a false-cut rate.
        ///
        /// - Onset 0.65, above the model's conventional 0.5, for the HFP noise floor (see the type
        ///   comment). Release 0.50 is Silero's conventional onset − 0.15.
        /// - `minSpeechDuration` 0.12 s is shorter than one chunk, and that is enough to make one
        ///   loud chunk never speech: the onset chunk opens the run at elapsed 0, which is below
        ///   any positive minimum, so a second consecutive chunk at or above onset (elapsed
        ///   0.256 s) is what confirms it. Anything from just above 0 up to 0.256 s means the same
        ///   "two chunks", so the number does not need retuning if the hop changes slightly.
        /// - `minSilenceDuration` 0.5 s, which in 256 ms chunks is three quiet chunks — see
        ///   `feltEndOfTurnDelay` for what the wearer actually waits.
        static let silero = Configuration(onsetThreshold: 0.65, releaseThreshold: 0.50,
                                          minSpeechDuration: 0.12, minSilenceDuration: 0.5)
    }

    /// Plan CU P2 PR2 — what the wearer feels between their last word and the acoustic commit,
    /// once silence can only be observed in whole chunks.
    ///
    /// The wearer stops at T, inside a chunk that still holds speech and so scores as speech; the
    /// first quiet chunk starts at the next boundary, up to one chunk after T. The gate times
    /// silence from that chunk's start and confirms on the k-th quiet chunk, where
    /// k = ⌈minSilence / chunk⌉ + 1 — and that chunk is only scored once it has been fully
    /// captured, k chunks after the silence began. `EndOfTurnPolicy` commits at the silence start
    /// plus `grace`, or on the event's arrival if that is later. So the delay lies in
    /// (max(k·chunk, grace), max(k·chunk, grace) + chunk], before model time (milliseconds).
    ///
    /// The step table at 256 ms chunks and the 0.4 s grace:
    ///
    /// | minSilence | quiet chunks k | felt delay      |
    /// |------------|----------------|-----------------|
    /// | 0          | 1              | 0.400–0.656 s   |
    /// | 0.25 s     | 2              | 0.512–0.768 s   |
    /// | **0.5 s**  | **3**          | **0.768–1.024 s** |
    /// | 0.75 s     | 4              | 1.024–1.280 s   |
    /// | 1.0 s      | 5              | 1.280–1.536 s   |
    ///
    /// against today's 2.0 s timer window measured from the last partial. The steps are why CU P5
    /// should tune `minSilenceDuration` in whole chunks: 0.3 s and 0.5 s feel identical.
    static func feltEndOfTurnDelay(minSilence: TimeInterval,
                                   chunk: TimeInterval,
                                   grace: TimeInterval = EndOfTurnPolicy.acousticGrace) -> ClosedRange<TimeInterval> {
        precondition(chunk > 0, "a chunk has a length")
        // The epsilon keeps an exact multiple (0.512 / 0.256) from rounding up a whole chunk.
        let extraChunks = max(0, (minSilence / chunk - 1e-9).rounded(.up))
        let confirmed = (extraChunks + 1) * chunk
        let floor = max(confirmed, grace)
        return floor...(floor + chunk)
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

    /// Plan CU P2 PR2 — a format change in the middle of an utterance. The candidate runs were
    /// timed on audio from the old route and go with it; whether the wearer is talking is a
    /// conclusion about the wearer, not about the samples, and survives. Without that, a wearer who
    /// stops right as the route flips is never heard to stop (the new gate was never speaking),
    /// and `EndOfTurnPolicy` holds the turn to its backstop instead of the grace.
    mutating func restart(speaking: Bool) {
        reset()
        isSpeaking = speaking
    }
}
