import Foundation

/// Reads the rows of a CSV file (RFC 4180), the format many records systems export (Plan MY §8).
///
/// Pure and bounded like `XLSXReader`: quoted fields, doubled quotes inside them, line breaks inside
/// quotes, CRLF or LF, and a leading byte-order mark. The separator is a comma, or a semicolon or a
/// tab when the first line has more of those outside quotes (as some locales export). Nothing in
/// the file is interpreted: every field is the text it holds.
///
/// `keeping` names the only columns to keep; every other field is skipped as it is read and never
/// stored, so a caller that wants three columns of a wide file never holds the rest.
enum CSVReader {

    enum Failure: Error, Equatable {
        case notText
        case tooLarge
        case tooManyRows
        case unterminatedQuote
    }

    static let maximumFileBytes = 2 * 1_024 * 1_024
    /// Data rows, not counting the header.
    static let maximumRows = 5_000
    static let maximumColumns = 64

    /// Every row, each as far as its last field. With `keeping`, a row holds only those columns,
    /// in index order, and a missing one is an empty string.
    static func read(_ data: Data, keeping columns: [Int]? = nil) -> Result<[[String]], Failure> {
        guard data.count <= maximumFileBytes else { return .failure(.tooLarge) }
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            return .failure(.notText)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return read(text, keeping: columns)
    }

    static func read(_ text: String, keeping columns: [Int]? = nil) -> Result<[[String]], Failure> {
        let separator = self.separator(of: text)
        let wanted = columns.map(Set.init)
        var rows: [[String]] = []
        var row: [Int: String] = [:]
        var field = ""
        var column = 0
        var inQuotes = false
        var fieldStarted = false
        var rowHasContent = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        func keep(_ index: Int) -> Bool { wanted?.contains(index) ?? true }

        func endField() {
            if keep(column), column < maximumColumns { row[column] = field }
            if !field.isEmpty { rowHasContent = true }
            field = ""
            column += 1
            fieldStarted = false
        }

        func endRow() -> Bool {
            endField()
            defer {
                row = [:]
                column = 0
                rowHasContent = false
            }
            guard rowHasContent else { return true }
            if let columns {
                rows.append(columns.map { row[$0] ?? "" })
            } else {
                let width = (row.keys.max() ?? -1) + 1
                rows.append((0..<width).map { row[$0] ?? "" })
            }
            return rows.count <= maximumRows + 1
        }

        while let scalar = pending ?? scalars.next() {
            pending = nil
            if inQuotes {
                if scalar == "\"" {
                    let next = scalars.next()
                    if next == "\"" {
                        field.unicodeScalars.append("\"")
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where !fieldStarted && field.isEmpty:
                inQuotes = true
                fieldStarted = true
            case separator:
                endField()
            case "\r":
                let next = scalars.next()
                if next != "\n" { pending = next }
                guard endRow() else { return .failure(.tooManyRows) }
            case "\n":
                guard endRow() else { return .failure(.tooManyRows) }
            default:
                field.unicodeScalars.append(scalar)
                fieldStarted = true
            }
        }
        if inQuotes { return .failure(.unterminatedQuote) }
        guard endRow() else { return .failure(.tooManyRows) }
        return .success(rows)
    }

    /// A comma, unless the first line has more semicolons or tabs outside quotes.
    static func separator(of text: String) -> Unicode.Scalar {
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for scalar in text.unicodeScalars {
            if scalar == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if scalar == "\n" || scalar == "\r" { break }
            if counts[scalar] != nil { counts[scalar, default: 0] += 1 }
        }
        let comma = counts[","] ?? 0
        let semicolon = counts[";"] ?? 0
        let tab = counts["\t"] ?? 0
        if tab > comma && tab >= semicolon { return "\t" }
        if semicolon > comma { return ";" }
        return ","
    }
}
