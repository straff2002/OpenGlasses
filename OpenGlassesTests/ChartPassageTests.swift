import XCTest
@testable import OpenGlasses

/// Plan LX P0 §4 — the passage retrieval finds for a chart: the words-only one written at import,
/// and the template for a read chart. Invented charts only.
final class ChartPassageTests: XCTestCase {

    private typealias F = ChartFixtures

    func testTheWordsOnlyPassageKeepsTheCaptionAxesAndLabelsAndSaysValuesWereNotRead() {
        let candidate = F.candidates(F.chargingChart(), physical: 41, printed: "39").first!
        XCTAssertEqual(ChartPassage.wordsOnlyText(for: candidate), """
            Chart: Figure 9 \u{2014} Charging chart, model QMX90 (page 39). Values not read: the manual gives them only as a chart.
            Axes: Outdoor temperature (°F), 65 to 115; Target superheat (°F), 0 to 40.
            Printed on the chart: 57 Do not charge below 55 °F 62 67 72.
            """)
    }

    func testAWordsOnlyPassageWithNoCaptionOrTitlesStillSaysWhatItIs() {
        let candidate = F.candidates(F.chargingChart(caption: nil, yTitle: false, xTitle: nil, insideLabels: [])).first!
        let text = ChartPassage.wordsOnlyText(for: candidate)
        XCTAssertTrue(text.hasPrefix("Chart (page 41). Values not read"))
        XCTAssertTrue(text.contains("Axes: the x axis, 65 to 115; the y axis, 0 to 40."))
    }

    func testTheWordsOnlyPassageIsAChartChunkNamedByItsCaption() {
        let candidates = F.candidates(F.chargingChart()) + F.candidates(F.chargingChart(caption: nil), physical: 42)
        let chunks = ChartPassage.chunks(for: candidates, startingAt: 17)
        XCTAssertEqual(chunks.map(\.index), [17, 18])
        XCTAssertEqual(chunks.map(\.kind), [.chart, .chart])
        XCTAssertEqual(chunks.map(\.page), [41, 42])
        XCTAssertEqual(chunks.map(\.figure), ["Figure 9", nil])
        XCTAssertTrue(DocumentChunker.Kind.chart.isAppWritten)
        XCTAssertFalse(DocumentChunker.Kind.diagram.isAppWritten)
    }

    func testTheTemplateForAReadChart() {
        let text = ChartPassage.readText(F.validated(), caption: .init(label: "Figure 9", title: "Target superheat"),
                                         description: nil)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Chart: Figure 9 \u{2014} Target superheat (page 41). Read from a picture of the chart; every value is approximate.")
        XCTAssertEqual(lines[1], "Axes: Outdoor temperature (°F), 65 to 115; Target superheat (°F), 0 to 40.")
        XCTAssertEqual(lines[2], "Series by indoor wet bulb: 57, 62, 67, 72.")
        XCTAssertEqual(lines[5], "At indoor wet bulb 67: about 28 at 65, about 22 at 75, about 15 at 85, about 9 at 95, about 6 at 105, about 4 at 115.")
    }

    func testADescriptionThatPassesItsCheckIsAddedAndOneThatFailsIsDropped() {
        let caption = ChartCandidate.Caption(label: "Figure 9", title: "Target superheat")
        let good = "Target superheat falls as the outdoor temperature rises from 65 to 115."
        let bad = "Target superheat falls to about 3 at 120."
        XCTAssertTrue(ChartPassage.readText(F.validated(), caption: caption, description: good).hasSuffix(good))
        XCTAssertFalse(ChartPassage.readText(F.validated(), caption: caption, description: bad).contains(bad))
    }
}

/// Plan LX P0 §5 — how a chart's value is said: *about* and the page in every wording.
final class ChartCitationTests: XCTestCase {

    private typealias F = ChartFixtures

    private func fifteen() -> ChartValue {
        guard case .value(let value, _) = ChartLookup.value(in: F.validated(), series: "67", at: 85) else { fatalError() }
        return value
    }

    func testTheEnglishValueSentence() {
        XCTAssertEqual(ChartCitation.valueSentence(fifteen(), page: "41", figure: "Figure 99"),
                       "About 15 °F, read off the chart on page 41 (Figure 99). That's approximate: check it on the chart.")
    }

    func testOutsideTheChartAndPageOnlyWordings() {
        XCTAssertEqual(ChartCitation.outsideSentence(page: "41", figure: "Figure 99"),
                       "That's outside the chart on page 41 (Figure 99), so the manual doesn't give one.")
        XCTAssertEqual(ChartCitation.pageOnlySentence(page: "41", figure: nil),
                       "The manual gives this as a chart on page 41. Its values haven't been read: check the chart.")
    }

    func testAnotherLanguageKeepsAboutThePageAndItsDecimalComma() throws {
        XCTAssertEqual(ChartCitation.valueSentence(fifteen(), page: "41", figure: "Abbildung 99", language: "de-DE"),
                       "Etwa 15 °F, abgelesen aus dem Diagramm auf Seite 41 (Abbildung 99). Das ist ein ungefährer Wert: Prüfen Sie ihn im Diagramm.")
        // A finer reading (ticks a degree apart near the foot) gives half a degree, with a comma.
        let fine = F.validated(F.chargingReading(axes: [
            .init(role: .x, title: "Outdoor temperature", unit: "°F", ticks: F.xValues),
            .init(role: .y, title: "Target superheat", unit: "°F", ticks: [0, 1, 2, 3, 4, 5, 10, 20, 30, 40]),
        ]))
        guard case .value(let half, _) = ChartLookup.value(in: fine, series: "67", at: 80) else { return XCTFail() }
        XCTAssertEqual(half.about, 18.5)
        XCTAssertTrue(ChartCitation.valueSentence(half, page: "41", figure: nil, language: "de").hasPrefix("Etwa 18,5 °F"))
        XCTAssertTrue(ChartCitation.valueSentence(half, page: "41", figure: nil).hasPrefix("About 18.5 °F"))
    }

    func testEveryWordingCarriesAboutAndThePage() {
        for (language, wording) in ChartCitation.wordings {
            let value = ChartCitation.valueSentence(fifteen(), page: "417", figure: nil, language: language)
            XCTAssertTrue(value.hasPrefix(wording.about), "\(language): \(value)")
            XCTAssertTrue(value.contains("417"), "\(language): \(value)")
            XCTAssertTrue(ChartCitation.outsideSentence(page: "417", figure: nil, language: language).contains("417"), language)
            XCTAssertTrue(ChartCitation.pageOnlySentence(page: "417", figure: nil, language: language).contains("417"), language)
            for template in [wording.value, wording.outside, wording.pageOnly] {
                XCTAssertTrue(template.contains("{page}"), language)
            }
            XCTAssertTrue(wording.value.contains("{about}") && wording.value.contains("{value}"), language)
        }
        XCTAssertEqual(ChartCitation.wording(for: "ja").about, "About", "a language without a template is said in English")
    }

    func testValuesAreWrittenToTheirStep() {
        XCTAssertEqual(ChartCitation.decimals(of: 5), 0)
        XCTAssertEqual(ChartCitation.decimals(of: 0.5), 1)
        XCTAssertEqual(ChartCitation.decimals(of: 0.05), 2)
    }

    func testThePageLabelIsThePageEvidenceLabel() {
        XCTAssertEqual(ChartCitation.label(title: "Invented service manual", page: 41, figure: "Figure 9"),
                       PageEvidencePolicy.label(title: "Invented service manual", page: 41, figure: "Figure 9"))
    }
}

/// Plan LX P0 §2 — pass 2's description is kept only when every number in it is the chart's.
final class ChartDescriptionCheckTests: XCTestCase {

    private typealias F = ChartFixtures

    func testANumberNotInTheTableDropsTheDescription() {
        let reading = F.chargingReading()
        let caption = ChartCandidate.Caption(label: "Figure 9", title: "Charging chart")
        XCTAssertTrue(ChartDescriptionCheck.passes("Each curve falls from 65 to 115; the 72 curve starts near 36.",
                                                   reading: reading, caption: caption))
        XCTAssertFalse(ChartDescriptionCheck.passes("Superheat bottoms out near 3.5 at high temperatures.",
                                                    reading: reading, caption: caption))
        XCTAssertEqual(ChartDescriptionCheck.strayNumbers(in: "From 65 to 125.", reading: reading, caption: caption), [125])
    }

    func testCaptionNumbersAndRangesAreAllowed() {
        let reading = F.chargingReading()
        let caption = ChartCandidate.Caption(label: "Figure 9", title: "Charging chart")
        XCTAssertTrue(ChartDescriptionCheck.passes("Figure 9 gives superheat for 65-115 outdoor.", reading: reading, caption: caption))
    }

    func testNumbersAreReadAsWritten() {
        XCTAssertEqual(ChartDescriptionCheck.numbers(in: "about 0.35 at 1,200 and -10"), [0.35, 1200, -10])
    }
}
