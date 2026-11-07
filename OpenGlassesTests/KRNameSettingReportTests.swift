import XCTest
@testable import OpenGlasses

/// Plan KR P6 — the name, the setting and the report say what they mean.
///
/// The partner's rename was stored and never reached the job's title; the report said
/// "Vault-only" only when it was on; two jobs in one conversation each printed all of it, and the
/// first claimed the second one's AI turns; and a "figure presented" line never said where the page
/// went. Headless, with invented jobs, names and turns.

// MARK: - The title rule (pure)

final class KRJobTitleRuleTests: XCTestCase {

    func testANameFollowsTheReference() {
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", name: "Boiler swap", equipment: "QX100"),
                       "Job 4410 — Boiler swap", "the name stands in for the machine")
    }

    func testANameThatStartsWithTheReferenceStandsAlone() {
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", name: "4410 boiler swap", equipment: nil),
                       "4410 boiler swap")
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", name: "Job 4410 roof unit", equipment: nil),
                       "Job 4410 roof unit")
        XCTAssertEqual(JobThreadTitle.title(reference: "J-77", name: "j-77: kitchen", equipment: nil), "j-77: kitchen",
                       "ignoring case")
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", name: "44105 boiler", equipment: nil),
                       "Job 4410 — 44105 boiler", "a longer number is not the reference")
    }

    func testNoNameIsTodaysRule() {
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", name: nil, equipment: "QX100"), "Job 4410 — QX100")
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", name: "  ", equipment: nil), "Job 4410")
        XCTAssertEqual(JobThreadTitle.title(reference: "4410", equipment: nil), "Job 4410")
        XCTAssertNil(JobThreadTitle.title(reference: nil, name: "Boiler swap", equipment: nil),
                     "without a number the thread keeps its title, as before")
    }

    func testTheNameAloneFormIsTheAppsOwn() {
        XCTAssertTrue(JobThreadTitle.isGenerated("4410 boiler swap", reference: "4410", name: "4410 boiler swap"))
        XCTAssertTrue(JobThreadTitle.isGenerated("Job 4410 — Boiler swap", reference: "4410", name: "Boiler swap"))
        XCTAssertFalse(JobThreadTitle.isGenerated("Roof plant — Tuesday", reference: "4410", name: "Boiler swap"))
    }
}

// MARK: - A rename retitles the job's conversation

@MainActor
final class KRJobNameRetitlesTests: XCTestCase {

    private var sessionsRoot: URL!
    private var storeDirectory: URL!
    private var service: FieldSessionService!
    private var store: ConversationStore!
    private var flow: GuidedJobFlow!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KRJobName-sessions-\(unique)", isDirectory: true)
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KRJobName-store-\(unique)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        service = FieldSessionService(sessionsRoot: sessionsRoot)
        store = ConversationStore(directory: storeDirectory)
        flow = GuidedJobFlow(sessions: service, store: store, seams: .init(persistenceEnabled: { true }))
    }

    override func tearDown() {
        flow = nil
        service = nil
        store = nil
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        try? FileManager.default.removeItem(at: sessionsRoot)
        try? FileManager.default.removeItem(at: storeDirectory)
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func turn(_ user: String) async {
        if await flow.handleUtterance(user) { return }
        flow.prepareThreadForTurn(.wakeWord)
        if store.activeThreadId == nil { store.startThread(mode: AppMode.direct.rawValue) }
        store.appendMessage(role: "user", content: user)
        store.appendMessage(role: "assistant", content: "Right you are.")
        flow.endThreadForVoiceReturn()
    }

    private func title() -> String? {
        store.threads.first { $0.id == service.activeSession?.conversationThreadId }?.title
    }

    func testARenameMovesTheTitle() async throws {
        _ = try flow.startJob(vaultId: "refrigeration", jobReference: "4410")
        await turn("first look at the unit")
        XCTAssertEqual(title(), "Job 4410")

        XCTAssertTrue(service.setJobName("Boiler swap"))
        XCTAssertEqual(title(), "Job 4410 — Boiler swap")

        XCTAssertTrue(service.setJobName("4410 boiler swap"))
        XCTAssertEqual(title(), "4410 boiler swap", "the number is not said twice")

        XCTAssertTrue(service.setJobName("Kitchen extract"))
        XCTAssertEqual(title(), "Job 4410 — Kitchen extract", "the app's own name-alone title moves too")
    }

    func testAWearersOwnTitleIsNotTakenOverByAName() async throws {
        _ = try flow.startJob(vaultId: "refrigeration", jobReference: "4410")
        await turn("first look at the unit")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)
        let idx = try XCTUnwrap(store.threads.firstIndex { $0.id == threadId })
        store.threads[idx].title = "Roof plant — Tuesday"
        service.setJobName("Boiler swap")
        XCTAssertEqual(store.threads[idx].title, "Roof plant — Tuesday")
    }
}

// MARK: - The report

final class KRJobReportTests: XCTestCase {

    private static let utc = TimeZone(identifier: "UTC")!

    private static func date(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute))!
    }

    private static func session(_ id: String, reference: String, thread: String?, from start: Date,
                                to end: Date?, name: String? = nil) -> FieldSession {
        var session = FieldSession(id: id, vaultId: "refrigeration", assetId: name, mode: .aiOnly,
                                   startedAt: start, outcome: .resolved, escalations: [], billableSeconds: 0)
        session.endedAt = end
        session.jobReference = reference
        session.conversationThreadId = thread
        return session
    }

    private static func message(_ role: String, _ content: String, at date: Date) -> ConversationMessage {
        let json: [String: Any] = ["id": UUID().uuidString, "role": role, "content": content,
                                   "imageAttached": false, "timestamp": date.timeIntervalSinceReferenceDate]
        return try! JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func trace(at date: Date, session: String?, thread: String?) -> TurnTrace {
        var timeline = TurnTimeline(backend: .direct(.anthropic), model: "fixture-model")
        timeline.mark(.commit, at: date)
        timeline.mark(.generationDone, at: date.addingTimeInterval(2))
        timeline.fieldSessionId = session
        timeline.threadId = thread
        return TurnTrace(timeline, sealedAt: date.addingTimeInterval(3))
    }

    /// The body's job sections, by heading line.
    private static func sections(_ body: String) -> [String] {
        body.components(separatedBy: String(repeating: "=", count: 60)).dropFirst().map { $0 }
    }

    // MARK: Two jobs in one thread

    private func twoJobsInOneThread() -> (jobs: [JobTranscriptExport.Job], traces: [TurnTrace]) {
        let first = Self.session("s1", reference: "4410", thread: "t", from: Self.date(9, 0), to: Self.date(9, 30))
        let second = Self.session("s2", reference: "4411", thread: "t", from: Self.date(10, 0), to: Self.date(10, 40))
        var thread = ConversationThread(mode: "fieldAssist")
        thread.messages = [
            Self.message("user", "Furnace short cycles.", at: Self.date(9, 5)),
            Self.message("assistant", "Check the flame sensor.", at: Self.date(9, 6)),
            Self.message("user", "Close the job.", at: Self.date(9, 30)),
            Self.message("user", "Next job: the rooftop unit.", at: Self.date(10, 2)),
            Self.message("assistant", "Read the suction pressure.", at: Self.date(10, 3)),
        ]
        let all = [first, second]
        let jobs = all.map {
            JobTranscriptExport.job(session: $0, vaultName: "Refrigeration", thread: thread, events: [],
                                    sharesThread: JobTranscriptExport.sharesThread($0, among: all))
        }
        // The first job's turns carry its session id; a later one in the second job's window was
        // recorded against the thread only; the second job's own is by its session id.
        let traces = [
            Self.trace(at: Self.date(9, 5), session: "s1", thread: "t"),
            Self.trace(at: Self.date(10, 2), session: nil, thread: "t"),
            Self.trace(at: Self.date(10, 3), session: "s2", thread: "t"),
        ]
        return (jobs, traces)
    }

    func testTwoJobsInOneThreadExportWithoutOverlap() {
        let (jobs, _) = twoJobsInOneThread()
        XCTAssertTrue(jobs.allSatisfy(\.sharesThread))
        XCTAssertEqual(jobs[0].lines.map(\.text), ["Furnace short cycles.", "Check the flame sensor.", "Close the job."])
        XCTAssertEqual(jobs[1].lines.map(\.text), ["Next job: the rooftop unit.", "Read the suction pressure."])
        XCTAssertTrue(Set(jobs[0].lines.map(\.text)).isDisjoint(with: jobs[1].lines.map(\.text)))
    }

    func testEachJobKeepsItsOwnTurns() {
        let (jobs, traces) = twoJobsInOneThread()
        let document = JobTranscriptExport.document(
            scope: .day(Self.date(0, 0)), jobs: jobs, exportedAt: Self.date(12, 0), timeZone: Self.utc,
            details: .init(traces: traces))
        let sections = Self.sections(document.body)
        let first = sections.first { $0.contains("Job 4410 ·") } ?? ""
        let second = sections.first { $0.contains("Job 4411 ·") } ?? ""
        XCTAssertFalse(first.isEmpty || second.isEmpty, document.body)
        XCTAssertFalse(second.contains(JobTranscriptExport.untracedNote), "the second job has its turns")
        XCTAssertFalse(first.contains("Read the suction pressure."))
        XCTAssertEqual(document.turnCount, 3, "every turn printed once")
        XCTAssertFalse(document.body.contains("Other AI turns"), "none left over")
    }

    func testOneJobOfTheTwoClaimsNoneOfTheOthersTurns() {
        let (jobs, traces) = twoJobsInOneThread()
        let document = JobTranscriptExport.document(
            scope: .job(sessionId: "s1"), jobs: [jobs[0]], exportedAt: Self.date(12, 0), timeZone: Self.utc,
            details: .init(traces: traces))
        XCTAssertEqual(document.turnCount, 1, "only the first job's own turn")
    }

    func testAJobAloneInItsThreadKeepsTheWholeThreadAsBefore() {
        let lone = Self.session("s1", reference: "4410", thread: "t", from: Self.date(9, 0), to: Self.date(9, 30))
        var thread = ConversationThread(mode: "fieldAssist")
        thread.messages = [Self.message("user", "A debrief the next hour.", at: Self.date(10, 30))]
        let job = JobTranscriptExport.job(session: lone, vaultName: "Refrigeration", thread: thread, events: [],
                                          sharesThread: JobTranscriptExport.sharesThread(lone, among: [lone]))
        XCTAssertFalse(job.sharesThread)
        XCTAssertEqual(job.lines.map(\.text), ["A debrief the next hour."])
    }

    // MARK: The heading, the vault line and the figure line

    func testTheHeadingCarriesTheName() {
        let named = Self.session("s1", reference: "4410", thread: nil, from: Self.date(9, 0), to: nil, name: "Boiler swap")
        let job = JobTranscriptExport.job(session: named, vaultName: "Refrigeration", thread: nil, events: [])
        let body = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                exportedAt: Self.date(12, 0), timeZone: Self.utc).body
        XCTAssertTrue(body.components(separatedBy: "\n").contains("Job 4410 — Boiler swap · Resolved"), body)

        let leading = Self.session("s2", reference: "4410", thread: nil, from: Self.date(9, 0), to: nil,
                                   name: "4410 boiler swap")
        let alone = JobTranscriptExport.job(session: leading, vaultName: "Refrigeration", thread: nil, events: [])
        let aloneBody = JobTranscriptExport.document(scope: .job(sessionId: "s2"), jobs: [alone],
                                                     exportedAt: Self.date(12, 0), timeZone: Self.utc).body
        XCTAssertTrue(aloneBody.components(separatedBy: "\n").contains("4410 boiler swap · Resolved"), aloneBody)
    }

    func testTheVaultLineSaysOnOrOff() {
        var sealed = Self.session("s1", reference: "4410", thread: nil, from: Self.date(9, 0), to: nil)
        sealed.vaultOnly = true
        let open = Self.session("s2", reference: "4411", thread: nil, from: Self.date(9, 0), to: nil)
        XCTAssertEqual(JobTranscriptExport.vaultLine(
            JobTranscriptExport.job(session: sealed, vaultName: "Acme", thread: nil, events: [])),
                       "Vault: Acme · Vault-only: on")
        XCTAssertEqual(JobTranscriptExport.vaultLine(
            JobTranscriptExport.job(session: open, vaultName: "Acme", thread: nil, events: [])),
                       "Vault: Acme · Vault-only: off")
    }

    func testTheFigureLineSaysWhereThePageWent() {
        XCTAssertEqual(JobTranscriptExport.presentedPlace("phone"), "on the phone")
        XCTAssertEqual(JobTranscriptExport.presentedPlace("model_only"), "to the model only")
        XCTAssertEqual(JobTranscriptExport.presentedPlace("none"), "nowhere")
        XCTAssertNil(JobTranscriptExport.presentedPlace(nil))
        XCTAssertNil(JobTranscriptExport.presentedPlace("elsewhere"))

        let session = Self.session("s1", reference: "4410", thread: nil, from: Self.date(9, 0), to: nil)
        let job = JobTranscriptExport.job(session: session, vaultName: "Acme", thread: nil, events: [])
        let events: [SessionLogger.Event] = [
            .init(timestamp: Self.date(9, 5), kind: .figurePresented, text: "Fixture manual, page 4",
                  payload: ["presented": AnyCodable("model_only"), "page": AnyCodable(4)]),
            .init(timestamp: Self.date(9, 6), kind: .figurePresented, text: "Fixture manual, page 9",
                  payload: ["presented": AnyCodable("phone"), "page": AnyCodable(9)]),
        ]
        let body = JobTranscriptExport.document(
            scope: .job(sessionId: "s1"), jobs: [job], exportedAt: Self.date(12, 0), timeZone: Self.utc,
            details: .init(jobEvents: ["s1": events])).body
        XCTAssertTrue(body.contains("[job] figure presented — Fixture manual, page 4 · to the model only"), body)
        XCTAssertTrue(body.contains("[job] figure presented — Fixture manual, page 9 · on the phone"), body)
    }
}
