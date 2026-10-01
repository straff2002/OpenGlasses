import CryptoKit
import Foundation

// MARK: - Tombstones

/// The content-free record that a fact was forgotten, so the assistant does not quietly learn it
/// again from the next conversation (Plan GG decision 2).
///
/// A tombstone is a SHA-256 of the fact's normalised words, never the words. It lives beside the
/// rows it guards (`semantic_memory.sqlite`, `brain.sqlite`), so it shares their protection class
/// and backup exclusion. An *inferred* write whose digest matches is dropped; a *told-me* write
/// clears the tombstone and is kept — the wearer saying it again is the wearer changing their mind.
///
/// Matching is on the whole fact (key and value; source, relation and destination), so forgetting
/// "sister city: Wellington" does not stop the assistant learning "favourite city: Wellington".
enum MemoryTombstone {

    /// Lower-cased, underscores and punctuation to spaces, whitespace collapsed.
    static func normalise(_ text: String) -> String {
        let mapped = text.lowercased().map { ch -> Character in
            ch == "_" || ch.isPunctuation || ch.isSymbol ? " " : ch
        }
        return String(mapped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func digest(_ parts: String...) -> String {
        digest(parts)
    }

    static func digest(_ parts: [String]) -> String {
        let joined = parts.map(normalise).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Write provenance

/// Decides the origin of the `[REMEMBER…]` tags in one model reply.
///
/// The model emits the same tag whether the wearer said "remember that my sister lives in
/// Wellington" or merely mentioned her, so the tag alone cannot carry provenance. The utterance it
/// answered can: an explicit request to keep something is `toldMe`; anything else — including the
/// periodic memory review and background agent tasks, which have no utterance — is `inferred`.
/// Erring towards `inferred` is the safe direction: it can only make a forgotten fact harder to
/// re-learn, never make a guess look like something the wearer said.
enum MemoryOriginClassifier {

    static let explicitRequestPhrases: [String] = [
        "remember", "don't forget", "do not forget", "dont forget", "make a note", "note that",
        "keep in mind", "for the record", "save that", "store that", "write that down",
        "actually,", "actually my", "actually she", "actually he", "actually it's", "actually i ",
        "correction", "that's wrong", "that is wrong",
    ]

    static func originForReplyTags(userUtterance: String?) -> MemoryOrigin {
        guard let utterance = userUtterance?.lowercased(), !utterance.isEmpty else { return .inferred }
        let normalised = utterance.replacingOccurrences(of: "’", with: "'")
        return explicitRequestPhrases.contains(where: normalised.contains) ? .toldMe : .inferred
    }
}

// MARK: - Resolving a spoken reference to one fact

/// Pure: which facts a spoken phrase ("my sister lives in Wellington") refers to.
///
/// Voice Forget and Correct must resolve **exactly one** fact; this returns the best-scoring tier
/// so the caller can tell one from several from none and never guesses between them.
enum MemoryFactMatcher {

    private static let stopwords: Set<String> = [
        "the", "and", "that", "this", "my", "me", "you", "your", "about", "what", "know", "is",
        "are", "was", "were", "for", "with", "from", "she", "he", "her", "his", "they", "them",
        "it", "its", "of", "to", "in", "on", "at", "a", "an", "fact", "forget", "remember",
        "please", "do", "does", "did", "have", "has", "had",
    ]

    /// The words that carry the reference, folded for comparison.
    static func significantWords(_ text: String) -> [String] {
        MemoryTombstone.normalise(text.folding(options: [.diacriticInsensitive], locale: nil))
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// A query word matches a fact word when either is a prefix of the other, so "lives" finds
    /// "live" and "Wellington" finds "Wellington's" — without stemming tables.
    private static func matches(_ queryWord: String, in factWords: [String]) -> Bool {
        factWords.contains { word in
            word == queryWord
                || (queryWord.count >= 4 && word.hasPrefix(queryWord))
                || (word.count >= 4 && queryWord.hasPrefix(word))
        }
    }

    /// The share of a phrase's words a fact must contain to answer a question about it.
    static let browseShare = 0.5
    /// The stricter share a fact must contain to be *changed* by it: "forget my favourite colour"
    /// must not resolve to "favourite tea" on one shared word.
    static let changeShare = 2.0 / 3.0

    /// The facts the phrase most plausibly means: every fact sharing the highest share of the
    /// phrase's significant words, provided that share reaches `minimumShare`. Empty when nothing
    /// clears the bar.
    static func candidates(for query: String, in facts: [MemoryFact],
                           minimumShare: Double = browseShare) -> [MemoryFact] {
        let words = Array(Set(significantWords(query)))
        guard !words.isEmpty else { return [] }
        let scored: [(MemoryFact, Int)] = facts.map { fact in
            let factWords = significantWords(fact.text)
            return (fact, words.filter { matches($0, in: factWords) }.count)
        }
        guard let best = scored.map(\.1).max(), best > 0,
              Double(best) / Double(words.count) >= minimumShare - 1e-9 else { return [] }
        return MemoryFactRepository.ordered(scored.filter { $0.1 == best }.map(\.0))
    }
}

// MARK: - Agent notes that mention a fact

/// Pure: which lines of the agent's `memory.md` mention a fact. This is text matching over prose
/// the model wrote, so the lines are shown to the wearer before anything is removed.
enum MemoryNoteMatcher {

    /// The needles a line must contain, all of them, for the fact to count as mentioned.
    static func needles(for fact: MemoryFact) -> [String] {
        switch fact.kind {
        case .relation:
            // "Maria lives in Wellington": both ends, so a line about Maria's job does not match.
            let parts = fact.text.components(separatedBy: " ")
            guard let first = parts.first else { return [] }
            return [first, fact.correctableValue].filter { $0.count >= 3 }
        case .agentNote:
            return []   // the fact *is* a line; it is removed as itself
        default:
            let value = fact.correctableValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.count >= 4 ? [value] : []
        }
    }

    static func lines(_ lines: [String], mentioning fact: MemoryFact) -> [String] {
        let needles = needles(for: fact)
        guard !needles.isEmpty else { return [] }
        return lines.filter { line in
            needles.allSatisfy { line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

// MARK: - Spoken summary

/// Pure: "What do you know about me?" in one or two sentences — counts per group and the three
/// most recent facts (Plan GG decision 5). Health facts are never counted or read aloud here.
enum MemorySpokenSummary {

    static let recentCount = 3

    static func groupNoun(_ group: MemoryFactGroup, count: Int) -> String {
        switch group {
        case .people: return count == 1 ? "1 about people" : "\(count) about people"
        case .places: return count == 1 ? "1 place" : "\(count) places"
        case .preferences: return count == 1 ? "1 preference" : "\(count) preferences"
        case .unfinished: return count == 1 ? "1 unfinished thing" : "\(count) unfinished things"
        case .other: return count == 1 ? "1 other thing" : "\(count) other things"
        case .health: return ""
        }
    }

    static func summary(_ facts: [MemoryFact]) -> String {
        let speakable = facts.filter { $0.group != .health }
        guard !speakable.isEmpty else {
            return "I don't have anything saved about you yet. Say \"remember that…\" and I'll keep it."
        }
        let counts = Dictionary(grouping: speakable, by: \.group).mapValues(\.count)
        let parts = MemoryFactGroup.displayOrder.compactMap { group -> String? in
            guard let n = counts[group], n > 0, group != .health else { return nil }
            return groupNoun(group, count: n)
        }
        let total = speakable.count
        var text = "I know \(total) \(total == 1 ? "thing" : "things") about you: \(listed(parts))."
        let recent = MemoryFactRepository.ordered(speakable).prefix(recentCount).map(\.text)
        if !recent.isEmpty {
            text += " Most recently: \(recent.joined(separator: "; "))."
        }
        text += " The full list is in Memory on your phone."
        return text
    }

    static func listed(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
