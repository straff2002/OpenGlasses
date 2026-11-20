import XCTest
@testable import OpenGlasses

/// Plan MO §5 step 3: a model's reply read leniently, and cut to size in code whatever it says.
final class HintReplyTests: XCTestCase {

    private func reply(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> HintReply? {
        guard case let .hint(reply) = HintReply.parse(raw) else {
            XCTFail("expected a hint from \(raw)", file: file, line: line)
            return nil
        }
        return reply
    }

    // MARK: - Reading

    func testRawJSON() {
        let parsed = reply(#"{"hint": "12 weeks from order", "full": "The larger unit ships in 12 weeks.", "general": false}"#)
        XCTAssertEqual(parsed?.hint, "12 weeks from order")
        XCTAssertEqual(parsed?.full, "The larger unit ships in 12 weeks.")
        XCTAssertEqual(parsed?.general, false)
    }

    func testFencedJSON() {
        let parsed = reply("""
        ```json
        {"hint": "5-year parts warranty", "full": "Parts are covered for five years."}
        ```
        """)
        XCTAssertEqual(parsed?.hint, "5-year parts warranty")
        XCTAssertEqual(parsed?.full, "Parts are covered for five years.")
    }

    func testJSONAmongProse() {
        let parsed = reply("""
        Sure! Here is the answer: {"hint": "Free delivery over 200", "full": "Orders over 200 ship free {standard}.", "general": true} Hope that helps.
        """)
        XCTAssertEqual(parsed?.hint, "Free delivery over 200")
        XCTAssertEqual(parsed?.full, "Orders over 200 ship free {standard}.", "braces inside strings don't end the object")
        XCTAssertEqual(parsed?.general, true)
    }

    func testGeneralAsAString() {
        XCTAssertEqual(reply(#"{"hint": "Paris", "general": "true"}"#)?.general, true)
        XCTAssertEqual(reply(#"{"hint": "Paris"}"#)?.general, false)
        XCTAssertEqual(reply(#"{"hint": "Paris"}"#)?.full, "")
    }

    func testNotJSONIsReadAsLines() {
        let parsed = reply("""

        - 12 weeks from order
        The larger unit ships in twelve weeks.
        Rush orders take six.
        """)
        XCTAssertEqual(parsed?.hint, "12 weeks from order")
        XCTAssertEqual(parsed?.full, "The larger unit ships in twelve weeks. Rush orders take six.")
        XCTAssertEqual(parsed?.general, false)
    }

    func testAnEmptyHintIsNothingToShow() {
        XCTAssertEqual(HintReply.parse(#"{"hint": "", "full": "Just small talk."}"#), .nothingToShow)
        XCTAssertEqual(HintReply.parse(#"{"hint": "   \n "}"#), .nothingToShow)
        XCTAssertEqual(HintReply.parse(#"{"full": "No hint key."}"#), .nothingToShow)
        XCTAssertEqual(HintReply.parse(#"{"hint": null}"#), .nothingToShow)
        XCTAssertEqual(HintReply.parse(""), .nothingToShow)
        XCTAssertEqual(HintReply.parse("  \n\n "), .nothingToShow)
    }

    // MARK: - Lengths

    func testTheHintIsCutToEightWords() {
        let parsed = reply(#"{"hint": "one two three four five six seven eight nine ten"}"#)
        XCTAssertEqual(parsed?.hint, "one two three four five six seven eight")
    }

    func testTheHintIsCutToFortyFiveCharactersAtAWord() {
        let parsed = reply(#"{"hint": "Refrigerant charge is approximately 2.4 kilograms total"}"#)
        let hint = parsed?.hint ?? ""
        XCTAssertLessThanOrEqual(hint.count, HintLimits.hintMaxCharacters)
        XCTAssertEqual(hint, "Refrigerant charge is approximately 2.4")
    }

    func testACutHintDoesNotEndOnPunctuation() {
        let parsed = reply(#"{"hint": "Yes, the warranty, as written, covers labour, parts, and travel too"}"#)
        XCTAssertEqual(parsed?.hint, "Yes, the warranty, as written, covers labour")
        XCTAssertEqual(reply(#"{"hint": "12 weeks,"}"#)?.hint, "12 weeks", "a dangling comma goes even uncut")
        XCTAssertEqual(reply(#"{"hint": "Twelve weeks."}"#)?.hint, "Twelve weeks.", "an uncut full stop stays")
    }

    func testOneOverlongWordIsCutInside() {
        let long = String(repeating: "x", count: 60)
        XCTAssertEqual(reply("{\"hint\": \"\(long)\"}")?.hint.count, HintLimits.hintMaxCharacters)
    }

    func testWhitespaceInTheHintIsCollapsed() {
        XCTAssertEqual(reply("{\"hint\": \"  12\\n weeks \\t from   order \"}")?.hint, "12 weeks from order")
    }

    func testTheFullAnswerKeepsTwoSentences() {
        let parsed = reply(#"{"hint": "12 weeks", "full": "It ships in 12 weeks. Rush takes 6. Weekends add a day."}"#)
        XCTAssertEqual(parsed?.full, "It ships in 12 weeks. Rush takes 6.")
    }

    func testTheFullAnswerIsCutTo240Characters() {
        let first = "The larger unit ships in twelve weeks from the date the order is confirmed in writing by the regional office."
        let second = "Rush orders, which carry a surcharge, take six weeks, and the surcharge is waived for schools, hospitals and charities registered with us."
        let parsed = reply("{\"hint\": \"12 weeks\", \"full\": \"\(first) \(second)\"}")
        XCTAssertEqual(parsed?.full, first, "the second sentence would pass 240 characters")

        let words = Array(repeating: "word", count: 80).joined(separator: " ") + "."
        let cut = reply("{\"hint\": \"12 weeks\", \"full\": \"\(words)\"}")?.full ?? ""
        XCTAssertLessThanOrEqual(cut.count, HintLimits.fullMaxCharacters)
        XCTAssertTrue(cut.hasSuffix("word"), "cut at a word boundary: \(cut)")
    }

    func testTheSpokenHintIsAtMostSevenWords() {
        let parsed = reply(#"{"hint": "one two three four five six seven eight"}"#)
        XCTAssertEqual(parsed?.spokenHint, "one two three four five six seven")
        XCTAssertEqual(reply(#"{"hint": "12 weeks"}"#)?.spokenHint, "12 weeks")
    }

    func testTheLimitsAreThePlans() {
        XCTAssertEqual(HintLimits.hintMaxWords, 8)
        XCTAssertEqual(HintLimits.hintMaxCharacters, 45)
        XCTAssertEqual(HintLimits.fullMaxSentences, 2)
        XCTAssertEqual(HintLimits.fullMaxCharacters, 240)
        XCTAssertEqual(HintLimits.spokenHintMaxWords, 7)
    }
}
