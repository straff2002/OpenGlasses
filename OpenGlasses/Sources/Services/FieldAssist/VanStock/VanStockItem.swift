import Foundation

/// How a line of van stock is counted (Plan IH §1).
///
/// A closed list. Every figure is kept in thousandths of the unit (`StockQuantity`); the unit
/// decides which steps a figure may take (`step`): whole ones for `each` and `pack`.
enum VanStockUnit: String, Codable, CaseIterable, Sendable {
    case each
    case m
    case ft
    case kg
    case lb
    case l
    case pack

    /// What a spoken or typed unit means. Nil for anything that is not on the list, so a unit the
    /// app does not keep is refused instead of being filed as `each`.
    init?(spoken raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "each", "ea", "unit", "units", "piece", "pieces", "pc", "pcs": self = .each
        case "m", "metre", "metres", "meter", "meters": self = .m
        case "ft", "foot", "feet": self = .ft
        case "kg", "kilo", "kilos", "kilogram", "kilograms": self = .kg
        case "lb", "lbs", "pound", "pounds": self = .lb
        case "l", "litre", "litres", "liter", "liters": self = .l
        case "pack", "packs", "box", "boxes", "bag", "bags": self = .pack
        default: return nil
        }
    }
}

/// One line of stock on the van (Plan IH §1).
///
/// The identifier is separate from the part number on purpose: a number can be corrected, and most
/// of what a van carries — capacitors, contactors, fuses, fittings — is in no manual and may have
/// a description and no number at all.
struct VanStockItem: Codable, Equatable, Identifiable, Sendable {

    /// Who decided what the van should carry of this line: base's baseline, or this truck.
    enum StandardOrigin: String, Codable, Sendable {
        case base
        case van
    }

    let id: String
    /// The part number, normalised with `VaultPartsIndex.normalise`. Nil for a line with none.
    var number: String?
    var description: String
    var unit: VanStockUnit
    /// Warn at or below this. In thousandths of `unit`.
    var minimum: StockQuantity?
    /// What the van should carry; a top-up fills to it. In thousandths of `unit`.
    var standard: StockQuantity?
    var standardSetBy: StandardOrigin?
    /// A short label for where it lives on the van: "left shelf 2".
    var bin: String?
    /// Scanned codes that mean this line. A printed barcode is usually a retail code, not the part
    /// number, so it is remembered here the first time somebody says what it was.
    var codes: [String]
    /// What the last lookup of the number said, and which book answered (Plan MK §4). Never a
    /// gate.
    var verification: VanStockVerification
    /// The batch that created the line, so undoing that batch takes the line away again.
    let createdBatch: String

    init(id: String = UUID().uuidString,
         number: String? = nil,
         description: String,
         unit: VanStockUnit = .each,
         minimum: StockQuantity? = nil,
         standard: StockQuantity? = nil,
         standardSetBy: StandardOrigin? = nil,
         bin: String? = nil,
         codes: [String] = [],
         verified: Bool = false,
         verification: VanStockVerification? = nil,
         createdBatch: String) {
        self.id = id
        self.number = number
        self.description = description
        self.unit = unit
        self.minimum = minimum
        self.standard = standard
        self.standardSetBy = standardSetBy
        self.bin = bin
        self.codes = codes
        self.verification = verification ?? VanStockVerification(legacy: verified)
        self.createdBatch = createdBatch
    }

    /// Whether the number was found when it was last looked up: today's two-state view of
    /// `verification`, kept so every existing caller reads as before until Plan MK P1 moves them.
    /// Setting it changes the state only when the answer changes: `true` is found (in no named
    /// book), `false` takes a found line back to not checked and leaves a not-found line as it is.
    var verified: Bool {
        get { verification.isFound }
        set {
            guard newValue != verification.isFound else { return }
            verification = newValue ? .found(in: nil) : .notChecked
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, number, description, unit, minimum, standard, bin, codes, verified, verification
        case standardSetBy = "standard_set_by"
        case createdBatch = "created_batch"
    }

    /// A line stored before Plan MK has only `verified`: `true` reads as found and `false`, or
    /// nothing, as not checked. A newer line has `verification`, which wins.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decodeIfPresent(String.self, forKey: .number)
        description = try container.decode(String.self, forKey: .description)
        unit = try container.decode(VanStockUnit.self, forKey: .unit)
        minimum = try container.decodeIfPresent(StockQuantity.self, forKey: .minimum)
        standard = try container.decodeIfPresent(StockQuantity.self, forKey: .standard)
        standardSetBy = try container.decodeIfPresent(StandardOrigin.self, forKey: .standardSetBy)
        bin = try container.decodeIfPresent(String.self, forKey: .bin)
        codes = try container.decode([String].self, forKey: .codes)
        if let stored = try container.decodeIfPresent(VanStockVerification.self, forKey: .verification) {
            verification = stored
        } else {
            verification = VanStockVerification(legacy: try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false)
        }
        createdBatch = try container.decode(String.self, forKey: .createdBatch)
    }

    /// Writes `verification`, and `verified` beside it, so a phone that goes back to an older
    /// build, which requires `verified`, can still read its list.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encode(description, forKey: .description)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(standard, forKey: .standard)
        try container.encodeIfPresent(standardSetBy, forKey: .standardSetBy)
        try container.encodeIfPresent(bin, forKey: .bin)
        try container.encode(codes, forKey: .codes)
        try container.encode(verified, forKey: .verified)
        try container.encode(verification, forKey: .verification)
        try container.encode(createdBatch, forKey: .createdBatch)
    }

    /// "Flame sensor (62-23543-01)", "45/5 capacitor", or the bare number for a line nobody
    /// described.
    var name: String {
        let described = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number, !number.isEmpty else { return described.isEmpty ? "Unnamed item" : described }
        return described.isEmpty ? number : "\(described) (\(number))"
    }

    /// "2 × Flame sensor (62-23543-01)", "4.25 litres of Engine oil": for the model, measured
    /// amounts in words (`VanStockUnit.spoken(_:of:)`).
    func phrase(_ quantity: StockQuantity) -> String { unit.spoken(quantity, of: name) }

    /// A figure for this line in a sentence that does not name the unit: "3", "4.25 litres".
    func figure(_ quantity: StockQuantity) -> String { unit.figure(quantity) }
}
