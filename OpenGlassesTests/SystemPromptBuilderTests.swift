import XCTest
@testable import OpenGlasses

/// Plan BG P1 (docs/plans/BG-spine-refactor.md): the system-prompt tool list is generated from each
/// NativeTool's own description, so it can't drift from the real tool set or between Direct Mode and
/// Gemini Live.
@MainActor
final class SystemPromptBuilderTests: XCTestCase {

    func testToolLinesRenderNameAndDescription() {
        let out = SystemPromptBuilder.toolLines([
            ("get_weather", "Get current weather."),
            ("calculate", "Evaluate math expressions."),
        ])
        XCTAssertEqual(out, "- get_weather: Get current weather.\n- calculate: Evaluate math expressions.")
    }

    func testMultilineDescriptionIsFlattened() {
        let out = SystemPromptBuilder.toolLines([
            ("brain", "Unified search.\n  action 'query' for facts.\n  action 'recall' for conversations."),
        ])
        XCTAssertEqual(out, "- brain: Unified search. action 'query' for facts. action 'recall' for conversations.")
        XCTAssertFalse(out.contains("\n  "), "internal newlines/indentation must be collapsed")
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(SystemPromptBuilder.toolLines([]), "")
    }

    /// The whole point of BG P1: every enabled tool appears exactly once, sourced from the registry
    /// — no hand-maintained list to fall out of sync.
    func testEveryRegisteredToolAppearsExactlyOnce() {
        let registry = NativeToolRegistry(locationService: LocationService())
        let names = registry.toolNames
        XCTAssertFalse(names.isEmpty, "registry should have tools")

        let pairs = registry.toolDescriptions(for: names)
        XCTAssertEqual(pairs.count, names.count, "every enabled tool must resolve to a description")

        let lines = SystemPromptBuilder.toolLines(pairs)
        for name in names {
            let occurrences = lines.components(separatedBy: "- \(name): ").count - 1
            XCTAssertEqual(occurrences, 1, "\(name) should appear exactly once in the generated list")
        }
    }

    // MARK: - Mandatory routing rules (BM P4)

    func testHealthCheckRoutingRulePresentWhenToolEnabled() {
        let rules = SystemPromptBuilder.routingRules(toolNames: ["get_weather", "health_check"])
        XCTAssertTrue(rules.contains("health_check"))
        XCTAssertTrue(rules.contains("MUST"))
        XCTAssertFalse(rules.contains("\n  "), "rule must be flattened to a single bullet line")
    }

    func testNoRoutingRulesWithoutGatedTools() {
        // `calculate` has its own rule since Plan LO §3 (`SpokenMannersTests`).
        XCTAssertEqual(SystemPromptBuilder.routingRules(toolNames: ["get_weather", "flashlight"]), "")
        XCTAssertEqual(SystemPromptBuilder.routingRules(toolNames: []), "")
    }

    func testRegistryToolSetTriggersHealthRoutingRule() {
        // The real registry registers health_check, so the generated prompt carries the rule.
        let registry = NativeToolRegistry(locationService: LocationService())
        let rules = SystemPromptBuilder.routingRules(toolNames: registry.toolNames)
        XCTAssertTrue(rules.contains("health_check"))
    }

    func testDescriptionsComeFromTheToolItself() {
        let registry = NativeToolRegistry(locationService: LocationService())
        // Sample a stable, always-registered tool and confirm the generated line matches its own
        // description property (not a hand-copied string).
        guard let weather = registry.tool(named: "get_weather") else {
            return XCTFail("get_weather should be registered")
        }
        let line = SystemPromptBuilder.toolLines(registry.toolDescriptions(for: ["get_weather"]))
        XCTAssertTrue(line.contains(weather.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""),
                      "generated line should reflect the tool's own description")
    }

    // MARK: - The app's own settings

    func testTheGuideSaysWhereTheVoiceIsChangedInTheHubsOwnWords() {
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        let connections = SettingsCatalog.category(.connections).title
        XCTAssertTrue(guide.contains("Your voice"))
        XCTAssertTrue(guide.contains("Settings > \(connections) > Services & Integrations"))
        XCTAssertTrue(guide.contains("Avenkin app"))
    }

    func testTheGuideNamesOnlyCategoriesTheHubDraws() {
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        for id in [SettingsCategoryID.voice, .intelligence, .tools, .devices, .lookAndFeel] {
            XCTAssertTrue(guide.contains("Settings > \(SettingsHub.path(to: id))"), id.rawValue)
        }
        XCTAssertTrue(guide.contains("Settings > Assistant > Voice & Triggers"))
        XCTAssertTrue(guide.contains("Settings > Assistant > Agentic Features"))
        for gone in ["AI & Personality", "Tools & Actions"] {
            XCTAssertFalse(guide.contains(gone), gone)
            XCTAssertFalse(SystemPromptBuilder.onDeviceAppGuide(appName: "Avenkin").contains(gone), gone)
        }
    }

    func testTheGuideSteersAwayFromTheWrongApps() {
        // The answer this replaces sent the wearer to the iPhone's Settings, the glasses' own app
        // and Siri for a setting none of them holds.
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        XCTAssertTrue(guide.contains("never send the user there"))
    }

    /// A tester asked whether the wake phrase is heard with the phone locked in a pocket, and the
    /// model, with no facts, said to keep the app open. The guide now says what the app does: the
    /// wake phrase works locked while listening is on; the glasses carry a locked turn whichever
    /// mic waits for the phrase (`TurnMicHandoff.sessionSwitch`: the idle session kept, or a fresh
    /// one from the default phone-mic listener); glasses holding the idle mic stand down when
    /// taken off (`GlassesSleepPolicy.doffGraceSeconds`).
    func testTheGuideSaysWhatListeningDoesWithThePhoneLocked() {
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        XCTAssertTrue(guide.contains("works with the phone locked or in a pocket"))
        XCTAssertTrue(guide.contains("(not push-to-talk)"))
        #if !AVENKIN_PHONE_ONLY
        XCTAssertTrue(guide.contains("with the glasses as the microphone the request and the reply go through the glasses there too"),
                      "not only with Same as Microphone: the default iPhone listener reaches the glasses too")
        XCTAssertTrue(guide.contains("Settings > \(SettingsCatalog.category(.devices).title) > Glasses > Listen for the wake word on"))
        XCTAssertTrue(guide.contains(WakeListenMic.sameAsMicrophone.label))
        XCTAssertTrue(guide.contains("On \(WakeListenMic.iPhone.label), the default"))
        let stored = UserDefaults.standard.object(forKey: "wakeListenMic")
        defer { UserDefaults.standard.set(stored, forKey: "wakeListenMic") }
        UserDefaults.standard.removeObject(forKey: "wakeListenMic")
        XCTAssertEqual(Config.wakeListenMic, .iPhone, "the guide calls iPhone the default")
        XCTAssertTrue(guide.contains("\(Int(GlassesSleepPolicy.doffGraceSeconds)) seconds"))
        #endif
        XCTAssertFalse(guide.lowercased().contains("keep the app open"))
    }

    /// A tester whose wake word had died in a pocket was sent by the model to Background App
    /// Refresh (the app is not listed there), then to "the physical button on the glasses"
    /// (there is none). The guide now says what is true: no iOS setting applies, unlocking and
    /// opening the app restarts listening, and the in-app Listen button and the watch start a
    /// request by hand.
    func testTheGuideSaysWhatToDoWhenListeningStopsWhileLocked() {
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        XCTAssertTrue(guide.contains("no iPhone setting fixes it"))
        XCTAssertTrue(guide.contains("not listed under Background App Refresh"))
        #if !AVENKIN_PHONE_ONLY
        XCTAssertTrue(guide.contains("no button on the glasses"))
        #endif
        XCTAssertTrue(guide.contains("Unlocking the phone and opening the app restarts listening"))
        XCTAssertTrue(guide.contains("Never send the user to iOS Settings for this"))
    }

    /// After a search had returned, the model's reply was "Vou pesquisar… um momento" and the
    /// app spoke it as the answer. The guide tells the model how the app ends a turn.
    func testTheGuideSaysAToolResultIsAnsweredInTheSameReply() {
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        XCTAssertTrue(guide.contains("answer with what it returned in that same reply"))
        XCTAssertTrue(guide.contains("the app ends your turn at the first reply without a tool call"))
    }
}
