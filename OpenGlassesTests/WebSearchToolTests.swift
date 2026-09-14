import XCTest
@testable import OpenGlasses

final class WebSearchToolTests: XCTestCase {

    private static let searxngKey = "searxngBaseURL"

    func testSearXNGSearchURLTrimsTrailingSlash() {
        let url = WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com/", query: "meta glasses")
        XCTAssertEqual(url?.absoluteString, "https://search.example.com/search?q=meta%20glasses&format=json")
    }

    /// An unescaped `&` would split the query into a second parameter (`T stock`).
    func testSearXNGSearchURLEncodesAmpersand() {
        let url = WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com", query: "AT&T stock")
        XCTAssertEqual(url?.absoluteString, "https://search.example.com/search?q=AT%26T%20stock&format=json")
        XCTAssertEqual(queryValue(url, "q"), "AT&T stock")
        XCTAssertEqual(queryValue(url, "format"), "json")
    }

    /// A literal `+` in a query string is decoded as a space by form-style parsers.
    func testSearXNGSearchURLEncodesPlus() {
        let url = WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com", query: "1+1=2")
        XCTAssertEqual(url?.absoluteString, "https://search.example.com/search?q=1%2B1%3D2&format=json")
    }

    /// An unescaped `#` would turn the rest of the URL, `format=json` included, into a fragment.
    func testSearXNGSearchURLEncodesHash() {
        let url = WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com", query: "C# tutorial")
        XCTAssertEqual(url?.absoluteString, "https://search.example.com/search?q=C%23%20tutorial&format=json")
        XCTAssertNil(url?.fragment)
    }

    func testSearXNGSearchURLKeepsBasePath() {
        let url = WebSearchTool.searxngSearchURL(baseURL: "https://host.example.com/searx/", query: "news")
        XCTAssertEqual(url?.absoluteString, "https://host.example.com/searx/search?q=news&format=json")
    }

    func testSearXNGSearchURLRejectsEmptyOrWhitespaceBase() {
        XCTAssertNil(WebSearchTool.searxngSearchURL(baseURL: "", query: "news"))
        XCTAssertNil(WebSearchTool.searxngSearchURL(baseURL: "   \n", query: "news"))
    }

    func testSearXNGConfiguredRequiresValidURL() {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: Self.searxngKey)
        defer {
            if let prior { defaults.set(prior, forKey: Self.searxngKey) } else { defaults.removeObject(forKey: Self.searxngKey) }
        }

        Config.setSearXNGBaseURL("")
        XCTAssertFalse(Config.isSearXNGConfigured)

        Config.setSearXNGBaseURL("https://search.example.com")
        XCTAssertTrue(Config.isSearXNGConfigured)

        Config.setSearXNGBaseURL("not-a-url")
        XCTAssertFalse(Config.isSearXNGConfigured)
    }

    private func queryValue(_ url: URL?, _ name: String) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}
