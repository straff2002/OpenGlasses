import Foundation

// The clinic's workbook (Plan NK §1): two Excel tables in a workbook the clinic owns, in its own
// Microsoft 365. Every row that goes into them is a `ClinicalStockShareRow` (Plan NJ §1) and its
// row key, and nothing else: no staff, no time, no free text, no patient. Pure.

// MARK: - A share row on the queue

extension ClinicalStockShareRow.Kind: Codable {}
extension ClinicalStockShareRow.Span: Codable {}

/// A share row as the offline queue keeps it. The quantity is written as signed thousandths, so a
/// correction (a row with the opposite quantity, Plan NK §2) survives a relaunch like any other.
extension ClinicalStockShareRow: Codable {

    enum CodingKeys: String, CodingKey {
        case day, span, lineID, lineNumber, lineName, lotCode, lotExpiry, kind, quantity, wasteReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scaled = try container.decode(Int.self, forKey: .quantity)
        guard abs(scaled) <= StockQuantity.maximumScaled else {
            throw DecodingError.dataCorruptedError(forKey: .quantity, in: container,
                                                   debugDescription: "a quantity out of range")
        }
        self.init(day: try container.decode(StockDay.self, forKey: .day),
                  span: try container.decode(Span.self, forKey: .span),
                  lineID: try container.decode(String.self, forKey: .lineID),
                  lineNumber: try container.decodeIfPresent(String.self, forKey: .lineNumber),
                  lineName: try container.decode(String.self, forKey: .lineName),
                  lotCode: try container.decodeIfPresent(String.self, forKey: .lotCode),
                  lotExpiry: try container.decodeIfPresent(StockDay.self, forKey: .lotExpiry),
                  kind: try container.decode(Kind.self, forKey: .kind),
                  quantity: StockQuantity(scaled: scaled),
                  wasteReason: try container.decodeIfPresent(VanStockMovement.WasteReason.self, forKey: .wasteReason))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(span, forKey: .span)
        try container.encode(lineID, forKey: .lineID)
        try container.encodeIfPresent(lineNumber, forKey: .lineNumber)
        try container.encode(lineName, forKey: .lineName)
        try container.encodeIfPresent(lotCode, forKey: .lotCode)
        try container.encodeIfPresent(lotExpiry, forKey: .lotExpiry)
        try container.encode(kind, forKey: .kind)
        try container.encode(quantity.scaled, forKey: .quantity)
        try container.encodeIfPresent(wasteReason, forKey: .wasteReason)
    }

    /// The same row with another quantity: a top-up, or a correction.
    func with(quantity: StockQuantity) -> ClinicalStockShareRow {
        ClinicalStockShareRow(day: day, span: span, lineID: lineID, lineNumber: lineNumber, lineName: lineName,
                              lotCode: lotCode, lotExpiry: lotExpiry, kind: kind, quantity: quantity,
                              wasteReason: wasteReason)
    }
}

/// One row on its way to the workbook: the share row and the key that makes it once only. The
/// whole of what the route carries (`ClinicStockRouteGuardTests` holds it to these two fields).
struct KeyedShareRow: Codable, Equatable, Hashable, Sendable {
    let row: ClinicalStockShareRow
    let key: String
}

// MARK: - The two tables

/// The workbook's two tables. Their names, their columns and the order of the columns are fixed.
enum ClinicalStockWorkbookTable: String, CaseIterable, Codable, Sendable {
    case movements = "Movements"
    case counts = "Counts"

    /// The heading row, in column order.
    var headers: [String] {
        switch self {
        case .movements:
            return ["Day", "Span", "Line number", "Line", "Lot", "Expiry", "Kind", "Quantity", "Reason", "Row key"]
        case .counts:
            return ["Day", "Line number", "Line", "Lot", "Counted", "Row key"]
        }
    }

    /// The heading row's cells on the table's own sheet, "A1:J1".
    var headerAddress: String {
        let last = Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(headers.count - 1)))
        return "A1:\(last)1"
    }

    /// The table a row goes into: a count into `Counts`, everything else into `Movements`.
    static func of(_ row: ClinicalStockShareRow) -> ClinicalStockWorkbookTable {
        row.kind == .counted ? .counts : .movements
    }
}

/// A cell as it goes to the workbook through Graph: text, a number, or nothing.
enum ClinicalStockWorkbookCell: Equatable, Sendable {
    case text(String)
    case number(StockQuantity)
    case empty

    /// The cell as a JSON value for Graph's `values`. Text goes with a leading apostrophe, which
    /// Excel keeps as text: a lot "1E5" or a line number "0123" is never turned into a number or a
    /// day into a date. A number goes as an exact decimal. [P3 confirms the apostrophe on a tenant.]
    var json: Any {
        switch self {
        case .text(let text): return "'" + text
        case .number(let quantity): return NSDecimalNumber(string: quantity.decimalString)
        case .empty: return ""
        }
    }
}

enum ClinicalStockWorkbookSchema {

    /// "Day" or "Week", as the NJ sheets say it.
    static func spanText(_ span: ClinicalStockShareRow.Span) -> String { span == .week ? "Week" : "Day" }

    /// A keyed row's cells, in its table's column order.
    static func cells(_ keyed: KeyedShareRow) -> [ClinicalStockWorkbookCell] {
        let row = keyed.row
        let number = row.lineNumber.map(ClinicalStockWorkbookCell.text) ?? .empty
        let lot = row.lotCode.map(ClinicalStockWorkbookCell.text) ?? .empty
        switch ClinicalStockWorkbookTable.of(row) {
        case .movements:
            return [.text(row.day.description), .text(spanText(row.span)), number, .text(row.lineName), lot,
                    row.lotExpiry.map { .text($0.description) } ?? .empty, .text(row.kind.rawValue),
                    .number(row.quantity), row.wasteReason.map { .text($0.spoken) } ?? .empty, .text(keyed.key)]
        case .counts:
            return [.text(row.day.description), number, .text(row.lineName), lot, .number(row.quantity),
                    .text(keyed.key)]
        }
    }
}

// MARK: - Reading the tables back

/// One row read back from either table, whoever added it: a phone, or a member of staff by hand.
struct ClinicalStockWorkbookEntry: Equatable, Sendable {
    let table: ClinicalStockWorkbookTable
    let day: StockDay
    let span: ClinicalStockShareRow.Span
    let lineNumber: String?
    let lineName: String
    let lotCode: String?
    let kind: ClinicalStockShareRow.Kind
    /// Signed: a correction is negative. A count is the level found.
    let quantity: StockQuantity
    let wasteReason: VanStockMovement.WasteReason?
    let key: String?
    /// Where the row stands in its table, for "a day's last count stands".
    let position: Int

    var line: ClinicalStockLineIdentity { ClinicalStockLineIdentity(number: lineNumber, name: lineName) }
}

/// Why a table was not read.
enum ClinicalStockWorkbookRefusal: Error, Equatable, Sendable {
    /// A heading reads like a patient's details (staff can add columns by hand). The whole table is
    /// refused, never stripped quietly.
    case patientColumns([String])
    /// A column the app reads is missing or renamed.
    case missingColumns([String])

    var sentence: String {
        switch self {
        case .patientColumns(let names):
            let named = names.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            return String(localized: "The clinic's workbook wasn't read, because a table has a column that may hold patient details (\(named)). The stock tables take vaccines, lots and quantities only. Remove that column in the workbook, then try again.",
                          comment: "Refusal when the clinic's stock workbook has a column named like a patient's details.")
        case .missingColumns(let names):
            let named = names.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            return String(localized: "The clinic's workbook wasn't read, because a stock table is missing a column (\(named)). Put the column back with its name, then try again.",
                          comment: "Refusal when a column the app reads is missing from the clinic's stock workbook.")
        }
    }
}

extension ClinicalStockWorkbookSchema {

    /// What a table's rows read as: the rows understood, and how many were not.
    struct Read: Equatable, Sendable {
        var entries: [ClinicalStockWorkbookEntry]
        var skipped: Int
    }

    /// Read a table's rows by its headings. Refuses a table with a patient-like heading, or one
    /// missing a column the app reads; ignores any other column staff added. A row that does not
    /// read (no day, no line, no figure, an unknown kind) is counted and left out.
    static func read(_ table: ClinicalStockWorkbookTable, headers: [String], rows: [[Any]],
                     firstPosition: Int = 0) -> Result<Read, ClinicalStockWorkbookRefusal> {
        let patient = ClinicalStockInboundGuard.patientFields(headers)
        if !patient.isEmpty { return .failure(.patientColumns(patient)) }
        let index = Dictionary(headers.enumerated().map { (normalised($1), $0) }, uniquingKeysWith: { first, _ in first })
        let missing = table.headers.filter { index[normalised($0)] == nil }
        if !missing.isEmpty { return .failure(.missingColumns(missing)) }

        func cell(_ row: [Any], _ heading: String) -> Any? {
            guard let at = index[normalised(heading)], at < row.count else { return nil }
            return row[at]
        }

        var read = Read(entries: [], skipped: 0)
        for (offset, row) in rows.enumerated() {
            let position = firstPosition + offset
            guard let day = self.day(cell(row, "Day")),
                  let name = text(cell(row, "Line")) ?? text(cell(row, "Line number")),
                  let quantity = self.quantity(cell(row, table == .counts ? "Counted" : "Quantity")) else {
                if !row.allSatisfy({ text($0) == nil }) { read.skipped += 1 }
                continue
            }
            let kind: ClinicalStockShareRow.Kind
            let span: ClinicalStockShareRow.Span
            var reason: VanStockMovement.WasteReason?
            switch table {
            case .counts:
                kind = .counted
                span = .day
            case .movements:
                guard let raw = text(cell(row, "Kind")),
                      let found = ClinicalStockShareRow.Kind.allCases.first(where: { $0.rawValue == raw.lowercased() }),
                      found != .counted else {
                    read.skipped += 1
                    continue
                }
                kind = found
                span = text(cell(row, "Span"))?.lowercased() == "week" ? .week : .day
                if kind == .wasted {
                    let said = text(cell(row, "Reason"))?.lowercased()
                    reason = VanStockMovement.WasteReason.allCases.first { $0.rawValue == said || $0.spoken.lowercased() == said } ?? .other
                }
            }
            guard table == .movements || quantity >= .zero else {
                read.skipped += 1
                continue
            }
            read.entries.append(ClinicalStockWorkbookEntry(
                table: table, day: day, span: span, lineNumber: text(cell(row, "Line number")), lineName: name,
                lotCode: text(cell(row, "Lot")), kind: kind, quantity: quantity, wasteReason: reason,
                key: text(cell(row, "Row key")), position: position))
        }
        return .success(read)
    }

    static func normalised(_ heading: String) -> String {
        heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A cell's text: trimmed, a leading apostrophe dropped, nil when empty.
    static func text(_ value: Any?) -> String? {
        let raw: String
        switch value {
        case let string as String: raw = string
        case let number as NSNumber:
            // Excel hands back a number for a cell that looks like one.
            raw = number.stringValue
        default: return nil
        }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("'") { trimmed.removeFirst() }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A day: "2026-11-27", or the serial number Excel keeps a date as.
    static func day(_ value: Any?) -> StockDay? {
        if let number = value as? NSNumber, !(value is String) {
            let serial = number.doubleValue
            guard serial >= 1, serial < 2_958_466, serial == serial.rounded(.down) else { return nil }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            guard let epoch = utc.date(from: DateComponents(year: 1899, month: 12, day: 30)),
                  let date = utc.date(byAdding: .day, value: Int(serial), to: epoch) else { return nil }
            return StockDay(date, calendar: utc)
        }
        return text(value).flatMap { StockDay(iso: $0) }
    }

    /// A figure, signed, exact to the thousandth: a JSON number, or the text of one.
    static func quantity(_ value: Any?) -> StockQuantity? {
        if let number = value as? NSNumber, !(value is String) {
            let scaled = (number.doubleValue * Double(StockQuantity.perUnit)).rounded()
            guard scaled.isFinite, abs(scaled) <= Double(StockQuantity.maximumScaled) else { return nil }
            return StockQuantity(scaled: Int(scaled))
        }
        guard var said = text(value) else { return nil }
        let negative = said.hasPrefix("-")
        if negative { said.removeFirst() }
        guard case .success(let quantity) = StockQuantity.parse(said, unit: .m) else { return nil }
        return negative ? StockQuantity(scaled: -quantity.scaled) : quantity
    }
}
