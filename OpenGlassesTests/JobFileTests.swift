import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan FO P3c, §8 — a job that arrives as a file: the validator, the organisation's signature,
/// who may add an unsigned one, the review, and the one write. Pure over fixture bytes and an
/// ephemeral key pair; nothing here opens Mail or a network.
@MainActor
final class JobFileTests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private var privateKey: String { key.rawRepresentation.base64EncodedString() }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func document(_ overrides: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var doc: [String: Any] = [
            "format": "openglasses.job",
            "format_version": 1,
            "job_reference": "1007",
            "site": ["customer": "Smith & Co", "address": "14 Smith Street", "contact": "Jo, 021 555 0100"],
            "fault_report": "No heat.\nDisplay shows E200.",
            "equipment": [["model": "SLP99UH090XV60CK", "serial": "5919K01234"]],
            "scheduled_for": "2026-09-25T09:00:00Z",
            "notes": "Side gate code 4411.",
            "attachments": [["name": "Previous invoice", "reference": "INV-2231"]],
            "issued_by": "Smith Refrigeration Ltd",
        ]
        for (key, value) in overrides { doc[key] = value }
        for key in removing { doc.removeValue(forKey: key) }
        return doc
    }

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// A document signed over its own canonical body, the way `Scripts/make-job-file.swift` does.
    private func signed(_ object: [String: Any], with signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let file = try XCTUnwrap(try? JobFileValidator.validate(data(object)).get())
        let signature = try JobFileSignatureCheck.sign(
            file.body, privateKeyBase64: (signer ?? key).rawRepresentation.base64EncodedString())
        var withSignature = object
        withSignature["signature"] = ["algorithm": signature.algorithm, "value": signature.value]
        return data(withSignature)
    }

    private func validate(_ object: [String: Any]) -> Result<JobFile, JobFileValidator.Refusal> {
        JobFileValidator.validate(data(object))
    }

    private func refusal(_ object: [String: Any]) -> JobFileValidator.Refusal? {
        if case .failure(let refusal) = validate(object) { return refusal }
        return nil
    }

    // MARK: - Validation

    func testAValidFileParsesWithEveryFieldAsGiven() throws {
        let file = try validate(document()).get()
        XCTAssertEqual(file.body.jobReference, "1007")
        XCTAssertEqual(file.body.faultReport, "No heat.\nDisplay shows E200.")
        XCTAssertNil(file.signature)
        let job = file.upcomingJob(provenance: JobFileProvenance(fileName: "1007.ogjob", signature: .unsigned,
                                                                 signer: nil, receivedAt: now, digest: "x"),
                                   createdAt: now)
        XCTAssertEqual(job.site.address, "14 Smith Street")
        XCTAssertEqual(job.faultReport?.source, .jobFile)
        XCTAssertEqual(job.equipment, [KnownEquipment(model: "SLP99UH090XV60CK", serial: "5919K01234")])
        XCTAssertEqual(job.attachments, ["Previous invoice (INV-2231)"])
        XCTAssertNotNil(job.scheduledFor)
    }

    func testFieldsTheOfficeLeftOutStayEmpty() throws {
        let file = try validate(["format": "openglasses.job", "format_version": 1, "job_reference": "1008"]).get()
        let job = file.upcomingJob(provenance: JobFileProvenance(fileName: "f", signature: .unsigned, signer: nil,
                                                                 digest: "x"))
        XCTAssertTrue(job.site.isEmpty)
        XCTAssertNil(job.faultReport)
        XCTAssertTrue(job.equipment.isEmpty)
        XCTAssertNil(job.scheduledFor)
    }

    func testAnOversizedFileIsRefusedBeforeItIsParsed() {
        let padding = String(repeating: "x", count: JobFile.maximumBytes + 1)
        XCTAssertEqual(JobFileValidator.validate(Data(padding.utf8)), .failure(.tooLarge(JobFile.maximumBytes + 1)))
    }

    func testNotAJobFile() {
        XCTAssertEqual(JobFileValidator.validate(Data("hello".utf8)), .failure(.notAJobFile))
        XCTAssertEqual(refusal(document(["format": "something.else"])), .notAJobFile)
        XCTAssertEqual(refusal(document(removing: ["format_version"])), .notAJobFile)
        XCTAssertEqual(refusal(document(["format_version": 2])), .unsupportedVersion(2))
    }

    func testAFieldThisVersionDoesNotKnowIsRefused() {
        XCTAssertEqual(refusal(document(["start_job": true])), .unexpectedField("start_job"))
        XCTAssertEqual(refusal(document(["site": ["address": "x", "gps": "1,2"]])), .unexpectedField("gps"))
        XCTAssertEqual(refusal(document(["equipment": [["model": "A", "tasks": "replace"]]])),
                       .unexpectedField("tasks"))
    }

    func testHTMLBearingFilesAreRefused() {
        XCTAssertEqual(refusal(document(["notes": "<b>urgent</b>"])), .containsMarkup("notes"))
        XCTAssertEqual(refusal(document(["fault_report": "see <a href=x>here</a>"])), .containsMarkup("fault_report"))
        XCTAssertEqual(refusal(document(["site": ["customer": "Smith &amp; Co"]])), .containsMarkup("customer"))
        XCTAssertEqual(refusal(document(["notes": "<!-- hidden -->"])), .containsMarkup("notes"))
        // A bare "<" is arithmetic, not markup.
        XCTAssertNoThrow(try validate(document(["fault_report": "suction < 20 psi & falling"])).get())
    }

    func testTextOnlyAndLengthCapped() {
        XCTAssertEqual(refusal(document(["job_reference": 1007])), .wrongType("job_reference"))
        XCTAssertEqual(refusal(document(["job_reference": String(repeating: "9", count: 65)])),
                       .tooLong("job_reference"))
        XCTAssertEqual(refusal(document(["job_reference": "10\n07"])), .notPlainText("job_reference"))
        XCTAssertEqual(refusal(document(["site": "14 Smith St"])), .wrongType("site"))
        XCTAssertEqual(refusal(document(["equipment": Array(repeating: ["model": "A"], count: 11)])),
                       .tooMany("machines"))
    }

    func testAttachmentsAreNamedNeverEmbedded() {
        XCTAssertEqual(refusal(document(["attachments": [["name": "Manual", "reference": "data:application/pdf;base64,AAAA"]]])),
                       .embeddedAttachment)
    }

    func testABadBookingTimeIsRefused() {
        XCTAssertEqual(refusal(document(["scheduled_for": "next Tuesday"])), .badDate)
        XCTAssertNoThrow(try validate(document(["scheduled_for": "2026-09-25T09:00:00.500Z"])).get())
    }

    func testAFileWithNothingToProposeIsRefused() {
        XCTAssertEqual(refusal(["format": "openglasses.job", "format_version": 1, "notes": "hi"]), .empty)
    }

    func testAMalformedSignatureIsRefused() {
        XCTAssertEqual(refusal(document(["signature": ["algorithm": "rsa", "value": "x"]])), .malformedSignature)
        XCTAssertEqual(refusal(document(["signature": "abc"])), .malformedSignature)
    }

    // MARK: - The organisation's signature

    func testSignedWithTheOrganisationsKey() throws {
        let file = try JobFileValidator.validate(signed(document())).get()
        XCTAssertEqual(JobFileSignatureCheck.check(file, organisationKey: publicKey, organisationName: "Smith Refrigeration"),
                       .signed(organisation: "Smith Refrigeration"))
    }

    func testTheSignatureSurvivesAReLayoutOfTheJSON() throws {
        // Signed over the canonical body, so the office's mail system can re-indent it.
        let raw = try signed(document())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let compact = try JSONSerialization.data(withJSONObject: object, options: [])
        let file = try JobFileValidator.validate(compact).get()
        XCTAssertEqual(JobFileSignatureCheck.check(file, organisationKey: publicKey, organisationName: "X"),
                       .signed(organisation: "X"))
    }

    func testUnsigned() throws {
        let file = try validate(document()).get()
        XCTAssertEqual(JobFileSignatureCheck.check(file, organisationKey: publicKey, organisationName: "X"), .unsigned)
    }

    func testSignedButNoOrganisationKeyOnThisPhone() throws {
        let file = try JobFileValidator.validate(signed(document())).get()
        XCTAssertEqual(JobFileSignatureCheck.check(file, organisationKey: "", organisationName: "X"), .unverifiable)
    }

    func testAlteredAfterSigningIsInvalid() throws {
        let raw = try signed(document())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object["job_reference"] = "1008"
        let file = try validate(object).get()
        XCTAssertEqual(JobFileSignatureCheck.check(file, organisationKey: publicKey, organisationName: "X"), .invalid)
    }

    func testSignedBySomebodyElseIsInvalid() throws {
        let stranger = Curve25519.Signing.PrivateKey()
        let file = try JobFileValidator.validate(signed(document(), with: stranger)).get()
        XCTAssertEqual(JobFileSignatureCheck.check(file, organisationKey: publicKey, organisationName: "X"), .invalid)
    }

    // MARK: - Policy

    func testMedicalModeRefusesAnUnsignedFile() {
        let policy = JobFileImportPolicy.resolve(medicalMode: true, organisationRequiresSigned: false)
        guard case .refuse(let message) = policy.decide(.unsigned) else { return XCTFail("medical mode must refuse") }
        XCTAssertTrue(message.hasPrefix("Medical mode"))
        guard case .refuse = policy.decide(.unverifiable) else { return XCTFail("an unverifiable signature is unsigned") }
        XCTAssertEqual(policy.decide(.signed(organisation: "X")), .offer(.signed, signer: "X"))
    }

    func testAnOrganisationCanRequireSigning() {
        let policy = JobFileImportPolicy.resolve(medicalMode: false, organisationRequiresSigned: true)
        guard case .refuse = policy.decide(.unsigned) else { return XCTFail() }
    }

    func testByDefaultAnUnsignedFileIsOfferedAndLabelled() {
        let policy = JobFileImportPolicy.resolve(medicalMode: false, organisationRequiresSigned: false)
        XCTAssertEqual(policy.decide(.unsigned), .offer(.unsigned, signer: nil))
        XCTAssertEqual(policy.decide(.unverifiable), .offer(.unverifiable, signer: nil))
    }

    func testABadSignatureIsNeverOverridable() {
        for policy in [JobFileImportPolicy(unsigned: .allowed), JobFileImportPolicy(unsigned: .forbiddenByMedicalMode)] {
            guard case .refuse = policy.decide(.invalid) else { return XCTFail("a tamper must be refused") }
        }
    }

    // MARK: - The review, and the one write

    private func service(store: UpcomingJobStore, key: String = "", medical: Bool = false,
                         fieldAssist: Bool = true) -> JobFileService {
        JobFileService(seams: .init(
            store: { store },
            policy: { JobFileImportPolicy.resolve(medicalMode: medical, organisationRequiresSigned: false) },
            organisationKey: { key },
            organisationName: { "Smith Refrigeration" },
            now: { [now = self.now] in now },
            fieldAssistActive: { fieldAssist }))
    }

    func testOpeningAFileCreatesNothingUntilTheTap() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        files.handle(data: data(document()), fileName: "1007.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail("expected a review") }
        XCTAssertTrue(store.jobs.isEmpty, "a review is not a write")
        XCTAssertEqual(review.signatureLine, "Not signed — check it came from your office before adding it.")
        XCTAssertEqual(review.claimedIssuer, "Smith Refrigeration Ltd", "an unsigned claim is shown as a claim")

        let added = try XCTUnwrap(files.accept(.add))
        XCTAssertEqual(store.jobs.map(\.id), [added.id])
        XCTAssertEqual(added.provenance?.fileName, "1007.ogjob")
        XCTAssertEqual(added.provenance?.digest, JobFile.digest(data(document())))
        XCTAssertEqual(files.stage, .added("Job 1007"))
    }

    func testASignedFileShowsItsSigner() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store, key: publicKey)
        files.handle(data: try signed(document()), fileName: "1007.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail() }
        XCTAssertTrue(review.isSigned)
        XCTAssertEqual(review.signatureLine, "Signed by Smith Refrigeration.")
    }

    func testTheHIPAARefusalWritesNothing() {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store, medical: true)
        files.handle(data: data(document()), fileName: "1007.ogjob")
        guard case .refused = files.stage else { return XCTFail("medical mode must refuse an unsigned file") }
        XCTAssertNil(files.accept(.add))
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testFieldAssistOffRefusesBeforeReadingAnything() {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store, fieldAssist: false)
        files.handle(data: data(document()), fileName: "1007.ogjob")
        XCTAssertEqual(files.stage, .refused(JobFileService.fieldAssistOffMessage))
    }

    func testADuplicateReferenceIsAQuestionNeverASilentOverwrite() throws {
        let store = UpcomingJobStore(directory: directory)
        let original = UpcomingJob(id: "orig", jobReference: "1007", site: JobSite(address: "Old address"),
                                   origin: .typed, createdAt: now.addingTimeInterval(-600))
        store.add(original)
        let files = service(store: store)
        files.handle(data: data(document()), fileName: "1007.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail() }
        XCTAssertEqual(review.duplicate?.id, "orig")
        XCTAssertEqual(review.duplicateQuestion, "Job 1007 is already on this phone. Update it with this file, or keep both?")
        XCTAssertEqual(store.job(id: "orig")?.site.address, "Old address", "asking changes nothing")

        let updated = try XCTUnwrap(files.accept(.update))
        XCTAssertEqual(updated.id, "orig", "update keeps the job's identity")
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.job(id: "orig")?.site.address, "14 Smith Street")
        XCTAssertEqual(store.job(id: "orig")?.createdAt, original.createdAt)
    }

    func testKeepBothAddsASecond() throws {
        let store = UpcomingJobStore(directory: directory)
        store.add(UpcomingJob(id: "orig", jobReference: "1007", origin: .typed, createdAt: now))
        let files = service(store: store)
        files.handle(data: data(document()), fileName: "1007.ogjob")
        XCTAssertNotNil(files.accept(.keepBoth))
        XCTAssertEqual(store.jobs(reference: "1007").count, 2)
    }

    func testAJobFileNeverCreatesTasksNorStartsAJob() throws {
        // The job ahead a file proposes has nowhere to put a task and no session: a job file can
        // only ever become an upcoming job. `startUpcomingJob` is the technician's, on site.
        let file = try validate(document()).get()
        let job = file.upcomingJob(provenance: JobFileProvenance(fileName: "f", signature: .unsigned,
                                                                 signer: nil, digest: "x"))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any]
        XCTAssertNil(encoded?["tasks"])
        XCTAssertNil(encoded?["session_id"])
        XCTAssertEqual(job.origin, .jobFile)
    }

    func testOnlyFilesAreJobFiles() {
        XCTAssertTrue(JobFileService.isJobFile(URL(fileURLWithPath: "/tmp/Inbox/1007.ogjob")))
        XCTAssertTrue(JobFileService.isJobFile(URL(fileURLWithPath: "/tmp/Inbox/1007.OGJOB")))
        XCTAssertFalse(JobFileService.isJobFile(URL(string: "openglasses://job?reference=1007")!),
                       "there is deliberately no link form")
        XCTAssertFalse(JobFileService.isJobFile(URL(fileURLWithPath: "/tmp/1007.json")))
    }
}
