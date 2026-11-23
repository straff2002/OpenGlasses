import XCTest
@testable import OpenGlasses

/// Plan MQ H1: a catalog entry's own sampling, as its publisher recommends it, over the global set.
final class LocalModelSamplingTests: XCTestCase {

    private func decode(_ json: String) throws -> LocalModelSampling {
        try JSONDecoder().decode(LocalModelSampling.self, from: Data(json.utf8))
    }

    func testOnlyTheMembersPresentAreDecoded() throws {
        let sampling = try decode(#"{"temperature": 1.0, "topK": 64, "source": "card"}"#)
        XCTAssertEqual(sampling.general, .init(temperature: 1.0, topK: 64))
        XCTAssertNil(sampling.general.topP)
        XCTAssertNil(sampling.general.minP)
        XCTAssertNil(sampling.general.repetitionPenalty)
        XCTAssertNil(sampling.general.presencePenalty)
        XCTAssertNil(sampling.toolTurn)
        XCTAssertEqual(sampling.source, "card")
    }

    func testOnlyTheMembersSetReplaceTheGlobalValues() throws {
        let sampling = try decode(#"{"temperature": 1.0, "topK": 64, "source": "card"}"#)
        let resolved = sampling.resolved(over: LocalModelSampling.global, toolTurn: false)
        XCTAssertEqual(resolved.temperature, 1.0)
        XCTAssertEqual(resolved.topK, 64)
        XCTAssertEqual(resolved.topP, 0.9, "top-p is not set, so the global value stands")
        XCTAssertNil(resolved.minP)
        XCTAssertNil(resolved.repetitionPenalty)
    }

    func testTheToolTurnSetAppliesOverTheEntrysOwnOnAToolTurnOnly() throws {
        let sampling = try decode(#"{"temperature": 0.8, "topP": 0.95, "toolTurn": {"temperature": 0.2}, "source": "card"}"#)
        XCTAssertEqual(sampling.resolved(over: LocalModelSampling.global, toolTurn: false).temperature, 0.8)
        let tool = sampling.resolved(over: LocalModelSampling.global, toolTurn: true)
        XCTAssertEqual(tool.temperature, 0.2)
        XCTAssertEqual(tool.topP, 0.95, "the entry's own set is under the tool-turn set")
    }

    func testAModelWithNoSetKeepsTheGlobalSet() {
        XCTAssertEqual(LocalModelSampling.global, LocalSamplingConfiguration(temperature: 0.7, topP: 0.9))
        for id in ["mlx-community/Qwen2.5-3B-Instruct-4bit", "someone/uncatalogued-model", ""] {
            XCTAssertEqual(LocalModelSampling.configuration(for: id, toolTurn: false, ggufEntries: { [] }),
                           LocalModelSampling.global, id)
        }
        XCTAssertEqual(LocalModelSampling.configuration(for: nil, toolTurn: true, ggufEntries: { [] }), LocalModelSampling.global)
    }

    /// Only entries whose publisher states a recommendation carry one, each with its source.
    func testTheCatalogCarriesThePublishersSetsWithTheirSources() throws {
        let withSampling = LocalModelCatalog.entries.filter { $0.sampling != nil }.map(\.id.rawValue).sorted()
        XCTAssertEqual(withSampling, ["LiquidAI/LFM2.5-2.6B-MLX-4bit", "mlx-community/gemma-4-e2b-it-4bit",
                                      "mlx-community/gemma-4-e4b-it-4bit"])
        for entry in LocalModelCatalog.entries {
            XCTAssertNil(LocalModelCatalog.validationError(for: entry), entry.id.rawValue)
            if let sampling = entry.sampling {
                XCTAssertFalse(sampling.source.isEmpty, entry.id.rawValue)
                XCTAssertNil(sampling.toolTurn, "no publisher we ship recommends tool-turn settings")
            }
        }
        let gemma = LocalModelSampling.configuration(for: "mlx-community/gemma-4-e2b-it-4bit", toolTurn: true,
                                                     ggufEntries: { [] })
        XCTAssertEqual(gemma.temperature, 1.0)
        XCTAssertEqual(gemma.topP, 0.95)
        XCTAssertEqual(gemma.topK, 64)
        XCTAssertNil(gemma.minP)
        XCTAssertNil(gemma.repetitionPenalty)
        // LFM2.5's set is the one `generateParameters` hard-coded before H1; the card names no top-p.
        let lfm = LocalModelSampling.configuration(for: "LiquidAI/LFM2.5-2.6B-MLX-4bit", toolTurn: false,
                                                   ggufEntries: { [] })
        XCTAssertEqual(lfm.temperature, 0.1)
        XCTAssertEqual(lfm.topK, 50)
        XCTAssertEqual(lfm.repetitionPenalty, 1.1)
        XCTAssertEqual(lfm.topP, 0.9)
    }

    func testASetMustNameItsSourceAndHoldSamplerValues() throws {
        XCTAssertEqual(try decode(#"{"temperature": 1.0}"#).validationError(supportsPresencePenalty: true),
                       "sampling names no source")
        XCTAssertEqual(try decode(#"{"source": "card"}"#).validationError(supportsPresencePenalty: true),
                       "sampling sets nothing")
        XCTAssertEqual(try decode(#"{"topP": 0, "source": "card"}"#).validationError(supportsPresencePenalty: true),
                       "sampling top-p out of range")
        XCTAssertEqual(try decode(#"{"temperature": 3, "source": "card"}"#).validationError(supportsPresencePenalty: true),
                       "sampling temperature out of range")
        XCTAssertNil(try decode(#"{"presencePenalty": 1.5, "source": "card"}"#).validationError(supportsPresencePenalty: true))
        XCTAssertEqual(try decode(#"{"presencePenalty": 1.5, "source": "card"}"#).validationError(supportsPresencePenalty: false),
                       "sampling presence penalty is not supported by this runtime")
    }

    // MARK: - GGUF

    private func ggufCatalog(sampling: Any?) throws -> (LocalModelCatalogDocument, [String]) {
        var entry: [String: Any] = [
            "id": "owner/repo#model-q4_k_m.gguf", "displayName": "Test model", "repositoryID": "owner/repo",
            "revision": String(repeating: "b", count: 40), "quantization": "Q4_K_M", "capabilities": ["text"],
            "contextLength": 4096, "estimatedWeightsBytes": 1_000,
            "files": [["relativePath": "model-q4_k_m.gguf", "byteCount": 1_000,
                       "sha256": String(repeating: "a", count: 64), "role": "weights"]],
            "license": ["displayName": "Apache License 2.0", "summary": "Permissive.", "requiresAcceptance": false,
                        "revision": String(repeating: "b", count: 40)],
            "evidence": "fileMetadataOnly",
        ]
        if let sampling { entry["sampling"] = sampling }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "models": [entry]])
        return try LocalModelCatalogDocument.loadStrict(from: data)
    }

    func testAGGUFEntryDecodesItsSetAndTheRequestCarriesIt() throws {
        let (document, rejected) = try ggufCatalog(sampling: ["temperature": 0.6, "minP": 0.1, "source": "card"])
        XCTAssertEqual(rejected, [])
        let entry = try XCTUnwrap(document.entries.first)
        XCTAssertEqual(entry.sampling?.general, .init(temperature: 0.6, minP: 0.1))
        let resolved = LocalModelSampling.configuration(for: entry.id.rawValue, toolTurn: false,
                                                        ggufEntries: { document.entries })
        XCTAssertEqual(resolved.temperature, 0.6)
        XCTAssertEqual(resolved.minP, 0.1)
        // The engine takes min-p from the request now; a member left open keeps its own default.
        let options = LlamaSamplerOptions(resolved)
        XCTAssertEqual(options.minP, 0.1)
        XCTAssertEqual(options.topK, LlamaSamplerOptions.defaultTopK)
        XCTAssertEqual(options.penaltyRepeat, LlamaSamplerOptions.defaultRepeatPenalty)
        XCTAssertEqual(LlamaSamplerOptions(LocalSamplingConfiguration()).minP, LlamaSamplerOptions.defaultMinP)
    }

    func testAGGUFEntryWithoutASetOrWithAnUnsupportedOneIsHandled() throws {
        let (plain, plainRejected) = try ggufCatalog(sampling: nil)
        XCTAssertEqual(plainRejected, [])
        XCTAssertNil(plain.entries.first?.sampling)
        let (refused, rejected) = try ggufCatalog(sampling: ["presencePenalty": 1.5, "source": "card"])
        XCTAssertTrue(refused.entries.isEmpty, "the GGUF sampler has no presence penalty")
        XCTAssertEqual(rejected.count, 1)
    }

    func testTheBundledGGUFCatalogStillLoadsWhole() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Resources/LocalModelCatalog.json")
        let (document, rejected) = try LocalModelCatalogDocument.loadStrict(from: Data(contentsOf: url))
        XCTAssertEqual(rejected, [])
        XCTAssertEqual(document.entries.count, 3)
        XCTAssertTrue(document.entries.allSatisfy { $0.sampling == nil }, "no GGUF publisher recommendation is cited yet")
    }
}
