import Foundation
import NaturalLanguage

/// Splits raw document text into overlapping, sentence-aware chunks for embedding + retrieval.
///
/// Pure and deterministic — no I/O, no embeddings. Sentences are kept whole where possible:
/// chunks are packed up to `targetChars`, and each new chunk re-includes trailing sentences
/// from the previous one (up to `overlapChars`) so a passage that straddles a boundary stays
/// retrievable. A single sentence longer than `maxChars` is hard-split as a last resort.
struct DocumentChunker {

    /// Soft target size — packing starts a new chunk once adding the next sentence would exceed this.
    var targetChars: Int
    /// Hard cap — a single oversized sentence is split into pieces no larger than this.
    var maxChars: Int
    /// How much trailing context (in characters, sentence-aligned) to repeat into the next chunk.
    var overlapChars: Int

    init(targetChars: Int = 700, maxChars: Int = 900, overlapChars: Int = 100) {
        // Keep the invariants the packing logic relies on.
        precondition(maxChars >= targetChars, "maxChars must be >= targetChars")
        precondition(overlapChars < targetChars, "overlapChars must be < targetChars to guarantee progress")
        self.targetChars = targetChars
        self.maxChars = maxChars
        self.overlapChars = overlapChars
    }

    struct Chunk: Equatable {
        let index: Int
        let text: String
    }

    func chunk(_ raw: String) -> [Chunk] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let sentences = Self.sentences(in: text)
        var chunks: [String] = []
        var current: [String] = []
        var currentLen = 0

        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { chunks.append(joined) }
        }

        for sentence in sentences {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }

            // A single sentence too big to ever fit: flush what we have, then hard-split it.
            if s.count > maxChars {
                flush()
                current = []
                currentLen = 0
                for piece in Self.hardSplit(s, maxChars: maxChars) { chunks.append(piece) }
                continue
            }

            // Starting this sentence would overflow the target: close the chunk and seed the next
            // one with sentence-aligned overlap.
            if currentLen + s.count + 1 > targetChars && !current.isEmpty {
                flush()
                current = Self.overlapTail(current, overlapChars: overlapChars)
                currentLen = current.reduce(0) { $0 + $1.count + 1 }
            }

            current.append(s)
            currentLen += s.count + 1
        }
        flush()

        return chunks.enumerated().map { Chunk(index: $0.offset, text: $0.element) }
    }

    // MARK: - Helpers

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            return true
        }
        // Fall back to the whole text if the tokenizer found nothing usable.
        return result.isEmpty ? [text] : result
    }

    /// Trailing sentences whose cumulative length fits within `overlapChars`, in original order.
    private static func overlapTail(_ sentences: [String], overlapChars: Int) -> [String] {
        guard overlapChars > 0 else { return [] }
        var tail: [String] = []
        var len = 0
        for sentence in sentences.reversed() {
            let next = len + sentence.count + 1
            if next > overlapChars && !tail.isEmpty { break }
            tail.append(sentence)
            len = next
            if len >= overlapChars { break }
        }
        return tail.reversed()
    }

    /// Split an oversized sentence on word boundaries into pieces no larger than `maxChars`,
    /// falling back to raw character slicing for a single word that is itself too long.
    private static func hardSplit(_ sentence: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var buffer = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            let w = String(word)
            if w.count > maxChars {
                if !buffer.isEmpty { pieces.append(buffer); buffer = "" }
                pieces.append(contentsOf: w.chunkedByCharacters(maxChars))
                continue
            }
            if buffer.isEmpty {
                buffer = w
            } else if buffer.count + 1 + w.count > maxChars {
                pieces.append(buffer)
                buffer = w
            } else {
                buffer += " " + w
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }
}

private extension String {
    /// Slice into fixed-size character pieces (used only for pathological single words).
    func chunkedByCharacters(_ size: Int) -> [String] {
        guard size > 0, count > size else { return [self] }
        var result: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[idx..<end]))
            idx = end
        }
        return result
    }
}
