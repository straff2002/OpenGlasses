import Foundation

/// How much transcript one notes call may carry, and how a longer meeting is cut into parts
/// (Plan MX P4). Pure.
///
/// **The budget** is half the routed model's context window, at most 24,000 tokens, turned into
/// characters at a rate for the transcript's script: three a token for Latin script (the same
/// conservative rate as the excerpt's budget), two for other alphabets (Cyrillic, Greek, Arabic,
/// Hebrew, Devanagari…), one for scripts written without spaces (Chinese, Japanese, Korean,
/// Thai…), whose characters are dense. An unknown window is read as 4,096 tokens. The other half
/// is the instructions, the frame and the reply: unlike the excerpt beside a summary, this call
/// carries nothing else. The 24,000-token ceiling keeps a call inside a turn short, and a reply
/// over a very long input no worse than the condensed one.
///
/// - A 4,096-token on-device model: 2,048 tokens, 6,144 characters of English.
/// - A 200,000-token cloud model: the 24,000 ceiling, 72,000 characters — about an hour and a
///   half of speech in one call.
enum MeetingNotesBudget {

    enum Script: String, Equatable, Sendable {
        case latin
        case otherAlphabet
        case unspaced

        var charactersPerToken: Int {
            switch self {
            case .latin: return 3
            case .otherAlphabet: return 2
            case .unspaced: return 1
            }
        }
    }

    static let unknownWindow = 4_096
    static let maximumTranscriptTokens = 24_000
    static let minimumCharacters = 1_500

    static func characters(contextTokens: Int?, script: Script) -> Int {
        let window = (contextTokens ?? 0) > 0 ? contextTokens! : unknownWindow
        let tokens = min(maximumTranscriptTokens, window / 2)
        return max(minimumCharacters, tokens * script.charactersPerToken)
    }

    /// The script most of `text`'s letters are in, read from at most its first 4,000 letters. The
    /// denser class wins at a quarter of the letters: one Chinese line in five already makes
    /// English's rate an underestimate.
    static func script(of text: String) -> Script {
        var latin = 0, other = 0, unspaced = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if MeetingNotesVerifier.isUnspacedScript(scalar) || (0xAC00...0xD7AF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value) {
                unspaced += 1
            } else if scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value) {
                latin += 1
            } else {
                other += 1
            }
            if latin + other + unspaced >= 4_000 { break }
        }
        let total = latin + other + unspaced
        guard total > 0 else { return .latin }
        if unspaced * 4 >= total { return .unspaced }
        if (other + unspaced) * 4 >= total { return .otherAlphabet }
        return .latin
    }

    // MARK: - Parts

    /// `lines` packed into parts of at most `budget` characters, in order. A line longer than the
    /// budget is cut at sentence ends, and a sentence longer than the budget at a space (or, in a
    /// script without spaces, anywhere).
    static func parts(of lines: [String], budget: Int) -> [String] {
        let limit = max(1, budget)
        var parts: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { parts.append(current) }
            current = ""
        }
        for line in lines.flatMap({ pieces(of: $0, limit: limit) }) {
            let added = current.isEmpty ? line.count : current.count + 1 + line.count
            if added > limit { flush() }
            current = current.isEmpty ? line : current + "\n" + line
        }
        flush()
        return parts
    }

    /// One line as pieces no longer than `limit`.
    static func pieces(of line: String, limit: Int) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }
        var out: [String] = []
        var current = ""
        for sentence in sentences(of: trimmed) {
            for piece in hardCut(sentence, limit: limit) {
                let added = current.isEmpty ? piece.count : current.count + 1 + piece.count
                if added > limit, !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                current = current.isEmpty ? piece : current + " " + piece
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Sentences, each keeping its closing mark.
    static func sentences(of text: String) -> [String] {
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？", "؟", "।"]
        var out: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if let previous, enders.contains(previous), character == " " {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
                if enders.contains(character), "。！？".contains(character) {
                    out.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            previous = character
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out.filter { !$0.isEmpty }
    }

    private static func hardCut(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var out: [String] = []
        var rest = Substring(sentence)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(of: " ").map { $0 } ?? window.endIndex
            let head = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { out.append(head) }
            rest = rest[cut...].drop { $0 == " " }
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
