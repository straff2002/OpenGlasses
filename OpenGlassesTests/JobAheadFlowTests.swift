import XCTest
@testable import OpenGlasses

/// Plan FO P3c through the guided flow, against real services: a real `FieldSessionService` on a
/// temp root, a real `ConversationStore`, a real `UpcomingJobStore`, and the bundled refrigeration
/// vault. Speech is the only seam — what is asserted is what the app says, what it writes, and
/// what it does not.
@MainActor
final class JobAheadFlowTests: XCTestCase {

    private var root: URL!
    private var service: FieldSessionService!
    private var conversations: ConversationStore!
    private var upcoming: UpcomingJobStore!
    private var flow: GuidedJobFlow!
    private var spoken: [String] = []
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobAheadFlow-\(UUID().uuidString)", isDirectory: true)
        for folder in ["sessions", "store", "upcoming"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                     withIntermediateDirectories: true)
        }
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        build()
    }

    override func tearDown() {
        flow = nil
        service = nil
        conversations = nil
        upcoming = nil
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// Everything a cold launch rebuilds, from the same directories.
    private func build() {
        service = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions"))
        conversations = ConversationStore(directory: root.appendingPathComponent("store"))
        upcoming = UpcomingJobStore(directory: root.appendingPathComponent("upcoming"))
        flow = GuidedJobFlow(sessions: service, store: conversations, seams: .init(
            speak: { [weak self] line in self?.spoken.append(line) },
            persistenceEnabled: { true }))
        flow.connectUpcoming(upcoming)
    }

    private func jobAhead(reference: String? = "1007", fault: String? = "No heat, display shows E200") -> UpcomingJob {
        var job = UpcomingJob(jobReference: reference,
                              site: JobSite(customer: "Smith & Co", address: "14 Smith Street"),
                              faultReport: fault.map { FaultReport(text: $0, source: .jobFile) },
                              equipment: [KnownEquipment(model: "Lennox SLP99")],
                              origin: .jobFile)
        job.provenance = JobFileProvenance(fileName: "1007.ogjob", signature: .signed,
                                           signer: "Smith Refrigeration", digest: "abc")
        return job
    }

    private func auditKinds(sessionId: String) -> [SessionLogger.Event.Kind] {
        SessionLogger.readEvents(at: root.appendingPathComponent("sessions")
            .appendingPathComponent(sessionId, isDirectory: true)).map(\.kind)
    }

    // MARK: - A job ahead is not a session

    func testAJobAheadCountsNoTimeAndIsNotRestoredAsTheOpenJob() throws {
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead()))
        XCTAssertNil(service.activeSession)
        XCTAssertTrue(service.history.isEmpty, "a job ahead is not a session, so it has no clock")

        build()   // a cold launch
        XCTAssertNil(service.activeSession, "the launch restore must never reopen a job ahead")
        XCTAssertEqual(upcoming.job(id: job.id)?.jobReference, "1007")
    }

    // MARK: - Starting one on site

    func testAStartedJobAheadKeepsItsNumberSiteFaultReportBriefAndProvenance() throws {
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead()))
        flow.assembleBrief(jobId: job.id, vaultId: "refrigeration")

        let session = try flow.startUpcomingJob(id: job.id, vaultId: "refrigeration")
        XCTAssertEqual(session.jobReference, "1007")
        XCTAssertEqual(session.jobIntake, .recorded(reference: "1007"), "the intake has its number")
        XCTAssertEqual(session.site?.address, "14 Smith Street")
        XCTAssertEqual(session.faultReport?.text, "No heat, display shows E200")
        XCTAssertNotNil(session.brief)
        XCTAssertEqual(session.jobFile?.signer, "Smith Refrigeration")
        XCTAssertNil(session.equipment, "the office's model is not a recognition; the machine is identified on site")
        XCTAssertTrue(session.tasks.isEmpty, "nothing about a job ahead becomes a task")
        XCTAssertNil(upcoming.job(id: job.id), "it is the job now, not a job ahead")
        XCTAssertTrue(auditKinds(sessionId: session.id).contains(.jobAheadStarted))
    }

    func testAJobAheadWithNoNumberIsAskedForOneLikeAnyOtherJob() throws {
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead(reference: nil)))
        let session = try flow.startUpcomingJob(id: job.id, vaultId: "refrigeration")
        XCTAssertEqual(session.jobIntake, .needsReference)
        XCTAssertEqual(GuidedJobFlow.startedLine(for: job), "Started Smith & Co, 14 Smith Street.")
    }

    func testTheStartedLineSaysTheNumberBack() {
        XCTAssertEqual(GuidedJobFlow.startedLine(for: jobAhead()),
                       "Starting job 1007 at Smith & Co, 14 Smith Street.")
    }

    func testAJobAheadCannotStartOverAnOpenJobAndStaysOnTheList() throws {
        _ = try flow.startJob(vaultId: "refrigeration", jobReference: "1006")
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead()))
        XCTAssertThrowsError(try flow.startUpcomingJob(id: job.id, vaultId: "refrigeration"))
        XCTAssertNotNil(upcoming.job(id: job.id))
        XCTAssertEqual(service.activeSession?.jobReference, "1006")
    }

    func testAnUnknownJobAheadIsSaidToBeGone() {
        XCTAssertThrowsError(try flow.startUpcomingJob(id: "nope", vaultId: "refrigeration")) { error in
            XCTAssertEqual(error as? UpcomingJobError, .notFound)
        }
    }

    // MARK: - The brief, against the bundled vault

    func testTheBriefReadsTheBundledVaultsCodeTableAndIsSavedOnTheJob() throws {
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead()))
        let brief = try XCTUnwrap(flow.assembleBrief(jobId: job.id, vaultId: "refrigeration"))
        let candidates = brief.section(.faultCandidates).items
        let lennox = try XCTUnwrap(candidates.first { $0.text.hasPrefix("E200:") })
        XCTAssertTrue(lennox.text.contains("Low refrigerant pressure"))
        XCTAssertTrue(lennox.citation.contains("error_codes.md"))
        XCTAssertTrue(lennox.citation.contains("Lennox"), "the row under this job's make ranks first")
        XCTAssertEqual(upcoming.job(id: job.id)?.brief, brief)
    }

    func testBriefingAloudSpeaksThroughTheApp() async throws {
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead()))
        let spokenOK = await flow.briefAloud(jobId: job.id)
        XCTAssertTrue(spokenOK)
        XCTAssertTrue(spoken.last?.hasPrefix("Brief for Job 1007.") == true)
        let more = await flow.moreOfBrief(jobId: job.id, request: "say more about the fault")
        XCTAssertNotNil(more)
        XCTAssertTrue(more?.hasPrefix("The fault report:") == true)
    }

    func testALockedOrMissingVaultContributesNothingButTheBriefStillCites() throws {
        let job = try XCTUnwrap(flow.addUpcomingJob(jobAhead()))
        let brief = try XCTUnwrap(flow.assembleBrief(jobId: job.id, vaultId: "no-such-vault"))
        XCTAssertTrue(brief.faultUnmatched)
        for item in brief.allItems { XCTAssertFalse(item.citation.isEmpty) }
    }

    func testWithoutAStoreNothingIsRecorded() {
        let bare = GuidedJobFlow(sessions: service, store: conversations)
        XCTAssertNil(bare.addUpcomingJob(jobAhead()))
    }
}
