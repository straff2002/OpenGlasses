import XCTest
@testable import OpenGlasses

/// A stock quantity is a whole number of thousandths of the line's unit, read and written exactly.
final class StockQuantityTests: XCTestCase {

    private func q(_ scaled: Int) -> StockQuantity { StockQuantity(scaled: scaled) }

    private func parsed(_ text: String, _ unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal> {
        StockQuantity.parse(text, unit: unit)
    }

    private func json(_ raw: Any?, _ unit: VanStockUnit) -> Result<StockQuantity, StockQuantityRefusal>? {
        StockQuantity.parse(json: raw, unit: unit)
    }

    // MARK: Exact text

    func testDecimalTextParsesToThousandths() {
        XCTAssertEqual(parsed("4.25", .l), .success(q(4250)))
        XCTAssertEqual(parsed("4.250", .l), .success(q(4250)))
        XCTAssertEqual(parsed("4.2500", .l), .success(q(4250)), "a trailing zero is not a fourth place")
        XCTAssertEqual(parsed("0.001", .l), .success(q(1)))
        XCTAssertEqual(parsed("  12 ", .m), .success(q(12_000)))
        XCTAssertEqual(parsed("0", .kg), .success(.zero))
        XCTAssertEqual(parsed("0004.5", .kg), .success(q(4500)))
        XCTAssertEqual(parsed("1000000", .l), .success(q(1_000_000_000)))
    }

    func testMoreThanThreeDecimalPlacesIsRefused() {
        XCTAssertEqual(parsed("4.2501", .l), .failure(.tooManyDecimals))
        XCTAssertEqual(parsed("0.0005", .l), .failure(.tooManyDecimals))
    }

    func testEachAndPackAreHeldToWholeNumbers() {
        XCTAssertEqual(parsed("2", .each), .success(q(2000)))
        XCTAssertEqual(parsed("2.0", .each), .success(q(2000)))
        XCTAssertEqual(parsed("2.5", .each), .failure(.notWhole))
        XCTAssertEqual(parsed("1.5", .pack), .failure(.notWhole))
        XCTAssertEqual(parsed("2.0001", .each), .failure(.notWhole))
    }

    func testNegativeIsRefused() {
        XCTAssertEqual(parsed("-1", .l), .failure(.negative))
        XCTAssertEqual(parsed("-4.25", .l), .failure(.negative))
        XCTAssertEqual(parsed("-", .l), .failure(.notANumber))
        XCTAssertEqual(parsed("-abc", .l), .failure(.notANumber))
    }

    func testAnythingButAPlainDecimalIsNotANumber() {
        for text in ["", "   ", "abc", "4,25", "1e3", ".5", "5.", "+4", "4.2.5", "1 000", "4 l", "٣", "0x10"] {
            XCTAssertEqual(parsed(text, .l), .failure(.notANumber), "\"\(text)\"")
        }
    }

    func testOverAMillionIsTooLarge() {
        XCTAssertEqual(parsed("1000001", .l), .failure(.tooLarge))
        XCTAssertEqual(parsed("1000000.001", .l), .failure(.tooLarge))
    }

    func testAVeryLongNumberIsRefusedWithoutOverflow() {
        let forty = String(repeating: "9", count: 40)
        XCTAssertEqual(parsed(forty, .l), .failure(.tooLarge))
        XCTAssertEqual(parsed(forty + ".5", .l), .failure(.tooLarge))
        XCTAssertEqual(parsed("1." + forty, .l), .failure(.tooManyDecimals))
        XCTAssertEqual(parsed("4.25" + String(repeating: "0", count: 40), .l), .success(q(4250)))
    }

    // MARK: From the model's JSON

    func testJSONDoublesParseExactly() {
        XCTAssertEqual(json(4.25, .l), .success(q(4250)))
        XCTAssertEqual(json(0.1, .l), .success(q(100)))
        XCTAssertEqual(json(1e-3, .l), .success(q(1)))
        XCTAssertEqual(json(4.0, .each), .success(q(4000)))
        XCTAssertEqual(json(4.2501, .l), .failure(.tooManyDecimals))
        XCTAssertEqual(json(2.5, .each), .failure(.notWhole))
        XCTAssertEqual(json(-1.5, .l), .failure(.negative))
        XCTAssertEqual(json(Double.nan, .l), .failure(.notANumber))
        XCTAssertEqual(json(Double.infinity, .l), .failure(.notANumber))
        XCTAssertEqual(json(1e300, .l), .failure(.tooLarge))
    }

    func testTheSharedDoubleRuleMatchesTheJSONPath() {
        XCTAssertEqual(StockQuantity.parse(number: 4.25, unit: .l), .success(q(4250)))
        XCTAssertEqual(StockQuantity.parse(number: 4.2499999999999991, unit: .l), .success(q(4250)))
        XCTAssertEqual(StockQuantity.parse(number: 4.2501, unit: .l), .failure(.tooManyDecimals))
    }

    func testJSONIntegersAreWholeUnits() {
        XCTAssertEqual(json(3, .each), .success(q(3000)))
        XCTAssertEqual(json(NSNumber(value: 3), .pack), .success(q(3000)))
        XCTAssertEqual(json(-2, .each), .failure(.negative))
        XCTAssertEqual(json(1_000_001, .each), .failure(.tooLarge))
        XCTAssertEqual(json(Int.max, .l), .failure(.tooLarge))
        XCTAssertEqual(json(NSNumber(value: UInt64.max), .l), .failure(.tooLarge))
    }

    func testJSONBooleansAreNotNumbers() {
        XCTAssertEqual(json(NSNumber(value: true), .each), .failure(.notANumber))
        XCTAssertEqual(json(true, .each), .failure(.notANumber))
        XCTAssertEqual(json(false, .l), .failure(.notANumber))
    }

    func testJSONStringsAreReadExactlyAndOtherShapesRefused() {
        XCTAssertEqual(json("4.25", .l), .success(q(4250)))
        XCTAssertEqual(json("4.2501", .l), .failure(.tooManyDecimals))
        XCTAssertEqual(json(["4"], .l), .failure(.notANumber))
        XCTAssertEqual(json(["q": 4], .l), .failure(.notANumber))
    }

    func testAnAbsentArgumentIsNil() {
        XCTAssertNil(json(nil, .l))
        XCTAssertNil(json(NSNull(), .l))
        XCTAssertNil(json("", .l))
        XCTAssertNil(json("  ", .l))
    }

    func testJSONSerializationRoundTrip() throws {
        let data = Data(#"{"q": 4.25, "small": 0.1, "milli": 1e-3, "whole": 3, "noise": 4.2501, "flag": true}"#.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json(object["q"], .l), .success(q(4250)))
        XCTAssertEqual(json(object["small"], .l), .success(q(100)))
        XCTAssertEqual(json(object["milli"], .l), .success(q(1)))
        XCTAssertEqual(json(object["whole"], .each), .success(q(3000)))
        XCTAssertEqual(json(object["noise"], .l), .failure(.tooManyDecimals))
        XCTAssertEqual(json(object["flag"], .l), .failure(.notANumber))
        XCTAssertNil(json(object["missing"], .l))
    }

    // MARK: Arithmetic

    func testSumsAreExact() {
        let sum = (try? parsed("0.1", .l).get())! + (try? parsed("0.2", .l).get())!
        XCTAssertEqual(sum, q(300))
        XCTAssertEqual(sum.decimalString, "0.3")

        var total = StockQuantity.zero
        let milli = q(1)
        for _ in 0..<1000 { total += milli }
        XCTAssertEqual(total, q(1000))
        XCTAssertEqual(total, StockQuantity(whole: 1))
    }

    func testTopUpIsStandardMinusOnHand() {
        let standard = StockQuantity(whole: 5)
        let onHand = q(4250)
        XCTAssertEqual(standard - onHand, q(750))
        XCTAssertEqual((standard - onHand).decimalString, "0.75")

        var level = onHand
        level -= StockQuantity(whole: 5)
        XCTAssertEqual(level, q(-750), "a difference may go below zero; callers clamp")
        XCTAssertFalse(level.isInRange)
    }

    func testComparison() {
        XCTAssertLessThan(q(4250), q(4251))
        XCTAssertGreaterThan(StockQuantity(whole: 5), q(4999))
        XCTAssertEqual(StockQuantity(whole: 2), q(2000))
        XCTAssertEqual([q(3), q(1), q(2)].sorted(), [q(1), q(2), q(3)])
        XCTAssertEqual(max(q(10), q(9)), q(10))
    }

    func testWholeAndFits() {
        XCTAssertTrue(q(2000).isWhole)
        XCTAssertFalse(q(2500).isWhole)

        XCTAssertTrue(q(2000).fits(.each))
        XCTAssertFalse(q(2500).fits(.each))
        XCTAssertTrue(q(3000).fits(.pack))
        XCTAssertFalse(q(1).fits(.pack))
        XCTAssertTrue(q(4250).fits(.l))
        XCTAssertTrue(q(1).fits(.l))
        XCTAssertFalse(q(-1).fits(.l))
        XCTAssertTrue(q(StockQuantity.maximumScaled).fits(.l))
        XCTAssertFalse(q(StockQuantity.maximumScaled + 1).fits(.l))
    }

    func testStepPerUnit() {
        for unit in [VanStockUnit.m, .ft, .kg, .lb, .l] {
            XCTAssertEqual(unit.step, 1)
            XCTAssertTrue(unit.allowsFraction)
        }
        for unit in [VanStockUnit.each, .pack] {
            XCTAssertEqual(unit.step, 1000)
            XCTAssertFalse(unit.allowsFraction)
        }
        XCTAssertEqual(StockQuantity.scale, 3)
        XCTAssertEqual(StockQuantity.perUnit, 1000)
        XCTAssertEqual(StockQuantity.maximumScaled, 1_000_000_000)
    }

    // MARK: Codable

    func testEncodesAsABareInteger() throws {
        let data = try JSONEncoder().encode(q(4250))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "4250")
        let wrapped = try JSONEncoder().encode(["q": q(4250)])
        XCTAssertEqual(String(decoding: wrapped, as: UTF8.self), #"{"q":4250}"#)
        XCTAssertEqual(try JSONDecoder().decode(StockQuantity.self, from: data), q(4250))
    }

    func testDecodingRefusesANegativeOrOversizeFigure() {
        XCTAssertThrowsError(try JSONDecoder().decode(StockQuantity.self, from: Data("-1".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(StockQuantity.self, from: Data("1000000001".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(StockQuantity.self, from: Data("4.25".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(StockQuantity.self, from: Data(#""4250""#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(StockQuantity.self, from: Data("1000000000".utf8)),
                       q(1_000_000_000))
    }

    // MARK: Formatting

    func testDecimalString() {
        XCTAssertEqual(q(4250).decimalString, "4.25")
        XCTAssertEqual(q(4000).decimalString, "4")
        XCTAssertEqual(q(1).decimalString, "0.001")
        XCTAssertEqual(q(500).decimalString, "0.5")
        XCTAssertEqual(q(12_010).decimalString, "12.01")
        XCTAssertEqual(q(0).decimalString, "0")
        XCTAssertEqual(q(1_000_000_000).decimalString, "1000000")
        XCTAssertEqual(q(-750).decimalString, "-0.75")
    }

    func testFormattedFollowsTheLocale() {
        let german = Locale(identifier: "de_DE")
        let french = Locale(identifier: "fr_FR")
        let newZealand = Locale(identifier: "en_NZ")
        let american = Locale(identifier: "en_US")
        XCTAssertEqual(q(4250).formatted(locale: german), "4,25")
        XCTAssertEqual(q(4250).formatted(locale: french), "4,25")
        XCTAssertEqual(q(4250).formatted(locale: newZealand), "4.25")
        XCTAssertEqual(q(4250).formatted(locale: american), "4.25")
        XCTAssertEqual(q(4000).formatted(locale: german), "4")
        XCTAssertEqual(q(1).formatted(locale: american), "0.001")
        XCTAssertEqual(q(1_000_000_000).formatted(locale: american), "1,000,000")
    }

    // MARK: Typed on the screen

    func testLocalizedParse() {
        let german = Locale(identifier: "de_DE")
        let newZealand = Locale(identifier: "en_NZ")
        let american = Locale(identifier: "en_US")
        XCTAssertEqual(StockQuantity.parse(localized: "4,25", locale: german, unit: .l), .success(q(4250)))
        XCTAssertEqual(StockQuantity.parse(localized: "4.25", locale: german, unit: .l), .success(q(4250)))
        XCTAssertEqual(StockQuantity.parse(localized: "4.25", locale: newZealand, unit: .l), .success(q(4250)))
        XCTAssertEqual(StockQuantity.parse(localized: "1,000", locale: american, unit: .l), .failure(.notANumber))
        XCTAssertEqual(StockQuantity.parse(localized: "4,2.5", locale: german, unit: .l), .failure(.notANumber))
        XCTAssertEqual(StockQuantity.parse(localized: " 3 ", locale: german, unit: .each), .success(q(3000)))
        XCTAssertEqual(StockQuantity.parse(localized: "2,5", locale: german, unit: .pack), .failure(.notWhole))
    }

    // MARK: Words for the model

    func testSpokenMeasuredUnits() {
        XCTAssertEqual(VanStockUnit.l.spoken(q(4250)), "4.25 litres")
        XCTAssertEqual(VanStockUnit.l.spoken(q(1000)), "1 litre")
        XCTAssertEqual(VanStockUnit.kg.spoken(q(500)), "0.5 kilograms")
        XCTAssertEqual(VanStockUnit.kg.spoken(q(1000)), "1 kilogram")
        XCTAssertEqual(VanStockUnit.m.spoken(q(12_000)), "12 metres")
        XCTAssertEqual(VanStockUnit.m.spoken(q(1000)), "1 metre")
        XCTAssertEqual(VanStockUnit.ft.spoken(q(3000)), "3 feet")
        XCTAssertEqual(VanStockUnit.ft.spoken(q(1000)), "1 foot")
        XCTAssertEqual(VanStockUnit.lb.spoken(q(750)), "0.75 pounds")
        XCTAssertEqual(VanStockUnit.lb.spoken(q(1000)), "1 pound")
        XCTAssertEqual(VanStockUnit.l.spoken(q(1001)), "1.001 litres", "singular only when exactly one")
    }

    func testSpokenEachAndPack() {
        XCTAssertEqual(VanStockUnit.each.spoken(q(2000)), "2")
        XCTAssertEqual(VanStockUnit.pack.spoken(q(1000)), "1 pack")
        XCTAssertEqual(VanStockUnit.pack.spoken(q(2000)), "2 packs")
    }

    func testSpokenPhraseMatchesTodaysEachAndPackWording() {
        XCTAssertEqual(VanStockUnit.l.spoken(q(4250), of: "Engine oil"), "4.25 litres of Engine oil")
        XCTAssertEqual(VanStockUnit.each.spoken(q(2000), of: "Flame sensor"), "2 × Flame sensor")
        XCTAssertEqual(VanStockUnit.pack.spoken(q(1000), of: "Wire nuts"), "1 pack of Wire nuts")
        for whole in [0, 1, 2, 12] {
            for unit in [VanStockUnit.each, .pack] {
                XCTAssertEqual(unit.spoken(StockQuantity(whole: whole), of: "Fuse"), unit.phrase(whole, of: "Fuse"))
            }
        }
    }

    // MARK: Refusal sentences

    func testRefusalSentences() {
        XCTAssertEqual(StockQuantityRefusal.tooManyDecimals.sentence(for: .l), "litres are kept to 3 decimal places")
        XCTAssertEqual(StockQuantityRefusal.tooManyDecimals.sentence(for: .m), "metres are kept to 3 decimal places")
        XCTAssertEqual(StockQuantityRefusal.tooManyDecimals.sentence(for: .ft), "feet are kept to 3 decimal places")
        XCTAssertEqual(StockQuantityRefusal.tooManyDecimals.sentence(for: .kg), "kilograms are kept to 3 decimal places")
        XCTAssertEqual(StockQuantityRefusal.tooManyDecimals.sentence(for: .lb), "pounds are kept to 3 decimal places")
        XCTAssertEqual(StockQuantityRefusal.notWhole.sentence(for: .each), "each is counted in whole numbers")
        XCTAssertEqual(StockQuantityRefusal.notWhole.sentence(for: .pack), "packs are counted whole")
        for unit in [VanStockUnit.l, .each, .pack] {
            XCTAssertEqual(StockQuantityRefusal.negative.sentence(for: unit), "a quantity cannot be below zero")
            XCTAssertEqual(StockQuantityRefusal.tooLarge.sentence(for: unit), "that is more than a million")
            XCTAssertEqual(StockQuantityRefusal.notANumber.sentence(for: unit), "that is not a number")
        }
    }
}
