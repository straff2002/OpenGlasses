import Foundation

/// Square, as a stock system with no jobs (Plan MM P1). The thin adapter only: its five endpoints,
/// its requests, its response shapes, its units, what it can take back and how its own writes are
/// recognised. Pure; it never sees the key. Built from Square's public API reference and synthetic
/// fixtures (`Contracts/fixtures/square-v2/`), and qualified against a live account later.
///
/// The one write is an inventory adjustment from `IN_STOCK` to `WASTE` at the chosen location,
/// carrying the phone's per-step idempotency key in `reference_id`. It never writes a physical
/// count, a transfer, a sale, a price or anything in the catalogue.
struct SquareStockAdapter: StockSystemAdapter {

    /// The API version every request pins: the first with an adjustment's `from_location_id` and
    /// `to_location_id` (and without its `location_id`).
    static let squareVersion = "2026-07-15"

    /// Square refuses an adjustment that says it happened more than 24 hours ago; an hour short of
    /// that leaves room for a slow send and a clock out of step.
    static let maximumOccurredAge: TimeInterval = 23 * 60 * 60

    /// At most this many changes go in one write (Square's limit).
    static let changesPerWrite = 100
    /// At most this many items are named in one history read (Square's limit).
    static let itemsPerHistoryRead = 500
    /// At most this many items are asked for in one check of a few lines: a check names one or a
    /// handful, so anything more is refused rather than paged.
    static let itemsPerLinesRead = 100
    /// The page size asked for on every paged read (Square's maximum).
    static let pageLimit = 1000
    /// The most pages one paged read may take before the pull is refused as too large.
    static let pageBudget = 40
    /// The largest response body read; anything larger is refused as too large.
    static let maximumResponseBytes = 8_000_000
    /// The most locations a pull names.
    static let maximumLocations = 50
    /// How far before the batch was queued a read-back looks.
    static let readBackMargin: TimeInterval = 5 * 60

    enum Endpoint {
        static let locations = StockSystemEndpoint(.get, "/v2/locations", purpose: .locations, scope: "MERCHANT_PROFILE_READ")
        static let catalogSearch = StockSystemEndpoint(.post, "/v2/catalog/search", purpose: .catalogue, scope: "ITEMS_READ")
        static let inventoryCounts = StockSystemEndpoint(.post, "/v2/inventory/counts/batch-retrieve", purpose: .stock,
                                                         scope: "INVENTORY_READ")
        static let inventoryChanges = StockSystemEndpoint(.post, "/v2/inventory/changes/batch-retrieve", purpose: .history,
                                                          scope: "INVENTORY_READ")
        static let inventoryWrite = StockSystemEndpoint(.post, "/v2/inventory/changes/batch-create", purpose: .write,
                                                        scope: "INVENTORY_WRITE")

        static let all = [locations, catalogSearch, inventoryCounts, inventoryChanges, inventoryWrite]
    }

    let connectorID = "square"
    let displayName = "Square"
    let hosts = StockSystemHosts(production: "connect.squareup.com", sandbox: "connect.squareupsandbox.com")
    var allowedEndpoints: [StockSystemEndpoint] { Endpoint.all }
    var unitMap: StockSystemUnitMap { SquareUnitMap.table }
    var maximumResponseBytes: Int { Self.maximumResponseBytes }

    /// No jobs; decimals per item (`decimalPlaces`); one reason, `waste` (`IN_STOCK` → `WASTE`);
    /// no note field, because `reference_id` carries the idempotency key.
    func capabilities(chosenReason: StockAdjustmentReason?) -> StockSystemCapabilities {
        StockSystemCapabilities(connectorID: connectorID, displayName: displayName, hasJobs: false,
                                wholeNumbersOnly: false, adjustmentReasons: [.waste], chosenReason: chosenReason,
                                adjustmentNote: false)
    }

    // MARK: - Reads

    func locationsPlan() -> any StockSystemPullPlan<[StockSystemLocation]> {
        SquareLocationsPlan(adapter: self)
    }

    /// Test connection's reads beside the locations: one `IN_STOCK` count and one item variation,
    /// stock first. Each is a page of one, so a key without the permission is named and nothing is
    /// pulled.
    func probeRequests() throws -> [StockSystemRequest] {
        [
            try request(Endpoint.inventoryCounts, body: ["states": ["IN_STOCK"], "limit": 1]),
            try request(Endpoint.catalogSearch, body: ["object_types": ["ITEM_VARIATION"], "limit": 1]),
        ]
    }

    func snapshotPlan(locationIDs: [String], pulledAt: Date, accountLabel: String?,
                      pricesEnabled: Bool) -> any StockSystemPullPlan<StockSystemSnapshotPull> {
        SquareSnapshotPlan(adapter: self, locationIDs: locationIDs, pulledAt: pulledAt, accountLabel: accountLabel,
                           pricesEnabled: pricesEnabled)
    }

    /// `POST /v2/inventory/counts/batch-retrieve` for just these variations' `IN_STOCK` counts at
    /// the chosen locations: the snapshot's stock endpoint with `catalog_object_ids`, so still one
    /// of the five.
    func linesPlan(itemIDs: [String], locationIDs: [String]) throws -> any StockSystemPullPlan<StockSystemFreshLines> {
        try SquareLinesPlan(adapter: self, itemIDs: itemIDs, locationIDs: locationIDs)
    }

    func readBackPlan(_ plan: PartsUsedWritePlan, queuedAt: Date) -> any StockSystemPullPlan<StockSystemReadBack> {
        SquareReadBackPlan(adapter: self, steps: plan.steps, updatedAfter: queuedAt.addingTimeInterval(-Self.readBackMargin))
    }

    // MARK: - The one write

    func writeRequests(for steps: [PartsUsedWritePlan.Step], occurredAt: Date, now: Date) throws -> [StockSystemWriteRequest] {
        let adjustments = try steps.map { step -> PartsUsedWritePlan.Adjustment in
            guard case .adjustment(let adjustment) = step, adjustment.reason == .waste,
                  Self.isSquareID(adjustment.itemID), Self.isSquareID(adjustment.locationID),
                  !adjustment.idempotencyKey.isEmpty, adjustment.idempotencyKey.count <= 255,
                  case .success(let quantity) = StockQuantity.parse(adjustment.quantity, unit: adjustment.unit),
                  quantity > .zero, quantity.decimalString == adjustment.quantity
            else { throw StockSystemRequestRefusal.notAllowed }
            return adjustment
        }
        guard Set(adjustments.map(\.idempotencyKey)).count == adjustments.count else { throw StockSystemRequestRefusal.notAllowed }
        let occurred = Self.timestamp(StockSystemIdempotency.occurredAt(confirmedAt: occurredAt, now: now,
                                                                        maximumAge: Self.maximumOccurredAge))
        return try stride(from: 0, to: adjustments.count, by: Self.changesPerWrite).map { start in
            let chunk = Array(adjustments[start..<min(start + Self.changesPerWrite, adjustments.count)])
            let batchKey = StockSystemIdempotency.batchKey(stepKeys: chunk.map(\.idempotencyKey))
            let changes: [[String: Any]] = chunk.map { adjustment in
                [
                    "type": "ADJUSTMENT",
                    "adjustment": [
                        "reference_id": adjustment.idempotencyKey,
                        "catalog_object_id": adjustment.itemID,
                        "from_state": "IN_STOCK",
                        "to_state": "WASTE",
                        "from_location_id": adjustment.locationID,
                        "to_location_id": adjustment.locationID,
                        "quantity": adjustment.quantity,
                        "occurred_at": occurred,
                    ] as [String: Any],
                ]
            }
            let body: [String: Any] = ["idempotency_key": batchKey, "changes": changes]
            let request = try self.request(Endpoint.inventoryWrite, body: body)
            return StockSystemWriteRequest(request: request, steps: chunk.map { .adjustment($0) }, batchKey: batchKey)
        }
    }

    /// A `200` lists the changes it created. Every step must be there, exactly as sent; anything
    /// less is uncertain and throws, so the caller reads back before trying again.
    func acceptedWrite(_ response: StockSystemResponse, for write: StockSystemWriteRequest) throws -> StockSystemReadBack {
        if let failure = failure(response, endpoint: write.request.endpoint) { throw failure }
        let page = try Self.decode(SquareWire.ChangesPage.self, from: response.body)
        let adjustments = (page.changes ?? []).compactMap(\.value).compactMap { $0.type == "ADJUSTMENT" ? $0.adjustment : nil }
        var applied = Set<String>()
        for step in write.steps {
            guard case .adjustment(let expected) = step else { throw StockSystemFailure.malformedResponse }
            let found = adjustments.filter { $0.referenceId == expected.idempotencyKey }
            guard found.count == 1, SquareReadBackPlan.difference(found[0], expected) == nil else {
                throw StockSystemFailure.malformedResponse
            }
            applied.insert(expected.idempotencyKey)
        }
        return StockSystemReadBack(applied: applied)
    }

    // MARK: - Failures

    /// Square's error body is `{"errors":[{"category","code","detail","field"}]}`. The code decides
    /// the category; `detail` is never kept. A 403 for missing scopes does not say which, so the
    /// endpoint names it.
    func failure(_ response: StockSystemResponse, endpoint: StockSystemEndpoint) -> StockSystemFailure? {
        guard !response.succeeded else { return nil }
        let first: SquareWire.Error? = response.body.count <= 65_536
            ? (try? Self.decoder.decode(SquareWire.ErrorBody.self, from: response.body))?.errors?.compactMap(\.value).first
            : nil
        switch response.status {
        case 401:
            switch first?.code {
            case "ACCESS_TOKEN_EXPIRED": return .unauthorized(.expired)
            case "ACCESS_TOKEN_REVOKED": return .unauthorized(.revoked)
            default: return .unauthorized(.invalid)
            }
        case 403:
            return .missingScope(endpoint.scope ?? "needed")
        case 429:
            return .rateLimited(retryAfter: StockSystemFailure.retryAfter(response))
        case 404:
            return .notFound
        case 500...599:
            return .server(status: response.status)
        case 400..<500 where response.status != 413:
            return StockSystemFailure.rejected(systemCode: first?.code, systemField: first?.field)
        default:
            return StockSystemFailure.forStatus(response.status, endpoint: endpoint) ?? .malformedResponse
        }
    }

    // MARK: - Pieces

    /// A request on one of the five endpoints, with Square's version header and a JSON body.
    func request(_ endpoint: StockSystemEndpoint, body: [String: Any]? = nil) throws -> StockSystemRequest {
        var headers = ["Square-Version": Self.squareVersion, "Accept": "application/json"]
        var data: Data?
        if let body {
            data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            headers["Content-Type"] = "application/json"
        }
        return try StockSystemRequest(endpoint, allowed: allowedEndpoints, body: data, headers: headers)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// A response body read as `type`, refused as too large or unreadable rather than guessed at.
    static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        guard body.count <= maximumResponseBytes else { throw StockSystemFailure.tooLarge }
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw StockSystemFailure.malformedResponse
        }
    }

    /// A Square object id as the phone will send it back: 1–100 characters, no spaces or controls.
    static func isSquareID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) }
    }

    /// RFC 3339 in UTC, whole seconds.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// A paging cursor kept only when it is plain text of a sane length.
    static func cursor(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.count <= 4096, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw StockSystemFailure.malformedResponse
        }
        return raw
    }
}

// MARK: - Square's response shapes (closed: members not named here are ignored)

enum SquareWire {

    struct Error: Decodable {
        let category: String?
        let code: String?
        let field: String?
    }

    struct ErrorBody: Decodable {
        let errors: [StockSystemLossy<Error>]?
    }

    struct Location: Decodable {
        let id: String
        let name: String?
        let status: String?
        let type: String?
    }

    struct LocationsBody: Decodable {
        let locations: [StockSystemLossy<Location>]?
    }

    struct Money: Decodable {
        let amount: Int64?
        let currency: String?
    }

    struct LocationOverride: Decodable {
        let locationId: String?
        let trackInventory: Bool?
        let inventoryAlertType: String?
        let inventoryAlertThreshold: Int64?
    }

    struct ItemData: Decodable {
        let name: String?
    }

    struct VariationData: Decodable {
        let itemId: String?
        let name: String?
        let sku: String?
        let trackInventory: Bool?
        let measurementUnitId: String?
        let inventoryAlertType: String?
        let inventoryAlertThreshold: Int64?
        let locationOverrides: [StockSystemLossy<LocationOverride>]?
        let pricingType: String?
        let priceMoney: Money?
    }

    struct CustomUnit: Decodable {
        let name: String?
        let abbreviation: String?
    }

    struct MeasurementUnit: Decodable {
        let customUnit: CustomUnit?
        let areaUnit: String?
        let lengthUnit: String?
        let volumeUnit: String?
        let weightUnit: String?
        let genericUnit: String?
        let timeUnit: String?
        let type: String?
    }

    struct MeasurementUnitData: Decodable {
        let measurementUnit: MeasurementUnit?
        let precision: Int?
    }

    struct CatalogObject: Decodable {
        let type: String
        let id: String
        let isDeleted: Bool?
        let presentAtAllLocations: Bool?
        let presentAtLocationIds: [String]?
        let absentAtLocationIds: [String]?
        let itemData: ItemData?
        let itemVariationData: VariationData?
        let measurementUnitData: MeasurementUnitData?

        /// Square's rule: present everywhere unless `present_at_all_locations` is false, then only
        /// where listed; never where listed absent.
        func isPresent(at location: String) -> Bool {
            if presentAtAllLocations ?? true {
                return !(absentAtLocationIds ?? []).contains(location)
            }
            return (presentAtLocationIds ?? []).contains(location)
        }
    }

    struct CatalogPage: Decodable {
        let objects: [StockSystemLossy<CatalogObject>]?
        let relatedObjects: [StockSystemLossy<CatalogObject>]?
        let cursor: String?
    }

    struct Count: Decodable {
        let catalogObjectId: String
        let catalogObjectType: String?
        let state: String
        let locationId: String
        let quantity: String
    }

    struct CountsPage: Decodable {
        let counts: [StockSystemLossy<Count>]?
        let cursor: String?
    }

    struct Adjustment: Decodable {
        let id: String?
        let referenceId: String?
        let fromState: String?
        let toState: String?
        let fromLocationId: String?
        let toLocationId: String?
        let catalogObjectId: String?
        let quantity: String?
    }

    struct Change: Decodable {
        let type: String?
        let adjustment: Adjustment?
    }

    struct ChangesPage: Decodable {
        let changes: [StockSystemLossy<Change>]?
        let cursor: String?
    }
}
