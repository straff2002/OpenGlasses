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

    /// "4", "10 m", "4,25 l" in German, or nil for a line nothing has been recorded against — an
    /// unknown is never shown as a number.
    var quantity: String? { quantity(locale: .current) }

    func quantity(locale: Locale) -> String? {
        guard level.isRecorded else { return nil }
        return VanStockRow.figure(level.onHand, unit: item.unit, locale: locale)
    }

    /// A figure as the screen shows it: the locale's form and the unit's symbol, never a converted
    /// unit. Each is the bare number. "4", "4,25 l", "1,000 m".
    static func figure(_ quantity: StockQuantity, unit: VanStockUnit, locale: Locale = .current) -> String {
        let figure = quantity.formatted(locale: locale)
        return unit == .each ? figure : "\(figure) \(unit.rawValue)"
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

/// What a figure typed on a line's page means (Plan ML §4). Pure.
///
/// A measured unit is typed into a decimal field in the phone's locale ("4,25" in German, "4.25"
/// in English) and read exactly, as the tool reads the model's figure; `each` and `pack` keep the
/// whole-number stepper. A figure the line's unit cannot hold is refused, never rounded.
enum VanStockEntry {

    /// A figure as a field holds it: the locale's decimal separator, no grouping and no trailing
    /// zeros, so what is shown reads back as the same figure. "4,25" in German, "1000.5" in English.
    static func text(_ quantity: StockQuantity, locale: Locale) -> String {
        let plain = quantity.decimalString
        guard let separator = locale.decimalSeparator, separator != "." else { return plain }
        return plain.replacingOccurrences(of: ".", with: separator)
    }

    /// A typed figure, read exactly in `unit`.
    static func read(_ text: String, unit: VanStockUnit, locale: Locale) -> Result<StockQuantity, StockQuantityRefusal> {
        StockQuantity.parse(localized: text, locale: locale, unit: unit)
    }

    /// A typed minimum: an empty field is no minimum.
    static func minimum(_ text: String, unit: VanStockUnit, locale: Locale) -> Result<StockQuantity?, StockQuantityRefusal> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .success(nil) }
        return read(text, unit: unit, locale: locale).map { Optional($0) }
    }

    /// One whole unit up or down from the field's figure, or from `fallback` when the field holds
    /// none, kept within nothing and a million. 4.25 steps to 5.25 and 3.25; 0.5 steps down to 0.
    static func stepped(_ text: String, by units: Int, unit: VanStockUnit, locale: Locale,
                        fallback: StockQuantity) -> String {
        let current = (try? read(text, unit: unit, locale: locale).get()) ?? fallback
        let moved = current.scaled + units * StockQuantity.perUnit
        return Self.text(StockQuantity(scaled: min(max(moved, 0), StockQuantity.maximumScaled)), locale: locale)
    }

    /// The whole number a stepper shows for a line in `each` or `pack`. Their figures are always
    /// whole (`VanStockUnit.step`); nil for one that is not, which a stepper would cut.
    static func wholeCount(_ quantity: StockQuantity) -> Int? {
        quantity.isWhole ? quantity.scaled / StockQuantity.perUnit : nil
    }
}
