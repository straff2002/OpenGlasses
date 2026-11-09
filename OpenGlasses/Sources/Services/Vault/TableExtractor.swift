import CoreGraphics
import Foundation

/// One word on a page and where it sits, read off the PDF's text layer (Plan JJ P0).
///
/// Used only to find a table's rows and columns, and never stored: the passages a manual is
/// searched by keep the text [[VaultDocumentExtractor]] has always produced.
struct PositionedWord: Equatable {
    var text: String
    /// The word's box in **top-down** page coordinates: the origin is the page's top left and y
    /// grows downwards, so a line lower on the page has a larger `minY`.
    var rect: CGRect
    /// Point size of the word's font.
    var size: Double
    var bold: Bool
    /// On a page the PDF turns to show it, a word still drawn the page's own way up — a running
    /// head or footer — and so on its side as the page is shown (Plan JW follow-up).
    var sideways: Bool

    init(_ text: String, rect: CGRect, size: Double, bold: Bool = false, sideways: Bool = false) {
        self.text = text
        self.rect = rect
        self.size = size
        self.bold = bold
        self.sideways = sideways
    }

    /// A word whose box sits at `x`, with its top at `y`, sized as type of `size` points sets it.
    /// What the pure fixtures build words with.
    init(_ text: String, x: Double, y: Double, size: Double = 9, bold: Bool = false, width: Double? = nil) {
        let w = width ?? Double(text.count) * size * 0.55
        self.init(text, rect: CGRect(x: x, y: y, width: w, height: size), size: size, bold: bold)
    }

    /// Set on its side: a box much taller than it is wide for a word of several letters, or a
    /// word read as `sideways`.
    var isRotated: Bool { sideways || (text.count >= 3 && rect.height > 2 * rect.width) }
}

/// A table extracted from an organisation's own loaded manual or code book (Plan JJ P0): its
/// caption, its column headers as paths, its rows by their header paths, every cell's text with a
/// number and a unit where one parses, and the notes printed under it.
///
/// Derived on the phone at import from the PDF the organisation loaded, stored beside the
/// document's passages, and never shipped, exported, packed or linked (decision 1).
struct ManualTable: Codable, Equatable {

    /// A page the table is on: the PDF's own page number and, where the PDF or its header and
    /// footer say, the number printed on it (Plan IN P0).
    struct Page: Codable, Equatable, Hashable {
        var physical: Int
        var printed: String?

        init(physical: Int, printed: String? = nil) {
            self.physical = physical
            self.printed = printed
        }

        /// The number a reader turns to: the printed one when known.
        var spoken: String { printed ?? String(physical) }
    }

    /// A value column. `path` runs from the outermost group heading to the column's own heading
    /// ("Rating group 2", "75"); empty when the table prints no header over it.
    struct Column: Codable, Equatable {
        var path: [String]
        var unit: String?
        /// Read from a picture and its heading not clear enough to name the column by (Plan JN P1,
        /// [[CellCertainty]]): a lookup that names it gives no value. Always false off a text layer.
        var uncertain: Bool

        init(path: [String], unit: String? = nil, uncertain: Bool = false) {
            self.path = path
            self.unit = unit
            self.uncertain = uncertain
        }

        private enum CodingKeys: String, CodingKey { case path, unit, uncertain }

        /// A column stored before Plan JN P1 has no `uncertain` and reads as clear.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode([String].self, forKey: .path)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            uncertain = try container.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
        }

        /// `uncertain` is written only when set, so a text-layer table stores exactly the JSON it
        /// stored before.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(unit, forKey: .unit)
            if uncertain { try container.encode(true, forKey: .uncertain) }
        }

        static let pathSeparator = " › "
        var name: String { path.joined(separator: Self.pathSeparator) }
    }

    struct Cell: Codable, Equatable {
        /// As printed, footnote marker included.
        var text: String
        /// The number the cell carries, when it is one (marker and unit aside).
        var value: Double?
        /// The cell's own unit, else its column's, when the cell is a number.
        var unit: String?
        /// Footnote markers on the cell: "*", "1" for a superscript one, "a" for "(a)".
        var markers: [String]
        /// Read from a picture and not clear enough to give (Plan JN P0): a word under the
        /// confidence floor, a glyph a number could be mistaken for, or two readings that disagree
        /// ([[CellCertainty]]). The text is kept as read, for the page to be checked against, and is
        /// never given as a value. Always false for a cell off a text layer.
        var uncertain: Bool
        /// What checking the table against its page said of this cell (Plan JN P3,
        /// [[TableChecks]]): set only when checks are applied to a table read from a picture, for
        /// the lookup that gives it and the check view. Never stored: the table keeps what was
        /// read, and the checks are kept beside it.
        var check: TableCellCheck? = nil

        init(text: String, value: Double? = nil, unit: String? = nil, markers: [String] = [], uncertain: Bool = false) {
            self.text = text
            self.value = value
            self.unit = unit
            self.markers = markers
            self.uncertain = uncertain
        }

        var isEmpty: Bool { text.isEmpty }

        private enum CodingKeys: String, CodingKey { case text, value, unit, markers, uncertain }

        /// A cell stored before Plan JN has no `uncertain` and reads as certain.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            value = try container.decodeIfPresent(Double.self, forKey: .value)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            markers = try container.decode([String].self, forKey: .markers)
            uncertain = try container.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
        }

        /// `uncertain` is written only when set, so a text-layer table stores exactly the JSON it
        /// stored before Plan JN.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(value, forKey: .value)
            try container.encodeIfPresent(unit, forKey: .unit)
            try container.encode(markers, forKey: .markers)
            if uncertain { try container.encode(true, forKey: .uncertain) }
        }
    }

    struct Row: Codable, Equatable {
        /// The row's group heading (when one is printed above it), then its row-header cells.
        var path: [String]
        /// One per value column, in column order; an empty cell where the table prints none.
        var cells: [Cell]
        /// The page this row is printed on — a table continued over pages keeps each row's own.
        var page: Page
        /// Read from a picture and its key (the row-header cells, or the heading over it) not clear
        /// enough to find the row by (Plan JN P1, [[CellCertainty]]): a lookup that lands on it
        /// gives no value, since a misread key points at another row's values. Always false off a
        /// text layer.
        var keyUncertain: Bool

        init(path: [String], cells: [Cell], page: Page, keyUncertain: Bool = false) {
            self.path = path
            self.cells = cells
            self.page = page
            self.keyUncertain = keyUncertain
        }

        private enum CodingKeys: String, CodingKey { case path, cells, page, keyUncertain }

        /// A row stored before Plan JN P1 has no `keyUncertain` and reads as clear.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode([String].self, forKey: .path)
            cells = try container.decode([Cell].self, forKey: .cells)
            page = try container.decode(Page.self, forKey: .page)
            keyUncertain = try container.decodeIfPresent(Bool.self, forKey: .keyUncertain) ?? false
        }

        /// `keyUncertain` is written only when set, so a text-layer table stores exactly the JSON it
        /// stored before.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(cells, forKey: .cells)
            try container.encode(page, forKey: .page)
            if keyUncertain { try container.encode(true, forKey: .keyUncertain) }
        }
    }

    struct Note: Codable, Equatable {
        /// The marker the note is keyed by ("*", "1", "a"), or nil for an unmarked note.
        var marker: String?
        var text: String
    }

    /// Where the table's grid was read from (Plan JN P0). A value read from a picture says so,
    /// every time it is given.
    enum Source: Codable, Equatable {
        /// The PDF's own text layer: what every table was before Plan JN.
        case textLayer
        /// A picture of the table, read on the phone by `reader`, its words recognised with
        /// `meanConfidence` (0–1) on average.
        case recognised(reader: Reader, meanConfidence: Double)

        /// Which recognised reading made the grid.
        enum Reader: String, Codable, Equatable {
            /// The recogniser's own table: cells by row and column range ([[RecognisedGrid]]).
            case documentGrid = "document_grid"
            /// Recognised words laid out by the text extractor's own rules ([[RecognisedWords]]).
            case words
        }

        var isRecognised: Bool {
            if case .recognised = self { return true }
            return false
        }
    }

    /// Where on a page a table read from a picture was printed (Plan JN P2): the region that was
    /// recognised, in top-down page points from the page's top left (the space
    /// [[PictureRegion]] works in), on the PDF's own page. "Show me the table" outlines it, since
    /// a picture has no text to mark.
    struct PictureArea: Codable, Equatable {
        var physical: Int
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(physical: Int, rect: CGRect) {
            self.physical = physical
            x = Double(rect.minX)
            y = Double(rect.minY)
            width = Double(rect.width)
            height = Double(rect.height)
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// "Table 99".
    var label: String
    var title: String
    /// Where the table starts.
    var page: Page
    /// The headings over the row-header columns ("Designation", "Conductors").
    var rowHeaders: [String]
    var columns: [Column]
    var rows: [Row]
    var notes: [Note]
    /// The caption read "(Continued)" and no earlier page of the table was found to join it to.
    var continues: Bool
    /// Set when the caption was found and its page did not resolve to a grid (Plan JJ P1). Such a
    /// table is kept by its label, title and page only, with no columns and no rows, so a lookup
    /// can say the table is there and could not be read, and name the page to show, rather than
    /// say the book has no such table.
    var failure: TableExtractor.Failure?
    /// The text layer, or a picture of the table (Plan JN P0).
    var source: Source
    /// The regions a table read from a picture was recognised from, one per page (Plan JN P2).
    /// Empty off a text layer, and for a recognised table stored before P2.
    var pictureAreas: [PictureArea] = []
    /// Set when the organisation requires a table read from a picture to be checked before its
    /// values are given and this one is not (Plan JN P3, `organizationRequiresTableChecks`): a
    /// lookup on it gives no value at all. Set by [[TableChecks]] when checks are applied, never
    /// stored.
    var uncheckedWithheld = false

    init(label: String, title: String, page: Page, rowHeaders: [String] = [], columns: [Column],
         rows: [Row], notes: [Note] = [], continues: Bool = false, failure: TableExtractor.Failure? = nil,
         source: Source = .textLayer) {
        self.label = label
        self.title = title
        self.page = page
        self.rowHeaders = rowHeaders
        self.columns = columns
        self.rows = rows
        self.notes = notes
        self.continues = continues
        self.failure = failure
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case label, title, page, rowHeaders, columns, rows, notes, continues, failure, source, pictureAreas
    }

    /// A table stored before Plan JN has no `source` and reads as off the text layer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        title = try container.decode(String.self, forKey: .title)
        page = try container.decode(Page.self, forKey: .page)
        rowHeaders = try container.decode([String].self, forKey: .rowHeaders)
        columns = try container.decode([Column].self, forKey: .columns)
        rows = try container.decode([Row].self, forKey: .rows)
        notes = try container.decode([Note].self, forKey: .notes)
        continues = try container.decode(Bool.self, forKey: .continues)
        failure = try container.decodeIfPresent(TableExtractor.Failure.self, forKey: .failure)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .textLayer
        pictureAreas = try container.decodeIfPresent([PictureArea].self, forKey: .pictureAreas) ?? []
    }

    /// `source` is written only for a recognised table, and `pictureAreas` only when there are
    /// any, so a text-layer table stores exactly the JSON it stored before Plan JN.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(title, forKey: .title)
        try container.encode(page, forKey: .page)
        try container.encode(rowHeaders, forKey: .rowHeaders)
        try container.encode(columns, forKey: .columns)
        try container.encode(rows, forKey: .rows)
        try container.encode(notes, forKey: .notes)
        try container.encode(continues, forKey: .continues)
        try container.encodeIfPresent(failure, forKey: .failure)
        if source != .textLayer { try container.encode(source, forKey: .source) }
        if !pictureAreas.isEmpty { try container.encode(pictureAreas, forKey: .pictureAreas) }
    }

    /// A caption whose page extracted nothing, kept as a pointer to its page.
    static func unextracted(_ caption: TableExtractor.Caption, page: Page,
                            failure: TableExtractor.Failure) -> ManualTable {
        ManualTable(label: caption.label, title: caption.title, page: page, columns: [], rows: [],
                    continues: caption.continues, failure: failure)
    }

    /// The table's grid was read. False for a caption kept only as a pointer to its page.
    var isExtracted: Bool { failure == nil }

    /// Every page the table is printed on, in order.
    var pages: [Page] {
        var seen: [Page] = [page]
        for row in rows where !seen.contains(row.page) { seen.append(row.page) }
        return seen
    }

    /// "Table 99 (Conductor ratings)", or the label alone.
    var displayName: String { title.isEmpty ? label : "\(label) (\(title))" }
}

/// Reads a captioned table off a page's positioned words (Plan JJ P0). Pure: words and a caption
/// in, a `ManualTable` or the reason there is none out, so every rule is tested without a PDF.
///
/// **How the grid is found.** Words that share a line become a line, and words close enough to be
/// one phrase become a cell. The lines between the caption (and its title) and the first body row
/// are the header: the leading run of bold lines, or, on a page set in one weight, the lines
/// before the first row of numbers. The body is the run of lines under it, ended by
/// a note, a wide gap or a paragraph. Columns are the union of the body cells' horizontal extents,
/// taken over the rows with the most common number of cells, so a column is wherever the body
/// prints something and a gap is wherever it never does. A heading over several columns becomes a
/// level of the column path; a heading printed alone over a run of rows becomes a level of their
/// row path.
///
/// **What is not a table.** Fewer than three body rows, columns that do not come out as many as
/// the rows have cells, or more than a few rows that do not fit the grid, and the page extracts
/// nothing. A wiring diagram with numbers on it is never a table, and a caption over prose is
/// reported, not guessed at.
enum TableExtractor {

    struct Caption: Equatable {
        /// "Table 99", "Table 95A", "Table Q7" — the word, then the label as printed; the same
        /// spelling `ManualStructure.caption` gives the chunk's `figure`.
        var label: String
        var title: String
        /// The caption read "(Continued)".
        var continues: Bool
    }

    /// Why a captioned table did not extract. The classes the private measurement counts.
    enum Failure: String, Codable, CaseIterable, Equatable {
        /// The page has no words at all — a scan, or a photographed page.
        case noTextLayer = "no_text_layer"
        /// The caption named was not found on the page.
        case captionNotFound = "caption_not_found"
        /// Fewer than three rows of two or more cells under the caption.
        case tooFewRows = "too_few_rows"
        /// The rows do not agree on how many columns there are.
        case varyingColumnCount = "varying_column_count"
        /// Rows with a cell spanning several columns, more than the tolerance allows.
        case mergedCells = "merged_cells"
        /// The grid failed and the table sets words on their side, most likely its headings.
        case rotatedHeaders = "rotated_headers"
        /// Under the caption the page's text stops for a long stretch with no grid above it: the
        /// table is printed there with no text the PDF gives — a picture, or type drawn as shapes
        /// (Plan JJ P5). Only a recogniser could read it.
        case noTextInTable = "no_text_in_table"
        /// The table was read from a picture and its grid passed the structural tests, but too few
        /// of its cells could be read clearly to trust it (Plan JN P0, [[CellCertainty]]): kept as an
        /// unread table that names its page, never as a sparse one.
        case unclearInPicture = "unclear_in_picture"
    }

    enum Outcome: Equatable {
        case table(ManualTable)
        case failed(Failure)

        var table: ManualTable? {
            if case .table(let table) = self { return table }
            return nil
        }

        var failure: Failure? {
            if case .failed(let failure) = self { return failure }
            return nil
        }
    }

    /// Fewer body rows than this and there is no grid to trust.
    static let minimumBodyRows = 3
    /// The share of body rows allowed not to fit the grid (a merged cell, two phrases in one
    /// column) before the page is refused.
    static let misfitTolerance = 0.15

    // MARK: - Lines and phrases

    /// Words that share a line, left to right, with the cells they make.
    struct Line: Equatable {
        var words: [PositionedWord]
        var top: Double
        var bottom: Double
        /// The line's dominant point size.
        var size: Double

        var text: String { words.map(\.text).joined(separator: " ") }

        /// Most of the line's letters are set in bold.
        var isBold: Bool {
            let bold = words.filter(\.bold).reduce(0) { $0 + $1.text.count }
            let all = words.reduce(0) { $0 + $1.text.count }
            return all > 0 && bold * 2 > all
        }

        /// A word set smaller than the line and raised above it — or a mark of one or two
        /// characters set that small, whose box PDFKit may report at the line's full height: a
        /// footnote marker.
        func isSuperscript(_ word: PositionedWord) -> Bool {
            guard word.size < 0.8 * size else { return false }
            return Double(word.rect.maxY) < bottom - 0.15 * (bottom - top) || word.text.count <= 2
        }

        /// The line's words joined into cells: words closer than half the type size are one
        /// phrase; a superscript after a phrase is that phrase's marker.
        var phrases: [Phrase] {
            var out: [Phrase] = []
            let gap = max(2, 0.5 * size)
            for word in words.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                if isSuperscript(word) {
                    let marker = TableExtractor.normalisedMarker(word.text)
                    if var last = out.last, Double(word.rect.minX - last.maxX) <= gap * 2 {
                        last.markers.append(marker)
                        last.maxX = max(last.maxX, Double(word.rect.maxX))
                        out[out.count - 1] = last
                    } else {
                        out.append(Phrase(text: "", minX: Double(word.rect.minX), maxX: Double(word.rect.maxX),
                                          markers: [marker], bold: word.bold, leadingMarker: true))
                    }
                    continue
                }
                if var last = out.last, Double(word.rect.minX) - last.maxX <= gap {
                    last.text += last.text.isEmpty ? word.text : " " + word.text
                    last.maxX = max(last.maxX, Double(word.rect.maxX))
                    out[out.count - 1] = last
                } else {
                    out.append(Phrase(text: word.text, minX: Double(word.rect.minX), maxX: Double(word.rect.maxX),
                                      markers: [], bold: word.bold))
                }
            }
            return out
        }
    }

    /// One cell's worth of words on a line.
    struct Phrase: Equatable {
        var text: String
        var minX: Double
        var maxX: Double
        var markers: [String]
        var bold: Bool
        /// The phrase began with a superscript marker ("¹ Applies to …").
        var leadingMarker = false

        var center: Double { (minX + maxX) / 2 }
        /// The text as printed, its superscript markers written after it as superscripts.
        var printed: String {
            let marks = markers.map(TableExtractor.superscripted).joined()
            return leadingMarker ? (marks + (text.isEmpty ? "" : " " + text)) : text + marks
        }
    }

    /// The page's words grouped into lines, top to bottom. Words set on their side are left out
    /// (they are counted by the caller); a superscript joins the line it is raised above.
    static func lines(of words: [PositionedWord]) -> [Line] {
        let upright = words.filter { !$0.text.isEmpty && $0.rect.height > 0 && !$0.isRotated }
        guard !upright.isEmpty else { return [] }
        let sizes = upright.map(\.size).sorted()
        let median = sizes[sizes.count / 2]
        let normal = upright.filter { $0.size >= 0.8 * median }
        let small = upright.filter { $0.size < 0.8 * median }

        var lines: [Line] = []
        for word in normal.sorted(by: { ($0.rect.midY, $0.rect.minX) < ($1.rect.midY, $1.rect.minX) }) {
            let mid = Double(word.rect.midY)
            if var last = lines.last, mid <= last.bottom, mid >= last.top - 0.5 * last.size {
                last.words.append(word)
                last.top = min(last.top, Double(word.rect.minY))
                last.bottom = max(last.bottom, Double(word.rect.maxY))
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(words: [word], top: Double(word.rect.minY), bottom: Double(word.rect.maxY),
                                  size: word.size))
            }
        }
        // Larger first, so a table set smaller than the page's prose forms its lines before the
        // superscripts on it look for one.
        for word in small.sorted(by: { ($1.size, $0.rect.midY) < ($0.size, $1.rect.midY) }) {
            let mid = Double(word.rect.midY)
            if let index = lines.firstIndex(where: { mid >= $0.top - 0.25 * $0.size && mid <= $0.bottom }) {
                lines[index].words.append(word)
            } else {
                lines.append(Line(words: [word], top: Double(word.rect.minY), bottom: Double(word.rect.maxY),
                                  size: word.size))
            }
        }
        lines.sort { $0.top < $1.top }
        for index in lines.indices {
            lines[index].words.sort { $0.rect.minX < $1.rect.minX }
            let weights = lines[index].words.reduce(into: [Double: Int]()) { $0[$1.size, default: 0] += $1.text.count }
            lines[index].size = weights.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? lines[index].size
        }
        return lines
    }

    // MARK: - Captions

    /// What follows the word `TABLE` in a caption, and is kept as printed in its label (Plan JJ
    /// P5): a number, with one letter after it ("95A", "12b") or one or two capitals before it
    /// ("Q7", "DB3"). A letter run straight into a word ("16Wiring", a text layer that lost its
    /// space) is not part of the label. Several tables share a number and differ by the letter, so
    /// a label read as its digits alone would merge them, and "(Continued)" would join the wrong
    /// pages.
    ///
    /// **Dotted labels (Plan JY P5a).** A regulation numbers its tables by clause ("Table 2.7.2.2.1"):
    /// read to its first dot, every table in a chapter shared one label and the rest of the number
    /// became the title (12 of 12 captions in one regulation's English edition, 7 of 7 in its
    /// Russian). The dotted parts are the label's now. A full stop before the title ("Table 12.
    /// Clearances") is not one — a dotted part is digits.
    static let labelPattern = #"(?:[A-Z]{1,2}\d{1,4}|\d{1,4})(?:\.\d{1,4}){0,6}(?:[A-Za-z](?![\p{L}\p{N}]))?"#
    private static let captionPattern = #"^(?i:TABLE)\s+("# + labelPattern + ")"
    private static let figurePattern = #"^(?i:FIGURE)\s+"# + labelPattern
    /// "(Continued)", and "(Concluded)" on a table's last page (Plan JW P0): either way the caption
    /// carries on a table begun on an earlier page.
    private static let continuedPattern = #"[\(\[]?\s*\b(?:continued|concluded|cont'd|cont\.)\s*[\)\]]?"#

    /// Longest line read as a caption on a page set in one weight.
    static let plainCaptionMaximumWords = 12

    /// The table caption a line carries, starting `TABLE` (any case) and a number.
    ///
    /// Where the page sets anything in bold, the caption must be bold — the rule
    /// `ManualStructure.caption` applies to typed lines, so every caption that names a chunk's
    /// `figure` is a caption here with the same label, and a cross-reference in a sentence is not
    /// bold and is not a caption. A page whose text layer carries no bold at all (a code book set
    /// in one font, with no weight in its text layer) has no bold to read, so there the caption is
    /// the line that begins `Table N` and stands on its own: at most
    /// `plainCaptionMaximumWords` words, with no sentence ended before its last word. The grid that
    /// must follow is what keeps a short line of prose that begins with a table reference from
    /// extracting anything. `ManualStructure.caption` is unchanged: it names passages and decides
    /// which pages open (Plan IV measured it), and a table found here only on a plain page is not
    /// named there.
    ///
    /// A revision mark printed in the margin on the caption's own line (Plan JW P0) is not part of
    /// it: the rules read the line from its first word after the marks (`captionHead(of:)`), so the
    /// bold rule applies to that word and the mark counts toward no other rule.
    static func caption(of line: Line, pageHasBold: Bool = true) -> Caption? {
        guard let start = captionHead(of: line) else { return nil }
        let first = start.first, text = start.text
        if pageHasBold {
            guard first.bold else { return nil }
        } else {
            guard standsAlone(text) else { return nil }
        }
        guard let match = text.range(of: captionPattern, options: .regularExpression) else {
            // Another interface language's caption word (Plan JY P4), after the English rule.
            guard let other = CaptionWords.match(text), other.kind == .table else { return nil }
            return Caption(label: other.label, title: other.title, continues: other.continues)
        }
        let head = String(text[match])
        let number = head.range(of: labelPattern + "$", options: .regularExpression).map { String(head[$0]) } ?? ""
        var title = String(text[match.upperBound...])
        var continues = false
        if let range = title.range(of: continuedPattern, options: [.regularExpression, .caseInsensitive]) {
            continues = true
            title.removeSubrange(range)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t.:\u{2014}\u{2013}-"))
        return Caption(label: "Table \(number)", title: title, continues: continues)
    }

    // MARK: Margin marks (Plan JW P0)

    /// Characters a mark glued to a caption's first word may not be: an opening bracket or a quote
    /// starts a cross-reference ("(Table 99)"), and a footnote marker starts a note.
    private static let notMarginMark: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}",
                                                         "*", "\u{2020}", "\u{2021}", "\u{00A7}", "\u{2016}", "\u{00B6}"]

    /// A character a code book prints in the margin to flag a revision: a triangle, a bar, an
    /// arrow, a bullet — anything that is neither a letter nor a digit — or the triangle set as a
    /// Greek capital delta, which a text layer reads as a letter.
    static func isMarginMarkCharacter(_ character: Character) -> Bool {
        if character == "\u{0394}" { return true }
        return !character.isLetter && !character.isNumber && !character.isWhitespace && !notMarginMark.contains(character)
    }

    /// A word that is only a margin mark: one or more mark characters, no letter or digit.
    static func isMarginMark<S: StringProtocol>(_ word: S) -> Bool {
        !word.isEmpty && word.allSatisfy(isMarginMarkCharacter)
    }

    /// `text` from its first word after the margin marks: mark words standing apart dropped, and a
    /// mark glued to the first word ("\u{25B2}TABLE") cut from it. Shared by the table and passage
    /// caption rules, so a marked caption names the same label in both.
    static func droppingMarginMarks(_ text: String) -> String {
        var rest = Substring(text).drop(while: \.isWhitespace)
        while let word = rest.split(whereSeparator: \.isWhitespace).first, isMarginMark(word) {
            rest = rest[word.endIndex...].drop(while: \.isWhitespace)
        }
        // A mark glued to a word is cut only when a word follows it: "\u{0394}TABLE", not "\u{0394}".
        let glued = rest.prefix(while: isMarginMarkCharacter)
        if !glued.isEmpty, rest.dropFirst(glued.count).first?.isLetter == true { rest = rest.dropFirst(glued.count) }
        return String(rest)
    }

    /// The caption rules' view of a line: its first word after any margin marks, and its text from
    /// there. Nil for a line of marks only.
    static func captionHead(of line: Line) -> (first: PositionedWord, text: String)? {
        guard let start = line.words.firstIndex(where: { !isMarginMark($0.text) }) else { return nil }
        let words = line.words[start...]
        return (words[start], droppingMarginMarks(words.map(\.text).joined(separator: " ")))
    }

    /// A short line that is not a sentence: at most `plainCaptionMaximumWords` words, and no full
    /// stop, question or exclamation mark followed by more words.
    private static func standsAlone(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= plainCaptionMaximumWords else { return false }
        return !words.dropLast().contains { word in
            guard let last = word.last, ".!?".contains(last) else { return false }
            // "No." or an abbreviation with a dot inside is not the end of a sentence.
            return word.count > 2 && !word.dropLast().contains(".")
        }
    }

    /// Whether the page sets words on their side that may be a table's headings: any but those
    /// read as `sideways` — a turned page's running head and footer, which every such page has
    /// (Plan JW follow-up) and which say nothing of why a grid failed.
    static func hasRotatedHeadings(_ words: [PositionedWord]) -> Bool {
        words.contains { $0.isRotated && !$0.sideways }
    }

    /// Whether any word on the page is set in bold.
    static func hasBold(_ words: [PositionedWord]) -> Bool { words.contains(where: \.bold) }

    /// Every table caption on a page, top to bottom, with the title read off the next line when
    /// the caption line carries none.
    static func captions(in words: [PositionedWord]) -> [Caption] {
        captionLines(in: lines(of: words), pageHasBold: hasBold(words)).map(\.caption)
    }

    static func captionLines(in lines: [Line], pageHasBold: Bool)
        -> [(caption: Caption, index: Int, titleLines: Int)] {
        var found: [(Caption, Int, Int)] = []
        for (index, line) in lines.enumerated() {
            guard var caption = caption(of: line, pageHasBold: pageHasBold) else { continue }
            var titleLines = 0
            // A title on the line below is read only where weight says it is one.
            if pageHasBold, caption.title.isEmpty, index + 1 < lines.count {
                let next = lines[index + 1]
                let phrases = next.phrases
                if next.isBold, phrases.count == 1, next.text.count <= 80, Self.caption(of: next) == nil,
                   next.top - line.bottom < 2 * line.size {
                    var title = next.text
                    if let range = title.range(of: continuedPattern, options: [.regularExpression, .caseInsensitive]) {
                        caption.continues = true
                        title.removeSubrange(range)
                    }
                    caption.title = title.trimmingCharacters(in: .whitespaces)
                    titleLines = 1
                }
            }
            found.append((caption, index, titleLines))
        }
        return found
    }

    // MARK: - Extraction

    /// Every captioned table on a page, each with its outcome.
    static func extractAll(words: [PositionedWord], page: ManualTable.Page) -> [(caption: Caption, outcome: Outcome)] {
        extractGrids(words: words, page: page).map { ($0.caption, $0.outcome) }
    }

    /// Where a caption that gave too few rows lost them, in counts only (Plan JJ P1's diagnosis,
    /// for the private measurement runner): never a word from the page.
    struct TooFewRows: Equatable {
        /// Body rows of two or more cells the reading found before it stopped.
        var bodyRows: Int
        /// How many lines under the caption (and a title read with it) the first run of three
        /// lines of two or more cells starts, or nil when the region holds no such run.
        var gridStart: Int?
        /// That run's first cell is text, not a number, in every row.
        var firstColumnText = false
        /// Every cell of that run is text.
        var allCellsText = false
    }

    /// The `TooFewRows` reading of every caption on the page that failed for too few rows.
    static func diagnoseTooFewRows(words: [PositionedWord], page: ManualTable.Page) -> [TooFewRows] {
        let all = lines(of: words)
        let bold = hasBold(words)
        let rotated = hasRotatedHeadings(words)
        return captionLines(in: all, pageHasBold: bold).compactMap { found -> TooFewRows? in
            let outcome = extract(lines: all, at: found.index, titleLines: found.titleLines, caption: found.caption,
                                  page: page, hasRotatedWords: rotated, pageHasBold: bold)
            guard outcome.failure == .tooFewRows else { return nil }
            let layout = layout(lines: all, at: found.index, titleLines: found.titleLines, caption: found.caption,
                                pageHasBold: bold)
            var reading = TooFewRows(bodyRows: layout.body.filter { $0.phrases.count >= 2 }.count)
            let region = layout.region
            guard let start = region.indices.first(where: { index in
                index + 2 < region.count && (index...(index + 2)).allSatisfy { region[$0].phrases.count >= 2 }
            }) else { return reading }
            reading.gridStart = start
            let run = region[start...].prefix { $0.phrases.count >= 2 }
            func isText(_ phrase: Phrase) -> Bool { parseCell(phrase.text, markers: phrase.markers, columnUnit: nil).value == nil }
            reading.firstColumnText = run.allSatisfy { $0.phrases.first.map(isText) ?? false }
            reading.allCellsText = run.allSatisfy { $0.phrases.allSatisfy(isText) }
            return reading
        }
    }

    /// The table `caption` names on this page.
    static func extract(words: [PositionedWord], caption: Caption, page: ManualTable.Page) -> Outcome {
        let all = lines(of: words)
        guard !all.isEmpty else { return .failed(.noTextLayer) }
        let bold = hasBold(words)
        guard let found = captionLines(in: all, pageHasBold: bold).first(where: { $0.caption.label == caption.label }) else {
            return .failed(.captionNotFound)
        }
        return extract(lines: all, at: found.index, titleLines: found.titleLines, caption: found.caption,
                       page: page, hasRotatedWords: hasRotatedHeadings(words), pageHasBold: bold)
    }

    /// The footnote markers a book runs through after the asterisk, in order: dagger, double
    /// dagger, section sign, double bar, pilcrow (the last three, Plan JW follow-up).
    private static let footnoteSigns = #"\x{2020}|\x{2021}|\x{00A7}|\x{2016}|\x{00B6}"#
    private static let noteStart = #"^(\*+|"# + footnoteSigns + #"|\([a-z0-9]\)|\d{1,2}[\).]|[\x{00B9}\x{00B2}\x{00B3}\x{2070}-\x{2079}]+|notes?\b)"#

    /// A line that starts a note under the table: a superscript marker first, or one phrase of
    /// text opening with a marker or "Note", or a marker standing apart from the note it keys. A
    /// row of cells is never a note, so a row header "(a)" does not end the body.
    private static func isNoteLine(_ line: Line) -> Bool {
        let phrases = line.phrases
        guard let first = phrases.first else { return false }
        if first.leadingMarker { return true }
        switch phrases.count {
        case 1:
            return first.text.range(of: noteStart, options: [.regularExpression, .caseInsensitive]) != nil
        case 2:
            return first.text.range(of: noteStart + "$", options: [.regularExpression, .caseInsensitive]) != nil
                && phrases[1].text.count >= 15
        default:
            return false
        }
    }

    /// Most header lines a plain page's table is read with before its first row of numbers.
    static let plainHeaderMaximumLines = 4
    /// Most lines a plain page's caption title is read as wrapping onto.
    static let plainTitleMaximumLines = 3
    /// Most lines past those a bracketed line under a plain page's title is read as part of it.
    static let plainBracketMaximumLines = 3

    /// A line that is a bracketed phrase of words, not a unit: "(see the notes below)", never
    /// "(A)" or "(mm²)", which head a column.
    static func opensBracket(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("(") && trimmed.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// The text opens more round brackets than it closes.
    static func bracketOpen(_ text: String) -> Bool {
        text.filter { $0 == "(" }.count > text.filter { $0 == ")" }.count
    }

    /// Most heading lines a plain page's table is read with when its first rows of numbers sit
    /// further down than a short header reaches (Plan JJ P5), and how far down they are looked for.
    static let plainLongHeaderMaximumLines = 12
    static let plainLongHeaderReach = 18

    /// A line under a caption, or a row of a recognised grid (Plan JN P0), as the one-weight header
    /// rule reads it: how many cells it prints, and how many of those after the first are numbers.
    struct HeaderRuleRow: Equatable {
        var cells: Int
        var numbersAfterFirst: Int
        /// Of those numbers, the ones that carry a unit of their own ("40 kg", "16 A").
        var unitNumbersAfterFirst = 0
        /// Cells after the first that print only a dash: a value the table does not give.
        var dashesAfterFirst = 0
        /// Every cell after the first is a number with no unit of its own, each larger than the
        /// one before — and the first too, when it is a number: "1 2 3 4", as a row of headings
        /// printed as numbers reads, with a word or two at its left or none.
        var ascendingNumbers = false

        /// A row of cells, each as its text and markers, left to right.
        init(cells: [(text: String, markers: [String])]) {
            self.cells = cells.count
            let parsed = cells.map { TableExtractor.parseCell($0.text, markers: $0.markers, columnUnit: nil) }
            let after = parsed.dropFirst()
            let numbers = after.filter { $0.value != nil }
            numbersAfterFirst = numbers.count
            unitNumbersAfterFirst = numbers.filter { $0.unit != nil }.count
            dashesAfterFirst = cells.dropFirst().filter { TableExtractor.isDash($0.text) }.count
            func bare(_ cell: ManualTable.Cell) -> Double? { cell.unit == nil ? cell.value : nil }
            let values = after.compactMap(bare)
            let rising = (parsed.first.flatMap(bare).map { [$0] } ?? []) + values
            ascendingNumbers = values.count >= 2 && values.count == after.count
                && zip(rising, rising.dropFirst()).allSatisfy { $0 < $1 }
        }

        init(phrases: [Phrase]) {
            self.init(cells: phrases.map { ($0.text, $0.markers) })
        }

        /// A row of two or more cells whose cells after the first are at least half numbers — of
        /// the cells that print a value at all: a dash for a value not given counts for neither
        /// side (Plan JW follow-up), so a row of a sparse table is still a row of numbers.
        var isNumeric: Bool {
            cells >= 2 && numbersAfterFirst > 0 && numbersAfterFirst * 2 >= cells - 1 - dashesAfterFirst
        }
        /// Every cell after the first is text.
        var isTextAfterFirst: Bool { numbersAfterFirst == 0 }
        /// A row of numbers each printed with a unit of its own: over rows whose numbers carry
        /// none, the columns' headings printed as quantities ("40 kg", "80 kg").
        var isUnitHeading: Bool { isNumeric && unitNumbersAfterFirst == numbersAfterFirst }
    }

    /// A cell that prints only a dash (or a run of them): no value.
    static func isDash(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}".contains($0) }
    }

    /// Most lines of headings printed as quantities over a table's first row of numbers.
    static let unitHeadingMaximumLines = 2

    /// Past the headings printed as quantities at `index`: at most `unitHeadingMaximumLines` rows,
    /// the first of them one whose numbers each carry a unit and the others that or a row of
    /// words ("Widget A" under "40 kg"), directly over a run of `minimumBodyRows` rows of
    /// numbers the first of which carries a number with none. Those rows head the columns under
    /// them, so the body starts after them. `index` itself when the rows there are not such
    /// headings — and a table whose every row prints its units is never read as all heading.
    static func pastUnitHeadings(_ index: Int, in rows: [HeaderRuleRow]) -> Int {
        guard index < rows.count, rows[index].isUnitHeading else { return index }
        var next = index + 1
        while next < rows.count, next - index < unitHeadingMaximumLines,
              rows[next].isUnitHeading || (rows[next].cells >= 2 && rows[next].isTextAfterFirst) {
            next += 1
        }
        guard next + minimumBodyRows <= rows.count, !rows[next].isUnitHeading,
              rows[next..<(next + minimumBodyRows)].allSatisfy(\.isNumeric) else { return index }
        return next
    }

    /// The rows the one-weight header rule ever looks at: far enough down for the deepest header
    /// it reads and a run of rows under it.
    static let headerRuleReach = plainLongHeaderReach + minimumBodyRows

    /// The one-weight header rule, shared by a plain text-layer page and a recognised grid (Plan JN
    /// P0): the lines before the first row of numbers head the table. `rows` are the lines under the
    /// caption (at least the first `headerRuleReach` of them). `wrapTitle(before:)` reads the lines
    /// of a title that wrapped under the caption, up to a line index, and gives the index the header
    /// starts at after them; `isHeaderLine` says a line may be a heading at all. Returns where the
    /// header starts and where it ends (the body's first line); both zero for a table it finds no
    /// header for.
    static func plainHeader(rows: [HeaderRuleRow], wrapTitle: (_ before: Int) -> Int,
                            isHeaderLine: (Int) -> Bool) -> (start: Int, count: Int) {
        let reach = plainTitleMaximumLines + plainHeaderMaximumLines
        // Headings printed as quantities over the first rows of numbers head the table, not
        // start its body (Plan JW follow-up).
        let run = numericRunStart(in: rows).map { pastUnitHeadings($0, in: rows) }
        // A run of rows of numbers under headings stacked deeper than a short header (Plan JJ
        // P5): at most `plainLongHeaderMaximumLines` lines of headings that are neither prose nor
        // a note, after the title's wrapped lines.
        func deepHeader(_ run: Int, from start: Int) -> Bool {
            run - start <= plainLongHeaderMaximumLines && (start..<run).allSatisfy(isHeaderLine)
        }
        if let found = rows.prefix(reach + 1).firstIndex(where: \.isNumeric) {
            let firstRow = pastUnitHeadings(found, in: rows)
            let start = wrapTitle(firstRow)
            // A lone row of numbers over more headings — a row of cells all words — and then the
            // run of rows: the columns' own headings printed as numbers ("1", "2", "3" under
            // "Number of widgets"), read with the headings round them (Plan JW follow-up).
            if let run, run > firstRow + 1, numberedHeadingsAbove(run, from: firstRow, in: rows, isHeaderLine: isHeaderLine),
               deepHeader(run, from: start) {
                return (start, run)
            }
            if firstRow - start <= plainHeaderMaximumLines, (start..<firstRow).allSatisfy(isHeaderLine) {
                return (start, firstRow)
            }
            if run == firstRow, deepHeader(firstRow, from: start) { return (start, firstRow) }
            return (start, start)
        }
        if let run {
            let start = wrapTitle(run)
            return (start, deepHeader(run, from: start) ? run : start)
        }
        if let run = textGridStart(in: rows, reach: reach) {
            // A table whose rows are text in every column (Plan JJ P1): no row of numbers to find
            // the body by. The first run of rows of two or more cells starts the grid; its first
            // line is the column headings, and one-phrase lines above it are the title wrapping,
            // as for a table of numbers.
            let start = wrapTitle(run)
            if run - start < plainHeaderMaximumLines, (start...run).allSatisfy(isHeaderLine) { return (start, run + 1) }
            return (start, start)
        }
        return (0, 0)
    }

    /// The row of numbers at `row` heads the columns, with the lines under it down to `run`: the
    /// row is numbers only, rising ("1 2 3"), none of the lines under it is a row of numbers, each
    /// may be a heading, and one of them is a row of two or more cells all words — the headings
    /// under the numbers, which no group heading over a run of rows is.
    private static func numberedHeadingsAbove(_ run: Int, from row: Int, in rows: [HeaderRuleRow],
                                              isHeaderLine: (Int) -> Bool) -> Bool {
        guard rows[row].ascendingNumbers else { return false }
        let between = (row + 1)..<run
        return between.allSatisfy { !rows[$0].isNumeric && isHeaderLine($0) }
            && between.contains { rows[$0].cells >= 2 && rows[$0].isTextAfterFirst && rows[$0].dashesAfterFirst == 0 }
    }

    /// The first of `minimumBodyRows` consecutive rows of numbers within `plainLongHeaderReach`
    /// lines of the caption, or nil.
    private static func numericRunStart(in rows: [HeaderRuleRow]) -> Int? {
        guard rows.count >= minimumBodyRows else { return nil }
        let last = min(plainLongHeaderReach, rows.count - minimumBodyRows)
        guard last >= 0 else { return nil }
        return (0...last).first { index in (index..<(index + minimumBodyRows)).allSatisfy { rows[$0].isNumeric } }
    }

    /// Where a plain page's text-only grid starts: the first of `minimumBodyRows + 1` consecutive
    /// lines of two or more cells (a heading line and three rows), within `reach` lines of the
    /// caption, whose cells after the first are all text. Nil when there is none.
    private static func textGridStart(in rows: [HeaderRuleRow], reach: Int) -> Int? {
        let needed = minimumBodyRows + 1
        guard rows.count >= needed else { return nil }
        for index in 0...min(reach, rows.count - needed) {
            let run = rows[index..<(index + needed)]
            guard run.allSatisfy({ $0.cells >= 2 }) else { continue }
            return run.allSatisfy(\.isTextAfterFirst) ? index : nil
        }
        return nil
    }

    /// A line of running prose rather than a row: one long phrase, or a sentence.
    private static func isProse(_ line: Line, phrases: [Phrase]) -> Bool {
        guard phrases.count == 1 else { return false }
        let text = line.text
        return text.count >= 60 || (text.hasSuffix(".") && text.split(separator: " ").count >= 8)
    }

    /// Where a caption's table sits among the page's lines: the region under it, its title as
    /// read (a wrapped title included), its header lines and its body lines, as `extract` reads
    /// them. Shared with the too-few-rows diagnosis, so the counts it gives are of the same reading.
    struct Layout {
        var region: [Line]
        var title: String
        var headerStart: Int
        var headerCount: Int
        var header: [Line]
        var body: [Line]
        var bodyEnd: Int
    }

    /// Widest space between two bands of a table's rows, in lines of its type.
    static let bandGapMaximumLines = 3.0

    /// A row past a wide space that carries on the rows above it: as many cells as the row above,
    /// at least three, each over the cell above it.
    static func continuesBand(_ phrases: [Phrase], under above: [Phrase]) -> Bool {
        phrases.count >= 3 && phrases.count == above.count
            && zip(phrases, above).allSatisfy { min($0.maxX, $1.maxX) - max($0.minX, $1.minX) > 0 }
    }

    static func layout(lines all: [Line], at captionIndex: Int, titleLines: Int, caption: Caption,
                       pageHasBold: Bool) -> Layout {
        // The table's region: under the caption and its title, up to the next caption or the end.
        let start = captionIndex + 1 + titleLines
        var end = all.count
        for index in start..<all.count {
            let line = all[index]
            if Self.caption(of: line, pageHasBold: pageHasBold) != nil
                || captionHead(of: line).map({ head in
                    (pageHasBold ? head.first.bold : standsAlone(head.text))
                        && (head.text.range(of: figurePattern, options: .regularExpression) != nil
                            || CaptionWords.match(head.text)?.kind == .figure)
                }) == true {
                end = index
                break
            }
        }
        let region = start < end ? Array(all[start..<end]) : []
        guard !region.isEmpty else {
            return Layout(region: [], title: caption.title, headerStart: 0, headerCount: 0, header: [], body: [], bodyEnd: 0)
        }

        // Header: the leading run of bold lines that are not prose. On a page with no bold at all,
        // the lines before the first row whose cells after the first are mostly numbers — after
        // the lines of a long title that wrapped under the caption, which have no weight to tell
        // them apart and read as prose.
        var title = caption.title
        var headerStart = 0
        var headerCount = 0
        func isHeaderLine(_ line: Line) -> Bool {
            !isProse(line, phrases: line.phrases) && !isNoteLine(line)
        }
        if pageHasBold {
            while headerCount < region.count, region[headerCount].isBold, isHeaderLine(region[headerCount]) {
                headerCount += 1
            }
        } else {
            // The lines of a long title that wrapped under the caption, up to `first` — and, past
            // `plainTitleMaximumLines`, a bracketed line under it (a cross-reference, the basis of
            // its values) and the lines that bracket runs on to (Plan JW follow-up).
            func wrapTitle(before first: Int) -> Int {
                var previous = captionIndex
                func takes(_ index: Int) -> Bool {
                    if index < plainTitleMaximumLines { return true }
                    guard index < plainTitleMaximumLines + plainBracketMaximumLines else { return false }
                    return bracketOpen(title) || opensBracket(region[index].text)
                }
                while headerStart < first, takes(headerStart),
                      region[headerStart].phrases.count == 1, !isNoteLine(region[headerStart]),
                      region[headerStart].top - all[previous].bottom < region[headerStart].size {
                    title += (title.isEmpty ? "" : " ") + region[headerStart].text
                    previous = start + headerStart
                    headerStart += 1
                }
                return headerStart
            }
            let rows = region.prefix(headerRuleReach).map { HeaderRuleRow(phrases: $0.phrases) }
            (headerStart, headerCount) = plainHeader(rows: rows, wrapTitle: wrapTitle(before:),
                                                     isHeaderLine: { isHeaderLine(region[$0]) })
        }
        // A bold run that swallows the whole region is a table with bold rows, not all header.
        if pageHasBold, headerCount >= region.count - 1 { headerCount = min(headerCount, 1) }
        let header = Array(region[headerStart..<max(headerStart, headerCount)])

        // Body: until a note, a paragraph or a wide gap.
        var body: [Line] = []
        var bodyEnd = max(headerStart, headerCount)
        var gaps: [Double] = []
        for index in bodyEnd..<region.count {
            let line = region[index]
            let phrases = line.phrases
            if isNoteLine(line) || isProse(line, phrases: phrases) { break }
            if let previous = body.last ?? header.last {
                let gap = line.top - previous.bottom
                let typical = gaps.isEmpty ? line.size : gaps.sorted()[gaps.count / 2]
                if gap > max(3 * typical, 1.5 * line.size) {
                    // Rows printed in bands with a wider space between them (Plan JW follow-up):
                    // past the gap, a row that prints in the same columns as the row above it,
                    // every cell over the one above, carries the body on. The gap is not counted.
                    guard let last = body.last, gap <= bandGapMaximumLines * line.size,
                          continuesBand(phrases, under: last.phrases) else { break }
                    body.append(line)
                    bodyEnd = index + 1
                    continue
                }
                gaps.append(max(gap, 0))
            }
            body.append(line)
            bodyEnd = index + 1
        }

        return Layout(region: region, title: title, headerStart: headerStart, headerCount: headerCount,
                      header: header, body: body, bodyEnd: bodyEnd)
    }

    private static func extract(lines all: [Line], at captionIndex: Int, titleLines: Int, caption: Caption,
                                page: ManualTable.Page, hasRotatedWords: Bool, pageHasBold: Bool) -> Outcome {
        read(lines: all, at: captionIndex, titleLines: titleLines, caption: caption, page: page,
             hasRotatedWords: hasRotatedWords, pageHasBold: pageHasBold).outcome
    }

    /// The grid a read table was laid on (Plan JJ P5), kept while the next page is read so a page
    /// that carries the table on with no caption of its own is read onto the same columns. Never
    /// stored.
    struct Grid: Equatable {
        /// What a run of rows carries down: the group heading over them, and the row headers
        /// printed once for the rows that leave them blank.
        struct Carry: Equatable {
            var group: String?
            var stubs: [String] = []
        }

        /// One set of columns under the caption: the whole grid, or one of the groups printed side
        /// by side. `columns` index the grid's columns; the first `stubs` of them head the rows;
        /// `prefix` heads every row of the group when the groups are told apart by a heading.
        struct Group: Equatable {
            var columns: [Int]
            var stubs: Int
            var prefix: [String]
            var carry = Carry()
        }

        var label: String
        /// The columns' horizontal extents, left to right.
        var lows: [Double]
        var highs: [Double]
        var groups: [Group]
        /// The value columns' units, in the table's column order.
        var units: [String?]
        /// The heading lines, as `headingKey` compares them.
        var headings: Set<String>
        /// The usual gap between two body rows.
        var gap: Double
        /// Nothing but a few lines follow the table on its page: the next page may carry it on.
        var runsToFoot: Bool
        /// Where each row read onto this grid on the caption's page printed its value cells (Plan
        /// JN P0): per row, in the table's row order, the box of the phrase each value column holds,
        /// nil for none. Lets a table read from recognised words find each cell's words again, to
        /// judge how clearly they were read. Never stored.
        var cellBoxes: [[CGRect?]] = []
        /// The caption's page printed a heading over its rows under the columns' headings
        /// (`headsRows`): a page that carries the table on may print the next one in the same
        /// place, above its first row (Plan KR follow-up).
        var headsRowGroups = false

        var segments: [(Double, Double)] { Array(zip(lows, highs)) }
    }

    /// A body line laid on the grid: one phrase or none per column.
    struct Placed {
        var line: Line
        var cells: [Phrase?]
    }

    /// The table `caption` heads, and the grid it was read onto.
    static func read(lines all: [Line], at captionIndex: Int, titleLines: Int, caption: Caption,
                     page: ManualTable.Page, hasRotatedWords: Bool, pageHasBold: Bool) -> (outcome: Outcome, grid: Grid?) {
        let layout = layout(lines: all, at: captionIndex, titleLines: titleLines, caption: caption,
                            pageHasBold: pageHasBold)
        let region = layout.region
        func fail(_ failure: Failure) -> (outcome: Outcome, grid: Grid?) {
            (.failed(hasRotatedWords && failure != .tooFewRows ? .rotatedHeaders : failure), nil)
        }
        guard !region.isEmpty else { return (.failed(.tooFewRows), nil) }
        var header = layout.header
        let body = layout.body
        let bodyEnd = layout.bodyEnd

        let multi = body.filter { $0.phrases.count >= 2 }
        guard multi.count >= minimumBodyRows else {
            return (.failed(textStopsBelowCaption(region: region) ? .noTextInTable : .tooFewRows), nil)
        }

        // Columns: where the rows with the most common cell count print something — or, for a
        // grid whose rows leave cells blank (marks in some columns only), wherever any row prints
        // something, when the headings stand one over each such column.
        guard let segments = modalSegments(multi) ?? sparseSegments(multi, header: header) else {
            return fail(.varyingColumnCount)
        }

        // Every body row onto the grid.
        var misfits = 0
        var merged = 0
        var placed: [Placed] = []
        for line in body {
            let fit = place(line, on: segments)
            if line.phrases.count >= 2, !fit.fits {
                misfits += 1
                if fit.spans { merged += 1 }
            }
            placed.append(Placed(line: line, cells: fit.cells))
        }
        if Double(misfits) > misfitTolerance * Double(multi.count) {
            return fail(merged * 2 >= misfits ? .mergedCells : .varyingColumnCount)
        }

        // A heading row of numbers (Plan JJ P5): under a heading that spans several columns, the
        // columns' own headings printed as numbers, which read as the first row. When most value
        // columns have no heading of their own and the first row fills every one of them with a
        // number, that row heads them.
        // A heading set under the columns' own headings, over the rows, heads those rows (Plan KR
        // follow-up): it is not a level of the columns it happens to sit over.
        var rowGroup: String?
        if header.count >= 2, let last = header.last, headsRows(last, under: Array(header.dropLast()), segments: segments) {
            rowGroup = last.phrases.first?.printed
            header.removeLast()
        }
        var paths = columnPaths(header: header, segments: segments)
        if let first = placed.first, numberedHeadingRow(first, paths: paths, header: header),
           numberedRowHeads(rowsUnder: placed.dropFirst().filter({ $0.line.phrases.count >= 2 }).count,
                            namesARow: first.cells.first.map { $0 != nil } ?? false,
                            counts: first.cells.dropFirst().map { $0?.text ?? "" }) {
            header.append(placed[0].line)
            placed.removeFirst()
            paths = columnPaths(header: header, segments: segments)
        }

        // Two or three groups printed side by side under the one caption read as one table, the
        // right group's rows after the left's.
        guard let laid = sideBySideGroups(paths: paths, placed: placed).flatMap({ lay(placed, groups: $0, paths: paths) })
            ?? lay(placed, groups: [Array(segments.indices)], paths: paths) else { return fail(.varyingColumnCount) }
        let units = laid.columns.map(\.unit)

        // Rows.
        var rows: [ManualTable.Row] = []
        var boxes: [[CGRect?]] = []
        var groups = laid.groups
        if let rowGroup { for index in groups.indices { groups[index].carry.group = rowGroup } }
        for index in groups.indices {
            let read = self.rows(placed, group: groups[index], units: units, page: page)
            rows += read.rows
            boxes += read.boxes
            groups[index].carry = read.carry
        }

        // Notes: marked lines under the body, each with its wrapped lines.
        let notes = self.notes(in: Array(region[bodyEnd...]))

        let gaps = zip(body, body.dropFirst()).map { max(0, $1.top - $0.bottom) }.sorted()
        let regionStart = captionIndex + 1 + titleLines
        let trailing = region.count - bodyEnd - notes.lines
        let grid = Grid(label: caption.label, lows: segments.map(\.0), highs: segments.map(\.1), groups: groups,
                        units: units, headings: Set(header.map { headingKey($0.text) }),
                        gap: gaps.isEmpty ? body[0].size : gaps[gaps.count / 2],
                        runsToFoot: regionStart + region.count == all.count && trailing <= trailingAllowance,
                        cellBoxes: boxes, headsRowGroups: rowGroup != nil)
        return (.table(ManualTable(label: caption.label, title: layout.title, page: page, rowHeaders: laid.rowHeaders,
                                   columns: laid.columns, rows: rows, notes: notes.notes, continues: caption.continues)),
                grid)
    }

    /// How many lines' height of empty page under a caption, with no grid above it, says the table
    /// is printed there with no text to read.
    static let blankTableLines = 15.0

    /// Under the caption, the text stops for at least `blankTableLines` lines' height before the
    /// next line (most often the footer), and the lines above that stretch hold no run of rows: the
    /// table is printed in the stretch with no text the PDF gives (Plan JJ P5). A caption over a
    /// short paragraph on a page otherwise empty reads the same way; it reads no grid either way,
    /// and only the reason it is given differs.
    static func textStopsBelowCaption(region: [Line]) -> Bool {
        for (index, pair) in zip(region, region.dropFirst()).enumerated() {
            let gap = pair.1.top - pair.0.bottom
            guard gap >= blankTableLines * max(pair.0.size, 1) else { continue }
            return region[...index].filter { $0.phrases.count >= 2 }.count < minimumBodyRows
        }
        return false
    }

    /// Lines a table may leave under itself on its page (a footer, a page number) and still run
    /// on to the next.
    static let trailingAllowance = 3

    /// The columns the rows with the most common number of cells make, when they make as many as
    /// those rows have cells.
    private static func modalSegments(_ multi: [Line]) -> [(Double, Double)]? {
        let counts = multi.map { $0.phrases.count }
        let histogram = counts.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        guard let modal = histogram.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key else { return nil }
        let modalRows = multi.filter { $0.phrases.count == modal }
        guard modalRows.count >= 2, Double(modalRows.count) >= 0.5 * Double(multi.count) else { return nil }
        let segments = unionSegments(modalRows.flatMap { $0.phrases.map { ($0.minX, $0.maxX) } })
        return segments.count == modal ? segments : nil
    }

    /// The columns of a grid whose rows leave cells blank (Plan JJ P5): every place any body row
    /// prints something, accepted only when the lowest heading line stands one phrase over each of
    /// them — the row-header column's own heading may be left out — and over no other. Without
    /// headings to agree, a sparse grid is not told from a drawing, and nothing is read.
    private static func sparseSegments(_ multi: [Line], header: [Line]) -> [(Double, Double)]? {
        guard let lowest = header.last else { return nil }
        let headings = lowest.phrases.filter { !$0.text.isEmpty }
        let segments = unionSegments(multi.flatMap { $0.phrases.map { ($0.minX, $0.maxX) } })
        guard segments.count >= 3, headings.count >= 2 else { return nil }
        let offset: Int
        if headings.count == segments.count {
            offset = 0
        } else if headings.count == segments.count - 1 {
            offset = 1
        } else {
            return nil
        }
        for (index, heading) in headings.enumerated() {
            let over = segments.indices.filter { overlap(heading, segments[$0]) > 0 }
            guard over == [index + offset] else { return nil }
        }
        return segments
    }

    /// A line's phrases laid on the columns. `strictly`, a phrase over no column does not fit (a
    /// continuation page's rows must sit on the grid they continue); otherwise it takes the
    /// nearest. A phrase over two columns spans them and does not fit.
    static func place(_ line: Line, on segments: [(Double, Double)], strictly: Bool = false)
        -> (cells: [Phrase?], fits: Bool, spans: Bool) {
        var cells = [Phrase?](repeating: nil, count: segments.count)
        var fits = true
        var spans = false
        for phrase in line.phrases {
            let covered = segments.indices.filter { overlap(phrase, segments[$0]) > 0 }
            let column: Int
            if covered.count > 1 {
                spans = true
                fits = false
                column = covered[0]
            } else if let only = covered.first {
                column = only
            } else {
                if strictly { fits = false }
                column = nearest(phrase.center, segments)
            }
            if cells[column] != nil { fits = false; cells[column]?.text += " " + phrase.text }
            else { cells[column] = phrase }
        }
        return (cells, fits, spans)
    }

    private static func isNumeric(_ phrase: Phrase?) -> Bool {
        guard let phrase else { return false }
        return parseCell(phrase.text, markers: phrase.markers, columnUnit: nil).value != nil
    }

    /// The first body line is the value columns' headings printed as numbers: the header has a
    /// heading spanning two or more value columns, at least half the value columns have no heading
    /// of their own (none, or only the one they share with a neighbour), and the line prints in
    /// every value column, a number in all of them but perhaps the last ("5 or more").
    private static func numberedHeadingRow(_ first: Placed?, paths: [[String]], header: [Line]) -> Bool {
        guard let first, !header.isEmpty else { return false }
        return numberedHeadingRow(prints: { first.cells[$0] != nil }, numeric: { isNumeric(first.cells[$0]) }, paths: paths)
    }

    /// The numbered-heading rule on any first row (shared with a recognised grid, Plan JN P0):
    /// `prints` and `numeric` say what the row holds in each column, `paths` are the columns'
    /// header paths so far.
    static func numberedHeadingRow(prints: (Int) -> Bool, numeric: (Int) -> Bool, paths: [[String]]) -> Bool {
        guard paths.count >= 3 else { return false }
        let values = Array(1..<paths.count)
        guard values.allSatisfy(prints),
              values.dropLast().allSatisfy(numeric),
              values.count >= 3 || numeric(values[values.count - 1]) else { return false }
        let spans = values.contains { index in
            !paths[index].isEmpty && values.contains { $0 != index && paths[$0].first == paths[index].first }
        }
        let bare = values.filter { index in
            paths[index].isEmpty || values.contains { $0 != index && paths[$0] == paths[index] }
        }
        return spans && bare.count * 2 >= values.count
    }

    /// Whether a row the numbered-heading rule fits heads the columns, by what it prints at the
    /// left and how many rows of the table follow it (Plan KR follow-up). As a rule
    /// `minimumBodyRows` must follow, so a table's first row that happens to count up stays a row.
    /// A row that names no row — nothing in the row-header column — and counts up in whole
    /// numbers, the last perhaps in words ("1 2 3 Over 3"), heads the columns however few rows
    /// follow it: a table of fill by how many conductors share a run may have two. `counts` are
    /// the row's value cells, left to right.
    static func numberedRowHeads(rowsUnder: Int, namesARow: Bool, counts: [String]) -> Bool {
        if rowsUnder >= minimumBodyRows { return true }
        return rowsUnder >= 1 && !namesARow && countsUp(counts)
    }

    /// Cells that count up: whole numbers with no unit, each larger than the one before, at least
    /// two of them, the last cell perhaps words with a number ("Over 3", "5 or more").
    static func countsUp(_ cells: [String]) -> Bool {
        var counts: [Double] = []
        for (index, text) in cells.enumerated() {
            let cell = parseCell(text, markers: [], columnUnit: nil)
            if index == cells.count - 1, text.contains(where: \.isLetter) { break }
            guard let value = cell.value, cell.unit == nil, value >= 0, value == value.rounded() else { return false }
            counts.append(value)
        }
        return counts.count >= 2 && zip(counts, counts.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// The last heading line is a heading over the rows under it rather than over columns (Plan KR
    /// follow-up): one phrase of words, wider than one value column and clear of the row-header
    /// column (`spansValueColumns`), not wrapping on from the line above, under headings that
    /// already give every value column a heading over it alone ("Plain widgets" centred under "Area, mm²" printed over each column). Headings nest
    /// from the top down, so a line spanning several columns below each column's own heading
    /// cannot be one of theirs; it starts a group of rows, as a heading set alone at the left
    /// does.
    static func headsRows(_ line: Line, under above: [Line], segments: [(Double, Double)]) -> Bool {
        guard let previous = above.last, spansValueColumns(line, segments: segments) != nil,
              let phrase = line.phrases.first else { return false }
        // A heading wrapping on from the line above is that heading, not one over the rows.
        guard !previous.phrases.contains(where: { continuesHeading(phrase, on: line, from: $0, on: previous) }) else {
            return false
        }
        return columnHeadings(header: above, segments: segments).dropFirst().allSatisfy { $0.last?.columns.count == 1 }
    }

    /// A line of one phrase of words set over value columns and clear of the first, row-header
    /// column, wider than one column: over two or more columns' values, or wider than the space
    /// from one column's middle to the next. Its words, or nil.
    static func spansValueColumns(_ line: Line, segments: [(Double, Double)]) -> String? {
        guard segments.count >= 3, line.phrases.count == 1, let phrase = line.phrases.first,
              !isNumeric(phrase), !isNoteMarkerHeading(phrase.text), phrase.minX > segments[0].1 else { return nil }
        let over = segments.indices.filter { min(phrase.maxX, segments[$0].1) - max(phrase.minX, segments[$0].0) > 0 }
        let centers = segments.map { ($0.0 + $0.1) / 2 }
        let pitches = zip(centers, centers.dropFirst()).map { $1 - $0 }.sorted()
        let pitch = pitches[pitches.count / 2]
        return over.count >= 2 || phrase.maxX - phrase.minX > pitch ? phrase.printed : nil
    }

    /// How many of a group's columns head its rows: the first, and any after it that never hold a
    /// number. A table of words throughout has no numbers to tell its row headers by: only its
    /// first column heads the rows (Plan JJ P1).
    private static func stubCount(_ placed: [Placed], columns: [Int]) -> Int {
        stubCount(columns: columns.count,
                  prints: { position in placed.contains { $0.cells[columns[position]] != nil } },
                  holdsNumber: { position in placed.contains { isNumeric($0.cells[columns[position]]) } })
    }

    /// The row-header rule on any grid (shared with a recognised grid, Plan JN P0): of `count`
    /// columns, `prints` says a body row prints something in one, `holdsNumber` that one holds a
    /// number.
    static func stubCount(columns count: Int, prints: (Int) -> Bool, holdsNumber: (Int) -> Bool) -> Int {
        let holdsNumbers = count > 1 && (1..<count).contains(where: holdsNumber)
        var stubs = 1
        while holdsNumbers, stubs < count - 1 {
            guard prints(stubs), !holdsNumber(stubs) else { break }
            stubs += 1
        }
        return stubs
    }

    /// The groups of columns printed side by side under one caption (Plan JJ P5): the columns split
    /// into two or three runs of equal width whose headings read alike column for column
    /// ("Designation", "Limit (A)" twice over) — by the heading under which nothing else is
    /// printed, or by all of a column's heading words, since a heading stretched over a gap can
    /// land on a neighbour's path — each run's first column printing rows. Nil for one grid.
    private static func sideBySideGroups(paths: [[String]], placed: [Placed]) -> [[Int]]? {
        let count = paths.count
        let leaves = paths.map { headingKey($0.last ?? "") }
        let wholes = paths.map { headingKey($0.joined(separator: " ")) }
        for runs in [2, 3] where count % runs == 0 && count / runs >= 2 {
            let width = count / runs
            let chunks = (0..<runs).map { Array(($0 * width)..<(($0 + 1) * width)) }
            let alike = (0..<width).allSatisfy { position in
                let column = chunks.map { $0[position] }
                let first = column[0]
                return !wholes[first].isEmpty && column.allSatisfy { leaves[$0] == leaves[first] || wholes[$0] == wholes[first] }
            }
            guard alike else { continue }
            guard chunks.allSatisfy({ chunk in placed.filter { $0.cells[chunk[0]] != nil }.count >= 2 }) else { continue }
            return chunks
        }
        return nil
    }

    /// A table's row-header headings, value columns and groups, from the groups its columns make.
    /// Nil when the groups do not agree on how many value columns they have.
    private static func lay(_ placed: [Placed], groups: [[Int]], paths: [[String]])
        -> (rowHeaders: [String], columns: [ManualTable.Column], groups: [Grid.Group])? {
        let stubs = groups.map { stubCount(placed, columns: $0) }
        let values = zip(groups, stubs).map { $0.count - $1 }
        guard let width = values.first, values.allSatisfy({ $0 == width }), stubs.allSatisfy({ $0 == stubs[0] }) else {
            return nil
        }
        // Groups told apart by a heading over each ("Rating group 1", "Rating group 2"): that
        // heading heads the group's rows, and the columns are named below it.
        var prefixes = groups.map { _ in [String]() }
        var drop = 0
        if groups.count > 1 {
            let outers = groups.map { group -> String? in
                let firsts = Set(group.map { paths[$0].count >= 2 ? paths[$0][0] : "" })
                return firsts.count == 1 ? firsts.first.flatMap { $0.isEmpty ? nil : $0 } : nil
            }
            if outers.allSatisfy({ $0 != nil }), Set(outers.compactMap { $0 }).count == groups.count {
                prefixes = outers.map { [$0!] }
                drop = 1
            }
        }
        let first = groups[0]
        // A row-header column's heading that reached a value column by the midpoints is the rows'
        // heading, not a level of the column's (Plan KR P3): it is left out above the column's own.
        // A row-header heading that wrapped is one level of its own column; a value column may
        // hold its first line alone, which is that heading all the same.
        let stubHeadings = Set(first.prefix(stubs[0]).flatMap { paths[$0] })
        func isStubHeading(_ level: String) -> Bool {
            stubHeadings.contains { $0 == level || $0.hasPrefix(level + " ") }
        }
        let columns = first[stubs[0]...].map { index -> ManualTable.Column in
            var path = withoutNoteLeaf(Array(paths[index].dropFirst(drop)))
            if path.count > 1 {
                path = path.dropLast().filter { !isStubHeading($0) } + [path[path.count - 1]]
            }
            return ManualTable.Column(path: path, unit: unit(in: path))
        }
        let rowHeaders = first.prefix(stubs[0]).map { paths[$0].dropFirst(drop).joined(separator: " ") }
        let laid = zip(groups, zip(stubs, prefixes)).map { Grid.Group(columns: $0, stubs: $1.0, prefix: $1.1) }
        return (rowHeaders, columns, laid)
    }

    /// One group's rows off the laid lines, starting from what the rows above carried down, with
    /// the box each row's value cells were printed in (`Grid.cellBoxes`).
    private static func rows(_ placed: [Placed], group: Grid.Group, units: [String?], page: ManualTable.Page)
        -> (rows: [ManualTable.Row], carry: Grid.Carry, boxes: [[CGRect?]]) {
        var rows: [ManualTable.Row] = []
        var boxes: [[CGRect?]] = []
        var heading = group.carry.group
        var previousStubs = group.carry.stubs
        var previousLine: Line?
        let stubs = group.stubs
        for laid in placed {
            let cells = group.columns.map { laid.cells[$0] }
            let line = laid.line
            let filled = cells.compactMap { $0 }
            // Nothing of this group on the line: the group beside it runs a row longer.
            if filled.isEmpty { continue }
            if filled.count == 1, let only = cells.firstIndex(where: { $0 != nil }), only < stubs {
                let text = cells[only]!.printed
                // A short line under a row, close to it and not bold, is that row's header
                // wrapping onto a second line; anything else alone at the left heads a group.
                if !line.isBold, let previous = previousLine, let last = rows.indices.last,
                   line.top - previous.bottom < 0.4 * line.size, !rows[last].path.isEmpty, !previousStubs.isEmpty {
                    rows[last].path[rows[last].path.count - 1] += " " + text
                    previousStubs[previousStubs.count - 1] += " " + text
                } else {
                    heading = text
                    previousStubs = []
                }
                previousLine = line
                continue
            }
            var stubTexts = (0..<stubs).map { cells[$0]?.printed ?? "" }
            // A row header printed once for the rows under it: carry it down to the rows that
            // leave it blank.
            if let firstFilled = stubTexts.firstIndex(where: { !$0.isEmpty }) {
                for index in 0..<firstFilled where index < previousStubs.count { stubTexts[index] = previousStubs[index] }
            } else {
                stubTexts = previousStubs.count == stubs ? previousStubs : stubTexts
            }
            let values = (stubs..<cells.count).map { index -> ManualTable.Cell in
                guard let phrase = cells[index] else { return ManualTable.Cell(text: "") }
                let column = index - stubs
                return parseCell(phrase.text, markers: phrase.markers, columnUnit: column < units.count ? units[column] : nil)
            }
            let path = group.prefix + (heading.map { [$0] } ?? []) + stubTexts.filter { !$0.isEmpty }
            rows.append(ManualTable.Row(path: path, cells: values, page: page))
            boxes.append((stubs..<cells.count).map { index in
                cells[index].map { CGRect(x: $0.minX, y: line.top, width: $0.maxX - $0.minX, height: line.bottom - line.top) }
            })
            previousStubs = stubTexts
            previousLine = line
        }
        return (rows, Grid.Carry(group: heading, stubs: previousStubs), boxes)
    }

    /// The notes printed under a continuing caption whose page reads no grid of its own (Plan JW
    /// P0): a "(Concluded)" page that carries only the table's notes. Read from the first note line
    /// under the caption to the next caption; empty when the caption is not on the page or nothing
    /// under it is a note.
    static func notes(under caption: Caption, words: [PositionedWord]) -> [ManualTable.Note] {
        let all = lines(of: words)
        let bold = hasBold(words)
        guard let found = captionLines(in: all, pageHasBold: bold)
            .first(where: { $0.caption.label.caseInsensitiveCompare(caption.label) == .orderedSame }) else { return [] }
        let region = layout(lines: all, at: found.index, titleLines: found.titleLines, caption: found.caption,
                            pageHasBold: bold).region
        guard let first = region.firstIndex(where: isNoteLine) else { return [] }
        return notes(in: Array(region[first...])).notes
    }

    /// Notes: the marked lines at the head of `lines`, each with its wrapped lines, and how many
    /// lines they took.
    private static func notes(in lines: [Line]) -> (notes: [ManualTable.Note], lines: Int) {
        var notes: [ManualTable.Note] = []
        var lastNoteLine: Line?
        var used = 0
        for line in lines {
            if isNoteLine(line) {
                notes.append(note(from: line))
                lastNoteLine = line
            } else if let previous = lastNoteLine, !notes.isEmpty, line.top - previous.bottom < 0.8 * line.size {
                notes[notes.count - 1].text += " " + line.text
                lastNoteLine = line
            } else {
                break
            }
            used += 1
        }
        notes.removeAll { $0.text.isEmpty }
        return (notes, used)
    }

    /// A heading line as a continuation page's lines are compared to it: lower case, letters and
    /// digits only, single spaces.
    static func headingKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
    }

    // MARK: - A table carried on with no caption (Plan JJ P5)

    /// Lines a continuation page may print above the table's rows — a running head, a section
    /// title — besides the table's own headings printed again.
    static let continuationLeadAllowance = 3

    /// Where a caption that read no table sits (Plan JJ P5).
    enum Placement: Equatable {
        /// Lines enough under it for a table.
        case onPage
        /// Another caption follows within two lines: an entry in a list of tables, not a table.
        case listed
        /// Fewer than `footMaximumLines` lines under it before the foot of the page: its table may
        /// start on the next page.
        case atFoot
    }

    /// Most lines under a caption at the foot of a page whose table starts on the next.
    static let footMaximumLines = 4

    /// Every captioned table on a page with the grid each read table was laid on, and where each
    /// caption that read nothing sits.
    static func extractGrids(words: [PositionedWord], page: ManualTable.Page)
        -> [(caption: Caption, outcome: Outcome, grid: Grid?, placement: Placement)] {
        let all = lines(of: words)
        let rotated = hasRotatedHeadings(words)
        let bold = hasBold(words)
        let captions = captionLines(in: all, pageHasBold: bold)
        return captions.enumerated().map { position, found in
            let read = read(lines: all, at: found.index, titleLines: found.titleLines, caption: found.caption,
                            page: page, hasRotatedWords: rotated, pageHasBold: bold)
            var placement = Placement.onPage
            if read.outcome.failure != nil {
                let region = layout(lines: all, at: found.index, titleLines: found.titleLines, caption: found.caption,
                                    pageHasBold: bold).region
                let start = found.index + 1 + found.titleLines
                let toFoot = start + region.count >= all.count
                // A run of captions a line or two apart is a list of tables, the last entry too.
                let afterAnother = position > 0 && found.index - captions[position - 1].index <= 3
                if region.count <= 2, !toFoot || afterAnother {
                    placement = .listed
                } else if toFoot, region.count <= footMaximumLines {
                    placement = .atFoot
                }
            }
            return (found.caption, read.outcome, read.grid, placement)
        }
    }

    /// The table a caption at the foot of a page heads when its rows start on the next page (Plan
    /// JJ P5): the caption and the few lines under it, then the next page's lines above any caption
    /// of its own, after at most `continuationLeadAllowance` single-phrase lines of page furniture,
    /// read as one region. Its rows keep the next page; the table starts on the caption's.
    static func startingOnNextPage(words: [PositionedWord], caption: Caption, page: ManualTable.Page,
                                   next: [PositionedWord], nextPage: ManualTable.Page) -> (table: ManualTable, grid: Grid?)? {
        let all = lines(of: words)
        let bold = hasBold(words)
        guard let found = captionLines(in: all, pageHasBold: bold).last(where: {
            $0.caption.label.caseInsensitiveCompare(caption.label) == .orderedSame
        }) else { return nil }
        // The caption and the lines set close under it; a footer further down is left behind.
        var head = [all[found.index]]
        for line in all[(found.index + 1)...] {
            guard let previous = head.last, line.top - previous.bottom < 1.5 * line.size else { break }
            head.append(line)
        }
        guard let last = head.last else { return nil }
        let following = lines(of: next)
        let end = captionLines(in: following, pageHasBold: hasBold(next)).first?.index ?? following.count
        var top = Array(following[..<end])
        var furniture = 0
        while let first = top.first, first.phrases.count < 2, furniture < continuationLeadAllowance {
            top.removeFirst()
            furniture += 1
        }
        guard let first = top.first, first.phrases.count >= 2 else { return nil }
        // The next page's lines set straight under the caption page's last line.
        let shift = last.bottom + 0.4 * last.size - first.top
        let moved = top.map { line -> Line in
            var line = line
            line.top += shift
            line.bottom += shift
            line.words = line.words.map { word in
                var word = word
                word.rect.origin.y += CGFloat(shift)
                return word
            }
            return line
        }
        let joined = head + moved
        let read = read(lines: joined, at: 0, titleLines: found.titleLines, caption: found.caption, page: nextPage,
                        hasRotatedWords: hasRotatedHeadings(words + next), pageHasBold: bold)
        guard var table = read.outcome.table else { return nil }
        table.page = page
        return (table, read.grid)
    }

    /// The rows a page carries on from the table read onto `grid` on the page before: the lines at
    /// the top of the page, above any caption of its own, that sit on the same columns, after at
    /// most `continuationLeadAllowance` lines of page furniture and the table's headings printed
    /// again. With `under`, the lines under that caption instead — a "(Continued)" caption whose
    /// page did not read on its own. Each row keeps this page; a row header or group heading
    /// carried down from the page before carries on. Nil when the page does not begin with at
    /// least two rows that sit on the grid, every phrase over exactly one of its columns.
    static func continuation(words: [PositionedWord], page: ManualTable.Page, grid: Grid, under caption: Caption? = nil)
        -> (rows: [ManualTable.Row], notes: [ManualTable.Note], grid: Grid)? {
        let all = lines(of: words)
        guard !all.isEmpty else { return nil }
        let captions = captionLines(in: all, pageHasBold: hasBold(words))
        let start: Int
        let end: Int
        if let caption {
            guard let at = captions.firstIndex(where: { $0.caption.label.caseInsensitiveCompare(caption.label) == .orderedSame })
            else { return nil }
            start = captions[at].index + 1 + captions[at].titleLines
            end = at + 1 < captions.count ? captions[at + 1].index : all.count
        } else {
            start = 0
            end = captions.first?.index ?? all.count
        }
        guard start < end else { return nil }
        let lines = Array(all[start..<end])
        let segments = grid.segments

        // Furniture and the headings again, before the first line that sits on the grid.
        var first: Int?
        var furniture = 0
        for (index, line) in lines.enumerated() {
            if grid.headings.contains(headingKey(line.text)) { continue }
            if line.phrases.count >= 2, place(line, on: segments, strictly: true).fits {
                first = index
                break
            }
            furniture += 1
            if furniture > continuationLeadAllowance { return nil }
        }
        guard let first else { return nil }

        // The rows: until a line that does not sit on the grid, a note, a paragraph or a wide gap.
        let stubColumns = Set(grid.groups.flatMap { $0.columns.prefix($0.stubs) })
        var placed: [Placed] = []
        var used = first
        for line in lines[first...] {
            if isNoteLine(line) || isProse(line, phrases: line.phrases) { break }
            if let previous = placed.last?.line, line.top - previous.bottom > max(3 * grid.gap, 1.5 * line.size) { break }
            let fit = place(line, on: segments, strictly: true)
            guard fit.fits else { break }
            // A phrase alone heads a group only in a row-header column.
            if line.phrases.count == 1, !fit.cells.indices.contains(where: { fit.cells[$0] != nil && stubColumns.contains($0) }) {
                break
            }
            placed.append(Placed(line: line, cells: fit.cells))
            used += 1
        }
        let rows = placed.filter { $0.line.phrases.count >= 2 }
        guard rows.count >= 2 else { return nil }
        // Rows of a table carry their keys: the first column is printed on most of them.
        let keyColumn = grid.groups[0].columns[0]
        guard rows.filter({ $0.cells[keyColumn] != nil }).count * 2 >= rows.count else { return nil }

        var out: [ManualTable.Row] = []
        var next = grid
        // A table whose rows run in groups headed over the value columns (`headsRows`): the line
        // set straight above this page's first row, among the lines before it, heads the next
        // group (Plan KR follow-up), in place of the group carried on from the page before.
        if grid.headsRowGroups, first > 0, !grid.headings.contains(headingKey(lines[first - 1].text)),
           lines[first].top - lines[first - 1].bottom < 1.5 * lines[first].size,
           let heading = spansValueColumns(lines[first - 1], segments: segments) {
            for index in next.groups.indices { next.groups[index].carry = Grid.Carry(group: heading) }
        }
        for index in next.groups.indices {
            let read = self.rows(placed, group: next.groups[index], units: grid.units, page: page)
            out += read.rows
            next.groups[index].carry = read.carry
        }
        let notes = self.notes(in: Array(lines[used...]))
        next.runsToFoot = end == all.count && lines.count - used - notes.lines <= trailingAllowance
        return (out, notes.notes, next)
    }

    // MARK: - Geometry

    /// Merge overlapping horizontal extents into the columns they make, left to right.
    static func unionSegments(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (low, high) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, low <= last.1 + 0.5 {
                out[out.count - 1].1 = max(last.1, high)
            } else {
                out.append((low, high))
            }
        }
        return out
    }

    private static func overlap(_ phrase: Phrase, _ segment: (Double, Double)) -> Double {
        min(phrase.maxX, segment.1) - max(phrase.minX, segment.0)
    }

    private static func nearest(_ x: Double, _ segments: [(Double, Double)]) -> Int {
        segments.indices.min { abs((segments[$0].0 + segments[$0].1) / 2 - x) < abs((segments[$1].0 + segments[$1].1) / 2 - x) } ?? 0
    }

    /// Each column's header path, outermost first. A header phrase reaches the columns whose
    /// centres fall in its region — its own extent, widened symmetrically about its centre to the
    /// midpoint with its neighbours — so a group heading centred over three columns heads all
    /// three. Stacked phrases over the same columns are one heading wrapped onto two lines and are
    /// joined; a phrase over more columns than the one below it is a level of the path.
    static func columnPaths(header: [Line], segments: [(Double, Double)]) -> [[String]] {
        columnHeadings(header: header, segments: segments).map { $0.map(\.text) }
    }

    /// Each column's headings, top down, each with the columns it heads.
    static func columnHeadings(header: [Line], segments: [(Double, Double)]) -> [[(text: String, columns: Set<Int>)]] {
        let centers = segments.map { ($0.0 + $0.1) / 2 }
        let gaps = zip(segments, segments.dropFirst()).map { $1.0 - $0.1 }.sorted()
        let gap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let pitches = zip(centers, centers.dropFirst()).map { $1 - $0 }.sorted()
        let pitch = pitches.isEmpty ? 0 : pitches[pitches.count / 2]
        var paths = [[(text: String, columns: Set<Int>)]](repeating: [], count: segments.count)
        var above: (line: Line, phrases: [Phrase], owners: [Int: Int])?
        for line in header {
            let phrases = line.phrases.filter { !$0.text.isEmpty }
            var coverage: [Set<Int>] = []
            for (index, phrase) in phrases.enumerated() {
                let leftMid = index > 0 ? (phrases[index - 1].maxX + phrase.minX) / 2 : nil
                let rightMid = index + 1 < phrases.count ? (phrase.maxX + phrases[index + 1].minX) / 2 : nil
                var low: Double
                var high: Double
                switch (leftMid, rightMid) {
                case let (l?, r?): low = l; high = r
                case let (nil, r?): high = r; low = min(phrase.minX, phrase.center - (r - phrase.center))
                case let (l?, nil): low = l; high = max(phrase.maxX, phrase.center + (phrase.center - l))
                case (nil, nil): low = phrase.minX - gap; high = phrase.maxX + gap
                }
                var covered = Set(centers.indices.filter { centers[$0] >= low && centers[$0] <= high })
                let under = Set(segments.indices.filter {
                    min(phrase.maxX, segments[$0].1) - max(phrase.minX, segments[$0].0) > 0
                        || (centers[$0] >= phrase.minX && centers[$0] <= phrase.maxX)
                })
                covered.formUnion(under)
                // A heading reaches back over the columns to its left only when it is set over their
                // middle (Plan KR P3). One printed over the last of three columns, with a stub
                // heading far to its left, reached back over the other two by the midpoints alone
                // and became a level of their paths too. Only that way: a group heading is set
                // centred or from the left, never from the right, so one whose spread runs to its
                // right — "Capacity" printed narrow over the first of three or four columns — heads
                // them all, and keeps its level in every path.
                if covered.count > 1, pitch > 0, !under.isEmpty {
                    let middle = covered.map { centers[$0] }.reduce(0, +) / Double(covered.count)
                    if phrase.center - middle > spanOffCentre * pitch { covered = under }
                }
                coverage.append(covered)
            }
            // A heading that wrapped onto this line heads the columns its first line heads, and
            // only those (Plan KR follow-up): "… or multi-" over "widget bundles", which alone is
            // narrower and would reach only some of them — or, under a row-header heading, wider.
            var wraps: [Int: Int] = [:]
            if let above {
                for index in phrases.indices {
                    guard let wrapped = above.phrases.indices.first(where: {
                        continuesHeading(phrases[index], on: line, from: above.phrases[$0], on: above.line)
                    }) else { continue }
                    let headed = Set(above.owners.filter { $0.value == wrapped }.keys)
                    guard !headed.isEmpty else { continue }
                    coverage[index] = headed
                    wraps[index] = wrapped
                }
            }
            var owners: [Int: Int] = [:]
            for column in segments.indices {
                let candidates = phrases.indices.filter { coverage[$0].contains(column) }
                guard let owner = candidates.min(by: { abs(phrases[$0].center - centers[column]) < abs(phrases[$1].center - centers[column]) })
                else { continue }
                owners[column] = owner
                let text = phrases[owner].printed
                if let last = paths[column].last, wraps[owner] != nil || last.columns == coverage[owner] {
                    paths[column][paths[column].count - 1].text += " " + text
                } else {
                    paths[column].append((text, coverage[owner]))
                }
            }
            above = (line, phrases, owners)
        }
        return paths
    }

    /// `phrase` carries on the heading `first` on the line above: set straight under it, from the
    /// same left edge and no wider, and reading on from it — it starts with a small letter, or the
    /// line above breaks a word with a hyphen. A heading under another that starts with a capital
    /// is a heading of its own, even set from the same edge.
    static func continuesHeading(_ phrase: Phrase, on line: Line, from first: Phrase, on firstLine: Line) -> Bool {
        let slack = 0.5 * line.size
        guard abs(phrase.minX - first.minX) <= slack, phrase.maxX <= first.maxX + slack,
              line.top - firstLine.bottom < 0.6 * line.size,
              let start = phrase.text.first(where: { $0.isLetter || $0.isNumber }) else { return false }
        return start.isLowercase || first.text.hasSuffix("-")
    }

    /// How far, in columns, a heading's centre may sit right of the middle of the columns it would
    /// spread over and still head them all. A heading centred over its columns sits on their
    /// middle; one printed over the last of three sits a whole column right of it. Left of the
    /// middle has no limit: that is a heading set from the left over its group.
    static let spanOffCentre = 0.75

    /// A heading that only points to the notes: "Note", "Notes 2", "(note)", "*", "†"
    /// (Plan KR P3). It names no column.
    static func isNoteMarkerHeading(_ text: String) -> Bool {
        let bare = text.lowercased()
            .replacingOccurrences(of: #"\*+|"# + footnoteSigns + #"|[\x{00B9}\x{00B2}\x{00B3}\x{2070}-\x{2079}()\[\].,:;]"#,
                                  with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if bare.isEmpty { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return bare.range(of: #"^(see\s+)?notes?(\s+(\d{1,2}|[a-z]|below|above))?$"#, options: .regularExpression) != nil
    }

    /// A column's path with a last heading that is only a note marker left out, so the heading
    /// above it is the column's own (Plan KR P3): a heading printed over a "Note" is the
    /// column's name, not the pointer under it. A path of the marker alone is kept.
    static func withoutNoteLeaf(_ path: [String]) -> [String] {
        guard path.count > 1, let last = path.last, isNoteMarkerHeading(last) else { return path }
        return Array(path.dropLast())
    }

    // MARK: - Cells

    private static let superscriptDigits: [Character: Character] = [
        "\u{2070}": "0", "\u{00B9}": "1", "\u{00B2}": "2", "\u{00B3}": "3", "\u{2074}": "4",
        "\u{2075}": "5", "\u{2076}": "6", "\u{2077}": "7", "\u{2078}": "8", "\u{2079}": "9",
    ]

    /// A digit marker written back as the superscript it was printed as; anything else as is.
    static func superscripted(_ marker: String) -> String {
        guard marker.allSatisfy(\.isASCII), marker.allSatisfy(\.isNumber) else { return marker }
        let inverse = Dictionary(uniqueKeysWithValues: superscriptDigits.map { ($1, $0) })
        return String(marker.map { inverse[$0] ?? $0 })
    }

    /// A marker as notes and cells compare it: superscript digits as plain digits, "(a)" as "a",
    /// "1)" as "1".
    static func normalisedMarker(_ raw: String) -> String {
        let mapped = String(raw.map { superscriptDigits[$0] ?? $0 })
        return mapped.trimmingCharacters(in: CharacterSet(charactersIn: "()[]. :"))
    }

    private static let numberPattern =
        #"^([-+\x{2212}]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:[.,]\d+)?|[-+\x{2212}]?[.,]\d+)\s*([A-Za-z\x{00B5}\x{03A9}\x{00B0}%\x{00B2}\x{00B3}/]{1,8})?$"#

    /// The unit a header path names in brackets at its end, innermost heading first: "(A)",
    /// "[mm²]", "(°C)".
    static func unit(in path: [String]) -> String? {
        for heading in path.reversed() {
            guard let range = heading.range(of: #"[\(\[]\s*([^()\[\]]{1,10}?)\s*[\)\]]\s*$"#, options: .regularExpression)
            else { continue }
            let unit = heading[range].trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
            if unit.contains(where: { $0.isLetter || "%\u{00B0}\u{00B5}\u{03A9}".contains($0) }),
               !unit.contains(" ") {
                return unit
            }
        }
        return nil
    }

    /// A cell's number, unit and markers. Trailing markers — asterisks, daggers, section signs, superscript
    /// digits after a number, "(a)" — are taken off before the number is read; the text keeps
    /// them, as printed. A unit is the cell's own ("30 A") or, for a number, its column's.
    static func parseCell(_ raw: String, markers given: [String], columnUnit: String?) -> ManualTable.Cell {
        let printed = (raw + given.map(superscripted).joined()).trimmingCharacters(in: .whitespaces)
        var body = raw.trimmingCharacters(in: .whitespaces)
        var markers = given
        var trailing: [String] = []
        while true {
            if let range = body.range(of: #"(\*+|"# + footnoteSigns + #")$"#, options: .regularExpression) {
                trailing.insert(String(body[range]), at: 0)
                body.removeSubrange(range)
            } else if let range = body.range(of: #"(?<=[\d)])[\x{00B9}\x{00B2}\x{00B3}\x{2070}-\x{2079}]+$"#,
                                             options: .regularExpression) {
                trailing.insert(normalisedMarker(String(body[range])), at: 0)
                body.removeSubrange(range)
            } else if let range = body.range(of: #"\s*\([a-z]\)$"#, options: .regularExpression),
                      body[..<range.lowerBound].last?.isNumber == true {
                trailing.insert(normalisedMarker(String(body[range]).trimmingCharacters(in: .whitespaces)), at: 0)
                body.removeSubrange(range)
            } else {
                break
            }
            body = body.trimmingCharacters(in: .whitespaces)
        }
        markers = trailing + markers
        guard let regex = try? NSRegularExpression(pattern: numberPattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let numberRange = Range(match.range(at: 1), in: body) else {
            return ManualTable.Cell(text: printed, markers: markers)
        }
        var number = String(body[numberRange]).replacingOccurrences(of: "\u{2212}", with: "-")
        if number.range(of: #"\d,\d{3}(,|$|\.)"#, options: .regularExpression) != nil {
            number = number.replacingOccurrences(of: ",", with: "")
        } else {
            number = number.replacingOccurrences(of: ",", with: ".")
        }
        let own = Range(match.range(at: 2), in: body).map { String(body[$0]) }
        return ManualTable.Cell(text: printed, value: Double(number), unit: own ?? columnUnit, markers: markers)
    }

    private static func note(from line: Line) -> ManualTable.Note {
        let phrases = line.phrases
        guard let first = phrases.first else { return ManualTable.Note(marker: nil, text: line.text) }
        if first.leadingMarker {
            let rest = ([first.text] + phrases.dropFirst().map(\.printed)).filter { !$0.isEmpty }.joined(separator: " ")
            return ManualTable.Note(marker: first.markers.first, text: rest)
        }
        let text = phrases.map(\.printed).joined(separator: " ")
        guard let range = text.range(of: noteStart, options: [.regularExpression, .caseInsensitive]) else {
            return ManualTable.Note(marker: nil, text: text)
        }
        let token = String(text[range])
        var rest = String(String(text[range.upperBound...]).drop { " :.-\u{2014}\u{2013}".contains($0) })
        if token.lowercased().hasPrefix("note") {
            // "Note 2: …" keys the note by its number; "Notes:" alone is a heading over the notes.
            if let number = rest.range(of: #"^\d+[\).:]?\s*"#, options: .regularExpression) {
                let marker = normalisedMarker(String(rest[number]))
                rest.removeSubrange(number)
                return ManualTable.Note(marker: marker, text: rest)
            }
            return ManualTable.Note(marker: nil, text: rest)
        }
        return ManualTable.Note(marker: normalisedMarker(token), text: rest)
    }

    // MARK: - Continued tables

    /// Join each continued piece onto the table it continues: the previous page's table of the
    /// same label, keeping that table's headers and each row's own page. A continuation with no
    /// start before it stays its own table, marked as continuing.
    static func merge(_ tables: [ManualTable]) -> [ManualTable] {
        var out: [ManualTable] = []
        for piece in tables {
            if piece.continues,
               let index = out.lastIndex(where: { $0.label.caseInsensitiveCompare(piece.label) == .orderedSame }),
               let lastPage = out[index].pages.last, piece.page.physical == lastPage.physical + 1,
               out[index].columns.count == piece.columns.count {
                out[index].rows.append(contentsOf: piece.rows)
                for note in piece.notes where !out[index].notes.contains(note) { out[index].notes.append(note) }
                // A page of it read from a picture makes the whole table one read from a picture
                // (Plan JN P2): its values are said to be so, never presented as the PDF's text.
                if piece.source.isRecognised, !out[index].source.isRecognised { out[index].source = piece.source }
                out[index].pictureAreas += piece.pictureAreas
                continue
            }
            out.append(piece)
        }
        return out
    }
}
