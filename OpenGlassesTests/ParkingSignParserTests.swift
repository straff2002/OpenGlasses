import XCTest
@testable import OpenGlasses

/// Plan GH P0 — car-park sign fixtures (OCR lines as Vision returns them) into level / space /
/// zone, with a score and a flag for when to ask the wearer.
final class ParkingSignParserTests: XCTestCase {

    func testKeywordedLevelAndBayAreCertain() {
        let reading = ParkingSignParser.parse(lines: ["LEVEL 2", "BAY 41"])
        XCTAssertEqual(reading.fields, ParkingFields(level: "2", space: "41"))
        XCTAssertEqual(reading.confidence, 1.0, accuracy: 0.001)
        XCTAssertFalse(reading.needsConfirmation)
    }

    func testKeywordAndValueOnSeparateLinesAmidNoise() {
        let reading = ParkingSignParser.parse(lines: ["EXIT →", "MAX HEIGHT 2.1M", "LEVEL", "4", "GREEN ZONE"])
        XCTAssertEqual(reading.fields.level, "4")
        XCTAssertEqual(reading.fields.zone, "Green")
        XCTAssertNil(reading.fields.space, "the height limit must not be read as a space")
        XCTAssertFalse(reading.needsConfirmation)
    }

    func testCompactPillarCodeIsConfidentEnough() {
        let reading = ParkingSignParser.parse(lines: ["P3"])
        XCTAssertEqual(reading.fields.level, "3")
        XCTAssertFalse(reading.needsConfirmation)
    }

    func testBareBayCodeAsksForConfirmation() {
        let reading = ParkingSignParser.parse(lines: ["B12"])
        XCTAssertEqual(reading.fields.space, "B12")
        XCTAssertTrue(reading.needsConfirmation)
    }

    func testLargeIsolatedNumberIsAProbableSpace() {
        let reading = ParkingSignParser.parse(lines: ["L2", "041"])
        XCTAssertEqual(reading.fields, ParkingFields(level: "2", space: "41"))
        XCTAssertTrue(reading.needsConfirmation, "a lone number is a guess")
        XCTAssertEqual(reading.candidates.first?.field, .level, "candidates are ordered best first")
    }

    func testNumbersOnANoisyLineAreIgnored() {
        let reading = ParkingSignParser.parse(lines: ["OPEN 24 HOURS", "NO PARKING"])
        XCTAssertTrue(reading.isEmpty)
        XCTAssertFalse(reading.needsConfirmation)
        XCTAssertEqual(reading.confidence, 0)
    }

    func testConflictingLevelsAskForConfirmationAndKeepTheFirst() {
        let reading = ParkingSignParser.parse(lines: ["LEVEL 2", "LEVEL 3"])
        XCTAssertEqual(reading.fields.level, "2")
        XCTAssertTrue(reading.needsConfirmation)
    }

    func testColourLevelAndRow() {
        let reading = ParkingSignParser.parse(lines: ["BLUE LEVEL", "ROW C", "SPACE 118"])
        XCTAssertEqual(reading.fields, ParkingFields(level: "Blue", space: "118", zone: "Row C"))
        XCTAssertFalse(reading.needsConfirmation)
    }
}
