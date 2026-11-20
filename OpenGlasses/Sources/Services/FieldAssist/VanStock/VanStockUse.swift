import Foundation

/// A part that came off the van on one job (Plan IH §7).
///
/// Kept on the job as well as in the van's log, because the two outlive each other differently: the
/// van's log changes hands with the vehicle, and the job's record stays the job's. This is the
/// quantity the work record was missing — a part on a finished task says it was fitted, not how
/// many, and not that it came from the van.
///
/// It is the one figure that leaves the phone today: the work record's `van_stock` block, which
/// the office reads tolerantly (`Contracts/office-reports.md`, "Stock used from the van"). So the
/// figure is written under a name that says it is scaled, with its scale beside it
/// (`quantityScaled`, `quantityScale: 3`), and never as `quantity`: a reader that knows only the
/// old key finds nothing, rather than reading 4,250 thousandths as 4,250 litres (Plan ML §5).
struct VanStockUse: Codable, Equatable, Identifiable, Sendable {
    /// The movement in the van's log that recorded it, so an undo there takes it off the job too.
    let id: String
    let number: String?
    let description: String
    /// In thousandths of `unit`.
    let quantity: StockQuantity
    let unit: VanStockUnit
    /// Whether the part number was found in the manuals.
    let verified: Bool
    let at: Date
    /// Where a business's own system holds the count (Plan MM P4): the system's id for the item,
    /// where the line stands on its way there, and why it was kept on the phone or needs a person.
    /// All nil, and absent from the JSON, for a line from the phone's own list.
    let itemID: String?
    let delivery: StockSystemLineDelivery.State?
    let deliveryReason: String?

    /// The scale every line is written at: `quantityScaled` is in units of 10^−3 of `unit`.
    static let quantityScale = StockQuantity.scale

    init(id: String, number: String?, description: String, quantity: StockQuantity,
         unit: VanStockUnit, verified: Bool, at: Date, itemID: String? = nil,
         delivery: StockSystemLineDelivery.State? = nil, deliveryReason: String? = nil) {
        self.id = id
        self.number = number
        self.description = description
        self.quantity = quantity
        self.unit = unit
        self.verified = verified
        self.at = at
        self.itemID = itemID
        self.delivery = delivery
        self.deliveryReason = deliveryReason
    }

    enum CodingKeys: String, CodingKey {
        case id, number, description, unit, verified, at
        case itemID, delivery, deliveryReason
        case quantityScaled, quantityScale
        /// Read only: a use saved before figures were kept in thousandths, in whole units.
        case legacyQuantity = "quantity"
    }

    /// The scaled pair, or a legacy `quantity` in whole units (× 1,000). A scale other than 3, or
    /// a scaled figure with no scale, is refused rather than guessed at.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decodeIfPresent(String.self, forKey: .number)
        description = try container.decode(String.self, forKey: .description)
        unit = try container.decode(VanStockUnit.self, forKey: .unit)
        verified = try container.decode(Bool.self, forKey: .verified)
        at = try container.decode(Date.self, forKey: .at)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        // A state from a newer build is not guessed at: the line reads as one with no state.
        delivery = (try? container.decodeIfPresent(StockSystemLineDelivery.State.self, forKey: .delivery)) ?? nil
        deliveryReason = try container.decodeIfPresent(String.self, forKey: .deliveryReason)
        if let scaled = try container.decodeIfPresent(Int.self, forKey: .quantityScaled) {
            let scale = try container.decode(Int.self, forKey: .quantityScale)
            guard scale == Self.quantityScale else {
                throw DecodingError.dataCorruptedError(
                    forKey: .quantityScale, in: container,
                    debugDescription: "A stock use must be at scale \(Self.quantityScale), not \(scale)")
            }
            let value = StockQuantity(scaled: scaled)
            guard value.isInRange else {
                throw DecodingError.dataCorruptedError(
                    forKey: .quantityScaled, in: container,
                    debugDescription: "A stock use must be 0…\(StockQuantity.maximumScaled) thousandths")
            }
            quantity = value
        } else {
            let units = try container.decode(Int.self, forKey: .legacyQuantity)
            guard (0...StockQuantity.maximumUnits).contains(units) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .legacyQuantity, in: container,
                    debugDescription: "A legacy stock use must be 0…\(StockQuantity.maximumUnits) units")
            }
            quantity = StockQuantity(whole: units)
        }
    }

    /// Writes `quantityScaled` and `quantityScale`, and no `quantity` key; the system's members
    /// only when the line has them.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encode(description, forKey: .description)
        try container.encode(quantity.scaled, forKey: .quantityScaled)
        try container.encode(Self.quantityScale, forKey: .quantityScale)
        try container.encode(unit, forKey: .unit)
        try container.encode(verified, forKey: .verified)
        try container.encode(at, forKey: .at)
        try container.encodeIfPresent(itemID, forKey: .itemID)
        try container.encodeIfPresent(delivery, forKey: .delivery)
        try container.encodeIfPresent(deliveryReason, forKey: .deliveryReason)
    }

    /// "2 × Igniter (22B22)", "4.25 litres of Engine oil (OIL-5W30)": the words the assistant uses
    /// (`VanStockUnit.spoken(_:of:)`).
    var summary: String {
        let described = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let number, !number.isEmpty {
            name = described.isEmpty ? number : "\(described) (\(number))"
        } else {
            name = described.isEmpty ? "Unnamed item" : described
        }
        return unit.spoken(quantity, of: name)
    }
}

/// Which parts on a job's finished tasks have no stock entry (Plan IH §7).
///
/// The complaint this plan started from is a part used and never recorded. A part on a finished
/// task is the one place the app already knows something was fitted, so those are compared with
/// what was recorded as used on the job. A part with no entry is asked about — it is never
/// deducted, because a part on a task is not proof of where it came from.
///
/// Pure.
enum VanStockReconciler {

    /// Parts on finished tasks that were neither recorded as used from the van on this job nor
    /// said not to have come from it, in the order the job reached them.
    /// `noted` is the part numbers noted on the job for a business's own system (Plan MM P4): a
    /// part noted there is accounted for, as one recorded on the van is.
    static func unrecorded(partsUsed: [TaskPart], uses: [VanStockUse], notFromVan: [String],
                           noted: [String] = []) -> [TaskPart] {
        let recorded = Set(uses.compactMap { $0.number.map(VaultPartsIndex.normalise) } + noted.map(VaultPartsIndex.normalise))
        let dismissed = Set(notFromVan.map(VaultPartsIndex.normalise))
        var seen = Set<String>()
        return partsUsed.filter { part in
            let number = VaultPartsIndex.normalise(part.number)
            guard !number.isEmpty, seen.insert(number).inserted else { return false }
            return !recorded.contains(number) && !dismissed.contains(number)
        }
    }

    /// "the igniter (22B22) and the pressure switch (14T65)" — for the question at the close.
    static func named(_ parts: [TaskPart]) -> String {
        let names = parts.map { part in
            part.partDescription.map { "\($0) (\(part.number))" } ?? part.number
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
