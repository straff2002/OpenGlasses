import Foundation

/// The suggested-follow-ups tail of a reply (Plan KP §4): after the answer, the model writes
/// `<next>q1|q2|q3</next>`. `parse(_:)` takes the tail off before anything else sees the reply, so
/// it never reaches speech, the HUD body, the transcript or memory. Pure.
///
/// Rules:
/// - **Well-formed:** the reply ends (trailing whitespace aside) with `<next>…</next>`. The tail is
///   removed and its questions are kept. The tags may be on the answer's last line or a line of
///   their own; they match case-insensitively. Questions are separated by `|` (a newline counts as
///   a separator too).
/// - **Missing:** no follow-ups, `answer` is the reply unchanged.
/// - **Empty** (`<next></next>`): the tail is removed, no follow-ups.
/// - **Not at the end:** a `<next>…</next>` block followed by more text is not a tail. The reply is
///   left unchanged, with no follow-ups.
/// - **Malformed:** no follow-ups, and the answer never loses real content. Only tag text is
///   removed: a closed tail at the end whose content holds another tag, or that follows an
///   earlier unclosed `<next>` beginning a sentence on the same line (removed from there), or an
///   unclosed `<next>` that begins a sentence (start of the reply,
///   a new line, or after a sentence stop) and runs to the end of the reply on one line, the
///   shape of a tail cut short. A stray `</next>` with no opening tag, or an unclosed `<next>`
///   inside a sentence or followed by more lines, is left as written.
/// - **Questions:** whitespace collapsed; empty ones and any holding `<` or `>` are dropped; any
///   over `maxWords` words or `maxCharacters` characters is dropped, never cut; then the first
///   `maxFollowUps` are kept.
struct FollowUpTail: Equatable {
    /// The reply without its tail (trailing whitespace before the tail trimmed), or the reply
    /// unchanged when it has none.
    let answer: String
    /// Up to `maxFollowUps` questions, in the order written.
    let followUps: [String]
    /// True when a tail (well-formed or not) was found and removed from `answer`.
    let removedTail: Bool

    static let openTag = "<next>"
    static let closeTag = "</next>"
    static let maxFollowUps = 3
    /// The prompt clause asks for six words or fewer.
    static let maxWords = 6
    /// What a HUD button carries on one line: `HUDTextShaper.maxTitleLength`, which is also an
    /// Even G2 line. A longer question is dropped rather than cut.
    static let maxCharacters = HUDTextShaper.maxTitleLength

    static func parse(_ reply: String) -> FollowUpTail {
        let unchanged = FollowUpTail(answer: reply, followUps: [], removedTail: false)
        let trimmed = trimTrailingWhitespace(reply)

        // A closed tail at the very end.
        if let close = trimmed.range(of: closeTag, options: [.caseInsensitive, .backwards, .anchored]) {
            guard let open = trimmed.range(of: openTag, options: [.caseInsensitive, .backwards],
                                           range: trimmed.startIndex..<close.lowerBound) else {
                return unchanged   // a stray close tag: leave it
            }
            let content = trimmed[open.upperBound..<close.lowerBound]
            let before = trimmed[..<open.lowerBound]
            // An earlier, unclosed <next> that begins a sentence on the same line makes this a
            // malformed tail: take the tail from there, but keep no questions.
            if let earlier = before.range(of: openTag, options: [.caseInsensitive, .backwards]),
               beginsSentence(at: earlier.lowerBound, in: trimmed),
               !before[earlier.upperBound...].contains(where: \.isNewline),
               before[earlier.upperBound...].range(of: closeTag, options: .caseInsensitive) == nil {
                return FollowUpTail(answer: trimTrailingWhitespace(before[..<earlier.lowerBound]),
                                    followUps: [], removedTail: true)
            }
            let answer = trimTrailingWhitespace(before)
            if content.range(of: closeTag, options: .caseInsensitive) != nil {
                return FollowUpTail(answer: answer, followUps: [], removedTail: true)
            }
            return FollowUpTail(answer: answer, followUps: questions(in: content), removedTail: true)
        }

        // An unclosed tail, cut short, at the end.
        if let open = trimmed.range(of: openTag, options: [.caseInsensitive, .backwards]) {
            let after = trimmed[open.upperBound...]
            if !after.contains(where: \.isNewline),
               after.range(of: closeTag, options: .caseInsensitive) == nil,
               beginsSentence(at: open.lowerBound, in: trimmed) {
                return FollowUpTail(answer: trimTrailingWhitespace(trimmed[..<open.lowerBound]),
                                    followUps: [], removedTail: true)
            }
        }
        return unchanged
    }

    /// For the sentence streamer (Plan KP P2): true when a streamed sentence begins a tail, so
    /// it — and everything after it in the reply — is held back from speech. A tail's questions
    /// end in "?", so a sentence splitter can cut one tail into several pieces; only the first
    /// begins with `<next>`, and the streamer holds back from there to the end of the reply.
    static func beginsTail(_ sentence: String) -> Bool {
        sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: openTag, options: [.caseInsensitive, .anchored]) != nil
    }

    /// For the sentence streamer: when a streamed chunk carries the end of the answer and the
    /// start of a tail together ("…the end. <next>Why?"), the part before the tail, to speak.
    /// Nil when the chunk has no `<next>` that begins a sentence.
    static func textBeforeTail(in sentence: String) -> String? {
        var searchEnd = sentence.endIndex
        while let open = sentence.range(of: openTag, options: [.caseInsensitive, .backwards],
                                        range: sentence.startIndex..<searchEnd) {
            if beginsSentence(at: open.lowerBound, in: sentence) {
                return trimTrailingWhitespace(sentence[..<open.lowerBound])
            }
            searchEnd = open.lowerBound
        }
        return nil
    }

    // MARK: - Helpers

    private static let sentenceStops: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    private static func questions(in content: Substring) -> [String] {
        content
            .split(whereSeparator: { $0 == "|" || $0.isNewline })
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { question in
                !question.isEmpty
                    && !question.contains("<") && !question.contains(">")
                    && question.split(separator: " ").count <= maxWords
                    && question.count <= maxCharacters
            }
            .prefix(maxFollowUps)
            .map { $0 }
    }

    /// Whether `index` starts a sentence: the start of the text, a new line, or a sentence stop
    /// followed by whitespace (or directly by the tag).
    private static func beginsSentence(at index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character.isNewline { return true }
            if character.isWhitespace { cursor = previous; continue }
            return sentenceStops.contains(character)
        }
        return true
    }

    private static func trimTrailingWhitespace<S: StringProtocol>(_ text: S) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[text.startIndex..<end])
    }
}
