import Foundation

/// The recorder's device-facing seams (Plan IM P1).
///
/// Everything the recorder touches outside itself is a closure, so the session logic — the
/// standing line, the prompts in the car, the next-case split, the cap, the job path — is
/// headless-testable with a scripted capture.
extension AppState {

    func makeExperienceRecorder() -> ExperienceRecorder {
        ExperienceRecorder(store: .shared, seams: ExperienceRecorder.Seams(
            availability: { ExperienceRecordingAvailability.current() },
            // A conversation that is listening would hear the recording too, and send it to the
            // model. The recorder waits for it to end.
            conversationActive: { [weak self] in self?.isListening ?? false },
            speak: { [weak self] line in await self?.speechService.speak(line, source: .job) },
            makeCapture: { [weak self] in LiveExperienceCapture(audio: self?.captureAudioRouter) },
            captureFolder: { ExperienceRecorderRules.captureFolder() },
            openJob: { FieldSessionService.shared.activeSession?.id },
            fileOnJob: { transcript in ExperienceJobFiling.file(transcript, with: .shared) },
            vaultInForce: { Config.fieldAssistDefaultVaultId },
            now: { Date() },
            startTicker: { recorder in
                let task = Task { @MainActor [weak recorder] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let recorder, !Task.isCancelled else { return }
                        await recorder.tick(now: Date())
                    }
                }
                return { task.cancel() }
            }))
    }
}
