import XCTest
@testable import OpenGlasses

/// Plan HP P1 item 3, as changed by Plan HS P1 item 2 — Social mode (observation-only since Plan HR)
/// is offered wherever the wearer's switch and the Accessibility tier are on, a managed phone and a
/// Field Assist edition included. Scene mode is never refused, and a refused Social request is
/// answered as a scene rather than sent to the model with the Social prompt.
@MainActor
final class AssistiveModePolicyTests: XCTestCase {

    private typealias Policy = AssistiveModePolicy

    private func facts(tier: Bool = true, social: Bool = true) -> Policy.Facts {
        Policy.Facts(accessibilityTierOn: tier, socialSwitchOn: social)
    }

    // MARK: - The rule

    func testAWearerWithTheTierOnIsOfferedSocialMode() {
        XCTAssertEqual(Policy.evaluate(facts()), .offered)
        XCTAssertTrue(Policy.evaluate(facts()).isOffered)
        XCTAssertNil(Policy.evaluate(facts()).refusal)
    }

    func testTheWearersOwnSwitchAndTheTierEachRefuseIt() {
        XCTAssertEqual(Policy.evaluate(facts(social: false)), .notOffered(.turnedOff))
        XCTAssertEqual(Policy.evaluate(facts(tier: false)), .notOffered(.accessibilityTierOff))
        XCTAssertEqual(Policy.evaluate(facts(tier: false, social: false)), .notOffered(.turnedOff),
                       "the switch the wearer moved is the reason given")
    }

    /// Plan HS P1 item 2: the workplace refusals are gone, not merely unreachable.
    func testOnlyTheWearersSwitchAndTheTierRemainAsRefusals() {
        XCTAssertEqual(Set(Policy.Refusal.allCases), [.turnedOff, .accessibilityTierOff])
    }

    // MARK: - Routing

    func testARefusedSocialRequestIsAnsweredAsAScene() {
        XCTAssertEqual(AssistiveRouter.route(transcription: "how is this person feeling",
                                             social: .notOffered(.turnedOff)), .scene)
        XCTAssertEqual(AssistiveRouter.route(transcription: "is he angry?",
                                             social: .notOffered(.accessibilityTierOff)), .scene)
    }

    func testAnOfferedSocialRequestStillGoesToSocial() {
        XCTAssertEqual(AssistiveRouter.route(transcription: "how is this person feeling", social: .offered), .social)
    }

    func testSceneModeIsUnaffectedByTheRefusal() {
        let decisions = [Policy.Decision.offered] + Policy.Refusal.allCases.map { .notOffered($0) }
        for decision in decisions {
            XCTAssertEqual(AssistiveRouter.route(transcription: "describe the room", social: decision), .scene)
            XCTAssertEqual(AssistiveRouter.route(transcription: nil, social: decision), .scene)
        }
    }

    /// The live service routes through the policy and publishes the refusal.
    func testTheServiceRoutesThroughThePolicyAndPublishesTheRefusal() {
        let service = AssistiveModeService.shared
        let savedPolicy = service.socialPolicy
        defer {
            service.socialPolicy = savedPolicy
            service.routeNextAnalysis(transcription: nil)
        }

        service.socialPolicy = { .notOffered(.turnedOff) }
        XCTAssertEqual(service.routeNextAnalysis(transcription: "how is this person feeling"), .scene)
        XCTAssertEqual(service.currentMode, .scene)
        XCTAssertEqual(service.socialRefusal, .turnedOff)

        service.socialPolicy = { .offered }
        XCTAssertEqual(service.routeNextAnalysis(transcription: "how is this person feeling"), .social)
        XCTAssertEqual(service.currentMode, .social)
        XCTAssertNil(service.socialRefusal)
    }

    /// Plan HS P1 item 2: the adapter reads the wearer's switch and the tier, and neither an
    /// organisation profile nor a Field Assist edition refuses Social mode any more.
    func testAManagedPhoneUnderAFieldAssistEditionIsOfferedSocialMode() {
        let keys = ["fieldAssistEnabled", "accessibilityModeEnabled", "assistiveSocialEnabled"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        PolicyEnvelope.clear()
        defer {
            PolicyEnvelope.clear()
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        Config.setFieldAssistEnabled(true)
        Config.setAccessibilityModeEnabled(true)
        Config.assistiveSocialEnabled = true
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: [:])
        PolicyEnvelope.install(ProfileApplier.apply(profile: profile, resolvableVaultIds: []),
                               organizationName: "Northbridge Mechanical")
        XCTAssertTrue(PolicyEnvelope.isManaged)
        XCTAssertTrue(Config.fieldAssistEnabled)

        XCTAssertEqual(Policy.currentFacts(), facts())
        XCTAssertEqual(Policy.current(), .offered)

        Config.assistiveSocialEnabled = false
        XCTAssertEqual(Policy.current(), .notOffered(.turnedOff))
        Config.assistiveSocialEnabled = true
        Config.setAccessibilityModeEnabled(false)
        XCTAssertEqual(Policy.current(), .notOffered(.accessibilityTierOff))
    }

    // MARK: - The inventory

    func testSocialModeIsInTheAIFeatureInventory() {
        let record = AIFeature.assistiveSocial.record
        // Plan HR P1 item 4: observe-only, so screened `.none`, with the reason written down.
        XCTAssertEqual(record.sensitiveCategories, [.none])
        let note = record.screeningNote ?? ""
        XCTAssertTrue(note.contains("Article 3(39)"), "no screening note: \(note)")
        XCTAssertTrue(note.contains("infers no emotional state or intention"), note)
        XCTAssertEqual(record.disableSwitch.key, "assistiveSocialEnabled")
        XCTAssertTrue(record.toolNames.isEmpty, "Social mode is routed to, not called as a tool")
        XCTAssertTrue(record.stores.isEmpty)
        XCTAssertTrue(record.dataRetainedWhenDisabled.lowercased().hasPrefix("nothing"))
    }

    /// Default on, and the face-recognition migration does not touch it.
    func testSocialSwitchDefaultsOnAndTheMigrationLeavesItAlone() {
        let suite = "AssistiveModePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CapabilityDefaultMigration.run(defaults: defaults, faceDatabaseHasEntries: { false })
        XCTAssertNil(defaults.object(forKey: "assistiveSocialEnabled"))

        let saved = UserDefaults.standard.object(forKey: "assistiveSocialEnabled")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "assistiveSocialEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "assistiveSocialEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "assistiveSocialEnabled")
        XCTAssertTrue(Config.assistiveSocialEnabled)
    }
}
