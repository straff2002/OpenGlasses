import Foundation

/// One claim as the EMR's billing export gives it, with nothing else (Plan NJ §4, MY Decision 13):
/// the day it was billed, the tariff, and the lot when the export has one. No field for anything
/// else; `BillingExportReaderTests` fails if one is added.
struct BillingRecord: Equatable, Sendable {
    let day: StockDay
    let tariff: String
    /// "" when the export has no lot column, or the cell is empty.
    let lot: String
}

/// Which columns of the billing export hold the date, the tariff and (optionally) the lot. Column
/// names only, never a value; held in memory for one check and not kept.
struct BillingColumnMapping: Equatable, Sendable {
    var date: String
    var tariff: String
    /// Nil when the export has no lot: the check is then by day and line only.
    var lot: String?
    var dateOrder: ImmunisationColumnMapping.DateOrder = .dayMonthYear
}

/// Reads the EMR's billing export and forgets it (Plan NJ §4). Pure over the file's bytes, beside
/// `ImmunisationListReader` and sharing its reading: the header row, then only the mapped columns.
/// Every other column (the patient, the claim number, the fee) is dropped as the file is read;
/// nothing is written, logged or kept, and no failure repeats a value from the file.
enum BillingExportReader {

    typealias Failure = ImmunisationListReader.Failure

    struct List: Equatable, Sendable {
        let records: [BillingRecord]
        /// Rows with no readable date, or no tariff. Counted, never shown.
        let skippedRows: Int
    }

    /// The header row's column names, for choosing the mapping. Only the first row is read.
    static func header(_ data: Data, format: ImmunisationListReader.Format) -> Result<[String], Failure> {
        ImmunisationListReader.header(data, format: format)
    }

    static func read(_ data: Data, format: ImmunisationListReader.Format,
                     mapping: BillingColumnMapping) -> Result<List, Failure> {
        let headerRow: [String]
        switch header(data, format: format) {
        case .failure(let failure): return .failure(failure)
        case .success(let names): headerRow = names
        }
        let keys = headerRow.map(ImmunisationListReader.columnKey)
        var columns: [Int] = []
        for name in [mapping.date, mapping.tariff] + (mapping.lot.map { [$0] } ?? []) {
            guard let found = keys.firstIndex(of: ImmunisationListReader.columnKey(name)) else {
                return .failure(.missingColumn(name))
            }
            columns.append(found)
        }
        switch ImmunisationListReader.rows(data, format: format, keeping: columns, headerOnly: false) {
        case .failure(let failure): return .failure(failure)
        case .success(let rows):
            return .success(records(fromKept: Array(rows.dropFirst()), hasLot: mapping.lot != nil,
                                    dateOrder: mapping.dateOrder))
        }
    }

    /// Rows already cut to [date, tariff] or [date, tariff, lot], header removed.
    static func records(fromKept rows: [[String]], hasLot: Bool,
                        dateOrder: ImmunisationColumnMapping.DateOrder) -> List {
        var records: [BillingRecord] = []
        var skipped = 0
        let width = hasLot ? 3 : 2
        for row in rows {
            guard row.count == width else { skipped += 1; continue }
            let tariff = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let lot = hasLot ? row[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !tariff.isEmpty, let day = ImmunisationListReader.day(row[0], order: dateOrder) else {
                if !row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { skipped += 1 }
                continue
            }
            records.append(BillingRecord(day: day, tariff: tariff, lot: lot))
        }
        return List(records: records, skippedRows: skipped)
    }
}

/// Which line a billed tariff means (Plan NJ §4). Pure.
///
/// The tariff is the line's number (Plan MY P3b), so no mapping step is needed. A tariff that more
/// than one line carries (a catch-all code, one tariff over several brands) is never assigned to
/// one of them: it is reported as billed under a shared code, for staff to sort out.
enum TariffLineLookup {

    enum Match: Equatable {
        case line(VanStockItem)
        /// Every line that carries the tariff, in list order.
        case shared([VanStockItem])
        case none
    }

    static func match(_ tariff: String, in items: [VanStockItem]) -> Match {
        let wanted = ImmunisationListReader.columnKey(tariff)
        guard !wanted.isEmpty else { return .none }
        let lines = items.filter { item in item.number.map { ImmunisationListReader.columnKey($0) == wanted } == true }
        switch lines.count {
        case 0: return .none
        case 1: return .line(lines[0])
        default: return .shared(lines)
        }
    }
}

/// The phone's doses given compared with what was billed, by day × line, and by lot when the
/// export has one (Plan NJ §4). Pure; the comparison is `ImmunisationReconciliation`'s.
struct BillingReconciliation: Equatable, Sendable {

    /// Claims under a tariff several lines carry, never assigned to any of them.
    struct SharedCode: Equatable, Sendable {
        let tariff: String
        let itemIDs: [String]
        let rows: Int
    }

    /// Findings by day × line (× lot when the export had lots). "Not in the EMR" reads as not
    /// billed here; `unmatchedVaccines` are the tariffs no line carries.
    let reconciliation: ImmunisationReconciliation
    let sharedCodes: [SharedCode]

    /// Compare `doses` with `records` over `first...last`. With `hasLot` false the doses' lots are
    /// set aside too, so the comparison is by day and line on both sides.
    static func compare(doses: [ImmunisationReconciliation.Dose], records: [BillingRecord], hasLot: Bool,
                        items: [VanStockItem], first: StockDay, last: StockDay,
                        calendar: Calendar) -> BillingReconciliation {
        var entries: [ImmunisationReconciliation.Entry] = []
        var unmatched: [String: Int] = [:]
        var shared: [String: (itemIDs: [String], rows: Int)] = [:]
        for record in records where first <= record.day && record.day <= last {
            switch TariffLineLookup.match(record.tariff, in: items) {
            case .line(let item):
                entries.append(.init(itemID: item.id, day: record.day, lot: hasLot ? record.lot : ""))
            case .shared(let lines):
                shared[record.tariff, default: (lines.map(\.id), 0)].rows += 1
            case .none:
                unmatched[record.tariff, default: 0] += 1
            }
        }
        // A dose of a line under a shared code cannot be told from its neighbours' on the bill, so
        // it is left out of the comparison rather than reported as not billed.
        let sharedLines = Set(shared.values.flatMap(\.itemIDs))
        let compared = doses.filter { !sharedLines.contains($0.itemID) }
            .map { hasLot ? $0 : ImmunisationReconciliation.Dose(itemID: $0.itemID, day: $0.day, lot: "", count: $0.count) }
        let result = ImmunisationReconciliation.compare(doses: compared, entries: entries, unmatched: unmatched,
                                                        items: items, first: first, last: last, calendar: calendar)
        let codes = shared.sorted { $0.key < $1.key }
            .map { SharedCode(tariff: $0.key, itemIDs: $0.value.itemIDs, rows: $0.value.rows) }
        return BillingReconciliation(reconciliation: result, sharedCodes: codes)
    }
}

/// The billing-export check, as the Stock screen runs it (Plan NJ §4). Gated on medical mode like
/// the check against the EMR, because the export in the person's hand carries patient details.
/// It keeps nothing: not the file, not its mapping, not a summary. Nothing stores a tariff on a
/// movement.
@MainActor
final class BillingCheckService {
    static let shared = BillingCheckService()

    enum Outcome: Equatable {
        case refused(String)
        case failed(String)
        case done(BillingReconciliation, skippedRows: Int)
    }

    static var medicalModeRefusal: String {
        String(localized: "The check against the billing export runs only while medical mode is on, because the export holds patient details. Turn on medical mode in Settings, then try again. Nothing was read.",
               comment: "Refusal of the billing export check outside medical mode.")
    }

    private let store: VanStockStore
    private let medicalMode: () -> Bool
    private let calendar: Calendar

    init(store: VanStockStore? = nil, medicalMode: @escaping () -> Bool = { Config.hipaaMode },
         calendar: Calendar = .current) {
        self.store = store ?? .shared
        self.medicalMode = medicalMode
        self.calendar = calendar
    }

    var isAllowed: Bool { medicalMode() }

    /// The export's column names, to choose the mapping from. Refused outside medical mode.
    func header(_ data: Data, format: ImmunisationListReader.Format) -> Result<[String], ImmunisationCheckRefusal> {
        guard medicalMode() else { return .failure(.init(sentence: Self.medicalModeRefusal)) }
        switch BillingExportReader.header(data, format: format) {
        case .success(let names): return .success(names)
        case .failure(let failure): return .failure(.init(sentence: failure.sentence))
        }
    }

    /// Read the export as mapped and compare it with the doses given here, over `range` or the
    /// days the export covers.
    func check(_ data: Data, format: ImmunisationListReader.Format, mapping: BillingColumnMapping,
               range: StockReportRange? = nil) -> Outcome {
        guard medicalMode() else { return .refused(Self.medicalModeRefusal) }
        guard !store.isUnreadable else {
            return .refused(String(localized: "The stock list on this phone can't be read. Nothing was checked."))
        }
        let list: BillingExportReader.List
        switch BillingExportReader.read(data, format: format, mapping: mapping) {
        case .failure(let failure): return .failed(failure.sentence)
        case .success(let read): list = read
        }
        let days = list.records.map(\.day)
        guard let first = range?.first ?? days.min(), let last = range?.last ?? days.max() else {
            return .failed(ImmunisationListReader.Failure.noRows.sentence)
        }
        let log = store.log
        let doses = ImmunisationReconciliation.doses(in: log, first: first, last: last, calendar: calendar)
        let result = BillingReconciliation.compare(doses: doses, records: list.records, hasLot: mapping.lot != nil,
                                                   items: log.items, first: first, last: last, calendar: calendar)
        return .done(result, skippedRows: list.skippedRows)
    }
}
