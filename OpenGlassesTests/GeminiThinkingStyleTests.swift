import XCTest
@testable import OpenGlasses

/// Which thinking control each Gemini model id is sent, and the function-call shapes of the same
/// REST loop. The rows are Google's thinking guide and 3.8 Flash migration notes as read
/// 2026-10-10; nothing here was run against a live key.
final class GeminiThinkingStyleTests: XCTestCase {

    private let all: [ReasoningEffort] = [.minimal, .low, .medium, .high]
    private let noMinimal: [ReasoningEffort] = [.low, .medium, .high]

    func testListedGemini3ModelsTakeTheirDocumentedLevels() {
        typealias Row = (model: String, accepted: [ReasoningEffort], providerDefault: ReasoningEffort)
        let rows: [Row] = [
            ("gemini-3.8-flash", noMinimal, .medium),
            ("gemini-3.6-flash", all, .medium),
            ("gemini-3.5-flash-lite", all, .minimal),
            ("gemini-3.1-flash-lite", all, .minimal),
            ("gemini-3.1-flash-lite-image", [.minimal, .high], .minimal),
            ("gemini-3.1-pro-preview", noMinimal, .high),
            ("gemini-3-flash-preview", all, .high),
            ("gemini-3-pro-preview", [.low, .high], .high),
            // A dated snapshot, the list endpoint's prefix, and stray case or spaces.
            ("gemini-3.8-flash-2026-09-01", noMinimal, .medium),
            ("models/gemini-3.5-flash-lite", all, .minimal),
            (" Gemini-3.6-Flash ", all, .medium),
        ]
        for row in rows {
            XCTAssertEqual(GeminiThinkingStyle.style(for: row.model),
                           .level(accepted: row.accepted, providerDefault: row.providerDefault), row.model)
        }
    }

    func testTheShippedDefaultIsListed() {
        XCTAssertEqual(GeminiThinkingStyle.style(for: LLMProvider.gemini.defaultModel),
                       .level(accepted: all, providerDefault: .minimal))
    }

    func testUnlistedGemini3IdsGetTheLevelsEveryListedChatModelTakes() {
        for model in ["gemini-3.9-flash", "gemini-3.5-flash", "gemini-4-pro", "gemini-10-flash",
                      "gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"] {
            XCTAssertEqual(GeminiThinkingStyle.style(for: model),
                           .level(accepted: [.low, .high], providerDefault: nil), model)
        }
        // "Every listed chat model" is a claim about the table: hold it to that.
        let chatModels = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite",
                          "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-3-pro-preview"]
        for model in chatModels {
            guard case .level(let accepted, _) = GeminiThinkingStyle.style(for: model) else {
                return XCTFail("\(model) should take a level")
            }
            XCTAssertTrue(Set(GeminiThinkingStyle.commonLevels).isSubset(of: accepted), model)
        }
    }

    func testOlderAndUnplaceableIdsKeepTheBudget() {
        typealias Row = (model: String, floor: Int, canDisable: Bool)
        let rows: [Row] = [
            ("gemini-2.5-flash", 0, true),
            ("gemini-2.5-flash-preview-09-2025", 0, true),
            ("gemini-2.0-flash", 0, true),
            ("gemini-2.5-flash-lite", 512, true),
            ("gemini-2.5-pro", 128, false),
            ("gemini-1.5-pro", 128, false),
            // No readable version: the shape every current model accepts.
            ("gemini-pro", 128, false),
            ("gemini-exp-1206", 0, true),
            ("tunedModels/my-model-abc123", 0, true),
            ("gemma-3-27b-it", 0, true),
            ("", 0, true),
        ]
        for row in rows {
            XCTAssertEqual(GeminiThinkingStyle.style(for: row.model),
                           .budget(floor: row.floor, canDisable: row.canDisable), row.model)
        }
    }

    func testNearestLevel() {
        typealias Row = (requested: ReasoningEffort, accepted: [ReasoningEffort], sent: ReasoningEffort)
        let rows: [Row] = [
            (.none, all, .minimal), (.none, noMinimal, .low),
            (.minimal, noMinimal, .low), (.minimal, all, .minimal),
            (.medium, [.low, .high], .low), (.medium, all, .medium),
            (.xhigh, all, .high), (.xhigh, [.minimal, .high], .high),
            (.low, [.minimal, .high], .minimal),
        ]
        for row in rows {
            XCTAssertEqual(GeminiThinkingStyle.nearestLevel(row.requested, accepted: row.accepted), row.sent,
                           "\(row.requested) in \(row.accepted)")
        }
    }

    // MARK: - Function calls

    /// Gemini 3 always returns an id on a function call, and its response should carry it back.
    func testFunctionResponseEchoesTheCallsIdAndName() throws {
        let invocation = GeminiFunctionCalling.invocation(
            name: "get_weather", call: ["name": "get_weather", "id": "fc_8a1", "args": ["city": "Lisbon"]])
        XCTAssertEqual(invocation.responseID, "fc_8a1")
        XCTAssertEqual(invocation.arguments?["city"] as? String, "Lisbon")
        // Not the journal's identity: nothing has shown a Gemini id never repeats.
        XCTAssertNil(invocation.id)

        let part = GeminiFunctionCalling.responsePart(for: invocation, response: ["result": "18C"])
        let response = try XCTUnwrap(part["functionResponse"] as? [String: Any])
        XCTAssertEqual(Set(response.keys), ["name", "id", "response"])
        XCTAssertEqual(response["id"] as? String, "fc_8a1")
        XCTAssertEqual(response["name"] as? String, "get_weather")
        XCTAssertEqual((response["response"] as? [String: String])?["result"], "18C")
    }

    /// A 2.x model sends no id: the response is name-keyed, as it always was, with no empty `id`.
    func testFunctionResponseWithoutAnIdStaysNameKeyed() throws {
        for call in [["name": "stop_timer", "args": [String: Any]()], ["name": "stop_timer", "id": ""]] as [[String: Any]] {
            let invocation = GeminiFunctionCalling.invocation(name: "stop_timer", call: call)
            XCTAssertNil(invocation.responseID)
            let part = GeminiFunctionCalling.responsePart(for: invocation, response: ["error": "none running"])
            let response = try XCTUnwrap(part["functionResponse"] as? [String: Any])
            XCTAssertEqual(Set(response.keys), ["name", "response"])
        }
    }

    /// `args` is optional in the API. A call without it used to be skipped, which ended the turn
    /// with nothing run and nothing said.
    func testACallWithoutArgsRunsWithNone() {
        let invocation = GeminiFunctionCalling.invocation(name: "stop_timer", call: ["name": "stop_timer", "id": "fc_1"])
        XCTAssertNotNil(invocation.arguments, "nil would be reported as unparseable arguments")
        XCTAssertEqual(invocation.arguments?.count, 0)
    }
}
