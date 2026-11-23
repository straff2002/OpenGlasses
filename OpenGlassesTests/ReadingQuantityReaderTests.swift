import XCTest
@testable import OpenGlasses

/// Plan NA P0 — the quantities a reading reply must not fill in: doses and amounts, currency,
/// dates and times; matched to the on-device text by value, with OCR confusions folded on the
/// evidence side only; the wearer's own numbers accepted; words in English only.
final class ReadingQuantityReaderTests: XCTestCase {

    private func evidence(_ text: String) throws -> ReadingEvidence {
        try XCTUnwrap(ReadingEvidence(text: text, source: .readingTool))
    }

    private func ungrounded(_ sentence: String, _ evidenceText: String, question: String? = nil,
                            english: Bool = true) throws -> [ReadingQuantityReader.Kind] {
        ReadingQuantityReader.ungrounded(in: sentence, evidence: try evidence(evidenceText),
                                         question: question, english: english).map(\.kind)
    }

    // MARK: - What is found

    func testDosesAndAmounts() {
        let found = ReadingQuantityReader.quantities(
            in: "Take 500 mg, or 5 ml, 0.5 g, 2.5mg, 10 units, 40 IU, 5 mmol/L, 2% and 250 micrograms.",
            english: true)
        XCTAssertEqual(found.map(\.kind), Array(repeating: .dose, count: 9))
        XCTAssertEqual(found.map(\.values), [[500], [5], [0.5], [2.5], [10], [40], [5], [2], [250]])
    }

    func testCurrency() {
        let found = ReadingQuantityReader.quantities(in: "It's $4.50, or £12, or 20 euros.", english: true)
        XCTAssertEqual(found.map(\.kind), [.currency, .currency, .currency])
        XCTAssertEqual(found.map(\.values), [[4.5], [12], [20]])
    }

    func testDates() {
        let found = ReadingQuantityReader.quantities(
            in: "It expires 03/2026, best before 12/05/2026, posted March 5th, 2026 and due 7 June.",
            english: true)
        XCTAssertEqual(found.map(\.kind), [.date, .date, .date, .date])
        XCTAssertEqual(found.first(where: { $0.month == 3 })?.values, [5, 2026])
        XCTAssertEqual(found.first(where: { $0.month == 6 })?.values, [7])
    }

    func testTimes() {
        let found = ReadingQuantityReader.quantities(in: "Opens at 9:30 am and closes at 5.30 pm, or 6pm.",
                                                     english: true)
        XCTAssertEqual(found.map(\.kind), [.time, .time, .time])
        XCTAssertEqual(found.map(\.values), [[9, 30], [5, 30], [6]])
    }

    func testPlainNumbersAndModelNumbersAreNotQuantities() {
        XCTAssertTrue(ReadingQuantityReader.quantities(in: "Take 2 tablets twice daily from box X500mg.",
                                                       english: true).isEmpty)
        XCTAssertTrue(ReadingQuantityReader.quantities(in: "There are 3 steps.", english: true).isEmpty)
    }

    // MARK: - Matching by value

    func testValuesMatchByValue() throws {
        XCTAssertEqual(try ungrounded("It costs $4.5.", "PRICE $4.50"), [])
        XCTAssertEqual(try ungrounded("Take 500 mg.", "Paracetamol 500mg tablets"), [])
        XCTAssertEqual(try ungrounded("Take 45 mg.", "Dose 4.5 mg"), [.dose])
        XCTAssertEqual(try ungrounded("It's 1,200 mg in all.", "Total 1200 mg"), [])
    }

    func testAnInventedDoseIsUngrounded() throws {
        XCTAssertEqual(try ungrounded("It's amoxicillin, 500 mg, take twice daily.", "Amoxicillin take"), [.dose])
    }

    func testDatesAndTimesMatchTheirParts() throws {
        XCTAssertEqual(try ungrounded("It expires in March 2026.", "EXP 03/2026"), [])
        XCTAssertEqual(try ungrounded("It expires in March 2026.", "EXP MAR 2026"), [])
        XCTAssertEqual(try ungrounded("It expires in April 2026.", "EXP 03/2026"), [.date])
        XCTAssertEqual(try ungrounded("Opens at 9:30.", "OPEN 9:30-17:00"), [])
        XCTAssertEqual(try ungrounded("Opens at 9:45.", "OPEN 9:30-17:00"), [.time])
    }

    // MARK: - OCR confusions, on the evidence side only

    func testOCRConfusionsAreFoldedOnTheEvidenceSide() throws {
        XCTAssertEqual(try ungrounded("Take 500 mg.", "Ibuprofen 5OO mg"), [], "O read as 0")
        XCTAssertEqual(try ungrounded("Take 10 ml.", "Dose l0 ml"), [], "l read as 1")
        XCTAssertEqual(try ungrounded("It's 12 mg.", "Strength I2 mg"), [], "I read as 1")
    }

    func testTheReplyIsNeverFolded() {
        // "5OO mg" in a reply is not a number the reader recognises, and is never read as 500.
        XCTAssertTrue(ReadingQuantityReader.quantities(in: "Take 5OO mg.", english: true)
            .allSatisfy { !$0.values.contains(500) })
    }

    func testFoldingLeavesWordsAlone() {
        XCTAssertEqual(ReadingQuantityReader.foldOCR("5oo ml of oil"), "500 ml of oil")
        XCTAssertEqual(ReadingQuantityReader.foldOCR("mild 2 l"), "mild 2 l")
    }

    // MARK: - The wearer's numbers

    func testANumberFromTheQuestionPasses() throws {
        XCTAssertEqual(try ungrounded("Yes, 400 mg is on it.", "Ibuprofen tablets",
                                      question: "Does this say 400 mg?"), [])
        XCTAssertEqual(try ungrounded("It says 200 mg.", "Ibuprofen tablets",
                                      question: "Does this say 400 mg?"), [.dose])
    }

    // MARK: - Words in English only

    func testNumberWordsAreReadInEnglish() throws {
        XCTAssertEqual(try ungrounded("Take five hundred milligrams.", "Paracetamol 500 mg"), [])
        XCTAssertEqual(try ungrounded("Take two hundred and fifty milligrams.", "Paracetamol 500 mg"), [.dose])
        XCTAssertEqual(try ungrounded("It's twenty dollars.", "PRICE $20"), [])
        XCTAssertEqual(ReadingQuantityReader.wordValue("one thousand two hundred"), 1200)
        XCTAssertEqual(ReadingQuantityReader.wordValue("ninety-nine"), 99)
        XCTAssertNil(ReadingQuantityReader.wordValue("twice"))
    }

    func testNumberWordsAreNotReadInOtherLanguages() throws {
        XCTAssertEqual(try ungrounded("Take five hundred milligrams.", "Paracetamol", english: false), [])
    }

    func testDigitsAreCheckedInSpanishAndJapanese() throws {
        XCTAssertEqual(try ungrounded("Tome 400 mg cada ocho horas.", "Ibuprofeno 200 mg", english: false), [.dose])
        XCTAssertEqual(try ungrounded("Tome 200 mg cada ocho horas.", "Ibuprofeno 200 mg", english: false), [])
        XCTAssertEqual(try ungrounded("Tome 4,5 ml.", "Jarabe 4,5 ml", english: false), [])
        XCTAssertEqual(try ungrounded("1回500mgを服用してください。", "ロキソプロフェン 60mg", english: false), [.dose])
        XCTAssertEqual(try ungrounded("賞味期限は2026年3月5日です。", "賞味期限 2026.03.05", english: false), [])
        XCTAssertEqual(try ungrounded("賞味期限は2027年3月5日です。", "賞味期限 2026.03.05", english: false), [.date])
    }

    // MARK: - Evidence

    func testEmptyTextIsNoEvidence() {
        XCTAssertNil(ReadingEvidence(text: "  \n ", source: .lookClosely))
    }

    func testEvidenceOffersEveryReadingOfItsNumbers() throws {
        let read = try evidence("EXP03/2026 LOT A1234")
        XCTAssertTrue(read.contains(3))
        XCTAssertTrue(read.contains(2026))
        XCTAssertTrue(read.namesMonth(3))
    }
}
