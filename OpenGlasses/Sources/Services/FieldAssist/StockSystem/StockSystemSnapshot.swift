import Foundation

/// Where a snapshot's figures came from (Plan MM §2). Stated, not signed: no Avenkin party
/// produced the figures, so there is no signature to check. Integrity comes from the pinned host
/// and TLS, as for any direct connector.
struct StockSystemSource: Codable, Equatable, Sendable {
    /// The connector's own id, a lowercase token.
    let connectorID: String
    /// How people name the system, for every sentence: "in <name>".
    let displayName: String
    /// The account as the person sees it on the connection.
    let accountLabel: String?

    init(connectorID: String, displayName: String, accountLabel: String? = nil) {
        self.connectorID = String(connectorID.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(StockSystemPolicy.Cap.identifier))
        self.displayName = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(StockSystemPolicy.Cap.sourceText))
        let account = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountLabel = account?.isEmpty == false ? String(account!.prefix(StockSystemPolicy.Cap.sourceText)) : nil
    }

    enum CodingKeys: String, CodingKey {
        case connectorID = "connector"
        case displayName = "name"
        case accountLabel = "account"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(connectorID: try container.decode(String.self, forKey: .connectorID),
                  displayName: try container.decode(String.self, forKey: .displayName),
                  accountLabel: try container.decodeIfPresent(String.self, forKey: .accountLabel))
        guard !self.connectorID.isEmpty, !self.displayName.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .connectorID, in: container,
                                                   debugDescription: "A source needs a connector and a name")
        }
    }
}

/// How a figure is known. One word only (Decision 11): the system's own figure, however the
/// system arrived at it. HF's `counted`, `inferred` and `declared` describe the office's ledger,
/// and the phone cannot know which of them a system's figure is.
enum StockSystemProvenance: String, Codable, Equatable, Sendable {
    case system
}

/// One of the system's locations: an outlet, a storage device, a warehouse (HF's `locations`).
struct StockSystemLocation: Codable, Equatable, Sendable {

    /// HF's location classes. A class this build does not know reads as `other`.
    enum LocationClass: String, Codable, Equatable, Sendable, CaseIterable {
        case base
        case van
        case site
        case other

        init(lenient raw: String?) {
            self = raw.flatMap { LocationClass(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                ?? .other
        }

        init(from decoder: Decoder) throws {
            self.init(lenient: try decoder.singleValueContainer().decode(String.self))
        }
    }

    let id: String
    let name: String
    let locationClass: LocationClass

    init(id: String, name: String, locationClass: LocationClass = .other) {
        self.id = id
        self.name = name
        self.locationClass = locationClass
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case locationClass = "class"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= StockSystemPolicy.Cap.identifier else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Bad location id")
        }
        self.id = id
        self.name = String(try container.decode(String.self, forKey: .name).prefix(StockSystemPolicy.Cap.locationName))
        self.locationClass = try container.decodeIfPresent(LocationClass.self, forKey: .locationClass) ?? .other
    }
}

/// A price as the system gave it (HF's optional `price`). Kept only when the organisation enables
/// prices (Decision 9), and never spoken in this plan. The amount is the system's plain decimal
/// text, checked digit by digit and never through a float.
struct StockSystemPrice: Codable, Equatable, Sendable {
    let amount: String
    /// ISO 4217, three capital letters, when the system gave one.
    let currency: String?

    /// Nil unless `amount` is a plain decimal and `currency`, when given, is three capital letters.
    init?(amount raw: String?, currency rawCurrency: String?) {
        guard let raw else { return nil }
        let amount = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !amount.isEmpty, amount.count <= StockSystemPolicy.Cap.price, Self.isPlainDecimal(amount) else { return nil }
        let currency = rawCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let currency, !currency.isEmpty {
            guard currency.count == 3, currency.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
            self.currency = currency
        } else {
            self.currency = nil
        }
        self.amount = amount
    }

    enum CodingKeys: String, CodingKey { case amount, currency }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let price = StockSystemPrice(amount: try container.decode(String.self, forKey: .amount),
                                           currency: try container.decodeIfPresent(String.self, forKey: .currency)) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: container, debugDescription: "Bad price")
        }
        self = price
    }

    private static func isPlainDecimal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return false
        }
        return true
    }
}

/// The phone's copy of a business system's stock for the chosen locations: HF's snapshot body,
/// with a stated `source` in place of a signature and the `system` provenance (Plan MM §2).
///
/// Quantities are Plan ML's `StockQuantity`, encoded as HF's `onHandScaled` integers under a
/// top-level `quantityScale` of 3; any other scale is refused on decode. Decoding is closed: an
/// unknown member is ignored, text is capped, and a line that cannot be read is dropped and counted
/// in `droppedLineCount`, never guessed at. Prices are dropped on decode unless the decoder's
/// `userInfo[.stockSystemPricesEnabled]` is `true` (Decision 9).
struct StockSystemSnapshot: Codable, Equatable, Sendable {

    struct Level: Equatable, Sendable {
        let locationID: String
        let value: StockSystemLevelValue
    }

    struct Line: Equatable, Sendable {
        /// The system's own id for the item: what a write names.
        let itemID: String
        /// The part number as the system holds it. Nil for an item with none.
        let part: String?
        let description: String
        /// The phone's unit for the line. Nil only when the system's unit maps onto none of the
        /// phone's, and then every level is unknown with that reason.
        let unit: VanStockUnit?
        /// The unit as the system writes it, kept for the sentences and for P1's request builder.
        let systemUnit: String
        let levels: [Level]
        let provenance: StockSystemProvenance
        /// When the system dated this line's figure, if it did.
        let lineAsOf: Date?
        let price: StockSystemPrice?
        /// The system's own reorder point, when it has one.
        let reorderPoint: StockQuantity?
        /// The most decimal places the system keeps for this item, when it says (a till's
        /// measurement-unit precision, say): checked before a quantity is sent, and never rounded
        /// to. Nil is no limit beyond the phone's own scale. Encoded as `decimalPlaces`; a value
        /// outside `StockSystemPolicy.decimalPlacesRange` is dropped on decode.
        var decimalPlaces: Int?

        init(itemID: String, part: String?, description: String, unit: VanStockUnit?, systemUnit: String,
             levels: [Level], provenance: StockSystemProvenance, lineAsOf: Date?, price: StockSystemPrice?,
             reorderPoint: StockQuantity?, decimalPlaces: Int? = nil) {
            self.itemID = itemID
            self.part = part
            self.description = description
            self.unit = unit
            self.systemUnit = systemUnit
            self.levels = levels
            self.provenance = provenance
            self.lineAsOf = lineAsOf
            self.price = price
            self.reorderPoint = reorderPoint
            self.decimalPlaces = decimalPlaces.flatMap { StockSystemPolicy.decimalPlacesRange.contains($0) ? $0 : nil }
        }

        /// "Capacitor 45/5 (ZX-1001)", or the bare number, or the description.
        var name: String {
            let described = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let part, !part.isEmpty else { return described.isEmpty ? "Unnamed item" : described }
            return described.isEmpty ? part : "\(described) (\(part))"
        }

        func level(at locationID: String) -> StockSystemLevelValue? {
            levels.first { $0.locationID == locationID }?.value
        }
    }

    let source: StockSystemSource
    /// The pull-finished time, or the oldest date the system put on its figures.
    let asOf: Date
    let locations: [StockSystemLocation]
    let lines: [Line]
    /// Lines a decode could not read, or held beyond the cap. Not encoded.
    var droppedLineCount: Int = 0

    init(source: StockSystemSource, asOf: Date, locations: [StockSystemLocation], lines: [Line]) {
        self.source = source
        self.asOf = asOf
        self.locations = locations
        self.lines = lines
    }

    func location(_ id: String) -> StockSystemLocation? {
        locations.first { $0.id == id }
    }

    // MARK: - Codable

    static let quantityScale = StockQuantity.scale

    enum CodingKeys: String, CodingKey {
        case quantityScale, source, asOf, locations, lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scale = try container.decode(Int.self, forKey: .quantityScale)
        guard scale == Self.quantityScale else {
            throw DecodingError.dataCorruptedError(forKey: .quantityScale, in: container,
                                                   debugDescription: "quantityScale must be \(Self.quantityScale)")
        }
        source = try container.decode(StockSystemSource.self, forKey: .source)
        asOf = Date(timeIntervalSince1970: TimeInterval(try container.decode(Int.self, forKey: .asOf)))

        var seenLocations = Set<String>()
        locations = try container.decode([Lossy<StockSystemLocation>].self, forKey: .locations)
            .compactMap(\.value)
            .filter { seenLocations.insert($0.id).inserted }

        let pricesEnabled = decoder.userInfo[.stockSystemPricesEnabled] as? Bool ?? StockSystemPolicy.pricesEnabledByDefault
        let decoded = try container.decode([Lossy<StoredLine>].self, forKey: .lines)
        var kept: [Line] = []
        var seenItems = Set<String>()
        var dropped = 0
        for entry in decoded {
            guard let stored = entry.value, kept.count < StockSystemPolicy.lineCap,
                  seenItems.insert(stored.line.itemID).inserted else {
                dropped += 1
                continue
            }
            let line = stored.line
            kept.append(pricesEnabled ? line : Line(itemID: line.itemID, part: line.part, description: line.description,
                                                   unit: line.unit, systemUnit: line.systemUnit, levels: line.levels,
                                                   provenance: line.provenance, lineAsOf: line.lineAsOf, price: nil,
                                                   reorderPoint: line.reorderPoint, decimalPlaces: line.decimalPlaces))
        }
        lines = kept
        droppedLineCount = dropped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.quantityScale, forKey: .quantityScale)
        try container.encode(source, forKey: .source)
        try container.encode(Int(asOf.timeIntervalSince1970.rounded(.down)), forKey: .asOf)
        try container.encode(locations, forKey: .locations)
        try container.encode(lines.map(StoredLine.init), forKey: .lines)
    }

    /// Two snapshots are the same stock when everything but the decode count matches.
    static func == (lhs: StockSystemSnapshot, rhs: StockSystemSnapshot) -> Bool {
        lhs.source == rhs.source && lhs.asOf == rhs.asOf && lhs.locations == rhs.locations && lhs.lines == rhs.lines
    }
}

extension CodingUserInfoKey {
    /// Set to `true` on a decoder to keep prices (Decision 9). Absent is the policy's default.
    static let stockSystemPricesEnabled = CodingUserInfoKey(rawValue: "stockSystemPricesEnabled")!
}

// MARK: - The stored form

/// An element that is dropped, not thrown, when it cannot be read.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A line as it is written: HF's members, with `onHandScaled` or `known: false` per level.
private struct StoredLine: Codable {
    let line: StockSystemSnapshot.Line

    init(_ line: StockSystemSnapshot.Line) {
        self.line = line
    }

    enum CodingKeys: String, CodingKey {
        case itemID, part, description, unit, systemUnit, levels, provenance, lineAsOf, price, reorderPointScaled,
             decimalPlaces
    }

    struct StoredLevel: Codable {
        let location: String
        let onHandScaled: Int?
        let known: Bool?
        let reason: String?
        let systemUnit: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func fail(_ key: CodingKeys, _ why: String) -> DecodingError {
            .dataCorruptedError(forKey: key, in: container, debugDescription: why)
        }
        let itemID = try container.decode(String.self, forKey: .itemID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty, itemID.count <= StockSystemPolicy.Cap.identifier else { throw fail(.itemID, "Bad item id") }
        let part = try container.decodeIfPresent(String.self, forKey: .part)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StockSystemPolicy.Cap.part)) }
        let description = String(try container.decode(String.self, forKey: .description)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(StockSystemPolicy.Cap.description))
        guard part?.isEmpty == false || !description.isEmpty else { throw fail(.description, "A line needs a part or a description") }
        let unit: VanStockUnit?
        if let raw = try container.decodeIfPresent(String.self, forKey: .unit) {
            guard let known = VanStockUnit(rawValue: raw) else { throw fail(.unit, "Unknown unit") }
            unit = known
        } else {
            unit = nil
        }
        let systemUnit = String(try container.decode(String.self, forKey: .systemUnit).prefix(StockSystemPolicy.Cap.systemUnit))
        let provenance = try container.decode(StockSystemProvenance.self, forKey: .provenance)

        var levels: [StockSystemSnapshot.Level] = []
        var seen = Set<String>()
        for stored in try container.decode([StoredLevel].self, forKey: .levels) {
            guard !stored.location.isEmpty, seen.insert(stored.location).inserted else { throw fail(.levels, "Bad level location") }
            if let scaled = stored.onHandScaled {
                guard stored.known != false, let unit else { throw fail(.levels, "A count needs a unit and cannot be unknown") }
                let quantity = StockQuantity(scaled: scaled)
                guard quantity.fits(unit) else { throw fail(.levels, "A count out of range or off its unit's step") }
                levels.append(.init(locationID: stored.location, value: .known(quantity)))
            } else if stored.known == false {
                levels.append(.init(locationID: stored.location,
                                    value: .unknown(StockSystemUnknownReason(code: stored.reason ?? "", systemUnit: stored.systemUnit))))
            } else {
                throw fail(.levels, "A level is a count or known: false")
            }
        }

        var reorderPoint: StockQuantity?
        if let scaled = try container.decodeIfPresent(Int.self, forKey: .reorderPointScaled) {
            let quantity = StockQuantity(scaled: scaled)
            if let unit, quantity.fits(unit) { reorderPoint = quantity }
        }
        let lineAsOf = try container.decodeIfPresent(Int.self, forKey: .lineAsOf).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let price = try? container.decodeIfPresent(StockSystemPrice.self, forKey: .price)
        // Absent is no extra limit; a value that is not a small whole number is dropped, never trusted.
        let places = (try? container.decodeIfPresent(Int.self, forKey: .decimalPlaces)) ?? nil

        line = StockSystemSnapshot.Line(itemID: itemID, part: part?.isEmpty == true ? nil : part, description: description,
                                        unit: unit, systemUnit: systemUnit, levels: levels, provenance: provenance,
                                        lineAsOf: lineAsOf, price: price ?? nil, reorderPoint: reorderPoint,
                                        decimalPlaces: places)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(line.itemID, forKey: .itemID)
        try container.encodeIfPresent(line.part, forKey: .part)
        try container.encode(line.description, forKey: .description)
        try container.encodeIfPresent(line.unit?.rawValue, forKey: .unit)
        try container.encode(line.systemUnit, forKey: .systemUnit)
        try container.encode(line.levels.map { level -> StoredLevel in
            switch level.value {
            case .known(let quantity):
                return StoredLevel(location: level.locationID, onHandScaled: quantity.scaled, known: nil, reason: nil, systemUnit: nil)
            case .unknown(let reason):
                var unit: String?
                if case .unmappedUnit(let raw) = reason { unit = raw }
                return StoredLevel(location: level.locationID, onHandScaled: nil, known: false, reason: reason.code, systemUnit: unit)
            }
        }, forKey: .levels)
        try container.encode(line.provenance, forKey: .provenance)
        try container.encodeIfPresent(line.lineAsOf.map { Int($0.timeIntervalSince1970.rounded(.down)) }, forKey: .lineAsOf)
        try container.encodeIfPresent(line.price, forKey: .price)
        try container.encodeIfPresent(line.reorderPoint?.scaled, forKey: .reorderPointScaled)
        try container.encodeIfPresent(line.decimalPlaces, forKey: .decimalPlaces)
    }
}
