import XCTest
@testable import OpenGlasses

/// Plan MH P1 — "Report this reply" carries the turn that produced the reply, and nothing else.
///
/// Headless and fixture-driven, like `JobTranscriptExportTests`: `ReportedReplyScope` and
/// `JobTranscriptExport` read no store, clock or locale, so what goes into the report is stated
/// here with fixed dates in UTC.
final class ReportedReplyScopeTests: XCTestCase {

    private static let utc = TimeZone(identifier: "UTC")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func date(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 19,
                                           hour: hour, minute: minute, second: second))!
    }

    /// `ConversationMessage` stamps itself with a random id and the current time, so a fixture
    /// decodes one instead.
    private static func message(_ id: String, _ role: String, _ content: String, at date: Date,
                                answeredOnDevice: Bool = false) -> ConversationMessage {
        var json: [String: Any] = ["id": id, "role": role, "content": content, "imageAttached": false,
                                   "timestamp": date.timeIntervalSinceReferenceDate]
        if answeredOnDevice { json["answeredOnDevice"] = true }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ConversationMessage.self, from: data)
    }

    private static func thread(id: String = "t", title: String = "Boiler pressure and the cat",
                               _ messages: [ConversationMessage]) -> ConversationThread {
        var thread = ConversationThread(mode: "direct", title: title)
        thread.id = id
        thread.messages = messages
        return thread
    }

    private static func trace(at date: Date, thread: String?, model: String = "claude-test-model",
                              provider: LLMProvider = .anthropic) -> TurnTrace {
        var timeline = TurnTimeline(backend: .direct(provider), model: model)
        timeline.mark(.commit, at: date)
        timeline.mark(.firstToken, at: date.addingTimeInterval(1))
        timeline.mark(.generationDone, at: date.addingTimeInterval(2))
        timeline.threadId = thread
        return TurnTrace(timeline, sealedAt: date.addingTimeInterval(3))
    }

    /// Three turns, a minute apart.
    private static let threeTurns: [ConversationMessage] = [
        message("s", "system", "You are a helpful assistant.", at: date(9, 0)),
        message("q1", "user", "What pressure should the boiler run at?", at: date(9, 1)),
        message("a1", "assistant", "Between one and one and a half bar when cold.", at: date(9, 1, 5)),
        message("q2", "user", "And the radiator in the spare room is cold?", at: date(9, 2)),
        message("a2", "assistant", "Bleed it from the valve at the top.", at: date(9, 2, 5)),
        message("q3", "user", "Thanks, what's the weather tomorrow?", at: date(9, 3)),
        message("a3", "assistant", "Rain in the afternoon.", at: date(9, 3, 5)),
    ]

    // MARK: - The turn, and nothing else

    func testTheTurnIsTheQuestionBeforeTheReplyAndTheReply() throws {
        let turn = try XCTUnwrap(ReportedReplyScope.turn(in: Self.threeTurns, reportedId: "a2"))
        XCTAssertEqual(turn.messages.map(\.id), ["q2", "a2"])
        XCTAssertEqual(turn.question?.id, "q2")
        XCTAssertEqual(turn.replyId, "a2")
        XCTAssertEqual(turn.after, Self.date(9, 1, 5), "the turn starts after the previous reply")
    }

    func testTheReportCarriesTheTurnAndNothingElseByDefault() throws {
        let thread = Self.thread(Self.threeTurns)
        let traces = [Self.trace(at: Self.date(9, 1, 1), thread: "t", model: "first-turn-model"),
                      Self.trace(at: Self.date(9, 2, 1), thread: "t", model: "claude-test-model"),
                      Self.trace(at: Self.date(9, 3, 1), thread: "t", model: "third-turn-model")]
        let selection = JobTranscriptExport.replySelection(threadId: "t", messageId: "a2",
                                                           threads: [thread], traces: traces,
                                                           now: Self.date(18, 0))
        let conversation = try XCTUnwrap(selection.conversation)
        XCTAssertEqual(conversation.lines.map(\.text),
                       ["And the radiator in the spare room is cold?", "Bleed it from the valve at the top."])
        XCTAssertEqual(selection.traces.map(\.model), ["claude-test-model"])
        XCTAssertEqual(selection.answeredBy, "Anthropic (Claude) / claude-test-model")
        // The app's events and debug lines reach a minute either side of the turn, no further.
        XCTAssertEqual(selection.window.start, Self.date(9, 1, 0))
        XCTAssertEqual(selection.window.end, Self.date(9, 3, 5))

        let document = JobTranscriptExport.document(
            scope: .reply(threadId: "t", messageId: "a2"), jobs: [], exportedAt: Self.date(18, 0),
            timeZone: Self.utc, conversations: [conversation],
            details: .init(traces: selection.traces, phone: ["App: 1.0 (729)"], app: "1.0 (729), TestFlight"),
            answeredBy: selection.answeredBy)
        let body = document.body
        XCTAssertTrue(body.contains("Technician: And the radiator in the spare room is cold?"))
        XCTAssertTrue(body.contains("Assistant: Bleed it from the valve at the top."))
        XCTAssertTrue(body.contains("Answered by: Anthropic (Claude) / claude-test-model"))
        XCTAssertTrue(body.contains("App 1.0 (729), TestFlight"), "the build identity travels with it")
        XCTAssertTrue(body.contains(JobTranscriptExport.replyPreamble))
        XCTAssertTrue(body.contains(JobTranscriptExport.replyTroubleshootingPreamble))
        for other in ["boiler run at", "one and a half bar", "weather tomorrow", "Rain in the afternoon",
                      "first-turn-model", "third-turn-model", "You are a helpful assistant",
                      "Boiler pressure and the cat"] {
            XCTAssertFalse(body.contains(other), "the report carries nothing else of the thread: \(other)")
        }
        XCTAssertTrue(document.title.hasPrefix("Reported reply support report — 2026-11-19 09:02"))
        XCTAssertEqual(document.lineCount, 2)
        XCTAssertEqual(document.turnCount, 1)
    }

    func testTheReportStillMasksKeysAndConfiguredSecrets() throws {
        // Built at run time, so no key-shaped literal sits in the source for a secret scanner.
        let keyShaped = "sk-" + "ant-" + String(repeating: "Q7x", count: 8)
        let messages = [
            Self.message("q", "user", "my gateway code is plover-quartz-lantern, does it work?", at: Self.date(9, 1)),
            Self.message("a", "assistant", "Try \(keyShaped) instead.", at: Self.date(9, 1, 5)),
        ]
        let selection = JobTranscriptExport.replySelection(threadId: "t", messageId: "a",
                                                           threads: [Self.thread(messages)], traces: [],
                                                           now: Self.date(18, 0))
        let document = JobTranscriptExport.document(
            scope: .reply(threadId: "t", messageId: "a"), jobs: [], exportedAt: Self.date(18, 0),
            timeZone: Self.utc, conversations: [try XCTUnwrap(selection.conversation)],
            details: .init(), secrets: ["plover-quartz-lantern"], answeredBy: selection.answeredBy)
        XCTAssertFalse(document.body.contains("plover-quartz-lantern"))
        XCTAssertFalse(document.body.contains(keyShaped))
        XCTAssertFalse(document.redactionHits.isEmpty)
        XCTAssertTrue(document.body.contains("Answered by: not recorded on this phone"))
    }

    // MARK: - Boundaries

    func testTheFirstReplyInAThreadHasNoQuestion() throws {
        let messages = [
            Self.message("s", "system", "Instructions", at: Self.date(9, 0)),
            Self.message("a0", "assistant", "Good morning. Your first job is at ten.", at: Self.date(9, 0, 1)),
            Self.message("q1", "user", "Thanks", at: Self.date(9, 1)),
            Self.message("a1", "assistant", "You're welcome.", at: Self.date(9, 1, 5)),
        ]
        let turn = try XCTUnwrap(ReportedReplyScope.turn(in: messages, reportedId: "a0"))
        XCTAssertNil(turn.question)
        XCTAssertEqual(turn.messages.map(\.id), ["a0"])
        XCTAssertNil(turn.after, "nothing came before it, so any earlier record of this thread is its own")
    }

    /// The pinned boundary: a tool round's interim line and the reply belong together, back to the
    /// question. Whatever the assistant said after the reported reply does not.
    func testAReplyAfterAToolRoundKeepsTheTurnsEarlierLinesAndNothingAfter() throws {
        let messages = [
            Self.message("q1", "user", "Is it going to rain?", at: Self.date(9, 1)),
            Self.message("a1", "assistant", "No.", at: Self.date(9, 1, 5)),
            Self.message("q2", "user", "Book the plumber for Friday", at: Self.date(9, 2)),
            Self.message("a2a", "assistant", "Checking your calendar.", at: Self.date(9, 2, 3)),
            Self.message("a2b", "assistant", "Booked for Friday at nine.", at: Self.date(9, 2, 8)),
            Self.message("a2c", "assistant", "I also added a reminder.", at: Self.date(9, 2, 9)),
        ]
        let turn = try XCTUnwrap(ReportedReplyScope.turn(in: messages, reportedId: "a2b"))
        XCTAssertEqual(turn.messages.map(\.id), ["q2", "a2a", "a2b"])
        XCTAssertEqual(turn.after, Self.date(9, 1, 5))

        let interim = try XCTUnwrap(ReportedReplyScope.turn(in: messages, reportedId: "a2a"))
        XCTAssertEqual(interim.messages.map(\.id), ["q2", "a2a"])
    }

    func testTheTurnsRecordsAreTheOnesBetweenThePreviousMessageAndTheReply() throws {
        let turn = try XCTUnwrap(ReportedReplyScope.turn(in: Self.threeTurns, reportedId: "a2"))
        let traces = [
            Self.trace(at: Self.date(9, 1, 5), thread: "t", model: "at-the-previous-reply"),
            Self.trace(at: Self.date(9, 2, 1), thread: "t", model: "this-turn"),
            Self.trace(at: Self.date(9, 2, 5), thread: "t", model: "at-the-reply"),
            Self.trace(at: Self.date(9, 2, 1), thread: "elsewhere", model: "another-thread"),
            Self.trace(at: Self.date(9, 2, 1), thread: nil, model: "no-thread"),
            Self.trace(at: Self.date(9, 2, 6), thread: "t", model: "after-the-reply"),
        ]
        XCTAssertEqual(ReportedReplyScope.traces(traces, threadId: "t", for: turn).map(\.model),
                       ["this-turn", "at-the-reply"])
    }

    func testAnsweredByNamesTheNewestRecordAndSaysWhenItWasOffline() {
        let reply = Self.message("a", "assistant", "Done.", at: Self.date(9, 0), answeredOnDevice: true)
        XCTAssertEqual(ReportedReplyScope.answeredBy([], reply: reply),
                       "not recorded on this phone (answered on the phone while offline)")
        let traces = [Self.trace(at: Self.date(8, 0), thread: "t", model: "older", provider: .openai),
                      Self.trace(at: Self.date(8, 1), thread: "t", model: "newer", provider: .gemini)]
        let online = Self.message("b", "assistant", "Done.", at: Self.date(9, 0))
        XCTAssertEqual(ReportedReplyScope.answeredBy(traces, reply: online), "Google (Gemini) / newer")
    }

    func testAnUnknownIdAnEmptyReplyOrAnInstructionHasNothingToReport() {
        let messages = Self.threeTurns + [Self.message("blank", "assistant", "  \n", at: Self.date(9, 4))]
        XCTAssertNil(ReportedReplyScope.turn(in: messages, reportedId: "gone"))
        XCTAssertNil(ReportedReplyScope.turn(in: messages, reportedId: "blank"))
        XCTAssertNil(ReportedReplyScope.turn(in: messages, reportedId: "s"))
        XCTAssertNil(JobTranscriptExport.replySelection(threadId: "t", messageId: "gone",
                                                        threads: [Self.thread(messages)], traces: [],
                                                        now: Self.date(18, 0)).conversation)
        XCTAssertNil(JobTranscriptExport.replySelection(threadId: "other-thread", messageId: "a2",
                                                        threads: [Self.thread(messages)], traces: [],
                                                        now: Self.date(18, 0)).conversation)
    }

    // MARK: - Who is offered the action

    func testTheWearersOwnMessageNeverOffersTheAction() {
        XCTAssertFalse(ReportedReplyScope.offersReport(role: "user", isPrivate: false))
        XCTAssertFalse(ReportedReplyScope.offersReport(role: "system", isPrivate: false))
        XCTAssertTrue(ReportedReplyScope.offersReport(role: "assistant", isPrivate: false))
        XCTAssertNil(ReportedReplyScope.turn(in: Self.threeTurns, reportedId: "q2"))
        let question = Self.threeTurns[3]
        XCTAssertNil(SupportReportRequest.reportedReply(threadId: "t", message: question, isPrivate: false))
    }

    func testTheRequestOpensOnTheReplyWithTheConversationOneSwitchAway() throws {
        let reply = Self.threeTurns[4]
        let request = try XCTUnwrap(SupportReportRequest.reportedReply(threadId: "t", message: reply,
                                                                       isPrivate: false))
        XCTAssertEqual(request.scope, .reply(threadId: "t", messageId: "a2"))
        XCTAssertTrue(request.options.troubleshooting, "the build identity and the masking come with it")
        XCTAssertFalse(request.options.otherConversations)
        XCTAssertEqual(request.widerThreadId, "t")
        XCTAssertNil(request.widerDay, "the day is not on offer: it is far more than a reply")
        XCTAssertNotNil(request.reason)
        XCTAssertTrue(JobTranscriptExport.sessions(for: request.scope, in: [], calendar: Self.calendar).isEmpty)
    }

    // MARK: - Private conversations (Plan LU)

    /// LU's support report row is `.skip`: a private conversation has no thread to export. So the
    /// action is absent — not present with a thinner report — and asking anyway finds nothing.
    func testAPrivateConversationNeverOffersOrBuildsAReport() {
        XCTAssertEqual(PrivateConversationPolicy.rule(for: .supportReport), .skip)
        XCTAssertFalse(ReportedReplyScope.offersReport(role: "assistant", isPrivate: true))
        XCTAssertNil(ReportedReplyScope.turn(in: Self.threeTurns, reportedId: "a2", isPrivate: true))
        XCTAssertNil(SupportReportRequest.reportedReply(threadId: "t", message: Self.threeTurns[4],
                                                        isPrivate: true))

        // The private page draws messages made on the spot from its in-memory transcript. They are
        // in no stored thread, so even a report asked for by id holds nothing of them.
        let synthetic = ConversationMessage(role: "assistant", content: "A private answer.")
        XCTAssertNil(JobTranscriptExport.replySelection(threadId: "t", messageId: synthetic.id,
                                                        threads: [Self.thread(Self.threeTurns)],
                                                        traces: [], now: Self.date(18, 0)).conversation)
    }

    // MARK: - The call sites

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    private func sources() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sourcesRoot,
                                                                      includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(files.count, 100, "the scan found the sources")
        return files
    }

    /// `onReport:` as an argument label, not the end of a longer name (`GenerationReport:`).
    private static func passesReport(_ line: String) -> Bool {
        line.range(of: #"(?<![A-Za-z0-9_])onReport:"#, options: .regularExpression) != nil
    }

    /// Every bubble that is handed a Report action gets it from `AppState.replyReportRequest`,
    /// which consults the private conversation; the private page's bubbles are handed none.
    func testEveryReportActionGoesThroughThePrivateCheckAndThePrivatePageHasNone() throws {
        var passing: [String] = []
        for (name, text) in try sources() where name != "MessageBubble.swift" {
            let lines = text.components(separatedBy: .newlines)
            guard lines.contains(where: Self.passesReport) else { continue }
            passing.append(name)
            XCTAssertTrue(text.contains("appState.replyReportRequest(threadId:"),
                          "\(name) passes onReport without asking replyReportRequest")
            for line in lines where Self.passesReport(line) {
                XCTAssertTrue(line.contains("reportAction(for: message)"), "\(name): \(line)")
            }
        }
        XCTAssertEqual(Set(passing), ["ChatThreadView.swift", "ConversationPageBody.swift", "JobTranscriptView.swift"])

        let privatePage = try XCTUnwrap(try sources().first { $0.name == "PrivateConversationViews.swift" })
        let bubbles = privatePage.text.components(separatedBy: .newlines).filter { $0.contains("MessageBubble(") }
        XCTAssertFalse(bubbles.isEmpty)
        XCTAssertFalse(bubbles.contains { $0.contains("onReport") }, "a private bubble is offered a report")

        let reporting = try XCTUnwrap(try sources().first { $0.name == "SupportReporting.swift" })
        XCTAssertTrue(reporting.text.contains("isPrivate: privateConversation.isActive || PrivateConversationGate.isActive"))
    }
}
