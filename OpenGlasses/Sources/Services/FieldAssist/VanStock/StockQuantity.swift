import Foundation

/// An amount of stock: a whole number of thousandths of the line's unit.
///
/// 4.25 L is `4250`, two flame sensors are `2000`, 12 m is `12000`. One scale for every unit, so
/// the stored number never depends on the unit; the unit only decides which steps are allowed
/// (`VanStockUnit.step`): a thousandth for measured units, a whole one for `each` and `pack`.
///
/// Sums, differences and comparisons are integer arithmetic, so they are exact: 0.1 + 0.2 litres is
/// 300 thousandths, and a thousand additions of 0.001 make exactly 1. Text is read digit by digit
/// and never goes through `Double`. Pure.
struct StockQuantity: Hashable, Comparable, Sendable {

    /// Decimal places kept.
    static let scale = 3
    /// Thousandths in one unit.
    static let perUnit = 1000
    /// The most of one unit a figure may hold.
    static let maximumUnits = 1_000_000
    /// `maximumUnits` in thousandths.
    static let maximumScaled = maximumUnits * perUnit

    static let zero = StockQuantity(scaled: 0)

    /// The amount in thousandths of the line's unit. Arithmetic may take it below zero (a
    /// difference); callers clamp, as the ledger does.
    let scaled: Int

    init(scaled: Int) {
        self.scaled = scaled
    }

    /// Whole units: `init(whole: 2)` is 2000 thousandths.
    init(whole: Int) {
        self.scaled = whole * Self.perUnit
    }

    /// Within 0 … a million units.
    var isInRange: Bool { (0...Self.maximumScaled).contains(scaled) }

    /// A whole number of units.
    var isWhole: Bool { scaled % Self.perUnit == 0 }

    /// Whether this figure can be kept on a line in `unit`: in range, and a multiple of its step.
    func fits(_ unit: VanStockUnit) -> Bool {
        isInRange && scaled % unit.step == 0
    }

    // MARK: Arithmetic

    static func + (lhs: StockQuantity, rhs: StockQuantity) -> StockQuantity {
        StockQuantity(scaled: lhs.scaled + rhs.scaled)
    }

    static func - (lhs: StockQuantity, rhs: StockQuantity) -> StockQuantity {
        StockQuantity(scaled: lhs.scaled - rhs.scaled)
    }

    static func += (lhs: inout StockQuantity, rhs: StockQuantity) {
        lhs = lhs + rhs
    }

    static func -= (lhs: inout StockQuantity, rhs: StockQuantity) {
        lhs = lhs - rhs
    }

    static func < (lhs: StockQuantity, rhs: StockQuantity) -> Bool {
        lhs.scaled < rhs.scaled
    }

    // MARK: Formatting

    /// "4.25", "4", "0.001", "1000000": `.` as the separator, no trailing zeros, no exponent, no
    /// grouping. The spelling for the model, the sheet and the log's edit strings.
    var decimalString: String {
        let magnitude = scaled.magnitude
        let perUnit = UInt(Self.perUnit)
        let units = magnitude / perUnit
        let fraction = magnitude % perUnit
        let sign = scaled < 0 ? "-" : ""
        guard fraction != 0 else { return "\(sign)\(units)" }
        var digits = String(fraction)
        while digits.count < Self.scale { digits = "0" + digits }
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(sign)\(units).\(digits)"
    }

    /// The screen's form: the locale's decimal separator and grouping, up to three decimal places,
    /// no trailing zeros. "4,25" in German and French, "4.25" in English. Never through `Double`.
    func formatted(locale: Locale) -> String {
        let value = Decimal(scaled) / Decimal(Self.perUnit)
        return value.formatted(.number.locale(locale).precision(.fractionLength(0...Self.scale)))
    }

    // MARK: Parsing

    /// Reads a plain decimal exactly: one or more ASCII digits, optionally `.` and one or more
    /// digits, with surrounding whitespace ignored. No sign, exponent, comma or grouping. Digits
    /// past the third decimal place are allowed only when they are all zero ("4.2500" is 4.25).
    static func parse(_ text: String, unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard !bytes.isEmpty else { return .failure(.notANumber) }
        if bytes[0] == UInt8(ascii: "-") {
            // A valid number behind a minus sign is a negative amount, not a typo.
            return isPlainDecimal(bytes[1...]) ? .failure(.negative) : .failure(.notANumber)
        }
        guard isPlainDecimal(bytes[...]) else { return .failure(.notANumber) }

        let point = bytes.firstIndex(of: UInt8(ascii: "."))
        let wholeDigits = bytes[..<(point ?? bytes.endIndex)]
        let fractionDigits = point.map { bytes[($0 + 1)...] } ?? []

        // The fraction: its first three digits are thousandths; any after must be zero.
        var thousandths = 0
        for (offset, digit) in fractionDigits.enumerated() {
            let value = Int(digit - UInt8(ascii: "0"))
            if offset < scale {
                thousandths = thousandths * 10 + value
            } else if value != 0 {
                return .failure(unit.allowsFraction ? .tooManyDecimals : .notWhole)
            }
        }
        for _ in min(fractionDigits.count, scale)..<scale { thousandths *= 10 }

        // The whole part, stopping as soon as it passes the bound so a long string cannot overflow.
        var units = 0
        for digit in wholeDigits {
            units = units * 10 + Int(digit - UInt8(ascii: "0"))
            if units > maximumUnits { return .failure(.tooLarge) }
        }
        return checked(scaled: units * perUnit + thousandths, unit: unit)
    }

    /// Reads a tool argument from the model's JSON. Nil when it is absent (missing, `null`, or an
    /// empty string). A boolean is not a number. An integer is whole units, a string is read
    /// exactly, and a floating-point number goes through `parse(number:unit:)`.
    static func parse(json raw: Any?, unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal>? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let text = raw as? String {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return parse(text, unit: unit)
        }
        guard let number = raw as? NSNumber else { return .failure(.notANumber) }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .failure(.notANumber) }
        if let decimal = number as? NSDecimalNumber {
            // Already exact in base ten: read its digits rather than a binary approximation.
            guard !decimal.decimalValue.isNaN else { return .failure(.notANumber) }
            return parse(decimal.decimalValue.description, unit: unit)
        }
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" {
            return parse(number: number.doubleValue, unit: unit)
        }
        if number.compare(NSNumber(value: 0)) == .orderedAscending { return .failure(.negative) }
        if number.compare(NSNumber(value: maximumUnits)) == .orderedDescending { return .failure(.tooLarge) }
        return checked(scaled: number.intValue * perUnit, unit: unit)
    }

    /// Reads a floating-point figure (from JSON or a spreadsheet cell). It is taken when it is
    /// within a millionth of a unit of a whole thousandth, which absorbs binary noise
    /// (0.1 is 100.00000000000001 thousandths) and still refuses 4.2501.
    static func parse(number value: Double, unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal> {
        guard value.isFinite else { return .failure(.notANumber) }
        if value < 0 { return .failure(.negative) }
        let thousandths = value * Double(perUnit)
        let nearest = thousandths.rounded()
        if abs(thousandths - nearest) > 0.001 {
            return .failure(unit.allowsFraction ? .tooManyDecimals : .notWhole)
        }
        guard nearest <= Double(maximumScaled) else { return .failure(.tooLarge) }
        return checked(scaled: Int(nearest), unit: unit)
    }

    /// Reads what somebody typed on the screen: the locale's decimal separator, and `.` always,
    /// count as the decimal point (one at most). Grouping separators are refused. Then exactly as
    /// `parse(_:unit:)`, so "4,25" in German and "4.25" anywhere are 4.25.
    static func parse(localized text: String, locale: Locale, unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal> {
        var normalised = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = locale.decimalSeparator, !separator.isEmpty, separator != "." {
            normalised = normalised.replacingOccurrences(of: separator, with: ".")
        }
        guard normalised.filter({ $0 == "." }).count <= 1 else { return .failure(.notANumber) }
        return parse(normalised, unit: unit)
    }

    /// One or more ASCII digits, optionally a `.` followed by one or more digits.
    private static func isPlainDecimal(_ bytes: ArraySlice<UInt8>) -> Bool {
        var sawDigitBeforePoint = false
        var sawPoint = false
        var sawDigitAfterPoint = false
        for byte in bytes {
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                if sawPoint { sawDigitAfterPoint = true } else { sawDigitBeforePoint = true }
            } else if byte == UInt8(ascii: "."), !sawPoint {
                sawPoint = true
            } else {
                return false
            }
        }
        return sawDigitBeforePoint && (!sawPoint || sawDigitAfterPoint)
    }

    /// The range and step checks every parse ends with.
    private static func checked(scaled: Int, unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal> {
        if scaled < 0 { return .failure(.negative) }
        if scaled > maximumScaled { return .failure(.tooLarge) }
        if scaled % unit.step != 0 { return .failure(.notWhole) }
        return .success(StockQuantity(scaled: scaled))
    }
}

extension StockQuantity: Codable {

    /// A bare JSON integer: `4250`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard (0...Self.maximumScaled).contains(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A stock quantity must be 0…\(Self.maximumScaled) thousandths")
        }
        self.init(scaled: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(scaled)
    }
}

/// Why a figure was not taken. Each has a model-facing English sentence.
enum StockQuantityRefusal: Error, Equatable, Sendable {
    case notANumber
    case negative
    case tooLarge
    case tooManyDecimals
    case notWhole

    /// "litres are kept to 3 decimal places", "packs are counted whole". English, for the model;
    /// not localised.
    func sentence(for unit: VanStockUnit) -> String {
        switch self {
        case .notANumber: return "that is not a number"
        case .negative: return "a quantity cannot be below zero"
        case .tooLarge: return "that is more than a million"
        case .tooManyDecimals, .notWhole:
            switch unit {
            case .each: return "each is counted in whole numbers"
            case .pack: return "packs are counted whole"
            case .m, .ft, .kg, .lb, .l: return "\(unit.pluralWord) are kept to \(StockQuantity.scale) decimal places"
            }
        }
    }
}

extension VanStockUnit {

    /// The smallest amount a line in this unit moves by, in thousandths: a millimetre, a gram or a
    /// millilitre for measured units, a whole one for `each` and `pack`.
    var step: Int {
        switch self {
        case .m, .ft, .kg, .lb, .l: return 1
        case .each, .pack: return StockQuantity.perUnit
        }
    }

    /// Whether a line in this unit can hold part of one.
    var allowsFraction: Bool { step < StockQuantity.perUnit }

    /// The unit in English words, for the model: "litre", "feet".
    var singularWord: String {
        switch self {
        case .each: return "each"
        case .m: return "metre"
        case .ft: return "foot"
        case .kg: return "kilogram"
        case .lb: return "pound"
        case .l: return "litre"
        case .pack: return "pack"
        }
    }

    var pluralWord: String {
        switch self {
        case .each: return "each"
        case .m: return "metres"
        case .ft: return "feet"
        case .kg: return "kilograms"
        case .lb: return "pounds"
        case .l: return "litres"
        case .pack: return "packs"
        }
    }

    /// An amount in words, for the model: "4.25 litres", "1 litre", "3 feet", "2" (each),
    /// "1 pack". Singular only when it is exactly one.
    func spoken(_ quantity: StockQuantity) -> String {
        let number = quantity.decimalString
        switch self {
        case .each: return number
        case .m, .ft, .kg, .lb, .l, .pack:
            return "\(number) \(quantity.scaled == StockQuantity.perUnit ? singularWord : pluralWord)"
        }
    }

    /// "4.25 litres of Engine oil", "2 × Flame sensor", "1 pack of Wire nuts".
    func spoken(_ quantity: StockQuantity, of name: String) -> String {
        switch self {
        case .each: return "\(quantity.decimalString) × \(name)"
        case .m, .ft, .kg, .lb, .l, .pack: return "\(spoken(quantity)) of \(name)"
        }
    }
}
