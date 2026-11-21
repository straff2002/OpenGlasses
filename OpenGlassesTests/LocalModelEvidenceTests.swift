import XCTest
@testable import OpenGlasses

/// Plan MQ P0: the MLX catalog's badges follow evidence, under the GGUF catalog's rule, and the
/// tools a downloaded model is offered do not depend on a badge.
@MainActor
final class LocalModelEvidenceTests: XCTestCase {

    func testNoMLXEntryClaimsMoreThanTextWithoutDeviceEvidence() {
        for entry in LocalModelCatalog.entries {
            XCTAssertNil(LocalModelCatalog.validationError(for: entry), "\(entry.id)")
            XCTAssertEqual(entry.evidence, .fileMetadataOnly,
                           "\(entry.id): no MLX entry has been qualified on a device yet")
            XCTAssertEqual(entry.descriptor.capabilities, [.text], "\(entry.id) wears a badge nobody earned")
        }
    }

    func testTheRuleRefusesAnOverClaimingEntry() throws {
        let honest = try XCTUnwrap(LocalModelCatalog.entries.first)
        let descriptor = honest.descriptor
        let badged = LocalModelDescriptor(
            id: descriptor.id, displayName: descriptor.displayName, runtime: .mlx,
            repositoryID: descriptor.repositoryID, revision: descriptor.revision, files: [],
            quantization: descriptor.quantization, capabilities: [.text, .toolFriendly],
            contextLength: descriptor.contextLength, estimatedWeightsBytes: descriptor.estimatedWeightsBytes,
            estimatedWorkingBytes: descriptor.estimatedWorkingBytes,
            minimumHeadroomBytes: descriptor.minimumHeadroomBytes, license: descriptor.license)
        let overClaiming = LocalModelCatalog.Entry(descriptor: badged, snapshot: honest.snapshot,
                                                   notes: honest.notes, minimumRAMGB: honest.minimumRAMGB,
                                                   evidence: .fileMetadataOnly, pendingClaims: [.text, .toolFriendly])
        XCTAssertEqual(LocalModelCatalog.validationError(for: overClaiming), "claims toolFriendly without device evidence")

        let verified = LocalModelCatalog.Entry(descriptor: badged, snapshot: honest.snapshot,
                                               notes: honest.notes, minimumRAMGB: honest.minimumRAMGB,
                                               evidence: .deviceVerified, pendingClaims: [.text, .toolFriendly])
        XCTAssertNil(LocalModelCatalog.validationError(for: verified))
    }

    func testDeviceEvidenceIsWhatLetsAPendingClaimThrough() {
        XCTAssertEqual(LocalModelCatalog.claimedCapabilities([.text, .vision, .toolFriendly], evidence: .fileMetadataOnly),
                       [.text])
        XCTAssertEqual(LocalModelCatalog.claimedCapabilities([.vision, .toolFriendly], evidence: .deviceVerified),
                       [.text, .vision, .toolFriendly])
    }

    func testTheToolCandidatesAreTheShippedAgentModelsAndNotTheSmallestQwen() {
        let pending = Dictionary(uniqueKeysWithValues: LocalModelCatalog.entries.map { ($0.id.rawValue, $0.pendingClaims) })
        for id in ["mlx-community/gemma-4-e2b-it-4bit", "mlx-community/gemma-4-e4b-it-4bit",
                   "mlx-community/Qwen2.5-3B-Instruct-4bit", "LiquidAI/LFM2.5-2.6B-MLX-4bit"] {
            XCTAssertEqual(pending[id]?.contains(.toolFriendly), true, id)
        }
        XCTAssertEqual(pending["mlx-community/Qwen2.5-0.5B-Instruct-4bit"]?.contains(.toolFriendly), false,
                       "4-bit tool calling collapses at 1B and below: not even a candidate until a device run")
    }

    func testVisionStaysAnArchitecturalFactSoPhotosStillReachAVisionModel() {
        // The badge went; the routing did not. Photo turns, the vision factory and the picker's
        // filter all read the asserted architecture set.
        for id in ["mlx-community/gemma-4-e2b-it-4bit", "mlx-community/SmolVLM2-2.2B-Instruct-mlx"] {
            XCTAssertTrue(LocalLLMService.isVisionCapable(modelId: id), id)
            let descriptor = LocalModelCatalog.descriptor(for: LocalModelID(id))!
            XCTAssertFalse(descriptor.supportsVision, "\(id): no badge without evidence")
            XCTAssertTrue(LocalModelPresentation.CapabilityFilter.vision.accepts(
                LocalModelCatalog.filterCapabilities(for: descriptor)), "\(id) still listed under Vision")
            XCTAssertFalse(LocalModelPresentation.CapabilityFilter.text.accepts(
                LocalModelCatalog.filterCapabilities(for: descriptor)))
        }
        XCTAssertTrue(LocalLLMService.recommendedModels.first { $0.id == "mlx-community/gemma-4-e2b-it-4bit" }?.hasVision == true)
    }

    func testAnOldRecordsBadgesAreReplacedByTheCatalogsCurrentClaims() {
        // A record written before Plan MQ still says vision and tools.
        let current = LocalModelCatalog.descriptor(for: LocalModelID("mlx-community/gemma-4-e2b-it-4bit"))!
        let stale = LocalModelDescriptor(
            id: current.id, displayName: current.displayName, runtime: .mlx,
            repositoryID: current.repositoryID, revision: current.revision, files: [],
            quantization: current.quantization, capabilities: [.text, .vision, .toolFriendly],
            contextLength: current.contextLength, estimatedWeightsBytes: current.estimatedWeightsBytes,
            estimatedWorkingBytes: current.estimatedWorkingBytes,
            minimumHeadroomBytes: current.minimumHeadroomBytes, license: current.license)
        let badges = LocalModelPresentation.rowBadges(state: .installed, descriptor: stale)
        XCTAssertFalse(badges.contains { $0.id == "capability.tools" })
        XCTAssertFalse(badges.contains { $0.id == "capability.vision" })
        XCTAssertEqual(LocalModelCatalog.currentClaims(
            for: LocalModelCatalog.compatibilityDescriptor(forLegacyMLXModelID: "someone/other")), [.text])
    }

    func testNoDownloadedModelHasEarnedTheFieldAssistToolsYet() {
        for entry in LocalModelCatalog.entries {
            XCTAssertFalse(LocalModelCatalog.qualifiesForFieldAssistTools(entry.id, ggufEntries: []), "\(entry.id)")
        }
        XCTAssertFalse(LocalModelCatalog.qualifiesForFieldAssistTools(LocalModelID("someone/unknown"), ggufEntries: []))
    }

    /// Decision 6: the everyday local tools never depended on a badge, and still don't. Every shipped
    /// model — Gemma 4, Qwen 2.5 3B, the 0.5B — gets the same everyday set it got before.
    func testTheEverydaySetIsOfferedWhateverTheBadge() {
        let registered = Array(LLMService.localSafeTools) + ["field_session", "reading", "web_search"]
        let offered = LLMService.localToolNames(registered: registered, offlineHandoff: false)
        XCTAssertEqual(Set(offered), LLMService.localSafeTools)
        XCTAssertFalse(offered.contains("field_session"), "no Field Assist tools until a model qualifies")
    }
}
