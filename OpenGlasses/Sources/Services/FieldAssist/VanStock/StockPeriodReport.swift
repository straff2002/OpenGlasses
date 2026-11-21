import Foundation

/// The span a stock report covers (Plan MY §7): today, this week, or any range of days. Pure.
///
/// A range is whole days in the caller's calendar, first and last day both included, so "this
/// week" on a Wednesday runs from the calendar's first weekday to today's week's last day.
struct StockReportRange: Equatable, Sendable {
    let first: StockDay
    let last: StockDay

    init(first: StockDay, last: StockDay) {
        self.first = min(first, last)
        self.last = max(first, last)
    }

    /// The day `now` falls on.
    static func today(now: Date, calendar: Calendar) -> StockReportRange {
        let day = StockDay(now, calendar: calendar)
        return StockReportRange(first: day, last: day)
    }

    /// The calendar week `now` falls in, from the calendar's first weekday.
    static func thisWeek(now: Date, calendar: Calendar) -> StockReportRange {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return today(now: now, calendar: calendar) }
        let first = StockDay(week.start, calendar: calendar)
        return StockReportRange(first: first, last: first.adding(days: 6, calendar: calendar))
    }

    /// Whether `date` falls on one of the range's days in `calendar`.
    func contains(_ date: Date, calendar: Calendar) -> Bool {
        let day = StockDay(date, calendar: calendar)
        return first <= day && day <= last
    }

    /// Whether `date` falls after the range's last day.
    func isAfter(_ date: Date, calendar: Calendar) -> Bool {
        StockDay(date, calendar: calendar) > last
    }

    /// "22 November 2026" or "16 November 2026 to 22 November 2026".
    var spoken: String { first == last ? first.spoken : "\(first.spoken) to \(last.spoken)" }
}

/// The latest check against the EMR (Plan MY §8), as a report repeats it: when it ran, the days it
/// covered and how many of each finding it gave. Counts only: no vaccine, lot, record or person,
/// so it can be kept without keeping anything from the file.
struct ImmunisationCheckSummary: Codable, Equatable, Sendable {
    let ranAt: Date
    let first: StockDay
    let last: StockDay
    let givenNotInEMR: Int
    let inEMRNotGiven: Int
    let differentLot: Int
    let nearby: Int
    /// EMR rows whose vaccine is not yet matched to a line.
    let unmatched: Int

    var differences: Int { givenNotInEMR + inEMRNotGiven + differentLot }

    enum CodingKeys: String, CodingKey {
        case ranAt = "ran_at"
        case first, last
        case givenNotInEMR = "given_not_in_emr"
        case inEMRNotGiven = "in_emr_not_given"
        case differentLot = "different_lot"
        case nearby, unmatched
    }

    private static let defaultsKey = "vaccineStockLastEMRCheck"

    /// The last summary kept on this phone, if a check ran.
    static func stored(_ defaults: UserDefaults = .standard) -> ImmunisationCheckSummary? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(ImmunisationCheckSummary.self, from: $0) }
    }

    func store(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// What a stock list did over a range of days, and what it holds at the end of it (Plan MY §7).
///
/// Pure over the log: the same log, range and today give the same report. Given, wasted (by
/// reason), received and removed are summed from the movements on the range's days; a reversed
/// movement counts nowhere, whenever it was reversed. On hand is the figure at the end of the
/// range's last day, or now for a range that runs to today. Count differences are each `counted`
/// movement on the range's days compared with what the log held just before it.
struct StockPeriodReport: Equatable, Sendable {

    struct LotLine: Equatable, Sendable {
        let lotID: String
        let code: String
        let expiry: StockDay?
        var given: StockQuantity = .zero
        var wasted: StockQuantity = .zero
        var received: StockQuantity = .zero
        var onHand: StockQuantity = .zero
    }

    struct Line: Equatable, Sendable {
        let item: VanStockItem
        var given: StockQuantity = .zero
        var wasted: [VanStockMovement.WasteReason: StockQuantity] = [:]
        var received: StockQuantity = .zero
        var removed: StockQuantity = .zero
        var onHand: StockQuantity = .zero
        /// The line's lots, oldest expiry first. Hidden empty lots with nothing on the range's days
        /// are left out.
        var lots: [LotLine] = []

        var wastedTotal: StockQuantity { wasted.values.reduce(.zero, +) }
        var hasActivity: Bool { given > .zero || wastedTotal > .zero || received > .zero || removed > .zero }
    }

    struct ExpiringLot: Equatable, Sendable {
        let item: VanStockItem
        let code: String
        let expiry: StockDay
        let onHand: StockQuantity
    }

    struct CountDifference: Equatable, Sendable {
        let item: VanStockItem
        /// The lot counted; nil for a line counted as a whole.
        let lotCode: String?
        let at: Date
        let counted: StockQuantity
        let check: VanStockCountCheck
    }

    let range: StockReportRange
    let clinical: Bool
    /// Every line with something on the range's days or something on hand, in list order.
    let lines: [Line]
    /// Lots with stock at the end of the range that expire within the clinic's window.
    let expiringSoon: [ExpiringLot]
    /// Lots with stock at the end of the range that have already expired.
    let expired: [ExpiringLot]
    /// How many counts were made on the range's days.
    let countsMade: Int
    /// The counts that did not match what the log expected.
    let countDifferences: [CountDifference]
    /// The latest check against the EMR, if one was run.
    let emrCheck: ImmunisationCheckSummary?

    // MARK: - Totals

    var given: StockQuantity { lines.reduce(.zero) { $0 + $1.given } }
    var received: StockQuantity { lines.reduce(.zero) { $0 + $1.received } }
    var wastedTotal: StockQuantity { lines.reduce(.zero) { $0 + $1.wastedTotal } }

    /// Every reason something was wasted for, in `WasteReason` order, with its total.
    var wastedByReason: [Wasted] {
        VanStockMovement.WasteReason.allCases.compactMap { reason in
            let total = lines.reduce(StockQuantity.zero) { $0 + ($1.wasted[reason] ?? .zero) }
            return total > .zero ? Wasted(reason: reason, quantity: total) : nil
        }
    }

    struct Wasted: Equatable, Sendable {
        let reason: VanStockMovement.WasteReason
        let quantity: StockQuantity
    }

    // MARK: - Building

    /// The report for `range`. `today` decides what has expired; `now` caps the end of the range.
    static func make(_ log: VanStockLog, range: StockReportRange, now: Date, calendar: Calendar,
                     clinical: Bool, expiringWithin days: Int = VaccineStockPolicy.expiringSoonDays,
                     emrCheck: ImmunisationCheckSummary? = nil) -> StockPeriodReport {
        let reversed = reversedIDs(log.movements)
        let live = log.movements.filter { !reversed.contains($0.id) && $0.kind != .reversed }
        let inRange = live.filter { range.contains($0.at, calendar: calendar) }

        // On hand as the range's last day ended (or now, for a range that has not ended).
        let upToEnd = live.filter { !range.isAfter($0.at, calendar: calendar) }
        let endLog = VanStockLog(items: log.items, movements: upToEnd, lots: log.lots)
        let levels = endLog.levels

        let today = StockDay(now, calendar: calendar)
        let asOfDay = min(today, range.last)

        var lines: [Line] = []
        for item in log.items {
            var line = Line(item: item)
            let level = levels[item.id] ?? VanStockLevel(itemID: item.id)
            line.onHand = level.onHand
            var lotLines: [String: LotLine] = [:]
            for lot in log.lots(of: item.id) {
                lotLines[lot.id] = LotLine(lotID: lot.id, code: lot.code, expiry: lot.expiry,
                                           onHand: level.lots[lot.id]?.onHand ?? .zero)
            }
            for movement in inRange where movement.itemID == item.id {
                let lotID = movement.lotID.flatMap { lotLines[$0] == nil ? nil : $0 }
                switch movement.kind {
                case .used:
                    line.given += movement.quantity
                    if let lotID { lotLines[lotID]?.given += movement.quantity }
                case .wasted:
                    line.wasted[movement.wasteReason ?? .other, default: .zero] += movement.quantity
                    if let lotID { lotLines[lotID]?.wasted += movement.quantity }
                case .loaded:
                    line.received += movement.quantity
                    if let lotID { lotLines[lotID]?.received += movement.quantity }
                case .removed:
                    line.removed += movement.quantity
                case .counted, .ordered, .edited, .reversed, .opening:
                    break
                }
            }
            let lots = StockExpiry.oldestFirst(log.lots(of: item.id))
            line.lots = lots.compactMap { lot -> LotLine? in
                guard let lotLine = lotLines[lot.id] else { return nil }
                let quiet = [lotLine.onHand, lotLine.given, lotLine.wasted, lotLine.received]
                    .allSatisfy { $0 == StockQuantity.zero }
                return lot.hidden == true && quiet ? nil : lotLine
            }
            if line.hasActivity || line.onHand > .zero || level.isRecorded { lines.append(line) }
        }

        var expiringSoon: [ExpiringLot] = []
        var expired: [ExpiringLot] = []
        for item in log.items {
            let lots = log.lots(of: item.id)
            let lotLevels = levels[item.id]?.lots ?? [:]
            for lot in StockExpiry.expiredInStock(lots, levels: lotLevels, today: asOfDay) {
                guard let expiry = lot.expiry else { continue }
                expired.append(ExpiringLot(item: item, code: lot.code, expiry: expiry,
                                           onHand: lotLevels[lot.id]?.onHand ?? .zero))
            }
            for lot in StockExpiry.expiringSoon(lots, levels: lotLevels, today: asOfDay, within: days, calendar: calendar) {
                guard let expiry = lot.expiry else { continue }
                expiringSoon.append(ExpiringLot(item: item, code: lot.code, expiry: expiry,
                                                onHand: lotLevels[lot.id]?.onHand ?? .zero))
            }
        }
        let byExpiry: (ExpiringLot, ExpiringLot) -> Bool = { lhs, rhs in
            lhs.expiry != rhs.expiry ? lhs.expiry < rhs.expiry : lhs.code < rhs.code
        }

        // Each count on the range's days, checked against the log just before it.
        var countsMade = 0
        var differences: [CountDifference] = []
        for (index, movement) in live.enumerated() where movement.kind == .counted
            && range.contains(movement.at, calendar: calendar) {
            guard let item = log.item(id: movement.itemID) else { continue }
            countsMade += 1
            let before = VanStockLog(items: log.items, movements: Array(live[..<index]), lots: log.lots)
                .level(of: item.id)
            let check: VanStockCountCheck?
            var lotCode: String?
            if let lotID = movement.lotID, let lot = log.lot(id: lotID) {
                lotCode = lot.code
                check = VanStockCountCheck(before: before.lots[lotID] ?? StockLotLevel(lotID: lotID),
                                           counted: movement.quantity)
            } else {
                check = VanStockCountCheck(before: before, counted: movement.quantity)
            }
            switch check {
            case .short?, .over?, .unreliable?:
                differences.append(CountDifference(item: item, lotCode: lotCode, at: movement.at,
                                                   counted: movement.quantity, check: check!))
            case .matches?, nil:
                break
            }
        }

        return StockPeriodReport(range: range, clinical: clinical, lines: lines,
                                 expiringSoon: expiringSoon.sorted(by: byExpiry),
                                 expired: expired.sorted(by: byExpiry),
                                 countsMade: countsMade, countDifferences: differences, emrCheck: emrCheck)
    }

    private static func reversedIDs(_ movements: [VanStockMovement]) -> Set<String> {
        Set(movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
    }

    // MARK: - The spoken summary

    /// One sentence (Plan MY §7): "From 16 November 2026 to 22 November 2026: 42 doses given,
    /// 3 wasted (2 expired, 1 cold chain), 60 received; 2 lots expire within 30 days; 1 count
    /// differed from the log." A figure is summed only over lines counted in each.
    func spokenSummary(expiringWithin days: Int = VaccineStockPolicy.expiringSoonDays) -> String {
        let w = StockPlaceWording(.stock, clinical: clinical)
        let each = lines.filter { $0.item.unit == .each }
        func total(_ value: (Line) -> StockQuantity) -> StockQuantity { each.reduce(.zero) { $0 + value($1) } }
        let given = total(\.given)
        let wasted = total(\.wastedTotal)
        let received = total(\.received)
        // "42 doses given" on a clinic's list; the later figures share its unit.
        var parts = [(clinical ? w.doses(given) : given.decimalString) + " \(w.takenVerb)"]
        var wastedText = "\(wasted.decimalString) \(w.wastedVerb)"
        let reasons = VanStockMovement.WasteReason.allCases.compactMap { reason -> String? in
            let sum = each.reduce(StockQuantity.zero) { $0 + ($1.wasted[reason] ?? .zero) }
            return sum > .zero ? "\(sum.decimalString) \(reason.spoken)" : nil
        }
        if !reasons.isEmpty { wastedText += " (" + reasons.joined(separator: ", ") + ")" }
        parts.append(wastedText)
        parts.append("\(received.decimalString) received")
        var sentence = "\(StockPlaceWording.capitalised(rangeLead)): " + parts.joined(separator: ", ")
        var tail: [String] = []
        if !expired.isEmpty {
            tail.append("\(expired.count) \(expired.count == 1 ? w.lotNoun : w.lotNoun + "s") \(w.location) "
                + "\(expired.count == 1 ? "has" : "have") expired")
        }
        tail.append(expiringSoon.isEmpty
            ? "no \(w.lotNoun)s expire within \(days) days"
            : "\(expiringSoon.count) \(expiringSoon.count == 1 ? w.lotNoun + " expires" : w.lotNoun + "s expire") within \(days) days")
        if countsMade == 0 {
            tail.append("no count was made")
        } else if countDifferences.isEmpty {
            tail.append(countsMade == 1 ? "the count matched the log" : "all \(countsMade) counts matched the log")
        } else {
            tail.append("\(countDifferences.count) of \(countsMade) \(countsMade == 1 ? "count" : "counts") "
                + "differed from the log")
        }
        if let emrCheck {
            tail.append(emrCheck.differences == 0
                ? "the last check against the EMR found no differences"
                : "the last check against the EMR found \(emrCheck.differences) "
                    + "\(emrCheck.differences == 1 ? "difference" : "differences") to look at")
        }
        sentence += "; " + tail.joined(separator: "; ") + "."
        return sentence
    }

    private var rangeLead: String {
        range.first == range.last ? "on \(range.first.spoken)" : "from \(range.first.spoken) to \(range.last.spoken)"
    }

    // MARK: - The spreadsheet

    /// "Stock report 2026-11-16 to 2026-11-22.xlsx". Titled as stock, never as a record of
    /// patients (Plan MY risks).
    var fileName: String {
        range.first == range.last ? "Stock report \(range.first).xlsx" : "Stock report \(range.first) to \(range.last).xlsx"
    }

    /// The workbook: a summary, the movements by line and lot, what is on hand with expiry, and
    /// the counts that differed. Every date is written as text ("2026-11-22").
    func workbook() -> XLSX.Workbook {
        let reasons = VanStockMovement.WasteReason.allCases
        var summary: [[XLSX.Cell]] = [[.text("Stock report"), .text(range.first == range.last
            ? range.first.description : "\(range.first) to \(range.last)")]]
        if clinical { summary.append([.text("This is a stock record, not the immunisation record."), .empty]) }
        summary.append([.text("Given"), .decimal(given)])
        for reason in reasons {
            let total = lines.reduce(StockQuantity.zero) { $0 + ($1.wasted[reason] ?? .zero) }
            summary.append([.text("Wasted: \(reason.spoken)"), .decimal(total)])
        }
        summary.append([.text("Received"), .decimal(received)])
        summary.append([.text("Counts made"), .number(countsMade)])
        summary.append([.text("Counts that differed"), .number(countDifferences.count)])
        summary.append([.text("Lots expiring soon"), .number(expiringSoon.count)])
        summary.append([.text("Lots expired in stock"), .number(expired.count)])
        if let emrCheck {
            summary.append([.text("Last check against the EMR"), .text("\(emrCheck.first) to \(emrCheck.last)")])
            summary.append([.text("Given here, not in the EMR on that day"), .number(emrCheck.givenNotInEMR)])
            summary.append([.text("In the EMR, not given here"), .number(emrCheck.inEMRNotGiven)])
            summary.append([.text("Same day, different lot"), .number(emrCheck.differentLot)])
            summary.append([.text("Nearby day"), .number(emrCheck.nearby)])
        }

        var movements: [[XLSX.Cell]] = [[.text("Line"), .text("Lot"), .text("Expiry"), .text("Given")]
            + reasons.map { XLSX.Cell.text("Wasted: \($0.spoken)") } + [.text("Received"), .text("Removed")]]
        for line in lines where line.hasActivity {
            movements.append([.text(line.item.name), .empty, .empty, .decimal(line.given)]
                + reasons.map { XLSX.Cell.decimal(line.wasted[$0] ?? .zero) } + [.decimal(line.received), .decimal(line.removed)])
            for lot in line.lots where lot.given > .zero || lot.wasted > .zero || lot.received > .zero {
                movements.append([.text(line.item.name), .text(lot.code), lot.expiry.map { XLSX.Cell.text($0.description) } ?? XLSX.Cell.empty,
                                  .decimal(lot.given)] + reasons.map { _ in XLSX.Cell.empty }
                    + [.decimal(lot.received), .empty])
            }
        }

        var onHand: [[XLSX.Cell]] = [[.text("Line"), .text("Unit"), .text("Lot"), .text("Expiry"), .text("On hand")]]
        for line in lines {
            onHand.append([.text(line.item.name), .text(line.item.unit.rawValue), .empty, .empty, .decimal(line.onHand)])
            for lot in line.lots {
                onHand.append([.text(line.item.name), .text(line.item.unit.rawValue), .text(lot.code),
                               lot.expiry.map { XLSX.Cell.text($0.description) } ?? XLSX.Cell.empty, .decimal(lot.onHand)])
            }
        }

        var counts: [[XLSX.Cell]] = [[.text("Line"), .text("Lot"), .text("Counted"), .text("Expected"), .text("Difference")]]
        for difference in countDifferences {
            let expected: XLSX.Cell
            let by: XLSX.Cell
            switch difference.check {
            case .short(let value, let gap): (expected, by) = (.decimal(value), .text("-" + gap.decimalString))
            case .over(let value, let gap): (expected, by) = (.decimal(value), .text("+" + gap.decimalString))
            case .matches(let value): (expected, by) = (.decimal(value), .text("0"))
            case .unreliable: (expected, by) = (.empty, .text("The log's figure could not be trusted"))
            }
            counts.append([.text(difference.item.name), difference.lotCode.map(XLSX.Cell.text) ?? .empty,
                           .decimal(difference.counted), expected, by])
        }

        return XLSX.Workbook(sheets: [
            XLSX.Sheet(name: "Summary", columns: [XLSX.Column(width: 44), XLSX.Column(width: 24)], rows: summary),
            XLSX.Sheet(name: "Given and wasted",
                       columns: [XLSX.Column(width: 32), XLSX.Column(width: 14, isText: true), XLSX.Column(width: 12)]
                           + Array(repeating: XLSX.Column(width: 12), count: reasons.count + 3),
                       rows: movements),
            XLSX.Sheet(name: "On hand",
                       columns: [XLSX.Column(width: 32), XLSX.Column(width: 10), XLSX.Column(width: 14, isText: true),
                                 XLSX.Column(width: 12), XLSX.Column(width: 12)],
                       rows: onHand),
            XLSX.Sheet(name: "Count differences",
                       columns: [XLSX.Column(width: 32), XLSX.Column(width: 14, isText: true), XLSX.Column(width: 12),
                                 XLSX.Column(width: 12), XLSX.Column(width: 30)],
                       rows: counts),
        ])
    }

    func spreadsheet(modified: Date) -> Data {
        XLSXWriter.data(for: workbook(), modified: modified)
    }
}
