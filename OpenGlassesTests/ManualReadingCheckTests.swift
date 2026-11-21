import XCTest
@testable import OpenGlasses

/// Plan MP's `ManualReadingCheck`, built under Plan MQ P0. The passages are written from the Lennox
/// example vault's service values (`examples/vaults/lennox-slp99/service_values.md`), so the
/// numbers and units are the shapes a real manual has: ranges, table headings, inches of water.
final class ManualReadingCheckTests: XCTestCase {

    private let passages: [String: String] = [
        "p1": """
            Gas supply (line) pressure — TABLE 34. | Gas | Line pressure, in. w.c. | \
            | Natural | 4.5 – 10.5 | | LP/propane | 11.0 – 13.0 |
            """,
        "p2": "The high-pressure switch opens at 610 psig and resets automatically at 420 psig.",
        "p3": "Allow 24 VAC at the thermostat. The blower runs for 90 seconds after the burners stop.",
    ]

    private func check(_ answer: String, quote: String, passage: String = "p1",
                       found: Bool = true) -> ManualReadingCheck.Verdict {
        ManualReadingCheck.check(ManualReading(found: found, answer: answer, passage: passage, quote: quote),
                                 passages: passages)
    }

    func testAnAnswerQuotedFromItsPassageWithItsNumbersIsAccepted() {
        XCTAssertEqual(check("Natural gas line pressure is 4.5 to 10.5 in. w.c.", quote: "Natural | 4.5 – 10.5"),
                       .accepted)
        XCTAssertEqual(check("It opens at 610 psig.", quote: "opens at 610 psig", passage: "p2"), .accepted)
    }

    func testFoundFalseIsDeclinedWhateverTheAnswerSays() {
        XCTAssertEqual(check("4.5 in. w.c.", quote: "Natural | 4.5", found: false), .declined(.notFound))
    }

    func testAnEmptyQuoteOrAnswerIsDeclined() {
        XCTAssertEqual(check("4.5 in. w.c.", quote: ""), .declined(.emptyQuote))
        XCTAssertEqual(check("4.5 in. w.c.", quote: " … – "), .declined(.emptyQuote))
        XCTAssertEqual(check("  ", quote: "Natural"), .declined(.emptyAnswer))
    }

    func testAQuoteFromADifferentPassageIsNotEvidenceForThisOne() {
        XCTAssertEqual(check("It opens at 610 psig.", quote: "opens at 610 psig", passage: "p1"),
                       .declined(.quoteNotInPassage))
    }

    func testAPassageThatWasNotHandedOverIsDeclined() {
        XCTAssertEqual(check("4.5 in. w.c.", quote: "Natural", passage: "p9"), .declined(.unknownPassage))
    }

    func testQuotesMatchAcrossCaseWhitespaceAndDashes() {
        XCTAssertEqual(check("4.5 in. w.c.", quote: "NATURAL  |  4.5 - 10.5"), .accepted)
        XCTAssertEqual(check("4.5 in. w.c.", quote: "natural | 4.5 — 10.5"), .accepted)
    }

    func testANearMissNumberIsDeclined() {
        XCTAssertEqual(check("Line pressure is 45 in. w.c.", quote: "Natural | 4.5"), .declined(.numberNotInPassage))
        XCTAssertEqual(check("Line pressure is 1.05 in. w.c.", quote: "Natural | 4.5"), .declined(.numberNotInPassage))
        XCTAssertEqual(check("It opens at 61 psig.", quote: "opens at 610 psig", passage: "p2"),
                       .declined(.numberNotInPassage))
    }

    func testTheSameValueWrittenDifferentlyIsTheSameNumber() {
        XCTAssertEqual(check("Line pressure is 4.50 in. w.c.", quote: "Natural"), .accepted)
        XCTAssertEqual(check("Line pressure is 11 in. w.c. on LP.", quote: "LP/propane | 11.0"), .accepted)
    }

    func testTheRightNumberWithTheWrongUnitIsDeclined() {
        XCTAssertEqual(check("Line pressure is 4.5 psi.", quote: "Natural"), .declined(.numberNotInPassage))
        XCTAssertEqual(check("It opens at 610 kPa.", quote: "opens at 610 psig", passage: "p2"),
                       .declined(.numberNotInPassage))
    }

    func testUnitVariantsReadAsOneUnit() {
        for written in ["in. w.c.", "inches w.c.", "inWC", "in w.c.", "iwc", "inches of water", "\" w.c."] {
            XCTAssertEqual(check("Natural is 4.5 \(written)", quote: "Natural"), .accepted, written)
        }
        XCTAssertEqual(check("It opens at 610 psi.", quote: "opens at 610 psig", passage: "p2"), .accepted,
                       "psi and psig are one unit to a technician")
        XCTAssertEqual(check("Allow 24 volts.", quote: "Allow 24 VAC", passage: "p3"), .accepted)
        XCTAssertEqual(check("It runs 90 secs.", quote: "runs for 90 seconds", passage: "p3"), .accepted)
    }

    func testABareSecondsUnitInATimingTableMatchesSecondsInTheAnswer() {
        let timing = ["t": "Gas meter clocking, natural gas, 1 cu ft dial: -070 55 s, -090 41 s."]
        let reading = ManualReading(found: true, answer: "41 seconds on the 090.", passage: "t", quote: "-090 41 s")
        XCTAssertEqual(ManualReadingCheck.check(reading, passages: timing), .accepted)
        let wrong = ManualReading(found: true, answer: "14 seconds on the 090.", passage: "t", quote: "-090 41 s")
        XCTAssertEqual(ManualReadingCheck.check(wrong, passages: timing), .declined(.numberNotInPassage))
    }

    func testTheUnitMaySitInATableHeading() {
        // "in. w.c." is in the column heading, not beside 10.5.
        XCTAssertEqual(check("Up to 10.5 in. w.c.", quote: "Natural | 4.5 – 10.5"), .accepted)
    }

    func testNumbersWithoutAUnitAreNotChecked() {
        // MP's rule is about numbers with a unit; "TABLE 34" or a count in prose is not a value claim.
        XCTAssertEqual(check("See table 99 for the natural gas range.", quote: "Natural"), .accepted)
    }

    func testANumberInsideAModelNameIsNotAValue() {
        XCTAssertEqual(ManualReadingCheck.numbers(in: "r410a and slp99 at 4.5"), [Decimal(string: "4.5")!])
    }

    func testThousandsSeparatorsAndBareDecimals() {
        XCTAssertEqual(ManualReadingCheck.numbers(in: "1,200 cfm and .5 in"), [1200, Decimal(string: "0.5")!])
    }

    func testRangesCarryTheirUnitToBothEnds() {
        let quantities = ManualReadingCheck.quantities(in: "4.5 - 10.5 in. w.c. and 3.0 to 3.5 psi")
        XCTAssertEqual(quantities.map(\.unit), ["inwc", "inwc", "psi", "psi"])
    }

    func testOneLetterUnitsCountOnlyAfterANumber() {
        XCTAssertFalse(ManualReadingCheck.units(in: "a fan in the cabinet").contains("a"))
        XCTAssertFalse(ManualReadingCheck.units(in: "a fan in the cabinet").contains("in"))
        XCTAssertTrue(ManualReadingCheck.units(in: "draws 5 a at start").contains("a"))
    }
}
