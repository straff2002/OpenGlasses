import XCTest
@testable import OpenGlasses

/// Plan HB — Field Assist as a mode: when it is on, what the Modes slot becomes, what a scenario
/// tap does, and which day card the home screen draws. All pure; no view, no `Config`.
final class FieldAssistModeTests: XCTestCase {

    private typealias Inputs = FieldAssistMode.Inputs

    // MARK: - On or off

    func testOnNeedsTheSwitchOrTheEditionAndTheEntitlement() {
        XCTAssertTrue(FieldAssistMode.isOn(Inputs(switchOn: true, entitled: true, entitlementChecked: true)))
        XCTAssertTrue(FieldAssistMode.isOn(Inputs(switchOn: false, entitled: true, restricted: true)),
                      "the edition is Field Assist whatever the switch says")
        XCTAssertFalse(FieldAssistMode.isOn(Inputs(switchOn: true, entitled: false, entitlementChecked: true)),
                       "a lapsed entitlement turns the mode off even with the switch left on")
        XCTAssertFalse(FieldAssistMode.isOn(Inputs(switchOn: false, entitled: true, entitlementChecked: true)))
        XCTAssertFalse(FieldAssistMode.isOn(Inputs(switchOn: false, entitled: false, restricted: true)),
                       "an edition with no licence in force is not Field Assist")
        XCTAssertFalse(FieldAssistMode.isOn(Inputs()))
    }

    // MARK: - The Modes slot

    func testFieldAssistOnTurnsTheModesTabIntoFieldAssist() {
        let presentation = ModesTabPresentation.resolve(Inputs(switchOn: true, entitled: true,
                                                               entitlementChecked: true))
        XCTAssertEqual(presentation, .fieldAssist(otherModes: .accordion))
        XCTAssertEqual(presentation.title, "Field Assist")
        XCTAssertEqual(presentation.systemImage, "wrench.and.screwdriver.fill",
                       "the tab wears the dock tile's Field Assist mark")
        XCTAssertEqual(presentation.systemImage, QuickAction.fieldAssist.icon)
        XCTAssertTrue(presentation.showsTab)
    }

    func testFieldAssistOffKeepsModesWithTheShortcutThatFits() {
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: false, entitled: true, entitlementChecked: true)),
                       .modes(shortcut: .turnOn))
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: false, entitled: false, entitlementChecked: true)),
                       .modes(shortcut: .unlock))
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: true, entitled: false, entitlementChecked: true)),
                       .modes(shortcut: .lapsed))
        let off = ModesTabPresentation.modes(shortcut: .turnOn)
        XCTAssertEqual(off.title, "Modes")
        XCTAssertEqual(off.systemImage, MainTab.modes.systemImage)
    }

    /// Nothing is drawn on a guess: before the store has answered, a false entitlement means
    /// "unknown", so neither the upsell nor the Field Assist tab appears.
    func testAnUnresolvedEntitlementDrawsNoShortcut() {
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: true, entitled: false, entitlementChecked: false)),
                       .modes(shortcut: nil))
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: false, entitled: false, entitlementChecked: false)),
                       .modes(shortcut: nil))
        // A signed organisation licence answers synchronously, before the store check.
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: true, entitled: true, entitlementChecked: false)),
                       .fieldAssist(otherModes: .accordion))
    }

    func testTheShortcutCopy() {
        XCTAssertFalse(ModesTabPresentation.FieldAssistShortcut.turnOn.showsLock)
        XCTAssertTrue(ModesTabPresentation.FieldAssistShortcut.unlock.showsLock)
        XCTAssertTrue(ModesTabPresentation.FieldAssistShortcut.lapsed.showsLock)
        for shortcut in [ModesTabPresentation.FieldAssistShortcut.turnOn, .unlock, .lapsed] {
            XCTAssertEqual(shortcut.title, "Field Assist")
            XCTAssertFalse(shortcut.subtitle.isEmpty)
            XCTAssertFalse(shortcut.footer.isEmpty)
            XCTAssertTrue(shortcut.spoken.hasPrefix("Field Assist. "))
        }
    }

    // MARK: - Lapse revert

    /// Each way Field Assist can end — the switch, the entitlement, the edition going — returns the
    /// slot to Modes, keeps the wearer on it, and leaves nothing of Field Assist in the bar.
    func testEveryWayFieldAssistEndsRevertsTheTabToModes() {
        let on = Inputs(switchOn: true, entitled: true, entitlementChecked: true)
        XCTAssertTrue(ModesTabPresentation.resolve(on).isFieldAssist)

        var switchedOff = on; switchedOff.switchOn = false
        var lapsed = on; lapsed.entitled = false
        let editionRemoved = Inputs(switchOn: false, entitled: true, entitlementChecked: true, restricted: false)

        for (name, inputs) in [("switch off", switchedOff), ("lapsed", lapsed), ("edition removed", editionRemoved)] {
            let presentation = ModesTabPresentation.resolve(inputs)
            XCTAssertFalse(presentation.isFieldAssist, name)
            XCTAssertEqual(presentation.title, "Modes", name)
            XCTAssertEqual(ModesTabPresentation.selection(.modes, after: presentation), .modes,
                           "\(name): the wearer stays on the slot, which is Modes again")
            XCTAssertFalse(FieldAssistMode.isOn(inputs), name)
        }
    }

    // MARK: - Org-forced

    func testTheEditionForcesFieldAssistAndHidesTheOtherModes() {
        let forced = ModesTabPresentation.resolve(Inputs(switchOn: false, entitled: true, restricted: true))
        XCTAssertEqual(forced, .fieldAssist(otherModes: .hidden))
        XCTAssertEqual(forced.title, "Field Assist")

        // An administrator session lifts the technician's view: the accordion is back, and the
        // mode follows the switch the profile set.
        XCTAssertEqual(ModesTabPresentation.resolve(Inputs(switchOn: true, entitled: true, restricted: false)),
                       .fieldAssist(otherModes: .accordion))
    }

    func testAnEditionWithoutALicenceDrawsNoSlotAndMovesTheWearerHome() {
        let presentation = ModesTabPresentation.resolve(Inputs(switchOn: true, entitled: false,
                                                               entitlementChecked: true, restricted: true))
        XCTAssertEqual(presentation, .hidden)
        XCTAssertFalse(presentation.showsTab)
        XCTAssertEqual(ModesTabPresentation.selection(.modes, after: presentation), .voice)
        XCTAssertEqual(ModesTabPresentation.selection(.job, after: presentation), .job,
                       "only the slot that went away moves anybody")
    }

    // MARK: - Scenarios

    func testAScenarioWithNoJobOpenStartsOne() {
        let decision = FieldAssistScenarioStart.decide(vaultId: "refrigeration", vaultName: "Refrigeration",
                                                       vaultUnlocked: true, openJob: nil)
        XCTAssertEqual(decision, .startJob)
        XCTAssertEqual(decision.confirmButton("Low suction"), "Start a job and run Low suction")
        XCTAssertTrue(decision.message("Low suction", vaultName: "Refrigeration").contains("Refrigeration"))
    }

    func testAScenarioRunsInsideAJobOpenOnTheSameVault() {
        let decision = FieldAssistScenarioStart.decide(
            vaultId: "refrigeration", vaultName: "Refrigeration", vaultUnlocked: true,
            openJob: .init(vaultId: "refrigeration", vaultName: "Refrigeration", label: "Job 1005"))
        XCTAssertEqual(decision, .runInOpenJob(label: "Job 1005"))
        XCTAssertEqual(decision.confirmButton("Low suction"), "Run in Job 1005")
    }

    /// The old Modes panel ended whatever job was open; a scenario tap now never does.
    func testAJobOpenOnAnotherVaultIsNeverEndedByAScenario() {
        let decision = FieldAssistScenarioStart.decide(
            vaultId: "it_network", vaultName: "IT & Network", vaultUnlocked: true,
            openJob: .init(vaultId: "refrigeration", vaultName: "Refrigeration", label: "Job 1005"))
        guard case .blocked(let reason) = decision else { return XCTFail("expected a refusal, got \(decision)") }
        XCTAssertTrue(reason.contains("Job 1005"))
        XCTAssertTrue(reason.contains("Refrigeration"))
        XCTAssertNil(decision.confirmButton("Anything"))
    }

    func testALockedVaultCannotStartAJob() {
        let decision = FieldAssistScenarioStart.decide(vaultId: "electrical", vaultName: "Electrical",
                                                       vaultUnlocked: false, openJob: nil)
        guard case .blocked(let reason) = decision else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.contains("Electrical is locked"))
    }

    // MARK: - The home screen's day card

    func testFieldAssistShowsTheJobDayCardEvenWithMyDayOff() {
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: true, myDayEnabled: false, myDayOnHome: true,
                                           personalLocked: false, surfaceFree: true),
                       .jobDay(showsPersonal: false))
    }

    func testMyDayOnFoldsItsItemsIntoTheJobDayCardInsteadOfASecondCard() {
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: true, myDayEnabled: true, myDayOnHome: true,
                                           personalLocked: false, surfaceFree: true),
                       .jobDay(showsPersonal: true))
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: true, myDayEnabled: true, myDayOnHome: false,
                                           personalLocked: false, surfaceFree: true),
                       .jobDay(showsPersonal: false),
                       "My Day taken off the home screen stays off it, in either card")
    }

    func testTheLockdownKeepsPersonalItemsOffTheWorkCard() {
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: true, myDayEnabled: true, myDayOnHome: true,
                                           personalLocked: true, surfaceFree: true),
                       .jobDay(showsPersonal: false))
        XCTAssertTrue(SettingsLockPolicy.lock(.connections, lockdown: .standard, restricted: true).isLocked,
                      "the standard lockdown locks Connections, where My Day's switch lives")
        XCTAssertFalse(SettingsLockPolicy.lock(.connections, lockdown: .standard, restricted: false).isLocked,
                       "an administrator session does not")
    }

    func testWithoutFieldAssistMyDayIsUnchanged() {
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: false, myDayEnabled: true, myDayOnHome: true,
                                           personalLocked: false, surfaceFree: true), .myDay)
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: false, myDayEnabled: false, myDayOnHome: true,
                                           personalLocked: false, surfaceFree: true), .none)
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: false, myDayEnabled: true, myDayOnHome: false,
                                           personalLocked: false, surfaceFree: true), .none)
    }

    func testBothCardsYieldToATurnOrCaptions() {
        for fieldAssistOn in [true, false] {
            XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: fieldAssistOn, myDayEnabled: true, myDayOnHome: true,
                                               personalLocked: false, surfaceFree: false), .none)
        }
        XCTAssertFalse(HomeSurfaceVisibility.showsMyDay(state: .speaking, captionsActive: false))
        XCTAssertFalse(HomeSurfaceVisibility.showsMyDay(state: .idle, captionsActive: true))
    }

    /// The card goes when Field Assist does, and My Day's own card (if placed) comes back.
    func testTheJobDayCardRevertsWhenFieldAssistEnds() {
        let lapsed = FieldAssistMode.isOn(Inputs(switchOn: true, entitled: false, entitlementChecked: true))
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: lapsed, myDayEnabled: true, myDayOnHome: true,
                                           personalLocked: false, surfaceFree: true), .myDay)
        XCTAssertEqual(HomeDayCard.resolve(fieldAssistOn: lapsed, myDayEnabled: false, myDayOnHome: true,
                                           personalLocked: false, surfaceFree: true), .none)
    }
}
