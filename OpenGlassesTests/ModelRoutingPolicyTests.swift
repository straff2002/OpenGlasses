import XCTest
@testable import OpenGlasses

/// Plan BG P2 — the pure model-routing decision extracted from `handleTranscription`. These pin the
/// fast-tier agent / auto-route / keep branching that was previously untested inside the voice path.
final class ModelRoutingPolicyTests: XCTestCase {

    /// Baseline args = fast tier, agent mode on, model downloaded, cloud agent, not a photo,
    /// auto-routing on, a distinct tier model available. Override per test.
    private func decide(
        isFastTier: Bool = true,
        agentModeEnabled: Bool = true,
        agentModelDownloaded: Bool = true,
        agentIsCloud: Bool = true,
        localAgentEnabled: Bool = false,
        isPhoto: Bool = false,
        autoRoutingEnabled: Bool = true,
        tierModelId: String? = "tier-model",
        activeModelId: String? = "active-model"
    ) -> ModelTurnRoute {
        ModelRoutingPolicy.decide(
            isFastTier: isFastTier, agentModeEnabled: agentModeEnabled,
            agentModelDownloaded: agentModelDownloaded, agentIsCloud: agentIsCloud,
            localAgentEnabled: localAgentEnabled, isPhoto: isPhoto,
            autoRoutingEnabled: autoRoutingEnabled, tierModelId: tierModelId, activeModelId: activeModelId)
    }

    // MARK: - Local agent

    func testFastCloudAgentRoutesToLocalAgent() {
        XCTAssertEqual(decide(), .localAgent)
    }

    func testOnDeviceAgentUsedOnlyWhenOptedIn() {
        // On-device (not cloud), opt-in off → falls through to auto-routing, not the agent.
        XCTAssertEqual(decide(agentIsCloud: false, localAgentEnabled: false), .switchModel(toId: "tier-model"))
        // On-device with opt-in on → agent.
        XCTAssertEqual(decide(agentIsCloud: false, localAgentEnabled: true), .localAgent)
    }

    func testPhotoTurnNeverUsesAgent() {
        XCTAssertEqual(decide(isPhoto: true), .keepCurrent)
    }

    func testPhotoTurnKeepsSelectedModelDuringOfflineHandoff() {
        XCTAssertEqual(ModelRoutingPolicy.decide(
            isFastTier: true, agentModeEnabled: true, agentModelDownloaded: true,
            agentIsCloud: false, localAgentEnabled: true, isPhoto: true,
            autoRoutingEnabled: true, tierModelId: "tier", activeModelId: "selected",
            phoneModelId: "local"), .keepCurrent)
    }

    func testAgentSkippedWhenModeOffOrNotDownloaded() {
        XCTAssertEqual(decide(agentModeEnabled: false), .switchModel(toId: "tier-model"))
        XCTAssertEqual(decide(agentModelDownloaded: false), .switchModel(toId: "tier-model"))
    }

    func testNonFastTierNeverUsesAgent() {
        XCTAssertEqual(decide(isFastTier: false), .switchModel(toId: "tier-model"))
    }

    // MARK: - Auto-routing

    func testSwitchesToTierModelWhenDifferentAndEnabled() {
        XCTAssertEqual(decide(isFastTier: false, tierModelId: "tier-x", activeModelId: "active"),
                       .switchModel(toId: "tier-x"))
    }

    func testKeepsCurrentWhenAutoRoutingOff() {
        XCTAssertEqual(decide(isFastTier: false, autoRoutingEnabled: false), .keepCurrent)
    }

    func testKeepsCurrentWhenTierModelIsAlreadyActive() {
        XCTAssertEqual(decide(isFastTier: false, tierModelId: "same", activeModelId: "same"), .keepCurrent)
    }

    func testKeepsCurrentWhenNoTierModel() {
        XCTAssertEqual(decide(isFastTier: false, tierModelId: nil), .keepCurrent)
    }
}
