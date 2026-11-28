import Foundation

/// The phone's doses given compared with the EMR's own list, per day × line × lot (Plan MY §8).
/// Pure, with the days handed in.
///
/// It says which counts differ, never which patient: neither side carries one. In order, for each
/// line: the same day and lot matches; a dose with no lot on either side matches a dose that day
/// with any lot; the same lot one day either side is "nearby", not missing, because an entry made
/// after midnight is common; the same day with a different lot is listed on its own, usually a
/// typo in one record; and what is left is either given here and not in the EMR on that day (the
/// likely missed claim) or in the EMR and not given here (a stock entry missed).
struct ImmunisationReconciliation: Equatable, Sendable {

    /// A dose the phone recorded as given.
    struct Dose: Equatable, Sendable {
        let itemID: String
        let day: StockDay
        /// The lot code as recorded, or "" for a dose recorded with no lot.
        let lot: String
        let count: Int
    }

    enum Finding: Equatable, Sendable {
        case givenNotInEMR(itemID: String, day: StockDay, lot: String, count: Int)
        case inEMRNotGiven(itemID: String, day: StockDay, lot: String, count: Int)
        case differentLot(itemID: String, day: StockDay, here: String, emr: String, count: Int)
        case nearby(itemID: String, here: StockDay, emr: StockDay, lot: String, count: Int)

        var itemID: String {
            switch self {
            case .givenNotInEMR(let id, _, _, _), .inEMRNotGiven(let id, _, _, _),
                 .differentLot(let id, _, _, _, _), .nearby(let id, _, _, _, _): return id
            }
        }

        var day: StockDay {
            switch self {
            case .givenNotInEMR(_, let day, _, _), .inEMRNotGiven(_, let day, _, _),
                 .differentLot(_, let day, _, _, _), .nearby(_, let day, _, _, _): return day
            }
        }

        var count: Int {
            switch self {
            case .givenNotInEMR(_, _, _, let n), .inEMRNotGiven(_, _, _, let n),
                 .differentLot(_, _, _, _, let n), .nearby(_, _, _, _, let n): return n
            }
        }

        fileprivate var order: Int {
            switch self {
            case .givenNotInEMR: return 0
            case .inEMRNotGiven: return 1
            case .differentLot: return 2
            case .nearby: return 3
            }
        }
    }

    let first: StockDay
    let last: StockDay
    let findings: [Finding]
    /// Doses found on both sides.
    let matched: Int
    /// The EMR's vaccine names that match no line, with how many rows each had. A name is a
    /// vaccine, never a person; it is shown so the person can match it to a line once.
    let unmatchedVaccines: [UnmatchedVaccine]

    struct UnmatchedVaccine: Equatable, Sendable {
        let vaccine: String
        let rows: Int
    }

    func count(_ kind: (Finding) -> Bool) -> Int { findings.filter(kind).reduce(0) { $0 + $1.count } }

    /// The counts only, to keep for the report.
    func summary(ranAt: Date) -> ImmunisationCheckSummary {
        ImmunisationCheckSummary(
            ranAt: ranAt, first: first, last: last,
            givenNotInEMR: count { if case .givenNotInEMR = $0 { return true } else { return false } },
            inEMRNotGiven: count { if case .inEMRNotGiven = $0 { return true } else { return false } },
            differentLot: count { if case .differentLot = $0 { return true } else { return false } },
            nearby: count { if case .nearby = $0 { return true } else { return false } },
            unmatched: unmatchedVaccines.reduce(0) { $0 + $1.rows })
    }

    // MARK: - From the log

    /// The doses given on `first...last` in `log`, by line, day and lot; a reversed dose counts
    /// nowhere. Only whole doses of lines counted in each are compared.
    static func doses(in log: VanStockLog, first: StockDay, last: StockDay, calendar: Calendar) -> [Dose] {
        let reversed = Set(log.movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
        var totals: [String: (itemID: String, day: StockDay, lot: String, count: Int)] = [:]
        for movement in log.movements where movement.kind == .used && !reversed.contains(movement.id) {
            guard let item = log.item(id: movement.itemID), item.unit == .each else { continue }
            let day = StockDay(movement.at, calendar: calendar)
            guard first <= day, day <= last else { continue }
            let whole = movement.quantity.scaled / StockQuantity.perUnit
            guard whole > 0 else { continue }
            let lot = movement.lotID.flatMap { log.lot(id: $0)?.code } ?? ""
            let key = "\(item.id)|\(day)|\(lot)"
            totals[key, default: (item.id, day, lot, 0)].count += whole
        }
        return totals.values.map { Dose(itemID: $0.itemID, day: $0.day, lot: $0.lot, count: $0.count) }
    }

    // MARK: - The comparison

    static func compare(doses: [Dose], records: [ImmunisationRecord], items: [VanStockItem],
                        first: StockDay, last: StockDay, calendar: Calendar) -> ImmunisationReconciliation {
        var entries: [Entry] = []
        var unmatched: [String: Int] = [:]
        for record in records where first <= record.day && record.day <= last {
            guard let item = ImmunisationLineAliases.line(for: record.vaccine, in: items) else {
                unmatched[record.vaccine, default: 0] += 1
                continue
            }
            entries.append(Entry(itemID: item.id, day: record.day, lot: record.lot))
        }
        return compare(doses: doses, entries: entries, unmatched: unmatched, items: items,
                       first: first, last: last, calendar: calendar)
    }

    /// One row of the other record, already matched to a line: an EMR immunisation, or a billed
    /// claim (Plan NJ §4). "" for a row with no lot.
    struct Entry: Equatable, Sendable {
        let itemID: String
        let day: StockDay
        let lot: String
    }

    /// The comparison over rows already matched to lines, with the names that matched none.
    static func compare(doses: [Dose], entries: [Entry], unmatched: [String: Int], items: [VanStockItem],
                        first: StockDay, last: StockDay, calendar: Calendar) -> ImmunisationReconciliation {
        struct Key: Hashable, Comparable {
            let day: StockDay
            let lot: String
            static func < (lhs: Key, rhs: Key) -> Bool { lhs.day != rhs.day ? lhs.day < rhs.day : lhs.lot < rhs.lot }
        }
        func lotKey(_ code: String) -> String { StockLotMatch.normalised(code) }

        var here: [String: [Key: Int]] = [:]
        var shownHere: [String: String] = [:]
        for dose in doses where first <= dose.day && dose.day <= last {
            here[dose.itemID, default: [:]][Key(day: dose.day, lot: lotKey(dose.lot)), default: 0] += dose.count
            shownHere[lotKey(dose.lot)] = shownHere[lotKey(dose.lot)] ?? dose.lot
        }
        var emr: [String: [Key: Int]] = [:]
        var shownEMR: [String: String] = [:]
        for entry in entries where first <= entry.day && entry.day <= last {
            emr[entry.itemID, default: [:]][Key(day: entry.day, lot: lotKey(entry.lot)), default: 0] += 1
            shownEMR[lotKey(entry.lot)] = shownEMR[lotKey(entry.lot)] ?? entry.lot
        }

        var findings: [Finding] = []
        var matched = 0
        let order = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lines = Set(here.keys).union(emr.keys).sorted { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) }

        for itemID in lines {
            var mine = here[itemID] ?? [:]
            var theirs = emr[itemID] ?? [:]
            func take(_ a: Key, _ b: Key) -> Int {
                let n = min(mine[a] ?? 0, theirs[b] ?? 0)
                guard n > 0 else { return 0 }
                mine[a, default: 0] -= n
                theirs[b, default: 0] -= n
                return n
            }
            // 1. Same day, same lot.
            for key in mine.keys.sorted() { matched += take(key, key) }
            // 2. No lot on one side: it matches that day's doses of any lot.
            for key in mine.keys.sorted() where (mine[key] ?? 0) > 0 {
                for other in theirs.keys.sorted() where other.day == key.day && (key.lot.isEmpty || other.lot.isEmpty) {
                    matched += take(key, other)
                }
            }
            // 3. The same lot one day either side: nearby, not missing.
            for key in mine.keys.sorted() where (mine[key] ?? 0) > 0 {
                for offset in [-1, 1] {
                    let other = Key(day: key.day.adding(days: offset, calendar: calendar), lot: key.lot)
                    let n = take(key, other)
                    if n > 0 {
                        findings.append(.nearby(itemID: itemID, here: key.day, emr: other.day,
                                                lot: shownHere[key.lot] ?? key.lot, count: n))
                    }
                }
            }
            // 4. The same day, a different lot.
            for key in mine.keys.sorted() where (mine[key] ?? 0) > 0 {
                for other in theirs.keys.sorted() where other.day == key.day && other.lot != key.lot {
                    let n = take(key, other)
                    if n > 0 {
                        findings.append(.differentLot(itemID: itemID, day: key.day, here: shownHere[key.lot] ?? key.lot,
                                                      emr: shownEMR[other.lot] ?? other.lot, count: n))
                    }
                }
            }
            // 5. What is left, on one side only.
            for key in mine.keys.sorted() where (mine[key] ?? 0) > 0 {
                findings.append(.givenNotInEMR(itemID: itemID, day: key.day, lot: shownHere[key.lot] ?? key.lot,
                                               count: mine[key] ?? 0))
            }
            for key in theirs.keys.sorted() where (theirs[key] ?? 0) > 0 {
                findings.append(.inEMRNotGiven(itemID: itemID, day: key.day, lot: shownEMR[key.lot] ?? key.lot,
                                               count: theirs[key] ?? 0))
            }
        }

        findings.sort { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            let (l, r) = (order[lhs.itemID] ?? .max, order[rhs.itemID] ?? .max)
            if l != r { return l < r }
            return lhs.order < rhs.order
        }
        let unmatchedList = unmatched.sorted { $0.key < $1.key }.map { UnmatchedVaccine(vaccine: $0.key, rows: $0.value) }
        return ImmunisationReconciliation(first: first, last: last, findings: findings, matched: matched,
                                          unmatchedVaccines: unmatchedList)
    }
}

/// The findings in words (Plan MY §8): which counts differ, on which day, of which vaccine and lot,
/// and never which patient. "Not in the EMR on that day" keeps a late entry a prompt to check, not
/// a verdict. Screen text, localised: the model never reads a check.
///
/// Each sentence is one whole string, so a translation can order its words, and opens with the
/// count: a catalog plural is chosen by the first argument.
struct ImmunisationFindingWording {
    let items: [VanStockItem]

    func sentence(_ finding: ImmunisationReconciliation.Finding) -> String {
        switch finding {
        case .givenNotInEMR(let itemID, let day, let lot, let count):
            let (line, on) = (line(itemID, lot: lot), StockScanText.day(day))
            return count == 1
                ? String(localized: "1 dose of \(line) given here on \(on) is not in the EMR on that day.")
                : String(localized: "\(count) doses of \(line) given here on \(on) are not in the EMR on that day.")
        case .inEMRNotGiven(let itemID, let day, let lot, let count):
            let (line, on) = (line(itemID, lot: lot), StockScanText.day(day))
            return count == 1
                ? String(localized: "1 dose of \(line) in the EMR on \(on) was not recorded as given here, so the stock figure may be high.")
                : String(localized: "\(count) doses of \(line) in the EMR on \(on) were not recorded as given here, so the stock figure may be high.")
        case .differentLot(let itemID, let day, let here, let emr, let count):
            let (line, on) = (StockCheckText.line(itemID, in: items), StockScanText.day(day))
            let (hereLot, emrLot) = (StockCheckText.lot(here), StockCheckText.lot(emr))
            return count == 1
                ? String(localized: "1 dose of \(line) on \(on) was recorded here from lot \(hereLot) and in the EMR from lot \(emrLot). One of the two records likely has a typo.")
                : String(localized: "\(count) doses of \(line) on \(on) were recorded here from lot \(hereLot) and in the EMR from lot \(emrLot). One of the two records likely has a typo.")
        case .nearby(let itemID, let here, let emr, let lot, let count):
            let line = line(itemID, lot: lot)
            let (given, entered) = (StockScanText.day(here), StockScanText.day(emr))
            return count == 1
                ? String(localized: "1 dose of \(line) given here on \(given) is in the EMR on \(entered): nearby, not missing.")
                : String(localized: "\(count) doses of \(line) given here on \(given) are in the EMR on \(entered): nearby, not missing.")
        }
    }

    /// "the flu vaccine from lot ZZ1001", or "the flu vaccine with no lot": the EMR's list always has lots.
    private func line(_ itemID: String, lot: String) -> String {
        let name = StockCheckText.line(itemID, in: items)
        return lot.isEmpty ? String(localized: "\(name) with no lot", comment: "A stock line's name, put into a sentence.") : StockCheckText.withLot(name, lot)
    }

    /// One sentence for the whole check.
    func summary(_ result: ImmunisationReconciliation) -> String {
        let s = result.summary(ranAt: Date(timeIntervalSince1970: 0))
        if s.differences == 0, s.nearby == 0 {
            let matched = StockCheckText.doses(result.matched)
            let first = StockScanText.day(result.first)
            guard result.first != result.last else {
                return String(localized: "On \(first), every dose given here matches the EMR (\(matched)).")
            }
            let last = StockScanText.day(result.last)
            return String(localized: "From \(first) to \(last), every dose given here matches the EMR (\(matched)).")
        }
        var parts: [String] = []
        if s.givenNotInEMR > 0 {
            let count = s.givenNotInEMR
            parts.append(count == 1 ? String(localized: "1 dose given here but not in the EMR that day")
                                    : String(localized: "\(count) doses given here but not in the EMR that day"))
        }
        if s.inEMRNotGiven > 0 {
            let count = s.inEMRNotGiven
            parts.append(count == 1 ? String(localized: "1 dose in the EMR but not recorded as given here")
                                    : String(localized: "\(count) doses in the EMR but not recorded as given here"))
        }
        if s.differentLot > 0 {
            let count = s.differentLot
            parts.append(count == 1 ? String(localized: "1 dose with a different lot")
                                    : String(localized: "\(count) doses with a different lot"))
        }
        if s.nearby > 0 {
            let count = s.nearby
            parts.append(count == 1 ? String(localized: "1 dose in the EMR on a nearby day")
                                    : String(localized: "\(count) doses in the EMR on a nearby day"))
        }
        return StockCheckText.differences(parts, from: result.first, to: result.last)
    }
}

/// What the two checks' sentences share (`ImmunisationFindingWording`, `BillingFindingWording`).
/// Screen text, localised.
enum StockCheckText {

    /// A line's name, put into a sentence.
    static func line(_ itemID: String, in items: [VanStockItem]) -> String {
        items.first { $0.id == itemID }?.name ?? String(localized: "a line no longer on the list")
    }

    /// "the flu vaccine from lot ZZ1001", put into a sentence, so it carries no comma to close.
    static func withLot(_ name: String, _ lot: String) -> String {
        String(localized: "\(name) from lot \(lot)", comment: "A stock line's name and lot, put into a sentence.")
    }

    /// A lot's code after the word "lot", for a record that may name none.
    static func lot(_ code: String) -> String {
        code.isEmpty ? String(localized: "(none)", comment: "In place of a lot number, after the word lot.") : code
    }

    static func doses(_ count: Int) -> String {
        count == 1 ? String(localized: "1 dose") : String(localized: "\(count) doses")
    }

    /// "From 22 Nov 2026 to 23 Nov 2026: 1 dose …, and 2 doses …." The list is joined as the
    /// phone's language joins one.
    static func differences(_ parts: [String], from first: StockDay, to last: StockDay) -> String {
        let list = parts.formatted(.list(type: .and))
        let start = StockScanText.day(first)
        guard first != last else { return String(localized: "On \(start): \(list).") }
        return String(localized: "From \(start) to \(StockScanText.day(last)): \(list).")
    }
}
