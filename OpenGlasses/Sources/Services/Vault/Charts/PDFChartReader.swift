import Foundation
import PDFKit

/// The charts in a PDF, found from each page's text-layer words (Plan LX §1, §8): on the phone, at
/// import, with no model and no image. A page with no text layer has no words to find a chart by,
/// so a scanned chart is not found yet. The decision is [[ChartCandidate]]'s; this only reads the
/// words off each page, the way [[PDFTableReader]] does for tables.
enum PDFChartReader {

    /// The most charts kept per document. A manual prints tens at most; more is a layout the rule
    /// misreads, and each one is a passage.
    static let documentCap = 200

    static func read(document: PDFDocument, printedLabels: [Int: String] = [:]) -> [ChartCandidate] {
        var found: [ChartCandidate] = []
        for index in 0..<document.pageCount where found.count < documentCap {
            let charts: [ChartCandidate] = autoreleasepool {
                guard let page = document.page(at: index), mayHoldChart(page.string ?? "") else { return [] }
                let words = PDFTableReader.positionedWords(on: page)
                guard words.count >= 2 * ChartTicks.minimumTicks else { return [] }
                let bounds = page.bounds(for: .mediaBox)
                let rotation = PDFTableReader.displayRotation(of: page)
                let shown = rotation % 180 == 0 ? CGRect(origin: .zero, size: bounds.size)
                    : CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
                let physical = index + 1
                return ChartCandidate.detect(words: words, pageBounds: shown,
                                             page: ManualTable.Page(physical: physical, printed: printedLabels[physical]))
            }
            found += charts.prefix(documentCap - found.count)
        }
        return found
    }

    /// Whether a page's plain text could hold a chart's ticks: at least two runs' worth of numbers,
    /// and a line made of numbers alone (a column's ticks come out a line each, a row's on one
    /// line). Asked first, from the text PDFKit already has, so the words' positions — the costly
    /// read — are taken only on pages that pass. Pure.
    static func mayHoldChart(_ text: String) -> Bool {
        var numbers = 0
        var numberLine = false
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            let count = tokens.filter { ChartTicks.value(of: String($0)) != nil }.count
            numbers += count
            if count > 0, count == tokens.count { numberLine = true }
        }
        return numberLine && numbers >= 2 * ChartTicks.minimumTicks
    }
}
