import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// A queued record reaching the office over the managed folders, headless: the real queue and
/// sync engine, the office sink and report service, the in-memory transport, and the Go golden
/// fixtures as the office's side.
@MainActor
final class OfficeReportServiceTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private typealias Service = OfficeReportService

    private static let operationID = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"
    private static let sessionID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    /// The fixture attachments' bytes are public sentences; only their digests are in the manifest.
    private static let attachmentBytes = [
        "workOrder": "Avenkin public fixture work order v1",
        "transcript": "Avenkin public fixture transcript v1",
        "photo": "Avenkin public fixture photo v1",
    ]

    private let transport = OfficeManagedFolderMemoryTransport()
    private var directory: URL!
    private var saved = Service.Ledger()
    private var gateFailure: Error?
    private var officeIsDestination = true
    private var signs = 0
    private var evidenceFailure: Error?
    private var missingFiles: Set<String> = []

    private struct Failed: Error {}

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeReportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - The world

    private func openFolders() async throws {
        let held = try F.held()
        let binding = try F.fields(F.payload("office-check-in-binding-v1"))
        let fields: [String: Any] = [
            "organizationID": held.organizationID, "enrolmentID": held.enrolmentID, "officeID": held.officeID,
            "generation": 1, "officeTransportID": try XCTUnwrap(binding["officeTransportID"]),
            "officeApplicationKey": held.officeApplicationKey.base64EncodedString(),
            "phoneApplicationKey": held.phoneApplicationKey.base64EncodedString(),
        ]
        try await transport.startFolders(
            bindingJSON: String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self),
            policy: "automatic", lanHint: "")
    }

    /// A service over `saved`, so a second one is the app launched again.
    private func makeService() -> Service {
        var seams = Service.Seams(transport: transport, held: { [unowned self] in
            if let gateFailure = self.gateFailure { throw gateFailure }
            return try F.held()
        })
        // The golden report's own signature for the golden payload (CryptoKit's signatures are
        // randomised, so the fixture's bytes are only reproduced by its own); the fixture phone
        // key for anything else.
        seams.sign = { [unowned self] payload in
            await MainActor.run { self.signs += 1 }
            guard OfficeReport.reportPayload(payload) != nil else { throw OfficePhoneIdentity.Refusal.invalidReport }
            if payload == (try F.payload("office-report-v1")) {
                return try XCTUnwrap(Data(base64Encoded: F.envelope(F.data("office-report-v1")).signature))
            }
            return try F.phone().signature(for: OfficeReport.reportDomain + payload)
        }
        seams.load = { [unowned self] in self.saved }
        seams.save = { [unowned self] in self.saved = $0 }
        return Service(seams: seams)
    }

    /// The golden report's three attachments, each in a file holding its exact bytes.
    private func goldenEvidence() throws -> [Service.Evidence] {
        try XCTUnwrap(OfficeReport.manifest(F.data("office-report-manifest-v1"))).map { attachment in
            let file = directory.appendingPathComponent(attachment.sha256)
            if !missingFiles.contains(attachment.role) {
                try Data(try XCTUnwrap(Self.attachmentBytes[attachment.role]).utf8).write(to: file)
            }
            return Service.Evidence(attachment: attachment, file: file)
        }
    }

    private func makeSink(_ service: Service, fallback: SyncSink? = nil) -> OfficeReportSink {
        OfficeReportSink(seams: .init(
            fallback: fallback ?? LocalSyncSink(),
            officeIsDestination: { [unowned self] in self.officeIsDestination },
            reports: service,
            evidence: { [unowned self] _ in
                if let evidenceFailure = self.evidenceFailure { throw evidenceFailure }
                return (try self.goldenEvidence(), .attached)
            }))
    }

    /// The queued operation the golden report is the report of.
    private func goldenOp(id: String = operationID, record: Data? = nil) throws -> QueuedOp {
        QueuedOp(id: id, kind: .workRecord, sessionId: Self.sessionID,
                 payload: try record ?? F.data("office-report-record-v1"),
                 createdAt: Date(timeIntervalSince1970: TimeInterval(F.now)))
    }

    private func makeQueue() -> OfflineQueue {
        OfflineQueue(path: directory.appendingPathComponent("queue-\(UUID().uuidString).sqlite"))
    }

    private var reportID: String { OfficeReport.reportID(operationID: Self.operationID) }

    private func officeAnswers(_ stage: String) async throws {
        await transport.put(receipt: try F.data("office-report-receipt-\(stage)-v1"), reportID: reportID, stage: stage)
    }

    // MARK: - The exit: the fixture round trip

    func testTheFixtureRecordReachesTheOfficeAndIsDeliveredOnlyOnItsReceipt() async throws {
        try await openFolders()
        let service = makeService()
        let queue = makeQueue()
        let engine = SyncEngine(queue: queue, sink: makeSink(service))
        queue.enqueue(try goldenOp())

        let first = await engine.flush()
        XCTAssertEqual(first, 0, "published is not delivered")
        // What is in the folder is the golden report, with the record and manifest it names…
        let reports = await transport.reports
        let records = await transport.reportRecords
        let manifests = await transport.reportManifests
        XCTAssertEqual(reports[reportID], try F.data("office-report-v1"))
        XCTAssertEqual(records[reportID], try F.data("office-report-record-v1"))
        XCTAssertEqual(manifests[reportID], try F.data("office-report-manifest-v1"))
        // …and every attachment, as its exact bytes.
        let attachments = await transport.attachments
        XCTAssertEqual(Set(attachments.values.map { String(decoding: $0, as: UTF8.self) }),
                       Set(Self.attachmentBytes.values))
        XCTAssertEqual(service.status(operationID: Self.operationID), .waiting)
        XCTAssertEqual(queue.pending().first?.attempts, 0)

        // The office has the record; a required attachment is still to arrive.
        try await officeAnswers("pending")
        var changed = try await service.sweep()
        XCTAssertTrue(changed)
        XCTAssertEqual(service.status(operationID: Self.operationID), .evidencePending)
        let stillWaiting = await engine.flush()
        XCTAssertEqual(stillWaiting, 0, "evidence pending is not delivered")
        XCTAssertEqual(queue.pendingCount, 1)

        // Every required attachment is in: delivered.
        try await officeAnswers("record")
        changed = try await service.sweep()
        XCTAssertTrue(changed)
        XCTAssertEqual(service.status(operationID: Self.operationID), .recordAccepted)
        XCTAssertEqual(service.notFullyAccepted(recordIDs: [Self.sessionID]), 1,
                       "delivered, but not everything the report named is at the office")
        let delivered = await engine.flush()
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(queue.pendingCount, 0)
        var withdrawn = await transport.withdrawnReports
        XCTAssertEqual(withdrawn, [], "optional evidence keeps travelling")

        // Everything is in: the report's files leave the folder.
        try await officeAnswers("full")
        changed = try await service.sweep()
        XCTAssertTrue(changed)
        XCTAssertEqual(service.status(operationID: Self.operationID), .fullyAccepted)
        XCTAssertEqual(service.notFullyAccepted(recordIDs: [Self.sessionID]), 0)
        withdrawn = await transport.withdrawnReports
        XCTAssertEqual(withdrawn, [reportID])
        let left = await transport.attachments
        XCTAssertTrue(left.isEmpty)
        // Nothing was signed twice, and another pass changes nothing.
        XCTAssertEqual(signs, 1)
        changed = try await service.sweep()
        XCTAssertFalse(changed)
        let publishes = await transport.reportPublishes
        XCTAssertEqual(publishes, 1)
    }

    // MARK: - The exit: a lost receipt

    func testALostReceiptIsAskedForAgainAndMatches() async throws {
        try await openFolders()
        let service = makeService()
        try await service.submit(try XCTUnwrap(OfficeReportSink.submission(
            for: goldenOp(), evidence: goldenEvidence(), transcript: .attached)))
        // The office receipted it, and this phone's record of the report was lost before it
        // heard: as after its storage was restored from before the send.
        try await officeAnswers("record")
        saved = Service.Ledger()
        let relaunched = makeService()
        XCTAssertNil(relaunched.status(operationID: Self.operationID))

        // The record is still queued, so it is sent again: the report in the folder is the same
        // file, and the office's receipt for it is the same receipt.
        let status = try await relaunched.submit(try XCTUnwrap(OfficeReportSink.submission(
            for: goldenOp(), evidence: goldenEvidence(), transcript: .attached)))
        XCTAssertEqual(status, .waiting)
        let reports = await transport.reports
        let publishes = await transport.reportPublishes
        XCTAssertEqual(reports[reportID], try F.data("office-report-v1"), "the same bytes")
        XCTAssertEqual(publishes, 1, "and nothing published a second time")
        try await relaunched.sweep()
        XCTAssertEqual(relaunched.status(operationID: Self.operationID), .recordAccepted)

        // A receipt that only arrives later is taken then; one already taken changes nothing.
        try await officeAnswers("full")
        try await relaunched.sweep()
        XCTAssertEqual(relaunched.status(operationID: Self.operationID), .fullyAccepted)
        let again = try await relaunched.sweep()
        XCTAssertFalse(again)
    }

    // MARK: - The exit: an unreachable office

    func testAnUnreachableOfficeLeavesTheQueueIntactPastTheOldRetryLimit() async throws {
        let service = makeService()
        let queue = makeQueue()
        let engine = SyncEngine(queue: queue, sink: makeSink(service))
        queue.enqueue(try goldenOp())

        // The folders are closed: the office is off, or the phone is out of reach of it.
        for _ in 0..<(engine.maxAttempts * 3) {
            let delivered = await engine.flush()
            XCTAssertEqual(delivered, 0)
        }
        XCTAssertEqual(queue.pending().map(\.id), [Self.operationID], "still queued")
        XCTAssertEqual(queue.pending().first?.attempts, 0, "and no attempt counted")
        XCTAssertEqual(queue.all().first?.state, .pending)

        // The pairing does not verify just now — a lapsed lease, say. Still waiting, not failing.
        try await openFolders()
        gateFailure = OfficePairingService.Refusal.inactiveLease
        for _ in 0..<(engine.maxAttempts * 3) { _ = await engine.flush() }
        XCTAssertEqual(queue.pending().first?.attempts, 0)
        let none = await transport.reports
        XCTAssertTrue(none.isEmpty, "nothing is published on a pairing that does not verify")

        // Connected, with no answer from the office: published, and still waiting however long.
        gateFailure = nil
        for _ in 0..<(engine.maxAttempts * 3) { _ = await engine.flush() }
        let reports = await transport.reports
        XCTAssertEqual(reports[reportID], try F.data("office-report-v1"))
        XCTAssertEqual(queue.pending().first?.attempts, 0)
        XCTAssertEqual(signs, 1)

        // And it is delivered when the office says so.
        try await officeAnswers("record")
        try await service.sweep()
        let delivered = await engine.flush()
        XCTAssertEqual(delivered, 1)
    }

    // MARK: - Receipts that change nothing

    func testOnlyAReceiptForExactlyTheReportPublishedCountsAndAnOutcomeNeverGoesBack() async throws {
        try await openFolders()
        let service = makeService()
        try await service.submit(try XCTUnwrap(OfficeReportSink.submission(
            for: goldenOp(), evidence: goldenEvidence(), transcript: .attached)))
        let full = try F.payload("office-report-receipt-full-v1")
        let foreign: [(String, String, Data)] = [
            ("signed by the phone", "full", try F.signed(full, domain: OfficeReport.receiptDomain, by: F.phone())),
            ("under the report's domain", "full", try F.signed(full, domain: OfficeReport.reportDomain, by: F.office())),
            ("for another report's bytes", "full",
             try F.changed("office-report-receipt-full-v1", domain: OfficeReport.receiptDomain, by: F.office()) {
                 $0["reportSHA256"] = String(repeating: "0", count: 64)
             }),
            ("for another phone", "full",
             try F.changed("office-report-receipt-full-v1", domain: OfficeReport.receiptDomain, by: F.office()) {
                 $0["phoneTransportID"] = OfficeReportTests.otherPhone
             }),
            ("a full receipt under the pending name", "pending", try F.data("office-report-receipt-full-v1")),
            ("not a receipt", "record", Data("receipt".utf8)),
        ]
        for (name, stage, receipt) in foreign {
            await transport.put(receipt: receipt, reportID: reportID, stage: stage)
            let changed = try await service.sweep()
            XCTAssertFalse(changed, name)
            XCTAssertEqual(service.status(operationID: Self.operationID), .waiting, name)
        }
        // Record accepted, and then an earlier outcome is seen again: it stays accepted.
        try await officeAnswers("record")
        try await service.sweep()
        try await officeAnswers("pending")
        await transport.put(receipt: Data("receipt".utf8), reportID: reportID, stage: "full")
        try await service.sweep()
        XCTAssertEqual(service.status(operationID: Self.operationID), .recordAccepted)
        let withdrawn = await transport.withdrawnReports
        XCTAssertEqual(withdrawn, [])
    }

    // MARK: - Revisions

    func testALaterSendIsAHigherRevisionAndWithdrawsOneTheOfficeHasNotAccepted() async throws {
        try await openFolders()
        let service = makeService()
        let queue = makeQueue()
        let engine = SyncEngine(queue: queue, sink: makeSink(service))
        queue.enqueue(try goldenOp())
        _ = await engine.flush()

        // The same job's record again, with more in it: another operation.
        let laterRecord = Data(String(decoding: try F.data("office-report-record-v1"), as: UTF8.self)
            .replacingOccurrences(of: #""tasks":[]"#, with: #""debriefs":[],"tasks":[]"#).utf8)
        let laterID = "0E984725-C51C-4BF4-9960-E1C80E27ABA0"
        var later = try goldenOp(id: laterID, record: laterRecord)
        later = QueuedOp(id: later.id, kind: later.kind, sessionId: later.sessionId, payload: later.payload,
                         createdAt: later.createdAt.addingTimeInterval(60))
        queue.enqueue(later)
        // The earlier one is ahead of it in the queue, so it is released on the pass after.
        _ = await engine.flush()
        let delivered = await engine.flush()
        XCTAssertEqual(delivered, 1, "the earlier one is released: the later one says everything it said")
        XCTAssertEqual(service.status(operationID: Self.operationID), .superseded)
        XCTAssertEqual(service.status(operationID: laterID), .waiting)
        XCTAssertEqual(queue.pending().map(\.id), [laterID])

        let laterReportID = OfficeReport.reportID(operationID: laterID)
        let reports = await transport.reports
        let withdrawn = await transport.withdrawnReports
        XCTAssertEqual(Array(reports.keys), [laterReportID])
        XCTAssertEqual(withdrawn, [reportID])
        let published = try OfficeReport.report(
            XCTUnwrap(reports[laterReportID]), phoneApplicationKey: F.phone().publicKey.rawRepresentation,
            identity: OfficeReport.Identity(F.held()))
        XCTAssertEqual(published.revision, 2)
        XCTAssertEqual(published.recordID, Self.sessionID)
        XCTAssertEqual(published.jobID, "job-2031")
        // The evidence both named is still there for the later one.
        let attachments = await transport.attachments
        XCTAssertEqual(attachments.count, 3)
        // A receipt for the withdrawn revision changes nothing.
        try await officeAnswers("full")
        try await service.sweep()
        XCTAssertEqual(service.status(operationID: Self.operationID), .superseded)

    }

    func testARevisionTheOfficeHasAcceptedIsNotWithdrawnByALaterSend() async throws {
        try await openFolders()
        let service = makeService()
        try await service.submit(try XCTUnwrap(OfficeReportSink.submission(
            for: goldenOp(), evidence: goldenEvidence(), transcript: .attached)))
        try await officeAnswers("record")
        try await service.sweep()
        let later = try goldenOp(id: "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
                                 record: Data(#"{"job_reference":"JOB-1042","tasks":[1]}"#.utf8))
        try await service.submit(try XCTUnwrap(OfficeReportSink.submission(
            for: later, evidence: [], transcript: .none)))
        XCTAssertEqual(service.status(operationID: Self.operationID), .recordAccepted)
        let withdrawn = await transport.withdrawnReports
        let reports = await transport.reports
        XCTAssertEqual(withdrawn, [])
        XCTAssertEqual(reports.count, 2)
    }

    // MARK: - Evidence that is not there yet

    func testEvidenceThatCannotBePublishedYetIsTriedAgainAndTheRestStillGoes() async throws {
        try await openFolders()
        let service = makeService()
        missingFiles = ["photo"]
        let queue = makeQueue()
        let engine = SyncEngine(queue: queue, sink: makeSink(service))
        queue.enqueue(try goldenOp())
        _ = await engine.flush()
        var attachments = await transport.attachments
        XCTAssertEqual(attachments.count, 2, "the two that are there are published")
        XCTAssertEqual(queue.pending().first?.attempts, 0, "and nothing is counted against the record")
        let reports = await transport.reports
        XCTAssertNotNil(reports[reportID])

        // The file turns up: the next pass publishes it.
        missingFiles = []
        _ = try goldenEvidence()
        try await service.sweep()
        attachments = await transport.attachments
        XCTAssertEqual(attachments.count, 3)
    }

    // MARK: - What is not a report

    func testARecordThatCannotBeAReportFailsWithAReasonRatherThanWaitingForever() async throws {
        try await openFolders()
        let service = makeService()
        let sink = makeSink(service)
        let tooLarge = try goldenOp(record: Data(repeating: 0x20, count: OfficeReport.maximumRecordBytes + 1))
        guard case .permanent(let reason) = await sink.deliver(tooLarge) else { return XCTFail("a record over the cap waited") }
        XCTAssertFalse(reason.isEmpty)
        let noRequest = QueuedOp(kind: .partsRequest, sessionId: Self.sessionID, payload: Data(#"{"quantity":1}"#.utf8))
        guard case .permanent = await sink.deliver(noRequest) else { return XCTFail("a request with no identifier waited") }
        let published = await transport.reports
        XCTAssertTrue(published.isEmpty)

        // A stock check is a report of its own: its own record, no evidence, no transcript.
        let request = QueuedOp(id: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", kind: .partsRequest, sessionId: Self.sessionID,
                               payload: Data(#"{"id":"5B1E0B3C-7F0D-4E55-9F0E-0E6B1C2D3E4F","quantity":1}"#.utf8))
        guard case .waiting = await sink.deliver(request) else { return XCTFail("a stock check was not published") }
        let reports = await transport.reports
        let report = try OfficeReport.report(
            XCTUnwrap(reports.values.first), phoneApplicationKey: F.phone().publicKey.rawRepresentation,
            identity: OfficeReport.Identity(F.held()))
        XCTAssertEqual(report.recordKind, "partsRequest")
        XCTAssertEqual(report.recordID, "5B1E0B3C-7F0D-4E55-9F0E-0E6B1C2D3E4F")
        XCTAssertEqual(report.transcript, "none")
        XCTAssertEqual(report.jobID, "")
        let manifests = await transport.reportManifests
        XCTAssertEqual(manifests.values.first, OfficeReport.manifestBytes([]))
    }

    func testEverythingElseGoesWhereItWentBefore() async throws {
        try await openFolders()
        let fallback = LocalSyncSink()
        let sink = makeSink(makeService(), fallback: fallback)
        // Another kind of operation is not a report.
        let photo = QueuedOp(kind: .photoUpload, sessionId: Self.sessionID)
        guard case .done = await sink.deliver(photo) else { return XCTFail() }
        // A phone whose records do not go to an office sends nothing this way.
        officeIsDestination = false
        guard case .done = await sink.deliver(try goldenOp()) else { return XCTFail() }
        XCTAssertEqual(fallback.delivered, [photo.id, Self.operationID])
        let published = await transport.reports
        XCTAssertTrue(published.isEmpty)
    }

    func testAJobReferenceWithMoreThanOneSpellingIsLeftToTheRecord() throws {
        let record = Data(#"{"job_reference":"Smith & Co — 7","tasks":[]}"#.utf8)
        let submission = try XCTUnwrap(OfficeReportSink.submission(
            for: goldenOp(record: record), evidence: [], transcript: .none))
        XCTAssertEqual(submission.jobReference, "")
        XCTAssertEqual(submission.jobID, "")
        XCTAssertEqual(submission.jobRevision, 0)
        XCTAssertEqual(submission.record, record, "the record itself is sent as it is")
    }

    func testALeavingPhoneForgetsWhatItKeptAboutItsRecords() async throws {
        try await openFolders()
        let service = makeService()
        try await service.submit(try XCTUnwrap(OfficeReportSink.submission(
            for: goldenOp(), evidence: goldenEvidence(), transcript: .attached)))
        XCTAssertEqual(service.summary, .init(waiting: 1, evidencePending: 0))
        XCTAssertEqual(service.settledOperationIDs, [])
        try await officeAnswers("full")
        try await service.sweep()
        XCTAssertEqual(service.settledOperationIDs, [Self.operationID])
        XCTAssertEqual(service.summary, .init())
        service.forget(recordIDs: ["another-job"])
        XCTAssertNotNil(service.status(operationID: Self.operationID))
        service.forget(recordIDs: [Self.sessionID])
        XCTAssertNil(service.status(operationID: Self.operationID))
        XCTAssertTrue(saved.entries.isEmpty)
    }

    func testTheRecordSurvivesAFileRoundTrip() throws {
        let file = directory.appendingPathComponent("reports.json")
        XCTAssertEqual(Service.readLedger(file), Service.Ledger())
        var ledger = Service.Ledger()
        ledger.revisions["a"] = 3
        try Service.writeLedger(ledger, to: file)
        XCTAssertEqual(Service.readLedger(file), ledger)
    }
}
