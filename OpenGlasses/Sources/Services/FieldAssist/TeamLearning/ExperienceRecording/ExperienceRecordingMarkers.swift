import Foundation

/// The spoken markers inside an experience recording (Plan IM P1). Pure.
///
/// Two of them, and deliberately narrow, because a false marker cuts a technician off mid-case:
///
/// - **next case** — "that's one, next case" ends the recording and starts the next. Heard
///   anywhere in a stretch of speech when it opens with "that's one" (or "that is one"), and on
///   its own ("next case", "okay, next case") when it is the whole stretch — "in the next case
///   I'd check the board" is speech, not a marker.
/// - **finish** — "that's all", "that's everything", "stop recording", "I'm done", and the like,
///   only as the whole stretch of speech or its whole last sentence, so "and that's all it needed"
///   stays in the case. A bare "next case" is read the same way.
///
/// **In the recording's language, and always in English** (owner decision 2026-11-27). The
/// recogniser transcribes in the phone's speech language (`LiveExperienceCapture`'s locale), so
/// the recorder listens for that language's three phrases (`translations`) as well as English's.
/// The same rules hold in every language: the long marker anywhere, the bare one and the finish
/// only as the whole stretch or its last sentence. Matching reads what the recogniser wrote, not
/// how it wrote it: case, punctuation (`،` `，` `、` `。` `؟` `۔` included), apostrophe variants,
/// width, extra spaces, `ё`/`е`, Arabic vowel marks and letter forms, and "1" for the word for
/// one. Han, kana and Hangul are read a character at a time, so a recogniser that writes Japanese,
/// Chinese or Korean without spaces (or with them in odd places) still matches.
///
/// A stretch is one final result from the recogniser: what was said between pauses. The text
/// before a marker belongs to the case it ends; the text after a next-case marker opens the next.
enum ExperienceRecordingMarkers {

    enum Marker: Equatable, Sendable {
        case nextCase
        case finish
    }

    /// One stretch of speech, read for a marker.
    struct Split: Equatable, Sendable {
        /// What belongs to the case being recorded.
        let before: String
        let marker: Marker?
        /// What opens the next case (after a next-case marker only).
        let after: String
    }

    // MARK: - The phrases

    /// The three phrases one language says: the long next-case marker, the bare one it ends with,
    /// and the finish. What the recorder listens for and what its copy tells the technician to say.
    struct Phrases: Equatable, Sendable {
        let nextCase: String
        let bareNextCase: String
        let finish: String
    }

    static let english = Phrases(nextCase: "that's one, next case", bareNextCase: "next case", finish: "that's all")

    /// A translation: its phrases, and the ways a recogniser writes the word for one in its long
    /// marker (as well as "1"): Dutch "één" often comes back as "een".
    struct Translation: Sendable {
        let phrases: Phrases
        let one: [String]
    }

    /// The one table of translated markers, matched against recogniser output — so here and not in
    /// the string catalog. Keyed by language, with Chinese by script (`key(for:)`).
    static let translations: [String: Translation] = [
        "ar": Translation(phrases: Phrases(nextCase: "هذه واحدة، الحالة التالية", bareNextCase: "الحالة التالية",
                                           finish: "هذا كل شيء"), one: ["واحدة"]),
        "es": Translation(phrases: Phrases(nextCase: "esa es una, siguiente caso", bareNextCase: "siguiente caso",
                                           finish: "eso es todo"), one: ["una"]),
        "fr": Translation(phrases: Phrases(nextCase: "ça en fait un, cas suivant", bareNextCase: "cas suivant",
                                           finish: "c'est tout"), one: ["un"]),
        "hu": Translation(phrases: Phrases(nextCase: "ez egy, következő eset", bareNextCase: "következő eset",
                                           finish: "ennyi volt"), one: ["egy"]),
        "it": Translation(phrases: Phrases(nextCase: "questo è uno, caso successivo", bareNextCase: "caso successivo",
                                           finish: "è tutto"), one: ["uno"]),
        "ja": Translation(phrases: Phrases(nextCase: "これで一件、次のケース", bareNextCase: "次のケース",
                                           finish: "以上です"), one: ["一"]),
        "ko": Translation(phrases: Phrases(nextCase: "이걸로 하나, 다음 사례", bareNextCase: "다음 사례",
                                           finish: "이상입니다"), one: []),
        "nl": Translation(phrases: Phrases(nextCase: "dat is er één, volgend geval", bareNextCase: "volgend geval",
                                           finish: "dat was het"), one: ["één", "een"]),
        "pt": Translation(phrases: Phrases(nextCase: "esse é um, próximo caso", bareNextCase: "próximo caso",
                                           finish: "é só isso"), one: ["um"]),
        "ru": Translation(phrases: Phrases(nextCase: "это один, следующий случай", bareNextCase: "следующий случай",
                                           finish: "это всё"), one: ["один"]),
        "ur": Translation(phrases: Phrases(nextCase: "یہ ایک ہو گیا، اگلا کیس", bareNextCase: "اگلا کیس",
                                           finish: "بس اتنا ہی"), one: ["ایک"]),
        "zh-Hans": Translation(phrases: Phrases(nextCase: "这是一个，下一个案例", bareNextCase: "下一个案例",
                                                finish: "就这些"), one: ["一"]),
        "zh-Hant": Translation(phrases: Phrases(nextCase: "這是一個，下一個案例", bareNextCase: "下一個案例",
                                                finish: "就這些"), one: ["一"]),
    ]

    /// The table's key for a recogniser locale: its language, and for Chinese its script —
    /// written in the identifier, else the language's likely script for its region (zh-TW and
    /// zh-HK are Traditional), else Simplified. Nil for English and any language not in the table.
    static func key(for locale: Locale) -> String? {
        let parts = locale.identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty else { return nil }
        if language == "zh" {
            let written = parts.dropFirst().first { $0.count == 4 }?.capitalized
            let script = written ?? SpeechLocaleResolver.scriptCode(of: locale.identifier) ?? "Hans"
            return script == "Hant" ? "zh-Hant" : "zh-Hans"
        }
        return translations[language] == nil ? nil : language
    }

    /// The phrases for a recogniser locale: its translation, or English.
    static func phrases(for locale: Locale) -> Phrases {
        key(for: locale).flatMap { translations[$0]?.phrases } ?? english
    }

    /// Which phrases a reading accepts. English always.
    struct Listening: Sendable {
        fileprivate let vocabulary: Vocabulary

        /// English only.
        static let english = Listening(vocabulary: .english)

        /// English and the language the recogniser transcribes in — what the recorder hears with.
        static func language(_ locale: Locale) -> Listening {
            guard let key = key(for: locale), let translated = Vocabulary.translated[key] else { return .english }
            return Listening(vocabulary: Vocabulary.english.merged(with: translated))
        }

        /// English and every translation — for a transcript read away from the phone that made it,
        /// which carries no record of the language it was spoken in (the drafting pass, Plan IM P2).
        static let everyLanguage = Listening(vocabulary: Vocabulary.translated.keys.sorted()
            .reduce(Vocabulary.english) { $0.merged(with: Vocabulary.translated[$1]!) })
    }

    // MARK: - Reading a stretch

    /// Read one stretch. With no marker, the whole stretch is `before`.
    static func split(_ stretch: String, listening: Listening = .english) -> Split {
        let vocabulary = listening.vocabulary
        let trimmed = stretch.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = units(trimmed)
        guard !words.isEmpty else { return Split(before: "", marker: nil, after: "") }

        if vocabulary.isFinish(words.map(\.word)) { return Split(before: "", marker: .finish, after: "") }

        // "that's one, next case" anywhere in the stretch.
        let spoken = words.map(\.word)
        for start in spoken.indices {
            guard let length = vocabulary.nextCaseLength(in: spoken, at: start) else { continue }
            let end = start + length
            // "Okay, that's one, next case": a filler in front is not part of the case.
            let lead = spoken[..<start]
            let before = lead.allSatisfy({ vocabulary.fillers.contains($0) }) ? "" : original(trimmed, upTo: words[start - 1])
            let after = end < words.count ? original(trimmed, from: words[end]) : ""
            // "that's one, next case. That's all." — a finish straight after the marker ends it.
            let rest = Array(spoken[end...])
            if !rest.isEmpty, vocabulary.isFinish(rest) {
                return Split(before: before, marker: .finish, after: "")
            }
            return Split(before: before, marker: .nextCase, after: after)
        }

        // "next case" as the whole stretch, with at most a filler in front.
        if vocabulary.isBareNextCase(spoken) {
            return Split(before: "", marker: .nextCase, after: "")
        }

        // "…sealed the cover. That's all." — the recogniser punctuates, so a marker that is the
        // stretch's whole last sentence is one too, said without a pause before it. "…the fan,
        // that's all" (no sentence end) and "That's all it needed." (more than the marker) stay
        // in the case.
        if let (head, tail) = lastSentence(of: trimmed) {
            let tailWords = units(tail).map(\.word)
            if vocabulary.isFinish(tailWords) { return Split(before: head, marker: .finish, after: "") }
            if vocabulary.isBareNextCase(tailWords) { return Split(before: head, marker: .nextCase, after: "") }
        }
        return Split(before: trimmed, marker: nil, after: "")
    }

    /// What ends a sentence, in every script the table writes: `。` and `！`/`？` (CJK), `؟` (Arabic
    /// and Urdu), `۔` (Urdu), the halfwidth `｡`.
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "。", "！", "？", "؟", "۔", "｡", "．"]
    /// What may trail a sentence end before the text stops: a space or a comma of any script.
    private static let trailing: Set<Character> = [",", "،", "，", "、", "､"]

    /// The text before the stretch's last sentence, and that sentence, when it has more than one.
    private static func lastSentence(of text: String) -> (head: String, tail: String)? {
        var core = Substring(text)
        while let last = core.last, sentenceEnds.contains(last) || trailing.contains(last) || last.isWhitespace {
            core = core.dropLast()
        }
        guard let boundary = core.lastIndex(where: { sentenceEnds.contains($0) }) else { return nil }
        let head = core[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = core[core.index(after: boundary)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return (head, tail)
    }

    /// A whole transcript as cases, split at every next-case marker — what P2's segmenter starts
    /// from, and how a test reads a recording the way the recorder did. Empty cases are dropped;
    /// a finish marker ends the transcript.
    static func cases(in stretches: [String], listening: Listening = .english) -> [String] {
        var cases: [String] = []
        var current: [String] = []
        func close() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { cases.append(text) }
            current = []
        }
        for stretch in stretches {
            let split = split(stretch, listening: listening)
            if !split.before.isEmpty { current.append(split.before) }
            switch split.marker {
            case .none:
                continue
            case .finish:
                close()
                return cases
            case .nextCase:
                close()
                if !split.after.isEmpty { current.append(split.after) }
            }
        }
        close()
        return cases
    }

    // MARK: - Matching

    /// The unit sequences a reading matches, each a phrase as `units` reads it.
    fileprivate struct Vocabulary: Sendable {
        var nextCase: [[String]]
        var bareNextCase: [[String]]
        var finishes: [[String]]
        var fillers: Set<String>
        var courtesies: Set<String>
        /// The ways of writing the word for one, any of which (or "1") may stand for another.
        var ones: Set<String>

        /// English, as P1 shipped it: "that is one" and "that's 1" as well as the phrase, "new
        /// case", and the finishes a technician reaches for.
        static let english = Vocabulary(
            nextCase: [["thats", "one"], ["that", "is", "one"], ["thats", "1"], ["that", "is", "1"]]
                .map { $0 + ["next", "case"] },
            bareNextCase: [["next", "case"], ["new", "case"]],
            finishes: [
                ["thats", "all"], ["that", "is", "all"], ["thats", "everything"], ["that", "is", "everything"],
                ["thats", "it", "for", "now"], ["stop", "recording"], ["finish", "recording"], ["end", "recording"],
                ["finished", "recording"], ["im", "done"], ["i", "am", "done"], ["done", "recording"],
                ["thats", "all", "for", "now"], ["thats", "one", "thats", "all"], ["thats", "one", "and", "thats", "all"],
                ["thats", "1", "thats", "all"],
            ],
            fillers: ["okay", "ok", "right", "so", "and", "alright", "um", "uh"],
            courtesies: ["thanks", "thank", "you", "please"],
            ones: [])

        /// Each translation's phrases as units: the long marker, the bare one, the finish, and the
        /// long marker's opening followed by the finish ("esa es una, eso es todo"), as English
        /// has "that's one, that's all".
        static let translated: [String: Vocabulary] = translations.mapValues { translation in
            let phrases = translation.phrases
            let long = units(phrases.nextCase).map(\.word)
            let bare = units(phrases.bareNextCase).map(\.word)
            let finish = units(phrases.finish).map(\.word)
            var finishes = [finish]
            if long.count > bare.count, Array(long.suffix(bare.count)) == bare {
                finishes.append(Array(long.dropLast(bare.count)) + finish)
            }
            let ones = translation.one.map { units($0).map(\.word) }.filter { $0.count == 1 }.map { $0[0] }
            return Vocabulary(nextCase: [long], bareNextCase: [bare], finishes: finishes,
                              fillers: [], courtesies: [], ones: Set(ones))
        }

        func merged(with other: Vocabulary) -> Vocabulary {
            Vocabulary(nextCase: nextCase + other.nextCase, bareNextCase: bareNextCase + other.bareNextCase,
                       finishes: finishes + other.finishes, fillers: fillers.union(other.fillers),
                       courtesies: courtesies.union(other.courtesies), ones: ones.union(other.ones))
        }

        /// Whether `heard` says `phrase`, "1" or another way of writing it standing for the word for one.
        func matches(_ heard: ArraySlice<String>, _ phrase: [String]) -> Bool {
            guard heard.count == phrase.count else { return false }
            return zip(heard, phrase).allSatisfy { said, wanted in
                said == wanted || (ones.contains(wanted) && (said == "1" || ones.contains(said)))
            }
        }

        /// How many units starting at `start` make a long next-case marker, or nil.
        func nextCaseLength(in words: [String], at start: Int) -> Int? {
            for phrase in nextCase {
                let end = start + phrase.count
                guard end <= words.count else { continue }
                if matches(words[start..<end], phrase) { return phrase.count }
            }
            return nil
        }

        /// The units are a bare next-case marker, with at most a filler in front.
        func isBareNextCase(_ words: [String]) -> Bool {
            let core = words.drop(while: { fillers.contains($0) })
            return bareNextCase.contains { matches(core, $0) }
        }

        /// The units are a finish, with at most a filler in front or "thanks" after.
        func isFinish(_ words: [String]) -> Bool {
            var core = words.drop(while: { fillers.contains($0) })
            while let last = core.last, courtesies.contains(last) { core = core.dropLast() }
            return finishes.contains { matches(core, $0) }
        }
    }

    /// Han, kana and Hangul, read a character at a time: a recogniser writes the first two without
    /// spaces, and spaces Korean as it likes.
    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true   // kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return true   // Han
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return true   // Hangul
        case 0x3005, 0x3007: return true   // 々 〇
        default: return false
        }
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "\u{FF07}", "`", "\u{00B4}"]

    /// The units of `text` — words, and single characters of the unspaced scripts — each folded for
    /// matching, with where it sits in the original so the text either side of a marker comes
    /// back exactly as said.
    fileprivate static func units(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        func flush(at end: String.Index) {
            guard let begin = start else { return }
            let word = fold(text[begin..<end])
            if !word.isEmpty { result.append((word, begin..<end)) }
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if isUnspaced(character) {
                flush(at: index)
                let word = fold(text[index..<next])
                if !word.isEmpty { result.append((word, index..<next)) }
            } else if character.isLetter || character.isNumber || apostrophes.contains(character) {
                if start == nil { start = index }
            } else {
                flush(at: index)
            }
            index = next
        }
        flush(at: text.endIndex)
        return result
    }

    /// One unit as it is compared: width and compatibility forms folded, lowercased, apostrophes
    /// dropped ("that's" → "thats", "c'est" → "cest"), `ё` read as `е`, Arabic vowel marks and the
    /// tatweel dropped and its letter forms read as one, and a lone digit one as "1".
    private static func fold(_ unit: Substring) -> String {
        let lowered = String(unit).precomposedStringWithCompatibilityMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            switch scalar.value {
            case 0x27, 0x2019, 0x2018, 0x02BC, 0x60, 0xB4: continue   // apostrophes
            case 0x064B...0x065F, 0x0670, 0x0640: continue           // Arabic marks, tatweel
            case 0x0451: scalars.append("\u{0435}")                  // ё → е
            case 0x0623, 0x0625, 0x0622, 0x0671: scalars.append("\u{0627}")   // أ إ آ ٱ → ا
            case 0x064A, 0x0649: scalars.append("\u{06CC}")          // ي ى → ی
            case 0x0643: scalars.append("\u{06A9}")                  // ك → ک
            case 0x0647, 0x06BE: scalars.append("\u{06C1}")          // ه ھ → ہ
            default: scalars.append(scalar)
            }
        }
        let folded = String(scalars)
        if folded.count == 1, let digit = folded.first?.wholeNumberValue, digit == 1, folded.first?.isNumber == true {
            return "1"
        }
        return folded
    }

    /// The original text up to and including `word`, trimmed of trailing punctuation and space.
    private static func original(_ text: String, upTo word: (word: String, range: Range<String.Index>)) -> String {
        String(text[..<word.range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The original text from `word` on.
    private static func original(_ text: String, from word: (word: String, range: Range<String.Index>)) -> String {
        String(text[word.range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
