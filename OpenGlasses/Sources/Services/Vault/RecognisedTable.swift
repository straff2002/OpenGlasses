import CoreGraphics
import Foundation

// A table printed as a picture, read from what a recogniser saw (Plan JN P0).
//
// The headless half: a page's recognition comes in as plain values ([[RecognisedPage]]) and goes out
// as a `ManualTable`, or the extractor's reason there is none, by one of two readers. Reader A lays
// the recognised words out with [[TableExtractor]]'s own rules, unchanged; reader B maps the
// recogniser's own grid of cells. Neither relaxes a structural test for a picture. How clearly each
// cell was read is judged apart, by [[CellCertainty]], from the evidence a reading keeps per cell.
//
// Foundation and CoreGraphics only — no Vision, no PDFKit — so every rule runs in a unit test and
// in the Mac measurement runners. The adapters that fill a `RecognisedPage` from Vision are P1's.

/// One word a recogniser read, in page space.
struct RecognisedWord: Equatable, Codable {
    var text: String
    /// The word's box in **top-down** page points, as [[PositionedWord]] keeps one: the origin is
    /// the page's top left and y grows downwards. [[PictureRegion]] maps a recogniser's box to it.
    var rect: CGRect
    /// The recogniser's confidence in `text`, 0–1.
    var confidence: Float
    /// The other readings the recogniser offered, best first, `text` not among them.
    var candidates: [String]

    init(_ text: String, rect: CGRect, confidence: Float, candidates: [String] = []) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.candidates = candidates
    }
}

/// A page's recognition, or a region of one (Plan JN P0): its words, and any tables the
/// recogniser returned as cells by row and column. Pure input: built by the Vision adapters (P1)
/// and constructed directly in tests.
struct RecognisedPage: Equatable, Codable {

    /// One cell of a recognised table. A heading over several columns, or a row header printed once
    /// over several rows, is one cell whose range spans them — the recogniser says so, rather than
    /// a reader inferring it from where the words sit.
    struct Cell: Equatable, Codable {
        var rowRange: ClosedRange<Int>
        var columnRange: ClosedRange<Int>
        /// The cell's words in reading order.
        var words: [RecognisedWord]

        init(rows: ClosedRange<Int>, columns: ClosedRange<Int>, words: [RecognisedWord]) {
            rowRange = rows
            columnRange = columns
            self.words = words
        }
    }

    struct Table: Equatable, Codable {
        var cells: [Cell]
    }

    var words: [RecognisedWord]
    var tables: [Table]

    init(words: [RecognisedWord] = [], tables: [Table] = []) {
        self.words = words
        self.tables = tables
    }
}

/// A table read from a picture, with what each of its value cells was read from (Plan JN P0), for
/// [[CellCertainty]] to judge. Never stored: the `ManualTable` is.
struct RecognisedReading: Equatable {

    /// What a value cell was read from.
    struct Evidence: Equatable {
        /// Where a second pass over the same region finds the same cell.
        enum Place: Equatable {
            /// A recogniser's grid: the table's index on the page and the cell's ranges.
            case grid(table: Int, rows: ClosedRange<Int>, columns: ClosedRange<Int>)
            /// Recognised words: the box, in page points, the cell's phrase was printed in.
            case box(CGRect)
        }

        /// The recognised words the cell's text was read from; empty when none could be tied to it.
        var words: [RecognisedWord]
        var place: Place?

        static let missing = Evidence(words: [], place: nil)
    }

    var caption: TableExtractor.Caption
    var outcome: TableExtractor.Outcome
    /// Per row of the table, per value column, in the table's order. Empty when no table was read.
    var cells: [[Evidence]]
    /// Per row of the table, what its key was read from: the heading printed over it and its
    /// row-header cells, each once (Plan JN P1). A row with no key has none; a key the reader could
    /// not tie to its words is `.missing`. Empty when the reader kept none, and then no key is
    /// judged.
    var rowKeys: [[Evidence]] = []
    /// Per value column, what its heading was read from, outermost level first (Plan JN P1). Empty
    /// when the reader kept none.
    var columnHeadings: [[Evidence]] = []
    /// The grid reader A laid the table on, kept so a text page that carries the table on with no
    /// caption is read onto the same columns (Plan JN P1). Nil for reader B. Never stored.
    var grid: TableExtractor.Grid?
}

// MARK: - A cell's words as the extractor reads them

/// A cell's words read as one cell: its text, its footnote markers and the text as printed —
/// through [[TableExtractor]]'s own lines and phrases, so a superscript marker read as a word of its
/// own ("45" and a small raised "1") becomes the cell's marker exactly as on a text layer.
struct RecognisedCellText: Equatable {
    var text: String
    var markers: [String]
    var printed: String

    init(_ words: [RecognisedWord]) {
        let phrases = TableExtractor.lines(of: RecognisedWords.positioned(words)).flatMap(\.phrases)
        text = phrases.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        markers = phrases.flatMap(\.markers)
        printed = phrases.map(\.printed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The reading as two readings are compared: the printed text, whitespace aside. Case and
    /// glyphs are kept — "5O" and "50" are exactly the difference that matters.
    var key: String { printed.filter { !$0.isWhitespace } }
}

// MARK: - Reader A: recognised words into the extractor

/// Reader A (Plan JN P0): recognised words become [[PositionedWord]]s and are read by
/// `TableExtractor.extractGrids`, unchanged. A word's size is its box height and nothing is bold,
/// which routes the extractor to its one-weight header rule; the caption's own text-layer words
/// are read with them, their weight dropped, so the page reads in one weight throughout.
enum RecognisedWords {

    static func positioned(_ words: [RecognisedWord]) -> [PositionedWord] {
        words.map { PositionedWord($0.text, rect: $0.rect, size: Double($0.rect.height), bold: false) }
    }

    /// The table `caption` heads, read from `recognised`'s words under the caption's own
    /// text-layer words (its line and any title lines), on `page`.
    static func table(_ recognised: RecognisedPage, captionWords: [PositionedWord],
                      caption: TableExtractor.Caption, page: ManualTable.Page) -> RecognisedReading {
        let plain = captionWords.map { word -> PositionedWord in
            var word = word
            word.bold = false
            return word
        }
        let found = TableExtractor.extractGrids(words: plain + positioned(recognised.words), page: page)
        guard let match = found.first(where: { $0.caption.label.caseInsensitiveCompare(caption.label) == .orderedSame })
        else { return RecognisedReading(caption: caption, outcome: .failed(.captionNotFound), cells: []) }
        guard case .table(var table) = match.outcome, let grid = match.grid else {
            return RecognisedReading(caption: match.caption, outcome: match.outcome, cells: [])
        }
        table.source = .recognised(reader: .words, meanConfidence: meanConfidence(recognised.words))
        let cells = table.rows.indices.map { row -> [RecognisedReading.Evidence] in
            table.rows[row].cells.indices.map { column in
                guard row < grid.cellBoxes.count, column < grid.cellBoxes[row].count,
                      let box = grid.cellBoxes[row][column] else { return .missing }
                let words = self.words(in: box, of: recognised.words)
                // Words that do not read back as the cell's text cannot vouch for it: the cell
                // then has no evidence, and is uncertain.
                let read = RecognisedCellText(words)
                let text = table.rows[row].cells[column].text.filter { !$0.isWhitespace }
                return RecognisedReading.Evidence(words: read.key == text ? words : [], place: .box(box))
            }
        }
        let headings = headingEvidence(table: table, grid: grid, words: recognised.words)
        return RecognisedReading(caption: match.caption, outcome: .table(table), cells: cells,
                                 rowKeys: headings.rowKeys, columnHeadings: headings.columns, grid: grid)
    }

    /// What each row's key and each column's heading were read from (Plan JN P1), by where the
    /// grid printed them: a row's key in its row-header columns across the band its value cells
    /// print in, a column's heading in its own extent above the first row. A key carried down from
    /// the row above (printed once for the rows under it) is vouched for by the words it was read
    /// from there. A key whose words do not read back as the row's key, or a grid of groups printed
    /// side by side, is `.missing` — uncertain, never guessed.
    static func headingEvidence(table: ManualTable, grid: TableExtractor.Grid, words: [RecognisedWord])
        -> (rowKeys: [[RecognisedReading.Evidence]], columns: [[RecognisedReading.Evidence]]) {
        let unknownRows = table.rows.map { $0.path.isEmpty ? [] : [RecognisedReading.Evidence.missing] }
        let unknownColumns = table.columns.map { $0.path.isEmpty ? [] : [RecognisedReading.Evidence.missing] }
        guard grid.groups.count == 1, let group = grid.groups.first,
              group.columns.count - group.stubs == table.columns.count,
              group.columns.allSatisfy({ $0 < grid.lows.count && $0 < grid.highs.count }) else {
            return (unknownRows, unknownColumns)
        }
        func extent(_ column: Int, top: Double, bottom: Double) -> CGRect {
            CGRect(x: grid.lows[column], y: top, width: max(grid.highs[column] - grid.lows[column], 1),
                   height: max(bottom - top, 1))
        }
        let stubColumns = Array(group.columns.prefix(group.stubs))
        var carried = [RecognisedReading.Evidence?](repeating: nil, count: stubColumns.count)
        var rowKeys: [[RecognisedReading.Evidence]] = []
        var bodyTop = Double.infinity
        for (index, row) in table.rows.enumerated() {
            let boxes = index < grid.cellBoxes.count ? grid.cellBoxes[index].compactMap { $0 } : []
            guard let top = boxes.map({ Double($0.minY) }).min(), let bottom = boxes.map({ Double($0.maxY) }).max() else {
                rowKeys.append(row.path.isEmpty ? [] : [.missing])
                continue
            }
            bodyTop = min(bodyTop, top)
            var evidence: [RecognisedReading.Evidence] = []
            for (position, column) in stubColumns.enumerated() {
                let box = extent(column, top: top, bottom: bottom)
                let found = self.words(in: box, of: words)
                if found.isEmpty {
                    if let earlier = carried[position] { evidence.append(earlier) }
                    continue
                }
                let own = RecognisedReading.Evidence(words: found, place: .box(box))
                carried[position] = own
                evidence.append(own)
            }
            // The key the words read must be the key the row was given, stub for stub.
            let read = evidence.map { RecognisedCellText($0.words).key }
            let given = row.path.suffix(read.count).map { $0.filter { !$0.isWhitespace } }
            if row.path.isEmpty {
                rowKeys.append([])
            } else if read.isEmpty || read != Array(given) {
                rowKeys.append([.missing])
            } else {
                rowKeys.append(evidence)
            }
        }
        guard bodyTop.isFinite else { return (unknownRows, unknownColumns) }
        let headTop = (words.map { Double($0.rect.minY) }.min() ?? bodyTop) - 1
        let columns = table.columns.indices.map { index -> [RecognisedReading.Evidence] in
            guard !table.columns[index].path.isEmpty else { return [] }
            // Stopped short of the first row, past the point of slack `words(in:)` allows, so a
            // second pass finds the same words in the same box.
            let box = extent(group.columns[group.stubs + index], top: headTop, bottom: bodyTop - 3)
            let found = self.words(in: box, of: words)
            return [RecognisedReading.Evidence(words: found, place: found.isEmpty ? nil : .box(box))]
        }
        return (rowKeys, columns)
    }

    /// The words whose boxes meet `box` (a point's slack either way), in reading order.
    static func words(in box: CGRect, of words: [RecognisedWord]) -> [RecognisedWord] {
        let slack = box.insetBy(dx: -1, dy: -1)
        return words.filter { slack.intersects($0.rect) }
    }

    static func meanConfidence(_ words: [RecognisedWord]) -> Double {
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { $0 + Double($1.confidence) } / Double(words.count)
    }
}

// MARK: - Reader B: the recogniser's grid into a table

/// Reader B (Plan JN P0): a recogniser's table of cells, by row and column range, into a
/// `ManualTable`, by the extractor's own rules wherever a rule decides something.
///
/// - **Header.** The leading rows before the first row of numbers: `TableExtractor.plainHeader`,
///   the one-weight rule a plain text-layer page is read by, and its numbered-heading row.
/// - **Columns.** Each column's path runs down the header rows; a cell spanning several columns
///   there is a level of every one of their paths.
/// - **Rows.** Row-header columns are the extractor's (`TableExtractor.stubCount`). A cell spanning
///   rows in them is a level of every one of those rows' paths, and a cell alone across a row, over
///   the value columns, heads the rows under it. A blank row-header cell is left blank: in a
///   picture a blank may be a cell the recogniser missed, and a key carried down into it would put
///   a row's values under another row's name.
/// - **Cells.** Through `TableExtractor.parseCell` (number, unit, markers), as on a text layer.
/// - **Structure.** At least `minimumBodyRows` rows of two or more cells, and no more than the
///   extractor's `misfitTolerance` of them with a hole in the grid or a cell spanning value
///   columns or rows; otherwise the extractor's `Failure`. A page whose recognition holds no table
///   stays `no_text_in_table`.
enum RecognisedGrid {

    static func table(_ recognised: RecognisedPage, caption: TableExtractor.Caption, page: ManualTable.Page,
                      index: Int = 0) -> RecognisedReading {
        func failed(_ failure: TableExtractor.Failure) -> RecognisedReading {
            RecognisedReading(caption: caption, outcome: .failed(failure), cells: [])
        }
        guard index < recognised.tables.count else { return failed(.noTextInTable) }
        let cells = recognised.tables[index].cells.filter { $0.rowRange.lowerBound >= 0 && $0.columnRange.lowerBound >= 0 }
        guard let lastRow = cells.map(\.rowRange.upperBound).max(),
              let lastColumn = cells.map(\.columnRange.upperBound).max() else { return failed(.noTextInTable) }
        let rowCount = lastRow + 1
        let columnCount = lastColumn + 1

        // Which cell covers each place in the grid.
        var at = [[Int?]](repeating: [Int?](repeating: nil, count: columnCount), count: rowCount)
        for (number, cell) in cells.enumerated() {
            for row in cell.rowRange { for column in cell.columnRange where at[row][column] == nil { at[row][column] = number } }
        }
        let read = cells.map { RecognisedCellText($0.words) }
        guard read.contains(where: { !$0.printed.isEmpty }) else { return failed(.noTextInTable) }

        /// The cells a row prints, left to right, each once however many columns it spans.
        func printed(_ row: Int) -> [Int] {
            var out: [Int] = []
            for column in 0..<columnCount {
                guard let number = at[row][column], !read[number].printed.isEmpty, out.last != number else { continue }
                out.append(number)
            }
            return out
        }
        /// The cell that starts in this row and column, when one does.
        func anchored(_ row: Int, _ column: Int) -> Int? {
            guard let number = at[row][column], cells[number].rowRange.lowerBound == row,
                  cells[number].columnRange.lowerBound == column else { return nil }
            return number
        }
        func isNumber(_ number: Int) -> Bool {
            TableExtractor.parseCell(read[number].text, markers: read[number].markers, columnUnit: nil).value != nil
        }
        func paths(headerRows: Int) -> [[String]] {
            (0..<columnCount).map { column in
                var path: [String] = []
                var previous: Int?
                for row in 0..<headerRows {
                    let number = at[row][column]
                    defer { previous = number }
                    guard let number, number != previous, !read[number].printed.isEmpty else { continue }
                    path.append(read[number].printed)
                }
                return path
            }
        }

        // Header: the extractor's one-weight rule over the grid's rows. A grid has no title lines
        // to wrap and no prose or note lines among its rows.
        let ruleRows = (0..<min(rowCount, TableExtractor.headerRuleReach)).map { row in
            TableExtractor.HeaderRuleRow(cells: printed(row).map { (read[$0].text, read[$0].markers) })
        }
        var headerRows = TableExtractor.plainHeader(rows: ruleRows, wrapTitle: { _ in 0 }, isHeaderLine: { _ in true }).count
        var columnPaths = paths(headerRows: headerRows)
        func multiRows() -> [Int] { (headerRows..<rowCount).filter { printed($0).count >= 2 } }
        guard multiRows().count >= TableExtractor.minimumBodyRows else { return failed(.tooFewRows) }
        // The value columns' own headings printed as numbers under a heading over them.
        if headerRows > 0, headerRows < rowCount,
           TableExtractor.numberedHeadingRow(prints: { anchored(headerRows, $0).map { !read[$0].printed.isEmpty } ?? false },
                                             numeric: { anchored(headerRows, $0).map(isNumber) ?? false },
                                             paths: columnPaths),
           TableExtractor.numberedRowHeads(rowsUnder: multiRows().filter({ $0 > headerRows }).count,
                                           namesARow: anchored(headerRows, 0).map { !read[$0].printed.isEmpty } ?? false,
                                           counts: (1..<columnCount).map { anchored(headerRows, $0).map { read[$0].text } ?? "" }) {
            headerRows += 1
            columnPaths = paths(headerRows: headerRows)
        }
        let body = Array(headerRows..<rowCount)
        let multi = multiRows()

        // Row-header columns, by the extractor's rule.
        let stubs = TableExtractor.stubCount(
            columns: columnCount,
            prints: { column in body.contains { anchored($0, column).map { !read[$0].printed.isEmpty } ?? false } },
            holdsNumber: { column in body.contains { anchored($0, column).map(isNumber) ?? false } })

        // Structure: a row with a hole, or a cell spanning value columns or rows, does not fit.
        var misfits = 0
        var merged = 0
        for row in multi {
            var fits = true
            var spans = false
            for column in 0..<columnCount {
                guard let number = at[row][column] else { fits = false; continue }
                let cell = cells[number]
                let inStubs = cell.columnRange.upperBound < stubs
                if (cell.columnRange.count > 1 && !inStubs) || (cell.rowRange.count > 1 && !inStubs) {
                    fits = false
                    spans = true
                }
            }
            if !fits {
                misfits += 1
                if spans { merged += 1 }
            }
        }
        if Double(misfits) > TableExtractor.misfitTolerance * Double(multi.count) {
            return failed(merged * 2 >= misfits ? .mergedCells : .varyingColumnCount)
        }

        let columns = (stubs..<columnCount).map { ManualTable.Column(path: columnPaths[$0], unit: TableExtractor.unit(in: columnPaths[$0])) }
        let rowHeaders = (0..<stubs).map { columnPaths[$0].joined(separator: " ") }

        func proof(of number: Int) -> RecognisedReading.Evidence {
            RecognisedReading.Evidence(words: cells[number].words,
                                       place: .grid(table: index, rows: cells[number].rowRange, columns: cells[number].columnRange))
        }
        var rows: [ManualTable.Row] = []
        var evidence: [[RecognisedReading.Evidence]] = []
        var keys: [[RecognisedReading.Evidence]] = []
        var heading: String?
        var headingCell: Int?
        for row in body {
            let filled = printed(row)
            guard !filled.isEmpty else { continue }
            // A cell alone across the row, reaching over the value columns, or alone with no value
            // cells under it at all, heads the rows below. One alone beside value cells that were
            // read empty is a row whose values could not be read, not a heading.
            if filled.count == 1, cells[filled[0]].columnRange.lowerBound < stubs,
               cells[filled[0]].rowRange == row...row,
               cells[filled[0]].columnRange.upperBound >= stubs || (stubs..<columnCount).allSatisfy({ at[row][$0] == nil }) {
                heading = read[filled[0]].printed
                headingCell = filled[0]
                continue
            }
            var stubTexts: [String] = []
            var key = headingCell.map { [proof(of: $0)] } ?? []
            var previous: Int?
            for column in 0..<stubs {
                let number = at[row][column]
                defer { previous = number }
                guard let number, number != previous, !read[number].printed.isEmpty else { continue }
                stubTexts.append(read[number].printed)
                key.append(proof(of: number))
            }
            var values: [ManualTable.Cell] = []
            var found: [RecognisedReading.Evidence] = []
            for column in stubs..<columnCount {
                let unit = columns[column - stubs].unit
                guard let number = anchored(row, column) else {
                    values.append(ManualTable.Cell(text: ""))
                    found.append(.missing)
                    continue
                }
                let cell = read[number]
                values.append(cell.printed.isEmpty
                              ? ManualTable.Cell(text: "")
                              : TableExtractor.parseCell(cell.text, markers: cell.markers, columnUnit: unit))
                found.append(proof(of: number))
            }
            rows.append(ManualTable.Row(path: (heading.map { [$0] } ?? []) + stubTexts, cells: values, page: page))
            evidence.append(found)
            keys.append(key)
        }
        // Each value column's heading, a cell spanning several columns read once per column.
        let headings = (stubs..<columnCount).map { column -> [RecognisedReading.Evidence] in
            var out: [RecognisedReading.Evidence] = []
            var previous: Int?
            for row in 0..<headerRows {
                let number = at[row][column]
                defer { previous = number }
                guard let number, number != previous, !read[number].printed.isEmpty else { continue }
                out.append(proof(of: number))
            }
            return out
        }

        let table = ManualTable(label: caption.label, title: caption.title, page: page, rowHeaders: rowHeaders,
                                columns: columns, rows: rows, continues: caption.continues,
                                source: .recognised(reader: .documentGrid,
                                                    meanConfidence: RecognisedWords.meanConfidence(cells.flatMap(\.words))))
        return RecognisedReading(caption: caption, outcome: .table(table), cells: evidence,
                                 rowKeys: keys, columnHeadings: headings)
    }
}
