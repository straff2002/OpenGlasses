import CryptoKit
import XCTest
@testable import OpenGlasses

/// What a format-2 job names (Contracts/office-bulk.md §5): attachments by exact digest, and
/// manual sets. The job file's own rules, then the attachment following the job through the
/// office's `bulk` folder, against the Go golden fixture.
@MainActor
final class OfficeJobAttachmentTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private typealias Store = OfficeJobAttachmentStore

    private var directory: URL!
    private var transport = OfficeManagedFolderMemoryTransport()
    private var jobs: UpcomingJobStore!
    private var started: [(needs: JobNeeds?, provenance: JobFileProvenance?)] = []
    private var bulkAllowed = false
    private var freeBytes: Int64?
    private var maximumBytes: Int64 = 50 * 1_048_576
    private let now = Date(timeIntervalSince1970: TimeInterval(OfficeCheckInFixtures.now + 60))

    /// The exact bytes the golden job names, and their digest.
    private let attachmentBytes = Data("Avenkin public fixture job attachment v1".utf8)
    private var attachmentDigest: String { OfficeBulk.digest(attachmentBytes) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeJobAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        jobs = UpcomingJobStore(directory: directory.appendingPathComponent("jobs", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The fictional organisation key the golden file is signed with. It has no authority.
    private var fixtureKey: String {
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture organisation job key v1".utf8)))
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString()
    }

    private func golden() throws -> Data { try F.file("job-file-v2-needs", extension: "ogjob") }

    private func file(_ job: String) throws -> Data {
        try JobFileSignatureCheck.format2File(job: Data(job.utf8), privateKeyBase64: nil)
    }

    private func refusal(_ data: Data) -> JobFileValidator.Refusal? {
        if case .failure(let refusal) = JobFileValidator.validate(data) { return refusal }
        return nil
    }

    private func files(key: String? = nil) -> JobFileService {
        JobFileService(seams: .init(
            store: { [unowned self] in self.jobs },
            policy: { JobFileImportPolicy.resolve(medicalMode: false, organisationRequiresSigned: false) },
            organisationKey: { [fixtureKey] in key ?? fixtureKey },
            organisationName: { "Fixture Service Ltd" },
            now: { [now] in now },
            fieldAssistActive: { true },
            startedJobFiles: { [] }))
    }

    @discardableResult
    private func addGoldenJob() throws -> UpcomingJob {
        let service = files()
        service.handle(data: try golden(), fileName: "FX-1008.ogjob")
        return try XCTUnwrap(service.accept(.add))
    }

    private func openFolders() async throws {
        let held = try F.held()
        let binding = try F.fields(F.payload("office-check-in-binding-v1"))
        let fields: [String: Any] = [
            "organizationID": held.organizationID, "enrolmentID": held.enrolmentID, "officeID": held.officeID,
            "generation": 1, "officeTransportID": try XCTUnwrap(binding["officeTransportID"]),
            "officeApplicationKey": held.officeApplicationKey.base64EncodedString(),
            "phoneApplicationKey": held.phoneApplicationKey.base64EncodedString(),
            "profileID": held.profileID, "bindingSHA256": held.bindingSHA256,
            "administratorKey": held.administratorKey.base64EncodedString(),
        ]
        try await transport.startFolders(
            bindingJSON: String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self),
            policy: "automatic", lanHint: "")
    }

    private func makeStore() -> Store {
        var seams = Store.Seams(transport: transport,
                                directory: directory.appendingPathComponent("attachments", isDirectory: true))
        seams.named = { [unowned self] in
            Store.named(self.jobs.jobs.map { ($0.needs, $0.provenance) } + self.started)
        }
        seams.freeBytes = { [unowned self] in self.freeBytes }
        seams.maximumBytes = maximumBytes
        return Store(seams: seams)
    }

    /// The one owner of the folder's list, asking for what the store wants.
    private func makeManuals(_ store: Store) -> OfficeManualService {
        var seams = OfficeManualService.Seams(transport: transport, held: { try F.held() }, install: { _ in })
        seams.bulkAllowed = { [unowned self] in self.bulkAllowed }
        seams.attachmentsWanted = { store.wanted }
        seams.attachmentsStatus = { await store.took(status: $0, allowed: $1) }
        seams.clock = { [now] in now }
        return OfficeManualService(seams: seams)
    }

    private func officeOffersAttachment(_ bytes: Data? = nil) async {
        await transport.offer(bulk: "attachments/\(attachmentDigest)", bytes ?? attachmentBytes)
    }

    // MARK: - The job file

    func testTheGoldenJobNamesAnAttachmentByDigestAndAManualSet() throws {
        let parsed = try JobFileValidator.validate(try golden()).get()
        XCTAssertEqual(parsed.needs.attachments, [
            .init(name: "Site plan", sha256: attachmentDigest, bytes: 40, mediaType: "application/pdf")])
        XCTAssertEqual(parsed.needs.manualSets, ["fixture-manuals"])

        let service = files()
        service.handle(data: try golden(), fileName: "FX-1008.ogjob")
        guard case .review(let review) = service.stage else { return XCTFail("\(service.stage)") }
        XCTAssertTrue(review.isSigned)
        XCTAssertEqual(review.lines.first { $0.label == "Attachments (follow from the office)" }?.value, "Site plan")
        XCTAssertEqual(review.lines.first { $0.label == "Attachments (not included)" }?.value, "Previous invoice (INV-2231)")
        XCTAssertEqual(review.lines.first { $0.label == "Manuals it needs" }?.value, "fixture-manuals")

        let added = try XCTUnwrap(service.accept(.add))
        XCTAssertEqual(added.attachments, ["Previous invoice (INV-2231)"], "only the one that is merely named")
        // Kept on the job ahead across a relaunch, and on the job once it is started.
        let reloaded = try XCTUnwrap(UpcomingJobStore(directory: directory.appendingPathComponent("jobs")).jobs.first)
        XCTAssertEqual(reloaded.needs, parsed.needs)
        let encoded = try JSONEncoder().encode(XCTUnwrap(reloaded.needs))
        XCTAssertEqual(try JSONDecoder().decode(JobNeeds.self, from: encoded), parsed.needs)
    }

    func testAJobThatNamesNothingHasNoNeeds() throws {
        let plain = try file(#"{"job_id":"job-1","revision":1,"job_reference":"1007","attachments":[{"name":"Old invoice"}]}"#)
        let parsed = try JobFileValidator.validate(plain).get()
        XCTAssertTrue(parsed.needs.isEmpty)
        XCTAssertNil(parsed.upcomingJob(provenance: .init(
            fileName: "a.ogjob", signature: .unsigned, signer: nil, receivedAt: now,
            digest: JobFile.digest(plain), identity: parsed.identity)).needs)
    }

    func testAFormatOneFileNeverNamesWhatFollowsIt() {
        let digest = String(repeating: "a", count: 64)
        let attachment = #"{"format":"openglasses.job","format_version":1,"job_reference":"1007","attachments":[{"name":"Plan","sha256":"\#(digest)","bytes":4,"media_type":"application/pdf"}]}"#
        XCTAssertNotNil(refusal(Data(attachment.utf8)))
        let manuals = #"{"format":"openglasses.job","format_version":1,"job_reference":"1007","manuals":[{"set_id":"set-a"}]}"#
        XCTAssertNotNil(refusal(Data(manuals.utf8)))
    }

    func testOnlyAnExactAttachmentAndAClosedManualListAreAccepted() throws {
        let a = String(repeating: "a", count: 64)
        func job(attachments: String = "[]", manuals: String = "[]") -> String {
            #"{"job_id":"job-1","revision":1,"job_reference":"1007","attachments":\#(attachments),"manuals":\#(manuals)}"#
        }
        let good = #"[{"name":"Plan","sha256":"\#(a)","bytes":4,"media_type":"image/png"}]"#
        XCTAssertNil(refusal(try file(job(attachments: good, manuals: #"[{"set_id":"set-a"}]"#))))

        let attachments: [(String, String)] = [
            ("a digest and no size or type", #"[{"name":"Plan","sha256":"\#(a)"}]"#),
            ("a size and type and no digest", #"[{"name":"Plan","bytes":4,"media_type":"image/png"}]"#),
            ("an upper-case digest", #"[{"name":"Plan","sha256":"\#(a.uppercased())","bytes":4,"media_type":"image/png"}]"#),
            ("a short digest", #"[{"name":"Plan","sha256":"abc","bytes":4,"media_type":"image/png"}]"#),
            ("no bytes at all", #"[{"name":"Plan","sha256":"\#(a)","bytes":0,"media_type":"image/png"}]"#),
            ("a size in words", #"[{"name":"Plan","sha256":"\#(a)","bytes":"4","media_type":"image/png"}]"#),
            ("a size that is a truth value", #"[{"name":"Plan","sha256":"\#(a)","bytes":true,"media_type":"image/png"}]"#),
            ("a fractional size", #"[{"name":"Plan","sha256":"\#(a)","bytes":4.5,"media_type":"image/png"}]"#),
            ("a type the phone does not open", #"[{"name":"Plan","sha256":"\#(a)","bytes":4,"media_type":"text/html"}]"#),
            ("an unknown member", #"[{"name":"Plan","sha256":"\#(a)","bytes":4,"media_type":"image/png","path":"../x"}]"#),
            ("one digest twice", #"[{"name":"Plan","sha256":"\#(a)","bytes":4,"media_type":"image/png"},{"name":"Plan again","sha256":"\#(a)","bytes":4,"media_type":"image/png"}]"#),
        ]
        for (what, list) in attachments {
            XCTAssertNotNil(refusal(try file(job(attachments: list))), what)
        }

        let eleven = (0..<11).map { #"{"set_id":"set-\#($0)"}"# }.joined(separator: ",")
        let manuals: [(String, String)] = [
            ("not a list", #"{"set_id":"set-a"}"#),
            ("more than ten", "[\(eleven)]"),
            ("one set twice", #"[{"set_id":"set-a"},{"set_id":"set-a"}]"#),
            ("an extra member", #"[{"set_id":"set-a","sha256":"\#(a)"}]"#),
            ("a set that is a path", #"[{"set_id":"../set"}]"#),
            ("a set that is not text", #"[{"set_id":7}]"#),
            ("an empty object", "[{}]"),
        ]
        for (what, list) in manuals {
            XCTAssertNotNil(refusal(try file(job(manuals: list))), what)
        }
    }

    func testAStartedJobKeepsWhatItsFileNamed() throws {
        let needs = try JobFileValidator.validate(try golden()).get().needs
        var session = FieldSession(id: "session-1", vaultId: "vault", assetId: nil, mode: .aiOnly,
                                   startedAt: now, outcome: .inProgress, escalations: [], billableSeconds: 0)
        session.jobNeeds = needs
        let decoded = try JSONDecoder().decode(FieldSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.jobNeeds, needs)
        // A record written before this had no such member.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["jobNeeds"] = nil
        XCTAssertNil(try JSONDecoder().decode(FieldSession.self, from: JSONSerialization.data(withJSONObject: object)).jobNeeds)
    }

    // MARK: - The attachment follows the job

    func testAnAttachmentASignedJobNamesArrivesCheckedAndOpens() async throws {
        try await openFolders()
        let job = try addGoldenJob()
        let attachment = try XCTUnwrap(job.needs?.attachments.first)
        let store = makeStore()
        let manuals = makeManuals(store)
        XCTAssertEqual(store.state(of: attachment), .waitingForOffice)

        // Asked of the folder as an attachment, by exactly the digest and size the job named.
        try await manuals.sweep()
        var wanted = await transport.bulkWanted
        XCTAssertEqual(wanted.map(\.kind), ["attachment"])
        XCTAssertEqual(wanted.map(\.sha256), [attachmentDigest])
        XCTAssertEqual(wanted.map(\.bytes), [40])
        XCTAssertEqual(store.state(of: attachment), .waitingForOffice)

        // The office has it; the route is not one large content uses unasked.
        await officeOffersAttachment()
        try await manuals.sweep()
        var paused = await transport.bulkPaused
        XCTAssertTrue(paused)
        XCTAssertEqual(store.state(of: attachment), .waitingForWiFi)
        XCTAssertEqual(Store.status(attachment, state: store.state(of: attachment)).detail, "Waiting for Wi-Fi. 40 bytes.")

        // On the office's own network it arrives, is checked again here and is kept.
        bulkAllowed = true
        try await manuals.sweep()
        guard case .ready(let file) = store.state(of: attachment) else {
            return XCTFail("\(store.state(of: attachment))")
        }
        XCTAssertEqual(try Data(contentsOf: file), attachmentBytes)
        XCTAssertEqual(file.lastPathComponent, "\(attachmentDigest).pdf", "the digest and the stated type, never the job's words")
        XCTAssertTrue(Store.status(attachment, state: .ready(file)).detail?.hasPrefix("Ready.") == true)

        // Nothing more is asked of the folder, and the app launched again still has the file.
        try await manuals.sweep()
        wanted = await transport.bulkWanted
        paused = await transport.bulkPaused
        XCTAssertTrue(wanted.isEmpty)
        XCTAssertTrue(paused)
        XCTAssertEqual(makeStore().state(of: attachment), .ready(file))

        // It goes with its job.
        _ = jobs.remove(id: job.id)
        try await manuals.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.states.isEmpty)
    }

    func testAStartedJobKeepsItsAttachmentAndAFinishedOneDoesNot() async throws {
        try await openFolders()
        let job = try addGoldenJob()
        let attachment = try XCTUnwrap(job.needs?.attachments.first)
        let store = makeStore()
        let manuals = makeManuals(store)
        await officeOffersAttachment()
        bulkAllowed = true
        try await manuals.sweep()
        guard case .ready(let file) = store.state(of: attachment) else { return XCTFail("not ready") }

        // Started: the job ahead is gone and the open job names the same attachment.
        started = [(job.needs, job.provenance)]
        _ = jobs.remove(id: job.id)
        try await manuals.sweep()
        XCTAssertEqual(store.state(of: attachment), .ready(file))

        // Finished: no job this phone holds names it.
        started = []
        try await manuals.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testBytesThatAreNotWhatTheJobNamedAreNeverKept() async throws {
        try await openFolders()
        let attachment = try XCTUnwrap(try addGoldenJob().needs?.attachments.first)
        let store = makeStore()
        let manuals = makeManuals(store)
        bulkAllowed = true
        // The right name in the folder, and other bytes of the same length.
        await officeOffersAttachment(Data(repeating: 0x41, count: attachmentBytes.count))
        try await manuals.sweep()
        try await manuals.sweep()
        let taken = await transport.bulkTaken
        XCTAssertTrue(taken.isEmpty)
        XCTAssertEqual(store.state(of: attachment), .downloading)

        // A folder that says ready for something it cannot hand over keeps nothing either.
        await store.took(status: [attachmentDigest: "ready"], allowed: true)
        XCTAssertEqual(store.state(of: attachment), .downloading)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("attachments").path)) ?? [], [])
    }

    func testAJobThatIsOnlyAClaimFetchesNothing() async throws {
        try await openFolders()
        // A file nobody signed that names the same bytes.
        let unsigned = try file(#"{"job_id":"job-9","revision":1,"job_reference":"FX-1009","attachments":[{"name":"Site plan","sha256":"\#(attachmentDigest)","bytes":40,"media_type":"application/pdf"}]}"#)
        let service = files()
        service.handle(data: unsigned, fileName: "FX-1009.ogjob")
        let job = try XCTUnwrap(service.accept(.add))
        XCTAssertNotEqual(job.provenance?.signature, .signed)
        XCTAssertNotNil(job.needs, "what it names is still shown")

        let store = makeStore()
        let manuals = makeManuals(store)
        await officeOffersAttachment()
        bulkAllowed = true
        try await manuals.sweep()
        let wanted = await transport.bulkWanted
        let taken = await transport.bulkTaken
        XCTAssertTrue(wanted.isEmpty)
        XCTAssertTrue(taken.isEmpty)
        XCTAssertTrue(store.wanted.isEmpty)
    }

    func testAnAttachmentThereIsNoRoomForIsNotAskedFor() async throws {
        try await openFolders()
        let attachment = try XCTUnwrap(try addGoldenJob().needs?.attachments.first)
        freeBytes = Store.spaceMargin + 39
        var store = makeStore()
        XCTAssertTrue(store.wanted.isEmpty)
        XCTAssertEqual(store.state(of: attachment), .notEnoughSpace)
        XCTAssertEqual(Store.status(attachment, state: .notEnoughSpace).detail, "Not enough space on this phone. 40 bytes.")
        freeBytes = Store.spaceMargin + 40
        XCTAssertEqual(makeStore().wanted, [attachment])

        maximumBytes = 39
        store = makeStore()
        XCTAssertTrue(store.wanted.isEmpty)
        XCTAssertEqual(store.state(of: attachment), .tooLarge)
    }

    func testLeavingTheOrganisationRemovesEveryAttachment() async throws {
        try await openFolders()
        let attachment = try XCTUnwrap(try addGoldenJob().needs?.attachments.first)
        let store = makeStore()
        let manuals = makeManuals(store)
        await officeOffersAttachment()
        bulkAllowed = true
        try await manuals.sweep()
        guard case .ready(let file) = store.state(of: attachment) else { return XCTFail("not ready") }
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.state(of: attachment), .waitingForOffice)
    }

    // MARK: - Pure

    func testAFileIsNamedOnlyByADigestAndAKnownType() {
        let folder = URL(fileURLWithPath: "/store", isDirectory: true)
        let a = String(repeating: "a", count: 64)
        XCTAssertEqual(Store.file(for: .init(name: "../x", sha256: a, bytes: 1, mediaType: "image/jpeg"), in: folder)?.path,
                       "/store/\(a).jpg")
        XCTAssertNil(Store.file(for: .init(name: "x", sha256: "../../etc", bytes: 1, mediaType: "image/jpeg"), in: folder))
        XCTAssertNil(Store.file(for: .init(name: "x", sha256: a.uppercased(), bytes: 1, mediaType: "image/jpeg"), in: folder))
        XCTAssertNil(Store.file(for: .init(name: "x", sha256: a, bytes: 1, mediaType: "text/html"), in: folder))
        XCTAssertNil(Store.file(for: .init(name: "x", sha256: a, bytes: 0, mediaType: "image/jpeg"), in: folder))
    }

    func testNothingSaysDeliveredAndOnlyAKeptFileIsReady() {
        let attachment = JobNeeds.Attachment(name: "Site plan", sha256: String(repeating: "a", count: 64),
                                             bytes: 40, mediaType: "application/pdf")
        let states: [Store.State] = [.downloading, .waitingForWiFi, .waitingForOffice, .notEnoughSpace, .tooLarge]
        for state in states {
            let status = Store.status(attachment, state: state)
            let words = (status.title + " " + (status.detail ?? "")).lowercased()
            XCTAssertFalse(words.contains("delivered"), words)
            XCTAssertFalse(words.contains("ready"), words)
        }
        XCTAssertEqual(Store.status(set: "fixture-manuals", standing: nil).detail, "Not yet available.")
        XCTAssertEqual(Store.status(set: "fixture-manuals", standing: .notYetAvailable).detail, "Not yet available.")
        XCTAssertEqual(Store.status(set: "fixture-manuals", standing: .onItsWay).detail, "On its way from the office.")
        XCTAssertEqual(Store.status(set: "fixture-manuals", standing: .ready).detail, "Ready.")
    }
}
