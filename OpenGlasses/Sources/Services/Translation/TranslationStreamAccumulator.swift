import Foundation

/// Plan BY P2 — pure accumulator between the cloud stream and the caption surface.
///
/// The translator session streams three kinds of events: model text deltas (the translation),
/// the model's turn completion (the utterance's translation is done), and input transcriptions
/// (the source-language words that were heard). This type folds them into
/// `TranslationSegment`s: one interim per delta, one final per completed turn — so the live
/// transport stays a dumb pipe and everything decodable is unit-tested.
///
/// The prompt instructs the model to begin each utterance with a source-language tag like
/// `[es] ` (see `TranslationPromptBuilder`). The tag can be split across deltas, so parsing
/// buffers until it resolves; a malformed or absent tag degrades to plain text, never a
/// dropped caption.
struct TranslationStreamAccumulator {

    private(set) var translated = ""
    private(set) var original = ""
    private(set) var language: String?

    /// Buffer for the head of a turn until the leading language tag is proven present or absent.
    private var raw = ""
    private var tagResolved = false

    /// Longest head we'll wait on for a closing `]` before deciding there is no tag.
    private static let maxTagLength = 16

    // MARK: - Events

    /// Model text arrived. Returns the interim segment to render, or nil while the language tag
    /// is still ambiguous (a few characters at most).
    mutating func acceptDelta(_ chunk: String) -> TranslationSegment? {
        if tagResolved {
            translated = ScriptAwareJoiner.join(translated, chunk)
        } else {
            raw = ScriptAwareJoiner.join(raw, chunk)
            resolveTagIfPossible()
        }
        return interimSegment()
    }

    /// Source-language transcription arrived (what was actually heard).
    mutating func acceptInputTranscription(_ chunk: String) {
        original = ScriptAwareJoiner.join(original, chunk)
    }

    /// The model finished translating the utterance. Returns the final segment — equal to the
    /// last interim by construction — and resets for the next utterance. Nil for an empty turn.
    mutating func turnCompleted() -> TranslationSegment? {
        // A turn can end while a short tag-less head is still buffered ("OK" never resolves
        // by length) — flush the buffer as text before finalizing.
        if !tagResolved, !raw.isEmpty {
            translated = raw
            raw = ""
            tagResolved = true
        }
        defer { reset() }
        guard let segment = interimSegment() else { return nil }
        return TranslationSegment(text: segment.text, isFinal: true, speaker: nil,
                                  language: segment.language, original: segment.original)
    }

    mutating func reset() {
        translated = ""
        original = ""
        language = nil
        raw = ""
        tagResolved = false
    }

    // MARK: - Tag parsing

    private mutating func resolveTagIfPossible() {
        let head = raw.drop(while: { $0 == " " })
        guard !head.isEmpty else { return }

        guard head.hasPrefix("[") else {
            translated = raw
            raw = ""
            tagResolved = true
            return
        }
        if let close = head.firstIndex(of: "]") {
            let code = String(head[head.index(after: head.startIndex)..<close])
            let remainder = String(head[head.index(after: close)...]).drop(while: { $0 == " " })
            if Self.isLanguageCode(code) {
                language = code.lowercased()
                translated = String(remainder)
            } else {
                // `[something else]` — not a tag; keep the text verbatim.
                translated = raw
            }
            raw = ""
            tagResolved = true
        } else if head.count > Self.maxTagLength {
            // An unclosed `[` this deep isn't a tag.
            translated = raw
            raw = ""
            tagResolved = true
        }
        // else: still ambiguous (e.g. `[e`) — keep buffering.
    }

    /// `es`, `zh`, `pt-BR` — 2–3 letters, optional subtag.
    static func isLanguageCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first, (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isLetter }) else { return false }
        guard parts.count <= 2 else { return false }
        if parts.count == 2 {
            let sub = parts[1]
            guard (2...8).contains(sub.count), sub.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                return false
            }
        }
        return true
    }

    // MARK: - Segments

    private func interimSegment() -> TranslationSegment? {
        guard !translated.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return TranslationSegment(text: translated, isFinal: false, speaker: nil,
                                  language: language,
                                  original: original.isEmpty ? nil : original)
    }
}
