import Foundation

/// A job block built for one live session, and the generation it was built for (Plan FO P3a).
///
/// The generation is the live session's own identity — `GeminiLiveSessionManager.sessionIdentity`
/// and `OpenAIRealtimeSessionManager.sessionIdentity`, both of which already exist and both of
/// which are bumped on every start. EX resets a conversation by *cycling the session*, so a reset
/// bumps the identity; a block assembled before the reset therefore fails ``LiveJobSnapshot``'s
/// own check afterwards instead of landing in a conversation that was deliberately emptied.
struct LiveJobSnapshot: Equatable {
    let generation: Int
    let text: String
}

/// Whether a snapshot may still be sent.
enum LiveJobSnapshotDecision: Equatable {
    case apply(String)
    /// The session it was built for is gone (stopped, reset, or replaced by a later one).
    case discardStaleGeneration
    /// The session is not in a state that can take an injection right now; try again at the next
    /// turn boundary rather than talking over the model.
    case holdBusy
}

/// The pure half of the decision, so "a snapshot built before a reset never applies after it" is a
/// value test rather than a session test.
enum LiveJobSnapshotPolicy {
    static func decide(_ snapshot: LiveJobSnapshot,
                       currentGeneration: Int,
                       canInject: Bool,
                       isBusy: Bool) -> LiveJobSnapshotDecision {
        guard snapshot.generation == currentGeneration else { return .discardStaleGeneration }
        guard canInject else { return .discardStaleGeneration }
        guard !isBusy else { return .holdBusy }
        return .apply(snapshot.text)
    }
}

/// The guided job flow, applied to a live voice backend (Plan FO P3a).
///
/// One object, owned by each live session manager, holding the three things the plan asks both
/// providers to do identically:
///
///  - **the snapshot**: the bounded ``LiveJobContract`` block, put in the session's setup
///    instruction and re-injected whenever the job changes (a tool mutation, an equipment change,
///    an intake change — all of which are one publisher, because all of them write the session);
///  - **the app-driven prompts**: the intake question and the unit-change question, spoken by the
///    app rather than asked for from the model;
///  - **the classification**: the wearer's completed transcript is offered to `GuidedJobFlow`
///    before the app treats it as an ordinary turn, and an unrelated utterance passes straight
///    through.
///
/// The debrief (Plan FO P3b) rides the same path as a second block: ``DebriefContract``'s bounded
/// "JOB DEBRIEF:" block, put in the setup when a debrief is running and re-injected when one starts,
/// switches jobs or settles. It has its own last-sent record and its own held slot, so a debrief
/// changing never re-sends the job block (or the reverse), and it goes through the same
/// ``LiveJobSnapshotPolicy``, so a debrief block built before a reset never lands after it.
///
/// ### The per-provider audio decision
///
/// **Both providers: the app speaks, gated on the session's own busy signal.** Neither backend can
/// be made to say an exact sentence: `injectText(_:completeTurn: true)` asks the model to compose a
/// reply — which is the "model goodwill" this plan exists to remove — and `completeTurn: false`
/// produces no speech at all. So the question goes out through the same `TextToSpeechService` seam
/// Direct mode already uses, with the exact wording `JobIntakePrompt`/`JobUnitChangeQuestion` own,
/// and the session's `isBusyForInjection` is what stops it landing on top of the model. A question
/// that cannot be put now is held by `JobIntakeState` itself and re-offered at the next turn
/// boundary — `turnCompleted()` is the only moment either provider asks, and a turn boundary is by
/// definition a moment the model has stopped talking. The ask budget still bounds how often it is
/// put at all.
///
/// The one thing this cannot do is withhold the wearer's words from the provider: in a live session
/// the audio is already on the wire before any transcript exists. "Classified before the turn"
/// therefore means before the *app* treats it as a turn — the state machine consumes it, and the
/// very next snapshot tells the model the number is recorded and not to ask again.
@MainActor
final class LiveJobBridge {

    /// Everything device-facing, as closures, so the whole bridge runs headlessly.
    struct Seams {
        /// The job as it stands. `FieldSessionService.activeSession` in the app.
        var activeSession: () -> FieldSession? = { nil }
        /// The live session's identity. Bumped on every start by both managers.
        var generation: () -> Int = { 0 }
        /// Whether the session could take an injection at all.
        var canInject: () -> Bool = { false }
        /// Whether the model (or the wearer) is mid-utterance.
        var isBusy: () -> Bool = { false }
        /// Put text into the live session without asking for a reply.
        var injectText: (String) -> Void = { _ in }
        /// Offer an utterance to the guided flow. True when it answered an app question.
        var consumeUtterance: (String) async -> Bool = { _ in false }
        /// Put whatever question is due, at a turn boundary.
        var speakPendingQuestion: () async -> Void = {}
        /// Write the wearer's turn into the session's audit log. The gap P0 found on Gemini Live.
        var recordTurn: (String, String) -> Void = { _, _ in }
        /// The debrief block while one is running (P3b). `GuidedJobFlow.debriefBlock()` in the app.
        var debriefBlock: () -> String? = { nil }
    }

    /// One block's delivery record. The job block and the debrief block each have one, so either
    /// can change without re-sending the other.
    private struct Lane {
        /// The block last sent, so a trigger that changed nothing the model can see sends nothing.
        var lastSent: String?
        /// The generation `lastSent` was sent for. A new session has been told nothing.
        var lastSentGeneration: Int?
        /// A block that was ready while the session was busy.
        var held: LiveJobSnapshot?
    }

    private enum LaneID { case job, debrief }

    private var seams: Seams
    private var jobLane = Lane()
    private var debriefLane = Lane()

    /// The job block last sent.
    var lastSentBlock: String? { jobLane.lastSent }
    /// A job block that was ready while the session was busy.
    var heldBlock: LiveJobSnapshot? { jobLane.held }
    /// The debrief block last sent, or the line saying the debrief is over.
    var lastSentDebriefBlock: String? { debriefLane.lastSent }
    /// A debrief block that was ready while the session was busy.
    var heldDebriefBlock: LiveJobSnapshot? { debriefLane.held }

    init(seams: Seams = Seams()) { self.seams = seams }

    func connect(_ seams: Seams) { self.seams = seams }

    // MARK: - Setup

    /// The block for the session's setup instruction, or nil when no job is open.
    ///
    /// Records what the setup carried, so the first mid-session refresh compares against what the
    /// model was actually given rather than against nothing.
    func setupBlock() -> String? {
        let block = LiveJobContract.block(session: seams.activeSession())
        jobLane = Lane(lastSent: block, lastSentGeneration: seams.generation(), held: nil)
        return block
    }

    /// The debrief block for the session's setup instruction, or nil when no debrief is running.
    ///
    /// Independent of ``setupBlock()`` on purpose: a debrief usually runs on a finished job, so a
    /// session with no open job still has to be told which job the debrief is about.
    func setupDebriefBlock() -> String? {
        let block = seams.debriefBlock()
        debriefLane = Lane(lastSent: block, lastSentGeneration: seams.generation(), held: nil)
        return block
    }

    /// The session went away. Nothing it was told survives it.
    func sessionEnded() {
        jobLane = Lane()
        debriefLane = Lane()
    }

    // MARK: - Refresh

    /// The job changed. Re-inject the block when what the model can see has actually moved.
    ///
    /// - Returns: the snapshot that was sent, the one being held, or nil when nothing was due.
    @discardableResult
    func refresh() -> LiveJobSnapshot? {
        // A job that has closed is worth saying once: a model still holding "JOB: open" would
        // answer as though the visit were running.
        refresh(.job, block: LiveJobContract.block(session: seams.activeSession()),
                closed: LiveJobContract.heading + "\nNo job is open.")
    }

    /// A debrief started, moved to another job, or settled. Re-inject its block when what the
    /// model can see has moved.
    ///
    /// A debrief that settled or was put away is said once, the way a closed job is: a model still
    /// holding "DEBRIEF SUBJECT: Job 1004" would go on hearing everything as an account of 1004.
    @discardableResult
    func refreshDebrief() -> LiveJobSnapshot? {
        refresh(.debrief, block: seams.debriefBlock(), closed: DebriefContract.endedBlock)
    }

    /// Try the held blocks again — called at a turn boundary, where the session is quiet.
    ///
    /// - Returns: the job block's snapshot when one was held and went out, else the debrief's.
    @discardableResult
    func flushHeldBlock() -> LiveJobSnapshot? {
        let heldJob = jobLane.held
        let heldDebrief = debriefLane.held
        let job = heldJob.flatMap { send($0, on: .job) }
        let debrief = heldDebrief.flatMap { send($0, on: .debrief) }
        return job ?? debrief
    }

    private func refresh(_ id: LaneID, block: String?, closed: String) -> LiveJobSnapshot? {
        let generation = seams.generation()
        let lane = id == .job ? jobLane : debriefLane
        let text = block ?? (lane.lastSent == nil ? nil : closed)
        guard let text else { return nil }
        if generation == lane.lastSentGeneration, text == lane.lastSent, lane.held == nil { return nil }
        return send(LiveJobSnapshot(generation: generation, text: text), on: id)
    }

    private func update(_ id: LaneID, _ change: (inout Lane) -> Void) {
        switch id {
        case .job: change(&jobLane)
        case .debrief: change(&debriefLane)
        }
    }

    @discardableResult
    private func send(_ snapshot: LiveJobSnapshot, on id: LaneID) -> LiveJobSnapshot? {
        switch LiveJobSnapshotPolicy.decide(snapshot,
                                            currentGeneration: seams.generation(),
                                            canInject: seams.canInject(),
                                            isBusy: seams.isBusy()) {
        case .apply(let text):
            seams.injectText(text)
            update(id) { $0 = Lane(lastSent: text, lastSentGeneration: snapshot.generation, held: nil) }
            return snapshot
        case .holdBusy:
            update(id) { $0.held = snapshot }
            return snapshot
        case .discardStaleGeneration:
            // Built for a session that no longer exists. Dropping it is the whole point: a block
            // that landed here would be describing a job to a conversation that was deliberately
            // emptied, or to the wrong session entirely.
            update(id) { $0.held = nil }
            return nil
        }
    }

    // MARK: - The turn

    /// The wearer's completed utterance. Records it on the job and offers it to the guided flow.
    ///
    /// - Returns: true when the guided flow consumed it as an answer to one of its own questions.
    @discardableResult
    func handleTranscript(_ text: String, sourceID: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seams.activeSession() != nil else { return false }
        // The audit hook first, and unconditionally: a job's record is what was said on it,
        // whether or not the app's state machine had a use for the sentence.
        seams.recordTurn(trimmed, sourceID)
        return await seams.consumeUtterance(trimmed)
    }

    /// A turn finished: put the app's outstanding question, then let any held block through.
    func turnCompleted() async {
        await seams.speakPendingQuestion()
        flushHeldBlock()
    }
}
