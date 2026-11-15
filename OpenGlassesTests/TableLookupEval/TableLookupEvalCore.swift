import Foundation
#if canImport(OpenGlasses)
@testable import OpenGlasses
#endif

/// Scores the table lookup against a key of cells (Plan JJ P5): for each question, the table, row
/// and column the key names, and what the lookup should give — the cell's text, the two rows a
/// number falls between, or a question back with the candidates it should offer. Counts only:
/// how many questions found their table, resolved their row and their column, and gave what the
/// key expects. Nothing from the key or a table is printed.
///
/// Shared by two runners: `TableCoverageTests` in the simulator, on an invented key over invented
/// tables, and `Scripts/table-lookup-eval` on a Mac, which compiles this file with the app's own
/// `TableLookup`, `TableExtractor` and `PDFTableReader` and reads a vault's PDFs as an import does.
enum TableLookupEval {

    /// What the key expects of one question.
    enum Expect: Equatable {
        /// The cell, as printed.
        case cell(String)
        /// The number falls between two rows: the one below it and the one above.
        case between(below: String, above: String)
        /// The lookup should ask, offering these.
        case ask(candidates: [String])
    }

    struct Question: Equatable {
        var table: String
        var row: String
        var column: String?
        var expect: Expect
        /// The edition the question is about, to pick the book by.
        var edition: String?
    }

    /// The key's lines as questions, and how many lines could not be read as one. A line is a JSON
    /// object with `table`, `row`, optionally `column` and `edition`, and `expect`: a string (or a
    /// number), `{"below": …, "above": …}`, or `{"ask": true, "candidates": […]}`. Blank lines and
    /// lines starting `//` are skipped.
    static func parse(_ jsonl: String) -> (questions: [Question], unreadable: Int) {
        let read = parseCounting(jsonl)
        return (read.questions, read.unreadable.values.reduce(0, +))
    }

    /// Why a key line was not read as a question, as a count.
    enum Unreadable: String, CaseIterable {
        case notJSON = "not_json"
        case noTable = "no_table"
        case noRow = "no_row"
        case noExpect = "no_expect"
        case expectShape = "expect_shape"
    }

    /// `parse`, with the lines it could not read counted by why.
    static func parseCounting(_ jsonl: String) -> (questions: [Question], unreadable: [Unreadable: Int]) {
        var questions: [Question] = []
        var unreadable: [Unreadable: Int] = [:]
        for raw in jsonl.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                unreadable[.notJSON, default: 0] += 1
                continue
            }
            guard let table = text(object["table"]) else { unreadable[.noTable, default: 0] += 1; continue }
            guard let row = text(object["row"]) else { unreadable[.noRow, default: 0] += 1; continue }
            guard object["expect"] != nil, !(object["expect"] is NSNull) else {
                unreadable[.noExpect, default: 0] += 1
                continue
            }
            guard let expect = expectation(object["expect"]) else { unreadable[.expectShape, default: 0] += 1; continue }
            questions.append(Question(table: table, row: row, column: text(object["column"]), expect: expect,
                                      edition: text(object["edition"])))
        }
        return (questions, unreadable)
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? String(Int(double)) : String(double)
        default:
            return nil
        }
    }

    private static func expectation(_ value: Any?) -> Expect? {
        if let cell = text(value) { return .cell(cell) }
        guard let object = value as? [String: Any] else { return nil }
        if let below = text(object["below"]), let above = text(object["above"]) { return .between(below: below, above: above) }
        if object["ask"] as? Bool == true {
            return .ask(candidates: (object["candidates"] as? [Any] ?? []).compactMap(text))
        }
        return nil
    }

    // MARK: - Scoring

    struct Report: Equatable {
        var questions = 0
        var unreadable = 0
        var tableRead = 0
        var tableUnread = 0
        var tableMissing = 0
        var tableAmbiguous = 0
        var rowResolved = 0
        var columnResolved = 0
        var cellsExpected = 0
        var cellsMatched = 0
        var betweenExpected = 0
        var betweenMatched = 0
        var askExpected = 0
        var askMatched = 0
        var askCandidatesAgree = 0
        /// The key's unread lines by why (`Unreadable`), when the runner counted them.
        var unreadableBy: [String: Int] = [:]
    }

    /// Each question looked up in `sources` — the books whose name holds the question's edition,
    /// when one does, else all of them.
    static func score(_ questions: [Question], unreadable: Int = 0, sources: [TableLookup.Source]) -> Report {
        scoreWithOutcomes(questions, unreadable: unreadable, sources: sources).report
    }

    /// The metrics a question's outcome carries, with the names the lines print. A question has the
    /// one its `expect` asks for: `cell` (the cell matched), `between` (the two rows matched) or
    /// `ask` (the lookup asked).
    static let metrics: [(name: String, key: String)] = [("cells", "cell"), ("between rows", "between"), ("asks", "ask")]

    /// `score`, with one outcome per question (1 matched, 0 not, under its `expect`'s metric), by
    /// the question's place and a hash of its fields, never the fields themselves.
    static func scoreWithOutcomes(_ questions: [Question], unreadable: Int = 0,
                                  sources: [TableLookup.Source]) -> (report: Report, outcomes: [EvalOutcome]) {
        var report = Report(questions: questions.count, unreadable: unreadable)
        var outcomes: [EvalOutcome] = []
        for (index, question) in questions.enumerated() {
            let before = (report.cellsMatched, report.betweenMatched, report.askMatched)
            defer {
                let metric: (String, Bool)
                switch question.expect {
                case .cell: metric = ("cell", report.cellsMatched > before.0)
                case .between: metric = ("between", report.betweenMatched > before.1)
                case .ask: metric = ("ask", report.askMatched > before.2)
                }
                outcomes.append(EvalOutcome(q: index + 1, h: EvalOutcomes.hash(identity(of: question)),
                                            metrics: [metric.0: metric.1 ? 1 : 0]))
            }
            let pool = question.edition.map { edition in
                sources.filter { $0.documentName.localizedCaseInsensitiveContains(edition) }
            }.flatMap { $0.isEmpty ? nil : $0 } ?? sources

            switch TableLookup.resolveTable(.init(table: question.table, row: question.row), in: pool) {
            case .success:
                report.tableRead += 1
            case .failure(let refusal):
                switch refusal.outcome {
                case .notExtracted: report.tableUnread += 1
                case .ambiguous: report.tableAmbiguous += 1
                default: report.tableMissing += 1
                }
                count(question.expect, in: &report)
                continue
            }

            // The column on its own (the row left empty, so only the column is read), the row on
            // its own, then the cell.
            switch TableLookup.resolve(.init(table: question.table, row: "", column: question.column), in: pool) {
            case .notFound(.column, _, _), .ambiguous(.column, _, _): break
            default: report.columnResolved += 1
            }
            if case .found(let row) = TableLookup.resolve(.init(table: question.table, row: question.row), in: pool),
               row.between == nil, row.rows.count == 1 {
                report.rowResolved += 1
            }
            let outcome = TableLookup.resolve(.init(table: question.table, row: question.row, column: question.column), in: pool)
            count(question.expect, in: &report)
            switch (question.expect, outcome) {
            case (.cell(let expected), .found(let found)):
                if found.between == nil, found.rows.count == 1, found.columns.count == 1,
                   found.columns[0] < found.rows[0].cells.count,
                   same(found.rows[0].cells[found.columns[0]].text, expected) {
                    report.cellsMatched += 1
                }
            case (.between(let below, let above), .found(let found)):
                if found.between != nil, found.rows.count == 2,
                   names(found.rows[0], found, below), names(found.rows[1], found, above) {
                    report.betweenMatched += 1
                }
            case (.ask(let candidates), .ambiguous(_, _, let offered)):
                report.askMatched += 1
                if !candidates.isEmpty, candidates.allSatisfy({ wanted in offered.contains { overlaps($0, wanted) } }) {
                    report.askCandidatesAgree += 1
                }
            default:
                break
            }
        }
        return (report, outcomes)
    }

    /// What makes a question the same question in another run: its fields, joined. Hashed, never
    /// printed or written.
    static func identity(of question: Question) -> String {
        let expect: String
        switch question.expect {
        case .cell(let cell): expect = "cell\u{1F}" + cell
        case .between(let below, let above): expect = "between\u{1F}" + below + "\u{1F}" + above
        case .ask(let candidates): expect = "ask\u{1F}" + candidates.joined(separator: "\u{1F}")
        }
        return [question.table, question.row, question.column ?? "", question.edition ?? "", expect].joined(separator: "\u{1E}")
    }

    /// The 95% bootstrap intervals of the matched shares over the questions of each kind: a line
    /// of rates only, printed apart from `render` so the counts there stay as they were.
    static func renderIntervals(_ outcomes: [EvalOutcome]) -> [String] {
        let line = EvalIntervals.intervalLine(prefix: "[CELLS]  ", metrics: metrics.map { metric in
            (metric.name, outcomes.compactMap { $0.metrics[metric.key] })
        })
        return line.map { [$0] } ?? []
    }

    private static func count(_ expect: Expect, in report: inout Report) {
        switch expect {
        case .cell: report.cellsExpected += 1
        case .between: report.betweenExpected += 1
        case .ask: report.askExpected += 1
        }
    }

    /// Two cell texts the same: as printed, ignoring case, spacing and the kind of dash or minus;
    /// or the same number.
    static func same(_ printed: String, _ expected: String) -> Bool {
        if key(printed) == key(expected) { return true }
        let a = TableExtractor.parseCell(printed, markers: [], columnUnit: nil)
        let b = TableExtractor.parseCell(expected, markers: [], columnUnit: nil)
        guard let x = a.value, let y = b.value else { return false }
        return x == y
    }

    /// A bracketing row named by the key: by a row header, the whole row path, or its cell in the
    /// column asked for.
    private static func names(_ row: ManualTable.Row, _ found: TableLookup.Found, _ expected: String) -> Bool {
        if row.path.contains(where: { same($0, expected) }) || same(row.path.joined(separator: " "), expected) { return true }
        return found.columns.count == 1 && found.columns[0] < row.cells.count && same(row.cells[found.columns[0]].text, expected)
    }

    private static func overlaps(_ offered: String, _ wanted: String) -> Bool {
        let a = key(offered), b = key(wanted)
        return !b.isEmpty && (a == b || a.contains(b) || b.contains(a))
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-").replacingOccurrences(of: "\u{203A}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Tables read from a picture (Plan JN P1)

    /// What the lookup gave where it matters most for a table read from a picture: a value given
    /// as certain that the key says is wrong. Counts only.
    struct PictureReport: Equatable {
        /// Questions whose table resolved to one read from a picture.
        var questions = 0
        /// Of those, the lookups that gave a row (or two either side of a number).
        var resolved = 0
        /// The lookups that gave no value because what they needed was read unclearly.
        var unclear = 0
        /// Cells the key expects on those tables, and the ones given that match it.
        var cellsExpected = 0
        var cellsMatched = 0
        /// A single cell given as certain that does not match the key: on a table read from a
        /// picture, and on any table.
        var wrongCertain = 0
        var wrongCertainAnywhere = 0
        /// Two rows either side of a number, given as certain, that are not the rows the key names.
        var wrongBetween = 0
    }

    /// Each question looked up as `score` looks it up, counted for the tables read from a picture.
    static func scorePictures(_ questions: [Question], sources: [TableLookup.Source]) -> PictureReport {
        var report = PictureReport()
        for question in questions {
            let pool = question.edition.map { edition in
                sources.filter { $0.documentName.localizedCaseInsensitiveContains(edition) }
            }.flatMap { $0.isEmpty ? nil : $0 } ?? sources
            guard case .success(let resolved) = TableLookup.resolveTable(.init(table: question.table, row: question.row), in: pool)
            else { continue }
            let pictured = resolved.source.table.source.isRecognised
            let outcome = TableLookup.resolve(.init(table: question.table, row: question.row, column: question.column), in: pool)
            if pictured {
                report.questions += 1
                if case .cell = question.expect { report.cellsExpected += 1 }
                switch outcome {
                case .found: report.resolved += 1
                case .unclear: report.unclear += 1
                default: break
                }
            }
            switch (question.expect, outcome) {
            case (.cell(let expected), .found(let found)):
                guard found.between == nil, found.rows.count == 1, found.columns.count == 1,
                      found.columns[0] < found.rows[0].cells.count else { break }
                if same(found.rows[0].cells[found.columns[0]].text, expected) {
                    if pictured { report.cellsMatched += 1 }
                } else {
                    report.wrongCertainAnywhere += 1
                    if pictured { report.wrongCertain += 1 }
                }
            case (.between(let below, let above), .found(let found)) where pictured:
                if found.between != nil, found.rows.count == 2,
                   !(names(found.rows[0], found, below) && names(found.rows[1], found, above)) {
                    report.wrongBetween += 1
                }
            default:
                break
            }
        }
        return report
    }

    /// The picture report as lines: counts only.
    static func renderPictures(_ report: PictureReport, label: String) -> [String] {
        [
            "[CELLS] \(label) on tables read from a picture: questions=\(report.questions) resolved=\(report.resolved) "
                + "unclear=\(report.unclear) cells expected=\(report.cellsExpected) matched=\(report.cellsMatched)",
            "[CELLS]   wrong certain cells: on a pictured table=\(report.wrongCertain) anywhere=\(report.wrongCertainAnywhere) "
                + "wrong between rows=\(report.wrongBetween)",
        ]
    }

    // MARK: - Output

    /// The report as lines: counts only, said to be against a key nobody has checked yet when it is.
    static func render(_ report: Report, label: String, checked: Bool = false) -> [String] {
        func share(_ part: Int, _ whole: Int) -> String { whole == 0 ? "-" : String(format: "%.2f", Double(part) / Double(whole)) }
        let against = checked ? "against the key" : "against the unchecked key"
        let why = Unreadable.allCases.compactMap { reason in report.unreadableBy[reason.rawValue].map { "\(reason.rawValue)=\($0)" } }
        return [
            "[CELLS] \(label) \(against): questions=\(report.questions) unreadable_lines=\(report.unreadable)"
                + (why.isEmpty ? "" : " (" + why.joined(separator: " ") + ")"),
            "[CELLS]   tables: read=\(report.tableRead) unread=\(report.tableUnread) missing=\(report.tableMissing) "
                + "ambiguous=\(report.tableAmbiguous)",
            "[CELLS]   on a read table: rows resolved=\(report.rowResolved) columns resolved=\(report.columnResolved)",
            "[CELLS]   cells: expected=\(report.cellsExpected) matched=\(report.cellsMatched) "
                + "(\(share(report.cellsMatched, report.cellsExpected)))",
            "[CELLS]   between rows: expected=\(report.betweenExpected) matched=\(report.betweenMatched)",
            "[CELLS]   asks: expected=\(report.askExpected) asked=\(report.askMatched) candidates_agree=\(report.askCandidatesAgree)",
        ]
    }
}
