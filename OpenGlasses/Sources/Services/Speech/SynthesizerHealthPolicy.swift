import AVFoundation
import Foundation

/// Plan GB P4 — is the system speech synthesizer still doing anything?
///
/// # The failure this catches
///
/// In the field tester's earlier run the app spoke five answers with the system voice and none of
/// them finished or was cancelled: the one `AVSpeechSynthesizer` had wedged. `speakWithiOS` awaits a
/// continuation that only `didFinish`/`didCancel` resume, so each turn waited for ever, the next
/// utterance was held behind it and later dropped as stale. After a relaunch, nine of nine finished.
/// What wedged it is unproven (a device question); this policy is the recovery, not the cause.
///
/// # The rule
///
/// An utterance that has not started within `startTimeout` **never started**. One that started
/// but has gone quiet — no word boundary for `boundarySilence` — *and* has run past its expected
/// length (characters ÷ speaking rate, plus slack) has **stalled**. Either way the caller rebuilds
/// the synthesizer, records the failure, releases the waiting turn and tries the utterance once
/// more. Pure: times in, verdict out.
enum SynthesizerHealthPolicy {

    enum Verdict: String, Equatable {
        case healthy, neverStarted, stalled
    }

    struct Timing: Equatable {
        /// How long `speak` may take to produce `didStart`.
        var startTimeout: TimeInterval
        /// How long a started utterance may go without a word boundary before it can be stalled.
        var boundarySilence: TimeInterval
        /// Added to the expected spoken length.
        var slack: TimeInterval
        /// How often the watchdog looks.
        var pollInterval: TimeInterval

        static let `default` = Timing(startTimeout: 4, boundarySilence: 4, slack: 5, pollInterval: 0.5)
    }

    /// Characters per second at the system default rate (≈ 150 words a minute of English).
    static let charactersPerSecondAtDefaultRate: Double = 14

    /// How long an utterance of `characters` should take at `rate` (an `AVSpeechUtterance` rate).
    static func expectedDuration(characters: Int, rate: Float) -> TimeInterval {
        let scale = Double(rate) / Double(AVSpeechUtteranceDefaultSpeechRate)
        let perSecond = max(1, charactersPerSecondAtDefaultRate * max(0.1, scale))
        return Double(max(0, characters)) / perSecond
    }

    static func assess(speakAt: Date, didStartAt: Date?, lastBoundaryAt: Date?,
                       characters: Int, rate: Float, now: Date,
                       timing: Timing = .default) -> Verdict {
        guard let didStartAt else {
            return now.timeIntervalSince(speakAt) > timing.startTimeout ? .neverStarted : .healthy
        }
        let quietSince = max(lastBoundaryAt ?? didStartAt, didStartAt)
        let overran = now.timeIntervalSince(didStartAt)
            > expectedDuration(characters: characters, rate: rate) + timing.slack
        let quiet = now.timeIntervalSince(quietSince) > timing.boundarySilence
        return overran && quiet ? .stalled : .healthy
    }
}

/// What the text-to-speech service drives. `AVSpeechSynthesizer` is the only production
/// conformer; the seam lets a test hand in one that never calls back (Plan GB P4).
@MainActor
protocol SpeechSynthesizing: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}
