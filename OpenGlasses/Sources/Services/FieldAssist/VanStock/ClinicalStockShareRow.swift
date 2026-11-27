import Foundation

/// What a clinical stock list may say outside the phone (Plan NJ §1): the fridge, never a
/// patient. One row is a day (or, for a sensitive line, a week), a line, a lot, a kind of movement,
/// a quantity and, for waste, its reason. Pure.
///
/// The fields are an allow-list, held by `ClinicalStockShareRowTests`, which fails on any stored
/// property not named there: adding one is a decision, never an accident. There is no time, no
/// job reference, no staff code, no free text and no patient field, so none can be shared.
struct ClinicalStockShareRow: Equatable, Hashable, Sendable {

    /// What a row's quantity did.
    enum Kind: String, CaseIterable, Sendable {
        /// Doses in (a `loaded` movement).
        case received
        /// Doses given (a `used` movement).
        case given
        /// Doses thrown out, with a `WasteReason`.
        case wasted
        /// Sent back to where they came from (a removal for `returned`).
        case returned
        /// A count: the level found. A day's last count stands for that day.
        case counted
        /// Taken off for any other reason: damaged, lent, other.
        case adjusted
    }

    /// How much of the calendar the row covers: a day, or the week a sensitive line is shown by.
    enum Span: String, Sendable {
        case day
        case week
    }

    /// The day, or the first day of the week for a weekly row. Never a time.
    let day: StockDay
    let span: Span
    /// The line's identifier, so rows from two phones for the same line add up.
    let lineID: String
    /// The line's number: the tariff, where the clinic's list made it one.
    let lineNumber: String?
    let lineName: String
    let lotCode: String?
    let lotExpiry: StockDay?
    let kind: Kind
    /// Exact. A report or export prints it through `StockSmallCell`.
    let quantity: StockQuantity
    /// For `wasted` only. A closed list, so free text cannot be represented.
    let wasteReason: VanStockMovement.WasteReason?
}

/// Builds `ClinicalStockShareRow`s from the phone's own log (Plan NJ §2). Pure.
///
/// One row per day (or week) × line × lot × kind × reason, quantities summed; a count keeps the
/// day's last one. A reversed movement counts nowhere, and edits, orders, openings and reversals
/// are not stock moving, so they give no row. The phone's log keeps its minutes; nothing here does.
enum ClinicalStockShare {

    /// The rows for `log`, oldest first, over `range` (every day the log holds when nil).
    /// `sensitive` names the lines shown by the week; by default, the lines marked sensitive.
    static func rows(_ log: VanStockLog, calendar: Calendar, range: StockReportRange? = nil,
                     sensitive: Set<String>? = nil) -> [ClinicalStockShareRow] {
        let weekly = sensitive ?? Set(log.items.filter(\.isSensitive).map(\.id))
        let reversed = Set(log.movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
        let items = Dictionary(log.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lots = Dictionary(log.lots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        struct Key: Hashable {
            let day: StockDay
            let span: ClinicalStockShareRow.Span
            let lineID: String
            let lotID: String?
            let kind: ClinicalStockShareRow.Kind
            let reason: VanStockMovement.WasteReason?
        }
        var sums: [Key: StockQuantity] = [:]
        var order: [Key] = []

        for movement in log.movements where !reversed.contains(movement.id) {
            guard let item = items[movement.itemID], let kind = kind(of: movement) else { continue }
            let movedOn = StockDay(movement.at, calendar: calendar)
            if let range, !(range.first <= movedOn && movedOn <= range.last) { continue }
            let span: ClinicalStockShareRow.Span = weekly.contains(item.id) ? .week : .day
            let day = span == .week ? weekStart(of: movement.at, calendar: calendar) : movedOn
            let lotID = movement.lotID.flatMap { lots[$0] == nil ? nil : $0 }
            let key = Key(day: day, span: span, lineID: item.id, lotID: lotID, kind: kind,
                          reason: kind == .wasted ? (movement.wasteReason ?? .other) : nil)
            if sums[key] == nil { order.append(key) }
            // A day's counts are not added up: the last one stands, as the log's own fold reads it.
            sums[key] = kind == .counted ? movement.quantity : (sums[key] ?? .zero) + movement.quantity
        }

        let rows = order.map { key -> ClinicalStockShareRow in
            let item = items[key.lineID]
            let lot = key.lotID.flatMap { lots[$0] }
            return ClinicalStockShareRow(day: key.day, span: key.span, lineID: key.lineID, lineNumber: item?.number,
                                         lineName: item?.description.isEmpty == false ? item?.description ?? "" : item?.name ?? "",
                                         lotCode: lot?.code, lotExpiry: lot?.expiry, kind: key.kind,
                                         quantity: sums[key] ?? .zero, wasteReason: key.reason)
        }
        let position = Dictionary(log.items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            let (l, r) = (position[lhs.lineID] ?? .max, position[rhs.lineID] ?? .max)
            if l != r { return l < r }
            if (lhs.lotCode ?? "") != (rhs.lotCode ?? "") { return (lhs.lotCode ?? "") < (rhs.lotCode ?? "") }
            let kinds = ClinicalStockShareRow.Kind.allCases
            let (lk, rk) = (kinds.firstIndex(of: lhs.kind) ?? 0, kinds.firstIndex(of: rhs.kind) ?? 0)
            if lk != rk { return lk < rk }
            return (lhs.wasteReason?.rawValue ?? "") < (rhs.wasteReason?.rawValue ?? "")
        }
    }

    /// The row kind a movement gives, or nil for one that is not stock moving.
    static func kind(of movement: VanStockMovement) -> ClinicalStockShareRow.Kind? {
        switch movement.kind {
        case .loaded: return .received
        case .used: return .given
        case .wasted: return .wasted
        case .removed: return movement.reason == .returned ? .returned : .adjusted
        case .counted: return .counted
        case .ordered, .edited, .reversed, .opening: return nil
        }
    }

    /// The first day of the calendar week `date` falls in.
    static func weekStart(of date: Date, calendar: Calendar) -> StockDay {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return StockDay(date, calendar: calendar) }
        return StockDay(week.start, calendar: calendar)
    }

    // MARK: - As a sheet

    /// The sheet's heading row.
    static let headings = ["Day", "Period", "Line number", "Line", "Lot", "Expiry", "Kind", "Reason", "Quantity"]

    /// The rows as a workbook sheet, every date as text and every quantity through the small-cell
    /// rule (Plan NJ §6), so a figure from 1 to 4 reads "fewer than 5".
    static func sheet(_ rows: [ClinicalStockShareRow], name: String = "By day",
                      threshold: Int = VaccineStockPolicy.smallCellThreshold) -> XLSX.Sheet {
        var cells: [[XLSX.Cell]] = [headings.map { .text($0) }]
        for row in rows {
            cells.append([
                .text(row.day.description),
                .text(row.span == .week ? "Week" : "Day"),
                row.lineNumber.map(XLSX.Cell.text) ?? .empty,
                .text(row.lineName),
                row.lotCode.map(XLSX.Cell.text) ?? .empty,
                row.lotExpiry.map { XLSX.Cell.text($0.description) } ?? .empty,
                .text(row.kind.rawValue),
                row.wasteReason.map { XLSX.Cell.text($0.spoken) } ?? .empty,
                StockSmallCell.cell(row.quantity, kind: row.kind, threshold: threshold),
            ])
        }
        return XLSX.Sheet(name: name,
                          columns: [XLSX.Column(width: 12, isText: true), XLSX.Column(width: 8), XLSX.Column(width: 14, isText: true),
                                    XLSX.Column(width: 32), XLSX.Column(width: 14, isText: true), XLSX.Column(width: 12, isText: true),
                                    XLSX.Column(width: 10), XLSX.Column(width: 22), XLSX.Column(width: 14)],
                          rows: cells)
    }
}

/// The small-cell rule for a clinical list's reports and exports (Plan NJ §6, Decision 5). Pure.
///
/// A figure from 1 to `threshold - 1` prints as "fewer than 5": one rabies dose on one day says
/// who was bitten. Zero prints as zero, which identifies nobody. A count is a level, not a dose
/// event, and prints exactly. The phone's own Stock screen never goes through this.
enum StockSmallCell {

    /// Whether `quantity` is a small cell under `threshold`.
    static func isSmall(_ quantity: StockQuantity, threshold: Int = VaccineStockPolicy.smallCellThreshold) -> Bool {
        quantity > .zero && quantity < StockQuantity(whole: threshold)
    }

    /// "fewer than 5", in the app's language.
    static func fewerThan(_ threshold: Int = VaccineStockPolicy.smallCellThreshold) -> String {
        String(localized: "fewer than \(threshold)", comment: "A stock report figure too small to print exactly, so it cannot point to one patient.")
    }

    /// The figure as text: exact, or "fewer than 5".
    static func text(_ quantity: StockQuantity, threshold: Int = VaccineStockPolicy.smallCellThreshold) -> String {
        isSmall(quantity, threshold: threshold) ? fewerThan(threshold) : quantity.decimalString
    }

    /// The figure as a cell: a number, or the "fewer than" text.
    static func cell(_ quantity: StockQuantity, threshold: Int = VaccineStockPolicy.smallCellThreshold) -> XLSX.Cell {
        isSmall(quantity, threshold: threshold) ? .text(fewerThan(threshold)) : .decimal(quantity)
    }

    /// A row's figure: a count exactly, anything else by the rule.
    static func cell(_ quantity: StockQuantity, kind: ClinicalStockShareRow.Kind,
                     threshold: Int = VaccineStockPolicy.smallCellThreshold) -> XLSX.Cell {
        kind == .counted ? .decimal(quantity) : cell(quantity, threshold: threshold)
    }
}
