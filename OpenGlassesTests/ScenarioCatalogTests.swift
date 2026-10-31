import XCTest
@testable import OpenGlasses

/// Plan KH P1. Scenarios turn capabilities into situations, and the plan's hardest rule is that one
/// never promises what this phone cannot do. So the names are checked against the real registry,
/// the rules are walked row by row, and the shelf is held to the owner's requirement that nothing
/// on the home screen is permanent.
@MainActor
final class ScenarioCatalogTests: XCTestCase {

    // MARK: - Fixtures

    /// A phone with everything a scenario can name switched on, a cloud model and no glasses: the
    /// starting point each rule below moves one thing away from.
    private var phone: ScenarioContext {
        var context = ScenarioContext()
        context.availableTools = ScenarioCatalog.namedTools
        context.homeControlAvailable = true
        context.myManualsPermitted = true
        context.myManualsHaveContent = true
        context.captionHistoryExists = true
        return context
    }

    private func scenario(_ id: String) throws -> Scenario {
        try XCTUnwrap(ScenarioCatalog.scenario(id: id), "\(id) left the catalogue")
    }

    private func readiness(_ id: String, _ change: (inout ScenarioContext) -> Void = { _ in }) throws -> ScenarioReadiness {
        var context = phone
        change(&context)
        return ScenarioReadiness.evaluate(try scenario(id), in: context)
    }

    /// Tool names from the tools' own declarations, the same way `OfflineToolPolicyTests` does:
    /// some tools are registered by the app with services a headless registry does not have.
    private func declaredToolNames() throws -> Set<String> {
        let directory = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources/Services/NativeTools")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(
            pattern: #"(?:let|var) name(?:: String)? (?:= |\{ *(?:return )?)"([a-z0-9_]+)""#)
        var declared = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let name = Range(match.range(at: 1), in: source) { declared.insert(String(source[name])) }
            }
        }
        return declared
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Every name is real

    func testEveryNamedToolIsDeclaredByARealTool() throws {
        let declared = try declaredToolNames()
        XCTAssertGreaterThan(declared.count, 100, "the scrape found too few tools to be trusted")
        XCTAssertEqual(ScenarioCatalog.namedTools.subtracting(declared).sorted(), [],
                       "a scenario names a tool that does not exist")
    }

    /// The tools a headless registry cannot build are the ones `NativeToolRegistry.init` takes as a
    /// service, or `AppState` registers later. Each is named here with where it comes from, so a
    /// new scenario cannot lean on a tool nothing registers.
    func testEveryNamedToolIsRegistered() throws {
        let headless = Set(NativeToolRegistry(locationService: LocationService()).allTools.map(\.name))
        let wiredElsewhere: [String: String] = [
            "my_memory": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "meeting_summary": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "audio_recording": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "study": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "reading_assist": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "identify_money": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "identify_color": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
            "navigation_assist": "OpenGlasses/Sources/App/OpenGlassesApp.swift",
        ]
        let missing = ScenarioCatalog.namedTools.subtracting(headless).subtracting(wiredElsewhere.keys)
        XCTAssertEqual(missing.sorted(), [], "not registered headless, and not named as wired elsewhere")

        let appState = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/App/OpenGlassesApp.swift"), encoding: .utf8)
        XCTAssertTrue(appState.contains("MyMemoryTool()"), "my_memory is registered by AppState")
        let registry = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift"), encoding: .utf8)
        for type in ["MeetingSummaryTool(", "AudioRecordingTool(", "StudyTool(", "ReadingAccessibilityTool(",
                     "MoneyIdentifierTool(", "ColorIdentifierTool(", "NavigationAssistTool("] {
            XCTAssertTrue(registry.contains(type), "\(type) is no longer registered")
        }
    }

    // MARK: - Ids

    func testIdsAreUnique() {
        let ids = ScenarioCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// `ScenarioProgress` stores these. A rename would hand a person back a card they dismissed, so
    /// each one is pinned here. Additions do not fail this; only a rename or a removal does.
    func testEveryPinnedIdIsStillInTheCatalogue() {
        let pinned = [
            "day-ahead", "add-event", "add-reminder", "quick-note", "what-to-wear", "text-someone",
            "remember-fact", "what-you-know", "remember-person", "remember-object", "play-music",
            "name-that-song", "split-bill", "how-i-slept", "start-workout", "lights", "goal-make",
            "goal-progress", "whats-next", "what-done", "where-it-goes",
            "notice-to-calendar", "bill-to-reminder", "translate-sign", "read-aloud", "whats-this",
            "receipt-note", "card-note", "meal-estimate", "remember-label", "which-note",
            "which-colour", "label-question", "live-coach",
            "where-am-i", "find-nearby", "walk-there", "drive-there", "just-parked",
            "arrive-reminder", "translate-phrase", "local-phrases", "currency", "walk-guide",
            "meeting-prep", "week-ahead", "draft-email", "record-meeting", "meeting-summary",
            "quick-research", "focus-session", "ask-my-manual", "study-deck",
            "field-start-job", "field-ask-vault", "field-nameplate", "field-log-reading",
            "field-van-stock", "field-safety",
        ]
        let ids = Set(ScenarioCatalog.all.map(\.id))
        XCTAssertEqual(pinned.filter { !ids.contains($0) }, [])
    }

    func testIntentAndTopicTokensAreStable() {
        XCTAssertEqual(ScenarioIntent.allCases.map(\.rawValue),
                       ["everyday", "seeing", "gettingAround", "work", "field"])
        for topic in ["calendar", "errands", "travel", "home", "health", "work", "people",
                      "reading", "memory", "goals", "entertainment"] {
            XCTAssertNotNil(ScenarioTopic(rawValue: topic), topic)
        }
    }

    // MARK: - Breadth

    func testTheCatalogueIsBroad() {
        XCTAssertGreaterThanOrEqual(ScenarioCatalog.all.count, 40)
    }

    /// Phone first (Decision 5), and every intent has several things that run on a new phone. The
    /// counting context has glasses off and nothing extra set up.
    func testEveryIntentHasSeveralReadyScenariosWithNoGlasses() {
        var context = ScenarioContext()
        context.availableTools = ScenarioCatalog.namedTools.subtracting(ToolExposureCore.accessibility)
        let ready = ScenarioReadiness.visible(ScenarioCatalog.all, in: context)
            .filter { $0.readiness == .ready }
        for intent in ScenarioIntent.allCases where intent != .field {
            XCTAssertGreaterThanOrEqual(ready.filter { $0.scenario.intent == intent }.count, 4,
                                        "\(intent) has too little that runs on a new phone")
        }
        XCTAssertEqual(ready.filter { $0.scenario.intent == .field }, [], "field needs Field Assist")
    }

    func testFieldAssistBringsReadyFieldScenarios() {
        var context = phone
        context.fieldAssistActive = true
        let ready = ScenarioReadiness.visible(ScenarioCatalog.all, in: context)
            .filter { $0.readiness == .ready && $0.scenario.intent == .field }
        XCTAssertGreaterThanOrEqual(ready.count, 3)
    }

    func testTheGeneralSetNeedsNoGlasses() {
        let general = ScenarioCatalog.all.filter { $0.intent != .field && !$0.needs.contains(.glasses) }
        XCTAssertGreaterThanOrEqual(general.count, 30)
        XCTAssertTrue(ScenarioCatalog.all.filter { $0.needs.contains(.glasses) }.count <= 3,
                      "phone first: glasses scenarios stay the exception")
    }

    func testEveryScenarioHasATopicAndWords() {
        for scenario in ScenarioCatalog.all {
            XCTAssertFalse(scenario.topics.isEmpty, scenario.id)
            XCTAssertFalse(scenario.title.isEmpty, scenario.id)
            XCTAssertFalse(scenario.situation.isEmpty, scenario.id)
            XCTAssertFalse(scenario.prompt.isEmpty, scenario.id)
        }
    }

    func testGoalsAreCoveredByTopicOnly() throws {
        for id in ["goal-make", "goal-progress", "whats-next", "what-done"] {
            XCTAssertTrue(try scenario(id).topics.contains(.goals), id)
        }
        // Topics are data for a later phase: nothing in the scenario code reads them or the stores.
        let directory = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources/Services/Scenarios")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["GoalStore", "ActivityStore", "SemanticMemoryStore", ".topics."] {
                XCTAssertFalse(source.contains(forbidden), "\(file.lastPathComponent) reads \(forbidden)")
            }
        }
    }

    // MARK: - What a prompt must not do

    /// `daily_briefing` refuses while My Day is off, which is the default, so the first thing a new
    /// person tries must not route there.
    func testTheFirstEverydayTurnDoesNotDependOnMyDay() throws {
        let first = try scenario("day-ahead")
        XCTAssertFalse(first.toolNames.contains("daily_briefing"))
        XCTAssertFalse(first.prompt.lowercased().contains("brief"))
    }

    /// `geofence` falls back to the current location with no address, which would arm the reminder
    /// where the wearer is standing.
    func testTheArrivalReminderAsksForAnAddress() throws {
        XCTAssertTrue(try scenario("arrive-reminder").prompt.lowercased().contains("address"))
    }

    func testAnActingToolIsLeftToTheWearer() throws {
        XCTAssertTrue(try scenario("text-someone").prompt.contains("send it myself"))
        XCTAssertTrue(try scenario("draft-email").prompt.contains("send it myself"))
        XCTAssertTrue(try scenario("goal-make").prompt.contains("before you save"))
        XCTAssertTrue(try scenario("lights").prompt.lowercased().hasPrefix("list"))
        XCTAssertTrue(try scenario("record-meeting").prompt.lowercased().hasPrefix("ask me to confirm"))
    }

    func testAScenarioRunsThroughTheGridsSeam() throws {
        let scenario = try scenario("notice-to-calendar")
        let action = scenario.action
        XCTAssertEqual(action.kind, .photoPrompt)
        XCTAssertEqual(action.prompt, scenario.prompt)
        XCTAssertTrue(HomeGridAction.builtIns.allSatisfy { $0.id != action.id })
    }

    // MARK: - Strings

    func testNoStringCarriesAPlanLetter() throws {
        let pattern = try NSRegularExpression(pattern: #"\bPlan [A-Z]{1,2}\b|\bP[0-9]\b"#)
        let intents = ScenarioIntent.allCases.flatMap { [$0.title, $0.subtitle] }
        let steps: [ScenarioSetupStep] = [.chooseModel, .chooseVisionModel, .turnOnTool, .turnOnFeature,
                                          .turnOnMemory, .setUpHome, .addManual, .runCaptions]
        let copy = ScenarioCatalog.all.flatMap { [$0.title, $0.situation, $0.prompt] }
            + intents + steps.map(\.instruction)
        for string in copy {
            let range = NSRange(string.startIndex..., in: string)
            XCTAssertNil(pattern.firstMatch(in: string, range: range), string)
        }
    }

    /// Every word a person sees goes through `String(localized:)`.
    func testCatalogueCopyIsLocalized() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/Services/Scenarios/ScenarioCatalog.swift"), encoding: .utf8)
        let bare = try NSRegularExpression(pattern: #"(title|situation|prompt): ""#)
        XCTAssertNil(bare.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
    }

    func testGeneralCopyDoesNotAssumeGlasses() {
        for scenario in ScenarioCatalog.all where !scenario.needs.contains(.glasses) {
            for text in [scenario.title, scenario.situation, scenario.prompt] {
                XCTAssertFalse(text.lowercased().contains("glasses"), scenario.id)
            }
        }
    }

    // MARK: - Readiness

    func testACleanPhoneIsReady() throws {
        XCTAssertEqual(try readiness("add-event"), .ready)
    }

    func testAClosedToolHidesTheScenario() throws {
        XCTAssertEqual(try readiness("add-event") {
            $0.availableTools.remove("calendar")
            $0.closedTools = ["calendar"]
            // The stored list keeps the person's own choice under a lockdown; closed still wins.
            $0.toolsTurnedOff = ["calendar"]
        }, .hidden)
    }

    func testAToolThePersonTurnedOffIsOneStepAway() throws {
        XCTAssertEqual(try readiness("add-event") {
            $0.availableTools.remove("calendar")
            $0.toolsTurnedOff = ["calendar"]
        }, .needsSetup(.turnOnTool))
    }

    func testAFeatureSwitchedOffIsOneStepAway() throws {
        XCTAssertEqual(try readiness("text-someone") {
            $0.availableTools.remove("send_message")
            $0.featureToolsOff = ["send_message"]
        }, .needsSetup(.turnOnFeature))
    }

    func testAToolThatDoesNotExistHereIsHidden() throws {
        XCTAssertEqual(try readiness("which-note") { $0.availableTools.remove("identify_money") }, .hidden)
    }

    func testGlassesScenariosNeedGlasses() throws {
        XCTAssertEqual(try readiness("live-coach"), .hidden)
        XCTAssertEqual(try readiness("live-coach") { $0.glassesAdded = true }, .ready)
    }

    func testFieldScenariosNeedFieldAssist() throws {
        XCTAssertEqual(try readiness("field-start-job"), .hidden)
        XCTAssertEqual(try readiness("field-start-job") { $0.fieldAssistActive = true }, .ready)
    }

    /// `manual_lookup` refuses in Field Assist with no session, so these wait for a job.
    func testJobScenariosNeedAnOpenJob() throws {
        XCTAssertEqual(try readiness("field-ask-vault") { $0.fieldAssistActive = true }, .hidden)
        XCTAssertEqual(try readiness("field-ask-vault") {
            $0.fieldAssistActive = true
            $0.fieldJobOpen = true
        }, .ready)
    }

    func testMemoryOffIsOneStepAway() throws {
        XCTAssertEqual(try readiness("remember-fact") { $0.memoryOn = false }, .needsSetup(.turnOnMemory))
    }

    func testAPhotoScenarioNeedsAModelThatCanSee() throws {
        XCTAssertEqual(try readiness("read-aloud") { $0.modelCanSee = false }, .needsSetup(.chooseVisionModel))
    }

    func testNoModelIsTheStepForEverything() throws {
        XCTAssertEqual(try readiness("add-event") { $0.hasUsableModel = false }, .needsSetup(.chooseModel))
    }

    func testHomeAndManualsAndCaptionsHaveTheirOwnSteps() throws {
        XCTAssertEqual(try readiness("lights") { $0.homeControlAvailable = false }, .needsSetup(.setUpHome))
        XCTAssertEqual(try readiness("ask-my-manual") { $0.myManualsHaveContent = false }, .needsSetup(.addManual))
        XCTAssertEqual(try readiness("meeting-summary") { $0.captionHistoryExists = false }, .needsSetup(.runCaptions))
    }

    /// A paid feature is not a setup step: a card is not a place to sell one.
    func testManualsWithoutTheEntitlementAreHidden() throws {
        XCTAssertEqual(try readiness("ask-my-manual") { $0.myManualsPermitted = false }, .hidden)
    }

    func testOfflineHidesWhatNeedsTheNetwork() throws {
        var context = phone
        context.isOnline = false
        context.availableTools = ScenarioToolOffer.offered(
            ScenarioCatalog.namedTools, provider: .anthropic, fieldAssistActive: false,
            isOnline: false, libraryHasManuals: false)
        for id in ["what-to-wear", "find-nearby", "currency", "quick-research", "day-ahead"] {
            XCTAssertEqual(ScenarioReadiness.evaluate(try scenario(id), in: context), .hidden, id)
        }
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("read-aloud"), in: context), .hidden,
                       "a cloud model cannot take a photo with no signal")
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("add-event"), in: context), .ready)
    }

    func testAnOnDeviceModelIsOnlyPromisedWhatItIsOffered() throws {
        var context = phone
        context.modelOnDevice = true
        context.availableTools = ScenarioToolOffer.offered(
            ScenarioCatalog.namedTools, provider: .local, fieldAssistActive: false,
            isOnline: true, libraryHasManuals: false)
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("add-event"), in: context), .ready)
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("just-parked"), in: context), .hidden,
                       "parking is not in the on-device tool set")
    }

    func testTheCloudModelCheckFollowsTheProvider() {
        XCTAssertFalse(ScenarioToolOffer.modelCanAnswer(provider: .anthropic, apiKey: " ", baseURL: "",
                                                        accountConnected: false))
        XCTAssertTrue(ScenarioToolOffer.modelCanAnswer(provider: .anthropic, apiKey: "", baseURL: "",
                                                       accountConnected: true))
        XCTAssertFalse(ScenarioToolOffer.modelCanAnswer(provider: .openai, apiKey: "", baseURL: "",
                                                        accountConnected: true))
        XCTAssertTrue(ScenarioToolOffer.modelCanAnswer(provider: .local, apiKey: "", baseURL: "",
                                                       accountConnected: false))
        XCTAssertFalse(ScenarioToolOffer.modelCanAnswer(provider: .custom, apiKey: "x", baseURL: "",
                                                        accountConnected: false))
    }

    // MARK: - HIPAA

    func testHIPAAWithACloudModelHidesEverything() {
        var context = phone
        context.hipaaMode = true
        context.fieldAssistActive = true
        context.fieldJobOpen = true
        XCTAssertEqual(ScenarioReadiness.visible(ScenarioCatalog.all, in: context), [])
    }

    func testHIPAAOnDeviceHidesWhatWouldLeaveThePhone() throws {
        var context = phone
        context.hipaaMode = true
        context.modelOnDevice = true
        for id in ["what-to-wear", "text-someone", "find-nearby", "quick-research", "translate-phrase"] {
            XCTAssertEqual(ScenarioReadiness.evaluate(try scenario(id), in: context), .hidden, id)
        }
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("read-aloud"), in: context), .hidden,
                       "a picture can be a chart")
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("arrive-reminder"), in: context), .hidden,
                       "geocoding an address reaches a third party")
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("ask-my-manual"), in: context), .hidden,
                       "My Manuals is off the table in the mode")
        XCTAssertEqual(ScenarioReadiness.evaluate(try scenario("add-event"), in: context), .ready,
                       "the calendar is on this phone")
    }

    /// Every tool HIPAA switches off must hide its scenario, however a tool list was built.
    func testNothingVisibleUnderHIPAANamesAToolHIPAACloses() {
        var context = phone
        context.hipaaMode = true
        context.modelOnDevice = true
        context.availableTools.subtract(Config.hipaaDisabledTools)
        for entry in ScenarioReadiness.visible(ScenarioCatalog.all, in: context) {
            XCTAssertTrue(entry.scenario.toolNames.isDisjoint(with: Config.hipaaDisabledTools), entry.id)
            XCTAssertEqual(entry.scenario.kind, .prompt, entry.id)
        }
    }

    /// A tool on both HIPAA's list and the person's own is not a step they can take.
    func testATurnedOffToolHIPAACloses() throws {
        var context = phone
        context.hipaaMode = true
        context.modelOnDevice = true
        let closed = Scenario(id: "test", intent: .everyday, title: "t", situation: "s", icon: "i",
                              kind: .prompt, prompt: "p", needs: [.tool("reading_session")], topics: [.reading])
        context.toolsTurnedOff = ["reading_session"]
        // `reading_session` is `.local`, so the only thing hiding it here is HIPAA's own list.
        XCTAssertEqual(ScenarioReadiness.evaluate(closed, in: context), .hidden)
    }

    // MARK: - Simple Mode and locked settings

    func testSimpleModeHidesWhatNeedsASettingsChange() throws {
        XCTAssertEqual(try readiness("remember-fact") {
            $0.memoryOn = false
            $0.simpleMode = true
        }, .hidden)
        XCTAssertEqual(try readiness("add-event") { $0.simpleMode = true }, .ready,
                       "what already works stays")
    }

    func testAStepBehindALockedCategoryIsHidden() throws {
        XCTAssertEqual(try readiness("add-event") {
            $0.availableTools.remove("calendar")
            $0.toolsTurnedOff = ["calendar"]
            $0.unreachableSettings = [.tools]
        }, .hidden)
    }

    func testEveryStepWithADestinationNamesARealCategory() {
        XCTAssertEqual(ScenarioSetupStep.turnOnTool.destination, .tools)
        XCTAssertEqual(ScenarioSetupStep.addManual.destination, .myManuals)
        XCTAssertNil(ScenarioSetupStep.turnOnFeature.destination)
        XCTAssertNil(ScenarioSetupStep.runCaptions.destination)
    }

    // MARK: - The shelf

    private func entries(_ context: ScenarioContext? = nil) -> [ScenarioEntry] {
        ScenarioReadiness.visible(ScenarioCatalog.all, in: context ?? phone)
    }

    func testTheShelfNeverExceedsThree() {
        XCTAssertEqual(ScenarioShelfPolicy.cards(from: entries(), progress: .empty).count, 3)
    }

    func testTheChosenIntentComesFirst() {
        var progress = ScenarioProgress()
        progress.chosenIntent = .gettingAround
        let cards = ScenarioShelfPolicy.cards(from: entries(), progress: progress)
        XCTAssertTrue(cards.allSatisfy { $0.scenario.intent == .gettingAround })
    }

    func testAShortChosenIntentIsFilledFromTheRest() {
        var context = phone
        context.availableTools = ["where_am_i", "calendar"]
        var progress = ScenarioProgress()
        progress.chosenIntent = .gettingAround
        let cards = ScenarioShelfPolicy.cards(from: entries(context), progress: progress)
        XCTAssertEqual(cards.first?.id, "where-am-i")
        XCTAssertEqual(cards.count, 3)
    }

    func testReadyComesBeforeNeedingSetup() {
        var context = phone
        context.availableTools.remove("calendar")
        context.toolsTurnedOff = ["calendar"]
        let cards = ScenarioShelfPolicy.cards(from: entries(context), progress: .empty)
        XCTAssertTrue(cards.allSatisfy { $0.readiness == .ready })
        XCTAssertEqual(cards.first?.id, "add-reminder", "day-ahead and add-event both need the calendar")
    }

    func testNeedsSetupOnlyFillsTheShelfAfterReady() {
        var context = ScenarioContext()
        context.availableTools = ["reminder"]
        context.toolsTurnedOff = ["calendar"]
        // No memory and no sight, so the scenarios that need no tool are not ready either.
        context.memoryOn = false
        context.modelCanSee = false
        let cards = ScenarioShelfPolicy.cards(from: entries(context), progress: .empty)
        XCTAssertEqual(cards.first?.readiness, .ready)
        XCTAssertTrue(cards.dropFirst().contains { $0.readiness == .needsSetup(.turnOnTool) })
    }

    func testAStepWithNowhereToGoIsNotACard() {
        var context = ScenarioContext()
        context.availableTools = ["meeting_summary"]
        XCTAssertEqual(ScenarioShelfPolicy.cards(from: entries(context), progress: .empty)
            .filter { $0.id == "meeting-summary" }, [])
    }

    func testNoModelEmptiesTheShelf() {
        var context = phone
        context.hasUsableModel = false
        XCTAssertEqual(ScenarioShelfPolicy.cards(from: entries(context), progress: .empty), [])
    }

    func testTriedAndDismissedLeaveTheShelf() {
        var progress = ScenarioProgress()
        progress.tried = ["day-ahead"]
        progress.dismissed = ["add-event"]
        let ids = ScenarioShelfPolicy.cards(from: entries(), progress: progress).map(\.id)
        XCTAssertFalse(ids.contains("day-ahead"))
        XCTAssertFalse(ids.contains("add-event"))
        XCTAssertEqual(ids.count, 3)
    }

    func testTheShelfEndsAfterThreeAndStaysEnded() {
        var progress = ScenarioProgress()
        progress.tried = ["day-ahead", "add-event"]
        progress.dismissed = ["add-reminder"]
        XCTAssertTrue(ScenarioShelfPolicy.hasEnded(progress))
        XCTAssertEqual(ScenarioShelfPolicy.cards(from: entries(), progress: progress), [])

        // New scenarios, a changed setting or a retired id must not reopen it.
        progress.tried = ["retired-a", "retired-b"]
        XCTAssertEqual(ScenarioShelfPolicy.cards(from: entries(), progress: progress), [])
    }

    func testTheSameIdTriedAndDismissedCountsOnce() {
        var progress = ScenarioProgress()
        progress.tried = ["day-ahead", "add-event"]
        progress.dismissed = ["day-ahead"]
        XCTAssertFalse(ScenarioShelfPolicy.hasEnded(progress))
    }

    /// The policy has no business ranking by topic yet.
    func testTheShelfIgnoresTopics() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/Services/Scenarios/ScenarioShelfPolicy.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".topics"))
    }

    // MARK: - First run

    func testTheFirstTurnIsAReadyPromptOfTheIntent() throws {
        let turn = try XCTUnwrap(ScenarioFirstRun.firstTurn(for: .everyday, in: phone,
                                                            scenarios: ScenarioCatalog.all))
        XCTAssertEqual(turn.id, "day-ahead")
        XCTAssertEqual(turn.kind, .prompt)
    }

    func testNoFirstTurnWithoutAReadyPrompt() {
        // Seeing is all photos on a phone with no glasses, and a photo needs a camera in hand.
        XCTAssertNil(ScenarioFirstRun.firstTurn(for: .seeing, in: phone, scenarios: ScenarioCatalog.all))
    }

    func testAGlassesScenarioIsNeverAFirstTurn() {
        var context = phone
        context.glassesAdded = true
        XCTAssertNil(ScenarioFirstRun.firstTurn(for: .seeing, in: context, scenarios: ScenarioCatalog.all))
    }

    func testNoFirstTurnWithNoModel() {
        var context = phone
        context.hasUsableModel = false
        XCTAssertNil(ScenarioFirstRun.firstTurn(for: .everyday, in: context, scenarios: ScenarioCatalog.all))
    }

    func testTheFieldFirstTurnIsAJobStartThatAsksFirst() throws {
        var context = phone
        context.fieldAssistActive = true
        let turn = try XCTUnwrap(ScenarioFirstRun.firstTurn(for: .field, in: context,
                                                            scenarios: ScenarioCatalog.all))
        XCTAssertEqual(turn.id, "field-start-job")
        XCTAssertTrue(turn.prompt.contains("Ask me"))
    }

    /// The first prompt of each intent runs from one tap, with nothing else said.
    func testNoFirstTurnActsWithoutAskingOrSavesSomethingWrong() {
        var context = phone
        context.fieldAssistActive = true
        let safe: Set<String> = ["day-ahead", "where-am-i", "meeting-prep", "field-start-job"]
        for intent in ScenarioIntent.allCases {
            guard let turn = ScenarioFirstRun.firstTurn(for: intent, in: context,
                                                        scenarios: ScenarioCatalog.all) else { continue }
            XCTAssertTrue(safe.contains(turn.id), "\(turn.id) would run from one tap")
        }
    }

    func testThePickerIsOnlyForAnOrdinaryFirstRun() {
        XCTAssertTrue(ScenarioFirstRun.showsPicker(isManaged: false, fieldAssistSetUp: false))
        XCTAssertFalse(ScenarioFirstRun.showsPicker(isManaged: true, fieldAssistSetUp: false))
        XCTAssertFalse(ScenarioFirstRun.showsPicker(isManaged: false, fieldAssistSetUp: true))
        XCTAssertFalse(ScenarioIntent.offeredOnReadyPage.contains(.field))
    }

    func testConsumption() throws {
        let scenarios = ScenarioCatalog.all
        let id = "day-ahead"
        XCTAssertEqual(ScenarioFirstRun.consumption(of: nil, pastOnboarding: true, directMode: true, busy: false,
                                                    context: phone, scenarios: scenarios), .wait)
        XCTAssertEqual(ScenarioFirstRun.consumption(of: id, pastOnboarding: false, directMode: true, busy: false,
                                                    context: phone, scenarios: scenarios), .wait)
        XCTAssertEqual(ScenarioFirstRun.consumption(of: id, pastOnboarding: true, directMode: true, busy: false,
                                                    context: phone, scenarios: scenarios),
                       .run(try scenario(id)))
        XCTAssertEqual(ScenarioFirstRun.consumption(of: id, pastOnboarding: true, directMode: false, busy: false,
                                                    context: phone, scenarios: scenarios), .discard)
        XCTAssertEqual(ScenarioFirstRun.consumption(of: "gone", pastOnboarding: true, directMode: true, busy: false,
                                                    context: phone, scenarios: scenarios), .discard)
        var noModel = phone
        noModel.hasUsableModel = false
        XCTAssertEqual(ScenarioFirstRun.consumption(of: id, pastOnboarding: true, directMode: true, busy: false,
                                                    context: noModel, scenarios: scenarios), .discard)
    }

    /// A turn sent while busy is dropped without a word, so it must wait rather than be spent.
    func testABusyAppKeepsTheFirstTurnWaiting() throws {
        let scenarios = ScenarioCatalog.all
        XCTAssertEqual(ScenarioFirstRun.consumption(of: "day-ahead", pastOnboarding: true, directMode: true,
                                                    busy: true, context: phone, scenarios: scenarios), .wait)
        XCTAssertEqual(ScenarioFirstRun.consumption(of: "day-ahead", pastOnboarding: true, directMode: false,
                                                    busy: true, context: phone, scenarios: scenarios), .wait,
                       "busy is looked at first: nothing is thrown away mid-turn")
        XCTAssertEqual(ScenarioFirstRun.consumption(of: "day-ahead", pastOnboarding: true, directMode: true,
                                                    busy: false, context: phone, scenarios: scenarios),
                       .run(try scenario("day-ahead")), "and it runs once the app is free")
    }

    /// The Voice tab is alive under the overlay, so the turn must not be stored before onboarding
    /// has finished, whatever the order updates happen to arrive in.
    func testTheFirstTurnIsStoredAfterOnboardingCompletes() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/App/Views/OnboardingView.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.components(separatedBy: "private func finishReadyPage").last)
        let choose = try XCTUnwrap(body.range(of: "progress.choose(intent)"))
        let complete = try XCTUnwrap(body.range(of: "completeOnboarding()"))
        let pending = try XCTUnwrap(body.range(of: "progress.setPendingFirstTurn"))
        XCTAssertLessThan(choose.lowerBound, complete.lowerBound)
        XCTAssertLessThan(complete.lowerBound, pending.lowerBound)
    }

    // MARK: - Opening on the cards

    private func opens(pager: DockPagerState = DockPagerState(), voiceState: VoiceVisualState = .idle,
                       directMode: Bool = true, onboardingDone: Bool = true, alreadySettled: Bool = false,
                       conversationIsEmpty: Bool = true, hasCards: Bool = true) -> Bool {
        ScenarioShelfPolicy.opensOnConversation(
            pager: pager, voiceState: voiceState, directMode: directMode, onboardingDone: onboardingDone,
            alreadySettled: alreadySettled, conversationIsEmpty: conversationIsEmpty, hasCards: hasCards)
    }

    func testTheTabStartsOnTheConversationOnlyWithCardsToShow() {
        XCTAssertTrue(opens())
        XCTAssertFalse(opens(hasCards: false))
    }

    func testAnEndedShelfLeavesTheGrid() {
        var progress = ScenarioProgress()
        progress.tried = ["day-ahead", "add-event", "add-reminder"]
        let cards = ScenarioShelfPolicy.cards(from: entries(), progress: progress)
        XCTAssertFalse(opens(hasCards: !cards.isEmpty))
        XCTAssertEqual(DockPage.home, .actions, "the resting page itself never changes")
    }

    func testTheWearersOwnMoveAlwaysWins() {
        XCTAssertFalse(opens(pager: DockPagerPolicy.userMoved(DockPagerState(), to: .actions)))
        XCTAssertFalse(opens(pager: DockPagerPolicy.userMoved(DockPagerState(), to: .conversation)))
        XCTAssertFalse(opens(pager: DockPagerPolicy.userMoved(DockPagerState(), toGridPageStartingWith: "tile")))
        // A turn clears `userMovedThisTurn`; the page the wearer chose is still theirs.
        var earlier = DockPagerState()
        earlier.gridAnchor = "tile"
        XCTAssertFalse(opens(pager: earlier))
    }

    func testItHappensAtMostOncePerLaunch() {
        XCTAssertFalse(opens(alreadySettled: true))
    }

    func testNothingMovesDuringATurnARealtimeModeOrAConversation() {
        XCTAssertFalse(opens(voiceState: .thinking))
        XCTAssertFalse(opens(voiceState: .speaking))
        XCTAssertFalse(opens(directMode: false))
        XCTAssertFalse(opens(conversationIsEmpty: false))
        XCTAssertFalse(opens(pager: DockPagerState(page: .conversation)))
        XCTAssertTrue(opens(voiceState: .listening), "the mic being open is not a turn")
    }

    func testNothingMovesUnderOnboarding() {
        XCTAssertFalse(opens(onboardingDone: false))
    }

    func testOpeningKeepsTheGridPageAndGrantsNothing() {
        var state = DockPagerState()
        state.gridAnchor = "tile"
        let opened = DockPagerPolicy.openedForShelf(state)
        XCTAssertEqual(opened.page, .conversation)
        XCTAssertEqual(opened.gridAnchor, "tile")
        XCTAssertFalse(opened.userMovedThisTurn, "it was not the wearer's move")
    }

    func testTheOpeningIsSettledInMemoryOnly() {
        let (store, defaults) = makeStore()
        XCTAssertFalse(store.shelfOpeningSettled)
        store.settleShelfOpening()
        XCTAssertTrue(store.shelfOpeningSettled)
        XCTAssertFalse(ScenarioProgressStore(defaults: defaults).shelfOpeningSettled,
                       "a new launch gets its one chance")
    }

    // MARK: - The spoken answer

    func testTheSpokenAnswerHasOnlyReadyScenariosAndNoToolNames() {
        var context = phone
        context.availableTools.remove("calendar")
        context.toolsTurnedOff = ["calendar"]
        let text = ScenarioSpokenAnswer.text(from: ScenarioReadiness.visible(ScenarioCatalog.all, in: context))
        let dayAhead = ScenarioCatalog.scenario(id: "day-ahead")?.title ?? "missing"
        XCTAssertFalse(text.contains(dayAhead), "it needs setup, so it is not offered")
        XCTAssertTrue(text.contains(ScenarioCatalog.scenario(id: "add-reminder")?.title ?? "missing"))
        for tool in ScenarioCatalog.namedTools where tool.contains("_") {
            XCTAssertFalse(text.contains(tool), tool)
        }
    }

    func testTheSpokenAnswerIsShortEnoughToPickFrom() {
        let text = ScenarioSpokenAnswer.text(from: ScenarioReadiness.visible(ScenarioCatalog.all, in: phone))
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertLessThanOrEqual(lines.count, ScenarioIntent.allCases.count * ScenarioSpokenAnswer.perIntent)
    }

    func testNothingReadyIsSaidPlainly() {
        XCTAssertTrue(ScenarioSpokenAnswer.text(from: []).contains("Nothing is ready"))
    }

    // MARK: - The tool

    func testDiscoverCapabilitiesOffersTheCategory() throws {
        let tool = DiscoverCapabilitiesTool()
        XCTAssertTrue(tool.description.contains("what can you do for me?"))
        XCTAssertTrue(SystemPromptBuilder.summary(tool.description).contains("what can you do for me?"),
                      "the on-demand list keeps only the first sentence")
        let properties = try XCTUnwrap(tool.parametersSchema["properties"] as? [String: Any])
        let category = try XCTUnwrap(properties["category"] as? [String: Any])
        let options = try XCTUnwrap(category["enum"] as? [String])
        XCTAssertTrue(options.contains("scenarios"))
        for existing in ["all", "shortcuts", "apps", "tools", "tasks", "suggest"] {
            XCTAssertTrue(options.contains(existing), existing)
        }
    }

    func testTheCategoryRunsHeadless() async throws {
        let answer = try await DiscoverCapabilitiesTool().execute(args: ["category": "scenarios"])
        XCTAssertTrue(answer.contains("Things to try"))
    }

    func testAnExistingCategoryStillAnswers() async throws {
        let answer = try await DiscoverCapabilitiesTool().execute(args: ["category": "suggest"])
        XCTAssertTrue(answer.contains("How to Suggest Improvements"))
        XCTAssertFalse(answer.contains("Things to try"))
    }

    func testTheQuestionReachesTheToolOnDemandAndInAFieldJob() {
        XCTAssertTrue(ToolExposureCore.names(fieldJobActive: false, accessibilityMode: false)
            .contains("discover_capabilities"))
        XCTAssertTrue(FieldToolProfile.names.contains("discover_capabilities"))
        XCTAssertEqual(OfflineToolPolicy.availability(of: "discover_capabilities"), .local)
    }

    // MARK: - The support report

    func testTheReportLineIsACountFromTheCatalogue() {
        var progress = ScenarioProgress()
        progress.tried = ["day-ahead", "add-event", "retired-id"]
        progress.dismissed = ["lights"]
        progress.chosenIntent = .work
        let ids = ScenarioCatalog.all.map(\.id)
        let line = ScenarioReportLine.line(progress: progress, catalogIDs: ids)
        XCTAssertEqual(line, "Things to try: 2 of \(ids.count)")
        XCTAssertFalse(line.contains("day-ahead"))
    }

    // MARK: - The record

    private func makeStore() -> (ScenarioProgressStore, UserDefaults) {
        let suite = "ScenarioProgressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (ScenarioProgressStore(defaults: defaults), defaults)
    }

    func testTheRecordRoundTrips() {
        let (store, defaults) = makeStore()
        store.markTried("day-ahead")
        store.dismiss("lights")
        store.choose(.work)
        store.setPendingFirstTurn("meeting-prep")

        let reopened = ScenarioProgressStore(defaults: defaults)
        XCTAssertEqual(reopened.progress.tried, ["day-ahead"])
        XCTAssertEqual(reopened.progress.dismissed, ["lights"])
        XCTAssertEqual(reopened.progress.chosenIntent, .work)
        XCTAssertEqual(reopened.progress.pendingFirstTurn, "meeting-prep")
    }

    func testTheRecordErases() {
        let (store, defaults) = makeStore()
        store.markTried("day-ahead")
        store.setPendingFirstTurn("meeting-prep")
        store.deleteAll()
        XCTAssertEqual(store.progress, .empty)
        XCTAssertEqual(ScenarioProgressStore(defaults: defaults).progress, .empty)
    }

    func testAFirstTurnIsTakenOnce() {
        let (store, defaults) = makeStore()
        store.setPendingFirstTurn("day-ahead")
        XCTAssertEqual(store.takePendingFirstTurn(), "day-ahead")
        XCTAssertNil(store.takePendingFirstTurn())
        XCTAssertNil(ScenarioProgressStore(defaults: defaults).takePendingFirstTurn(),
                     "a relaunch must find nothing to fire")
    }

    func testAnUnreadableRecordStartsEmpty() {
        let suite = "ScenarioProgressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "scenarioProgress")
        XCTAssertEqual(ScenarioProgressStore(defaults: defaults).progress, .empty)
    }

    func testTheStoreIsRegistered() {
        let record = SensitiveStore.scenarioProgress.record
        XCTAssertEqual(record.owner, "ScenarioProgressStore")
        XCTAssertEqual(record.subjectLinkage, .wearer)
        XCTAssertEqual(record.deleteAll, .api("ScenarioProgressStore.deleteAll()"))
    }

    // MARK: - The grid's photo rule

    func testThePhotoRuleIsTheGrids() {
        var model = ModelConfig(id: "m", name: "m", provider: LLMProvider.local.rawValue, apiKey: "",
                                model: "m", baseURL: "")
        model.supportsVision = false
        XCTAssertTrue(HomeGridPhotoPolicy.blocksPhoto(activeModel: model))
        model.supportsVision = true
        XCTAssertFalse(HomeGridPhotoPolicy.blocksPhoto(activeModel: model))
        XCTAssertFalse(HomeGridPhotoPolicy.blocksPhoto(activeModel: nil))
    }
}
