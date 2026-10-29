import Foundation
import NaturalLanguage

// Where a cited passage is on its page (Plan IN P0).
//
// The partner's electrician asked for two things after a source with every answer: the page on
// request, and the exact supporting passage marked on it, so he reads the requirement rather than
// the whole page. This file is the headless half of the second: where a chunk sits, which printed
// page a physical page carries, and the ranges on a PDF page's own text layer that hold the
// chunk's sentences. Nothing here draws; `PassageHighlighter` does, from what this returns.

// MARK: - A chunk's place

/// What the store keeps about where a chunk came from on its page, read back for the highlight.
struct PassageAnchor: Equatable, Hashable {
    let documentId: String
    let chunkIndex: Int
    /// The chunk's text, as cited.
    let text: String
    /// The physical page (PDF index + 1).
    let page: Int?
    /// The chunk's span within its page's text as the chunker read it — see
    /// `DocumentChunker.Chunk.pageStart`. A tie-breaker when a sentence appears twice on a page.
    let pageStart: Int?
    let pageEnd: Int?
    /// Offsets into `text` where each sentence starts. Empty for a row stored before the column
    /// existed; the locator then splits the text itself.
    let sentenceStarts: [Int]
    /// For a table's row passage (Plan JJ P1), whose text is the app's sentence and not the page's:
    /// the runs of the row as printed on its line, longest first. The locator marks the first run
    /// that appears exactly once on the page, and nothing when none does. Empty for any other
    /// chunk, which is located by its sentences.
    let printedRuns: [String]

    init(documentId: String, chunkIndex: Int, text: String, page: Int?, pageStart: Int? = nil,
         pageEnd: Int? = nil, sentenceStarts: [Int] = [], printedRuns: [String] = []) {
        self.documentId = documentId
        self.chunkIndex = chunkIndex
        self.text = text
        self.page = page
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.sentenceStarts = sentenceStarts
        self.printedRuns = printedRuns
    }

    /// The chunk's sentences, from the stored starts when there are any.
    var sentences: [String] { PassageLocator.sentences(of: text, starts: sentenceStarts) }

    /// The compact form `doc_chunks.sentences` stores: "0,112,240".
    static func encode(_ starts: [Int]) -> String { starts.map(String.init).joined(separator: ",") }

    static func decode(_ stored: String?) -> [Int] {
        guard let stored, !stored.isEmpty else { return [] }
        return stored.split(separator: ",").compactMap { Int($0) }
    }
}

// MARK: - Printed page numbers (decision 4)

/// The number a page carries in print, beside the physical index the PDF knows it by.
///
/// A code book's printed page 112 can be PDF page 130: a cover, a contents and roman-numeral front
/// matter come first. A citation that says "page 130" sends the reader to the wrong place in the
/// paper book, and one that says "page 112" opens the wrong page in the viewer, so both numbers are
/// kept and each is used for what it is.
struct PageLabel: Equatable, Hashable {
    enum Source: String, Equatable {
        /// The PDF's own page label (`PDFPage.label`), set by the publisher.
        case pdfLabel = "pdf_label"
        /// A lone number, or roman numeral, printed in the page's top or bottom band — or a number
        /// at a band line's end that runs in step with the physical page (Plan JW P0).
        case printed
    }

    /// Physical page, 1-based.
    let page: Int
    /// What is printed: "112", "iv", "A-3".
    let label: String
    let source: Source
}

/// Physical ↔ printed, both ways, for one document.
struct PageLabelMap: Equatable {
    private let byPage: [Int: String]

    init(_ labels: [PageLabel]) {
        byPage = Dictionary(labels.map { ($0.page, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { byPage.isEmpty }

    /// The printed label of a physical page, when one is known.
    func printed(forPhysical page: Int) -> String? { byPage[page] }

    /// The physical page a printed label names. Nil when no page carries it, or when more than one
    /// does — "page 3" of the front matter and of the body cannot both be right, and opening either
    /// would be a guess.
    func physical(forPrinted label: String) -> Int? {
        let hits = physicalPages(forPrinted: label)
        return hits.count == 1 ? hits[0] : nil
    }

    /// Every physical page that carries `label`, in page order: none, one, or — front matter and
    /// body both printing "3" — several, which a caller refuses rather than picks from.
    func physicalPages(forPrinted label: String) -> [Int] {
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        return byPage.filter { $0.value.lowercased() == wanted }.map(\.key).sorted()
    }
}

/// Reads the printed page number out of the text of a page's top or bottom band.
enum PrintedPageBand {

    /// The page number the band text prints, or nil. A line that is only a number ("112",
    /// "- 112 -", "Page 112") or only a roman numeral ("iv") counts; a line with anything else on
    /// it does not, because a header is full of numbers that are not page numbers — a clause, a
    /// year, a model. When the band prints two different candidates, neither is trusted.
    static func label(in bandText: String) -> String? {
        let lines = bandText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var found = Set<String>()
        for line in lines {
            if let candidate = candidate(line) { found.insert(candidate) }
        }
        return found.count == 1 ? found.first : nil
    }

    // MARK: A folio that shares its line (Plan JW P0)

    /// Fewest pages an in-step offset must hold on, over the whole document, before a number at a
    /// line's end is read as the page.
    static let minimumInStepPages = 3
    /// How far either side of a page a neighbour holding the same offset may be: a blank page or a
    /// full-page drawing with no footer between two pages does not break the run.
    static let inStepNeighbourReach = 2

    /// The numbers printed at the outer ends of the band's lines: each line's first and last word,
    /// when it is a plain number of one to four digits ("399", "- 399 -" is a lone-number line
    /// and read by `label(in:)`). A footer such as "<month> <year> © <year> <publisher> 399" gives
    /// 399, never the years inside the line.
    static func lineEndNumbers(in bandText: String) -> Set<Int> {
        var out = Set<Int>()
        for line in bandText.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            for word in [words.first, words.last].compactMap({ $0 }) {
                let digits = word.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2014}\u{2013}-|\u{00B7}\u{2022}()[]"))
                guard (1...4).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                      let number = Int(digits), number > 0 else { continue }
                out.insert(number)
            }
        }
        return out
    }

    /// The printed label of every page of a document (Plan JW P0), from the PDF's own labels and
    /// the text of each page's top and bottom band. `bands[i]` is physical page `i + 1`'s band;
    /// `pdfLabels` maps a physical page to the publisher's label where it says something other
    /// than the physical number. Pure, so every rule is tested without a PDF.
    ///
    /// In order, for each page: the publisher's label; else a lone number on a band line
    /// (`label(in:)`); else a number at the outer end of a band line that runs **in step** with the
    /// physical page — its offset (number − physical page) is held by a neighbouring page within
    /// `inStepNeighbourReach`, and by at least `minimumInStepPages` pages over the document. A
    /// book that prints its folio at the end of the footer line beside a date and a copyright
    /// notice reads that way, while a year or an edition number, the same on every page, changes
    /// its offset with every page and never qualifies. Where two in-step numbers compete, the one
    /// whose offset more pages hold wins; a tie gives no label. A page none of this reads gets no
    /// entry: unknown is not "the same as the physical page".
    static func labels(bands: [String], pdfLabels: [Int: String] = [:]) -> [PageLabel] {
        let ends = bands.map(lineEndNumbers(in:))
        var pagesByOffset: [Int: Int] = [:]
        for (index, numbers) in ends.enumerated() {
            for offset in Set(numbers.map { $0 - (index + 1) }) { pagesByOffset[offset, default: 0] += 1 }
        }
        func inStep(_ physical: Int) -> String? {
            let held = ends[physical - 1].compactMap { number -> (number: Int, pages: Int)? in
                let offset = number - physical
                let pages = pagesByOffset[offset] ?? 0
                guard pages >= minimumInStepPages else { return nil }
                let neighbours = (physical - inStepNeighbourReach)...(physical + inStepNeighbourReach)
                let agrees = neighbours.contains { other in
                    other != physical && other >= 1 && other <= ends.count && ends[other - 1].contains(offset + other)
                }
                return agrees ? (number, pages) : nil
            }
            guard let best = held.max(by: { $0.pages < $1.pages }),
                  held.filter({ $0.pages == best.pages }).count == 1 else { return nil }
            return String(best.number)
        }
        var out: [PageLabel] = []
        for (index, band) in bands.enumerated() {
            let physical = index + 1
            if let publisher = pdfLabels[physical] {
                out.append(PageLabel(page: physical, label: publisher, source: .pdfLabel))
            } else if let printed = Self.label(in: band) ?? inStep(physical) {
                out.append(PageLabel(page: physical, label: printed, source: .printed))
            }
        }
        return out
    }

    private static let arabic = try! NSRegularExpression(
        pattern: #"(?i)^(?:page\s+)?(?:[—–-]\s*)?([0-9]{1,4})(?:\s*[—–-])?$"#)
    private static let roman = try! NSRegularExpression(
        pattern: #"(?i)^(?:page\s+)?(?:[—–-]\s*)?(m{0,1}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3}))(?:\s*[—–-])?$"#)

    private static func candidate(_ line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = arabic.firstMatch(in: line, range: range), let r = Range(match.range(at: 1), in: line),
           let number = Int(line[r]), number > 0 {
            return String(number)
        }
        if let match = roman.firstMatch(in: line, range: range), let r = Range(match.range(at: 1), in: line),
           !r.isEmpty {
            return line[r].lowercased()
        }
        return nil
    }
}

// MARK: - Finding the passage on the page

/// What locating a passage on a page came to.
enum PassageLocation: Equatable {
    /// The passage's sentences that were found, as ranges in the PDF page's own text (UTF-16, as
    /// `PDFPage.selection(for:)` takes them), in reading order. `dropped` sentences could not be
    /// anchored and are simply not marked.
    case located(ranges: [NSRange], dropped: Int)
    /// Nothing can be marked. Named, because the viewer says so in words (decision 3).
    case notLocatable(Reason)

    enum Reason: String, Equatable {
        /// The page has no text layer — a scan, or a photographed page.
        case noTextLayer = "no_text_layer"
        /// The page has text, and none of the passage's sentences was found whole in it.
        case notFound = "not_found"
    }

    var ranges: [NSRange] {
        if case .located(let ranges, _) = self { return ranges }
        return []
    }
}

/// Finds a chunk's sentences in a PDF page's text (Plan IN P0, decision 3).
///
/// A highlight is read as the requirement, so a wrong one is worse than none: only what is found
/// is marked. The chunk text and the PDF's text layer disagree in every way that does not change
/// the words — line breaks, hyphenation at a line end, ligatures, curly quotes, a heading the
/// extractor re-marked, a table's pipes — so both sides are folded to their letters and digits,
/// lower-cased and stripped of diacritics, and a sentence is found only if the whole of it appears
/// there. One that does not — interrupted by a running header, reflowed across a column — is
/// dropped from the highlight rather than stretched to fit.
///
/// Pure: strings in, ranges out.
enum PassageLocator {

    /// Below this many folded characters a sentence ("Note.", "2.") is too short to anchor on its
    /// own: it is marked only if it appears once on the page, or right after the sentence before it.
    static let shortSentence = 12
    /// How far after the previous sentence a short one may sit and still be taken as its neighbour.
    static let neighbourGap = 40

    static func locate(_ anchor: PassageAnchor, onPageText pageText: String?) -> PassageLocation {
        guard anchor.printedRuns.isEmpty else { return locate(printedRuns: anchor.printedRuns, onPageText: pageText) }
        return locate(sentences: anchor.sentences, onPageText: pageText, hint: anchor.pageStart)
    }

    /// A table row as printed (Plan JJ P1): the first of `runs` found exactly once on the page,
    /// whole. A run found twice — two rows printing the same words and values — is never chosen
    /// between, and a row none of whose runs is found opens its page unmarked (decision 3).
    static func locate(printedRuns runs: [String], onPageText pageText: String?) -> PassageLocation {
        guard let pageText else { return .notLocatable(.noTextLayer) }
        let page = Folded(pageText)
        guard !page.scalars.isEmpty else { return .notLocatable(.noTextLayer) }
        let ns = pageText as NSString
        for run in runs {
            let needle = Folded(run).scalars
            guard needle.count >= shortRun else { continue }
            // Whole words only, the same words: "QX4 12.5" folds to what "QX41 2.5" folds to, and
            // is not it.
            let words = foldedWords(run)
            let hits = occurrences(of: needle, in: page.scalars).filter { start in
                let range = page.utf16Range(from: start, to: start + needle.count)
                return !isWordCharacter(at: range.location - 1, in: ns) && !isWordCharacter(at: NSMaxRange(range), in: ns)
                    && foldedWords(ns.substring(with: range)) == words
            }
            guard hits.count == 1 else { continue }
            let range = page.utf16Range(from: hits[0], to: hits[0] + needle.count)
            return .located(ranges: [closingPunctuation(range, in: ns)], dropped: 0)
        }
        return .notLocatable(.notFound)
    }

    /// Fewest folded characters a printed row run is matched on. Below it ("30 35") a run is too
    /// likely to be part of another row to stand for one, however rarely it is printed.
    static let shortRun = 6

    /// The text's words as folding reads them, each a run of folded letters and digits.
    private static func foldedWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            let folded = Folded.fold(character)
            if folded.isEmpty {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current += String(String.UnicodeScalarView(folded.compactMap(Unicode.Scalar.init)))
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    static func locate(sentences: [String], onPageText pageText: String?, hint: Int? = nil) -> PassageLocation {
        guard let pageText else { return .notLocatable(.noTextLayer) }
        let page = Folded(pageText)
        guard !page.scalars.isEmpty else { return .notLocatable(.noTextLayer) }

        var found: [(start: Int, end: Int)] = []     // folded indices, end exclusive
        var dropped = 0
        for sentence in sentences {
            let needle = Folded(sentence).scalars
            guard !needle.isEmpty else { continue }
            let hits = occurrences(of: needle, in: page.scalars)
            let after = found.last?.end ?? 0
            let choice: Int?
            if needle.count < shortSentence {
                if hits.count == 1 {
                    choice = hits[0]
                } else {
                    choice = hits.first { $0 >= after && $0 - after <= neighbourGap && !found.isEmpty }
                }
            } else if hits.count <= 1 {
                choice = hits.first
            } else if !found.isEmpty {
                choice = hits.first { $0 >= after } ?? hits.first
            } else if let hint {
                // The first sentence, found twice: the copy nearer where the chunker saw it.
                choice = hits.min { abs(page.utf16Start(of: $0) - hint) < abs(page.utf16Start(of: $1) - hint) }
            } else {
                choice = hits.first
            }
            guard let start = choice else { dropped += 1; continue }
            found.append((start, start + needle.count))
        }
        guard !found.isEmpty else { return .notLocatable(.notFound) }

        // Neighbouring sentences with nothing but spaces and punctuation between them are one mark.
        var merged: [(start: Int, end: Int)] = []
        for span in found.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        let ns = pageText as NSString
        let ranges = merged.map { Self.closingPunctuation(page.utf16Range(from: $0.start, to: $0.end), in: ns) }
        return .located(ranges: ranges, dropped: dropped)
    }

    /// Folding drops punctuation, so a match ends on the sentence's last letter or digit. The mark
    /// takes in the full stop, bracket or quote that touches it on either side — "500 mm." is the
    /// requirement as printed — and never runs across a space.
    static func closingPunctuation(_ range: NSRange, in text: NSString) -> NSRange {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        func isPunctuation(_ index: Int) -> Bool {
            guard index >= 0, index < text.length,
                  let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return punctuation.contains(scalar)
        }
        var start = range.location
        var end = NSMaxRange(range)
        while end < text.length, end - NSMaxRange(range) < 3, isPunctuation(end) { end += 1 }
        let openers = CharacterSet(charactersIn: "\"'\u{201C}\u{2018}([")
        while start > 0, range.location - start < 2,
              let scalar = Unicode.Scalar(text.character(at: start - 1)), openers.contains(scalar) { start -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The sentences of a chunk: split at the stored starts, or by the tokenizer when the row
    /// predates them.
    static func sentences(of text: String, starts: [Int]) -> [String] {
        guard !starts.isEmpty else {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            var result: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { result.append(s) }
                return true
            }
            return result.isEmpty ? [text] : result
        }
        let characters = Array(text)
        let bounds = (starts.filter { $0 >= 0 && $0 < characters.count } + [characters.count])
        var result: [String] = []
        for (from, to) in zip(bounds, bounds.dropFirst()) where to > from {
            let s = String(characters[from..<to]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
        }
        return result
    }

    private static func occurrences(of needle: [UInt32], in haystack: [UInt32]) -> [Int] {
        guard needle.count <= haystack.count, let first = needle.first else { return [] }
        var hits: [Int] = []
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { hits.append(i) }
            }
            i += 1
        }
        return hits
    }

    /// Text reduced to the characters that carry its words, each remembering where it came from.
    struct Folded {
        /// Folded letters and digits.
        private(set) var scalars: [UInt32] = []
        /// For each folded scalar, the UTF-16 range of the source character it came from.
        private var sources: [NSRange] = []

        init(_ text: String) {
            var location = 0
            for character in text {
                let length = String(character).utf16.count
                let source = NSRange(location: location, length: length)
                location += length
                for scalar in Self.fold(character) {
                    scalars.append(scalar)
                    sources.append(source)
                }
            }
        }

        func utf16Start(of index: Int) -> Int { sources[index].location }

        func utf16Range(from start: Int, to end: Int) -> NSRange {
            let first = sources[start]
            let last = sources[end - 1]
            return NSRange(location: first.location, length: last.location + last.length - first.location)
        }

        private static let ligatures: [Character: String] = [
            "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl",
            "\u{FB05}": "st", "\u{FB06}": "st", "\u{0152}": "oe", "\u{0153}": "oe", "\u{00C6}": "ae", "\u{00E6}": "ae",
        ]

        /// One character's contribution: its letters and digits, case- and accent-folded.
        static func fold(_ character: Character) -> [UInt32] {
            let base = ligatures[character] ?? String(character)
            let folded = base.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
            return folded.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(\.value)
        }
    }
}
