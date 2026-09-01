import AppIntents
import XCTest
@testable import OpenGlasses

/// Plan BQ P1 — pure catalog policy: source merging, enablement defaults, compliance and
/// Agent-Mode gating, spoken-name matching, and user-action validation. No AppIntents, no
/// `.shared` services.
final class SiriActionCatalogTests: XCTestCase {

    // MARK: Built-ins

    func testBuiltinsDefaultEnabled() {
        let catalog = SiriActionCatalog(config: SiriExposureConfig())
        let builtins = catalog.entries.filter { $0.source == .builtin }
        XCTAssertEqual(builtins.count, BuiltinSiriAction.all.count)
        XCTAssertTrue(builtins.allSatisfy(\.isEnabled))
    }

    func testDisabledBuiltinIsListedButNotEnabled() {
        let config = SiriExposureConfig(disabledBuiltinActions: ["daily_briefing"])
        let catalog = SiriActionCatalog(config: config)
        let entry = catalog.entry(id: "builtin:daily_briefing")
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry!.isEnabled)
        // Still resolvable by id (stale Shortcuts should get the "disabled" error, not
        // "not found") but absent from the enabled set the query serves.
        XCTAssertFalse(catalog.enabledEntries.contains { $0.id == "builtin:daily_briefing" })
    }

    func testBuiltinIdsAreUnique() {
        let ids = BuiltinSiriAction.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: Harvested capabilities

    func testHarvestedDefaultOffAndEnableByKey() {
        let harvested = CapabilityHarvester.harvest(
            flows: [(id: "pump-inspection", title: "Pump Inspection")],
            playbooks: [(id: "morning-open", name: "Morning Opening")]
        )
        var config = SiriExposureConfig()
        var catalog = SiriActionCatalog(config: config, harvested: harvested)
        XCTAssertEqual(catalog.entries.filter { $0.source == .harvested }.count, 2)
        XCTAssertTrue(catalog.entries.filter { $0.source == .harvested }.allSatisfy { !$0.isEnabled })

        config.enabledCapabilityIds.insert(
            SiriExposureConfig.capabilityKey(kind: .captureFlow, id: "pump-inspection"))
        catalog = SiriActionCatalog(config: config, harvested: harvested)
        let flow = catalog.entry(id: "capability:capture_flow:pump-inspection")
        XCTAssertEqual(flow?.isEnabled, true)
        XCTAssertEqual(flow?.displayName, "Pump Inspection")
        XCTAssertEqual(catalog.entry(id: "capability:playbook:morning-open")?.isEnabled, false)
    }

    func testCustomToolCapabilityRequiresAgentMode() {
        let customTool = CustomToolDefinition(
            id: "ct1", name: "garage_door", description: "Opens the garage",
            parameters: [], actionType: .shortcut, shortcutName: "Garage", urlTemplate: nil)
        let harvested = CapabilityHarvester.harvest(customTools: [customTool])

        let without = SiriActionCatalog(config: SiriExposureConfig(), harvested: harvested,
                                        agentModeEnabled: false)
        XCTAssertNil(without.entry(id: "capability:custom_tool:garage_door"))

        let with = SiriActionCatalog(config: SiriExposureConfig(), harvested: harvested,
                                     agentModeEnabled: true)
        XCTAssertNotNil(with.entry(id: "capability:custom_tool:garage_door"))
    }

    func testBlockedToolNamesDropEntriesEntirely() {
        let blocked: Set<String> = ["web_search"]
        let action = SiriActionDefinition(
            displayName: "Search the news",
            binding: .tool(name: "web_search", argsJSON: ""))
        let catalog = SiriActionCatalog(
            config: SiriExposureConfig(userActions: [action]),
            blockedToolNames: blocked)
        XCTAssertFalse(catalog.entries.contains { $0.source == .user })
    }

    // MARK: User actions

    func testUserActionEnablementHonoured() {
        let on = SiriActionDefinition(displayName: "Brief me", binding: .prompt(text: "Give me a briefing"))
        var off = SiriActionDefinition(displayName: "Log coffee", binding: .prompt(text: "Log a coffee"))
        off.isEnabled = false
        let catalog = SiriActionCatalog(config: SiriExposureConfig(userActions: [on, off]))
        XCTAssertTrue(catalog.enabledEntries.contains { $0.displayName == "Brief me" })
        XCTAssertFalse(catalog.enabledEntries.contains { $0.displayName == "Log coffee" })
        XCTAssertNotNil(catalog.entry(id: "user:\(off.id)"))
    }

    // MARK: Spoken-name matching

    func testMatchingCoversNameAndSynonymsCaseInsensitive() {
        let action = SiriActionDefinition(
            displayName: "Morning Rundown",
            synonyms: ["brief me properly"],
            binding: .prompt(text: "Briefing"))
        let catalog = SiriActionCatalog(config: SiriExposureConfig(userActions: [action]))

        XCTAssertTrue(catalog.entries(matching: "morning rundown").contains { $0.displayName == "Morning Rundown" })
        XCTAssertTrue(catalog.entries(matching: "BRIEF ME PROPERLY").contains { $0.displayName == "Morning Rundown" })
        XCTAssertTrue(catalog.entries(matching: "").isEmpty)
    }

    func testMatchingExcludesDisabledEntries() {
        let config = SiriExposureConfig(disabledBuiltinActions: ["daily_briefing"])
        let catalog = SiriActionCatalog(config: config)
        XCTAssertFalse(catalog.entries(matching: "daily briefing").contains { $0.id == "builtin:daily_briefing" })
    }

    // MARK: Validation

    private func validate(
        _ definition: SiriActionDefinition,
        existing: [SiriActionCatalog.Entry] = SiriActionCatalog(config: SiriExposureConfig()).entries,
        tools: Set<String>? = ["teleprompter", "daily_briefing"],
        agentMode: Bool = false,
        blocked: Set<String> = []
    ) -> SiriActionCatalog.ValidationIssue? {
        SiriActionCatalog.validate(
            definition, existing: existing, availableToolNames: tools,
            agentModeEnabled: agentMode, blockedToolNames: blocked)
    }

    func testValidateRejectsEmptyName() {
        let issue = validate(.init(displayName: "  ", binding: .prompt(text: "x")))
        XCTAssertEqual(issue, .emptyName)
    }

    func testValidateRejectsDuplicateOfBuiltinName() {
        let issue = validate(.init(displayName: "daily briefing", binding: .prompt(text: "x")))
        XCTAssertEqual(issue, .duplicateName("Daily Briefing"))
    }

    func testValidateAllowsEditingOwnName() {
        let action = SiriActionDefinition(displayName: "Log coffee", binding: .prompt(text: "log it"))
        let catalog = SiriActionCatalog(config: SiriExposureConfig(userActions: [action]))
        // Re-validating the same definition (same id) must not collide with itself.
        XCTAssertNil(validate(action, existing: catalog.entries))
    }

    func testValidateRejectsEmptyPrompt() {
        let issue = validate(.init(displayName: "Do nothing", binding: .prompt(text: " ")))
        XCTAssertEqual(issue, .emptyPrompt)
    }

    func testValidateRejectsUnknownTool() {
        let issue = validate(.init(displayName: "Broken", binding: .tool(name: "no_such_tool", argsJSON: "")))
        XCTAssertEqual(issue, .unknownTool("no_such_tool"))
    }

    func testValidateRejectsMalformedArgsJSON() {
        let issue = validate(.init(displayName: "Broken", binding: .tool(name: "teleprompter", argsJSON: "not json")))
        XCTAssertEqual(issue, .invalidArgsJSON)
    }

    func testValidateAcceptsToolWithValidArgs() {
        let issue = validate(.init(
            displayName: "Prompter",
            binding: .tool(name: "teleprompter", argsJSON: #"{"action": "start"}"#)))
        XCTAssertNil(issue)
    }

    func testValidateRejectsComplianceBlockedTool() {
        let issue = validate(
            .init(displayName: "Search", binding: .tool(name: "web_search", argsJSON: "")),
            tools: ["web_search"], blocked: ["web_search"])
        XCTAssertEqual(issue, .toolBlockedByCompliance("web_search"))
    }

    func testValidateRequiresAgentModeForCustomToolBinding() {
        let issue = validate(
            .init(displayName: "Garage", binding: .capability(kind: .customTool, id: "garage_door")))
        XCTAssertEqual(issue, .agentModeRequired)
        XCTAssertNil(validate(
            .init(displayName: "Garage", binding: .capability(kind: .customTool, id: "garage_door")),
            agentMode: true))
    }

    // MARK: Grid actions (Plan EB P1)

    private let speedDial: [QuickAction] = [
        QuickAction(id: "coffee", label: "Coffee", icon: "cup.and.saucer", type: .prompt,
                    promptText: "Where is the nearest coffee?"),
        QuickAction(id: "lights-off", label: "Lights Off", icon: "lightbulb.slash",
                    type: .homeAssistant, haService: "light.turn_off", haEntityId: "all"),
    ]

    private func gridHarvest() -> [HarvestedCapability] {
        CapabilityHarvester.harvest(
            gridEntries: HomeGridCatalog.available(quickActions: speedDial))
    }

    /// Ids are the grid's own, and names are the ones the tile draws — a spoken name that isn't
    /// the drawn one is a name nobody can guess.
    func testGridActionsHarvestWithTheGridsOwnIdsAndLabels() {
        let catalog = SiriActionCatalog(config: SiriExposureConfig(), harvested: gridHarvest())
        let grid = catalog.entries.filter {
            if case .capability(kind: .gridAction, _) = $0.binding { return true }
            return false
        }
        XCTAssertEqual(grid.count, HomeGridAction.builtIns.count + speedDial.count)
        XCTAssertEqual(catalog.entry(id: "capability:grid_action:builtin:meetings-today")?.displayName,
                       HomeGridAction.meetingsToday.label)
        XCTAssertEqual(catalog.entry(id: "capability:grid_action:quick:coffee")?.displayName, "Coffee")
    }

    func testGridActionsAreOffUntilExposedAndRoundTrip() {
        var config = SiriExposureConfig()
        var catalog = SiriActionCatalog(config: config, harvested: gridHarvest())
        XCTAssertEqual(catalog.entry(id: "capability:grid_action:quick:coffee")?.isEnabled, false)

        let key = SiriExposureConfig.capabilityKey(kind: .gridAction, id: "quick:coffee")
        XCTAssertEqual(key, SpeedDialEditor.exposureKey(forQuickActionId: "coffee"))

        config.enabledCapabilityIds.insert(key)
        catalog = SiriActionCatalog(config: config, harvested: gridHarvest())
        XCTAssertEqual(catalog.entry(id: "capability:grid_action:quick:coffee")?.isEnabled, true)
        XCTAssertTrue(catalog.entries(matching: "coffee")
            .contains { $0.id == "capability:grid_action:quick:coffee" })

        config.enabledCapabilityIds.remove(key)
        catalog = SiriActionCatalog(config: config, harvested: gridHarvest())
        XCTAssertEqual(catalog.entry(id: "capability:grid_action:quick:coffee")?.isEnabled, false)
    }

    /// The intent resolves an entity id to the same entry the grid resolves it to — one catalog,
    /// two surfaces. This is the invariant that keeps a spoken phrase from growing its own
    /// behaviour.
    func testAnExposedGridIdResolvesToTheSameActionTheGridResolves() {
        let config = SiriExposureConfig(enabledCapabilityIds: [
            SiriExposureConfig.capabilityKey(kind: .gridAction, id: "builtin:photo-to-task"),
        ])
        let catalog = SiriActionCatalog(config: config, harvested: gridHarvest())
        let entry = catalog.entry(id: "capability:grid_action:builtin:photo-to-task")
        guard case .capability(kind: .gridAction, id: let gridId)? = entry?.binding else {
            return XCTFail("A harvested grid action lost its grid binding")
        }
        XCTAssertEqual(HomeGridCatalog.entry(id: gridId, quickActions: speedDial),
                       .builtIn(.photoToTask))
    }

    /// A grid action binds no single tool: it submits a turn, and whatever the model reaches for
    /// then goes through the router's gates. The HIPAA screen keys off `toolName`, so this is the
    /// line that says which screen applies.
    func testGridActionBindingNamesNoTool() {
        XCTAssertNil(SiriActionBinding.capability(kind: .gridAction, id: "quick:coffee").toolName)
    }

    /// Cap arithmetic. iOS exports ten App Shortcuts; the parameterized catalog takes exactly one
    /// of them however many actions it carries, which is why harvesting a whole extra source
    /// costs nothing at the cap.
    func testMixedSourcesShareOneAppShortcutSlot() {
        let userAction = SiriActionDefinition(displayName: "Morning Rundown",
                                              binding: .prompt(text: "Brief me"))
        let harvested = CapabilityHarvester.harvest(
            flows: [(id: "pump", title: "Pump Inspection")],
            gridEntries: HomeGridCatalog.available(quickActions: speedDial))
        let config = SiriExposureConfig(
            enabledCapabilityIds: [
                SiriExposureConfig.capabilityKey(kind: .captureFlow, id: "pump"),
                SiriExposureConfig.capabilityKey(kind: .gridAction, id: "quick:coffee"),
            ],
            userActions: [userAction])
        let catalog = SiriActionCatalog(config: config, harvested: harvested)

        let enabled = catalog.enabledEntries
        XCTAssertEqual(enabled.filter { $0.source == .builtin }.count, BuiltinSiriAction.all.count)
        XCTAssertEqual(enabled.filter { $0.source == .harvested }.count, 2)
        XCTAssertEqual(enabled.filter { $0.source == .user }.count, 1)
        XCTAssertEqual(enabled.count, BuiltinSiriAction.all.count + 3)

        XCTAssertGreaterThan(enabled.count, SiriShortcutBudget.systemCap,
                             "The catalog is meant to outgrow the cap — that's why it's an entity")
        XCTAssertEqual(SiriShortcutBudget.slotsUsedByCatalog, 1)
        XCTAssertLessThanOrEqual(OpenGlassesShortcuts.appShortcuts.count,
                                 SiriShortcutBudget.systemCap,
                                 "An eleventh App Shortcut wipes the lot at build time")
    }

    // MARK: Binding → tool mapping (HIPAA gate keys off this)

    func testBindingToolNames() {
        XCTAssertEqual(SiriActionBinding.capability(kind: .captureFlow, id: "f").toolName, "capture_flow")
        XCTAssertEqual(SiriActionBinding.capability(kind: .procedure, id: "p").toolName, "procedure_runner")
        XCTAssertEqual(SiriActionBinding.capability(kind: .playbook, id: "b").toolName, "playbook")
        XCTAssertEqual(SiriActionBinding.capability(kind: .customTool, id: "garage_door").toolName, "garage_door")
        XCTAssertEqual(SiriActionBinding.tool(name: "weather", argsJSON: "").toolName, "weather")
        XCTAssertNil(SiriActionBinding.prompt(text: "x").toolName)
        XCTAssertNil(SiriActionBinding.builtin(id: "take_photo").toolName)
    }
}
