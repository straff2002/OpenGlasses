import Foundation
import XCTest
@testable import OpenGlasses

/// Shared pieces for the Plan MM P0 tests: a small invented system, and the contract's fixtures
/// read from the checkout.
enum StockSystemSamples {

    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Friday 20 November 2026, 09:10 UTC: when the sample pull finished.
    static let pulledAt = date(2026, 11, 20, 9, 10)

    static let source = StockSystemSource(connectorID: "sample-system", displayName: "Sample System",
                                          accountLabel: "Sample Account")

    static let unitMap = StockSystemUnitMap(["ea": .each, "each": .each, "litre": .l, "l": .l, "pack": .pack, "m": .m])

    static let locations = [
        StockSystemRawLocation(id: "L1", name: "Rear Shelf", locationClass: "base"),
        StockSystemRawLocation(id: "L2", name: "North Bay", locationClass: "site"),
    ]

    static func row(_ id: String, part: String? = nil, description: String = "Capacitor 45/5", unit: String = "ea",
                    _ levels: [(String, String?)], asOf: String? = nil, price: String? = nil,
                    currency: String? = nil, reorderPoint: String? = nil) -> StockSystemRawRow {
        StockSystemRawRow(itemID: id, part: part ?? "ZX-\(id)", description: description, unit: unit,
                          levels: levels.map { .init(location: $0.0, quantity: $0.1) },
                          asOf: asOf, price: price, currency: currency, reorderPoint: reorderPoint)
    }

    static func builder(pricesEnabled: Bool = false, lineCap: Int = StockSystemPolicy.lineCap) -> StockSystemSnapshotBuilder {
        var builder = StockSystemSnapshotBuilder(source: source, unitMap: unitMap)
        builder.pricesEnabled = pricesEnabled
        builder.lineCap = lineCap
        return builder
    }

    static func snapshot(_ rows: [StockSystemRawRow], pulledAt: Date = pulledAt) -> StockSystemSnapshot {
        builder().build(locations: locations, rows: rows, pulledAt: pulledAt).snapshot
    }

    /// A vault parts table: `rows` of (number, description, supersedes).
    static func parts(_ rows: [(String, String, String?)]) -> VaultPartsIndex {
        var table = "| Part | Description | Supersedes |\n|---|---|---|\n"
        for row in rows { table += "| \(row.0) | \(row.1) | \(row.2 ?? "") |\n" }
        return VaultPartsIndex(files: [(filename: "parts.md", contents: table)])
    }

    static func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}

/// The contract's synthetic fixtures (`Contracts/fixtures/stock-systems/`), read from the checkout.
enum StockSystemFixtures {

    // `#filePath` is fixed at compile time, so it resolves the same on a developer machine and CI.
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/stock-systems")
    }

    static func data(_ set: String, _ file: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(set).appendingPathComponent(file))
    }

    struct Capabilities: Decodable {
        let hasJobs: Bool
        let wholeNumbersOnly: Bool
        let adjustmentReasons: [StockAdjustmentReason]
        let chosenReason: StockAdjustmentReason?
        let adjustmentNote: Bool
    }

    struct Input: Decodable {
        let source: StockSystemSource
        let pulledAt: String
        let pricesEnabled: Bool
        let unitMap: [String: String]
        let capabilities: Capabilities
        let locations: [StockSystemRawLocation]
        let rows: [StockSystemRawRow]

        var map: StockSystemUnitMap {
            StockSystemUnitMap(unitMap.compactMapValues { VanStockUnit(rawValue: $0) })
        }

        var pulled: Date { StockSystemSnapshotBuilder.date(pulledAt)! }

        var systemCapabilities: StockSystemCapabilities {
            StockSystemCapabilities(connectorID: source.connectorID, displayName: source.displayName,
                                    hasJobs: capabilities.hasJobs, wholeNumbersOnly: capabilities.wholeNumbersOnly,
                                    adjustmentReasons: Set(capabilities.adjustmentReasons),
                                    chosenReason: capabilities.chosenReason, adjustmentNote: capabilities.adjustmentNote)
        }

        func build() -> StockSystemSnapshotBuilder.Result {
            var builder = StockSystemSnapshotBuilder(source: source, unitMap: map)
            builder.pricesEnabled = pricesEnabled
            return builder.build(locations: locations, rows: rows, pulledAt: pulled)
        }
    }

    struct Line: Decodable {
        let id: String
        let itemID: String?
        let part: String?
        let description: String
        let quantityScaled: Int
        let unit: VanStockUnit
        let source: StagedStockUse.Source
    }

    struct Batch: Decodable {
        let jobID: String
        let jobNumber: String?
        let locationID: String
        let confirmation: String
        let reference: ExternalJobReference?
        let lines: [Line]

        var confirmed: ConfirmedStockUseBatch {
            ConfirmedStockUseBatch(
                jobID: jobID, jobNumber: jobNumber, locationID: locationID,
                lines: lines.map {
                    StagedStockUse(id: $0.id, itemID: $0.itemID, part: $0.part, description: $0.description,
                                   quantity: StockQuantity(scaled: $0.quantityScaled), unit: $0.unit, source: $0.source)
                },
                confirmation: .person(confirmation == "voice" ? .voice : .screen))
        }
    }

    static func input(_ set: String) throws -> Input {
        try JSONDecoder().decode(Input.self, from: data(set, "input.json"))
    }

    static func batch(_ set: String) throws -> Batch {
        try JSONDecoder().decode(Batch.self, from: data(set, "batch.json"))
    }
}
