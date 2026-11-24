import XCTest
@testable import OpenGlasses

/// Plan MQ P2 — the three GGUF targets the owner named: on the native-tool allowlist behind the
/// flag, in the bundled catalog with verified bytes, no badge (decision 6: evidence only) and a
/// permissive licence (decision 7).
final class GGUFToolTargetsTests: XCTestCase {

    func testTheGGUFTargetsRunNativeToolCallsOnlyOnGGUFWithTheFlagOn() {
        for id in LocalNativeToolPolicy.ggufAllowlist {
            XCTAssertTrue(LocalNativeToolPolicy.usesNativeToolCalls(modelID: id, runtime: .llamaCpp, flagOn: true), id)
            XCTAssertFalse(LocalNativeToolPolicy.usesNativeToolCalls(modelID: id, runtime: .llamaCpp, flagOn: false), id)
            XCTAssertFalse(LocalNativeToolPolicy.usesNativeToolCalls(modelID: id, runtime: .mlx, flagOn: true), id)
            XCTAssertFalse(LocalModelCatalog.qualifiesForFieldAssistTools(LocalModelID(id)),
                           "under qualification shows nothing: \(id)")
        }
        XCTAssertTrue(LocalNativeToolPolicy.usesNativeToolCalls(
            modelID: "ggml-org/gemma-4-E2B-it-GGUF#gemma-4-E2B-it-Q4_0.gguf", runtime: .llamaCpp, flagOn: true),
                      "case does not matter")
        XCTAssertFalse(LocalNativeToolPolicy.usesNativeToolCalls(
            modelID: "Qwen/Qwen2.5-1.5B-Instruct-GGUF#qwen2.5-1.5b-instruct-q4_k_m.gguf", runtime: .llamaCpp, flagOn: true),
                       "a catalog GGUF model not on the list keeps the single shot")
        XCTAssertEqual(LocalNativeToolPolicy.ggufAllowlist.count, 3)
    }

    func testEveryGGUFTargetIsACatalogEntryWithNoBadgeAndAPermissiveLicence() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Resources/LocalModelCatalog.json")
        let (document, rejected) = try LocalModelCatalogDocument.loadStrict(from: Data(contentsOf: url))
        XCTAssertEqual(rejected, [])
        for id in LocalNativeToolPolicy.ggufAllowlist {
            let entry = try XCTUnwrap(document.entries.first { $0.id.rawValue.lowercased() == id }, id)
            XCTAssertEqual(entry.descriptor.capabilities, [.text], "badges follow evidence: \(id)")
            XCTAssertEqual(entry.evidence, .fileMetadataOnly, id)
            XCTAssertEqual(entry.descriptor.license.displayName, "Apache License 2.0", "decision 7: \(id)")
            XCTAssertEqual(entry.descriptor.license.revision, entry.descriptor.revision, id)
            XCTAssertLessThanOrEqual(entry.descriptor.contextLength, entry.trainedContextTokens ?? .max, id)
        }
        // The same Gemma on both runtimes samples alike.
        for id in ["ggml-org/gemma-4-e2b-it-gguf#gemma-4-e2b-it-q4_0.gguf", "ggml-org/gemma-4-e4b-it-gguf#gemma-4-e4b-it-q4_0.gguf"] {
            let entry = try XCTUnwrap(document.entries.first { $0.id.rawValue.lowercased() == id })
            XCTAssertEqual(entry.sampling?.general, LocalModelCatalog.gemma4Sampling.general, id)
        }
    }
}
