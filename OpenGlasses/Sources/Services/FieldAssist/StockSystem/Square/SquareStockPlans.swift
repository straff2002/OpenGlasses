import Foundation

// Square's three multi-request reads as pure state machines (`StockSystemPullPlan`): the
// locations, a snapshot (locations → catalogue pages → count pages), and a read-back (history
// pages per location and per 500 items).

// MARK: - Locations

/// `GET /v2/locations`, one request. Active locations only, for "Which stock is here?". A
/// physical location reads as a base, a mobile one as a van.
struct SquareLocationsPlan: StockSystemPullPlan {

    let adapter: SquareStockAdapter
    private var asked = false
    private(set) var result: [StockSystemLocation]?

    init(adapter: SquareStockAdapter) {
        self.adapter = adapter
    }

    mutating func next() throws -> StockSystemRequest? {
        guard !asked else { return nil }
        asked = true
        return try adapter.request(SquareStockAdapter.Endpoint.locations)
    }

    mutating func consume(_ response: StockSystemResponse) throws {
        if let failure = adapter.failure(response, endpoint: SquareStockAdapter.Endpoint.locations) { throw failure }
        result = try Self.locations(response.body, activeOnly: true).map {
            StockSystemLocation(id: $0.id, name: $0.name, locationClass: .init(lenient: $0.locationClass))
        }
    }

    /// The body's locations, readable ones only, at most `maximumLocations × 10`.
    static func locations(_ body: Data, activeOnly: Bool) throws -> [StockSystemRawLocation] {
        let decoded = try SquareStockAdapter.decode(SquareWire.LocationsBody.self, from: body)
        var seen = Set<String>()
        var locations: [StockSystemRawLocation] = []
        for location in (decoded.locations ?? []).compactMap(\.value) {
            let id = location.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SquareStockAdapter.isSquareID(id), seen.insert(id).inserted else { continue }
            if activeOnly, location.status != "ACTIVE" { continue }
            let name = location.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let locationClass: String? = switch location.type {
            case "PHYSICAL": "base"
            case "MOBILE": "van"
            default: nil
            }
            locations.append(StockSystemRawLocation(
                id: id, name: String((name?.isEmpty == false ? name! : id).prefix(StockSystemPolicy.Cap.locationName)),
                locationClass: locationClass))
            if locations.count >= SquareStockAdapter.maximumLocations * 10 { break }
        }
        return locations
    }
}

// MARK: - Snapshot

/// A whole snapshot of the chosen locations:
///
/// 1. `GET /v2/locations`, to name the chosen locations (a chosen location Square no longer has is
///    left out; none left is `notFound`).
/// 2. `POST /v2/catalog/search` for `ITEM_VARIATION` and `MEASUREMENT_UNIT` objects, with related
///    objects (the parent `ITEM`, for its name), page by page.
/// 3. `POST /v2/inventory/counts/batch-retrieve` for the chosen locations' `IN_STOCK` counts, page
///    by page.
///
/// Then each tracked variation present at a chosen location becomes a line. Skipped: deleted
/// objects, variations tracked at none of the chosen locations (`track_inventory` false, or unset
/// at both the location and the variation), and variations not offered at any chosen location. A
/// tracked variation with no count at a location has an unknown figure there, never zero.
///
/// Square's `calculated_at` says when a count last changed, not how old the reading is, so it does
/// not date the line: the snapshot is as of the pull.
struct SquareSnapshotPlan: StockSystemPullPlan {

    private enum Stage: Equatable {
        case locations
        case catalogue(cursor: String?)
        case counts(cursor: String?)
        case done
    }

    private struct Variation {
        let object: SquareWire.CatalogObject
        let data: SquareWire.VariationData
    }

    private struct UnitRecord {
        let unit: SquareUnitMap.Unit
        let precision: Int?
    }

    let adapter: SquareStockAdapter
    let locationIDs: [String]
    let pulledAt: Date
    let accountLabel: String?
    let pricesEnabled: Bool

    private var stage = Stage.locations
    private var pages = 0
    private var cursors = Set<String>()
    private var locations: [StockSystemRawLocation] = []
    private var variations: [Variation] = []
    private var variationIDs = Set<String>()
    private var itemNames: [String: String] = [:]
    private var deletedItems = Set<String>()
    private var units: [String: UnitRecord] = [:]
    private var counts: [String: [String: String]] = [:]
    private var skipped = StockSystemSnapshotPull.Skipped()
    private(set) var result: StockSystemSnapshotPull?

    init(adapter: SquareStockAdapter, locationIDs: [String], pulledAt: Date, accountLabel: String?, pricesEnabled: Bool) {
        self.adapter = adapter
        var seen = Set<String>()
        self.locationIDs = Array(locationIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { SquareStockAdapter.isSquareID($0) && seen.insert($0).inserted }
            .prefix(SquareStockAdapter.maximumLocations))
        self.pulledAt = pulledAt
        self.accountLabel = accountLabel
        self.pricesEnabled = pricesEnabled
    }

    mutating func next() throws -> StockSystemRequest? {
        switch stage {
        case .locations:
            guard !locationIDs.isEmpty else { throw StockSystemFailure.notFound }
            return try adapter.request(SquareStockAdapter.Endpoint.locations)
        case .catalogue(let cursor):
            var body: [String: Any] = [
                "object_types": ["ITEM_VARIATION", "MEASUREMENT_UNIT"],
                "include_related_objects": true,
                "include_deleted_objects": false,
                "limit": SquareStockAdapter.pageLimit,
            ]
            if let cursor { body["cursor"] = cursor }
            return try adapter.request(SquareStockAdapter.Endpoint.catalogSearch, body: body)
        case .counts(let cursor):
            var body: [String: Any] = [
                "location_ids": locations.map(\.id),
                "states": ["IN_STOCK"],
                "limit": SquareStockAdapter.pageLimit,
            ]
            if let cursor { body["cursor"] = cursor }
            return try adapter.request(SquareStockAdapter.Endpoint.inventoryCounts, body: body)
        case .done:
            return nil
        }
    }

    mutating func consume(_ response: StockSystemResponse) throws {
        switch stage {
        case .locations:
            if let failure = adapter.failure(response, endpoint: SquareStockAdapter.Endpoint.locations) { throw failure }
            let all = try SquareLocationsPlan.locations(response.body, activeOnly: false)
            locations = locationIDs.compactMap { id in all.first { $0.id == id } }
            guard !locations.isEmpty else { throw StockSystemFailure.notFound }
            stage = .catalogue(cursor: nil)
        case .catalogue:
            if let failure = adapter.failure(response, endpoint: SquareStockAdapter.Endpoint.catalogSearch) { throw failure }
            let page = try SquareStockAdapter.decode(SquareWire.CatalogPage.self, from: response.body)
            take(page)
            stage = try advance(page.cursor).map { .catalogue(cursor: $0) } ?? .counts(cursor: nil)
            if case .counts = stage { pages = 0 }
        case .counts:
            if let failure = adapter.failure(response, endpoint: SquareStockAdapter.Endpoint.inventoryCounts) { throw failure }
            let page = try SquareStockAdapter.decode(SquareWire.CountsPage.self, from: response.body)
            take(page)
            if let cursor = try advance(page.cursor) {
                stage = .counts(cursor: cursor)
            } else {
                stage = .done
                result = assemble()
            }
        case .done:
            throw StockSystemFailure.malformedResponse
        }
    }

    /// The next cursor, refusing a repeated one (a loop) and a pull past the page budget.
    private mutating func advance(_ raw: String?) throws -> String? {
        pages += 1
        guard let cursor = try SquareStockAdapter.cursor(raw) else { return nil }
        guard cursors.insert(cursor).inserted else { throw StockSystemFailure.malformedResponse }
        guard pages < SquareStockAdapter.pageBudget else { throw StockSystemFailure.tooLarge }
        return cursor
    }

    private mutating func take(_ page: SquareWire.CatalogPage) {
        let objects = page.objects ?? []
        let related = page.relatedObjects ?? []
        skipped.unreadable += objects.filter { $0.value == nil }.count
        for object in (objects + related).compactMap(\.value) {
            let id = object.id.trimmingCharacters(in: .whitespacesAndNewlines)
            switch object.type {
            case "ITEM":
                if object.isDeleted == true { deletedItems.insert(id) }
                if let name = object.itemData?.name { itemNames[id] = name }
            case "MEASUREMENT_UNIT":
                guard object.isDeleted != true, let data = object.measurementUnitData else { continue }
                units[id] = UnitRecord(unit: Self.unit(data.measurementUnit), precision: data.precision)
            default:
                continue
            }
        }
        for object in objects.compactMap(\.value) where object.type == "ITEM_VARIATION" {
            let id = object.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = object.itemVariationData, SquareStockAdapter.isSquareID(id) else {
                skipped.unreadable += 1
                continue
            }
            guard variationIDs.insert(id).inserted else { continue }
            if object.isDeleted == true {
                skipped.deleted += 1
                continue
            }
            variations.append(Variation(object: object, data: data))
        }
    }

    private mutating func take(_ page: SquareWire.CountsPage) {
        let chosen = Set(locations.map(\.id))
        for entry in page.counts ?? [] {
            guard let count = entry.value else {
                skipped.unreadable += 1
                continue
            }
            // Only on-hand figures at the chosen locations; any other state is not stock here.
            guard count.state == "IN_STOCK", chosen.contains(count.locationId),
                  count.catalogObjectType == nil || count.catalogObjectType == "ITEM_VARIATION" else { continue }
            guard variationIDs.contains(count.catalogObjectId) else {
                skipped.unreadable += 1
                continue
            }
            // The first figure for an item and location stands.
            if counts[count.catalogObjectId]?[count.locationId] == nil {
                counts[count.catalogObjectId, default: [:]][count.locationId] = count.quantity
            }
        }
    }

    private mutating func assemble() -> StockSystemSnapshotPull {
        var rows: [StockSystemRawRow] = []
        var resolved: [String: VanStockUnit?] = [:]
        var conflicted = Set<String>()
        for variation in variations {
            let id = variation.object.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let data = variation.data
            if let item = data.itemId, deletedItems.contains(item) {
                skipped.deleted += 1
                continue
            }
            let present = locations.filter { variation.object.isPresent(at: $0.id) }
            guard !present.isEmpty else {
                skipped.notHere += 1
                continue
            }
            let tracked = present.filter { Self.isTracked(data, at: $0.id) }
            guard !tracked.isEmpty else {
                skipped.untracked += 1
                continue
            }

            let (resolution, places) = unitAndPlaces(data.measurementUnitId)
            if let earlier = resolved[resolution.systemUnit], earlier != resolution.unit {
                conflicted.insert(resolution.systemUnit)
            } else {
                resolved[resolution.systemUnit] = resolution.unit
            }

            rows.append(StockSystemRawRow(
                itemID: id,
                part: data.sku,
                description: description(data),
                unit: resolution.systemUnit,
                levels: tracked.map { .init(location: $0.id, quantity: counts[id]?[$0.id]) },
                price: pricesEnabled ? Self.price(data) : nil,
                currency: pricesEnabled ? data.priceMoney?.currency : nil,
                reorderPoint: Self.reorderPoint(data, at: tracked.map(\.id)),
                decimalPlaces: places))
        }

        // The pull's own table: each word this pull produced, onto what it means. A word that
        // came out of two different units is not trusted for either.
        var table: [String: VanStockUnit] = [:]
        for (word, unit) in resolved where !conflicted.contains(word) {
            if let unit { table[word] = unit }
        }
        var builder = StockSystemSnapshotBuilder(
            source: StockSystemSource(connectorID: adapter.connectorID, displayName: adapter.displayName,
                                      accountLabel: accountLabel),
            unitMap: StockSystemUnitMap(table))
        builder.pricesEnabled = pricesEnabled
        return StockSystemSnapshotPull(build: builder.build(locations: locations, rows: rows, pulledAt: pulledAt),
                                       skipped: skipped)
    }

    /// The variation's unit and the decimal places Square keeps for it: none named is whole items
    /// (0); a named unit keeps its precision (0–5, 3 when unset); a unit the pull did not see is
    /// not kept, with no limit said.
    private func unitAndPlaces(_ unitID: String?) -> (SquareUnitMap.Resolution, Int?) {
        guard let unitID = unitID?.trimmingCharacters(in: .whitespacesAndNewlines), !unitID.isEmpty else {
            return (SquareUnitMap.resolve(.none), 0)
        }
        guard let record = units[unitID] else { return (SquareUnitMap.resolve(.unreadable), nil) }
        let precision = record.precision ?? 3
        return (SquareUnitMap.resolve(record.unit), (0...5).contains(precision) ? precision : nil)
    }

    /// "Coolant concentrate, Bulk": the item's name, and the variation's when it adds something.
    /// Square names a single variation "Regular", which adds nothing.
    private func description(_ data: SquareWire.VariationData) -> String {
        let item = data.itemId.flatMap { itemNames[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let variation = data.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if item.isEmpty { return variation }
        if variation.isEmpty || variation.lowercased() == item.lowercased() || variation.lowercased() == "regular" {
            return item
        }
        return "\(item), \(variation)"
    }

    static func unit(_ unit: SquareWire.MeasurementUnit?) -> SquareUnitMap.Unit {
        guard let unit else { return .unreadable }
        if let custom = unit.customUnit, unit.type == nil || unit.type == "TYPE_CUSTOM" {
            return .custom(name: custom.name ?? "", abbreviation: custom.abbreviation ?? "")
        }
        let standard = [unit.areaUnit, unit.lengthUnit, unit.volumeUnit, unit.weightUnit, unit.genericUnit, unit.timeUnit]
            .compactMap { $0 }
        guard standard.count == 1, unit.customUnit == nil else { return .unreadable }
        return .standard(standard[0])
    }

    /// Tracked at a location: the location's own setting, else the variation's, else not tracked.
    static func isTracked(_ data: SquareWire.VariationData, at location: String) -> Bool {
        let override = data.locationOverrides?.compactMap(\.value).first { $0.locationId == location }
        return override?.trackInventory ?? data.trackInventory ?? false
    }

    /// Square's low-stock alert (`LOW_QUANTITY` at a threshold), the location's own before the
    /// variation's. Kept only when every tracked chosen location says the same.
    static func reorderPoint(_ data: SquareWire.VariationData, at locations: [String]) -> String? {
        let thresholds = locations.map { location -> Int64? in
            let override = data.locationOverrides?.compactMap(\.value).first { $0.locationId == location }
            let type = override?.inventoryAlertType ?? data.inventoryAlertType
            guard type == "LOW_QUANTITY" else { return nil }
            return override?.inventoryAlertThreshold ?? data.inventoryAlertThreshold
        }
        guard let first = thresholds.first, let value = first, value >= 0,
              thresholds.allSatisfy({ $0 == value }) else { return nil }
        return String(value)
    }

    /// The minor units each currency has, for the ones Square's sellers use. Another currency is
    /// dropped rather than guessed at.
    static let currencyExponent: [String: Int] = ["AUD": 2, "CAD": 2, "EUR": 2, "GBP": 2, "JPY": 0, "NZD": 2, "USD": 2]

    /// A fixed price as decimal text: Square gives the amount in the currency's smallest unit.
    static func price(_ data: SquareWire.VariationData) -> String? {
        guard data.pricingType != "VARIABLE_PRICING", let money = data.priceMoney, let amount = money.amount,
              amount >= 0, let currency = money.currency, let exponent = currencyExponent[currency] else { return nil }
        guard exponent > 0 else { return String(amount) }
        var divisor: Int64 = 1
        for _ in 0..<exponent { divisor *= 10 }
        let fraction = String(amount % divisor)
        return "\(amount / divisor)." + String(repeating: "0", count: exponent - fraction.count) + fraction
    }
}

// MARK: - A few lines

/// The current `IN_STOCK` counts of a few variations at the chosen locations, for a `check` while
/// the snapshot is old: `POST /v2/inventory/counts/batch-retrieve` with `catalog_object_ids`, page
/// by page. A count for anything not asked, at a location not asked, or in another state is not
/// this read's and is left out; the first figure for an item and location stands, as in a pull.
struct SquareLinesPlan: StockSystemPullPlan {

    let adapter: SquareStockAdapter
    let itemIDs: [String]
    let locationIDs: [String]
    private var cursor: String?
    private var pages = 0
    private var cursors = Set<String>()
    private var counts: [String: [String: String]] = [:]
    private(set) var result: StockSystemFreshLines?

    init(adapter: SquareStockAdapter, itemIDs: [String], locationIDs: [String]) throws {
        self.adapter = adapter
        var seenItems = Set<String>(), seenLocations = Set<String>()
        let items = itemIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { seenItems.insert($0).inserted }
        let locations = locationIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { seenLocations.insert($0).inserted }
        guard items.allSatisfy(SquareStockAdapter.isSquareID), locations.allSatisfy(SquareStockAdapter.isSquareID),
              items.count <= SquareStockAdapter.itemsPerLinesRead, locations.count <= SquareStockAdapter.maximumLocations
        else { throw StockSystemRequestRefusal.notAllowed }
        guard !locations.isEmpty || items.isEmpty else { throw StockSystemFailure.notFound }
        self.itemIDs = items
        self.locationIDs = locations
        if items.isEmpty { result = StockSystemFreshLines(itemIDs: [], locationIDs: locations, counts: [:]) }
    }

    mutating func next() throws -> StockSystemRequest? {
        guard result == nil else { return nil }
        var body: [String: Any] = [
            "catalog_object_ids": itemIDs,
            "location_ids": locationIDs,
            "states": ["IN_STOCK"],
            "limit": SquareStockAdapter.pageLimit,
        ]
        if let cursor { body["cursor"] = cursor }
        return try adapter.request(SquareStockAdapter.Endpoint.inventoryCounts, body: body)
    }

    mutating func consume(_ response: StockSystemResponse) throws {
        guard result == nil else { throw StockSystemFailure.malformedResponse }
        if let failure = adapter.failure(response, endpoint: SquareStockAdapter.Endpoint.inventoryCounts) { throw failure }
        let page = try SquareStockAdapter.decode(SquareWire.CountsPage.self, from: response.body)
        let items = Set(itemIDs), places = Set(locationIDs)
        for count in (page.counts ?? []).compactMap(\.value) {
            guard count.state == "IN_STOCK", items.contains(count.catalogObjectId), places.contains(count.locationId),
                  count.catalogObjectType == nil || count.catalogObjectType == "ITEM_VARIATION",
                  counts[count.catalogObjectId]?[count.locationId] == nil else { continue }
            counts[count.catalogObjectId, default: [:]][count.locationId] = count.quantity
        }
        pages += 1
        if let next = try SquareStockAdapter.cursor(page.cursor) {
            guard cursors.insert(next).inserted else { throw StockSystemFailure.malformedResponse }
            guard pages < SquareStockAdapter.pageBudget else { throw StockSystemFailure.tooLarge }
            cursor = next
        } else {
            result = StockSystemFreshLines(itemIDs: itemIDs, locationIDs: locationIDs, counts: counts)
        }
    }
}

// MARK: - Read-back

/// Which of the plan's adjustments Square already shows: `POST /v2/inventory/changes/batch-retrieve`
/// for `ADJUSTMENT`s at each location, for at most 500 items at a time, since a little before the
/// batch was queued, page by page.
///
/// A change counts as applied only when its `reference_id` is the step's key and it is the step:
/// `IN_STOCK` to `WASTE`, the same item, from and to the step's location, the same amount. A change
/// under the key that differs in any of those, or a key that shows twice, is a mismatch for a
/// person to look at, never trusted and never sent again.
struct SquareReadBackPlan: StockSystemPullPlan {

    private struct Query {
        let locationID: String
        let itemIDs: [String]
    }

    let adapter: SquareStockAdapter
    private let steps: [String: PartsUsedWritePlan.Adjustment]
    private let queries: [Query]
    private let updatedAfter: String
    private var index = 0
    private var cursor: String?
    private var pages = 0
    private var cursors = Set<String>()
    private var seenChanges = Set<String>()
    private var found: [String: [StockSystemReadBack.Mismatch.Difference?]] = [:]
    private(set) var result: StockSystemReadBack?

    init(adapter: SquareStockAdapter, steps: [PartsUsedWritePlan.Step], updatedAfter: Date) {
        self.adapter = adapter
        var byKey: [String: PartsUsedWritePlan.Adjustment] = [:]
        var order: [String] = []
        var items: [String: [String]] = [:]
        for step in steps {
            guard case .adjustment(let adjustment) = step else { continue }
            byKey[adjustment.idempotencyKey] = adjustment
            if items[adjustment.locationID] == nil { order.append(adjustment.locationID) }
            if !(items[adjustment.locationID] ?? []).contains(adjustment.itemID) {
                items[adjustment.locationID, default: []].append(adjustment.itemID)
            }
        }
        self.steps = byKey
        self.queries = order.flatMap { location -> [Query] in
            let ids = items[location] ?? []
            return stride(from: 0, to: ids.count, by: SquareStockAdapter.itemsPerHistoryRead).map {
                Query(locationID: location, itemIDs: Array(ids[$0..<min($0 + SquareStockAdapter.itemsPerHistoryRead, ids.count)]))
            }
        }
        self.updatedAfter = SquareStockAdapter.timestamp(updatedAfter)
        if queries.isEmpty { result = StockSystemReadBack(applied: []) }
    }

    mutating func next() throws -> StockSystemRequest? {
        guard result == nil, index < queries.count else { return nil }
        let query = queries[index]
        var body: [String: Any] = [
            "types": ["ADJUSTMENT"],
            "location_ids": [query.locationID],
            "catalog_object_ids": query.itemIDs,
            "updated_after": updatedAfter,
            "limit": SquareStockAdapter.pageLimit,
        ]
        if let cursor { body["cursor"] = cursor }
        return try adapter.request(SquareStockAdapter.Endpoint.inventoryChanges, body: body)
    }

    mutating func consume(_ response: StockSystemResponse) throws {
        guard result == nil else { throw StockSystemFailure.malformedResponse }
        if let failure = adapter.failure(response, endpoint: SquareStockAdapter.Endpoint.inventoryChanges) { throw failure }
        let page = try SquareStockAdapter.decode(SquareWire.ChangesPage.self, from: response.body)
        for change in (page.changes ?? []).compactMap(\.value) {
            guard change.type == "ADJUSTMENT", let adjustment = change.adjustment,
                  let key = adjustment.referenceId, let expected = steps[key] else { continue }
            if let id = adjustment.id, !seenChanges.insert(id).inserted { continue }
            found[key, default: []].append(Self.difference(adjustment, expected))
        }
        pages += 1
        if let next = try SquareStockAdapter.cursor(page.cursor) {
            guard cursors.insert(next).inserted else { throw StockSystemFailure.malformedResponse }
            guard pages < SquareStockAdapter.pageBudget else { throw StockSystemFailure.tooLarge }
            cursor = next
        } else {
            cursor = nil
            pages = 0
            index += 1
            if index >= queries.count { result = settle() }
        }
    }

    private func settle() -> StockSystemReadBack {
        var applied = Set<String>()
        var mismatched: [StockSystemReadBack.Mismatch] = []
        for key in found.keys.sorted() {
            let entries = found[key] ?? []
            if entries.count > 1 {
                mismatched.append(.init(idempotencyKey: key, difference: .duplicate))
            } else if let only = entries.first {
                if let difference = only {
                    mismatched.append(.init(idempotencyKey: key, difference: difference))
                } else {
                    applied.insert(key)
                }
            }
        }
        return StockSystemReadBack(applied: applied, mismatched: mismatched)
    }

    /// How a change under a step's key differs from the step, or nil when it is the step.
    static func difference(_ change: SquareWire.Adjustment,
                           _ step: PartsUsedWritePlan.Adjustment) -> StockSystemReadBack.Mismatch.Difference? {
        guard change.fromState == "IN_STOCK", change.toState == "WASTE" else { return .movement }
        guard change.catalogObjectId == step.itemID else { return .item }
        guard change.fromLocationId == step.locationID, change.toLocationId == step.locationID else { return .location }
        guard let text = change.quantity, let shown = amount(text), let sent = amount(step.quantity), shown == sent else {
            return .quantity
        }
        return nil
    }

    /// An amount compared digit by digit, with Square's trailing zeros ("0.50000") allowed.
    private static func amount(_ text: String) -> StockQuantity? {
        if case .success(let quantity) = StockQuantity.parse(text, unit: .l) { return quantity }
        return nil
    }
}
