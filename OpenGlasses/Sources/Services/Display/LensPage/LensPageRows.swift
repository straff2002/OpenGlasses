import Foundation

/// A page's table as text rows for the lens (Plan MU §6, decision 6: **Rows**, one press from the
/// whole page). Pure.
///
/// When the vault holds the table printed on the page (`ManualTable`, the same tables
/// `TableLookup` reads), each of the page's rows becomes one card: its values joined with " · "
/// ("E7 · Low supply voltage · Check the supply") and, under them in the meta style, the names of
/// the columns those values sit in ("Code · Fault · Action"). Nothing is lost to the lens's width,
/// and a press on a card says the row aloud.
///
/// **Which table.** Of the extracted tables with rows printed on the page: the one holding a row an
/// answer cited (its row passage, `TableRowPassage`), else the one the staged page names by label
/// ("Table 3"), else the first. A table whose values must be checked against the page before
/// they are given (`uncheckedWithheld`) offers no rows.
///
/// **What is shown.** The page's own rows of that table, in the order printed. As in a row
/// passage, nothing read unclearly from a picture is shown: a row whose key is uncertain is left
/// out, and so is an uncertain cell or a cell under an uncertain heading.
///
/// **The highlighted row** is the cited one, when an answer cited one. The rows view opens on it:
/// it is listed first, then the table's other rows in order (DAT focuses a button or the first
/// card, never a card further down, so the row the answer came from leads).
struct LensPageRows: Equatable {

    struct Row: Equatable {
        /// The row's heading as printed ("E7"): what "show E7" finds it by.
        let label: String
        /// The row's values joined: its headings, then its cells.
        let text: String
        /// The column names for those values, in the same order.
        let headings: String
        /// What a press says: "E7. Fault: Low supply voltage. Action: Check the supply."
        let spoken: String
    }

    /// "Table 3 (Fault codes)".
    let title: String
    let rows: [Row]
    /// The row an answer cited, when one was.
    let highlighted: Int?

    /// The rows in the order the view lists them: the highlighted row first, then the rest in order.
    var order: [Int] {
        guard let highlighted, rows.indices.contains(highlighted) else { return Array(rows.indices) }
        return [highlighted] + rows.indices.filter { $0 != highlighted }
    }

    /// The highlighted row's values, for the line under the whole page.
    var highlightedText: String? { highlighted.flatMap { rows.indices.contains($0) ? rows[$0].text : nil } }

    /// The row whose label is `spoken` ("e7", "E 7", "e-7"): letters and digits compared alone.
    func index(matching spoken: String) -> Int? {
        let wanted = Self.squeezed(spoken)
        guard !wanted.isEmpty else { return nil }
        return rows.firstIndex { Self.squeezed($0.label) == wanted }
    }

    static func squeezed(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    // MARK: - From the vault's tables

    /// The rows of the table printed on `page`, or nil when the vault holds none there.
    static func make(tables: [ManualTable], page: Int, cited: [CitedPassage] = [],
                     figure: String? = nil) -> LensPageRows? {
        let candidates = tables.filter { table in
            table.isExtracted && !table.uncheckedWithheld && !shownRows(of: table, page: page).isEmpty
        }
        guard !candidates.isEmpty else { return nil }
        let citedTexts = Set(cited.filter { !$0.anchor.printedRuns.isEmpty }.map(\.anchor.text))
        func citedRow(in table: ManualTable) -> ManualTable.Row? {
            shownRows(of: table, page: page).first { row in
                TableRowPassage.sentence(for: row, in: table).map(citedTexts.contains) ?? false
            }
        }
        let wantedLabel = figure?.trimmingCharacters(in: .whitespaces).lowercased()
        let table = candidates.first { citedRow(in: $0) != nil }
            ?? candidates.first { wantedLabel != nil && $0.label.lowercased() == wantedLabel }
            ?? candidates[0]
        let shown = shownRows(of: table, page: page)
        let highlightedRow = citedRow(in: table)
        let rows = shown.map { row(for: $0, in: table) }
        let highlighted = highlightedRow.flatMap { cited in shown.firstIndex(of: cited) }
        return LensPageRows(title: table.displayName, rows: rows, highlighted: highlighted)
    }

    /// The table's rows printed on `page` that have something certain to show.
    static func shownRows(of table: ManualTable, page: Int) -> [ManualTable.Row] {
        table.rows.filter { row in
            row.page.physical == page && !row.keyUncertain && !certainCells(of: row, in: table).isEmpty
        }
    }

    /// The row's cells that are shown: filled, and neither the cell nor its heading uncertain.
    static func certainCells(of row: ManualTable.Row, in table: ManualTable) -> [(column: String, text: String)] {
        row.cells.enumerated().compactMap { index, cell in
            guard !cell.isEmpty, !cell.uncertain else { return nil }
            let column = index < table.columns.count ? table.columns[index] : nil
            if column?.uncertain == true { return nil }
            return (column?.name ?? "", cell.text)
        }
    }

    static func row(for row: ManualTable.Row, in table: ManualTable) -> Row {
        let cells = certainCells(of: row, in: table)
        let label = row.path.joined(separator: " ")
        // The row's headings, each under its row-header column's name when the table prints one.
        let pathHeadings = row.path.indices.map { index in
            index < table.rowHeaders.count ? table.rowHeaders[index] : ""
        }
        let values = row.path + cells.map(\.text)
        let headings = (pathHeadings + cells.map(\.column)).map { $0.isEmpty ? "–" : $0 }
        let spokenCells = cells.map { $0.column.isEmpty ? "\($0.text)." : "\($0.column): \($0.text)." }
        let spoken = ([label.isEmpty ? nil : "\(label)."] + spokenCells.map { Optional($0) })
            .compactMap { $0 }
            .joined(separator: " ")
        return Row(label: label, text: values.joined(separator: " · "),
                   headings: headings.joined(separator: " · "), spoken: spoken)
    }
}
