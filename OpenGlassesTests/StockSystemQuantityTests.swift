import XCTest
@testable import OpenGlasses

/// Plan MM P0 — the seam between a system's figures and Plan ML's `StockQuantity`, both ways.
final class StockSystemQuantityTests: XCTestCase {

    private let map = StockSystemUnitMap(["EA": .each, " Litre ": .l, "box": .pack])

    func testTheUnitMapIsAClosedTableIgnoringCaseAndSpaces() {
        XCTAssertEqual(map.unit(for: "ea"), .each)
        XCTAssertEqual(map.unit(for: "LITRE"), .l)
        XCTAssertEqual(map.unit(for: " box"), .pack)
        XCTAssertNil(map.unit(for: "tin"))
        XCTAssertNil(map.unit(for: ""))
    }

    func testADecimalStringBecomesThousandthsAndBackWithoutLoss() {
        for text in ["0", "1", "4.25", "0.001", "12.5", "999999.999", "1000000"] {
            let value = StockSystemQuantityConversion.incoming(text, systemUnit: "litre", map: map)
            guard case .known(let quantity) = value else { return XCTFail("\(text) was \(value)") }
            XCTAssertEqual(quantity.decimalString, text)
            guard quantity > .zero else { continue }
            XCTAssertEqual(StockSystemQuantityConversion.outgoing(quantity, unit: .l, itemUnit: .l, wholeNumbersOnly: false),
                           .success(text))
        }
        // Trailing zeros past the third place are exact, not rounding.
        XCTAssertEqual(StockSystemQuantityConversion.incoming("4.25000", systemUnit: "litre", map: map),
                       .known(StockQuantity(scaled: 4250)))
    }

    func testMoreThanThreeDecimalPlacesIsUnknownNeverRounded() {
        XCTAssertEqual(StockSystemQuantityConversion.incoming("1.23456", systemUnit: "litre", map: map),
                       .unknown(.tooManyDecimals))
        XCTAssertEqual(StockSystemQuantityConversion.incoming("0.0005", systemUnit: "litre", map: map),
                       .unknown(.tooManyDecimals))
        // A fraction of something counted whole.
        XCTAssertEqual(StockSystemQuantityConversion.incoming("2.5", systemUnit: "ea", map: map), .unknown(.notWhole))
    }

    func testAnUnmappedUnitIsUnknownWithTheSystemsWord() {
        XCTAssertEqual(StockSystemQuantityConversion.incoming("7", systemUnit: " tin ", map: map),
                       .unknown(.unmappedUnit("tin")))
    }

    func testNoFigureAndBadFiguresAreUnknownNotZero() {
        XCTAssertEqual(StockSystemQuantityConversion.incoming(nil, systemUnit: "ea", map: map), .unknown(.noCount))
        XCTAssertEqual(StockSystemQuantityConversion.incoming("  ", systemUnit: "ea", map: map), .unknown(.noCount))
        XCTAssertEqual(StockSystemQuantityConversion.incoming("-2", systemUnit: "ea", map: map), .unknown(.negative))
        XCTAssertEqual(StockSystemQuantityConversion.incoming("1e3", systemUnit: "ea", map: map), .unknown(.notANumber))
        XCTAssertEqual(StockSystemQuantityConversion.incoming("2000000", systemUnit: "ea", map: map), .unknown(.tooLarge))
    }

    func testAWholeNumberSystemRefusesAFractionalUse() {
        let half = StockQuantity(scaled: 500)
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(half, unit: .l, itemUnit: .l, wholeNumbersOnly: true),
                       .failure(.fractional))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(.whole(2), unit: .l, itemUnit: .l, wholeNumbersOnly: true),
                       .success("2"))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(half, unit: .l, itemUnit: .l, wholeNumbersOnly: false),
                       .success("0.5"))
    }

    func testAUnitTheSystemDoesNotKeepForTheItemIsRefused() {
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(.whole(1), unit: .m, itemUnit: .each, wholeNumbersOnly: false),
                       .failure(.unitNotKept))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(.whole(1), unit: .each, itemUnit: nil, wholeNumbersOnly: false),
                       .failure(.unitNotKept))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(.zero, unit: .each, itemUnit: .each, wholeNumbersOnly: false),
                       .failure(.outOfRange))
        XCTAssertEqual(StockSystemOutRefusal.fractional.sentence(system: "Sample System", quantity: StockQuantity(scaled: 500), unit: .l),
                       "Sample System keeps whole numbers only, so 0.5 litres can't be sent.")
    }

    // MARK: - Plan MM P1: the item's decimal places

    func testAQuantityFinerThanTheItemsDecimalPlacesIsRefusedNeverRounded() {
        let quarter = StockQuantity(scaled: 250)
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(quarter, unit: .l, itemUnit: .l, wholeNumbersOnly: false,
                                                              decimalPlaces: 1), .failure(.tooManyDecimals))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(quarter, unit: .l, itemUnit: .l, wholeNumbersOnly: false,
                                                              decimalPlaces: 2), .success("0.25"))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(StockQuantity(scaled: 500), unit: .l, itemUnit: .l,
                                                              wholeNumbersOnly: false, decimalPlaces: 0), .failure(.tooManyDecimals))
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(.whole(3), unit: .l, itemUnit: .l, wholeNumbersOnly: false,
                                                              decimalPlaces: 0), .success("3"))
        // Three or more places, or none said, is no limit beyond the phone's own.
        for places in [nil, 3, 4, 5] {
            XCTAssertEqual(StockSystemQuantityConversion.outgoing(StockQuantity(scaled: 125), unit: .l, itemUnit: .l,
                                                                  wholeNumbersOnly: false, decimalPlaces: places), .success("0.125"))
        }
        // Whole numbers only still comes first, with its own sentence.
        XCTAssertEqual(StockSystemQuantityConversion.outgoing(quarter, unit: .l, itemUnit: .l, wholeNumbersOnly: true,
                                                              decimalPlaces: 1), .failure(.fractional))
    }

    func testTheTooManyDecimalsSentenceSaysTheItemsLimit() {
        let amount = StockQuantity(scaled: 250)
        XCTAssertEqual(StockSystemOutRefusal.tooManyDecimals.sentence(system: "Sample System", quantity: amount, unit: .l, decimalPlaces: 0),
                       "Sample System keeps that item in whole numbers, so 0.25 litres can't be sent.")
        XCTAssertEqual(StockSystemOutRefusal.tooManyDecimals.sentence(system: "Sample System", quantity: amount, unit: .l, decimalPlaces: 1),
                       "Sample System keeps that item to 1 decimal place, so 0.25 litres can't be sent.")
        XCTAssertEqual(StockSystemOutRefusal.tooManyDecimals.sentence(system: "Sample System", quantity: StockQuantity(scaled: 125),
                                                                      unit: .m, decimalPlaces: 2),
                       "Sample System keeps that item to 2 decimal places, so 0.125 metres can't be sent.")
    }

    func testAQuantityKnowsHowManyDecimalPlacesItNeeds() {
        XCTAssertEqual(StockQuantity.whole(4).decimalPlaces, 0)
        XCTAssertEqual(StockQuantity.zero.decimalPlaces, 0)
        XCTAssertEqual(StockQuantity(scaled: 4500).decimalPlaces, 1)
        XCTAssertEqual(StockQuantity(scaled: 4250).decimalPlaces, 2)
        XCTAssertEqual(StockQuantity(scaled: 4001).decimalPlaces, 3)
        XCTAssertEqual(StockQuantity(scaled: 10).decimalPlaces, 2)
    }
}
