import XCTest
@testable import OpenGlasses

/// Plan FO P3c — the job ahead: its value, its store, what it carries onto the record, the car's
/// list, the maps preference table, and the Info.plist entries the whole thing depends on.
@MainActor
final class JobAheadTests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobAheadTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func job(_ id: String, reference: String? = nil, scheduled: Date? = nil,
                     created: Date? = nil, address: String? = nil) -> UpcomingJob {
        UpcomingJob(id: id, jobReference: reference, site: JobSite(address: address),
                    scheduledFor: scheduled, origin: .typed, createdAt: created ?? now)
    }

    // MARK: - The value

    func testNothingIsFilledInAndBlanksAreAbsent() {
        let bare = UpcomingJob(jobReference: "  ", site: JobSite(customer: " ", address: ""),
                               faultReport: FaultReport(text: "  ", source: .typed),
                               equipment: [KnownEquipment()], notes: "\n", origin: .spoken)
        XCTAssertNil(bare.jobReference)
        XCTAssertTrue(bare.site.isEmpty)
        XCTAssertNil(bare.faultReport)
        XCTAssertTrue(bare.equipment.isEmpty)
        XCTAssertNil(bare.notes)
        XCTAssertEqual(bare.title, "Upcoming job", "never blank")
    }

    func testTheNumberIsKeptExactlyAsGiven() {
        XCTAssertEqual(job("a", reference: " wo-1007/b ").jobReference, "wo-1007/b")
    }

    func testAJobAheadDecodesWithOnlyItsRequiredKeys() throws {
        let json = #"{"id":"x","created_at":"2026-09-20T09:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UpcomingJob.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.origin, .typed)
        XCTAssertTrue(decoded.equipment.isEmpty)
        XCTAssertEqual(decoded.updatedAt, decoded.createdAt)
    }

    func testALegacySessionDecodesWithoutAnyJobAheadFields() throws {
        let legacy = """
        {"id":"s1","vaultId":"refrigeration","mode":"ai_only","startedAt":0,"outcome":"resolved"}
        """
        let session = try JSONDecoder().decode(FieldSession.self, from: Data(legacy.utf8))
        XCTAssertNil(session.site)
        XCTAssertNil(session.faultReport)
        XCTAssertNil(session.brief)
        XCTAssertNil(session.jobFile)
    }

    func testAJobAheadsFactsRoundTripThroughTheSession() throws {
        var session = FieldSession(id: "s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: now, endedAt: nil, pausedAt: nil, resumedAt: nil,
                                   outcome: .inProgress, startLocation: nil, endLocation: nil,
                                   escalations: [], billableSeconds: 0)
        session.site = JobSite(customer: "Smith & Co", address: "14 Smith St")
        session.faultReport = FaultReport(text: "No heat", source: .jobFile, receivedAt: now)
        session.jobFile = JobFileProvenance(fileName: "1007.ogjob", signature: .signed,
                                            signer: "Smith Refrigeration", receivedAt: now, digest: "ab")
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(FieldSession.self, from: data), session)
    }

    func testAnUnsignedFileNeverRecordsASigner() {
        let provenance = JobFileProvenance(fileName: "f.ogjob", signature: .unsigned,
                                           signer: "Claims To Be The Office", digest: "x")
        XCTAssertNil(provenance.signer)
        XCTAssertFalse(provenance.recordLine.contains("Claims To Be"))
    }

    // MARK: - The record

    func testTheRecordSaysWhatWasKnownBeforeTheVisitAsReportedNotFound() {
        var session = FieldSession(id: "s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: now, endedAt: now, pausedAt: nil, resumedAt: nil,
                                   outcome: .resolved, startLocation: nil, endLocation: nil,
                                   escalations: [], billableSeconds: 60)
        session.jobReference = "1007"
        let plain = WorkRecord(session: session, vaultName: "Refrigeration").summaryLines

        session.site = JobSite(customer: "Smith & Co", address: "14 Smith St")
        session.faultReport = FaultReport(text: "No heat", source: .jobFile, receivedAt: now)
        session.jobFile = JobFileProvenance(fileName: "1007.ogjob", signature: .unsigned, signer: nil,
                                            receivedAt: now, digest: "ab")
        let record = WorkRecord(session: session, vaultName: "Refrigeration")
        XCTAssertEqual(record.summaryLines[1], "Site: Smith & Co, 14 Smith St.")
        XCTAssertEqual(record.summaryLines[2],
                       "Reported fault (from the job file, not a finding): \u{201C}No heat\u{201D}")
        XCTAssertTrue(record.summaryLines[3].hasPrefix("Job file 1007.ogjob, opened "))
        XCTAssertEqual(record.summaryLines.count, plain.count + 3, "three lines added, nothing else moved")
        XCTAssertTrue(record.jsonString.contains("\"fault_report\""))
        XCTAssertFalse(WorkRecord(session: FieldSession(id: "s2", vaultId: "v", assetId: nil, mode: .aiOnly,
                                                        startedAt: now, endedAt: now, pausedAt: nil,
                                                        resumedAt: nil, outcome: .resolved, startLocation: nil,
                                                        endLocation: nil, escalations: [], billableSeconds: 0),
                                  vaultName: "V").jsonString.contains("fault_report"),
                       "a job born on site writes no new keys")
    }

    func testTheCustomerSummaryNeverCarriesTheFaultReport() {
        var session = FieldSession(id: "s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: now, endedAt: now, pausedAt: nil, resumedAt: nil,
                                   outcome: .resolved, startLocation: nil, endLocation: nil,
                                   escalations: [], billableSeconds: 60)
        session.faultReport = FaultReport(text: "Tenant says the landlord broke it", source: .jobFile)
        let lines = WorkRecord(session: session, vaultName: "Refrigeration").customerSummaryLines
        XCTAssertFalse(lines.joined().contains("landlord"))
    }

    // MARK: - The store

    func testScheduledJobsComeFirstSoonestFirstThenTheRestInArrivalOrder() {
        let store = UpcomingJobStore(directory: directory)
        store.add(job("late", scheduled: now.addingTimeInterval(7_200)))
        store.add(job("loose2", created: now.addingTimeInterval(20)))
        store.add(job("soon", scheduled: now.addingTimeInterval(600)))
        store.add(job("loose1", created: now.addingTimeInterval(10)))
        XCTAssertEqual(store.jobs.map(\.id), ["soon", "late", "loose1", "loose2"])
        XCTAssertEqual(store.next?.id, "soon")
    }

    func testTheStoreSurvivesARelaunch() {
        let store = UpcomingJobStore(directory: directory)
        store.add(job("a", reference: "1007", address: "14 Smith St"))
        let reopened = UpcomingJobStore(directory: directory)
        XCTAssertEqual(reopened.jobs.map(\.id), ["a"])
        XCTAssertEqual(reopened.jobs.first?.site.address, "14 Smith St")
    }

    func testTheCapPushesOutTheOldestUnscheduledJobNeverAScheduledOne() {
        let store = UpcomingJobStore(directory: directory)
        store.add(job("booked", scheduled: now, created: now.addingTimeInterval(-10_000)))
        for index in 0..<UpcomingJobStore.entryCap {
            store.add(job("j\(index)", created: now.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(store.jobs.count, UpcomingJobStore.entryCap)
        XCTAssertNotNil(store.job(id: "booked"))
        XCTAssertNil(store.job(id: "j0"))
    }

    func testUpdateKeepsIdentityAndRemoveTakesItOff() {
        let store = UpcomingJobStore(directory: directory)
        store.add(job("a", reference: "1007"))
        var changed = store.job(id: "a")!
        changed.notes = "Gate code 4411"
        store.update(changed, at: now.addingTimeInterval(60))
        XCTAssertEqual(store.job(id: "a")?.notes, "Gate code 4411")
        XCTAssertEqual(store.job(id: "a")?.updatedAt, now.addingTimeInterval(60))
        XCTAssertEqual(store.jobs(reference: "1007").count, 1)
        XCTAssertNotNil(store.remove(id: "a"))
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testTheFileIsExcludedFromBackupAsTheRegistrySays() throws {
        let store = UpcomingJobStore(directory: directory)
        store.add(job("a"))
        let url = directory.appendingPathComponent("upcoming-jobs.json")
        let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        XCTAssertEqual(excluded, SensitiveStore.upcomingJobs.record.backupExcluded)
        XCTAssertTrue(excluded)
    }

    // MARK: - The car's list

    func testJobsAheadSitBetweenTheOpenJobAndTheFinishedOnes() {
        var open = FieldSession(id: "open", vaultId: "v", assetId: nil, mode: .aiOnly, startedAt: now,
                                endedAt: nil, pausedAt: nil, resumedAt: nil, outcome: .inProgress,
                                startLocation: nil, endLocation: nil, escalations: [], billableSeconds: 0)
        open.jobReference = "1006"
        let done = FieldSession(id: "done", vaultId: "v", assetId: nil, mode: .aiOnly,
                                startedAt: now.addingTimeInterval(-86_400), endedAt: now, pausedAt: nil,
                                resumedAt: nil, outcome: .resolved, startLocation: nil, endLocation: nil,
                                escalations: [], billableSeconds: 0)
        let rows = CarPlayJobsList.rows(active: open, history: [open, done], boundThreadId: nil,
                                        upcoming: [job("u", reference: "1007")])
        XCTAssertEqual(rows.map(\.title), ["Job 1006", "Job 1007", "No job number"])
        XCTAssertEqual(rows[1].selection, .openUpcomingJob(id: "u"))
        XCTAssertTrue(rows[1].detail.hasPrefix("Upcoming"))
    }

    func testTheCarNeverShowsAFaultReportOrAContact() {
        var ahead = job("u", reference: "1007", address: "14 Smith St")
        ahead.site.contact = "Jo, 021 555 0100"
        ahead.faultReport = FaultReport(text: "No heat, E200", source: .typed)
        let row = CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, upcoming: [ahead])[0]
        XCTAssertFalse(row.spoken.contains("021"))
        XCTAssertFalse(row.spoken.contains("E200"))
    }

    func testDirectionsAreOfferedOnlyWithAnAddress() {
        XCTAssertEqual(CarPlayJobsList.upcomingActions(for: job("u")), [.brief(jobId: "u")])
        XCTAssertEqual(CarPlayJobsList.upcomingActions(for: job("u", address: "14 Smith St")),
                       [.brief(jobId: "u"), .directions(jobId: "u")])
    }

    // MARK: - Maps

    func testThePreferredAppIsUsedWhenItIsInstalled() throws {
        let waze = try XCTUnwrap(MapsHandoff.plan(destination: "14 Smith St", preferred: .waze,
                                                  isInstalled: { _ in true }))
        XCTAssertEqual(waze.app, .waze)
        XCTAssertEqual(waze.url.scheme, "waze")
        XCTAssertNil(waze.unavailable)
        let google = try XCTUnwrap(MapsHandoff.plan(destination: "14 Smith St", preferred: .google,
                                                    isInstalled: { _ in true }))
        XCTAssertEqual(google.url.absoluteString, "comgooglemaps://?daddr=14%20Smith%20St&directionsmode=driving")
    }

    func testAMissingAppFallsBackToAppleMapsAndSaysSo() throws {
        for preferred in [MapsApp.google, .waze] {
            let handoff = try XCTUnwrap(MapsHandoff.plan(destination: "14 Smith St", preferred: preferred,
                                                         isInstalled: { $0 == .apple }))
            XCTAssertEqual(handoff.app, .apple)
            XCTAssertEqual(handoff.unavailable, preferred)
            XCTAssertTrue(handoff.spoken.hasPrefix("\(preferred.label) isn't installed"))
        }
    }

    func testAppleMapsNeedsNoInstallCheck() throws {
        let handoff = try XCTUnwrap(MapsHandoff.plan(destination: "14 Smith St", preferred: .apple,
                                                     isInstalled: { _ in false }))
        XCTAssertEqual(handoff.app, .apple)
        XCTAssertEqual(handoff.url.absoluteString, "maps://?daddr=14%20Smith%20St&dirflg=d")
        XCTAssertEqual(handoff.spoken, "Opening driving directions to 14 Smith St in Apple Maps.")
    }

    func testWazeWalkingFallsBackBecauseWazeOnlyDrives() throws {
        let handoff = try XCTUnwrap(MapsHandoff.plan(destination: "14 Smith St", mode: .walking,
                                                     preferred: .waze, isInstalled: { _ in true }))
        XCTAssertEqual(handoff.app, .apple)
        XCTAssertEqual(handoff.reason, .drivingOnly)
    }

    func testAnAmpersandInAnAddressCannotSplitTheQuery() throws {
        let handoff = try XCTUnwrap(MapsHandoff.plan(destination: "Smith & Sons, Unit 4#2", preferred: .apple,
                                                     isInstalled: { _ in true }))
        XCTAssertFalse(handoff.url.absoluteString.contains("& "))
        XCTAssertTrue(handoff.url.absoluteString.contains("%26"))
        XCTAssertTrue(handoff.url.absoluteString.contains("%23"))
    }

    func testNoDestinationNoHandoff() {
        XCTAssertNil(MapsHandoff.plan(destination: "  ", preferred: .apple, isInstalled: { _ in true }))
    }

    func testASpokenAppNameIsRecognised() {
        XCTAssertEqual(MapsApp(spoken: "Waze"), .waze)
        XCTAssertEqual(MapsApp(spoken: "google maps"), .google)
        XCTAssertNil(MapsApp(spoken: "the usual"))
    }

    // MARK: - Info.plist

    private var infoPlist: [String: Any] {
        get throws {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("OpenGlasses/Info.plist")
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
    }

    /// iOS honours only the first fifty `LSApplicationQueriesSchemes` entries; anything after them
    /// silently answers "not installed". Found by P3c with fifty-two listed — LINE and Zalo were
    /// already dead — and the maps schemes must be inside the fifty or the fallback always fires.
    func testTheQuerySchemesFitTheFiftyIOSHonoursAndIncludeTheMapsApps() throws {
        let schemes = try XCTUnwrap(try infoPlist["LSApplicationQueriesSchemes"] as? [String])
        XCTAssertLessThanOrEqual(schemes.count, 50)
        XCTAssertEqual(Set(schemes).count, schemes.count, "no duplicates")
        for app in MapsApp.allCases {
            guard let scheme = app.probeURL?.scheme else { continue }
            XCTAssertTrue(schemes.prefix(50).contains(scheme), "\(scheme) must be within the first fifty")
        }
    }

    func testTheJobFileTypeIsDeclaredAndOpensAsACopy() throws {
        let plist = try infoPlist
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let type = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == JobFile.typeIdentifier })
        let tags = try XCTUnwrap(type["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], [JobFile.fileExtension])
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertTrue(documents.contains {
            ($0["LSItemContentTypes"] as? [String])?.contains(JobFile.typeIdentifier) == true
        })
        XCTAssertEqual(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool, false)
    }
}
