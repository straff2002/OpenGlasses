import XCTest
@testable import OpenGlasses

/// Plan GE P3 — the live modes' half of the handoff, and the probe that decides the return.
final class LiveModeHandoffPlannerTests: XCTestCase {

    // MARK: - Losing the session

    func testALiveSessionLostToTheSignalCarriesOnOnThePhone() {
        XCTAssertEqual(LiveModeHandoffPlanner.decideOnLoss(mode: .geminiLive, handoffEnabled: true,
                                                           route: .phone, pathSatisfied: true),
                       .continueOnPhone(resume: .geminiLive))
        XCTAssertEqual(LiveModeHandoffPlanner.decideOnLoss(mode: .openaiRealtime, handoffEnabled: true,
                                                           route: .cloud, pathSatisfied: false),
                       .continueOnPhone(resume: .openaiRealtime))
    }

    func testALossTheNetworkDoesNotExplainEndsAsBefore() {
        XCTAssertEqual(LiveModeHandoffPlanner.decideOnLoss(mode: .geminiLive, handoffEnabled: true,
                                                           route: .cloud, pathSatisfied: true),
                       .endSession, "a provider failure is not fixed by the phone")
    }

    func testOffOrDirectModeEndsAsBefore() {
        XCTAssertEqual(LiveModeHandoffPlanner.decideOnLoss(mode: .geminiLive, handoffEnabled: false,
                                                           route: .phone, pathSatisfied: false), .endSession)
        XCTAssertEqual(LiveModeHandoffPlanner.decideOnLoss(mode: .direct, handoffEnabled: true,
                                                           route: .phone, pathSatisfied: false), .endSession)
    }

    // MARK: - Coming back

    func testTheLostModeResumesOnlyIfTheWearerStayedPut() {
        XCTAssertEqual(LiveModeHandoffPlanner.modeToResume(pending: .geminiLive, currentMode: .direct,
                                                           liveSessionActive: false), .geminiLive)
        XCTAssertNil(LiveModeHandoffPlanner.modeToResume(pending: .geminiLive, currentMode: .openaiRealtime,
                                                         liveSessionActive: false), "they switched")
        XCTAssertNil(LiveModeHandoffPlanner.modeToResume(pending: .geminiLive, currentMode: .direct,
                                                         liveSessionActive: true), "already started")
        XCTAssertNil(LiveModeHandoffPlanner.modeToResume(pending: nil, currentMode: .direct,
                                                         liveSessionActive: false))
    }

    func testTheResumedSessionOpensWithThePhoneTurns() throws {
        let seed = try XCTUnwrap(LiveModeHandoffPlanner.resumeContext(phoneTurns: [
            (role: "user", content: "what's 15% of 80"),
            (role: "assistant", content: "12"),
            (role: "user", content: "and of 120?"),
        ]))
        XCTAssertTrue(seed.hasPrefix(LiveContextHandover.blockHeading))
        XCTAssertTrue(seed.contains("15% of 80"))
        XCTAssertTrue(seed.contains("and of 120?"))
        XCTAssertNil(LiveModeHandoffPlanner.resumeContext(phoneTurns: []))
    }

    // MARK: - The probe

    func testTheProbeTargetsTheCloudModelsOwnOriginOnly() {
        let anthropic = ModelConfig(id: "a", name: "A", provider: LLMProvider.anthropic.rawValue,
                                    apiKey: "secret", model: "m", baseURL: "")
        XCTAssertEqual(ConnectivityProbe.probeURL(for: anthropic)?.absoluteString, "https://api.anthropic.com/")
        let custom = ModelConfig(id: "c", name: "C", provider: LLMProvider.custom.rawValue, apiKey: "",
                                 model: "m", baseURL: "https://llm.example.com:8443/v1/chat/completions?x=1")
        XCTAssertEqual(ConnectivityProbe.probeURL(for: custom)?.absoluteString, "https://llm.example.com:8443/",
                       "no path, no query — nothing about the request leaves")
    }

    func testOnDeviceModelsHaveNothingToProbe() {
        let local = ModelConfig(id: "l", name: "L", provider: LLMProvider.local.rawValue, apiKey: "",
                                model: "mlx-community/gemma-4-e2b-it-4bit", baseURL: "")
        XCTAssertNil(ConnectivityProbe.probeURL(for: local))
        XCTAssertNil(ConnectivityProbe.probeURL(for: nil))
    }

    func testTheProbeRequestCarriesNothing() throws {
        let url = try XCTUnwrap(URL(string: "https://api.anthropic.com/"))
        let request = ConnectivityProbe.request(for: url)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.allHTTPHeaderFields?["Authorization"])
    }

    func testAPrivateHostIsNotProbedButDoesNotStrandTheConversation() async throws {
        let url = try XCTUnwrap(URL(string: "https://192.168.1.10/"))
        let outcome = await ConnectivityProbe.probe(url)
        XCTAssertEqual(outcome, .notProbeable)
        let none = await ConnectivityProbe.probe(nil)
        XCTAssertEqual(none, .notProbeable)
    }

    func testTheProbeRouteIsTelemetryFreeAndOwned() {
        XCTAssertEqual(NetworkRoute.connectivityProbe.dataClasses, [.telemetryFree])
        XCTAssertEqual(NetworkRoute.connectivityProbe.owningTypes, ["ConnectivityProbe"])
        XCTAssertTrue(NetworkRoute.connectivityProbe.medicalPolicy.blocksLocalOnly)
    }

    // MARK: - Routing reads the handoff first

    func testModelRoutingPolicyReadsThePhoneRouteFirst() {
        let route = ModelRoutingPolicy.decide(
            isFastTier: true, agentModeEnabled: true, agentModelDownloaded: true, agentIsCloud: true,
            localAgentEnabled: false, isPhoto: false, autoRoutingEnabled: true,
            tierModelId: "tier", activeModelId: "active", phoneModelId: "local")
        XCTAssertEqual(route, .phoneHandoff(toId: "local"))
        let unchanged = ModelRoutingPolicy.decide(
            isFastTier: false, agentModeEnabled: false, agentModelDownloaded: false, agentIsCloud: true,
            localAgentEnabled: false, isPhoto: false, autoRoutingEnabled: false,
            tierModelId: nil, activeModelId: "active")
        XCTAssertEqual(unchanged, .keepCurrent, "without a phone route nothing changes")
    }
}
