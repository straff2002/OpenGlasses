import Foundation

/// What the Stock screen's scan sheet does with a carton it read (Plan MY §5). Pure, so the
/// sheet, the tests and the tool agree on which line and lot a code means.
enum StockScanFlow {

    /// What a scan stands for on this list.
    enum Resolution: Equatable {
        /// A line on the list. `lot` is the line's lot the code names; nil when the code names no
        /// lot, or names one the line does not hold yet (`newLot` is then that code).
        case known(item: VanStockItem, lot: StockLot?, newLot: String?)
        /// Several lines carry this product number, as funded and private stock of one vaccine
        /// do (Decision 6), and the lot does not say which: ask once.
        case severalLines([VanStockItem])
        /// A product number not on the list: a new line, with its name and doses per carton.
        case newProduct
    }

    /// The line and lot `scan` means on `log`. The product number is matched against each line's
    /// codes in any form it may have been kept in; with several lines carrying it, the one holding
    /// the scanned lot is meant, and with none or several holding it the person is asked.
    static func resolve(_ scan: StockScan, in log: VanStockLog) -> Resolution {
        let forms = scan.gtin.map(StockScan.forms(of:)) ?? [scan.code]
        let lines = log.items.filter { item in item.codes.contains { forms.contains($0) } }
        guard !lines.isEmpty else { return .newProduct }
        let chosen: VanStockItem
        if lines.count == 1 {
            chosen = lines[0]
        } else {
            guard let code = scan.lot else { return .severalLines(lines) }
            let holding = lines.filter { item in log.lots(of: item.id).contains { $0.code == code } }
            guard holding.count == 1 else { return .severalLines(lines) }
            chosen = holding[0]
        }
        guard let code = scan.lot else { return .known(item: chosen, lot: nil, newLot: nil) }
        if let lot = log.lots(of: chosen.id).first(where: { $0.code == code }) {
            return .known(item: chosen, lot: lot, newLot: nil)
        }
        return .known(item: chosen, lot: nil, newLot: code)
    }

    /// The line `scan` means once the person has said which: picked among several sharing the
    /// product number, or chosen from the whole list for a code no line carries yet ("Which line
    /// is this?"). The lot is read as `resolve` reads it. Nil when the line is gone, or when the
    /// code is already on another line and not on this one (`linkConflict`).
    static func chosen(_ scan: StockScan, itemID: String, in log: VanStockLog) -> Resolution? {
        guard let item = log.item(id: itemID), linkConflict(scan, itemID: itemID, in: log) == nil else { return nil }
        guard let code = scan.lot else { return .known(item: item, lot: nil, newLot: nil) }
        let lot = log.lots(of: item.id).first { $0.code == code }
        return .known(item: item, lot: lot, newLot: lot == nil ? code : nil)
    }

    /// Link on first scan: a line imported from a clinic's list has its tariff and short forms but
    /// no product number, and the carton's code carries no name, so the first scan of its carton
    /// matches nothing. The person says which line it is, and recording the scan keeps the code
    /// on that line, in the form `resolve` matches (`StockScan.code`, the GTIN-14 for a GS1 code),
    /// so the next scan finds it. Whether the sheet offers the choice: a code no line carries, on a
    /// list that has lines to choose from.
    static func offersLink(_ resolution: Resolution, in log: VanStockLog) -> Bool {
        guard case .newProduct = resolution else { return false }
        return !log.items.isEmpty
    }

    /// The other line that already carries this code, when the chosen line does not: linking it
    /// there too would make one carton mean two lines, so it is refused. Nil when the chosen line
    /// carries it already (several lines sharing a product number, Decision 6) or no line does.
    static func linkConflict(_ scan: StockScan, itemID: String, in log: VanStockLog) -> VanStockItem? {
        let forms = scan.gtin.map(StockScan.forms(of:)) ?? [scan.code]
        let holders = log.items.filter { item in item.codes.contains { forms.contains($0) } }
        guard !holders.contains(where: { $0.id == itemID }) else { return nil }
        return holders.first
    }

    /// The four things a scanned carton can be (Plan MY §5). Given is the default.
    enum Action: Equatable, Hashable, Sendable {
        case given
        case wasted(VanStockMovement.WasteReason)
        case received
        case counted

        /// Whether this action may bring a lot onto the list: a delivery or a count, never a dose
        /// given (Plan MY §1).
        var addsALot: Bool {
            switch self {
            case .received, .counted: return true
            case .given, .wasted: return false
            }
        }
    }

    /// The actions a resolution allows, in the order the sheet offers them. A new product or a
    /// new lot comes in only on Received or Count; a dose from an expired lot is not given (it is
    /// offered as wasted · expired instead).
    static func allowed(_ resolution: Resolution, expiry: StockDay?, today: StockDay) -> [Action] {
        switch resolution {
        case .severalLines: return []
        case .newProduct: return [.received, .counted]
        case .known(_, let lot, let newLot):
            if newLot != nil { return [.received, .counted] }
            let expired = (lot?.expiry ?? expiry).map { $0 < today } ?? false
            if expired, VaccineStockPolicy.refusesExpiredGiven {
                return [.wasted(.expired), .received, .counted]
            }
            return [.given, .wasted(.other), .received, .counted]
        }
    }

    /// The action the sheet starts on: Given when it is allowed, otherwise the first allowed.
    static func defaultAction(_ allowed: [Action]) -> Action? {
        allowed.contains(.given) ? .given : allowed.first
    }
}

/// "Another one?" (Plan MY §5): the same code scanned again within ten seconds of being recorded
/// is asked about rather than recorded twice. Pure, with the time handed in.
struct StockScanRepeatGuard: Equatable, Sendable {
    var window: TimeInterval = VaccineStockPolicy.repeatScanWindow
    private(set) var last: Recorded?

    struct Recorded: Equatable, Sendable {
        let code: String
        let at: Date
    }

    init(window: TimeInterval = VaccineStockPolicy.repeatScanWindow) {
        self.window = window
    }

    /// Whether `code` at `at` is the last recorded code again, inside the window.
    func asksAgain(_ code: String, at: Date) -> Bool {
        guard let last, last.code == code else { return false }
        let gap = at.timeIntervalSince(last.at)
        return gap >= 0 && gap < window
    }

    /// Note that `code` was recorded at `at`.
    mutating func recorded(_ code: String, at: Date) {
        last = Recorded(code: code, at: at)
    }
}

/// The older lot in the fridge is pointed out once a day per line (Plan MY §4). Pure.
struct OldestFirstReminder: Equatable, Sendable {
    private(set) var said: [String: StockDay] = [:]

    /// True, once per line per day: the caller then says it.
    mutating func shouldSay(itemID: String, today: StockDay) -> Bool {
        guard VaccineStockPolicy.oldestFirstOncePerDay else { return true }
        guard said[itemID] != today else { return false }
        said[itemID] = today
        return true
    }
}
