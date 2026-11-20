import XCTest
@testable import OpenGlasses

/// Plan MM P1 — Square's measurement units onto the phone's closed list: a pure table that never
/// converts between units and never guesses.
final class SquareUnitMapTests: XCTestCase {

    private func resolve(_ unit: SquareUnitMap.Unit) -> SquareUnitMap.Resolution {
        SquareUnitMap.resolve(unit)
    }

    func testTheStandardUnitsThatAreThePhonesOwnMap() {
        let expected: [String: VanStockUnit] = [
            "METRIC_LITER": .l, "METRIC_METER": .m, "IMPERIAL_FOOT": .ft, "METRIC_KILOGRAM": .kg,
            "IMPERIAL_POUND": .lb, "UNIT": .each,
        ]
        XCTAssertEqual(SquareUnitMap.standard, expected)
        for (value, unit) in expected {
            XCTAssertEqual(resolve(.standard(value)), .init(unit: unit, systemUnit: unit.rawValue), value)
        }
    }

    func testNoMeasurementUnitIsWholeItems() {
        XCTAssertEqual(resolve(.none), .init(unit: .each, systemUnit: "each"))
    }

    func testEveryOtherStandardUnitIsNotKeptAndNeverConverted() {
        let others = [
            "METRIC_MILLILITER": "milliliter", "METRIC_GRAM": "gram", "METRIC_MILLIGRAM": "milligram",
            "METRIC_CENTIMETER": "centimeter", "METRIC_MILLIMETER": "millimeter", "METRIC_KILOMETER": "kilometer",
            "IMPERIAL_INCH": "inch", "IMPERIAL_YARD": "yard", "IMPERIAL_MILE": "mile", "IMPERIAL_WEIGHT_OUNCE": "weight ounce",
            "IMPERIAL_STONE": "stone", "GENERIC_FLUID_OUNCE": "fluid ounce", "GENERIC_GALLON": "gallon",
            "GENERIC_PINT": "pint", "GENERIC_HOUR": "hour", "METRIC_SQUARE_METER": "square meter",
        ]
        for (value, word) in others {
            XCTAssertEqual(resolve(.standard(value)), .init(unit: nil, systemUnit: word), value)
        }
    }

    func testACustomUnitMapsOnlyOnAnExactEachOrPackWord() {
        XCTAssertEqual(resolve(.custom(name: "Each", abbreviation: "")).unit, .each)
        XCTAssertEqual(resolve(.custom(name: "Piece", abbreviation: "pc")).unit, .each)
        XCTAssertEqual(resolve(.custom(name: "Something", abbreviation: " PCS ")).unit, .each, "the abbreviation counts")
        XCTAssertEqual(resolve(.custom(name: "Box", abbreviation: "bx")), .init(unit: .pack, systemUnit: "pack"))
        XCTAssertEqual(resolve(.custom(name: "packet", abbreviation: "")).unit, .pack)
        for unmapped in ["Tin", "Boxes of 10", "Each pair", "Bottle", "Roll", "Litres", "Bag"] {
            XCTAssertEqual(resolve(.custom(name: unmapped, abbreviation: "")), .init(unit: nil, systemUnit: unmapped), unmapped)
        }
        XCTAssertEqual(resolve(.custom(name: "", abbreviation: "tn")), .init(unit: nil, systemUnit: "tn"))
    }

    func testAnUnmappedWordThatReadsAsAPhoneUnitIsMarkedAsTheSystems() {
        // A seller's own "kg" is not Square's kilogram: it stays unmapped, and its word can never
        // be read as the phone's kilogram by the common table.
        for word in ["kg", "L", "m", "ft", "lb"] {
            let resolution = resolve(.custom(name: word, abbreviation: ""))
            XCTAssertNil(resolution.unit, word)
            XCTAssertEqual(resolution.systemUnit, "\(word) (custom)")
            XCTAssertNil(SquareUnitMap.table.unit(for: resolution.systemUnit))
        }
    }

    func testAnUnreadableUnitIsNotKept() {
        XCTAssertEqual(resolve(.unreadable), .init(unit: nil, systemUnit: "unknown unit"))
    }

    func testTheCommonTableHoldsExactlyThePhonesUnitWords() {
        for unit in VanStockUnit.allCases {
            XCTAssertEqual(SquareUnitMap.table.unit(for: unit.rawValue), unit)
        }
        XCTAssertNil(SquareUnitMap.table.unit(for: "METRIC_LITER"))
        XCTAssertNil(SquareUnitMap.table.unit(for: "milliliter"))
    }

    func testTheCatalogueShapeReadsAsTheRightKindOfUnit() throws {
        func unit(_ object: [String: Any]) throws -> SquareUnitMap.Unit {
            let data = try JSONSerialization.data(withJSONObject: object)
            return SquareSnapshotPlan.unit(try SquareStockAdapter.decoder.decode(SquareWire.MeasurementUnit.self, from: data))
        }
        XCTAssertEqual(try unit(["volume_unit": "METRIC_LITER", "type": "TYPE_VOLUME"]), .standard("METRIC_LITER"))
        XCTAssertEqual(try unit(["generic_unit": "UNIT", "type": "TYPE_GENERIC"]), .standard("UNIT"))
        XCTAssertEqual(try unit(["custom_unit": ["name": "Tin", "abbreviation": "tn"], "type": "TYPE_CUSTOM"]),
                       .custom(name: "Tin", abbreviation: "tn"))
        XCTAssertEqual(try unit(["volume_unit": "METRIC_LITER", "weight_unit": "METRIC_KILOGRAM"]), .unreadable,
                       "two units at once is no unit")
        XCTAssertEqual(try unit([:]), .unreadable)
        XCTAssertEqual(SquareSnapshotPlan.unit(nil), .unreadable)
    }
}
