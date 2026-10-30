import Foundation

/// A reply whose last part repeats the part just before it is said and kept once (Plan KD P3).
///
/// On the partner's retest some replies held the same paragraph twice: a model's tool turn, routed
/// automatically to Chat Completions, came back with its preamble merged into the answer, so the
/// answer's last paragraph (or the whole answer) was said twice and kept twice in history.
///
/// The rule is narrow on purpose. Only a repeat at the very end is collapsed, and only when the
/// repeated part follows the part it repeats with nothing between them but spacing and
/// punctuation: "A. B. A." is left alone, because "B" is something else said in between, and so
/// is "To recap: A." after "A.". Both copies start where a sentence starts, the repeat is compared
/// with case, spacing and punctuation set aside (a dot or slash between two digits is kept, so
/// "4/0" and "40" are not the same), and it must be long enough to be a sentence, not a word or a
/// line: at least `minimumCharacters` letters and digits and `minimumWords` words (a script
/// written without spaces is held to the length alone). A single list line is never collapsed,
/// even when it is long, because a list may legitimately repeat an item. Pure.
enum RepeatedReplyCollapse {

    /// The least a repeat carries, in letters and digits, to be collapsed.
    static let minimumCharacters = 40
    /// The least a repeat carries, in words, in a script written with spaces.
    static let minimumWords = 6
    /// How many times a reply may be collapsed: three copies are one reply, as two are.
    static let maximumPasses = 3

    /// The reply with a repeated end said once, or the reply exactly as it came when it has none.
    static func collapse(_ reply: String) -> String {
        var text = reply
        for _ in 0..<maximumPasses {
            guard let shorter = collapseOnce(text) else { break }
            text = shorter
        }
        return text
    }

    /// The history with its last assistant message's text replaced, when that message is exactly
    /// `original` — the reply each provider path appended before the collapse. Anything else is
    /// left exactly as it was.
    static func replacingLastAssistantReply(in history: [[String: Any]], original: String,
                                            with collapsed: String) -> [[String: Any]] {
        guard original != collapsed,
              let index = history.lastIndex(where: { $0["role"] as? String == "assistant" }),
              history[index]["content"] as? String == original else { return history }
        var history = history
        history[index]["content"] = collapsed
        return history
    }

    // MARK: - One pass

    private static func collapseOnce(_ text: String) -> String? {
        let characters = Array(text)
        let (normalised, origin) = normalise(characters)
        let total = normalised.count
        guard total >= 2 * minimumCharacters else { return nil }
        // The longest repeat first, so a reply said twice whole is cut to one copy in one pass.
        for half in stride(from: total / 2, through: minimumCharacters, by: -1) {
            let second = total - half, first = total - 2 * half
            guard normalised[first] == normalised[second],
                  normalised[second - 1] == normalised[total - 1],
                  normalised[first..<second].elementsEqual(normalised[second..<total]) else { continue }
            let copyStart = origin[second]
            guard startsSentence(characters, at: origin[first]),
                  startsSentence(characters, at: copyStart) else { continue }
            let copy = String(characters[copyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLongEnough(copy), !isSingleListLine(copy, characters: characters, at: copyStart) else { continue }
            let kept = String(characters[..<copyStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            return kept.isEmpty ? nil : kept
        }
        return nil
    }

    /// Letters and digits, lowercased, each with the position in `characters` it came from. A
    /// separator between two digits ("4/0", "2.5", "1,200") is kept, because it is part of a value.
    private static func normalise(_ characters: [Character]) -> ([Character], [Int]) {
        var normalised: [Character] = []
        var origin: [Int] = []
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                for lowered in character.lowercased() {
                    normalised.append(lowered)
                    origin.append(index)
                }
            } else if !character.isWhitespace, index > 0, index + 1 < characters.count,
                      characters[index - 1].isNumber, characters[index + 1].isNumber {
                normalised.append(character)
                origin.append(index)
            }
        }
        return (normalised, origin)
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":", ";", "…", "。", "！", "？", "：", "；"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "」", "』", "）"]
    private static let markers: Set<Character> = ["-", "*", "•", "–", "—", "·", "#", ">"]

    /// Whether the character at `index` starts a sentence: the text's start, a new line (a list
    /// marker or heading mark before it aside), or after a sentence's end (closing quotes aside).
    private static func startsSentence(_ characters: [Character], at index: Int) -> Bool {
        var cursor = index - 1
        var sawMarker = false
        while cursor >= 0 {
            let character = characters[cursor]
            if character.isNewline { return true }
            if character.isWhitespace { cursor -= 1; continue }
            if markers.contains(character) { sawMarker = true; cursor -= 1; continue }
            break
        }
        if cursor < 0 { return true }
        // A dash or star inside a line ("the fuse - then the relay") does not start a sentence.
        if sawMarker { return false }
        while cursor >= 0, closers.contains(characters[cursor]) { cursor -= 1 }
        return cursor < 0 || sentenceEnds.contains(characters[cursor])
    }

    private static func isLongEnough(_ copy: String) -> Bool {
        let words = copy.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        if words.count >= minimumWords { return true }
        // A script written without spaces (Chinese, Japanese) is held to the length alone.
        return copy.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil
    }

    /// A repeat that is one line opened by a list marker ("- check the fuse", "2. check the fuse").
    private static func isSingleListLine(_ copy: String, characters: [Character], at start: Int) -> Bool {
        guard !copy.contains(where: \.isNewline) else { return false }
        var cursor = start - 1
        while cursor >= 0, characters[cursor] == " " || characters[cursor] == "\t" { cursor -= 1 }
        if cursor >= 0, markers.contains(characters[cursor]) { return true }
        // "2. check the fuse": a number, then a dot or bracket, opening the line.
        return copy.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) != nil
    }
}
