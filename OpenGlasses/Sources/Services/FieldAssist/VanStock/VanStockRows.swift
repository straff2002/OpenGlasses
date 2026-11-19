import Foundation

/// One line of the Van Stock screen (Plan IH §5): the line, its level, and what to mark on it.
struct VanStockRow: Identifiable, Equatable {
    let item: VanStockItem
    let level: VanStockLevel
    /// At or below its minimum, or recorded at zero with no minimum set.
    let isLow: Bool

    var id: String { item.id }
    /// The part number was looked for in a book and the book did not hold it (Plan MK §4). A
    /// number nothing was searched for carries no mark, so a store that names no book never sees
    /// one.
    var isNotFound: Bool { item.number != nil && item.verification.state == .notFound }

    /// The mark on a number its book did not hold: "Not found in Supplier catalogue", or "Not in
    /// the manuals" when the lookup did not record which book answered. Nil for every other line.
    var notFoundLabel: String? {
        guard isNotFound else { return nil }
        if let vault = item.verification.vault {
            return String(localized: "Not found in \(vault)")
        }
        return String(localized: "Not in the manuals")
    }

    /// "4", "10 m", or nil for a line nothing has been recorded against — an unknown is never
    /// shown as a number.
    var quantity: String? {
        guard level.isRecorded else { return nil }
        let figure = level.onHand.decimalString
        return item.unit == .each ? figure : "\(figure) \(item.unit.rawValue)"
    }
}

/// One entry of a line's history, with whether it has since been taken back.
struct VanStockHistoryEntry: Identifiable, Equatable {
    let movement: VanStockMovement
    let takenBack: Bool

    var id: String { movement.id }
}

/// What the Van Stock screen shows, worked out from the log (Plan IH §5). Pure.
enum VanStockRows {

    /// Every line, by name, narrowed to those whose description, number, bin or codes contain
    /// each word of the query.
    static func rows(_ log: VanStockLog, query: String = "") -> [VanStockRow] {
        let levels = log.levels
        let low = Set(log.lowItems.map(\.id))
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return log.items
            .filter { item in
                guard !words.isEmpty else { return true }
                let haystack = ([item.description, item.number ?? "", item.bin ?? ""] + item.codes)
                    .joined(separator: " ").lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            .map { VanStockRow(item: $0, level: levels[$0.id] ?? VanStockLevel(itemID: $0.id),
                               isLow: low.contains($0.id)) }
    }

    /// One line's movements, newest first. An undo is shown as a mark on what it took back, not
    /// as an entry of its own.
    static func history(_ log: VanStockLog, itemID: String) -> [VanStockHistoryEntry] {
        let reversed = Set(log.movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
        return log.movements
            .filter { $0.itemID == itemID && $0.kind != .reversed }
            .reversed()
            .map { VanStockHistoryEntry(movement: $0, takenBack: reversed.contains($0.id)) }
    }
}

extension StockQuantity {
    /// The figure in whole units, for the screen's whole-number labels and fields. Every figure
    /// on a line is whole until the screen takes measured amounts, which reads them with
    /// `formatted(locale:)` instead; until then this drops nothing.
    var wholeUnits: Int { scaled / Self.perUnit }
}
