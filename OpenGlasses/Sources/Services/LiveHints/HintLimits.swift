import Foundation

/// Every number the live-hints core works to, in one place (Plan MO §4–§6).
///
/// The lengths are enforced in code whatever a model returns; the timings are what the trigger,
/// the keyword hold and the speak-when-quiet policy measure against an injected clock.
enum HintLimits {

    // MARK: - The trigger (§4)

    /// A caption shorter than this is never a question worth a hint.
    static let minimumQuestionWords = 4
    /// The least time between two hints, unless a different speaker asks.
    static let hintSpacing: TimeInterval = 8
    /// Two questions whose content words overlap this much (Jaccard) are the same question. At 0.8
    /// a rewording that keeps four content words of five is a repeat; one that changes a single
    /// word of three ("warranty on the compressor" / "warranty on the condenser") is not.
    static let duplicateOverlap = 0.8
    /// Small talk is the phrase plus at most this many trailing words ("how are you today, Sam").
    static let smallTalkTrailingWords = 2

    // MARK: - Keywords (§2)

    /// A keyword that fired is held this long before it can fire again.
    static let keywordHold: TimeInterval = 60

    // MARK: - The reply (§5)

    /// The glance line on the lens.
    static let hintMaxWords = 8
    static let hintMaxCharacters = 45
    /// The second page.
    static let fullMaxSentences = 2
    static let fullMaxCharacters = 240
    /// The ear form: about 5–7 words, under 2 s of speech.
    static let spokenHintMaxWords = 7
    /// The no-model passage card: two lens lines.
    static let passageCardMaxCharacters = 90

    // MARK: - The prompt (§4 context, §5 step 1)

    /// Earlier finals sent with the question, so "and the second one?" resolves.
    static let earlierLinesMax = 6
    /// Passages sent with the question.
    static let passagesMax = 4

    // MARK: - Speaking (§6)

    /// Nobody may have spoken for this long before a hint is spoken.
    static let quietBeforeSpeaking: TimeInterval = 0.4
    /// A hint not started this long after it arrived is dropped.
    static let speakWithin: TimeInterval = 5

    // MARK: - The session (§5, §6, §10)

    /// The model's hint replaces the passage card only if it lands this soon after the card.
    static let modelReplaceWindow: TimeInterval = 3
    /// A hint on the lens hides after this long (the Display's own dim), unless the next replaces it.
    static let lensCardLifetime: TimeInterval = 20
    /// The phone keeps this many hints, newest first, in memory only.
    static let phoneListMax = 10
    /// The longest session: it stops itself here.
    static let sessionLimit: TimeInterval = 2 * 60 * 60
    /// The spoken warning before the limit (at 1 h 55).
    static let sessionWarningAt: TimeInterval = sessionLimit - 5 * 60
    /// The capture notice stays on the phone this long after a start.
    static let captureNoticeDuration: TimeInterval = 8
    /// How often the session's clock ticks (the speak-when-quiet policy, the limits, the card).
    static let tickInterval: TimeInterval = 0.1
    /// Lecture mode: a key point about this often, or sooner at a pause after
    /// `keyPointWords` words (`MeetingAssistantService`'s cadence).
    static let keyPointInterval: TimeInterval = 60
    static let keyPointWords = 100
    /// The key-point line on the lens: two lens lines, as a passage card.
    static let keyPointMaxCharacters = 90
    /// The question over the hint: at most this many words.
    static let questionGlanceWords = 4

    /// Slack for comparing intervals built from `Date` arithmetic, so a boundary measured at
    /// exactly the limit lands on the limit's side whatever the base date's rounding.
    static let timeTolerance: TimeInterval = 0.000_001
}
