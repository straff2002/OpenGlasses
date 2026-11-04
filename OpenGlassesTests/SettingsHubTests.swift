import XCTest
@testable import OpenGlasses

/// Plan HA C1 — the settings hub: every category, always, in one fixed order; Simple Mode's
/// subset; and every screen the old folded hub reached is still reachable from the new one.
final class SettingsHubTests: XCTestCase {

    // MARK: - The order

    func testTheHubListsEveryCategoryInTheAgreedOrder() {
        XCTAssertEqual(SettingsCatalog.all.map(\.title), [
            "AI & Personality",
            "Voice & Triggers",
            "Everyday",
            "Devices & Privacy",
            "Accessibility",
            "Field Assist",
            "My Manuals",
            "Look & Feel",
            "Tools & Actions",
            "Connections",
            "Capture & Streaming",
            GlassesSupportPolicy.isSupported ? "Display & HUD" : "Teleprompter",
            "Advanced",
            "Diagnostics & Support",
        ])
        XCTAssertEqual(SettingsCatalog.all.map(\.id), SettingsCategoryID.allCases)
        XCTAssertEqual(SettingsCatalog.visible(simpleMode: false), SettingsCatalog.all,
                       "outside Simple Mode nothing is held back — there is no folding any more")
    }

    /// The raw values are what an organisation profile names; they must not drift.
    func testCategoryIdsAreStable() {
        XCTAssertEqual(SettingsCategoryID.allCases.map(\.rawValue), [
            "intelligence", "voice", "everyday", "devices", "accessibility", "field-assist", "my-manuals",
            "look-and-feel", "tools", "connections", "capture", "display", "advanced", "diagnostics",
        ])
    }

    /// Plan KH P2: added after Voice & Triggers, and no id that a profile already names moved.
    func testEverydayAddedNothingButItself() {
        let before = ["intelligence", "voice", "devices", "accessibility", "field-assist", "my-manuals",
                      "look-and-feel", "tools", "connections", "capture", "display", "advanced", "diagnostics"]
        XCTAssertEqual(SettingsCategoryID.allCases.map(\.rawValue).filter { $0 != "everyday" }, before)
        XCTAssertEqual(SettingsCategoryID.allCases[2], .everyday)
    }

    func testTitlesAndIconsAreUniqueAndPresent() {
        XCTAssertEqual(Set(SettingsCatalog.all.map(\.title)).count, SettingsCatalog.all.count)
        for category in SettingsCatalog.all {
            XCTAssertFalse(category.icon.isEmpty, category.title)
            XCTAssertFalse(category.subtitle.isEmpty, category.title)
        }
    }

    // MARK: - Simple Mode

    func testSimpleModeKeepsTheEverydaySurfaceInHubOrder() {
        XCTAssertEqual(SettingsCatalog.visible(simpleMode: true).map(\.id),
                       [.voice, .devices, .accessibility, .myManuals, .lookAndFeel, .diagnostics])
    }

    func testAccessibilityIsPinnedWhateverSimpleModeSays() {
        for simpleMode in [false, true] {
            XCTAssertTrue(SettingsCatalog.visible(simpleMode: simpleMode).contains { $0.id == .accessibility })
        }
        let pinned = SettingsCategory.pinnedAssistive(.accessibility, title: "A", icon: "a", subtitle: "s")
        XCTAssertTrue(pinned.shownInSimpleMode, "the assistive constructor has no way to hide it")
    }

    // MARK: - The profile script mirrors the ids

    /// The shared profile contract `Scripts/make-org-profile.swift` checks with is compiled into this bundle.
    func testTheProfileScriptKnowsTheSameCategories() {
        XCTAssertEqual(ProfileContract.settingsCategoryIds, SettingsCategoryID.allCases.map(\.rawValue))
        XCTAssertEqual(ProfileContract.pinnedOpenCategoryIds, Set(ManagedLockdown.pinnedOpen.map(\.rawValue)))
    }

    // MARK: - Nothing the old hub reached became unreachable

    /// Every screen the hub reached before Plan HA (main at 14d04710) — its own rows, and the rows
    /// of each category screen — with the category it lives in now and the chain of screens it is
    /// reached through. The chain starts at the screen `SettingsCategoryScreen.destination(for:)` opens for
    /// that category.
    static let inventory: [(screen: String, category: SettingsCategoryID, via: [String])] = [
        // The old hub's own rows.
        ("AIPersonalitySettingsScreen", .intelligence, []),
        ("VoiceTriggersSettingsScreen", .voice, []),
        ("GlassesPrivacySettingsScreen", .devices, []),
        ("AccessibilitySettingsView", .accessibility, []),
        ("LookFeelSettingsScreen", .lookAndFeel, []),
        ("ToolsActionsSettingsScreen", .tools, []),
        ("ConnectionsSettingsScreen", .connections, []),
        ("CaptureStreamingSettingsScreen", .capture, []),
        ("DisplayHUDSettingsScreen", .display, []),
        ("AdvancedSettingsScreen", .advanced, []),
        ("DiagnosticsSupportView", .diagnostics, []),
        // "Works with your iPhone" was a hub row; it is the first row of Connections now.
        ("AppleIntegrationsSettingsScreen", .connections, ["ConnectionsSettingsScreen", "ConnectionsSections"]),
        // Tools & Actions › Field Assist is its own category now.
        ("FieldAssistSettingsView", .fieldAssist, []),
        // AI & Personality.
        ("PersonasView", .intelligence, ["AIPersonalitySettingsScreen"]),
        ("PromptPresetsView", .intelligence, ["AIPersonalitySettingsScreen"]),
        ("SmartRoutingView", .intelligence, ["AIPersonalitySettingsScreen"]),
        ("LLMImageSettingsView", .intelligence, ["AIPersonalitySettingsScreen"]),
        ("AgenticFeaturesView", .intelligence, ["AIPersonalitySettingsScreen"]),
        // Plan KH P2: Everyday, and the rows that moved to it. Plan IW P2's goals and activity came
        // with Memory, along with the Memory screen's way to the goals, under "Unfinished things".
        ("EverydaySettingsScreen", .everyday, []),
        ("MemoryView", .everyday, ["EverydaySettingsScreen"]),
        ("GoalsView", .everyday, ["EverydaySettingsScreen"]),
        ("ActivityView", .everyday, ["EverydaySettingsScreen"]),
        ("GoalsView", .everyday, ["EverydaySettingsScreen", "MemoryView"]),
        ("MyDayContentsSettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("MyDayDeliverySettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("ScheduledTasksView", .everyday, ["EverydaySettingsScreen"]),
        ("ScheduledTasksView", .intelligence, ["AIPersonalitySettingsScreen", "AgenticFeaturesView"]),
        ("NavigationSettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("ParkingSettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("MusicSettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("HomeAssistantSettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("TranslationSettingsView", .everyday, ["EverydaySettingsScreen"]),
        ("HealthSettingsView", .everyday, ["EverydaySettingsScreen"]),
        // Where Everyday is not on the hub, Devices & Privacy links to the same screen.
        ("EverydaySettingsScreen", .devices, ["GlassesPrivacySettingsScreen"]),
        // Voice & Triggers.
        ("TempleTapSettingsView", .voice, ["VoiceTriggersSettingsScreen"]),
        // Devices & Privacy. The Connected Glasses section is the Glasses screen now.
        ("GlassesSettingsView", .devices, ["GlassesPrivacySettingsScreen"]),
        ("HardwarePrivacyView", .devices, ["GlassesPrivacySettingsScreen"]),
        ("MedicalCompliancePaywallView", .devices, ["GlassesPrivacySettingsScreen"]),
        ("ProcessingSummaryView", .devices, ["GlassesPrivacySettingsScreen"]),
        ("RecordingsView", .devices, ["GlassesPrivacySettingsScreen", "HardwarePrivacyView"]),
        ("MeetingRecordsView", .devices, ["GlassesPrivacySettingsScreen", "HardwarePrivacyView"]),
        ("InsightsView", .devices, ["GlassesPrivacySettingsScreen", "HardwarePrivacyView"]),
        // Look & Feel.
        ("LanguageSettingsView", .lookAndFeel, ["LookFeelSettingsScreen"]),
        // Tools & Actions.
        ("QuickActionsSettingsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("ToolsSettingsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("VaultManagerView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("VaultFilesEditorView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("DeckListView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("ReadingStatsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("HealthVaultEditorView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("CustomToolsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("SkillPacksSettingsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("SiriExposureView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("MCPServerSettingsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("PlaybooksSettingsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("ClawHubBrowserView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("VoiceSkillsManagerView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        ("SuggestedSkillsView", .tools, ["ToolsActionsSettingsScreen", "ToolsActionsSections"]),
        // Connections.
        ("ServicesSettingsView", .connections, ["ConnectionsSettingsScreen", "ConnectionsSections"]),
        ("GatewaySettingsView", .connections, ["ConnectionsSettingsScreen", "ConnectionsSections"]),
        ("MCPServersView", .connections, ["ConnectionsSettingsScreen", "ConnectionsSections"]),
        ("WeatherDataAboutView", .connections, ["ConnectionsSettingsScreen", "ConnectionsSections", "AppleIntegrationsSettingsScreen"]),
        // Capture & Streaming. (Services is Connections' screen; Capture keeps a shortcut to it.)
        ("RecordingsView", .capture, ["CaptureStreamingSettingsScreen", "CaptureStreamingSections"]),
        ("MeetingRecordsView", .capture, ["CaptureStreamingSettingsScreen", "CaptureStreamingSections"]),
        // Display & HUD.
        ("HUDMirrorView", .display, ["DisplayHUDSettingsScreen", "DisplayHUDSections"]),
        ("EvenDisplaySettingsView", .display, ["DisplayHUDSettingsScreen", "DisplayHUDSections"]),
        ("WebHUDMirrorSettingsView", .display, ["DisplayHUDSettingsScreen", "DisplayHUDSections"]),
        ("TeleprompterSettingsView", .display, ["DisplayHUDSettingsScreen", "DisplayHUDSections"]),
        // Advanced.
        ("DeveloperPanelView", .advanced, ["AdvancedSettingsScreen"]),
        ("PromptInspectorView", .advanced, ["AdvancedSettingsScreen"]),
        ("NetworkMonitorView", .advanced, ["AdvancedSettingsScreen"]),
        ("LiveVisionSettingsView", .advanced, ["AdvancedSettingsScreen"]),
        ("DocumentsView", .advanced, ["AdvancedSettingsScreen"]),
        ("CaptureFlowAuthorView", .advanced, ["AdvancedSettingsScreen"]),
    ]

    func testEveryScreenTheOldHubReachedIsStillReachable() throws {
        let destinations = try destinationCases()
        for entry in Self.inventory {
            let chain = entry.via + [entry.screen]
            let root = chain[0]
            XCTAssertEqual(destinations[entry.category], root,
                           "\(entry.screen): the hub opens \(destinations[entry.category] ?? "nothing") for "
                               + "\(entry.category.rawValue), not \(root)")
            for (parent, child) in zip(chain, chain.dropFirst()) {
                let body = try structBody(parent)
                XCTAssertTrue(body.contains("\(child)("),
                              "\(child) is no longer reached from \(parent) (\(entry.category.rawValue))")
            }
        }
    }

    /// Every category opens a screen, and no two open the same one.
    func testEveryCategoryHasItsOwnScreen() throws {
        let destinations = try destinationCases()
        XCTAssertEqual(Set(destinations.keys), Set(SettingsCategoryID.allCases))
        XCTAssertEqual(Set(destinations.values).count, destinations.count)
    }

    /// Plan KH P2: what a hub row opens, for the pages that hold more than one category.
    func testEveryMergedPageReachesWhatItHolds() throws {
        let rowScreen = try structBody("SettingsHubRowScreen")
        for screen in ["AIPersonalitySettingsScreen(", "DiagnosticsSupportView(", "GlassesPrivacySettingsScreen(",
                       "SettingsInlineSections(", "SettingsCategoryScreen("] {
            XCTAssertTrue(rowScreen.contains(screen), screen)
        }
        let inline = try structBody("SettingsInlineSections")
        for sections in ["CaptureStreamingSections(", "DisplayHUDSections(", "ConnectionsSections(", "ToolsActionsSections("] {
            XCTAssertTrue(inline.contains(sections), sections)
        }
        XCTAssertTrue(try structBody("GlassesPrivacySettingsScreen").contains("SettingsInlineSections("))
        XCTAssertTrue(try structBody("AIPersonalitySettingsScreen").contains("id: .voice"))
        XCTAssertTrue(try structBody("DiagnosticsSupportView").contains("id: .advanced"))
    }

    /// A link out of a merged page goes through the lock, like a hub row.
    func testTheHubOpensRowsAndRequestsThroughTheLockedScreens() throws {
        let hub = try structBody("SettingsView")
        XCTAssertTrue(hub.contains("SettingsHubRowScreen(appState: appState, row: row.id)"))
        XCTAssertTrue(hub.contains("SettingsCategoryScreen(appState: appState, id: id)"))
        XCTAssertTrue(hub.contains("SettingsHub.route(requested, visible: visibleCategories)"))
        XCTAssertTrue(try structBody("SettingsCategoryScreen").contains("ManagedHiddenScreen("))
        XCTAssertTrue(try structBody("SettingsHubRowScreen").contains("ManagedHiddenScreen("))
    }

    func testMyManualsAndThingsToTryAreOnTheScreensThePlanSays() throws {
        let everyday = try structBody("EverydaySettingsScreen")
        XCTAssertTrue(everyday.contains("ThingsToTryView()"))
        XCTAssertTrue(everyday.contains("SettingsHub.showsMyManuals(on: .everyday)"))
        XCTAssertTrue(everyday.contains("MyManualsView()"))
        // Field Assist's screen keeps only the locked offer's "Only need your own manuals?" link.
        XCTAssertFalse(try structBody("FieldAssistSettingsView").contains("SettingsHub.showsMyManuals"))
        let hub = try structBody("SettingsView")
        XCTAssertTrue(hub.contains("SettingsHub.thingsToTryPlace(visible: visibleCategories) == .besideAbout"))
        XCTAssertTrue(hub.contains("ThingsToTryView()"))
    }

    func testTheAboutSectionStillReachesAttributions() throws {
        XCTAssertTrue(try structBody("SettingsView").contains("AttributionsView()"))
    }

    // MARK: - Source helpers

    private struct MissingScreen: Error, CustomStringConvertible {
        let name: String
        var description: String { "no struct \(name): View in OpenGlasses/Sources/App/Views" }
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static let viewSources: [String] = {
        let root = repoRoot.appendingPathComponent("OpenGlasses/Sources/App/Views")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }()

    /// The text of `struct <name>` up to the next top-level declaration.
    private func structBody(_ name: String) throws -> String {
        for source in Self.viewSources {
            guard let start = source.range(of: "\nstruct \(name): View {")
                ?? source.range(of: "\nstruct \(name): View{") else { continue }
            let rest = source[start.upperBound...]
            let stops = ["\nstruct ", "\nprivate struct ", "\nfileprivate struct ", "\nfinal class ",
                         "\nextension ", "\nenum ", "\nprivate enum ", "\n// MARK: - "]
            let end = stops.compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
            return String(rest[..<end])
        }
        throw MissingScreen(name: name)
    }

    /// `SettingsCategoryScreen.destination(for:)`, read as `case .x:` → the screen type on the next line.
    private func destinationCases() throws -> [SettingsCategoryID: String] {
        let hub = try structBody("SettingsCategoryScreen")
        let function = try XCTUnwrap(hub.components(separatedBy: "private func destination(for id: SettingsCategoryID)")
            .dropFirst().first, "destination(for:) is gone")
        var result: [SettingsCategoryID: String] = [:]
        let lines = function.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ."), trimmed.hasSuffix(":"), index + 1 < lines.count else { continue }
            let name = String(trimmed.dropFirst("case .".count).dropLast())
            let id = try XCTUnwrap(SettingsCategoryID.allCases.first { "\($0)" == name }, "unknown case \(name)")
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            result[id] = String(next.prefix { $0 != "(" })
            if result.count == SettingsCategoryID.allCases.count { break }
        }
        return result
    }
}

/// Plan HA C3 — the hero card follows the glasses' truthful link, not "were they ever added".
final class SettingsHeroDeviceTests: XCTestCase {

    func testTheGlassesCardShowsOnlyWhileTheGlassesAreAttached() {
        XCTAssertEqual(SettingsHeroDevice.resolve(phase: .connected, glassesAdded: true), .glasses)
        XCTAssertEqual(SettingsHeroDevice.resolve(phase: .connecting, glassesAdded: true), .glasses,
                       "connecting is the moment after Connect — the glasses are what is being set up")
        XCTAssertEqual(SettingsHeroDevice.resolve(phase: .addedDisconnected, glassesAdded: true),
                       .phone(glassesAway: true),
                       "a pair in its case is not the device in use")
        XCTAssertEqual(SettingsHeroDevice.resolve(phase: .noGlassesAdded, glassesAdded: false),
                       .phone(glassesAway: false))
        XCTAssertEqual(SettingsHeroDevice.resolve(phase: .noGlassesAdded, glassesAdded: true),
                       .phone(glassesAway: true),
                       "glasses added on an earlier launch, not listed yet")
    }

    /// Paused is a connected link the wearer stood down: still attached, so still the glasses card
    /// (it says "Connected · paused").
    func testPausedGlassesKeepTheirCard() {
        var use = GlassesUse()
        use.linkChanged(.connected)
        use.standDown(.user)
        XCTAssertTrue(use.isPaused)
        XCTAssertEqual(SettingsHeroDevice.resolve(phase: use.link, glassesAdded: true), .glasses)
    }

    func testThePhoneCardSaysWhenGlassesAreAway() {
        XCTAssertEqual(SettingsHeroDevice.phone(glassesAway: false).phoneStatus, "In use")
        XCTAssertEqual(SettingsHeroDevice.phone(glassesAway: true).phoneStatus, "In use · Glasses not connected")
        XCTAssertNil(SettingsHeroDevice.glasses.phoneStatus)
    }
}
