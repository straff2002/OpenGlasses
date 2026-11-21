import Foundation

/// One hint as the session delivers it (Plan MO §5–§6): to the lens as two pages, to the ear as a
/// few words, and to the phone's list of the last ten. In memory only; nothing writes it anywhere.
struct LiveHint: Identifiable, Equatable, Sendable {

    /// Where the words came from.
    enum Source: String, Equatable, Sendable {
        /// The best passage's sentence, with no model (§5 step 4): the first card, keyword mode,
        /// or no provider reachable.
        case passage
        /// The model's hint, read and cut by `HintReply`.
        case model
        /// Lecture mode's key point.
        case keyPoint
    }

    /// A serial within the session: the lens card's number, and the phone list's id.
    let id: Int
    /// The question the hint answers, as the caption had it; nil for a keyword or a key point.
    let question: String?
    /// The keyword that fired, in keyword mode.
    let keyword: String?
    /// The glance line: the hint, the passage card's line, or the key point.
    var line: String
    /// The second page: the model's `full`, or the passage card's line again. May be empty.
    var full: String
    /// The ear form, at most `HintLimits.spokenHintMaxWords` words.
    var spoken: String
    var source: Source
    /// Answered from general knowledge, not the documents (decision 6).
    var general: Bool
    /// The passage the card stands on, so a press can open it on the phone. Nil for a model hint
    /// with no passage, and for a key point.
    var passage: PassageHint?
    /// When the caption that asked was final.
    let askedAt: Date

    /// The document's name for the card's second page, "General" for general knowledge.
    var sourceLabel: String? {
        if general { return String(localized: "General knowledge",
                                   comment: "Live hints card: the hint came from general knowledge, not the wearer's documents.") }
        return passage?.documentName
    }
}

/// A short glance at the question for the top of the lens card (Plan MO §6: "the question in 2–4
/// words, dimmed"): the question's own words after its opening question and filler words, at most
/// `HintLimits.questionGlanceWords` of them, first letter capitalised, with a question mark.
///
/// Pure.
enum HintQuestionGlance {

    static func glance(_ question: String) -> String {
        let tokens = HintText.collapsingWhitespace(question).split(separator: " ").map(String.init)
        let skippable = HintText.stopWords.union(HintText.questionWords)
            .union(HintTrigger.leadingFillers["en"] ?? [])
        let kept = tokens.drop { token in
            let folded = HintText.words(token)
            return !folded.isEmpty && folded.allSatisfy { skippable.contains($0) }
        }
        let body = kept.isEmpty ? tokens : Array(kept)
        var words = Array(body.prefix(HintLimits.questionGlanceWords))
        guard !words.isEmpty else { return "" }
        let wasCut = body.count > words.count
        var last = words.removeLast()
        while let character = last.last, character.isPunctuation { last.removeLast() }
        words.append(last)
        var line = words.joined(separator: " ")
        if let first = line.first { line = first.uppercased() + line.dropFirst() }
        return line + (wasCut ? "…?" : "?")
    }
}
