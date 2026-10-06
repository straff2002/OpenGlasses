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
        XCTAssertEqual(SystemPromptBuilder.routingRules(toolNames: ["get_weather", "calculate"]), "")
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
            XCTAssertTrue(guide.contains("Settings > \(SettingsCatalog.category(id).title)"), id.rawValue)
        }
    }

    func testTheGuideSteersAwayFromTheWrongApps() {
        // The answer this replaces sent the wearer to the iPhone's Settings, the glasses' own app
        // and Siri for a setting none of them holds.
        let guide = SystemPromptBuilder.appGuide(appName: "Avenkin")
        XCTAssertTrue(guide.contains("never send the user there"))
    }
}
