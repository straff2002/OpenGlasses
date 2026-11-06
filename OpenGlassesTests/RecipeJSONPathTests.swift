import XCTest
@testable import OpenGlasses

/// The JSONPath subset (`$`, `.key`, `['key']`, `[n]`, `[*]`), value coercion, templated paths,
/// and the harness dot-path `JSONPath` that now walks through it.
final class RecipeJSONPathTests: XCTestCase {

    private let doc: Any = try! JSONSerialization.jsonObject(with: Data(#"""
    {
      "rates": { "USD": 1.157, "GBP": 0.87, "JPY": 165 },
      "amount": 50.0,
      "ok": true, "zero": 0, "nothing": null,
      "big": 12345678901234,
      "items": [ { "name": "a", "n": 1 }, { "name": "b", "n": 2.5 }, { "name": "c" } ],
      "the key": { "x": "spaced" },
      "list": ["one", "two", 3, false, {"o": 1}, null]
    }
    """#.utf8))

    private func path(_ text: String) throws -> RecipeJSONPath { try RecipeJSONPath.parse(text).get() }

    // MARK: - Parsing

    func testParsesTheSubset() throws {
        XCTAssertEqual(try path("$").segments, [])
        XCTAssertEqual(try path("$.rates.USD").segments, [.key("rates"), .key("USD")])
        XCTAssertEqual(try path("$['the key'].x").segments, [.key("the key"), .key("x")])
        XCTAssertEqual(try path("$.items[1].name").segments, [.key("items"), .index(1), .key("name")])
        XCTAssertEqual(try path("$.items[*].name").segments, [.key("items"), .wildcard, .key("name")])
        XCTAssertEqual(try path("$.rates.*").segments, [.key("rates"), .wildcard])
    }

    func testRefusesEverythingElse() {
        XCTAssertEqual(RecipeJSONPath.parse("rates.USD"), .failure(.mustStartWithDollar))
        XCTAssertEqual(RecipeJSONPath.parse("$..USD"), .failure(.emptyKey(position: 1)))
        XCTAssertEqual(RecipeJSONPath.parse("$.items[0"), .failure(.unterminatedBracket(position: 7)))
        XCTAssertEqual(RecipeJSONPath.parse("$.items[-1]"), .failure(.invalidIndex("-1")))
        XCTAssertEqual(RecipeJSONPath.parse("$.items[0:2]"), .failure(.invalidIndex("0:2")))
        XCTAssertEqual(RecipeJSONPath.parse("$.items[?(@.n>1)]"), .failure(.invalidIndex("?(@.n>1)")))
        XCTAssertEqual(RecipeJSONPath.parse("$['']"), .failure(.emptyKey(position: 1)))
        XCTAssertEqual(RecipeJSONPath.parse("$x"), .failure(.unexpectedCharacter("x", position: 1)))
        XCTAssertEqual(RecipeJSONPath.parse("$." + String(repeating: "a", count: 199)), .failure(.tooLong))
        XCTAssertEqual(RecipeJSONPath.parse("$" + String(repeating: ".a", count: 17)), .failure(.tooManySegments))
    }

    // MARK: - Evaluation and coercion

    func testScalarCoercion() throws {
        XCTAssertEqual(try path("$.rates.USD").strings(in: doc), ["1.157"])
        XCTAssertEqual(try path("$.rates.JPY").strings(in: doc), ["165"])
        XCTAssertEqual(try path("$.amount").strings(in: doc), ["50"], "no spurious .0")
        XCTAssertEqual(try path("$.ok").strings(in: doc), ["true"])
        XCTAssertEqual(try path("$.zero").strings(in: doc), ["0"], "0 is a number, not false")
        XCTAssertEqual(try path("$.big").strings(in: doc), ["12345678901234"])
        XCTAssertEqual(try path("$.nothing").strings(in: doc), [])
        XCTAssertEqual(try path("$['the key'].x").strings(in: doc), ["spaced"])
        XCTAssertEqual(try path("$.items[1].n").strings(in: doc), ["2.5"])
        XCTAssertEqual(RecipeJSONPath.numberText(1e20 as Double), "1e+20")
    }

    func testMissesReachNothing() throws {
        XCTAssertEqual(try path("$.rates.EUR").strings(in: doc), [])
        XCTAssertEqual(try path("$.items[9].name").strings(in: doc), [])
        XCTAssertEqual(try path("$.rates.USD.deeper").strings(in: doc), [])
        XCTAssertEqual(try path("$.items.name").strings(in: doc), [], "a key on an array reaches nothing")
        XCTAssertEqual(try path("$.rates[0]").strings(in: doc), [], "an index on an object reaches nothing")
        XCTAssertEqual(try path("$.rates").strings(in: doc), [], "an object is not a value")
    }

    func testWildcardsJoinInOrderUpToTheLimit() throws {
        XCTAssertEqual(try path("$.items[*].name").strings(in: doc), ["a", "b", "c"])
        XCTAssertEqual(try path("$.items[*].name").strings(in: doc, limit: 2), ["a", "b"])
        XCTAssertEqual(try path("$.items[*].n").strings(in: doc), ["1", "2.5"])
        XCTAssertEqual(try path("$.rates.*").strings(in: doc), ["0.87", "165", "1.157"], "object wildcards go in key order")
        XCTAssertEqual(try path("$.list").strings(in: doc), ["one", "two", "3", "false"], "an array of scalars is its elements")
        let many = (0..<20).map { $0 }
        XCTAssertEqual(try path("$[*]").strings(in: many, limit: 50).count, RecipeJSONPath.maxResults)
    }

    // MARK: - Templated paths

    func testTemplatedKeysAreLiteral() throws {
        let t = try RecipeTemplate.parse("$.rates.{{to}}").get()
        XCTAssertEqual(try RecipeJSONPath.parse(template: t, values: ["to": "USD"]).get().strings(in: doc), ["1.157"])
        // A value can't add segments: "rates.USD" is one key name, which doesn't exist.
        let whole = try RecipeTemplate.parse("$.{{k}}").get()
        XCTAssertEqual(try RecipeJSONPath.parse(template: whole, values: ["k": "rates.USD"]).get().segments, [.key("rates.USD")])
        XCTAssertEqual(try RecipeJSONPath.parse(template: whole, values: ["k": "items[0]"]).get().segments, [.key("items[0]")])
        let quoted = try RecipeTemplate.parse("$['{{k}}'].x").get()
        XCTAssertEqual(try RecipeJSONPath.parse(template: quoted, values: ["k": "the key"]).get().strings(in: doc), ["spaced"])
        XCTAssertNoThrow(try RecipeJSONPath.parse(template: t).get(), "parses at install without values")
        let index = try RecipeTemplate.parse("$.items[{{i}}]").get()
        guard case .failure(.invalidIndex) = RecipeJSONPath.parse(template: index) else { return XCTFail("templated index") }
    }

    // MARK: - The harness dot-path, unchanged

    func testHarnessDotPathKeepsItsGrammar() {
        let json: [String: Any] = ["data": ["run": ["id": "r1"]], "files[0]": "literal", "*": "star", "a": ["b": 1]]
        XCTAssertEqual(JSONPath.value(at: "data.run.id", in: json) as? String, "r1")
        XCTAssertEqual(JSONPath.value(at: "files[0]", in: json) as? String, "literal", "brackets are part of a key")
        XCTAssertEqual(JSONPath.value(at: "*", in: json) as? String, "star", "* is a key, not a wildcard")
        XCTAssertEqual(JSONPath.value(at: "a..b", in: json) as? Int, 1, "empty components are skipped")
        XCTAssertEqual((JSONPath.value(at: "", in: json) as? [String: Any])?.count, 4, "an empty path is the object")
        XCTAssertNil(JSONPath.value(at: "data.run.id.deeper", in: json))
        XCTAssertNil(JSONPath.value(at: "data.missing", in: json))
    }
}
