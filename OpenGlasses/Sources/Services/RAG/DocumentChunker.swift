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
/// sentence, so retrieval can cite a locatable source ("§5.3, page 42"). Pages are detected from
/// form feeds and whole-line "Page N" / "- N -" markers, which are then removed from the text a
/// chunk quotes; sections from numbered/Chapter/ALL-CAPS heading lines, screened against the
/// captions, banners, list steps and table rows an OEM manual is full of. Unpaginated input
/// (e.g. a single OCR'd scan) leaves `page` nil.
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
    ///
    /// Tokenisation runs over the *scanned* text — recognised page-marker lines removed — because
    /// a marker rarely ends a sentence: "Page 34\nTEST B Use an ohmmeter…" tokenises as one
    /// sentence, so a marker cannot be dropped after the fact without cutting into real prose.
    private static func taggedSentences(in raw: String) -> [Sentence] {
        let scanned = scanLines(in: raw)
        let text = scanned.text
        let breaks = scanned.breaks

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [Sentence] = []
        var bpIdx = 0
        var page = 1            // content before any marker is page 1 (only surfaced when paginated)
        var section: String? = nil
        // Sentence ranges arrive in order, so the offset accumulates instead of being measured
        // from the start of the document each time (quadratic on a 200 KB manual).
        var cursor = text.startIndex
        var offset = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            offset += text.distance(from: cursor, to: range.lowerBound)
            cursor = range.lowerBound
            while bpIdx < breaks.count && breaks[bpIdx].offset <= offset {
                page = breaks[bpIdx].page
                section = breaks[bpIdx].section
                bpIdx += 1
            }
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                result.append(Sentence(text: s, page: scanned.paginated ? page : nil, section: section))
            }
            return true
        }

        // Fall back to the whole text if the tokenizer found nothing usable.
        if result.isEmpty {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [Sentence(text: whole, page: nil, section: nil)]
        }
        return result
    }

    /// A point in the text from which a new (page, section) state applies. Offsets are into the
    /// scanned text, not the raw input.
    private struct Breakpoint { let offset: Int; let page: Int; let section: String? }

    /// One line-scanning pass over the raw text.
    private struct ScannedText {
        /// The text a chunk may quote: recognised page-marker lines removed, everything else intact.
        let text: String
        /// Offset-keyed (page, section) state changes into `text`.
        let breaks: [Breakpoint]
        /// Whether the document showed any pagination evidence at all (a form feed or a marker
        /// line). Without evidence, callers treat page as nil — a lone scanned image isn't
        /// "page 1 of N".
        let paginated: Bool
    }

    /// Scan the raw text once: strip marker lines, record where the page and section change.
    ///
    /// **Page precedence.** Once a page has been opened — by a form feed or by a marker line — a
    /// further marker within that page's first two non-empty lines is the publisher's own running
    /// header and does not renumber the page. Extraction knows the physical page; a printed header
    /// may start its numbering after an unnumbered cover or roman-numeral front matter, and letting
    /// it win would cite a page the reader cannot turn to. A marker deeper in the page is a genuine
    /// page break, which is how a plain-text document paginates at all.
    private static func scanLines(in raw: String) -> ScannedText {
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        var length = 0                  // cleaned.count, tracked as we go
        var breaks: [Breakpoint] = []
        var page = 1
        var section: String? = nil
        var paginated = false
        var pageOpen = false
        var linesSincePageOpen = 0
        var line = ""

        func endLine(terminator: Character?) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            var keepText = true
            if let marker = pageNumber(in: trimmed) {
                keepText = false        // marker lines are furniture; they never reach a chunk
                paginated = true
                if pageOpen && linesSincePageOpen < 2 {
                    linesSincePageOpen += 1     // a printed running header: page unchanged
                } else {
                    page = marker
                    pageOpen = true
                    linesSincePageOpen = 0
                    breaks.append(Breakpoint(offset: length, page: page, section: section))
                }
            } else if !trimmed.isEmpty {
                if let heading = detectHeading(trimmed) {
                    section = heading
                    breaks.append(Breakpoint(offset: length, page: page, section: section))
                }
                linesSincePageOpen += 1
            }
            if keepText {
                cleaned += line
                length += line.count
            }
            if let terminator {
                cleaned.append(terminator)
                length += 1
            }
            line = ""
        }

        for ch in raw {
            if ch == "\n" {
                endLine(terminator: ch)
            } else if ch == "\u{0C}" {          // form feed → new page
                endLine(terminator: nil)
                cleaned.append(ch)
                length += 1
                page += 1
                paginated = true
                pageOpen = true
                linesSincePageOpen = 0
                breaks.append(Breakpoint(offset: length, page: page, section: section))
            } else {
                line.append(ch)
            }
        }
        endLine(terminator: nil)

        return ScannedText(text: cleaned, breaks: breaks, paginated: paginated)
    }

    // MARK: - Detection

    /// Lines an OEM manual prints as labels rather than section titles. A caption or a safety
    /// banner is not a place in the document, and citing one tells the reader nothing.
    private static let labelPrefix = #"^(figure|table|note|notes|warning|caution|danger|important)\b"#

    /// A numbered line that is a list step or a spec-table row rather than a heading. The
    /// separator after the number is what tells them apart: "7 - Inspect…", "1) Remove…" and
    /// "2.6 or greater…" are content, while "4.2 Gas Piping" is a place.
    private static let numberedNonHeading = [
        #"^\d+(\.\d+)*\s+[-–—]\s"#,     // 7 - Inspect the condensate drain
        #"^\d+(\.\d+)*\s*\)"#,           // 1) Remove
        #"^\d+(\.\d+)*\.?\s+\p{Ll}"#    // 2.6 or greater / 1 hour soft lockout.
    ]

    /// A line that reads as a section heading → its text, else nil.
    ///
    /// Accepts numbered sections ("5.3 Safety Requirements"), Chapter/Part/Section/Article N, and
    /// ALL-CAPS titles. Everything an OEM manual prints that merely *looks* like one — figure and
    /// table captions, safety banners, numbered list steps, spec-table rows, terminal designations
    /// and part-number columns — is rejected, because the heading is spoken aloud as part of a
    /// citation and a wrong one is worse than none. ("BOTTOM RETURN AIR" and its like stay: a
    /// multi-word all-letter title is a real place in a furnace manual.)
    static func detectHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // A citation is read out, so a heading has to be short enough to say.
        guard trimmed.count >= 4, trimmed.count <= 80 else { return nil }

        if trimmed.range(of: labelPrefix, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        // A label carrying a leading number is still a label — "30 TABLE 30 on page 59 for
        // allowable heating speeds." is a wrapped cross-reference, not a place in the document.
        if let number = trimmed.range(of: #"^\d+(\.\d+)*[.)]?\s+"#, options: .regularExpression),
           String(trimmed[number.upperBound...]).range(of: labelPrefix,
                                                       options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        for pattern in numberedNonHeading where trimmed.range(of: pattern, options: .regularExpression) != nil {
            return nil
        }

        // A row of figures is a table, not a title.
        let digits = trimmed.reduce(0) { $1.isNumber ? $0 + 1 : $0 }
        let letters = trimmed.reduce(0) { $1.isLetter ? $0 + 1 : $0 }
        if digits > letters { return nil }
        // More than one run of padding is a set of columns that lost its rules.
        if spacedRuns(in: trimmed) > 1 { return nil }

        if trimmed.range(of: #"^\d+(\.\d+)*\s+\S"#, options: .regularExpression) != nil {
            return trimmed
        }
        if trimmed.range(of: #"^(chapter|part|section|article)\s+\d"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed
        }
        if trimmed.range(of: #"^[A-Z0-9\s.,;:()&/-]+$"#, options: .regularExpression) != nil {
            let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            let uppercase = trimmed.filter { $0.isLetter && $0.isUppercase }
            let nonSpace = trimmed.filter { !$0.isWhitespace }
            // A word mixing letters and digits is a part number or a terminal designation
            // ("24VAXC", "090XV60C"), never a word in a title.
            let mixedToken = words.contains { w in w.contains(where: \.isLetter) && w.contains(where: \.isNumber) }
            if words.count >= 2, uppercase.count >= 4, !mixedToken,
               Float(letters) >= 0.6 * Float(nonSpace.count) {
                return trimmed
            }
        }
        return nil
    }

    /// How many runs of two or more consecutive whitespace characters the line contains.
    private static func spacedRuns(in line: String) -> Int {
        var runs = 0
        var run = 0
        for ch in line {
            if ch.isWhitespace {
                run += 1
                if run == 2 { runs += 1 }
            } else {
                run = 0
            }
        }
        return runs
    }

    /// The page number a marker line denotes ("Page 42" or "- 42 -"), else nil.
    ///
    /// The whole line must be the marker. A prefix match renumbers the page from any wrapped line
    /// of a table of contents ("Page 62 VII Typical Operating Characteristics"), which is how a
    /// document's first chunk ends up citing page 62.
    static func pageNumber(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMarker = trimmed.range(of: #"^page\s+\d{1,4}$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || trimmed.range(of: #"^-\s*\d{1,4}\s*-$"#, options: .regularExpression) != nil
        guard isMarker, let n = firstInt(in: trimmed), n > 0, n < 10000 else { return nil }
        return n
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
