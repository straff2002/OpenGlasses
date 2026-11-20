import XCTest
@testable import OpenGlasses

/// Plan MO §2: the on-keyword mode's whole-word, case- and diacritic-blind matcher and its hold.
final class KeywordMatcherTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testWholeWordsOnly() {
        var matcher = KeywordMatcher(keywords: ["cart"])
        XCTAssertEqual(matcher.match("Replace the cartridge first.", at: t0), [], "not inside a word")
        XCTAssertEqual(matcher.match("Bring the carts round.", at: t0), [], "a plural is another word")
        XCTAssertEqual(matcher.match("Put it in the cart.", at: t0), ["cart"])
    }

    func testCaseAndDiacriticsAreIgnored() {
        var matcher = KeywordMatcher(keywords: ["Müller", "café"])
        XCTAssertEqual(matcher.match("I spoke to MULLER yesterday", at: t0), ["Müller"])
        XCTAssertEqual(matcher.match("the Cafe on the corner", at: t0), ["café"])
    }

    func testPunctuationNextToTheWordStillMatches() {
        var matcher = KeywordMatcher(keywords: ["invoice"])
        XCTAssertEqual(matcher.match("Where's the invoice?", at: t0), ["invoice"])
        var quoted = KeywordMatcher(keywords: ["invoice"])
        XCTAssertEqual(quoted.match("\"Invoice,\" he said.", at: t0), ["invoice"])
        var dashed = KeywordMatcher(keywords: ["invoice"])
        XCTAssertEqual(dashed.match("—invoice—", at: t0), ["invoice"])
    }

    func testMultiWordTriggers() {
        var matcher = KeywordMatcher(keywords: ["price list"])
        XCTAssertEqual(matcher.match("The price is on the list.", at: t0), [], "not together")
        XCTAssertEqual(matcher.match("Is that the list price?", at: t0), [], "not in order")
        XCTAssertEqual(matcher.match("Send me the Price-List, please.", at: t0), ["price list"])
    }

    func testSeveralKeywordsInTheOrderTheyAreSaid() {
        var matcher = KeywordMatcher(keywords: ["warranty", "delivery", "refund"])
        XCTAssertEqual(matcher.match("After delivery, what about the warranty?", at: t0), ["delivery", "warranty"])
    }

    func testAKeywordIsHeldForSixtySeconds() {
        var matcher = KeywordMatcher(keywords: ["warranty"])
        XCTAssertEqual(matcher.match("the warranty", at: t0), ["warranty"])
        XCTAssertEqual(matcher.match("the warranty again", at: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(matcher.match("the warranty again", at: t0.addingTimeInterval(59.99)), [])
        XCTAssertEqual(matcher.match("the warranty again", at: t0.addingTimeInterval(60)), ["warranty"])
        XCTAssertEqual(matcher.match("the warranty again", at: t0.addingTimeInterval(61)), [],
                       "held again from the second firing")
    }

    func testAHeldKeywordDoesNotHoldTheOthers() {
        var matcher = KeywordMatcher(keywords: ["warranty", "refund"])
        _ = matcher.match("the warranty", at: t0)
        XCTAssertEqual(matcher.match("warranty or refund", at: t0.addingTimeInterval(5)), ["refund"])
    }

    func testBlanksAndRepeatsAreDropped() {
        let matcher = KeywordMatcher(keywords: ["  ", "Price List", "price list", "", "  refund "])
        XCTAssertEqual(matcher.keywords, ["Price List", "refund"])
        XCTAssertTrue(KeywordMatcher(keywords: ["", " , "]).isEmpty)
    }

    func testResetForgetsTheHolds() {
        var matcher = KeywordMatcher(keywords: ["warranty"])
        _ = matcher.match("the warranty", at: t0)
        matcher.reset()
        XCTAssertEqual(matcher.match("the warranty", at: t0.addingTimeInterval(1)), ["warranty"])
    }
}
