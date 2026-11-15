import XCTest
@testable import OpenGlasses

private typealias Row = OpenGlasses.DraftRow
private typealias FaultRow = OpenGlasses.FaultCodeRow
private typealias ModelRowT = OpenGlasses.ModelRow
private typealias SymptomRowT = OpenGlasses.SymptomRow
private typealias Page = OpenGlasses.DraftPage
private typealias Parser = OpenGlasses.PastedDraftParser

/// Plan LW §4a — pasted and proposed rows checked against a manual's page text. The manual is
/// invented: its codes, models and every sentence were written for this test.
final class DraftRowCheckTests: XCTestCase {

    typealias Mark = DraftRowCheck.Outcome.Mark

    /// PDF pages 41, 42 and 58 print 39, 40 and 56; nothing prints 41.
    static let manual = ManualPageText(
        texts: [
            1: "Installation manual\nQX-100 and QX-100A outdoor units\nRead every step before you begin.",
            2: "Contents\nSafety 3\nFault codes 39\nTroubleshooting 56",
            3: "Safety\nSwitch off the supply before opening the panel.",
            41: "Fault codes\nE9 Low refrigerant charge. Look at the pressures before adding any.\n"
                + "F17 Outdoor fan not turning. Test the fan motor and its capacitor.",
            42: "E\u{2013}12 Sensor open circuit. Measure the sensor against the resistance chart.\n"
                + "The QX-200 controller keeps its own list of codes.",
            44: "Display codes\nE 5 Water sensor dry. Fill the tray before restarting.",
            58: "Troubleshooting\nThe unit runs but the room stays warm. Clean the outdoor coil and look for dirt between the fins.\n"
                + "Make sure the outdoor fan turns with the compressor.",
            60: "Pump codes\nP99O1 pump relay stuck. Replace the relay board.",
            61: "lk;j qwr zxcv bnm,. ;lkj hgf dsq wrt pzx qqq zzz kkk vvv",
            70: "Specifications\nQX-300 charge 2.1 kg",
            90: "Index\nF17 outdoor fan not turning, see fault codes\nE9 low charge"
        ],
        labels: PageLabelMap([PageLabel(page: 41, label: "39", source: .printed),
                              PageLabel(page: 42, label: "40", source: .printed),
                              PageLabel(page: 58, label: "56", source: .printed)]),
        unclearPages: [61],
        recognisedPages: [60, 61])

    private func check(_ row: Row, copied: Bool = false, in manual: ManualPageText = manual) -> DraftRowCheck.Outcome {
        DraftRowCheck.check(row, copiedFromManual: copied, in: manual)
    }

    private func code(_ code: String, _ label: String, _ page: String) -> Row {
        .faultCode(FaultRow(code: code, label: label, page: Page(cited: page)))
    }

    // MARK: - Fault codes

    func testACodeWithItsLabelOnThePrintedPageIsChecked() {
        let outcome = check(code("E9", "Low refrigerant charge", "39"))
        XCTAssertEqual(outcome.mark, .checked)
        XCTAssertEqual(outcome.page, 41, "printed 39 is PDF page 41")
        XCTAssertFalse(outcome.inManualsWords)
        XCTAssertTrue(outcome.isChecked)
    }

    func testAPDFPageNumberIsReadWhenNoPagePrintsIt() {
        XCTAssertEqual(check(code("E9", "Low charge", "41")).mark, .checked)
        XCTAssertEqual(check(.faultCode(FaultRow(code: "E9", label: "Low charge", page: Page.parse("p. 41")!))).page, 41)
    }

    func testACodeOnExactlyOneOtherPageIsSuggested() {
        let outcome = check(code("E-12", "Sensor open", "39"))
        XCTAssertEqual(outcome.mark, .foundOnAnotherPage(42))
        XCTAssertEqual(outcome.page, 42)
        XCTAssertFalse(outcome.isChecked)
    }

    func testACodeOnSeveralOtherPagesListsThem() {
        XCTAssertEqual(check(code("F17", "Outdoor fan not turning", "56")).mark, .foundOnPages([41, 90]))
    }

    func testACodeTheManualNeverPrintsIsNotFound() {
        let outcome = check(code("E77", "Compressor locked", "39"))
        XCTAssertEqual(outcome.mark, .notFound)
        XCTAssertEqual(outcome.codePages, [])
    }

    func testAPrintedCodeWithAnotherMeaningIsNotFoundButSaysWhereTheCodeIs() {
        let outcome = check(code("E9", "Water pump failure", "39"))
        XCTAssertEqual(outcome.mark, .notFound)
        XCTAssertEqual(outcome.codePages, [41, 90])
    }

    func testCaseSpacesAndDashesAreAlike() {
        XCTAssertEqual(check(code("e-12", "sensor open circuit", "40")).mark, .checked, "an en dash on the page, a hyphen in the row")
        XCTAssertEqual(check(code("E12", "Sensor open", "40")).mark, .checked)
        XCTAssertEqual(check(code("E5", "Water sensor dry", "44")).mark, .checked, "the page prints \"E 5\"")
        XCTAssertEqual(check(code("E 5", "Water sensor dry", "44")).mark, .checked)
    }

    func testARecognisedPageFoldsOAndZero() {
        XCTAssertEqual(check(code("P9901", "Pump relay stuck", "60")).mark, .checked)
        var typed = Self.manual
        typed.recognisedPages = []
        XCTAssertEqual(check(code("P9901", "Pump relay stuck", "60"), in: typed).mark, .notFound,
                       "a text layer is read as printed")
    }

    func testAnUnclearPageIsNeitherPassNorFail() {
        let outcome = check(code("E9", "Low charge", "61"))
        XCTAssertEqual(outcome.mark, .pageTextUnclear)
        XCTAssertEqual(outcome.page, 61)
        XCTAssertFalse(outcome.isChecked)
    }

    func testALabelInTheManualsWordsIsMarked() {
        let copied = check(code("F17", "Test the fan motor and its capacitor", "39"))
        XCTAssertEqual(copied.mark, .checked)
        XCTAssertTrue(copied.inManualsWords, "six words in a row match the page")
        let own = check(code("F17", "Fan motor or capacitor", "39"))
        XCTAssertFalse(own.inManualsWords)
        XCTAssertTrue(check(code("F17", "Fan motor or capacitor", "39"), copied: true).inManualsWords,
                      "a label prefilled from the manual stays the manual's until rewritten")
    }

    func testARowThatAlreadyKnowsItsPDFPageUsesIt() {
        let row = Row.faultCode(FaultRow(code: "E9", label: "Low charge", page: Page(cited: "39", physical: 90)))
        XCTAssertEqual(check(row).mark, .checked)
        XCTAssertEqual(check(row).page, 90)
    }

    func testARangeIsReadByItsFirstPage() {
        XCTAssertEqual(check(code("E9", "Low charge", "39-40")).page, 41)
    }

    // MARK: - Models

    func testEverySpellingPrintedIsChecked() {
        let outcome = check(.model(ModelRowT(model: "QX-100", aliases: ["QX100", "qx 100"], page: Page(cited: "1"))))
        XCTAssertEqual(outcome.mark, .checked)
        XCTAssertEqual(outcome.page, 1)
        XCTAssertNil(outcome.mentionedOnce, "printed on the cover, where a model is expected once")
    }

    func testASpellingTheManualNeverPrintsIsNamed() {
        let outcome = check(.model(ModelRowT(model: "QX-100", aliases: ["QX-101"])))
        XCTAssertEqual(outcome.mark, .notFound)
        XCTAssertEqual(outcome.missingSpellings, ["QX-101"])
    }

    func testAModelPrintedOnceDeepInTheManualHasASoftNote() {
        let outcome = check(.model(ModelRowT(model: "QX-300")))
        XCTAssertEqual(outcome.mark, .checked)
        XCTAssertEqual(outcome.mentionedOnce, 70)
        XCTAssertEqual(outcome.page, 70)
    }

    func testAMissingModelIsUnclearOnlyWhenNoPageCanBeRead() {
        XCTAssertEqual(check(.model(ModelRowT(model: "QX-999"))).mark, .notFound, "one unclear page does not excuse it")
        let unreadable = ManualPageText(texts: [1: "lk;j qwr"], unclearPages: [1], recognisedPages: [1])
        XCTAssertEqual(check(.model(ModelRowT(model: "QX-999")), in: unreadable).mark, .pageTextUnclear)
    }

    // MARK: - Symptoms

    private func symptom(_ said: String, _ cause: String, _ first: String, _ page: String) -> Row {
        .symptom(SymptomRowT(symptom: said, cause: cause, check: first, page: Page(cited: page)))
    }

    func testASymptomIsSectionCheckedNeverATick() {
        let outcome = check(symptom("Room stays warm", "Dirty outdoor coil", "Clean the coil", "56"))
        XCTAssertEqual(outcome.mark, .sectionChecked)
        XCTAssertEqual(outcome.page, 58)
        XCTAssertFalse(outcome.isChecked, "the wording is the author's")
    }

    func testASymptomOnAnotherPageIsSuggested() {
        XCTAssertEqual(check(symptom("Room stays warm", "Dirty outdoor coil", "Clean the coil", "39")).mark,
                       .foundOnAnotherPage(58))
    }

    func testASymptomNoPageSupportsIsNotFound() {
        XCTAssertEqual(check(symptom("Smells of burning", "Wiring overheated", "Inspect terminals", "56")).mark, .notFound)
    }

    func testACodeInASymptomGetsTheCodeCheck() {
        let missing = check(symptom("Shows E77", "Dirty outdoor coil", "Clean the coil", "56"))
        XCTAssertEqual(missing.mark, .notFound)
        XCTAssertEqual(missing.missingCodes, ["E77"])
        XCTAssertEqual(check(symptom("Shows F17", "Outdoor fan stopped", "Fan turns with the compressor", "56")).mark,
                       .sectionChecked)
    }

    func testASymptomOnAnUnclearPageIsUnclear() {
        XCTAssertEqual(check(symptom("Room stays warm", "Dirty coil", "Clean the coil", "61")).mark, .pageTextUnclear)
    }

    func testASymptomInTheManualsWords() {
        XCTAssertTrue(check(symptom("Room stays warm", "Dirty coil", "look for dirt between the fins", "56")).inManualsWords)
    }

    // MARK: - Paste, then check

    func testAPastedReplyIsCheckedRowByRowAndOnlyCheckedRowsAreKeptByKeepAllChecked() {
        let parsed = Parser.parse("""
        Here is what I found:
        | Code | What it means | Page |
        |---|---|---|
        | E9 | Low refrigerant charge | 39 |
        | E-12 | Sensor open | 39 |
        | E77 | Compressor locked | 40 |
        | F17 | Fan motor or capacitor | 39 |
        """, layer: .faultCodes)
        XCTAssertEqual(parsed.unparsed.map(\.text), ["Here is what I found:"], "the prose is shown, not dropped")
        let outcomes = parsed.rows.map { DraftRowCheck.check($0, in: Self.manual) }
        XCTAssertEqual(outcomes.map(\.mark), [.checked, .foundOnAnotherPage(42), .notFound, .checked])
        XCTAssertEqual(DraftRowCheck.keepAllChecked(outcomes), [0, 3])
    }

    // MARK: - Pieces

    func testCodeKeysAndKeyWords() {
        XCTAssertEqual(DraftRowCheck.codeKey("e\u{2013}12 ", folding: false), "E12")
        XCTAssertEqual(DraftRowCheck.codeKey("SO-1", folding: true), "501")
        XCTAssertEqual(DraftRowCheck.keyWords("Check the fan, the FAN motor and 24 V"), ["fan", "motor"])
        XCTAssertTrue(DraftRowCheck.sameWord("sensors", "sensor"))
        XCTAssertFalse(DraftRowCheck.sameWord("fan", "fans"), "short words must match exactly")
    }

    func testGarbledText() {
        XCTAssertTrue(ManualPageText.looksGarbled(Self.manual.texts[61]!))
        XCTAssertFalse(ManualPageText.looksGarbled(Self.manual.texts[58]!))
        XCTAssertFalse(ManualPageText.looksGarbled("zx qq"), "short text is never called garbled")
    }
}
