import Foundation

/// One immunisation as the EMR's list gives it, with nothing else (Plan MY §8): the day it was
/// given, the vaccine as the EMR names or codes it, and the lot. There is deliberately no field for
/// anything else in the row; `ImmunisationCheckPrivacyGuardTests` fails if one is added.
struct ImmunisationRecord: Equatable, Sendable {
    let day: StockDay
    let vaccine: String
    let lot: String
}

/// Which columns of the EMR's list hold the date, the vaccine and the lot, chosen once and
/// remembered (Plan MY §8). Column names only: never a value from the file.
struct ImmunisationColumnMapping: Codable, Equatable, Sendable {

    /// How the list writes a date that is not "2026-11-24" or a spreadsheet date.
    enum DateOrder: String, Codable, CaseIterable, Sendable {
        /// 24/11/2026.
        case dayMonthYear = "day_month_year"
        /// 11/24/2026.
        case monthDayYear = "month_day_year"
    }

    var date: String
    var vaccine: String
    var lot: String
    var dateOrder: DateOrder = .dayMonthYear

    enum CodingKeys: String, CodingKey {
        case date, vaccine, lot
        case dateOrder = "date_order"
    }

    private static let defaultsKey = "vaccineStockEMRColumns"

    static func stored(_ defaults: UserDefaults = .standard) -> ImmunisationColumnMapping? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(ImmunisationColumnMapping.self, from: $0) }
    }

    func store(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The remembered names, when the list's header still has all three.
    func fits(_ header: [String]) -> Bool {
        let names = Set(header.map(ImmunisationListReader.columnKey))
        return [date, vaccine, lot].allSatisfy { names.contains(ImmunisationListReader.columnKey($0)) }
    }
}

/// Reads the EMR's list of immunisations and forgets it (Plan MY §8). Pure over the file's bytes.
///
/// It reads only the header row and the three mapped columns. A CSV's other fields are skipped as
/// the file is parsed and never held; a workbook is unpacked whole by `XLSXReader`, and every
/// other column is dropped from each row before anything is returned. Nothing here writes, logs or
/// copies the file, and no failure ever repeats a value from it: a failure names a column the
/// person chose, or says how many rows could not be read.
enum ImmunisationListReader {

    enum Format: Equatable, Sendable {
        case spreadsheet
        case csv

        /// The format a file's name says, or nil for anything else.
        init?(fileName: String) {
            switch (fileName as NSString).pathExtension.lowercased() {
            case "xlsx": self = .spreadsheet
            case "csv", "txt": self = .csv
            default: return nil
            }
        }
    }

    enum Failure: Error, Equatable {
        case unreadable
        case tooLarge
        case noRows
        /// A mapped column the list's header does not have: the name the person chose.
        case missingColumn(String)

        /// A sentence that repeats nothing from the file.
        var sentence: String {
            switch self {
            case .unreadable: return "The list couldn't be read. Export it from the EMR again as a spreadsheet (.xlsx) or a CSV file."
            case .tooLarge: return "The list is too large to read on the phone. Export a shorter date range from the EMR."
            case .noRows: return "The list has no rows to check."
            case .missingColumn(let name): return "The list has no column called \"\(name)\". Choose its columns again."
            }
        }
    }

    struct List: Equatable, Sendable {
        let records: [ImmunisationRecord]
        /// Rows with no readable date, or no vaccine. Counted, never shown.
        let skippedRows: Int
    }

    // MARK: - The header

    /// The header row's column names, for choosing the mapping. Only the first row is read.
    static func header(_ data: Data, format: Format) -> Result<[String], Failure> {
        switch rows(data, format: format, keeping: nil, headerOnly: true) {
        case .failure(let failure): return .failure(failure)
        case .success(let rows):
            guard let first = rows.first else { return .failure(.noRows) }
            return .success(first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
    }

    // MARK: - The records

    static func read(_ data: Data, format: Format, mapping: ImmunisationColumnMapping) -> Result<List, Failure> {
        let headerRow: [String]
        switch header(data, format: format) {
        case .failure(let failure): return .failure(failure)
        case .success(let names): headerRow = names
        }
        let keys = headerRow.map(columnKey)
        func index(of name: String) -> Result<Int, Failure> {
            guard let found = keys.firstIndex(of: columnKey(name)) else { return .failure(.missingColumn(name)) }
            return .success(found)
        }
        var columns: [Int] = []
        for name in [mapping.date, mapping.vaccine, mapping.lot] {
            switch index(of: name) {
            case .success(let found): columns.append(found)
            case .failure(let failure): return .failure(failure)
            }
        }
        switch rows(data, format: format, keeping: columns, headerOnly: false) {
        case .failure(let failure): return .failure(failure)
        case .success(let rows):
            return .success(records(fromKept: Array(rows.dropFirst()), dateOrder: mapping.dateOrder))
        }
    }

    /// Rows already cut to [date, vaccine, lot], header removed.
    static func records(fromKept rows: [[String]], dateOrder: ImmunisationColumnMapping.DateOrder) -> List {
        var records: [ImmunisationRecord] = []
        var skipped = 0
        for row in rows {
            guard row.count == 3 else { skipped += 1; continue }
            let vaccine = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let lot = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !vaccine.isEmpty, let day = day(row[0], order: dateOrder) else {
                if !row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { skipped += 1 }
                continue
            }
            records.append(ImmunisationRecord(day: day, vaccine: vaccine, lot: lot))
        }
        return List(records: records, skippedRows: skipped)
    }

    /// The rows of the file. With `keeping`, every row is cut to those columns before it is
    /// returned (a CSV's other fields are never held at all).
    private static func rows(_ data: Data, format: Format, keeping: [Int]?, headerOnly: Bool) -> Result<[[String]], Failure> {
        switch format {
        case .csv:
            // The header is read whole (column names only); after it, only the kept columns.
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            guard data.count <= CSVReader.maximumFileBytes else { return .failure(.tooLarge) }
            guard var text else { return .failure(.unreadable) }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            if headerOnly {
                let firstLine = Self.firstRecord(of: text)
                switch CSVReader.read(firstLine) {
                case .success(let rows): return .success(Array(rows.prefix(1)))
                case .failure: return .failure(.unreadable)
                }
            }
            switch CSVReader.read(text, keeping: keeping) {
            case .success(let rows): return .success(rows)
            case .failure(.tooLarge), .failure(.tooManyRows): return .failure(.tooLarge)
            case .failure: return .failure(.unreadable)
            }
        case .spreadsheet:
            switch XLSXReader.read(data) {
            case .failure(.tooLarge), .failure(.tooManyRows): return .failure(.tooLarge)
            case .failure: return .failure(.unreadable)
            case .success(let sheets):
                guard let sheet = sheets.first(where: { !$0.isHidden && !$0.rows.isEmpty }) else { return .failure(.noRows) }
                if headerOnly { return .success(Array(sheet.rows.prefix(1))) }
                guard let keeping else { return .success(sheet.rows) }
                // Every other column goes here, before anything leaves this function.
                return .success(sheet.rows.map { row in keeping.map { row.indices.contains($0) ? row[$0] : "" } })
            }
        }
    }

    /// The CSV's first record, quotes respected, so a header is read without the rows under it.
    private static func firstRecord(of text: String) -> String {
        var inQuotes = false
        var end = text.endIndex
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes, character == "\n" || character == "\r" || character == "\r\n" {
                end = index
                break
            }
        }
        return String(text[..<end])
    }

    /// A column name as it is compared: case, spaces and punctuation forgiven.
    static func columnKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    // MARK: - Dates

    /// The day a cell names: "2026-11-24" (with or without a time after it), a day-month or
    /// month-day date with `/`, `.` or `-` ("24/11/2026", "24.11.26"), or a spreadsheet's date
    /// number (days since 30 December 1899). Nil for anything else.
    static func day(_ raw: String, order: ImmunisationColumnMapping.DateOrder) -> StockDay? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A spreadsheet date number, perhaps with a time as its fraction.
        if let serial = Double(text), serial >= 1, serial < 2_958_466 {
            return serialDay(Int(serial.rounded(.down)))
        }
        let datePart = text.split(whereSeparator: { $0 == " " || $0 == "T" }).first.map(String.init) ?? text
        let pieces = datePart.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == "-" }).map(String.init)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = Int(pieces[0]), let b = Int(pieces[1]), let c = Int(pieces[2]) else { return nil }
        if pieces[0].count == 4 { return StockDay(year: a, month: b, day: c) }
        let year = pieces[2].count == 2 ? 2000 + c : c
        guard pieces[2].count == 4 || pieces[2].count == 2 else { return nil }
        switch order {
        case .dayMonthYear: return StockDay(year: year, month: b, day: a)
        case .monthDayYear: return StockDay(year: year, month: a, day: b)
        }
    }

    /// A spreadsheet's date number as a day, counted from 30 December 1899 as spreadsheets do,
    /// which is right for every date after February 1900.
    static func serialDay(_ serial: Int) -> StockDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)),
              let date = calendar.date(byAdding: .day, value: serial, to: base) else { return nil }
        return StockDay(date, calendar: calendar)
    }
}

/// Which line an EMR's name or code for a vaccine means (Plan MY §8). Pure.
///
/// The EMR's words are kept as the line's aliases in `codes`, chosen once by the person or read
/// from the clinic's own list (its short forms and brand names). A name is matched against each
/// line's codes and number (a tariff code, when the list gave one), then its description, with
/// case, spaces and punctuation forgiven; it means a line only when exactly one line matches.
enum ImmunisationLineAliases {

    static func line(for vaccine: String, in items: [VanStockItem]) -> VanStockItem? {
        let wanted = ImmunisationListReader.columnKey(vaccine)
        guard !wanted.isEmpty else { return nil }
        let byCode = items.filter { item in
            item.codes.contains { ImmunisationListReader.columnKey($0) == wanted }
                || item.number.map { ImmunisationListReader.columnKey($0) == wanted } == true
        }
        if byCode.count == 1 { return byCode[0] }
        if byCode.count > 1 { return nil }
        let byName = items.filter { ImmunisationListReader.columnKey($0.description) == wanted }
        return byName.count == 1 ? byName[0] : nil
    }
}
