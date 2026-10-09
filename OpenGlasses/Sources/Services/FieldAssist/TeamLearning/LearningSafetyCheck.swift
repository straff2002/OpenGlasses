import Foundation

/// Whether a finding touches what the vault's safety core says (Plan FP §5, contract §7.3) — a
/// deterministic, lexical check run at review, which **surfaces and never rejects**.
///
/// "The manual says X but on this unit…" is precisely the knowledge worth capturing, so a
/// collision is not a refusal: it makes approval ask a second time, and an entry approved through
/// that second confirmation carries `contradictsSafetyNote: true`, so the answer can say the
/// crew's finding departs from the manual's safety text. The standing prompt rule — a learning
/// never overrides a safety note — applies to every entry whatever this says.
///
/// **What counts as the safety core:** every core file whose name contains "safety", the same rule
/// `VaultPromptBuilder` uses to keep those files whole in the prompt.
///
/// **The heuristic, and its limit.** A finding collides when it shares a word with either
/// - the `##` (and deeper) headings of a safety file — the vault author's own names for the
///   hazards ("Electrical safety — Lockout/Tagout", "Refrigerant handling", "Flame rollout"),
///   less a short list of words that appear in headings without naming a hazard; or
/// - a fixed list of hazard words (`hazardTerms`) — lockout, bypass, jumper, energized, gas,
///   refrigerant and the like — so a vault whose safety file has no useful headings still trips.
///
/// It is vocabulary, not meaning: it cannot see a paraphrase that avoids every listed word
/// ("I bridged the two terminals on the limit"), and it flags a harmless mention ("checked the gas
/// pressure was in range"). Both errors land in front of a person, which is where this check
/// sends everything; it is a prompt for the reviewer's attention, not a judgement.
enum LearningSafetyCheck {

    /// The result: whether it collides, and on which words — shown to the reviewer.
    struct Finding: Equatable {
        let terms: [String]
        /// The safety files whose headings supplied a matched term (empty when only the fixed list
        /// matched).
        let files: [String]

        var collides: Bool { !terms.isEmpty }

        static let none = Finding(terms: [], files: [])
    }

    /// Hazard words checked whatever the safety file's headings say.
    static let hazardTerms: Set<String> = [
        "lockout", "tagout", "loto", "energized", "energised", "de-energize", "de-energise",
        "voltage", "arc", "bypass", "bypassed", "jumper", "jumpered", "defeat", "defeated",
        "override", "overridden", "interlock", "gas", "flame", "rollout", "ignition", "flammable",
        "refrigerant", "a2l", "brazing", "torch", "monoxide", "confined", "ppe", "venting",
        "grounding", "earthing",
    ]

    /// Heading words that name no hazard, left out so every heading does not match every finding.
    static let headingStopWords: Set<String> = [
        "safety", "before", "after", "when", "while", "with", "without", "from", "into", "onto",
        "about", "the", "and", "for", "any", "all", "this", "that", "these", "those", "your",
        "reference", "field", "general", "notes", "note", "should", "remind", "technician", "what",
        "where", "which", "opening", "open", "working", "work", "handling", "codes", "code", "unit",
        "units", "model", "models", "emergency", "shutdown",
    ]

    /// Check the text a reviewer is about to approve against the vault's core files.
    static func check(finding: String, symptom: String?, fix: String?,
                      coreFiles: [(filename: String, contents: String)]) -> Finding {
        let words = Self.words(in: [finding, symptom ?? "", fix ?? ""].joined(separator: " "))
        guard !words.isEmpty else { return .none }

        var matched = Set<String>()
        var files: [String] = []
        for file in coreFiles where file.filename.lowercased().contains("safety") {
            let terms = headingTerms(in: file.contents)
            let hit = words.intersection(terms)
            if !hit.isEmpty {
                matched.formUnion(hit)
                files.append(file.filename)
            }
        }
        matched.formUnion(words.intersection(hazardTerms))
        return Finding(terms: matched.sorted(), files: files)
    }

    /// The words of a safety file's headings, less the stop words. Words of three letters or more,
    /// so `PPE`, `gas` and `arc` count and `of`/`to` do not.
    static func headingTerms(in contents: String) -> Set<String> {
        var terms = Set<String>()
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix("##") {
            let heading = line.drop { $0 == "#" }
            terms.formUnion(words(in: String(heading)).subtracting(headingStopWords))
        }
        return terms
    }

    /// Lowercased words, split on anything but letters, digits and an inner hyphen.
    static func words(in text: String) -> Set<String> {
        var result = Set<String>()
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted
        for raw in text.lowercased().components(separatedBy: separators) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard word.count >= 3 else { continue }
            result.insert(word)
        }
        return result
    }
}
