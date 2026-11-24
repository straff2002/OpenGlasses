import Foundation

/// Reads the model's reply into `MeetingNotes` (Plan MX P4), leniently: small models wrap JSON in
/// a code fence or a sentence, spell a key two ways, or give an action item as a bare string.
///
/// - The JSON is the text from the first `{` to the last `}`, fences or prose around it ignored.
/// - `action_items` or `actionItems`; an item is an object (`task`, with `owner` and `due`) or a
///   string, which is its task.
/// - No usable JSON: the reply's text becomes the overview, with empty lists, so a model that
///   ignored the format still leaves its work. Only a blank reply gives nothing.
/// - Placeholders a small model copies from the prompt ("none", "n/a", "owner", "due"…) are taken
///   out as whole values.
enum MeetingNotesParser {

    /// Whole values that mean nothing was said (case-insensitive, trailing punctuation ignored).
    static let placeholders: Set<String> = [
        "none", "n/a", "na", "unknown", "empty", "-", "null", "tbd", "unspecified",
        "not specified", "not mentioned", "who", "when", "what", "owner", "due", "task", "name",
        "date", "...", "…", "—", "–", "nil",
    ]

    /// The longest overview kept from a reply that was not JSON.
    static let proseOverviewLimit = 1_500

    /// Nil only for a blank reply.
    static func parse(_ reply: String) -> MeetingNotes? {
        let text = stripFences(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let object = jsonObject(in: text) {
            let notes = notes(from: object)
            if !notes.isEmpty { return notes }
            // A JSON object with nothing in it: whatever prose came with it, else nothing.
            let prose = proseAround(text)
            return prose.isEmpty ? nil : MeetingNotes(overview: prose)
        }
        if let salvaged = salvage(text) { return salvaged }
        return MeetingNotes(overview: clip(text))
    }

    /// A condensing reply as lines: bullets and numbering taken off, blanks and placeholders
    /// dropped, at most `limit`.
    static func condensedLines(_ reply: String, limit: Int = MeetingNotesPrompt.partLineLimit) -> [String] {
        stripFences(reply)
            .components(separatedBy: .newlines)
            .map(stripListMarker)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isPlaceholder($0) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Values

    static func isPlaceholder(_ value: String) -> Bool {
        let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]"))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return folded.isEmpty || placeholders.contains(folded)
    }

    /// A string value, trimmed, or nil when it is blank or a placeholder.
    static func clean(_ value: Any?) -> String? {
        guard let string = value as? String else {
            if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlaceholder(trimmed) ? nil : trimmed
    }

    private static func notes(from object: [String: Any]) -> MeetingNotes {
        let title = clean(object["title"]) ?? ""
        let overview = clean(object["overview"] ?? object["summary"]) ?? ""
        let decisions = list(object["decisions"]).compactMap { value -> String? in
            if let dict = value as? [String: Any] {
                return clean(dict["decision"] ?? dict["text"] ?? dict["what"])
            }
            return clean(value)
        }
        let items = list(object["action_items"] ?? object["actionItems"] ?? object["action items"])
            .compactMap(actionItem)
        return MeetingNotes(title: title, overview: overview,
                            decisions: unique(decisions), actionItems: uniqueItems(items))
    }

    private static func actionItem(_ value: Any) -> MeetingActionItem? {
        if let dict = value as? [String: Any] {
            guard let task = clean(dict["task"] ?? dict["item"] ?? dict["action"] ?? dict["text"]) else {
                return nil
            }
            return MeetingActionItem(task: task,
                                     owner: clean(dict["owner"] ?? dict["who"] ?? dict["assignee"]),
                                     due: clean(dict["due"] ?? dict["when"] ?? dict["deadline"] ?? dict["due_date"]))
        }
        return clean(value).map { MeetingActionItem(task: $0) }
    }

    private static func list(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let single = value as? String, clean(single) != nil { return [single] }
        return []
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func uniqueItems(_ items: [MeetingActionItem]) -> [MeetingActionItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.task.lowercased()).inserted }
    }

    // MARK: - Finding the JSON

    private static func stripFences(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
    }

    /// The text from the first `{` to the last `}`, as an object.
    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            return nil
        }
        let slice = String(text[open...close])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func proseAround(_ text: String) -> String {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            return clip(text)
        }
        let before = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return clip([before, after].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// A reply cut off mid-JSON (the model ran out of room): its title and overview, read by key,
    /// rather than the raw braces as an overview.
    private static func salvage(_ text: String) -> MeetingNotes? {
        guard text.contains("{"), text.contains("\"overview\"") || text.contains("\"title\"") else { return nil }
        func value(_ key: String) -> String? {
            let pattern = "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let raw = String(text[range])
            let decoded = (try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8),
                                                             options: .fragmentsAllowed)) as? String
            return clean(decoded ?? raw)
        }
        let notes = MeetingNotes(title: value("title") ?? "", overview: value("overview") ?? "")
        return notes.isEmpty ? nil : notes
    }

    private static func stripListMarker(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "+ ", "– "] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
        }
        if let regex = try? NSRegularExpression(pattern: #"^\d{1,2}[.)]\s+"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return text
    }

    private static func clip(_ text: String) -> String {
        guard text.count > proseOverviewLimit else { return text }
        return String(text.prefix(proseOverviewLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Checks the model's notes against the transcript they came from (Plan MX P4).
///
/// An owner or a due whose words are not in the transcript is dropped and the task kept: a name
/// or a date the model supplied is exactly the invented fact the prompt forbids, and a task with
/// no owner is still the task. The match is by word, case- and diacritic-insensitive, with the
/// speaker names the transcript lines carry counting as words. A value in a script written
/// without spaces (Chinese, Japanese, Thai…) is matched as a substring instead.
enum MeetingNotesVerifier {

    /// Leading words a due may carry that the speaker need not have said ("by Friday").
    static let dueLeads: Set<String> = ["by", "before", "until", "till", "on", "at", "in", "the", "due"]

    static func verify(_ notes: MeetingNotes, against transcript: String) -> MeetingNotes {
        let folded = fold(transcript)
        let words = Set(tokens(folded))
        var checked = notes
        checked.title = MeetingNotesParser.isPlaceholder(notes.title) ? "" : notes.title
        checked.decisions = notes.decisions.filter { !MeetingNotesParser.isPlaceholder($0) }
        checked.actionItems = notes.actionItems.compactMap { item in
            guard !MeetingNotesParser.isPlaceholder(item.task) else { return nil }
            var kept = item
            kept.owner = item.owner.flatMap { said($0, in: folded, words: words, leads: []) ? $0 : nil }
            kept.due = item.due.flatMap { said($0, in: folded, words: words, leads: dueLeads) ? $0 : nil }
            return kept
        }
        return checked
    }

    /// Whether every word of `value` (leading `leads` aside) was said.
    static func said(_ value: String, in foldedTranscript: String, words: Set<String>,
                     leads: Set<String>) -> Bool {
        guard !MeetingNotesParser.isPlaceholder(value) else { return false }
        let folded = fold(value)
        if folded.unicodeScalars.contains(where: isUnspacedScript) {
            let compact = folded.filter { !$0.isWhitespace && !$0.isPunctuation }
            return !compact.isEmpty && foldedTranscript.filter { !$0.isWhitespace }.contains(compact)
        }
        var parts = tokens(folded)
        while let first = parts.first, leads.contains(first), parts.count > 1 { parts.removeFirst() }
        return !parts.isEmpty && parts.allSatisfy(words.contains)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func tokens(_ folded: String) -> [String] {
        folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Scripts written without spaces between words.
    static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified
             0xF900...0xFAFF,   // CJK Compatibility
             0x0E00...0x0E7F,   // Thai
             0x0E80...0x0EFF,   // Lao
             0x1000...0x109F,   // Myanmar
             0x1780...0x17FF:   // Khmer
            return true
        default:
            return false
        }
    }
}
