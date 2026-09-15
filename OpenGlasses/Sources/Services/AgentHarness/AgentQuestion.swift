import Foundation

/// A question a remote agent run is waiting on, with a **stable identity** (Plan FE P1).
///
/// The event this replaces carried a bare prompt string, which made two different mistakes
/// impossible to tell apart:
///
///  * the same question arriving on every poll — re-announced each time, because nothing
///    remembered it had been asked; and
///  * a genuinely new question that happens to be worded identically to the last one —
///    suppressed by any fix built on text equality.
///
/// Identity is `(id, revision)`. A question is surfaced once per identity: a repeat is silent, a
/// revision bump is a fresh ask, and a new `id` is a new question however familiar its wording.
struct AgentQuestion: Identifiable, Equatable {
    typealias ID = String

    /// What kind of answer the question wants. The distinction is load-bearing: a boolean cannot
    /// express "only change the tests", and ordinary speech must never be able to authorize an
    /// action (Plan FE P1).
    enum Kind: Equatable {
        /// The agent wants words back — a clarification, a choice, a file name.
        case freeText
        /// The agent wants permission to do something, summarised for the consent prompt.
        case approval(actionSummary: String)

        var isApproval: Bool {
            if case .approval = self { return true }
            return false
        }
    }

    let id: ID
    /// Bumped by the endpoint when the same question is re-asked with changed terms.
    let revision: Int
    let kind: Kind
    /// What the wearer is asked, already sanitised by the adapter.
    let prompt: String
    /// The run this question belongs to. A reply naming another run is not this question's answer.
    let runID: String

    init(id: ID, revision: Int = 0, kind: Kind, prompt: String, runID: String) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.prompt = prompt
        self.runID = runID
    }

    /// The pair that decides whether this has already been surfaced.
    struct Identity: Hashable {
        let id: AgentQuestion.ID
        let revision: Int
    }

    var identity: Identity { Identity(id: id, revision: revision) }

    /// The summary shown on the consent prompt for an approval question.
    var actionSummary: String {
        if case .approval(let summary) = kind, !summary.isEmpty { return summary }
        return prompt
    }

    // MARK: - Derived identity

    /// A deterministic id for an endpoint that supplies none — the legacy `awaiting_input` shape,
    /// which reports a prompt and nothing else.
    ///
    /// Derived from `(runID, sequence, prompt)`, so it is stable across app launches and across
    /// repeated polls of the same question. **The limit is documented rather than hidden:** two
    /// questions with identical wording from such an endpoint are told apart *only* by arrival
    /// order — the adapter advances `sequence` when the run leaves and re-enters the waiting state,
    /// or when the wording changes, and nothing else can distinguish them.
    static func derivedID(runID: String, prompt: String, sequence: Int) -> ID {
        "derived-" + fnv1a("\(runID)\u{1}\(sequence)\u{1}\(prompt)")
    }

    /// FNV-1a over UTF-8, rendered as hex. Swift's own `hashValue` is per-process seeded, so it
    /// cannot be used for an identity that has to survive a relaunch.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Map an endpoint's kind label onto `Kind`. Anything unrecognised — including nothing at all —
    /// is an **approval**, the conservative reading: an approval routes through the user-distinct
    /// consent prompt, where a free-text question would accept words and forward them. Guessing
    /// "free text" on an unlabelled question is how a confirmation becomes a conversation.
    static func kind(fromLabel raw: String?, prompt: String) -> Kind {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "text", "free_text", "freetext", "question", "input", "clarification":
            return .freeText
        default:
            return .approval(actionSummary: prompt)
        }
    }
}

/// An answer to one `AgentQuestion` (Plan FE P1).
///
/// It replaces `approved: Bool` as the harness reply contract. The boolean could not say
/// "only change the tests", and a harness that could not relay a reply at all silently accepted
/// one — the protocol's silent default. Both are addressed here: the body is typed, and a harness
/// that cannot carry a given body says so.
struct AgentReply: Equatable {
    enum Body: Equatable {
        case approve
        case deny
        case text(String)

        /// The label sent to an endpoint as the decision.
        var decision: String {
            switch self {
            case .approve: return "approve"
            case .deny:    return "deny"
            case .text:    return "text"
            }
        }

        /// The wearer's words, for a reply that carries any.
        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    let questionID: AgentQuestion.ID
    let revision: Int
    let body: Body
    let runID: String
    /// Stable across retries of the *same* reply, so an endpoint can make re-delivery a no-op.
    /// Re-sending after an uncertain delivery must not be able to apply an effect twice.
    let replyID: String

    init(questionID: AgentQuestion.ID, revision: Int, body: Body, runID: String,
         replyID: String = UUID().uuidString) {
        self.questionID = questionID
        self.revision = revision
        self.body = body
        self.runID = runID
        self.replyID = replyID
    }

    /// The reply to `question`, carrying its identity so a stale answer can be recognised.
    init(answering question: AgentQuestion, body: Body, replyID: String = UUID().uuidString) {
        self.init(questionID: question.id, revision: question.revision, body: body,
                  runID: question.runID, replyID: replyID)
    }

    /// Whether this reply answers `question` — same run, same id, same revision. Anything else is
    /// an answer to a question that has been replaced, cancelled or expired.
    func answers(_ question: AgentQuestion) -> Bool {
        questionID == question.id && revision == question.revision && runID == question.runID
    }
}

/// What became of the last reply we tried to send (Plan FE P1).
///
/// Five outcomes, not two. "Sent" and "we have no idea" used to arrive at the same spoken line.
enum AgentReplyOutcome: Equatable {
    /// The endpoint accepted it.
    case delivered
    /// The harness has no channel for a reply of that shape. A retry cannot help.
    case unsupported
    /// It did not get there. The question stays pending and a retry re-sends the same reply.
    case failed
    /// It left the device and we never learned whether it was applied; re-polling the run's status
    /// did not settle it either.
    case uncertain
    /// The answer named a question that has been replaced, cancelled or expired.
    case stale

    /// Whether re-sending the same reply is worth offering.
    var isRetryable: Bool {
        switch self {
        case .failed, .uncertain: return true
        case .delivered, .unsupported, .stale: return false
        }
    }
}
