import Foundation

/// The wake-word / tap-to-talk conversation-start choreography (Plan BG P2): mark the conversation
/// active, bring the audio session + engine up, only then mark ourselves listening, snapshot and
/// pause other audio, acknowledge, start recording, refresh the Live Activity.
///
/// The ordering is load-bearing and has bitten before: the audio session + engine must be alive
/// BEFORE `markListening`. Tap-to-talk calls `stopListening()` first (engine = nil), and
/// `startListening()` bails on `guard !isListening`, so marking listening early leaves the shared
/// engine dead and forces `TranscriptionService` onto a fragile fallback engine. The stages are
/// injected as `@MainActor` closures capturing the live `AppState` (same seam pattern as
/// `ConversationTurnRunner`), so unit tests lock the order with recorder closures.
enum ConversationStartSequence {

    struct Deps {
        /// Mark the conversation active (`inConversation = true`).
        let beginConversation: @MainActor () -> Void
        /// Configure the shared audio session for recording. Async since BJ PR2 — the blocking
        /// activation now runs off-main through the coordinator.
        let configureAudioSession: @MainActor () async -> Void
        /// Bring the shared audio engine up. Failure must not abort the start — the
        /// transcription path has its own fallback engine.
        let ensureAudioEngineRunning: @MainActor () async throws -> Void
        /// Mark ourselves listening (`isListening = true`) — only after the engine is up.
        let markListening: @MainActor () -> Void
        /// Snapshot what's playing before pausing it.
        let snapshotNowPlaying: @MainActor () -> Void
        /// Pause podcasts/music so the user can speak clearly (skips if call in progress).
        /// Async since BJ PR2 (off-main session reconfigure).
        let pauseOtherAudio: @MainActor () async -> Void
        /// Plan GU §2 — switch first, then listen: wait until the conversation mic is live (route
        /// resolved, engine rebuilt on it, first buffers carrying sound), falling back to the phone
        /// mic at `TurnMicHandoff.deadline`. Strictly before the tone, so the tone means "talk now"
        /// on the mic that will actually hear it.
        let handOffMic: @MainActor () async -> Void
        /// Play the acknowledgment tone.
        let playAcknowledgmentTone: @MainActor () -> Void
        /// Start transcribing the user's turn.
        let startRecording: @MainActor () -> Void
        /// Push the new state to the Live Activity.
        let updateLiveActivity: @MainActor () -> Void
    }

    @MainActor
    static func run(_ deps: Deps) async {
        deps.beginConversation()
        // Audio session + engine BEFORE marking ourselves as listening (see type comment).
        await deps.configureAudioSession()
        try? await deps.ensureAudioEngineRunning()
        deps.markListening()
        deps.snapshotNowPlaying()
        await deps.pauseOtherAudio()
        await deps.handOffMic()
        deps.playAcknowledgmentTone()
        deps.startRecording()
        deps.updateLiveActivity()
    }
}
