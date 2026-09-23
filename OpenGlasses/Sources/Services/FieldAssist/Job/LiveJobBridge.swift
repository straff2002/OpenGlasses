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
    }

    private var seams: Seams
    /// The block last sent, so a trigger that changed nothing the model can see sends nothing.
    private(set) var lastSentBlock: String?
    /// The generation `lastSentBlock` was sent for. A new session has been told nothing.
    private var lastSentGeneration: Int?
    /// A block that was ready while the session was busy.
    private(set) var heldBlock: LiveJobSnapshot?

    init(seams: Seams = Seams()) { self.seams = seams }

    func connect(_ seams: Seams) { self.seams = seams }

    // MARK: - Setup

    /// The block for the session's setup instruction, or nil when no job is open.
    ///
    /// Records what the setup carried, so the first mid-session refresh compares against what the
    /// model was actually given rather than against nothing.
    func setupBlock() -> String? {
        let block = LiveJobContract.block(session: seams.activeSession())
        lastSentBlock = block
        lastSentGeneration = seams.generation()
        heldBlock = nil
        return block
    }

    /// The session went away. Nothing it was told survives it.
    func sessionEnded() {
        lastSentBlock = nil
        lastSentGeneration = nil
        heldBlock = nil
    }

    // MARK: - Refresh

    /// The job changed. Re-inject the block when what the model can see has actually moved.
    ///
    /// - Returns: the snapshot that was sent, the one being held, or nil when nothing was due.
    @discardableResult
    func refresh() -> LiveJobSnapshot? {
        let generation = seams.generation()
        let block = LiveJobContract.block(session: seams.activeSession())
        // A job that has closed is worth saying once: a model still holding "JOB: open" would
        // answer as though the visit were running.
        let text = block ?? (lastSentBlock == nil ? nil : LiveJobContract.heading + "\nNo job is open.")
        guard let text else { return nil }
        if generation == lastSentGeneration, text == lastSentBlock, heldBlock == nil { return nil }
        return send(LiveJobSnapshot(generation: generation, text: text))
    }

    /// Try the held block again — called at a turn boundary, where the session is quiet.
    @discardableResult
    func flushHeldBlock() -> LiveJobSnapshot? {
        guard let held = heldBlock else { return nil }
        return send(held)
    }

    @discardableResult
    private func send(_ snapshot: LiveJobSnapshot) -> LiveJobSnapshot? {
        switch LiveJobSnapshotPolicy.decide(snapshot,
                                            currentGeneration: seams.generation(),
                                            canInject: seams.canInject(),
                                            isBusy: seams.isBusy()) {
        case .apply(let text):
            seams.injectText(text)
            lastSentBlock = text
            lastSentGeneration = snapshot.generation
            heldBlock = nil
            return snapshot
        case .holdBusy:
            heldBlock = snapshot
            return snapshot
        case .discardStaleGeneration:
            // Built for a session that no longer exists. Dropping it is the whole point: a block
            // that landed here would be describing a job to a conversation that was deliberately
            // emptied, or to the wrong session entirely.
            heldBlock = nil
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
