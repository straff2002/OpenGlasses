import XCTest
@testable import OpenGlasses

/// A job's, a day's or one conversation's transcript as a text file (support ask, 2026-09-26).
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

        XCTAssertEqual(lines.first, "Avenkin — Job 1005 transcript — 2026-09-26")
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

    // MARK: - Troubleshooting details

    private static func trace(at date: Date, session: String? = nil, thread: String? = nil,
                              failed: Bool = false) -> TurnTrace {
        var timeline = TurnTimeline(backend: .direct(.anthropic), model: "/var/models/claude.bin")
        timeline.mark(.commit, at: date)
        timeline.mark(.firstToken, at: date.addingTimeInterval(1.2))
        timeline.mark(.generationDone, at: date.addingTimeInterval(3.4))
        timeline.transcriber = .onDevice
        timeline.imageSent = true
        timeline.promptBlocks = [.init(name: "system prompt", characters: 4000),
                                 .init(name: "field assist: vault, job and manual passages", characters: 1500)]
        timeline.manualPassages = ["Lennox SLP99 IOM, page 12"]
        timeline.toolCalls = [.init(name: "lookup_part", outcome: "completed")]
        timeline.fieldSessionId = session
        timeline.threadId = thread
        if failed {
            timeline.abandoned = true
            timeline.failure = SafeErrorSummary(category: .rateLimited, code: 429)
        }
        return TurnTrace(timeline, sealedAt: date.addingTimeInterval(4))
    }

    func testASupportReportPutsEachAITurnUnderTheLineItAnswered() {
        let session = Self.session("s1", startedAt: Self.date(26, 9, 12))
        let thread = Self.thread([
            Self.message("user", "What's the gas pressure?", at: Self.date(26, 9, 13)),
            Self.message("assistant", "3.5 inches water column.", at: Self.date(26, 9, 14)),
        ])
        let job = JobTranscriptExport.job(session: session, vaultName: "Refrigeration",
                                          thread: thread, events: [])
        let events = [
            Self.said("What's the gas pressure?", at: Self.date(26, 9, 13)),
            SessionLogger.Event(timestamp: Self.date(26, 9, 20), kind: .taskStarted,
                                text: "Replace the flame sensor", payload: nil),
        ]
        let details = JobTranscriptExport.Details(
            traces: [Self.trace(at: Self.date(26, 9, 13), session: "s1"),
                     Self.trace(at: Self.date(26, 9, 30), session: "s1", failed: true)],
            jobEvents: ["s1": events],
            phone: ["Device: iPhone17,1"],
            appEvents: [.init(at: Self.date(26, 9, 30), line: "[network] request event=failed")],
            debugLog: [])
        let document = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                    exportedAt: Self.date(26, 14, 0),
                                                    timeZone: Self.utc, details: details)
        let lines = document.body.components(separatedBy: "\n")

        XCTAssertEqual(document.title, "Job 1005 support report — 2026-09-26")
        XCTAssertTrue(document.body.contains(JobTranscriptExport.troubleshootingPreamble))
        XCTAssertEqual(document.turnCount, 2)
        XCTAssertEqual(document.failedTurnCount, 1)

        let asked = lines.firstIndex(of: "09:13  Technician: What's the gas pressure?")!
        let turn = lines.firstIndex(of: "09:13  · AI turn answered")!
        let answered = lines.firstIndex(of: "09:14  Assistant: 3.5 inches water column.")!
        XCTAssertLessThan(asked, turn)
        XCTAssertLessThan(turn, answered)

        // The local model's path is reduced to its file name.
        XCTAssertTrue(document.body.contains("model: anthropic / claude.bin · transcribed by onDevice"))
        XCTAssertTrue(document.body.contains("instructions of 5500 characters (system prompt 4000, field assist: vault, job and manual passages 1500) + a photo"))
        XCTAssertTrue(document.body.contains("manual pages: Lennox SLP99 IOM, page 12"))
        XCTAssertTrue(document.body.contains("tools: lookup_part (completed)"))
        XCTAssertTrue(document.body.contains("timing: first output after 1.2 s, reply complete after 3.4 s"))
        XCTAssertTrue(lines.contains("09:30  · AI turn FAILED — rateLimited#429"))

        // The job log is in the timeline; its conversation events are not repeated.
        XCTAssertTrue(lines.contains("09:20  [job] task started — Replace the flame sensor"))
        XCTAssertFalse(document.body.contains("[job] user message"))

        XCTAssertTrue(lines.contains("Device: iPhone17,1"))
        XCTAssertTrue(lines.contains("09:30:00  [network] request event=failed"))
    }

    func testASupportReportNamesTheAppCopyInItsHeader() {
        let app = "2026.10 (460) · 9f9f57e28 · TestFlight · com.example.app"
        let stamped = JobTranscriptExport.document(
            scope: .day(Self.date(26, 0, 0)), jobs: [], exportedAt: Self.date(26, 14, 0),
            timeZone: Self.utc, details: .init(app: app))
        // Third line: under the title and the export time, above everything said.
        XCTAssertEqual(stamped.body.components(separatedBy: "\n")[2], "App \(app)")

        let unstamped = JobTranscriptExport.document(
            scope: .day(Self.date(26, 0, 0)), jobs: [], exportedAt: Self.date(26, 14, 0),
            timeZone: Self.utc, details: .init())
        XCTAssertEqual(unstamped.body.components(separatedBy: "\n")[2], "")
    }

    func testAPlainTranscriptCarriesNoTroubleshootingLayer() {
        let job = JobTranscriptExport.job(
            session: Self.session("s1", startedAt: Self.date(26, 9, 12)), vaultName: "Refrigeration",
            thread: nil, events: [Self.said("Hello", at: Self.date(26, 9, 13))])
        let document = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                    exportedAt: Self.date(26, 14, 0), timeZone: Self.utc)
        XCTAssertFalse(document.body.contains("AI turn"))
        XCTAssertFalse(document.body.contains("This phone"))
        XCTAssertFalse(document.body.contains(JobTranscriptExport.troubleshootingPreamble))
    }

    func testASupportReportMasksConfiguredSecretsEvenInWhatWasSaid() {
        let job = JobTranscriptExport.job(
            session: Self.session("s1", startedAt: Self.date(26, 9, 12)), vaultName: "Refrigeration",
            thread: Self.thread([Self.message("user", "the gateway code is plover-quartz-lantern",
                                              at: Self.date(26, 9, 13))]),
            events: [])
        let document = JobTranscriptExport.document(
            scope: .job(sessionId: "s1"), jobs: [job], exportedAt: Self.date(26, 14, 0),
            timeZone: Self.utc, details: .init(), secrets: ["plover-quartz-lantern"])
        XCTAssertFalse(document.body.contains("plover-quartz-lantern"))
        XCTAssertFalse(document.redactionHits.isEmpty)
    }

    func testADayCanCarryConversationsOutsideJobsWithTheirOwnTurns() {
        let job = JobTranscriptExport.job(
            session: Self.session("s1", startedAt: Self.date(26, 9, 0)), vaultName: "Refrigeration",
            thread: nil, events: [Self.said("On the job", at: Self.date(26, 9, 5))])
        let outside = JobTranscriptExport.Conversation(
            threadId: "t-outside", title: "Weather this afternoon",
            lines: [.init(timestamp: Self.date(26, 12, 0), speaker: .technician,
                          text: "Will it rain?", imageAttached: false)])
        let details = JobTranscriptExport.Details(traces: [
            Self.trace(at: Self.date(26, 12, 0), thread: "t-outside", failed: true),
            Self.trace(at: Self.date(26, 15, 0)),
        ])
        let document = JobTranscriptExport.document(
            scope: .day(Self.date(26, 0, 0)), jobs: [job], exportedAt: Self.date(26, 18, 0),
            timeZone: Self.utc, conversations: [outside], details: details)

        XCTAssertEqual(document.title, "Support report — 2026-09-26 (1 job)")
        XCTAssertTrue(document.body.contains("Outside a job: Weather this afternoon"))
        XCTAssertTrue(document.body.contains("12:00  Technician: Will it rain?"))
        XCTAssertTrue(document.body.contains("12:00  · AI turn FAILED — rateLimited#429"))
        // A turn with no saved conversation still appears, on its own.
        XCTAssertTrue(document.body.contains("Other AI turns (no saved conversation)"))
        XCTAssertTrue(document.body.contains("15:00  · AI turn answered"))
        XCTAssertEqual(document.turnCount, 2)
        XCTAssertEqual(document.lineCount, 2)
    }

    func testAJobReportNeverCarriesTurnsFromOutsideTheJob() {
        let job = JobTranscriptExport.job(
            session: Self.session("s1", startedAt: Self.date(26, 9, 0)), vaultName: "Refrigeration",
            thread: nil, events: [])
        let details = JobTranscriptExport.Details(traces: [Self.trace(at: Self.date(26, 12, 0), thread: "elsewhere")])
        let document = JobTranscriptExport.document(scope: .job(sessionId: "s1"), jobs: [job],
                                                    exportedAt: Self.date(26, 18, 0), timeZone: Self.utc,
                                                    details: details)
        XCTAssertFalse(document.body.contains("AI turn answered"))
        XCTAssertEqual(document.turnCount, 0)
    }

    func testATurnThatNeverReachedTheAIDoesNotReadAsAnAnswer() {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: Self.date(26, 10, 0))
        let lines = JobTranscriptExport.render(TurnTrace(timeline, sealedAt: Self.date(26, 10, 0)),
                                               stamp: "10:00")
        XCTAssertEqual(lines, ["10:00  · Turn handled by the app (no AI request)"])
    }

    func testLinesCanBeLimitedToAWindow() {
        let messages = [Self.message("user", "yesterday", at: Self.date(25, 23, 0)),
                        Self.message("user", "today", at: Self.date(26, 8, 0))]
        let window = JobTranscriptExport.window(of: Self.date(26, 12, 0), calendar: Self.calendar)
        XCTAssertEqual(JobTranscriptExport.lines(of: messages, within: window).map(\.text), ["today"])
    }

    // MARK: - One conversation

    private static func thread(id: String, title: String = "New Conversation",
                               _ messages: [ConversationMessage]) -> ConversationThread {
        var thread = Self.thread(messages)
        thread.id = id
        thread.title = title
        return thread
    }

    func testTheLastConversationIsTheOneMostRecentlySpokenIn() {
        let morning = Self.thread(id: "morning", [
            Self.message("user", "Morning question", at: Self.date(26, 8, 0)),
            Self.message("assistant", "Morning answer", at: Self.date(26, 8, 1)),
        ])
        let afternoon = Self.thread(id: "afternoon", [
            Self.message("user", "Afternoon question", at: Self.date(26, 15, 0)),
        ])
        // Opened later than either, with nothing anyone said in it.
        let instructionsOnly = Self.thread(id: "instructions", [
            Self.message("system", "You are a field assistant.", at: Self.date(26, 17, 0)),
            Self.message("user", "   ", at: Self.date(26, 17, 1)),
        ])
        let empty = Self.thread(id: "empty", [])
        // Started yesterday and picked up again this evening: its last line decides, not its first.
        let resumed = Self.thread(id: "resumed", [
            Self.message("user", "Yesterday", at: Self.date(25, 9, 0)),
            Self.message("assistant", "Back again", at: Self.date(26, 18, 0)),
        ])
        let sameInstant = Self.thread(id: "same-instant", [
            Self.message("user", "Also at three", at: Self.date(26, 15, 0)),
        ])

        let cases: [(name: String, threads: [ConversationThread], expected: String?)] = [
            ("nothing on the phone", [], nil),
            ("only threads with nothing said", [instructionsOnly, empty], nil),
            ("the newest line wins, whatever the store's order", [afternoon, morning], "afternoon"),
            ("the same threads the other way round", [morning, afternoon], "afternoon"),
            ("a thread with nothing said is passed over", [instructionsOnly, empty, morning], "morning"),
            ("a resumed thread counts by its last line", [afternoon, resumed, morning], "resumed"),
            ("lines at the same instant go to the first listed", [afternoon, sameInstant], "afternoon"),
        ]
        for (name, threads, expected) in cases {
            XCTAssertEqual(JobTranscriptExport.lastConversation(in: threads)?.id, expected, name)
            XCTAssertEqual(JobTranscriptExport.hasConversation(in: threads), expected != nil, name)
            // The request Settings opens is that thread's, with the troubleshooting layer and
            // nothing wider to switch to.
            let request = SupportReportRequest.lastConversation(in: threads)
            XCTAssertEqual(request?.scope, expected.map { JobTranscriptExport.Scope.conversation(threadId: $0) }, name)
            if let request {
                XCTAssertTrue(request.options.troubleshooting, name)
                XCTAssertNil(request.widerDay, name)
                XCTAssertNil(request.reason, name)
            }
        }
    }

    func testAConversationHoldsOnlyItsOwnLinesAndTurns() {
        let wanted = Self.thread(id: "wanted", title: "Slow answers", [
            Self.message("assistant", "Still thinking.", at: Self.date(26, 14, 1)),
            Self.message("system", "You are a field assistant.", at: Self.date(26, 14, 0)),
            Self.message("user", "Why so slow?", at: Self.date(26, 14, 0)),
        ])
        let other = Self.thread(id: "other", title: "Lunch", [
            Self.message("user", "Where is lunch?", at: Self.date(26, 14, 0)),
        ])
        let traces = [
            Self.trace(at: Self.date(26, 14, 30), thread: "wanted", failed: true),
            Self.trace(at: Self.date(26, 14, 0), thread: "other"),
            Self.trace(at: Self.date(26, 14, 0), thread: "wanted"),
            // Recorded on a job with no thread, and with no context at all: neither is this
            // conversation's, however close in time.
            Self.trace(at: Self.date(26, 14, 0), session: "s1"),
            Self.trace(at: Self.date(26, 14, 0)),
        ]
        let selection = JobTranscriptExport.selection(
            threadId: "wanted", threads: [other, wanted], sessions: [], traces: traces,
            now: Self.date(26, 18, 0))

        XCTAssertEqual(selection.conversation?.threadId, "wanted")
        XCTAssertEqual(selection.conversation?.title, "Slow answers")
        XCTAssertEqual(selection.conversation?.lines.map(\.text), ["Why so slow?", "Still thinking."])
        XCTAssertNil(selection.conversation?.jobNumber)
        // Its turns, oldest first, whenever they happened.
        XCTAssertEqual(selection.traces.map(\.at), [Self.date(26, 14, 0), Self.date(26, 14, 30)])
        XCTAssertTrue(selection.traces.allSatisfy { $0.threadId == "wanted" })
    }

    func testAConversationsPeriodRunsFromFirstToLastWithTheJobScopesMargin() {
        let now = Self.date(26, 18, 0)
        let said = Self.thread(id: "t", [
            Self.message("user", "First", at: Self.date(26, 10, 0)),
            Self.message("assistant", "Last", at: Self.date(26, 10, 20)),
        ])
        let oneLine = Self.thread(id: "t", [Self.message("user", "Only", at: Self.date(26, 10, 0))])
        let overMidnight = Self.thread(id: "t", [
            Self.message("user", "Late", at: Self.date(26, 23, 58)),
            Self.message("assistant", "Early", at: Self.date(27, 0, 2)),
        ])

        let cases: [(name: String, threads: [ConversationThread], traces: [TurnTrace],
                     start: Date, end: Date)] = [
            ("first line to last line", [said], [],
             Self.date(26, 9, 55), Self.date(26, 10, 25)),
            ("a single line still has a margin either side", [oneLine], [],
             Self.date(26, 9, 55), Self.date(26, 10, 5)),
            ("a turn after the last line — a reply that never came — stretches the end",
             [said], [Self.trace(at: Self.date(26, 10, 40), thread: "t", failed: true)],
             Self.date(26, 9, 55), Self.date(26, 10, 45)),
            ("a turn before the first line stretches the start",
             [said], [Self.trace(at: Self.date(26, 9, 50), thread: "t")],
             Self.date(26, 9, 45), Self.date(26, 10, 25)),
            ("another thread's turn does not move it",
             [said], [Self.trace(at: Self.date(26, 12, 0), thread: "elsewhere")],
             Self.date(26, 9, 55), Self.date(26, 10, 25)),
            ("turns alone, when the words were not saved",
             [], [Self.trace(at: Self.date(26, 11, 0), thread: "t")],
             Self.date(26, 10, 55), Self.date(26, 11, 5)),
            ("across midnight", [overMidnight], [],
             Self.date(26, 23, 53), Self.date(27, 0, 7)),
            ("nothing to measure from: the margin either side of now", [], [],
             Self.date(26, 17, 55), Self.date(26, 18, 5)),
        ]
        XCTAssertEqual(JobTranscriptExport.windowMargin, 5 * 60)
        for (name, threads, traces, start, end) in cases {
            let window = JobTranscriptExport.selection(threadId: "t", threads: threads, sessions: [],
                                                       traces: traces, now: now).window
            XCTAssertEqual(window.start, start, name)
            XCTAssertEqual(window.end, end, name)
        }
    }

    func testAJobsThreadIsReportedAsAConversationAndNamedAsThatJobs() {
        let thread = Self.thread(id: "job-thread", title: "Job 1005", [
            Self.message("user", "What's the gas pressure?", at: Self.date(26, 9, 13)),
        ])
        var numbered = Self.session("s1", reference: "1005", startedAt: Self.date(26, 9, 12))
        numbered.conversationThreadId = "job-thread"
        var unnumbered = Self.session("s2", reference: nil, startedAt: Self.date(26, 9, 12))
        unnumbered.conversationThreadId = "job-thread"
        var elsewhere = Self.session("s3", reference: "2000", startedAt: Self.date(26, 9, 12))
        elsewhere.conversationThreadId = "another-thread"

        let cases: [(name: String, sessions: [FieldSession], expected: String?)] = [
            ("no job owns it", [], nil),
            ("a job owns another thread", [elsewhere], nil),
            ("its job has a number", [elsewhere, numbered], "Job 1005"),
            ("its job has no number yet", [unnumbered], JobTabModel.noJobNumber),
        ]
        for (name, sessions, expected) in cases {
            let selection = JobTranscriptExport.selection(
                threadId: "job-thread", threads: [thread], sessions: sessions, traces: [],
                now: Self.date(26, 18, 0))
            XCTAssertEqual(selection.conversation?.jobNumber, expected, name)
            // Never as the job: its log and its other details are not what was asked for.
            XCTAssertTrue(JobTranscriptExport.sessions(for: .conversation(threadId: "job-thread"),
                                                       in: sessions, calendar: Self.calendar).isEmpty, name)
        }
    }

    func testAConversationWithNothingOnThePhoneHasNothingToSend() {
        let empty = Self.thread(id: "t", [Self.message("system", "Instructions", at: Self.date(26, 9, 0))])
        let now = Self.date(26, 18, 0)

        XCTAssertNil(JobTranscriptExport.selection(threadId: "t", threads: [empty], sessions: [],
                                                   traces: [], now: now).conversation)
        XCTAssertNil(JobTranscriptExport.selection(threadId: "gone", threads: [empty], sessions: [],
                                                   traces: [], now: now).conversation)

        // Its words were not saved but a turn was recorded: the turn is still worth sending.
        let unsaved = JobTranscriptExport.selection(
            threadId: "gone", threads: [empty], sessions: [],
            traces: [Self.trace(at: Self.date(26, 11, 0), thread: "gone", failed: true)], now: now)
        XCTAssertEqual(unsaved.conversation?.title, JobTranscriptExport.unsavedConversationTitle)
        XCTAssertEqual(unsaved.conversation?.lines, [])
        XCTAssertEqual(unsaved.traces.count, 1)
    }

    func testTheDebugLogIsCutToAConversationsPeriod() {
        let afternoon = (start: Self.date(26, 14, 0), end: Self.date(26, 14, 30))
        let overMidnight = (start: Self.date(26, 23, 55), end: Self.date(27, 0, 10))
        let twoDays = (start: Self.date(26, 9, 0), end: Self.date(28, 9, 0))
        let log = [
            "[13:59:59] before",
            "[14:00:00] at the start",
            "[14:29:59] just inside",
            "[14:30:00] at the end",
            "[23:57:00] late",
            "[00:09:59] early",
            "no stamp at all",
            "[25:00:00] not a time",
            "[14:05] no seconds",
        ]
        let cases: [(name: String, window: (start: Date, end: Date), expected: [String])] = [
            ("half-open, like every other period", afternoon,
             ["[14:00:00] at the start", "[14:29:59] just inside"]),
            ("a period over midnight is tried on both of its days", overMidnight,
             ["[23:57:00] late", "[00:09:59] early"]),
            ("a day or more holds every time of day, but still nothing unstamped", twoDays,
             Array(log.prefix(6))),
        ]
        for (name, window, expected) in cases {
            XCTAssertEqual(JobTranscriptExport.debugLines(log, within: window, calendar: Self.calendar),
                           expected, name)
        }
    }

    func testAConversationReportCarriesThatConversationAndSaysWhatIsLeftOut() {
        let conversation = JobTranscriptExport.Conversation(
            threadId: "t", title: "Slow answers",
            lines: [.init(timestamp: Self.date(26, 14, 32), speaker: .technician,
                          text: "Why so slow?", imageAttached: false),
                    .init(timestamp: Self.date(26, 14, 33), speaker: .assistant,
                          text: "Still thinking.", imageAttached: false)])
        let details = JobTranscriptExport.Details(
            traces: [Self.trace(at: Self.date(26, 14, 32), thread: "t"),
                     Self.trace(at: Self.date(26, 14, 40), thread: "t", failed: true)],
            phone: ["Device: iPhone17,1"],
            appEvents: [.init(at: Self.date(26, 14, 40), line: "[network] request event=failed")],
            debugLog: ["[14:40:02] request failed"])
        let document = JobTranscriptExport.document(
            scope: .conversation(threadId: "t"), jobs: [], exportedAt: Self.date(26, 18, 0),
            timeZone: Self.utc, conversations: [conversation], details: details)
        let lines = document.body.components(separatedBy: "\n")

        // Named for the minute it began, not for the words it began with.
        XCTAssertEqual(document.title, "Conversation support report — 2026-09-26 14:32")
        XCTAssertEqual(document.displayName, "Conversation support report 2026-09-26 1432.txt")
        XCTAssertEqual(lines.first, "Avenkin — Conversation support report — 2026-09-26 14:32")
        XCTAssertFalse(document.title.contains("Slow answers"))

        XCTAssertTrue(document.body.contains(JobTranscriptExport.conversationPreamble))
        XCTAssertTrue(document.body.contains(JobTranscriptExport.conversationTroubleshootingPreamble))
        XCTAssertFalse(document.body.contains(JobTranscriptExport.preamble))
        XCTAssertFalse(document.body.contains(JobTranscriptExport.troubleshootingPreamble))

        XCTAssertTrue(lines.contains("Conversation: Slow answers"))
        XCTAssertFalse(document.body.contains("Outside a job"))
        XCTAssertFalse(document.body.contains(JobTranscriptExport.jobConversationNote))
        XCTAssertFalse(document.body.contains("No jobs."))

        let asked = lines.firstIndex(of: "14:32  Technician: Why so slow?")!
        let turn = lines.firstIndex(of: "14:32  · AI turn answered")!
        let answered = lines.firstIndex(of: "14:33  Assistant: Still thinking.")!
        XCTAssertLessThan(asked, turn)
        XCTAssertLessThan(turn, answered)
        XCTAssertTrue(lines.contains("14:40  · AI turn FAILED — rateLimited#429"))
        XCTAssertTrue(document.body.contains("timing: first output after 1.2 s, reply complete after 3.4 s"))

        XCTAssertTrue(lines.contains("Device: iPhone17,1"))
        XCTAssertTrue(lines.contains("14:40:00  [network] request event=failed"))
        XCTAssertTrue(lines.contains("Debug log (1 from this period)"))
        XCTAssertTrue(lines.contains("[14:40:02] request failed"))

        XCTAssertEqual(document.jobCount, 0)
        XCTAssertEqual(document.lineCount, 2)
        XCTAssertEqual(document.turnCount, 2)
        XCTAssertEqual(document.failedTurnCount, 1)
    }

    func testAConversationReportSaysWhenItWasHeldOnAJobOrHasNoTurnsOrNoWords() {
        let line = JobTranscriptExport.Line(timestamp: Self.date(26, 9, 13), speaker: .technician,
                                            text: "What's the gas pressure?", imageAttached: false)
        func body(_ conversation: JobTranscriptExport.Conversation,
                  details: JobTranscriptExport.Details? = .init()) -> String {
            JobTranscriptExport.document(
                scope: .conversation(threadId: conversation.threadId), jobs: [],
                exportedAt: Self.date(26, 18, 0), timeZone: Self.utc,
                conversations: [conversation], details: details).body
        }

        let onAJob = body(.init(threadId: "t", title: "Job 1005", lines: [line], jobNumber: "Job 1005"))
        XCTAssertTrue(onAJob.contains("Conversation on Job 1005: Job 1005"))
        XCTAssertTrue(onAJob.contains(JobTranscriptExport.jobConversationNote))
        // The job itself is not in it: no job heading, no vault, no job log.
        XCTAssertFalse(onAJob.contains("Vault:"))
        XCTAssertFalse(onAJob.contains("[job]"))
        // Lines with no turn records say why, as a job's do.
        XCTAssertTrue(onAJob.contains(JobTranscriptExport.untracedNote))

        let wordsGone = body(
            .init(threadId: "t", title: JobTranscriptExport.unsavedConversationTitle, lines: []),
            details: .init(traces: [Self.trace(at: Self.date(26, 11, 0), thread: "t", failed: true)]))
        XCTAssertTrue(wordsGone.contains(JobTranscriptExport.unsavedConversationNote))
        XCTAssertTrue(wordsGone.contains("11:00  · AI turn FAILED — rateLimited#429"))
        XCTAssertFalse(wordsGone.contains(JobTranscriptExport.untracedNote))
        // Dated from its first turn when there is no line to date it from.
        XCTAssertTrue(wordsGone.hasPrefix("Avenkin — Conversation support report — 2026-09-26 11:00\n"))

        // The plain transcript of a conversation: no troubleshooting layer, and so no note about
        // missing turn records either.
        let plain = JobTranscriptExport.document(
            scope: .conversation(threadId: "t"), jobs: [], exportedAt: Self.date(26, 18, 0),
            timeZone: Self.utc, conversations: [.init(threadId: "t", title: "Gas", lines: [line])])
        XCTAssertEqual(plain.title, "Conversation transcript — 2026-09-26 09:13")
        XCTAssertEqual(plain.displayName, "Conversation transcript 2026-09-26 0913.txt")
        XCTAssertFalse(plain.body.contains("AI turn"))
        XCTAssertFalse(plain.body.contains("This phone"))
        XCTAssertFalse(plain.body.contains(JobTranscriptExport.untracedNote))
    }

    func testADaysConversationsAreStillHeadedOutsideAJobAndKeepTheNewestDebugLines() {
        // The wording a day's file has always had, with a job-owned number set or not: only a
        // conversation reported alone is headed differently.
        let outside = JobTranscriptExport.Conversation(
            threadId: "t", title: "Weather",
            lines: [.init(timestamp: Self.date(26, 12, 0), speaker: .technician,
                          text: "Will it rain?", imageAttached: false)],
            jobNumber: "Job 1005")
        let document = JobTranscriptExport.document(
            scope: .day(Self.date(26, 0, 0)), jobs: [], exportedAt: Self.date(26, 18, 0),
            timeZone: Self.utc, conversations: [outside],
            details: .init(debugLog: ["[09:00:00] one", "[09:00:01] two"]))
        let lines = document.body.components(separatedBy: "\n")

        XCTAssertTrue(lines.contains("Outside a job: Weather"))
        XCTAssertTrue(lines.contains("Debug log (newest 2)"))
        XCTAssertTrue(document.body.contains(JobTranscriptExport.preamble))
        XCTAssertTrue(document.body.contains(JobTranscriptExport.troubleshootingPreamble))
        XCTAssertFalse(document.body.contains(JobTranscriptExport.jobConversationNote))
        XCTAssertFalse(document.body.contains(JobTranscriptExport.untracedNote))
        XCTAssertFalse(document.body.contains("Conversation:"))
    }

    // MARK: - Where a report starts

    func testAFailedTurnOpensItsOwnConversationWithTheWholeDayStillReachable() {
        let at = Self.date(26, 10, 42)
        let reason = "An AI turn failed at 10:42: the AI service was busy (rate-limited)."

        let inAThread = SupportReportRequest.afterFailedTurn(at: at, threadId: "t", reason: reason)
        XCTAssertEqual(inAThread.scope, .conversation(threadId: "t"))
        XCTAssertEqual(inAThread.widerDay, at)
        XCTAssertEqual(inAThread.reason, reason)
        // Widened to the day, it includes everything, as the banner's report always did.
        XCTAssertEqual(inAThread.options, .init(troubleshooting: true, otherConversations: true))

        // A turn recorded against no conversation has nothing narrower to open.
        let noThread = SupportReportRequest.afterFailedTurn(at: at, threadId: nil, reason: reason)
        XCTAssertEqual(noThread.scope, .day(at))
        XCTAssertNil(noThread.widerDay)
        XCTAssertEqual(noThread.options, .init(troubleshooting: true, otherConversations: true))
    }

    func testSettingsAndTheJobTabOpenTheScopeTheyName() {
        let day = SupportReportRequest.named(.day(Self.date(26, 0, 0)))
        XCTAssertEqual(day.options, .init(troubleshooting: true, otherConversations: true))
        let job = SupportReportRequest.named(.job(sessionId: "s1"))
        XCTAssertEqual(job.options, .init(troubleshooting: true, otherConversations: false))
        let conversation = SupportReportRequest.named(.conversation(threadId: "t"))
        XCTAssertEqual(conversation.options, .init(troubleshooting: true, otherConversations: false))
        for request in [day, job, conversation] {
            XCTAssertNil(request.widerDay)
            XCTAssertNil(request.reason)
        }
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
