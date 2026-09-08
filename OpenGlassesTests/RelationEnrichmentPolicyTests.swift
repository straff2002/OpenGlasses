import XCTest
@testable import OpenGlasses

/// Tests for the gate on the one place the brain sends the wearer's words off the device.
/// Four conditions, all required, each with its own named refusal — a feature that silently does
/// nothing is indistinguishable from a broken one, and this is the gate that decides.
final class RelationEnrichmentPolicyTests: XCTestCase {

    /// The only combination that runs: Agent Mode on, the wearer's own switch on, HIPAA off, and
    /// a provider that isn't the phone.
    func testRunsOnlyWhenAllFourConditionsAreMet() {
        XCTAssertEqual(
            RelationEnrichmentPolicy.decide(agentMode: true, enrichmentEnabled: true,
                                            hipaaMode: false, provider: .anthropic),
            .run)
    }

    /// Agent Mode is the wide permission everything autonomous lives behind; without it the
    /// narrow switch means nothing.
    func testAgentModeOffIsItsOwnRefusal() {
        XCTAssertEqual(
            RelationEnrichmentPolicy.decide(agentMode: false, enrichmentEnabled: true,
                                            hipaaMode: false, provider: .anthropic).skipReason,
            .agentModeOff)
    }

    /// Agent Mode alone does not buy this: sending turn text to a provider is asked for
    /// separately, and defaults to off.
    func testEnrichmentFlagOffIsItsOwnRefusal() {
        XCTAssertEqual(
            RelationEnrichmentPolicy.decide(agentMode: true, enrichmentEnabled: false,
                                            hipaaMode: false, provider: .anthropic).skipReason,
            .enrichmentDisabled)
    }

    /// Under HIPAA the brain keeps working; it is only the cloud pass that stops.
    func testHIPAAModeIsItsOwnRefusal() {
        XCTAssertEqual(
            RelationEnrichmentPolicy.decide(agentMode: true, enrichmentEnabled: true,
                                            hipaaMode: true, provider: .anthropic).skipReason,
            .hipaaMode)
    }

    /// The on-device exclusion is not a preference the flag can express: local inference cannot
    /// run backgrounded, and this pass fires at the end of a voice turn. With every flag set the
    /// way the wearer wants, the *provider* is what refuses.
    func testOnDeviceProvidersAreRefusedByProviderNotByFlag() {
        for provider in [LLMProvider.local, .appleOnDevice] {
            XCTAssertEqual(
                RelationEnrichmentPolicy.decide(agentMode: true, enrichmentEnabled: true,
                                                hipaaMode: false, provider: provider).skipReason,
                .onDeviceProvider,
                "\(provider.rawValue) must be refused for being on-device")
        }
    }

    /// A phone with no model configured has nothing to ask, and says so rather than reporting a
    /// condition the wearer could act on.
    func testNoConfiguredProviderIsItsOwnRefusal() {
        XCTAssertEqual(
            RelationEnrichmentPolicy.decide(agentMode: true, enrichmentEnabled: true,
                                            hipaaMode: false, provider: nil).skipReason,
            .noProvider)
    }

    /// Every cloud provider the app can be pointed at is allowed: the gate is about where
    /// inference runs, not about which vendor it is.
    func testEveryCloudProviderIsAllowed() {
        for provider in LLMProvider.allCases where !RelationEnrichmentPolicy.isOnDevice(provider) {
            XCTAssertTrue(
                RelationEnrichmentPolicy.decide(agentMode: true, enrichmentEnabled: true,
                                                hipaaMode: false, provider: provider).runs,
                "\(provider.rawValue) is a cloud provider and should be allowed")
        }
    }

    /// A refusal is logged only when the wearer asked for the feature and still did not get it.
    /// The feature simply being off is not a fault to report, and reporting it would cost a
    /// privacy-log line per turn for every wearer who never switched it on.
    func testOnlyRefusalsTheWearerAskedForAreWorthLogging() {
        for reason in [RelationEnrichmentPolicy.SkipReason.agentModeOff, .enrichmentDisabled] {
            XCTAssertFalse(reason.isWorthLogging,
                           "\(reason.rawValue) means the feature is off, which is not worth a line")
        }
        for reason in [RelationEnrichmentPolicy.SkipReason.hipaaMode, .onDeviceProvider, .noProvider] {
            XCTAssertTrue(reason.isWorthLogging,
                          "\(reason.rawValue) refuses a feature the wearer turned on, so it must say so")
        }
    }
}
