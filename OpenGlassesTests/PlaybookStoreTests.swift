import XCTest
@testable import OpenGlasses

/// Tests for PlaybookStore state machine: CRUD, session navigation, context generation.
@MainActor
final class PlaybookStoreTests: XCTestCase {

    private let storageKeys = ["playbooks", "playbookSession"]

    override func setUp() {
        super.setUp()
        for key in storageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in storageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Data Model

    func testPlaybookIDGeneratedFromName() {
        let pb = Playbook(name: "Site Visit Checklist")
        XCTAssertEqual(pb.id, "site-visit-checklist")
    }

    func testPlaybookIDStripsSpecialChars() {
        let pb = Playbook(name: "Test @ #123!")
        // Only letters, numbers, hyphens survive
        XCTAssertFalse(pb.id.contains("@"))
        XCTAssertFalse(pb.id.contains("#"))
        XCTAssertFalse(pb.id.contains("!"))
    }

    func testPlaybookStepDefaultValues() {
        let step = PlaybookStep(title: "Test Step")
        XCTAssertFalse(step.isCompleted)
        XCTAssertTrue(step.notes.isEmpty)
        XCTAssertTrue(step.detail.isEmpty)
    }

    // MARK: - CRUD

    func testAddAndRetrievePlaybook() {
        let store = PlaybookStore()
        let pb = Playbook(id: "test-pb", name: "Test Playbook", steps: [
            PlaybookStep(title: "Step 1"),
            PlaybookStep(title: "Step 2"),
        ])
        store.add(pb)

        XCTAssertNotNil(store.playbook(byId: "test-pb"))
        XCTAssertEqual(store.playbook(byId: "test-pb")?.name, "Test Playbook")
    }

    func testFindPlaybookByName() {
        let store = PlaybookStore()
        let pb = Playbook(id: "find-test", name: "My Special Playbook")
        store.add(pb)

        XCTAssertNotNil(store.playbook(byName: "special"))
        XCTAssertNotNil(store.playbook(byName: "MY SPECIAL"))
        XCTAssertNil(store.playbook(byName: "nonexistent"))
    }

    func testUpdatePlaybook() {
        let store = PlaybookStore()
        var pb = Playbook(id: "update-test", name: "Original")
        store.add(pb)

        pb.name = "Updated"
        store.update(pb)

        XCTAssertEqual(store.playbook(byId: "update-test")?.name, "Updated")
    }

    func testDeletePlaybook() {
        let store = PlaybookStore()
        let pb = Playbook(id: "delete-test", name: "To Delete")
        store.add(pb)

        store.delete(id: "delete-test")
        XCTAssertNil(store.playbook(byId: "delete-test"))
    }

    func testDeleteActivePlaybookClearsSession() {
        let store = PlaybookStore()
        let pb = Playbook(id: "active-delete", name: "Active", steps: [PlaybookStep(title: "S1")])
        store.add(pb)
        _ = store.startPlaybook("active-delete")
        XCTAssertNotNil(store.activeSession)

        store.delete(id: "active-delete")
        XCTAssertNil(store.activeSession)
    }

    // MARK: - Session Navigation

    func testStartPlaybook() {
        let store = PlaybookStore()
        let pb = Playbook(id: "nav-test", name: "Navigation Test", steps: [
            PlaybookStep(title: "First"),
            PlaybookStep(title: "Second"),
            PlaybookStep(title: "Third"),
        ])
        store.add(pb)

        let result = store.startPlaybook("nav-test")
        XCTAssertTrue(result.contains("Started"))
        XCTAssertTrue(result.contains("Step 1 of 3"))
        XCTAssertEqual(store.activeSession?.currentStepIndex, 0)
    }

    func testStartPlaybookResetsCompletion() {
        let store = PlaybookStore()
        var step1 = PlaybookStep(title: "S1")
        step1.isCompleted = true
        let pb = Playbook(id: "reset-test", name: "Reset", steps: [step1, PlaybookStep(title: "S2")])
        store.add(pb)

        _ = store.startPlaybook("reset-test")
        let step = store.playbook(byId: "reset-test")?.steps.first
        XCTAssertFalse(step?.isCompleted ?? true, "Starting a playbook should reset step completion")
    }

    func testStartNonexistentPlaybook() {
        let store = PlaybookStore()
        let result = store.startPlaybook("nonexistent")
        XCTAssertTrue(result.contains("not found"))
    }

    func testStartEmptyPlaybook() {
        let store = PlaybookStore()
        let pb = Playbook(id: "empty", name: "Empty", steps: [])
        store.add(pb)
        let result = store.startPlaybook("empty")
        XCTAssertTrue(result.contains("no steps"))
    }

    func testNextStep() {
        let store = PlaybookStore()
        let pb = Playbook(id: "next-test", name: "Next", steps: [
            PlaybookStep(title: "A"),
            PlaybookStep(title: "B"),
            PlaybookStep(title: "C"),
        ])
        store.add(pb)
        _ = store.startPlaybook("next-test")

        let result = store.nextStep()
        XCTAssertTrue(result.contains("Step 2 of 3"))
        XCTAssertEqual(store.activeSession?.currentStepIndex, 1)
    }

    func testNextStepMarksCurrentComplete() {
        let store = PlaybookStore()
        let pb = Playbook(id: "complete-test", name: "Complete", steps: [
            PlaybookStep(title: "A"),
            PlaybookStep(title: "B"),
        ])
        store.add(pb)
        _ = store.startPlaybook("complete-test")
        _ = store.nextStep()

        let step = store.playbook(byId: "complete-test")?.steps[0]
        XCTAssertTrue(step?.isCompleted ?? false, "Previous step should be marked complete")
    }

    func testNextStepAtEndFinishesPlaybook() {
        let store = PlaybookStore()
        let pb = Playbook(id: "finish-test", name: "Finish", steps: [
            PlaybookStep(title: "Only"),
        ])
        store.add(pb)
        _ = store.startPlaybook("finish-test")

        let result = store.nextStep()
        XCTAssertTrue(result.contains("Finished"))
        XCTAssertNil(store.activeSession)
    }

    func testPreviousStep() {
        let store = PlaybookStore()
        let pb = Playbook(id: "prev-test", name: "Prev", steps: [
            PlaybookStep(title: "A"),
            PlaybookStep(title: "B"),
        ])
        store.add(pb)
        _ = store.startPlaybook("prev-test")
        _ = store.nextStep()

        let result = store.previousStep()
        XCTAssertTrue(result.contains("Step 1"))
        XCTAssertEqual(store.activeSession?.currentStepIndex, 0)
    }

    func testPreviousStepAtStartReturnsMessage() {
        let store = PlaybookStore()
        let pb = Playbook(id: "prev-start", name: "Start", steps: [
            PlaybookStep(title: "First"),
            PlaybookStep(title: "Second"),
        ])
        store.add(pb)
        _ = store.startPlaybook("prev-start")

        let result = store.previousStep()
        XCTAssertTrue(result.contains("first step"))
    }

    func testNoActivePlaybookMessages() {
        let store = PlaybookStore()
        XCTAssertTrue(store.nextStep().contains("No active"))
        XCTAssertTrue(store.previousStep().contains("No active"))
        XCTAssertTrue(store.currentStatus().contains("No active"))
    }

    // MARK: - Notes

    func testAddNoteToStep() {
        let store = PlaybookStore()
        let pb = Playbook(id: "note-test", name: "Notes", steps: [PlaybookStep(title: "S1")])
        store.add(pb)
        _ = store.startPlaybook("note-test")

        let result = store.addNoteToCurrentStep("Patient blood pressure 120/80")
        XCTAssertTrue(result.contains("Note added"))

        let step = store.playbook(byId: "note-test")?.steps[0]
        XCTAssertEqual(step?.notes, "Patient blood pressure 120/80")
    }

    func testMultipleNotesAppendWithSemicolon() {
        let store = PlaybookStore()
        let pb = Playbook(id: "multi-note", name: "Multi", steps: [PlaybookStep(title: "S1")])
        store.add(pb)
        _ = store.startPlaybook("multi-note")

        _ = store.addNoteToCurrentStep("First note")
        _ = store.addNoteToCurrentStep("Second note")

        let step = store.playbook(byId: "multi-note")?.steps[0]
        XCTAssertEqual(step?.notes, "First note; Second note")
    }

    // MARK: - Finish Summary

    func testFinishIncludesNotesInSummary() {
        let store = PlaybookStore()
        let pb = Playbook(id: "summary-test", name: "Summary", steps: [
            PlaybookStep(title: "Check Tires"),
        ])
        store.add(pb)
        _ = store.startPlaybook("summary-test")
        _ = store.addNoteToCurrentStep("Left rear low pressure")

        let result = store.finishPlaybook()
        XCTAssertTrue(result.contains("Finished"))
        XCTAssertTrue(result.contains("Left rear low pressure"))
    }

    // MARK: - Context Generation

    func testPlaybookContextNilWhenNoActiveSession() {
        let store = PlaybookStore()
        XCTAssertNil(store.playbookContext())
    }

    func testPlaybookContextIncludesStepInfo() {
        let store = PlaybookStore()
        let pb = Playbook(id: "ctx-test", name: "Context Test", steps: [
            PlaybookStep(title: "Inspect", detail: "Look at the thing"),
            PlaybookStep(title: "Report"),
        ])
        store.add(pb)
        _ = store.startPlaybook("ctx-test")

        let ctx = store.playbookContext()
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.contains("Context Test"))
        XCTAssertTrue(ctx!.contains("Step 1 of 2"))
        XCTAssertTrue(ctx!.contains("Inspect"))
        XCTAssertTrue(ctx!.contains("Look at the thing"))
    }

    func testPlaybookContextIncludesReferenceText() {
        let store = PlaybookStore()
        let pb = Playbook(id: "ref-test", name: "Ref", steps: [PlaybookStep(title: "S1")],
                          referenceText: "Important reference info here")
        store.add(pb)
        _ = store.startPlaybook("ref-test")

        let ctx = store.playbookContext()
        XCTAssertTrue(ctx!.contains("REFERENCE MATERIAL"))
        XCTAssertTrue(ctx!.contains("Important reference info here"))
    }

    // MARK: - Defaults

    func testDefaultPlaybooksExist() {
        XCTAssertFalse(PlaybookStore.defaults.isEmpty, "Should have default playbooks")
        let names = PlaybookStore.defaults.map(\.name)
        XCTAssertTrue(names.contains("Patient Encounter"), "Should include Patient Encounter template")
        XCTAssertTrue(names.contains("Meeting Agenda"), "Should include Meeting Agenda template")
    }
}
