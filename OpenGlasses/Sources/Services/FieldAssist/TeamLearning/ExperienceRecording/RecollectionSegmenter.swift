import Foundation

/// Cuts an experience recording's transcript into cases (Plan IM P2). Pure.
///
/// The partner asks for one case per recording, and the recorder ends a recording at "that's one,
/// next case" — but a recording can still hold several ("…and the other one we see a lot is the
/// RX-300…"), and the reviewer's job is tractable only one case per card. So, in order:
///
/// 1. **The spoken markers**, read exactly as the recorder reads them (`ExperienceRecordingMarkers`):
///    "that's one, next case" (or a bare "next case") ends a case and the words after it open the
///    next; "that's all" ends the transcript, as it ends a recording.
/// 2. **A change of model.** Within a case, a sentence that names exactly one of the vault's models
///    (`VaultModelIndex`, every model-like token in it agreeing), when an earlier sentence named a
///    different one, opens a new case. A sentence naming two models ("it's like the RX-200, but
///    the RX-300…") opens nothing: it is one case comparing them.
///
/// The transcript the recorder keeps is its stretches joined by spaces, so sentences — split after
/// `.`, `!` or `?` followed by a space or the end — stand in for stretches. Every segment is a span
/// of Unicode scalar offsets into the transcript, from its first sentence's first character to its
/// last sentence's last; a segment with no letter or digit in it is dropped.
enum RecollectionSegmenter {

    struct Segment: Equatable, Sendable {
        let span: RecollectionDraft.Span
        let text: String
        /// The vault model the segment names first, when it names one; nil when none.
        let modelName: String?
    }

    static func segments(in transcript: String, index: VaultModelIndex) -> [Segment] {
        let scalars = Array(transcript.unicodeScalars)
        var cases: [[RecollectionDraft.Span]] = []
        var current: [RecollectionDraft.Span] = []
        func close() {
            if !current.isEmpty { cases.append(current) }
            current = []
        }
        reading: for sentence in sentences(in: scalars) {
            let text = string(scalars, sentence)
            let split = ExperienceRecordingMarkers.split(text)
            if let before = part(split.before, of: sentence, in: scalars, atStart: true) { current.append(before) }
            switch split.marker {
            case .none:
                continue
            case .finish:
                break reading
            case .nextCase:
                close()
                if let after = part(split.after, of: sentence, in: scalars, atStart: false) { current.append(after) }
            }
        }
        close()

        var segments: [Segment] = []
        for pieces in cases {
            var open: [RecollectionDraft.Span] = []
            var model: String?
            func emit() {
                guard let first = open.first, let last = open.last else { return }
                let span = RecollectionDraft.Span(start: first.start, end: last.end)
                let text = string(scalars, span)
                if text.unicodeScalars.contains(where: RecollectionDraftRules.isWord) {
                    segments.append(Segment(span: span, text: text, modelName: model))
                }
                open = []
                model = nil
            }
            for piece in pieces {
                let named = RecollectionDraftRules.model(namedIn: string(scalars, piece), index: index)?.name
                if let named, let model, named != model { emit() }
                if model == nil, let named { model = named }
                open.append(piece)
            }
            emit()
        }
        return segments
    }

    // MARK: - Sentences

    /// Each sentence's span, trimmed of whitespace: a run of text up to and including a run of
    /// `.`, `!` or `?` that is followed by whitespace or the end, or the text left at the end.
    static func sentences(in scalars: [Unicode.Scalar]) -> [RecollectionDraft.Span] {
        let ends: Set<Unicode.Scalar> = [".", "!", "?"]
        var spans: [RecollectionDraft.Span] = []
        var start = 0
        var index = 0
        func add(_ end: Int) {
            var lower = start
            var upper = end
            while lower < upper, isSpace(scalars[lower]) { lower += 1 }
            while upper > lower, isSpace(scalars[upper - 1]) { upper -= 1 }
            if lower < upper { spans.append(RecollectionDraft.Span(start: lower, end: upper)) }
            start = end
        }
        while index < scalars.count {
            if ends.contains(scalars[index]) {
                var after = index + 1
                while after < scalars.count, ends.contains(scalars[after]) { after += 1 }
                if after == scalars.count || isSpace(scalars[after]) {
                    add(after)
                }
                index = after
            } else {
                index += 1
            }
        }
        add(scalars.count)
        return spans
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    private static func string(_ scalars: [Unicode.Scalar], _ span: RecollectionDraft.Span) -> String {
        String(String.UnicodeScalarView(scalars[span.start..<span.end]))
    }

    /// Where the markers' `before` (a prefix of the sentence) or `after` (a suffix) sits, or nil
    /// when it is empty. Found by its own text, so a marker the recogniser spelled oddly cannot
    /// shift a span.
    private static func part(_ text: String, of sentence: RecollectionDraft.Span, in scalars: [Unicode.Scalar],
                             atStart: Bool) -> RecollectionDraft.Span? {
        let wanted = Array(text.unicodeScalars)
        guard !wanted.isEmpty else { return nil }
        let whole = Array(scalars[sentence.start..<sentence.end])
        if atStart, whole.starts(with: wanted) {
            return RecollectionDraft.Span(start: sentence.start, end: sentence.start + wanted.count)
        }
        if !atStart, whole.reversed().starts(with: wanted.reversed()) {
            return RecollectionDraft.Span(start: sentence.end - wanted.count, end: sentence.end)
        }
        // Not where it was expected: search the sentence for it.
        guard wanted.count <= whole.count else { return nil }
        for offset in 0...(whole.count - wanted.count) where Array(whole[offset..<(offset + wanted.count)]) == wanted {
            return RecollectionDraft.Span(start: sentence.start + offset, end: sentence.start + offset + wanted.count)
        }
        return nil
    }
}
