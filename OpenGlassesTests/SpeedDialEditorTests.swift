import XCTest
@testable import OpenGlasses

/// Plan EB P2 — creating an action is data entry, and the rules that make that safe are pure:
/// what a name may be, what is immune, what an edit preserves, and that deleting an action and
/// revoking its voice exposure is one result rather than two writes a caller can half-make.
final class SpeedDialEditorTests: XCTestCase {

    private let mine = QuickAction(id: "coffee", label: "Coffee", icon: "cup.and.saucer",
                                   type: .prompt, promptText: "Where is the nearest coffee?")

    private func draft(name: String = "Coffee", kind: HomeGridAction.Kind = .prompt,
                       prompt: String = "Where is the nearest coffee?",
                       id: String? = nil) -> HomeActionDraft {
        HomeActionDraft(id: id, name: name, icon: "cup.and.saucer", kind: kind, prompt: prompt)
    }

    // MARK: Create

    func testCreatingAppendsAPromptActionToTheStore() {
        let next = SpeedDialEditor.applying(draft(), to: [])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].label, "Coffee")
        XCTAssertEqual(next[0].type, .prompt)
        XCTAssertEqual(next[0].promptText, "Where is the nearest coffee?")
        XCTAssertEqual(next[0].icon, "cup.and.saucer")
    }

    func testAPhotoKindBecomesThePhotoThenPromptTheGridAlreadyDraws() {
        let next = SpeedDialEditor.applying(draft(name: "Menu", kind: .photoPrompt,
                                                  prompt: "Read this menu"), to: [])
        XCTAssertEqual(next[0].type, .photoThenPrompt)
        XCTAssertTrue(HomeGridEntry.quickAction(next[0]).capturesPhoto)
    }

    /// The created action runs through the seam the grid already had — nothing this plan adds can
    /// execute anything the grid could not.
    @MainActor
    func testACreatedActionExecutesThroughTheExistingSeam() async {
        final class FakeSession: HomeGridSession {
            var prompts: [String] = []
            var photoPrompts: [String] = []
            var quickActions: [QuickAction] = []
            func submitHomePrompt(_ text: String) async { prompts.append(text) }
            func submitHomePhotoPrompt(_ text: String) async { photoPrompts.append(text) }
            func runHomeQuickAction(_ action: QuickAction) async { quickActions.append(action) }
        }

        let created = SpeedDialEditor.applying(draft(), to: [])[0]
        let session = FakeSession()
        await HomeGridDispatcher.run(.quickAction(created), on: session)

        XCTAssertEqual(session.quickActions, [created])
        XCTAssertTrue(session.prompts.isEmpty)
        XCTAssertTrue(session.photoPrompts.isEmpty)
    }

    /// Field Assist is injected on every read of the speed dial and never stored. A save that
    /// wrote it back would persist a copy that outlives the entitlement.
    func testSavingNeverPersistsTheInjectedFieldAssistAction() {
        let resolved = [QuickAction.fieldAssist, mine]
        let next = SpeedDialEditor.applying(draft(name: "Tea", prompt: "Make tea"), to: resolved)
        XCTAssertFalse(next.contains { $0.id == QuickAction.fieldAssist.id })
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.first?.id, mine.id)
        XCTAssertEqual(next.last?.label, "Tea")
    }

    // MARK: Edit

    func testEditingKeepsTheIdSoTheTileKeepsItsPlaceAndItsExposure() {
        let edited = draft(name: "Espresso", prompt: "Nearest espresso?", id: mine.id)
        let next = SpeedDialEditor.applying(edited, to: [mine])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].id, mine.id)
        XCTAssertEqual(next[0].label, "Espresso")
        XCTAssertEqual(HomeGridEntry.quickAction(next[0]).id, "quick:coffee")
    }

    func testEditingLoadsAnExistingActionRoundTrip() {
        let loaded = HomeActionDraft(editing: mine)
        XCTAssertEqual(loaded?.name, "Coffee")
        XCTAssertEqual(loaded?.kind, .prompt)
        XCTAssertEqual(loaded?.prompt, "Where is the nearest coffee?")
        XCTAssertEqual(SpeedDialEditor.applying(loaded!, to: [mine]), [mine])
    }

    // MARK: Built-ins are immune

    func testShippedGridActionsAreNotEditable() {
        for action in HomeGridAction.builtIns {
            XCTAssertNil(SpeedDialEditor.editableAction(for: .builtIn(action)),
                         "\(action.id) offered itself for editing")
        }
    }

    func testAppManagedSpeedDialActionsAreImmune() {
        for action in [QuickAction.fieldAssist, QuickAction.recordMeeting]
            + QuickAction.travelTemplates {
            XCTAssertFalse(SpeedDialEditor.isEditable(action), "\(action.id) is editable")
            XCTAssertFalse(SpeedDialEditor.isDeletable(action), "\(action.id) is deletable")
            XCTAssertNil(SpeedDialEditor.editableAction(for: .quickAction(action)))
            XCTAssertNil(SpeedDialEditor.deleting(id: action.id, from: [action],
                                                  exposure: SiriExposureConfig()))
        }
    }

    /// An advanced kind is still the wearer's data — it just isn't something this editor can
    /// express, so it may be deleted but not rewritten.
    func testAnAdvancedKindIsDeletableButNotEditable() {
        let ha = QuickAction(id: "lights", label: "Lights Off", icon: "lightbulb.slash",
                             type: .homeAssistant, haService: "light.turn_off")
        XCTAssertFalse(SpeedDialEditor.isEditable(ha))
        XCTAssertTrue(SpeedDialEditor.isDeletable(ha))
        XCTAssertNil(HomeActionDraft(editing: ha))
    }

    func testValidationRefusesToRewriteABuiltIn() {
        var edited = draft(name: "Record", id: QuickAction.recordMeeting.id)
        edited.prompt = "anything"
        XCTAssertEqual(SpeedDialEditor.validate(edited, against: [QuickAction.recordMeeting]),
                       .notEditable)
    }

    // MARK: Validation

    func testValidationRejectsEmptyNameAndPrompt() {
        XCTAssertEqual(SpeedDialEditor.validate(draft(name: "  "), against: []), .emptyName)
        XCTAssertEqual(SpeedDialEditor.validate(draft(prompt: " \n"), against: []), .emptyPrompt)
    }

    /// Names are spoken now, so two tiles with one name are two entities Siri cannot separate.
    func testValidationRejectsANameAlreadyOnTheGrid() {
        XCTAssertEqual(SpeedDialEditor.validate(draft(name: "meetings"), against: []),
                       .duplicateName(HomeGridAction.meetingsToday.label))
        XCTAssertEqual(SpeedDialEditor.validate(draft(name: "COFFEE"), against: [mine]),
                       .duplicateName("Coffee"))
    }

    func testValidationLetsAnActionKeepItsOwnName() {
        XCTAssertNil(SpeedDialEditor.validate(draft(id: mine.id), against: [mine]))
    }

    // MARK: Delete

    func testDeletingRemovesTheActionAndRevokesItsExposureTogether() {
        let key = SpeedDialEditor.exposureKey(forQuickActionId: mine.id)
        let exposure = SiriExposureConfig(enabledCapabilityIds: [key, "capture_flow:pump"])

        let deletion = SpeedDialEditor.deleting(id: mine.id, from: [mine], exposure: exposure)
        XCTAssertEqual(deletion?.actions, [])
        XCTAssertEqual(deletion?.revokedVoiceExposure, true)
        XCTAssertEqual(deletion?.exposure.enabledCapabilityIds, ["capture_flow:pump"],
                       "Deleting one action disturbed another capability's exposure")

        // And the catalog built from what's left offers nothing for the deleted id.
        let after = SiriActionCatalog(
            config: deletion!.exposure,
            harvested: CapabilityHarvester.harvest(
                gridEntries: HomeGridCatalog.available(quickActions: deletion!.actions)))
        XCTAssertNil(after.entry(id: "capability:grid_action:quick:coffee"))
    }

    func testDeletingAnUnexposedActionSaysSo() {
        let deletion = SpeedDialEditor.deleting(id: mine.id, from: [mine],
                                                exposure: SiriExposureConfig())
        XCTAssertEqual(deletion?.revokedVoiceExposure, false)
    }

    func testDeletingAnUnknownIdChangesNothing() {
        XCTAssertNil(SpeedDialEditor.deleting(id: "nope", from: [mine],
                                              exposure: SiriExposureConfig()))
    }

    // MARK: Icons

    func testTheCuratedIconSetIsUsableAndUnique() {
        let symbols = HomeActionIcons.curated.map(\.symbol)
        XCTAssertEqual(symbols.count, Set(symbols).count)
        XCTAssertTrue(HomeActionIcons.contains(HomeActionIcons.defaultSymbol))
        XCTAssertFalse(HomeActionIcons.contains("not.a.symbol"))
    }
}
