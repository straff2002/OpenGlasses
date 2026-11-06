import Foundation
import UIKit

/// A calendar month, as statements and ledgers are kept (Plan KM P4): a year and a month, read in
/// one calendar. Pure.
struct CalendarMonth: Hashable, Comparable, Sendable, Identifiable {
    let year: Int
    let month: Int

    var id: String { String(format: "%04d-%02d", year, month) }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool { CalendarMonth(date, calendar: calendar) == self }

    static func < (lhs: CalendarMonth, rhs: CalendarMonth) -> Bool { (lhs.year, lhs.month) < (rhs.year, rhs.month) }

    /// "November 2026", in English: the statement's own language, like the work order's.
    var title: String {
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                     "October", "November", "December"]
        let name = (1...12).contains(month) ? names[month - 1] : "Month \(month)"
        return "\(name) \(year)"
    }
}

/// A table of minutes, written as CSV and as a PDF (Plan KM P4): the shape the organisation's
/// `ExpertStatement` and the expert's own `ExpertLedger` are both exported in.
///
/// **Neutral on purpose.** It knows titles, columns and rows of text and nothing of a job, a
/// session, a vault or a handover, so the expert's side can export its own ledger through it
/// without reaching any of the Field Assist report machinery (`AssistingIsolationTests`). Pure but
/// for `pdfData`, which draws.
struct MinutesTableDocument: Equatable, Sendable {
    let title: String
    /// Lines under the title: who it is for, the basis, the rate where there is one.
    let lede: [String]
    let columns: [String]
    let rows: [[String]]
    /// The total row, aligned with `columns`. Nil for none.
    let total: [String]?
    /// Printed after the table, and as the CSV's closing `Note` rows.
    let notes: [String]

    // MARK: - CSV

    /// Header, rows, the total, then one `Note` row per note. RFC 4180 quoting, and a cell that a
    /// spreadsheet would read as a formula is prefixed so it stays text.
    var csv: String {
        var lines = [columns.map(Self.cell).joined(separator: ",")]
        lines += rows.map { $0.map(Self.cell).joined(separator: ",") }
        if let total { lines.append(total.map(Self.cell).joined(separator: ",")) }
        lines += notes.map { ["Note", $0].map(Self.cell).joined(separator: ",") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    var csvData: Data { Data(csv.utf8) }

    static func cell(_ raw: String) -> String {
        var text = raw
        if let first = text.first, "=+@\t\r".contains(first) || (first == "-" && Double(text) == nil) {
            text = "'" + text
        }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - PDF

    /// One line per row — "Date: 7 Nov 2026 · Job: 4471 · Minutes: 34 …" — empty cells left out.
    func rowLine(_ row: [String]) -> String {
        zip(columns, row).filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "  ·  ")
    }

    func pdfData() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, as the work order
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title,
                               kCGPDFContextCreator as String: "Avenkin"]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let layout = PDFLayout(pageRect: pageRect, margin: 50)
        return renderer.pdfData { context in
            layout.begin(context)
            layout.heading(title)
            lede.forEach(layout.body)
            layout.section("Jobs")
            if rows.isEmpty { layout.body("None this month.") }
            rows.forEach { layout.body("• " + rowLine($0)) }
            if let total {
                layout.spacer(4)
                layout.body(rowLine(total))
            }
            if !notes.isEmpty {
                layout.spacer(6)
                notes.forEach(layout.caption)
            }
        }
    }

    // MARK: - Names

    /// "sam-okafor-2026-11": letters, digits and hyphens only, never longer than 60.
    static func fileStem(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "-").lowercased()
        let mapped = String(joined.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let collapsed = mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(60))
    }

    /// Whole minutes for a cell.
    static func minutes(_ value: Int?) -> String { value.map(String.init) ?? "" }

    /// "2026-11-07" in `calendar`'s zone: the CSV's date.
    static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
