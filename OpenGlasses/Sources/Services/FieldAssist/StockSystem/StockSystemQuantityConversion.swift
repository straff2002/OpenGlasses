import Foundation

/// One connector's table from the units its system writes ("ea", "litre", "box") to the phone's
/// closed list (Plan MM §8). Pure. A unit missing from the table is a unit the phone does not keep,
/// never a guess at `each`.
struct StockSystemUnitMap: Equatable, Sendable {

    private let table: [String: VanStockUnit]

    /// Keys are matched with surrounding spaces ignored and without regard to case.
    init(_ table: [String: VanStockUnit]) {
        var normalised: [String: VanStockUnit] = [:]
        for (key, unit) in table {
            let cleaned = Self.key(key)
            guard !cleaned.isEmpty, normalised[cleaned] == nil else { continue }
            normalised[cleaned] = unit
        }
        self.table = normalised
    }

    func unit(for systemUnit: String) -> VanStockUnit? {
        table[Self.key(systemUnit)]
    }

    private static func key(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Why a system's figure for a line is not known on the phone (Plan MM §8). Each says why in
/// English for the model, and none of them is ever a number.
enum StockSystemUnknownReason: Equatable, Sendable {
    /// The system lists the item at the location but gives no figure.
    case noCount
    /// The system counts it in a unit that is not on the phone's list.
    case unmappedUnit(String)
    /// More decimal places than `StockQuantity.scale`: refused, never rounded.
    case tooManyDecimals
    /// A fraction of a unit that is counted whole (`each`, `pack`).
    case notWhole
    /// Below zero, which some systems allow after an oversell.
    case negative
    /// More than `StockQuantity.maximumUnits`.
    case tooLarge
    /// Not a plain decimal.
    case notANumber

    init(_ refusal: StockQuantityRefusal) {
        switch refusal {
        case .notANumber: self = .notANumber
        case .negative: self = .negative
        case .tooLarge: self = .tooLarge
        case .tooManyDecimals: self = .tooManyDecimals
        case .notWhole: self = .notWhole
        }
    }

    /// The stored word: "no_count", "too_many_decimals".
    var code: String {
        switch self {
        case .noCount: return "no_count"
        case .unmappedUnit: return "unmapped_unit"
        case .tooManyDecimals: return "too_many_decimals"
        case .notWhole: return "not_whole"
        case .negative: return "negative"
        case .tooLarge: return "too_large"
        case .notANumber: return "not_a_number"
        }
    }

    /// A stored reason read back. A word this build does not know reads as `noCount`, so it can
    /// never become a figure.
    init(code: String, systemUnit: String?) {
        switch code {
        case "unmapped_unit": self = .unmappedUnit(systemUnit ?? "")
        case "too_many_decimals": self = .tooManyDecimals
        case "not_whole": self = .notWhole
        case "negative": self = .negative
        case "too_large": self = .tooLarge
        case "not_a_number": self = .notANumber
        default: self = .noCount
        }
    }

    /// The reason in a sentence, after "<System> lists it but has no count for it." Nil for
    /// `noCount`, which that sentence already says.
    func sentence(system: String, unit: VanStockUnit?) -> String? {
        switch self {
        case .noCount:
            return nil
        case .unmappedUnit(let raw):
            let named = raw.isEmpty ? "a unit" : "'\(raw)'"
            return "\(system) counts it in \(named), which is not a unit kept on the phone, so its figure can't be given."
        case .tooManyDecimals:
            return "\(system) holds that to more decimal places than I keep, so I can't give you its figure."
        case .notWhole:
            return "\(system)'s figure for it is not a whole number, and this item is kept in whole numbers, "
                + "so I can't give you its figure."
        case .negative:
            return "\(system)'s figure for it is below zero, so I can't give you its figure."
        case .tooLarge:
            return "\(system)'s figure for it is more than a million, so I can't give you its figure."
        case .notANumber:
            return "\(system)'s figure for it could not be read, so I can't give you its figure."
        }
    }
}

/// A figure at one location: a quantity, or not known with the reason. Unknown is never zero.
enum StockSystemLevelValue: Equatable, Sendable {
    case known(StockQuantity)
    case unknown(StockSystemUnknownReason)

    var quantity: StockQuantity? {
        if case .known(let quantity) = self { return quantity }
        return nil
    }
}

/// Why a quantity is not sent to a system (Plan MM §8, out).
enum StockSystemOutRefusal: Error, Equatable, Sendable {
    /// The system keeps the item in another unit, or the phone could not map its unit at all.
    case unitNotKept
    /// The system keeps whole numbers only and the quantity is part of one.
    case fractional
    /// Nothing, or more than the phone keeps.
    case outOfRange

    /// "Fixture Till keeps whole numbers only, so 0.5 litres can't be sent."
    func sentence(system: String, quantity: StockQuantity, unit: VanStockUnit) -> String {
        let amount = unit.spoken(quantity)
        switch self {
        case .unitNotKept:
            return "\(system) doesn't keep that item in \(unit.unitName), so \(amount) can't be sent."
        case .fractional:
            return "\(system) keeps whole numbers only, so \(amount) can't be sent."
        case .outOfRange:
            return "\(amount) is not an amount that can be sent."
        }
    }
}

/// The seam between a system's figures and Plan ML's `StockQuantity`, both ways (Plan MM §8). Pure.
enum StockSystemQuantityConversion {

    /// In: a system's decimal text in a system unit, read through the connector's unit map and
    /// `StockQuantity.parse`. No text is no count. A unit the map does not hold, or a figure the
    /// parse refuses (more than three decimal places, a fraction of a whole unit, below zero, not a
    /// number), is unknown with the reason, never a rounded figure.
    static func incoming(_ text: String?, systemUnit: String, map: StockSystemUnitMap) -> StockSystemLevelValue {
        guard let unit = map.unit(for: systemUnit) else {
            return .unknown(.unmappedUnit(String(systemUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(StockSystemPolicy.Cap.systemUnit))))
        }
        return incoming(text, unit: unit)
    }

    /// In, once the unit is known.
    static func incoming(_ text: String?, unit: VanStockUnit) -> StockSystemLevelValue {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown(.noCount)
        }
        switch StockQuantity.parse(text, unit: unit) {
        case .success(let quantity): return .known(quantity)
        case .failure(let refusal): return .unknown(StockSystemUnknownReason(refusal))
        }
    }

    /// Out: a staged quantity as the decimal text the system is sent (`StockQuantity.decimalString`).
    /// Refused when the system keeps the item in another unit (or its unit could not be mapped),
    /// when the system keeps whole numbers only and the quantity is part of one, and when it is
    /// zero or out of range.
    static func outgoing(_ quantity: StockQuantity, unit: VanStockUnit, itemUnit: VanStockUnit?,
                         wholeNumbersOnly: Bool) -> Result<String, StockSystemOutRefusal> {
        guard let itemUnit, itemUnit == unit else { return .failure(.unitNotKept) }
        guard quantity > .zero, quantity.fits(unit) else { return .failure(.outOfRange) }
        if wholeNumbersOnly, !quantity.isWhole { return .failure(.fractional) }
        return .success(quantity.decimalString)
    }
}
