import XCTest
@testable import OpenGlasses

/// Plan IE P1 — what a request to each Claude family may carry. One row per family, the ids a
/// models listing can hand back for it, and the ids the table must *not* claim to know.
final class AnthropicModelContractTests: XCTestCase {

    private typealias Effort = AnthropicModelContract.Effort

    private struct Row {
        let id: String
        let forced: Bool
        let thinks: Bool
        let efforts: [Effort]
        let sampling: Bool
    }

    private let all: [Effort] = [.low, .medium, .high, .xhigh, .max]

    private var rows: [Row] {
        [
            Row(id: "claude-fable-5-1", forced: false, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-mythos-5-1", forced: false, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-fable-5", forced: true, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-mythos-5", forced: true, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-opus-5-5", forced: false, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-opus-5", forced: true, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-opus-4-8", forced: true, thinks: false, efforts: all, sampling: false),
            Row(id: "claude-opus-4-7", forced: true, thinks: false, efforts: all, sampling: false),
            Row(id: "claude-sonnet-5-5", forced: false, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-sonnet-5", forced: true, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-haiku-5-5", forced: true, thinks: true, efforts: all, sampling: false),
            Row(id: "claude-opus-4-6", forced: true, thinks: false,
                efforts: [.low, .medium, .high, .max], sampling: true),
            Row(id: "claude-sonnet-4-6", forced: true, thinks: false,
                efforts: [.low, .medium, .high, .max], sampling: true),
            Row(id: "claude-opus-4-5", forced: true, thinks: false,
                efforts: [.low, .medium, .high], sampling: true),
            Row(id: "claude-haiku-4-5", forced: true, thinks: false, efforts: [], sampling: true),
            Row(id: "claude-sonnet-4-5", forced: true, thinks: false, efforts: [], sampling: true),
            Row(id: "claude-opus-4-1", forced: true, thinks: false, efforts: [], sampling: true),
            Row(id: "claude-sonnet-4", forced: true, thinks: false, efforts: [], sampling: true),
            Row(id: "claude-3-5-haiku", forced: true, thinks: false, efforts: [], sampling: true),
        ]
    }

    private func assert(_ id: String, matches row: Row, file: StaticString = #filePath, line: UInt = #line) {
        let contract = AnthropicModelContract.contract(for: id)
        XCTAssertEqual(contract.allowsForcedToolChoice, row.forced, "\(id) forced tool choice", file: file, line: line)
        XCTAssertEqual(contract.thinksByDefault, row.thinks, "\(id) thinks by default", file: file, line: line)
        XCTAssertEqual(contract.effortLevels, row.efforts, "\(id) effort levels", file: file, line: line)
        XCTAssertEqual(contract.allowsSamplingParameters, row.sampling, "\(id) sampling", file: file, line: line)
        XCTAssertTrue(contract.isKnownModel, "\(id) is in the table", file: file, line: line)
    }

    func testEveryFamilyRow() {
        for row in rows { assert(row.id, matches: row) }
    }

    /// A listing can return the family id with a date after it, a platform's prefix before it, or
    /// in another case. Each is still its family — including the families whose id is a prefix of
    /// a newer one's.
    func testDatedPrefixedAndCasedIdsResolveToTheirFamily() {
        for row in rows {
            assert(row.id + "-20260901", matches: row)
            assert(row.id + "@20260901", matches: row)
            assert(row.id + "-latest", matches: row)
            assert("anthropic." + row.id, matches: row)
            assert("us.anthropic." + row.id + "-20260901-v1:0", matches: row)
            assert("  " + row.id.uppercased() + " ", matches: row)
        }
    }

    func testTheMoreSpecificFamilyWins() {
        // Each pair shares a prefix and differs in exactly the field that returns a 400.
        XCTAssertFalse(AnthropicModelContract.contract(for: "claude-sonnet-5-5").allowsForcedToolChoice)
        XCTAssertTrue(AnthropicModelContract.contract(for: "claude-sonnet-5").allowsForcedToolChoice)
        XCTAssertFalse(AnthropicModelContract.contract(for: "claude-opus-5-5").allowsForcedToolChoice)
        XCTAssertTrue(AnthropicModelContract.contract(for: "claude-opus-5").allowsForcedToolChoice)
        XCTAssertFalse(AnthropicModelContract.contract(for: "claude-fable-5-1").allowsForcedToolChoice)
        XCTAssertTrue(AnthropicModelContract.contract(for: "claude-fable-5").allowsForcedToolChoice)
        XCTAssertFalse(AnthropicModelContract.contract(for: "claude-mythos-5-1-20260901").allowsForcedToolChoice)
        XCTAssertTrue(AnthropicModelContract.contract(for: "claude-mythos-5-20260901").allowsForcedToolChoice)
    }

    /// An id the table does not know fails closed: no forced tool choice, no sampling, no effort,
    /// and output room for thinking. That includes the *next* model in a known line — a later
    /// version number is a different model, not a snapshot of the one before it.
    func testUnknownIdsGetTheStrictestContract() {
        let unknown = ["", "claude", "claude-nova-9", "gpt-6-sol", "claude-sonnet-5-6",
                       "claude-sonnet-6", "claude-opus-5-6", "claude-opus-6", "claude-opus-4-9",
                       "claude-fable-5-2", "claude-fable-6", "claude-haiku-5", "claude-haiku-5-6",
                       "claude-haiku-6-20270101", "claude-sonnet-5-10", "claude-sonnet-5x"]
        for id in unknown {
            let contract = AnthropicModelContract.contract(for: id)
            XCTAssertEqual(contract, .strictest, id)
            XCTAssertFalse(contract.allowsForcedToolChoice, id)
            XCTAssertFalse(contract.allowsSamplingParameters, id)
            XCTAssertTrue(contract.thinksByDefault, id)
            XCTAssertTrue(contract.effortLevels.isEmpty, id)
            XCTAssertFalse(contract.isKnownModel, id)
        }
    }

    // MARK: - Output room

    func testOutputCapIsRaisedOnlyWhereTheModelThinksByDefault() {
        let thinking = ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5",
                        "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-5-5", "claude-nova-9"]
        for id in thinking {
            let contract = AnthropicModelContract.contract(for: id)
            XCTAssertEqual(contract.outputCap(base: 200), 4_096, id)
            XCTAssertEqual(contract.outputCap(base: 1_024), 4_096, id)
            XCTAssertEqual(contract.outputCap(base: 4_096), 4_096, id)
            XCTAssertEqual(contract.outputCap(base: 16_000), 16_000, "\(id): a larger cap is kept")
        }
        let notThinking = ["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6",
                           "claude-opus-4-5", "claude-haiku-4-5", "claude-sonnet-4-5"]
        for id in notThinking {
            let contract = AnthropicModelContract.contract(for: id)
            for base in [200, 320, 512, 1_024, 2_048, 16_000] {
                XCTAssertEqual(contract.outputCap(base: base), base, "\(id) at \(base) is unchanged")
            }
        }
    }

    // MARK: - Strict schemas

    func testAClosedSchemaQualifiesForStrict() {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["label", "readings"],
            "properties": [
                "label": ["type": "string"],
                "readings": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["value"],
                        "properties": ["value": ["type": "number"],
                                       "unit": ["type": ["string", "null"]]] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        XCTAssertTrue(AnthropicModelContract.schemaQualifiesForStrict(schema))
        XCTAssertTrue(AnthropicModelContract.schemaQualifiesForStrict(["type": "string"]))
    }

    func testAnOpenObjectAtAnyLevelDoesNotQualify() {
        let closedLeaf: [String: Any] = ["type": "object", "additionalProperties": false,
                                         "required": ["a"], "properties": ["a": ["type": "string"]]]
        var missingAdditional = closedLeaf
        missingAdditional.removeValue(forKey: "additionalProperties")
        var additionalTrue = closedLeaf
        additionalTrue["additionalProperties"] = true
        var additionalSchema = closedLeaf
        additionalSchema["additionalProperties"] = ["type": "string"]
        var missingRequired = closedLeaf
        missingRequired.removeValue(forKey: "required")
        // An object declared only by its properties, with no `type`.
        let untyped: [String: Any] = ["properties": ["a": ["type": "string"]]]

        for open in [missingAdditional, additionalTrue, additionalSchema, missingRequired, untyped] {
            XCTAssertFalse(AnthropicModelContract.schemaQualifiesForStrict(open), "top level: \(open.keys.sorted())")
            // …and the same fault nested under a property, an array's items, a union and a
            // definition disqualifies the whole schema.
            let nested: [[String: Any]] = [
                ["type": "object", "additionalProperties": false, "required": ["child"],
                 "properties": ["child": open]],
                ["type": "array", "items": open],
                ["anyOf": [closedLeaf, open]],
                ["type": "object", "additionalProperties": false, "required": [String](),
                 "properties": [String: Any](), "$defs": ["thing": open]],
            ]
            for schema in nested {
                XCTAssertFalse(AnthropicModelContract.schemaQualifiesForStrict(schema), "\(schema.keys.sorted())")
            }
        }
    }

    // MARK: - Pricing rides along

    func testThe55IdsArePriced() {
        XCTAssertEqual(ModelPricing.rate(for: "claude-opus-5-5"), ModelPricing.Rate(4, 20, cached: 0.20))
        XCTAssertEqual(ModelPricing.rate(for: "claude-sonnet-5-5"), ModelPricing.Rate(2, 10, cached: 0.20))
        XCTAssertEqual(ModelPricing.rate(for: "claude-haiku-5-5"), ModelPricing.Rate(0.10, 0.50))
        // A dated snapshot resolves to its own row, not to the family it shares a prefix with.
        XCTAssertEqual(ModelPricing.rate(for: "claude-sonnet-5-5-20260901"), ModelPricing.Rate(2, 10, cached: 0.20))
        XCTAssertEqual(ModelPricing.rate(for: "claude-sonnet-5"), ModelPricing.Rate(3, 15), "the 5 row is untouched")
        XCTAssertNil(ModelPricing.rate(for: "claude-sonnet-5-6"), "a model with no row stays unpriced")
    }
}
