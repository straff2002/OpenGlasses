import Foundation

/// One of the system's locations as a connector hands it over: all strings (Plan MM P0).
struct StockSystemRawLocation: Codable, Equatable, Sendable {
    let id: String
    let name: String
    /// HF's class word, when the connector can say one; anything else reads as `other`.
    let locationClass: String?

    init(id: String, name: String, locationClass: String? = nil) {
        self.id = id
        self.name = name
        self.locationClass = locationClass
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case locationClass = "class"
    }
}

/// One item as a connector hands it over, already out of the system's own response shape and
/// still all strings (Plan MM P0). The builder decides what of it can be believed.
struct StockSystemRawRow: Codable, Equatable, Sendable {

    struct Level: Codable, Equatable, Sendable {
        let location: String
        /// The system's figure as decimal text, or nil when it gives none.
        let quantity: String?

        init(location: String, quantity: String?) {
            self.location = location
            self.quantity = quantity
        }
    }

    let itemID: String
    let part: String?
    let description: String?
    /// The unit as the system writes it: "ea", "litre".
    let unit: String
    let levels: [Level]
    /// When the system dated the figure, ISO 8601, if it does.
    let asOf: String?
    let price: String?
    let currency: String?
    let reorderPoint: String?
    /// The most decimal places the system keeps for the item, when it says.
    let decimalPlaces: Int?

    init(itemID: String, part: String?, description: String?, unit: String, levels: [Level],
         asOf: String? = nil, price: String? = nil, currency: String? = nil, reorderPoint: String? = nil,
         decimalPlaces: Int? = nil) {
        self.decimalPlaces = decimalPlaces
        self.itemID = itemID
        self.part = part
        self.description = description
        self.unit = unit
        self.levels = levels
        self.asOf = asOf
        self.price = price
        self.currency = currency
        self.reorderPoint = reorderPoint
    }
}

/// Builds a `StockSystemSnapshot` from a connector's raw rows (Plan MM §2). Pure.
///
/// - Text is capped; an identifier over its cap makes the row unreadable instead.
/// - A row that cannot be read (no item id, a repeated item id, neither part nor description, a
///   date that is not ISO 8601) is dropped and counted.
/// - Quantities go through `StockSystemQuantityConversion`, so a figure the phone cannot hold
///   exactly is unknown with its reason, never rounded and never zero.
/// - It stops at `lineCap` lines and says how many it left out.
/// - A price is dropped unless prices are enabled (Decision 9).
/// - The item's decimal places are kept when the system says them and they are in
///   `StockSystemPolicy.decimalPlacesRange`; otherwise dropped, which is no extra limit.
/// - `asOf` is the oldest date the system put on its figures, when it dates them, otherwise the
///   time the pull finished. A date after the pull (a clock out of step) counts as the pull time.
struct StockSystemSnapshotBuilder {

    struct Result: Equatable, Sendable {
        let snapshot: StockSystemSnapshot
        /// Rows dropped as unreadable.
        let malformedRows: Int
        /// Readable rows left out because the snapshot was full.
        let leftOut: Int

        /// What was not taken, for the person and the support report; nil when everything was.
        var summary: String? {
            var parts: [String] = []
            if malformedRows > 0 {
                parts.append(malformedRows == 1 ? "1 row could not be read and was left out"
                                                : "\(malformedRows) rows could not be read and were left out")
            }
            if leftOut > 0 {
                let cap = StockSystemPolicy.lineCap
                parts.append(leftOut == 1 ? "1 line over the \(cap)-line limit was left out"
                                          : "\(leftOut) lines over the \(cap)-line limit were left out")
            }
            guard !parts.isEmpty else { return nil }
            return "From \(snapshot.source.displayName): " + parts.joined(separator: "; ") + "."
        }
    }

    let source: StockSystemSource
    let unitMap: StockSystemUnitMap
    var pricesEnabled = StockSystemPolicy.pricesEnabledByDefault
    var lineCap = StockSystemPolicy.lineCap

    func build(locations rawLocations: [StockSystemRawLocation], rows: [StockSystemRawRow], pulledAt: Date) -> Result {
        let pulled = Self.wholeSecond(pulledAt)

        var locations: [StockSystemLocation] = []
        var locationIDs = Set<String>()
        for raw in rawLocations {
            let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= StockSystemPolicy.Cap.identifier, locationIDs.insert(id).inserted else { continue }
            let name = Self.capped(raw.name, StockSystemPolicy.Cap.locationName) ?? id
            locations.append(StockSystemLocation(id: id, name: name,
                                                 locationClass: .init(lenient: raw.locationClass)))
        }

        var lines: [StockSystemSnapshot.Line] = []
        var itemIDs = Set<String>()
        var malformed = 0
        var leftOut = 0
        var oldest: Date?
        for row in rows {
            guard let line = line(row, locations: locationIDs, pulledAt: pulled),
                  itemIDs.insert(line.itemID).inserted else {
                malformed += 1
                continue
            }
            guard lines.count < lineCap else {
                leftOut += 1
                continue
            }
            lines.append(line)
            if let dated = line.lineAsOf { oldest = min(oldest ?? dated, dated) }
        }

        let snapshot = StockSystemSnapshot(source: source, asOf: oldest ?? pulled, locations: locations, lines: lines)
        return Result(snapshot: snapshot, malformedRows: malformed, leftOut: leftOut)
    }

    /// One row as a line, or nil when it cannot be read.
    private func line(_ row: StockSystemRawRow, locations: Set<String>, pulledAt: Date) -> StockSystemSnapshot.Line? {
        let itemID = row.itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty, itemID.count <= StockSystemPolicy.Cap.identifier else { return nil }
        let part = Self.capped(row.part, StockSystemPolicy.Cap.part)
        let description = Self.capped(row.description, StockSystemPolicy.Cap.description) ?? ""
        guard part != nil || !description.isEmpty else { return nil }

        var lineAsOf: Date?
        if let raw = row.asOf?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let date = Self.date(raw) else { return nil }
            lineAsOf = min(Self.wholeSecond(date), pulledAt)
        }

        let systemUnit = String(row.unit.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StockSystemPolicy.Cap.systemUnit))
        let unit = unitMap.unit(for: systemUnit)

        // Only the snapshot's locations; a level elsewhere is ignored, and the first figure for a
        // location stands.
        var levels: [StockSystemSnapshot.Level] = []
        var seen = Set<String>()
        for level in row.levels {
            let location = level.location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard locations.contains(location), seen.insert(location).inserted else { continue }
            let value = unit.map { StockSystemQuantityConversion.incoming(level.quantity, unit: $0) }
                ?? .unknown(.unmappedUnit(systemUnit))
            levels.append(.init(locationID: location, value: value))
        }

        let reorderPoint = unit.flatMap { StockSystemQuantityConversion.incoming(row.reorderPoint, unit: $0).quantity }
        let price = pricesEnabled ? StockSystemPrice(amount: row.price, currency: row.currency) : nil

        return StockSystemSnapshot.Line(itemID: itemID, part: part, description: description, unit: unit,
                                        systemUnit: systemUnit, levels: levels, provenance: .system,
                                        lineAsOf: lineAsOf, price: price, reorderPoint: reorderPoint,
                                        decimalPlaces: row.decimalPlaces)
    }

    private static func capped(_ raw: String?, _ cap: Int) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(cap))
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// ISO 8601 with a zone, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
