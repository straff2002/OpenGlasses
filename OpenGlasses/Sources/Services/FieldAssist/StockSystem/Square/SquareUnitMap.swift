import Foundation

/// Square's measurement units onto the phone's closed list (Plan MM §8, P1). A pure table.
///
/// A variation with no measurement unit is counted in whole items (`each`, no decimal places). A
/// standard unit maps only when it is one of the phone's own units: litre, metre, foot, kilogram,
/// pound, and Square's generic "unit" as `each`. A custom unit maps only when its name or its
/// abbreviation is exactly one of the each or pack words below. Everything else (millilitres,
/// grams, inches, hours, a custom "tin") is not kept on the phone, and its figures are unknown with
/// that reason. Nothing is ever converted from one unit to another, and nothing is guessed.
enum SquareUnitMap {

    /// A measurement unit as the catalogue describes it.
    enum Unit: Equatable, Sendable {
        /// The variation names no measurement unit: whole items.
        case none
        /// One of Square's standard units, by its enum value ("METRIC_LITER", "UNIT").
        case standard(String)
        /// A seller's own unit, by its name and abbreviation.
        case custom(name: String, abbreviation: String)
        /// The variation names a unit the pull could not read or did not see.
        case unreadable
    }

    /// What a unit is on the phone.
    struct Resolution: Equatable, Sendable {
        /// The phone's unit, or nil when the phone does not keep it.
        let unit: VanStockUnit?
        /// The unit's word for the snapshot's `systemUnit`: the phone's own unit word when it maps,
        /// otherwise the system's word, so the sentence can name it.
        let systemUnit: String
    }

    /// Square's standard units that are the phone's own.
    static let standard: [String: VanStockUnit] = [
        "METRIC_LITER": .l,
        "METRIC_METER": .m,
        "IMPERIAL_FOOT": .ft,
        "METRIC_KILOGRAM": .kg,
        "IMPERIAL_POUND": .lb,
        "UNIT": .each,
    ]

    /// Custom unit names or abbreviations, matched exactly (case and surrounding spaces aside),
    /// that mean one item.
    static let eachWords: Set<String> = ["each", "ea", "item", "items", "piece", "pieces", "pc", "pcs", "unit", "units"]

    /// Custom unit names or abbreviations that mean a pack the system counts whole.
    static let packWords: Set<String> = ["pack", "packs", "pk", "packet", "packets", "box", "boxes"]

    /// The common table form, keyed by the words this map produces for `systemUnit`.
    static var table: StockSystemUnitMap {
        StockSystemUnitMap(Dictionary(uniqueKeysWithValues: VanStockUnit.allCases.map { ($0.rawValue, $0) }))
    }

    static func resolve(_ unit: Unit) -> Resolution {
        switch unit {
        case .none:
            return Resolution(unit: .each, systemUnit: VanStockUnit.each.rawValue)
        case .standard(let value):
            if let mapped = standard[value] { return Resolution(unit: mapped, systemUnit: mapped.rawValue) }
            return Resolution(unit: nil, systemUnit: protect(word(forStandard: value)))
        case .custom(let name, let abbreviation):
            let words = [name, abbreviation].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if words.contains(where: eachWords.contains) { return Resolution(unit: .each, systemUnit: VanStockUnit.each.rawValue) }
            if words.contains(where: packWords.contains) { return Resolution(unit: .pack, systemUnit: VanStockUnit.pack.rawValue) }
            let shown = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? abbreviation : name
            return Resolution(unit: nil, systemUnit: protect(capped(shown)))
        case .unreadable:
            return Resolution(unit: nil, systemUnit: "unknown unit")
        }
    }

    /// "METRIC_MILLILITER" as "milliliter", "GENERIC_FLUID_OUNCE" as "fluid ounce".
    static func word(forStandard value: String) -> String {
        var word = capped(value)
        for prefix in ["METRIC_", "IMPERIAL_", "GENERIC_"] where word.hasPrefix(prefix) {
            word = String(word.dropFirst(prefix.count))
            break
        }
        let spoken = word.lowercased().replacingOccurrences(of: "_", with: " ")
        return spoken.isEmpty ? "unknown unit" : spoken
    }

    /// An unmapped word that reads as one of the phone's own units ("l", "kg") would be taken for
    /// it by the common table, so it is marked as the system's own.
    private static func protect(_ word: String) -> String {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "unknown unit" }
        guard VanStockUnit(rawValue: cleaned.lowercased()) != nil else { return cleaned }
        return String("\(cleaned) (custom)".prefix(StockSystemPolicy.Cap.systemUnit))
    }

    private static func capped(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StockSystemPolicy.Cap.systemUnit - 9))
    }
}
