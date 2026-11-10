import XCTest
@testable import OpenGlasses

/// Plan KZ §6: no web address reaches speech — whole replies and streamed ones alike.
final class CitationMarkupStripperTests: XCTestCase {

    private func strip(_ text: String) -> String { CitationMarkupStripper.strip(text) }

    func testMarkdownLinksKeepTheirWords() {
        XCTAssertEqual(strip("Open until 9, per [the airport's shop list](https://airport.example/shops)."),
                       "Open until 9, per the airport's shop list.")
        XCTAssertEqual(strip("See [1](https://a.example/x) for more."), "See for more.")
        XCTAssertEqual(strip("[https://a.example](https://a.example) is the page."), " is the page.")
    }

    func testXAIInlineCitationsAreDropped() {
        XCTAssertEqual(strip("It opens at 8.[[1]](https://x.example/a)[[2]](https://y.example/b)"), "It opens at 8.")
    }

    func testGroqMarkersAreDropped() {
        XCTAssertEqual(strip("It closes at 6【2†L6-L10】."), "It closes at 6.")
    }

    func testBareAddressesAreDroppedButTheSentenceEndStays() {
        XCTAssertEqual(strip("Details at https://shop.example/hours."), "Details at.")
        XCTAssertEqual(strip("The site (https://shop.example) lists it."), "The site lists it.")
        XCTAssertEqual(strip("Try www.shop.example today"), "Try today")
        XCTAssertEqual(strip("Link: <https://shop.example/x> ok"), "Link: ok")
    }

    func testTextWithoutMarkupIsUntouched() {
        let plain = "It's 22°C and  sunny [laughs] — take a hat."
        XCTAssertEqual(strip(plain), plain)
    }

    func testNoAddressSurvivesAnyShape() {
        let samples = ["[a](https://a.example/1)", "[[3]](https://b.example)", "https://c.example/x?y=1",
                       "(www.d.example)", "<http://e.example>"]
        for sample in samples {
            let spoken = strip("Before \(sample) after.")
            XCTAssertFalse(spoken.contains("http"), spoken)
            XCTAssertFalse(spoken.contains("www."), spoken)
            XCTAssertFalse(spoken.contains(".example"), spoken)
        }
    }

    // MARK: - Streamed

    private func streamed(_ chunks: [String]) -> String {
        var stream = CitationMarkupStripper.Stream()
        var out = ""
        for chunk in chunks { out += stream.ingest(chunk) }
        return out + stream.flush()
    }

    func testAStreamNeverReleasesHalfALink() {
        var stream = CitationMarkupStripper.Stream()
        XCTAssertEqual(stream.ingest("Per [the shop "), "Per ")
        XCTAssertEqual(stream.ingest("list](https://airport.exa"), "")
        XCTAssertEqual(stream.ingest("mple/shops) it is open."), "the shop list it is open.")
    }

    func testAStreamHoldsAnAddressUntilItEnds() {
        var stream = CitationMarkupStripper.Stream()
        XCTAssertEqual(stream.ingest("See htt"), "See ")
        XCTAssertEqual(stream.ingest("ps://a.example/x"), "")
        XCTAssertEqual(stream.ingest(" now."), " now.")
        XCTAssertEqual(stream.flush(), "")
    }

    func testStreamedAndWholeAgreeOnEveryCharacterButSpaces() {
        let reply = "It's open until 9[[1]](https://x.example/a), per [the list](https://airport.example/s) and www.b.example【1†L2-L4】 too."
        let whole = strip(reply).filter { !$0.isWhitespace }
        for size in [1, 2, 3, 5, 8, 13] {
            var chunks: [String] = []
            var index = reply.startIndex
            while index < reply.endIndex {
                let end = reply.index(index, offsetBy: size, limitedBy: reply.endIndex) ?? reply.endIndex
                chunks.append(String(reply[index..<end]))
                index = end
            }
            XCTAssertEqual(streamed(chunks).filter { !$0.isWhitespace }, whole, "chunk size \(size)")
        }
    }

    func testAPlainBracketIsNotHeldForever() {
        var stream = CitationMarkupStripper.Stream()
        XCTAssertEqual(stream.ingest("He said [quietly] that"), "He said [quietly] that")
        let long = "[" + String(repeating: "word ", count: 200)
        XCTAssertFalse(stream.ingest(long).isEmpty, "held text past the limit is let go")
    }
}
