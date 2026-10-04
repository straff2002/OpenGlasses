import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The pieces that switch reports to the office on in the app: which documents go with a job's
/// record, the store that keeps their exact bytes, the pump on the connection's poll, and who
/// the office is a destination for. Headless: nothing is rendered and no engine runs.
@MainActor
final class OfficeReportWiringTests: XCTestCase {
    private typealias Store = OfficeReportEvidenceStore
    private typealias Documents = OfficeReportDocuments

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeReportWiringTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func op(_ id: String = "7C9E6679-7425-40DE-944B-E07FC1F90AE7") -> QueuedOp {
        QueuedOp(id: id, kind: .workRecord, sessionId: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                 payload: Data(#"{"job_reference":"JOB-1042"}"#.utf8))
    }

    // MARK: - Which documents

    private func seams(sessionExists: Bool = true, mayExport: Bool = true, staysOnPhone: Bool = false,
                       hasTranscript: Bool = true) -> Documents.Seams {
        .init(sessionExists: { _ in sessionExists }, mayExport: { mayExport },
              transcriptStaysOnPhone: { staysOnPhone }, hasTranscript: { _ in hasTranscript },
              report: { _ in (Data("work order".utf8), Data("audit export".utf8)) },
              transcript: { _ in Data("transcript".utf8) })
    }

    func testTheWorkOrderAndAuditExportAlwaysGoAndTheTranscriptFollowsTheOrganisationsRule() throws {
        let attached = try Documents.render(sessionID: "s", seams: seams())
        XCTAssertEqual(attached.transcript, .attached)
        XCTAssertEqual(attached.documents.map(\.role), [.workOrder, .auditExport, .transcript])
        XCTAssertEqual(attached.documents.map(\.requirement), [.required, .required, .required])
        // Only the work order is something the office may pass on to a customer.
        XCTAssertEqual(attached.documents.map(\.audience), [.customer, .office, .office])
        XCTAssertEqual(attached.documents.map(\.name), ["work-order.pdf", "audit-export.json", "transcript.pdf"])

        // The organisation keeps transcripts on the phone: the report says so, and none travels.
        let omitted = try Documents.render(sessionID: "s", seams: seams(staysOnPhone: true))
        XCTAssertEqual(omitted.transcript, .omitted)
        XCTAssertEqual(omitted.documents.map(\.role), [.workOrder, .auditExport])

        // Nothing was said on the job.
        let none = try Documents.render(sessionID: "s", seams: seams(hasTranscript: false))
        XCTAssertEqual(none.transcript, OfficeReport.Transcript.none)
        XCTAssertEqual(none.documents.map(\.role), [.workOrder, .auditExport])

        // A job no longer on this phone, or a phone that cannot make the documents: the record
        // still goes, with none.
        for bare in [seams(sessionExists: false), seams(mayExport: false)] {
            let rendered = try Documents.render(sessionID: "s", seams: bare)
            XCTAssertTrue(rendered.documents.isEmpty)
            XCTAssertEqual(rendered.transcript, OfficeReport.Transcript.none)
        }
    }

    func testADocumentThatCannotBeRenderedIsNotSilentlyLeftOut() {
        struct Failed: Error {}
        var failing = seams()
        failing.transcript = { _ in throw Failed() }
        XCTAssertThrowsError(try Documents.render(sessionID: "s", seams: failing))
    }

    // MARK: - The exact bytes, kept

    func testDocumentsAreRenderedOnceAndTheSameBytesAreNamedEveryTime() async throws {
        var renders = 0
        let store = Store(directory: directory) { _ in
            renders += 1
            // Two renderings of one document are not the same bytes.
            return try Documents.render(sessionID: "s", seams: .init(
                sessionExists: { _ in true }, mayExport: { true }, transcriptStaysOnPhone: { false },
                hasTranscript: { _ in true },
                report: { _ in (Data("work order \(renders)".utf8), Data("audit export \(renders)".utf8)) },
                transcript: { _ in Data("transcript \(renders)".utf8) }))
        }
        let first = try await store.evidence(for: op())
        XCTAssertEqual(first.transcript, .attached)
        XCTAssertEqual(first.evidence.count, 3)
        for item in first.evidence {
            let bytes = try Data(contentsOf: item.file)
            XCTAssertEqual(OfficeReport.digest(bytes), item.attachment.sha256)
            XCTAssertEqual(Int64(bytes.count), item.attachment.bytes)
            XCTAssertEqual(item.file.lastPathComponent, item.attachment.sha256, "a name never selects a path")
        }
        // They make a manifest, and the report and manifest agree about the transcript.
        XCTAssertNotNil(OfficeReport.manifestBytes(first.evidence.map(\.attachment)))

        // Asked again, and after a relaunch: the same documents, not rendered again.
        let again = try await store.evidence(for: op())
        let relaunched = try await Store(directory: directory) { _ in
            renders += 1
            return .init(documents: [], transcript: .none)
        }.evidence(for: op())
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(again.evidence, first.evidence)
        XCTAssertEqual(relaunched.evidence, first.evidence)
        XCTAssertEqual(relaunched.transcript, .attached)

        // Another operation for the same job is another rendering.
        let other = try await store.evidence(for: op("0E984725-C51C-4BF4-9960-E1C80E27ABA0"))
        XCTAssertEqual(renders, 2)
        XCTAssertNotEqual(other.evidence.map(\.attachment.sha256), first.evidence.map(\.attachment.sha256))

        // Once the office has them, they go; the other operation's stay.
        store.remove(operationIDs: [op().id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.evidence[0].file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.evidence[0].file.path))
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEvidenceThatCouldNotBeAManifestIsNotKept() async throws {
        let duplicate = Store.Document(role: .photo, mediaType: "image/jpeg", name: "a.jpg",
                                       requirement: .optional, audience: .office, bytes: Data("same".utf8))
        let cases: [(String, Store.Rendered)] = [
            ("one digest twice", .init(documents: [duplicate, duplicate], transcript: .none)),
            ("a name that is a path", .init(documents: [.init(
                role: .workOrder, mediaType: "application/pdf", name: "../order.pdf",
                requirement: .required, audience: .customer, bytes: Data("x".utf8))], transcript: .none)),
            ("a transcript for the customer", .init(documents: [.init(
                role: .transcript, mediaType: "application/pdf", name: "t.pdf",
                requirement: .required, audience: .customer, bytes: Data("x".utf8))], transcript: .attached)),
            ("says attached with no transcript", .init(documents: [], transcript: .attached)),
            ("an empty document", .init(documents: [.init(
                role: .workOrder, mediaType: "application/pdf", name: "order.pdf",
                requirement: .required, audience: .customer, bytes: Data())], transcript: .none)),
        ]
        for (name, rendered) in cases {
            let store = Store(directory: directory) { _ in rendered }
            do {
                _ = try await store.evidence(for: op())
                XCTFail("\(name): kept")
            } catch {
                XCTAssertEqual(error as? Store.Failure, .notListable, name)
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(op().id).appendingPathComponent("evidence.json").path), name)
        }
        // A record with no documents is still evidence: an empty list.
        let empty = try await Store(directory: directory) { _ in .init(documents: [], transcript: .none) }
            .evidence(for: op())
        XCTAssertTrue(empty.evidence.isEmpty)
        // A stored document that has gone is rendered again rather than named and not sent.
        var renders = 0
        let store = Store(directory: directory.appendingPathComponent("again")) { _ in
            renders += 1
            return .init(documents: [.init(role: .workOrder, mediaType: "application/pdf", name: "order.pdf",
                                           requirement: .required, audience: .customer,
                                           bytes: Data("order \(renders)".utf8))], transcript: .none)
        }
        let first = try await store.evidence(for: op())
        try FileManager.default.removeItem(at: first.evidence[0].file)
        let second = try await store.evidence(for: op())
        XCTAssertEqual(renders, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.evidence[0].file.path))
    }

    // MARK: - The pump

    func testThePumpFlushesWhenAReceiptChangedSomethingOrRecordsAreWaitingAndNotOnEveryPoll() async {
        var changed = false
        var waiting = false
        var flushes = 0
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settled: Set<String> = []
        var forgotten: [Set<String>] = []
        let pump = OfficeReportPump(seams: .init(
            sweep: { changed }, recordsWaiting: { waiting }, flush: { flushes += 1 },
            settled: { settled }, forget: { forgotten.append($0) }, clock: { now }))

        await pump.tick()
        XCTAssertEqual(flushes, 0, "nothing queued, nothing changed")
        waiting = true
        await pump.tick()
        XCTAssertEqual(flushes, 1, "records are waiting: they are offered")
        for _ in 0..<10 {
            now = now.addingTimeInterval(3)
            await pump.tick()
        }
        XCTAssertEqual(flushes, 1, "but not on every poll")
        now = now.addingTimeInterval(OfficeReportPump.retryInterval)
        await pump.tick()
        XCTAssertEqual(flushes, 2)
        // A receipt changed a report's standing: the queue is told at once.
        changed = true
        now = now.addingTimeInterval(3)
        await pump.tick()
        XCTAssertEqual(flushes, 3)
        changed = false

        // Documents the office now has are let go of, once.
        settled = ["a"]
        await pump.tick()
        await pump.tick()
        settled = ["a", "b"]
        await pump.tick()
        XCTAssertEqual(forgotten, [["a"], ["b"]])
    }

    // MARK: - Who the office is a destination for

    func testOnlyAPhoneThatJoinedAnOfficeAndHasNotBeenRemovedSendsThere() {
        XCTAssertTrue(OfficeReportSink.officeIsDestination(source: .office, revoked: false, transportAvailable: true))
        XCTAssertFalse(OfficeReportSink.officeIsDestination(source: .office, revoked: true, transportAvailable: true))
        XCTAssertFalse(OfficeReportSink.officeIsDestination(source: .office, revoked: false, transportAvailable: false))
        for source in ProfileSource.allCases where source != .office {
            XCTAssertFalse(OfficeReportSink.officeIsDestination(source: source, revoked: false, transportAvailable: true))
        }
        XCTAssertFalse(OfficeReportSink.officeIsDestination(source: nil, revoked: false, transportAvailable: true))
    }

    // MARK: - What a screen says

    func testTheSummaryCountsWhatIsStillOnItsWayAndSaysNothingOfSentOrDelivered() throws {
        func entry(_ id: String, outcome: OfficeReport.Outcome?, superseded: Bool = false) -> OfficeReportService.Entry {
            .init(operationID: id, reportID: id, recordKind: "workRecord", recordID: "s", enrolmentID: "e",
                  revision: 1, payload: Data(), signature: nil, recordSHA256: "", manifest: Data(), files: [:],
                  attachmentsPublished: [], published: nil, outcome: outcome, superseded: superseded, withdrawn: false)
        }
        var ledger = OfficeReportService.Ledger()
        ledger.entries = [entry("a", outcome: nil), entry("b", outcome: nil), entry("c", outcome: .evidencePending),
                          entry("d", outcome: .recordAccepted), entry("e", outcome: .fullyAccepted),
                          entry("f", outcome: nil, superseded: true)]
        let summary = OfficeReportService.summary(of: ledger)
        XCTAssertEqual(summary, .init(waiting: 2, evidencePending: 1))
        XCTAssertEqual(OfficeReportService.status(summary)?.title, "2 records for the office")
        XCTAssertEqual(OfficeReportService.status(.init(waiting: 0, evidencePending: 1))?.title, "The office has 1 record")
        XCTAssertNil(OfficeReportService.status(.init()))
        for state in [summary, .init(waiting: 1, evidencePending: 0), .init(waiting: 0, evidencePending: 3)] {
            let status = try XCTUnwrap(OfficeReportService.status(state))
            let words = (status.title + " " + (status.detail ?? "")).lowercased()
            for claim in ["sent", "delivered", "received by"] { XCTAssertFalse(words.contains(claim), words) }
        }
    }
}
