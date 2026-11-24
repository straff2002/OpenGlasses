import XCTest
@testable import OpenGlasses

/// Plan ND P2 — the pages a managed phone's first run walks, the assistants it offers, and the
/// language line. The walk itself, from a fresh install to Ready, is `ManagedOnboardingUITests`.
final class ManagedOnboardingRouteTests: XCTestCase {

    private func inputs(chose: Bool = false, choices: [String]? = ["chatgpt", "local"],
                        glasses: Bool = true) -> ManagedOnboardingPlan.Inputs {
        .init(organisationChoseModel: chose, aiChoices: choices, editionUsesGlasses: glasses)
    }

    // MARK: - The route

    func testAManagedPhoneSkipsTheServicesAndAssistantNamePages() {
        XCTAssertEqual(OnboardingFlow.route(managed: inputs()),
                       [.welcome, .provider, .accessKey, .permissions, .language, .addDevice, .ready])
    }

    func testAPinnedModelSkipsTheAssistantPages() {
        XCTAssertEqual(OnboardingFlow.route(managed: inputs(chose: true)),
                       [.welcome, .permissions, .language, .addDevice, .ready])
    }

    func testACopyWithoutGlassesAsksNothingAboutDevices() {
        XCTAssertEqual(OnboardingFlow.route(managed: inputs(chose: true, glasses: false)),
                       [.welcome, .permissions, .language, .ready])
    }

    func testAProfileFromBeforeNDStillGetsTheProviderPages() {
        XCTAssertEqual(OnboardingFlow.route(managed: inputs(choices: nil)),
                       [.welcome, .provider, .accessKey, .permissions, .language, .addDevice, .ready])
    }

    func testBackAndForwardFollowTheRoute() {
        let route = OnboardingFlow.route(managed: inputs(chose: true))
        XCTAssertEqual(OnboardingFlow.page(after: .welcome, in: route), .permissions)
        XCTAssertEqual(OnboardingFlow.page(before: .permissions, in: route), .welcome)
        XCTAssertEqual(OnboardingFlow.page(before: .welcome, in: route), .welcome)
        XCTAssertNil(OnboardingFlow.page(after: .ready, in: route))
    }

    /// The profile came into force while a page it removes was showing: forward goes on from the
    /// first page after Welcome rather than stranding the person.
    func testAPageTheRouteDropsLeadsToTheStartOfTheRoute() {
        let route = OnboardingFlow.route(managed: inputs(chose: true))
        XCTAssertEqual(OnboardingFlow.page(after: .services, in: route), .permissions)
        XCTAssertEqual(OnboardingFlow.page(before: .services, in: route), .welcome)
    }

    // MARK: - What the assistant page offers

    func testOnlyTheChoicesThisPhoneCanRunAreOffered() {
        XCTAssertEqual(ManagedOnboardingPlan.offered(choices: ["chatgpt", "local"], appleIntelligence: false, localModel: true),
                       [.chatgpt, .local])
        XCTAssertEqual(ManagedOnboardingPlan.offered(choices: ["chatgpt", "local"], appleIntelligence: true, localModel: false),
                       [.chatgpt], "a phone that cannot download the model is not offered it")
        XCTAssertEqual(ManagedOnboardingPlan.offered(choices: ["appleOnDevice"], appleIntelligence: true, localModel: false),
                       [.appleOnDevice])
    }

    func testNothingToOfferFallsBackToTheFullList() {
        XCTAssertNil(ManagedOnboardingPlan.offered(choices: ["local"], appleIntelligence: false, localModel: false),
                     "a page with nothing to pick is never shown")
        XCTAssertNil(ManagedOnboardingPlan.offered(choices: nil, appleIntelligence: true, localModel: true))
        XCTAssertNil(ManagedOnboardingPlan.offered(choices: [], appleIntelligence: true, localModel: true))
    }

    // MARK: - The language line

    func testTheLineSaysLikeYourPhoneOnlyWhenItIs() {
        let same = OnboardingLanguage.line(appLanguage: "en", phoneLanguages: ["en-NZ", "mi"])
        XCTAssertEqual(same.languageName, "English")
        XCTAssertTrue(same.matchesPhone, "a regional variant of the same language is the phone's language")

        let chosen = OnboardingLanguage.line(appLanguage: "de", phoneLanguages: ["en-NZ"])
        XCTAssertEqual(chosen.languageName, "Deutsch", "named in its own language")
        XCTAssertFalse(chosen.matchesPhone, "the person chose another language for this app")
    }

    func testNoPhoneLanguagesNeverClaimsAMatch() {
        XCTAssertFalse(OnboardingLanguage.line(appLanguage: "en", phoneLanguages: []).matchesPhone)
    }
}
