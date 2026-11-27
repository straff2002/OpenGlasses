import Foundation

/// Which line a figure is about, across phones (Plan NK §2). A line's id is each phone's own, so
/// rows from two phones are matched by the line's number (the tariff, where the clinic's list made
/// it one) or, without one, by its name. Pure.
struct ClinicalStockLineIdentity: Hashable, Comparable, Sendable {
    let value: String

    init(number: String?, name: String) {
        let normalised = number.map(VaultPartsIndex.normalise) ?? ""
        value = normalised.isEmpty
            ? "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : "number:" + normalised
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// One line's figure: its total and what is in each lot, by lot code.
struct ClinicalStockFigure: Equatable, Sendable {
    var name: String
    var onHand: StockQuantity = .zero
    var lots: [String: StockQuantity] = [:]
}

/// Folds the workbook's rows into the fridge's figures with the phone's own ledger semantics
/// (`VanStockLog.levels`), so the workbook needs no formulas (Plan NK §1). Pure.
///
/// Days in order. On each day:
/// 1. **Movements.** Received adds; given, wasted, returned and adjusted take away, summed for the
///    day (a correction is a negative row). A lot's change moves the lot and the line together; a
///    change with no lot moves the line only. Nothing goes below zero, as on the phone. Rows from
///    every phone and every member of staff add up, in whatever order the table holds them.
/// 2. **Counts.** A day's last count of a lot (last in the table) sets the lot and moves the line
///    by the difference; a count with no lot sets the line. **A count stands for the end of its
///    day:** a dose given after the count on the same day is in the record, but the day closes at
///    the figure counted. The phone knows the minute and the workbook does not, so on that one day
///    the two can differ, and the "differs" line says so.
enum ClinicalStockWorkbookFold {

    static func fold(_ entries: [ClinicalStockWorkbookEntry]) -> [ClinicalStockLineIdentity: ClinicalStockFigure] {
        var figures: [ClinicalStockLineIdentity: ClinicalStockFigure] = [:]
        let days = Dictionary(grouping: entries, by: \.day)
        for day in days.keys.sorted() {
            let rows = days[day] ?? []
            // The day's movements as one net change per lot and one for the line itself, so the
            // order rows sit in the table (which is not the order things happened) cannot matter.
            var lotChanges: [ClinicalStockLineIdentity: [String: StockQuantity]] = [:]
            var lineChanges: [ClinicalStockLineIdentity: StockQuantity] = [:]
            var names: [ClinicalStockLineIdentity: String] = [:]
            for entry in rows where entry.table == .movements {
                let change = entry.kind == .received ? entry.quantity : StockQuantity(scaled: -entry.quantity.scaled)
                names[entry.line] = names[entry.line] ?? entry.lineName
                if let lot = entry.lotCode {
                    lotChanges[entry.line, default: [:]][lot, default: .zero] += change
                } else {
                    lineChanges[entry.line, default: .zero] += change
                }
            }
            for line in Set(lotChanges.keys).union(lineChanges.keys) {
                var figure = figures[line] ?? ClinicalStockFigure(name: names[line] ?? "")
                var moved = lineChanges[line] ?? .zero
                for (lot, change) in lotChanges[line] ?? [:] {
                    let before = figure.lots[lot] ?? .zero
                    let after = clamped(before + change)
                    figure.lots[lot] = after
                    moved += after - before
                }
                figure.onHand = clamped(figure.onHand + moved)
                figures[line] = figure
            }
            // The day's last count of each line and lot, in table order.
            var counts: [String: ClinicalStockWorkbookEntry] = [:]
            for entry in rows where entry.table == .counts {
                let key = entry.line.value + "|" + (entry.lotCode ?? "")
                if counts[key].map({ $0.position < entry.position }) ?? true { counts[key] = entry }
            }
            // Lots first, then a count of the whole line, which has the last word.
            for entry in counts.values.sorted(by: { ($0.lotCode == nil ? 1 : 0, $0.position) < ($1.lotCode == nil ? 1 : 0, $1.position) }) {
                var figure = figures[entry.line] ?? ClinicalStockFigure(name: entry.lineName)
                if let lot = entry.lotCode {
                    let before = figure.lots[lot] ?? .zero
                    figure.lots[lot] = entry.quantity
                    figure.onHand = clamped(figure.onHand + (entry.quantity - before))
                } else {
                    figure.onHand = entry.quantity
                }
                figures[entry.line] = figure
            }
        }
        return figures
    }

    /// The phone's own figures, keyed the same way: its ledger's levels, by line and lot code.
    static func own(_ log: VanStockLog) -> [ClinicalStockLineIdentity: ClinicalStockFigure] {
        let levels = log.levels
        var figures: [ClinicalStockLineIdentity: ClinicalStockFigure] = [:]
        for item in log.items {
            let level = levels[item.id] ?? VanStockLevel(itemID: item.id)
            var figure = ClinicalStockFigure(name: item.name, onHand: level.onHand)
            for lot in log.lots(of: item.id) {
                if let held = level.lots[lot.id]?.onHand { figure.lots[lot.code] = held }
            }
            figures[ClinicalStockLineIdentity(number: item.number, name: item.name)] = figure
        }
        return figures
    }

    private static func clamped(_ quantity: StockQuantity) -> StockQuantity { max(quantity, .zero) }
}

/// The clinic's shared figure beside the phone's own (Plan NK §2): "matches" or "differs by N",
/// per line and lot. It never changes either one. Pure.
struct ClinicalStockComparison: Equatable, Sendable {

    enum Verdict: Equatable, Sendable {
        case matches
        /// The workbook's figure less the phone's: positive when the workbook shows more.
        case differs(by: StockQuantity)
        /// The workbook has nothing for this line yet.
        case notShared
    }

    struct Lot: Equatable, Sendable, Identifiable {
        let code: String
        let own: StockQuantity?
        let shared: StockQuantity?
        let verdict: Verdict
        var id: String { code }
    }

    struct Line: Equatable, Sendable, Identifiable {
        let identity: ClinicalStockLineIdentity
        let name: String
        let own: StockQuantity?
        let shared: StockQuantity?
        let verdict: Verdict
        let lots: [Lot]
        var id: String { identity.value }
    }

    let lines: [Line]

    /// How many lines differ, a line differing in any of its lots included.
    var differing: Int {
        lines.filter { line in
            if case .differs = line.verdict { return true }
            return line.lots.contains { if case .differs = $0.verdict { return true } else { return false } }
        }.count
    }

    static func verdict(own: StockQuantity?, shared: StockQuantity?) -> Verdict {
        guard let shared else { return .notShared }
        let mine = own ?? .zero
        return shared == mine ? .matches : .differs(by: shared - mine)
    }

    /// Every line either side has, the phone's lines first in their own order of names.
    static func compare(shared: [ClinicalStockLineIdentity: ClinicalStockFigure],
                        own: [ClinicalStockLineIdentity: ClinicalStockFigure]) -> ClinicalStockComparison {
        let identities = Set(shared.keys).union(own.keys).sorted { lhs, rhs in
            let (l, r) = ((own[lhs] ?? shared[lhs])?.name ?? "", (own[rhs] ?? shared[rhs])?.name ?? "")
            return l.localizedStandardCompare(r) == .orderedAscending || (l == r && lhs < rhs)
        }
        let lines = identities.map { identity -> Line in
            let mine = own[identity]
            let theirs = shared[identity]
            let codes = Set(mine?.lots.keys.map { $0 } ?? []).union(theirs?.lots.keys.map { $0 } ?? []).sorted()
            let lots = codes.map { code in
                Lot(code: code, own: mine?.lots[code], shared: theirs?.lots[code],
                    verdict: theirs == nil ? .notShared : verdict(own: mine?.lots[code], shared: theirs?.lots[code] ?? .zero))
            }
            return Line(identity: identity, name: mine?.name ?? theirs?.name ?? "", own: mine?.onHand,
                        shared: theirs?.onHand, verdict: verdict(own: mine?.onHand, shared: theirs?.onHand), lots: lots)
        }
        return ClinicalStockComparison(lines: lines)
    }

    /// The "differs" line for one figure, in the app's language: nil when it matches.
    static func sentence(_ verdict: Verdict) -> String? {
        switch verdict {
        case .matches: return nil
        case .notShared:
            return String(localized: "Not in the clinic's workbook yet.",
                          comment: "A stock line the clinic's shared workbook has no rows for yet.")
        case .differs(let by):
            let amount = StockQuantity(scaled: abs(by.scaled)).decimalString
            return by > .zero
                ? String(localized: "The clinic's workbook shows \(amount) more.",
                         comment: "The shared stock figure is higher than this phone's own by the amount.")
                : String(localized: "The clinic's workbook shows \(amount) fewer.",
                         comment: "The shared stock figure is lower than this phone's own by the amount.")
        }
    }
}
