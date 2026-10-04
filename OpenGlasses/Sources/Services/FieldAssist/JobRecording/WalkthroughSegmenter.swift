import Foundation

/// Splits narration into the stretches a person would call steps (Plan GY's pipeline).
///
/// Deterministic: a new segment opens on a spoken marker at the start of a sentence ("first",
/// "next", "then", "step three", "now I'm going to", "once that's done"), on the explicit marker
/// "new step", and on a silence longer than a threshold. It never splits inside a sentence, and a
/// fragment too short to stand alone is joined to the segment after it. The markers are English.
///
/// The recorded-session contract leans on it: a *step-like* segment — one that opened on a marker —
/// is what the agreement rule (§7.3) means by a step someone said, so an office computes the same
/// segments from the same transcript. `Contracts/fixtures/walkthrough-segments-v1.json` holds a
/// transcript and the segments it must give.
enum WalkthroughSegmenter {

    struct Configuration: Equatable, Sendable {
        /// A pause between utterances longer than this opens a new segment.
        var silence = SessionTime(milliseconds: 4_000)
        /// A segment with fewer words than this is a fragment.
        var minimumWords = 3

        /// What both sides of the contract use.
        static let standard = Configuration()
    }

    /// What opened a segment.
    enum Opening: String, Codable, Sendable {
        /// The first words of the transcript, with no marker.
        case start
        case silence
        /// A spoken marker: "next", "then", "step three" …
        case marker
        /// The explicit marker "new step".
        case newStep = "new_step"
    }

    struct Segment: Equatable, Sendable {
        /// `s1`, `s2`, … in time order.
        let id: String
        let start: SessionTime
        let end: SessionTime
        let text: String
        /// The utterances its words come from, in order. An utterance that holds the end of one
        /// step and the start of the next is in both.
        let utteranceIDs: [String]
        let opening: Opening

        /// Said as a step: it opened on a marker, not merely after a pause.
        var isStepLike: Bool { opening == .marker || opening == .newStep }
    }

    /// Words that may come before a marker without hiding it: "okay, next …", "and then …".
    static let fillers: Set<String> = ["alright", "and", "ok", "okay", "right", "so", "uh", "um", "well"]

    /// The spoken markers, as the words `RecordingText.words` gives. "step" also needs a number
    /// after it.
    static let markers: [[String]] = [
        ["first"], ["next"], ["then"],
        ["now", "im", "going", "to"], ["now", "i", "am", "going", "to"],
        ["once", "thats", "done"], ["once", "that", "is", "done"],
    ]
    static let explicitMarker = ["new", "step"]
    static let stepNumbers: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty",
    ]

    static func segments(_ transcript: TimedTranscript,
                         configuration: Configuration = .standard) -> [Segment] {
        var drafts: [Draft] = []
        var previous: TimedTranscript.Utterance?
        for utterance in transcript.utterances {
            let sentences = sentences(of: utterance)
            guard !sentences.isEmpty else { continue }
            for (index, sentence) in sentences.enumerated() {
                let marker = leadingMarker(sentence.words)
                let opening: Opening?
                if drafts.isEmpty {
                    opening = marker ?? .start
                } else if index == 0, let previous,
                          utterance.start - previous.end > configuration.silence {
                    opening = marker ?? .silence
                } else if marker == .newStep {
                    opening = .newStep
                } else if marker == .marker,
                          index > 0 || previous.map({ endsSentence($0.text) }) ?? true {
                    opening = .marker
                } else {
                    // Mid-sentence, or simply more of the same step.
                    opening = nil
                }
                if let opening {
                    drafts.append(Draft(sentence, utteranceID: utterance.id, opening: opening))
                } else {
                    drafts[drafts.count - 1].append(sentence, utteranceID: utterance.id)
                }
            }
            previous = utterance
        }
        return merged(drafts, configuration: configuration).enumerated().map { index, draft in
            Segment(id: "s\(index + 1)", start: draft.start, end: draft.end, text: draft.text,
                    utteranceIDs: draft.utteranceIDs, opening: draft.opening)
        }
    }

    // MARK: - Sentences

    struct Sentence: Equatable {
        let start: SessionTime
        let end: SessionTime
        let text: String
        let words: [String]
    }

    /// The sentences of one utterance. A sentence ends at a `.`, `!` or `?` that is followed by
    /// white space or by the end of the text, so "3.5 volts" stays whole. Only the utterance has a
    /// real time; a sentence inside it is placed by how far along the text it begins, counted in
    /// characters (Unicode scalars) and rounded down to the millisecond.
    static func sentences(of utterance: TimedTranscript.Utterance) -> [Sentence] {
        let scalars = Array(utterance.text.unicodeScalars)
        var pieces: [(offset: Int, text: String)] = []
        var pieceStart = 0
        func close(_ end: Int) {
            let piece = scalars[pieceStart..<end]
            if let first = piece.firstIndex(where: { !$0.properties.isWhitespace }) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: piece[first...])
                let text = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
                if !RecordingText.words(text).isEmpty { pieces.append((first, text)) }
            }
            pieceStart = end
        }
        for index in scalars.indices where isTerminator(scalars[index]) {
            if index + 1 == scalars.count || scalars[index + 1].properties.isWhitespace { close(index + 1) }
        }
        close(scalars.count)

        let length = utterance.end.milliseconds - utterance.start.milliseconds
        let starts = pieces.enumerated().map { index, piece in
            index == 0 ? utterance.start
                : SessionTime(milliseconds: utterance.start.milliseconds + length * Int64(piece.offset) / Int64(scalars.count))
        }
        return pieces.enumerated().map { index, piece in
            Sentence(start: starts[index], end: index + 1 < starts.count ? starts[index + 1] : utterance.end,
                     text: piece.text, words: RecordingText.words(piece.text))
        }
    }

    private static func isTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar == "!" || scalar == "?"
    }

    /// Whether a text finishes its sentence. Words that stop without doing so are taken to carry on
    /// into the next utterance, where a marker word is then just a word.
    private static func endsSentence(_ text: String) -> Bool {
        text.unicodeScalars.last(where: { !$0.properties.isWhitespace }).map(isTerminator) ?? true
    }

    /// The marker a sentence opens with, once any fillers are passed over.
    static func leadingMarker(_ words: [String]) -> Opening? {
        let rest = Array(words.drop(while: fillers.contains))
        if rest.starts(with: explicitMarker) { return .newStep }
        if markers.contains(where: { rest.starts(with: $0) }) { return .marker }
        if rest.count >= 2, rest[0] == "step",
           stepNumbers.contains(rest[1]) || rest[1].utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            return .marker
        }
        return nil
    }

    // MARK: - Fragments

    private struct Draft {
        var start: SessionTime
        var end: SessionTime
        var text: String
        var wordCount: Int
        var utteranceIDs: [String]
        var opening: Opening

        var isStepLike: Bool { opening == .marker || opening == .newStep }

        init(_ sentence: Sentence, utteranceID: String, opening: Opening) {
            start = sentence.start
            end = sentence.end
            text = sentence.text
            wordCount = sentence.words.count
            utteranceIDs = [utteranceID]
            self.opening = opening
        }

        mutating func append(_ sentence: Sentence, utteranceID: String) {
            end = sentence.end
            text += " " + sentence.text
            wordCount += sentence.words.count
            if utteranceIDs.last != utteranceID { utteranceIDs.append(utteranceID) }
        }

        /// This segment followed by `next`, as one.
        func joined(_ next: Draft, opening: Opening) -> Draft {
            var joined = self
            joined.end = next.end
            joined.text += " " + next.text
            joined.wordCount += next.wordCount
            joined.utteranceIDs += next.utteranceIDs.filter { !utteranceIDs.contains($0) }
            joined.opening = opening
            return joined
        }
    }

    /// Joins fragments to what follows them. A fragment that is a marker on its own ("Next.") is
    /// announcing the step that comes after it, however long the pause, so it is joined to the next
    /// segment and that segment counts as opened by the marker. Any other fragment ("Okay.") is
    /// joined to the next segment only when no long silence lies between them; otherwise it is left
    /// as it is, so a stray word never stretches a step across a pause.
    private static func merged(_ drafts: [Draft], configuration: Configuration) -> [Draft] {
        var result: [Draft] = []
        var carried: Draft?
        for draft in drafts {
            var current = draft
            if let waiting = carried {
                if waiting.isStepLike {
                    current = waiting.joined(draft, opening: waiting.opening)
                } else if draft.start - waiting.end <= configuration.silence {
                    current = waiting.joined(draft, opening: draft.opening)
                } else {
                    result.append(waiting)
                }
                carried = nil
            }
            if current.wordCount < configuration.minimumWords {
                carried = current
            } else {
                result.append(current)
            }
        }
        if let carried { result.append(carried) }
        return result
    }
}
