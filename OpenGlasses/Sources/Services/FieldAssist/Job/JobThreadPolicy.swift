import Foundation

/// Which saved conversation a turn belongs to while a job is running.
///
/// This replaces `ConversationThreadContinuityPolicy`, which answered one narrower question — may
/// the end of a voice turn close the saved thread — and answered it well. What it could not do was
/// say *which* thread the next turn joins, and that turned out to be the thing that breaks: the
/// four surfaces that never go through `returnToWakeWord()` (the conversation page's New
/// conversation, CarPlay's new/resume, the watch's resume, and a glasses disconnect) each moved or
/// closed the thread with no idea a job owned it. A binding that only covers the end of a voice
/// turn is a binding a CarPlay tap breaks.
///
/// So the decision is made here, once, for every one of those surfaces, and the coordinator that
/// calls it is the only thing in the app allowed to start, switch or end a thread while a job is
/// running.
///
/// **Binding is lazy, and that is deliberate.** Thread creation in this app happens on the first
/// turn that produces text, not when a conversation "starts" — `ConversationContinuity.startFresh`
/// says why: an empty thread created up front litters the switcher with conversations nobody had.
/// A job started from a settings screen and abandoned would do exactly that. So a job binds the
/// thread that is already active if there is one (which is the normal case: "start a job" is
/// itself a turn, and by the time the tool runs its thread exists), and otherwise binds the first
/// thread the next turn creates.
enum JobThreadPolicy {

    /// Everything the decision depends on. A value type so the whole table is testable without a
    /// store, a session or an app.
    struct Inputs: Equatable {
        /// Whether a Field Assist job is running at all.
        var jobActive: Bool = false
        /// The job's number, for the question's wording. Nil while it is still outstanding.
        var jobReference: String?
        /// The thread the job owns, once it owns one.
        var boundThreadId: String?
        /// Whether that thread is still in the store. A technician can delete it from the Chat tab.
        var boundThreadExists: Bool = false
        /// True once the technician has chosen to carry on in a separate chat (see `.detachThread`).
        var boundThreadDetached: Bool = false
        /// The store's current thread, if any.
        var activeThreadId: String?
        /// Whether conversations are being saved at all.
        var persistenceEnabled: Bool = true
        /// The debrief in hand, when one is (Plan FO P3b).
        var debrief: DebriefBinding?
    }

    /// Where a turn came from. Carried through so the audit can say which surface bound a thread,
    /// and so a future rule can treat a typed turn differently without reshaping the policy.
    ///
    /// `.debrief` is the one that is not about the open job (Plan FO P3b): a debrief is a
    /// conversation about **a chosen job**, which is usually a finished one, and its turns belong
    /// in *that* job's thread rather than in whatever the technician has open. A turn tagged with
    /// it therefore resolves against the debrief binding below and nothing else.
    enum TurnSource: Equatable {
        case wakeWord
        case tapToTalk
        case typed
        case debrief(jobId: String)

        /// What the audit log records.
        var label: String {
            switch self {
            case .wakeWord: return "wakeWord"
            case .tapToTalk: return "tapToTalk"
            case .typed: return "typed"
            case .debrief: return "debrief"
            }
        }

        var debriefJobId: String? {
            if case .debrief(let jobId) = self { return jobId }
            return nil
        }
    }

    /// The job a debrief is bound to, and the conversation that debrief's turns land in.
    ///
    /// Held beside the active job rather than folded into it: the two are routinely different
    /// things — a debrief on job 1004 while job 1005 is open is the ordinary case on a drive — and
    /// a binding that confused them would put one customer's account on another's record.
    struct DebriefBinding: Equatable {
        let jobId: String
        /// The thread that job owns, when it owns one.
        var threadId: String?
        /// Whether that thread is still in the store.
        var threadExists: Bool = false

        init(jobId: String, threadId: String? = nil, threadExists: Bool = false) {
            self.jobId = jobId
            self.threadId = threadId
            self.threadExists = threadExists
        }
    }

    /// What the app is about to do.
    enum Request: Equatable {
        case turn(TurnSource)
        /// "New chat" / "New conversation" — the Chat tab, the page header, CarPlay.
        case newChat(confirmed: Bool)
        /// Opening another conversation — the switcher, the Chat tab, CarPlay, the watch.
        case resumeThread(id: String, confirmed: Bool)
        /// A voice turn finished and the wake word is re-arming.
        case returnToWakeWord
        /// The wearer put the glasses down.
        case disconnect
        case jobStarted
        case jobClosed
        /// The app came back from a cold launch with a restored session and maybe a restored thread.
        case launchRestore
    }

    enum BindReason: String, Equatable {
        case jobStarted
        case noThreadYet
        case boundThreadDeleted
        /// A debrief was started on a job that never had a conversation — a job closed before the
        /// guided flow existed, or one nobody spoke on (Plan FO P3b).
        case debriefStarted
    }

    enum Resolution: Equatable {
        /// Do exactly what the app does with no job running. The only outcome for everyone who
        /// does not have Field Assist.
        case proceedUnbound
        /// A job is running but there is nothing to bind yet; the next turn will bind.
        case deferBinding
        /// The turn belongs to this thread. The caller resumes it — id **and** history — when it
        /// is not already the active one.
        case useBoundThread(id: String)
        /// Adopt the thread that is already open as the job's.
        case bindActiveThread(id: String)
        /// Start a thread and bind it.
        case bindNewThread(reason: BindReason)
        /// The bound id points at nothing. Forget it without creating anything in its place.
        case clearBinding(reason: BindReason)
        /// The technician chose to carry on in a separate chat. The job keeps the id for review;
        /// turns stop resolving to it until something re-attaches.
        case detachThread
        case endThread
        /// Leave the saved thread exactly as it is — the job owns it.
        case keepThread
        case askFirst(JobThreadQuestion)
    }

    // MARK: - The decision

    static func resolve(_ request: Request, _ inputs: Inputs) -> Resolution {
        switch request {
        case .jobStarted:
            guard inputs.jobActive, inputs.persistenceEnabled else { return .proceedUnbound }
            if let active = inputs.activeThreadId { return .bindActiveThread(id: active) }
            return .deferBinding

        case .turn(let source) where source.debriefJobId != nil:
            // A debrief's turn goes to the debriefed job's own thread, whatever is open. It never
            // falls back to the active job: a debrief turn filed against the wrong job is the one
            // failure §6 exists to prevent, so with no binding it goes nowhere near a thread.
            guard inputs.persistenceEnabled else { return .proceedUnbound }
            guard let debrief = inputs.debrief, debrief.jobId == source.debriefJobId else {
                return .proceedUnbound
            }
            guard let thread = debrief.threadId, debrief.threadExists else {
                return .bindNewThread(reason: .debriefStarted)
            }
            return .useBoundThread(id: thread)

        case .turn:
            guard inputs.jobActive, inputs.persistenceEnabled else { return .proceedUnbound }
            guard !inputs.boundThreadDetached else { return .proceedUnbound }
            guard let bound = inputs.boundThreadId else {
                if let active = inputs.activeThreadId { return .bindActiveThread(id: active) }
                return .bindNewThread(reason: .noThreadYet)
            }
            // Deleted from under the job. Rebind rather than resurrect: the messages are gone and
            // pointing at a missing id would strand every later turn.
            guard inputs.boundThreadExists else { return .bindNewThread(reason: .boundThreadDeleted) }
            return .useBoundThread(id: bound)

        case .returnToWakeWord, .disconnect:
            guard inputs.persistenceEnabled, inputs.activeThreadId != nil else { return .keepThread }
            // A debrief owns the open thread across wake-word cycles exactly as a job does — the
            // conversation is the point of it, and ending it between sentences would scatter one
            // account across several threads.
            if let debrief = inputs.debrief, debrief.threadId == inputs.activeThreadId {
                return .keepThread
            }
            guard inputs.jobActive, !inputs.boundThreadDetached else { return .endThread }
            // A job is running. The open thread is the job's — either already bound, or about to
            // be by the next turn — unless the technician deliberately stepped into another one.
            if let bound = inputs.boundThreadId, bound != inputs.activeThreadId { return .endThread }
            return .keepThread

        case .newChat(let confirmed):
            guard shouldAsk(inputs) else { return .proceedUnbound }
            guard confirmed else {
                return .askFirst(JobThreadQuestion(jobReference: inputs.jobReference,
                                                   requested: .newChat))
            }
            return .detachThread

        case .resumeThread(let id, let confirmed):
            // Re-opening the job's own thread is never a question.
            if let bound = inputs.boundThreadId, bound == id, !inputs.boundThreadDetached {
                return .useBoundThread(id: id)
            }
            guard shouldAsk(inputs) else { return .proceedUnbound }
            guard confirmed else {
                return .askFirst(JobThreadQuestion(jobReference: inputs.jobReference,
                                                   requested: .switchThread(id: id)))
            }
            return .detachThread

        case .jobClosed:
            guard inputs.persistenceEnabled, let active = inputs.activeThreadId else { return .keepThread }
            // Finishing the job is one of the two things that really do end its thread.
            return inputs.boundThreadId == active ? .endThread : .keepThread

        case .launchRestore:
            guard inputs.jobActive, inputs.persistenceEnabled else { return .proceedUnbound }
            guard !inputs.boundThreadDetached else { return .proceedUnbound }
            guard let bound = inputs.boundThreadId else { return .deferBinding }
            guard inputs.boundThreadExists else {
                // Nothing to create at launch: no turn is happening. The next one rebinds.
                return .clearBinding(reason: .boundThreadDeleted)
            }
            return .useBoundThread(id: bound)
        }
    }

    /// Whether leaving the job's thread is what is being asked for. Only then is there a question.
    private static func shouldAsk(_ inputs: Inputs) -> Bool {
        guard inputs.jobActive, inputs.persistenceEnabled, !inputs.boundThreadDetached else { return false }
        guard let bound = inputs.boundThreadId else { return false }
        return bound == inputs.activeThreadId
    }
}

/// The question the app asks before it lets a job's conversation be left.
///
/// Never rhetorical and never silent: the whole point is that a technician who taps "New chat" out
/// of habit is told what it would do to the job they are on, in the job's own terms.
struct JobThreadQuestion: Equatable {
    enum Requested: Equatable {
        case newChat
        case switchThread(id: String)
    }

    let jobReference: String?
    let requested: Requested

    var spoken: String {
        let job = jobReference.map { "job \($0)" } ?? "a job"
        switch requested {
        case .newChat:
            return "You're on \(job) — keep this in the job, or start a separate chat?"
        case .switchThread:
            return "You're on \(job) — keep this in the job, or open that conversation separately?"
        }
    }
}
