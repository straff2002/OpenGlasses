import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan LX P0 §1 and §11 — which pictures on a page are charts, from placed words alone. Invented
/// pages only.
final class ChartCandidateTests: XCTestCase {

    private typealias F = ChartFixtures

    func testATwoAxisChartIsFoundWithItsTicksTitlesAndCaption() throws {
        let found = F.candidates(F.chargingChart(), physical: 41, printed: "39")
        XCTAssertEqual(found.count, 1)
        let chart = try XCTUnwrap(found.first)
        XCTAssertEqual(chart.page, ManualTable.Page(physical: 41, printed: "39"))
        XCTAssertEqual(chart.caption, .init(label: "Figure 9", title: "Charging chart, model QMX90"))
        XCTAssertTrue(chart.hasChartWord)
        let x = try XCTUnwrap(chart.axis(.x)), y = try XCTUnwrap(chart.axis(.y))
        XCTAssertEqual(x.values, F.xValues)
        XCTAssertEqual(y.values, F.yValues, "a column reads bottom to top")
        XCTAssertEqual(x.ticks.map(\.text), ["65", "75", "85", "95", "105", "115"], "as printed")
        XCTAssertEqual(x.title, "Outdoor temperature (°F)")
        XCTAssertEqual(x.unit, "°F")
        XCTAssertEqual(y.title, "Target superheat (°F)", "set on its side, read bottom to top")
        XCTAssertEqual(y.unit, "°F")
        XCTAssertEqual(x.scale, .linear)
        XCTAssertEqual(chart.insideNumbers.sorted(), [55, 57, 62, 67, 72])
        XCTAssertTrue(chart.insideWords.contains("charge"))
        XCTAssertNil(chart.pictureType)
        XCTAssertTrue(chart.allowsReading)
        XCTAssertTrue(chart.region.contains(chart.plotArea))
    }

    func testAChartWithNoCaptionIsStillFound() throws {
        let chart = try XCTUnwrap(F.candidates(F.chargingChart(caption: nil)).first)
        XCTAssertNil(chart.caption)
        XCTAssertFalse(chart.hasChartWord, "a chart word raises confidence but is not required")
        XCTAssertEqual(chart.axis(.x)?.values, F.xValues)
    }

    func testAChartWithNoAxisTitlesIsFoundWithoutUnits() throws {
        let chart = try XCTUnwrap(F.candidates(F.chargingChart(yTitle: false, xTitle: nil)).first)
        XCTAssertNil(chart.axis(.x)?.title)
        XCTAssertNil(chart.axis(.y)?.unit)
    }

    func testUnevenlySpacedTicksAreNotAChart() {
        let uneven = F.chargingChart(xPositions: [110, 160, 240, 290, 380, 410])
        XCTAssertTrue(F.candidates(uneven).isEmpty)
    }

    func testTicksThatDoNotStepEvenlyAreNotAChart() {
        let uneven = F.chargingChart(xValues: [65, 70, 85, 90, 110, 112])
        XCTAssertTrue(F.candidates(uneven).isEmpty)
    }

    func testALogarithmicAxisIsFound() throws {
        let log = F.chargingChart(xValues: [1, 10, 100, 1000, 10000, 100000])
        let chart = try XCTUnwrap(F.candidates(log).first)
        XCTAssertEqual(chart.axis(.x)?.scale, .logarithmic)
    }

    func testAWiringDiagramWithTerminalNumbersIsNotAChart() {
        var words = F.line("Figure 12. Control wiring", x: 80, y: 120, bold: true)
        // Terminal numbers scattered over the drawing, wire colours and gauges beside them.
        for (text, x, y) in [("1", 120.0, 200.0), ("2", 190, 214), ("3", 300, 205), ("4", 330, 260), ("5", 150, 300),
                             ("6", 260, 340), ("7", 410, 380), ("18", 230, 410), ("24", 100, 430), ("120", 400, 450)] {
            words.append(PositionedWord(text, x: x, y: y))
        }
        for (text, x, y) in [("BK", 130.0, 200.0), ("RD", 200, 214), ("WH", 310, 205), ("L1", 340, 260), ("L2", 160, 300),
                             ("AWG", 245, 410), ("VAC", 425, 450), ("Transformer", 250, 300), ("Blower", 380, 340)] {
            words.append(PositionedWord(text, x: x, y: y))
        }
        XCTAssertTrue(F.candidates(words).isEmpty)
    }

    func testANumberedBoxFlowDiagramIsNotAChart() {
        // Boxes 1 to 4 across the top; stages 6 to 1 down the left, each heading a line of text.
        var words: [PositionedWord] = []
        for (index, number) in ["1", "2", "3", "4"].enumerated() {
            words.append(PositionedWord(number, x: 120 + Double(index) * 80, y: 160))
        }
        for (index, number) in ["6", "5", "4", "3", "2", "1"].enumerated() {
            let y = 200 + Double(index) * 40
            words.append(F.rightAligned(number, right: 82, y: y))
            words += F.line("Close valve and wait", x: 90, y: y)
        }
        XCTAssertTrue(F.candidates(words).isEmpty)
        let failures = shapeFailures(words)
        XCTAssertTrue(failures.contains(.numbersInsideBoxes) || failures.contains(.axesDoNotMeet), "\(failures)")
    }

    func testAWiringSequenceIsNotAChart() {
        // Seconds along the bottom; the steps numbered up the left, each followed by what happens.
        var words: [PositionedWord] = []
        for (index, number) in ["5", "4", "3", "2", "1"].enumerated() {
            let y = 200 + Double(index) * 40
            words.append(F.rightAligned(number, right: 82, y: y))
            words += F.line("Inducer on", x: 88, y: y)
        }
        for (index, seconds) in ["0", "15", "30", "45", "60"].enumerated() {
            words.append(PositionedWord(seconds, x: 100 + Double(index) * 60, y: 380))
        }
        XCTAssertTrue(F.candidates(words).isEmpty)
        XCTAssertTrue(shapeFailures(words).contains(.numbersInsideBoxes), "the axes meet; the steps head lines of text")
        XCTAssertFalse(shapeFailures(words).contains(.axesDoNotMeet))
    }

    func testATableOfNumbersIsNotAChart() {
        // Row keys 40 to 0 down the left, a value in every column of every row, headings below.
        var words: [PositionedWord] = []
        for (row, key) in ["40", "30", "20", "10", "0"].enumerated() {
            let y = 200 + Double(row) * 30
            words.append(F.rightAligned(key, right: 82, y: y))
            for column in 0..<4 {
                words.append(PositionedWord(String(row * 4 + column + 3), x: 100 + Double(column) * 60, y: y))
            }
        }
        for (column, heading) in ["57", "62", "67", "72"].enumerated() {
            words.append(PositionedWord(heading, x: 100 + Double(column) * 60, y: 350))
        }
        XCTAssertTrue(F.candidates(words).isEmpty)
        XCTAssertEqual(shapeFailures(words), [.gridOfValues], "laid out like axes, filled like a table")
    }

    func testFurnitureNumbersAreNeverTicks() {
        // Page numbers in the header and footer bands, evenly spaced, are not an axis.
        var words: [PositionedWord] = []
        for (index, n) in ["10", "20", "30", "40"].enumerated() { words.append(PositionedWord(n, x: 100 + Double(index) * 60, y: 20)) }
        for (index, n) in ["4", "3", "2", "1"].enumerated() { words.append(F.rightAligned(n, right: 60, y: 10 + Double(index) * 12)) }
        XCTAssertTrue(F.candidates(words).isEmpty)
    }

    func testTickValuesAreRead() {
        XCTAssertEqual(ChartTicks.value(of: "65"), 65)
        XCTAssertEqual(ChartTicks.value(of: "0.8"), 0.8)
        XCTAssertEqual(ChartTicks.value(of: "-10"), -10)
        XCTAssertEqual(ChartTicks.value(of: "1,000"), 1000)
        XCTAssertEqual(ChartTicks.value(of: "65°"), 65)
        XCTAssertEqual(ChartTicks.value(of: "20%"), 20)
        XCTAssertNil(ChartTicks.value(of: "L1"))
        XCTAssertNil(ChartTicks.value(of: "QMX90"))
    }

    func testAxisUnitsAreReadFromTheirTitles() {
        XCTAssertEqual(ChartAxisTitle.unit(in: "Outdoor temperature (°F)"), "°F")
        XCTAssertEqual(ChartAxisTitle.unit(in: "Static pressure [in. w.c.]"), "in. w.c.")
        XCTAssertEqual(ChartAxisTitle.unit(in: "Airflow CFM"), "CFM")
        XCTAssertNil(ChartAxisTitle.unit(in: "Airflow"))
        XCTAssertEqual(ChartAxisTitle.name(of: "Outdoor temperature (°F)"), "Outdoor temperature")
    }

    func testAPageWithoutANumberLineIsNotReadForWords() {
        XCTAssertFalse(PDFChartReader.mayHoldChart("Remove the panel. Check the filter.\nTighten 4 screws to 12 in-lb."))
        XCTAssertTrue(PDFChartReader.mayHoldChart("Figure 9. Charging chart\n40\n30\n20\n10\n0\n65 75 85 95 105 115"))
    }

    // MARK: -

    /// The shape rule's failures for the first row and column the page's numbers make.
    private func shapeFailures(_ words: [PositionedWord]) -> [ChartShape.Failure] {
        let rows = ChartTicks.horizontalRuns(words), columns = ChartTicks.verticalRuns(words)
        // The row and column that meet at a corner, if any do; else the longest of each.
        let meeting = rows.lazy.compactMap { row in columns.first { ChartShape.cornerDistance(row: row, column: $0) != nil }.map { (row, $0) } }.first
        guard let row = meeting?.0 ?? rows.max(by: { $0.ticks.count < $1.ticks.count }),
              let column = meeting?.1 ?? columns.max(by: { $0.ticks.count < $1.ticks.count }) else { return [] }
        let tickWords = Set(row.indices + column.indices)
        let plot = CGRect(x: column.box.maxX, y: column.box.minY, width: max(0, row.box.maxX - column.box.maxX),
                          height: max(0, row.box.minY - column.box.minY))
        let inside = words.enumerated().filter { !tickWords.contains($0.offset) && plot.contains(CGPoint(x: $0.element.rect.midX, y: $0.element.rect.midY)) }
            .map(\.element)
        return ChartShape.check(row: row, column: column, inside: inside, words: words).failures
    }
}
