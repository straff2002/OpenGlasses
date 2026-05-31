import Foundation
import NaturalLanguage

/// Splits raw document text into overlapping, sentence-aware chunks for embedding + retrieval.
///
/// Pure and deterministic — no I/O, no embeddings. Sentences are kept whole where possible:
/// chunks are packed up to `targetChars`, and each new chunk re-includes trailing sentences
/// from the previous one (up to `overlapChars`) so a passage that straddles a boundary stays
/// retrievable. A single sentence longer than `maxChars` is hard-split as a last resort.
///
/// Each chunk also carries the page number and nearest section heading active at its first
/// sentence, so retrieval can cite a locatable source ("§5.3, page 42"). Pages are detected
/// from form feeds and "Page N" / "- N -" markers; sections from numbered/Chapter/ALL-CAPS
/// heading lines. Unpaginated input (e.g. a single OCR'd scan) leaves `page` nil.
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
        let page: Int?
        let section: String?
    }

    /// A sentence tagged with the page/section context active where it appears.
    private struct Sentence {
        let text: String
        let page: Int?
        let section: String?
    }

    func chunk(_ raw: String) -> [Chunk] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let sentences = Self.taggedSentences(in: text)
        var chunks: [(text: String, page: Int?, section: String?)] = []
        var current: [Sentence] = []
        var currentLen = 0

        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, let first = current.first else { return }
            chunks.append((joined, first.page, first.section))
        }

        for sentence in sentences {
            let s = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }

            // A single sentence too big to ever fit: flush what we have, then hard-split it.
            // The split pieces inherit the oversized sentence's page/section.
            if s.count > maxChars {
                flush()
                current = []
                currentLen = 0
                for piece in Self.hardSplit(s, maxChars: maxChars) {
                    chunks.append((piece, sentence.page, sentence.section))
                }
                continue
            }

            // Starting this sentence would overflow the target: close the chunk and seed the next
            // one with sentence-aligned overlap.
            if currentLen + s.count + 1 > targetChars && !current.isEmpty {
                flush()
                current = Self.overlapTail(current, overlapChars: overlapChars)
                currentLen = current.reduce(0) { $0 + $1.text.count + 1 }
            }

            current.append(Sentence(text: s, page: sentence.page, section: sentence.section))
            currentLen += s.count + 1
        }
        flush()

        return chunks.enumerated().map {
            Chunk(index: $0.offset, text: $0.element.text, page: $0.element.page, section: $0.element.section)
        }
    }

    // MARK: - Sentence tagging

    /// Tokenise into sentences, each tagged with the page/section context where it starts.
    private static func taggedSentences(in text: String) -> [Sentence] {
        let (breaks, paginated) = pageHeadingBreakpoints(in: text)

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [Sentence] = []
        var bpIdx = 0
        var page = 1            // content before any marker is page 1 (only surfaced when paginated)
        var section: String? = nil

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            while bpIdx < breaks.count && breaks[bpIdx].offset <= offset {
                page = breaks[bpIdx].page
                section = breaks[bpIdx].section
                bpIdx += 1
            }
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                result.append(Sentence(text: s, page: paginated ? page : nil, section: section))
            }
            return true
        }

        // Fall back to the whole text if the tokenizer found nothing usable.
        if result.isEmpty { return [Sentence(text: text, page: nil, section: nil)] }
        return result
    }

    /// A point in the text from which a new (page, section) state applies.
    private struct Breakpoint { let offset: Int; let page: Int; let section: String? }

    /// Single pass producing offset-keyed (page, section) state changes, plus whether the document
    /// showed any pagination evidence at all (form feed or "Page N"). Without evidence, callers
    /// treat page as nil — a lone scanned image isn't "page 1 of N".
    private static func pageHeadingBreakpoints(in text: String) -> (breaks: [Breakpoint], paginated: Bool) {
        var breaks: [Breakpoint] = []
        var page = 1
        var section: String? = nil
        var paginated = false

        var offset = 0
        var lineStart = 0
        var line = ""

        func endLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = pageNumber(in: trimmed) {
                page = n
                paginated = true
                breaks.append(Breakpoint(offset: lineStart, page: page, section: section))
            } else if let heading = detectHeading(trimmed) {
                section = heading
                breaks.append(Breakpoint(offset: lineStart, page: page, section: section))
            }
            line = ""
        }

        for ch in text {
            if ch == "\n" {
                endLine()
                offset += 1
                lineStart = offset
            } else if ch == "\u{0C}" {           // form feed → new page
                endLine()
                page += 1
                paginated = true
                offset += 1
                lineStart = offset
                breaks.append(Breakpoint(offset: offset, page: page, section: section))
            } else {
                line.append(ch)
                offset += 1
            }
        }
        endLine()

        return (breaks, paginated)
    }

    // MARK: - Detection (ported from qaeros documentChunker.js)

    /// A line that reads as a section heading → its text, else nil.
    /// Matches numbered sections ("5.3 Safety"), Chapter/Part/Section/Article N, and ALL-CAPS lines.
    static func detectHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count < 200 else { return nil }

        if trimmed.range(of: #"^\d+(\.\d+)*\s+\S"#, options: .regularExpression) != nil {
            return trimmed
        }
        if trimmed.range(of: #"^(chapter|part|section|article)\s+\d"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed
        }
        if trimmed.range(of: #"^[A-Z0-9\s.,;:()&/-]+$"#, options: .regularExpression) != nil {
            let uppercase = trimmed.filter { $0.isLetter && $0.isUppercase }
            if uppercase.count >= 4 { return trimmed }
        }
        return nil
    }

    /// The page number a marker line denotes ("Page 42" or "- 42 -"), else nil.
    static func pageNumber(in line: String) -> Int? {
        if line.range(of: #"^\s*page\s+\d"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let n = firstInt(in: line), n > 0, n < 10000 {
            return n
        }
        if line.range(of: #"^\s*-\s*\d+\s*-\s*$"#, options: .regularExpression) != nil,
           let n = firstInt(in: line), n > 0, n < 10000 {
            return n
        }
        return nil
    }

    private static func firstInt(in s: String) -> Int? {
        guard let r = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    // MARK: - Packing helpers

    /// Trailing sentences whose cumulative length fits within `overlapChars`, in original order.
    private static func overlapTail(_ sentences: [Sentence], overlapChars: Int) -> [Sentence] {
        guard overlapChars > 0 else { return [] }
        var tail: [Sentence] = []
        var len = 0
        for sentence in sentences.reversed() {
            let next = len + sentence.text.count + 1
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
