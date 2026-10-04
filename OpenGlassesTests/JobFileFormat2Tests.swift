import CryptoKit
import XCTest
@testable import OpenGlasses

/// Job-file format 2 on the phone (Contracts/job-file.md): the office's identifier and revision,
/// a signature over the job's exact bytes, and what a second file for a job the phone holds is.
/// Against the Go golden fixture and files signed here with an ephemeral key.
@MainActor
final class JobFileFormat2Tests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private var privateKey: String { key.rawRepresentation.base64EncodedString() }
    private var started: [JobFileProvenance] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobFileFormat2Tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The fictional organisation key the golden file is signed with: seed = SHA-256 of a public
    /// label. It has no authority.
    private var fixtureKey: Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture organisation job key v1".utf8)))
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    private func golden() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "job-file-v2", withExtension: "ogjob")))
    }

    private func job(_ id: String = "job-1", revision: Int = 1, notes: String = "Gate code 4411.",
                     reference: String = "1007") -> Data {
        Data(#"{"job_id":"\#(id)","revision":\#(revision),"job_reference":"\#(reference)","site":{"customer":"Smith & Co"},"notes":"\#(notes)"}"#.utf8)
    }

    private func file(_ job: Data, signed: Bool = true,
                      with signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        try JobFileSignatureCheck.format2File(
            job: job, privateKeyBase64: signed ? (signer ?? key).rawRepresentation.base64EncodedString() : nil)
    }

    private func file(jobJSON: String) throws -> Data { try file(Data(jobJSON.utf8), signed: false) }

    private func refusal(_ data: Data) -> JobFileValidator.Refusal? {
        if case .failure(let refusal) = JobFileValidator.validate(data) { return refusal }
        return nil
    }

    private func service(store: UpcomingJobStore, key: String? = nil,
                         requireSigned: Bool = false) -> JobFileService {
        JobFileService(seams: .init(
            store: { store },
            policy: { JobFileImportPolicy.resolve(medicalMode: false, organisationRequiresSigned: requireSigned) },
            organisationKey: { [publicKey] in key ?? publicKey },
            organisationName: { "Smith Refrigeration" },
            now: { [now] in now },
            fieldAssistActive: { true },
            startedJobFiles: { [unowned self] in self.started }))
    }

    /// Open a file and accept whatever the review offers.
    @discardableResult
    private func add(_ data: Data, to files: JobFileService, line: UInt = #line) throws -> UpcomingJob {
        files.handle(data: data, fileName: "job.ogjob")
        guard case .review = files.stage else {
            XCTFail("expected a review, got \(files.stage)", line: line)
            throw CancellationError()
        }
        let written = try XCTUnwrap(files.accept(.add), line: line)
        files.dismiss()
        return written
    }

    // MARK: - The golden fixture: imports, reviews and round-trips

    func testTheGoldenFixtureImportsReviewsAndRoundTrips() throws {
        let data = try golden()
        let parsed = try JobFileValidator.validate(data).get()
        XCTAssertEqual(parsed.identity?.jobID, "job-2031")
        XCTAssertEqual(parsed.identity?.revision, 2)
        XCTAssertEqual(parsed.identity?.sha256, JobFile.digest(try XCTUnwrap(parsed.jobBytes)))
        XCTAssertEqual(parsed.body.jobReference, "FX-1007")
        XCTAssertEqual(parsed.body.site?.address, "14 Fixture Street")
        XCTAssertEqual(parsed.body.equipment?.first?.model, "FX-90")
        XCTAssertEqual(JobFileSignatureCheck.check(
            parsed, organisationKey: fixtureKey.publicKey.rawRepresentation.base64EncodedString(),
            organisationName: "Fixture Service Ltd"), .signed(organisation: "Fixture Service Ltd"))

        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store, key: fixtureKey.publicKey.rawRepresentation.base64EncodedString())
        files.handle(data: data, fileName: "FX-1007.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail("\(files.stage)") }
        XCTAssertTrue(review.isSigned)
        XCTAssertTrue(store.jobs.isEmpty, "a review is not a write")
        XCTAssertEqual(review.lines.first { $0.label == "Revision" }?.value, "2")
        XCTAssertNil(review.lines.first { $0.value.contains("job-2031") },
                     "the office's identifier is not shown as the job number")
        XCTAssertNil(review.revises)
        let added = try XCTUnwrap(files.accept(.add))
        XCTAssertEqual(added.jobReference, "FX-1007")

        // The identifier and revision are kept on the job ahead, across a relaunch…
        let reloaded = try XCTUnwrap(UpcomingJobStore(directory: directory).jobs.first)
        XCTAssertEqual(reloaded.provenance?.identity, parsed.identity)
        XCTAssertEqual(reloaded.provenance?.digest, JobFile.digest(data))
        // …and in the form the visit's record carries.
        let encoded = try JSONEncoder().encode(XCTUnwrap(reloaded.provenance))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(record["job_id"] as? String, "job-2031")
        XCTAssertEqual(record["revision"] as? Int, 2)
        XCTAssertEqual(record["job_sha256"] as? String, parsed.identity?.sha256)
        XCTAssertTrue(try XCTUnwrap(reloaded.provenance).recordLine.contains("(revision 2)"))
    }

    func testAFormatOneFileStillImportsAndHasNoIdentity() throws {
        let v1 = Data(#"{"format":"openglasses.job","format_version":1,"job_reference":"1007","site":{"customer":"Smith & Co"}}"#.utf8)
        let parsed = try JobFileValidator.validate(v1).get()
        XCTAssertNil(parsed.identity)
        XCTAssertNil(parsed.jobBytes)
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        let added = try add(v1, to: files)
        XCTAssertNil(added.provenance?.identity)
        XCTAssertFalse(try XCTUnwrap(added.provenance).recordLine.contains("revision"))
        // A record written before the identity existed still reads.
        let old = Data(#"{"file_name":"1007.ogjob","signature":"unsigned","received_at":0,"digest":"abc"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(JobFileProvenance.self, from: old).identity)
        // A format-1 file is never upgraded: opened again it is the job-number question it always was.
        files.handle(data: v1, fileName: "1007.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail() }
        XCTAssertNotNil(review.duplicateQuestion)
        XCTAssertNil(review.revises)
    }

    // MARK: - The signature

    func testTheSignatureIsOverTheDomainAndTheExactJobBytes() throws {
        func outcome(_ data: Data, key: String? = nil) throws -> JobFileSignatureCheck.Outcome {
            JobFileSignatureCheck.check(try JobFileValidator.validate(data).get(),
                                        organisationKey: key ?? publicKey, organisationName: "Smith Refrigeration")
        }
        let bytes = job()
        XCTAssertEqual(try outcome(file(bytes)), .signed(organisation: "Smith Refrigeration"))
        XCTAssertEqual(try outcome(file(bytes, signed: false)), .unsigned)
        XCTAssertEqual(try outcome(file(bytes), key: ""), .unverifiable)
        XCTAssertEqual(try outcome(file(bytes, with: Curve25519.Signing.PrivateKey())), .invalid)

        func wrapped(_ job: Data, signatureOver message: Data) throws -> Data {
            let value = try key.signature(for: message).base64EncodedString()
            return Data(#"{"format":"openglasses.job","format_version":2,"job":"\#(job.base64EncodedString())","signature":{"algorithm":"ed25519","value":"\#(value)"}}"#.utf8)
        }
        // No domain; a format-1 signature over the canonical fields; another message's domain.
        XCTAssertEqual(try outcome(wrapped(bytes, signatureOver: bytes)), .invalid)
        let canonical = try JobFileValidator.validate(file(bytes)).get().body.canonicalData()
        XCTAssertEqual(try outcome(wrapped(bytes, signatureOver: canonical)), .invalid)
        XCTAssertEqual(try outcome(wrapped(bytes, signatureOver: Data("Avenkin.ManagedJob.v1\0".utf8) + bytes)), .invalid)
        // The same job laid out another way is other bytes: the signature does not carry over.
        let spaced = Data(String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: #"{"job_id""#, with: #"{ "job_id""#).utf8)
        XCTAssertEqual(try outcome(wrapped(spaced, signatureOver: JobFile.signatureDomainV2 + bytes)), .invalid)
        XCTAssertEqual(try outcome(wrapped(spaced, signatureOver: JobFile.signatureDomainV2 + spaced)),
                       .signed(organisation: "Smith Refrigeration"))
    }

    // MARK: - What is not a format-2 file

    func testOnlyAClosedFileWithAnIdentityOpens() throws {
        let good = String(decoding: try file(job()), as: UTF8.self)
        func changed(_ old: String, _ new: String) -> Data {
            XCTAssertTrue(good.contains(old))
            return Data(good.replacingOccurrences(of: old, with: new).utf8)
        }
        XCTAssertEqual(refusal(changed(#"{"format""#, #"{"note":"x","format""#)), .unexpectedField("note"))
        XCTAssertEqual(refusal(changed(#"{"format""#, #"{"format":"openglasses.job","format""#)), .notAJobFile)
        XCTAssertEqual(refusal(changed(#""format_version":2"#, #""format_version":2.0"#)), .notAJobFile)
        XCTAssertEqual(refusal(changed(#""format_version":2"#, #""format_version":3"#)), .unsupportedVersion(3))
        XCTAssertEqual(refusal(Data((good + "{}").utf8)), .notAJobFile)
        XCTAssertEqual(refusal(changed(#"{"algorithm":"ed25519","#, #"{"algorithm":"ed25519","algorithm":"ed25519","#)),
                       .notAJobFile)
        XCTAssertEqual(refusal(changed(#""algorithm":"ed25519""#, #""algorithm":"rsa""#)), .malformedSignature)
        XCTAssertEqual(refusal(Data(#"{"format":"openglasses.job","format_version":2,"job":"{}"}"#.utf8)), .notAJobFile)
        XCTAssertEqual(refusal(Data(#"{"format":"openglasses.job","format_version":2}"#.utf8)), .notAJobFile)

        let cases: [(String, String, JobFileValidator.Refusal)] = [
            ("a job that is not an object", "[]", .notAJobFile),
            ("no identifier", #"{"revision":1,"job_reference":"1007"}"#, .noIdentity),
            ("an identifier that is a path", #"{"job_id":"../1007","revision":1,"job_reference":"1007"}"#, .noIdentity),
            ("no revision", #"{"job_id":"job-1","job_reference":"1007"}"#, .noIdentity),
            ("revision zero", #"{"job_id":"job-1","revision":0,"job_reference":"1007"}"#, .noIdentity),
            ("a fractional revision", #"{"job_id":"job-1","revision":1.0,"job_reference":"1007"}"#, .noIdentity),
            ("an exponent", #"{"job_id":"job-1","revision":1e0,"job_reference":"1007"}"#, .noIdentity),
            ("a revision in text", #"{"job_id":"job-1","revision":"1","job_reference":"1007"}"#, .noIdentity),
            ("a revision with a leading zero", #"{"job_id":"job-1","revision":01,"job_reference":"1007"}"#, .notAJobFile),
            ("a field this version does not know", #"{"job_id":"job-1","revision":1,"start_job":true}"#,
             .unexpectedField("start_job")),
            ("format 1's own members inside the job", #"{"job_id":"job-1","revision":1,"format":"openglasses.job"}"#,
             .unexpectedField("format")),
            ("a member named twice", #"{"job_id":"job-1","job_id":"job-2","revision":1,"job_reference":"1007"}"#, .notAJobFile),
            ("a member named twice inside the site",
             #"{"job_id":"job-1","revision":1,"site":{"customer":"A","customer":"B"}}"#, .notAJobFile),
            ("a member named twice inside a machine",
             #"{"job_id":"job-1","revision":1,"equipment":[{"model":"A","model":"B"}]}"#, .notAJobFile),
            ("markup", #"{"job_id":"job-1","revision":1,"notes":"<b>urgent</b>"}"#, .containsMarkup("notes")),
            ("an embedded attachment",
             #"{"job_id":"job-1","revision":1,"job_reference":"1","attachments":[{"name":"x","reference":"data:text/plain,hi"}]}"#,
             .embeddedAttachment),
            ("nothing to propose", #"{"job_id":"job-1","revision":1}"#, .empty),
        ]
        for (name, jobJSON, expected) in cases {
            XCTAssertEqual(refusal(try file(jobJSON: jobJSON)), expected, name)
        }
    }

    // MARK: - One job, its revisions, and the same file twice

    func testAHigherRevisionIsARevisionOfThatJobNotASecondJob() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        let first = try add(file(job(revision: 1)), to: files)

        // The job number changed between revisions; the identifier did not.
        files.handle(data: try file(job(revision: 2, notes: "Gate code 9999.", reference: "1007A")),
                     fileName: "job.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail("\(files.stage)") }
        XCTAssertEqual(review.revises?.id, first.id)
        XCTAssertNil(review.duplicateQuestion, "a revision is not the job-number question")
        XCTAssertEqual(review.revisionNote,
                       "This is revision 2 of Job 1007, which is on this phone at revision 1. Updating replaces what's there with what this file says.")
        // Whatever is tapped, it replaces the job in place.
        let written = try XCTUnwrap(files.accept(.keepBoth))
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(written.id, first.id)
        XCTAssertEqual(store.jobs.first?.jobReference, "1007A")
        XCTAssertEqual(store.jobs.first?.notes, "Gate code 9999.")
        XCTAssertEqual(store.jobs.first?.provenance?.revision, 2)
    }

    func testTheSameIdentifierAndRevisionTwiceIsOneJob() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        let bytes = job(revision: 2)
        try add(file(bytes), to: files)

        // The same job, signed again: other file bytes, the same job bytes.
        let again = try file(bytes)
        XCTAssertTrue(files.isAlreadyHeld(again))
        XCTAssertNil(files.refusal(for: again), "it is not a refusal")
        files.handle(data: again, fileName: "job.ogjob")
        XCTAssertEqual(files.stage, .alreadyHeld("Job 1007"))
        XCTAssertNil(files.accept(.add))
        XCTAssertEqual(store.jobs.count, 1)

        // Other words at the same revision are a conflict, however small the difference.
        for other in [job(revision: 2, notes: "Gate code 9999."),
                      Data(String(decoding: bytes, as: UTF8.self)
                        .replacingOccurrences(of: #"{"job_id""#, with: #"{ "job_id""#).utf8)] {
            XCTAssertEqual(files.refusal(for: try file(other)), JobFileService.conflictingRevisionMessage)
            XCTAssertFalse(files.isAlreadyHeld(try file(other)))
        }
        XCTAssertEqual(store.jobs.count, 1)
    }

    func testAnOlderRevisionNeverReplacesANewerOne() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        try add(file(job(revision: 3)), to: files)
        let older = try file(job(revision: 2, notes: "An earlier note."))
        XCTAssertEqual(files.refusal(for: older), JobFileService.olderRevisionMessage)
        files.handle(data: older, fileName: "job.ogjob")
        XCTAssertEqual(files.stage, .refused(JobFileService.olderRevisionMessage))
        XCTAssertNil(files.accept(.update))
        XCTAssertEqual(store.jobs.first?.provenance?.revision, 3)
        XCTAssertEqual(store.jobs.first?.notes, "Gate code 4411.")
        // Another office job with the same number is not this job: it is the old question.
        files.handle(data: try file(job("job-2", revision: 1)), fileName: "job.ogjob")
        guard case .review(let review) = files.stage else { return XCTFail("\(files.stage)") }
        XCTAssertNil(review.revises)
        XCTAssertNotNil(review.duplicateQuestion)
    }

    func testAnUnsignedFileNeverRevisesAJobThatArrivedSigned() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        try add(file(job(revision: 1)), to: files)
        XCTAssertEqual(store.jobs.first?.provenance?.signature, .signed)
        let unsigned = try file(job(revision: 2, notes: "Send the report to this address."), signed: false)
        XCTAssertEqual(files.refusal(for: unsigned), JobFileService.unsignedRevisionMessage)
        // Nor does one signed with a key this phone cannot check.
        let unverifiable = service(store: store, key: "")
        XCTAssertEqual(unverifiable.refusal(for: try file(job(revision: 2))), JobFileService.unsignedRevisionMessage)
        XCTAssertEqual(store.jobs.first?.provenance?.revision, 1)

        // An unsigned job may be revised by an unsigned file, and by a signed one.
        let other = UpcomingJobStore(directory: directory.appendingPathComponent("other"))
        let plain = service(store: other)
        try add(file(job(revision: 1), signed: false), to: plain)
        plain.handle(data: try file(job(revision: 2), signed: false), fileName: "job.ogjob")
        guard case .review(let review) = plain.stage else { return XCTFail("\(plain.stage)") }
        XCTAssertNotNil(review.revises)
    }

    func testAJobAlreadyStartedIsNotOfferedAgainOrChangedByAFile() throws {
        let store = UpcomingJobStore(directory: directory)
        let files = service(store: store)
        let bytes = job(revision: 2)
        let ahead = try add(file(bytes), to: files)
        // Started on site: it leaves the jobs ahead and its file goes onto the visit.
        started = [try XCTUnwrap(store.remove(id: ahead.id)?.provenance)]

        XCTAssertTrue(files.isAlreadyHeld(try file(bytes)), "the same job again is still one job")
        XCTAssertEqual(files.refusal(for: try file(job(revision: 3))), JobFileService.startedJobMessage)
        XCTAssertEqual(files.refusal(for: try file(job(revision: 1))), JobFileService.olderRevisionMessage)
        XCTAssertEqual(files.refusal(for: try file(job(revision: 2, notes: "Other words."))),
                       JobFileService.conflictingRevisionMessage)
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testTheOrganisationsSigningRuleStillAppliesToFormatTwo() throws {
        let store = UpcomingJobStore(directory: directory)
        let strict = service(store: store, requireSigned: true)
        XCTAssertNotNil(strict.refusal(for: try file(job(), signed: false)))
        XCTAssertNil(strict.refusal(for: try file(job())))
        XCTAssertNotNil(strict.refusal(for: try file(job(), with: Curve25519.Signing.PrivateKey())),
                        "a signature that does not match is never overridable")
    }

    func testRelation() {
        let held = JobFile.Identity(jobID: "job-1", revision: 2, sha256: "a")
        XCTAssertEqual(JobFile.relation(held: held, arriving: .init(jobID: "job-1", revision: 3, sha256: "b")), .newer)
        XCTAssertEqual(JobFile.relation(held: held, arriving: .init(jobID: "job-1", revision: 1, sha256: "a")), .older)
        XCTAssertEqual(JobFile.relation(held: held, arriving: .init(jobID: "job-1", revision: 2, sha256: "a")), .same)
        XCTAssertEqual(JobFile.relation(held: held, arriving: .init(jobID: "job-1", revision: 2, sha256: "b")), .conflict)
        XCTAssertNil(JobFile.relation(held: held, arriving: .init(jobID: "job-2", revision: 9, sha256: "a")))
    }
}
