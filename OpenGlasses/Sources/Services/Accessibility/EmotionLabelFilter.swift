import Foundation

/// The deterministic check that keeps Social mode on the observation side of the line
/// (Plan HR P1 item 2).
///
/// `SocialObservationContract` asks the model to describe only what is visible; this checks that it
/// did. Every Social mode answer's `advice` and `followup` are scanned for words and phrases that
/// name an emotional state, a mood or an intention. A hit is an `.inference`, which
/// `AssistiveModeService` never speaks.
///
/// **What is not in the tables matters as much as what is.** The observation vocabulary the prompt
/// asks for — smiling, frowning, mouth turned down, brow raised, eyes narrowed, looking away, arms
/// crossed, leaning in, stepping back, waving, pointing, crying, laughing — is absent from both
/// tables, and so are words that are also everyday observations (`down` as in "looking down",
/// `cross` as in "arms crossed", `content` as in "the content on the screen", `patient`, `warm`,
/// `blue`). Physical states pass too: tired, cold, hot, in pain, shivering. The tests hold the pass
/// list as a table of sentences, so adding a word here that collides with an observation fails
/// there.
///
/// Matching is whole-word and case-insensitive. "Simple stemming" is two things: each family below
/// lists its forms (anxious, anxiety, anxiously), and a word is also tried with one trailing `s`,
/// `ly` or `ness` removed, so a plural or an adverb the table did not spell out is still caught.
enum EmotionLabelFilter {

    enum Verdict: Equatable {
        /// Nothing in the text names a feeling, a mood or an intention.
        case observation
        /// The text names one; `matched` is the table entries that hit, sorted, for tests and review.
        /// Never logged: they are the model's words.
        case inference(matched: [String])

        var isObservation: Bool { self == .observation }
    }

    // MARK: - The tables

    /// Emotional states, moods and diagnoses, one family per line.
    static let emotionWords: [[String]] = [
        ["happy", "happiness", "happily", "unhappy", "unhappiness"],
        ["sad", "sadness", "sadly", "sadder", "saddest"],
        ["angry", "anger", "angrily", "angered"],
        ["anxious", "anxiety", "anxiously", "anxieties"],
        ["upset"],
        ["distress", "distressed", "distressing"],
        ["nervous", "nervously", "nervousness"],
        ["bored", "boredom"],
        ["frustrated", "frustration", "frustrating"],
        ["excited", "excitement", "excitedly"],
        ["scared", "afraid", "fear", "fearful", "frightened", "terrified"],
        ["annoyed", "annoyance"],
        ["irritated", "irritation", "irritable"],
        ["hostile", "hostility"],
        ["friendly", "unfriendly"],
        ["furious", "fury", "mad", "enraged"],
        ["worried", "worry", "worrying"],
        ["uneasy", "unease"],
        ["glad", "pleased", "delighted", "joy", "joyful", "cheerful"],
        ["calm", "relaxed"],
        ["stressed", "stress"],
        ["overwhelmed", "panicked", "panic", "panicking"],
        ["confused", "confusion"],
        ["surprised", "surprise", "shocked"],
        ["disgusted", "disgust"],
        ["embarrassed", "embarrassment", "ashamed", "shame", "guilty", "guilt"],
        ["jealous", "envious", "lonely", "proud"],
        ["disappointed", "disappointment", "satisfied", "grateful", "relieved", "hopeful"],
        ["interested", "uninterested", "disinterested", "impatient", "impatience"],
        ["aggressive", "aggression", "defensive", "suspicious", "sarcastic", "awkward", "shy"],
        ["uncomfortable", "concerned", "insecure", "amused"],
        ["emotion", "emotions", "emotional", "emotionally"],
        ["mood", "moody", "vibe"],
        ["feel", "feels", "feeling", "feelings", "felt"],
        ["depressed", "depression", "manic", "paranoid", "autistic", "diagnosis"],
        // Third person: "wants" is always about somebody else. The wearer is "you", and a follow-up
        // such as "Want me to keep watching?" has to pass, so the bare "want" is not here.
        ["wants", "intends", "intention", "intentions"],
    ]

    /// Phrases that state an intention or attribute a feeling, matched as whole-word sequences.
    static let inferencePhrases: [String] = [
        "seems to feel", "is feeling", "are feeling",
        "wants to", "wants you", "they want", "wanting to",
        "is about to", "are about to", "about to",
        "intends to", "intend to", "plans to", "planning to",
        "trying to", "hoping to", "hopes to",
        "in a good mood", "in a bad mood",
    ]

    /// Suffixes tried off the end of a word that is not itself in the table.
    static let strippedSuffixes = ["ness", "ly", "s"]

    // MARK: - The check

    private static let words: Set<String> = Set(emotionWords.flatMap { $0 })

    /// Check one advice result: its `advice` and `followup` together.
    static func check(_ advice: AssistiveAdvice) -> Verdict {
        check([advice.advice, advice.followup ?? ""].joined(separator: " "))
    }

    /// Check free text.
    static func check(_ text: String) -> Verdict {
        let tokens = tokenize(text)
        var matched = Set<String>()

        for token in tokens {
            if let hit = match(token) { matched.insert(hit) }
        }
        let padded = " " + tokens.joined(separator: " ") + " "
        for phrase in inferencePhrases where padded.contains(" \(phrase) ") {
            matched.insert(phrase)
        }
        return matched.isEmpty ? .observation : .inference(matched: matched.sorted())
    }

    /// The table entry a word hits, trying it as written and then with one suffix stripped.
    private static func match(_ token: String) -> String? {
        if words.contains(token) { return token }
        for suffix in strippedSuffixes where token.hasSuffix(suffix) && token.count > suffix.count + 2 {
            let stem = String(token.dropLast(suffix.count))
            if words.contains(stem) { return stem }
        }
        return nil
    }

    /// Lowercased words. An apostrophe splits ("she's" → "she", "s"), so a contraction never
    /// hides a word, and every other non-letter is a boundary.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }
}
