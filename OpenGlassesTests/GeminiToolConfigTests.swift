import XCTest
@testable import OpenGlasses

/// `toolConfig` for Google Search beside function declarations, and the history a request
/// without it sends (support report, build 737).
final class GeminiToolConfigTests: XCTestCase {

    private let functions: [String: Any] = ["functionDeclarations": [["name": "get_time"]]]
    private let search: [String: Any] = ["google_search": [String: Any]()]

    func testSearchBesideFunctionsAsksForServerSideInvocationsInValidatedMode() {
        let config = GeminiFunctionCalling.toolConfig(tools: [functions, search], withholdingCalls: false)
        XCTAssertEqual(config?["includeServerSideToolInvocations"] as? Bool, true)
        XCTAssertEqual(config?["functionCallingConfig"] as? [String: String], ["mode": "VALIDATED"])
        XCTAssertTrue(GeminiFunctionCalling.includesServerSideInvocations(config))
    }

    func testFunctionsAloneNeedNoToolConfig() {
        XCTAssertNil(GeminiFunctionCalling.toolConfig(tools: [functions], withholdingCalls: false))
        XCTAssertNil(GeminiFunctionCalling.toolConfig(tools: [], withholdingCalls: false))
    }

    func testSearchAloneIsValidatedWithoutTheFlag() {
        // Our own declarations can all be withheld (an empty list is dropped), leaving search alone.
        let config = GeminiFunctionCalling.toolConfig(tools: [search], withholdingCalls: false)
        XCTAssertEqual(config?["functionCallingConfig"] as? [String: String], ["mode": "VALIDATED"])
        XCTAssertNil(config?["includeServerSideToolInvocations"])
    }

    func testTheWrapUpRoundOffersNoCallButKeepsTheFlagWithSearch() {
        XCTAssertEqual(GeminiFunctionCalling.toolConfig(tools: [functions], withholdingCalls: true)?["functionCallingConfig"]
                       as? [String: String], ["mode": "NONE"])
        let combined = GeminiFunctionCalling.toolConfig(tools: [functions, search], withholdingCalls: true)
        XCTAssertEqual(combined?["functionCallingConfig"] as? [String: String], ["mode": "NONE"])
        XCTAssertEqual(combined?["includeServerSideToolInvocations"] as? Bool, true)
    }

    func testServerSidePartsLeaveARequestWithoutTheFlag() {
        let contents: [[String: Any]] = [
            ["role": "user", "parts": [["text": "q"]]],
            ["role": "model", "parts": [
                ["toolCall": ["id": "s1"], "thoughtSignature": "a"],
                ["toolResponse": ["id": "s1"], "thoughtSignature": "b"],
                ["functionCall": ["name": "get_time", "id": "f1"], "thoughtSignature": "c"],
            ]],
            ["role": "model", "parts": [["toolCall": ["id": "s2"]]]],
            ["role": "model", "content": "plain"],
        ]
        let kept = GeminiFunctionCalling.withoutServerSideToolParts(contents)
        XCTAssertEqual(kept.count, 3, "a turn left with no parts is dropped")
        let parts = kept[1]["parts"] as? [[String: Any]] ?? []
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts.first?["thoughtSignature"] as? String, "c")
        XCTAssertEqual(kept[2]["content"] as? String, "plain")
    }
}
