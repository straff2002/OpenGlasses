import XCTest
@testable import OpenGlasses

/// Plan KH P2. A parent toggle covers one consent: off turns its members off, on restores what was
/// on, and neither reaches past a lock, a separate consent or Medical Compliance's hard-disable.
final class SettingsGroupTests: XCTestCase {

    private typealias Member = SettingsGroupMemberID
    private typealias Reading = SettingsGroupState.Reading

    /// A group with `on` switched on and every member editable, unless told otherwise.
    private func state(_ id: SettingsGroupID, on: Set<Member> = [],
                       readOnly: Set<Member> = [], hidden: Set<Member> = [], medical: Bool = false,
                       remembered: Set<Member>? = nil) -> SettingsGroupState {
        let group = SettingsGroupCatalog.group(id)
        var readings: [Member: Reading] = [:]
        for member in group.members {
            let presentation: SettingPresentation = hidden.contains(member.id) ? .hidden
                : readOnly.contains(member.id) ? .readOnly : .editable
            readings[member.id] = Reading(isOn: on.contains(member.id), presentation: presentation,
                                          medicalModeRefuses: medical && member.hardDisabledInMedicalMode)
        }
        return SettingsGroupState(group: group, readings: readings, remembered: remembered)
    }

    private func applied(_ change: SettingsGroupState.Change, to on: Set<Member>) -> Set<Member> {
        change.writes.reduce(into: on) { result, write in
            if write.value { result.insert(write.member) } else { result.remove(write.member) }
        }
    }

    // MARK: - Off

    func testOffTurnsEveryMemberOff() {
        let on: Set<Member> = [.userMemory, .conversationHistory, .memorySuggestions]
        let change = state(.memory, on: on).parentChange(to: false)
        XCTAssertEqual(applied(change, to: on), [])
    }

    func testOffCoversASeparateConsentToo() {
        let on: Set<Member> = [.userMemory, .memoryEnrichment]
        XCTAssertEqual(applied(state(.memory, on: on).parentChange(to: false), to: on), [])
    }

    func testOffRemembersWhatWasOn() {
        let on: Set<Member> = [.userMemory, .memorySuggestions]
        XCTAssertEqual(state(.memory, on: on).parentChange(to: false).remembered, on)
    }

    // MARK: - On

    func testOnNeverEnablesASeparateConsentForTheFirstTime() {
        for (group, consent) in [(SettingsGroupID.memory, Member.memoryEnrichment), (.healthFitness, .shareHealth)] {
            let change = state(group).parentChange(to: true)
            XCTAssertFalse(change.writes.contains { $0.member == consent }, "\(group)")
        }
    }

    func testOnWithNothingToRestoreLeavesOffWhatIsOffByDefault() {
        let change = state(.memory).parentChange(to: true)
        XCTAssertEqual(applied(change, to: []), [.userMemory, .conversationHistory, .earlierInConversation],
                       "Memory Suggestions speaks up unprompted, so it stays the wearer's to turn on")
    }

    func testOffThenOnRestoresThePriorMix() {
        for mix: Set<Member> in [[.userMemory], [.conversationHistory, .memorySuggestions],
                                 [.userMemory, .memoryEnrichment]] {
            let off = state(.memory, on: mix).parentChange(to: false)
            let afterOff = applied(off, to: mix)
            let on = state(.memory, on: afterOff, remembered: off.remembered).parentChange(to: true)
            XCTAssertEqual(applied(on, to: afterOff), mix)
            XCTAssertNil(on.remembered, "a restore is spent")
        }
    }

    // MARK: - A consent only its own switch gives

    func testHealthSharingGoesOffWithTheParent() {
        let on: Set<Member> = [.firstAid, .shareHealth]
        XCTAssertEqual(applied(state(.healthFitness, on: on).parentChange(to: false), to: on), [])
    }

    func testHealthSharingNeverComesBackThroughAParent() {
        let mix: Set<Member> = [.healthSummaries, .firstAid, .shareHealth]
        let off = state(.healthFitness, on: mix).parentChange(to: false)
        XCTAssertEqual(off.remembered, [.healthSummaries, .firstAid], "off does not remember the consent")
        let on = state(.healthFitness, remembered: off.remembered).parentChange(to: true)
        XCTAssertEqual(applied(on, to: []), [.healthSummaries, .firstAid])
    }

    /// Whatever is on the phone already, the parent's on cannot be the thing that gives it.
    func testHealthSharingIsNotRestoredFromAnOlderRecord() {
        let change = state(.healthFitness, remembered: [.firstAid, .shareHealth]).parentChange(to: true)
        XCTAssertFalse(change.writes.contains { $0.member == .shareHealth })
    }

    func testMemoryEnrichmentIsStillRestoredIfItWasOn() {
        let mix: Set<Member> = [.userMemory, .memoryEnrichment]
        let off = state(.memory, on: mix).parentChange(to: false)
        XCTAssertEqual(off.remembered, mix)
        XCTAssertEqual(applied(state(.memory, remembered: off.remembered).parentChange(to: true), to: []), mix)
    }

    func testOnlyHealthSharingStandsOutsideRestore() {
        let held = SettingsGroupCatalog.all.flatMap(\.members).filter { !$0.parentMayRestore }.map(\.id)
        XCTAssertEqual(held, [.shareHealth])
    }

    /// A consent given by hand while the parent was off is not taken back by turning the parent on.
    func testOnNeverTurnsAMemberOff() {
        let change = state(.memory, on: [.memoryEnrichment]).parentChange(to: true)
        XCTAssertFalse(change.writes.contains { !$0.value })
    }

    func testOnAlwaysTurnsSomethingOn() {
        let onlyTheConsentWasOn = state(.memory, remembered: [.memoryEnrichment]).parentChange(to: true)
        XCTAssertTrue(applied(onlyTheConsentWasOn, to: []).contains(.userMemory))
        let nothingComesOnFirstTime = state(.memory, hidden: [.userMemory, .conversationHistory,
                                                              .earlierInConversation])
            .parentChange(to: true)
        XCTAssertEqual(applied(nothingComesOnFirstTime, to: []), [.memorySuggestions])
    }

    // MARK: - Locks

    func testAParentNeverWritesALockedMember() {
        for lock in [SettingPresentation.readOnly, .hidden] {
            let on: Set<Member> = [.smartHome, .messaging]
            let locked = state(.homeMusicMessages, on: on,
                               readOnly: lock == .readOnly ? [.smartHome] : [],
                               hidden: lock == .hidden ? [.smartHome] : [])
            let off = locked.parentChange(to: false)
            XCTAssertFalse(off.writes.contains { $0.member == .smartHome }, "\(lock)")
            XCTAssertFalse(off.remembered?.contains(.smartHome) ?? true, "\(lock)")
            let cold = state(.homeMusicMessages,
                             readOnly: lock == .readOnly ? [.smartHome] : [],
                             hidden: lock == .hidden ? [.smartHome] : [])
            XCTAssertFalse(cold.parentChange(to: true).writes.contains { $0.member == .smartHome }, "\(lock)")
        }
    }

    func testALockedMemberIsNotDrawn() {
        let drawn = state(.homeMusicMessages, hidden: [.messaging]).drawnMembers.map(\.id)
        XCTAssertFalse(drawn.contains(.messaging))
        XCTAssertTrue(drawn.contains(.smartHome))
    }

    func testAnAllLockedGroupIsNotDrawn() {
        for group in SettingsGroupCatalog.all {
            XCTAssertFalse(state(group.id, hidden: Set(group.members.map(\.id))).isDrawn, group.title)
        }
    }

    /// Nothing to write means no parent, not a switch that does nothing.
    func testAGroupWhoseFollowersAreLockedHasNoParent() {
        let locked = state(.homeMusicMessages, readOnly: [.smartHome, .messaging])
        XCTAssertFalse(locked.hasParent)
        XCTAssertNil(locked.summary)
        XCTAssertTrue(locked.isDrawn)
    }

    // MARK: - Medical Compliance

    func testHIPAADisableWins() {
        let on = state(.homeMusicMessages, medical: true).parentChange(to: true)
        XCTAssertFalse(on.writes.contains { $0.member == .messaging })
        let restored = state(.homeMusicMessages, medical: true, remembered: [.smartHome, .messaging])
            .parentChange(to: true)
        XCTAssertFalse(restored.writes.contains { $0.member == .messaging })
        XCTAssertFalse(state(.healthFitness, medical: true, remembered: [.shareHealth, .firstAid])
            .parentChange(to: true).writes.contains { $0.member == .shareHealth })
    }

    /// Plan KK P2: the earlier-conversation notes never run in HIPAA mode, so the Memory parent
    /// neither turns them on there nor counts them.
    func testHIPAAKeepsTheEarlierConversationNotesOutOfTheParent() {
        let on = state(.memory, medical: true).parentChange(to: true)
        XCTAssertFalse(on.writes.contains { $0.member == .earlierInConversation })
        let member = SettingsGroupCatalog.member(.earlierInConversation)
        XCTAssertEqual(member?.kind, .follows)
        XCTAssertEqual(member?.hardDisabledInMedicalMode, true)
        XCTAssertEqual(member?.onFirstTime, true, "on for everyone, a setting turns it off")
    }

    /// The stored value is the wearer's, and comes back when the mode ends.
    func testAParentLeavesARefusedMemberAlone() {
        let off = state(.memory, on: [.userMemory, .memoryEnrichment], medical: true).parentChange(to: false)
        XCTAssertFalse(off.writes.contains { $0.member == .memoryEnrichment })
        XCTAssertFalse(off.remembered?.contains(.memoryEnrichment) ?? true)
    }

    func testTheSummaryDoesNotCountARefusedMember() {
        XCTAssertEqual(state(.homeMusicMessages, on: [.smartHome], medical: true).summary, "On")
    }

    // MARK: - The summary

    func testTheSummaryCountsSwitchesOnly() {
        XCTAssertEqual(state(.memory, on: [.userMemory, .conversationHistory, .memorySuggestions]).summary,
                       "On · 3 of 5")
        XCTAssertEqual(state(.memory, on: [.userMemory]).summary, "On · 1 of 5")
    }

    func testOffSaysOff() {
        XCTAssertEqual(state(.memory).summary, "Off")
    }

    /// A consent is its own switch: on by itself it does not make the parent read on.
    func testASeparateConsentAloneDoesNotTurnTheParentOn() {
        XCTAssertEqual(state(.memory, on: [.memoryEnrichment]).summary, "Off")
    }

    func testAGroupThatIsOneSwitchSaysOnOrOff() {
        XCTAssertEqual(state(.myDayRoutines, on: [.myDay]).summary, "On")
        XCTAssertEqual(state(.myDayRoutines).summary, "Off")
    }

    func testAPlainListHasNoSummary() {
        XCTAssertNil(state(.gettingAround).summary)
        XCTAssertNil(state(.translate).summary)
    }

    // MARK: - The catalogue

    func testGroupsThatHaveARealSwitchHaveAParent() {
        let parents = SettingsGroupCatalog.all.filter { state($0.id).hasParent }.map(\.id)
        XCTAssertEqual(parents, [.memory, .myDayRoutines, .homeMusicMessages, .healthFitness])
    }

    func testAListGroupHasNoSwitchToFakeAParentWith() {
        for id in [SettingsGroupID.gettingAround, .translate] {
            XCTAssertTrue(SettingsGroupCatalog.group(id).members.allSatisfy { $0.kind == .link }, "\(id)")
        }
    }

    func testEveryMemberIsInExactlyOneGroup() {
        let members = SettingsGroupCatalog.all.flatMap(\.members).map(\.id)
        XCTAssertEqual(members.count, Set(members).count)
        XCTAssertEqual(Set(members), Set(Member.allCases))
    }

    func testEveryKindIsWhatThePlanSays() {
        let all = SettingsGroupCatalog.all.flatMap(\.members)
        func kind(_ id: Member) -> SettingsGroupMember.Kind? { all.first { $0.id == id }?.kind }
        XCTAssertEqual(all.filter { $0.kind == .separateConsent }.map(\.id), [.memoryEnrichment, .shareHealth])
        for id in [Member.userMemory, .conversationHistory, .memorySuggestions, .myDay, .smartHome, .messaging,
                   .healthSummaries, .firstAid] {
            XCTAssertEqual(kind(id), .follows, "\(id)")
        }
    }

    /// Decision 7: these keep their own switches, wherever they live.
    func testNoConsentThatStandsAloneIsUnderAParent() {
        let keys = Set(SettingsGroupCatalog.all.flatMap(\.members).filter(\.isSwitch).map(\.id.rawValue))
        XCTAssertFalse(keys.contains("agentModeEnabled"))
    }

    func testSwitchIdsAreTheKeysTheSettingsLiveAt() {
        for member in SettingsGroupCatalog.all.flatMap(\.members).filter(\.isSwitch) {
            XCTAssertTrue(member.id.rawValue.hasSuffix("Enabled") || member.id == .shareHealth, member.title)
        }
    }

    func testGroupIdsAreStable() {
        XCTAssertEqual(SettingsGroupID.allCases.map(\.rawValue),
                       ["memory", "my-day-routines", "getting-around", "home-music-messages", "translate",
                        "health-fitness"])
    }

    func testNoPlanLettersReachTheScreen() throws {
        let pattern = try NSRegularExpression(pattern: #"\b(?:Plan [A-Z]{1,2}|[A-Z]{2}\d?\s?P\d)\b"#)
        for group in SettingsGroupCatalog.all {
            for line in [group.title] + group.members.map(\.title) {
                XCTAssertNil(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
            }
        }
    }

    // MARK: - A managed phone

    private func technician(_ lockdown: ManagedLockdown = .standard, keys: Set<SettingKey> = [])
        -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: true, lockedKeys: keys)
    }

    private func member(_ id: Member) throws -> SettingsGroupMember {
        try XCTUnwrap(SettingsGroupCatalog.all.flatMap(\.members).first { $0.id == id })
    }

    func testEverydayIsLockedByDefaultOnAManagedPhone() {
        XCTAssertTrue(ManagedLockdown.standard.lockedCategories.contains(.everyday))
        XCTAssertFalse(SettingsVisibilityPolicy.hubCategories(simpleMode: false, in: technician())
            .contains { $0.id == .everyday })
    }

    func testEveryMemberIsHiddenFromTheTechnicianByDefault() {
        for member in SettingsGroupCatalog.all.flatMap(\.members) {
            XCTAssertEqual(SettingsGroupCatalog.presentation(of: member, in: technician()), .hidden, member.title)
        }
    }

    func testAnUnmanagedPhoneShowsEveryMember() {
        for member in SettingsGroupCatalog.all.flatMap(\.members) {
            XCTAssertEqual(SettingsGroupCatalog.presentation(of: member, in: .unmanaged), .editable, member.title)
        }
    }

    func testAProfileThatOpensEverydayStillKeepsClosedToolsClosed() throws {
        let open = ManagedLockdown(opening: [.everyday], locking: [],
                                   closedTools: Set(AIFeature.messaging.record.toolNames))
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.messaging), in: technician(open)), .hidden)
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.smartHome), in: technician(open)), .editable)
    }

    /// Everyday open must not be a way into a category that stayed locked.
    func testScheduledTasksStaysBehindAgenticFeaturesOnAManagedPhone() throws {
        let open = ManagedLockdown(opening: [.everyday], locking: [], closedTools: [])
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.scheduledTasks), in: technician(open)), .hidden)
        let both = ManagedLockdown(opening: [.everyday, .intelligence], locking: [], closedTools: [])
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.scheduledTasks), in: technician(both)), .editable)
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.scheduledTasks),
                                                         in: technician(both, keys: [.agentModeEnabled])), .hidden)
    }

    // MARK: - Where Everyday is not on the hub

    private func healthLink(simpleMode: Bool = false, _ context: ManagedSettingsContext) -> Bool {
        SettingsGroupCatalog.showsHealthLinkUnderDevices(simpleMode: simpleMode, in: context)
    }

    func testSimpleModeKeepsTheHealthSwitchesAwayFromEverydayButReachable() {
        XCTAssertTrue(healthLink(simpleMode: true, .unmanaged))
        XCTAssertFalse(SettingsCatalog.visible(simpleMode: true).contains { $0.id == .everyday })
        XCTAssertTrue(SettingsCatalog.visible(simpleMode: true).contains { $0.id == .devices })
    }

    func testThereIsNoSecondWayInWhileEverydayIsOnTheHub() {
        XCTAssertFalse(healthLink(.unmanaged))
    }

    /// Devices open and Everyday locked: these rows were reachable before they moved.
    func testAManagedPhoneWithDevicesOpenKeepsTheHealthSwitches() throws {
        let open = technician(ManagedLockdown(opening: [.devices], locking: [], closedTools: []))
        XCTAssertTrue(healthLink(open))
        for id in [Member.health, .healthSummaries, .firstAid, .shareHealth] {
            XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(id), in: open), .editable, "\(id)")
        }
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.userMemory), in: open), .hidden,
                       "only the rows that came from Devices & Privacy")
    }

    func testAStandardLockShowsNoLinkAndNoHealthRows() throws {
        XCTAssertFalse(healthLink(technician()))
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.firstAid), in: technician()), .hidden)
    }

    func testAProfileThatOpensEverydayNeedsNoLink() {
        XCTAssertFalse(healthLink(technician(ManagedLockdown(opening: [.everyday, .devices], locking: [], closedTools: []))))
    }

    func testAClosedToolStaysClosedThroughTheLink() throws {
        let open = technician(ManagedLockdown(opening: [.devices], locking: [],
                                              closedTools: Set(AIFeature.firstAidAssist.record.toolNames)))
        XCTAssertEqual(SettingsGroupCatalog.presentation(of: try member(.firstAid), in: open), .hidden)
    }

    /// It opens the group's own screen, so the one-screen rule below is what keeps it honest.
    func testTheLinkIsTheSameScreen() throws {
        let source = try String(contentsOf: Self.viewsRoot.appendingPathComponent("SettingsScreens.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("EverydaySettingsScreen(appState: appState, only: .healthFitness)"))
    }

    func testAccessibilityKeepsItsGuarantees() {
        XCTAssertTrue(ManagedLockdown.pinnedOpen.contains(.accessibility))
        XCTAssertFalse(ManagedLockdown.pinnedOpen.contains(.everyday))
        XCTAssertFalse(ManagedLockdown.standard.lockedCategories.contains(.accessibility))
        for simpleMode in [false, true] {
            XCTAssertTrue(SettingsCatalog.visible(simpleMode: simpleMode).contains { $0.id == .accessibility })
        }
    }

    func testEverydayIsNotInSimpleMode() {
        XCTAssertFalse(SettingsCatalog.category(.everyday).shownInSimpleMode)
    }

    func testTheSetupStepsLandOnEveryday() {
        XCTAssertEqual(ScenarioSetupStep.turnOnMemory.destination, .everyday)
        XCTAssertEqual(ScenarioSetupStep.setUpHome.destination, .everyday)
    }

    // MARK: - The real settings

    /// One run through the live store, so the keys the catalogue names are the keys `Config` uses.
    @MainActor
    func testTheStoreWritesThroughTheSettings() {
        let keys = SettingsGroupCatalog.group(.memory).members.filter(\.isSwitch).map(\.id.rawValue)
            + ["settingsGroupRemembered.memory"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        Config.setUserMemoryEnabled(true)
        Config.setConversationPersistenceEnabled(false)
        Config.setMemoryNudgesEnabled(true)
        Config.setBrainEnrichmentEnabled(false)
        Config.setSettingsGroupRemembered(nil, group: "memory")

        SettingsGroupStore.setParent(false, of: .memory, in: .unmanaged)
        XCTAssertFalse(Config.userMemoryEnabled)
        XCTAssertFalse(Config.memoryNudgesEnabled)
        XCTAssertEqual(SettingsGroupStore.state(of: .memory, in: .unmanaged).summary, "Off")

        SettingsGroupStore.setParent(true, of: .memory, in: .unmanaged)
        XCTAssertTrue(Config.userMemoryEnabled)
        XCTAssertTrue(Config.memoryNudgesEnabled)
        XCTAssertFalse(Config.conversationPersistenceEnabled, "it was off, so it stays off")
        XCTAssertFalse(Config.brainEnrichmentEnabled)
        XCTAssertNil(Config.settingsGroupRemembered(group: "memory"))
    }

    /// The live store, for the one consent a parent can only take away.
    @MainActor
    func testTheStoreNeverRestoresHealthSharing() {
        let keys = SettingsGroupCatalog.group(.healthFitness).members.filter(\.isSwitch).map(\.id.rawValue)
            + ["settingsGroupRemembered.health-fitness"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        Config.firstAidAssistEnabled = true
        Config.setShareHealthDataWithAI(true)
        SettingsGroupStore.setParent(false, of: .healthFitness, in: .unmanaged)
        XCTAssertFalse(Config.shareHealthDataWithAI)
        SettingsGroupStore.setParent(true, of: .healthFitness, in: .unmanaged)
        XCTAssertTrue(Config.firstAidAssistEnabled)
        XCTAssertFalse(Config.shareHealthDataWithAI)
        SettingsGroupStore.setMember(.shareHealth, to: true, in: .healthFitness)
        XCTAssertTrue(Config.shareHealthDataWithAI, "its own switch is the way back")
    }

    /// Turned off by hand while the parent is off, it stays off when the parent comes back.
    @MainActor
    func testAMemberTurnedOffByHandIsNotRestored() {
        let keys = ["brainEnrichmentEnabled", "settingsGroupRemembered.memory"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        Config.setSettingsGroupRemembered(["userMemoryEnabled", "brainEnrichmentEnabled"], group: "memory")
        SettingsGroupStore.setMember(.memoryEnrichment, to: false, in: .memory)
        XCTAssertEqual(Config.settingsGroupRemembered(group: "memory"), ["userMemoryEnabled"])
    }

    // MARK: - Each switch lives in one place

    private static let viewsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("OpenGlasses/Sources/App/Views")

    private func files(drawing pattern: String) throws -> [String] {
        let files = FileManager.default.enumerator(at: Self.viewsRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.flatMap { url -> [String] in
            let source = try String(contentsOf: url, encoding: .utf8)
            let count = source.components(separatedBy: pattern).count - 1
            return Array(repeating: url.lastPathComponent, count: count)
        }
    }

    func testEachMovedSwitchIsDrawnOnExactlyOneScreen() throws {
        let rows = ["title: \"User Memory\"", "title: \"Conversation History\"", "title: \"Memory Suggestions\"",
                    "title: \"Memory Enrichment\"", "title: \"AI Smart Home Control\"", "title: \"AI Messaging\"",
                    "title: \"Health Summaries\"", "title: \"Share Health Data with AI\"",
                    "title: String(localized: \"First-Aid Coaching and Triage\")", "Toggle(\"My Day\""]
        for row in rows {
            XCTAssertEqual(try files(drawing: row), ["EverydaySettingsScreen.swift"], row)
        }
    }

    func testTheOldScreensKeepNoCopyOfAMovedRow() throws {
        for row in ["\"My Day\"", "\"Morning briefing\"", "NavigationSettingsView()", "ParkingSettingsView(",
                    "MusicSettingsView()", "TranslationSettingsView()", "HomeAssistantSettingsView()"] {
            for file in try files(drawing: row) {
                XCTAssertFalse(["ServicesSettingsView.swift", "SettingsCategoryScreens.swift", "SettingsScreens.swift"]
                    .contains(file), "\(row) is still on \(file)")
            }
        }
    }

    func testIntentClassifierIsARowUnderVoiceInPlainWords() throws {
        XCTAssertEqual(try files(drawing: "title: \"Ignore nearby chatter\""), ["SettingsScreens.swift"])
        XCTAssertEqual(try files(drawing: "title: \"Intent Classifier\""), [])
    }

    /// The row used to call this on-device. It sends what was heard to a cloud model.
    func testIgnoreNearbyChatterSaysWhereTheWordsGo() throws {
        let source = try String(contentsOf: Self.viewsRoot.appendingPathComponent("SettingsScreens.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("it sends the words it heard to your AI provider, OpenAI or Groq"))
    }

    /// The Things to Try and My Manuals rows open Everyday, and the one-group page has neither.
    func testTheOneGroupPageIsOnlyThatGroup() throws {
        let source = try String(contentsOf: SettingsHubTests.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/App/Views/EverydaySettingsScreen.swift"), encoding: .utf8)
        let guardLine = try XCTUnwrap(source.range(of: "if only == nil {"))
        let things = try XCTUnwrap(source.range(of: "ThingsToTryView()"))
        let groups = try XCTUnwrap(source.range(of: "ForEach(groups"))
        XCTAssertLessThan(guardLine.lowerBound, things.lowerBound)
        XCTAssertLessThan(things.lowerBound, groups.lowerBound, "Things to Try is the first row")
    }

    func testBlurBystanderFacesStaysUnderDevicesAndPrivacy() throws {
        XCTAssertEqual(try files(drawing: "BystanderBlurSwitch(appState: appState)").sorted(),
                       ["ServicesSettingsView.swift", "SettingsView.swift"])
    }
}
