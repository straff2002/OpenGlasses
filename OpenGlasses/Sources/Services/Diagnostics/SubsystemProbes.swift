import Foundation

/// The live edge of the subsystem self-test: each probe exercises the real
/// service, so `SubsystemTestRunner` stays a pure, unit-tested core.
///
/// Shared rather than owned by one screen — the same six checks back both the
/// Developer panel and the Diagnostics & Support screen, and a check that exists
/// in only one of them is a check someone won't run.
@MainActor
enum SubsystemProbes {

    static func makeRunner(appState: AppState) -> SubsystemTestRunner {
        let tests: [SubsystemTest] = [
            SubsystemTest(id: "glasses", name: "Glasses Link", icon: "eyeglasses") { @MainActor in
                guard appState.isConnected else {
                    return .fail("Not connected — pair via the Meta AI app")
                }
                let name = appState.glassesService.deviceName ?? "Glasses"
                let battery = appState.glassesService.batteryLevel.map { " · \($0)%" } ?? ""
                return .pass("\(name)\(battery)")
            },
            SubsystemTest(id: "camera", name: "Camera Photo", icon: "camera") { @MainActor in
                guard appState.isConnected else {
                    return .fail("Needs connected glasses")
                }
                do {
                    let data = try await appState.cameraService.capturePhoto()
                    return .pass("\(max(1, data.count / 1024)) KB photo")
                } catch {
                    return .fail(error.localizedDescription)
                }
            },
            SubsystemTest(id: "hud", name: "HUD Render", icon: "rectangle.dashed") { @MainActor in
                guard appState.glassesDisplay.hasDisplayCapability else {
                    return .fail("No display on this device")
                }
                appState.glassesDisplay.showNotification(
                    title: "Test", body: "Developer panel render check", icon: .info, duration: 4
                )
                return .pass("Card sent to lens")
            },
            SubsystemTest(id: "query", name: "AI Query", icon: "brain.head.profile") { @MainActor in
                guard Config.activeModel != nil else {
                    return .fail("No model configured")
                }
                do {
                    let reply = try await appState.llmService.completeStateless(
                        "Reply with exactly: OK",
                        system: "You are a connectivity probe. Reply with exactly: OK"
                    )
                    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.localizedCaseInsensitiveContains("ok")
                        ? .pass(Config.activeModel?.name ?? "Model answered")
                        : .fail("Unexpected reply: \(String(trimmed.prefix(60)))")
                } catch {
                    return .fail(error.localizedDescription)
                }
            },
            SubsystemTest(id: "tts", name: "Text to Speech", icon: "speaker.wave.2") { @MainActor in
                await appState.speechService.speak("Test okay", urgency: .low, mirrorToHUD: false)
                return .pass("Spoken")
            },
            SubsystemTest(id: "wakeword", name: "Wake Word", icon: "waveform.badge.mic") { @MainActor in
                appState.wakeWordService.isListening
                    ? .pass("Listening for “\(Config.wakePhrase.capitalized)”")
                    : .fail("Not listening — check mic permission or silent mode")
            },
        ]
        return SubsystemTestRunner(tests: tests, log: { [weak appState] message in
            appState?.addDebugEvent(message)
        })
    }

    /// One line per completed probe, for a bug report's self-test section.
    static func summary(of runner: SubsystemTestRunner) -> [String] {
        runner.tests.compactMap { test in
            guard let outcome = runner.outcomes[test.id] else { return nil }
            let verdict = outcome.passed ? "PASS" : "FAIL"
            return "\(verdict) — \(test.name): \(outcome.detail) (\(SubsystemTestRunner.format(outcome.seconds)))"
        }
    }
}
