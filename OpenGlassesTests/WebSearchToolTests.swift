import XCTest
@testable import OpenGlasses

final class WebSearchToolTests: XCTestCase {

    func testSearXNGSearchURLTrimsTrailingSlash() {
        let url = WebSearchTool.searxngSearchURL(baseURL: "https://search.example.com/", query: "meta glasses")
        XCTAssertEqual(url?.absoluteString, "https://search.example.com/search?q=meta%20glasses&format=json")
    }

    func testSearXNGConfiguredRequiresValidURL() {
        Config.setSearXNGBaseURL("")
        XCTAssertFalse(Config.isSearXNGConfigured)

        Config.setSearXNGBaseURL("https://search.example.com")
        XCTAssertTrue(Config.isSearXNGConfigured)

        Config.setSearXNGBaseURL("not-a-url")
        XCTAssertFalse(Config.isSearXNGConfigured)

        Config.setSearXNGBaseURL("")
    }
}
