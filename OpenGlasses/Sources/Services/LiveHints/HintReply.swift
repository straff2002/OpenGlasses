import Foundation

/// A model's answer to one hint call, read and cut to size (Plan MO §5 step 3).
///
/// The model is asked for `{"hint": "...", "full": "...", "general": false}`. What it sends back
/// is read leniently: the bare object, the object inside a ``` fence, or one object with prose
/// around it. A reply with no object at all is read as lines: the first non-empty line is the
/// hint, the rest the full answer. Whatever arrives, the lengths are enforced here, never trusted
/// to the model: the hint to `HintLimits.hintMaxWords` words and `hintMaxCharacters` characters,
/// the full answer to `fullMaxSentences` sentences and `fullMaxCharacters` characters, each cut
/// at a word or sentence boundary. An empty hint means there is nothing worth showing.
struct HintReply: Equatable, Sendable {
    /// The glance line.
    let hint: String
    /// The second page: one or two sentences.
    let full: String
    /// The model answered from general knowledge, not the passages (decision 6).
    let general: Bool
    /// The ear form of the hint, at most `HintLimits.spokenHintMaxWords` words.
    let spokenHint: String

    enum Parsed: Equatable {
        case hint(HintReply)
        case nothingToShow
    }

    static func parse(_ raw: String) -> Parsed {
        let fields = jsonFields(raw) ?? lineFields(raw)
        let hint = cutHint(fields.hint)
        guard !hint.isEmpty else { return .nothingToShow }
        return .hint(HintReply(hint: hint, full: cutFull(fields.full), general: fields.general,
                               spokenHint: cutSpoken(hint)))
    }

    // MARK: - Reading

    private struct Fields {
        var hint: String
        var full: String
        var general: Bool
    }

    /// The first JSON object in the reply, bare, fenced or among prose.
    private static func jsonFields(_ raw: String) -> Fields? {
        guard let object = jsonObject(in: raw) else { return nil }
        return Fields(hint: string(object["hint"]), full: string(object["full"]),
                      general: bool(object["general"]))
    }

    /// The first JSON object in a model's reply, bare, fenced or among prose. Shared with the talk
    /// note, whose reply has the same habits.
    static func jsonObject(in raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in [trimmed, unfenced(trimmed), firstObject(in: trimmed)].compactMap({ $0 }) {
            guard let data = candidate.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let text as String: return text.lowercased() == "true"
        default: return false
        }
    }

    /// The body of a ``` fence (with or without a language tag), if the reply has one.
    private static func unfenced(_ text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        var body = text[open.upperBound...]
        if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
        guard let close = body.range(of: "```") else { return nil }
        return String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first balanced `{…}` in the text, braces inside strings ignored.
    private static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// No JSON: the first non-empty line is the hint, the rest the full answer. A list marker or
    /// surrounding quotes on the line are not part of it.
    private static func lineFields(_ raw: String) -> Fields {
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }) else {
            return Fields(hint: "", full: "", general: false)
        }
        let marks = CharacterSet(charactersIn: "-*•#>\"'\u{201C}\u{201D}` ")
        let hint = lines[first].trimmingCharacters(in: marks)
        let rest = lines[(first + 1)...].joined(separator: " ")
        return Fields(hint: hint, full: rest.trimmingCharacters(in: .whitespacesAndNewlines), general: false)
    }

    // MARK: - Cutting

    static func cutHint(_ text: String) -> String {
        let (line, wasCut) = HintText.cut(text, maxWords: HintLimits.hintMaxWords,
                                          maxCharacters: HintLimits.hintMaxCharacters)
        return HintText.trimmingTrailingPunctuation(line, includingStops: wasCut)
    }

    static func cutSpoken(_ hint: String) -> String {
        let (line, wasCut) = HintText.cut(hint, maxWords: HintLimits.spokenHintMaxWords,
                                          maxCharacters: .max)
        return HintText.trimmingTrailingPunctuation(line, includingStops: wasCut)
    }

    /// Whole sentences while they fit; a first sentence that alone is too long is cut at a word.
    static func cutFull(_ text: String) -> String {
        let sentences = HintText.sentences(HintText.collapsingWhitespace(text))
        var kept: [String] = []
        for sentence in sentences.prefix(HintLimits.fullMaxSentences) {
            let candidate = (kept + [sentence]).joined(separator: " ")
            guard candidate.count <= HintLimits.fullMaxCharacters else { break }
            kept.append(sentence)
        }
        if kept.isEmpty, let first = sentences.first {
            let (line, _) = HintText.cut(first, maxCharacters: HintLimits.fullMaxCharacters)
            return HintText.trimmingTrailingPunctuation(line, includingStops: true)
        }
        return kept.joined(separator: " ")
    }
}
