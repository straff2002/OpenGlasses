import XCTest
@testable import OpenGlasses

/// Plan GH P0 — what the wearer says about where they parked, into level / space / zone / note.
final class ParkingUtteranceParserTests: XCTestCase {

    private func parse(_ text: String) -> ParkingFields { ParkingUtteranceParser.parse(text) }

    func testLevelAndSpaceWithPunctuation() {
        XCTAssertEqual(parse("I parked on level 2, space 41."),
                       ParkingFields(level: "2", space: "41"))
    }

    func testCompactLevelAndLetteredBay() {
        XCTAssertEqual(parse("P3 bay B12"), ParkingFields(level: "3", space: "B12"))
    }

    func testFloorMinusOne() {
        XCTAssertEqual(parse("floor minus one").level, "-1")
        XCTAssertEqual(parse("level -2").level, "-2")
    }

    func testStandaloneBasementCode() {
        XCTAssertEqual(parse("B2").level, "B2")
        XCTAssertEqual(parse("basement 3, spot 15"), ParkingFields(level: "B3", space: "15"))
    }

    func testRowAndColourZone() {
        XCTAssertEqual(parse("row G").zone, "Row G")
        XCTAssertEqual(parse("green zone").zone, "Green")
        XCTAssertEqual(parse("level 4 in the blue section").zone, "Blue")
    }

    func testSpelledNumbers() {
        XCTAssertEqual(parse("level two, space forty-one"), ParkingFields(level: "2", space: "41"))
        XCTAssertEqual(parse("space one hundred and twelve").space, "112")
        XCTAssertEqual(parse("bay B twelve").space, "B12")
    }

    func testOrdinalBeforeKeywordAndNote() {
        XCTAssertEqual(parse("second floor near the lifts"),
                       ParkingFields(level: "2", note: "near the lifts"))
        XCTAssertEqual(parse("3rd level").level, "3")
    }

    func testGroundAndRoof() {
        XCTAssertEqual(parse("ground floor, bay 7"), ParkingFields(level: "G", space: "7"))
        XCTAssertEqual(parse("on the roof level").level, "Roof")
    }

    func testLetteredLevelName() {
        XCTAssertEqual(parse("level 3A space 9"), ParkingFields(level: "3A", space: "9"))
    }

    func testUnparsedTextBecomesTheNote() {
        let fields = parse("Remember I parked by the red door")
        XCTAssertNil(fields.level)
        XCTAssertNil(fields.space)
        XCTAssertNil(fields.zone)
        XCTAssertEqual(fields.note, "by the red door")
    }

    func testFillerOnlyLeavesNoNote() {
        XCTAssertTrue(parse("I parked the car here").isEmpty)
        XCTAssertTrue(parse("").isEmpty)
    }

    func testANumberWithoutAKeywordIsNotGuessedAsALevel() {
        let fields = parse("I parked about 5 minutes ago")
        XCTAssertNil(fields.level)
        XCTAssertNil(fields.space)
    }
}
