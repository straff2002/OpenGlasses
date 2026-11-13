import Foundation

/// Plan LQ §2 — whether a left conversation is one a note is written for. Pure.
///
/// A thread qualifies when it is a real conversation (two turns from the wearer and some 200
/// characters of words between them), has something the note does not yet describe (no note, or
/// messages after the one it covers through), was never forgotten, and belongs to no job.
///
/// **Job threads never qualify** (decision 2). A Field Assist session, open or ended, that names
/// the thread as its `conversationThreadId` makes it a job's thread, and so does being the debrief
/// thread. `jobTitle` is not enough: it is set only once the job has a reference, and a thread the
/// technician renamed has none. The caller collects the ids from the sessions; this check, not the
/// seam the pass hangs on, is what keeps them out, and the backlog applies it too.
enum ConversationDigestEligibility {

    /// The fewest turns from the wearer a conversation needs.
    static let minimumUserTurns = 2
    /// The fewest characters of conversational text, user and assistant together. "What time is
    /// it" twice, answered twice, is well under.
    static let minimumCharacters = 200

    enum Reason: String, Equatable, Sendable {
        /// A Field Assist job or the debrief owns it.
        case jobThread
        /// A forget or an erasure cleared its note; it is not written again.
        case redacted
        /// It has a note and nothing has been said since.
        case upToDate
        /// Too few turns, or too few words, to be worth a note.
        case tooShort
    }

    enum Verdict: Equatable, Sendable {
        case eligible
        case ineligible(Reason)

        var isEligible: Bool { self == .eligible }
        var reason: Reason? {
            if case .ineligible(let reason) = self { return reason }
            return nil
        }
    }

    static func check(_ thread: ConversationThread, jobThreadIDs: Set<String>) -> Verdict {
        if jobThreadIDs.contains(thread.id) { return .ineligible(.jobThread) }
        if thread.digest?.isRedacted == true { return .ineligible(.redacted) }
        let spoken = thread.messages.filter(TimelineSummaryPass.isConversational)
        if let digest = thread.digest, !hasTail(after: digest.coversThroughMessageID, in: spoken) {
            return .ineligible(.upToDate)
        }
        let userTurns = spoken.filter { $0.role == "user" }.count
        let characters = spoken.reduce(0) {
            $0 + $1.content.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        guard userTurns >= minimumUserTurns, characters >= minimumCharacters else {
            return .ineligible(.tooShort)
        }
        return .eligible
    }

    /// Whether anything was said after `messageID`. A note whose last message is no longer in the
    /// thread describes something the thread no longer says, so it counts as having a tail.
    static func hasTail(after messageID: String, in spoken: [ConversationMessage]) -> Bool {
        guard let index = spoken.firstIndex(where: { $0.id == messageID }) else { return !spoken.isEmpty }
        return index < spoken.count - 1
    }
}
