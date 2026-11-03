import XCTest
@testable import OpenGlasses

/// What counts as an agenda in a calendar event's notes, and what happens to one once found: it is
/// offered, kept for that meeting only, and stays out of everything that lists playbooks for reuse.
@MainActor
final class MeetingAgendaTests: XCTestCase {

    private let storageKeys = ["playbooks", "playbookSession"]
    private let ends = Date(timeIntervalSince1970: 2_000_000)

    override func setUp() {
        super.setUp()
        storageKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        storageKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func offer(_ title: String = "Weekly sync", items: [String] = ["Budget", "Hiring"]) -> MeetingAgendaOffer {
        MeetingAgendaOffer(title: title, items: items, endsAt: ends)
    }

    /// What earlier versions wrote for an event with these notes.
    private func savedByEarlierVersion(_ title: String, notes: String, steps: [String]) -> Playbook {
        Playbook(name: title, icon: "person.3", steps: steps.map { PlaybookStep(title: $0) }, referenceText: notes)
    }

    // MARK: - Rule: what isn't an agenda

    func testPlainInviteTextIsNotAnAgenda() {
        let invite = """
        Hi both,
        Looking forward to catching up on Thursday.
        Join Zoom Meeting
        https://example.zoom.us/j/123456789
        Meeting ID: 123 456 789
        Passcode: 424242
        """
        XCTAssertEqual(MeetingAgenda.items(in: invite), [])
    }

    func testTwoPlainLinesAreNotAnAgenda() {
        XCTAssertEqual(MeetingAgenda.items(in: "Budget\nHiring"), [])
    }

    func testOneItemIsNotAList() {
        XCTAssertEqual(MeetingAgenda.items(in: "- Bring your laptop"), [])
    }

    func testAMarkerNeedsTheSpaceAfterIt() {
        XCTAssertEqual(MeetingAgenda.items(in: "-5 degrees\n-10 degrees\n*bold*\n1.5 hours\n2.5 hours"), [])
    }

    func testNumbersThatDoNotCountUpAreNotAList() {
        XCTAssertEqual(MeetingAgenda.items(in: "10. Bring laptops\n25. Parking is out back"), [])
    }

    func testAnItemNeedsALetter() {
        XCTAssertEqual(MeetingAgenda.items(in: "- 555 1234\n- 555 9876"), [])
    }

    func testAListWithALinkIsJoinDetailsNotAnAgenda() {
        let joinDetails = """
        - Join: https://example.zoom.us/j/123
        - Passcode: abc
        - Dial in: 555 1234
        """
        XCTAssertEqual(MeetingAgenda.items(in: joinDetails), [])
        XCTAssertEqual(MeetingAgenda.items(in: "- Intro\n- Slides at www.example.com"), [])
    }

    func testAChangeOfMarkerEndsTheRun() {
        XCTAssertEqual(MeetingAgenda.items(in: "- Budget\n* Hiring"), [])
    }

    func testPlainLineBetweenItemsEndsTheRun() {
        XCTAssertEqual(MeetingAgenda.items(in: "- Budget\nHi all\n* Hiring"), [])
    }

    // MARK: - Rule: what is

    func testBulletsAreAnAgenda() {
        XCTAssertEqual(MeetingAgenda.items(in: "- Budget\n- Hiring"), ["Budget", "Hiring"])
        XCTAssertEqual(MeetingAgenda.items(in: "* Budget\n* Hiring"), ["Budget", "Hiring"])
        XCTAssertEqual(MeetingAgenda.items(in: "• Budget\n• Hiring"), ["Budget", "Hiring"])
        XCTAssertEqual(MeetingAgenda.items(in: "· Budget\n· Hiring"), ["Budget", "Hiring"])
        XCTAssertEqual(MeetingAgenda.items(in: "・ 予算\n・ 採用"),
                       ["予算", "採用"])
    }

    func testNumbersAreAnAgenda() {
        XCTAssertEqual(MeetingAgenda.items(in: "1. Budget\n2. Hiring"), ["Budget", "Hiring"])
        XCTAssertEqual(MeetingAgenda.items(in: "1) Budget\n2) Hiring"), ["Budget", "Hiring"])
        XCTAssertEqual(MeetingAgenda.items(in: "1、预算\n2、招聘"), ["预算", "招聘"])
    }

    func testOnlyTheListIsTakenFromAnInvite() {
        let invite = """
        Hi all, here's the plan for Thursday.

        Agenda:
        1. Budget
        2. Hiring
        3. Next steps

        Join Zoom Meeting
        https://example.zoom.us/j/123456789
        Passcode: 424242
        """
        XCTAssertEqual(MeetingAgenda.items(in: invite), ["Budget", "Hiring", "Next steps"])
    }

    func testBlankLinesBetweenItemsAreFine() {
        XCTAssertEqual(MeetingAgenda.items(in: "- Budget\n\n- Hiring\n\n\n- Close"), ["Budget", "Hiring", "Close"])
    }

    func testIndentedDetailIsSkipped() {
        let notes = """
        1. Budget
           - Q3 numbers
           Owner: finance
        2. Hiring
        """
        XCTAssertEqual(MeetingAgenda.items(in: notes), ["Budget", "Hiring"])
    }

    func testAnIndentedListIsStillAList() {
        XCTAssertEqual(MeetingAgenda.items(in: "  - Budget\n  - Hiring"), ["Budget", "Hiring"])
    }

    func testAJoinDetailsListDoesNotHideTheAgendaAfterIt() {
        let notes = """
        - Join: https://example.zoom.us/j/123
        - Passcode: abc

        Agenda
        - Budget
        - Hiring
        """
        XCTAssertEqual(MeetingAgenda.items(in: notes), ["Budget", "Hiring"])
    }

    // MARK: - The switch

    func testNothingIsOfferedWhileTheSwitchIsOff() {
        XCTAssertNil(MeetingAgenda.offer(title: "Sync", notes: "- Budget\n- Hiring", endsAt: ends, enabled: false))
    }

    func testAnEventWithoutAnAgendaIsNotOffered() {
        XCTAssertNil(MeetingAgenda.offer(title: "Sync", notes: "Budget\nHiring", endsAt: ends, enabled: true))
        XCTAssertNil(MeetingAgenda.offer(title: "Sync", notes: nil, endsAt: ends, enabled: true))
    }

    func testAnOfferCarriesOnlyTheItems() {
        XCTAssertEqual(
            MeetingAgenda.offer(title: "Sync", notes: "Dial 555 1234\n- Budget\n- Hiring", endsAt: ends, enabled: true),
            MeetingAgendaOffer(title: "Sync", items: ["Budget", "Hiring"], endsAt: ends)
        )
    }

    // MARK: - Offered, not started

    func testAnOfferStartsNothing() {
        let store = PlaybookStore()
        XCTAssertTrue(store.offerMeetingAgenda(offer()))
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.offeredMeetingAgenda?.steps.map(\.title), ["Budget", "Hiring"])
    }

    func testAnOfferDoesNotInterruptARunningPlaybook() {
        let store = PlaybookStore()
        store.add(Playbook(id: "mine", name: "Mine", steps: [PlaybookStep(title: "One")]))
        _ = store.startPlaybook("mine")

        XCTAssertFalse(store.offerMeetingAgenda(offer()))
        XCTAssertEqual(store.activeSession?.playbookId, "mine")
        XCTAssertNil(store.meetingAgenda)
    }

    func testAnOfferCanBeStartedAndFollowed() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        XCTAssertTrue(store.startPlaybook(MeetingAgenda.playbookID).contains("Budget"))
        XCTAssertNil(store.offeredMeetingAgenda)
        XCTAssertTrue(store.nextStep().contains("Hiring"))
    }

    func testTheInviteTextIsNotCarriedIntoTheAssistantContext() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        _ = store.startPlaybook(MeetingAgenda.playbookID)
        XCTAssertEqual(store.meetingAgenda?.referenceText, "")
        XCTAssertFalse(store.playbookContext()?.contains("REFERENCE MATERIAL") ?? true)
    }

    func testAnUnstartedOfferGivesTheAssistantNothing() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        XCTAssertNil(store.playbookContext())
    }

    // MARK: - Kept for the meeting only

    func testAnAgendaIsNeverSaved() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        _ = store.startPlaybook(MeetingAgenda.playbookID)
        _ = store.addNoteToCurrentStep("Written to disk by the store's own save")

        let relaunched = PlaybookStore()
        XCTAssertNil(relaunched.meetingAgenda)
        XCTAssertNil(relaunched.activeSession)
    }

    func testRepeatsOfAMeetingDoNotPileUp() {
        let store = PlaybookStore()
        let before = store.playbooks.count
        for _ in 0..<5 { _ = store.offerMeetingAgenda(offer()) }
        XCTAssertEqual(store.playbooks.count, before + 1)
    }

    func testANewOfferReplacesTheLastOne() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer("First"))
        _ = store.offerMeetingAgenda(offer("Second"))
        XCTAssertEqual(store.meetingAgenda?.name, "Second")
    }

    func testFinishingAnAgendaRemovesIt() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        _ = store.startPlaybook(MeetingAgenda.playbookID)
        XCTAssertTrue(store.finishPlaybook().contains("Weekly sync"))
        XCTAssertNil(store.meetingAgenda)
        XCTAssertNil(store.activeSession)
    }

    func testWorkingThroughTheLastStepRemovesIt() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        _ = store.startPlaybook(MeetingAgenda.playbookID)
        _ = store.nextStep()
        _ = store.nextStep()
        XCTAssertNil(store.meetingAgenda)
    }

    func testAnOfferLapsesWhenTheMeetingEnds() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        store.expireMeetingAgenda(now: ends.addingTimeInterval(-1))
        XCTAssertNotNil(store.meetingAgenda)
        store.expireMeetingAgenda(now: ends)
        XCTAssertNil(store.meetingAgenda)
    }

    func testAnAgendaBeingFollowedSurvivesAnOverrun() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        _ = store.startPlaybook(MeetingAgenda.playbookID)
        store.expireMeetingAgenda(now: ends.addingTimeInterval(3600))
        XCTAssertNotNil(store.meetingAgenda)
    }

    func testTurningOffersOffWithdrawsTheOfferButNotARunningAgenda() {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        store.withdrawMeetingAgenda()
        XCTAssertNil(store.meetingAgenda)

        _ = store.offerMeetingAgenda(offer())
        _ = store.startPlaybook(MeetingAgenda.playbookID)
        store.withdrawMeetingAgenda()
        XCTAssertNotNil(store.meetingAgenda)
    }

    func testTheAgendaIDCannotMeetANameDerivedID() {
        XCTAssertNotEqual(Playbook(name: "calendar:agenda").id, MeetingAgenda.playbookID)
    }

    // MARK: - Saved by earlier versions

    func testAPlaybookSavedByAnEarlierVersionIsRecognised() {
        let notes = "Hi both,\nCatching up Thursday\n- Passcode 424242"
        let saved = savedByEarlierVersion("Coffee with Sam", notes: notes,
                                          steps: ["Hi both,", "Catching up Thursday", "Passcode 424242"])
        XCTAssertTrue(MeetingAgenda.wasSavedFromCalendar(saved))
        XCTAssertTrue(saved.isFromCalendar)
    }

    func testTheWearersOwnPlaybooksAreNotMistakenForOne() {
        for playbook in PlaybookStore.defaults {
            XCTAssertFalse(MeetingAgenda.wasSavedFromCalendar(playbook), playbook.name)
        }
        let edited = savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring", "Added by me"])
        XCTAssertFalse(MeetingAgenda.wasSavedFromCalendar(edited))

        var withDetail = savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"])
        withDetail.steps[0].detail = "Mine"
        XCTAssertFalse(MeetingAgenda.wasSavedFromCalendar(withDetail))

        let otherIcon = Playbook(name: "Sync", steps: [PlaybookStep(title: "Budget"), PlaybookStep(title: "Hiring")],
                                 referenceText: "Budget\nHiring")
        XCTAssertFalse(MeetingAgenda.wasSavedFromCalendar(otherIcon))
    }

    func testRepeatsOfASavedMeetingShowAsOneRow() {
        let store = PlaybookStore()
        for _ in 0..<3 { store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"])) }
        XCTAssertEqual(store.savedMeetingPlaybooks.map(\.id), ["sync"])
    }

    func testRemovingSavedMeetingsLeavesTheWearersPlaybooks() {
        let store = PlaybookStore()
        let mine = store.playbooks.map(\.id)
        for _ in 0..<3 { store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"])) }

        store.removeSavedMeetingPlaybooks()

        XCTAssertEqual(store.playbooks.map(\.id), mine)
        XCTAssertEqual(PlaybookStore().playbooks.map(\.id), mine)
    }

    func testRemovingOneSavedMeetingRemovesItsRepeats() {
        let store = PlaybookStore()
        for _ in 0..<3 { store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"])) }
        store.add(savedByEarlierVersion("Retro", notes: "Wins\nMisses", steps: ["Wins", "Misses"]))

        store.removeSavedMeetingPlaybooks(id: "sync")

        XCTAssertEqual(store.savedMeetingPlaybooks.map(\.id), ["retro"])
    }

    func testRemovingSavedMeetingsSparesAWearersPlaybookWithTheSameName() {
        let store = PlaybookStore()
        store.add(Playbook(name: "Sync", steps: [PlaybookStep(title: "Mine")]))
        store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"]))

        store.removeSavedMeetingPlaybooks(id: "sync")

        XCTAssertEqual(store.playbook(byId: "sync")?.steps.map(\.title), ["Mine"])
    }

    func testRemovingTheSavedMeetingInProgressEndsItsSession() {
        let store = PlaybookStore()
        store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"]))
        _ = store.startPlaybook("sync")

        store.removeSavedMeetingPlaybooks()

        XCTAssertNil(store.activeSession)
        XCTAssertNil(PlaybookStore().activeSession)
    }

    func testASessionAnEarlierVersionStartedIsEndedOnLaunch() {
        let store = PlaybookStore()
        store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"]))
        _ = store.startPlaybook("sync")

        let relaunched = PlaybookStore()

        XCTAssertNil(relaunched.activeSession)
        XCTAssertNil(relaunched.playbookContext())
        XCTAssertNotNil(relaunched.playbook(byId: "sync"), "ending the session leaves removal to the wearer")
    }

    func testTheWearersOwnSessionSurvivesLaunch() {
        let store = PlaybookStore()
        _ = store.startPlaybook("meeting-agenda")
        XCTAssertEqual(PlaybookStore().activeSession?.playbookId, "meeting-agenda")
    }

    // MARK: - Reuse and Spotlight

    func testReusablePlaybooksLeaveOutCalendarOnes() {
        let store = PlaybookStore()
        let mine = store.playbooks.map(\.id)
        store.add(savedByEarlierVersion("Sync", notes: "Budget\nHiring", steps: ["Budget", "Hiring"]))
        _ = store.offerMeetingAgenda(offer())

        XCTAssertEqual(store.reusablePlaybooks.map(\.id), mine)
    }

    func testCalendarPlaybooksAreNotIndexed() {
        let store = PlaybookStore()
        store.add(savedByEarlierVersion("Coffee with Sam", notes: "Budget\nHiring", steps: ["Budget", "Hiring"]))
        _ = store.offerMeetingAgenda(offer("Weekly sync"))

        let titles = SiriContentAdapters.playbooks(store.playbooks).map(\.title)

        XCTAssertFalse(titles.contains("Coffee with Sam"))
        XCTAssertFalse(titles.contains("Weekly sync"))
        XCTAssertTrue(titles.contains("Site Visit"))
    }

    func testAMeetingAlreadyInSpotlightIsDeletedOnTheNextRefresh() {
        let saved = savedByEarlierVersion("Coffee with Sam", notes: "Budget\nHiring", steps: ["Budget", "Hiring"])
        let donated = IndexableRecord(
            contentType: .playbook, itemId: saved.id, title: saved.name,
            text: "Budget. Hiring", keywords: ["playbook"], date: saved.createdAt
        )
        let plan = IndexPlanner.plan(current: SiriContentAdapters.playbooks([saved]),
                                     previous: IndexPlanner.snapshot([donated]))
        XCTAssertEqual(plan.deletions, [donated.id])
    }

    func testToolSaysSoWhenNoAgendaIsOnOffer() async throws {
        var tool = PlaybookTool()
        tool.playbookStore = PlaybookStore()
        let result = try await tool.execute(args: ["action": "start", "playbook_id": MeetingAgenda.playbookID])
        XCTAssertEqual(result, "No meeting agenda is on offer right now.")
    }

    func testToolStartsAnOfferedAgenda() async throws {
        let store = PlaybookStore()
        _ = store.offerMeetingAgenda(offer())
        var tool = PlaybookTool()
        tool.playbookStore = store
        let result = try await tool.execute(args: ["action": "start", "playbook_id": MeetingAgenda.playbookID])
        XCTAssertTrue(result.contains("Budget"))
        XCTAssertEqual(store.activeSession?.playbookId, MeetingAgenda.playbookID)
    }
}
