import CryptoKit
import XCTest
@testable import OpenGlasses

/// A recorded job sealed on the phone and taken to the office: the bundle on disk, and the
/// service that sends it, against the Go golden fixtures and an in-memory stand-in for the
/// transport.
@MainActor
final class JobRecordingSyncServiceTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private typealias Store = JobRecordingBundleStore
    private typealias Service = JobRecordingSyncService

    private var root: URL!
    private var transport = OfficeManagedFolderMemoryTransport()
    private var now = Date(timeIntervalSince1970: TimeInterval(OfficeCheckInFixtures.now))
    private var conditions = SyncEligibility.Conditions(
        network: .wifi, isCharging: true, batteryLevel: 1, profileIsCurrent: true, leaseIsCurrent: true,
        bindingIsCurrent: true, officeIsReachable: true)
    private var gateFailure: Error?
    private var gateCalls = 0
    /// What the service wrote into jobs' logs.
    private var logged: [(sessionID: String, kind: SessionLogger.Event.Kind, payload: [String: AnyCodable])] = []

    private let sessionID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private let videoPart = Data("Avenkin public fixture recording video part v1: eighty-two bytes of nothing at all".utf8)
    private let audioPart = Data("Avenkin public fixture audio v1".utf8)

    private struct Failed: Error {}

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobRecordingSyncServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - The world

    private var store: Store { Store(sessionsRoot: root.appendingPathComponent("FieldSessions", isDirectory: true)) }

    private func bundleID() throws -> String {
        try XCTUnwrap(try F.fields(F.payload("recording-bundle-manifest-v1"))["bundleID"] as? String)
    }

    private func binding() throws -> BundleManifest.Binding {
        let held = try F.held()
        return .init(organizationID: held.organizationID, enrolmentID: held.enrolmentID, officeID: held.officeID,
                     generation: held.generation, phoneTransportID: held.phoneTransportID)
    }

    /// The recorder's output: two part files in the app's own storage.
    private func partFiles() throws -> [Store.PartFile] {
        let parts = root.appendingPathComponent("parts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let video = parts.appendingPathComponent("video-1.mp4")
        let audio = parts.appendingPathComponent("audio-1.m4a")
        try videoPart.write(to: video)
        try audioPart.write(to: audio)
        return [.init(partID: "video-1", track: .video, container: "mp4", file: video),
                .init(partID: "audio-1", track: .audio, container: "m4a", file: audio)]
    }

    /// The golden signature for the golden manifest (CryptoKit's signatures are randomised); the
    /// fixture phone key for anything else.
    private func sign(_ payload: Data) throws -> Data {
        if payload == (try F.payload("recording-bundle-manifest-v1")) {
            return try XCTUnwrap(Data(base64Encoded: F.envelope(F.data("recording-bundle-manifest-v1")).signature))
        }
        return try F.phone().signature(for: BundleManifest.signingDomain + payload)
    }

    @discardableResult
    private func seal(parts: [Store.PartFile]? = nil, blurred: Bool = false,
                      droppedFrames: Int64 = 0) async throws -> Store.Record {
        try await store.seal(
            .init(bundleID: try bundleID(), sessionID: sessionID, jobNumber: "JOB-1042", binding: try binding(),
                  consentAt: now.addingTimeInterval(-3_600), blurred: blurred, droppedFrames: droppedFrames,
                  chunkBytes: 32,
                  timeline: try RecordedJobFixtures.data("recorded-session-timeline-v1"),
                  transcript: try RecordedJobFixtures.data("recorded-session-transcript-v1"),
                  parts: try parts ?? partFiles()),
            now: now, sign: { try self.sign($0) })
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

    private func makeService() -> Service {
        Service(seams: .init(
            transport: transport, store: store,
            trust: { [unowned self] in
                self.gateCalls += 1
                if let gateFailure = self.gateFailure { throw gateFailure }
                let held = try F.held()
                return .init(organizationID: held.organizationID, enrolmentID: held.enrolmentID, officeID: held.officeID,
                             phoneTransportID: held.phoneTransportID, officeApplicationKey: held.officeApplicationKey)
            },
            conditions: { [unowned self] in self.conditions },
            clock: { [unowned self] in self.now },
            log: { [unowned self] sessionID, kind, payload in self.logged.append((sessionID, kind, payload)) }))
    }

    /// Passes until every chunk is in the office's folder and the office has taken it.
    private func sendEverything(_ service: Service) async throws {
        for _ in 0..<8 {
            try await service.sweep()
            await transport.officeTakes(try bundleID())
        }
        try await service.sweep()
    }

    private func officeSays(_ status: String, _ fixture: String? = nil, _ envelope: Data? = nil) async throws {
        await transport.put(recordingStatus: try envelope ?? F.data(fixture ?? "recording-receipt-\(status)-v1"),
                            bundleID: try bundleID(), status: status)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Sealing

    func testARecordedJobIsSealedAsTheGoldenBundle() async throws {
        let parts = try partFiles()
        let record = try await seal(parts: parts)
        let manifest = try store.manifest(record)
        XCTAssertEqual(manifest.payload, try F.payload("recording-bundle-manifest-v1"), "the golden manifest, byte for byte")
        XCTAssertEqual(BundleManifest.sealed(payload: manifest.payload, signature: manifest.signature),
                       try F.data("recording-bundle-manifest-v1"))
        XCTAssertEqual(record.manifestSHA256, OfficeCheckIn.digest(manifest.payload))
        XCTAssertEqual(record.chunks.map(\.bytes), [32, 32, 18, 31])
        XCTAssertEqual(record.mediaBytes, 113)
        XCTAssertEqual(record.stage, .sealed)

        // Each chunk is a file named by its digest, the two JSON files are the ones listed, and
        // the recorder's part files are gone: the chunks are the recording now.
        for chunk in record.chunks {
            let bytes = try Data(contentsOf: store.chunkFile(record, sha256: chunk.sha256))
            XCTAssertEqual(OfficeCheckIn.digest(bytes), chunk.sha256)
        }
        let video = try record.chunks.prefix(3).reduce(Data()) { $0 + (try Data(contentsOf: store.chunkFile(record, sha256: $1.sha256))) }
        XCTAssertEqual(video, videoPart)
        XCTAssertEqual(try Data(contentsOf: store.timelineFile(record)), try RecordedJobFixtures.data("recorded-session-timeline-v1"))
        XCTAssertTrue(parts.allSatisfy { !exists($0.file) })
        XCTAssertEqual(store.records(), [record])
        XCTAssertEqual(store.unsyncedBytes(), 113)
        let media = try FileManager.default.contentsOfDirectory(atPath: store.bundleDirectory(sessionID: sessionID).appendingPathComponent("media").path)
        XCTAssertEqual(media.count, 4, "nothing left over from cutting")
    }

    func testHalfABundleIsNoBundleAndTheRecordedPartsStay() async throws {
        var parts = try partFiles()
        parts.append(.init(partID: "video-2", track: .video, container: "mp4",
                           file: root.appendingPathComponent("missing.mp4")))
        do {
            try await seal(parts: parts)
            XCTFail("sealed with a part that cannot be read")
        } catch let failure as Store.Failure {
            XCTAssertEqual(failure, .unreadablePart)
        }
        XCTAssertFalse(exists(store.bundleDirectory(sessionID: sessionID)))
        XCTAssertTrue(parts.prefix(2).allSatisfy { exists($0.file) })
        XCTAssertTrue(store.records().isEmpty)

        // A signer that does not sign leaves no bundle either, and a session that is a path is refused.
        do {
            _ = try await store.seal(
                .init(bundleID: try bundleID(), sessionID: sessionID, jobNumber: nil, binding: try binding(),
                      consentAt: now, blurred: false, droppedFrames: 0, chunkBytes: 32,
                      timeline: Data("{}".utf8), transcript: Data("{}".utf8), parts: Array(parts.prefix(2))),
                now: now, sign: { _ in Data(repeating: 0, count: 10) })
            XCTFail("sealed without a signature")
        } catch let failure as Store.Failure {
            XCTAssertEqual(failure, .notSigned)
        }
        XCTAssertFalse(exists(store.bundleDirectory(sessionID: sessionID)))
        do {
            _ = try await store.seal(
                .init(bundleID: try bundleID(), sessionID: "../elsewhere", jobNumber: nil, binding: try binding(),
                      consentAt: now, blurred: false, droppedFrames: 0, timeline: Data(), transcript: Data(), parts: []),
                now: now, sign: { try self.sign($0) })
            XCTFail("sealed under a path")
        } catch let failure as Store.Failure {
            XCTAssertEqual(failure, .notAnIdentifier)
        }
    }

    // MARK: - The road to the office

    func testARecordingGoesOnlyWhenTheMomentIsRightAndOnlyAFewChunksAhead() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        let id = try bundleID()
        XCTAssertEqual(service.rows.map(\.phase), [.sealed])

        // On mobile data, which the person has not allowed: nothing is published and it says why.
        conditions.network = .cellular
        try await service.sweep()
        var published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.waitingForWiFi)))
        XCTAssertEqual(Service.words(try XCTUnwrap(service.rows.first)),
                       "Recording waiting to sync. Waiting for Wi-Fi. Recordings aren't sent over mobile data unless you allow it.")
        XCTAssertEqual(gateCalls, 0, "the pairing gate is not asked while nothing can be sent")

        // On the office's Wi-Fi: the manifest, byte for byte the golden one, and two chunks.
        conditions.network = .wifi
        try await service.sweep()
        published = await transport.recordings
        XCTAssertEqual(published[id]?.envelope, try F.data("recording-bundle-manifest-v1"))
        XCTAssertEqual(published[id]?.published.keys.filter { $0.hasPrefix("media/") }.count, 2)
        guard case .transferring(let sent, let total)? = service.rows.first?.phase else {
            return XCTFail("\(String(describing: service.rows.first?.phase))")
        }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(total, store.records().first?.totalBytes)

        // Nothing more goes until the office has taken what is there.
        try await service.sweep()
        var chunkPublishes = await transport.recordingChunkPublishes
        XCTAssertEqual(chunkPublishes, 2)
        await transport.officeTakes(id)
        try await service.sweep()
        chunkPublishes = await transport.recordingChunkPublishes
        XCTAssertEqual(chunkPublishes, 4)

        // The route stops being a good one: what is there stays, nothing is added.
        conditions.isCharging = false
        conditions.batteryLevel = 0.2
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.waitingForPower)))

        // Everything served is "sent", never "received": only the office's receipt says that.
        conditions.isCharging = true
        await transport.officeTakes(id)
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .delivered)
        XCTAssertEqual(Service.words(try XCTUnwrap(service.rows.first)), "Recording sent. Waiting for the office to confirm it.")
        XCTAssertNil(store.records().first?.acknowledgedAt)
        XCTAssertTrue(exists(store.chunkFile(try XCTUnwrap(store.records().first), sha256: try XCTUnwrap(store.records().first?.chunks.first?.sha256))))
        let withdrawn = await transport.withdrawnRecordings
        XCTAssertTrue(withdrawn.isEmpty)
    }

    /// Through a relay a recording's manifest, timeline and transcript go and its video does not:
    /// no chunk is offered until the connection is straight to the office, and none is added to
    /// the ones already there when a direct connection becomes a relayed one.
    func testThroughARelayTheVideoWaitsAndEverythingElseGoes() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        let id = try bundleID()

        conditions.officeIsThroughRelay = true
        try await service.sweep()
        var published = await transport.recordings
        XCTAssertEqual(published[id]?.envelope, try F.data("recording-bundle-manifest-v1"))
        XCTAssertEqual(Set(published[id]?.published.keys.filter { !$0.hasPrefix("media/") } ?? []),
                       ["timeline.json", "transcript.json"])
        var chunkPublishes = await transport.recordingChunkPublishes
        XCTAssertEqual(chunkPublishes, 0, "no video is offered through a relay")
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.videoNeedsDirectRoute)))
        XCTAssertEqual(Service.words(try XCTUnwrap(service.rows.first)),
                       "Recording waiting to sync. The video is waiting for a direct connection to the office. "
                           + "Video is never sent through a relay.")

        // The office takes the small files through the relay; the video still waits.
        await transport.officeTakes(id)
        try await service.sweep()
        chunkPublishes = await transport.recordingChunkPublishes
        XCTAssertEqual(chunkPublishes, 0)
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.videoNeedsDirectRoute)))

        // Straight to the office: the video starts.
        conditions.officeIsThroughRelay = false
        try await service.sweep()
        chunkPublishes = await transport.recordingChunkPublishes
        XCTAssertEqual(chunkPublishes, 2)
        guard case .transferring? = service.rows.first?.phase else {
            return XCTFail("\(String(describing: service.rows.first?.phase))")
        }

        // Back on a relay part-way: the office has taken what was there, and nothing is added.
        await transport.officeTakes(id)
        conditions.officeIsThroughRelay = true
        try await service.sweep()
        chunkPublishes = await transport.recordingChunkPublishes
        XCTAssertEqual(chunkPublishes, 2)
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.videoNeedsDirectRoute)))

        // Direct again, to the end. A recording all of which the office has taken is sent,
        // whatever the route is by then.
        conditions.officeIsThroughRelay = false
        try await sendEverything(service)
        conditions.officeIsThroughRelay = true
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .delivered)
        published = await transport.recordings
        XCTAssertEqual(published[id]?.published.keys.filter { $0.hasPrefix("media/") }.count,
                       store.records().first?.chunks.count)
    }

    /// The route the connection reports is what holds the video: a relay is in reach and is not
    /// a connection straight to the office.
    func testARelayedConnectionIsInReachAndNotDirect() {
        let relay = Service.pairing(.connected(.relay))
        XCTAssertTrue(relay.bindingIsCurrent && relay.officeIsReachable && relay.officeIsThroughRelay)
        let direct = Service.pairing(.connected(.direct))
        XCTAssertTrue(direct.officeIsReachable)
        XCTAssertFalse(direct.officeIsThroughRelay)
    }

    func testOnlyTheOfficesReceiptLetsARecordingGoAndTheMediaIsTrimmedAWeekLater() async throws {
        try await openFolders()
        let sealed = try await seal()
        let service = makeService()
        try await sendEverything(service)
        XCTAssertEqual(service.rows.first?.phase, .delivered)

        // What is not the office's word about this bundle changes nothing.
        try await officeSays("received", nil, try F.changed("recording-receipt-received-v1", domain: OfficeRecordingReceipt.domain, by: F.phone()) { _ in })
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .delivered)
        try await officeSays("received", nil, try F.changed("recording-receipt-received-v1", domain: OfficeRecordingReceipt.domain, by: F.office()) {
            $0["manifestSHA256"] = String(repeating: "0", count: 64)
        })
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .delivered)
        try await officeSays("reviewed", "recording-receipt-received-v1")   // under another status's name
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .delivered)
        XCTAssertNil(service.rows.first?.outcome)

        // The golden receipt: acknowledged, taken out of the folder, and nothing removed yet.
        try await officeSays("received")
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .acknowledged)
        XCTAssertEqual(Service.words(try XCTUnwrap(service.rows.first)), "Recording received by the office.")
        var record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.acknowledgedAt, now)
        let withdrawn = await transport.withdrawnRecordings
        XCTAssertEqual(withdrawn, [sealed.bundleID])
        let receipts = store.bundleDirectory(sessionID: sessionID).appendingPathComponent("receipts")
        XCTAssertEqual(try Data(contentsOf: receipts.appendingPathComponent("received.envelope.json")),
                       try F.data("recording-receipt-received-v1"))
        XCTAssertTrue(record.chunks.allSatisfy { exists(store.chunkFile(record, sha256: $0.sha256)) })
        XCTAssertEqual(store.unsyncedBytes(), 0)

        // Six days on the media is still here; at seven it is trimmed, and only the media.
        now = now.addingTimeInterval(6 * 86_400)
        try await service.sweep()
        XCTAssertTrue(exists(store.chunkFile(record, sha256: record.chunks[0].sha256)))
        now = now.addingTimeInterval(86_400)
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .trimmed)
        record = try XCTUnwrap(store.records().first)
        XCTAssertTrue(record.chunks.allSatisfy { !exists(store.chunkFile(record, sha256: $0.sha256)) })
        XCTAssertTrue(exists(store.timelineFile(record)))
        XCTAssertTrue(exists(store.transcriptFile(record)))
        XCTAssertNoThrow(try store.manifest(record))
        XCTAssertTrue(exists(receipts.appendingPathComponent("received.envelope.json")))

        // What came of it arrives after the bundle has left the folder, and is still heard.
        try await officeSays("published")
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.outcome?.status, "published")
        XCTAssertEqual(service.rows.first?.outcome?.vaultID, "fixture-organisation-vault")
        XCTAssertEqual(Service.words(try XCTUnwrap(service.rows.first)),
                       "Recording received by the office. A procedure was published from it.")

        // The app launched again is where it was, and the same receipts are not acted on twice.
        let relaunched = makeService()
        try await relaunched.sweep()
        XCTAssertEqual(relaunched.rows, service.rows)
        let after = await transport.withdrawnRecordings
        XCTAssertEqual(after, [sealed.bundleID])
    }

    func testARefusedRecordingIsKeptWholeAndOfferedAgainOnlyWhenTheTechnicianSays() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        try await sendEverything(service)
        try await officeSays("refused")
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .failed(.digest))
        XCTAssertEqual(Service.words(try XCTUnwrap(service.rows.first)),
                       "The office didn't accept the recording (what arrived wasn't what was sent). It is still on this phone.")
        var record = try XCTUnwrap(store.records().first)
        XCTAssertTrue(record.chunks.allSatisfy { exists(store.chunkFile(record, sha256: $0.sha256)) })
        XCTAssertNil(record.acknowledgedAt)
        XCTAssertTrue(service.deletionNeedsConfirmation(bundleID: record.bundleID))

        // Nothing more is sent by itself.
        let before = await transport.recordingChunkPublishes
        try await service.sweep()
        var publishes = await transport.recordingChunkPublishes
        XCTAssertEqual(publishes, before)

        // The technician says try again: it goes from the start, and the old refusal is not acted on again.
        try await service.keepWaiting(bundleID: record.bundleID)
        XCTAssertEqual(service.rows.first?.phase, .sealed)
        try await service.sweep()
        publishes = await transport.recordingChunkPublishes
        XCTAssertEqual(publishes, before + 2)
        record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.stage, .sealed)

        // A refusal after an acknowledgement takes nothing back.
        try await sendEverything(service)
        try await officeSays("received")
        try await service.sweep()
        try await officeSays("refused", nil, try F.changed("recording-receipt-refused-v1", domain: OfficeRecordingReceipt.domain, by: F.office()) {
            $0["at"] = F.now + 9_000
        })
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .acknowledged)
    }

    func testARecordingThatWaitsTooLongIsKeptAndTheTechnicianIsAsked() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        conditions.officeIsReachable = false
        now = now.addingTimeInterval(29 * 86_400)
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.officeNotReachable)))
        now = now.addingTimeInterval(86_400)
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .expired)
        let record = try XCTUnwrap(store.records().first)
        XCTAssertTrue(record.chunks.allSatisfy { exists(store.chunkFile(record, sha256: $0.sha256)) }, "nothing is removed")

        // Even with the office back, nothing is sent until the technician chooses.
        conditions.officeIsReachable = true
        try await service.sweep()
        let published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
        try await service.keepWaiting(bundleID: record.bundleID)
        XCTAssertEqual(store.records().first?.waitingSince, now)
        try await service.sweep()
        guard case .transferring? = service.rows.first?.phase else {
            return XCTFail("\(String(describing: service.rows.first?.phase))")
        }
    }

    func testNothingIsPublishedOnAPairingThatDoesNotVerify() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        gateFailure = Failed()
        do {
            try await service.sweep()
            XCTFail("the pass should have failed at the gate")
        } catch is Failed {}
        var published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(service.rows.first?.phase, .sealed)
        gateFailure = nil
        try await service.sweep()
        published = await transport.recordings
        XCTAssertEqual(published.count, 1)
    }

    /// The medical local-only rule is asked by the service itself, where the bytes would leave —
    /// not only taken on trust from whoever reports the conditions.
    func testNothingIsPublishedWhileMedicalLocalOnlyRefusesTheRoute() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        let previous = MedicalEgressGuard.currentMode
        MedicalEgressGuard.currentMode = { .localOnly }
        defer { MedicalEgressGuard.currentMode = previous }
        do {
            try await service.sweep()
            XCTFail("the pass should have been refused")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .jobRecordingOfficeSync)
        }
        var published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(gateCalls, 0, "refused before the pairing is even asked")

        MedicalEgressGuard.currentMode = { .off }
        try await service.sweep()
        published = await transport.recordings
        XCTAssertEqual(published.count, 1)
    }

    /// An unblurred recording is not sent where the organisation requires blur. It is kept, and
    /// the line on the job says why.
    func testAnUnblurredRecordingIsHeldWhereTheOrganisationRequiresBlur() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        conditions.blurRequiredAndNotDone = true
        try await service.sweep()
        let published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(service.rows.first?.phase, .waiting(.notEligible(.blurRequired)))
        XCTAssertTrue(Service.words(try XCTUnwrap(service.rows.first)).contains("blurred"))
        XCTAssertEqual(store.records().count, 1, "it is kept")
        XCTAssertFalse(store.isBlurred(try XCTUnwrap(store.records().first)))
    }

    /// A sealed recording cannot be blurred afterwards: its manifest is signed. So one sealed
    /// before the rule applied is held for as long as the rule does, however many passes go by,
    /// and the words on the job's page say what it is and what can be done about it.
    func testAnUnblurredRecordingSealedBeforeTheRuleStaysHeldAndSaysItCanBeDeleted() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        conditions.blurRequiredAndNotDone = true
        for _ in 0..<3 { try await service.sweep() }
        let published = await transport.recordings
        XCTAssertTrue(published.isEmpty)

        let words = Service.words(try XCTUnwrap(service.rows.first))
        XCTAssertTrue(words.hasPrefix("This recording is held on this phone."), words)
        XCTAssertTrue(words.contains("can't be blurred now") && words.contains("You can delete it"), words)
        XCTAssertFalse(words.contains("waiting to sync"), "it is not waiting for anything")
        XCTAssertTrue(service.deletionNeedsConfirmation(bundleID: try bundleID()))

        // Deleting it is the one thing a technician can do, and it works while it is held.
        try await service.delete(bundleID: try bundleID())
        XCTAssertTrue(store.records().isEmpty)
    }

    /// A bundle whose own signed manifest says it was blurred is what the rule asks for, and goes.
    /// What the caller reports is the organisation's rule; whether a bundle meets it is read from
    /// the bundle.
    func testABlurredRecordingIsSentWhereTheOrganisationRequiresBlur() async throws {
        try await openFolders()
        let record = try await seal(blurred: true, droppedFrames: 7)
        XCTAssertTrue(store.isBlurred(record))
        let manifest = try XCTUnwrap(BundleManifest(payload: store.manifest(record).payload))
        XCTAssertTrue(manifest.blurred)
        XCTAssertEqual(manifest.droppedFrames, 7)

        let service = makeService()
        conditions.blurRequiredAndNotDone = true
        try await service.sweep()
        let published = await transport.recordings
        XCTAssertEqual(published.count, 1)
        XCTAssertNotEqual(service.rows.first?.phase, .waiting(.notEligible(.blurRequired)))
    }

    /// Whether a bundle is blurred is read from its manifest and nowhere else. One whose manifest
    /// is gone, or is not the one the record was made for, is not taken to be blurred.
    func testABundleWhoseManifestCannotBeReadIsNotTakenToBeBlurred() async throws {
        try await openFolders()
        let record = try await seal(blurred: true)
        XCTAssertTrue(store.isBlurred(record))
        let manifest = store.bundleDirectory(sessionID: sessionID).appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: manifest)
        XCTAssertFalse(store.isBlurred(record))
        try FileManager.default.removeItem(at: manifest)
        XCTAssertFalse(store.isBlurred(record))

        let service = makeService()
        conditions.blurRequiredAndNotDone = true
        try? await service.sweep()
        let published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
    }

    func testDeletingARecordingRemovesAllOfItAndAsksFirstWhenTheOfficeHasNotGotIt() async throws {
        try await openFolders()
        let record = try await seal()
        let service = makeService()
        try await service.sweep()
        XCTAssertTrue(service.deletionNeedsConfirmation(bundleID: record.bundleID))
        try await service.delete(bundleID: record.bundleID)
        XCTAssertFalse(exists(store.bundleDirectory(sessionID: sessionID).deletingLastPathComponent()))
        XCTAssertTrue(service.rows.isEmpty)
        let published = await transport.recordings
        XCTAssertTrue(published.isEmpty)
        try await service.sweep()   // nothing to do, and nothing wrong
    }

    // MARK: - Audit without content (Plan HE §5)

    private func lines(_ kind: SessionLogger.Event.Kind) -> [[String: AnyCodable]] {
        logged.filter { $0.kind == kind }.map(\.payload)
    }

    /// The office's receipt and the trim are each written into the job's log once — as counts
    /// and digests, and never on the transport's word that everything was served.
    func testTheReceiptAndTheTrimAreEachWrittenDownOnceAsCountsAndDigests() async throws {
        try await openFolders()
        let sealed = try await seal()
        let service = makeService()
        try await sendEverything(service)
        XCTAssertEqual(service.rows.first?.phase, .delivered)
        XCTAssertTrue(logged.isEmpty, "everything served is sent, not acknowledged: nothing is written yet")

        // What is not the office's word about this bundle is not written down either.
        try await officeSays("received", nil, try F.changed("recording-receipt-received-v1", domain: OfficeRecordingReceipt.domain, by: F.phone()) { _ in })
        try await service.sweep()
        try await officeSays("reviewed", "recording-receipt-received-v1")
        try await service.sweep()
        XCTAssertTrue(logged.isEmpty)

        try await officeSays("received")
        try await service.sweep()
        XCTAssertEqual(logged.map(\.kind), [.recordingSyncAcknowledged])
        let acknowledged = try XCTUnwrap(lines(.recordingSyncAcknowledged).first)
        XCTAssertEqual(logged.first?.sessionID, sessionID)
        XCTAssertEqual(acknowledged["manifest_sha256"]?.value as? String, sealed.manifestSHA256)
        XCTAssertEqual(acknowledged["receipt_sha256"]?.value as? String,
                       OfficeJobUpdate.digest(try F.data("recording-receipt-received-v1")))
        XCTAssertEqual(acknowledged["chunks"]?.value as? Int, 4)
        XCTAssertEqual(acknowledged["bytes"]?.value as? Int, Int(sealed.totalBytes))
        XCTAssertEqual(acknowledged.count, 4)

        // Seen again, on the next pass and after the app is launched again: not written twice.
        try await service.sweep()
        try await makeService().sweep()
        XCTAssertEqual(lines(.recordingSyncAcknowledged).count, 1)
        XCTAssertTrue(lines(.recordingTrimmed).isEmpty, "the media is still on the phone")

        // What the office says later is not another acknowledgement.
        try await officeSays("published")
        try await service.sweep()
        XCTAssertEqual(logged.map(\.kind), [.recordingSyncAcknowledged])

        now = now.addingTimeInterval(6 * 86_400)
        try await service.sweep()
        XCTAssertTrue(lines(.recordingTrimmed).isEmpty)
        now = now.addingTimeInterval(86_400)
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .trimmed)
        XCTAssertEqual(logged.map(\.kind), [.recordingSyncAcknowledged, .recordingTrimmed])
        let trimmed = try XCTUnwrap(lines(.recordingTrimmed).first)
        XCTAssertEqual(logged.last?.sessionID, sessionID)
        XCTAssertEqual(trimmed["manifest_sha256"]?.value as? String, sealed.manifestSHA256)
        XCTAssertEqual(trimmed["chunks"]?.value as? Int, 4)
        XCTAssertEqual(trimmed["bytes"]?.value as? Int, 113, "the media, and only the media")
        XCTAssertEqual(trimmed.count, 3)

        try await service.sweep()
        try await makeService().sweep()
        XCTAssertEqual(logged.map(\.kind), [.recordingSyncAcknowledged, .recordingTrimmed], "each written once")

        // Counts and digests: no job number, no path, no status word, nothing that was said.
        for line in logged {
            for (key, value) in line.payload {
                switch value.value {
                case is Int, is Bool:
                    continue
                case let text as String:
                    XCTAssertTrue(text.count == 64 && text.allSatisfy { $0.isHexDigit },
                                  "\(line.kind.rawValue).\(key) carries \(text)")
                default:
                    XCTFail("\(line.kind.rawValue).\(key) carries something that is not a count or a digest")
                }
            }
        }
    }

    /// A recording the office refused, and one it never answered, are neither acknowledged nor
    /// trimmed — and say so by saying nothing.
    func testARefusedOrUnansweredRecordingWritesNeitherLine() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        try await sendEverything(service)
        try await officeSays("refused")
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .failed(.digest))
        now = now.addingTimeInterval(40 * 86_400)
        try await service.sweep()
        XCTAssertTrue(logged.isEmpty)
    }

    /// A receipt that could not be kept is taken in again on the next pass; the line is written
    /// when the phone's own record says acknowledged, and so once.
    func testAReceiptThatCouldNotBeKeptAtOnceIsStillWrittenDownOnce() async throws {
        try await openFolders()
        try await seal()
        let service = makeService()
        try await sendEverything(service)
        // A file where the folder of receipts goes: the receipt verifies and cannot be kept.
        let receipts = store.bundleDirectory(sessionID: sessionID).appendingPathComponent("receipts")
        try Data("in the way".utf8).write(to: receipts)
        try await officeSays("received")
        do {
            try await service.sweep()
            XCTFail("the receipt was kept across a file")
        } catch {}
        XCTAssertTrue(logged.isEmpty, "not written down until the phone's own record says so")
        XCTAssertNil(store.records().first?.acknowledgedAt)

        try FileManager.default.removeItem(at: receipts)
        try await service.sweep()
        try await service.sweep()
        XCTAssertNotNil(store.records().first?.acknowledgedAt)
        XCTAssertEqual(logged.map(\.kind), [.recordingSyncAcknowledged])
    }

    /// Deleting a sealed recording is written down too: whether the office had it, and no more.
    func testDeletingASealedRecordingIsWrittenDownWithWhetherTheOfficeHadIt() async throws {
        try await openFolders()
        let record = try await seal()
        let service = makeService()
        try await service.sweep()
        try await service.deleteRecording(sessionID: "another-job")
        XCTAssertEqual(store.records().count, 1, "another job's recording is not this one")
        try await service.deleteRecording(sessionID: sessionID)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertTrue(service.rows.isEmpty)
        XCTAssertEqual(logged.map(\.kind), [.recordingDeleted])
        let line = try XCTUnwrap(logged.first?.payload)
        XCTAssertEqual(line["sealed"]?.value as? Bool, true)
        XCTAssertEqual(line["acknowledged"]?.value as? Bool, false)
        XCTAssertEqual(line["manifest_sha256"]?.value as? String, record.manifestSHA256)
        XCTAssertEqual(line["bytes"]?.value as? Int, Int(record.totalBytes))
        XCTAssertEqual(line.count, 4)
    }

    /// What the Jobs list and the job-day card are told as a recording goes: owed until the
    /// office's receipt, "sent" only when everything has been served, and then nothing.
    func testARecordingIsOwedUntilTheOfficesReceiptAndNeverAfter() async throws {
        func owed(_ service: Service) -> [JobDayRecording] {
            JobRecordingOwed.gather(coordinator: nil, sync: service, label: { _ in "Job 1042" })
        }
        try await openFolders()
        try await seal()
        let service = makeService()
        XCTAssertEqual(owed(service).map(\.title), ["Recording waiting to sync"])
        XCTAssertNil(owed(service).first?.reason)

        conditions.network = .cellular
        try await service.sweep()
        XCTAssertEqual(owed(service).first?.sentence,
                       "Recording waiting to sync. Waiting for Wi-Fi. Recordings aren't sent over mobile data unless you allow it.")
        conditions.network = .wifi
        conditions.isCharging = false
        conditions.batteryLevel = 0.2
        try await service.sweep()
        XCTAssertEqual(owed(service).first?.reason, "Waiting for power. Plug the phone in to send the recording.")
        conditions.isCharging = true
        conditions.officeIsReachable = false
        try await service.sweep()
        XCTAssertEqual(owed(service).first?.reason,
                       "The office can't be reached from here. The recording will be sent when it can.")
        XCTAssertEqual(owed(service).first?.sessionId, sessionID)
        XCTAssertEqual(owed(service).first?.needsAttention, false)

        conditions.officeIsReachable = true
        try await service.sweep()
        XCTAssertEqual(owed(service).first?.title, "Sending the recording to the office")
        try await sendEverything(service)
        XCTAssertEqual(owed(service).map(\.sentence), ["Recording sent. Waiting for the office to confirm it."])

        try await officeSays("received")
        try await service.sweep()
        XCTAssertEqual(service.rows.first?.phase, .acknowledged)
        XCTAssertTrue(owed(service).isEmpty, "nothing is owed once the office has confirmed it")
    }

    // MARK: - The record and the words

    func testTheRecordAndTheStateMachineAgree() async throws {
        let sealed = try await seal()
        for stage in [Store.Stage.sealed, .delivered, .acknowledged, .trimmed, .failed("too_large"), .expired] {
            var record = sealed
            record.stage = stage
            var back = sealed
            Service.keep(Service.state(of: record), in: &back)
            XCTAssertEqual(back.stage, stage)
        }
        var partway = sealed
        partway.transferStarted = true
        partway.sentBytes = 64
        XCTAssertEqual(Service.state(of: partway).phase, .transferring(sentBytes: 64, totalBytes: sealed.totalBytes))
        XCTAssertTrue(Service.state(of: { var r = sealed; r.stage = .trimmed; return r }()).isAcknowledged)
        XCTAssertFalse(Service.state(of: { var r = sealed; r.stage = .delivered; return r }()).isAcknowledged)
    }

    func testOnlyAnAcknowledgedRecordingIsSaidToBeReceived() {
        let phases: [BundleSyncState.Phase] = [
            .preparing, .sealed, .waiting(.notEligible(.waitingForPower)), .waiting(.openAppToPrepare),
            .transferring(sentBytes: 10, totalBytes: 100), .delivered, .failed(.policy), .expired]
        for phase in phases {
            let words = Service.words(.init(id: "a", sessionID: "s", phase: phase, sentBytes: 10, totalBytes: 100, outcome: nil))
            XCTAssertFalse(words.lowercased().contains("received"), words)
        }
        XCTAssertEqual(Service.words(.init(id: "a", sessionID: "s", phase: .transferring(sentBytes: 50, totalBytes: 200),
                                           sentBytes: 50, totalBytes: 200, outcome: nil)),
                       "Sending the recording to the office: 25% of 200 bytes.")
        for reason in BundleSyncState.RefusalReason.allCases {
            XCTAssertFalse(Service.refusalWords(reason).isEmpty)
        }
    }
}
