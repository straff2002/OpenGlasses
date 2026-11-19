import Foundation

/// What a report on one AI reply carries (Plan MH P1): the turn that produced it, and nothing else
/// from the conversation.
///
/// A wearer who reports a reply has one answer in mind. The report that goes with it should hold
/// the question that led to it, the reply, and which model and provider answered — not the rest of
/// what they said in that conversation, and not anything from the rest of the day. The composer can
/// still widen it to the whole conversation when the wearer chooses that on the sheet.
///
/// **The turn's boundary.** From the reported reply back to the nearest user message before it,
/// which is the question. Every assistant message between the two is part of the turn — a tool
/// round's interim line, or a reply said in parts — because the reported reply only makes sense
/// with them. Nothing after the reported reply is included, even another assistant message of the
/// same turn: the report is about what the wearer pointed at. A reply with no user message before
/// it (the first message of a thread) is a turn with no question. System messages are the app's
/// instructions to the model and are never part of a turn.
///
/// **Private conversations (Plan LU).** A private conversation keeps nothing, and its row for the
/// support report is `.skip`: there is no thread to export. So no reply is offered for report while
/// a private conversation is open, its own bubbles never offer it, and `turn(in:reportedId:isPrivate:)`
/// answers nil for one. The private page draws synthetic messages that exist in no stored thread,
/// so even a report asked for by id finds nothing to put in.
///
/// **Pure.** Values in, values out: no store, no clock and no gate is read in here.
enum ReportedReplyScope {

    /// One reported turn.
    struct Turn {
        /// The reported reply's id.
        let replyId: String
        /// The reported reply.
        let reply: ConversationMessage
        /// The user message that led to it, or nil when nothing was asked before it.
        let question: ConversationMessage?
        /// The turn's messages in thread order: the question when there is one, then every
        /// assistant message from it up to and including the reported reply.
        let messages: [ConversationMessage]
        /// When the message just before the turn was saved, or nil when the turn opens the thread.
        /// A turn record after this moment, and no later than the reply, is this turn's.
        let after: Date?
    }

    /// How far either side of the turn the app's own events and debug lines reach. Narrower than a
    /// conversation's five minutes: this report promises the turn, not the minutes around it.
    static let windowMargin: TimeInterval = 60

    /// Whether a message offers "Report this reply": an assistant reply, outside a private
    /// conversation. Never the wearer's own words, and never an app instruction.
    static func offersReport(role: String, isPrivate: Bool) -> Bool {
        guard role == "assistant" else { return false }
        return !(isPrivate && PrivateConversationPolicy.rule(for: .supportReport) == .skip)
    }

    /// The turn the reported message closes, or nil when there is nothing to report: an unknown id,
    /// a message that is not an assistant reply, an empty reply, or a private conversation.
    static func turn(in messages: [ConversationMessage], reportedId: String,
                     isPrivate: Bool = false) -> Turn? {
        guard let index = messages.firstIndex(where: { $0.id == reportedId }) else { return nil }
        let reply = messages[index]
        guard offersReport(role: reply.role, isPrivate: isPrivate),
              !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var included: [ConversationMessage] = [reply]
        var question: ConversationMessage?
        var start = index
        var cursor = index - 1
        while cursor >= 0 {
            let message = messages[cursor]
            if message.role == "user" {
                question = message
                included.append(message)
                start = cursor
                break
            }
            if message.role == "assistant" {
                included.append(message)
                start = cursor
            }
            cursor -= 1
        }
        // With no question, the turn reaches back to the thread's first message.
        if question == nil { start = 0 }
        let after = start > 0 ? messages[start - 1].timestamp : nil
        return Turn(replyId: reply.id, reply: reply, question: question,
                    messages: included.reversed(), after: after)
    }

    /// The turn records that belong to `turn`: recorded against its thread, after the message
    /// before the turn, and no later than the reply was saved. A turn's record is stamped when the
    /// question was handed to the model (or, failing that, when speech ended), which is after the
    /// previous reply was saved and before this one was.
    static func traces(_ traces: [TurnTrace], threadId: String, for turn: Turn) -> [TurnTrace] {
        traces.filter { trace in
            guard trace.threadId == threadId else { return false }
            if let after = turn.after, trace.at <= after { return false }
            return trace.at <= turn.reply.timestamp
        }
        .sorted { $0.at < $1.at }
    }

    /// Which provider and model answered, for the report's heading: from the newest of the turn's
    /// records that names either. "not recorded on this phone" when none does — turn records are
    /// kept for two weeks and can be switched off, while the conversation is kept longer.
    static func answeredBy(_ traces: [TurnTrace], reply: ConversationMessage) -> String {
        let named = traces.last { $0.backend != nil || $0.model != nil }
        var parts: [String] = []
        if let named {
            if let backend = named.backend {
                parts.append(LLMProvider(rawValue: backend)?.displayName ?? backend)
            }
            if let model = named.model { parts.append(model) }
        }
        var answer = parts.isEmpty ? "not recorded on this phone" : parts.joined(separator: " / ")
        if reply.isAnsweredOnDevice { answer += " (answered on the phone while offline)" }
        return answer
    }
}
