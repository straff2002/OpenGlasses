import Foundation

/// Recognises "off the record" and the other ways a wearer starts, or ends, a private conversation
/// by voice (Plan LU §2). Pure: it reads a transcript and says what it asked for.
///
/// It runs in `handleTranscription` before `prepareThreadForTurn` (P1), so the turn that asks for
/// privacy is never saved anywhere.
///
/// **The rule.** A phrase counts only at the very start of the utterance, and only when what
/// follows it is a separator — a comma, a colon, a full stop, a semicolon, an exclamation mark, a
/// spaced dash, the word "please" — or nothing at all. So "Off the record, is a mole that's changed
/// shape worth seeing a doctor about?" starts one, and "Private school fees are due", "Is this
/// private property?" and "Privately owned land" do not: the first and last are not followed by a
/// separator, the middle one is not at the start. A question mark is never a separator, so "This is
/// private?" — a wearer asking whether it is — does not start one either.
///
/// Speech recognition capitalises, adds commas and full stops, and sometimes hyphenates
/// ("off-the-record"), so case is ignored, punctuation is read as separators rather than as part of
/// a word, and a hyphen may join a phrase's words.
///
/// **A leading wake phrase.** Wake-word turns arrive without the wake phrase (dictation starts after
/// it is heard), but a push-to-talk or Action Button turn carries whatever the wearer said,
/// "Hey Avenkin, off the record…" included — the persona matcher strips the same kind of prefix.
/// The caller passes the configured wake phrases, and one of them (optionally after "hey" or "ok")
/// is skipped before the phrase is looked for.
///
/// **Languages.** The phrase set is per language. English ships first; every other language returns
/// no match until its phrases are added after review (decision 5). Those languages still get the
/// button and the watch entry.
enum PrivateStartPhrase {

    /// What followed the phrase.
    enum Remainder: Equatable, Sendable {
        /// The rest of the utterance, as spoken (casing kept): the private conversation's first
        /// question, or what to answer after ending one.
        case question(String)
        /// The phrase was said alone. A start answers "Private. Go ahead." and listens.
        case nothingFollowed
    }

    enum Match: Equatable, Sendable {
        /// A start phrase. The remainder is the first private question, if there was one.
        case start(Remainder)
        /// An end phrase ("end private", "back on the record"). The remainder, if any, is an
        /// ordinary question asked after the private conversation ends.
        case end(Remainder)
    }

    /// One language's phrases, each as its words in order.
    struct PhraseSet: Equatable, Sendable {
        let start: [[String]]
        let end: [[String]]
        /// Words that may follow a phrase in place of punctuation ("go private please, …").
        let politeWords: Set<String>
        /// Words that may come before a wake phrase ("hey Avenkin").
        let wakeLeadIns: Set<String>
    }

    static let english = PhraseSet(
        start: [
            ["off", "the", "record"],
            ["go", "private"],
            ["private", "conversation"],
            ["privately"],
            ["just", "between", "us"],
            ["this", "is", "private"],
        ],
        end: [
            ["end", "private"],
            ["stop", "private"],
            ["back", "on", "the", "record"],
            // The natural longer form of the first two; without these, "end private conversation"
            // would not match, because "conversation" is not a separator.
            ["end", "private", "conversation"],
            ["stop", "private", "conversation"],
        ],
        politeWords: ["please"],
        wakeLeadIns: ["hey", "ok", "okay"])

    /// Phrase sets by language code. Add a language here once its phrases are reviewed.
    static let phraseSets: [String: PhraseSet] = ["en": english]

    /// The phrase set for a locale or language identifier ("en", "en-GB", "en_NZ"), or nil when the
    /// language has none yet.
    static func phraseSet(forLanguage identifier: String) -> PhraseSet? {
        let code = identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { $0.lowercased() } ?? ""
        return phraseSets[code]
    }

    /// What the utterance asks for, or nil when it is an ordinary turn.
    ///
    /// - Parameters:
    ///   - utterance: the transcript `handleTranscription` received.
    ///   - language: the recognition locale's identifier.
    ///   - wakePhrases: the configured wake phrase and its alternatives, any of which may lead the
    ///     utterance.
    static func match(_ utterance: String, language: String = "en",
                      wakePhrases: [String] = []) -> Match? {
        guard let set = phraseSet(forLanguage: language) else { return nil }
        let tokens = tokenize(utterance)
        var start = 0
        skipMarks(tokens, &start)
        start = afterWakePhrase(tokens, from: start, wakePhrases: wakePhrases, set: set)

        if let remainder = remainder(after: set.end, in: tokens, from: start,
                                     utterance: utterance, set: set) {
            return .end(remainder)
        }
        if let remainder = remainder(after: set.start, in: tokens, from: start,
                                     utterance: utterance, set: set) {
            return .start(remainder)
        }
        return nil
    }

    // MARK: - Tokens

    struct Token: Equatable {
        enum Kind: Equatable {
            case word(String)
            case mark(Character)
        }
        let kind: Kind
        let range: Range<String.Index>
        /// Whether whitespace came straight after the token (or it ends the utterance).
        var spaceAfter: Bool
    }

    /// Words (letters, digits and inner apostrophes, lower-cased) and single punctuation marks.
    /// Whitespace only separates.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if !tokens.isEmpty { tokens[tokens.count - 1].spaceAfter = true }
                index = text.index(after: index)
            } else if isWordCharacter(character) {
                var end = text.index(after: index)
                while end < text.endIndex, isWordCharacter(text[end]) || isApostrophe(text[end]) {
                    end = text.index(after: end)
                }
                let word = text[index..<end].lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
                tokens.append(Token(kind: .word(word), range: index..<end, spaceAfter: end == text.endIndex))
                index = end
            } else {
                let end = text.index(after: index)
                tokens.append(Token(kind: .mark(character), range: index..<end, spaceAfter: end == text.endIndex))
                index = end
            }
        }
        return tokens
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }

    /// Marks that may stand between the words of one phrase: a hyphen, as in "off-the-record".
    private static func isJoiner(_ character: Character) -> Bool {
        character == "-" || character == "‐"
    }

    /// Whether a mark ends the phrase. A plain hyphen counts only when spaced ("privately - is
    /// it…"); attached to the next word ("privately-owned") it is part of a compound.
    private static func isSeparator(_ token: Token) -> Bool {
        guard case .mark(let character) = token.kind else { return false }
        switch character {
        case ",", ":", ";", ".", "!", "…", "—", "–", "，", "：", "。", "！":
            return true
        case "-":
            return token.spaceAfter
        default:
            return false
        }
    }

    private static func skipMarks(_ tokens: [Token], _ index: inout Int) {
        while index < tokens.count, case .mark(let character) = tokens[index].kind, character != "?" {
            index += 1
        }
    }

    /// The index just past `words` if they lead `tokens` from `index`, joined by whitespace or a
    /// hyphen; nil otherwise.
    private static func indexAfter(_ words: [String], in tokens: [Token], from index: Int) -> Int? {
        var cursor = index
        for (offset, word) in words.enumerated() {
            if offset > 0 {
                while cursor < tokens.count, case .mark(let character) = tokens[cursor].kind,
                      isJoiner(character) {
                    cursor += 1
                }
            }
            guard cursor < tokens.count, case .word(let found) = tokens[cursor].kind, found == word else {
                return nil
            }
            cursor += 1
        }
        return cursor
    }

    /// Past a leading wake phrase ("Avenkin", "hey Avenkin", "ok Avenkin") and the punctuation
    /// after it, or `index` unchanged when the utterance doesn't start with one.
    private static func afterWakePhrase(_ tokens: [Token], from index: Int, wakePhrases: [String],
                                        set: PhraseSet) -> Int {
        var candidates: [[String]] = []
        for phrase in wakePhrases {
            let words = tokenize(phrase).compactMap { token -> String? in
                if case .word(let word) = token.kind { return word }
                return nil
            }
            guard !words.isEmpty else { continue }
            candidates.append(words)
            if let first = words.first, !set.wakeLeadIns.contains(first) {
                candidates.append(contentsOf: set.wakeLeadIns.sorted().map { [$0] + words })
            }
        }
        for words in candidates.sorted(by: { $0.count > $1.count }) {
            if var cursor = indexAfter(words, in: tokens, from: index) {
                skipMarks(tokens, &cursor)
                return cursor
            }
        }
        return index
    }

    /// What follows the longest of `phrases` that leads the utterance from `index` and is followed
    /// by a separator, a polite word or nothing; nil when none does.
    private static func remainder(after phrases: [[String]], in tokens: [Token], from index: Int,
                                  utterance: String, set: PhraseSet) -> Remainder? {
        for words in phrases.sorted(by: { $0.count > $1.count }) {
            guard var cursor = indexAfter(words, in: tokens, from: index) else { continue }
            if cursor == tokens.count { return .nothingFollowed }

            var separated = false
            while cursor < tokens.count {
                let token = tokens[cursor]
                if isSeparator(token) {
                    separated = true
                } else if case .word(let word) = token.kind, set.politeWords.contains(word) {
                    separated = true
                } else {
                    break
                }
                cursor += 1
            }
            guard separated else { continue }

            // Only marks left ("Off the record, ?") is a phrase said alone.
            let rest = tokens[cursor...]
            guard rest.contains(where: { if case .word = $0.kind { return true }; return false }),
                  let first = rest.first else {
                return .nothingFollowed
            }
            let question = utterance[first.range.lowerBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .question(question)
        }
        return nil
    }
}
