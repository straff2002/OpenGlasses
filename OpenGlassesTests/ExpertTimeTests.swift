import XCTest
import PDFKit
@testable import OpenGlasses

// Plan KM P4 — an expert's time on the record and the statement: the reply checked against the
// call the technician's phone saw, billable minutes by the contracted expert's rule, `expert_time`
// on the record (minutes, never a rate), the audience rules for the office and the customer, the
// organisation's `ExpertStatement`, and the expert's own `ExpertLedger`.
//
// Every name, number, company and figure here is invented.

extension AssistingFixture {
    /// The calendar statements and ledgers are read in, in tests: UTC, so a month is the same
    /// wherever the tests run.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A time reply as the expert's app writes it.
    static func timeReply(handoverId: String = "H-1", organisation: String = "Kestrel Heating", jobReference: String? = "4471",
                          expertId: String = "sam", expertName: String = "Sam Ferreira", minutes: Int,
                          callMinutes: Int? = nil, uncounted: Int = 0, doneAt: Date? = nil,
                          coachingReplyIds: [String]? = nil) -> ExpertTimeReply {
        let done = doneAt ?? start.addingTimeInterval(Double(minutes) * 60)
        return ExpertTimeReply(type: ExpertHandover.typeIdentifier, version: ExpertHandover.version, kind: ExpertTimeReply.kind,
                               handoverId: handoverId, jobReference: jobReference, organisation: organisation,
                               generationsSeen: [1], acceptedAt: done.addingTimeInterval(-Double(minutes) * 60), doneAt: done,
                               minutes: minutes, uncountedMinutes: uncounted, callMinutes: callMinutes, note: nil,
                               expert: .init(listId: expertId, listName: expertName, cardId: nil, phone: nil, faceTimeHandle: nil),
                               createdAt: done, coachingReplyIds: coachingReplyIds)
    }
}

/// The technician's side: a job that sent a handover to an expert, called them, and got replies.
enum ExpertTimeFixture {
    static let start = AssistingFixture.start

    static let rate = EscalationContact.Rate(perHour: 60, minimumMinutes: 15, roundingMinutes: 15, currency: "GBP")

    static func contracted(id: String = "sam", name: String = "Sam Ferreira", rate: EscalationContact.Rate? = rate) -> EscalationContact {
        EscalationContact(id: id, name: name, phone: "+64 21 000 1111", kind: .contracted, rate: rate)
    }

    static func staff(id: String = "sam", name: String = "Sam Ferreira") -> EscalationContact {
        EscalationContact(id: id, name: name, phone: "+64 21 000 1111", kind: .staff)
    }

    /// A job that sent `handoverId` to the expert, with an observed call when `call` is given
    /// (seconds connected), and the call's billing grain on the escalation.
    static func job(id: String = "job-s1", reference: String? = "4471", handoverId: String = "H-1",
                    expert: EscalationContact = contracted(), started: Date = start,
                    call: TimeInterval? = nil, connectSeen: Bool = true) -> FieldSession {
        var session = FieldSession(id: id, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: started, outcome: .inProgress, escalations: [], billableSeconds: 0)
        session.jobReference = reference
        let snapshot = expert.snapshot
        let handover = AssistingFixture.handover(id: handoverId, expertId: expert.id, expertName: expert.name)
        session.expertHandovers = [AssistingFixture.sent(handover, expert: snapshot)]
        if let call {
            let placed = started.addingTimeInterval(60)
            let connected = placed.addingTimeInterval(20)
            session.escalations = [FieldSession.Escalation(
                timestamp: placed, reason: "Called \(expert.name)", resolvedAt: nil, expert: snapshot, callVia: "facetime",
                callStartedAt: placed, callConnectedAt: connectSeen ? connected : nil,
                callEndedAt: connected.addingTimeInterval(call), billing: expert.billingRule)]
        }
        return session
    }

    /// The reply matched onto the job, as the intake attaches it.
    static func attach(_ reply: ExpertTimeReply, to session: inout FieldSession, list: [EscalationContact]) throws {
        let match = try ExpertReplyMatch.match(reply, sessions: [session], organisationExperts: list, now: start).get()
        session.expertReplies = (session.expertReplies ?? []) + [match.received]
    }
}

// MARK: - The reconciliation

final class ExpertTimeReconcilerTests: XCTestCase {

    private let observed = ObservedExpertCallTime(minutes: 22, measuredFrom: .connected, endedAt: AssistingFixture.start)

    func testAReplyWithinAMinuteOfTheObservedCallAgrees() {
        XCTAssertEqual(ExpertTimeReconciler.toleranceMinutes, 1)
        for reported in [21, 22, 23] {
            XCTAssertEqual(ExpertTimeReconciler.reconcile(hasReply: true, reportedCallMinutes: reported, observed: observed), .agrees,
                           "\(reported)")
        }
    }

    func testAReplyThatDiffersSaysByHowMuchAndIsNeverSettled() {
        let more = ExpertTimeReconciler.reconcile(hasReply: true, reportedCallMinutes: 28, observed: observed)
        XCTAssertEqual(more, .differs(byMinutes: 6))
        let sentence = more.sentence(reportedCallMinutes: 28, observed: observed)
        XCTAssertTrue(sentence.contains("differs by 6 minutes"), sentence)
        XCTAssertTrue(sentence.contains("the reply says 28 minutes, this phone saw 22 minutes"), sentence)
        XCTAssertTrue(sentence.contains("doesn't settle"), sentence)
        XCTAssertEqual(ExpertTimeReconciler.reconcile(hasReply: true, reportedCallMinutes: 19, observed: observed),
                       .differs(byMinutes: -3))
        XCTAssertEqual(ExpertTimeReconciliation.differs(byMinutes: -3).statementNote, "reply 3 min less than the call seen")
    }

    func testNoReplyCarriesTheObservedCallOnlyLabelled() throws {
        let session = ExpertTimeFixture.job(call: 22 * 60)
        let time = try XCTUnwrap(ExpertTime.build(session: session).first)
        XCTAssertEqual(time.source, .observedCall)
        XCTAssertEqual(time.reconciliation, .observedCallOnly)
        XCTAssertEqual(time.minutes, 22)
        XCTAssertEqual(time.observedCallMinutes, 22)
        XCTAssertNil(time.reviewMinutes)
        XCTAssertTrue(time.lines.joined().contains("on the call this phone saw"))
        XCTAssertTrue(time.lines.joined().contains("No reply from the expert: this is the call this phone saw, only"))
    }

    func testAReplyAndNoObservedCallCarriesTheReplyOnlyLabelled() throws {
        var session = ExpertTimeFixture.job()
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(minutes: 34, callMinutes: 20), to: &session,
                                     list: [ExpertTimeFixture.contracted()])
        let time = try XCTUnwrap(ExpertTime.build(session: session).first)
        XCTAssertEqual(time.source, .reply)
        XCTAssertEqual(time.reconciliation, .replyOnly)
        XCTAssertEqual(time.minutes, 34)
        XCTAssertTrue(time.lines.joined().contains("The expert's reply only"))
    }

    func testAReplyWithoutCallMinutesIsNotComparedToAGuess() throws {
        var session = ExpertTimeFixture.job(call: 20 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(minutes: 30), to: &session, list: [ExpertTimeFixture.contracted()])
        let time = try XCTUnwrap(ExpertTime.build(session: session).first)
        XCTAssertEqual(time.reconciliation, .replyWithoutCallMinutes)
        XCTAssertEqual(time.minutes, 30, "the reply's clock is the time")
        XCTAssertEqual(time.observedCallMinutes, 20)
    }

    func testTheObservedCallRunsFromConnectOrFromPlacedWhenTheConnectWasNotSeen() throws {
        let connected = try XCTUnwrap(ExpertTimeReconciler.observedCall(
            expertId: "sam", escalations: ExpertTimeFixture.job(call: 10 * 60).escalations))
        XCTAssertEqual(connected.minutes, 10)
        XCTAssertEqual(connected.measuredFrom, .connected)
        let placed = try XCTUnwrap(ExpertTimeReconciler.observedCall(
            expertId: "sam", escalations: ExpertTimeFixture.job(call: 10 * 60, connectSeen: false).escalations))
        XCTAssertEqual(placed.minutes, 10, "placed 20 s before the connect would have been: 10 min 20 s")
        XCTAssertEqual(placed.measuredFrom, .placed)
        XCTAssertTrue(ExpertTimeReconciliation.observedCallOnly.sentence(reportedCallMinutes: nil, observed: placed)
            .contains("didn't see it connect"))
        // Another expert's call is not this one's, and a call not yet ended is no call.
        XCTAssertNil(ExpertTimeReconciler.observedCall(expertId: "priya", escalations: ExpertTimeFixture.job(call: 600).escalations))
        var open = ExpertTimeFixture.job(call: 600)
        open.escalations[0].callEndedAt = nil
        XCTAssertNil(ExpertTimeReconciler.observedCall(expertId: "sam", escalations: open.escalations))
        XCTAssertTrue(ExpertTime.build(session: open).isEmpty, "no reply and no ended call is no time yet")
    }

    func testTheReconciliationRoundTripsThroughTheRecord() throws {
        let decoder = JSONDecoder()
        for value in [ExpertTimeReconciliation.agrees, .differs(byMinutes: -4), .observedCallOnly, .replyOnly, .replyWithoutCallMinutes] {
            XCTAssertEqual(try decoder.decode(ExpertTimeReconciliation.self, from: JSONEncoder().encode(value)), value)
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExpertTimeReconciliation.differs(byMinutes: 6)))
        XCTAssertEqual(encoded as? NSDictionary, ["result": "differs", "by_minutes": 6] as NSDictionary)
    }
}

// MARK: - Billable minutes

final class ExpertBillingTests: XCTestCase {

    func testTheMinimumFirstThenUpToTheGrain() {
        let rule = ExpertBillingRule(minimumMinutes: 15, roundingMinutes: 15)
        XCTAssertEqual(rule.billableMinutes(for: 0), 0, "nothing on the clock bills nothing")
        XCTAssertEqual(rule.billableMinutes(for: 1), 15)
        XCTAssertEqual(rule.billableMinutes(for: 7), 15)
        XCTAssertEqual(rule.billableMinutes(for: 15), 15)
        XCTAssertEqual(rule.billableMinutes(for: 16), 30)
        XCTAssertEqual(rule.billableMinutes(for: 34), 45)
        let longMinimum = ExpertBillingRule(minimumMinutes: 30, roundingMinutes: 10)
        XCTAssertEqual(longMinimum.billableMinutes(for: 12), 30)
        XCTAssertEqual(longMinimum.billableMinutes(for: 34), 40)
        XCTAssertEqual(ExpertBillingRule(minimumMinutes: 0, roundingMinutes: 1).billableMinutes(for: 7), 7)
        // A hand-edited job can't make a zero grain.
        XCTAssertEqual(ExpertBillingRule(minimumMinutes: -5, roundingMinutes: 0), ExpertBillingRule(minimumMinutes: 0, roundingMinutes: 1))
        let decoded = try? JSONDecoder().decode(ExpertBillingRule.self, from: Data(#"{"minimumMinutes":5,"roundingMinutes":0}"#.utf8))
        XCTAssertEqual(decoded?.roundingMinutes, 1)
    }

    func testAContractedExpertsReplyIsBilledByTheRuleKeptOnTheJob() throws {
        var session = ExpertTimeFixture.job(call: 33 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(minutes: 34, callMinutes: 33), to: &session,
                                     list: [ExpertTimeFixture.contracted()])
        XCTAssertEqual(session.expertReplies?.first?.billing, ExpertBillingRule(minimumMinutes: 15, roundingMinutes: 15))
        let time = try XCTUnwrap(ExpertTime.build(session: session).first)
        XCTAssertEqual(time.billableMinutes, 45)
        XCTAssertEqual(time.reconciliation, .agrees)
        XCTAssertTrue(time.lines[0].contains("34 minutes on their clock; 45 billable"), time.lines[0])

        // No reply: the observed call, by the rule the call kept.
        let observedOnly = try XCTUnwrap(ExpertTime.build(session: ExpertTimeFixture.job(call: 7 * 60)).first)
        XCTAssertEqual(observedOnly.billableMinutes, 15)
    }

    func testAStaffExpertHasMinutesAndNoBillableFigure() throws {
        var session = ExpertTimeFixture.job(expert: ExpertTimeFixture.staff(), call: 20 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(minutes: 25, callMinutes: 20), to: &session,
                                     list: [ExpertTimeFixture.staff()])
        let time = try XCTUnwrap(ExpertTime.build(session: session).first)
        XCTAssertEqual(time.kind, .staff)
        XCTAssertEqual(time.minutes, 25)
        XCTAssertNil(time.billableMinutes)
        XCTAssertNil(session.expertReplies?.first?.billing)
        XCTAssertNil(session.escalations.first?.billing)
        XCTAssertFalse(time.lines.joined().contains("billable"))
    }

    func testTheCallRecordsTheGrainButNeverTheRate() throws {
        let directory = AssistingFixture.temporaryDirectory("escalation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let labels = Set(Mirror(reflecting: ExpertTimeFixture.job(call: 60).escalations[0]).children.compactMap(\.label))
        XCTAssertTrue(labels.contains("billing"))
        XCTAssertTrue(labels.isDisjoint(with: ["rate", "perHour", "currency", "amount"]))
        XCTAssertEqual(Set(Mirror(reflecting: ExpertBillingRule(minimumMinutes: 1, roundingMinutes: 1)).children.compactMap(\.label)),
                       ["minimumMinutes", "roundingMinutes"])
    }
}

// MARK: - The record and its audiences

@MainActor
final class ExpertTimeRecordTests: XCTestCase {

    private var directory: URL!
    private var priorShows: Any?

    override func setUp() async throws {
        directory = AssistingFixture.temporaryDirectory("expert-time")
        priorShows = UserDefaults.standard.object(forKey: SettingKey.customerReportShowsExpertTime.rawValue)
        UserDefaults.standard.removeObject(forKey: SettingKey.customerReportShowsExpertTime.rawValue)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        if let priorShows { UserDefaults.standard.set(priorShows, forKey: SettingKey.customerReportShowsExpertTime.rawValue) }
        else { UserDefaults.standard.removeObject(forKey: SettingKey.customerReportShowsExpertTime.rawValue) }
    }

    /// A job with a contracted expert's reply, their coaching walked, and the call to them.
    private func job() throws -> FieldSession {
        var session = ExpertTimeFixture.job(call: 22 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(minutes: 34, callMinutes: 28, coachingReplyIds: ["coach-a"]),
                                     to: &session, list: [ExpertTimeFixture.contracted()])
        let handover = AssistingFixture.handover(id: "H-1", expertId: "sam", expertName: "Sam Ferreira")
        let coaching = try CoachingFixture.reply(for: [handover], directory: directory)
        let accepted = try CoachingReplyMatch.match(
            coaching, openJob: session, otherJobs: [], lockedSessionIds: [],
            organisationExperts: [ExpertTimeFixture.contracted()], coreFiles: [], medicalMode: false,
            now: AssistingFixture.start).get()
        session.expertCoaching = [accepted.received]
        session.tasks = [FieldSession.Task(title: "Coaching from \(accepted.received.credit)", origin: .operatorAdded,
                                           status: .done, procedureId: accepted.received.procedureId, procedureOutcome: "resolved")]
        return session
    }

    func testTheOfficeRecordCarriesExpertTimeInMinutes() throws {
        let record = WorkRecord(session: try job(), vaultName: "Refrigeration")
        let time = try XCTUnwrap(record.expertTime?.first)
        XCTAssertEqual(time.expertName, "Sam Ferreira")
        XCTAssertEqual(time.kind, .contracted)
        XCTAssertEqual(time.reviewMinutes, 34)
        XCTAssertEqual(time.callMinutes, 28)
        XCTAssertEqual(time.observedCallMinutes, 22)
        XCTAssertEqual(time.billableMinutes, 45)
        XCTAssertEqual(time.reconciliation, .differs(byMinutes: 6))
        XCTAssertEqual(time.coachingRepliesSent, 1)
        XCTAssertEqual(time.coachingRepliesNotReceived, 1, "the reply names coaching this job never got")
        let json = record.jsonString
        for key in ["\"expert_time\"", "\"review_minutes\" : 34", "\"call_minutes\" : 28", "\"observed_call_minutes\" : 22",
                    "\"billable_minutes\" : 45", "\"accepted_at\"", "\"result\" : \"differs\"", "\"by_minutes\" : 6"] {
            XCTAssertTrue(json.contains(key), key)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WorkRecord.self, from: record.json).expertTime, record.expertTime)
        XCTAssertTrue(record.summaryLines.contains { $0.hasPrefix("Expert time: Sam Ferreira (contracted expert) — 34 minutes") })

        // The office's export keeps it, and the expert's credit on the coaching.
        let office = SessionExporter.exportedRecord(session: try job(), audience: .office, showsExpertTime: false)
        XCTAssertNotNil(office.expertTime)
        XCTAssertEqual(office.coachingWalkthroughs?.first?.credit, "Sam Ferreira (contracted expert)")

        // A job that called nobody by name carries no key at all.
        let plain = WorkRecord(session: AssistingFixture.session(), vaultName: "Refrigeration")
        XCTAssertNil(plain.expertTime)
        XCTAssertFalse(plain.jsonString.contains("expert_time"))
    }

    func testTheCustomersRecordNeverCarriesExpertTimeOrTheCreditUnlessTurnedOn() throws {
        let customer = SessionExporter.exportedRecord(session: try job(), audience: .customer, showsExpertTime: false)
        XCTAssertNil(customer.expertTime)
        let walkthrough = try XCTUnwrap(customer.coachingWalkthroughs?.first)
        XCTAssertNil(walkthrough.credit)
        XCTAssertNil(walkthrough.expertKind)
        XCTAssertEqual(walkthrough.steps.map(\.instruction), CoachingFixture.steps.map(\.instruction), "the work done stays")
        let text = customer.summaryLines.joined(separator: "\n") + customer.jsonString
        for leak in ["Sam", "Ferreira", "contracted expert", "staff expert", "expert_time"] {
            XCTAssertFalse(text.contains(leak), leak)
        }
        XCTAssertTrue(customer.summaryLines.contains("Steps walked on this job — finished as resolved."))
        XCTAssertTrue(customer.summaryLines.contains { $0.hasPrefix("Escalated: Called an expert.") })
        XCTAssertFalse(CustomerSummary.lines(for: WorkRecord(session: try job(), vaultName: "R"), showsExpertTime: false)
            .joined().contains("Sam"))

        // Turned on, the customer's record shows the name and minutes — and still no rate.
        let shown = SessionExporter.exportedRecord(session: try job(), audience: .customer, showsExpertTime: true)
        XCTAssertNotNil(shown.expertTime)
        XCTAssertEqual(shown.coachingWalkthroughs?.first?.credit, "Sam Ferreira (contracted expert)")
        XCTAssertFalse(shown.jsonString.contains("GBP"))
    }

    func testTheWorkOrderPDFNeverCarriesExpertTimeOrTheCreditUnlessTurnedOn() throws {
        let session = try job()
        let sessionDir = directory.appendingPathComponent(session.id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let event = SessionLogger.Event(timestamp: AssistingFixture.start, kind: .escalationRequested,
                                        text: "Called Sam Ferreira", payload: nil)
        try (String(decoding: try encoder.encode(event), as: UTF8.self) + "\n")
            .write(to: sessionDir.appendingPathComponent("log.jsonl"), atomically: true, encoding: .utf8)

        // The office's export, rendered as the work order: the PDF is the customer's document.
        let office = try XCTUnwrap(SessionExporter.buildExport(sessionDir: sessionDir, sessionOverride: session))
        XCTAssertNotNil(office.workRecord?.expertTime, "the office's JSON keeps it")
        let hidden = directory.appendingPathComponent("hidden.pdf")
        try SessionExporter.writePDF(office, to: hidden, showsExpertTime: false)
        let text = try XCTUnwrap(PDFDocument(url: hidden)?.string)
        for leak in ["Sam", "Ferreira", "contracted expert", "Expert time", "billable"] {
            XCTAssertFalse(text.contains(leak), "the customer's PDF carries \(leak)")
        }
        XCTAssertTrue(text.contains("Steps walked on this job"))
        XCTAssertTrue(text.contains("Called an expert."))
        XCTAssertTrue(text.contains(CoachingFixture.hoseStep), "the steps are work done")

        let shown = directory.appendingPathComponent("shown.pdf")
        try SessionExporter.writePDF(office, to: shown, showsExpertTime: true)
        let shownText = try XCTUnwrap(PDFDocument(url: shown)?.string)
        XCTAssertTrue(shownText.contains("Sam Ferreira (contracted expert)"))
        XCTAssertTrue(shownText.contains("Expert time"))
        XCTAssertFalse(shownText.contains("GBP"))
        XCTAssertFalse(shownText.contains("60.00"))

        // A customer-audience export scrubs the log's escalation too.
        let customer = try XCTUnwrap(SessionExporter.buildExport(
            sessionDir: sessionDir, sessionOverride: session,
            transcript: ReportTranscriptPolicy.decide(channel: .email, recipients: ["someone@example.com"],
                                                      carriesFiles: true, context: .init())))
        XCTAssertEqual(customer.escalations.map(\.reason), ["Called an expert."])
        XCTAssertNil(customer.workRecord?.expertTime)
    }

    func testAReportsMessageBodyIsTheCustomersCopyUnlessItGoesToTheOffice() throws {
        let record = WorkRecord(session: try job(), vaultName: "Refrigeration")
        let unknown = DeliveryRequest.make(record: record, channel: .email, recipients: ["someone@example.com"], attachments: [])
        XCTAssertFalse(unknown.body.contains("Sam"))
        XCTAssertFalse(unknown.body.contains("Expert time"))
    }

    // MARK: - The technician never sees a rate

    func testTheTechniciansViewsNeverShowARate() throws {
        // The record's own value has nowhere to put one.
        let labels = Set(Mirror(reflecting: try XCTUnwrap(WorkRecord(session: try job(), vaultName: "R").expertTime?.first))
            .children.compactMap(\.label))
        XCTAssertTrue(labels.isDisjoint(with: ["rate", "perHour", "currency", "amount", "money"]), "\(labels)")
        XCTAssertTrue(Set(Mirror(reflecting: try job().expertReplies![0]).children.compactMap(\.label))
            .isDisjoint(with: ["rate", "perHour", "currency", "amount"]))

        // What the technician reads and hears: the read-back, the JSON, the Job tab's lines.
        let rated = ExpertTimeFixture.contracted(rate: .init(perHour: 87.5, minimumMinutes: 15, roundingMinutes: 15, currency: "NZD"))
        var session = ExpertTimeFixture.job(expert: rated, call: 22 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(minutes: 34, callMinutes: 22), to: &session, list: [rated])
        let record = WorkRecord(session: session, vaultName: "Refrigeration")
        let everything = record.summaryLines.joined(separator: "\n") + record.jsonString + record.shortSummary
        for money in ["NZD", "87.5", "87.50", "per hour", "\"rate\"", "amount"] {
            XCTAssertFalse(everything.contains(money), "the technician's record shows \(money)")
        }

        // And no technician surface's source names a rate, an amount or the statement.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
        var files = ["Services/FieldAssist/WorkRecord.swift", "Services/FieldAssist/WorkRecordSurface.swift",
                     // Not ExpertReplyIntake.swift: beside the reply intake it holds the device owner's
                     // card import, which keeps the rate the owner set on their own list.
                     "Services/FieldAssist/Experts/ExpertTime.swift",
                     "Services/FieldAssist/Experts/ExpertCoachingIntake.swift", "Services/FieldAssist/Job/JobTabModel.swift",
                     "Services/FieldAssist/Job/CustomerSignOff.swift", "Services/FieldAssist/DeliveryRequest.swift",
                     "Services/NativeTools/EscalateToExpertTool.swift", "Services/NativeTools/TaskTool.swift"]
        let jobViews = root.appendingPathComponent("App/Views/Job")
        files += try FileManager.default.contentsOfDirectory(atPath: jobViews.path).filter { $0.hasSuffix(".swift") }
            .map { "App/Views/Job/\($0)" }
        XCTAssertGreaterThan(files.count, 12)
        for file in files {
            var code = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            code = code.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
            for symbol in ["perHour", "currency", "ExpertStatement", "\\.rate\\b"] {
                XCTAssertNil(code.range(of: symbol, options: .regularExpression), "\(file) names \(symbol)")
            }
        }
    }
}

// MARK: - The statement

final class ExpertStatementTests: XCTestCase {

    private let calendar = AssistingFixture.calendar
    private var month: CalendarMonth { CalendarMonth(AssistingFixture.start, calendar: calendar) }

    /// Three jobs for Sam this month and one next month.
    private func jobs(expert: EscalationContact = ExpertTimeFixture.contracted()) throws -> [FieldSession] {
        var a = ExpertTimeFixture.job(id: "job-a", reference: "4471", handoverId: "H-A", expert: expert, call: 33 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(handoverId: "H-A", minutes: 34, callMinutes: 33), to: &a, list: [expert])
        var b = ExpertTimeFixture.job(id: "job-b", reference: "4480", handoverId: "H-B", expert: expert, call: 10 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(handoverId: "H-B", jobReference: "4480", minutes: 7, callMinutes: 16,
                                                                doneAt: AssistingFixture.start.addingTimeInterval(86_400)),
                                     to: &b, list: [expert])
        let c = ExpertTimeFixture.job(id: "job-c", reference: "4492", handoverId: "H-C", expert: expert,
                                      started: AssistingFixture.start.addingTimeInterval(2 * 86_400), call: 20 * 60)
        var later = ExpertTimeFixture.job(id: "job-d", reference: "4600", handoverId: "H-D", expert: expert,
                                          started: AssistingFixture.start.addingTimeInterval(40 * 86_400))
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(handoverId: "H-D", jobReference: "4600", minutes: 50,
                                                                doneAt: AssistingFixture.start.addingTimeInterval(40 * 86_400)),
                                     to: &later, list: [expert])
        return [a, b, c, later]
    }

    private func statement(_ expert: EscalationContact = ExpertTimeFixture.contracted(), listed: EscalationContact? = nil) throws -> ExpertStatement {
        ExpertStatement.build(expert: expert.snapshot, listed: listed ?? expert, month: month, sessions: try jobs(expert: expert),
                              organisation: "Kestrel Heating", calendar: calendar, preparedAt: AssistingFixture.start)
    }

    func testOneRowPerJobThisMonthWithATotal() throws {
        let statement = try statement()
        XCTAssertEqual(statement.rows.map(\.jobReference), ["4471", "4480", "4492"])
        XCTAssertEqual(statement.rows.map(\.minutes), [34, 7, 20])
        XCTAssertEqual(statement.rows.map(\.billableMinutes), [45, 15, 30])
        XCTAssertEqual(statement.rows.map(\.amount), [45, 15, 30])
        XCTAssertEqual(statement.totalMinutes, 61)
        XCTAssertEqual(statement.totalBillableMinutes, 90)
        XCTAssertEqual(statement.totalAmount, 90)
        XCTAssertEqual(statement.rows.map(\.reconciliation), [.agrees, .differs(byMinutes: 6), .observedCallOnly])
        XCTAssertEqual(statement.differences, 1)
        XCTAssertEqual(ExpertStatement.months(expertId: "sam", sessions: try jobs(), calendar: calendar).count, 2)
        XCTAssertEqual(ExpertStatement.experts(in: try jobs()).map(\.id), ["sam"])

        let document = statement.document(calendar: calendar)
        XCTAssertEqual(document.columns, ["Date", "Job", "Minutes", "Billable minutes", "Rate per hour", "Amount", "Check"])
        XCTAssertEqual(document.rows[0], ["2027-01-15", "4471", "34", "45", "GBP 60.00", "GBP 45.00", ""])
        XCTAssertEqual(document.total, ["Total", "3 jobs", "61", "90", "", "GBP 90.00", "1 to check"])
        let csv = document.csv
        XCTAssertTrue(csv.hasPrefix("Date,Job,Minutes,Billable minutes,Rate per hour,Amount,Check\r\n"), csv)
        XCTAssertTrue(csv.contains("Note,The amount is a figure"))
        XCTAssertTrue(csv.contains("never takes or sends a payment"))
        XCTAssertTrue(document.lede.joined().contains("GBP 60.00 an hour"))
        XCTAssertTrue(document.title.contains("Sam Ferreira") && document.title.contains("January 2027"))
        XCTAssertGreaterThan(document.pdfData().count, 500)
    }

    func testAmountsRoundToTheCent() {
        XCTAssertEqual(ExpertStatement.amount(minutes: 45, perHour: Decimal(string: "87.5")!), Decimal(string: "65.63")!)
        XCTAssertEqual(ExpertStatement.money(Decimal(string: "65.625")!), "65.63")
        XCTAssertEqual(ExpertStatement.money(90), "90.00")
    }

    func testAStaffExpertHasNoAmount() throws {
        let statement = try statement(ExpertTimeFixture.staff())
        XCTAssertFalse(statement.hasMoney)
        XCTAssertNil(statement.rate)
        XCTAssertTrue(statement.rows.allSatisfy { $0.amount == nil && $0.billableMinutes == nil })
        XCTAssertNil(statement.totalAmount)
        XCTAssertEqual(statement.totalMinutes, 61)
        let document = statement.document(calendar: calendar)
        XCTAssertEqual(document.columns, ["Date", "Job", "Minutes", "Check"])
        XCTAssertFalse(document.csv.contains("Amount"))
        XCTAssertTrue(document.lede.joined().contains("no rate and no amount"))

        // A staff entry the list later gives a rate to is still staff on the jobs: no amount.
        let relisted = ExpertTimeFixture.contracted()
        XCTAssertNil(ExpertStatement.build(expert: ExpertTimeFixture.staff().snapshot, listed: relisted, month: month,
                                           sessions: try jobs(expert: ExpertTimeFixture.staff()), organisation: nil,
                                           calendar: calendar, preparedAt: AssistingFixture.start).totalAmount)
    }

    func testAContractedExpertNoLongerRatedHasMinutesButNoAmount() throws {
        let statement = try statement(listed: ExpertTimeFixture.contracted(rate: nil))
        XCTAssertNil(statement.rate)
        XCTAssertEqual(statement.totalBillableMinutes, 90, "the jobs kept their rule")
        XCTAssertNil(statement.totalAmount)
        XCTAssertTrue(statement.document(calendar: calendar).lede.joined().contains("No rate on this phone's list"))
    }

    func testACSVCellCannotBecomeAFormula() {
        XCTAssertEqual(MinutesTableDocument.cell("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(MinutesTableDocument.cell("-12"), "-12")
        XCTAssertEqual(MinutesTableDocument.cell("Job, \"the big one\""), "\"Job, \"\"the big one\"\"\"")
    }
}

// MARK: - The expert's ledger

@MainActor
final class ExpertLedgerTests: XCTestCase {

    private let calendar = AssistingFixture.calendar
    private var directory: URL!

    override func setUp() async throws { directory = AssistingFixture.temporaryDirectory("ledger") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testALedgerBuiltFromTheSameRepliesMatchesTheOrganisationsStatement() throws {
        let expert = ExpertTimeFixture.contracted()
        let replies = [
            AssistingFixture.timeReply(handoverId: "H-A", minutes: 34, callMinutes: 33),
            AssistingFixture.timeReply(handoverId: "H-B", jobReference: "4480", minutes: 7, callMinutes: 16,
                                       doneAt: AssistingFixture.start.addingTimeInterval(86_400)),
            AssistingFixture.timeReply(handoverId: "H-C", jobReference: "4492", minutes: 61, uncounted: 3,
                                       doneAt: AssistingFixture.start.addingTimeInterval(3 * 86_400)),
        ]
        // The organisation's phone: each reply attached to the job that sent it.
        var sessions: [FieldSession] = []
        for (index, reply) in replies.enumerated() {
            var job = ExpertTimeFixture.job(id: "job-\(index)", reference: reply.jobReference, handoverId: reply.handoverId,
                                            expert: expert, call: 30 * 60)
            try ExpertTimeFixture.attach(reply, to: &job, list: [expert])
            sessions.append(job)
        }
        let month = CalendarMonth(AssistingFixture.start, calendar: calendar)
        let statement = ExpertStatement.build(expert: expert.snapshot, listed: expert, month: month, sessions: sessions,
                                              organisation: "Kestrel Heating", calendar: calendar, preparedAt: AssistingFixture.start)

        // The expert's phone: the same replies on their own ledger.
        let ledger = ExpertLedger(entries: replies.map { ExpertLedgerEntry(reply: $0, sentAt: $0.doneAt) })
        let key = HeldHandover.organisationKey("Kestrel Heating")
        let rows = ledger.rows(organisation: key, month: month, calendar: calendar)
        XCTAssertEqual(rows.map(\.jobReference), statement.rows.map(\.jobReference))
        XCTAssertEqual(rows.map(\.minutes), statement.rows.map(\.minutes))
        XCTAssertEqual(ledger.totalMinutes(organisation: key, month: month, calendar: calendar), statement.totalMinutes)
        XCTAssertEqual(statement.totalMinutes, 102)

        // The ledger has no rate anywhere.
        let document = ledger.document(organisation: key, month: month, calendar: calendar, preparedAt: AssistingFixture.start)
        XCTAssertEqual(document.columns, ["Date", "Job", "Minutes", "Call minutes", "Not counted"])
        for money in ["GBP", "60.00", "Amount", "Billable"] { XCTAssertFalse(document.csv.contains(money), money) }
        XCTAssertTrue(document.csv.contains("never takes or sends a payment"))
        XCTAssertTrue(Set(Mirror(reflecting: rows[0]).children.compactMap(\.label)).isDisjoint(with: ["rate", "amount", "currency"]))
    }

    func testTheLedgerIsWrittenOnlyWhenTheReplysShareCompletes() throws {
        let clock = AssistingTestClock()
        let store = AssistingHandoverStore(directory: directory, now: { clock.now })
        let replies = StagedExportCoordinator(channel: .assistingReply, rootDirectoryName: "unused",
                                              store: ProtectedExportFileStore(rootDirectoryName: "unused",
                                                                              root: directory.appendingPathComponent("r")))
        let service = AssistingService(store: store, cards: ExpertCardStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                       replies: replies, now: { clock.now })
        service.makeCallObserver = { LedgerFakeCallObserver() }
        XCTAssertTrue(service.open(AssistingFixture.opened(AssistingFixture.handover())).shown)
        service.take("H-1")
        clock.advance(25 * 60)
        service.done("H-1")
        let cancelled = try service.stageReply(for: "H-1", note: nil).get()
        service.finishShare(cancelled, for: "H-1", completed: false)
        XCTAssertTrue(service.ledger.entries.isEmpty, "a cancelled share sent nothing")
        let sent = try service.stageReply(for: "H-1", note: nil).get()
        service.finishShare(sent, for: "H-1", completed: true)
        XCTAssertEqual(service.ledger.entries.map(\.minutes), [25])
        XCTAssertEqual(service.ledger.entries.first?.organisation, "Kestrel Heating")
        // Sent again, the same handover is one row.
        service.finishShare(try service.stageReply(for: "H-1", note: nil).get(), for: "H-1", completed: true)
        XCTAssertEqual(service.ledger.entries.count, 1)

        // It survives a relaunch, beside the handovers, protected and out of backup.
        let reopened = ExpertLedgerStore(directory: directory, now: { clock.now })
        XCTAssertEqual(reopened.entries, service.ledger.entries)
        XCTAssertEqual(reopened.fileLocation.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        let values = try reopened.fileLocation.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(SensitiveStore.expertLedger.record.backupExcluded, true)
        XCTAssertEqual(SensitiveStore.expertLedger.record.subjectLinkage, .wearer)

        // A ledger export is one organisation's month, through the reply's own staging family.
        let month = CalendarMonth(clock.now, calendar: .current)
        let staged = try service.stageLedger(organisation: HeldHandover.organisationKey("Kestrel Heating"), month: month,
                                             pdf: false).get()
        let csv = try String(contentsOf: staged.lease.fileURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("4471"))
        service.finishShare(staged, completed: false)
        XCTAssertNotNil(service.stageLedger(organisation: "nobody", month: month, pdf: true).failureValue)

        // Old rows go, and everything goes on removeAll.
        let later = ExpertLedgerStore(directory: directory, now: { clock.now.addingTimeInterval(401 * 86_400) })
        XCTAssertTrue(later.entries.isEmpty)
        reopened.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.fileLocation.path))
    }

    // MARK: - The expert's call minutes

    func testACallSeenWhileOneClockRunsIsThatHandoversCallMinutes() throws {
        let clock = AssistingTestClock()
        let store = AssistingHandoverStore(directory: directory, now: { clock.now })
        let service = AssistingService(store: store, cards: ExpertCardStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                       now: { clock.now })
        let fake = LedgerFakeCallObserver()
        service.makeCallObserver = { fake }
        service.open(AssistingFixture.opened(AssistingFixture.handover()))
        service.take("H-1")
        let call = UUID()
        clock.advance(60)
        fake.report(ObservedCall(id: call, isOutgoing: false, hasConnected: true, hasEnded: false))
        clock.advance(22 * 60)
        fake.report(ObservedCall(id: call, isOutgoing: false, hasConnected: true, hasEnded: true))
        fake.report(ObservedCall(id: call, isOutgoing: false, hasConnected: true, hasEnded: true))
        // A call that rang out adds nothing.
        let missed = UUID()
        fake.report(ObservedCall(id: missed, isOutgoing: true, hasConnected: false, hasEnded: false))
        fake.report(ObservedCall(id: missed, isOutgoing: true, hasConnected: false, hasEnded: true))
        clock.advance(5 * 60)
        service.done("H-1")
        let reply = try XCTUnwrap(service.reply(for: "H-1", note: nil)).get()
        XCTAssertEqual(reply.callMinutes, 22)
        XCTAssertEqual(reply.minutes, 28)
        XCTAssertTrue(reply.summary.contains("Your phone saw 22 minutes of calls"), reply.summary)
        // After Done nothing more is added.
        store.recordObservedCall(id: "H-1", call: AssistingObservedCall(connectedAt: clock.now, endedAt: clock.now.addingTimeInterval(600)))
        XCTAssertEqual(store.handover(id: "H-1")?.observedCallMinutes, 22)
    }

    func testNoCallOrTwoRunningClocksCountsNothingAndSaysSo() throws {
        var tally = AssistingCallTally()
        let start = AssistingFixture.start
        let one = UUID(), two = UUID(), three = UUID()
        XCTAssertNil(tally.observe(.init(id: one, isOutgoing: false, hasConnected: true, hasEnded: false), at: start, running: []))
        XCTAssertNil(tally.observe(.init(id: one, isOutgoing: false, hasConnected: true, hasEnded: true), at: start + 600, running: []))
        XCTAssertNil(tally.observe(.init(id: two, isOutgoing: false, hasConnected: true, hasEnded: false), at: start, running: ["A", "B"]))
        XCTAssertNil(tally.observe(.init(id: two, isOutgoing: false, hasConnected: true, hasEnded: true), at: start + 600, running: ["A"]))
        XCTAssertNil(tally.observe(.init(id: three, isOutgoing: false, hasConnected: true, hasEnded: false), at: start, running: ["A"]))
        let done = tally.observe(.init(id: three, isOutgoing: false, hasConnected: true, hasEnded: true), at: start + 300, running: [])
        XCTAssertEqual(done, .init(handoverId: "A", call: .init(connectedAt: start, endedAt: start + 300)),
                       "decided at the connect: the clock may stop before the call does")

        let held = HeldHandover(handover: AssistingFixture.handover(), receivedAt: start)
        XCTAssertNil(held.observedCallMinutes)
        var taken = held
        taken.clock = .take(at: start)
        taken.clock?.done(at: start + 600)
        let reply = try ExpertTimeReply.build(for: taken, card: nil, note: nil, now: start + 600).get()
        XCTAssertNil(reply.callMinutes)
        XCTAssertTrue(reply.summary.contains("didn't see a call"), reply.summary)
    }

    // MARK: - Coaching named on the time reply

    func testTheTimeReplyNamesTheCoachingSentAndStaysBackwardCompatible() throws {
        let clock = AssistingTestClock()
        let store = AssistingHandoverStore(directory: directory, now: { clock.now })
        store.open(AssistingFixture.opened(AssistingFixture.handover()))
        store.take(id: "H-1")
        store.markCoachingSent(id: "H-1", coachingId: "coach-1")
        store.markCoachingSent(id: "H-1", coachingId: "coach-1")
        store.markCoachingSent(id: "H-1", coachingId: "coach-2")
        clock.advance(600)
        store.done(id: "H-1")
        let reply = try ExpertTimeReply.build(for: try XCTUnwrap(store.handover(id: "H-1")), card: nil, note: nil, now: clock.now).get()
        XCTAssertEqual(reply.coachingReplyIds, ["coach-1", "coach-2"])

        // Through the file and back, and an older reply without the field reads as it did.
        let file = try ExpertTimeReplyFile.write(reply)
        XCTAssertEqual(try ExpertTimeReplyFile.read(file).get(), reply)
        var older = try JSONSerialization.jsonObject(with: ExpertHandoverFile.encoder().encode(reply)) as! [String: Any]
        older.removeValue(forKey: "coachingReplyIds")
        let decoded = try ExpertHandoverFile.decoder().decode(ExpertTimeReply.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(decoded.coachingReplyIds)
        XCTAssertNil(decoded.callMinutes)
    }
}

// MARK: - The customer-report key

final class CustomerReportExpertTimeKeyTests: XCTestCase {

    func testTheKeyIsProfileOwnedAndOffByDefault() {
        XCTAssertEqual(SettingKey.customerReportShowsExpertTime.kind, .profileOwned(.bool))
        XCTAssertNil(SettingKey.customerReportShowsExpertTime.contentProblem(.bool(true), resolvableVaultIds: []))
        XCTAssertEqual(SettingKey.customerReportShowsExpertTime.ownedDescription,
                       "Whether the customer's report shows an expert's time and name")
        // No profile: the device owner's stored switch, off unless set.
        XCTAssertFalse(ExpertTimeAudience.customerShowsExpertTime(managed: false, owned: nil, stored: false))
        XCTAssertTrue(ExpertTimeAudience.customerShowsExpertTime(managed: false, owned: nil, stored: true))
        // A profile: only the profile decides, and absent is off whatever the phone stored.
        XCTAssertFalse(ExpertTimeAudience.customerShowsExpertTime(managed: true, owned: nil, stored: true))
        XCTAssertTrue(ExpertTimeAudience.customerShowsExpertTime(managed: true, owned: true, stored: false))
        XCTAssertFalse(ExpertTimeAudience.customerShowsExpertTime(managed: true, owned: false, stored: true))

        let applied = ProfileApplier.apply(
            profile: ConfigProfile(keyId: "test-key", profileId: "p", organizationName: "Northbridge Mechanical",
                                   issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: 30,
                                   eraseAfterLapseDays: nil, undeliveredEraseDays: nil,
                                   settings: ["customerReportShowsExpertTime": RawSetting(.bool(true), .default)]),
            resolvableVaultIds: [])
        XCTAssertEqual(applied.owned[.customerReportShowsExpertTime], .bool(true))
        XCTAssertTrue(applied.isLocked(.customerReportShowsExpertTime))
    }

    func testPersonalAdditionsAreUnaffected() throws {
        // A technician's own addition is staff with no rate, so its time has no billable figure,
        // whatever the customer-report switch says, and the addition gains no field from it.
        let personal = PersonalExpert(name: "Ari Moana", phone: "+64 21 000 2222")
        XCTAssertEqual(personal.contact.kind, .staff)
        XCTAssertNil(personal.contact.rate)
        let labels = Set(Mirror(reflecting: personal).children.compactMap(\.label))
        XCTAssertTrue(labels.isDisjoint(with: ["kind", "rate", "billing", "customerReportShowsExpertTime"]))
        var session = ExpertTimeFixture.job(expert: personal.contact, call: 12 * 60)
        try ExpertTimeFixture.attach(AssistingFixture.timeReply(expertId: personal.id, expertName: "Ari Moana", minutes: 14,
                                                                callMinutes: 12),
                                     to: &session, list: [])
        let time = try XCTUnwrap(ExpertTime.build(session: session).first)
        XCTAssertEqual(time.minutes, 14)
        XCTAssertNil(time.billableMinutes)
        XCTAssertEqual(time.reconciliation, .agrees)
    }
}

/// A call observer the test drives.
@MainActor
final class LedgerFakeCallObserver: CallObserving {
    var onChange: ((ObservedCall) -> Void)?
    func report(_ call: ObservedCall) { onChange?(call) }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
