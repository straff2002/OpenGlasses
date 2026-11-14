import XCTest
@testable import OpenGlasses

/// Plan LE P1 §10 — the job's loose ends, read from fixture field sessions and send-queue entries
/// the way `JobDayFeed` reads them. Every customer, job number and part here is invented.
final class OpenLoopJobLoopsTests: XCTestCase {
    private typealias F = OpenLoopFixture

    // MARK: Fixtures

    private func session(_ id: String, ref: String? = nil, customer: String? = nil,
                         started: Date = F.at(8), ended: Date? = F.at(12),
                         outcome: FieldSession.Outcome = .resolved) -> FieldSession {
        var session = FieldSession(id: id, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: started, outcome: outcome, escalations: [], billableSeconds: 0)
        session.endedAt = ended
        session.jobReference = ref
        if let customer { session.site = JobSite(customer: customer) }
        return session
    }

    private func send(_ id: String, session: String, state: QueuedSend.State, created: Date = F.at(13),
                      updated: Date? = nil) -> QueuedSend {
        QueuedSend(id: id, sessionId: session, jobNumber: "Job \(session)", documentKind: .report,
                   channel: .email, recipients: ["office@example.com"], recipientSource: .deliverySettings,
                   createdAt: created, updatedAt: updated, state: state)
    }

    private func loops(_ sessions: [OpenLoopJobSession], queue: [QueuedSend] = [],
                       signOff: Bool = false) -> [OpenLoop] {
        OpenLoopJobLoops.loops(OpenLoopJobFacts(sessions: sessions, queue: queue, signOffRequired: signOff),
                               now: F.now, calendar: F.calendar)
    }

    private func finished(_ session: FieldSession, sent: Bool = true) -> OpenLoopJobSession {
        OpenLoopJobSession(session: session, reportSent: sent)
    }

    // MARK: Job report

    func testAFinishedJobWhoseReportNeverReachedTheQueueIsAnUnsentReport() {
        let found = loops([finished(session("s1", customer: "Smith"), sent: false)])
        XCTAssertEqual(found.map(\.id), ["report:session:s1"])
        XCTAssertEqual(found[0].source, .jobReport)
        XCTAssertEqual(found[0].job, .customer("Smith"))
        XCTAssertFalse(found[0].failed)
        XCTAssertEqual(found[0].action, .open(.job(.pastJob(sessionId: "s1"))))
        XCTAssertEqual(OpenLoopPhraser.clause(found[0]), "the report for the Smith job isn't sent")
    }

    func testAFailedSendIsAFailedReportAndCoversItsJob() {
        let found = loops([finished(session("s1", ref: "1005"), sent: false)],
                          queue: [send("q1", session: "s1", state: .failed, updated: F.at(14))])
        XCTAssertEqual(found.map(\.id), ["report:q1"], "the job's row is the failed send, not a second")
        XCTAssertTrue(found[0].failed)
        XCTAssertEqual(found[0].job, .reference("1005"))
        XCTAssertEqual(found[0].action, .open(.job(.send(queuedId: "q1"))))
        XCTAssertEqual(OpenLoopPhraser.clause(found[0]), "the report for job 1005 didn't send")
    }

    func testAStagedReportIsWaitingAndASentOneIsNot() {
        let found = loops([finished(session("s1", customer: "Smith"), sent: false),
                           finished(session("s2", customer: "Jones"), sent: true)],
                          queue: [send("q1", session: "s1", state: .staged),
                                  send("q2", session: "s2", state: .sent)])
        XCTAssertEqual(found.map(\.id), ["report:q1"])
        XCTAssertFalse(found[0].failed)
    }

    func testAFailedSendSupersededByALaterSendIsNotOwed() {
        let found = loops([finished(session("s1"), sent: true)],
                          queue: [send("q1", session: "s1", state: .failed, created: F.at(13)),
                                  send("q2", session: "s1", state: .sent, created: F.at(14))])
        XCTAssertTrue(found.isEmpty)
    }

    func testYesterdaysFinishedJobIsNotTodaysLooseEnd() {
        let old = session("s0", customer: "Smith", started: F.at(8, day: 13), ended: F.at(12, day: 13))
        XCTAssertTrue(loops([finished(old, sent: false)]).isEmpty)
        let cancelled = session("s1", customer: "Smith", outcome: .cancelled)
        XCTAssertTrue(loops([finished(cancelled, sent: false)]).isEmpty, "a cancelled job is nobody's")
    }

    // MARK: Held close

    func testAnOpenJobWithACheckStillOwedIsAHeldClose() {
        var open = session("s1", customer: "Smith", ended: nil, outcome: .inProgress)
        open.tasks = [FieldSession.Task(id: "t1", title: "Verify: the burner lights", origin: .recommended,
                                        status: .accepted,
                                        verification: VerificationRequirement(instruction: "Watch it light"))]
        let found = loops([OpenLoopJobSession(session: open, reportSent: false)])
        let close = found.first { $0.source == .jobCloseHeld }
        XCTAssertEqual(close?.id, "close:s1")
        XCTAssertEqual(close?.title, "the check 'the burner lights'")
        XCTAssertEqual(close?.action, .open(.job(.openJob)))
        XCTAssertEqual(close.map(OpenLoopPhraser.clause), "the Smith job still needs the check 'the burner lights'")
    }

    func testAMissingSignOffHoldsTheCloseUntilTheReportGoes() {
        let open = session("s1", customer: "Smith", ended: nil, outcome: .inProgress)
        let unsent = session("s2", customer: "Jones")
        let sent = session("s3", customer: "Brown")
        let found = loops([OpenLoopJobSession(session: open, reportSent: false),
                           finished(unsent, sent: false), finished(sent, sent: true)], signOff: true)
        let closes = found.filter { $0.source == .jobCloseHeld }
        XCTAssertEqual(closes.map(\.id), ["close:s1", "close:s2"])
        XCTAssertTrue(closes.allSatisfy { $0.title == "the customer's sign-off" })
        XCTAssertEqual(closes.last?.action, .open(.job(.pastJob(sessionId: "s2"))))

        XCTAssertTrue(loops([finished(unsent, sent: false)], signOff: false)
            .filter { $0.source == .jobCloseHeld }.isEmpty, "no rule, no hold")
    }

    // MARK: Parts

    func testAPartsRequestCountsWhileRequestedNotOnceSent() {
        var job = session("s1", customer: "Jones")
        job.partsRequests = [
            PartsRequest(id: "p1", part: TaskPart(number: "70W16", partDescription: "filter"), status: .requested,
                         createdAt: F.at(10)),
            PartsRequest(id: "p2", part: TaskPart(number: "14T65"), status: .sent, createdAt: F.at(10)),
            PartsRequest(id: "p3", part: TaskPart(number: "22K01"), status: .answered, createdAt: F.at(10)),
        ]
        let found = loops([finished(job)]).filter { $0.source == .partsRequest }
        XCTAssertEqual(found.map(\.id), ["parts:p1"])
        XCTAssertEqual(found[0].title, "filter")
        XCTAssertEqual(found[0].action, .open(.job(.partsOrder(sessionId: "s1"))))
        XCTAssertEqual(OpenLoopPhraser.clause(found[0]), "the filter for Jones is still not ordered")
    }

    // MARK: Deferred task

    func testADeferredTaskIsALooseEndAndADoneOneIsNot() {
        var job = session("s1", ref: "1005")
        job.tasks = [
            FieldSession.Task(id: "t1", title: "Clean the condensate trap", origin: .recommended, status: .deferred,
                              createdAt: F.at(9)),
            FieldSession.Task(id: "t2", title: "Replace the flame sensor", origin: .recommended, status: .done,
                              createdAt: F.at(9), completedAt: F.at(10)),
        ]
        let found = loops([finished(job)]).filter { $0.source == .deferredTask }
        XCTAssertEqual(found.map(\.id), ["task:s1:t1"])
        XCTAssertEqual(found[0].action, .open(.job(.pastJob(sessionId: "s1"))))
        XCTAssertEqual(OpenLoopPhraser.clause(found[0]), "you put off clean the condensate trap on job 1005")
    }

    // MARK: Expert or escalation

    private func handover(_ id: String, generation: Int = 1, expert: String = "sam") -> ExpertHandoverSent {
        ExpertHandoverSent(handoverId: id, generation: generation,
                           expert: ExpertSnapshot(id: expert, name: expert == "sam" ? "Sam Ferreira" : "Ari Moana",
                                                  kind: .staff),
                           channel: DeliveryChannel.messages.rawValue, sentAt: F.at(11), photoIds: [],
                           photosLeftOut: .none, transcriptIncluded: false, addressIncluded: false,
                           tasks: 0, readings: 0, manualReferences: 0, question: nil, ruledOut: [])
    }

    private func reply(_ handoverId: String, expert: String = "sam") -> ExpertReplyReceived {
        ExpertReplyReceived(handoverId: handoverId,
                            expert: ExpertSnapshot(id: expert, name: "Sam Ferreira", kind: .staff),
                            generationsSeen: [1], acceptedAt: F.at(11), doneAt: F.at(12), minutes: 10,
                            uncountedMinutes: 0, callMinutes: nil, note: nil, matchedBy: .listEntry,
                            receivedAt: F.at(12))
    }

    func testAHandOffWithNoReplyIsWaitingAndOneWithAReplyIsNot() {
        var job = session("s1", customer: "Smith")
        job.expertHandovers = [handover("H-1"), handover("H-1", generation: 2), handover("H-2", expert: "ari")]
        job.expertReplies = [reply("H-2", expert: "ari")]
        let found = loops([finished(job)]).filter { $0.source == .expertOrEscalation }
        XCTAssertEqual(found.map(\.id), ["handover:H-1"], "one row a hand-off, at its current generation")
        XCTAssertEqual(found[0].subject, "Sam Ferreira")
        XCTAssertEqual(OpenLoopPhraser.clause(found[0]), "no answer yet from Sam Ferreira on the Smith job")
    }

    func testAnEscalationCountsUntilResolvedAndOnceWithItsHandOff() {
        var job = session("s1", customer: "Smith")
        job.escalations = [
            FieldSession.Escalation(timestamp: F.at(10), reason: "No heat", resolvedAt: nil),
            FieldSession.Escalation(timestamp: F.at(9), reason: "Gas smell", resolvedAt: F.at(9, 30)),
        ]
        let found = loops([finished(job)]).filter { $0.source == .expertOrEscalation }
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found[0].subject)
        XCTAssertEqual(found[0].title, "No heat")
        XCTAssertEqual(OpenLoopPhraser.clause(found[0]), "the escalation on the Smith job has no answer yet")

        // Called the same expert the hand-off went to: one row, the hand-off's.
        job.escalations[0].expert = ExpertSnapshot(id: "sam", name: "Sam Ferreira", kind: .staff)
        job.expertHandovers = [handover("H-1")]
        let together = loops([finished(job)]).filter { $0.source == .expertOrEscalation }
        XCTAssertEqual(together.map(\.id), ["handover:H-1"])
    }

    // MARK: Naming

    func testAJobIsNamedAsItsRecordNamesIt() {
        XCTAssertEqual(OpenLoopJobLoops.name(of: session("s", ref: "1005", customer: "Smith")), .customer("Smith"))
        XCTAssertEqual(OpenLoopJobLoops.name(of: session("s", ref: "1005")), .reference("1005"))
        XCTAssertNil(OpenLoopJobLoops.name(of: session("s", ref: "  ")))
    }

    // MARK: Ranked with the rest

    func testTheJobsLooseEndsRankAfterApprovalsInDecisionElevensOrder() {
        var job = session("s1", customer: "Smith")
        job.tasks = [FieldSession.Task(id: "t1", title: "Clean the trap", origin: .recommended, status: .deferred)]
        job.partsRequests = [PartsRequest(id: "p1", part: TaskPart(number: "70W16"), createdAt: F.at(10))]
        let jobLoops = loops([finished(job, sent: false)], signOff: true)
        let all = jobLoops + [F.approval(1, "Your OK to send", since: F.at(20)),
                              F.reminder("r1", "Renew", due: F.at(9, day: 12))]
        let ranked = OpenLoopCollector.collect(all, dismissed: [:], now: F.now, calendar: F.calendar).loops
        XCTAssertEqual(ranked.map(\.source), [.approval, .jobReport, .jobCloseHeld, .partsRequest,
                                               .deferredTask, .reminder])
    }
}
