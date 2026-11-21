import Foundation

/// The weekly count, lot by lot (Plan MY §6). Pure over the log.
///
/// One entry per lot of every line that has lots, oldest expiry first within the line, and one for
/// each line that has none. An empty lot stays in the round, to be counted at zero, until the
/// clinic hides it; a hidden lot comes back by itself once something is in it again.
enum StockCountRound {

    struct Entry: Equatable, Identifiable, Sendable {
        let item: VanStockItem
        let lot: StockLot?
        /// What the log holds now in the lot (or the line), and whether that is a figure to check
        /// the count against.
        let expected: StockQuantity
        let isKnown: Bool

        var id: String { lot.map { "lot-\($0.id)" } ?? "line-\(item.id)" }

        /// An empty lot may be hidden from the round.
        var mayHide: Bool { lot != nil && expected == .zero }
    }

    static func entries(_ log: VanStockLog) -> [Entry] {
        let levels = log.levels
        var entries: [Entry] = []
        for item in log.items {
            let level = levels[item.id] ?? VanStockLevel(itemID: item.id)
            let lots = log.lots(of: item.id)
            if lots.isEmpty {
                entries.append(Entry(item: item, lot: nil, expected: level.onHand,
                                     isKnown: level.isRecorded && !level.unreliable))
                continue
            }
            for lot in StockExpiry.oldestFirst(lots) {
                let held = level.lots[lot.id] ?? StockLotLevel(lotID: lot.id)
                if lot.hidden == true, held.onHand == .zero { continue }
                entries.append(Entry(item: item, lot: lot, expected: held.onHand,
                                     isKnown: held.isRecorded && !held.unreliable))
            }
        }
        return entries
    }

    /// One counted entry, and how it compared with the log.
    struct Result: Equatable, Sendable {
        let entry: Entry
        let counted: StockQuantity
        let check: VanStockCountCheck?
    }
}
