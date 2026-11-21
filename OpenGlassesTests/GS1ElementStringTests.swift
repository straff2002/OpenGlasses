import XCTest
@testable import OpenGlasses

/// Plan MY P0 — `GS1ElementString` and `StockScan`: the fields a carton's code carries, read in
/// any order, with and without separators, and refused rather than guessed when anything is off.
/// Every GTIN here is invented, with a valid check digit.
final class GS1ElementStringTests: XCTestCase {

    private let gs = "\u{1D}"
    private let gtinA = "02000000000015"
    private let gtinB = "02000000000022"

    private func parse(_ text: String) -> Result<GS1ElementString, GS1ElementString.Failure> {
        GS1ElementString.parse(text, referenceYear: 2026)
    }

    // MARK: - Fields

    func testFixedThenVariableFieldsWithASeparator() throws {
        let fields = try parse("01\(gtinA)17271130" + "10ZZ1001" + gs + "21SER42").get()
        XCTAssertEqual(fields.gtin, gtinA)
        XCTAssertEqual(fields.expiry, StockDay(year: 2027, month: 11, day: 30))
        XCTAssertEqual(fields.lot, "ZZ1001")
        XCTAssertEqual(fields.serial, "SER42")
    }

    func testAVariableFieldLastNeedsNoSeparator() throws {
        let fields = try parse("01\(gtinA)17280229" + "10zz-0042").get()
        XCTAssertEqual(fields.lot, "zz-0042", "kept exactly, case and leading zeros")
        XCTAssertEqual(fields.expiry, StockDay(year: 2028, month: 2, day: 29), "2028 is a leap year")
        XCTAssertNil(fields.serial)
    }

    func testTheOrderOfTheFieldsDoesNotMatter() throws {
        let one = try parse("10ZZ1001" + gs + "17271130" + "01\(gtinA)" + "21S1").get()
        let two = try parse("21S1" + gs + "01\(gtinA)10ZZ1001" + gs + "17271130").get()
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.lot, "ZZ1001")
        XCTAssertEqual(one.gtin, gtinA)
    }

    func testASeparatorAfterAFixedFieldAndALeadingFNC1AreForgiven() throws {
        let fields = try parse(gs + "01\(gtinA)" + gs + "10ZZ1001").get()
        XCTAssertEqual(fields.gtin, gtinA)
        XCTAssertEqual(fields.lot, "ZZ1001")
    }

    func testASymbologyIdentifierIsStepped() throws {
        XCTAssertEqual(try parse("]d201\(gtinA)10ZZ1001").get().lot, "ZZ1001")
        XCTAssertEqual(try parse("]C101\(gtinB)17270600").get().gtin, gtinB)
    }

    func testADayOf00IsTheLastDayOfTheMonth() throws {
        XCTAssertEqual(try parse("01\(gtinA)17270200").get().expiry, StockDay(year: 2027, month: 2, day: 28))
        XCTAssertEqual(try parse("01\(gtinA)17280200").get().expiry, StockDay(year: 2028, month: 2, day: 29))
        XCTAssertEqual(try parse("01\(gtinA)17271100").get().expiry, StockDay(year: 2027, month: 11, day: 30))
        XCTAssertEqual(GS1ElementString.day("261200", referenceYear: 2026), StockDay(year: 2026, month: 12, day: 31))
    }

    func testTwoDigitYearsFollowGS1sCenturyRule() {
        XCTAssertEqual(GS1ElementString.fullYear(27, referenceYear: 2026), 2027)
        XCTAssertEqual(GS1ElementString.fullYear(75, referenceYear: 2026), 2075)
        XCTAssertEqual(GS1ElementString.fullYear(77, referenceYear: 2026), 1977)
        XCTAssertEqual(GS1ElementString.fullYear(3, referenceYear: 2098), 2103)
    }

    func testTheBracketedFormReadsTheSame() throws {
        let raw = try parse("01\(gtinA)17271130" + "10ZZ(1)" + gs + "21S1").get()
        let bracketed = try parse("(01)\(gtinA)(17)271130(10)ZZ(1)(21)S1").get()
        XCTAssertEqual(raw, bracketed, "a bracket that is no known AI stays in the lot")
        XCTAssertEqual(try parse(raw.bracketed).get(), raw)
    }

    // MARK: - Refusals

    func testABadCheckDigitIsRefused() {
        XCTAssertEqual(parse("0102000000000016" + "10ZZ1001"), .failure(.badCheckDigit))
    }

    func testAThirteenthMonthIsRefused() {
        XCTAssertEqual(parse("01\(gtinA)17271301" + "10ZZ1001"), .failure(.impossibleDate(ai: "17")))
        XCTAssertEqual(parse("01\(gtinA)17270231"), .failure(.impossibleDate(ai: "17")), "no 31 February")
        XCTAssertEqual(parse("01\(gtinA)17270001"), .failure(.impossibleDate(ai: "17")), "no month 0")
    }

    func testATruncatedFieldIsRefused() {
        XCTAssertEqual(parse("01\(gtinA)10"), .failure(.truncated(ai: "10")), "a lot with nothing in it")
        XCTAssertEqual(parse("0102000000"), .failure(.truncated(ai: "01")))
        XCTAssertEqual(parse("01\(gtinA)1727"), .failure(.truncated(ai: "17")))
        XCTAssertEqual(parse("01\(gtinA)10" + gs + "21S1"), .failure(.truncated(ai: "10")))
    }

    func testAnOverlongLotAnUnknownAIAndARepeatAreRefused() {
        XCTAssertEqual(parse("01\(gtinA)10ABCDEFGHIJKLMNOPQRSTU"), .failure(.tooLong(ai: "10")))
        XCTAssertEqual(parse("01\(gtinA)99SOMETHING"), .failure(.unknownAI("99")))
        XCTAssertEqual(parse("01\(gtinA)01\(gtinA)"), .failure(.repeatedAI("01")))
        XCTAssertEqual(parse("01\(gtinA)17ABCDEF"), .failure(.notDigits(ai: "17")))
        XCTAssertEqual(parse(""), .failure(.empty))
    }

    func testTheCheckDigitWorksForEveryGTINLength() {
        XCTAssertTrue(GS1ElementString.checkDigitIsValid(gtinA))
        XCTAssertTrue(GS1ElementString.checkDigitIsValid("2000000000015"))
        XCTAssertFalse(GS1ElementString.checkDigitIsValid("2000000000016"))
        XCTAssertEqual(GS1ElementString.gtin14("2000000000015"), gtinA)
        XCTAssertNil(GS1ElementString.gtin14("ZZ1001"))
    }

    // MARK: - A scanned code

    func testAScanKeepsTheProductNumberLotAndExpiry() throws {
        let scan = try StockScan.read("01\(gtinA)17271130" + "10ZZ1001", referenceYear: 2026).get()
        XCTAssertEqual(scan.code, gtinA)
        XCTAssertEqual(scan.lot, "ZZ1001")
        XCTAssertEqual(scan.expiry, StockDay(year: 2027, month: 11, day: 30))
        XCTAssertEqual(scan.described, "product number \(gtinA), lot ZZ1001, expiry 30 November 2027")
    }

    func testAPlainBarcodeIsAProductNumberWithNoLot() throws {
        let scan = try StockScan.read("2000000000015", referenceYear: 2026).get()
        XCTAssertEqual(scan.code, gtinA)
        XCTAssertNil(scan.lot)
        XCTAssertEqual(StockScan.forms(of: gtinA), [gtinA, "2000000000015"])
    }

    func testAPlainTextCodeIsKeptVerbatimButABrokenGS1CodeIsRefused() throws {
        XCTAssertEqual(try StockScan.read("SHELF-7", referenceYear: 2026).get().code, "SHELF-7")
        XCTAssertEqual(StockScan.read("0102000000000016" + "10ZZ1001", referenceYear: 2026), .failure(.badCheckDigit))
        XCTAssertEqual(StockScan.read("01\(gtinA)17271301", referenceYear: 2026), .failure(.impossibleDate(ai: "17")))
    }

    func testScanCodeReportsTheParsedFields() {
        let said = BarcodeScannerTool.gs1Fields("01\(gtinA)17271130" + "10ZZ1001", referenceYear: 2026)
        XCTAssertTrue(said.contains("lot ZZ1001"), said)
        XCTAssertTrue(said.contains("expiry 30 November 2027"), said)
        XCTAssertTrue(said.contains("(01)\(gtinA)(17)271130(10)ZZ1001"), said)
        XCTAssertEqual(BarcodeScannerTool.gs1Fields("https://example.invalid/x"), "")
        XCTAssertTrue(BarcodeScannerTool.gs1Fields("0102000000000016", referenceYear: 2026).contains("could not be read safely"))
    }
}
