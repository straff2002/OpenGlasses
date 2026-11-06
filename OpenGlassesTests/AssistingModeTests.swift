import XCTest
@testable import OpenGlasses

/// Plan KM P2 — Assisting mode: a handover opened as a read-only copy, the expert's clock across a
/// kill, generations, retention, and the time reply.
///
/// Every name, number, company and address here is invented.
@MainActor
final class AssistingModeTests: XCTestCase {

    private var directory: URL!
    private var clock: AssistingTestClock!

    override func setUp() {
        super.setUp()
        directory = AssistingFixture.temporaryDirectory()
        clock = AssistingTestClock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func store() -> AssistingHandoverStore {
        let clock = self.clock!
        return AssistingHandoverStore(directory: directory, now: { clock.now })
    }

    // MARK: - The clock

    func testTheClockTakesPausesResumesAndStopsAtDone() {
        let t0 = AssistingFixture.start
        var clock = AssistingClock.take(at: t0)
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.minutes(at: t0.addingTimeInterval(600)), 10)
        clock.pause(at: t0.addingTimeInterval(600))
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.minutes(at: t0.addingTimeInterval(3_600)), 10, "a paused clock doesn't count")
        clock.resume(at: t0.addingTimeInterval(1_200))
        clock.checkpoint(at: t0.addingTimeInterval(1_500))
        XCTAssertEqual(clock.minutes(at: t0.addingTimeInterval(1_500)), 15, "a checkpoint changes nothing on the face")
        clock.done(at: t0.addingTimeInterval(1_800))
        XCTAssertTrue(clock.isDone)
        XCTAssertEqual(clock.minutes(at: t0.addingTimeInterval(9_000)), 20, "Done stops it for good")
        clock.resume(at: t0.addingTimeInterval(9_000))
        XCTAssertTrue(clock.isDone, "nothing restarts a clock that is Done")
        XCTAssertEqual(clock.uncountedMinutes, 0)
    }

    func testTheClockSurvivesAKillAndRelaunch() throws {
        let opened = AssistingFixture.opened(AssistingFixture.handover())
        var first: AssistingHandoverStore? = store()
        first?.open(opened)
        first?.take(id: "H-1")
        clock.advance(600)
        first?.checkpointRunningClocks()     // the minute heartbeat: the last sign of life
        clock.advance(240)                   // four more minutes, then the app is killed
        first = nil

        clock.advance(60)                    // relaunched a minute later
        let relaunched = store()
        let recovered = try XCTUnwrap(relaunched.handover(id: "H-1")?.clock)
        XCTAssertTrue(recovered.isPaused, "a clock the app died under is paused at its last sign of life")
        XCTAssertTrue(recovered.pausedWhenAppClosed)
        XCTAssertEqual(recovered.minutes(at: clock.now), 10, "the time up to the checkpoint is kept")
        XCTAssertEqual(recovered.uncountedMinutes, 5, "the time since is not counted, and is said so")

        // A second relaunch recovers nothing more: the clock is paused.
        clock.advance(600)
        XCTAssertEqual(store().handover(id: "H-1")?.clock, recovered)

        // Resumed and finished, the reply carries both.
        let again = store()
        again.resume(id: "H-1")
        clock.advance(300)
        again.done(id: "H-1")
        let reply = try ExpertTimeReply.build(for: XCTUnwrap(again.handover(id: "H-1")), card: nil, note: nil,
                                              now: clock.now).get()
        XCTAssertEqual(reply.minutes, 15)
        XCTAssertEqual(reply.uncountedMinutes, 5)
        XCTAssertTrue(reply.summary.contains("5 minutes weren't counted after the app closed"))
    }

    func testTheRecoveryIsBillableClocksRule() {
        // The same four instants give the same answer through the job's clock and the expert's.
        let t0 = AssistingFixture.start
        var session = AssistingFixture.session()
        session.resumedAt = t0.addingTimeInterval(100)
        session.billableCheckpointAt = t0.addingTimeInterval(700)
        let viaSession = BillableClock.recover(session: session, lastEvidenceOfLife: t0.addingTimeInterval(700),
                                               now: t0.addingTimeInterval(1_000))
        let viaFields = BillableClock.recover(startedAt: t0, resumedAt: t0.addingTimeInterval(100), pausedAt: nil,
                                              checkpointAt: t0.addingTimeInterval(700),
                                              lastEvidenceOfLife: t0.addingTimeInterval(700),
                                              now: t0.addingTimeInterval(1_000))
        XCTAssertEqual(viaSession, viaFields)
        XCTAssertEqual(viaFields.uncountedSeconds, 300)
    }

    // MARK: - Generations

    func testGenerationNPlusOneReplacesNAndMarksWhatChanged() throws {
        let store = store()
        XCTAssertEqual(store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 1, readings: 1, photos: 1))), .added)
        let outcome = store.open(AssistingFixture.opened(
            AssistingFixture.handover(generation: 2, readings: 3, photos: 2, question: "Is it the board?")))
        guard case .replaced(let changes) = outcome else { return XCTFail("expected a replacement, got \(outcome)") }
        XCTAssertTrue(changes.contains(.readings))
        XCTAssertTrue(changes.contains(.question))
        XCTAssertTrue(changes.contains(.photos))
        XCTAssertFalse(changes.contains(.ruledOut), "unchanged sections aren't marked")
        XCTAssertTrue(changes.lines.contains("2 new readings."))

        XCTAssertEqual(store.held.count, 1, "one handover, not two")
        let held = try XCTUnwrap(store.handover(id: "H-1"))
        XCTAssertEqual(held.handover.generation, 2)
        XCTAssertEqual(held.handover.question, "Is it the board?")
        XCTAssertEqual(held.generationsSeen, [1, 2])
        XCTAssertNotNil(store.photo(handoverId: "H-1", index: 1), "the new generation's photos replace the old")
    }

    func testAnOlderOrRepeatedGenerationIsKeptAsItWas() throws {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 3)))
        XCTAssertEqual(store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 3))), .alreadyHeld)
        XCTAssertEqual(store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 2, question: "old"))),
                       .olderThanHeld(held: 3))
        let held = try XCTUnwrap(store.handover(id: "H-1"))
        XCTAssertEqual(held.handover.generation, 3)
        XCTAssertEqual(held.generationsSeen, [3], "a generation never kept is not one the expert saw")
    }

    func testAHandoverFromSomeoneElseCannotReplaceOneHeld() {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 1)))
        XCTAssertEqual(store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 2, organisation: "Rival Air"))),
                       .conflicting)
        XCTAssertEqual(store.open(AssistingFixture.opened(AssistingFixture.handover(generation: 2, expertId: "priya"))),
                       .conflicting)
        XCTAssertEqual(store.handover(id: "H-1")?.handover.generation, 1)
    }

    func testAReplyCarriesEveryGenerationSeen() throws {
        let store = store()
        for generation in [1, 2, 4] {
            store.open(AssistingFixture.opened(AssistingFixture.handover(generation: generation)))
            if generation == 1 { store.take(id: "H-1") }
            clock.advance(300)
        }
        store.done(id: "H-1")
        let held = try XCTUnwrap(store.handover(id: "H-1"))
        let reply = try ExpertTimeReply.build(for: held, card: nil, note: "Hose was fine; replace the switch.",
                                              now: clock.now).get()
        XCTAssertEqual(reply.generationsSeen, [1, 2, 4])
        XCTAssertEqual(reply.handoverId, "H-1")
        XCTAssertEqual(reply.minutes, 15)
        XCTAssertEqual(reply.note, "Hose was fine; replace the switch.")
        XCTAssertEqual(reply.expert.listId, "sam")
        XCTAssertEqual(reply.expert.listName, "Sam Ferreira")

        // …and through the file the expert sends.
        let read = try ExpertTimeReplyFile.read(ExpertTimeReplyFile.write(reply)).get()
        XCTAssertEqual(read, reply)
        XCTAssertEqual(read.generationsSeen, [1, 2, 4])
    }

    func testAReplyNeedsTheJobTakenAndDone() {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover()))
        let untaken = store.handover(id: "H-1")!
        XCTAssertEqual(ExpertTimeReply.build(for: untaken, card: nil, note: nil, now: clock.now).failureValue, .notTaken)
        store.take(id: "H-1")
        XCTAssertEqual(ExpertTimeReply.build(for: store.handover(id: "H-1")!, card: nil, note: nil, now: clock.now).failureValue,
                       .notDone)
    }

    func testTheReplyCarriesTheCardAndNoRate() throws {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover()))
        store.take(id: "H-1")
        store.done(id: "H-1")
        let card = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111", faceTimeHandle: "sam@example.com")
        let reply = try ExpertTimeReply.build(for: XCTUnwrap(store.handover(id: "H-1")), card: card, note: nil,
                                              now: clock.now).get()
        XCTAssertEqual(reply.expert.cardId, card.cardId)
        XCTAssertEqual(reply.expert.phone, "+64 21 000 1111")
        let json = String(decoding: try ExpertHandoverFile.encoder().encode(reply), as: UTF8.self).lowercased()
        XCTAssertFalse(json.contains("rate"), "a reply never carries a rate (decision 6)")
        XCTAssertFalse(json.contains("tamatea"), "nothing of the conversation goes back")
    }

    // MARK: - The file family

    func testAnOgcaseIsReadByItsKind() throws {
        let handover = AssistingFixture.handover()
        let file = try ExpertHandoverFile.write(handover, photos: Dictionary(uniqueKeysWithValues: handover.photos.map { ($0.file, AssistingFixture.jpeg) }))
        guard case .handover(let opened) = ExpertHandoverFile.received(file) else { return XCTFail("a handover is a handover") }
        XCTAssertEqual(opened.handover, handover)

        let store = store()
        store.open(opened)
        store.take(id: "H-1")
        store.done(id: "H-1")
        let reply = try ExpertTimeReply.build(for: XCTUnwrap(store.handover(id: "H-1")), card: nil, note: nil, now: clock.now).get()
        guard case .timeReply(let read) = ExpertHandoverFile.received(try ExpertTimeReplyFile.write(reply)) else {
            return XCTFail("a reply is a reply")
        }
        XCTAssertEqual(read, reply)

        guard case .refused = ExpertHandoverFile.received(Data("not a zip".utf8)) else { return XCTFail() }
        // A reply with anything else inside is not a reply.
        let padded = StoredZipWriter.zip([("handover.json", try ExpertHandoverFile.encoder().encode(reply)),
                                         ("photos/01.jpg", AssistingFixture.jpeg)])
        XCTAssertEqual(ExpertTimeReplyFile.read(padded).failureValue, .unexpectedEntry("photos/01.jpg"))
        // A reply of a newer version is named, not guessed at.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ExpertHandoverFile.encoder().encode(reply)) as? [String: Any])
        object["version"] = 2
        let newer = StoredZipWriter.zip([("handover.json", try JSONSerialization.data(withJSONObject: object))])
        XCTAssertEqual(ExpertTimeReplyFile.read(newer).failureValue, .unsupportedVersion(2))
        // A handover's reader never takes a reply.
        XCTAssertEqual(ExpertHandoverFile.read(try ExpertTimeReplyFile.write(reply)).failureValue, .notAHandover)
    }

    // MARK: - Grouped by organisation

    func testHandoversAreGroupedByOrganisationNewestFirst() {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "A-1", organisation: "Kestrel Heating")))
        clock.advance(60)
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "B-1", organisation: "Rival Air")))
        clock.advance(60)
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "A-2", organisation: "kestrel heating ")))
        let groups = store.groups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map { $0.handovers.map(\.id) }, [["A-2", "A-1"], ["B-1"]])
    }

    // MARK: - Retention

    func testRetentionDeletesAnExpiredHandover() throws {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "H-1", retentionDays: 7)))
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "H-2", retentionDays: 30)))
        store.take(id: "H-1")
        clock.advance(600)
        store.done(id: "H-1")
        let doneAt = clock.now
        XCTAssertNotNil(store.photo(handoverId: "H-1", index: 0))

        XCTAssertEqual(store.purgeExpired(now: doneAt.addingTimeInterval(7 * 86_400 - 1)), 0, "inside its own period")
        XCTAssertEqual(store.purgeExpired(now: doneAt.addingTimeInterval(7 * 86_400)), 1)
        XCTAssertNil(store.handover(id: "H-1"))
        XCTAssertNil(store.photo(handoverId: "H-1", index: 0), "its photos go with it")
        XCTAssertNotNil(store.handover(id: "H-2"), "another handover keeps its own period")

        // One nobody took leaves on its own period from when it last changed.
        XCTAssertEqual(store.purgeExpired(now: AssistingFixture.start.addingTimeInterval(30 * 86_400 + 1)), 1)
        XCTAssertTrue(store.held.isEmpty)
        XCTAssertTrue(self.store().held.isEmpty, "the deletion is on disk, not just in memory")
    }

    func testTheRetentionSchedulerAppliesEachHandoversOwnPeriod() {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover(retentionDays: 1)))
        clock.advance(2 * 86_400)
        var sources = RetentionScheduler.Sources()
        sources.assistingHandovers = store
        let targets = RetentionScheduler.targets(sources: sources, fileSystem: EmptyFileSystem())
            .filter { $0.id == .assistingHandovers }
        XCTAssertEqual(targets.count, 1)
        let testClock = clock!
        let scheduler = RetentionScheduler(targets: targets, settings: { RetentionSettings(clinicalDays: 0, wearerHistoryDays: 0) },
                                           runStore: MemoryRunStore(), clock: { testClock.now })
        let outcome = scheduler.run()
        XCTAssertEqual(outcome.rowsRemoved, 1, "a class-wide 'keep everything' doesn't override a handover's own period")
        XCTAssertTrue(store.held.isEmpty)
    }

    // MARK: - The store's own posture

    func testTheStoreIsProtectedKeptOutOfBackupAndRegistered() throws {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover()))
        let values = try store.fileLocation.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let record = SensitiveStore.assistingHandovers.record
        XCTAssertEqual(record.subjectLinkage, .thirdPartySubject, "another organisation's job")
        XCTAssertTrue(record.backupExcluded)
        XCTAssertEqual(record.protection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(AssistingHandoverStore.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(SubjectErasureCoordinator.order.contains(.assistingHandovers))
    }

    func testTheSubjectErasureAndDeleteAllReachIt() async {
        let store = store()
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "H-1")))
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "H-2", conversation: false)))
        var stores = SubjectErasureCoordinator.Stores()
        stores.assistingHandovers = store
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.person("Ngaio Tamatea"))
        let receipt = receipts.first { $0.store == .assistingHandovers }
        XCTAssertEqual(receipt?.localComplete, true)
        XCTAssertEqual(receipt?.removed, 1, "the handover whose conversation names them goes whole")
        XCTAssertEqual(store.held.map(\.id), ["H-2"])
        store.removeAll()
        XCTAssertTrue(self.store().held.isEmpty)
    }

    // MARK: - The service: staged reply, Medical

    private func service(_ store: AssistingHandoverStore, cards: ExpertCardStore? = nil) -> (AssistingService, StagedExportCoordinator) {
        let replies = StagedExportCoordinator(channel: .assistingReply, rootDirectoryName: "unused",
                                              store: ProtectedExportFileStore(rootDirectoryName: "unused",
                                                                              root: directory.appendingPathComponent("replies")))
        let defaults = UserDefaults(suiteName: "assisting-\(UUID().uuidString)")!
        let clock = self.clock!
        return (AssistingService(store: store, cards: cards ?? ExpertCardStore(defaults: defaults), replies: replies,
                                 now: { clock.now }), replies)
    }

    func testTheReplyIsStagedAndOnlyTheSharesSendMarksItSent() throws {
        let store = store()
        let (service, replies) = service(store)
        let report = service.open(AssistingFixture.opened(AssistingFixture.handover()))
        XCTAssertTrue(report.shown)
        XCTAssertEqual(service.presented?.id, "H-1")
        service.take("H-1")
        clock.advance(1_200)
        service.done("H-1")

        // Showing what it says writes nothing.
        XCTAssertNotNil(try service.reply(for: "H-1", note: "x")?.get())
        XCTAssertEqual(replies.activeLeaseCount, 0, "nothing is written until the expert taps Send reply")

        let staged = try service.stageReply(for: "H-1", note: "Replace the switch.").get()
        XCTAssertEqual(replies.activeLeaseCount, 1)
        XCTAssertEqual(staged.lease.fileURL.pathExtension, "ogcase")
        XCTAssertEqual(try ExpertTimeReplyFile.read(Data(contentsOf: staged.lease.fileURL)).get().minutes, 20)

        service.beginShare(staged)
        service.finishShare(staged, for: "H-1", completed: false)
        XCTAssertNil(store.handover(id: "H-1")?.replySentAt, "a cancelled share sent nothing")
        XCTAssertEqual(replies.activeLeaseCount, 0, "the staged file is released however the share ends")

        let again = try service.stageReply(for: "H-1", note: nil).get()
        service.finishShare(again, for: "H-1", completed: true)
        XCTAssertNotNil(store.handover(id: "H-1")?.replySentAt)
    }

    func testMedicalModeStillOpensAHandoverReadOnly() throws {
        // Holding a handover sent to you is not an egress, and the only thing that leaves is your own
        // reply by your own share: Assisting stays available in Medical Compliance mode.
        let previous = MedicalEgressGuard.currentMode
        MedicalEgressGuard.currentMode = { .localOnly }
        defer { MedicalEgressGuard.currentMode = previous }
        let (service, _) = service(store())
        XCTAssertTrue(service.open(AssistingFixture.opened(AssistingFixture.handover())).shown)
        service.take("H-1")
        service.done("H-1")
        XCTAssertNoThrow(try service.stageReply(for: "H-1", note: nil).get())
    }

    func testOpeningTellsTheExpertWhatHappened() {
        let handover = AssistingFixture.handover(generation: 2)
        XCTAssertTrue(AssistingService.message(for: .added, handover: handover).contains("from Kestrel Heating"))
        XCTAssertTrue(AssistingService.message(for: .replaced(.init(sections: [.readings], lines: ["2 new readings."])),
                                               handover: handover).contains("Update 2 replaced the earlier one. 2 new readings."))
        XCTAssertTrue(AssistingService.message(for: .conflicting, handover: handover).contains("wasn't opened"))
    }
}

private struct EmptyFileSystem: RetentionFileSystem {
    func children(of directory: URL) throws -> [(url: URL, created: Date)] { throw RetentionFault.sourceUnavailable }
    func remove(at url: URL) throws {}
}

private final class MemoryRunStore: RetentionRunStore {
    var lastCompletedAt: Date?
    var inProgress: RetentionRunRecord?
    func loadInProgress() -> RetentionRunRecord? { inProgress }
    func saveInProgress(_ record: RetentionRunRecord) { inProgress = record }
    func clearInProgress() { inProgress = nil }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
