import Foundation

// MARK: - The job's loose ends, as open loops (Plan LE §10, P1)
//
// The five §10 rows, read from the records the P0 As built table names: the field sessions and
// the send queue, together, the way `JobDayFeed` reads them. Pure — the sessions (with whether
// each one's report went, which is a disk read the reader makes), the queue entries and the
// organisation's sign-off rule all come in as values.

/// One field session as the check-in reads it.
struct OpenLoopJobSession: Equatable {
    let session: FieldSession
    /// Whether the session's report went out by any channel (`FieldSessionService.reportWasSent`).
    let reportSent: Bool
}

/// Everything the job rows are read from, gathered fresh at delivery time.
struct OpenLoopJobFacts: Equatable {
    /// The open job and the finished ones, newest last. Only today's work is read for the per-job
    /// rows; the full list lets a queued report still name its job.
    let sessions: [OpenLoopJobSession]
    /// The send queue's entries (`DeliveryQueue.entries`).
    let queue: [QueuedSend]
    /// The organisation asks for the customer's signature on every job.
    let signOffRequired: Bool

    init(sessions: [OpenLoopJobSession], queue: [QueuedSend], signOffRequired: Bool) {
        self.sessions = sessions
        self.queue = queue
        self.signOffRequired = signOffRequired
    }
}

enum OpenLoopJobLoops {

    static func loops(_ facts: OpenLoopJobFacts, now: Date, calendar: Calendar) -> [OpenLoop] {
        let startOfToday = calendar.startOfDay(for: now)
        let byID = Dictionary(facts.sessions.map { ($0.session.id, $0) }, uniquingKeysWith: { _, last in last })
        // Today's work: the open job, and every job that finished today. A cancelled job is nobody's.
        let today = facts.sessions.filter { item in
            let session = item.session
            guard session.outcome != .cancelled else { return false }
            if session.endedAt == nil { return true }
            return (session.endedAt ?? .distantPast) >= startOfToday
        }

        var loops: [OpenLoop] = []
        loops += reports(facts, today: today, byID: byID, now: now)
        loops += heldCloses(today, signOffRequired: facts.signOffRequired)
        loops += parts(today)
        loops += deferredTasks(today)
        loops += handOffs(today)
        return loops
    }

    // MARK: Job report

    /// A report staged in the queue and never sent, a send that failed and is still owed
    /// (`JobDayComposer.owedFailures`), and a job finished today whose report never reached the
    /// queue at all. A job whose report is waiting in the queue or failed is that row, not a second.
    static func reports(_ facts: OpenLoopJobFacts, today: [OpenLoopJobSession],
                        byID: [String: OpenLoopJobSession], now: Date) -> [OpenLoop] {
        let failed = JobDayComposer.owedFailures(facts.queue, now: now)
        let staged = facts.queue.filter { $0.state == .staged }.sorted { $0.createdAt < $1.createdAt }
        var loops: [OpenLoop] = failed.map { entry in
            OpenLoop(id: "report:\(entry.id)", source: .jobReport, title: entry.documentKind.label,
                     job: byID[entry.sessionId].flatMap { name(of: $0.session) }, since: entry.updatedAt,
                     failed: true, action: .open(.job(.send(queuedId: entry.id))))
        }
        loops += staged.map { entry in
            OpenLoop(id: "report:\(entry.id)", source: .jobReport, title: entry.documentKind.label,
                     job: byID[entry.sessionId].flatMap { name(of: $0.session) }, since: entry.createdAt,
                     action: .open(.job(.send(queuedId: entry.id))))
        }
        let queued = Set(facts.queue.filter { $0.state.isWaiting }.map(\.sessionId))
            .union(failed.map(\.sessionId))
        loops += today
            .filter { $0.session.endedAt != nil && !$0.reportSent && !queued.contains($0.session.id) }
            .map { item in
                OpenLoop(id: "report:session:\(item.session.id)", source: .jobReport,
                         title: QueuedSend.DocumentKind.report.label, job: name(of: item.session),
                         since: item.session.endedAt ?? item.session.startedAt,
                         action: .open(.job(.pastJob(sessionId: item.session.id))))
            }
        return loops
    }

    // MARK: Job close held

    /// No record keeps "held": the close inputs are re-run. An open job holds its close while a
    /// check is owed, or while the organisation's sign-off is missing; a finished job is still held
    /// for a signature while its report has not gone (a signature after the work order left would
    /// describe a document nobody holds). One row a job, named by what it waits on.
    static func heldCloses(_ today: [OpenLoopJobSession], signOffRequired: Bool) -> [OpenLoop] {
        today.compactMap { item in
            let session = item.session
            let isOpen = session.endedAt == nil
            let check = isOpen ? session.openVerifications.first : nil
            let needsSignature = signOffRequired && session.signOff == nil && (isOpen || !item.reportSent)
            let title: String
            if let check {
                title = String(localized: "the check '\(checkName(check.title))'",
                               comment: "Spoken: what a held job close waits on, a check still owed by its task's name; follows 'the Smith job still needs'.")
            } else if needsSignature {
                title = String(localized: "the customer's sign-off",
                               comment: "Spoken: what a held job close waits on; follows 'the Smith job still needs'.")
            } else {
                return nil
            }
            return OpenLoop(id: "close:\(session.id)", source: .jobCloseHeld, title: title,
                            job: name(of: session), since: session.startedAt,
                            action: .open(.job(isOpen ? .openJob : .pastJob(sessionId: session.id))))
        }
    }

    /// "Verify: the burner lights" → "the burner lights": the task's own words, without the prefix
    /// the close gave it.
    static func checkName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Verify:") else { return trimmed }
        return String(trimmed.dropFirst("Verify:".count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Parts request

    /// A request on today's work asked for and not yet sent (`PartsOrder.waiting`).
    static func parts(_ today: [OpenLoopJobSession]) -> [OpenLoop] {
        today.flatMap { item in
            PartsOrder.waiting(item.session.partsRequests).map { request in
                let described = request.part.partDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = (described?.isEmpty == false ? described : nil) ?? request.part.number
                return OpenLoop(id: "parts:\(request.id)", source: .partsRequest, title: title,
                                job: name(of: item.session), since: request.createdAt,
                                action: .open(.job(.partsOrder(sessionId: item.session.id))))
            }
        }
    }

    // MARK: Deferred task

    /// A work task the technician put off (`Task.Status.deferred`) and did not come back to.
    static func deferredTasks(_ today: [OpenLoopJobSession]) -> [OpenLoop] {
        today.flatMap { item in
            item.session.tasks.filter { $0.status == .deferred && $0.completedAt == nil }.map { task in
                OpenLoop(id: "task:\(item.session.id):\(task.id)", source: .deferredTask, title: task.title,
                         job: name(of: item.session), since: task.acceptedAt ?? task.createdAt,
                         action: .open(.job(route(item.session))))
            }
        }
    }

    // MARK: Expert or escalation

    /// A hand-off whose current generation has no reply from its expert, and an escalation never
    /// marked resolved. An escalation to an expert who also has a hand-off waiting is that
    /// hand-off's row, not a second one.
    static func handOffs(_ today: [OpenLoopJobSession]) -> [OpenLoop] {
        today.flatMap { item -> [OpenLoop] in
            let session = item.session
            let replied = Set((session.expertReplies ?? []).map(\.handoverId))
            let waiting = ExpertHandoverLedger.current(session.expertHandovers ?? [])
                .filter { !replied.contains($0.handoverId) }
            var loops = waiting.map { sent in
                OpenLoop(id: "handover:\(sent.handoverId)", source: .expertOrEscalation,
                         title: sent.expert.name, subject: sent.expert.name, job: name(of: session),
                         since: sent.sentAt, action: .open(.job(route(session))))
            }
            let expertsWaiting = Set(waiting.map(\.expert.id))
            loops += session.escalations.filter { escalation in
                escalation.resolvedAt == nil
                    && !(escalation.expert.map { expertsWaiting.contains($0.id) } ?? false)
            }.map { escalation in
                OpenLoop(id: "escalation:\(session.id):\(Int(escalation.timestamp.timeIntervalSince1970))",
                         source: .expertOrEscalation, title: escalation.reason,
                         subject: escalation.expert?.name, job: name(of: session), since: escalation.timestamp,
                         action: .open(.job(route(session))))
            }
            return loops
        }
    }

    // MARK: Pieces

    /// The job as its record names it: the customer as the technician entered them, else the job's
    /// reference as given. Never invented.
    static func name(of session: FieldSession) -> OpenLoopJobName? {
        if let customer = session.site?.customer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customer.isEmpty {
            return .customer(customer)
        }
        if let reference = session.jobReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty {
            return .reference(reference)
        }
        return nil
    }

    private static func route(_ session: FieldSession) -> JobDayDestination {
        session.endedAt == nil ? .openJob : .pastJob(sessionId: session.id)
    }
}
