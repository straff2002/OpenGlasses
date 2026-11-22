import Foundation

/// What the assistant is told to say about lots, doses given and waste (Plan MY §4, §5). Pure.
///
/// Every sentence is built from `wording`, so a clinical list hears "given", "doses", "wasted"
/// and "lot", and never a patient: nothing here takes or repeats who a dose was given to.
struct StockLotComposer {

    var wording: StockPlaceWording

    private var w: StockPlaceWording { wording }
    private func cap(_ phrase: String) -> String { StockPlaceWording.capitalised(phrase) }

    /// "lot ZZ1001 (expires 30 November 2027)".
    func lotPhrase(_ lot: StockLot) -> String {
        "\(w.lotNoun) \(lot.code)" + (lot.expiry.map { " (expires \($0.spoken))" } ?? "")
    }

    // MARK: - Read-backs

    func given(_ item: VanStockItem, quantity: StockQuantity, lot: StockLot?, after: VanStockLevel,
               older: StockLot?) -> String {
        var lines = ["\(cap(w.takenVerb)) \(w.amount(quantity, of: item))" + (lot.map { ", \(lotPhrase($0))" } ?? "") + "."]
        lines.append(left(item, lot: lot, after: after))
        if let older {
            lines.append("\(cap(item.name)) also has the older \(lotPhrase(older)) \(w.location); use that one first.")
        }
        return lines.joined(separator: " ")
    }

    func wasted(_ item: VanStockItem, quantity: StockQuantity, reason: VanStockMovement.WasteReason,
                lot: StockLot?, after: VanStockLevel) -> String {
        let lotText = lot.map { ", \(lotPhrase($0))" } ?? ""
        return "\(cap(w.wastedVerb)) \(w.amount(quantity, of: item))\(lotText), \(reason.spoken). "
            + left(item, lot: lot, after: after)
    }

    func received(_ item: VanStockItem, quantity: StockQuantity, lot: StockLot?, newLot: Bool,
                  after: VanStockLevel) -> String {
        var lines = ["\(cap(w.putVerb)) \(w.amount(quantity, of: item))" + (lot.map { ", \(lotPhrase($0))" } ?? "") + "."]
        if newLot, let lot { lines.append("\(cap(w.lotNoun)) \(lot.code) is new on \(w.list).") }
        lines.append("\(w.figure(after.onHand, of: item)) of \(item.name) \(w.location) now.")
        return lines.joined(separator: " ")
    }

    func lotCounted(_ item: VanStockItem, lot: StockLot, newLot: Bool, check: VanStockCountCheck?,
                    after: VanStockLevel) -> String {
        let counted = after.lots[lot.id]?.onHand ?? .zero
        var lines = ["Counted \(w.figure(counted, of: item)) of \(item.name) in \(lotPhrase(lot))."]
        switch check {
        case nil: break
        case .matches: lines.append("That matches what the log expected in that \(w.lotNoun).")
        case .short(let expected, let by):
            lines.append("The log expected \(w.figure(expected, of: item)) in that \(w.lotNoun), so it is \(w.figure(by, of: item)) short.")
        case .over(let expected, let by):
            lines.append("The log expected \(w.figure(expected, of: item)) in that \(w.lotNoun), so it is \(w.figure(by, of: item)) over.")
        case .unreliable:
            lines.append("The log's figure for that \(w.lotNoun) could not be trusted, so the count is the figure now.")
        }
        if newLot { lines.append("\(cap(w.lotNoun)) \(lot.code) is new on \(w.list).") }
        lines.append("\(w.figure(after.onHand, of: item)) of \(item.name) \(w.location) in all.")
        return lines.joined(separator: " ")
    }

    /// A line's lots in stock, oldest expiry first, for a check: "By lot, oldest expiry first:
    /// lot ZZ1001 (expires 30 November 2027), 4 doses; …". Expired and soon-expiring lots are
    /// said as such. Nil for a line with nothing in its lots.
    func lotsSummary(_ item: VanStockItem, lots: [StockLot], levels: [String: StockLotLevel], today: StockDay,
                     calendar: Calendar) -> String? {
        let inStock = StockExpiry.inStock(lots, levels: levels)
        guard !inStock.isEmpty else { return nil }
        let listed = inStock.map { lot -> String in
            var text = "\(w.lotNoun) \(lot.code)"
            if let expiry = lot.expiry {
                if StockExpiry.isExpired(lot, today: today) {
                    text += " (expired \(expiry.spoken): not to be given)"
                } else if StockExpiry.expiresSoon(lot, today: today, calendar: calendar) {
                    text += " (expires soon, \(expiry.spoken))"
                } else {
                    text += " (expires \(expiry.spoken))"
                }
            }
            return text + ", " + w.figure(levels[lot.id]?.onHand ?? .zero, of: item)
        }
        return "By \(w.lotNoun), oldest expiry first: " + listed.joined(separator: "; ") + "."
    }

    // MARK: - Refusals and questions

    /// More than one lot could be meant: listed oldest expiry first, to be asked about.
    func whichLot(_ item: VanStockItem, lots: [StockLot], levels: [String: StockLotLevel], today: StockDay) -> String {
        let listed = StockExpiry.oldestFirst(lots).enumerated().map { offset, lot -> String in
            let held = w.figure(levels[lot.id]?.onHand ?? .zero, of: item)
            let expiry = lot.expiry.map { StockExpiry.isExpired(lot, today: today) ? ", expired \($0.spoken)" : ", expires \($0.spoken)" } ?? ""
            return "\(offset + 1). \(w.lotNoun) \(lot.code)\(expiry), \(held)"
        }
        return "\(item.name) has \(lots.count) \(w.lotNoun)s \(w.location), oldest expiry first: "
            + listed.joined(separator: "; ") + ". Ask \(w.person) which \(w.lotNoun); do not choose for them. "
            + "Then call again with 'lot'. Nothing was recorded."
    }

    /// A lot the line does not hold. A spoken lot never adds one (Plan MY §1).
    func lotNotHeld(_ item: VanStockItem, said: String, lots: [StockLot]) -> String {
        let held = StockExpiry.oldestFirst(lots).map(\.code)
        let holds = held.isEmpty ? "it has no \(w.lotNoun)s on \(w.list) yet"
                                 : "it holds " + held.joined(separator: ", ")
        return "\(cap(w.lotNoun)) \(said) is not one of the \(w.lotNoun)s of \(item.name) (\(holds)). Nothing was recorded. "
            + "Ask \(w.person) to check the \(w.lotNoun) on the carton. A new \(w.lotNoun) comes onto \(w.list) when its "
            + "carton is scanned as it is received or counted, never from a spoken \(w.lotNoun)."
    }

    /// A scanned lot the line does not hold, on a dose given: it has to come in first.
    func newLotOnGiven(_ item: VanStockItem, code: String) -> String {
        "\(cap(w.lotNoun)) \(code) of \(item.name) is not on \(w.list) yet, so nothing was \(w.takenVerb) from it. "
            + "Receive or count it first (scan the carton and choose Received or Count). Nothing was recorded."
    }

    /// Plan MY §4, Decision 4: an expired lot is not given; the offer is to record it as wasted.
    func expiredOnGiven(_ item: VanStockItem, lot: StockLot) -> String {
        let when = lot.expiry.map { " expired on \($0.spoken)" } ?? " has expired"
        return "\(cap(w.lotNoun)) \(lot.code) of \(item.name)\(when). It has not been recorded as \(w.takenVerb). "
            + "Ask \(w.person) whether to record it as \(w.wastedVerb), expired; if they say yes, call again with "
            + "action 'waste', 'waste_reason' 'expired' and 'lot' '\(lot.code)'. Nothing was recorded."
    }

    /// A carton count asked for on a line that has no doses per carton yet.
    func noCartonSize(_ item: VanStockItem) -> String {
        "\(item.name) has no carton size yet. Ask \(w.person) how many \(w.goods) a carton holds, then call again "
            + "with 'doses_per_carton'. Nothing was recorded."
    }

    // MARK: - Pieces

    /// What is left of the line, and of the lot when there is one.
    private func left(_ item: VanStockItem, lot: StockLot?, after: VanStockLevel) -> String {
        if after.unreliable {
            return "The figure for \(item.name) cannot be trusted now: more went out than the log showed. "
                + "Ask \(w.person) to count it."
        }
        let total = w.figure(after.onHand, of: item)
        guard let lot, let lotLevel = after.lots[lot.id] else {
            return after.onHand == .zero ? "That was the last \(w.location)." : "\(total) left."
        }
        if after.onHand == .zero { return "That was the last \(w.location)." }
        return "\(total) left, \(w.figure(lotLevel.onHand, of: item)) of them in \(w.lotNoun) \(lot.code)."
    }

    /// The "Say:" line's part for a dose given: "1 dose of the flu vaccine given, lot ZZ1001".
    func givenDone(_ item: VanStockItem, quantity: StockQuantity, lot: StockLot?) -> String {
        "\(w.amount(quantity, of: item)) \(w.takenFrom)" + (lot.map { ", \(w.lotNoun) \($0.code)" } ?? "")
    }

    func wastedDone(_ item: VanStockItem, quantity: StockQuantity, reason: VanStockMovement.WasteReason,
                    lot: StockLot?) -> String {
        "\(w.amount(quantity, of: item)) \(w.wastedVerb) (\(reason.spoken))" + (lot.map { ", \(w.lotNoun) \($0.code)" } ?? "")
    }
}
