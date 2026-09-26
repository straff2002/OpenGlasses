import XCTest
@testable import OpenGlasses

/// A job's or a day's transcript as a text file (support ask, 2026-09-26).
///
/// Headless and fixture-driven: `JobTranscriptExport` reads no store, clock or locale, so every
/// rule — which jobs a day holds, what happens when a job's conversation has gone, how a line after
/// midnight is stamped — is stated here with fixed dates in UTC.
final class JobTranscriptExportTests: XCTestCase {

    private static let utc = TimeZone(identifier: "UTC")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private static func session(_ id: String, reference: String? = "1005",
                                startedAt: Date, endedAt: Date? = nil,
                                outcome: FieldSession.Outcome = .resolved) -> FieldSession {
        var session = FieldSession(id: id, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: startedAt, outcome: outcome, escalations: [],
                                   billableSeconds: 0)
        session.endedAt = endedAt
        session.jobReference = reference
        return session
    }

    /// `ConversationMessage` stamps itself with the current time, so a fixture decodes one instead.
    private static func message(_ role: String, _ content: String, at date: Date,
                                image: Bool = false) -> ConversationMessage {
        let json: [String: Any] = ["id": UUID().uuidString, "role": role, "content": content,
                                   "imageAttached": image,
                                   "timestamp": date.timeIntervalSinceReferenceDate]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ConversationMessage.self, from: data)
    }

    private static func thread(_ messages: [ConversationMessage]) -> ConversationThread {
        var thread = ConversationThread(mode: "fieldAssist")
        thread.messages = messages
        return thread
    }

    private static func said(_ text: String, at date: Date) -> SessionLogger.Event {
        SessionLogger.Event(timestamp: date, kind: .userMessage, text: text, payload: nil)
    }

    // MARK: - One job's lines

    func testTheConversationGivesBothSidesInTimeOrderWithoutSystemMessages() {
        let session = Self.session("s1", startedAt: Self.date(26, 9, 12))
        let thread = Self.thread([
            Self.message("assistant", "Check the flame sensor.", at: Self.date(26, 9, 14)),
            Self.message("system", "You are a field assistant.", at: Self.date(26, 9, 12)),
            Self.message("user", "It keeps short cycling.", at: Self.date(26, 9, 13)),
            Self.message("user", "   ", at: Self.date(26, 9, 15)),
        ])
        let job = JobTranscriptExport.job(session: session, vaultName: "Refrigeration",
                                          thread: thread, events: [Self.said("ignored", at: Self.date(26, 9, 13))])

        XCTAssertEqual(job.source, .conversation)
        XCTAssertEqual(job.lines.map(\.speaker), [.technician, .assistant])
        XCTAssertEqual(job.lines.map(\.text), ["It keeps short cycling.", "Check the flame sensor."])
        XCTAssertEqual(job.jobNumber, "Job 1005")
    }

    func testWithTheThreadGoneTheJobLogGivesTheTechniciansWordsAndSaysSo() {
        let session = Self.session("s1", startedAt: Self.date(26, 9, 12))
        let events = [
            Self.said("It keeps short cycling.", at: Self.date(26, 9, 13)),
            SessionLogger.Event(timestamp: Self.date(26, 9, 14), kind: .taskStarted,
                                text: "Not something anyone said", payload: nil),
        ]
        let job = JobTranscriptExport.job(session: session, vaultName: "Refrigeration",
                                          thread: nil, events: events)

        XCTAssertEqual(job.source, .jobLogOnly)
        XCTAssertEqual(job.lines.map(\.text), ["It keeps short cycling."])
        XCTAssertEqual(job.lines.map(\.speaker), [.technician])

        let body = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                exportedAt: Self.date(26, 14, 0),
                                                timeZone: Self.utc).body
        XCTAssertTrue(body.contains(JobTranscriptExport.jobLogOnlyNote))
    }

    func testAnEmptyThreadFallsBackToTheJobLogRatherThanPrintingNothing() {
        let session = Self.session("s1", startedAt: Self.date(26, 9, 12))
        let job = JobTranscriptExport.job(session: session, vaultName: "Refrigeration",
                                          thread: Self.thread([]),
                                          events: [Self.said("Hello", at: Self.date(26, 9, 13))])
        XCTAssertEqual(job.source, .jobLogOnly)
    }

    func testAJobWithNothingSaidSaysSo() {
        let session = Self.session("s1", reference: nil, startedAt: Self.date(26, 9, 12))
        let job = JobTranscriptExport.job(session: session, vaultName: "Refrigeration",
                                          thread: nil, events: [])
        XCTAssertEqual(job.source, .nothing)
        XCTAssertEqual(job.jobNumber, JobTabModel.noJobNumber)

        let body = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                exportedAt: Self.date(26, 14, 0),
                                                timeZone: Self.utc).body
        XCTAssertTrue(body.contains(JobTranscriptExport.nothingNote))
    }

    // MARK: - Choosing the jobs

    func testADayHoldsTheJobsStartedOnItOldestFirstCancelledIncluded() {
        let sessions = [
            Self.session("late", startedAt: Self.date(26, 22, 30), endedAt: Self.date(27, 1, 0)),
            Self.session("early", startedAt: Self.date(26, 8, 0), outcome: .cancelled),
            Self.session("yesterday", startedAt: Self.date(25, 15, 0)),
            Self.session("tomorrow", startedAt: Self.date(27, 0, 30)),
        ]
        let chosen = JobTranscriptExport.sessions(for: .day(Self.date(26, 12, 0)), in: sessions,
                                                  calendar: Self.calendar)
        XCTAssertEqual(chosen.map(\.id), ["early", "late"])
    }

    func testAJobScopeHoldsOnlyThatJob() {
        let sessions = [Self.session("a", startedAt: Self.date(26, 8, 0)),
                        Self.session("b", startedAt: Self.date(26, 9, 0))]
        let chosen = JobTranscriptExport.sessions(for: .job(sessionId: "b"), in: sessions,
                                                  calendar: Self.calendar)
        XCTAssertEqual(chosen.map(\.id), ["b"])
    }

    func testDaysAreNewestFirstWithTheirJobCounts() {
        let sessions = [Self.session("a", startedAt: Self.date(24, 8, 0)),
                        Self.session("b", startedAt: Self.date(26, 8, 0)),
                        Self.session("c", startedAt: Self.date(26, 13, 0))]
        let days = JobTranscriptExport.days(in: sessions, calendar: Self.calendar)
        XCTAssertEqual(days.map(\.day), [Self.date(26, 0, 0), Self.date(24, 0, 0)])
        XCTAssertEqual(days.map(\.jobCount), [2, 1])
    }

    // MARK: - The file

    func testTheFileStampsLinesAndIndentsContinuations() {
        var session = Self.session("s1", startedAt: Self.date(26, 9, 12), endedAt: Self.date(26, 10, 40))
        session.jobReference = "1005"
        let thread = Self.thread([
            Self.message("user", "What is this part?", at: Self.date(26, 9, 13), image: true),
            Self.message("assistant", "That is the flame sensor.\nClean it with emery cloth.",
                         at: Self.date(26, 9, 14)),
            Self.message("user", "Follow-up from the debrief.", at: Self.date(27, 8, 5)),
        ])
        let job = JobTranscriptExport.job(session: session, vaultName: "Refrigeration",
                                          thread: thread, events: [])
        let document = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                    exportedAt: Self.date(26, 14, 3),
                                                    timeZone: Self.utc)
        let lines = document.body.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "OpenGlasses — Job 1005 transcript — 2026-09-26")
        XCTAssertTrue(lines.contains("Exported 2026-09-26 14:03 (UTC+00:00)"))
        XCTAssertTrue(document.body.contains(JobTranscriptExport.preamble))
        XCTAssertTrue(lines.contains("Job 1005 · Resolved"))
        XCTAssertTrue(lines.contains("Vault: Refrigeration"))
        XCTAssertTrue(lines.contains("Started 2026-09-26 09:12 · Ended 10:40"))
        XCTAssertTrue(lines.contains("09:13  Technician: [with photo] What is this part?"))
        XCTAssertTrue(lines.contains("09:14  Assistant: That is the flame sensor."))
        XCTAssertTrue(lines.contains("       Clean it with emery cloth."))
        // A line on another day than the job started carries its date.
        XCTAssertTrue(lines.contains("2026-09-27 08:05  Technician: Follow-up from the debrief."))

        XCTAssertEqual(document.displayName, "Job 1005 transcript 2026-09-26.txt")
        XCTAssertEqual(document.jobCount, 1)
        XCTAssertEqual(document.lineCount, 3)
    }

    func testADayFileNamesTheDayAndHoldsEveryJob() {
        let first = JobTranscriptExport.job(
            session: Self.session("a", reference: "1005", startedAt: Self.date(26, 8, 0)),
            vaultName: "Refrigeration", thread: nil,
            events: [Self.said("First job", at: Self.date(26, 8, 5))])
        let second = JobTranscriptExport.job(
            session: Self.session("b", reference: nil, startedAt: Self.date(26, 13, 0)),
            vaultName: "Refrigeration", thread: nil, events: [])
        let document = JobTranscriptExport.document(scope: .day(Self.date(26, 0, 0)),
                                                    jobs: [first, second],
                                                    exportedAt: Self.date(26, 18, 0),
                                                    timeZone: Self.utc)

        XCTAssertEqual(document.title, "Job transcripts — 2026-09-26 (2 jobs)")
        XCTAssertEqual(document.displayName, "Job transcripts 2026-09-26.txt")
        XCTAssertTrue(document.body.contains("Job 1005 · Resolved"))
        XCTAssertTrue(document.body.contains("\(JobTabModel.noJobNumber) · Resolved"))
        XCTAssertTrue(document.body.contains("Started 2026-09-26 13:00 · Still open"))
        let firstAt = document.body.range(of: "Job 1005")!.lowerBound
        let secondAt = document.body.range(of: JobTabModel.noJobNumber)!.lowerBound
        XCTAssertLessThan(firstAt, secondAt)
    }
}
