import Foundation

/// A reply that promises to look something up instead of answering.
///
/// The shared tool loop ends a turn at the first reply with no tool call, and speaks it. On a
/// tester's phone a search ran and returned, and the model's next reply — the one the loop took
/// as the answer — was "Vou pesquisar a programação atual… Um momento, por favor." The wearer
/// waited ten minutes for a reply that was never coming. The model had the results in front of it
/// and narrated an intention instead of reading them.
///
/// This names that shape of reply so the loop can ask once more, with the results still in
/// history, before it speaks: short, no figures, and built around a stalling phrase in one of the
/// languages the app ships in. The bar is deliberately narrow — one extra request on a false
/// positive costs a second or two; a false negative costs a wasted turn — so a reply that carries
/// a number, or runs longer than a sentence or two, is never second-guessed.
///
/// A reply with no words at all is the same mistake with nothing to speak (`isSilent`): a provider
/// path that keeps an empty reply would end the turn in silence, so the loop asks once there too.
enum StallReplyPolicy {

    /// Replies longer than this are answers, whatever they open with.
    static let maxStallLength = 160

    /// Stalling phrases, lower-cased and diacritic-folded, matched as substrings of the folded
    /// reply. English, Portuguese, Spanish, French, German, Italian.
    static let stallPhrases: [String] = [
        // English
        "one moment", "just a moment", "a moment please", "hold on", "bear with me", "give me a second",
        "let me check", "let me look", "let me search", "let me find", "i'll look", "i will look",
        "i'll check", "i will check", "i'll search", "i will search", "i'll find out", "looking that up",
        "looking it up",
        // Portuguese
        "um momento", "um instante", "so um momento", "so um instante", "vou pesquisar", "vou procurar",
        "vou verificar", "vou consultar", "vou ver", "deixa-me ver", "deixe-me ver", "deixa me ver",
        "deixe me ver", "aguarde", "aguarda", "ja te digo", "ja lhe digo",
        // Spanish
        "un momento", "un segundo", "voy a buscar", "voy a verificar", "voy a consultar", "dejame ver",
        "dejeme ver", "permiteme", "ahora mismo lo busco",
        // French
        "un instant", "un moment", "je vais chercher", "je vais verifier", "je vais regarder",
        "laissez-moi verifier", "laisse-moi verifier", "je regarde",
        // German
        "einen moment", "einen augenblick", "ich schaue nach", "ich sehe nach", "ich suche",
        "ich prufe", "moment bitte",
        // Italian
        "un attimo", "vado a cercare", "vado a controllare", "fammi controllare", "fammi vedere",
        "controllo subito",
    ]

    /// Whether `text` promises an answer rather than giving one.
    static func isStall(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxStallLength else { return false }
        // A figure is content: a time, a price, a count — the reply is saying something.
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return stallPhrases.contains { folded.contains($0) }
    }

    /// What the model is told when its reply stalled after a tool had already answered.
    static let nudge =
        "The tool results above are already in. Do not say you will look it up or ask the user to "
        + "wait: answer now, in the user's language, with what the results contain, or say plainly "
        + "that they do not contain it."

    /// Tools whose result tells the model to say nothing, because the app speaks for itself: a blank
    /// reply after one of these is the reply it was asked for. `new_topic` is confirmed aloud once
    /// the context has been cleared.
    static let toolsThatEndInSilence: Set<String> = ["new_topic"]

    /// Whether `text` would end the turn with nothing said, after `toolsRun` answered this turn.
    /// False once a tool has asked for that silence.
    static func isSilent(_ text: String, toolsRun: [String] = []) -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !toolsRun.contains(where: toolsThatEndInSilence.contains)
    }

    /// What the model is told when its reply had no words in it. Unlike `nudge` it claims no tool
    /// results, because no tool may have run. On the Responses route a reply can be a note to itself
    /// and nothing else, which is why it asks for the answer and not just for a reply.
    static let silenceNudge =
        "Your last reply had no answer in it, so the user heard nothing. Give them your answer now, "
        + "in the user's language, or say plainly that you cannot answer."
}
