import Foundation

/// Retrieve-or-silence citation gate for safety/medical speech (Plan CJ item 3).
///
/// Invariant: the assistant may only *speak* a safety/medical citation when retrieval actually
/// returned the underlying text. A proposed-but-unretrieved citation is queued for review and
/// the spoken answer omits it — an authoritative-sounding reference the model free-formed is
/// worse than none, because the wearer can't check it mid-task.
///
/// Two pure operations:
/// - `filter(proposed:retrieved:)` — for verticals that carry explicit citation lists: split
///   into speakable (retrieval-backed) and queued (unbacked).
/// - `scrub(_:)` — for LLM-composed advisory prose that *should contain no citations at all*
///   (the model was grounded only in the user's own vault entries): remove citation-shaped
///   authority claims ("per FDA guidance", "section 4.2 of…", "WHO recommends…") sentence-wise
///   and return them separately for the review queue.
///
/// Both are deterministic and total — no retrieval, no network, no model.
enum CitationGate {

    /// Outcome of scrubbing LLM prose: what may be spoken, and what was withheld.
    struct ScrubResult: Equatable {
        /// The text with citation-bearing sentences removed (may be empty).
        let spokenText: String
        /// The removed sentences, verbatim — the review-queue payload.
        let queuedCitations: [String]
    }

    /// Split explicit proposed citations by whether retrieval backs them. Matching is
    /// case-insensitive on the trimmed citation key.
    static func filter(proposed: [String], retrieved: Set<String>) -> (spoken: [String], queued: [String]) {
        let retrievedKeys = Set(retrieved.map { normalise($0) })
        var spoken: [String] = []
        var queued: [String] = []
        for citation in proposed {
            if retrievedKeys.contains(normalise(citation)) {
                spoken.append(citation)
            } else {
                queued.append(citation)
            }
        }
        return (spoken, queued)
    }

    /// Citation-shaped authority claims. Deliberately aimed at *external-source* claims —
    /// "your vault entries", "your pharmacist" and other user-directed phrasing don't match.
    private static let citationPatterns: [String] = [
        // "according to / as per / as recommended by / as stated in … guidelines/protocol/label…"
        #"(?i)\b(according to|as per|as stated in|as recommended by|as advised by|as noted in|citing|per)\s+(the\s+)?[^,.;:]{1,60}?(guidelines?|guidance|protocols?|standards?|recommendations?|monograph|labell?ing|label)\b"#,
        // "the X guidelines state/recommend…"
        #"(?i)\b(the\s+)?[A-Z][A-Za-z-]{1,24}\s+(guidelines?|protocol|monograph)\s+(state|says?|recommends?|advises?|suggests?)\b"#,
        // "section 4.2 (of …)"
        #"(?i)\bsection\s+\d+(\.\d+)*\b"#,
        // A health-authority named as the source.
        #"\b(FDA|WHO|CDC|NHS|NICE|EMA|ERC|AHA|TGA|Medsafe|Health Canada)\b"#,
    ]

    /// Whether one sentence contains a citation-shaped authority claim.
    static func containsCitationClaim(_ sentence: String) -> Bool {
        citationPatterns.contains { pattern in
            sentence.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Remove citation-bearing sentences from LLM-composed advisory prose.
    static func scrub(_ text: String) -> ScrubResult {
        let sentences = splitSentences(text)
        var kept: [String] = []
        var queued: [String] = []
        for sentence in sentences {
            if containsCitationClaim(sentence) {
                queued.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                kept.append(sentence)
            }
        }
        let spoken = kept.joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrubResult(spokenText: spoken, queuedCitations: queued)
    }

    // MARK: - Pieces

    private static func normalise(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Sentence split that keeps terminators attached (so rejoining preserves punctuation).
    /// A terminator only ends a sentence when followed by whitespace or end-of-text, so a
    /// decimal like "section 4.2" never splits mid-number. Deliberately simple beyond that:
    /// advisory prose is 1–3 short model sentences, not literature.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let isTerminator = character == "." || character == "!" || character == "?" || character == "\n"
            let atEnd = index == characters.count - 1
            if isTerminator && (atEnd || characters[index + 1].isWhitespace) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current)
        }
        return sentences
    }
}
