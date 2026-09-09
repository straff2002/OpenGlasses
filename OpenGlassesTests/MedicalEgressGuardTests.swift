import XCTest
@testable import OpenGlasses

/// Roadmap W04.2 — the universal local-only rule, decided purely.
final class MedicalEgressGuardTests: XCTestCase {

    private let off = MedicalEgressGuard.Mode.off
    private let localOnly = MedicalEgressGuard.Mode.localOnly
    private let medicalWithoutLocalOnly = MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false)
    private let localOnlyWithoutMedical = MedicalEgressGuard.Mode(hipaaMode: false, localOnly: true)

    func testNothingIsBlockedWhenTheModeIsOff() {
        for route in NetworkRoute.allCases {
            XCTAssertTrue(MedicalEgressGuard.decide(route, mode: off).isAllowed, route.rawValue)
        }
    }

    /// The half-on states are the ones a bug hides in: the flag pair must mean exactly what
    /// `MedicalLLMRoutingPolicy.isEnforced` already means, so the two rules can never disagree.
    func testTheRuleBindsOnlyWhenBothFlagsAreOn() {
        for mode in [medicalWithoutLocalOnly, localOnlyWithoutMedical] {
            XCTAssertFalse(mode.isEnforcing)
            XCTAssertTrue(MedicalEgressGuard.decide(.llmCompletion, mode: mode).isAllowed)
        }
        XCTAssertTrue(localOnly.isEnforcing)
        XCTAssertFalse(MedicalEgressGuard.decide(.llmCompletion, mode: localOnly).isAllowed)
    }

    func testTheGuardAgreesWithTheModelRoutingPolicyAboutWhenItIsEnforcing() {
        for hipaa in [true, false] {
            for local in [true, false] {
                XCTAssertEqual(
                    MedicalEgressGuard.Mode(hipaaMode: hipaa, localOnly: local).isEnforcing,
                    MedicalLLMRoutingPolicy.isEnforced(hipaaMode: hipaa, localOnly: local),
                    "hipaa=\(hipaa) local=\(local)")
            }
        }
    }

    func testEveryBlockedRouteIsRefusedInLocalOnly() {
        for route in NetworkRoute.allCases where route.medicalPolicy.blocksLocalOnly {
            XCTAssertEqual(MedicalEgressGuard.decide(route, mode: localOnly),
                           .refuse(MedicalEgressRefusal(route: route)), route.rawValue)
        }
    }

    func testDocumentedExceptionsStayOpenInLocalOnly() {
        for route in NetworkRoute.allCases where !route.medicalPolicy.blocksLocalOnly {
            XCTAssertTrue(MedicalEgressGuard.decide(route, mode: localOnly).isAllowed, route.rawValue)
        }
        // The exceptions are on-device model acquisition, the loopback OAuth listener, and the
        // operator's own FHIR system. Pin them so widening the set is a deliberate edit.
        let open = NetworkRoute.allCases.filter { !$0.medicalPolicy.blocksLocalOnly }.map(\.rawValue).sorted()
        XCTAssertEqual(open, [
            "asrModelDownload", "conversationRecallSummary", "fhirConnectionTest", "fhirExport",
            "fingerspellingModelDownload", "localModelDownload", "localModelRepositoryMetadata",
            "loopbackOAuthCallback", "ttsVoiceModelDownload"
        ])
    }

    func testCheckThrowsARefusalNamingTheRoute() throws {
        try withMode(localOnly) {
            XCTAssertThrowsError(try MedicalEgressGuard.check(.elevenLabsSpeechSynthesis)) { error in
                guard let refusal = error as? MedicalEgressRefusal else {
                    return XCTFail("expected a MedicalEgressRefusal, got \(error)")
                }
                XCTAssertEqual(refusal.route, .elevenLabsSpeechSynthesis)
                XCTAssertTrue(refusal.description.contains("elevenLabsSpeechSynthesis"))
            }
            XCTAssertNoThrow(try MedicalEgressGuard.check(.localModelDownload))
        }
    }

    /// The refusal a user could see must name the mode, not the route: the wearer needs to know
    /// which setting to change, and the route name is an implementation detail.
    func testTheUserFacingMessageNamesTheSettingAndNotTheRoute() {
        XCTAssertTrue(MedicalEgressRefusal.userMessage.contains("Local Only"))
        for route in NetworkRoute.allCases {
            XCTAssertFalse(MedicalEgressRefusal.userMessage.contains(route.rawValue))
        }
    }

    func testAllowsAndBlocksReadTheLiveMode() {
        withMode(off) {
            XCTAssertTrue(MedicalEgressGuard.allows(.webSearch))
            XCTAssertFalse(MedicalEgressGuard.blocks(.webSearch))
            XCTAssertTrue(MedicalEgressGuard.blockedRoutes.isEmpty)
        }
        withMode(localOnly) {
            XCTAssertFalse(MedicalEgressGuard.allows(.webSearch))
            XCTAssertTrue(MedicalEgressGuard.blocks(.webSearch))
            XCTAssertFalse(MedicalEgressGuard.blockedRoutes.contains(.localModelDownload))
            XCTAssertTrue(MedicalEgressGuard.blockedRoutes.contains(.openClawGatewaySocket))
        }
    }

    // MARK: - Helper

    private func withMode(_ mode: MedicalEgressGuard.Mode, _ body: () throws -> Void) rethrows {
        let previous = MedicalEgressGuard.currentMode
        MedicalEgressGuard.currentMode = { mode }
        defer { MedicalEgressGuard.currentMode = previous }
        try body()
    }
}
