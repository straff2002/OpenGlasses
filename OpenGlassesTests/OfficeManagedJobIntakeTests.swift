import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// A job the office transport has committed reaching the technician's review, and its receipt,
/// driven headless through the in-memory transport.
@MainActor
final class OfficeManagedJobIntakeTests: XCTestCase {
    private typealias Intake = OfficeManagedJobIntake
    private typealias Transport = OfficeManagedFolderMemoryTransport

    private let transport = Transport()
    /// The fictional phone key the fixture generator derives from a public label.
    private let phone: Curve25519.Signing.PrivateKey = {
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture phone application key v1".utf8)))
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }()
    private var saved = Intake.Ledger()
    private var saveFailure: Error?
    private var signFailure: Error?
    private var signs = 0
    private var refusalChecks = 0
    private var raisedFiles: [String] = []
    private var reviewBusy = false

    private struct Failed: Error, Equatable {}

    // MARK: - Fixtures

    private func fixture(_ name: String, extension ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
    private func keys() throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: fixture("managed-job-fixture-keys", extension: "json"))
        return try XCTUnwrap(object as? [String: Any]).compactMapValues { $0 as? String }
    }
    private func goldenReceiptPayload() throws -> Data {
        let envelope = try JSONDecoder().decode(OfficeManagedJobReceipt.Envelope.self,
                                                from: fixture("managed-job-receipt-v1", extension: "json"))
        return try XCTUnwrap(Data(base64Encoded: envelope.payload))
    }
    private func goldenJob() throws -> Transport.Job {
        let receipt = try XCTUnwrap(OfficeManagedJobReceipt.payload(goldenReceiptPayload()))
        return try Transport.Job(messageID: receipt.messageID, sequence: receipt.sequence,
                                 file: fixture("managed-job-v1", extension: "ogjob"),
                                 receiptPayload: goldenReceiptPayload())
    }
    /// Another job under the fixture binding, with the receipt payload the transport would offer.
    private func job(sequence: Int64, file: Data? = nil) throws -> Transport.Job {
        let bytes = file ?? Data(#"{"format":"openglasses.job","format_version":1,"job_reference":"FX-\#(2000 + sequence)","site":{"customer":"Fixture Service"}}"#.utf8)
        let messageID = String(format: "%032x", sequence)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: goldenReceiptPayload()) as? [String: Any])
        fields["messageID"] = messageID
        fields["sequence"] = sequence
        fields["jobSHA256"] = Intake.sha256(bytes)
        fields["payloadSHA256"] = Intake.sha256(Data("payload \(sequence)".utf8))
        return Transport.Job(messageID: messageID, sequence: sequence, file: bytes,
                             receiptPayload: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    }
    private func openFolders() async throws {
        let keys = try keys()
        let binding: [String: Any] = [
            "organizationID": "fixture-org", "enrolmentID": "fixture-phone", "officeID": "fixture-office",
            "generation": 1, "officeTransportID": try XCTUnwrap(keys["officeTransportID"]),
            "officeApplicationKey": try XCTUnwrap(keys["officeApplicationKey"]),
            "phoneApplicationKey": try XCTUnwrap(keys["phoneApplicationKey"]),
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: binding), as: UTF8.self)
        try await transport.startFolders(bindingJSON: json, policy: "automatic", lanHint: "")
    }

    /// An intake over counting stand-ins for the import and its review.
    private func makeIntake(refuse: @escaping (Data) -> String? = { _ in nil }) -> Intake {
        Intake(seams: seams(
            refusal: { [unowned self] in
                self.refusalChecks += 1
                return refuse($0)
            },
            raise: { [unowned self] _, name in
                if self.reviewBusy { return .busy }
                self.raisedFiles.append(name)
                return .raised
            }))
    }
    private func seams(refusal: @escaping @MainActor (Data) -> String?,
                       raise: @escaping @MainActor (Data, String) -> Intake.Raised) -> Intake.Seams {
        var seams = Intake.Seams(transport: transport, refusal: refusal, raise: raise)
        seams.sign = { [unowned self] payload in
            try await self.sign(payload)
        }
        seams.load = { [unowned self] in self.saved }
        seams.save = { [unowned self] in
            if let failure = self.saveFailure { throw failure }
            self.saved = $0
        }
        return seams
    }
    private func sign(_ payload: Data) throws -> Data {
        if let signFailure { throw signFailure }
        signs += 1
        return try phone.signature(for: OfficeManagedJobReceipt.domain + payload)
    }

    // MARK: - The exit: a fixture job reaches the review, and its receipt verifies

    func testAFixtureJobReachesTheJobReviewAndItsReceiptVerifies() async throws {
        try await openFolders()
        await transport.commit(try goldenJob())
        // The app's own wiring: the real job-file import and its review.
        let jobFiles = JobFileService()
        var seams = Intake.Seams.app(transport: transport, jobFiles: jobFiles, ledgerFile: nil)
        seams.sign = { [unowned self] in try await self.sign($0) }
        seams.load = { [unowned self] in self.saved }
        seams.save = { [unowned self] in self.saved = $0 }
        let intake = Intake(seams: seams)
        XCTAssertEqual(intake.state, .waitingForOffice)

        try await intake.sweep()

        // The technician's review, raised and unanswered: nothing was added by the office's signature.
        guard case .review(let review) = jobFiles.stage else {
            return XCTFail("the job did not reach the review: \(jobFiles.stage)")
        }
        XCTAssertEqual(review.proposed.jobReference, "FX-1007")
        XCTAssertEqual(review.proposed.provenance?.digest, try goldenJob().jobSHA256)
        XCTAssertFalse(review.isSigned, "the office connection does not sign the job file itself")
        XCTAssertEqual(intake.state, .jobReceived(1))

        // The receipt, by the receipt contract's rules: the binding's phone key, the binding, and
        // exactly the message the office sent.
        let keys = try keys()
        let sent = try OfficeManagedJob.verify(
            fixture("managed-job-v1", extension: "json"),
            trust: .init(organizationID: "fixture-org", enrolmentID: "fixture-phone",
                         officeID: "fixture-office", generation: 1,
                         officeTransportID: XCTUnwrap(keys["officeTransportID"]),
                         phoneTransportID: XCTUnwrap(keys["phoneTransportID"]),
                         officeApplicationKey: XCTUnwrap(Data(base64Encoded: XCTUnwrap(keys["officeApplicationKey"])))),
            now: 1_800_000_000)
        let published = await transport.receipts
        let receipt = try OfficeManagedJobReceipt.verify(
            XCTUnwrap(published[sent.payload.messageID]),
            trust: .init(organizationID: "fixture-org", enrolmentID: "fixture-phone",
                         officeID: "fixture-office", generation: 1,
                         phoneTransportID: XCTUnwrap(keys["phoneTransportID"]),
                         phoneApplicationKey: XCTUnwrap(Data(base64Encoded: XCTUnwrap(keys["phoneApplicationKey"])))),
            expected: .init(messageID: sent.payload.messageID, sequence: sent.payload.sequence,
                            payloadSHA256: sent.payloadSHA256, jobSHA256: sent.payload.jobSHA256))
        XCTAssertEqual(receipt.outcome, "received")

        // Closing the review without adding the job puts it aside: no pass raises it again, and
        // it is said to be there for the technician to review when they choose.
        intake.reviewStageChanged(jobFiles.stage)
        jobFiles.dismiss()
        intake.reviewStageChanged(jobFiles.stage)
        XCTAssertEqual(intake.state, .jobPutAside(1))
        try await intake.sweep()
        XCTAssertEqual(jobFiles.stage, .idle)

        // Asked for, it is the same review again, through the real import.
        let again = try await intake.reviewPutAside()
        XCTAssertEqual(again, .raised)
        guard case .review(let second) = jobFiles.stage else {
            return XCTFail("the job put aside did not reach the review again: \(jobFiles.stage)")
        }
        XCTAssertEqual(second.proposed.provenance?.digest, try goldenJob().jobSHA256)
        XCTAssertEqual(intake.state, .jobReceived(1))
        let receiptsAfter = await transport.receipts
        XCTAssertEqual(receiptsAfter, published, "no second receipt")
    }

    // MARK: - Once

    func testAJobIsOfferedOnceAndAnExactRepeatGetsTheSameReceipt() async throws {
        try await openFolders()
        let job = try goldenJob()
        await transport.commit(job)
        let intake = makeIntake()
        try await intake.sweep()
        try await intake.sweep()
        XCTAssertEqual(raisedFiles, ["office-job-7.ogjob"])
        XCTAssertEqual(signs, 1)
        let firstReceipts = await transport.receipts
        let first = try XCTUnwrap(firstReceipts[job.messageID])

        // The receipt never reached the folder, so the transport lists the job again.
        await transport.loseReceipt(messageID: job.messageID)
        try await intake.sweep()
        let againReceipts = await transport.receipts
        XCTAssertEqual(againReceipts[job.messageID], first, "the same receipt, byte for byte")
        XCTAssertEqual(signs, 1, "nothing is signed twice")
        XCTAssertEqual(raisedFiles.count, 1, "and the technician is not asked twice")
        XCTAssertEqual(refusalChecks, 1)
        let publishes = await transport.publishes
        XCTAssertEqual(publishes, 2)
    }

    func testAReviewNeverAnsweredIsRaisedAgainAfterARelaunchWithoutANewReceipt() async throws {
        try await openFolders()
        await transport.commit(try goldenJob())
        try await makeIntake().sweep()
        XCTAssertEqual(raisedFiles.count, 1)

        // The app closed with the review still open: a new intake over the same record.
        let relaunched = makeIntake()
        XCTAssertEqual(relaunched.state, .jobReceived(1))
        try await relaunched.sweep()
        try await relaunched.sweep()
        XCTAssertEqual(raisedFiles.count, 2, "raised once more, from the committed bytes")
        XCTAssertEqual(signs, 1)
        let publishes = await transport.publishes
        XCTAssertEqual(publishes, 1)

        relaunched.reviewEnded(jobSHA256: try goldenJob().jobSHA256)
        XCTAssertEqual(relaunched.state, .waitingForOffice)
        try await makeIntake().sweep()
        XCTAssertEqual(raisedFiles.count, 2, "an answered review stays answered")
    }

    /// A job the technician closes without adding is put aside: it is not raised again unasked,
    /// it is said to be there, and the technician can have its review again.
    func testAJobPutAsideIsNotRaisedAgainUnaskedAndCanBeReviewedAgain() async throws {
        try await openFolders()
        await transport.commit(try goldenJob())
        let intake = makeIntake()
        try await intake.sweep()
        XCTAssertEqual(raisedFiles.count, 1)
        let digest = try goldenJob().jobSHA256

        // Closed without adding.
        intake.reviewEnded(jobSHA256: digest, added: false)
        XCTAssertEqual(intake.state, .jobPutAside(1))
        let status = try XCTUnwrap(Intake.status(intake.state))
        XCTAssertEqual(status.title, "A job from the office was put aside")
        XCTAssertEqual(status.detail, "It hasn't been added to your jobs. You can review it again.")

        // No pass brings it back, now or after a relaunch.
        try await intake.sweep()
        let relaunched = makeIntake()
        XCTAssertEqual(relaunched.state, .jobPutAside(1))
        try await relaunched.sweep()
        XCTAssertEqual(raisedFiles.count, 1)

        // The technician asks: the same file is raised, from the bytes the office sent, with no
        // second receipt.
        let outcome = try await relaunched.reviewPutAside()
        XCTAssertEqual(outcome, .raised)
        XCTAssertEqual(raisedFiles.count, 2)
        XCTAssertEqual(raisedFiles.last, raisedFiles.first)
        XCTAssertEqual(relaunched.state, .jobReceived(1))
        XCTAssertEqual(signs, 1)
        let publishes = await transport.publishes
        XCTAssertEqual(publishes, 1)

        // Put aside again, asked for again while the review is showing something else: it waits.
        relaunched.reviewEnded(jobSHA256: digest, added: false)
        reviewBusy = true
        let busy = try await relaunched.reviewPutAside()
        XCTAssertEqual(busy, .busy)
        XCTAssertEqual(relaunched.state, .jobPutAside(1))
        reviewBusy = false

        // Added this time: answered, and nothing is left to review.
        _ = try await relaunched.reviewPutAside()
        relaunched.reviewEnded(jobSHA256: digest, added: true)
        XCTAssertEqual(relaunched.state, .waitingForOffice)
        let nothing = try await relaunched.reviewPutAside()
        XCTAssertNil(nothing)
        XCTAssertEqual(raisedFiles.count, 3)
    }

    /// The review's own stage says which it was: added is an answer, closed is put aside.
    func testClosingAReviewPutsTheJobAsideAndAddingItAnswers() async throws {
        try await openFolders()
        await transport.commit(try goldenJob())
        let digest = try goldenJob().jobSHA256
        for (stage, expected) in [(JobFileService.Stage.idle, Intake.State.jobPutAside(1)),
                                  (.added("Job FX-2031"), .waitingForOffice),
                                  (.alreadyHeld("Job FX-2031"), .waitingForOffice)] {
            saved = Intake.Ledger()
            let intake = makeIntake()
            try await intake.sweep()
            intake.reviewShowing = digest
            intake.reviewStageChanged(stage)
            XCTAssertEqual(intake.state, expected, "\(stage)")
        }
    }

    func testEveryJobIsReceiptedButReviewsAreRaisedOneAtATimeLowestSequenceFirst() async throws {
        try await openFolders()
        let later = try job(sequence: 9)
        let earlier = try job(sequence: 8)
        await transport.commit(later)
        await transport.commit(earlier)
        let intake = makeIntake()
        try await intake.sweep()
        let receipts = await transport.receipts
        XCTAssertEqual(Set(receipts.keys), [earlier.messageID, later.messageID],
                       "a receipt does not wait for the technician")
        XCTAssertEqual(raisedFiles, ["office-job-8.ogjob"])
        XCTAssertEqual(intake.state, .jobReceived(2))
        try await intake.sweep()
        XCTAssertEqual(raisedFiles.count, 1, "nothing is raised over a review that is still open")

        intake.reviewEnded(jobSHA256: earlier.jobSHA256)
        try await intake.sweep()
        XCTAssertEqual(raisedFiles, ["office-job-8.ogjob", "office-job-9.ogjob"])
        XCTAssertEqual(intake.state, .jobReceived(1))
    }

    func testABusyReviewDelaysTheReviewNotTheReceipt() async throws {
        try await openFolders()
        let job = try goldenJob()
        await transport.commit(job)
        reviewBusy = true
        let intake = makeIntake()
        try await intake.sweep()
        let receipts = await transport.receipts
        XCTAssertNotNil(receipts[job.messageID])
        XCTAssertEqual(raisedFiles, [])
        XCTAssertEqual(intake.state, .jobReceived(1))
        reviewBusy = false
        try await intake.sweep()
        XCTAssertEqual(raisedFiles, ["office-job-7.ogjob"])
    }

    // MARK: - Refused

    func testAJobFileTheImportRefusesIsRecordedWithABoundedReasonAndGetsNoReceipt() async throws {
        try await openFolders()
        let job = try job(sequence: 8, file: Data("not a job file".utf8))
        await transport.commit(job)
        let long = String(repeating: "This job file could not be read. ", count: 40)
        let intake = makeIntake(refuse: { _ in long })
        try await intake.sweep()
        try await intake.sweep()

        let receipts = await transport.receipts
        XCTAssertTrue(receipts.isEmpty, "a refused job gets no receipt")
        XCTAssertEqual(signs, 0)
        XCTAssertEqual(raisedFiles, [])
        XCTAssertEqual(refusalChecks, 1, "recorded once, not asked again while its bytes are the same")
        let entry = try XCTUnwrap(saved.entries.first)
        XCTAssertEqual(entry.state, .refused)
        XCTAssertEqual(entry.reason?.count, Intake.maximumReasonCharacters)
        XCTAssertEqual(intake.state, .jobRefused(String(long.prefix(Intake.maximumReasonCharacters))))
    }

    /// An office issues a job again under a new message after a binding renewal: the same office
    /// job at the same revision. It is on this phone, so it is receipted; it is one job, so the
    /// technician is not asked again and nothing is added twice.
    func testTheSameJobUnderASecondMessageIsReceiptedAndIsOneJob() async throws {
        try await openFolders()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeManagedJobIntakeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UpcomingJobStore(directory: directory)
        let jobFiles = JobFileService(seams: .init(store: { store }))
        var seams = Intake.Seams.app(transport: transport, jobFiles: jobFiles, ledgerFile: nil)
        seams.sign = { [unowned self] in try await self.sign($0) }
        let intake = Intake(seams: seams)

        let file = try fixture("job-file-v2", extension: "ogjob")
        await transport.commit(try job(sequence: 8, file: file))
        try await intake.sweep()
        guard case .review = jobFiles.stage else { return XCTFail("\(jobFiles.stage)") }
        intake.reviewStageChanged(jobFiles.stage)
        XCTAssertNotNil(jobFiles.accept(.add))
        intake.reviewStageChanged(jobFiles.stage)
        jobFiles.dismiss()
        intake.reviewStageChanged(jobFiles.stage)
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs.first?.provenance?.jobID, "job-2031")

        // The same file again, under another message and sequence.
        await transport.commit(try job(sequence: 9, file: file))
        try await intake.sweep()
        XCTAssertEqual(jobFiles.stage, .idle, "no second review")
        XCTAssertEqual(store.jobs.count, 1, "and no second job")
        let receipts = await transport.receipts
        XCTAssertEqual(receipts.count, 2, "each message is receipted")
        XCTAssertEqual(intake.ledger.entries.map(\.state), [.reviewed, .reviewed])
        XCTAssertEqual(intake.state, .waitingForOffice)
    }

    func testTheRealImportRefusesWhatIsNotAJobFile() async throws {
        try await openFolders()
        await transport.commit(try job(sequence: 8, file: Data("not a job file".utf8)))
        let jobFiles = JobFileService()
        var seams = Intake.Seams.app(transport: transport, jobFiles: jobFiles, ledgerFile: nil)
        seams.sign = { [unowned self] in try await self.sign($0) }
        let intake = Intake(seams: seams)
        try await intake.sweep()
        XCTAssertEqual(jobFiles.stage, .idle, "nothing is raised for a file the import refuses")
        let receipts = await transport.receipts
        XCTAssertTrue(receipts.isEmpty)
        guard case .jobRefused(let reason) = intake.state else { return XCTFail("\(intake.state)") }
        XCTAssertFalse(reason.isEmpty)
    }

    func testBytesOrAReceiptThatAreNotThisJobsAreRefused() async throws {
        try await openFolders()
        // The receipt offered names another job file.
        let honest = try job(sequence: 8)
        await transport.commit(Transport.Job(messageID: honest.messageID, sequence: 8,
                                             file: Data("{}".utf8), receiptPayload: honest.receiptPayload))
        // The receipt offered is not a receipt at all.
        await transport.commit(Transport.Job(messageID: String(format: "%032x", 9), sequence: 9,
                                             file: honest.file, receiptPayload: Data(#"{"kind":"other"}"#.utf8)))
        let intake = makeIntake()
        try await intake.sweep()
        XCTAssertEqual(saved.entries.map(\.state), [.refused, .refused])
        XCTAssertEqual(signs, 0)
        XCTAssertEqual(refusalChecks, 0, "neither reached the import")
        let receipts = await transport.receipts
        XCTAssertTrue(receipts.isEmpty)
    }

    // MARK: - Failures leave nothing half done

    func testAReceiptThatCannotBeSignedIsTriedAgainWithoutASecondReview() async throws {
        try await openFolders()
        let job = try goldenJob()
        await transport.commit(job)
        signFailure = Failed()
        let intake = makeIntake()
        do {
            try await intake.sweep()
            XCTFail("the failure is reported")
        } catch {
            XCTAssertEqual(error as? Failed, Failed())
        }
        var receipts = await transport.receipts
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertEqual(raisedFiles.count, 1)

        signFailure = nil
        try await intake.sweep()
        receipts = await transport.receipts
        XCTAssertNotNil(receipts[job.messageID])
        XCTAssertEqual(raisedFiles.count, 1)
    }

    func testNoReceiptWithoutARecordOfTheOffer() async throws {
        try await openFolders()
        await transport.commit(try goldenJob())
        saveFailure = Failed()
        let intake = makeIntake()
        do {
            try await intake.sweep()
            XCTFail("the failure is reported")
        } catch {
            XCTAssertEqual(error as? Failed, Failed())
        }
        let receipts = await transport.receipts
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertEqual(signs, 0)
        XCTAssertEqual(raisedFiles, [])
        XCTAssertEqual(intake.state, .waitingForOffice)
    }

    func testClosedFoldersGiveNothing() async throws {
        await transport.commit(try goldenJob())
        let intake = makeIntake()
        try await intake.sweep()
        XCTAssertEqual(saved.entries, [])
        XCTAssertEqual(intake.state, .waitingForOffice)
    }

    // MARK: - The record and the words

    func testTheRecordSurvivesAFileRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-managed-jobs-\(UUID().uuidString)/managed-jobs.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(Intake.readLedger(file), Intake.Ledger())
        let ledger = Intake.Ledger(entries: [.init(
            receiptID: "r", messageID: "m", sequence: 7, jobSHA256: "j", state: .awaitingReview,
            reason: nil, signature: "s", receiptPublished: true)])
        try Intake.writeLedger(ledger, to: file)
        XCTAssertEqual(Intake.readLedger(file), ledger)
        try Data("damaged".utf8).write(to: file)
        XCTAssertEqual(Intake.readLedger(file), Intake.Ledger())
    }

    func testNothingSaysSentOrDelivered() {
        XCTAssertNil(Intake.status(.waitingForOffice), "the connection's own line says waiting")
        XCTAssertEqual(Intake.status(.jobReceived(1))?.title, "Job received")
        XCTAssertEqual(Intake.status(.jobReceived(3))?.detail, "3 jobs from the office are ready for your review.")
        XCTAssertEqual(Intake.status(.jobRefused("Why."))?.detail, "Why.")
        let connection = OfficeFieldConnectionPolicy.self
        let all = [Intake.status(.jobReceived(1)), Intake.status(.jobReceived(2)), Intake.status(.jobRefused("")),
                   connection.status(.waiting(.automatic)), connection.status(.connected(.direct))]
        for status in all.compactMap({ $0 }) {
            let words = (status.title + " " + (status.detail ?? "")).lowercased()
            XCTAssertFalse(words.contains("sent"), words)
            XCTAssertFalse(words.contains("delivered"), words)
            XCTAssertFalse(words.contains("accepted"), words)
        }
        XCTAssertEqual(connection.status(.waiting(.automatic))?.title, "Waiting for the office")
    }
}
