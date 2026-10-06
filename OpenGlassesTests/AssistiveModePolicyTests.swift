import XCTest
@testable import OpenGlasses

/// Plan HP P1 item 3 — Social mode (emotional-state inference) is never offered where the app is a
/// work tool, Scene mode is never refused, and a refused Social request is answered as a scene
/// rather than sent to the model with the emotion prompt.
@MainActor
final class AssistiveModePolicyTests: XCTestCase {

    private typealias Policy = AssistiveModePolicy

    private func facts(managed: Bool = false, fieldAssist: Bool = false, tier: Bool = true,
                       social: Bool = true) -> Policy.Facts {
        Policy.Facts(organisationManaged: managed, fieldAssistEditionActive: fieldAssist,
                     accessibilityTierOn: tier, socialSwitchOn: social)
    }

    // MARK: - The rule

    func testAPersonalWearerWithTheTierOnIsOfferedSocialMode() {
        XCTAssertEqual(Policy.evaluate(facts()), .offered)
        XCTAssertTrue(Policy.evaluate(facts()).isOffered)
        XCTAssertNil(Policy.evaluate(facts()).refusal)
    }

    func testAManagedPhoneIsNeverOfferedSocialMode() {
        for fieldAssist in [false, true] {
            for tier in [false, true] {
                for social in [false, true] {
                    XCTAssertEqual(Policy.evaluate(facts(managed: true, fieldAssist: fieldAssist, tier: tier,
                                                         social: social)),
                                   .notOffered(.organisationManaged))
                }
            }
        }
    }

    func testAFieldAssistEditionIsNeverOfferedSocialMode() {
        for tier in [false, true] {
            for social in [false, true] {
                XCTAssertEqual(Policy.evaluate(facts(fieldAssist: true, tier: tier, social: social)),
                               .notOffered(.fieldAssistEdition))
            }
        }
    }

    func testTheWearersOwnSwitchAndTheTierEachRefuseIt() {
        XCTAssertEqual(Policy.evaluate(facts(social: false)), .notOffered(.turnedOff))
        XCTAssertEqual(Policy.evaluate(facts(tier: false)), .notOffered(.accessibilityTierOff))
    }

    // MARK: - Routing

    func testARefusedSocialRequestIsAnsweredAsAScene() {
        let refused = Policy.Decision.notOffered(.organisationManaged)
        XCTAssertEqual(AssistiveRouter.route(transcription: "how is this person feeling", social: refused), .scene)
        XCTAssertEqual(AssistiveRouter.route(transcription: "is he angry?", social: .notOffered(.fieldAssistEdition)),
                       .scene)
        XCTAssertEqual(AssistiveRouter.route(transcription: "read their emotion", social: .notOffered(.turnedOff)),
                       .scene)
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

    /// The live service routes through the policy and publishes the refusal for the UI to explain.
    func testTheServiceRoutesThroughThePolicyAndPublishesTheRefusal() {
        let service = AssistiveModeService.shared
        let savedPolicy = service.socialPolicy
        defer {
            service.socialPolicy = savedPolicy
            service.routeNextAnalysis(transcription: nil)
        }

        service.socialPolicy = { .notOffered(.organisationManaged) }
        XCTAssertEqual(service.routeNextAnalysis(transcription: "how is this person feeling"), .scene)
        XCTAssertEqual(service.currentMode, .scene)
        XCTAssertEqual(service.socialRefusal, .organisationManaged)

        service.socialPolicy = { .offered }
        XCTAssertEqual(service.routeNextAnalysis(transcription: "how is this person feeling"), .social)
        XCTAssertEqual(service.currentMode, .social)
        XCTAssertNil(service.socialRefusal)
    }

    /// The adapter reads the organisation envelope and the edition switch the policy is about.
    func testCurrentFactsReadTheEnvelopeAndTheEdition() {
        PolicyEnvelope.clear()
        let savedEdition = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        defer {
            PolicyEnvelope.clear()
            if let savedEdition { UserDefaults.standard.set(savedEdition, forKey: "fieldAssistEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        }

        Config.setFieldAssistEnabled(true)
        XCTAssertTrue(Policy.currentFacts().fieldAssistEditionActive)
        Config.setFieldAssistEnabled(false)
        XCTAssertFalse(Policy.currentFacts().fieldAssistEditionActive)

        XCTAssertFalse(Policy.currentFacts().organisationManaged)
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: [:])
        PolicyEnvelope.install(ProfileApplier.apply(profile: profile, resolvableVaultIds: []),
                               organizationName: "Northbridge Mechanical")
        XCTAssertTrue(Policy.currentFacts().organisationManaged)
        XCTAssertEqual(Policy.current(), .notOffered(.organisationManaged))
    }

    // MARK: - The inventory

    func testSocialModeIsInTheAIFeatureInventory() {
        let record = AIFeature.assistiveSocial.record
        // Plan HR P1 item 4: observe-only, so screened `.none`, with the reason written down.
        XCTAssertEqual(record.sensitiveCategories, [.none])
        let note = record.screeningNote ?? ""
        XCTAssertTrue(note.contains("Article 3(39)"), "no screening note: \(note)")
        XCTAssertTrue(note.contains("infers no emotional state or intention"), note)
        // The workplace refusals stay in this plan: the policy is unchanged.
        XCTAssertEqual(Policy.evaluate(facts(managed: true)), .notOffered(.organisationManaged))
        XCTAssertEqual(Policy.evaluate(facts(fieldAssist: true)), .notOffered(.fieldAssistEdition))
        XCTAssertEqual(record.disableSwitch.key, "assistiveSocialEnabled")
        XCTAssertTrue(record.toolNames.isEmpty, "Social mode is routed to, not called as a tool")
        XCTAssertTrue(record.stores.isEmpty)
        XCTAssertTrue(record.dataRetainedWhenDisabled.lowercased().hasPrefix("nothing"))
    }

    /// Default on for personal users, and the face-recognition migration does not touch it.
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
