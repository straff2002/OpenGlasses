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

    /// Read one stretch. With no marker, the whole stretch is `before`.
    static func split(_ stretch: String) -> Split {
        let trimmed = stretch.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokens(trimmed)
        guard !words.isEmpty else { return Split(before: "", marker: nil, after: "") }

        if isFinish(words) { return Split(before: "", marker: .finish, after: "") }

        // "that's one, next case" anywhere in the stretch.
        let spoken = words.map(\.word)
        for start in spoken.indices {
            guard let length = nextCaseLength(in: spoken, at: start) else { continue }
            let end = start + length
            // "Okay, that's one, next case": a filler in front is not part of the case.
            let lead = spoken[..<start]
            let before = lead.allSatisfy({ fillers.contains($0) }) ? "" : original(trimmed, upTo: words[start - 1])
            let after = end < words.count ? original(trimmed, from: words[end]) : ""
            // "that's one, next case. That's all." — a finish straight after the marker ends it.
            let rest = Array(words[end...])
            if !rest.isEmpty, isFinish(rest) {
                return Split(before: before, marker: .finish, after: "")
            }
            return Split(before: before, marker: .nextCase, after: after)
        }

        // "next case" as the whole stretch, with at most a filler in front.
        if isBareNextCase(spoken) {
            return Split(before: "", marker: .nextCase, after: "")
        }

        // "…sealed the cover. That's all." — the recogniser punctuates, so a marker that is the
        // stretch's whole last sentence is one too, said without a pause before it. "…the fan,
        // that's all" (no sentence end) and "That's all it needed." (more than the marker) stay
        // in the case.
        if let (head, tail) = lastSentence(of: trimmed) {
            let tailWords = tokens(tail)
            if isFinish(tailWords) { return Split(before: head, marker: .finish, after: "") }
            if isBareNextCase(tailWords.map(\.word)) { return Split(before: head, marker: .nextCase, after: "") }
        }
        return Split(before: trimmed, marker: nil, after: "")
    }

    /// "next case" or "new case", with at most a filler in front.
    private static func isBareNextCase(_ words: [String]) -> Bool {
        let core = Array(words.drop(while: { fillers.contains($0) }))
        return core == ["next", "case"] || core == ["new", "case"]
    }

    /// The text before the stretch's last sentence, and that sentence, when it has more than one.
    private static func lastSentence(of text: String) -> (head: String, tail: String)? {
        let ends: Set<Character> = [".", "!", "?"]
        var core = Substring(text)
        while let last = core.last, ends.contains(last) || last == " " || last == "," { core = core.dropLast() }
        guard let boundary = core.lastIndex(where: { ends.contains($0) }) else { return nil }
        let head = core[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = core[core.index(after: boundary)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return (head, tail)
    }

    /// A whole transcript as cases, split at every next-case marker — what P2's segmenter starts
    /// from, and how a test reads a recording the way the recorder did. Empty cases are dropped;
    /// a finish marker ends the transcript.
    static func cases(in stretches: [String]) -> [String] {
        var cases: [String] = []
        var current: [String] = []
        func close() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { cases.append(text) }
            current = []
        }
        for stretch in stretches {
            let split = split(stretch)
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

    private static let fillers: Set<String> = ["okay", "ok", "right", "so", "and", "alright", "um", "uh"]

    /// "that's one next case", "that is one next case", "thats one next case": how many words
    /// starting at `start` make the marker, or nil.
    private static func nextCaseLength(in words: [String], at start: Int) -> Int? {
        // The recogniser writes "one" as a digit as often as a word.
        let openings: [[String]] = [["thats", "one"], ["that", "is", "one"], ["thats", "1"], ["that", "is", "1"]]
        for opening in openings {
            let tail = opening + ["next", "case"]
            let end = start + tail.count
            guard end <= words.count else { continue }
            if Array(words[start..<end]) == tail { return tail.count }
        }
        return nil
    }

    private static let finishes: [[String]] = [
        ["thats", "all"], ["that", "is", "all"], ["thats", "everything"], ["that", "is", "everything"],
        ["thats", "it", "for", "now"], ["stop", "recording"], ["finish", "recording"], ["end", "recording"],
        ["finished", "recording"], ["im", "done"], ["i", "am", "done"], ["done", "recording"],
        ["thats", "all", "for", "now"], ["thats", "one", "thats", "all"], ["thats", "one", "and", "thats", "all"],
        ["thats", "1", "thats", "all"],
    ]

    /// The whole stretch is a finish, with at most a filler in front or "thanks" after.
    private static func isFinish(_ words: [(word: String, range: Range<String.Index>)]) -> Bool {
        var core = words.map(\.word).drop(while: { fillers.contains($0) })
        while let last = core.last, ["thanks", "thank", "you", "please"].contains(last) { core = core.dropLast() }
        return finishes.contains(Array(core))
    }

    /// Lowercased words, apostrophes folded ("that's" → "thats"), with where each sits in the
    /// original so the text either side of a marker comes back exactly as said.
    private static func tokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        func flush(at end: String.Index) {
            guard let begin = start else { return }
            let word = text[begin..<end].lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
            if !word.isEmpty { result.append((word, begin..<end)) }
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" || character == "\u{2019}" {
                if start == nil { start = index }
            } else {
                flush(at: index)
            }
            index = text.index(after: index)
        }
        flush(at: text.endIndex)
        return result
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
