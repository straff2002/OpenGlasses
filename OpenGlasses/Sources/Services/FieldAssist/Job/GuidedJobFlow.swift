import Foundation

/// The guided job flow: one conversation per job, the app asking for the job number itself, and a
/// question before the conversation moves to a different machine (Plan FO P1).
///
/// Everything deterministic lives in the pure types this composes — `JobThreadPolicy`,
/// `JobIntakeState`, `JobChangeDetector`. This is the part that touches the app: it performs the
/// thread moves the policy decides, speaks the two questions through an injected seam, writes both
/// questions and both answers into the session's audit log, and holds the equipment re-scope until
/// the technician has answered.
///
/// **It is the single chokepoint for a job's thread.** Five surfaces used to start, switch or end
/// a conversation on their own — the conversation page header, CarPlay's new and resume, the
/// watch's resume, and a glasses disconnect — and every one of them could have orphaned a job's
/// thread. They all come through here now. So does the launch restore, which fixes a live defect
/// on its way past: resuming a thread is two steps, the id *and* the history, and three callers
/// only ever did the first.
///
/// **It never speaks for the model and the model never drives it.** The model is told the state
/// through `FieldSessionContextSnapshot` so it does not ask for the number twice or contradict a
/// read-back; the prompts themselves are app behaviour and survive a model that ignores its
/// instructions, a provider switch, and a context compaction.
///
/// Headless by construction: every device-facing thing it needs is a closure, so the whole flow is
/// exercisable against a real `FieldSessionService` and a real `ConversationStore` in a temp
/// directory, with no `AppState`, no microphone and no glasses.
@MainActor
final class GuidedJobFlow: ObservableObject {

    /// What the flow needs from the app around it.
    struct Seams {
        /// Speak a line to the technician. `TextToSpeechService.speak` in the app.
        var speak: (String) async -> Void = { _ in }
        /// Hand a thread's prior turns to the model — the second half of a resume.
        var loadHistory: ([(role: String, content: String)]) -> Void = { _ in }
        /// Forget the model's in-memory context.
        var clearHistory: () -> Void = {}
        /// The mode a newly created thread is tagged with.
        var threadMode: () -> String = { AppMode.direct.rawValue }
        var personaId: () -> String? = { nil }
        var persistenceEnabled: () -> Bool = { Config.conversationPersistenceEnabled }
        /// Ask the model for one structured result — `LLMService.completeStructured` in the app.
        /// A debrief's summary is the only thing in this flow a model produces, and it produces it
        /// through a seam so the whole review is exercisable with no network (Plan FO P3b).
        var summarise: (String, String, [String: Any]) async -> [String: Any]? = { _, _, _ in nil }
        /// Which model answered, and a digest of the instructions it was given. Written onto the
        /// debrief so a reader can tell one summary's provenance from another's.
        var provenance: () -> AIProvenance? = {
            AIProvenance.forActiveModel(promptSources: DebriefContract.promptSources)
        }
    }

    /// Internal rather than private so the debrief half of the flow can live in its own file
    /// (`GuidedJobFlow+Debrief.swift`) without this one growing a second personality. Nothing
    /// outside the flow touches them.
    let sessions: FieldSessionService
    let store: ConversationStore
    private(set) var seams: Seams

    /// The question waiting on the technician, if one is. Published so the Job tab (P2) can show
    /// it with buttons for the moments voice fails.
    @Published private(set) var pendingUnitQuestion: JobUnitChangeQuestion?

    /// The evidence review, while it is open (Plan FO P2a). Published because the grid and the
    /// spoken walk edit **one** selection: a picture ticked by voice has to appear ticked on the
    /// screen, and one ticked on the screen has to be what the read-out says next.
    ///
    /// Nil whenever the review is not up, which is what stops "yes" meaning anything here during
    /// an ordinary turn.
    @Published private(set) var evidenceReview: EvidenceReviewVoiceState?
    /// The evidence the open review is about. Held beside the state because the state is a pure
    /// value and the catalogue is the job's.
    private var evidenceItems: [JobMediaItem] = []

    /// The debrief in hand, when one is (Plan FO P3b). Published because the past job's page and
    /// the Job tab both show it, and because a debrief on a *finished* job is state no session
    /// publishes on its own.
    @Published private(set) var debrief: ActiveDebrief?

    init(sessions: FieldSessionService, store: ConversationStore, seams: Seams = Seams()) {
        self.sessions = sessions
        self.store = store
        self.seams = seams
        pendingUnitQuestion = Self.question(for: sessions.activeSession)
    }

    /// Wire the app's services in after construction — `AppState` builds its services in an order
    /// this cannot assume.
    func connect(_ seams: Seams) { self.seams = seams }

    // MARK: - What P2 calls

    /// Where the job number stands.
    var intakeState: JobIntakeState { sessions.activeSession?.jobIntake ?? .notRequired }

    /// The saved conversation this job owns, or nil while it owns none.
    var boundThreadId: String? { sessions.activeSession?.conversationThreadId }

    /// Start a job. **A service call, not a prompt** — the quick action, the tool and the Job tab
    /// all come through here, so whether a job starts is never the model's decision.
    @discardableResult
    func startJob(vaultId: String, assetId: String? = nil, mode: FieldSession.Mode = .aiOnly,
                  jobReference: String? = nil) throws -> FieldSession {
        let session = try sessions.startSession(vaultId: vaultId, assetId: assetId, mode: mode,
                                                jobReference: jobReference)
        apply(JobThreadPolicy.resolve(.jobStarted, inputs()), reason: .jobStarted)
        applyThreadTitle()
        return session
    }

    /// Finish the job, and let its thread go with it.
    @discardableResult
    func closeJob(outcome: FieldSession.Outcome = .resolved) throws -> FieldSession {
        let resolution = JobThreadPolicy.resolve(.jobClosed, inputs())
        let session = try sessions.endSession(outcome: outcome)
        apply(resolution)
        pendingUnitQuestion = nil
        return session
    }

    /// A number arriving by a route that needs no read-back: typed on the Job tab, or handed to
    /// `field_session set_job_reference`.
    func supplyJobReference(_ text: String) {
        guard sessions.activeSession != nil else { return }
        let outcome = intakeState.advance(.referenceSupplied(text))
        commit(outcome, spokenAnswer: nil)
    }

    /// "I don't have one", said through a control rather than out loud. Recorded, never blocking.
    func declineJobReference() {
        guard sessions.activeSession != nil else { return }
        commit(intakeState.advance(.declinedExplicitly), spokenAnswer: nil)
    }

    /// Answer the change-of-unit question from a control.
    func answerUnitChange(_ answer: JobUnitChangeAnswer) async {
        await resolveUnitChange(answer, spoken: nil)
    }

    // MARK: - The evidence review (Plan FO P2a)

    /// The review is now in front of the technician, and listening.
    func beginEvidenceReview(selection: EvidenceSelection, items: [JobMediaItem]) {
        evidenceItems = items
        evidenceReview = EvidenceReviewVoiceState(selection: selection)
    }

    /// The technician changed something by tapping. The spoken walk edits the same value, so it
    /// takes the change rather than carrying on from a stale copy.
    func updateEvidenceReview(selection: EvidenceSelection) {
        guard evidenceReview != nil else { return }
        evidenceReview = EvidenceReviewVoiceState(selection: selection)
    }

    /// Start reading the pictures out one at a time. Offered rather than automatic: a sheet that
    /// starts talking the moment it appears is the wrong behaviour with a customer standing there.
    func readEvidenceOutLoud() async {
        guard let review = evidenceReview else { return }
        let step = review.beginWalk(items: evidenceItems)
        evidenceReview = step.state
        if let spoken = step.spoken { await seams.speak(spoken) }
    }

    /// The review has closed, however it closed.
    func endEvidenceReview() {
        evidenceReview = nil
        evidenceItems = []
    }

    // MARK: - The turn pipeline

    /// Give the app's outstanding question to the next utterance before the model sees it.
    ///
    /// Returns true when the utterance *was* an answer and must go no further. Anything that is
    /// not an answer — "what's this error code?", a bystander, the wake word firing on a cough —
    /// returns false and reaches the model untouched, with the question still outstanding.
    func handleUtterance(_ text: String) async -> Bool {
        // The debrief first, and before the active-session guard: a debrief is usually about a
        // job that finished hours ago, so "save" has to mean something with no job open at all
        // (Plan FO P3b).
        if debrief != nil, await handleDebriefUtterance(text) { return true }
        guard sessions.activeSession != nil else { return false }

        // The evidence review first, and only while it is actually open: "yes" is an answer to a
        // question that is being put right now, and nothing else in this app may claim it.
        if let review = evidenceReview {
            let step = review.hearing(text, items: evidenceItems)
            if step.consumed {
                evidenceReview = step.state
                if let spoken = step.spoken { await seams.speak(spoken) }
                return true
            }
        }

        if pendingUnitQuestion != nil, let answer = JobUnitChangeClassifier.classify(text) {
            await resolveUnitChange(answer, spoken: text)
            return true
        }
        guard intakeState.awaitsAnswer else { return false }
        let outcome = intakeState.advance(.heard(text))
        guard outcome.consumesUtterance else { return false }
        await commitSpeaking(outcome, spokenAnswer: text)
        return true
    }

    /// Put the app's outstanding question, if one is due. Called at the end of a turn, after the
    /// reply has been spoken and before the microphone re-arms, so the next thing heard is the
    /// answer.
    ///
    /// Safe to call on every turn: it speaks only when something is genuinely due, and the ask
    /// budget means a technician who ignores it twice is left alone.
    func speakPendingQuestionIfDue() async {
        guard sessions.activeSession?.isActive == true else { return }

        if let question = pendingUnitQuestion,
           let pending = sessions.activeSession?.pendingUnitChange, pending.asked == 0 {
            sessions.setPendingUnitChange(PendingUnitChange(candidate: pending.candidate,
                                                            candidateSerial: pending.candidateSerial,
                                                            raisedAt: pending.raisedAt,
                                                            asked: 1))
            sessions.logJobQuestion(question.spoken, asked: true,
                                    detail: ["kind": AnyCodable("unit_change"),
                                             "candidate": AnyCodable(pending.candidate.modelToken)])
            await seams.speak(question.spoken)
            return
        }

        guard intakeState.hasQuestionDue else { return }
        let outcome = intakeState.advance(.questionAsked)
        guard case .asked(let attempt) = outcome.state else { return }
        sessions.updateJobIntake(outcome.state)
        let line = attempt == 1 ? JobIntakePrompt.ask.spoken : JobIntakePrompt.askAgain.spoken
        sessions.logJobQuestion(line, asked: true,
                                detail: ["kind": AnyCodable("job_reference"),
                                         "attempt": AnyCodable(attempt)])
        await seams.speak(line)
    }

    /// Make sure the next turn lands in the job's conversation. Called before the store is asked
    /// to append anything, so a turn cannot be filed in the wrong thread and moved afterwards.
    func prepareThreadForTurn(_ source: JobThreadPolicy.TurnSource) {
        apply(JobThreadPolicy.resolve(.turn(source), inputs()))
        applyThreadTitle()
    }

    // MARK: - The thread chokepoint

    /// A voice turn finished. The job owns its thread across wake-word cycles — that is the whole
    /// point — so this ends a thread only when there is no job holding it open.
    func endThreadForVoiceReturn() { apply(JobThreadPolicy.resolve(.returnToWakeWord, inputs())) }

    /// The wearer put the glasses down. Same rule: a job survives a disconnect.
    func endThreadForDisconnect() { apply(JobThreadPolicy.resolve(.disconnect, inputs())) }

    /// What has to be asked before the technician is taken out of the job's conversation, or nil
    /// when nothing does.
    ///
    /// **A query, and now actually one.** It said so from the start and wrote an audit event on
    /// every call anyway (found by P2, fixed in P2a): P1's four callers all asked from a tap, so
    /// nothing was wrong in practice, but a view body asking the same question during a render
    /// would have filled the session log with questions nobody was ever put. Raising the question
    /// is `raiseLeaveJobThreadQuestion`, and that is what the surfaces call; this one is safe to
    /// ask from anywhere, as its documentation always claimed.
    ///
    /// - Parameter threadId: the conversation being opened, when one is. Re-opening the job's own
    ///   thread is never a question.
    func leaveJobThreadQuestion(switchingTo threadId: String? = nil) -> JobThreadQuestion? {
        let request: JobThreadPolicy.Request = threadId.map { .resumeThread(id: $0, confirmed: false) }
            ?? .newChat(confirmed: false)
        guard case .askFirst(let question) = JobThreadPolicy.resolve(request, inputs()) else { return nil }
        return question
    }

    /// Put the question to the technician, and write into the record that it was put.
    ///
    /// The log entry belongs here, beside the surface that is about to show the question, and not
    /// in the query — because "was the technician asked?" is a fact about a moment on a screen,
    /// not about a resolution being computed. `confirmLeaveJobThread` already records the answer.
    func raiseLeaveJobThreadQuestion(switchingTo threadId: String? = nil) -> JobThreadQuestion? {
        guard let question = leaveJobThreadQuestion(switchingTo: threadId) else { return nil }
        logThreadQuestion(question)
        return question
    }

    /// The technician chose the separate chat. The job lets go of its thread — it keeps the id so
    /// the conversation can still be reviewed under the job, but turns stop landing in it.
    func confirmLeaveJobThread() {
        guard case .detachThread = JobThreadPolicy.resolve(.newChat(confirmed: true), inputs()) else { return }
        sessions.detachConversationThread()
        sessions.logJobQuestion("leave job thread", asked: false, answer: "separate_chat",
                                detail: ["kind": AnyCodable("leave_job_thread")])
    }

    /// "New chat", for the surfaces that have no reset of their own to run (the conversation page
    /// header, CarPlay). Asks first while a job owns the open thread.
    /// - Returns: the question to put to the technician, or nil when the request went through.
    @discardableResult
    func requestNewChat(confirmed: Bool = false) -> JobThreadQuestion? {
        if !confirmed, let question = raiseLeaveJobThreadQuestion() { return question }
        if confirmed { confirmLeaveJobThread() }
        startFresh()
        return nil
    }

    /// Open another conversation, from wherever it was tapped. Resuming the job's own thread is
    /// never a question; leaving it for another one is.
    @discardableResult
    func requestResume(threadId: String, confirmed: Bool = false) -> JobThreadQuestion? {
        if !confirmed, let question = raiseLeaveJobThreadQuestion(switchingTo: threadId) { return question }
        if confirmed { confirmLeaveJobThread() }
        resume(threadId)
        return nil
    }

    /// Cold launch. Re-bind the restored job to its conversation — **through the two-step resume**,
    /// because a job thread rebound by id alone is an empty-context thread wearing a job number.
    ///
    /// This also repairs the plain case: a restored active thread with no job at all got its id
    /// back at launch and none of its history, so the wearer's first sentence after relaunching
    /// carried on a conversation the model had never seen.
    func restoreOnLaunch() {
        switch JobThreadPolicy.resolve(.launchRestore, inputs()) {
        case .useBoundThread(let id):
            resume(id, force: true)
        case .clearBinding(let reason):
            sessions.bindConversationThread(nil, reason: reason)
            replayActiveThread()
        default:
            replayActiveThread()
        }
        pendingUnitQuestion = Self.question(for: sessions.activeSession)
    }

    // MARK: - Equipment

    /// A machine has been recognised. Apply it, or hold it and ask.
    ///
    /// The correction path ("no, it's the 070") and a tap on the phone's model list go straight to
    /// `setEquipment`: those are the technician saying which machine this is, and a question there
    /// would be the app arguing with an instruction. This is for the paths where recognition
    /// *happened to* the session — a spoken model number, a nameplate the camera read.
    ///
    /// - Returns: the question to put, or nil when the equipment was applied as usual.
    @discardableResult
    func proposeEquipment(_ candidate: JobChangeDetector.Candidate,
                          candidateSerial: String? = nil) -> JobUnitChangeQuestion? {
        guard let session = sessions.activeSession else { return nil }
        let outcome = JobChangeDetector.compare(current: session.equipment,
                                                currentSerial: sessions.activeSerial,
                                                candidate: candidate,
                                                candidateSerial: candidateSerial)
        switch outcome {
        case .same:
            if case .model(let identity) = candidate { setEquipmentRecordingUnit(identity) }
            return nil
        case .unclear:
            // Not confident enough to re-scope and nowhere near confident enough to end a job.
            return nil
        case .additionalUnit(let identity):
            // Once per candidate. A technician who has already been asked about this machine and
            // said nothing is not asked again.
            if let pending = session.pendingUnitChange, pending.matches(identity) {
                return pendingUnitQuestion
            }
            let pending = PendingUnitChange(candidate: identity, candidateSerial: candidateSerial)
            sessions.setPendingUnitChange(pending)
            let question = JobUnitChangeQuestion(jobReference: session.jobReference, candidate: identity)
            pendingUnitQuestion = question
            return question
        }
    }

    /// Apply the held re-scope, or not, according to the answer.
    private func resolveUnitChange(_ answer: JobUnitChangeAnswer, spoken: String?) async {
        guard let session = sessions.activeSession,
              let pending = session.pendingUnitChange else { return }
        sessions.logJobQuestion("unit change", asked: false, answer: answer.rawValue,
                                detail: ["kind": AnyCodable("unit_change"),
                                         "candidate": AnyCodable(pending.candidate.modelToken),
                                         "transcript": AnyCodable(spoken ?? "")])
        switch answer {
        case .unsure:
            // Nothing changes, and the question is not asked again for this candidate.
            sessions.setPendingUnitChange(PendingUnitChange(candidate: pending.candidate,
                                                            candidateSerial: pending.candidateSerial,
                                                            raisedAt: pending.raisedAt,
                                                            asked: max(pending.asked, 1)))
            pendingUnitQuestion = nil
            await seams.speak("Leaving it as it is for now.")

        case .sameJob:
            // The re-scope happens exactly as it does today (FM): new continuity scope, procedure
            // dropped. The only difference is that the unit is written onto the job as well.
            sessions.setPendingUnitChange(nil)
            pendingUnitQuestion = nil
            setEquipmentRecordingUnit(pending.candidate, serial: pending.candidateSerial)
            await seams.speak("Same job, then — I've added \(pending.candidate.modelToken) to it.")

        case .jobFinished:
            sessions.setPendingUnitChange(nil)
            pendingUnitQuestion = nil
            let finished = try? closeJob(outcome: .resolved)
            // A new visit, to the machine that raised the question, with its own number to ask for.
            if let finished {
                let started = try? startJob(vaultId: finished.vaultId, assetId: nil, mode: finished.mode)
                if started != nil { setEquipmentRecordingUnit(pending.candidate, serial: pending.candidateSerial) }
            }
            await seams.speak("Closed that one off. Starting a new job on \(pending.candidate.modelToken).")
        }
    }

    /// `setEquipment` records the unit on the job itself, whichever route reached it; all this
    /// adds is the serial the change question happened to carry, and the thread's new name.
    private func setEquipmentRecordingUnit(_ identity: EquipmentIdentity, serial: String? = nil) {
        sessions.setEquipment(identity)
        sessions.recordSerialForActiveUnit(serial)
        applyThreadTitle()
    }

    // MARK: - Applying a resolution

    /// A **paused** job is still the job.
    ///
    /// `FieldSession.isActive` means "accepting input", which a paused session is not — and the
    /// launch restore pauses every recovered session on purpose, so reading the binding through
    /// `isActive` made a job that had survived a crash look like no job at all: its thread would
    /// have been orphaned by the first tap, and its outstanding job number forgotten. The binding,
    /// the intake and the change question all belong to a job that has not ended, paused or not.
    private func inputs() -> JobThreadPolicy.Inputs {
        let session = sessions.activeSession
        let bound = session?.conversationThreadId
        return JobThreadPolicy.Inputs(
            jobActive: session.map { $0.endedAt == nil && $0.outcome != .cancelled } ?? false,
            jobReference: session?.jobReference,
            boundThreadId: bound,
            boundThreadExists: bound.map { id in store.threads.contains { $0.id == id } } ?? false,
            boundThreadDetached: session?.conversationThreadDetached == true,
            activeThreadId: store.activeThreadId,
            persistenceEnabled: seams.persistenceEnabled(),
            debrief: debriefBinding())
    }

    private func apply(_ resolution: JobThreadPolicy.Resolution,
                       reason: JobThreadPolicy.BindReason? = nil) {
        switch resolution {
        case .proceedUnbound, .deferBinding, .keepThread, .askFirst:
            break
        case .bindActiveThread(let id):
            sessions.bindConversationThread(id, reason: reason ?? .jobStarted)
        case .bindNewThread(let bindReason):
            // The thread the job owned was deleted, or there has never been one. Either way the
            // job gets a fresh thread and the audit log says which it was — never a crash, never
            // an orphan pointing at something that is gone.
            let thread = store.startThread(mode: seams.threadMode(), personaId: seams.personaId())
            // Only a deletion clears the model's context: the transcript it was holding is the one
            // that has just been destroyed. A job that simply has no thread yet keeps whatever the
            // wearer was talking about a moment ago.
            if bindReason == .boundThreadDeleted { seams.clearHistory() }
            sessions.bindConversationThread(thread.id, reason: bindReason)
        case .clearBinding(let bindReason):
            sessions.bindConversationThread(nil, reason: bindReason)
        case .useBoundThread(let id):
            resume(id)
        case .detachThread:
            sessions.detachConversationThread()
        case .endThread:
            if store.activeThreadId != nil { store.endThread() }
        }
    }

    /// The thread inputs as the policy sees them, for the debrief half of the flow.
    func debriefInputs() -> JobThreadPolicy.Inputs { inputs() }

    /// The two-step resume, for the debrief half of the flow — id **and** history, never the id
    /// alone.
    func resumeThread(_ threadId: String) { resume(threadId) }

    /// The two-step resume, always. Never the id on its own.
    private func resume(_ threadId: String, force: Bool = false) {
        if force, store.activeThreadId == threadId {
            seams.loadHistory(store.replayMessages(for: threadId))
            return
        }
        ConversationContinuity.resume(threadId, in: store) { [seams] history in
            seams.loadHistory(history)
        }
    }

    /// Hand the model whatever thread the store restored, when no job owns one. The missing half
    /// of `ConversationStore.restoreActiveSession()`.
    private func replayActiveThread() {
        guard let id = store.activeThreadId, store.threads.contains(where: { $0.id == id }) else { return }
        seams.loadHistory(store.replayMessages(for: id))
    }

    private func startFresh() {
        ConversationContinuity.startFresh(in: store) { [seams] in seams.clearHistory() }
    }

    // MARK: - Titling

    /// Name the job's conversation after the job, once there is something to name it with.
    private func applyThreadTitle() {
        guard let session = sessions.activeSession,
              let threadId = session.conversationThreadId,
              !session.conversationThreadDetached,
              let reference = session.jobReference,
              let title = JobThreadTitle.title(reference: reference,
                                               equipment: session.equipment?.modelToken) else { return }
        store.applyJobTitle(title, to: threadId) { existing in
            JobThreadTitle.isGenerated(existing, reference: reference)
        }
    }

    // MARK: - Intake plumbing

    /// Record the transition without speaking (the out-of-band routes).
    private func commit(_ outcome: JobIntakeOutcome, spokenAnswer: String?) {
        write(outcome, spokenAnswer: spokenAnswer)
    }

    /// Record the transition and say the line that goes with it.
    private func commitSpeaking(_ outcome: JobIntakeOutcome, spokenAnswer: String?) async {
        write(outcome, spokenAnswer: spokenAnswer)
        if let prompt = outcome.prompt { await seams.speak(prompt.spoken) }
    }

    private func write(_ outcome: JobIntakeOutcome, spokenAnswer: String?) {
        if let reference = outcome.recordedReference {
            // Through the service's own setter, so the number reaches the work record, the
            // exported file names and the audit log by the one path that already owns them.
            sessions.setJobReference(reference)
        }
        sessions.updateJobIntake(outcome.state)
        if let audit = outcome.audit { log(audit, spokenAnswer: spokenAnswer) }
        applyThreadTitle()
    }

    private func log(_ audit: JobIntakeOutcome.Audit, spokenAnswer: String?) {
        var detail: [String: AnyCodable] = ["kind": AnyCodable("job_reference")]
        if let spokenAnswer { detail["transcript"] = AnyCodable(spokenAnswer) }
        switch audit {
        case .asked(let attempt):
            detail["attempt"] = AnyCodable(attempt)
            sessions.logJobQuestion("job number", asked: true, detail: detail)
        case .candidateHeard(let candidate):
            sessions.logJobQuestion("job number", asked: false, answer: "heard:\(candidate)", detail: detail)
        case .recorded(let reference):
            sessions.logJobQuestion("job number", asked: false, answer: reference, detail: detail)
        case .corrected(let previous):
            detail["previous"] = AnyCodable(previous)
            sessions.logJobQuestion("job number", asked: false, answer: "corrected", detail: detail)
        case .declined:
            // Flagged, never blocking: a visit with no job number is still delivered.
            sessions.logJobQuestion("job number", asked: false, answer: "declined", detail: detail)
        case .gaveUp:
            sessions.logJobQuestion("job number", asked: false, answer: "outstanding", detail: detail)
        }
    }

    private func logThreadQuestion(_ question: JobThreadQuestion) {
        sessions.logJobQuestion(question.spoken, asked: true,
                                detail: ["kind": AnyCodable("leave_job_thread")])
    }

    private static func question(for session: FieldSession?) -> JobUnitChangeQuestion? {
        guard let session, let pending = session.pendingUnitChange else { return nil }
        return JobUnitChangeQuestion(jobReference: session.jobReference, candidate: pending.candidate)
    }
}
