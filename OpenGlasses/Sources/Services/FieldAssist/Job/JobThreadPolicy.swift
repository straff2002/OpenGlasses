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
///
/// **The same table decides when an ordinary conversation ends.** A voice turn's end used to close
/// the saved thread whenever no job held it, so every Tap & Talk or wake-word exchange became its
/// own conversation and nothing could be continued. Now the end of a turn ends nothing: the next
/// turn joins the same thread. A conversation is left behind only when the wearer asks for a new
/// one (New conversation on the page or CarPlay — `ConversationContinuity.startFresh`), or when the
/// next voice turn starts after `conversationIdleGap` with nothing said. Like binding, that is
/// decided lazily, at the start of the turn that would join the thread, never by a timer.
///
/// **A paused job claims nothing until it is resumed** (2026-10-03). Lazy binding made a job that
/// had never had a conversation adopt the next one anybody started — and a job is paused far more
/// often than it is abandoned, because closing the app pauses it and the next launch restores it
/// paused. On a real phone that is exactly what happened: a procedure tap opened a job with no
/// thread, the app closed, and hours later a question about the weather became that job's
/// conversation, was written into its record, and "you can end" closed it with an audit log. A
/// paused job is still the job — its number, its held question and its closing all still belong to
/// it — but while it is paused it does not bind a thread, does not pull a turn back into the thread
/// it already owns, does not ask before the wearer leaves that thread, and does not end anything at
/// the end of a turn. Its turns are ordinary unbound turns, except that the thread it owns is never
/// idle-ended (it is still the job's, and the job will want it back). Resuming the job puts all of
/// the lazy binding above back exactly as it was: the next turn binds, or rejoins the job's thread.
/// Turns made while it is paused are not recorded into the job's log either — that gate lives in
/// `FieldSessionService.recordConversationTurn`, because the log is the service's, not a thread's.
enum JobThreadPolicy {

    /// How long a conversation may sit untouched before the next voice turn starts a fresh one.
    /// Measured from the active thread's last activity — a message, or the wearer choosing it.
    static let conversationIdleGap: TimeInterval = 30 * 60

    /// Everything the decision depends on. A value type so the whole table is testable without a
    /// store, a session or an app.
    struct Inputs: Equatable {
        /// Whether a Field Assist job is running at all.
        var jobActive: Bool = false
        /// Whether that job is paused — deliberately, or because the app closed and the launch
        /// restore brought it back paused. A paused job is still `jobActive` (it has not ended),
        /// but it claims no conversation until it is resumed. Meaningless with no job.
        var jobPaused: Bool = false
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
        /// How long the active thread has gone without activity, in seconds. Nil with no active
        /// thread, or when the caller does not know.
        var activeThreadIdleFor: TimeInterval?
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

        /// A spoken turn. Only these are subject to the idle gap: a typed turn is made looking at
        /// the conversation it is typed into, and filing it anywhere else would be a surprise.
        var isVoice: Bool {
            switch self {
            case .wakeWord, .tapToTalk: return true
            case .typed, .debrief: return false
            }
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
        /// A voice turn finished and the wake word is re-arming. In push-to-talk this can arrive
        /// before the reply does — the release ends listening while the model is still thinking.
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
        /// The open conversation has gone quiet for `conversationIdleGap`: end it — and the
        /// model's context with it — so this turn starts a fresh one. Never a thread a job or a
        /// debrief owns.
        case endIdleThread
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

        case .turn(let source):
            guard inputs.persistenceEnabled else { return .proceedUnbound }
            // Paused, the job claims nothing: no adopting the open thread, no starting one, no
            // pulling the turn back into the thread it already owns. This is the check whose
            // absence turned a weather question into a job's conversation — the job had no thread
            // yet, so the lazy bind below took the first one anybody started.
            guard inputs.jobActive, !inputs.jobPaused, !inputs.boundThreadDetached else {
                return unboundTurn(source, inputs)
            }
            guard let bound = inputs.boundThreadId else {
                if let active = inputs.activeThreadId { return .bindActiveThread(id: active) }
                return .bindNewThread(reason: .noThreadYet)
            }
            // Deleted from under the job. Rebind rather than resurrect: the messages are gone and
            // pointing at a missing id would strand every later turn.
            guard inputs.boundThreadExists else { return .bindNewThread(reason: .boundThreadDeleted) }
            return .useBoundThread(id: bound)

        case .returnToWakeWord, .disconnect:
            // The end of a voice turn — or the glasses going down — is not the end of a
            // conversation. The next turn joins this thread; it is left behind only by an explicit
            // New conversation or, at the start of the next voice turn, the idle gap. Ending it
            // here is what made every Tap & Talk its own conversation, and in push-to-talk it ran
            // before the reply arrived, so the answer had no thread to land in.
            guard inputs.persistenceEnabled, inputs.activeThreadId != nil else { return .keepThread }
            // A debrief owns the open thread across wake-word cycles exactly as a job does — the
            // conversation is the point of it, and ending it between sentences would scatter one
            // account across several threads.
            if let debrief = inputs.debrief, debrief.threadId == inputs.activeThreadId {
                return .keepThread
            }
            // A paused job pulls nobody back: the thread the wearer is in is theirs until the job
            // is resumed, and the job's next turn after that rejoins its own thread lazily.
            guard inputs.jobActive, !inputs.jobPaused, !inputs.boundThreadDetached else {
                return .keepThread
            }
            // A job is running. The open thread is the job's — either already bound, or about to
            // be by the next turn — unless the technician stepped into another one without
            // detaching, which closes here so the job's next turn is back in the job's thread.
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
                // Nothing to create at launch: no turn is happening. The next one rebinds. Done
                // paused or not — forgetting an id that points at nothing claims no conversation,
                // it only stops the job's first turn after resuming from rebinding a deleted one.
                return .clearBinding(reason: .boundThreadDeleted)
            }
            // The launch restore pauses every job it recovers, so this is nearly always the paused
            // case — and a paused job claims nothing, at launch as on any turn. The store has
            // already restored whatever conversation was open when the app went away, if it was
            // recent; that is the one the wearer's history is replayed into. When the job owned
            // it, that is the job's thread anyway; when they had stepped somewhere else, a
            // relaunch is no reason to drag them back. Resuming the job brings its thread back on the next turn, the two-step
            // way, exactly as `.turn` does for a job that is running.
            guard !inputs.jobPaused else { return .proceedUnbound }
            return .useBoundThread(id: bound)
        }
    }

    /// A turn no job claims: it joins the open conversation, unless that has gone quiet for the
    /// idle gap and this is a voice turn. A thread a job or debrief owns is never ended for being
    /// idle — a detached job keeps the id, a paused job will want its thread back when it resumes,
    /// and a debrief carries on across a long drive.
    private static func unboundTurn(_ source: TurnSource, _ inputs: Inputs) -> Resolution {
        guard source.isVoice, let active = inputs.activeThreadId,
              let idle = inputs.activeThreadIdleFor, idle >= conversationIdleGap else {
            return .proceedUnbound
        }
        if active == inputs.boundThreadId { return .proceedUnbound }
        if let debrief = inputs.debrief, debrief.threadId == active { return .proceedUnbound }
        return .endIdleThread
    }

    /// Whether leaving the job's thread is what is being asked for. Only then is there a question.
    ///
    /// Never while the job is paused: the question exists so a technician mid-job is not walked
    /// out of its conversation by a habitual tap, and a paused job is not mid-anything. Asking
    /// "keep this in the job?" of someone who put the job down hours ago is the app arguing with
    /// a decision they already made. Leaving its thread then is not a detach — the job keeps the
    /// binding, and resuming it brings the thread back.
    private static func shouldAsk(_ inputs: Inputs) -> Bool {
        guard inputs.jobActive, !inputs.jobPaused, inputs.persistenceEnabled,
              !inputs.boundThreadDetached else { return false }
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
