import Foundation

/// A short notice the app speaks about the turn itself — "Switching to Claude for this.",
/// "<X> can't analyze photos — using <Y> for this picture." — played *alongside* the model request
/// rather than in front of it.
///
/// The notices used to be awaited before the request started, so every routed or re-routed turn
/// paid the whole playback (2–5 s on a tester's log) as dead air before the model was even asked.
/// Nothing about the audio needs that order: the request is network work, and the notice was
/// already spoken while a cascade hop's retry was being prepared. What does need an order is the
/// speaker — `TextToSpeechService.speak` supersedes whatever is playing, so a reply that arrived
/// early would cut the notice off mid-word. The rules, each pinned by `TurnAnnouncementTests`:
///
/// 1. `announce` returns at once; the caller starts the request without waiting for playback.
/// 2. Whatever the turn says next — the reply, or the failure line — first awaits
///    `waitUntilSpoken()`, so the notice always finishes.
/// 3. When the notice ends and nothing is waiting to speak, `onFinished` runs. The live host starts
///    the thinking sound there: `speak` stops it, and the turn is still working. When the reply is
///    already waiting, it is skipped — the reply is about to stop it again.
/// 4. `cancel()` (barge-in, stop, hang-up) drops the notice's follow-up. Stopping the audio itself
///    stays with the caller's `stopSpeaking()`, which those paths already call.
///
/// Each notice carries its `SpeechSource` (Plan KL P4) through to the speaker, so a notice queued
/// behind another is still logged as what it is: the switch notice, or the conversation cue that
/// now plays the same way.
@MainActor
final class TurnAnnouncement {
    typealias Speak = @MainActor (String, SpeechSource) async -> Void

    private let speak: Speak
    private let onFinished: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    /// Advanced by every `announce` and `cancel`, so only the latest notice's completion counts.
    private var epoch = 0
    /// How many callers are parked in `waitUntilSpoken()` right now.
    private var waiters = 0

    init(speak: @escaping Speak, onFinished: @escaping @MainActor () -> Void) {
        self.speak = speak
        self.onFinished = onFinished
    }

    /// A notice is still playing (or queued behind one that is).
    var isPending: Bool { pending != nil }

    /// Start speaking `text` and return without waiting for it. A notice announced while another
    /// is still playing queues behind it rather than cutting it off.
    func announce(_ text: String, source: SpeechSource) {
        let previous = pending
        epoch += 1
        let mine = epoch
        pending = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.speak(text, source)
            guard !Task.isCancelled, self.epoch == mine else { return }
            self.pending = nil
            if self.waiters == 0 { self.onFinished() }
        }
    }

    /// Return once the pending notice, if any, has finished playing (or been stopped).
    func waitUntilSpoken() async {
        guard let pending else { return }
        waiters += 1
        await pending.value
        waiters -= 1
    }

    /// Forget the pending notice: its completion no longer runs `onFinished`.
    func cancel() {
        pending?.cancel()
        pending = nil
        epoch += 1
    }
}
