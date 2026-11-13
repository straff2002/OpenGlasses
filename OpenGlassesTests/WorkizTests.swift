import XCTest
import CryptoKit
@testable import OpenGlasses

private enum WorkizFixtures {
    static func data(_ name: String) throws -> Data {
        let url = Bundle(for: WorkizAPITests.self).url(forResource: "workiz-" + name, withExtension: "json", subdirectory: "workiz-v2")
        return try Data(contentsOf: XCTUnwrap(url))
    }
    static func jobs() throws -> [WorkizJob] {
        try WorkizAPI.page(data("jobs-page"), decode: WorkizAPI.job).data + WorkizAPI.page(data("jobs-last"), decode: WorkizAPI.job).data
    }
    static let now = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
    static let zone = TimeZone(secondsFromGMT: 0)!
    static func record() throws -> WorkRecord {
        var session = FieldSession(id: "workiz-session", vaultId: "test", assetId: nil, mode: .aiOnly,
            startedAt: now, outcome: .resolved, escalations: [], billableSeconds: 60)
        session.endedAt = now.addingTimeInterval(60)
        session.jobReference = "1234"
        session.jobFile = WorkizJobMapper.map(try WorkizAPI.job(data("job")), technicianID: "USR-jamie", now: now, timeZone: zone).provenance
        session.reportedBy = ReportIdentity(company: "Fixture Company", technician: .init(fullName: "Jamie Lee", shortName: "Jamie", technicianID: "LOCAL"))
        return WorkRecord(session: session, vaultName: "Fixture")
    }
}

final class WorkizAPITests: XCTestCase {
    func testFixedOriginAndBearerAndQueryAndCustomFieldsOnlyPUT() throws {
        let body = try WorkizWriteBack.body(fieldID: "CF-report", value: "safe report")
        let request = try WorkizAPI.request(.job("JOB-fixture1"), key: "fixture-secret", query: [.init(name: "page", value: "2")], method: "PUT", body: body)
        XCTAssertEqual(request.url?.absoluteString, "https://api.workiz.com/crm/api/v2/jobs/JOB-fixture1?page=2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(Set(try WorkizAPI.object(XCTUnwrap(request.httpBody)).keys), ["customFields"])
    }
    func testForbiddenWriteShapesAreRefused() throws {
        for (method, body) in [("DELETE", Data()), ("PUT", Data(#"{"status":"Done"}"#.utf8)), ("PUT", Data(#"{"customFields":[],"description":"overwrite"}"#.utf8))] {
            XCTAssertThrowsError(try WorkizAPI.request(.job("JOB-fixture1"), key: "fixture-key", method: method, body: body))
        }
        XCTAssertThrowsError(try WorkizAPI.request(.jobs, key: "fixture-key", method: "POST", body: Data(#"{}"#.utf8)))
    }
    func testPathAndHeaderInjectionRefused() {
        for path in ["JOB-../secret", "https://attacker.invalid", "JOB-a?key=x", "JOB-a/b", "JOB-"] {
            XCTAssertThrowsError(try WorkizAPI.request(.job(path), key: "key"))
        }
        for key in ["", "key\r\nInjected: yes", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try WorkizAPI.request(.users, key: key))
        }
    }
    func testSharedShapesUnknownFieldsAndCustomerEmailAndAttachmentURLsDiscarded() throws {
        let jobs = try WorkizFixtures.jobs()
        XCTAssertEqual(jobs.count, 6)
        XCTAssertEqual(jobs[0].client.name, "Morgan Smith")
        XCTAssertTrue(jobs[0].client.address.contains("Unit 2"))
        XCTAssertEqual(jobs[0].client.phone, "+64 21 555 0101")
        XCTAssertEqual(jobs[0].attachments, ["Fictional appliance label.jpg"])
        XCTAssertEqual(jobs[0].notes.count, 5)
        XCTAssertTrue(jobs[3].isCancelled); XCTAssertFalse(jobs[4].isOpen)
        XCTAssertEqual(try WorkizAPI.page(WorkizFixtures.data("users"), decode: WorkizAPI.user).data.count, 4)
        XCTAssertEqual(try WorkizAPI.page(WorkizFixtures.data("customfields"), decode: WorkizAPI.field).data.count, 2)
        XCTAssertEqual(try WorkizAPI.page(WorkizFixtures.data("client-notes"), decode: { WorkizAPI.note($0) }).data.count, 1)
        var object = try WorkizAPI.object(WorkizFixtures.data("job")); object["unknown"] = ["secret": "ignored"]
        XCTAssertEqual(WorkizAPI.job(object), jobs[0])
    }
    func testMalformedJobDroppedAndCountedAndStringsBounded() throws {
        var job = try WorkizAPI.object(WorkizFixtures.data("job"))
        job["name"] = String(repeating: "a", count: 5000)
        job["description"] = String(repeating: "b", count: 20_000)
        let data = try JSONSerialization.data(withJSONObject: ["hasMore": false, "data": [job, ["id": "oops"], 7]])
        let page = try WorkizAPI.page(data, decode: WorkizAPI.job)
        XCTAssertEqual(page.dropped, 2); XCTAssertEqual(page.data.count, 1)
        XCTAssertEqual(page.data[0].name.count, 1000); XCTAssertEqual(page.data[0].fault.count, 12_000)
    }
    func testOversizeAndInvalidPagesAndReportFieldsFailClosed() throws {
        XCTAssertThrowsError(try WorkizAPI.object(Data(repeating: 32, count: WorkizAPI.maximumBytes + 1)))
        XCTAssertThrowsError(try WorkizAPI.page(Data(#"{"data":[]}"#.utf8), decode: WorkizAPI.job))
        var object = try WorkizAPI.object(WorkizFixtures.data("job"))
        object["customFields"] = [["id": "CF-report", "value": String(repeating: "x", count: 60_001)]]
        XCTAssertNil(WorkizAPI.job(object))
    }
    func testJSONBooleansAndNumbersCannotSubstituteForOneAnother() throws {
        var row = try WorkizAPI.object(WorkizFixtures.data("job"))
        row["serialId"] = true
        XCTAssertNil(WorkizAPI.job(row))
        row["serialId"] = 1
        XCTAssertEqual(WorkizAPI.job(row)?.number, "1")
        let badPage = Data(#"{"data":[],"hasMore":1}"#.utf8)
        XCTAssertThrowsError(try WorkizAPI.page(badPage, decode: WorkizAPI.job))
        let user = try XCTUnwrap(WorkizAPI.user(["id": "USR-fixture", "name": "Fixture", "active": 1, "fieldTech": 1]))
        XCTAssertFalse(user.active)
        XCTAssertFalse(user.fieldTech)
    }
    func testStatusSentencesNeverUseServerBodyOrKey() throws {
        for code in [400, 401, 403, 429] { _ = try WorkizAPI.object(WorkizFixtures.data("error-" + String(code))) }
        XCTAssertNil(WorkizFailure.status(200, resource: "Jobs"))
        XCTAssertEqual(WorkizFailure.status(401, resource: "Jobs"), .badKey)
        XCTAssertEqual(WorkizFailure.status(403, resource: "Jobs"), .permission("Jobs"))
        XCTAssertEqual(WorkizFailure.status(429, resource: "Jobs"), .rateLimited)
        XCTAssertEqual(WorkizFailure.status(503, resource: "Jobs"), .unavailable)
        XCTAssertTrue(WorkizFailure.badKey.localizedDescription.contains("Paste the new key"))
        XCTAssertFalse(WorkizFailure.status(403, resource: "fixture-secret")!.localizedDescription.contains("fixture-secret"))
    }
}

@MainActor
final class WorkizMyJobsTests: XCTestCase {
    func testAssignedOpenWindowAndUnscheduledOnly() throws {
        let jobs = try WorkizFixtures.jobs()
        let selected = WorkizMyJobs.select(jobs, technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone)
        XCTAssertEqual(selected.map(\.id), ["JOB-fixture1", "JOB-fixture2", "JOB-fixture3"])
        XCTAssertEqual(WorkizMyJobs.select(jobs + jobs, technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone, cap: 2).count, 2)
        XCTAssertTrue(WorkizMyJobs.select(jobs, technicianID: "USR-nobody", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone).isEmpty)
    }
    func testBoundariesAndInvalidDatesAndAccountTimezone() throws {
        var root = try WorkizAPI.object(WorkizFixtures.data("job"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = WorkizFixtures.zone
        let start = calendar.startOfDay(for: WorkizFixtures.now)
        for (date, included) in [("2026-10-22 00:00:00", true), ("2026-10-30 23:59:59", true), ("2026-10-31 00:00:00", false), ("2026-10-21 23:59:59", false), ("bad", false)] {
            root["date"] = date
            let job = try XCTUnwrap(WorkizAPI.job(root))
            XCTAssertEqual(!WorkizMyJobs.select([job], technicianID: "USR-jamie", now: start, timeZone: WorkizFixtures.zone).isEmpty, included, date)
        }
        let nz = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        XCTAssertNotEqual(WorkizMyJobs.date("2026-10-23 10:00:00", timeZone: nz), WorkizMyJobs.date("2026-10-23 10:00:00", timeZone: WorkizFixtures.zone))
    }
    func testLatestPageSnapshotWinsWhenAJobChangesBetweenQueries() throws {
        let first = try WorkizAPI.job(WorkizFixtures.data("job"))
        var row = try WorkizAPI.object(WorkizFixtures.data("job"))
        row["team"] = [["id": "USR-other", "name": "Alex Rivera"]]
        let changed = try XCTUnwrap(WorkizAPI.job(row))
        XCTAssertTrue(WorkizMyJobs.select([first, changed], technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone).isEmpty)
    }
    func testQueriesIncludeScheduledAndAllCreatedUnscheduledScan() {
        let queries = WorkizMyJobs.queries(now: WorkizFixtures.now, timeZone: WorkizFixtures.zone)
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries[0].first { $0.name == "dateProperty" }?.value, "date")
        XCTAssertEqual(queries[1].first { $0.name == "dateOperator" }?.value, "prev")
    }
}

@MainActor
final class WorkizJobMapperTests: XCTestCase {
    func testMapsSnapshotExternalIDNewestFiveNotesAndNoDownloadURL() throws {
        let job = WorkizJobMapper.map(try WorkizAPI.job(WorkizFixtures.data("job")), technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone)
        XCTAssertEqual(job.origin, .connector); XCTAssertEqual(job.jobReference, "1234")
        XCTAssertEqual(job.faultReport?.source, .connector)
        XCTAssertTrue(job.faultReport?.text.contains("Refrigerator repair") == true)
        XCTAssertEqual(job.provenance?.external?.jobID, "JOB-fixture1")
        XCTAssertEqual(job.provenance?.external?.customerID, "CL-fixture1")
        XCTAssertEqual(job.provenance?.external?.technicianID, "USR-jamie")
        XCTAssertTrue(job.provenance?.recordLine.hasPrefix("From Workiz at") == true)
        XCTAssertFalse(job.notes?.contains("Instruction 0") == true)
        XCTAssertTrue(job.notes?.hasPrefix("Fictional Dispatcher · 2026-10-22 14") == true)
        XCTAssertFalse(job.attachments.joined().contains("https"))
    }
    func testReconcilePreservesTypedJobsAndStartedSnapshotAndPullStamp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UpcomingJobStore(directory: directory)
        let typed = UpcomingJob(jobReference: "local", origin: .typed, createdAt: WorkizFixtures.now)
        store.add(typed)
        var job = WorkizJobMapper.map(try WorkizAPI.job(WorkizFixtures.data("job")), technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone)
        store.reconcileWorkiz([job], at: WorkizFixtures.now, notice: "")
        let snapshot = job
        store.remove(id: job.id) // starting copies the value and removes it from ahead
        job.notes = "Changed later"
        store.reconcileWorkiz([], at: WorkizFixtures.now, notice: "Job 1234 was cancelled in Workiz.")
        XCTAssertNotEqual(snapshot.notes, job.notes)
        XCTAssertEqual(store.jobs, [typed])
        let reopened = UpcomingJobStore(directory: directory)
        XCTAssertEqual(reopened.workizLastPull, WorkizFixtures.now)
        XCTAssertTrue(reopened.workizNotice?.contains("cancelled") == true)
        reopened.removeWorkizJobs(); XCTAssertEqual(reopened.jobs, [typed]); XCTAssertNil(reopened.workizLastPull)
    }
    func testPullNeverAddsASecondJobUnderAnIdAnOfficeFileUpdateKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UpcomingJobStore(directory: directory)
        let pulled = WorkizJobMapper.map(try WorkizAPI.job(WorkizFixtures.data("job")), technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone)
        store.reconcileWorkiz([pulled], at: WorkizFixtures.now, notice: "")
        // "Update job 1234" from an office job file: same id, the file's provenance (no connector).
        var updated = pulled
        updated.provenance = JobFileProvenance(fileName: "job-1234.ogjob", signature: .unsigned, signer: nil,
                                               receivedAt: WorkizFixtures.now, digest: "fixture")
        updated.notes = "From the office file"
        store.update(updated, at: WorkizFixtures.now)
        // The next pull brings the same Workiz job back, twice over (both scans can list it).
        store.reconcileWorkiz([pulled, pulled], at: WorkizFixtures.now, notice: "")
        XCTAssertEqual(store.jobs.map(\.id), [pulled.id])
        XCTAssertEqual(store.jobs.first?.notes, "From the office file")
        XCTAssertEqual(Set(UpcomingJobStore(directory: directory).jobs.map(\.id)).count, 1)
    }
}

@MainActor
final class WorkizWriteBackTests: XCTestCase {
    func testDigestUsesExactWorkRecordBytesAndJQExternalIdentity() throws {
        let record = try WorkizFixtures.record()
        let report = try XCTUnwrap(WorkizWriteBack.report(record))
        let digest = SHA256.hash(data: record.json).prefix(4).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(report.marker, "Avenkin ref " + digest)
        XCTAssertTrue(report.text.contains("Jamie Lee")); XCTAssertTrue(report.text.contains("USR-jamie"))
        for forbidden in ["transcript", "fileUrl", "https://", "fixture@example", "LOCAL"] { XCTAssertFalse(report.text.contains(forbidden)) }
    }
    func testBlockReplaceAppendAndResendPreserveOtherWriters() throws {
        let job = try WorkizAPI.job(WorkizFixtures.data("job-two-blocks"))
        let existing = try XCTUnwrap(job.customFields["CF-report"])
        let report = WorkizWriteBack.Report(jobID: job.id, clientID: nil, marker: "Avenkin ref 01234567", text: "Avenkin ref 01234567\nReplacement phone visit.", noteHeading: "Visit", fieldName: "Field Assist report", clientNote: false)
        let merged = try WorkizWriteBack.merging(existing: existing, report: report)
        XCTAssertTrue(merged.hasPrefix("Dispatcher preamble stays.\n\n"))
        XCTAssertTrue(merged.hasSuffix("Avenkin ref 89abcdef\nOffice revisit."))
        XCTAssertFalse(merged.contains("Phone visit one."))
        XCTAssertEqual(try WorkizWriteBack.merging(existing: merged, report: report), merged)
        let next = try XCTUnwrap(WorkizWriteBack.report(WorkizFixtures.record()))
        let appended = try WorkizWriteBack.merging(existing: merged, report: next)
        XCTAssertTrue(appended.hasPrefix(merged)); XCTAssertEqual(try WorkizWriteBack.merging(existing: appended, report: next), appended)
    }
    func testDuplicateMarkersInjectedMarkerAndOversizeRefused() throws {
        let report = try XCTUnwrap(WorkizWriteBack.report(WorkizFixtures.record()))
        XCTAssertThrowsError(try WorkizWriteBack.merging(existing: report.text + "\n" + report.text, report: report))
        XCTAssertThrowsError(try WorkizWriteBack.merging(existing: String(repeating: "x", count: 60_001), report: report))
        let injection = WorkizWriteBack.Report(jobID: "JOB-fixture1", clientID: nil, marker: report.marker, text: report.text + "\nAvenkin ref abcdef01", noteHeading: "Visit", fieldName: "Field Assist report", clientNote: false)
        XCTAssertThrowsError(try WorkizWriteBack.merging(existing: "", report: injection))
    }
    func testFieldLookupRequiresExactUniqueLargeTextJobField() throws {
        let fields = try WorkizAPI.page(WorkizFixtures.data("customfields"), decode: WorkizAPI.field).data
        XCTAssertEqual(try WorkizWriteBack.field(fields, named: "Field Assist report").id, "CF-report")
        XCTAssertThrowsError(try WorkizWriteBack.field(fields, named: "missing"))
        XCTAssertThrowsError(try WorkizWriteBack.field(fields + fields, named: "Field Assist report"))
        XCTAssertThrowsError(try WorkizWriteBack.field(WorkizAPI.page(WorkizFixtures.data("customfields-missing"), decode: WorkizAPI.field).data, named: "Field Assist report"))
    }
}

@MainActor
private final class WorkizMemory {
    var data: Data?
    func connection() throws -> WorkizConnection {
        let connection = WorkizConnection(storage: .init(read: { self.data }, write: { self.data = $0 }, erase: { self.data = nil }, needsNewKey: { false }, setNeedsNewKey: { _ in }), licensed: { true })
        try connection.pasteKey("fixture-key", administrator: true)
        try connection.select(WorkizUser(id: "USR-jamie", name: "Jamie Lee", emailAddress: "", active: true, fieldTech: true))
        return connection
    }
}
@MainActor
private final class WorkizSpy: WorkizTransport {
    var requests: [URLRequest] = []
    var replies: [(Data, Int)] = []
    var failAfter: Int?
    var cancelled = false
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if requests.count == failAfter { throw WorkizFailure.offline }
        guard !replies.isEmpty else { throw WorkizFailure.malformed }
        return replies.removeFirst()
    }
    func cancel() { cancelled = true }
}

@MainActor
final class WorkizSyncSinkTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        PolicyEnvelope.clear()
        UserDefaults.standard.removeObject(forKey: "workizEnabled")
        UserDefaults.standard.removeObject(forKey: "workizClientNotes")
        UserDefaults.standard.removeObject(forKey: "workizReportFieldName")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { PolicyEnvelope.clear(); try? FileManager.default.removeItem(at: directory) }
    private func harness(notes: Bool = false) throws -> (OfflineQueue, WorkizConnection, WorkizSpy, WorkizSyncSink, QueuedOp) {
        let connection = try WorkizMemory().connection()
        let spy = WorkizSpy()
        let client = WorkizAPIClient(connection: connection, transport: { spy })
        let queue = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        let sink = WorkizSyncSink(queue: queue, connection: connection, client: client, fallback: LocalSyncSink(), now: { WorkizFixtures.now })
        let report = try XCTUnwrap(WorkizWriteBack.report(WorkizFixtures.record(), clientNote: notes))
        let op = QueuedOp(id: "delivery", kind: .workizReport, sessionId: "workiz-session", payload: try JSONEncoder().encode(WorkizDelivery(report: report)))
        queue.enqueue(op)
        return (queue, connection, spy, sink, op)
    }
    func testAmbiguousOrTruncatedCustomFieldsNeverProduceAPUT() async throws {
        let tooMany: [[String: Any]] = (0..<100).map { ["id": "CF-other\($0)", "value": "Other field"] }
            + [["id": "CF-report", "value": "Existing report must stay"]]
        let duplicate: [[String: Any]] = [["id": "CF-report", "value": "First report"], ["id": "CF-report", "value": "Second report"]]
        for fields in [tooMany as Any, duplicate as Any, "not an array" as Any] {
            let (_, _, spy, sink, op) = try harness()
            var job = try WorkizAPI.object(WorkizFixtures.data("job"))
            job["customFields"] = fields
            spy.replies = [(try WorkizFixtures.data("customfields"), 200), (try JSONSerialization.data(withJSONObject: job), 200)]
            let outcome = await sink.deliver(op)
            guard case .permanent = outcome else { XCTFail("ambiguous report snapshot was accepted"); continue }
            XCTAssertEqual(spy.requests.map(\.httpMethod), ["GET", "GET"])
        }
    }
    func testCustomFieldsOnlyPutAndDurableResendAndClientNoteOnce() async throws {
        let (queue, _, spy, sink, op) = try harness(notes: true)
        spy.replies = [(try WorkizFixtures.data("customfields"), 200), (try WorkizFixtures.data("job-two-blocks"), 200), (Data(), 200), (Data(#"{"hasMore":false,"data":[]}"#.utf8), 200), (Data(#"{"id":"CLN-created"}"#.utf8), 201)]
        let first = await sink.deliver(op); XCTAssertEqual(first, .done)
        let put = try XCTUnwrap(spy.requests.first { $0.httpMethod == "PUT" })
        let object = try WorkizAPI.object(XCTUnwrap(put.httpBody))
        XCTAssertEqual(Set(object.keys), ["customFields"])
        let value = try XCTUnwrap((object["customFields"] as? [[String: String]])?.first?["value"])
        XCTAssertTrue(value.contains("Office revisit.")); XCTAssertTrue(value.contains("Phone visit one."))
        let kept = try XCTUnwrap(queue.all().first)
        let again = await sink.deliver(kept); XCTAssertEqual(again, .done)
        XCTAssertEqual(spy.requests.filter { $0.httpMethod == "POST" }.count, 1)
        queue.mark(op.id, state: .done); queue.purgeDone(); XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(sink.status(sessionID: op.sessionId), "Sent to Workiz")
    }
    func testAmbiguousPostRelaunchFindsMarkerAndNeverPostsAgain() async throws {
        let (queue, connection, spy, sink, op) = try harness(notes: true)
        spy.replies = [(try WorkizFixtures.data("customfields"), 200), (try WorkizFixtures.data("job"), 200), (Data(), 200), (Data(#"{"hasMore":false,"data":[]}"#.utf8), 200)]
        spy.failAfter = 5
        let first = await sink.deliver(op); XCTAssertEqual(first, .transient(reason: "Waiting for a connection"))
        let reopened = OfflineQueue(path: directory.appendingPathComponent("queue.sqlite"))
        var kept = try XCTUnwrap(reopened.all().first)
        var progress = try JSONDecoder().decode(WorkizDelivery.self, from: kept.payload)
        XCTAssertTrue(progress.noteAttempted); XCTAssertTrue(progress.fieldWritten)
        progress.retryAfter = nil; kept.payload = try JSONEncoder().encode(progress)
        let marker = progress.report.marker
        let result = try JSONSerialization.data(withJSONObject: ["hasMore": false, "data": [["id": "CLN-found", "note": marker + "\nAccepted before timeout"]]])
        spy.replies = [(result, 200)]; spy.failAfter = nil
        let recovered = WorkizSyncSink(queue: queue, connection: connection, client: WorkizAPIClient(connection: connection, transport: { spy }), fallback: LocalSyncSink())
        let second = await recovered.deliver(kept); XCTAssertEqual(second, .done)
        XCTAssertEqual(spy.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testAuthPausesAcrossReopenUntilKeyGenerationChanges() async throws {
        for status in [401, 403] {
            let (queue, connection, spy, sink, op) = try harness()
            spy.replies = [(Data(), status)]
            _ = await sink.deliver(op)
            var kept = try XCTUnwrap(queue.all().first)
            _ = await sink.deliver(kept); XCTAssertEqual(spy.requests.count, 1)
            XCTAssertNotNil(try JSONDecoder().decode(WorkizDelivery.self, from: kept.payload).blockedGeneration)
            try connection.pasteKey("rotated-key", administrator: true)
            spy.replies = [(try WorkizFixtures.data("customfields"), 200), (try WorkizFixtures.data("job"), 200), (Data(), 200)]
            kept = try XCTUnwrap(queue.all().first)
            let result = await sink.deliver(kept); XCTAssertEqual(result, .done)
            queue.deleteAll()
        }
    }
    func testRateLimitBackoffPersistsAndDoesNotSpin() async throws {
        for code in [429, 503] {
            let (queue, _, spy, sink, op) = try harness()
            spy.replies = [(Data(), code)]
            let result = await sink.deliver(op); XCTAssertEqual(result, .transient(reason: "Waiting for a connection"))
            let kept = try XCTUnwrap(queue.all().first)
            _ = await sink.deliver(kept); XCTAssertEqual(spy.requests.count, 1)
            XCTAssertNotNil(try JSONDecoder().decode(WorkizDelivery.self, from: kept.payload).retryAfter)
            queue.deleteAll()
        }
    }
    func testOfficeRouteEndsPendingDeliveryWithoutAnyNetwork() async throws {
        let (queue, connection, spy, sink, op) = try harness()
        var result = ProfileApplier.Result(); result.ceilings[.organizationFieldServiceRoute] = .string("office")
        PolicyEnvelope.install(result, organizationName: "Office firm")
        let outcome = await sink.deliver(op)
        XCTAssertEqual(outcome, .permanent(reason: WorkizSyncSink.officeHandover)); XCTAssertTrue(spy.requests.isEmpty)
        XCTAssertFalse(connection.isRunning); XCTAssertEqual(sink.status(sessionID: op.sessionId), WorkizSyncSink.officeHandover)
        sink.endForOffice(); XCTAssertEqual(queue.all().first?.state, .failed)
        PolicyEnvelope.clear(); try connection.pasteKey("new-key", administrator: true)
        let ended = try XCTUnwrap(queue.all().first)
        let retry = await sink.deliver(ended)
        XCTAssertEqual(retry, .permanent(reason: WorkizSyncSink.officeHandover)); XCTAssertTrue(spy.requests.isEmpty)
    }
    func testExplicitResendRearmsFailedDeliveryAndRetainsAttemptReceipt() throws {
        let (queue, _, _, sink, _) = try harness()
        queue.deleteAll()
        let record = try WorkizFixtures.record(); sink.enqueue(record)
        let op = try XCTUnwrap(queue.all().first)
        var delivery = try JSONDecoder().decode(WorkizDelivery.self, from: op.payload)
        delivery.noteAttempted = true
        XCTAssertTrue(queue.replacePayload(op.id, data: try JSONEncoder().encode(delivery)))
        queue.mark(op.id, state: .failed, attempts: 6)
        sink.enqueue(record)
        let retried = try XCTUnwrap(queue.all().first)
        XCTAssertEqual(retried.state, .pending); XCTAssertEqual(retried.attempts, 0)
        XCTAssertTrue(try JSONDecoder().decode(WorkizDelivery.self, from: retried.payload).noteAttempted)
    }
    func testPageBudgetNeverReturnsPartialList() async throws {
        let connection = try WorkizMemory().connection(); let spy = WorkizSpy()
        let page = Data(#"{"hasMore":true,"data":[]}"#.utf8)
        spy.replies = Array(repeating: (page, 200), count: WorkizAPI.pageBudget)
        do { let _: [WorkizJob] = try await WorkizAPIClient(connection: connection, transport: { spy }).pages(.jobs, decode: WorkizAPI.job); XCTFail("partial list") }
        catch { XCTAssertEqual(error as? WorkizFailure, .pageBudget) }
        XCTAssertEqual(spy.requests.count, WorkizAPI.pageBudget)
    }
}

@MainActor
final class WorkizRouteTests: XCTestCase {
    override func tearDown() { PolicyEnvelope.clear() }
    func testRefreshFiltersStartedJobsAndExplainsCancellationWithoutChangingOtherJobs() async throws {
        let connection = try WorkizMemory().connection(); let spy = WorkizSpy()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UpcomingJobStore(directory: folder)
        let jobs = try WorkizFixtures.jobs()
        store.add(WorkizJobMapper.map(jobs[3], technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone))
        let typed = UpcomingJob(jobReference: "local", origin: .typed, createdAt: WorkizFixtures.now); store.add(typed)
        spy.replies = [(try WorkizFixtures.data("jobs-page"), 200), (try WorkizFixtures.data("jobs-last"), 200), (try WorkizFixtures.data("jobs-page"), 200), (try WorkizFixtures.data("jobs-last"), 200)]
        let client = WorkizAPIClient(connection: connection, transport: { spy })
        let controller = WorkizController(connection: connection, jobs: store, client: client, started: { ["JOB-fixture1"] })
        await controller.refresh(force: true, now: WorkizFixtures.now)
        XCTAssertEqual(Set(store.jobs.compactMap { $0.provenance?.external?.jobID }), ["JOB-fixture2", "JOB-fixture3"])
        XCTAssertTrue(store.jobs.contains(typed)); XCTAssertTrue(store.workizNotice?.contains("1237 was cancelled") == true)
    }
    func testExpiredLicenceStopsTheNextRequestWithoutDeletingTheKey() async throws {
        var saved: Data?
        var licensed = true
        let connection = WorkizConnection(storage: .init(read: { saved }, write: { saved = $0 }, erase: { saved = nil }, needsNewKey: { false }, setNeedsNewKey: { _ in }), licensed: { licensed })
        try connection.pasteKey("fixture-key", administrator: true)
        let spy = WorkizSpy()
        spy.replies = [(try WorkizFixtures.data("users"), 200), (try WorkizFixtures.data("users"), 200)]
        let client = WorkizAPIClient(connection: connection, transport: { spy })
        _ = try await client.get(.users)
        licensed = false
        do { _ = try await client.get(.jobs); XCTFail("expired licence reached Workiz") }
        catch { XCTAssertEqual(error as? WorkizFailure, .disabled) }
        XCTAssertEqual(spy.requests.count, 1)
        XCTAssertFalse(connection.isRunning)
        XCTAssertNotNil(connection.credential)
        licensed = true
        _ = try await client.get(.users)
        XCTAssertEqual(spy.requests.count, 2)
    }
    func testMedicalLocalOnlyStopsRequestsBeforeTransport() async throws {
        let previous = MedicalEgressGuard.currentMode; defer { MedicalEgressGuard.currentMode = previous }
        MedicalEgressGuard.currentMode = { .localOnly }
        let connection = try WorkizMemory().connection(); let spy = WorkizSpy()
        let client = WorkizAPIClient(connection: connection, transport: { spy })
        do { _ = try await client.get(.jobs); XCTFail("medical egress") } catch { XCTAssertTrue(error is MedicalEgressRefusal) }
        XCTAssertTrue(spy.requests.isEmpty)
    }
    func testOfficeIsTheOnlyTighteningValueAndNoSecretCanBeProfiled() {
        for value in [ProfileValue.string("direct"), .string(""), .bool(false)] {
            let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "N", issued: Date(), leaseDays: 30,
                settings: ["organizationFieldServiceRoute": RawSetting(value, .ceiling)])
            let applied = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
            XCTAssertNil(applied.ceilings[.organizationFieldServiceRoute]); XCTAssertEqual(applied.drops.count, 1)
        }
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "N", issued: Date(), leaseDays: 30,
            settings: ["organizationFieldServiceRoute": RawSetting(.string("office"), .ceiling)])
        XCTAssertEqual(ProfileApplier.apply(profile: profile, resolvableVaultIds: []).ceilings[.organizationFieldServiceRoute], .string("office"))
        XCTAssertNil(SettingKey(rawValue: WorkizConnection.keychainAccount))
        XCTAssertEqual(NetworkRoute.workizAPI.medicalPolicy, .blockedWhenLocalOnly)
        XCTAssertTrue(NetworkRoute.workizAPI.dataClasses.contains(.credential))
    }
    func testVerifiedRouteErasesKeyAndChoiceAndUnstartedJobsAndAbsenceDoesNotRestore() throws {
        let memory = WorkizMemory(); let connection = try memory.connection()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UpcomingJobStore(directory: folder)
        store.add(WorkizJobMapper.map(try WorkizAPI.job(WorkizFixtures.data("job")), technicianID: "USR-jamie", now: WorkizFixtures.now, timeZone: WorkizFixtures.zone))
        let typed = UpcomingJob(origin: .typed); store.add(typed)
        let controller = WorkizController(connection: connection, jobs: store)
        var policy = ProfileApplier.Result(); policy.ceilings[.organizationFieldServiceRoute] = .string("office")
        PolicyEnvelope.install(policy, organizationName: "N"); controller.enforceRoute()
        XCTAssertNil(memory.data); XCTAssertNil(connection.credential); XCTAssertEqual(store.jobs, [typed])
        PolicyEnvelope.clear(); XCTAssertFalse(connection.isRunning)
    }
    func testManagedKeyNeedsAdministratorAndRemovalErrorsStopConnection() throws {
        let memory = WorkizMemory(); let connection = try memory.connection()
        PolicyEnvelope.install(.init(), organizationName: "N")
        XCTAssertThrowsError(try connection.pasteKey("new-key", administrator: false))
        try connection.pasteKey("new-key", administrator: true)
        XCTAssertEqual(connection.credential?.key, "new-key")
        XCTAssertEqual(connection.credential?.technicianID, "USR-jamie")
        let failing = WorkizConnection(storage: .init(read: { memory.data }, write: { _ in }, erase: { throw WorkizFailure.offline }), licensed: { true })
        XCTAssertThrowsError(try failing.remove()); XCTAssertFalse(failing.isRunning)
    }
    func testSignedCheckInOnOffAndLegacyAbsentAndNestedUnknownDuplicateRefused() throws {
        for state in ["on", "off"] {
            let data = try OfficeCheckInFixtures.data("office-check-in-workiz-" + state + "-v1")
            let value = try OfficeCheckIn.checkIn(data, phoneApplicationKey: OfficeCheckInFixtures.phone().publicKey.rawRepresentation)
            XCTAssertEqual(value.fsmDirect, .init(system: "workiz", state: state))
        }
        XCTAssertNil(try OfficeCheckIn.checkIn(OfficeCheckInFixtures.data("office-check-in-v1"), phoneApplicationKey: OfficeCheckInFixtures.phone().publicKey.rawRepresentation).fsmDirect)
        let raw = try OfficeCheckInFixtures.payload("office-check-in-workiz-on-v1")
        for replacement in [#""fsmDirect":{"system":"workiz","state":"on","extra":"x"}"#, #""fsmDirect":{"system":"workiz","state":"on","state":"off"}"#, #""fsmDirect":{"system":"workiz","state":"unknown"}"#] {
            let string = try XCTUnwrap(String(data: raw, encoding: .utf8))
            let bad = string.replacingOccurrences(of: #""fsmDirect":{"system":"workiz","state":"on"}"#, with: replacement)
            XCTAssertNotEqual(bad, string)
            let envelope = try OfficeCheckInFixtures.signed(Data(bad.utf8), domain: OfficeCheckIn.checkInDomain, by: OfficeCheckInFixtures.phone())
            XCTAssertThrowsError(try OfficeCheckIn.checkIn(envelope, phoneApplicationKey: OfficeCheckInFixtures.phone().publicKey.rawRepresentation))
        }
    }
}
