import XCTest
@testable import OpenGlasses

final class MedicalLLMRoutingPolicyTests: XCTestCase {
    private func model(_ id: String, provider: LLMProvider, model: String = "model") -> ModelConfig {
        ModelConfig(id: id, name: id, provider: provider.rawValue,
                    apiKey: provider.requiresAPIKey ? "test-key" : "", model: model,
                    baseURL: provider.defaultBaseURL)
    }

    private func decide(
        hipaa: Bool = true,
        localOnly: Bool = true,
        requested: ModelConfig,
        candidates: [ModelConfig] = [],
        usableIDs: Set<String> = []
    ) -> MedicalLLMRoutingPolicy.Decision {
        MedicalLLMRoutingPolicy.decide(
            hipaaMode: hipaa, localOnly: localOnly, requested: requested,
            candidates: candidates, isUsableLocal: { usableIDs.contains($0.id) })
    }

    func testInactivePolicyKeepsCloudProvider() {
        let cloud = model("cloud", provider: .anthropic)
        XCTAssertEqual(decide(hipaa: false, requested: cloud), .use(cloud))
        XCTAssertEqual(decide(localOnly: false, requested: cloud), .use(cloud))
    }

    func testActivePolicyReplacesCloudWithUsableDownloadedLocal() {
        let cloud = model("cloud", provider: .openai)
        let unavailable = model("missing", provider: .local)
        let downloaded = model("downloaded", provider: .local)
        XCTAssertEqual(
            decide(requested: cloud, candidates: [unavailable, downloaded],
                   usableIDs: [downloaded.id]),
            .replaceWithLocal(downloaded))
    }

    func testActivePolicyRefusesCloudWhenNoLocalModelIsUsable() {
        let cloud = model("cloud", provider: .gemini)
        let missing = model("missing", provider: .local)
        XCTAssertEqual(decide(requested: cloud, candidates: [missing]), .refuse)
        XCTAssertTrue(MedicalLLMRoutingPolicy.unavailableMessage.contains("no downloaded on-device model"))
    }

    func testUnusableRequestedLocalCanUseAnotherDownloadedLocal() {
        let missing = model("missing", provider: .local)
        let downloaded = model("downloaded", provider: .local)
        XCTAssertEqual(
            decide(requested: missing, candidates: [missing, downloaded], usableIDs: [downloaded.id]),
            .replaceWithLocal(downloaded))
    }

    func testUsableLocalAndAppleOnDeviceNeverRouteRemote() {
        let local = model("local", provider: .local)
        XCTAssertEqual(decide(requested: local, usableIDs: [local.id]), .use(local))

        let apple = model("apple", provider: .appleOnDevice)
        let cloud = model("cloud", provider: .anthropic)
        XCTAssertEqual(decide(requested: apple, candidates: [cloud]), .use(apple))
    }

    @MainActor
    func testRemoteProviderBoundaryFailsBeforeInference() async {
        let previousHIPAA = Config.hipaaMode
        let previousLocalOnly = Config.hipaaLocalOnly
        defer {
            Config.hipaaMode = previousHIPAA
            Config.hipaaLocalOnly = previousLocalOnly
        }
        Config.hipaaMode = true
        Config.hipaaLocalOnly = true

        do {
            _ = try await LLMService().sendAnthropic(
                "synthetic clinical canary", systemPrompt: "test",
                config: model("cloud", provider: .anthropic),
                includeTools: false, imageData: nil)
            XCTFail("medical local-only policy must reject a direct remote-provider call")
        } catch let LLMError.invalidConfiguration(message) {
            XCTAssertEqual(message, MedicalLLMRoutingPolicy.unavailableMessage)
        } catch {
            XCTFail("expected the medical routing refusal, got \(error)")
        }
    }
}
