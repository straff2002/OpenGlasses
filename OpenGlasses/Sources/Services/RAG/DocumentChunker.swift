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
/// sentence, so retrieval can cite a locatable source ("§5.3, page 42"), plus what kind of page it
/// came from and the figure that names it. Unpaginated input (e.g. a single OCR'd scan) leaves
/// `page` nil.
///
/// **The input grammar.** A document may annotate itself, and both producers of vault text do —
/// [[ManualStructure]] in the app and `Scripts/extract-manual-text.swift` on a Mac, each reading a
/// PDF's type. Every annotation is stripped from the text a chunk quotes:
///
/// - `Page N` (or `- N -`) alone on a line opens a page; a form feed does too.
/// - `## Heading` sets the section. The heading text stays in the chunk — it is content — the
///   hashes do not.
/// - `### Figure 58 — Integrated Control` sets `figure` for what follows on that page; the section
///   is unchanged. On a drawing the page's first caption names the whole page and later ones do not
///   override it, because the page is one picture.
/// - `<!-- page: diagram -->` before any content on a page marks the page a drawing. Any other HTML
///   comment is stripped and ignored, so an author can annotate freely.
///
/// **Lexical fallback.** When a document carries no `## ` heading at all — plain text, EPUB, a
/// recognised scan, a PDF whose fonts are all one size and weight — sections are detected from the
/// numbered/Chapter/ALL-CAPS shapes below, screened against the captions, banners, list steps and
/// table rows an OEM manual is full of. When it carries any, that lexical detection is off for the
/// whole document: type said what the sections are, and guessing beside it only adds noise.
struct DocumentChunker {

    /// Soft target size — packing starts a new chunk once adding the next sentence would exceed this.
    var targetChars: Int
    /// Hard cap — a single oversized sentence is split into pieces no larger than this.
    var maxChars: Int
    /// How much trailing context (in characters, sentence-aligned) to repeat into the next chunk.
    var overlapChars: Int

    /// Join sentences that a line break separated with a line break, not a space (Plan IV P3).
    /// A rule printed on its own line under a one-word group heading reached `ClauseReference` as
    /// "Wiring 12-345 Title", which it rightly grades as a citation: a clause starts a line or
    /// follows sentence punctuation. Keeping the break lets it see the rule start.
    var keepsLineBreaks: Bool
    /// In a document detected as clause-numbered (`clauseHeadingLines`), make each clause heading
    /// line a section and start a new chunk at it, with no overlap carried across (Plan IV P3).
    /// A rule's text then sits in chunks of its own, cited by its number. Never applied to a prose
    /// manual: splitting at every heading of every manual was measured and lowered one.
    var chunksAtClauseHeadings: Bool
    /// Cite a chunk at the page that holds most of its characters, not its first sentence's (Plan
    /// JY P5a). A chunk packed across a page break opened on the earlier page — often with the
    /// sentences it carries over from the chunk before — and cited it, though most of what it says
    /// is on the next. Off here; a document's language turns it on (`sized(for:text:)`), for the
    /// groups where it was measured not to cost.
    var creditsMajorityPage: Bool

    init(targetChars: Int = 700, maxChars: Int = 900, overlapChars: Int = 100,
         keepsLineBreaks: Bool = true, chunksAtClauseHeadings: Bool = true, creditsMajorityPage: Bool = false) {
        // Keep the invariants the packing logic relies on.
        precondition(maxChars >= targetChars, "maxChars must be >= targetChars")
        precondition(overlapChars < targetChars, "overlapChars must be < targetChars to guarantee progress")
        self.targetChars = targetChars
        self.maxChars = maxChars
        self.overlapChars = overlapChars
        self.keepsLineBreaks = keepsLineBreaks
        self.chunksAtClauseHeadings = chunksAtClauseHeadings
        self.creditsMajorityPage = creditsMajorityPage
    }

    /// What kind of page a chunk came off. A drawing's text is a bag of terminal labels: it embeds
    /// to noise and crowds a semantic result, but it is exactly what an exact-token search is for.
    ///
    /// `tableRow` is never produced by the chunker: it is one row of a table extracted from the
    /// PDF, written as a sentence by [[TableRowPassage]] (Plan JJ P0). It is text the app wrote,
    /// not text on the page, so it is not a drawing, it is left out of the document's own text,
    /// and it never opens a page by itself.
    enum Kind: String, Equatable, CaseIterable {
        case prose
        case diagram
        case tableRow = "table_row"
    }

    /// Where a page starts inside a chunk's text (Plan KE P2): the character offset in `text`, and
    /// the page that starts there.
    struct PageBreak: Equatable, Hashable {
        let offset: Int
        let page: Int

        /// The compact form `doc_chunks.page_breaks` stores: "0:11,412:12".
        static func encode(_ breaks: [PageBreak]) -> String {
            breaks.map { "\($0.offset):\($0.page)" }.joined(separator: ",")
        }

        /// A row stored before the column, or a chunk on one page, reads back as no breaks.
        static func decode(_ stored: String?) -> [PageBreak] {
            guard let stored, !stored.isEmpty else { return [] }
            return stored.split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: ":")
                guard parts.count == 2, let offset = Int(parts[0]), let page = Int(parts[1]) else { return nil }
                return PageBreak(offset: offset, page: page)
            }
        }
    }

    struct Chunk: Equatable {
        let index: Int
        let text: String
        let page: Int?
        let section: String?
        var kind: Kind = .prose
        /// The figure or table that names this chunk's place ("Figure 58", "Table 16").
        var figure: String?
        /// Where the chunk sits on its page (Plan IN P0): character offsets of its first
        /// sentence's start and of the end of its last sentence on that page, within the page's
        /// text as the chunker read it (annotations removed). A hint for the highlight, never the
        /// highlight itself — the chunk text is sentence-packed and the page text was rendered from
        /// type, so neither is a literal substring of the PDF's own text layer. Nil for a piece of
        /// a hard-split sentence, whose spacing no longer matches the page.
        var pageStart: Int?
        var pageEnd: Int?
        /// Offsets into `text` where each of the chunk's sentences starts. The highlight is built
        /// sentence by sentence (`PassageLocator`), so a sentence that cannot be found is dropped
        /// rather than the whole passage.
        var sentenceStarts: [Int] = []
        /// The pages a chunk packed across a page break sits on, in reading order, the first at
        /// offset 0 (Plan KE P2). `page` is one page and may be either of them: this says which of
        /// the chunk's words are on which. Empty for a chunk on one page, which is most of them.
        var pageBreaks: [PageBreak] = []
    }

    /// A sentence tagged with the page/section context active where it appears.
    private struct Sentence {
        let text: String
        let page: Int?
        let section: String?
        var kind: Kind = .prose
        var figure: String?
        /// Offset of the sentence's first character within its page's text, when known.
        var pageOffset: Int?
        /// A line break, not just a space, separated this sentence from the one before.
        var followsLineBreak = false
        /// Pages that open inside the sentence (Plan KE P2), offsets into `text`. A form feed does
        /// not end a sentence for the tokenizer, so the run of a table with no full stop in it
        /// carries on over the page, and `page` is only where it starts.
        var turns: [PageBreak] = []
    }

    /// IF: source page indices are authoritative. Chunk each body independently so short or
    /// empty pages and recognised footer numbers cannot merge or renumber a captured page.
    func chunkPages(_ pages: [(number: Int, text: String)]) -> [Chunk] {
        var result: [Chunk] = []
        for page in pages {
            for chunk in chunk(page.text) {
                result.append(Chunk(index: result.count, text: chunk.text, page: page.number,
                                    section: chunk.section, kind: chunk.kind, figure: chunk.figure,
                                    pageStart: chunk.pageStart, pageEnd: chunk.pageEnd,
                                    sentenceStarts: chunk.sentenceStarts))
            }
        }
        return result
    }

    func chunk(_ raw: String) -> [Chunk] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // A clause-numbered document's clause lines become sections, and a chunk starts at each.
        var splitsAtSections = false
        if chunksAtClauseHeadings {
            let headings = Self.clauseHeadingLines(in: text)
            if Self.isClauseNumbered(headings: headings) {
                text = Self.markingClauseHeadings(headings, in: text)
                splitsAtSections = true
            }
        }

        let sentences = Self.taggedSentences(in: text)
        var chunks: [Chunk] = []
        var current: [Sentence] = []
        var currentLen = 0
        // The chunk so far is only the overlap carried from the one before.
        var overlapOnly = false

        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.enumerated().map { index, sentence in
                index == 0 ? sentence.text : (keepsLineBreaks && sentence.followsLineBreak ? "\n" : " ") + sentence.text
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, let first = current.first else { return }
            let place = Self.location(of: current)
            let breaks = Self.pageBreaks(of: current, in: joined)
            var majority = creditsMajorityPage
            var share = 0.0
            #if RETRIEVAL_EVAL
            if RetrievalEvalTuning.p5.contains("majority") { majority = true; share = RetrievalEvalTuning.majorityShare }
            if RetrievalEvalTuning.p5.contains("nomajority") { majority = false }
            #endif
            // The page moves only within one section: a chunk that runs from one section's tail
            // into the next section on the next page keeps its first sentence's page, so the page
            // and section it is cited at are always a pair the book prints together.
            if majority, let page = Self.majorityPage(of: current, share: share), page != first.page,
               current.first(where: { $0.page == page })?.section == first.section {
                // The place is said on the page the chunk is cited at: its first sentence there to
                // the end of its last.
                let onPage = current.filter { $0.page == page }
                let start = onPage.first?.pageOffset
                let end = onPage.compactMap { s in s.pageOffset.map { $0 + s.text.count } }.max()
                chunks.append(Chunk(index: 0, text: joined, page: page, section: first.section,
                                    kind: first.kind, figure: first.figure,
                                    pageStart: start, pageEnd: end, sentenceStarts: place.sentenceStarts,
                                    pageBreaks: breaks))
                return
            }
            chunks.append(Chunk(index: 0, text: joined, page: first.page, section: first.section,
                                kind: first.kind, figure: first.figure,
                                pageStart: place.start, pageEnd: place.end, sentenceStarts: place.sentenceStarts,
                                pageBreaks: breaks))
        }

        for sentence in sentences {
            let s = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }

            // A new clause starts a new chunk, and the last one's tail is not carried in: the
            // clause before is not context for this one's number.
            if splitsAtSections, let open = current.last, open.section != sentence.section {
                if !overlapOnly { flush() }
                current = []
                currentLen = 0
                overlapOnly = false
            }

            #if RETRIEVAL_EVAL
            // Plan JY P5a's measured alternative: a chunk never crosses a page break.
            if RetrievalEvalTuning.p5.contains("split"), let open = current.last, let page = sentence.page,
               let openPage = open.page, page != openPage {
                if !overlapOnly { flush() }
                current = []
                currentLen = 0
                overlapOnly = false
            }
            #endif

            // Prose and a drawing never share a chunk. A chunk takes its kind and figure from its
            // first sentence, so the tail of a page of prose running into a wiring diagram would
            // otherwise swallow the diagram's labels and cite them as prose. No overlap is carried
            // across the seam either — the two sides are not context for each other. Nothing moves
            // in a document that is all one kind, which is every document without a diagram page.
            if let open = current.first, open.kind != sentence.kind {
                flush()
                current = []
                currentLen = 0
            }

            // A single sentence too big to ever fit: flush what we have, then hard-split it.
            // The split pieces inherit the oversized sentence's page/section.
            if s.count > maxChars {
                flush()
                current = []
                currentLen = 0
                var cursor = 0
                for piece in Self.hardSplit(s, maxChars: maxChars) {
                    let place = Self.pieceBreaks(of: sentence, from: cursor, length: piece.count, text: piece)
                    chunks.append(Chunk(index: 0, text: piece, page: place.page, section: sentence.section,
                                        kind: sentence.kind, figure: sentence.figure, sentenceStarts: [0],
                                        pageBreaks: place.breaks))
                    cursor += piece.count + 1
                }
                continue
            }

            // Starting this sentence would overflow the target: close the chunk and seed the next
            // one with sentence-aligned overlap.
            if currentLen + s.count + 1 > targetChars && !current.isEmpty {
                flush()
                current = Self.overlapTail(current, overlapChars: overlapChars)
                currentLen = current.reduce(0) { $0 + $1.text.count + 1 }
                overlapOnly = !current.isEmpty
            }

            current.append(Sentence(text: s, page: sentence.page, section: sentence.section,
                                    kind: sentence.kind, figure: sentence.figure, pageOffset: sentence.pageOffset,
                                    followsLineBreak: sentence.followsLineBreak, turns: sentence.turns))
            currentLen += s.count + 1
            overlapOnly = false
        }
        flush()

        return chunks.enumerated().map { offset, chunk in
            Chunk(index: offset, text: chunk.text, page: chunk.page, section: chunk.section,
                  kind: chunk.kind, figure: chunk.figure, pageStart: chunk.pageStart,
                  pageEnd: chunk.pageEnd, sentenceStarts: chunk.sentenceStarts, pageBreaks: chunk.pageBreaks)
        }
    }

    /// The page holding most of a run of sentences' characters, the earliest on a tie; nil when
    /// none is paginated, or when that page holds less than `share` of them.
    private static func majorityPage(of sentences: [Sentence], share: Double = 0) -> Int? {
        var counts: [Int: Int] = [:]
        var order: [Int] = []
        for sentence in sentences {
            guard let page = sentence.page else { continue }
            if counts[page] == nil { order.append(page) }
            counts[page, default: 0] += sentence.text.count
        }
        let total = counts.values.reduce(0, +)
        guard let best = order.max(by: { a, b in counts[a]! != counts[b]! ? counts[a]! < counts[b]! : order.firstIndex(of: a)! > order.firstIndex(of: b)! }),
              total > 0, Double(counts[best]!) / Double(total) >= share else { return nil }
        return best
    }

    /// Where a run of packed sentences sits: its sentence starts within the joined text, and its
    /// span on the first sentence's page. A sentence carried onto the next page (the tail of a
    /// chunk that crosses a page break) does not stretch the span — the span is a place on one
    /// page.
    private static func location(of sentences: [Sentence]) -> (start: Int?, end: Int?, sentenceStarts: [Int]) {
        var starts: [Int] = []
        var cursor = 0
        for sentence in sentences {
            starts.append(cursor)
            cursor += sentence.text.count + 1
        }
        guard let first = sentences.first, let start = first.pageOffset else { return (nil, nil, starts) }
        var end = start + first.text.count
        for sentence in sentences.dropFirst() where sentence.page == first.page {
            if let offset = sentence.pageOffset { end = max(end, offset + sentence.text.count) }
        }
        return (start, end, starts)
    }

    /// The pages a run of packed sentences sits on: where each page starts in the joined text, from
    /// the page each sentence starts on and the pages that open inside one. Empty when the run is
    /// on one page. A page with no words of the run on it (a blank page, a turn in the whitespace
    /// after a sentence) is not a break: nothing could be cited at it.
    private static func pageBreaks(of sentences: [Sentence], in text: String) -> [PageBreak] {
        var found: [PageBreak] = []
        var cursor = 0
        for sentence in sentences {
            if let page = sentence.page, page != found.last?.page {
                found.append(PageBreak(offset: cursor, page: page))
            }
            for turn in sentence.turns where turn.page != found.last?.page {
                found.append(PageBreak(offset: cursor + turn.offset, page: turn.page))
            }
            cursor += sentence.text.count + 1
        }
        return holdingWords(found, in: text)
    }

    /// `breaks` without those that open no words of `text`, and none at all for fewer than two
    /// pages.
    private static func holdingWords(_ breaks: [PageBreak], in text: String) -> [PageBreak] {
        guard breaks.count > 1 else { return [] }
        let characters = Array(text)
        var kept: [PageBreak] = []
        for (index, candidate) in breaks.enumerated() {
            let end = min(index + 1 < breaks.count ? breaks[index + 1].offset : characters.count, characters.count)
            guard candidate.offset < end,
                  characters[candidate.offset..<end].contains(where: { !$0.isWhitespace }),
                  candidate.page != kept.last?.page else { continue }
            kept.append(candidate)
        }
        return kept.count > 1 ? kept : []
    }

    /// The page a piece of a hard-split sentence starts on, and the pages that open inside it.
    /// `hardSplit` rejoins words with one space, so the offsets are the sentence's own unless it
    /// held a run of spaces, when a mark can land a word or so early. Only ever a mark's place.
    private static func pieceBreaks(of sentence: Sentence, from start: Int, length: Int,
                                    text: String) -> (page: Int?, breaks: [PageBreak]) {
        let page = sentence.turns.last { $0.offset <= start }?.page ?? sentence.page
        guard let page else { return (nil, []) }
        let inside = sentence.turns.filter { $0.offset > start && $0.offset < start + length }
            .map { PageBreak(offset: $0.offset - start, page: $0.page) }
        return (page, holdingWords([PageBreak(offset: 0, page: page)] + inside, in: text))
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
        var kind = Kind.prose
        var figure: String? = nil
        // Sentence ranges arrive in order, so the offset accumulates instead of being measured
        // from the start of the document each time (quadratic on a 200 KB manual).
        var cursor = text.startIndex
        var offset = 0
        var pageOrigin = 0
        var lineBreakPending = false

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            offset += text.distance(from: cursor, to: range.lowerBound)
            cursor = range.lowerBound
            let raw = text[range]
            let leading = raw.prefix(while: { $0.isWhitespace || $0.isNewline })
            // A page or section that opens inside the whitespace the sentence starts with (a form
            // feed after a line break) is the sentence's own: it is where its text begins.
            while bpIdx < breaks.count && breaks[bpIdx].offset <= offset + leading.count {
                page = breaks[bpIdx].page
                section = breaks[bpIdx].section
                kind = breaks[bpIdx].kind
                figure = breaks[bpIdx].figure
                pageOrigin = breaks[bpIdx].pageOrigin
                bpIdx += 1
            }
            let s = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                let lead = leading.count
                // The pages that open inside the sentence: read, not consumed, because the section
                // and kind they bring are for the sentence after it.
                var turns: [PageBreak] = []
                if scanned.paginated {
                    var ahead = bpIdx
                    while ahead < breaks.count, breaks[ahead].offset < offset + lead + s.count {
                        if breaks[ahead].page != (turns.last?.page ?? page) {
                            turns.append(PageBreak(offset: breaks[ahead].offset - offset - lead, page: breaks[ahead].page))
                        }
                        ahead += 1
                    }
                }
                result.append(Sentence(text: s, page: scanned.paginated ? page : nil, section: section,
                                       kind: kind, figure: figure, pageOffset: max(0, offset + lead - pageOrigin),
                                       followsLineBreak: lineBreakPending || leading.contains(where: \.isNewline),
                                       turns: turns))
                lineBreakPending = raw.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })
                    .contains(where: \.isNewline)
            } else if raw.contains(where: \.isNewline) {
                lineBreakPending = true
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

    /// A point in the text from which a new (page, section, kind, figure) state applies. Offsets
    /// are into the scanned text, not the raw input.
    private struct Breakpoint {
        let offset: Int
        let page: Int
        let section: String?
        var kind: Kind = .prose
        var figure: String?
        /// Offset in the scanned text where the page this state belongs to begins, so a sentence's
        /// place can be said relative to its own page (Plan IN P0).
        var pageOrigin: Int = 0
    }

    /// One line-scanning pass over the raw text.
    private struct ScannedText {
        /// The text a chunk may quote: recognised page-marker lines removed, everything else intact.
        let text: String
        /// Offset-keyed (page, section, kind, figure) state changes into `text`.
        let breaks: [Breakpoint]
        /// Whether the document showed any pagination evidence at all (a form feed or a marker
        /// line). Without evidence, callers treat page as nil — a lone scanned image isn't
        /// "page 1 of N".
        let paginated: Bool
    }

    /// Scan the raw text once: strip the marker and grammar lines, record where the page, section,
    /// kind and figure change.
    ///
    /// **Page precedence.** Once a page has been opened — by a form feed or by a marker line — a
    /// further marker before any content on that page is the publisher's own running header and
    /// does not renumber the page. Extraction knows the physical page; a printed header may start
    /// its numbering after an unnumbered cover or roman-numeral front matter, and letting it win
    /// would cite a page the reader cannot turn to. Once a line of content has appeared, the next
    /// marker is a genuine page break — which is the only way a plain-text document paginates.
    /// A grammar line (a comment, a `##` or `###` marker) is an annotation on the page, not content
    /// on it, so an extractor may write one above the publisher's header without losing that rule.
    ///
    /// **Printed folios (Plan JY P4).** In a document an extractor paginated — form feeds, or its
    /// own `Page N` lines — a folio printed alone on a line ("- 397 -") is the publisher's number,
    /// usually at the foot of the page, and never turns or renumbers a page. Read as a page turn,
    /// a footer folio opened the next page under its own number and the extractor's marker after
    /// it was taken for a running header, so every later page was cited by the printed numbering.
    /// A plain-text document paginated only by such folios still turns its pages at them.
    private static func scanLines(in raw: String) -> ScannedText {
        // The grammar is always read; what the presence of a `## ` heading switches off is the
        // lexical guessing beside it.
        let lexical = !hasStructuredHeadings(raw)
        let notTitles = lexical ? tableLines(in: raw) : []
        let extractorPaginated = isExtractorPaginated(raw)
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        var length = 0                  // cleaned.count, tracked as we go
        var breaks: [Breakpoint] = []
        var page = 1
        var section: String? = nil
        var kind = Kind.prose
        var figure: String? = nil
        var paginated = false
        var pageOpen = false
        var contentSincePageOpen = false
        var line = ""
        var pageOrigin = 0

        func mark() {
            breaks.append(Breakpoint(offset: length, page: page, section: section, kind: kind, figure: figure,
                                     pageOrigin: pageOrigin))
        }

        func endLine(terminator: Character?) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            var emitted: String? = line
            if let marker = pageNumber(in: trimmed) {
                emitted = nil           // marker lines are furniture; they never reach a chunk
                paginated = true
                if extractorPaginated && isPrintedFolio(trimmed) {
                    // The publisher's folio on a page the extractor numbered: page unchanged.
                } else if pageOpen && !contentSincePageOpen {
                    // A printed running header on a page already opened: page unchanged.
                } else {
                    page = marker
                    kind = .prose
                    figure = nil
                    pageOpen = true
                    contentSincePageOpen = false
                    // The marker line goes; its line break stays, so the page starts after it.
                    pageOrigin = length + (terminator == nil ? 0 : 1)
                    mark()
                }
            } else if isComment(trimmed) {
                emitted = nil           // an annotation, never quoted back
                if trimmed == ManualStructure.diagramMarker, !contentSincePageOpen {
                    kind = .diagram
                    mark()
                }
            } else if let heading = structuredHeading(trimmed) {
                section = heading
                // A new section starts new material: the figure captioned above it no longer
                // governs. On a drawing the page's own caption stands, because the page is one
                // picture and the citation has to name what the reader will see.
                if kind == .prose { figure = nil }
                mark()
                emitted = heading
            } else if let caption = structuredCaption(trimmed) {
                // On a drawing the first caption names the whole page; on a prose page each
                // caption governs what follows it.
                if kind == .prose || figure == nil {
                    figure = caption.label
                    mark()
                }
                emitted = caption.text
            } else if !trimmed.isEmpty {
                if lexical, !notTitles.contains(trimmed), let heading = detectHeading(trimmed) {
                    section = heading
                    mark()
                }
                contentSincePageOpen = true
            }
            if let emitted {
                cleaned += emitted
                length += emitted.count
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
                kind = .prose
                figure = nil
                paginated = true
                pageOpen = true
                contentSincePageOpen = false
                pageOrigin = length
                mark()
            } else {
                line.append(ch)
            }
        }
        endLine(terminator: nil)

        return ScannedText(text: cleaned, breaks: breaks, paginated: paginated)
    }

    // MARK: - The structured grammar

    /// Whether the document annotates its own sections. One `## ` line is enough: an extractor
    /// that found any structure in the type found all of it, and mixing in lexical guesses beside
    /// it is what produced `§1- DATA LOW CONNECTION`.
    static func hasStructuredHeadings(_ raw: String) -> Bool {
        raw.range(of: #"(?m)^[ \t]*##[ \t]+\S"#, options: .regularExpression) != nil
    }

    /// A whole-line HTML comment — an annotation the author or the extractor left for the chunker.
    private static func isComment(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") && trimmed.count >= 7
    }

    /// The heading text of a `## ` line, else nil. Exactly two hashes — a third makes it `### `,
    /// which is a caption and never matches this prefix.
    private static func structuredHeading(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("## ") else { return nil }
        let text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The figure a `### ` caption names, with the caption text that stays in the chunk.
    private static func structuredCaption(_ trimmed: String) -> (label: String, text: String)? {
        guard trimmed.hasPrefix("### ") else { return nil }
        let text = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let match = text.range(of: #"^(Figure|Table)\s+\S+"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let label = String(text[match])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t.:\u{2014}\u{2013}-"))
        return (label, String(text))
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
        #"^\d+(\.\d+)*\.?\s+\p{Ll}"#,   // 2.6 or greater / 1 hour soft lockout.
        #"^\d+(\.\d+)*\s*="#,            // 3 = Low Line, a key to a code
        #"^\d\s+\d\s"#                    // 1 2 TO PANEL, a connector's pins
    ]

    /// Units a figure is printed with. A figure and its unit is a value in a column, however it is
    /// followed: alone ("24 VAC") or running into the sentence it was wrapped from ("24 VDC is
    /// fed to"), and neither is a place. "24 VDC Supply" is a title and stays.
    private static let unit = #"(?:V|VA|VAC|VDC|A|AMPS?|MA|MV|W|KW|HZ|PSI|PSIG|KPA|RPM|CFM|BTU|OHMS?|MM|CM|Cu\.?\s+Ft\.?)"#

    /// Whether a line starting with a number is a row of a table (Plan KE P2). The line's own
    /// shape, in the cases that can be told from it alone: a word printed three times or a number
    /// printed twice is a column of values, never a title ("7 ON LOW ON ON"), though a title may
    /// use a word twice ("9 Control Board to Control Box").
    private static func isNumberedRow(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let number = words.first, number.first?.isNumber == true else { return false }
        if words.dropFirst().contains(number) { return true }
        var counts: [String: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        if counts.values.contains(where: { $0 >= 3 }) { return true }
        return line.range(of: #"^\d+(\.\d+)?\s+"# + unit + #"(?:,\s*\S+)?$|^\d+(\.\d+)?\s+"# + unit + #"\s+\p{Ll}"#,
                          options: .regularExpression) != nil
            || line.range(of: #"^\d+\s+\p{Lu}{1,2}$"#, options: .regularExpression) != nil
    }

    /// More titles in capitals than a page of text ever prints. A page past it is a table or a
    /// drawing the extractor did not recognise as one, and each of its labels would otherwise open
    /// a section ("FAN MOTOR", "TO PANEL"), which every page after it is then cited under (Plan KE
    /// P2).
    static let maximumCapitalTitles = 5

    /// The lines that read as headings and are a table's or a drawing's (Plan KE P2), which a rule
    /// over one line cannot tell. On one page, numbered headings go up. "3 Fixed Shelf" over "1 Door Bin" is a column of quantities, and no
    /// rule over the line alone can tell it from "12 Wiring". Only a whole number that numbers the
    /// line is compared: a dotted section under its chapter's running header counts down by design,
    /// and in "24 VAC Supply" the number is a value. A line at the top or foot of its page that is
    /// printed on another page too is a running header or footer, and takes no part. Past
    /// `maximumCapitalTitles` on a page, so are its capitals.
    static func tableLines(in raw: String) -> Set<String> {
        var pages: [[String]] = [[]]
        var line = ""
        func endLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            line = ""
            if pageNumber(in: trimmed) != nil {
                pages.append([])
            } else if !trimmed.isEmpty {
                pages[pages.count - 1].append(trimmed)
            }
        }
        for character in raw {
            if character == "\n" {
                endLine()
            } else if character == "\u{0C}" {
                endLine()
                pages.append([])
            } else {
                line.append(character)
            }
        }
        endLine()
        var pagesHolding: [String: Int] = [:]
        for page in pages { for text in Set(page) { pagesHolding[text, default: 0] += 1 } }
        var rows = Set<String>()
        for page in pages {
            let numbered = page.indices.compactMap { index -> (number: Int, line: String)? in
                let text = page[index]
                let furniture = (index == 0 || index == page.count - 1) && (pagesHolding[text] ?? 0) > 1
                guard !furniture, let found = text.range(of: #"^\d{1,3}(?=\s)"#, options: .regularExpression),
                      text.range(of: #"^\d+\s+"# + unit + #"(?:\s|$)"#, options: .regularExpression) == nil,
                      detectHeading(text) != nil, let number = Int(text[found]) else { return nil }
                return (number, text)
            }
            if zip(numbered, numbered.dropFirst()).contains(where: { $0.number >= $1.number }) {
                rows.formUnion(numbered.map(\.line))
            }
            let capitals = page.filter { $0.first?.isLetter == true && detectHeading($0) != nil }
            if capitals.count > maximumCapitalTitles {
                // The page's own title, at its head, is still one.
                let headed = capitals.first.map { page.prefix(2).contains($0) } ?? false
                rows.formUnion(capitals.dropFirst(headed ? 1 : 0))
            }
        }
        return rows
    }

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
        if isNumberedRow(trimmed) { return nil }

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
            if isCapitalsNote(trimmed, words: words) { return nil }
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

    /// A line in capitals that is no title (Plan KE P2): a drawing's note in brackets, a bracket left
    /// open by a wrapped cell, a sentence in capitals, a code printed with its letters spaced out
    /// (half its words a single character), or one word printed twice.
    private static func isCapitalsNote(_ line: String, words: [Substring]) -> Bool {
        if line.hasPrefix("("), line.hasSuffix(")") { return true }
        if line.filter({ $0 == "(" }).count != line.filter({ $0 == ")" }).count { return true }
        if line.hasSuffix(".") || line.range(of: #"\.\s+\p{Lu}"#, options: .regularExpression) != nil { return true }
        if words.filter({ $0.count == 1 }).count * 2 >= words.count { return true }
        return Set(words).count == 1
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

    /// A folio printed alone on a line, "- 42 -": the publisher's page number, not an extractor's.
    static func isPrintedFolio(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^-\s*\d{1,4}\s*-$"#, options: .regularExpression) != nil
    }

    /// Whether an extractor numbered the document's pages itself: a form feed between pages (the
    /// app's PDF extractor) or a `Page N` line (the Mac extractor's).
    static func isExtractorPaginated(_ raw: String) -> Bool {
        raw.contains("\u{0C}")
            || raw.range(of: #"(?mi)^[ \t]*page[ \t]+\d{1,4}[ \t]*$"#, options: .regularExpression) != nil
    }

    private static func firstInt(in s: String) -> Int? {
        guard let r = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    // MARK: - Clause-numbered documents (Plan IV P3)

    /// How many distinct clause headings make a document clause-numbered. A code book prints
    /// hundreds; a prose manual with a few numbered sections prints fewer than this, and a manual
    /// whose numbering is procedure steps ("1. Ignitor") prints none, because a step's number has
    /// no second part.
    static let minimumClauseHeadings = 10

    /// Whether a document is clause-numbered: enough distinct clause heading lines (Plan IV P3).
    /// Retrieval reads the same rule off a stored document to decide how many passages to send
    /// (Plan IV P6).
    static func isClauseNumbered(_ text: String) -> Bool {
        isClauseNumbered(headings: clauseHeadingLines(in: text))
    }

    private static func isClauseNumbered(headings: [String]) -> Bool {
        headings.count >= minimumClauseHeadings
    }

    /// The lines that read as a clause heading: a number with at least two parts ("12-345",
    /// "3.9.4", "110.26"), then a capitalised word, on a short line of its own. Distinct numbers
    /// only — a heading repeated as a running header counts once.
    ///
    /// A script without case (Plan JY P4) has no capital to start the word with, so there the
    /// number is followed by a letter of that script (`\p{Lo}`: Han, kana, Hangul, Arabic), with
    /// or without a space. A Latin or Cyrillic letter is never `\p{Lo}`, so their rule is as it was.
    static func clauseHeadingLines(in text: String) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("## ") ? String(trimmed.dropFirst(3)) : trimmed
            guard body.count <= 90,
                  let number = body.range(of: clauseNumberPattern, options: .regularExpression) else { continue }
            if seen.insert(String(body[number])).inserted { lines.append(trimmed) }
        }
        return lines
    }

    /// A clause heading's number, as `clauseHeadingLines` reads it.
    static var clauseNumberPattern: String {
        #if RETRIEVAL_EVAL
        if RetrievalEvalTuning.p4Off.contains("clauses") { return #"^\d{1,3}(?:[.\-]\d{1,4}){1,4}(?=\s+\p{Lu}\p{Ll})"# }
        #endif
        return #"^\d{1,3}(?:[.\-]\d{1,4}){1,4}(?=\s+\p{Lu}\p{Ll}|\s*\p{Lo})"#
    }

    /// The text with each clause heading line set as a section heading (`## `), which the
    /// grammar below already reads. Lines already marked are left alone.
    static func markingClauseHeadings(_ headings: [String], in text: String) -> String {
        let marked = Set(headings.filter { !$0.hasPrefix("## ") })
        guard !marked.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return marked.contains(trimmed) ? "## " + trimmed : String(line)
        }.joined(separator: "\n")
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
    ///
    /// A CJK run has no spaces, so the whole sentence is one "word"; it is broken after its own
    /// punctuation instead (Plan JY P4) — 。！？； first, then ，、 — and sliced raw only where a
    /// piece has none. A run with no CJK punctuation is sliced exactly as before.
    static func hardSplit(_ sentence: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var buffer = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            let w = String(word)
            if w.count > maxChars {
                if !buffer.isEmpty { pieces.append(buffer); buffer = "" }
                #if RETRIEVAL_EVAL
                if RetrievalEvalTuning.p4Off.contains("split") {
                    pieces.append(contentsOf: w.chunkedByCharacters(maxChars))
                    continue
                }
                #endif
                pieces.append(contentsOf: w.chunkedAtCJKPunctuation(maxChars))
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
    /// CJK punctuation a piece may end after, strongest first (Plan JY P4).
    static let cjkClauseEnds: [Set<Character>] = [["。", "！", "？", "；"], ["，", "、"]]

    /// Pieces of at most `size` characters, each ending after the last CJK sentence or clause
    /// mark that fits (a sentence end preferred), else sliced raw. With no such mark in the text
    /// this is `chunkedByCharacters(size)` exactly.
    func chunkedAtCJKPunctuation(_ size: Int) -> [String] {
        guard size > 0, count > size else { return [self] }
        let all = Self.cjkClauseEnds.reduce(Set<Character>()) { $0.union($1) }
        guard contains(where: { all.contains($0) }) else { return chunkedByCharacters(size) }
        let characters = Array(self)
        var result: [String] = []
        var start = 0
        while characters.count - start > size {
            let window = characters[start..<(start + size)]
            var cut: Int?
            for marks in Self.cjkClauseEnds {
                // A mark in the window's second half, so a piece is never cut to a sliver.
                if let last = window.lastIndex(where: { marks.contains($0) }), last - start >= size / 2 {
                    cut = last + 1
                    break
                }
            }
            let end = cut ?? (start + size)
            result.append(String(characters[start..<end]))
            start = end
        }
        if start < characters.count { result.append(String(characters[start...])) }
        return result
    }

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
