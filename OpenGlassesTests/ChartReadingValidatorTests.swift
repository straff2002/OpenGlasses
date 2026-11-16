import XCTest
@testable import OpenGlasses

/// Plan LX P0 §3 — a hand-written reading checked against the words its page prints. Invented
/// charts only.
final class ChartReadingValidatorTests: XCTestCase {

    private typealias F = ChartFixtures
    private let candidate = ChartFixtures.chargingCandidate()

    private func check(_ reading: ChartReading) -> ChartReadingValidator.Verdict {
        ChartReadingValidator.check(reading, against: candidate)
    }

    func testAReadingThatAgreesWithItsPageIsUsable() throws {
        let validated = try XCTUnwrap(check(F.chargingReading()).validated)
        XCTAssertEqual(validated.warnings, [])
        XCTAssertEqual(validated.reading.step(.y), 5, "half the smallest tick interval")
        XCTAssertEqual(validated.reading.step(.x), 5)
    }

    func testTicksThePageDoesNotPrintRejectTheReading() {
        let reading = F.chargingReading(axes: [
            .init(role: .x, title: "Outdoor temperature", unit: "°F", ticks: [60, 70, 80, 90, 100, 110, 120]),
            .init(role: .y, title: "Target superheat", unit: "°F", ticks: F.yValues),
        ], series: [.init(label: "67", parameter: 67, points: [.init(70, 20), .init(110, 5)])])
        XCTAssertEqual(check(reading), .rejected([.ticksNotOnPage]))
    }

    func testAnAxisTheCandidateHasNoRunForIsNotOnThePage() {
        var reading = F.chargingReading()
        reading.axes.append(.init(role: .secondY, title: "Pressure", unit: "psig", ticks: [100, 200, 300]))
        XCTAssertEqual(check(reading), .rejected([.ticksNotOnPage]))
    }

    func testAMissingUnitLeavesTheReadingWordsOnly() {
        // No unit read, and the page's own run printed none.
        let page = F.candidates(F.chargingChart(yTitle: false)).first!
        let reading = F.chargingReading(axes: [
            .init(role: .x, title: "Outdoor temperature", unit: "°F", ticks: F.xValues),
            .init(role: .y, title: "Target superheat", unit: nil, ticks: F.yValues),
        ])
        XCTAssertEqual(ChartReadingValidator.check(reading, against: page), .wordsOnly([.unitMissing]))
    }

    func testAUnitPrintedOnThePageIsEnoughWhenTheReadingLeftItOut() throws {
        let reading = F.chargingReading(axes: [
            .init(role: .x, title: "Outdoor temperature", unit: nil, ticks: F.xValues),
            .init(role: .y, title: "Target superheat", unit: nil, ticks: F.yValues),
        ])
        XCTAssertNotNil(check(reading).validated)
    }

    func testAPointOutsideTheAxesRejectsTheReading() {
        let reading = F.chargingReading(series: [.init(label: "67", parameter: 67, points: F.points([28, 22, 15, 9, 6, 51]))])
        XCTAssertEqual(check(reading), .rejected([.pointOutsideAxes]))
    }

    func testAPointWithinOneStepOfTheAxesIsKept() {
        let reading = F.chargingReading(series: [.init(label: "67", parameter: 67, points: F.points([28, 22, 15, 9, 6, 44]))])
        XCTAssertNotNil(check(reading).validated)
    }

    func testXGoingBackwardsRejectsTheReading() {
        let reading = F.chargingReading(series: [.init(label: "67", parameter: 67,
                                                       points: [.init(65, 28), .init(85, 15), .init(75, 22)])])
        XCTAssertEqual(check(reading), .rejected([.seriesNotMonotonic]))
    }

    func testARepeatedXMergesOnlyWhenItsYValuesAgree() throws {
        let agree = F.chargingReading(series: [.init(label: "67", parameter: 67,
                                                     points: [.init(65, 28), .init(75, 22), .init(75, 24), .init(85, 15)])])
        let merged = try XCTUnwrap(check(agree).validated)
        XCTAssertEqual(merged.reading.series[0].points, [.init(65, 28), .init(75, 23), .init(85, 15)])
        let disagree = F.chargingReading(series: [.init(label: "67", parameter: 67,
                                                        points: [.init(65, 28), .init(75, 22), .init(75, 34)])])
        XCTAssertEqual(check(disagree), .rejected([.seriesNotMonotonic]))
    }

    func testALogAxisWithAZeroTickIsRejected() {
        XCTAssertFalse(ChartReadingValidator.isLogarithmic([0, 10, 100, 1000]))
        XCTAssertFalse(ChartReadingValidator.isLogarithmic([1, 10, 50, 1000]))
        XCTAssertTrue(ChartReadingValidator.isLogarithmic([1, 10, 100, 1000]))

        let logPage = F.candidates(F.chargingChart(xValues: [1, 10, 100, 1000, 10000, 100000])).first!
        let reading = ChartReading(kind: .lines, axes: [
            .init(role: .x, title: "Flow", unit: "gpm", ticks: [1, 10, 100, 1000, 10000, 100000], scale: .logarithmic),
            .init(role: .y, title: "Head", unit: "ft", ticks: F.yValues, scale: .logarithmic),
        ], series: [.init(label: "Pump", points: [.init(1, 30), .init(100, 20)])], source: F.source)
        XCTAssertEqual(ChartReadingValidator.check(reading, against: logPage), .rejected([.logarithmicAxisInvalid]),
                       "the y axis has a zero tick")
    }

    func testTooManySeriesIsAMisread() {
        let many = (0..<13).map { ChartReading.Series(label: "\(57 + $0)", parameter: Double(57 + $0), points: F.points([10, 9, 8, 7, 6, 5])) }
        XCTAssertEqual(check(F.chargingReading(series: many)), .rejected([.tooManySeries]))
    }

    func testTooManyPointsIsAMisread() {
        let points = (0..<61).map { ChartReading.Point(65 + Double($0) * 50 / 60, 20) }
        XCTAssertEqual(check(F.chargingReading(series: [.init(label: "67", parameter: 67, points: points)])),
                       .rejected([.tooManyPoints]))
    }

    func testAFamilyLabelMissingFromThePageIsAWarningNotARejection() throws {
        let reading = F.chargingReading(series: [
            .init(label: "67", parameter: 67, points: F.points([28, 22, 15, 9, 6, 4])),
            .init(label: "77", parameter: 77, points: F.points([38, 33, 27, 20, 14, 10])),
        ])
        let validated = try XCTUnwrap(check(reading).validated)
        XCTAssertEqual(validated.warnings, [.familyLabelNotOnPage])
    }

    func testAReadingWithNoXAxisIsRejected() {
        let reading = F.chargingReading(axes: [.init(role: .y, title: "Target superheat", unit: "°F", ticks: F.yValues)])
        XCTAssertEqual(check(reading), .rejected([.axisMissing]))
    }

    func testAReadingRoundTripsThroughJSON() throws {
        let reading = F.chargingReading(bands: [.init(note: "Do not charge below 55 °F", x: 65...70)])
        let data = try JSONEncoder().encode(reading)
        XCTAssertEqual(try JSONDecoder().decode(ChartReading.self, from: data), reading)
    }
}
