import Foundation

/// Tunables for `NarrationGate` — plain data so tests (and, later, Settings) drive them directly.
///
/// The defaults are reasoned, not measured: Plan CV P4 gates them on a walked route with real
/// hardware, because dwell against a desk is not dwell against a corridor and chatter tolerance is
/// a wearer's judgement rather than a number we can derive.
struct NarrationGateRules: Equatable {
    /// The view must be still for this long before a description is worth generating (seconds).
    /// Describing mid-turn produces a description of a blur.
    var dwell: TimeInterval = 1.5

    /// Ceiling on deferring for dwell (seconds). A wearer walking continuously never settles, and
    /// a gate that waits for stillness would describe nothing for the entire walk — which is the
    /// case this plan exists for. Past this, describe the moving scene anyway.
    var dwellCeiling: TimeInterval = 8

    /// Minimum interval between inferences regardless of how much changed (seconds) — the
    /// duty-cycle floor.
    ///
    /// This is not battery politeness. VLM decode and Kokoro synthesis both want Metal, and the
    /// TTS chain reaches Kokoro whenever ElevenLabs is unavailable — i.e. on the offline wearer
    /// this plan most serves. The floor is what keeps the model answerable while it describes.
    var minInferenceInterval: TimeInterval = 6

    /// Similarity at or above which a description counts as the same scene already spoken.
    ///
    /// Deliberately **permissive toward "same"**, which is the opposite asymmetry to `FrameGate`'s:
    /// a false "same" costs one missed announcement, a false "new" costs chatter — continuously,
    /// in someone's ear. For an assistive feature that is not a close call.
    var sameSceneSimilarity: Double = 0.5

    /// Floor on the similarity denominator. Without it a two-word description ("a desk") scores 1.0
    /// against any longer description containing it, and would be silently swallowed.
    var minComparableWords: Int = 3
}

/// The gate a frame gate structurally cannot be (Plan CV): decides whether a *description* is
/// worth generating, and then whether it is worth saying.
///
/// `FrameGate` (Plan AT) already answers "is this a new scene?" from the pixels. The failure it
/// cannot catch is downstream of it: a vision model rephrases one unchanged scene endlessly — *"a
/// man at a desk"* / *"a person sitting at a desk"* / *"someone working at a desk"* — on the
/// heartbeat re-send `FrameGate` deliberately forces so the model's context can't go stale. From
/// the camera's point of view nothing changed and the frame was never re-sent; the duplication is
/// generated. So this gate runs on the **text**.
///
/// Three rules, in the order they apply:
/// 1. **Duty-cycle floor** — a minimum interval between inferences regardless of change.
/// 2. **Dwell** — the view must settle before a description is worth generating (with a ceiling,
///    so continuous motion still gets described).
/// 3. **Word-overlap similarity against the last _spoken_ description** — not the last *generated*
///    one. A silent rephrase must not reset the comparison, or the next rephrase gets spoken.
///
/// Pure value type: time is injected via `now`, no clock inside, so every branch is deterministic
/// and headless-testable — the same shape as `FrameGate`, which it partners.
struct NarrationGate {

    /// Whether to spend an inference right now.
    enum GenerateDecision: Equatable {
        case generate
        /// No unconsumed scene change — there is nothing new to describe.
        case idle
        /// The duty-cycle floor has not elapsed since the last inference.
        case dutyCycleFloor(remaining: TimeInterval)
        /// The view is still moving and the dwell ceiling has not been reached.
        case settling(remaining: TimeInterval)

        var isGenerate: Bool { self == .generate }
    }

    /// Whether a generated description is worth saying out loud.
    enum SpeakDecision: Equatable {
        case speak
        /// Too close to the last *spoken* description — a rephrase of a scene already announced.
        case rephrase(similarity: Double)
        /// Nothing describable came back (empty, or boilerplate with no content words).
        case empty

        var isSpeak: Bool { self == .speak }
    }

    var rules: NarrationGateRules

    /// When the current unconsumed run of scene changes began — the dwell ceiling measures from
    /// here, so continuous motion is bounded rather than deferred forever.
    private var pendingSince: TimeInterval?
    /// The most recent scene change — dwell measures from here.
    private var lastSceneChangeAt: TimeInterval?
    private var lastInferenceAt: TimeInterval?
    /// Content words of the last description actually **spoken**. Suppressed rephrases deliberately
    /// leave this untouched.
    private var lastSpokenWords: Set<String> = []

    private(set) var spokenCount: Int = 0
    private(set) var suppressedRephraseCount: Int = 0

    init(rules: NarrationGateRules = NarrationGateRules()) {
        self.rules = rules
    }

    /// The description last spoken, as its content words — exposed for diagnostics and tests.
    var lastSpokenContentWords: Set<String> { lastSpokenWords }

    // MARK: - Scene changes

    /// Record a genuine scene change (`FrameGate.SendReason.distinct`).
    ///
    /// Heartbeat re-sends must **not** be reported here: a forced re-send of an unchanged scene is
    /// precisely what must not produce a fresh announcement.
    mutating func noteSceneChange(at now: TimeInterval) {
        if pendingSince == nil { pendingSince = now }
        lastSceneChangeAt = now
    }

    // MARK: - Generation

    /// Decide whether to spend an inference at `now`. On `.generate` the pending scene change is
    /// consumed and the duty-cycle clock restarts, so a static scene is described once rather than
    /// re-described until it moves.
    mutating func evaluateGeneration(at now: TimeInterval) -> GenerateDecision {
        guard let pendingSince, let lastChange = lastSceneChangeAt else { return .idle }

        // Duty-cycle floor first: it is the hard resource constraint, and checking it first means
        // a busy scene can't spend inferences just because it keeps settling.
        if let last = lastInferenceAt {
            let elapsed = now - last
            if elapsed < rules.minInferenceInterval {
                return .dutyCycleFloor(remaining: rules.minInferenceInterval - elapsed)
            }
        }

        let settled = now - lastChange
        if settled < rules.dwell && now - pendingSince < rules.dwellCeiling {
            return .settling(remaining: rules.dwell - settled)
        }

        self.pendingSince = nil
        lastSceneChangeAt = nil
        lastInferenceAt = now
        return .generate
    }

    // MARK: - Speech

    /// Decide whether a generated description is worth saying. State moves **only** on `.speak` —
    /// a suppressed rephrase leaves the spoken baseline where it was, which is the point:
    /// comparing against the last *generated* description lets a silent rephrase reset the
    /// comparison and the next rephrase through.
    ///
    /// No `now` here, deliberately. The two time-based rules are on the generation side, and "this
    /// was said recently enough not to repeat" is the shared `AmbientSpeechArbiter`'s dedup window
    /// — putting a second copy of it here is precisely what the extraction was avoiding.
    mutating func evaluateSpeech(_ description: String) -> SpeakDecision {
        let words = Self.contentWords(description)
        guard !words.isEmpty else { return .empty }

        guard !lastSpokenWords.isEmpty else {
            recordSpoken(words)
            return .speak
        }

        let score = Self.similarity(words, lastSpokenWords, minComparableWords: rules.minComparableWords)
        if score >= rules.sameSceneSimilarity {
            suppressedRephraseCount += 1
            return .rephrase(similarity: score)
        }

        recordSpoken(words)
        return .speak
    }

    /// Clear all state (e.g. when the narration session restarts).
    mutating func reset() {
        pendingSince = nil
        lastSceneChangeAt = nil
        lastInferenceAt = nil
        lastSpokenWords = []
        spokenCount = 0
        suppressedRephraseCount = 0
    }

    private mutating func recordSpoken(_ words: Set<String>) {
        lastSpokenWords = words
        spokenCount += 1
    }

    // MARK: - Similarity (internal for tests)

    /// Words carrying no scene information: English function words plus the boilerplate a vision
    /// model wraps every description in ("the image shows…"). Left in, they inflate the score
    /// between two genuinely different scenes.
    static let stopWords: Set<String> = [
        "a", "about", "after", "all", "also", "an", "and", "any", "are", "as", "at", "be", "been",
        "being", "both", "but", "by", "can", "could", "did", "do", "does", "each", "for", "from",
        "had", "has", "have", "he", "her", "here", "him", "his", "how", "if", "in", "into", "is",
        "it", "its", "just", "may", "me", "might", "more", "most", "must", "my", "no", "not", "of",
        "off", "on", "onto", "only", "or", "other", "our", "out", "own", "same", "she", "should",
        "so", "some", "such", "than", "that", "the", "their", "them", "then", "there", "these",
        "they", "this", "those", "to", "too", "us", "very", "was", "we", "were", "what", "when",
        "where", "which", "while", "who", "why", "will", "with", "would", "you", "your",
        // Vision-model boilerplate.
        "appear", "appears", "background", "camera", "depict", "depicts", "featuring", "foreground",
        "image", "likely", "look", "looking", "looks", "photo", "photograph", "picture", "scene",
        "see", "seem", "seems", "shot", "show", "showing", "shows", "view", "visible",
    ]

    /// Generic references to a human, folded to one token.
    ///
    /// This is the exact rephrasing family the plan names — *"a man at a desk"* vs *"a person
    /// sitting at a desk"* — and without it those two share no subject word at all and score as a
    /// new scene. Folding gendered nouns in means a change of *who* is at the desk can read as the
    /// same scene: an accepted false "same" under this gate's stated asymmetry, and one the other
    /// content words usually break anyway.
    static let personWords: Set<String> = [
        "boy", "boys", "child", "children", "female", "figure", "gentleman", "girl", "girls",
        "guy", "guys", "human", "individual", "individuals", "kid", "kids", "lady", "ladies",
        "male", "man", "men", "people", "person", "persons", "someone", "somebody", "woman",
        "women",
    ]

    /// The content words of a description: lowercased, de-punctuated, person-folded, crudely
    /// de-pluralised, stop-worded.
    static func contentWords(_ text: String) -> Set<String> {
        var out: Set<String> = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var word = String(raw)
            if personWords.contains(word) {
                out.insert("person")
                continue
            }
            // Crude de-pluralisation — applied to both sides, so consistency matters more than
            // linguistic correctness.
            if word.count > 3, word.hasSuffix("s"),
               !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
                word.removeLast()
            }
            guard word.count > 1, !stopWords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }

    /// Overlap coefficient over content words: shared words over the size of the smaller
    /// description, floored at `minComparableWords` so a terse description can't score 1.0 by being
    /// a subset of a verbose one.
    ///
    /// Overlap rather than Jaccard because the two descriptions of one scene are routinely
    /// different lengths — the model elaborates on some passes and not others — and Jaccard
    /// punishes that length difference as if it were a change of subject.
    static func similarity(_ a: Set<String>, _ b: Set<String>, minComparableWords: Int = 3) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.intersection(b).count
        let denominator = max(minComparableWords, min(a.count, b.count))
        return Double(shared) / Double(denominator)
    }

    /// Convenience for tests and diagnostics: similarity between two raw descriptions.
    static func similarity(_ a: String, _ b: String, minComparableWords: Int = 3) -> Double {
        similarity(contentWords(a), contentWords(b), minComparableWords: minComparableWords)
    }
}
