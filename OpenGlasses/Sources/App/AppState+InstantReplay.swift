import Combine
import Foundation

/// The app side of Instant Replay: which relay feeds the buffer, what it reads to decide whether
/// it may run, and the one entry point the tool, the temple tap and the Shortcut all call.
extension AppState {

    /// Wire the buffer onto **`outboundFrames.publisher`, never `cameraService.framePublisher`**:
    /// the relay is where the bystander blur runs, so with the blur on the buffer only ever holds
    /// blurred frames. `OutboundFrameConsumer.instantReplayBuffer` is the roster entry.
    ///
    /// The camera's streaming flag is *read*, never requested: Instant Replay rides a stream the
    /// wearer started and stops the moment that stream does.
    func connectInstantReplay() {
        var seams = ReplayBufferService.Seams()
        seams.glassesStreaming = { [weak self] in self?.cameraService.isStreaming ?? false }
        seams.posture = { PowerPolicyService.shared.posture }
        seams.droppedFrameCount = { [weak self] in self?.outboundFrames.droppedFrameCount ?? 0 }
        seams.jobs = { FieldSessionService.shared }
        seams.saveToPhotos = { url in await GlassesPhotoAlbum.saveVideo(at: url).didSave }
        instantReplay.connect(seams, source: outboundFrames.publisher)

        // `@Published` fires before the value is stored, so each reconcile is a hop later, when
        // the flag it reads already says what the sink was told.
        instantReplayObservers = [
            cameraService.$isStreaming.removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.instantReplay.reconcile() }
            },
            PowerPolicyService.shared.$posture.removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.instantReplay.reconcile() }
            },
            // The status card reads `instantReplay.isRunning` through the app state, so a start or
            // a stop redraws it; both are rare, and the mark must never lag the buffer.
            instantReplay.$decision.map(\.isRunning).removeDuplicates().dropFirst().sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.updateLiveActivity()
                }
            },
        ]
    }

    /// Keep part of the replay buffer. What `instant_replay`, the temple tap and the Shortcut call.
    func saveInstantReplay(_ request: ReplaySaveRequest) async -> ReplaySaveOutcome {
        let outcome = await instantReplay.save(request)
        if outcome.didSave {
            addDebugEvent("Instant Replay kept (\(request.destination.rawValue)).")
        }
        return outcome
    }
}
