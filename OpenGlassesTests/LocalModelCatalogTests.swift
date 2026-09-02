import XCTest
@testable import OpenGlasses

/// Plan DZ P0 — the bundled catalog, and the compatibility projections that keep every pre-DZ call
/// site working.
///
/// The centrepiece is `testRecommendedModelsMatchThePreSeamList`, which holds a verbatim copy of the
/// array `LocalLLMService.recommendedModels` was before the catalog existed. That fixture is the
/// whole point: a projection is only a compatibility projection if it produces the same values in
/// the same order, and a test that derived its expectations from the catalog would agree with any
/// mistake the catalog made.
final class LocalModelCatalogTests: XCTestCase {

    /// The list exactly as it was hard-coded in `LocalLLMService` before Plan DZ.
    /// Order included — the picker renders this array directly and first-run offers entry zero.
    private struct PreSeamModel: Equatable {
        let id: String
        let name: String
        let estimatedSize: String
        let hasVision: Bool
        let hasToolCalling: Bool
        let notes: String
        let minimumRAMGB: Double
    }

    private let preSeamList: [PreSeamModel] = [
        PreSeamModel(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            name: "Gemma 4 E2B (Agent)",
            estimatedSize: "3.6 GB",
            hasVision: true,
            hasToolCalling: true,
            notes: "Best on-device agent — tool calling, 140+ languages, vision. Uses ~4 GB while running.",
            minimumRAMGB: 8),
        PreSeamModel(
            id: "mlx-community/gemma-4-e4b-it-4bit",
            name: "Gemma 4 E4B (Agent+)",
            estimatedSize: "5.1 GB",
            hasVision: true,
            hasToolCalling: true,
            notes: "Bigger Gemma 4 — highest-quality on-device agent, with vision. Needs a high-memory device (12 GB).",
            minimumRAMGB: 12),
        PreSeamModel(
            id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
            name: "SmolVLM2 2.2B (Vision)",
            estimatedSize: "1.5 GB",
            hasVision: true,
            hasToolCalling: false,
            notes: "Best small vision model — sees photos + video",
            minimumRAMGB: 0),
        PreSeamModel(
            id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            name: "SmolVLM2 500M (Vision)",
            estimatedSize: "0.35 GB",
            hasVision: true,
            hasToolCalling: false,
            notes: "Tiny vision model — basic photo understanding",
            minimumRAMGB: 0),
        PreSeamModel(
            id: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
            name: "LFM2.5 2.6B (Reasoning)",
            estimatedSize: "1.6 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Liquid AI hybrid reasoning model — thinks before every answer (expect a "
                + "pause before speech starts), then answers with strong tool use and "
                + "instruction following. Best quality per GB of the text-only models.",
            minimumRAMGB: 0),
        PreSeamModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen 2.5 3B",
            estimatedSize: "1.8 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Strong reasoning and tool use",
            minimumRAMGB: 0),
        PreSeamModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen 2.5 0.5B",
            estimatedSize: "0.4 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Ultra-light, basic capability",
            minimumRAMGB: 0),
    ]

    // MARK: - Compatibility projections

    func testRecommendedModelsMatchThePreSeamList() {
        let projected = LocalLLMService.recommendedModels.map {
            PreSeamModel(id: $0.id, name: $0.name, estimatedSize: $0.estimatedSize,
                         hasVision: $0.hasVision, hasToolCalling: $0.hasToolCalling,
                         notes: $0.notes, minimumRAMGB: $0.minimumRAMGB)
        }
        XCTAssertEqual(projected, preSeamList,
                       "the catalog is a compatibility projection — same models, same order, "
                       + "same copy")
    }

    func testVisionModelIdsMatchThePreSeamSet() {
        // Both hub casings of the Gemma 4 E-series were in the shipped set and must remain: a user
        // who typed the other one still needs the VLM factory.
        XCTAssertEqual(LocalLLMService.visionModelIds, [
            "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
            "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            "mlx-community/gemma-4-e2b-it-4bit",
            "mlx-community/gemma-4-E2B-it-4bit",
            "mlx-community/gemma-4-e4b-it-4bit",
        ])
    }

    func testExpectedDownloadBytesUnchanged() {
        // The concrete numbers, not a re-derivation: this drives the download progress bar.
        XCTAssertEqual(LocalLLMService.expectedDownloadBytes(for: "mlx-community/gemma-4-e4b-it-4bit"),
                       Int64(5.1 * 1_073_741_824))
        XCTAssertEqual(LocalLLMService.expectedDownloadBytes(for: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx"),
                       Int64(0.35 * 1_073_741_824))
        XCTAssertNil(LocalLLMService.expectedDownloadBytes(for: "someone/custom-model-4bit"),
                     "an uncatalogued id has no expected size")
        for model in LocalLLMService.recommendedModels {
            XCTAssertNotNil(LocalLLMService.expectedDownloadBytes(for: model.id),
                            "\(model.id) must parse")
        }
    }

    // MARK: - Descriptor facts

    func testEveryEntryDeclaresTextAndAnMLXRuntime() {
        for entry in LocalModelCatalog.entries {
            XCTAssertEqual(entry.descriptor.runtime, .mlx)
            XCTAssertTrue(entry.descriptor.capabilities.contains(.text))
            XCTAssertEqual(entry.descriptor.repositoryID, entry.id.rawValue)
        }
    }

    func testContextLengthAgreesWithTheBudgetTable() {
        // One source of truth for the context window; a second table is how the two drift.
        for entry in LocalModelCatalog.entries {
            XCTAssertEqual(entry.descriptor.contextLength,
                           LocalModelBudget.contextWindow(for: entry.id.rawValue),
                           "\(entry.id) context window")
        }
    }

    func testCatalogEntriesAreNotInstallableUntilTheyArePinned() {
        // Deliberate and honest: these entries record no revision and no digests, because the MLX
        // path never captured either. `installationFaults` is what stops that becoming the standard
        // for a *new* download.
        for entry in LocalModelCatalog.entries {
            let faults = entry.descriptor.installationFaults()
            XCTAssertTrue(faults.contains(.unpinnedRevision), "\(entry.id) should report unpinned")
        }
    }

    func testVisionIsAssertedNotInferredFromTheName() {
        // "Video" in the name, vision genuinely declared; "Instruct" in the name, no vision.
        XCTAssertTrue(LocalModelCatalog.descriptor(
            for: LocalModelID("mlx-community/SmolVLM2-500M-Video-Instruct-mlx"))?.supportsVision == true)
        XCTAssertFalse(LocalModelCatalog.descriptor(
            for: LocalModelID("mlx-community/Qwen2.5-3B-Instruct-4bit"))?.supportsVision == true)
        // A plausible-looking uncatalogued id gets no vision claim at all.
        let invented = LocalModelCatalog.compatibilityDescriptor(
            forLegacyMLXModelID: "someone/My-Great-VL-Vision-Model-4bit")
        XCTAssertFalse(invented.supportsVision,
                       "a name is not evidence — this is the exact inference the plan forbids")
        XCTAssertEqual(invented.capabilities, [.text])
    }

    func testLicenseIsMarkedUnverifiedRatherThanInvented() {
        for entry in LocalModelCatalog.entries {
            XCTAssertNil(entry.descriptor.license.revision)
            XCTAssertFalse(entry.descriptor.license.requiresAcceptance,
                           "no acceptance gate existed before DZ; adding one here would block "
                           + "models that install today")
        }
    }

    // MARK: - Legacy resolution

    func testKnownLegacyIDResolvesToItsBundledDescriptor() {
        let resolved = LocalModelCatalog.resolveDescriptor(
            forLegacyMLXModelID: "mlx-community/Qwen2.5-3B-Instruct-4bit")
        XCTAssertEqual(resolved.displayName, "Qwen 2.5 3B")
        XCTAssertTrue(resolved.supportsTools)
    }

    func testRetiredCatalogEntryStillResolves() {
        // Gemma 2 2B was dropped from the recommended list but users have it downloaded.
        let resolved = LocalModelCatalog.resolveDescriptor(
            forLegacyMLXModelID: "mlx-community/gemma-2-2b-it-4bit")
        XCTAssertEqual(resolved.runtime, .mlx)
        XCTAssertEqual(resolved.id.rawValue, "mlx-community/gemma-2-2b-it-4bit")
        XCTAssertEqual(resolved.contextLength, 4096, "its LocalModelBudget entry still applies")
    }

    func testUnknownLegacyIDDefaultsToMLXAndNeverFails() {
        let resolved = LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: "who/knows")
        XCTAssertEqual(resolved.runtime, .mlx)
        XCTAssertEqual(resolved.displayName, "who/knows")
        XCTAssertEqual(resolved.contextLength, LocalModelBudget.defaultContextWindow)
    }

    func testResolutionIsIdempotent() {
        let once = LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: "who/knows")
        let twice = LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: "who/knows")
        XCTAssertEqual(once, twice)
    }

    // MARK: - Stable id encoding

    func testStorageComponentRoundTrips() {
        for raw in ["mlx-community/gemma-4-e2b-it-4bit", "LiquidAI/LFM2.5-2.6B-MLX-4bit",
                    "a/b/c", "..", "with space", "emoji-🫥"] {
            let id = LocalModelID(raw)
            XCTAssertEqual(LocalModelID(storageComponent: id.storageComponent), id, raw)
        }
    }

    func testStorageComponentIsASingleSafePathComponent() {
        for raw in ["mlx-community/gemma-4-e2b-it-4bit", "../../etc/passwd", "a/../../b", "."] {
            let component = LocalModelID(raw).storageComponent
            XCTAssertFalse(component.contains("/"), "\(raw) must not introduce a path component")
            XCTAssertNotEqual(component, ".")
            XCTAssertNotEqual(component, "..")
        }
    }

    func testModelIDEncodesAsABareString() throws {
        let data = try JSONEncoder().encode(LocalModelID("a/b"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"a\\/b\"")
        XCTAssertEqual(try JSONDecoder().decode(LocalModelID.self, from: data), LocalModelID("a/b"))
    }

    // MARK: - Relative path containment

    func testPathNormalizationRejectsTraversalAndAbsolutePaths() {
        XCTAssertEqual(LocalModelPath.normalize("weights.gguf"), .contained("weights.gguf"))
        XCTAssertEqual(LocalModelPath.normalize("sub/dir/weights.gguf"), .contained("sub/dir/weights.gguf"))
        XCTAssertEqual(LocalModelPath.normalize("./a/./b"), .contained("a/b"))
        XCTAssertEqual(LocalModelPath.normalize("a/../b"), .contained("b"))

        XCTAssertEqual(LocalModelPath.normalize("/etc/passwd"), .absolute)
        XCTAssertEqual(LocalModelPath.normalize("~/secrets"), .absolute)
        XCTAssertEqual(LocalModelPath.normalize("../escape"), .escaping)
        XCTAssertEqual(LocalModelPath.normalize("a/../../escape"), .escaping)
        // Percent-encoded traversal: the decode has to happen before the component scan.
        XCTAssertEqual(LocalModelPath.normalize("%2e%2e/escape"), .escaping)
        XCTAssertEqual(LocalModelPath.normalize("..\\escape"), .escaping)
        XCTAssertEqual(LocalModelPath.normalize(""), .empty)
        XCTAssertEqual(LocalModelPath.normalize("   "), .empty)
        XCTAssertEqual(LocalModelPath.normalize("a/.."), .empty)
    }

    func testResolveKeepsFilesBeneathTheModelRoot() {
        let root = URL(fileURLWithPath: "/tmp/models/x", isDirectory: true)
        XCTAssertEqual(LocalModelPath.resolve("w.gguf", under: root)?.lastPathComponent, "w.gguf")
        XCTAssertNil(LocalModelPath.resolve("../y/w.gguf", under: root))
        XCTAssertNil(LocalModelPath.resolve("/etc/passwd", under: root))
    }

    // MARK: - Descriptor validation

    func testInstallationFaultsCatchEveryUnsafeFileShape() {
        let descriptor = LocalModelDescriptor(
            id: LocalModelID(""),
            displayName: "bad",
            runtime: .llamaCpp,
            repositoryID: "",
            revision: LocalModelDescriptor.floatingRevision,
            files: [
                LocalModelFile(relativePath: "../escape.gguf", byteCount: 10, sha256: "aa", role: .weights),
                LocalModelFile(relativePath: "/abs.gguf", byteCount: 10, sha256: "bb", role: .weights),
                LocalModelFile(relativePath: "ok.gguf", byteCount: 0, sha256: "", role: .weights),
                LocalModelFile(relativePath: "ok.gguf", byteCount: 5, sha256: "cc", role: .auxiliary),
            ],
            capabilities: [.vision],
            contextLength: 4096,
            estimatedWeightsBytes: 1,
            estimatedWorkingBytes: 1,
            minimumHeadroomBytes: 1)

        let faults = descriptor.installationFaults()
        XCTAssertTrue(faults.contains(.emptyID))
        XCTAssertTrue(faults.contains(.emptyRepositoryID))
        XCTAssertTrue(faults.contains(.unpinnedRevision))
        XCTAssertTrue(faults.contains(.noTextCapability))
        XCTAssertTrue(faults.contains(.escapingRelativePath("../escape.gguf")))
        XCTAssertTrue(faults.contains(.absoluteRelativePath("/abs.gguf")))
        XCTAssertTrue(faults.contains(.nonPositiveByteCount("ok.gguf")))
        XCTAssertTrue(faults.contains(.missingDigest("ok.gguf")))
        XCTAssertTrue(faults.contains(.duplicateRelativePath("ok.gguf")))
    }

    func testAFullyPinnedDescriptorHasNoFaults() {
        let descriptor = LocalModelDescriptor(
            id: LocalModelID("org/model"),
            displayName: "Model",
            runtime: .llamaCpp,
            repositoryID: "org/model",
            revision: "0123456789abcdef",
            files: [LocalModelFile(relativePath: "model.gguf", byteCount: 1_024,
                                   sha256: "abc", role: .weights)],
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: 1_024,
            estimatedWorkingBytes: 1,
            minimumHeadroomBytes: 1_025)
        XCTAssertEqual(descriptor.installationFaults(), [])
    }

    // MARK: - Legacy-safe decoding

    func testDescriptorDecodesARecordMissingEveryOptionalField() throws {
        // The `ModelConfig.supportsVision` precedent: a record written by an older build must still
        // decode, with defaults, rather than invalidating the installation.
        let json = """
        {"id":"a/b","displayName":"A","repositoryID":"a/b"}
        """
        let decoded = try JSONDecoder().decode(LocalModelDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, LocalModelID("a/b"))
        XCTAssertEqual(decoded.runtime, .mlx, "MLX is the runtime that has always existed")
        XCTAssertEqual(decoded.revision, LocalModelDescriptor.floatingRevision)
        XCTAssertEqual(decoded.files, [])
        XCTAssertEqual(decoded.capabilities, [])
        XCTAssertEqual(decoded.license, .unverified)
    }

    func testDescriptorDropsUnknownRuntimeAndCapabilitiesFromANewerBuild() throws {
        let json = """
        {"id":"a/b","displayName":"A","repositoryID":"a/b","runtime":"someFutureEngine",
         "capabilities":["text","audio"],"revision":"r1"}
        """
        let decoded = try JSONDecoder().decode(LocalModelDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.runtime, .mlx)
        XCTAssertEqual(decoded.capabilities, [.text],
                       "an unknown capability must be dropped, never claimed")
    }

    func testDescriptorEncodingIsStable() throws {
        // A Set has no order; an unstable encoding would make the migration's read-back comparison
        // and any future manifest digest meaningless.
        let descriptor = LocalModelCatalog.entries[0].descriptor
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(descriptor)
        let second = try encoder.encode(descriptor)
        XCTAssertEqual(first, second)
        let round = try JSONDecoder().decode(LocalModelDescriptor.self, from: first)
        XCTAssertEqual(round, descriptor)
    }
}
