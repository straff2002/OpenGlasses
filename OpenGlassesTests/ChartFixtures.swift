import CoreGraphics
import Foundation
@testable import OpenGlasses

/// Invented chart pages as placed words, and hand-written readings of them (Plan LX P0). Nothing
/// here comes from a real manual: the captions, titles, model names and numbers are made up.
enum ChartFixtures {

    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let size = 9.0

    /// A word whose right edge is at `right`.
    static func rightAligned(_ text: String, right: Double, y: Double, size: Double = size) -> PositionedWord {
        let width = Double(text.count) * size * 0.55
        return PositionedWord(text, x: right - width, y: y, size: size)
    }

    /// A word set on its side, reading bottom to top, its box `size` wide.
    static func rotated(_ text: String, x: Double, bottom: Double, size: Double = size) -> PositionedWord {
        let height = Double(text.count) * size * 0.55
        return PositionedWord(text, rect: CGRect(x: x, y: bottom - height, width: size, height: height), size: size)
    }

    /// Words laid left to right from `x` on one line.
    static func line(_ text: String, x: Double, y: Double, size: Double = size, bold: Bool = false) -> [PositionedWord] {
        var out: [PositionedWord] = []
        var left = x
        for word in text.split(separator: " ").map(String.init) {
            let w = PositionedWord(word, x: left, y: y, size: size, bold: bold)
            out.append(w)
            left = Double(w.rect.maxX) + size * 0.3
        }
        return out
    }

    static let xValues: [Double] = [65, 75, 85, 95, 105, 115]
    static let xPositions: [Double] = [110, 170, 230, 290, 350, 410]
    static let yValues: [Double] = [0, 10, 20, 30, 40]

    /// An invented charging chart: target superheat up the side (0 to 40 °F), outdoor temperature
    /// along the bottom (65 to 115 °F), four wet-bulb curves labelled inside the plot.
    static func chargingChart(caption: String? = "Figure 9. Charging chart, model QMX90",
                              xPositions: [Double] = xPositions, xValues: [Double] = xValues,
                              yTitle: Bool = true, xTitle: String? = "Outdoor temperature (°F)",
                              insideLabels: [String] = ["57", "62", "67", "72"]) -> [PositionedWord] {
        var words: [PositionedWord] = []
        words += line("Invented service manual", x: 50, y: 30)
        words.append(PositionedWord("41", x: 300, y: 760))
        if let caption { words += line(caption, x: 80, y: 150, bold: true) }
        // y ticks, top to bottom: 40 at the top, 0 at the foot, right-aligned at x 82.
        for (index, value) in yValues.reversed().enumerated() {
            words.append(rightAligned(ChartPassage.number(value), right: 82, y: 195 + Double(index) * 50))
        }
        for (x, value) in zip(xPositions, xValues) {
            words.append(PositionedWord(ChartPassage.number(value), x: x, y: 420, size: size))
        }
        if let xTitle { words += line(xTitle, x: 200, y: 440) }
        if yTitle {
            words.append(rotated("Target", x: 40, bottom: 380))
            words.append(rotated("superheat", x: 40, bottom: 340))
            words.append(rotated("(°F)", x: 40, bottom: 285))
        }
        // Curve labels inside the plot, placed away from every tick's line and column.
        let spots: [(Double, Double)] = [(395, 212), (300, 262), (250, 318), (180, 372)]
        for (label, spot) in zip(insideLabels, spots) { words.append(PositionedWord(label, x: spot.0, y: spot.1)) }
        words += line("Do not charge below 55 °F", x: 130, y: 228, size: 7)
        return words
    }

    static func candidates(_ words: [PositionedWord], physical: Int = 41, printed: String? = nil) -> [ChartCandidate] {
        ChartCandidate.detect(words: words, pageBounds: page, page: ManualTable.Page(physical: physical, printed: printed))
    }

    /// The charging chart's candidate.
    static func chargingCandidate() -> ChartCandidate {
        candidates(chargingChart()).first!
    }

    static let source = ChartReading.Source(documentId: "doc-1", page: .init(physical: 41), figure: "Figure 9")

    /// A hand-written reading of the charging chart: four curves, points at every x tick.
    static func chargingReading(axes: [ChartReading.Axis]? = nil, series: [ChartReading.Series]? = nil,
                                bands: [ChartReading.Band] = []) -> ChartReading {
        ChartReading(
            kind: .family,
            axes: axes ?? [
                .init(role: .x, title: "Outdoor temperature", unit: "°F", ticks: xValues),
                .init(role: .y, title: "Target superheat", unit: "°F", ticks: yValues),
            ],
            series: series ?? [
                .init(label: "57", parameter: 57, points: points([12, 8, 5, 3, 2, 1])),
                .init(label: "62", parameter: 62, points: points([18, 13, 9, 6, 4, 3])),
                .init(label: "67", parameter: 67, points: points([28, 22, 15, 9, 6, 4])),
                .init(label: "72", parameter: 72, points: points([36, 30, 23, 16, 11, 8])),
            ],
            familyTitle: "Indoor wet bulb (°F)",
            bands: bands,
            source: source)
    }

    static func points(_ ys: [Double]) -> [ChartReading.Point] {
        zip(xValues, ys).map { ChartReading.Point($0, $1) }
    }

    /// The charging reading, validated against its page.
    static func validated(_ reading: ChartReading = chargingReading()) -> ValidatedChartReading {
        ChartReadingValidator.check(reading, against: chargingCandidate()).validated!
    }
}
