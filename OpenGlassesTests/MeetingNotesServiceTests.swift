import XCTest
@testable import OpenGlasses

/// Plan MX P4/P6 — the notes service: the routing gates, the fallback, queueing a write for after
/// the turn, owing, and writing owed notes later — never overlapping a turn, never abandoning a
/// step.
@MainActor
final class MeetingNotesServiceTests: XCTestCase {

    private var workspace: URL!
    private var keep = true
    private var medical = false
    private var turn = false
    private var inputs = MeetingNotesRoutePolicy.Inputs(provider: .anthropic, contextTokens: 200_000,
                                                        isOnline: true, appActive: true)
    private var completed: [(OwedMeetingNotes, MeetingNotes)] = []

    nonisolated private static let reply = #"{"title": "Plant room", "overview": "The chiller.", "decisions": ["Keep the supplier"], "action_items": [{"task": "Order the filter", "owner": "Ana"}]}"#

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotesServiceTests_\(UUID().uuidString)", isDirectory: true)
        keep = true
        medical = false
        turn = false
        inputs = .init(provider: .anthropic, contextTokens: 200_000, isOnline: true, appActive: true)
        completed = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    private func makeStore(now: Date = Date()) -> MeetingNotesOwedStore {
        MeetingNotesOwedStore(directory: workspace, now: { now }, isEnabled: { [unowned self] in keep },
                              hipaaMode: { [unowned self] in medical })
    }

    private func makeService(store: MeetingNotesOwedStore, model: FakeNotesModel) -> MeetingNotesService {
        let service = MeetingNotesService(store: store)
        service.turnWaitStep = 0.01
        service.turnWaitSteps = 5
        service.configure(.init(
            complete: { try await model.complete($0, $1) },
            route: { [unowned self] in inputs },
            keepCaptionSessions: { [unowned self] in keep },
            medicalCompliance: { [unowned self] in medical },
            turnInFlight: { [unowned self] in turn },
            completeNote: { [unowned self] record, notes in completed.append((record, notes)) }))
        return service
    }

    private func request(saving: Bool = true, id: UUID = UUID(), lineCount: Int = 0) -> MeetingNotesRequest {
        let start = Date()
        var lines: [OwedMeetingNotes.Line] = [.init(text: "Ana: I'll order the filter.", at: start),
                                              .init(text: "Bob: We keep the supplier.", at: start.addingTimeInterval(60))]
        for index in 0..<lineCount {
            lines.append(.init(text: "Line \(index) about the chiller, the roof plant and the filter on order",
                               at: start.addingTimeInterval(Double(61 + index))))
        }
        return MeetingNotesRequest(id: id, lines: lines, startedAt: start,
                                   endedAt: lines.last?.at ?? start, saving: saving)
    }

    /// Wait (briefly) until `condition` holds.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAnUnconfiguredServiceTakesThePhonesNotes() async {
        let service = MeetingNotesService(store: makeStore())
        XCTAssertEqual(service.queue(request()), .fallback(.notConfigured))
    }

    func testQueueingNeverCallsTheModel() async {
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let service = makeService(store: makeStore(), model: model)
        turn = true
        XCTAssertEqual(service.queue(request()), .queued)
        service.startQueuedWrites()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await model.calls.count
        XCTAssertEqual(calls, 0, "inside a turn the model is never called")
        XCTAssertEqual(service.queuedIDs.count, 1)
    }

    func testAQueuedWriteRunsOnlyOnceTheTurnIsOverAndCompletesTheNote() async throws {
        let store = makeStore()
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let service = makeService(store: store, model: model)
        service.turnWaitSteps = 500
        turn = true
        let id = UUID()
        XCTAssertEqual(service.queue(request(id: id)), .queued)
        XCTAssertEqual(store.record(id: id)?.reason, .afterTurn, "held, so a kill before it is written recovers it")
        service.startQueuedWrites()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let during = await model.calls.count
        XCTAssertEqual(during, 0)

        turn = false
        await eventually { !completed.isEmpty }
        XCTAssertEqual(completed.map(\.0.id), [id])
        XCTAssertEqual(completed.first?.1.actionItems, [MeetingActionItem(task: "Order the filter", owner: "Ana")])
        XCTAssertNil(store.record(id: id), "settled")
        XCTAssertTrue(service.queuedIDs.isEmpty)
    }

    func testAQueuedWriteThatMayNotBeHeldIsWrittenFromMemory() async {
        keep = false
        let store = makeStore()
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let service = makeService(store: store, model: model)
        let id = UUID()
        XCTAssertEqual(service.queue(request(id: id)), .queued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "nothing written down")
        let written = await service.writeOwed(trigger: "afterTurn")
        XCTAssertEqual(written, 1)
        XCTAssertEqual(completed.map(\.0.id), [id])
    }

    func testATurnStartingMidWriteStopsFurtherStepsAndLeavesItOwed() async throws {
        let store = makeStore()
        inputs.contextTokens = 4_096
        let flag = TurnFlag()
        let model = FakeNotesModel { system, _, call in
            // The wearer starts a turn while the first part is being condensed.
            if call == 1 { await flag.set(true) }
            return system == MeetingNotesPrompt.condenseSystem ? "- point \(call)" : Self.reply
        }
        let service = MeetingNotesService(store: store)
        service.turnWaitStep = 0.01
        service.turnWaitSteps = 5
        service.configure(.init(
            complete: { try await model.complete($0, $1) },
            route: { [unowned self] in inputs },
            keepCaptionSessions: { true }, medicalCompliance: { false },
            turnInFlight: { flag.isOn },
            completeNote: { [unowned self] record, notes in completed.append((record, notes)) }))
        let id = UUID()
        XCTAssertEqual(service.queue(request(id: id, lineCount: 200)), .queued)

        let none = await service.writeOwed(trigger: "afterTurn")
        XCTAssertEqual(none, 0)
        let afterStop = await model.calls.count
        XCTAssertEqual(afterStop, 1, "the running step ends; no further step starts while the turn runs")
        let record = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(record.state, .owed)
        XCTAssertEqual(record.attempts, 0, "a stop for a turn is not a failed attempt")
        XCTAssertEqual(service.queuedIDs, [id], "still queued, to resume")
        XCTAssertTrue(completed.isEmpty)

        await flag.set(false)
        let written = await service.writeOwed(trigger: "afterTurn")
        XCTAssertEqual(written, 1)
        let calls = await model.calls
        let firstPart = calls[0].user
        XCTAssertEqual(calls.filter { $0.user == firstPart }.count, 1, "resumed from the next step")
        XCTAssertEqual(calls.last?.system, MeetingNotesPrompt.notesSystem)
        XCTAssertNil(store.record(id: id))
    }

    func testARunningStepIsNeverAbandoned() async {
        let flag = TurnFlag()
        let ended = TurnFlag()
        let model = FakeNotesModel { _, _, _ in
            await flag.set(true)                      // a turn starts mid-call
            try await Task.sleep(nanoseconds: 300_000_000)
            await ended.set(true)
            return Self.reply
        }
        let service = MeetingNotesService(store: makeStore())
        service.turnWaitStep = 0.01
        service.turnWaitSteps = 2
        service.configure(.init(
            complete: { try await model.complete($0, $1) },
            route: { [unowned self] in inputs },
            keepCaptionSessions: { true }, medicalCompliance: { false },
            turnInFlight: { flag.isOn },
            completeNote: { [unowned self] record, notes in completed.append((record, notes)) }))
        _ = service.queue(request())
        let written = await service.writeOwed(trigger: "afterTurn")
        XCTAssertTrue(ended.isOn, "the service returned only once the call had ended")
        XCTAssertEqual(written, 1, "the single step ran to its end and its notes were kept")
        XCTAssertEqual(completed.count, 1)
    }

    func testEveryGateThatForbidsACallIsTheFallbackWithNoCall() async {
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let service = makeService(store: makeStore(), model: model)
        inputs.provider = nil                        // no model, or Medical Compliance refused every one
        XCTAssertEqual(service.queue(request()), .fallback(.noModel))
        inputs = .init(provider: .openai, contextTokens: nil, isOnline: false, appActive: true)
        XCTAssertEqual(service.queue(request()), .fallback(.offline))
        _ = await service.writeOwed(trigger: "test")
        let calls = await model.calls.count
        XCTAssertEqual(calls, 0, "a forbidden route is never called")
        XCTAssertTrue(service.queuedIDs.isEmpty)
    }

    func testAFailedWriteAfterTheTurnStaysOwedForTheNextForeground() async {
        struct Boom: Error {}
        let store = makeStore()
        let model = FakeNotesModel { _, _, _ in throw Boom() }
        let service = makeService(store: store, model: model)
        let id = UUID()
        _ = service.queue(request(id: id))
        let written = await service.writeOwed(trigger: "afterTurn")
        XCTAssertEqual(written, 0)
        XCTAssertTrue(completed.isEmpty, "the note keeps the phone's notes")
        XCTAssertTrue(service.queuedIDs.isEmpty)
        XCTAssertEqual(store.record(id: id)?.state, .owed)
        XCTAssertEqual(store.record(id: id)?.attempts, 1)
    }

    func testTheOnDeviceModelInTheBackgroundOwesTheNotes() async throws {
        let store = makeStore()
        inputs = .init(provider: .local, contextTokens: 4_096, isOnline: true, appActive: false)
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let id = UUID()
        let outcome = makeService(store: store, model: model).queue(request(id: id))
        XCTAssertEqual(outcome, .owed(.appInBackground))
        let record = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(record.state, .owed)
        XCTAssertEqual(record.lines.count, 2)
        let calls = await model.calls.count
        XCTAssertEqual(calls, 0)
    }

    func testNothingIsOwedWithoutTheSwitchInTheModeOrForAnUnsavedSummary() async {
        inputs = .init(provider: .local, contextTokens: 4_096, isOnline: true, appActive: false)
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let store = makeStore()
        let service = makeService(store: store, model: model)

        keep = false
        XCTAssertEqual(service.queue(request()), .fallback(.cannotRunNow))
        keep = true
        medical = true
        XCTAssertEqual(service.queue(request()), .fallback(.cannotRunNow))
        medical = false
        XCTAssertEqual(service.queue(request(saving: false)), .fallback(.cannotRunNow))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "nothing was written")
    }

    func testOwedNotesAreWrittenWhenTheModelCanRunAndCompleteTheirNote() async throws {
        let store = makeStore()
        inputs = .init(provider: .local, contextTokens: 4_096, isOnline: true, appActive: false)
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let service = makeService(store: store, model: model)
        let id = UUID()
        _ = service.queue(request(id: id))

        // Still in the background: nothing is written.
        let none = await service.writeOwed(trigger: "test")
        XCTAssertEqual(none, 0)
        XCTAssertNotNil(store.record(id: id))

        inputs.appActive = true
        let written = await service.writeOwed(trigger: "test")
        XCTAssertEqual(written, 1)
        XCTAssertNil(store.record(id: id), "settled")
        XCTAssertEqual(completed.map(\.0.id), [id])
        XCTAssertEqual(completed.first?.1.title, "Plant room")
    }

    func testOwedNotesWaitForATurnInFlight() async {
        let store = makeStore()
        inputs = .init(provider: .local, contextTokens: 4_096, isOnline: true, appActive: false)
        let model = FakeNotesModel { _, _, _ in Self.reply }
        let service = makeService(store: store, model: model)
        service.turnWaitSteps = 3
        turn = true
        _ = service.queue(request())
        inputs.appActive = true
        let written = await service.writeOwed(trigger: "test")
        XCTAssertEqual(written, 0, "a turn that does not end leaves the notes owed")
        XCTAssertEqual(store.pending.count, 1)
        let calls = await model.calls.count
        XCTAssertEqual(calls, 0)
    }

    func testAFailedCatchUpCountsAnAttemptAndGivesUpAfterThree() async {
        struct Boom: Error {}
        let store = makeStore()
        inputs = .init(provider: .local, contextTokens: 4_096, isOnline: true, appActive: false)
        let model = FakeNotesModel { _, _, _ in throw Boom() }
        let service = makeService(store: store, model: model)
        let id = UUID()
        _ = service.queue(request(id: id))
        inputs.appActive = true
        for attempt in 1...2 {
            _ = await service.writeOwed(trigger: "test")
            XCTAssertEqual(store.record(id: id)?.attempts, attempt)
            XCTAssertEqual(store.record(id: id)?.state, .owed)
        }
        _ = await service.writeOwed(trigger: "test")
        XCTAssertNil(store.record(id: id), "the third failure gives up; the note keeps the phone's notes")
    }
}

/// A flag a fake model sets from its own task and the service reads on the main actor.
final class TurnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    func set(_ value: Bool) async {
        lock.withLock { on = value }
    }
}

/// Plan MX P6 — the owed store: its rule, its recovery after a kill, and its erasure.
@MainActor
final class MeetingNotesOwedStoreTests: XCTestCase {

    private var workspace: URL!

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotesOwedStoreTests_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    private func record(_ id: UUID = UUID(), began: Date = Date(), said: String = "The roof plant is fine",
                        state: OwedMeetingNotes.State = .owed) -> OwedMeetingNotes {
        OwedMeetingNotes(id: id, startedAt: began, endedAt: began, lines: [.init(text: said, at: began)],
                         state: state, reason: .appInBackground)
    }

    func testAWriteTheLastRunDidNotFinishIsOwedAtTheNextOpen() {
        let id = UUID()
        XCTAssertTrue(MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
            .hold(record(id, state: .writing)))
        let reopened = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        XCTAssertEqual(reopened.record(id: id)?.state, .owed)
        XCTAssertEqual(reopened.record(id: id)?.reason, .interrupted)
    }

    func testAReasonThisBuildDoesNotKnowReadsAsInterrupted() throws {
        let id = UUID()
        let store = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        var held = record(id)
        held.reason = .afterTurn
        XCTAssertTrue(store.hold(held))
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("afterTurn"))
        try Data(text.replacingOccurrences(of: "afterTurn", with: "someLaterReason").utf8).write(to: store.fileURL)
        let reopened = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        XCTAssertEqual(reopened.record(id: id)?.reason, .interrupted, "the record stays owed, the file readable")
    }

    func testNothingIsHeldWithTheSwitchOffOrInTheMode() {
        XCTAssertFalse(MeetingNotesOwedStore(directory: workspace, isEnabled: { false }, hipaaMode: { false })
            .hold(record()))
        XCTAssertFalse(MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { true })
            .hold(record()))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(MeetingNotesOwedStore.fileName).path))
    }

    func testTheSwitchGoingOffOrTheModeComingOnTakesEverything() {
        var keep = true
        var mode = false
        let store = MeetingNotesOwedStore(directory: workspace, isEnabled: { keep }, hipaaMode: { mode })
        store.hold(record())
        keep = false
        XCTAssertTrue(store.pending.isEmpty)
        keep = true
        store.hold(record())
        mode = true
        XCTAssertEqual(store.prune(), 1)
    }

    func testARecordGoesSevenDaysAfterItsMeetingBegan() {
        let now = Date()
        let store = MeetingNotesOwedStore(directory: workspace, now: { now }, isEnabled: { true }, hipaaMode: { false })
        store.hold(record(began: now.addingTimeInterval(-8 * 86_400)))
        store.hold(record(began: now.addingTimeInterval(-3_600)))
        XCTAssertEqual(store.pending.count, 1)
    }

    func testAtMostThreeMeetingsAreOwedAndTheOldestGoes() {
        let now = Date()
        let store = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() { store.hold(record(id, began: now.addingTimeInterval(Double(index)))) }
        XCTAssertEqual(store.pending.map(\.id), Array(ids.dropFirst()))
    }

    func testTheSubjectErasureTakesAMeetingThatMentionsThemWhole() async {
        let store = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        store.hold(record(said: "Ana Canary will order the filter"))
        store.hold(record(said: "Nothing to see"))
        var stores = SubjectErasureCoordinator.Stores()
        stores.owedMeetingNotes = store
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.person("ana canary"))
        XCTAssertEqual(receipts.first { $0.store == .owedMeetingNotes }?.removed, 1)
        XCTAssertEqual(store.pending.map { $0.lines[0].text }, ["Nothing to see"])
    }

    func testDeleteAllAndTheRegistry() {
        let store = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        store.hold(record())
        store.deleteAll()
        XCTAssertTrue(store.pending.isEmpty)
        let entry = SensitiveStore.owedMeetingNotes.record
        XCTAssertEqual(entry.subjectLinkage, .thirdPartySubject)
        XCTAssertTrue(entry.backupExcluded)
        XCTAssertTrue(SubjectErasureCoordinator.order.contains(.owedMeetingNotes))
    }

    func testTheFileIsOutOfBackup() throws {
        let store = MeetingNotesOwedStore(directory: workspace, isEnabled: { true }, hipaaMode: { false })
        XCTAssertTrue(store.hold(record()))
        let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}

/// Plan MX P5 — an action item into Reminders, once.
@MainActor
final class MeetingActionRemindersTests: XCTestCase {

    private final class FakeSaver: MeetingReminderSaving {
        var access = true
        var fail = false
        var saved: [(title: String, dueDate: Date?, notes: String?)] = []
        func requestRemindersAccess() async throws -> Bool { access }
        func saveReminder(title: String, dueDate: Date?, hasTime: Bool, notes: String?) throws {
            struct Refused: Error {}
            if fail { throw Refused() }
            saved.append((title, dueDate, notes))
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private let meetingId = UUID().uuidString

    override func setUp() {
        super.setUp()
        suite = "MeetingActionRemindersTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let record = MeetingActionItemsRecord(items: [
            MeetingActionItem(task: "Order the filter", owner: "Ana", due: "Friday"),
            MeetingActionItem(task: "Call the supplier"),
        ])
        SavedNotesStore.append(title: "Meeting Summary — test", content: "x", date: "2026-11-23T10:00:00Z",
                               extra: [MeetingActionItemsRecord.meetingIdKey: meetingId,
                                       MeetingActionItemsRecord.noteKey: record.encoded() ?? ""],
                               defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAnItemIsAddedOnceAndStaysAdded() async {
        let saver = FakeSaver()
        let first = await MeetingActionReminders.add(index: 0, meetingId: meetingId, meetingTitle: "Plant room",
                                                     saver: saver, defaults: defaults)
        guard case .added(let record) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(record.entries[0].addedToReminders)
        XCTAssertFalse(record.entries[1].addedToReminders)
        let second = await MeetingActionReminders.add(index: 0, meetingId: meetingId, meetingTitle: "Plant room",
                                                      saver: saver, defaults: defaults)
        XCTAssertEqual(second, .alreadyAdded)
        XCTAssertEqual(saver.saved.count, 1, "one reminder, however many presses")
        XCTAssertEqual(MeetingActionReminders.record(meetingId: meetingId, defaults: defaults)?.entries[0].addedToReminders,
                       true, "read back from the saved note")
    }

    func testTheReminderCarriesTheTaskWithTheOwnerAndDueAsText() async {
        let saver = FakeSaver()
        _ = await MeetingActionReminders.add(index: 0, meetingId: meetingId, meetingTitle: "Plant room",
                                             saver: saver, defaults: defaults)
        XCTAssertEqual(saver.saved.first?.title, "Order the filter")
        XCTAssertNil(saver.saved.first?.dueDate, "\"Friday\" is not a date the phone can be sure of")
        XCTAssertTrue(saver.saved.first?.notes?.contains("Ana") == true)
        XCTAssertTrue(saver.saved.first?.notes?.contains("Friday") == true)
    }

    func testAnExactFutureDueBecomesTheDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // January 2027
        let draft = MeetingReminderDraft.make(item: MeetingActionItem(task: "Send it", due: "2030-03-01T09:00:00Z"),
                                              meetingTitle: nil, now: now)
        XCTAssertNotNil(draft.dueDate)
        XCTAssertNil(draft.notes)
        let past = MeetingReminderDraft.make(item: MeetingActionItem(task: "Send it", due: "2020-03-01T09:00:00Z"),
                                             meetingTitle: nil, now: now)
        XCTAssertNil(past.dueDate)
        XCTAssertTrue(past.notes?.contains("2020-03-01") == true)
    }

    func testNoAccessOrAFailedSaveMarksNothing() async {
        let saver = FakeSaver()
        saver.access = false
        let denied = await MeetingActionReminders.add(index: 1, meetingId: meetingId, meetingTitle: nil,
                                                      saver: saver, defaults: defaults)
        XCTAssertEqual(denied, .noAccess)
        saver.access = true
        saver.fail = true
        let failed = await MeetingActionReminders.add(index: 1, meetingId: meetingId, meetingTitle: nil,
                                                      saver: saver, defaults: defaults)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(MeetingActionReminders.record(meetingId: meetingId, defaults: defaults)?.canAdd(1), true)
    }

    func testNotesWrittenLaterKeepWhatWasAdded() {
        var record = MeetingActionItemsRecord(items: [MeetingActionItem(task: "Please check the figures"),
                                                      MeetingActionItem(task: "Order the filter")])
        record.markAdded(0)
        record.markAdded(1)
        let replaced = record.replacingItems(with: [MeetingActionItem(task: "Order the filter", owner: "Ana"),
                                                    MeetingActionItem(task: "Call the supplier")])
        XCTAssertEqual(replaced.entries.map(\.item.task), ["Order the filter", "Call the supplier", "Please check the figures"])
        XCTAssertEqual(replaced.entries.map(\.addedToReminders), [true, false, true])
        XCTAssertEqual(MeetingActionItemsRecord.decode(replaced.encoded()), replaced)
    }
}

/// Plan MX P4 — what the summary hands on: the facts a prepared card reads, unchanged in shape.
@MainActor
final class MeetingSummaryNotesTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func phoneFacts() -> MeetingSummaryFacts {
        MeetingSummaryTool.facts(from: [
            (text: "Ana: I will send the revised budget by Friday.", timestamp: start),
            (text: "Lee: You should probably rest more.", timestamp: start.addingTimeInterval(60)),
        ], savedAt: start)!
    }

    func testTheModelsNotesFillTheFactsTheCardReads() {
        let notes = MeetingNotes(title: "Budget", overview: "The budget.", decisions: ["Keep the supplier"],
                                 actionItems: [MeetingActionItem(task: "Send the revised budget", owner: "Ana", due: "Friday")])
        let facts = phoneFacts().with(notes: notes)
        XCTAssertEqual(facts.actionItems, ["Send the revised budget (Ana, by Friday)"])
        XCTAssertEqual(facts.decisions, ["Keep the supplier"])
        XCTAssertEqual(facts.notes, notes)
        XCTAssertEqual(facts.notesSource, .model)
        XCTAssertEqual(facts.transcript, phoneFacts().transcript)
        XCTAssertEqual(phoneFacts().with(notes: nil), phoneFacts(), "no notes: the keyword facts as before")
        XCTAssertEqual(phoneFacts().notesSource, .phone)
    }

    func testAMeetingWithNoCommitmentsHasNoActionItems() {
        // The keyword extraction read "should" as an action item; the model's empty list stands.
        XCTAssertFalse(phoneFacts().actionItems.isEmpty)
        let facts = phoneFacts().with(notes: MeetingNotes(title: "Catch-up", overview: "A chat."))
        XCTAssertTrue(facts.actionItems.isEmpty)
    }

    func testTheReadableFormKeepsTheDraftValidatorsOwnWordsCheck() {
        let transcript = phoneFacts().transcript
        let items = ["Send the revised budget (Ana, by Friday)"]
        let context = DraftValidationContext(channel: .messages, language: "en",
                                             trustedText: ["Ana Example"] + items, actionItems: items,
                                             untrustedSource: transcript)
        XCTAssertNil(DraftValidator.validate("Hi Ana, thanks for today. To do:\n• Send the revised budget (Ana, by Friday)",
                                             context: context), "the item, with its due, is quoted whole")
        let source = "Ana: you said you will send the revised budget by Friday and Lee said you should probably rest more."
        let copying = DraftValidationContext(channel: .messages, language: "en",
                                             trustedText: ["Ana Example"] + items, actionItems: items,
                                             untrustedSource: source)
        XCTAssertEqual(DraftValidator.validate(
            "Hi Ana, you said you will send the revised budget by Friday and Lee said you should probably rest more.",
            context: copying), .copiedCaptionText, "copying the transcript outside the items still fails")
    }

    func testTheSummarySaysNeutrallyWhoseNotesTheyAre() {
        let facts = phoneFacts()
        let model = MeetingSummaryContent(notes: MeetingNotes(title: "Budget", overview: "The budget."),
                                          phoneFacts: facts, segments: 2, duration: "1 minute", words: 16,
                                          droppedLines: 0, outcome: .written(MeetingNotes()))
        XCTAssertTrue(model.brief().contains("written by the AI model"))
        XCTAssertTrue(model.actionItemsOnly().contains("No one committed"))
        let owed = MeetingSummaryContent(notes: nil, phoneFacts: facts, segments: 2, duration: "1 minute", words: 16,
                                         droppedLines: 0, outcome: .owed(.appInBackground))
        XCTAssertTrue(owed.brief().contains("picked out on the phone"))
        XCTAssertTrue(owed.brief().contains("written later and added to the saved note"))
        let queued = MeetingSummaryContent(notes: nil, phoneFacts: facts, segments: 2, duration: "1 minute", words: 16,
                                           droppedLines: 0, outcome: .queued, saved: false)
        XCTAssertTrue(queued.brief().contains("written after this reply."), queued.brief())
        XCTAssertFalse(queued.brief().contains("saved note"), "an unsaved summary has no note to add to")
        let phone = MeetingSummaryContent(notes: nil, phoneFacts: facts, segments: 2, duration: "1 minute", words: 16,
                                          droppedLines: 0, outcome: .fallback(.offline))
        XCTAssertFalse(phone.brief().contains("later"))
        for text in [model.brief(), owed.brief(), queued.brief(), phone.brief()] {
            XCTAssertNil(text.range(of: #"Plan [A-Z]{1,2}\b"#, options: .regularExpression), "no plan letters")
        }
    }

    func testWhileTheModelsNotesAreToComeTheKeywordLinesAreCandidates() {
        let facts = phoneFacts()
        let queued = MeetingSummaryContent(notes: nil, phoneFacts: facts, segments: 2, duration: "1 minute", words: 16,
                                           droppedLines: 0, outcome: .queued)
        XCTAssertTrue(queued.showsCandidates)
        XCTAssertTrue(queued.actionItemsOnly().hasPrefix("Possible action items, picked out on the phone by key phrase"))
        XCTAssertTrue(queued.actionItemsOnly().contains("no one committed to"))
        let excerpt = MeetingTranscriptExcerpt.make(lines: [.init(text: "Ana: I will send the revised budget by Friday.",
                                                                  timestamp: start)],
                                                    pinned: [], budget: 3_000)
        let full = queued.full(excerpt: excerpt)
        XCTAssertTrue(full.contains("POSSIBLE ACTION ITEMS:"), full)
        XCTAssertTrue(full.contains(MeetingSummaryContent.candidatesLine))
        let phone = MeetingSummaryContent(notes: nil, phoneFacts: facts, segments: 2, duration: "1 minute", words: 16,
                                          droppedLines: 0, outcome: .fallback(.offline))
        XCTAssertFalse(phone.showsCandidates, "nothing fuller is coming: the lines read as before")
        XCTAssertFalse(phone.full(excerpt: excerpt).contains("POSSIBLE"))
        XCTAssertNil(full.range(of: #"Plan [A-Z]{1,2}\b"#, options: .regularExpression), "no plan letters")
    }

    func testTheToolNeverCallsTheModelAndTheNotesFollowTheTurn() async throws {
        let captions = AmbientCaptionService()
        captions.insertVisualNote("whiteboard: we will send the budget")
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSummaryNotesTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let service = MeetingNotesService(store: MeetingNotesOwedStore(directory: workspace, isEnabled: { false },
                                                                       hipaaMode: { false }))
        service.turnWaitStep = 0.01
        service.turnWaitSteps = 500
        let reply = #"{"title": "Budget", "overview": "The whiteboard.", "decisions": [], "action_items": []}"#
        let model = FakeNotesModel { _, _, _ in reply }
        let turn = TurnFlag()
        await turn.set(true)
        service.configure(.init(complete: { try await model.complete($0, $1) },
                                route: { .init(provider: .anthropic, contextTokens: nil, isOnline: true, appActive: true) },
                                turnInFlight: { turn.isOn },
                                completeNote: { record, notes in MeetingSummaryTool.completeSavedNote(record, with: notes) }))
        let tool = MeetingSummaryTool(captionService: captions, notesService: service)
        let output = await tool.summarize(args: ["mode": "full", "save": false])
        let during = await model.calls.count
        XCTAssertEqual(during, 0, "the turn's tool call never runs the model")
        XCTAssertTrue(output.text.contains("Fuller notes will be written after this reply"), output.text)
        XCTAssertTrue(output.text.contains("TRANSCRIPT") || output.text.contains("whiteboard"), "the excerpt is there")
        XCTAssertEqual(output.facts?.notesSource, .phone)
        XCTAssertEqual(LatestMeetingSummary.shared.latest?.notesSource, .phone)

        await turn.set(false)                     // the turn is over
        for _ in 0..<200 where LatestMeetingSummary.shared.latest?.notes == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(LatestMeetingSummary.shared.latest?.notes?.title, "Budget")
        XCTAssertEqual(LatestMeetingSummary.shared.latest?.notesSource, .model)
        LatestMeetingSummary.shared.clear()
    }
}
