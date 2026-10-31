import XCTest
@testable import OpenGlasses

/// Plan KH P1. The Voice tab's "Things to try" card is how anyone with a restored conversation
/// reaches the scenarios. It is held here to the owner's rule that nothing on the home screen is
/// permanent, and to the store's: a dropped turn never counts as tried.
@MainActor
final class ScenarioIntroCardTests: XCTestCase {

    // MARK: - Fixtures

    private var phone: ScenarioContext {
        var context = ScenarioContext()
        context.availableTools = ScenarioCatalog.namedTools
        context.homeControlAvailable = true
        context.myManualsPermitted = true
        context.myManualsHaveContent = true
        context.captionHistoryExists = true
        return context
    }

    private func entries(_ context: ScenarioContext? = nil) -> [ScenarioEntry] {
        ScenarioReadiness.visible(ScenarioCatalog.all, in: context ?? phone)
    }

    private func entry(_ id: String, in context: ScenarioContext? = nil) throws -> ScenarioEntry {
        try XCTUnwrap(entries(context).first { $0.id == id }, "\(id) is not visible")
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ScenarioIntroCardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func shows(progress: ScenarioProgress = .empty, counted: Bool = false,
                       pastOnboarding: Bool = true, directMode: Bool = true, surfaceFree: Bool = true,
                       hasOffer: Bool = true, conversationIsEmpty: Bool = false) -> Bool {
        ScenarioIntroCard.shows(progress: progress, countedThisLaunch: counted,
                                pastOnboarding: pastOnboarding, directMode: directMode,
                                surfaceFree: surfaceFree, hasOffer: hasOffer,
                                conversationIsEmpty: conversationIsEmpty)
    }

    private func shows(_ store: ScenarioProgressStore) -> Bool {
        shows(progress: store.progress, counted: store.introCardCountedThisLaunch)
    }

    /// What the current build writes: none of the card's fields.
    private let recordFromTheLastBuild = #"""
        {"tried":["day-ahead"],"dismissed":["lights"],"chosenIntent":"work","pendingFirstTurn":"meeting-prep"}
        """#

    // MARK: - Who sees it

    func testItShowsAfterAnUpdateWithARestoredConversation() {
        let defaults = makeDefaults()
        defaults.set(Data(recordFromTheLastBuild.utf8), forKey: "scenarioProgress")
        let store = ScenarioProgressStore(defaults: defaults)
        let page = ConversationContinuity.pageContent(
            activeThreadId: "restored", activeThreadMessageCount: 12, isRealtimeSession: false,
            hasLiveUserText: false, hasLiveAssistantText: false)
        XCTAssertEqual(page, .history(threadId: "restored"))
        XCTAssertTrue(shows(progress: store.progress, conversationIsEmpty: page == .empty))
    }

    func testAnUpdateFromBeforeOnboardingExistedIsPastIt() {
        XCTAssertTrue(Config.isPastOnboarding(hasCompletedOnboarding: false, hasAnyAPIKey: true),
                      "the card goes by this, not by the completed flag such a phone never set")
    }

    func testANewUserMeetsItOnceAConversationExists() {
        XCTAssertFalse(shows(conversationIsEmpty: true))
        let page = ConversationContinuity.pageContent(
            activeThreadId: nil, activeThreadMessageCount: 0, isRealtimeSession: false,
            hasLiveUserText: true, hasLiveAssistantText: true)
        XCTAssertTrue(shows(conversationIsEmpty: page == .empty),
                      "with history off, the turn on screen is the conversation")
    }

    func testItNeverAppearsUnderOnboarding() {
        XCTAssertFalse(shows(pastOnboarding: false))
    }

    func testItYieldsToALiveTurnAndToCaptions() {
        for state in [VoiceVisualState.thinking, .speaking] {
            XCTAssertFalse(shows(surfaceFree: HomeSurfaceVisibility.showsMyDay(state: state, captionsActive: false)))
        }
        XCTAssertFalse(shows(surfaceFree: HomeSurfaceVisibility.showsMyDay(state: .idle, captionsActive: true)))
        XCTAssertTrue(shows(surfaceFree: HomeSurfaceVisibility.showsMyDay(state: .idle, captionsActive: false)))
        XCTAssertTrue(shows(surfaceFree: HomeSurfaceVisibility.showsMyDay(state: .listening, captionsActive: false)),
                      "the mic being open is not a turn")
    }

    func testItIsDirectModeOnly() {
        for mode in [AppMode.geminiLive, .openaiRealtime, .openaiCompatibleRealtime] {
            XCTAssertFalse(shows(directMode: HomeSurfaceVisibility.showsActionTiles(mode: mode)))
        }
        XCTAssertTrue(shows(directMode: HomeSurfaceVisibility.showsActionTiles(mode: .direct)))
    }

    func testTheShelfAndTheCardAreNeverUpTogether() {
        let page = ConversationContinuity.pageContent(
            activeThreadId: nil, activeThreadMessageCount: 0, isRealtimeSession: false,
            hasLiveUserText: false, hasLiveAssistantText: false)
        XCTAssertEqual(page, .empty, "the only state the shelf draws in")
        XCTAssertFalse(ScenarioShelfPolicy.cards(from: entries(), progress: .empty).isEmpty)
        XCTAssertFalse(shows(conversationIsEmpty: page == .empty))
    }

    /// With something in the sheet the shelf has cards too, so an empty conversation is never left
    /// with nothing, on either kind of phone.
    func testAnythingTheSheetOffersTheShelfCanShow() {
        var field = phone
        field.fieldAssistActive = true
        for (context, showsPicker) in [(phone, true), (field, false)] {
            XCTAssertTrue(ScenarioIntroCard.hasOffer(from: entries(context), progress: .empty,
                                                     showsPicker: showsPicker))
            XCTAssertFalse(ScenarioShelfPolicy.cards(from: entries(context), progress: .empty).isEmpty)
        }
    }

    func testACardThatWouldOpenOnNothingDoesNotShow() {
        var context = phone
        context.hasUsableModel = false
        XCTAssertFalse(ScenarioIntroCard.hasOffer(from: entries(context), progress: .empty, showsPicker: true))
        XCTAssertFalse(shows(hasOffer: false))
    }

    // MARK: - It goes away

    func testTheXRemovesItForGood() {
        let defaults = makeDefaults()
        let store = ScenarioProgressStore(defaults: defaults)
        XCTAssertTrue(shows(store))
        store.dismissIntroCard()
        XCTAssertFalse(shows(store))
        XCTAssertFalse(shows(ScenarioProgressStore(defaults: defaults)), "a relaunch keeps it gone")
    }

    func testTheXSpendsNoneOfTheShelf() {
        let store = ScenarioProgressStore(defaults: makeDefaults())
        store.dismissIntroCard()
        XCTAssertFalse(ScenarioShelfPolicy.hasEnded(store.progress))
        XCTAssertEqual(store.progress.triedOrDismissed, [])
    }

    func testItEndsWithTheShelf() {
        var progress = ScenarioProgress()
        progress.tried = ["day-ahead", "add-event"]
        XCTAssertTrue(shows(progress: progress))
        progress.dismissed = ["add-reminder"]
        XCTAssertFalse(shows(progress: progress))
    }

    func testItRetiresAfterFiveShownLaunchesNotFewer() {
        let defaults = makeDefaults()
        for launch in 1...ScenarioIntroCard.shownLaunchLimit {
            let store = ScenarioProgressStore(defaults: defaults)
            XCTAssertTrue(shows(store), "launch \(launch) shows it")
            store.noteIntroCardShown()
            XCTAssertEqual(store.progress.introCardShownLaunches, launch)
            XCTAssertTrue(shows(store), "launch \(launch) keeps it once counted")
        }
        XCTAssertFalse(shows(ScenarioProgressStore(defaults: defaults)), "the sixth does not")
        XCTAssertEqual(ScenarioIntroCard.shownLaunchLimit, 5)
    }

    func testALaunchThatDidNotShowItIsNotCounted() {
        let defaults = makeDefaults()
        for _ in 1...20 { _ = ScenarioProgressStore(defaults: defaults) }
        XCTAssertEqual(ScenarioProgressStore(defaults: defaults).progress.introCardShownLaunches, 0)
    }

    func testAProcessCountsOnce() {
        let defaults = makeDefaults()
        let store = ScenarioProgressStore(defaults: defaults)
        for _ in 1...4 { store.noteIntroCardShown() }
        XCTAssertEqual(store.progress.introCardShownLaunches, 1)
        XCTAssertEqual(ScenarioProgressStore(defaults: defaults).progress.introCardShownLaunches, 1,
                       "on disk, so it survives the launch")
    }

    func testTheCountsErase() {
        let defaults = makeDefaults()
        let store = ScenarioProgressStore(defaults: defaults)
        store.noteIntroCardShown()
        store.dismissIntroCard()
        store.deleteAll()
        XCTAssertEqual(ScenarioProgressStore(defaults: defaults).progress, .empty)
    }

    // MARK: - The record

    func testARecordFromTheLastBuildDecodes() throws {
        let progress = try JSONDecoder().decode(ScenarioProgress.self, from: Data(recordFromTheLastBuild.utf8))
        XCTAssertEqual(progress.tried, ["day-ahead"])
        XCTAssertEqual(progress.dismissed, ["lights"])
        XCTAssertEqual(progress.chosenIntent, .work)
        XCTAssertEqual(progress.pendingFirstTurn, "meeting-prep")
        XCTAssertFalse(progress.introCardDismissed)
        XCTAssertEqual(progress.introCardShownLaunches, 0)
    }

    /// The failure this guards against is quiet: the store reads a record it cannot decode as empty,
    /// so a finished shelf would come back.
    func testAnEndedShelfFromTheLastBuildStaysEnded() {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"tried":["a","b"],"dismissed":["c"]}"#.utf8), forKey: "scenarioProgress")
        let store = ScenarioProgressStore(defaults: defaults)
        XCTAssertTrue(ScenarioShelfPolicy.hasEnded(store.progress))
        XCTAssertFalse(shows(store))
    }

    func testTheNewFieldsRoundTrip() throws {
        var progress = ScenarioProgress()
        progress.introCardDismissed = true
        progress.introCardShownLaunches = 3
        let decoded = try JSONDecoder().decode(ScenarioProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(decoded, progress)
    }

    // MARK: - The sheet

    func testManagedAndFieldAssistPhonesGetNoPickerAndTheFieldSet() {
        XCTAssertFalse(ScenarioFirstRun.showsPicker(isManaged: true, fieldAssistSetUp: false))
        XCTAssertFalse(ScenarioFirstRun.showsPicker(isManaged: false, fieldAssistSetUp: true))
        XCTAssertEqual(ScenarioIntroCard.intent(showsPicker: false, chosen: nil), .field)
        XCTAssertEqual(ScenarioIntroCard.intent(showsPicker: false, chosen: .work), .field,
                       "an earlier choice does not bring the picker's set back")

        var context = phone
        context.fieldAssistActive = true
        let cards = ScenarioIntroCard.scenarios(for: .field, from: entries(context), progress: .empty)
        XCTAssertFalse(cards.isEmpty)
        XCTAssertTrue(cards.allSatisfy { $0.scenario.intent == .field })
    }

    func testThePickerWaitsForAChoiceAndOnlyTakesWhatItOffers() {
        XCTAssertNil(ScenarioIntroCard.intent(showsPicker: true, chosen: nil))
        XCTAssertEqual(ScenarioIntroCard.intent(showsPicker: true, chosen: .seeing), .seeing)
        XCTAssertNil(ScenarioIntroCard.intent(showsPicker: true, chosen: .field), "not one of the choices")
    }

    func testTheChoiceIsRecorded() {
        let defaults = makeDefaults()
        ScenarioProgressStore(defaults: defaults).choose(.gettingAround)
        XCTAssertEqual(ScenarioIntroCard.intent(
            showsPicker: true, chosen: ScenarioProgressStore(defaults: defaults).progress.chosenIntent),
                       .gettingAround)
    }

    func testEachChoiceOffersUpToThreeOfItsOwnAndNoneSpent() throws {
        for intent in ScenarioIntent.offeredOnReadyPage {
            let cards = ScenarioIntroCard.scenarios(for: intent, from: entries(), progress: .empty)
            XCTAssertFalse(cards.isEmpty, intent.rawValue)
            XCTAssertLessThanOrEqual(cards.count, ScenarioShelfPolicy.maximumCards)
            XCTAssertTrue(cards.allSatisfy { $0.scenario.intent == intent })
        }
        let first = try XCTUnwrap(ScenarioIntroCard.scenarios(for: .work, from: entries(), progress: .empty).first)
        var progress = ScenarioProgress()
        progress.dismissed = [first.id]
        XCTAssertFalse(ScenarioIntroCard.scenarios(for: .work, from: entries(), progress: progress)
            .contains { $0.id == first.id })
    }

    // MARK: - A tap

    func testADroppedTurnIsNotMarkedTried() throws {
        let defaults = makeDefaults()
        let store = ScenarioProgressStore(defaults: defaults)
        let card = try entry("add-reminder")
        XCTAssertEqual(card.readiness, .ready)

        XCTAssertEqual(store.begin(card, acceptsTurn: false), .nothing)
        XCTAssertEqual(store.progress.tried, [])
        XCTAssertEqual(ScenarioProgressStore(defaults: defaults).progress.tried, [])
    }

    func testAnAcceptedTurnIsMarkedTried() throws {
        let store = ScenarioProgressStore(defaults: makeDefaults())
        XCTAssertEqual(store.begin(try entry("add-reminder"), acceptsTurn: true), .run)
        XCTAssertEqual(store.progress.tried, ["add-reminder"])
    }

    func testASetupStepOpensSettingsAndIsNotTried() throws {
        var context = phone
        context.availableTools.remove("calendar")
        context.toolsTurnedOff = ["calendar"]
        let store = ScenarioProgressStore(defaults: makeDefaults())
        let card = try entry("day-ahead", in: context)
        XCTAssertEqual(card.readiness, .needsSetup(.turnOnTool))
        XCTAssertEqual(store.begin(card, acceptsTurn: true), .openSettings(.tools))
        XCTAssertEqual(store.progress.tried, [])
    }

    func testAStepWithNowhereToGoDoesNothing() throws {
        let scenario = try XCTUnwrap(ScenarioCatalog.scenario(id: "day-ahead"))
        let card = ScenarioEntry(scenario: scenario, readiness: .needsSetup(.turnOnFeature))
        XCTAssertEqual(ScenarioCardTap.resolve(card, acceptsTurn: true), .nothing)
    }
}
