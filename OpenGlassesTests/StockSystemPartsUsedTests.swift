import XCTest
@testable import OpenGlasses

/// Plan MM P4 — the parts used on a job (or a premises day) confirmed by a person, one yes per
/// batch, and queued; no keeps them on the job; not offered while sending is off or Medical Local
/// Only holds the route; the job's row states; the record's new members; the stepper; and the
/// answer while a use is still being sent.
@MainActor
final class StockSystemPartsUsedTests: XCTestCase {

    private typealias C = StockSystemConnectionSamples
    private var h: StockSystemVanStockHarness!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var queue: OfflineQueue!
    private var recorded: [String: StockSystemJobUses?] = [:]
    private var flushes = 0

    override func setUp() async throws {
        PolicyEnvelope.clear()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        h = StockSystemVanStockHarness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        queue = OfflineQueue(path: h.directory.appendingPathComponent("queue.sqlite"))
    }

    override func tearDown() async throws {
        queue = nil
        h.cleanUp()
        PolicyEnvelope.clear()
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
    }

    private final class NoSink: SyncSink {
        func deliver(_ op: QueuedOp) async -> SyncOutcome { .done }
    }

    private let none = NoSink()

    /// The system connected with sending back on (or off), a job open, and the parts service.
    private func make(sendingBack: Bool = true, kind: StockPlace.Kind = .van,
                      job: VanStockService.Job? = .init(sessionID: "S1", reference: "1027")) throws -> StockSystemPartsUsed {
        h.kind = kind
        h.job = job
        let service = try h.connect()
        try service.connection.setSendingBack(sendingBack)
        try service.connection.setReason(.waste)
        let sink = StockSystemSyncSink(queue: queue, fallback: none, seams: .init(
            connection: { _ in .removed }, officeRoute: { false }, medicalBlocks: { _ in false },
            now: { [unowned self] in self.h.clock }))
        return StockSystemPartsUsed(service: service, sink: sink, seams: .init(
            recordOnJob: { [unowned self] id, uses in self.recorded[id] = uses },
            flush: { [unowned self] in self.flushes += 1 },
            now: { [unowned self] in self.h.clock },
            makeID: { UUID().uuidString },
            calendar: StockSystemVanStockHarness.calendar))
    }

    private func stageTwo() async throws {
        let answer = try await h.run(["action": "use", "items": [
            ["part": "ZX-455", "quantity": 1],
            ["part": "CL-50", "quantity": 0.5, "unit": "litre"],
        ]])
        XCTAssertEqual(h.staged.count, 2, answer)
    }

    // MARK: - One yes per batch

    func testTheQuestionReadsTheLinesBackOnce() async throws {
        let parts = try make()
        try await stageTwo()
        XCTAssertEqual(parts.question(for: .job("S1")),
                       "Two parts used on this job: one Run capacitor 45/5, half a litre of Coolant. Send them to Square?")
    }

    func testOneYesQueuesTheBatchAndEveryLineIsQueued() async throws {
        let parts = try make()
        try await stageTwo()
        let outcome = parts.confirm(.job("S1"), by: .person(.voice), jobNumber: "1027")
        XCTAssertEqual(outcome.queued, 2)
        XCTAssertEqual(outcome.sentence, "Sending two parts to Square.")
        let ops = queue.all(limit: 10).filter { $0.kind == .stockSystemParts }
        XCTAssertEqual(ops.count, 1, "one batch for one location")
        let batch = try XCTUnwrap(StockSystemSyncSink.decode(try XCTUnwrap(ops.first).payload))
        XCTAssertEqual(batch.plan.steps.count, 2)
        XCTAssertEqual(batch.plan.jobID, "S1")
        XCTAssertEqual(batch.confirmedAt, h.clock)
        XCTAssertTrue(h.staged.allSatisfy { $0.delivery.state == .queued && $0.delivery.batchID == batch.batchID })
        XCTAssertNil(parts.question(for: .job("S1")), "asked once: nothing is waiting now")
        XCTAssertEqual(parts.confirm(.job("S1"), by: .person(.screen)).queued, 0, "a second yes sends nothing again")
        XCTAssertEqual(queue.all(limit: 10).count, 1)
        // The job's record follows.
        let uses = try XCTUnwrap(recorded["S1"] ?? nil)
        XCTAssertEqual(uses.connectorID, "square")
        XCTAssertEqual(uses.displayName, "Square")
        XCTAssertEqual(uses.lines.map(\.itemID), ["ITEM-CAP", "ITEM-COOL"])
        XCTAssertEqual(uses.lines.map(\.delivery), [.queued, .queued])
        XCTAssertEqual(parts.rowLines(for: .job("S1")), ["Waiting for a connection"])
    }

    func testNoKeepsThemOnTheJobWithTheJobTabLineUntilSentOrDiscarded() async throws {
        let parts = try make()
        try await stageTwo()
        // No: nothing is confirmed, nothing queued.
        XCTAssertTrue(queue.all(limit: 10).isEmpty)
        XCTAssertEqual(parts.rowLines(for: .job("S1")), ["2 parts not sent to Square"])
        XCTAssertNotNil(parts.question(for: .job("S1")), "still there to send later")
        let first = try XCTUnwrap(h.staged.first)
        XCTAssertTrue(parts.discard([first.id]))
        XCTAssertEqual(parts.rowLines(for: .job("S1")),
                       ["1 part not sent to Square", "1 not sent: it was discarded on this phone"])
        XCTAssertEqual(recorded["S1"]??.lines.first?.delivery, .notSent)
        XCTAssertEqual(recorded["S1"]??.lines.first?.deliveryReason, "discarded")
    }

    func testALineTheSystemDoesNotCarryIsKeptWithThePlansSentence() throws {
        let parts = try make()
        let stranger = StagedStockUseEntry(
            scope: .job("S1"), jobReference: "1027", connectorID: "square", locationID: C.main.id,
            use: StagedStockUse(id: "X1", itemID: "ITEM-GONE", part: "ZZ-1", description: "Mystery part",
                                quantity: .whole(1), unit: .each, source: .spoken),
            reason: nil, stagedAt: h.clock, call: "C1")
        XCTAssertTrue(parts.service.staged.stage([stranger]))
        let outcome = parts.confirm(.job("S1"), by: .person(.screen))
        XCTAssertEqual(outcome.queued, 0)
        XCTAssertEqual(outcome.notSent, 1)
        XCTAssertTrue(queue.all(limit: 10).isEmpty, "no writes, nothing queued")
        XCTAssertEqual(parts.rowLines(for: .job("S1")), ["1 not sent: not in Square's catalogue, so not sent"])
        XCTAssertEqual(h.staged.first?.delivery.reason, "not_carried")
    }

    // MARK: - Not offered

    func testWithSendingBackOffSendingIsNotOfferedAndTheCloseRecordsTheReason() async throws {
        let parts = try make(sendingBack: false)
        try await stageTwo()
        XCTAssertEqual(parts.offer, .notOffered(.sendingOff))
        XCTAssertNil(parts.question(for: .job("S1")), "never asked")
        let refused = parts.confirm(.job("S1"), by: .person(.screen))
        XCTAssertEqual(refused.queued, 0)
        XCTAssertTrue(refused.sentence.contains("Sending back to Square is off"), refused.sentence)
        XCTAssertTrue(queue.all(limit: 10).isEmpty)
        parts.settleAtClose(sessionID: "S1")
        XCTAssertTrue(h.staged.allSatisfy { $0.delivery.state == .notSent && $0.delivery.reason == "sending_off" })
        XCTAssertEqual(recorded["S1"]??.lines.map(\.deliveryReason), ["sending_off", "sending_off"])
    }

    func testUnderMedicalLocalOnlySendingIsNotOffered() async throws {
        let parts = try make()
        try await stageTwo()
        h.medicalBlocked = true
        XCTAssertEqual(parts.offer, .notOffered(.localOnly))
        XCTAssertNil(parts.question(for: .job("S1")))
        XCTAssertEqual(parts.confirm(.job("S1"), by: .person(.voice)).queued, 0)
        parts.settleAtClose(sessionID: "S1")
        XCTAssertTrue(h.staged.allSatisfy { $0.delivery.reason == "local_only" })
    }

    func testTheSendOfferIsDecidedInOrder() {
        XCTAssertEqual(StockSystemSendOffer.decide(officeRoute: true, connected: true, sendingBack: true, localOnly: false),
                       .notOffered(.officeRoute))
        XCTAssertEqual(StockSystemSendOffer.decide(officeRoute: false, connected: false, sendingBack: true, localOnly: false),
                       .notOffered(.disconnected))
        XCTAssertEqual(StockSystemSendOffer.decide(officeRoute: false, connected: true, sendingBack: true, localOnly: true),
                       .notOffered(.localOnly))
        XCTAssertEqual(StockSystemSendOffer.decide(officeRoute: false, connected: true, sendingBack: false, localOnly: false),
                       .notOffered(.sendingOff))
        XCTAssertEqual(StockSystemSendOffer.decide(officeRoute: false, connected: true, sendingBack: true, localOnly: false),
                       .offered)
    }

    // MARK: - The premises day list

    func testThePremisesDayListIsConfirmedTheSameWay() async throws {
        let parts = try make(kind: .store, job: nil)
        let answer = try await h.run(["action": "use", "part": "ZX-455", "quantity": 2])
        XCTAssertEqual(h.staged.map(\.scope), [.day("2026-11-20")], answer)
        XCTAssertEqual(parts.today, .day("2026-11-20"))
        XCTAssertEqual(parts.question(for: parts.today), "One part used today: two Run capacitor 45/5. Send it to Square?")
        XCTAssertEqual(parts.rowLines(for: parts.today), ["1 part not sent to Square"])
        let outcome = parts.confirm(parts.today, by: .person(.screen))
        XCTAssertEqual(outcome.queued, 1)
        let op = try XCTUnwrap(queue.all(limit: 10).first)
        XCTAssertEqual(op.sessionId, "stock-system-day:2026-11-20")
        XCTAssertEqual(StockSystemSyncSink.decode(op.payload)?.plan.jobID, "day:2026-11-20")
        XCTAssertTrue(recorded.isEmpty, "a day's list is on no job's record")
    }

    // MARK: - Still being sent

    func testACheckSaysAUseIsStillBeingSentUntilTheNextPull() async throws {
        let parts = try make()
        _ = try await h.run(["action": "use", "part": "ZX-455", "quantity": 1])
        let noted = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertTrue(noted.contains("1 used on this job is noted and not yet sent to Square"), noted)
        _ = parts.confirm(.job("S1"), by: .person(.voice))
        let sending = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertTrue(sending.hasPrefix("3 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 09:10"), sending)
        XCTAssertTrue(sending.contains("and 1 used on this job is still being sent."), sending)
        // Sent after the figure was read: still said, until a newer figure arrives.
        let id = try XCTUnwrap(h.staged.first?.id)
        h.clock = h.clock.addingTimeInterval(60)
        parts.service.staged.setDelivery([id: .init(state: .sent, changedAt: h.clock)])
        let sent = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertTrue(sent.contains("is still being sent"), sent)
        XCTAssertTrue(parts.service.store.replace(StockSystemVanStockHarness.snapshot(asOf: h.clock.addingTimeInterval(60))))
        let pulled = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertFalse(pulled.contains("still being sent"), pulled)
        XCTAssertFalse(pulled.contains("noted and not yet sent"), pulled)
    }

    func testTheComposerSaysSendingThenNoted() {
        let composer = StockSystemAnswerComposer(now: StockSystemSamples.pulledAt, calendar: StockSystemSamples.calendar,
                                                 system: "Square")
        let snapshot = StockSystemSamples.snapshot([StockSystemSamples.row("I1", [("L1", "2")])])
        let line = snapshot.lines[0]
        let answer = composer.check(line, in: snapshot, here: ["L1"], unsent: [
            .init(quantity: .whole(1), state: .staged), .init(quantity: .whole(1), state: .sending)])
        XCTAssertEqual(answer, "2 × Capacitor 45/5 (ZX-I1) on the van in Square, as of 09:10, and 1 used on this job is "
                       + "still being sent, and 1 used on this job is noted and not yet sent to Square.")
    }

    // MARK: - The stepper

    func testTheStepperKeepsToTheUnitAndTheItemsDecimalPlaces() {
        let each = StockSystemQuantityStepper(unit: .each, decimalPlaces: nil)
        XCTAssertEqual(each.step, 1000)
        XCTAssertEqual(each.minimum, .whole(1))
        XCTAssertEqual(each.down(.whole(1)), .whole(1), "never to nothing: Discard takes a line off")
        XCTAssertEqual(each.up(.whole(1)), .whole(2))
        XCTAssertFalse(each.accepts(StockQuantity(scaled: 1500)))

        let litreTwoPlaces = StockSystemQuantityStepper(unit: .l, decimalPlaces: 2)
        XCTAssertEqual(litreTwoPlaces.granule, 10)
        XCTAssertEqual(litreTwoPlaces.step, 100)
        XCTAssertEqual(litreTwoPlaces.up(StockQuantity(scaled: 500)), StockQuantity(scaled: 600))
        XCTAssertTrue(litreTwoPlaces.accepts(StockQuantity(scaled: 250)))
        XCTAssertFalse(litreTwoPlaces.accepts(StockQuantity(scaled: 255)), "finer than the item keeps")
        XCTAssertEqual(litreTwoPlaces.down(StockQuantity(scaled: 50)), StockQuantity(scaled: 10))

        let litreWhole = StockSystemQuantityStepper(unit: .l, decimalPlaces: 0)
        XCTAssertEqual(litreWhole.step, 1000)
        XCTAssertFalse(litreWhole.accepts(StockQuantity(scaled: 500)))

        let wholeSystem = StockSystemQuantityStepper(unit: .kg, decimalPlaces: 3, wholeNumbersOnly: true)
        XCTAssertEqual(wholeSystem.step, 1000)
        XCTAssertEqual(wholeSystem.minimum, .whole(1))

        let unlimited = StockSystemQuantityStepper(unit: .m, decimalPlaces: nil)
        XCTAssertEqual(unlimited.granule, 1)
        XCTAssertEqual(unlimited.step, 100)
        XCTAssertEqual(unlimited.up(StockQuantity(scaled: StockQuantity.maximumScaled)), StockQuantity(scaled: StockQuantity.maximumScaled))
    }

    func testTheStepperChangesOnlyAnAmountTheItemTakes() async throws {
        let parts = try make()
        try await stageTwo()
        let coolant = try XCTUnwrap(h.staged.first { $0.use.itemID == "ITEM-COOL" })
        XCTAssertEqual(parts.stepper(for: coolant).granule, 10, "the system keeps coolant to 2 places")
        XCTAssertFalse(parts.setQuantity(StockQuantity(scaled: 505), for: coolant))
        XCTAssertTrue(parts.setQuantity(StockQuantity(scaled: 600), for: coolant))
        XCTAssertEqual(h.staged.first { $0.id == coolant.id }?.use.quantity, StockQuantity(scaled: 600))
        XCTAssertEqual(h.staged.first { $0.id == coolant.id }?.id, coolant.id, "the same line, so the same keys")
        _ = parts.confirm(.job("S1"), by: .person(.screen))
        let queued = try XCTUnwrap(h.staged.first { $0.id == coolant.id })
        XCTAssertFalse(parts.setQuantity(StockQuantity(scaled: 700), for: queued), "not once it is confirmed")
    }

    // MARK: - The job's row

    private func entry(_ id: String, _ delivery: StockSystemLineDelivery) -> StagedStockUseEntry {
        StagedStockUseEntry(scope: .job("S"), jobReference: nil, connectorID: "square", locationID: "L",
                            use: StagedStockUse(id: id, itemID: "I", part: "P", description: "D", quantity: .whole(1),
                                                unit: .each, source: .spoken),
                            reason: nil, stagedAt: StockSystemSamples.pulledAt, call: "C", delivery: delivery)
    }

    func testTheJobRowsStates() {
        let sent = StockSystemLineDelivery(state: .sent)
        let queued = StockSystemLineDelivery(state: .queued)
        let attention = StockSystemLineDelivery(state: .needsAttention, reason: "missing_scope",
                                                sentence: "The Square key can't do this without the INVENTORY_WRITE permission.")
        let notCarried = StockSystemLineDelivery(state: .notSent, reason: "not_carried",
                                                 sentence: "Grease: not in Square's catalogue, so not sent.")
        XCTAssertEqual(StockSystemJobRowState.lines([], system: "Square"), [])
        XCTAssertEqual(StockSystemJobRowState.lines([entry("a", sent), entry("b", sent)], system: "Square"), ["Sent to Square"])
        XCTAssertEqual(StockSystemJobRowState.lines([entry("a", sent), entry("b", queued)], system: "Square"),
                       ["Waiting for a connection"])
        XCTAssertEqual(StockSystemJobRowState.lines([entry("a", queued), entry("b", attention)], system: "Square"),
                       ["Needs attention — The Square key can't do this without the INVENTORY_WRITE permission."])
        XCTAssertEqual(StockSystemJobRowState.lines([entry("a", sent), entry("b", notCarried), entry("c", notCarried)],
                                                    system: "Square"),
                       ["Sent to Square", "2 not sent: not in Square's catalogue, so not sent"])
        XCTAssertEqual(StockSystemJobRowState.lines([entry("a", .staged), entry("b", .staged), entry("c", sent)],
                                                    system: "Square"),
                       ["2 parts not sent to Square"], "noted lines are not sent yet")
    }

    // MARK: - The record

    private static func coders() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    private func session() -> FieldSession {
        FieldSession(id: "S1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly, startedAt: StockSystemSamples.pulledAt,
                     outcome: .resolved, escalations: [], billableSeconds: 0)
    }

    func testTheRecordHasNoBlockOnAJobThatUsedNothing() throws {
        let (encoder, _) = Self.coders()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(WorkRecord(session: session(), vaultName: "v")))
                                   as? [String: Any])
        XCTAssertNil(object["van_stock"])
        XCTAssertNil(object["van_stock_system"])
    }

    func testTheRecordCarriesTheSystemAndEachLinesItemAndState() throws {
        let (encoder, decoder) = Self.coders()
        var s = session()
        s.stockSystemUses = StockSystemJobUses(entries: [
            entry("a", .init(state: .sent)),
            entry("b", .init(state: .notSent, reason: "not_carried", sentence: "x")),
            entry("c", .init(state: .needsAttention, reason: "mismatch_quantity")),
            entry("d", .staged),
            entry("e", .init(state: .queued)),
        ], displayName: "Square")
        let record = WorkRecord(session: s, vaultName: "v")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        XCTAssertEqual(object["van_stock_system"] as? [String: String], ["connector": "square", "name": "Square"])
        let lines = try XCTUnwrap(object["van_stock"] as? [[String: Any]])
        XCTAssertEqual(lines.map { $0["delivery"] as? String }, ["sent", "not_sent", "needs_attention", "staged", "queued"])
        XCTAssertEqual(lines.map { $0["deliveryReason"] as? String }, [nil, "not_carried", "mismatch_quantity", nil, nil])
        XCTAssertTrue(lines.allSatisfy { $0["itemID"] as? String == "I" })
        XCTAssertTrue(lines.allSatisfy { $0["quantityScale"] as? Int == 3 && $0["quantity"] == nil })
        // It reads back the same, and the session saved with it does too.
        XCTAssertEqual(try decoder.decode(WorkRecord.self, from: encoder.encode(record)).vanStock, record.vanStock)
        XCTAssertEqual(try decoder.decode(FieldSession.self, from: encoder.encode(s)).stockSystemUses, s.stockSystemUses)
    }

    func testAPhoneHeldRecordIsUnchanged() throws {
        let (encoder, _) = Self.coders()
        var s = session()
        s.vanStockUses = [VanStockUse(id: "m1", number: "14T65", description: "Switch", quantity: .whole(2), unit: .each,
                                      verified: true, at: StockSystemSamples.pulledAt)]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(WorkRecord(session: s, vaultName: "v")))
                                   as? [String: Any])
        XCTAssertNil(object["van_stock_system"])
        let line = try XCTUnwrap((object["van_stock"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(line.keys), ["id", "number", "description", "unit", "quantityScaled", "quantityScale",
                                        "verified", "at"])
    }

    func testAStateFromANewerBuildIsNotGuessedAt() throws {
        let (_, decoder) = Self.coders()
        let json = """
        {"id":"a","description":"D","unit":"each","quantityScaled":1000,"quantityScale":3,"verified":false,
         "at":"2026-11-20T09:10:00Z","itemID":"I","delivery":"teleported"}
        """
        let use = try decoder.decode(VanStockUse.self, from: Data(json.utf8))
        XCTAssertNil(use.delivery)
        XCTAssertEqual(use.itemID, "I")
    }

    // MARK: - A workbook under a system-held place

    func testAWorkbookIsNotLoadedAndThePersonIsTold() throws {
        _ = try make()
        let imports = VanStockImportService(store: h.vanStore, service: h.vanStock, isAllowed: { nil })
        imports.handle(data: Data("not a workbook".utf8), fileName: "van.xlsx")
        XCTAssertEqual(imports.stage, .refused(.heldBySystem("Square")))
        XCTAssertEqual(VanStockImportService.Refusal.heldBySystemSentence("Square"),
                       "Stock is kept in Square, so this list was kept as the previous list and not loaded.")
    }

    // MARK: - A staged store from before P4

    func testALineWrittenBeforeDeliveryStatesReadsAsNoted() throws {
        let json = """
        {"scope":"job:S1","jobReference":"1","connectorID":"square","locationID":"L","stagedAt":"2026-11-20T09:10:00Z",
         "call":"C","use":{"id":"a","itemID":"I","part":"P","description":"D","quantity":1000,"unit":"each",
         "verification":{"state":"not_checked"},"source":"spoken"}}
        """
        let (_, decoder) = Self.coders()
        let entry = try decoder.decode(StagedStockUseEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.delivery, .staged)
        XCTAssertTrue(entry.isAwaitingConfirmation)
    }
}
