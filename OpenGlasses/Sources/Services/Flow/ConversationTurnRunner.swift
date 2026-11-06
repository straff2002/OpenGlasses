import Foundation

/// The execution skeleton of one LLM turn (Plan BG P2): send → cancellation check → post-process →
/// cancellation check → accept → cancellation check → speak, with a `finish` stage that ALWAYS runs
/// — success, error, or cancellation.
///
/// `handleTranscription`'s photo and normal turns both run this skeleton inside the tracked
/// `currentLLMTask`; only the stage bodies differ, so they are injected as `@MainActor` closures
/// that capture the live `AppState` (same pattern as `VoiceCommandHandler` — no wide protocol seam).
/// That makes the spine's ordering guarantees unit-testable with recorder closures:
///
/// - A response is only accepted/spoken if the turn wasn't cancelled while the LLM worked
///   (barge-in / stop must never speak a stale reply).
/// - An error mid-flow still reaches `finish`, so the app resumes listening or returns to the
///   wake word instead of sticking in the processing state (the July 2026 audit's
///   stuck-listening scenario).
/// - A suggested-follow-ups tail (Plan KP P2, `FollowUpTail`) never reaches `postProcess`,
///   `accept` or `speak`, whichever brain answered. `LLMService` already takes it off its own
///   replies (and their history); this is the spine's backstop for every other `send`, and for a
///   tail a memory tag after it kept from the end of the reply until `postProcess` removed the
///   tag. Its questions go to `onFollowUps` only.
enum ConversationTurnRunner {

    /// The seams of one turn. All closures are main-actor isolated because they mutate
    /// `AppState`'s published properties and drive UI-adjacent services.
    struct Deps {
        /// Produce the raw LLM response (photo capture + vision call, local agent, or cloud call).
        let send: @MainActor () async throws -> String
        /// Transform the raw response before it is accepted (memory-command parsing; identity
        /// when user memory is disabled).
        let postProcess: @MainActor (String) async -> String
        /// Accept the final response: publish it, persist it, log it.
        let accept: @MainActor (String) async -> Void
        /// Speak the response (wrapped in the stop-listener on the live host).
        let speak: @MainActor (String) async -> Void
        /// The turn was cancelled (barge-in / stop / cancel) — the reply was never spoken, and
        /// stages after the point of cancellation never ran.
        let onCancelled: @MainActor () -> Void
        /// `send` failed with a non-cancellation error: publish/speak the failure.
        let onError: @MainActor (Error) async -> Void
        /// Always runs last, on every path: restore any temporary model switch, clear the
        /// processing state, resume listening or return to the wake word.
        let finish: @MainActor () async -> Void
        /// Wait out a model-switch notice still playing (`TurnAnnouncement.waitUntilSpoken`), so
        /// the reply or the failure line does not cut it off mid-word. The notice plays alongside
        /// the request, so by the time the model answers it has usually already finished.
        var waitForAnnouncement: @MainActor () async -> Void = {}
        /// What the wearer said or typed to start this turn, bound around `send` as
        /// `TurnUtteranceScope.current` so a tool the model calls can check its arguments against
        /// the words (`RelativeTimeGuard`). Nil for a turn nobody spoke.
        var utterance: String? = nil
        /// Plan KP P2: the spine took a follow-ups tail off the reply; these are its questions
        /// (possibly none). Not called when the reply had no tail.
        var onFollowUps: @MainActor ([String]) -> Void = { _ in }
    }

    @MainActor
    static func run(_ deps: Deps) async {
        // Plan CU P1: this spine is where `commit` and `generationDone` are honest for every
        // backend at once. Deliberately not inside `runToolLoop` — auxiliary completions
        // (classification, history summarisation) run through that same loop *during* a turn, and
        // first-wins marks would hand the turn its neighbour's timings.
        TurnRecorder.beginTurn()
        do {
            try Task.checkCancellation()
            TurnRecorder.mark(.commit)
            let sent = try await TurnUtteranceScope.$current.withValue(deps.utterance) {
                try await deps.send()
            }
            TurnRecorder.mark(.generationDone)
            // `postProcess` can persist memory and inject prompt state, so a response cancelled
            // while in flight must not reach it.
            try Task.checkCancellation()
            // Plan KP P2: the tail comes off before memory sees the reply, and again after, for
            // one that a memory tag written after it kept from the end.
            let tail = FollowUpTail.parse(sent)
            let processed = FollowUpTail.parse(await deps.postProcess(tail.answer))
            if tail.removedTail || processed.removedTail {
                deps.onFollowUps(tail.removedTail ? tail.followUps : processed.followUps)
            }
            let response = processed.answer
            // Each injected async stage can yield the main actor. Re-check before every visible
            // step so a barge-in cannot persist, mirror, or speak a stale response.
            try Task.checkCancellation()
            await deps.accept(response)
            try Task.checkCancellation()
            // Before the hand-off, not inside `speak`: waiting on the app's own notice is not
            // synthesis time, and `ttsRequested → firstAudio` is the synthesis measure.
            await deps.waitForAnnouncement()
            try Task.checkCancellation()
            TurnRecorder.handOffToSpeech()
            await deps.speak(response)
        } catch is CancellationError {
            TurnRecorder.noteAbandoned()
            deps.onCancelled()
        } catch {
            TurnRecorder.noteAbandoned()
            // The failure line is speech too: it must not cut off a notice still playing.
            if !Task.isCancelled { await deps.waitForAnnouncement() }
            // URLSession/provider SDKs can surface their own error after the parent task was
            // cancelled. The interruption wins: do not speak an error after a user barge-in.
            if Task.isCancelled {
                deps.onCancelled()
            } else {
                TurnRecorder.noteFailure(error)
                await deps.onError(error)
            }
        }
        await deps.finish()
        TurnRecorder.endTurn()
    }
}
