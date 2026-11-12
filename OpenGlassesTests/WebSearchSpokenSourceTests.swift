import XCTest
@testable import OpenGlasses

/// Plan LO P0 §4 — our own `web_search` speaks like the provider's: one source the model can say,
/// the links kept for the phone under a line saying not to read them, and a `recency` mapped to each
/// backend's own filter, dropped where a backend has none.
@MainActor
final class WebSearchSpokenSourceTests: XCTestCase {

    // MARK: - Recency

    func testRecencyReadsLenientlyAndDropsTheUnknown() {
        XCTAssertEqual(WebSearchRecency(argument: "week"), .week)
        XCTAssertEqual(WebSearchRecency(argument: " Day \n"), .day)
        XCTAssertNil(WebSearchRecency(argument: "2026-11-12"))
        XCTAssertNil(WebSearchRecency(argument: "fortnight"))
        XCTAssertNil(WebSearchRecency(argument: nil))
        XCTAssertNil(WebSearchRecency(argument: 7))
    }

    func testRecencyMapsToEachBackendsOwnFilter() {
        for recency in WebSearchRecency.allCases {
            XCTAssertEqual(recency.filter(for: .perplexity)?.name, "search_recency_filter")
            XCTAssertEqual(recency.filter(for: .perplexity)?.value, recency.rawValue)
            XCTAssertEqual(recency.filter(for: .tavily)?.name, "time_range")
            XCTAssertEqual(recency.filter(for: .tavily)?.value, recency.rawValue)
            XCTAssertEqual(recency.filter(for: .searxng)?.name, "time_range")
            XCTAssertEqual(recency.filter(for: .searxng)?.value, recency.rawValue)
            XCTAssertEqual(recency.filter(for: .brave)?.name, "freshness")
            XCTAssertNil(recency.filter(for: .duckDuckGo), "no filter there: dropped, never put in the query")
        }
        XCTAssertEqual(WebSearchRecency.allCases.map { $0.filter(for: .brave)?.value }, ["pd", "pw", "pm", "py"])
    }

    func testTheBackendAddressesCarryTheFilter() throws {
        let brave = try XCTUnwrap(WebSearchTool.braveSearchURL(query: "AT&T 1+1", recency: .week))
        let items = URLComponents(url: brave, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "freshness" }?.value, "pw")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "AT&T 1+1")
        XCTAssertTrue(brave.absoluteString.contains("1%2B1"))
        let plain = try XCTUnwrap(WebSearchTool.braveSearchURL(query: "news", recency: nil))
        XCTAssertFalse(plain.absoluteString.contains("freshness"))

        let searx = try XCTUnwrap(WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com",
                                                                  query: "score", timeRange: "day"))
        XCTAssertTrue(searx.absoluteString.hasSuffix("&time_range=day"))
        let searxPlain = try XCTUnwrap(WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com", query: "score"))
        XCTAssertFalse(searxPlain.absoluteString.contains("time_range"))
    }

    func testTheToolOffersRecencyAndSaysWhenToSearch() throws {
        let tool = WebSearchTool()
        let properties = try XCTUnwrap(tool.parametersSchema["properties"] as? [String: Any])
        let recency = try XCTUnwrap(properties["recency"] as? [String: Any])
        XCTAssertEqual(recency["enum"] as? [String], ["day", "week", "month", "year"])
        XCTAssertEqual(tool.parametersSchema["required"] as? [String], ["query"], "recency is optional")
        for phrase in ["news, sport, weather, prices, opening hours", "Don't search for common knowledge, small talk, maths or translation",
                       "never a date in the query", "against today's date", "never read out", "never as a link"] {
            XCTAssertTrue(tool.description.contains(phrase), phrase)
        }
    }

    // MARK: - One source to say, per backend's result shape

    private func assertSpoken(_ result: String, source: String, links: [String],
                              file: StaticString = #filePath, line: UInt = #line) {
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.last, source, "the result ends on the source to name", file: file, line: line)
        XCTAssertEqual(lines.filter { $0.hasPrefix("Source: ") }.count, 1, "one source", file: file, line: line)
        XCTAssertTrue(result.contains(WebSearchResultFormat.phoneLinksLine + "\nSources: [1] "), file: file, line: line)
        // The phone still shows every link, read from the same line it always was.
        XCTAssertEqual(ProviderSearchEvidence.ourToolSources(fromResult: result).map(\.url), links, file: file, line: line)
    }

    func testPerplexityCitationsOnlyNameTheAddress() {
        let json: [String: Any] = ["citations": ["https://www.stuff.co.nz/sport/123", "https://rnz.co.nz/x", "https://a.example/1", "https://b.example/2"]]
        let result = WebSearchResultFormat.compose(header: "Search result for \"rugby\" (via Perplexity)",
                                                   summary: "Canterbury won 24 to 19.",
                                                   links: WebSearchTool.perplexityLinks(json))
        XCTAssertTrue(result.hasPrefix("Search result for \"rugby\" (via Perplexity): Canterbury won 24 to 19."))
        assertSpoken(result, source: "Source: stuff.co.nz",
                     links: ["https://www.stuff.co.nz/sport/123", "https://rnz.co.nz/x", "https://a.example/1"])
    }

    func testPerplexitySearchResultsNameTheSiteFromItsTitle() {
        let json: [String: Any] = [
            "citations": ["https://www.stuff.co.nz/sport/123"],
            "search_results": [["title": "Canterbury win the NPC final | Stuff", "url": "https://www.stuff.co.nz/sport/123"]],
        ]
        let result = WebSearchResultFormat.compose(header: "h", summary: "s", links: WebSearchTool.perplexityLinks(json))
        assertSpoken(result, source: "Source: Stuff (stuff.co.nz)", links: ["https://www.stuff.co.nz/sport/123"])
    }

    func testTavilyAndSearXNGTitles() {
        let results: [[String: Any]] = [
            ["url": "https://www.rnz.co.nz/news/sport/1", "title": "Canterbury claim the title - RNZ", "content": "…"],
            ["url": "https://example.org/2", "title": "Other"],
        ]
        let result = WebSearchResultFormat.compose(header: "h", summary: "s", links: WebSearchTool.titledLinks(results))
        assertSpoken(result, source: "Source: RNZ (rnz.co.nz)", links: ["https://www.rnz.co.nz/news/sport/1", "https://example.org/2"])
    }

    func testBraveUsesTheSitesOwnName() {
        let results: [[String: Any]] = [
            ["url": "https://www.bbc.co.uk/sport/rugby", "title": "Rugby union", "profile": ["name": "BBC"]],
        ]
        let result = WebSearchResultFormat.compose(header: "h", summary: "s", links: WebSearchTool.braveLinks(results))
        assertSpoken(result, source: "Source: BBC (bbc.co.uk)", links: ["https://www.bbc.co.uk/sport/rugby"])
    }

    func testDuckDuckGoAbstractNamesItsSource() {
        let json: [String: Any] = ["AbstractText": "A heat pump moves heat.", "AbstractSource": "Wikipedia",
                                   "AbstractURL": "https://en.wikipedia.org/wiki/Heat_pump"]
        let result = WebSearchTool.duckDuckGoAbstract(query: "heat pump", json: json)
        XCTAssertTrue(result.hasPrefix("Search result for \"heat pump\": A heat pump moves heat."))
        assertSpoken(result, source: "Source: Wikipedia (en.wikipedia.org)", links: ["https://en.wikipedia.org/wiki/Heat_pump"])

        let bare = WebSearchTool.duckDuckGoAbstract(query: "q", json: ["AbstractText": "Text."])
        XCTAssertEqual(bare, "Search result for \"q\": Text.", "no address, no source line and no phone list")
    }

    func testATitleThatIsNotTheSitesNameNamesNobody() {
        XCTAssertNil(WebSearchResultFormat.siteName(fromTitle: "How to fix it - Step by step", domain: "example.com"))
        XCTAssertNil(WebSearchResultFormat.siteName(fromTitle: "No separator here", domain: "stuff.co.nz"))
        XCTAssertEqual(WebSearchResultFormat.siteName(fromTitle: "Heat pump - Wikipedia", domain: "en.wikipedia.org"), "Wikipedia")
        XCTAssertEqual(WebSearchResultFormat.siteName(fromTitle: "A - B | BBC News", domain: "bbc.co.uk"), "BBC News")
        XCTAssertEqual(WebSearchResultFormat.domain(of: "https://m.stuff.co.nz/x"), "stuff.co.nz")
        XCTAssertNil(WebSearchResultFormat.domain(of: "not a url"))
    }
}
