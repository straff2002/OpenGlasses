import XCTest
@testable import OpenGlasses

/// Plan FP P3 — a team-learning bundle on the delivery channels and the offline queue, extending
/// P0's `DeliveryTests`: the payload case composes its subject and bodies from counts with no
/// candidate text, carries exactly one JSON attachment named for the bundle, queues the same op
/// `QueuedOp.make(learningBundle:)` makes, posts to an organisation endpoint with an
/// `Idempotency-Key`, and marks candidates `sent` when the bundle has left — never when it was
/// composed. `record` is optional and a job report is unaffected.
@MainActor
final class LearningBundleDeliveryTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var candidates: LearningCandidateStore!
    private var entries: LearningEntryStore!
    private var exports: StagedExportCoordinator!
    private var outbox: LearningBundleOutbox!
    private var recorded: [(id: String, status: LearningCandidate.Status)] = []
    private var hipaa = false
    private var granted: FieldAssistCapabilityCheck = .granted

    private let secret = "The pressure switch tubing sweats and reads open on a cold start"

    override func setUp() {
        super.setUp()
        root = F.tempDirectory("LearningBundleDelivery")
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        exports = StagedExportCoordinator(channel: .fieldSessionExport,
                                          rootDirectoryName: "LearningBundleDeliveryTests-\(UUID().uuidString.prefix(8))")
        outbox = LearningBundleOutbox(candidates: candidates, entries: entries)
        outbox.exports = exports
        outbox.capability = { [unowned self] in self.granted }
        outbox.hipaaMode = { [unowned self] in self.hipaa }
        outbox.organisationLabel = { "Northbridge Mechanical" }
        outbox.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        outbox.recordStatus = { [unowned self] candidate in self.recorded.append((candidate.id, candidate.status)) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: exports.root)
        outbox = nil
        exports = nil
        entries = nil
        candidates = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func filed(_ finding: String? = nil) -> LearningCandidate {
        let candidate = F.candidate(finding: finding ?? secret)
        candidates.add(candidate)
        return candidate
    }

    // MARK: - The envelope carries no text

    func testTheBundleRequestComposesItsEnvelopeFromCountsWithNoCandidateText() throws {
        _ = filed()
        _ = filed("The inducer bearing squeals below freezing")
        let bundle = try outbox.composeCandidates().get()
        let request = try outbox.deliveryRequest(for: bundle, channel: .email, recipients: ["base@example.com"]).get()

        XCTAssertEqual(request.subject, "Team learnings for review — 2 findings — Northbridge Mechanical")
        for text in [request.subject, request.body, request.shortBody, request.confirmation,
                     ReportComposerModel(request: request).filledBody] {
            XCTAssertFalse(text.contains("pressure switch"), text)
            XCTAssertFalse(text.contains("inducer"), text)
            XCTAssertFalse(text.contains("Sam Tane"), "nor the author: \(text)")
        }
        XCTAssertEqual(request.payload, .learningBundle(bundle, direction: .candidates))
        XCTAssertNil(request.record, "only report code reads the record, and a bundle has none")
        XCTAssertEqual(request.sessionId, LearningBundle.queueSessionID)
        XCTAssertEqual(request.partsRequestIds, [])
        XCTAssertNil(request.jobReference)

        XCTAssertEqual(request.attachments.count, 1)
        let attachment = try XCTUnwrap(request.attachments.first)
        XCTAssertEqual(attachment.kind, .json)
        XCTAssertEqual(attachment.filename, "team-learning-candidates-20270115-0800.json")
        XCTAssertEqual(try LearningBundle.decode(try XCTUnwrap(attachment.data)).get().bundle, bundle,
                       "the text travels in the attachment, exactly")
        XCTAssertTrue(request.confirmation.hasPrefix("Team learnings for review — 2 findings — Northbridge Mechanical ready to go by"),
                      request.confirmation)
        XCTAssertTrue(request.confirmation.contains("The learnings are in the attached file, not in the message."))
    }

    func testAChannelThatCannotCarryAFileCarriesNoneAndSaysSo() throws {
        _ = filed()
        let bundle = try outbox.composeCandidates().get()
        let request = try outbox.deliveryRequest(for: bundle, channel: .whatsapp, recipients: []).get()
        XCTAssertEqual(request.attachments, [])
        XCTAssertTrue(request.confirmation.contains("can't carry a file"), request.confirmation)
        XCTAssertFalse(ReportComposerModel(request: request).filledBody.contains("pressure switch"))
    }

    func testADecisionsBundleSubjectCountsEntriesRetractionsAndDecisions() throws {
        var kept = F.entry()
        kept = LearningEntry(id: kept.id, subject: kept.subject, vaultIDs: kept.vaultIDs, finding: secret,
                             approvedAt: kept.approvedAt, approvedByRole: "Service manager", approvedByName: "Ari")
        var gone = F.entry(finding: "Gone")
        gone.retractedAt = Date(timeIntervalSince1970: 1_791_600_000)
        gone.retractionReason = "Wrong unit"
        entries.upsert(kept)
        entries.upsert(gone)
        var imported = F.candidate(session: "job-field")
        imported.importedFrom = "team-learning bundle"
        imported.status = .notTakenUp
        imported.reviewReason = "Already in the manual"
        candidates.add(imported)

        let bundle = try outbox.composeDecisions().get()
        XCTAssertEqual(bundle.entries.count, 2)
        XCTAssertEqual(bundle.retracted.map(\.entryID), [gone.id])
        XCTAssertEqual(bundle.statuses.map(\.status), [.notTakenUp])
        XCTAssertEqual(bundle.statuses.first?.reason, "Already in the manual")
        XCTAssertNoThrow(try LearningBundle.decode(bundle.encoded()).get(), "what this phone makes, another accepts")
        let request = try outbox.deliveryRequest(for: bundle, channel: .shareSheet, recipients: []).get()
        XCTAssertEqual(request.subject,
                       "Team learnings — 2 approved learnings, 1 retraction, 1 review decision — Northbridge Mechanical")
        XCTAssertFalse(request.body.contains(secret))
        XCTAssertFalse(request.body.contains("Already in the manual"), "a reviewer's reason is text too")
    }

    // MARK: - The queue

    func testTheQueuedOpIsTheBundlesOwnBytesUnderNoJob() throws {
        _ = filed()
        let bundle = try outbox.composeCandidates().get()
        let request = try outbox.deliveryRequest(for: bundle, channel: .endpoint, recipients: []).get()
        let queued = request.payload.queuedOp()
        let made = QueuedOp.make(learningBundle: bundle)
        XCTAssertEqual(queued.kind, .teamLearning)
        XCTAssertEqual(queued.kind, made.kind)
        XCTAssertEqual(queued.sessionId, made.sessionId)
        XCTAssertEqual(queued.sessionId, LearningBundle.queueSessionID)
        XCTAssertEqual(queued.payload, made.payload)
        XCTAssertEqual(queued.payload, bundle.encoded())
        XCTAssertEqual(queued.payloadJSON["direction"] as? String, "candidates")
        XCTAssertEqual(QueuedRecordRows.outstandingCount(in: [queued], sessionId: LearningBundle.queueSessionID), 0,
                       "not a job record: the per-job counts and the unsent-reports list never include it")
        XCTAssertFalse(QueuedRecordRows.kinds.contains(.teamLearning))
    }

    func testTheEndpointReceivesTheBundleWithItsIdempotencyKeyAndDirection() async throws {
        _ = filed()
        let op = QueuedOp.make(learningBundle: try outbox.composeCandidates().get())
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: EndpointSyncSink.body(for: op)) as? [String: Any])
        XCTAssertEqual(body["op"] as? String, "teamLearning")
        XCTAssertEqual(body["op_id"] as? String, op.id)
        XCTAssertEqual(body["session_id"] as? String, LearningBundle.queueSessionID)
        XCTAssertEqual(body["direction"] as? String, "candidates")
        XCTAssertNil(body["job_reference"])
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, LearningBundle.kind)
        XCTAssertEqual((payload["candidates"] as? [Any])?.count, 1)

        XCTAssertTrue(EndpointSyncSink.handledKinds.contains(.teamLearning))
        XCTAssertFalse(OfficeReportSink.handledKinds.contains(.teamLearning),
                       "the office route is the signed contract, not this")

        DeliveryStubProtocol.reset()
        let spy = SpySink()
        var delivered: [String] = []
        let sink = EndpointSyncSink(fallback: spy, session: DeliveryStubProtocol.session(),
                                    endpoint: { URL(string: "https://ops.example.com/team-learnings") },
                                    token: { "" })
        sink.onDelivered = { delivered.append($0.id) }
        let outcome = await sink.deliver(op)
        XCTAssertEqual(outcome, .done)
        XCTAssertTrue(spy.delivered.isEmpty)
        XCTAssertEqual(DeliveryStubProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), op.id)
        XCTAssertEqual(delivered, [op.id])

        // With no endpoint, the local sink takes it — and that is not "sent".
        let local = EndpointSyncSink(fallback: LocalSyncSink(), session: DeliveryStubProtocol.session(),
                                     endpoint: { nil }, token: { "" })
        var told = false
        local.onDelivered = { _ in told = true }
        _ = await local.deliver(op)
        XCTAssertFalse(told)
    }

    // MARK: - Sent means it left

    func testSentIsSetWhenTheBundleLeavesNeverWhenItIsComposed() throws {
        let one = filed()
        let bundle = try outbox.composeCandidates().get()
        let request = try outbox.deliveryRequest(for: bundle, channel: .email, recipients: ["base@example.com"]).get()
        XCTAssertEqual(candidates.candidate(id: one.id)?.status, .filed, "composed and staged is not sent")

        for outcome in [DeliveryOutcome.cancelled, .saved, .handedOff, .failed("no network")] {
            outbox.completed(request, outcome: outcome)
            XCTAssertEqual(candidates.candidate(id: one.id)?.status, .filed, "\(outcome) is not a send")
        }
        XCTAssertTrue(recorded.isEmpty)

        outbox.completed(request, outcome: .sent)
        XCTAssertEqual(candidates.candidate(id: one.id)?.status, .sent)
        XCTAssertEqual(recorded.map(\.status), [.sent], "the job it was filed on hears it")
        outbox.completed(request, outcome: .sent)
        XCTAssertEqual(recorded.count, 1, "sent once")
    }

    func testTheEndpointAcceptingTheQueuedBundleMarksItsCandidatesSent() throws {
        let one = filed()
        let op = try outbox.queuedOp(for: try outbox.composeCandidates().get()).get()
        XCTAssertEqual(candidates.candidate(id: one.id)?.status, .filed, "queued is not sent")
        outbox.delivered(op)
        XCTAssertEqual(candidates.candidate(id: one.id)?.status, .sent)
        outbox.delivered(QueuedOp.make(workRecord: WorkRecordFixtureForBundles.record()))
        XCTAssertEqual(recorded.count, 1, "another kind of op changes nothing")
    }

    func testAWithdrawalTravelsAndAnAnsweredCandidateDoesNot() throws {
        var withdrawn = F.candidate(finding: "")
        withdrawn.status = .withdrawn
        withdrawn.symptom = nil
        withdrawn.fix = nil
        withdrawn.revision = 2
        candidates.add(withdrawn)
        var answered = F.candidate()
        answered.status = .approved
        candidates.add(answered)
        var imported = F.candidate()
        imported.importedFrom = "team-learning bundle"
        candidates.add(imported)
        let bundle = try outbox.composeCandidates().get()
        XCTAssertEqual(bundle.candidates.map(\.candidateID), [withdrawn.id])
        XCTAssertEqual(bundle.candidates.first?.withdrawn, true)
        XCTAssertNoThrow(try LearningBundle.decode(bundle.encoded()).get())
        outbox.markSent(bundle)
        XCTAssertEqual(candidates.candidate(id: withdrawn.id)?.status, .withdrawn, "a withdrawal stays withdrawn")
    }

    // MARK: - Gates

    func testHIPAAModeAndTheLicenceStopEveryBundleOut() {
        _ = filed()
        hipaa = true
        XCTAssertEqual(outbox.composeCandidates().failureValue, .hipaa)
        XCTAssertEqual(outbox.composeDecisions().failureValue, .hipaa)
        XCTAssertNil(outbox.vaultExport(vaultId: F.vaultId))
        hipaa = false
        granted = .denied(.noEvidence)
        XCTAssertEqual(outbox.composeCandidates().failureValue,
                       .notEntitled(FieldAssistPaywallCopy.teamLearningsBundleLocked))
        granted = .granted
        XCTAssertEqual(outbox.composeDecisions().failureValue, .nothingToSend)
    }

    // MARK: - A job report is unaffected

    func testAJobReportStillCarriesItsRecordAndItsSentence() {
        let record = WorkRecordFixtureForBundles.record()
        let request = DeliveryRequest.make(record: record, channel: .email, recipients: ["office@example.com"],
                                           attachments: [])
        XCTAssertEqual(request.record, record)
        XCTAssertNil(request.payload.learningBundle)
        XCTAssertTrue(request.confirmation.hasPrefix("Job report ready to go by"), request.confirmation)
    }
}

/// A minimal finished job, for the one test here that needs a report beside a bundle.
@MainActor
enum WorkRecordFixtureForBundles {
    static func record() -> WorkRecord {
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let session = FieldSession(id: "session-bundle", vaultId: "lennox_slp99", assetId: nil, mode: .aiOnly,
                                   startedAt: started, endedAt: started.addingTimeInterval(600), outcome: .resolved,
                                   escalations: [], billableSeconds: 600, jobReference: "4471")
        return WorkRecord(session: session, vaultName: "Lennox SLP99")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
