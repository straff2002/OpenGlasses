import XCTest
@testable import OpenGlasses

/// `{{name}}` templates: parsing, the variables they reference, and escaping by context — a
/// value can never change the structure of what it is placed in.
final class RecipeTemplateEscapingTests: XCTestCase {

    private func template(_ text: String) throws -> RecipeTemplate { try RecipeTemplate.parse(text).get() }

    private let hostile = "a&b=c#d?e/f g%h+i\r\nX-Injected: 1\"j\\k"

    // MARK: - Parsing

    func testParsesLiteralsAndVariables() throws {
        let t = try template("{{amount}} {{from}} is {{result}} {{to}}.")
        XCTAssertEqual(t.variableNames, ["amount", "from", "result", "to"])
        XCTAssertEqual(try template("{{a}}{{a}} {{b.status}}").variableNames, ["a", "b.status"])
        XCTAssertEqual(try template("no placeholders { } {x}").parts, [.literal("no placeholders { } {x}")])
        XCTAssertEqual(try template("{{ spaced }}").variableNames, ["spaced"])
        XCTAssertFalse(try template("plain").hasVariables)
    }

    func testRefusesExpressionsAndBrokenPlaceholders() {
        XCTAssertEqual(RecipeTemplate.parse("{{a"), .failure(.unclosedPlaceholder))
        XCTAssertEqual(RecipeTemplate.parse("{{}}"), .failure(.invalidName("")))
        for bad in ["{{a + b}}", "{{a|upper}}", "{{1a}}", "{{a..b}}", "{{a.}}", "{{é}}", "{{a b}}"] {
            guard case .failure(.invalidName) = RecipeTemplate.parse(bad) else { return XCTFail(bad) }
        }
    }

    // MARK: - Contexts

    func testQueryValueCannotChangeTheQuery() throws {
        let url = try template("https://api.example.org/v1?q={{q}}&n=1").renderURL(["q": hostile])
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.host, "api.example.org")
        XCTAssertNil(components.fragment)
        XCTAssertEqual(components.queryItems?.count, 2)
        XCTAssertEqual(components.queryItems?.first?.name, "q")
        XCTAssertEqual(components.queryItems?.first?.value, hostile)
        XCTAssertEqual(components.queryItems?.last, URLQueryItem(name: "n", value: "1"))
        XCTAssertFalse(url.contains("&b="))
        XCTAssertFalse(url.contains("#"))
        XCTAssertTrue(url.contains("%2B"), "a + is encoded, so no server reads it as a space")
    }

    func testPathSegmentCannotAddSegmentsOrStartAQuery() throws {
        let url = try template("https://api.example.org/items/{{id}}/detail").renderURL(["id": hostile])
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        XCTAssertEqual(components.percentEncodedPath.split(separator: "/").count, 3)
        XCTAssertEqual(components.percentEncodedPath.split(separator: "/")[1], Substring(RecipeTemplate.escape(hostile, for: .urlPathSegment)))
    }

    func testDotSegmentsCannotWalkUpThePath() throws {
        for dots in [".", ".."] {
            let url = try template("https://api.example.org/a/{{x}}/b").renderURL(["x": dots])
            XCTAssertFalse(url.contains("/../") || url.contains("/./"), url)
            XCTAssertTrue(url.contains("%2E"), url)
        }
        XCTAssertEqual(RecipeTemplate.escape("a.b", for: .urlPathSegment), "a.b")
    }

    func testURLSectionTracking() throws {
        let t = try template("https://api.example.org/{{p}}?a={{q}}#{{f}}")
        let url = t.renderURL(["p": "x y", "q": "1&2", "f": "z"])
        XCTAssertEqual(url, "https://api.example.org/x%20y?a=1%262#z")
        XCTAssertFalse(t.placesVariableBeforePath)
        XCTAssertTrue(try template("https://{{h}}.example.org/").placesVariableBeforePath)
        XCTAssertTrue(try template("{{s}}://example.org/").placesVariableBeforePath)
        XCTAssertTrue(try template("https://user:{{p}}@example.org/").placesVariableBeforePath)
        XCTAssertFalse(try template("https://example.org?{{q}}").placesVariableBeforePath)
    }

    func testFormValueEscaping() {
        XCTAssertEqual(RecipeTemplate.escape("a&b=c d+e#", for: .formValue), "a%26b%3Dc%20d%2Be%23")
    }

    func testJSONStringEscapingKeepsTheBodyValid() throws {
        let body = RecipeRunner.serialise(.object(["q": .string("say {{v}}"), "n": .number(3)]), ["v": hostile])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["q"] as? String, "say " + hostile)
        XCTAssertEqual(parsed.count, 2, "a quote in a value can't add a key")
        XCTAssertEqual(RecipeTemplate.escape("\"\\\r\n\t\u{01}\u{2028}", for: .jsonString), "\\\"\\\\\\r\\n\\t\\u0001\\u2028")
    }

    func testHeaderValueLosesControlCharacters() {
        let value = RecipeTemplate.escape(hostile, for: .headerValue)
        XCTAssertFalse(value.contains("\r"))
        XCTAssertFalse(value.contains("\n"))
        XCTAssertTrue(value.contains("X-Injected: 1"), "the text stays, on the same line")
        XCTAssertEqual(RecipeTemplate.escape("a\u{0}b\u{7F}c\u{85}d", for: .headerValue), "abcd")
    }

    func testPlainTextKeepsPunctuationAndLineBreaks() {
        XCTAssertEqual(RecipeTemplate.escape("Fish & chips # 1 \"quoted\"\nnext", for: .plain), "Fish & chips # 1 \"quoted\"\nnext")
        XCTAssertEqual(RecipeTemplate.escape("bell\u{07}\r", for: .plain), "bell")
    }

    func testMissingVariablesRenderEmpty() throws {
        XCTAssertEqual(try template("[{{gone}}]").render([:], context: .plain), "[]")
    }
}
