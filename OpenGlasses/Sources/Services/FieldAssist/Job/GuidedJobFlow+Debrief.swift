import Foundation

/// A debrief while it is happening (Plan FO §6, P3b).
///
/// Held in memory, on purpose. **Nothing on the record exists until a save**, so a debrief that is
/// abandoned — the app closed, the drive ended, the technician changed their mind — leaves its
/// turns in the job's conversation and the audit log saying they were never saved, and leaves the
/// work record exactly as it was.
struct ActiveDebrief: Equatable {
    let id: String
    /// The job this debrief is about — usually a finished one.
    let job: DebriefJobResolver.Candidate
    var turns: [JobDebrief.Turn] = []
    var state: DebriefReviewState = .listening
    /// The conversation the turns are landing in.
    var threadId: String?

    var sessionId: String { job.sessionId }
    var jobNumber: String {
        job.jobReference.map { "Job \($0)" } ?? JobTabModel.noJobNumber
    }

    /// The id the next turn gets. Stable and readable, so a citation in a summary resolves to a
    /// line a person can actually find in the log.
    var nextTurnId: String { "\(id)-t\(turns.count + 1)" }
}

extension GuidedJobFlow {

    // MARK: - Starting, switching, ending

    /// Every job a debrief may be about, newest first — the open one included.
    ///
    /// The order is what "next" and "previous" mean, so it is decided once, here, and both the
    /// resolver and the CarPlay list read the same sequence.
    func debriefCandidates() -> [DebriefJobResolver.Candidate] {
        let all = sessions.history.sorted { $0.startedAt > $1.startedAt }
        return all.map { session in
            DebriefJobResolver.Candidate(
                sessionId: session.id,
                jobReference: session.jobReference.flatMap { $0.isEmpty ? nil : $0 },
                startedAt: session.startedAt,
                outcomeLabel: session.outcome.displayName,
                isActive: session.endedAt == nil && session.outcome != .cancelled)
        }
    }

    /// Begin a debrief on one job. The app names the job out loud before anything is said about it.
    ///
    /// - Returns: false when the job is not on this device, so a caller can say so rather than
    ///   opening a debrief bound to nothing.
    @discardableResult
    func startDebrief(jobId: String) async -> Bool {
        guard let job = debriefCandidates().first(where: { $0.sessionId == jobId }) else {
            return false
        }
        // A debrief already in flight on another job is left exactly as it was — unsaved — and its
        // turns stay where they landed. Switching is not discarding.
        let session = sessions.history.first { $0.id == jobId }
        debrief = ActiveDebrief(id: UUID().uuidString, job: job,
                                threadId: session?.conversationThreadId)
        sessions.logDebrief(.debriefStarted, sessionId: jobId,
                            text: job.spoken,
                            payload: ["debrief": AnyCodable(debrief?.id ?? "")])
        await seams.speak(DebriefPrompt.started(job: job.spoken).spoken)
        return true
    }

    /// Move the debrief to another job, by what the technician said.
    ///
    /// Returns the resolution so the caller can put the question an ambiguous or unknown reference
    /// produces — the app asks by date and never guesses.
    @discardableResult
    func switchDebrief(to spoken: String) async -> DebriefJobResolver.Resolution {
        let resolution = DebriefJobResolver.resolve(spoken, candidates: debriefCandidates(),
                                                    current: debrief?.sessionId)
        switch resolution {
        case .resolved(let sessionId):
            guard sessionId != debrief?.sessionId else { return resolution }
            guard let job = debriefCandidates().first(where: { $0.sessionId == sessionId }) else {
                return resolution
            }
            let session = sessions.history.first { $0.id == sessionId }
            debrief = ActiveDebrief(id: UUID().uuidString, job: job,
                                    threadId: session?.conversationThreadId)
            sessions.logDebrief(.debriefStarted, sessionId: sessionId, text: job.spoken,
                                payload: ["debrief": AnyCodable(debrief?.id ?? ""),
                                          "switched": AnyCodable(true)])
            await seams.speak(DebriefPrompt.switched(job: job.spoken).spoken)
        case .ambiguous(let question, _), .notFound(let question):
            await seams.speak(question)
        case .notAReference:
            break
        }
        return resolution
    }

    /// Put the debrief away without settling it. Whatever was said stays in the conversation,
    /// marked unsaved; nothing reaches the record.
    func endDebrief() {
        guard let current = debrief else { return }
        if !current.state.isSettled {
            sessions.logDebrief(.debriefDiscarded, sessionId: current.sessionId,
                                text: "abandoned",
                                payload: ["debrief": AnyCodable(current.id),
                                          "turns": AnyCodable(current.turns.count),
                                          "saved": AnyCodable(false)])
        }
        debrief = nil
    }

    /// The block the model is given while a debrief is running, or nil when none is.
    ///
    /// The same shape FM and P3a use, so Direct mode and both live backends are told the same
    /// thing by the same renderer.
    func debriefBlock() -> String? {
        guard let current = debrief, !current.state.isSettled else { return nil }
        return DebriefContract.block(job: current.job, record: debriefRecord(current.sessionId))
    }

    /// What the thread policy needs to know about the debrief in hand.
    func debriefBinding() -> JobThreadPolicy.DebriefBinding? {
        guard let current = debrief, !current.state.isSettled else { return nil }
        return JobThreadPolicy.DebriefBinding(
            jobId: current.sessionId,
            threadId: current.threadId,
            threadExists: current.threadId.map { id in store.threads.contains { $0.id == id } } ?? false)
    }

    // MARK: - The turn pipeline

    /// Offer an utterance to the debrief before anything else sees it.
    ///
    /// Returns true when the debrief consumed it — a save, a scrap, an edit, or "that's it". An
    /// ordinary line of the account returns **false**: it is recorded as a turn *and* reaches the
    /// model, because the model is the one holding the conversation.
    func handleDebriefUtterance(_ text: String) async -> Bool {
        guard var current = debrief, !current.state.isSettled else { return false }

        // A switch is offered first: "next job" while a read-back is outstanding means the
        // technician has moved on, and the unsaved summary is left unsaved rather than applied to
        // the job they have just switched to.
        if DebriefJobResolver.relativeReference(in: text) != nil
            || DebriefJobResolver.spokenNumber(in: text) != nil {
            let resolution = await switchDebrief(to: text)
            if case .notAReference = resolution { /* fall through */ } else { return true }
            guard let refreshed = debrief else { return true }
            current = refreshed
        }

        let outcome = current.state.advance(.heard(text))
        let summaryBefore = current.state.summary
        current.state = outcome.state
        if outcome.recordsTurn { current = recordTurn(text, on: current) }
        debrief = current
        await perform(outcome, on: current, summaryBefore: summaryBefore)
        return outcome.consumesUtterance
    }

    /// Make sure the next debrief turn lands in the debriefed job's conversation.
    ///
    /// **Never the open job's.** A debrief on job 1004 said while job 1005 is running belongs to
    /// 1004, and the policy's `.debrief` source is what says so; this performs what it decides,
    /// including creating a thread for a job that never had one and writing the binding back onto
    /// that job so review later finds the turns in place.
    func prepareThreadForDebriefTurn() {
        guard var current = debrief else { return }
        switch JobThreadPolicy.resolve(.turn(.debrief(jobId: current.sessionId)), debriefInputs()) {
        case .useBoundThread(let id):
            resumeThread(id)
            current.threadId = id
        case .bindNewThread:
            let thread = store.startThread(mode: seams.threadMode(), personaId: seams.personaId())
            current.threadId = thread.id
            sessions.bindDebriefThread(thread.id, sessionId: current.sessionId)
        default:
            return
        }
        debrief = current
    }

    /// The technician tapped Save on the phone, or said it.
    func saveDebrief() async {
        guard let current = debrief else { return }
        let summaryBefore = current.state.summary
        let outcome = current.state.advance(.saveRequested)
        var updated = current
        updated.state = outcome.state
        debrief = updated
        await perform(outcome, on: updated, summaryBefore: summaryBefore)
    }

    func discardDebrief() async {
        guard let current = debrief else { return }
        let outcome = current.state.advance(.discardRequested)
        var updated = current
        updated.state = outcome.state
        debrief = updated
        await perform(outcome, on: updated, summaryBefore: nil)
    }

    /// "That's it" from a button rather than out loud.
    func finishDebrief() async {
        guard let current = debrief else { return }
        let outcome = current.state.advance(.finishRequested)
        var updated = current
        updated.state = outcome.state
        debrief = updated
        await perform(outcome, on: updated, summaryBefore: nil)
    }

    func retryDebriefSummary() async {
        guard let current = debrief else { return }
        let outcome = current.state.advance(.retryRequested)
        var updated = current
        updated.state = outcome.state
        debrief = updated
        await perform(outcome, on: updated, summaryBefore: nil)
    }

    /// Keep the account as it was said, labelled, when no summary could be made.
    func keepDebriefRaw() async {
        guard let current = debrief else { return }
        let outcome = current.state.advance(.keepRawRequested)
        var updated = current
        updated.state = outcome.state
        debrief = updated
        await perform(outcome, on: updated, summaryBefore: nil)
    }

    // MARK: - Performing a transition

    private func perform(_ outcome: DebriefReviewOutcome, on current: ActiveDebrief,
                         summaryBefore: DebriefSummary?) async {
        if let prompt = outcome.prompt { await seams.speak(prompt.spoken) }

        switch outcome.action {
        case .none:
            break

        case .requestSummary:
            await requestSummary(for: current)

        case .speakReadBack:
            guard case .readBack(let summary) = outcome.state else { break }
            await seams.speak(summary.spokenReadBack)
            var updated = debrief ?? current
            updated.state = updated.state.advance(.readBackSpoken).state
            debrief = updated

        case .save:
            guard let summary = summaryBefore ?? current.state.summary else { break }
            let written = JobDebrief.make(summary: summary, turns: current.turns,
                                          provenance: seams.provenance(),
                                          threadId: current.threadId)
            sessions.recordDebrief(written, sessionId: current.sessionId)
            await seams.speak(DebriefPrompt.saved(job: current.jobNumber).spoken)

        case .saveRaw:
            let written = JobDebrief.unsummarised(turns: current.turns, threadId: current.threadId)
            sessions.recordDebrief(written, sessionId: current.sessionId)
            await seams.speak(DebriefPrompt.keptRaw(job: current.jobNumber).spoken)

        case .discard:
            sessions.logDebrief(.debriefDiscarded, sessionId: current.sessionId, text: "scrapped",
                                payload: ["debrief": AnyCodable(current.id),
                                          "turns": AnyCodable(current.turns.count),
                                          "saved": AnyCodable(false)])
        }
    }

    /// Ask the model, and route its answer through the decoder — never straight onto the record.
    private func requestSummary(for current: ActiveDebrief) async {
        guard !current.turns.isEmpty else {
            await applySummaryFailure("There's nothing to summarise yet.", on: current)
            return
        }
        let json = await seams.summarise(
            DebriefContract.summarySystemPrompt,
            DebriefContract.summaryUserText(job: current.job.spoken, turns: current.turns),
            DebriefSummary.jsonSchema)
        guard let json else {
            await applySummaryFailure(DebriefSummaryDecoder.Failure.notAnObject.spoken, on: current)
            return
        }
        switch DebriefSummaryDecoder.decode(json, turnIds: current.turns.map(\.id)) {
        case .success(let summary):
            guard var updated = debrief, updated.id == current.id else { return }
            let outcome = updated.state.advance(.summaryReturned(summary))
            updated.state = outcome.state
            debrief = updated
            await perform(outcome, on: updated, summaryBefore: nil)
        case .failure(let failure):
            await applySummaryFailure(failure.spoken, on: current)
        }
    }

    private func applySummaryFailure(_ reason: String, on current: ActiveDebrief) async {
        guard var updated = debrief, updated.id == current.id else { return }
        let outcome = updated.state.advance(.summaryFailed(reason))
        updated.state = outcome.state
        debrief = updated
        await perform(outcome, on: updated, summaryBefore: nil)
    }

    /// Write one line of the account down: onto the debrief, and into the job's own log with the
    /// id the summary will cite.
    private func recordTurn(_ text: String, on current: ActiveDebrief) -> ActiveDebrief {
        var updated = current
        let turn = JobDebrief.Turn(id: current.nextTurnId,
                                   text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   at: Date())
        updated.turns.append(turn)
        sessions.logDebrief(.debriefTurn, sessionId: current.sessionId, text: turn.text,
                            payload: ["debrief": AnyCodable(current.id),
                                      "turn": AnyCodable(turn.id),
                                      "saved": AnyCodable(false)])
        return updated
    }

    // MARK: - Helpers

    /// The record of the job being debriefed, for the model's block.
    private func debriefRecord(_ sessionId: String) -> WorkRecord? {
        guard let session = sessions.history.first(where: { $0.id == sessionId }) else { return nil }
        let name = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
        return WorkRecord(session: session, vaultName: name)
    }
}
