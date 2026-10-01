import Foundation

/// Which job "send the report" means (Plan GB P0).
///
/// The field test closed a job by voice and asked for the report two seconds later: `field_session
/// end` at 18:21:02, `deliver_report` at 18:21:04, and "No active Field Assist session" at 18:21:10.
/// The job was finished, which is exactly when a report is sent, and the tool only knew how to
/// report on a job that was still open. The renderer never had that limit —
/// `reportDelivery(for:canSendAttachments:sessionId:)` already builds a finished job's report — so
/// what was missing was a rule for which finished job is meant. This is that rule.
///
/// **It never reopens a job.** A finished job's report is built from the finished session; nothing
/// here touches its clock, its tasks or its outcome.
///
/// Pure: the inputs are values, so every row of the table is a test.
enum ReportTargetResolver {

    /// A job that has ended, as far as the decision needs to know it.
    struct EndedJob: Equatable {
        let sessionId: String
        /// The conversation the job owned, when it owned one.
        let threadId: String?
        let endedAt: Date
        /// Whether its report has already gone by any channel.
        let reportSent: Bool

        init(sessionId: String, threadId: String?, endedAt: Date, reportSent: Bool) {
            self.sessionId = sessionId
            self.threadId = threadId
            self.endedAt = endedAt
            self.reportSent = reportSent
        }
    }

    /// The conversation the request arrived in.
    struct Thread: Equatable {
        /// The store's active thread, or nil when none is open — which is what closing a job
        /// leaves behind, because finishing the job ends its thread.
        let id: String?
        /// When that thread was created. A thread begun after the job ended is the conversation
        /// that carried on from the close, not somebody else's.
        let createdAt: Date?

        init(id: String?, createdAt: Date? = nil) {
            self.id = id
            self.createdAt = createdAt
        }

        static let none = Thread(id: nil)
    }

    enum Target: Equatable {
        /// The job that is open now.
        case active
        /// A job that ended moments ago in this conversation and has not been sent.
        case ended(sessionId: String)
        /// Nothing the technician could mean. The reason is what the tool says.
        case refuse(reason: String)
    }

    /// How long after a close "send the report" still means that job. Long enough to pack the van
    /// and say it; short enough that yesterday's job is never sent by accident.
    static let recentWindow: TimeInterval = 30 * 60

    static let noJobReason = "There is no open job and no job was closed in this conversation "
        + "in the last half hour. Open the job from the Jobs tab to send its report."
    static let alreadySentReason = "The report for the job just closed has already been sent. "
        + "To send it again, open the job from the Jobs tab and send it from there."
    static let otherConversationReason = "The job just closed belongs to a different conversation. "
        + "Open the job from the Jobs tab to send its report."

    /// Decide. `recentEnded` may be in any order and may include old jobs; the rule picks the most
    /// recently ended one and holds it to the window, the thread and the sent flag.
    static func resolve(active: Bool, recentEnded: [EndedJob], thread: Thread, now: Date,
                        window: TimeInterval = recentWindow) -> Target {
        if active { return .active }
        guard let latest = recentEnded.max(by: { $0.endedAt < $1.endedAt }),
              latest.endedAt <= now, now.timeIntervalSince(latest.endedAt) <= window else {
            return .refuse(reason: noJobReason)
        }
        guard belongs(latest, to: thread) else { return .refuse(reason: otherConversationReason) }
        guard !latest.reportSent else { return .refuse(reason: alreadySentReason) }
        return .ended(sessionId: latest.sessionId)
    }

    /// Whether the request came from the conversation the job finished in.
    ///
    /// No thread open is the normal case straight after a close (the close ends the job's thread).
    /// A thread created after the close is the conversation that carried on from it. The job's own
    /// thread is, obviously, its own. Anything else is a conversation about something else.
    private static func belongs(_ job: EndedJob, to thread: Thread) -> Bool {
        guard let current = thread.id else { return true }
        guard let owned = job.threadId else { return true }
        if owned == current { return true }
        if let created = thread.createdAt, created >= job.endedAt { return true }
        return false
    }
}
