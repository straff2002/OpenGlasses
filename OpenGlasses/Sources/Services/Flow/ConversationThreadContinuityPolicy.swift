import Foundation

/// Whether ending the *voice conversation* should also end the *saved chat thread*.
///
/// These are two different lifetimes that have been sharing one. `inConversation` is "the mic is
/// still in this exchange", which ends at the disconnect tone a second or two after the reply.
/// The saved thread is what the wearer later scrolls through. Tying the second to the first means
/// every wake-word turn becomes its own one-turn thread, which is what a field tester saw on a
/// job: each question he asked about the same unit was filed as a separate conversation.
///
/// During a Field Assist job the thread the technician wants is the *job*: the questions, the
/// readings and the answers from one visit, in one place. So while a session is active, the voice
/// conversation ending is not the thread ending. The thread is closed by the things that really
/// do end it — finishing the job, or the wearer explicitly starting a new chat or a new topic.
///
/// Deliberately not a binding between a job and a thread id: this rule only decides whether to
/// close the current thread at the end of a turn. Which thread a job owns across app restarts is
/// a larger question and belongs with the work that owns it.
enum ConversationThreadContinuityPolicy {

    /// - Parameters:
    ///   - persistenceEnabled: whether conversations are being saved at all.
    ///   - hasActiveThread: whether there is an open thread to end.
    ///   - fieldSessionActive: whether a Field Assist job is running.
    static func shouldEndSavedThread(persistenceEnabled: Bool,
                                     hasActiveThread: Bool,
                                     fieldSessionActive: Bool) -> Bool {
        guard persistenceEnabled, hasActiveThread else { return false }
        return !fieldSessionActive
    }
}
