import Foundation

/// The card a hint shows with no model (Plan MO §5 step 4): keyword mode, no provider reachable,
/// or the moment before the model's answer lands.
///
/// From the passages the search returned, the sentence that holds the most of the query's content
/// words, trimmed to two lens lines (`HintLimits.passageCardMaxCharacters`) at a word boundary,
/// with its document's name and the ids that open it on the phone. Ties go to the earlier passage,
/// then the earlier sentence: the search ranks passages best first. A sentence that shares no
/// content word with the query is no card at all.
///
/// Words are compared folded, with a plural "s" ignored ("prices" matches "price").
struct PassageHint: Equatable, Sendable {
    let text: String
    let documentName: String
    let documentId: String
    let chunkIndex: Int

    static func pick(from passages: [HintPassage], for query: String) -> PassageHint? {
        let terms = Set(HintText.contentWords(query).subtracting(HintText.questionWords).map(stem))
        guard !terms.isEmpty else { return nil }
        var best: (score: Int, sentence: String, passage: HintPassage)?
        for passage in passages {
            for sentence in HintText.sentences(HintText.collapsingWhitespace(passage.text)) {
                let words = Set(HintText.words(sentence).map(stem))
                let score = terms.intersection(words).count
                if score > (best?.score ?? 0) { best = (score, sentence, passage) }
            }
        }
        guard let best else { return nil }
        let (line, wasCut) = HintText.cut(best.sentence, maxCharacters: HintLimits.passageCardMaxCharacters)
        return PassageHint(text: HintText.trimmingTrailingPunctuation(line, includingStops: wasCut),
                           documentName: best.passage.documentName,
                           documentId: best.passage.documentId,
                           chunkIndex: best.passage.chunkIndex)
    }

    /// A word without a plural "s" ("prices" → "price", "glass" stays).
    private static func stem(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }
}
