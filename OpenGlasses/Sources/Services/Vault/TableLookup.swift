import Foundation

/// One cell of an extracted table, found by table, row and column, with where it came from (Plan JJ
/// P1). What `table_lookup` answers with.
///
/// **It says what it found and no more** (decision 2). A cell comes back with its row's and its
/// column's full header paths, its units, the notes it, its row or its column point to, and the
/// page it is printed on. An asked number that falls between two rows returns both rows and says
/// so: nothing is interpolated, rounded, or moved to "the next size up" — which row a rule wants is
/// a chain step's parameter or the technician's call. A table, row or column the words fit more
/// than one way lists the candidates and asks. A table whose caption was found and whose grid could
/// not be read says so, with its page, so the technician can be shown it.
///
/// Pure: the stored tables in, an outcome out. The tool renders it for the model.
enum TableLookup {

    /// A stored table and the document it came from.
    struct Source: Equatable {
        let documentId: String
        let documentName: String
        let table: ManualTable
        /// The rule the table's document is read with (Plan JY P0).
        var termRule: TermRule

        init(documentId: String, documentName: String, table: ManualTable, termRule: TermRule = .english) {
            self.documentId = documentId
            self.documentName = documentName
            self.table = table
            self.termRule = termRule
        }
    }

    struct Request: Equatable {
        /// A label ("Table 99", "table ninety-nine") or the words of a title.
        var table: String
        /// A row header value, a number, or the words of a row header.
        var row: String
        /// A column header path ("Rating group 2 › Band B") or its words. Nil reads the whole row
        /// unless the table has one value column.
        var column: String?
        /// The document the technician named, by title or part of it.
        var document: String?

        init(table: String, row: String, column: String? = nil, document: String? = nil) {
            self.table = table
            self.row = row
            self.column = column
            self.document = document
        }
    }

    /// The part of a request that could not be settled.
    enum Part: String, Equatable {
        case document, table, row, column
    }

    /// What of a table read from a picture a lookup could not read clearly (Plan JN P2).
    enum UnclearPart: Equatable {
        /// A value cell the lookup would give.
        case cell
        /// A row's name: the row it lands on, or any row when where the asked words or number fall
        /// among the rows depends on them.
        case rowKey
        /// A column's heading: the column it names, or any column when the asked words matched a
        /// heading only loosely.
        case columnHeading
        /// The whole table: the organisation requires a table read from a picture to be checked
        /// against its page before any of its values are given, and this one is not (Plan JN P3).
        case notChecked
    }

    /// The rows and columns a lookup read.
    struct Found: Equatable {
        let source: Source
        /// One row, or the two that bracket an asked number (`between`).
        let rows: [ManualTable.Row]
        /// Indexes into `source.table.columns`: one when a column was asked for or the table has
        /// only one, every column otherwise.
        let columns: [Int]
        /// The asked number when it fell between `rows[0]` and `rows[1]`.
        let between: Double?
        /// Pages of the same table, in the same document, whose grid could not be read — rows
        /// printed there are not in this lookup.
        let unreadPages: [ManualTable.Page]
        /// How the row was found (Plan KD P0). Anything but its name is said in the result when
        /// the name differs from what was asked.
        var basis: RowBasis = .exact
        /// The row as asked, for saying so.
        var askedRow: String? = nil
    }

    /// How a lookup's row was found (Plan KD P0).
    enum RowBasis: String, Equatable {
        /// By the row's own heading, or a run of its headings.
        case exact
        /// By the AWG size its heading prints, in another form ("0000" for "4/0").
        case awg
        /// By a number its heading holds, or a printed range that holds it.
        case number
        /// By the words of its headings.
        case words
        /// By a chain's row rule (`at_least`, `at_most`) or a column search: the rule's choice.
        case rule
    }

    enum Outcome: Equatable {
        case found(Found)
        /// More than one fits; ask which. `candidates` are names to say.
        case ambiguous(Part, asked: String, candidates: [String])
        /// Nothing fits. `available` names what does exist, to offer.
        case notFound(Part, asked: String, available: [String])
        /// The table's caption was found and its grid was not read: the page can be shown.
        case notExtracted(Source)
        /// The table was read from a picture and what this lookup needs of it — the cell, the
        /// row's key or the column's heading, `part` says which — could not be read clearly (Plan
        /// JN P1, worded in P2): no value is given, and the pages can be shown.
        case unclear(Source, pages: [ManualTable.Page], part: UnclearPart)
        /// The searched manuals hold no tables at all.
        case noTables
    }

    // MARK: - Resolving

    static func resolve(_ request: Request, in sources: [Source]) -> Outcome {
        let source: Source, unread: [ManualTable.Page]
        switch resolveTable(request, in: sources) {
        case .failure(let refusal): return refusal.outcome
        case .success(let resolved): (source, unread) = resolved
        }
        let table = source.table

        // The column first, so a row that fails to resolve can still be reported for it.
        let columns: [Int]
        switch resolveColumn(request.column, in: table) {
        case .resolved(let found): columns = found
        case .ambiguous(let names): return .ambiguous(.column, asked: request.column ?? "", candidates: names)
        case .none: return .notFound(.column, asked: request.column ?? "", available: table.columns.map(columnName))
        case .unclear: return .unclear(source, pages: table.pages, part: .columnHeading)
        }

        switch resolveRow(request.row, in: table) {
        case .rows(let rows, let basis):
            return unlessUnclear(Found(source: source, rows: rows, columns: columns, between: nil, unreadPages: unread,
                                       basis: basis, askedRow: request.row))
        case .between(let lower, let upper, let value):
            return unlessUnclear(Found(source: source, rows: [lower, upper], columns: columns, between: value,
                                       unreadPages: unread, basis: .number, askedRow: request.row))
        case .ambiguous(let rows):
            return .ambiguous(.row, asked: request.row, candidates: rows.map(rowName))
        case .outside(let range):
            return .notFound(.row, asked: request.row, available: range)
        case .none:
            return .notFound(.row, asked: request.row, available: Array(table.rows.prefix(12)).map(rowName))
        case .unclear:
            return .unclear(source, pages: table.pages, part: .rowKey)
        }
    }

    // MARK: Read from a picture (Plan JN P1, P2)

    /// What a found lookup leans on that was read unclearly from a picture, or nil: an uncertain
    /// heading on a column it gives, an uncertain key on a row it gives — or, when the asked number
    /// fell between two rows, an uncertain key on any row, since a misread key moves where a number
    /// falls — or an uncertain cell among those it would give. Always nil for a text-layer table.
    static func unclearPart(_ found: Found) -> UnclearPart? {
        let table = found.source.table
        if found.columns.contains(where: { $0 < table.columns.count && table.columns[$0].uncertain }) { return .columnHeading }
        if found.rows.contains(where: \.keyUncertain) { return .rowKey }
        if found.between != nil && table.rows.contains(where: \.keyUncertain) { return .rowKey }
        for row in found.rows where found.columns.contains(where: { $0 < row.cells.count && row.cells[$0].uncertain }) {
            return .cell
        }
        return nil
    }

    /// Whether a found lookup leans on anything read unclearly from a picture.
    static func isUnclear(_ found: Found) -> Bool { unclearPart(found) != nil }

    /// `found`, or the outcome that gives no value because it leans on something read unclearly.
    static func unlessUnclear(_ found: Found) -> Outcome {
        unclearPart(found).map { .unclear(found.source, pages: pages(of: found), part: $0) } ?? .found(found)
    }

    /// An outcome that ends a lookup before its row is read, as an error so it can travel in a
    /// `Result`.
    struct Refusal: Error { let outcome: Outcome }

    /// The one table a request names — the read grid, with the pages of it that were not read —
    /// or the outcome that says why there is not one.
    static func resolveTable(_ request: Request, in sources: [Source])
        -> Result<(source: Source, unread: [ManualTable.Page]), Refusal> {
        guard !sources.isEmpty else { return .failure(Refusal(outcome: .noTables)) }
        var pool = sources
        if let document = request.document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            let exact = sources.filter { $0.documentName.localizedCaseInsensitiveContains(document) }
            pool = exact.isEmpty ? sources.filter { ManualDocumentChoice.matches($0.documentName, requested: document) } : exact
            guard !pool.isEmpty else {
                return .failure(Refusal(outcome: .notFound(.document, asked: document,
                                                           available: orderedUnique(sources.map(\.documentName)))))
            }
        }

        // The table: by label, then by title words.
        let candidates: [Source]
        let printed = pool.map(\.table.label)
        if let label = TableReference.labels(in: request.table, among: printed).first ?? bareLabel(request.table) {
            candidates = pool.filter { $0.table.label.caseInsensitiveCompare(label) == .orderedSame }
            guard !candidates.isEmpty else {
                return .failure(Refusal(outcome: .notFound(.table, asked: label, available: availableTables(pool))))
            }
        } else {
            candidates = byTitle(request.table, in: pool)
            guard !candidates.isEmpty else {
                return .failure(Refusal(outcome: .notFound(.table, asked: request.table, available: availableTables(pool))))
            }
        }
        // One table per document: the grid that was read wins over a page of it that was not.
        let documents = orderedUnique(candidates.map(\.documentId))
        let tables = Set(candidates.map { "\($0.documentId)#\($0.table.label.lowercased())" })
        guard documents.count == 1, tables.count == 1 else {
            return .failure(Refusal(outcome: .ambiguous(.table, asked: request.table, candidates: orderedUnique(
                candidates.map { "\($0.table.displayName) in \($0.documentName)" }))))
        }
        let read = candidates.filter(\.table.isExtracted)
        guard let source = read.first else { return .failure(Refusal(outcome: .notExtracted(candidates[0]))) }
        // Read from a picture, not checked, and the organisation requires checking (Plan JN P3):
        // nothing of the table is given — no cell, no row, no column search.
        if source.table.uncheckedWithheld {
            return .failure(Refusal(outcome: .unclear(source, pages: source.table.pages, part: .notChecked)))
        }
        return .success((source, candidates.filter { !$0.table.isExtracted }.map(\.table.page)))
    }

    /// "99", "No. 99", "95A" or "Q7" asked for as the table.
    private static func bareLabel(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^(?:no\.?\s*|#)?[A-Za-z]{0,2}\d{1,4}[A-Za-z]?$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return TableReference.labels(in: "table " + trimmed).first
    }

    /// The tables the asked words describe best — all of them when two score within
    /// `titleTieShare` of each other, so the lookup asks which.
    ///
    /// Scored by [[TableDirectory]] (Plan JW P1b), the score the per-turn hint offers tables by:
    /// title, headings and units, each shared word weighed by how few of the searched tables print
    /// it — so "the widget ratings table" and the words of a long descriptive title both land on
    /// the table the hint named. Words it cannot weigh (a short word, a bare number) fall back to
    /// counting the title words shared, as before.
    private static func byTitle(_ words: String, in pool: [Source]) -> [Source] {
        let entries = pool.map { TableReference.Entry(table: $0.table, documentName: $0.documentId, termRule: $0.termRule) }
        let ranked = TableDirectory.ranked(words, in: entries)
        if let best = ranked.first {
            let close = ranked.filter { $0.score >= best.score * titleTieShare }
            return pool.filter { source in
                close.contains { $0.entry.documentName == source.documentId
                    && $0.entry.label.caseInsensitiveCompare(source.table.label) == .orderedSame }
            }
        }
        return byTitleWordCount(words, in: pool)
    }

    /// Two tables whose scores for the asked words are this close are both offered.
    static let titleTieShare = 0.9

    /// The tables whose titles share the most of the asked words — all of them on a tie.
    private static func byTitleWordCount(_ words: String, in pool: [Source]) -> [Source] {
        let asked = significantWords(words).subtracting(["table", "tables"])
        guard !asked.isEmpty else { return [] }
        let scored = pool.map { ($0, asked.intersection(significantWords($0.table.title)).count) }
        guard let best = scored.map(\.1).max(), best > 0 else { return [] }
        return scored.filter { $0.1 == best }.map(\.0)
    }

    private static func availableTables(_ pool: [Source]) -> [String] {
        Array(orderedUnique(pool.map(\.table.displayName)).prefix(12))
    }

    // MARK: Columns

    private enum ColumnMatch {
        case resolved([Int]), ambiguous([String]), none
        /// The asked words fit no heading exactly, and a heading of the table was read unclearly
        /// from a picture, so a loose match could land on the wrong column (Plan JN P2).
        case unclear
    }

    private static func resolveColumn(_ asked: String?, in table: ManualTable) -> ColumnMatch {
        let all = Array(table.columns.indices)
        guard let asked = asked?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty else {
            return .resolved(all)
        }
        guard !all.isEmpty else { return .none }
        // By path: the whole path, or the end of it ("Band B" under one group only) — as printed,
        // then with the units in brackets left out on both sides (Plan JJ P5: a chain writes
        // "Band A" for a heading printed "Band A (A)").
        for strip in [false, true] {
            let key = normalised(strip ? withoutUnits(asked) : asked)
            guard !key.isEmpty else { continue }
            let byPath = all.filter { index in
                suffixes(table.columns[index].path.map { strip ? withoutUnits($0) : $0 }).contains(key)
            }
            if byPath.count == 1 { return .resolved(byPath) }
            if byPath.count > 1 {
                let whole = byPath.filter {
                    normalised(table.columns[$0].path.map { strip ? withoutUnits($0) : $0 }.joined(separator: " ")) == key
                }
                return whole.count == 1 ? .resolved(whole) : .ambiguous(byPath.map { columnName(table.columns[$0]) })
            }
        }
        // A loose match over headings any of which was read unclearly from a picture could land on
        // the column the misread one should have been (Plan JN P2): no column is chosen by words.
        if table.columns.contains(where: \.uncertain) { return .unclear }
        // By words, in any order: with the units, then — when they fit no column, or several —
        // without them, so a unit said another way ("amps" for "A") or left out decides nothing.
        let paths = all.map { table.columns[$0].path }
        var match = bestByWords(asked, among: paths)
        if case .one = match {} else {
            let bare = bestByWords(withoutUnits(asked), among: paths.map { $0.map(withoutUnits) })
            switch (match, bare) {
            case (_, .one): match = bare
            case (.none, .several): match = bare
            default: break
            }
        }
        switch match {
        case .one(let index): return .resolved([all[index]])
        case .several(let indexes): return .ambiguous(indexes.map { columnName(table.columns[all[$0]]) })
        case .none: return .none
        }
    }

    /// A heading or asked words with every bracketed unit taken out: "(A)", "[mm²]", "(°C)",
    /// "(amps)" — a bracket of one short word. Words in brackets ("(see note)") stay.
    static func withoutUnits(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s*[\(\[]\s*[^()\[\]\s]{1,10}\s*[\)\]]"#) else { return text }
        let ns = text as NSString
        var out = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let inner = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: " ()[]"))
            guard inner.contains(where: { $0.isLetter || "%\u{00B0}\u{00B5}\u{03A9}".contains($0) }),
                  let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: "")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Rows

    private enum RowMatch {
        case rows([ManualTable.Row], RowBasis)
        case between(ManualTable.Row, ManualTable.Row, Double)
        case ambiguous([ManualTable.Row])
        /// A number outside the rows' range; the range, to say.
        case outside([String])
        case none
        /// The asked row fits no row's name exactly, and a row's name was read unclearly from a
        /// picture, so a match by number or by words could land on the wrong row (Plan JN P2).
        case unclear
    }

    private static func resolveRow(_ asked: String, in table: ManualTable) -> RowMatch {
        let rows = table.rows
        let key = normalised(asked)
        guard !key.isEmpty, !rows.isEmpty else { return .none }

        // 0. An AWG aught size (Plan KD P0), before anything reads it as numbers: "4/0", "4/0 AWG",
        // "0000" and "four aught" are one size, and a row printed in any of those forms is that
        // row. An aught size that no row prints finds nothing — never row 4, never row 0.
        if let size = askedAWGSize(asked, in: table) {
            if case .rows(let found, _) = exactRow(key, in: rows) { return .rows(found, .exact) }
            let sized = rows.filter { awgSize(of: $0, in: table) == size }
            if sized.count == 1 { return .rows(sized, .awg) }
            if sized.count > 1 {
                // "4/0 aluminum" over a copper and an aluminum 4/0: the other words decide.
                let others = significantWords(asked).filter { !AWGSize.isSizeWord($0) }
                let narrowed = sized.filter { others.isSubset(of: significantWords($0.path.joined(separator: " "))) }
                return !others.isEmpty && narrowed.count == 1 ? .rows(narrowed, .awg) : .ambiguous(sized)
            }
            return .none
        }

        // 1. Exactly a header: one of the row's headers, or a run of them ("QXRT three conductors").
        switch exactRow(key, in: rows) {
        case .rows(let found, let basis): return .rows(found, basis)
        case .ambiguous(let found): return .ambiguous(found)
        default: break
        }

        // Past an exact name, the rows are matched by number or by words, and every row is a
        // candidate: a misread name anywhere may move the match (Plan JN P2). A between-rows
        // answer would be refused anyway; a single row found this way is refused too.
        if rows.contains(where: \.keyUncertain) { return .unclear }

        // 2. A number: a row keyed by that number (or a printed range holding it), else the two
        // rows either side of it. Words beside the number narrow the rows first ("QXRT 35").
        if let value = number(in: asked) {
            let others = significantWords(asked.replacingOccurrences(of: numberText(in: asked) ?? "", with: " "))
            let rowWords = { (row: ManualTable.Row) in significantWords(row.path.joined(separator: " ")) }
            let filtered = rows.filter { others.isSubset(of: rowWords($0)) }
            // Words no row prints (a unit said after the number) narrow nothing — but a number
            // no row prints is never dropped (Plan KD P0): "4 0" is not 4 with a word left over.
            let leftoverNumbers = others.filter { $0.first?.isNumber == true }
            let narrowed: [ManualTable.Row]
            if others.isEmpty {
                narrowed = rows
            } else if !filtered.isEmpty {
                narrowed = filtered
            } else if leftoverNumbers.isEmpty {
                narrowed = rows
            } else {
                narrowed = rows.filter { leftoverNumbers.isSubset(of: rowWords($0)) }
            }
            let keyed = narrowed.compactMap { row in numericKey(of: row).map { (row, $0) } }
            if !keyed.isEmpty {
                let hits = keyed.filter { $0.1.contains(value) }.map(\.0)
                if hits.count == 1 { return .rows(hits, .number) }
                if hits.count > 1 { return .ambiguous(hits) }
                let below = keyed.filter { $0.1.upper < value }
                let above = keyed.filter { $0.1.lower > value }
                guard let lowKey = below.map(\.1.upper).max(), let highKey = above.map(\.1.lower).min() else {
                    let low = keyed.map(\.1.lower).min() ?? 0, high = keyed.map(\.1.upper).max() ?? 0
                    return .outside(["the rows run from \(format(low)) to \(format(high))"])
                }
                let lower = below.filter { $0.1.upper == lowKey }.map(\.0)
                let upper = above.filter { $0.1.lower == highKey }.map(\.0)
                guard lower.count == 1, upper.count == 1 else { return .ambiguous(lower + upper) }
                return .between(lower[0], upper[0], value)
            }
            if !leftoverNumbers.isEmpty, narrowed.isEmpty { return .none }
        }

        // 3. The nearest words.
        switch bestByWords(asked, among: rows.map(\.path)) {
        case .one(let index): return .rows([rows[index]], .words)
        case .several(let indexes): return .ambiguous(indexes.map { rows[$0] })
        case .none: return .none
        }
    }

    /// The row whose headers, or a run of them, are exactly `key`; several when more than one fits
    /// and none fits whole.
    private static func exactRow(_ key: String, in rows: [ManualTable.Row]) -> RowMatch {
        let exact = rows.filter { suffixesAndParts($0.path).contains(key) }
        if exact.count == 1 { return .rows(exact, .exact) }
        guard exact.count > 1 else { return .none }
        let whole = exact.filter { normalised($0.path.joined(separator: " ")) == key
            || normalised($0.path.dropFirst().joined(separator: " ")) == key }
        return whole.count == 1 ? .rows(whole, .exact) : .ambiguous(exact)
    }

    /// The AWG size the asked row names (Plan KD P0), or nil. A bare "0" is 1/0 only in a table
    /// that prints aught sizes; in a table of temperatures it is the number 0.
    private static func askedAWGSize(_ asked: String, in table: ManualTable) -> String? {
        guard let size = AWGSize.find(in: asked) else { return nil }
        if asked.trimmingCharacters(in: .whitespaces) == "0" {
            return printsAughtSizes(table) ? size : nil
        }
        return size
    }

    /// The AWG size a row's headings print, or nil. A heading of a bare "0" counts only in a table
    /// that prints another aught size.
    private static func awgSize(of row: ManualTable.Row, in table: ManualTable) -> String? {
        for header in row.path {
            let text = header.trimmingCharacters(in: .whitespaces)
            if text == "0" { if printsAughtSizes(table) { return "1/0" } else { continue } }
            if let size = AWGSize.canonical(text) { return size }
        }
        return nil
    }

    /// Whether some row prints an aught size other than a bare "0": "1/0", "00", "0000".
    private static func printsAughtSizes(_ table: ManualTable) -> Bool {
        table.rows.contains { row in
            row.path.contains { header in
                let text = header.trimmingCharacters(in: .whitespaces)
                return text != "0" && AWGSize.canonical(text) != nil
            }
        }
    }

    /// The number a row is keyed by: the first of its headers that is a number ("35", "2.5 mm²")
    /// or a printed range ("7-9", "10–12"), as the interval it covers.
    private static func numericKey(of row: ManualTable.Row) -> (lower: Double, upper: Double, contains: (Double) -> Bool)? {
        for header in row.path {
            let text = header.trimmingCharacters(in: .whitespaces)
            if let range = printedRange(text) { return range }
            let cell = TableExtractor.parseCell(text, markers: [], columnUnit: nil)
            if let value = cell.value, text.range(of: #"^[-+\u{2212}]?[\d.,]+"#, options: .regularExpression) != nil {
                return (value, value, { $0 == value })
            }
        }
        return nil
    }

    private static let rangeNumber = #"(\d+(?:[.,]\d+)?)"#
    private static let rangeUnit = #"(?:\s*[^\s\d.,]{1,6})?"#
    /// "7-9", "7 – 9", "7 to 9", "7 through 9", "from 7 to 9", "7 A to 9 A": both ends included.
    private static let closedRange = try! NSRegularExpression(
        pattern: #"^(?:from\s+)?"# + rangeNumber + rangeUnit + #"\s*(?:-|\x{2013}|\x{2014}|to|through|thru)\s*"#
            + rangeNumber + rangeUnit + #"(?:\s*(?:incl\.?|inclusive))?$"#, options: [.caseInsensitive])
    /// "over 15 up to 18", "above 15 to 18", "more than 15 but not more than 18": above the first
    /// number, up to and including the second.
    private static let openLowRange = try! NSRegularExpression(
        pattern: #"^(?:over|above|more\s+than|greater\s+than|exceeding)\s+"# + rangeNumber + rangeUnit
            + #"\s+(?:(?:and\s+)?up\s+to|to|but\s+not\s+(?:over|more\s+than|exceeding))\s+"# + rangeNumber + rangeUnit + "$",
        options: [.caseInsensitive])

    /// A row key printed as a range (Plan JJ P1, widened in P5 to the ranges a book prints in
    /// words), as the interval it covers.
    private static func printedRange(_ text: String) -> (lower: Double, upper: Double, contains: (Double) -> Bool)? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func bounds(_ match: NSTextCheckingResult) -> (Double, Double)? {
            let parts = [1, 2].compactMap { Double(ns.substring(with: match.range(at: $0)).replacingOccurrences(of: ",", with: ".")) }
            return parts.count == 2 && parts[0] <= parts[1] ? (parts[0], parts[1]) : nil
        }
        if let match = closedRange.firstMatch(in: text, range: whole), let (low, high) = bounds(match) {
            return (low, high, { $0 >= low && $0 <= high })
        }
        if let match = openLowRange.firstMatch(in: text, range: whole), let (low, high) = bounds(match) {
            return (low, high, { $0 > low && $0 <= high })
        }
        return nil
    }

    /// The first number the asked words carry ("37", "37 A", "2.5"), else nil.
    private static func number(in text: String) -> Double? {
        guard let raw = numberText(in: text) else { return nil }
        return TableExtractor.parseCell(raw, markers: [], columnUnit: nil).value
    }

    private static func numberText(in text: String) -> String? {
        text.range(of: #"(?<![\p{L}\p{N}.])\d+(?:[.,]\d+)?(?![\p{N}]|[.,]\d)"#, options: .regularExpression)
            .map { String(text[$0]) }
    }

    // MARK: - Words

    private enum WordsMatch { case one(Int), several([Int]), none }

    /// The header path the asked words fit best. Every number the words carry must be in the path —
    /// a number is never approximated — and then the path holding the most of the other words
    /// wins; two that hold as many are both returned.
    private static func bestByWords(_ asked: String, among paths: [[String]]) -> WordsMatch {
        let words = significantWords(asked)
        guard !words.isEmpty else { return .none }
        let numbers = words.filter { $0.first?.isNumber == true }
        var best = 0
        var hits: [Int] = []
        for (index, path) in paths.enumerated() {
            let have = significantWords(path.joined(separator: " "))
            guard numbers.isSubset(of: have) else { continue }
            let shared = words.intersection(have).count
            guard shared > 0 else { continue }
            if shared > best { best = shared; hits = [index] } else if shared == best { hits.append(index) }
        }
        switch hits.count {
        case 0: return .none
        case 1: return .one(hits[0])
        default:
            // Several hold as many: the one with nothing beyond the asked words is meant.
            let tight = hits.filter { significantWords(paths[$0].joined(separator: " ")).count == best }
            return tight.count == 1 ? .one(tight[0]) : .several(hits)
        }
    }

    /// Words as they are compared: lower-cased, accents folded, "conductors" as "conductor", a
    /// printed range ("7-9") and a decimal ("1.5") kept whole; filler words dropped.
    static func significantWords(_ text: String) -> Set<String> {
        Set(tokens(text).filter { !filler.contains($0) }.map(singular))
    }

    private static let filler: Set<String> = ["the", "of", "for", "in", "and", "row", "column", "at", "with", "to", "on"]

    private static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
        let pattern = #"\d+(?:[.,]\d+)?(?:\s*-\s*\d+(?:[.,]\d+)?)?|\p{L}[\p{L}\p{N}]*|\p{N}+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = folded as NSString
        return regex.matches(in: folded, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        }
    }

    private static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), word.first?.isLetter == true else { return word }
        return String(word.dropLast())
    }

    /// A header as compared whole: its words joined by single spaces.
    static func normalised(_ text: String) -> String { tokens(text).map(singular).joined(separator: " ") }

    /// Every run of the path that ends at its end, whole path first ("rating group 2 band b",
    /// "band b").
    private static func suffixes(_ path: [String]) -> Set<String> {
        Set(path.indices.map { normalised(path[$0...].joined(separator: " ")) })
    }

    /// Every contiguous run of the path's parts.
    private static func suffixesAndParts(_ path: [String]) -> Set<String> {
        var out = Set<String>()
        for start in path.indices {
            for end in start..<path.count {
                out.insert(normalised(path[start...end].joined(separator: " ")))
            }
        }
        return out
    }

    // MARK: - Names

    static func rowName(_ row: ManualTable.Row) -> String {
        row.path.isEmpty ? "(unnamed row)" : row.path.joined(separator: ManualTable.Column.pathSeparator)
    }

    static func columnName(_ column: ManualTable.Column) -> String {
        column.name.isEmpty ? "(unnamed column)" : column.name
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Notes and citation

    /// The notes a found cell set points to: those keyed by a marker on a cell, on its row's
    /// headers or on its column's headings, then the table's unmarked notes, which apply to all of
    /// it. In the order the table prints them.
    static func notes(for found: Found) -> [ManualTable.Note] {
        let table = found.source.table
        var markers = Set<String>()
        for row in found.rows {
            for index in found.columns where index < row.cells.count { markers.formUnion(row.cells[index].markers) }
            for header in row.path { markers.formUnion(TableExtractor.parseCell(header, markers: [], columnUnit: nil).markers) }
        }
        for index in found.columns where index < table.columns.count {
            for heading in table.columns[index].path {
                markers.formUnion(TableExtractor.parseCell(heading, markers: [], columnUnit: nil).markers)
            }
        }
        return table.notes.filter { note in note.marker.map(markers.contains) ?? true }
    }

    /// The pages the found rows are printed on, in order.
    static func pages(of found: Found) -> [ManualTable.Page] {
        var seen: [ManualTable.Page] = []
        for row in found.rows where !seen.contains(row.page) { seen.append(row.page) }
        return seen.isEmpty ? [found.source.table.page] : seen
    }

    /// "page 12 (printed 10)" in the form `VaultRetriever.Passage.citation` writes it, which
    /// `CitationLineParser` reads back to the physical page.
    private static func citedPage(_ page: ManualTable.Page) -> String {
        "page \(page.physical)" + (page.printed.map { " (printed \($0))" } ?? "")
    }

    /// The machine-attached `Source:` line for a table's pages: "Book, page 12 (printed 10), Table
    /// 99", a second page of it as "; page 13, Table 99".
    static func sourceLine(documentName: String, label: String, pages: [ManualTable.Page]) -> String {
        let parts = pages.enumerated().map { index, page in
            (index == 0 ? "\(documentName), " : "") + "\(citedPage(page)), \(label)"
        }
        return "Source: " + parts.joined(separator: "; ")
    }

    /// The citations a result opens: one per page, each naming the table.
    static func citations(documentName: String, label: String, pages: [ManualTable.Page]) -> [Citation] {
        pages.map { Citation(kind: .manual, title: documentName, page: $0.physical, figure: label) }
    }

    /// How a page is said: its printed number when the book prints one, else the PDF's own.
    static func spokenPage(_ page: ManualTable.Page) -> String {
        page.printed.map { "page \($0)" } ?? "PDF page \(page.physical)"
    }

    // MARK: - Rendering

    /// What the model is told. Every answer that names a cell ends with the `Source:` line.
    static func render(_ outcome: Outcome) -> String {
        switch outcome {
        case .noTables:
            return "No table could be read from the loaded manuals, so there is no cell to look up. "
                + "Search with manual_lookup instead, and say the value comes from a passage, not a table."
        case .notFound(.document, let asked, let available):
            return "No manual with tables is titled like \"\(asked)\". Manuals with tables: "
                + available.joined(separator: "; ") + ". Nothing was looked up."
        case .notFound(.table, let asked, let available):
            return "No table matching \"\(asked)\" was read from the loaded manuals. Tables that were read: "
                + available.joined(separator: "; ")
                + ". If the book prints it, its grid may not have been readable: find its page with manual_lookup "
                + "and show it rather than answering from memory."
        case .notFound(.column, let asked, let available):
            return "No column matching \"\(asked)\" in that table. Its columns: " + available.joined(separator: "; ")
                + ". Ask the technician which column, then call again. No value was given."
        case .notFound(.row, let asked, let available):
            return "No row matching \"\(asked)\" in that table"
                + (available.isEmpty ? "." : " (" + available.joined(separator: "; ") + ").")
                + " Do not take the nearest row instead: say the table has no such row, or ask for the row as printed."
        case .ambiguous(let part, let asked, let candidates):
            let what: String
            switch part {
            case .document: what = "manual"
            case .table: what = "table"
            case .row: what = "row"
            case .column: what = "column"
            }
            let retry = part == .table ? "Ask the technician which table or which book (pass 'document'), then call again."
                : "Ask the technician which \(what), then call again with it."
            return "More than one \(what) matches \"\(asked)\": " + candidates.joined(separator: "; ") + ". "
                + retry + " No value was given."
        case .unclear(let source, let pages, let part):
            let table = source.table
            return "\(table.displayName) is printed on " + pages.map(spokenPage).joined(separator: ", ")
                + " of \(source.documentName) as a picture, and \(unclearReason(part)), so there is no value to give. "
                + "Do not answer from memory. Tell the technician, and offer to show the page (open it with show_source only if they ask).\n"
                + sourceLine(documentName: source.documentName, label: table.label, pages: pages)
        case .notExtracted(let source):
            let table = source.table
            return "\(table.displayName) is printed on \(spokenPage(table.page)) of \(source.documentName), "
                + "but its grid could not be read from the PDF (\(reason(table.failure))), so there is no cell to give. "
                + "Do not answer from memory. Tell the technician, and offer to show the page (open it with show_source only if they ask).\n"
                + sourceLine(documentName: source.documentName, label: table.label, pages: [table.page])
        case .found(let found):
            return renderFound(found)
        }
    }

    /// What a row found by number or by words says when it is not the row asked for (Plan KD P0):
    /// "4/0" answered from row 4 was the retest's wrong answer. Row matching no longer does that,
    /// and this says so plainly if anything ever does. Nil when the row is the one asked for — a
    /// range that holds the number, "2.5" for "2.5 mm²". Pure.
    static func mismatchLine(_ found: Found) -> String? {
        guard found.between == nil, found.basis == .number || found.basis == .words,
              let asked = found.askedRow?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty,
              let row = found.rows.first else { return nil }
        let rowWords = significantWords(row.path.joined(separator: " "))
        let askedSize = AWGSize.find(in: asked)
        let differs: Bool
        if let askedSize {
            differs = row.path.lazy.compactMap(AWGSize.canonical).first != askedSize
        } else {
            // Every number asked beyond the one matched must be printed in the row.
            let primary = numberText(in: asked).map { normalised($0) }
            let extra = significantWords(asked).filter { $0.first?.isNumber == true && $0 != primary }
            differs = !extra.isSubset(of: rowWords)
        }
        guard differs else { return nil }
        let how = found.basis == .number ? "by number" : "by its words"
        return "Asked for row \"\(asked)\"; matched row \"\(rowName(row))\" \(how) — not the same row. "
            + "Do not answer from it; ask which \(askedSize == nil ? "row" : "size")."
    }

    /// Why a lookup on a table read from a picture gives no value (Plan JN P2).
    static func unclearReason(_ part: UnclearPart) -> String {
        switch part {
        case .cell: return "this cell could not be read clearly from the picture"
        case .rowKey: return "a row's name this lookup depends on could not be read clearly from the picture"
        case .columnHeading: return "a column's heading this lookup depends on could not be read clearly from the picture"
        case .notChecked: return "this table was read from a picture and has not been checked against the page yet"
        }
    }

    /// The latest check of the cells `found` gives from `rows`, when every one of them was checked
    /// against the page and the checks agree (Plan JN P3); nil when any was not.
    static func checkMark(of rows: [ManualTable.Row], in found: Found) -> TableCheckMark? {
        var marks: [TableCheckMark] = []
        for row in rows {
            for index in found.columns {
                guard index < row.cells.count, let mark = row.cells[index].check?.agreedMark else { return nil }
                marks.append(mark)
            }
        }
        return marks.max { $0.at < $1.at }
    }

    /// "read from a picture of the table on page 31 of Invented Book" — what every value a
    /// recognised table gives is said with (Plan JN P2), at the page its row is printed on.
    static func pictureNote(documentName: String, page: ManualTable.Page) -> String {
        "read from a picture of the table on \(spokenPage(page)) of \(documentName)"
    }

    private static func reason(_ failure: TableExtractor.Failure?) -> String {
        switch failure {
        case .noTextLayer: return "the page has no text layer"
        case .captionNotFound: return "the caption was not found on the page"
        case .tooFewRows: return "fewer than three rows came out of it"
        case .varyingColumnCount: return "its rows do not agree on their columns"
        case .mergedCells: return "it has cells spanning several columns"
        case .rotatedHeaders: return "its headings are set on their side"
        case .noTextInTable: return "the table is printed with no text the PDF can give, most likely as a picture"
        case .unclearInPicture: return "the table was read from a picture and too few of its cells could be read clearly"
        case nil: return "unknown"
        }
    }

    private static func cellText(_ cell: ManualTable.Cell) -> String {
        guard !cell.isEmpty else { return "(nothing printed)" }
        var text = "\"\(cell.text)\""
        if let value = cell.value {
            text += " (the number " + format(value) + (cell.unit.map { " \($0)" } ?? "") + ")"
        }
        return text
    }

    private static func renderFound(_ found: Found) -> String {
        let source = found.source
        let table = source.table
        let pictured = table.source.isRecognised
        var lines = ["\(table.displayName), \(source.documentName):"]
        if let mismatch = mismatchLine(found) { lines.append(mismatch) }
        func rowLine(_ row: ManualTable.Row) -> String {
            let cells = found.columns.map { index -> String in
                let cell = index < row.cells.count ? row.cells[index] : ManualTable.Cell(text: "")
                let column = index < table.columns.count ? columnName(table.columns[index]) : "column \(index + 1)"
                return "column \(column): \(cellText(cell))"
            }
            let line = "row \(rowName(row)) (\(spokenPage(row.page))) — " + cells.joined(separator: "; ")
            // Every row a picture gave says so (Plan JN P2), both rows of a between-rows answer too,
            // and who checked it against the page when someone has (Plan JN P3).
            guard pictured else { return line }
            let note = line + " — " + pictureNote(documentName: source.documentName, page: row.page)
            return checkMark(of: [row], in: found).map { note + ", " + TableChecks.checkedNote($0) } ?? note
        }
        if let value = found.between, found.rows.count == 2 {
            lines.append("\(format(value)) is not a row of this table; it falls between two rows:")
            lines += found.rows.map { "- " + rowLine($0) }
            lines.append("Say both rows and that \(format(value)) falls between them. Do not interpolate, round, "
                         + "or pick one: which row applies is the rule's call or the technician's.")
        } else {
            lines += found.rows.map(rowLine)
        }
        let notes = notes(for: found)
        if !notes.isEmpty {
            lines.append("Notes: " + notes.map { note in
                (note.marker.map { "[\(TableExtractor.superscripted($0))] " } ?? "") + note.text
            }.joined(separator: " | "))
        }
        if !found.unreadPages.isEmpty {
            lines.append("Part of this table, on " + found.unreadPages.map(spokenPage).joined(separator: ", ")
                         + ", could not be read, so rows printed there are not in this lookup.")
        }
        if pictured {
            if notes.isEmpty {
                lines.append("Notes printed with a table read from a picture are not read: any note that applies is on the page.")
            }
            if let mark = checkMark(of: found.rows, in: found) {
                // Every value given was checked against the page (Plan JN P3): still said to be from
                // a picture, and no longer handed back to the technician to check.
                lines.append("This table is printed as a picture, and the value was read from that picture on the phone, not "
                             + "from the PDF's text, then checked against the page. Say it was "
                             + pictureNote(documentName: source.documentName, page: pages(of: found)[0])
                             + " and " + TableChecks.checkedNote(mark) + ", and offer to show the page (open it with "
                             + "show_source only if they ask).")
            } else {
                lines.append("This table is printed as a picture, and the value was read from that picture on the phone, not "
                             + "from the PDF's text. Say it was " + pictureNote(documentName: source.documentName,
                                                                             page: pages(of: found)[0])
                             + ", read the value back to the technician to check against the page, and offer to show the page "
                             + "(open it with show_source only if they ask).")
            }
        }
        lines.append("Read the value out as printed, with its row, column and page. Do not interpolate, round, "
                     + "or move to another row.")
        lines.append(sourceLine(documentName: source.documentName, label: table.label, pages: pages(of: found)))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Row rules (Plan JJ P2)

/// What a rule chain's `lookup` step asks of a table beyond P1's lookup: which row a rule wants
/// when the asked number is not a row of its own, and the row whose cell in a column meets a
/// number. The rule is the chain's, written by the organisation (decision 2): the lookup itself
/// still never interpolates, rounds or picks a row on its own.
extension TableLookup {

    enum RowRule: String, CaseIterable, Equatable, Codable {
        /// The row whose key is the number, or a printed range that holds it ("8" in "7-9").
        case exact
        /// That row, else the first row whose key is at or above the number.
        case atLeast = "at_least"
        /// That row, else the last row whose key is at or below the number.
        case atMost = "at_most"
    }

    /// `resolve` with a row rule applied. `exact` is `resolve` unchanged — a number between two
    /// rows comes back with both, and the chain stops on it. `at_least` takes the upper of the two
    /// rows, `at_most` the lower; a number below every row is `at_least` the first, and one above
    /// every row `at_most` the last. Anything else is what `resolve` said.
    static func resolve(_ request: Request, rule: RowRule, in sources: [Source]) -> Outcome {
        let outcome = resolve(request, in: sources)
        guard rule != .exact else { return outcome }
        switch outcome {
        case .found(let found) where found.between != nil && found.rows.count == 2:
            // `resolve` gave the two rows only with every key of the table clear (Plan JN P1).
            let row = rule == .atLeast ? found.rows[1] : found.rows[0]
            return unlessUnclear(Found(source: found.source, rows: [row], columns: found.columns, between: nil,
                                       unreadPages: found.unreadPages, basis: .rule, askedRow: found.askedRow))
        case .notFound(.row, _, _):
            guard let value = number(in: request.row),
                  case .success(let resolved) = resolveTable(request, in: sources),
                  case .resolved(let columns) = resolveColumn(request.column, in: resolved.source.table) else {
                return outcome
            }
            let keyed = resolved.source.table.rows.compactMap { row in
                numericKey(of: row).map { (row: row, lower: $0.lower, upper: $0.upper) }
            }
            var pick: ManualTable.Row?
            if rule == .atLeast, let lowest = keyed.map(\.lower).min(), value < lowest {
                pick = keyed.first { $0.lower == lowest }?.row
            } else if rule == .atMost, let highest = keyed.map(\.upper).max(), value > highest {
                pick = keyed.last { $0.upper == highest }?.row
            }
            guard let pick else { return outcome }
            let found = Found(source: resolved.source, rows: [pick], columns: columns, between: nil,
                              unreadPages: resolved.unread, basis: .rule, askedRow: request.row)
            // The first or last row by key: a misread key anywhere may have moved which that is.
            if resolved.source.table.rows.contains(where: \.keyUncertain) {
                return .unclear(resolved.source, pages: pages(of: found), part: .rowKey)
            }
            return unlessUnclear(found)
        default:
            return outcome
        }
    }

    /// What searching one column for a number came to.
    enum CellSearch: Equatable {
        /// One row, one column: the cell that meets the rule.
        case found(Found)
        /// The table or the column did not resolve to one; the outcome says why.
        case refused(Outcome)
        /// No cell in the column meets the rule. `range` is what the column's numbers run over.
        case none(Source, column: Int, range: ClosedRange<Double>?)
        /// Under `exact`, more than one cell holds the number.
        case several(Source, column: Int, rows: [ManualTable.Row])
    }

    /// The row whose cell in the named column meets `value` under `rule`: `exact` a cell holding
    /// the number; `at_least` the smallest cell at or above it; `at_most` the largest at or below
    /// it — the first printed of equal cells for `at_least`, the last for `at_most`. The column
    /// must resolve to exactly one. `request.row` is not read.
    static func search(_ request: Request, value: Double, rule: RowRule, in sources: [Source]) -> CellSearch {
        let resolved: (source: Source, unread: [ManualTable.Page])
        switch resolveTable(request, in: sources) {
        case .failure(let refusal): return .refused(refusal.outcome)
        case .success(let found): resolved = found
        }
        let table = resolved.source.table
        let column: Int
        switch resolveColumn(request.column, in: table) {
        case .resolved(let found) where found.count == 1: column = found[0]
        case .resolved(let found):
            return .refused(.ambiguous(.column, asked: request.column ?? "",
                                       candidates: found.map { columnName(table.columns[$0]) }))
        case .ambiguous(let names): return .refused(.ambiguous(.column, asked: request.column ?? "", candidates: names))
        case .none:
            return .refused(.notFound(.column, asked: request.column ?? "", available: table.columns.map(columnName)))
        case .unclear:
            return .refused(.unclear(resolved.source, pages: table.pages, part: .columnHeading))
        }
        // A heading or any cell of the column read unclearly from a picture may move which row
        // meets the number (Plan JN P1): no row is given.
        if table.columns[column].uncertain {
            return .refused(.unclear(resolved.source, pages: table.pages, part: .columnHeading))
        }
        if table.rows.contains(where: { column < $0.cells.count && $0.cells[column].uncertain }) {
            return .refused(.unclear(resolved.source, pages: table.pages, part: .cell))
        }
        let numbered = table.rows.compactMap { row -> (row: ManualTable.Row, value: Double)? in
            guard column < row.cells.count, let number = row.cells[column].value else { return nil }
            return (row, number)
        }
        let values = numbered.map(\.value)
        let range = values.min().flatMap { low in values.max().map { low...$0 } }
        let chosen: [ManualTable.Row]
        switch rule {
        case .exact:
            chosen = numbered.filter { $0.value == value }.map(\.row)
            if chosen.count > 1 { return .several(resolved.source, column: column, rows: chosen) }
        case .atLeast:
            let best = numbered.filter { $0.value >= value }.map(\.value).min()
            chosen = best.map { best in numbered.filter { $0.value == best }.prefix(1).map(\.row) } ?? []
        case .atMost:
            let best = numbered.filter { $0.value <= value }.map(\.value).max()
            chosen = best.map { best in numbered.filter { $0.value == best }.suffix(1).map(\.row) } ?? []
        }
        guard let row = chosen.first else { return .none(resolved.source, column: column, range: range) }
        let found = Found(source: resolved.source, rows: [row], columns: [column], between: nil,
                          unreadPages: resolved.unread, basis: .rule)
        if case .unclear(let source, let pages, let part) = unlessUnclear(found) {
            return .refused(.unclear(source, pages: pages, part: part))
        }
        return .found(found)
    }

    /// The row printed after `row`, for "the next row is …".
    static func nextRow(after row: ManualTable.Row, in table: ManualTable) -> ManualTable.Row? {
        guard let index = table.rows.firstIndex(of: row), index + 1 < table.rows.count else { return nil }
        return table.rows[index + 1]
    }
}
