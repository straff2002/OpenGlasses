import XCTest
@testable import OpenGlasses

/// Plan MN P0: reading a typed, spoken or scanned answer, deterministically.
final class AnswerReaderTests: XCTestCase {

    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private let ph = ProcedureAnswerFixtures.phAnswer

    private func value(_ text: String, _ answer: StepAnswer? = nil, locale: Locale? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> ProcedureAnswerValue? {
        switch AnswerReader.read(text, for: answer ?? ph, locale: locale ?? en) {
        case .accepted(let value): return value
        case .askAgain(let why):
            XCTFail("\(text) was asked again: \(why)", file: file, line: line)
            return nil
        }
    }

    private func asksAgain(_ text: String, _ answer: StepAnswer? = nil, locale: Locale? = nil) -> String? {
        if case .askAgain(let why) = AnswerReader.read(text, for: answer ?? ph, locale: locale ?? en) { return why }
        return nil
    }

    func testTypedDigitsAreKeptExactAndRoundedToTheStepsPlaces() {
        let read = value("4.6")
        XCTAssertEqual(read?.number, Decimal(string: "4.60"))
        XCTAssertEqual(read?.entered, "4.6")
        XCTAssertEqual(read?.display(for: ph), "4.60")
        XCTAssertEqual(value("4.449")?.number, Decimal(string: "4.45"), "rounded half away from zero at 2 places")
        XCTAssertEqual(value("about 4.2 on the meter")?.number, Decimal(string: "4.2"))
    }

    func testSpokenWordsReadAsDigits() {
        XCTAssertEqual(value("four point two")?.number, Decimal(string: "4.2"))
        XCTAssertEqual(value("it's four point oh five")?.number, Decimal(string: "4.05"))
        XCTAssertEqual(value("4 point 2")?.number, Decimal(string: "4.2"))
        XCTAssertEqual(value("point five")?.number, Decimal(string: "0.5"))
        let wide = StepAnswer(recordAs: "t", kind: .number, plausible: [-50, 500])
        XCTAssertEqual(value("minus twelve", wide)?.number, -12)
        XCTAssertEqual(value("one hundred and five", wide)?.number, 105)
        XCTAssertEqual(value("twenty one", wide)?.number, 21)
    }

    func testADecimalCommaIsReadByLocale() {
        XCTAssertEqual(value("4,2", locale: de)?.number, Decimal(string: "4.2"))
        XCTAssertNotNil(asksAgain("4,2", locale: en), "a decimal comma where the locale writes a point is asked again")
        let big = StepAnswer(recordAs: "n", kind: .number, decimals: 1, plausible: [0, 5000])
        XCTAssertEqual(value("1,250", big, locale: en)?.number, 1250)
        XCTAssertEqual(value("1.250,5", big, locale: de)?.number, Decimal(string: "1250.5"))
    }

    func testTwoNumbersAreAskedAgainButDigitsInANameAreNot() {
        XCTAssertNotNil(asksAgain("4.2 or 4.3"))
        XCTAssertNotNil(asksAgain("four or five"))
        let co2 = StepAnswer(recordAs: "co2", kind: .number, decimals: 2, plausible: [0, 6])
        XCTAssertEqual(value("CO2 is 2.9", co2)?.number, Decimal(string: "2.9"))
    }

    func testOutsidePlausibleIsAskedAgainAndNothingIsRecorded() {
        let why = asksAgain("42")
        XCTAssertEqual(why, "pH 42? That's outside what it can read (0 to 14). Read it again.")
        XCTAssertNotNil(asksAgain("no idea"))
        XCTAssertNotNil(value("14"), "the bounds are inclusive")
        XCTAssertNotNil(value("0"))
    }

    func testOutsideSpecIsAcceptedAndMarked() {
        XCTAssertEqual(value("4.6")?.specStatus, .out)
        XCTAssertEqual(value("4.4")?.specStatus, .in, "the spec bounds are inclusive")
        XCTAssertEqual(value("3.8")?.specStatus, .in)
        XCTAssertEqual(value("3.79")?.specStatus, .out)
        let noSpec = StepAnswer(recordAs: "n", kind: .number, plausible: [0, 10])
        XCTAssertNil(value("5", noSpec)?.specStatus)
    }

    func testAChoiceReadsItsLabelIdAndSynonyms() {
        let label = StepAnswer(recordAs: "label", kind: .choice, options: [
            .init(id: "ok", label: "Straight", says: ["good", "level"]),
            .init(id: "skewed", label: "Skewed", says: ["crooked", "tilted"]),
            .init(id: "missing", label: "Missing", says: ["none"]),
        ])
        XCTAssertEqual(value("Straight", label)?.option, "ok")
        XCTAssertEqual(value("it's crooked.", label)?.option, "skewed")
        XCTAssertEqual(value("skewed", label)?.option, "skewed")
        XCTAssertEqual(value("NONE", label)?.option, "missing")
        XCTAssertNotNil(asksAgain("purple", label))
        XCTAssertNotNil(asksAgain("good but crooked", label), "two options heard is asked again")
    }

    func testResolveOptionWithoutSynonymsIsTheCaptureFlowRule() {
        XCTAssertEqual(CaptureFlowRunner.resolveOption("major", options: ["minor", "major"]), "major")
        XCTAssertEqual(CaptureFlowRunner.resolveOption("it looks major", options: ["minor", "major"]), "major")
        XCTAssertNil(CaptureFlowRunner.resolveOption("or", options: ["minor", "major"]))
        XCTAssertEqual(CaptureFlowRunner.resolveOption("wonky", options: ["ok", "bad"], says: ["bad": ["wonky"]]), "bad")
    }

    func testYesOrNoUsesTheFixedWordsAndAsksAgainWhenBothOrNeither() {
        let yn = StepAnswer(recordAs: "clear", kind: .yesNo, label: "Line clear")
        XCTAssertEqual(value("yeah", yn)?.option, "yes")
        XCTAssertEqual(value("Done.", yn)?.option, "yes")
        XCTAssertEqual(value("pass", yn)?.option, "yes")
        XCTAssertEqual(value("nope", yn)?.option, "no")
        XCTAssertEqual(value("fail", yn)?.option, "no")
        XCTAssertNotNil(asksAgain("not done", yn))
        XCTAssertNotNil(asksAgain("maybe", yn))
    }

    func testTextIsKeptAsSaidWithinItsLengths() {
        let text = StepAnswer(recordAs: "comment", kind: .text, minLen: 3, maxLen: 10)
        XCTAssertEqual(value("  all fine ", text)?.text, "all fine")
        XCTAssertNotNil(asksAgain("ok", text))
        XCTAssertNotNil(asksAgain("far too long a comment", text))
        XCTAssertNotNil(asksAgain("   ", text))
    }

    func testACodeMatchesItsExpectedValueOrIsOutOfSpec() {
        let code = StepAnswer(recordAs: "batch", kind: .code, symbology: "qr", expected: "LOT 42A")
        XCTAssertEqual(value("lot42a", code)?.specStatus, .in)
        XCTAssertEqual(value("LOT 43A", code)?.specStatus, .out)
        let open = StepAnswer(recordAs: "date", kind: .code)
        XCTAssertNil(value("2611201", open)?.specStatus)
        XCTAssertEqual(value("2611201", open)?.text, "2611201")
    }

    func testPhotosCountWithinTheirBounds() {
        let photo = StepAnswer(recordAs: "bottles", kind: .photo, minPhotos: 1, maxPhotos: 2)
        guard case .accepted(let two) = AnswerReader.readPhotos(["a.jpg", "b.jpg", "a.jpg"], for: photo) else {
            return XCTFail("two distinct photos are accepted")
        }
        XCTAssertEqual(two.photoIds, ["a.jpg", "b.jpg"])
        XCTAssertEqual(two.display(for: photo), "2 photos")
        if case .accepted = AnswerReader.readPhotos([], for: photo) { XCTFail("none taken is asked again") }
        if case .accepted = AnswerReader.readPhotos(["a", "b", "c"], for: photo) { XCTFail("three is over the max") }
        XCTAssertEqual(value("a.jpg, b.jpg", photo)?.photoIds, ["a.jpg", "b.jpg"])
    }
}
