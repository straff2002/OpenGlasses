import AVFoundation
import Foundation
import Speech

/// Plan FF P1/PR3 — `AppState` as the live-session activation owner, and the launch decision built
/// from the app's real settings, permissions and registration state.
///
/// The split is deliberate: everything that has to *decide* lives in `BlindAssistantLaunchPolicy`
/// and everything that has to *sequence* lives in `LiveSessionActivator`, both of them pure enough
/// to test headlessly. What is left here is only the reading of the world, which is the one part a
/// simulator cannot exercise anyway (`Wearables` traps in a headless process).
extension AppState: LiveSessionActivationOwner {

    var realtimeSupportsVision: Bool {
        guard currentMode.isRealtime else { return true }
        let model = currentMode == .geminiLive
            ? (geminiLiveSession.isActive ? geminiLiveSession.sessionModel : Config.realtimeModel(for: currentMode))
            : (openAIRealtimeSession.isActive ? openAIRealtimeSession.sessionModel : Config.realtimeModel(for: currentMode))
        return model?.capabilities?.vision ?? false
    }

    func selectRealtimeModel(_ id: String) {
        Task { @MainActor in
            let wasActive = isSessionActive(currentMode)
            guard id != Config.activeRealtimeModelID || currentMode != .openaiCompatibleRealtime else { return }
            Config.setActiveRealtimeModelID(id)
            if currentMode != .openaiCompatibleRealtime {
                await performModeSwitch(to: .openaiCompatibleRealtime)
            } else if wasActive {
                stopLiveSession(.openaiCompatibleRealtime, source: .appUI)
                if Config.modeSwitchAutoRedialEnabled {
                    _ = await requestLiveSession(.openaiCompatibleRealtime, source: .appUI)
                }
            }
        }
    }

    var activeMode: AppMode { currentMode }

    func isSessionActive(_ mode: AppMode) -> Bool {
        switch mode {
        case .geminiLive: return geminiLiveSession.isActive
        case .openaiRealtime, .openaiCompatibleRealtime:
            return openAIRealtimeSession.isActive && openAIRealtimeSession.sessionMode == mode
        case .direct: return false
        }
    }

    func startSession(_ mode: AppMode) async {
        switch mode {
        case .geminiLive: await geminiLiveSession.startSession()
        case .openaiRealtime, .openaiCompatibleRealtime: await openAIRealtimeSession.startSession()
        case .direct: break
        }
    }

    func stopSession(_ mode: AppMode) {
        // Plan LU §8: a Live session started private takes its private conversation with it when it
        // stops; an ordinary one leaves a phone-side private conversation open. No Live session is
        // started private yet (P1b), so this ends nothing today.
        notePrivateEvent(.liveStopped(sessionWasPrivate: false))
        switch mode {
        case .geminiLive: if geminiLiveSession.isActive { geminiLiveSession.stopSession() }
        case .openaiRealtime, .openaiCompatibleRealtime:
            if openAIRealtimeSession.isActive, openAIRealtimeSession.sessionMode == mode {
                openAIRealtimeSession.stopSession()
            }
        case .direct: break
        }
    }

    /// Which realtime backend a Blind Assistant start would use: the selected one when a realtime
    /// mode is already selected, and Gemini Live otherwise — it is the backend the preset's live
    /// session was built around, and Direct mode has no session to start.
    var blindAssistantTargetMode: AppMode {
        currentMode.isRealtime ? currentMode : .geminiLive
    }

    // MARK: - The launch decision

    /// Read the world the launch policy decides from.
    ///
    /// `awaitRegistration` is true only on a cold launch. Glasses registration can take seconds to
    /// settle after the app starts, and starting a session in the middle of it destabilises the
    /// Bluetooth route (the same reason the wake-word auto-start waits). On a foreground event
    /// there is nothing to wait for — whatever state registration is in now is the answer.
    func blindAssistantLaunchInputs(awaitRegistration: Bool) async
        -> BlindAssistantLaunchPolicy.Inputs {
        let mode = blindAssistantTargetMode
        let provider: BlindAssistantLaunchPolicy.Provider = mode == .openaiCompatibleRealtime
            ? .openAICompatibleRealtime : (mode.usesOpenAIRealtimeTransport ? .openAIRealtime : .gemini)
        let providerConfigured = mode.usesOpenAIRealtimeTransport
            ? (Config.realtimeModel(for: mode)?.isConfigured ?? false)
            : Config.isGeminiLiveConfigured

        var glassesReady = registrationStateRaw >= 3
        if awaitRegistration, !glassesReady {
            let settled = await waitForRegistration(minState: 3, timeoutSeconds: 20)
            registrationStateRaw = settled
            glassesReady = settled >= 3
        }

        return BlindAssistantLaunchPolicy.Inputs(
            settingEnabled: Config.startBlindAssistantOnLaunch,
            isPastOnboarding: Config.isPastOnboarding,
            selectedPresetID: Config.activeLiveAIModeId,
            provider: provider,
            providerConfigured: providerConfigured,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechRecognitionGranted: SFSpeechRecognizer.authorizationStatus() == .authorized,
            cameraGranted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            glassesReady: glassesReady,
            silentMode: Config.silentMode,
            sessionAlreadyActive: isSessionActive(mode),
            stoppedByUserThisForeground: liveActivator.stoppedByUserThisForeground)
    }

    /// Start the Blind Assistant if the wearer asked for it and everything it needs is there.
    /// Announces the reason when it does not.
    @discardableResult
    func activateBlindAssistant(source: LiveActivationSource) async -> LiveSessionActivator.Outcome {
        let mode = blindAssistantTargetMode
        let awaitRegistration = (source == .launch)
        return await liveActivator.activate(.init(mode: mode, source: source) { [weak self] in
            guard let self else { return .skip(.settingOff) }
            let inputs = await self.blindAssistantLaunchInputs(awaitRegistration: awaitRegistration)
            return BlindAssistantLaunchPolicy.decide(inputs)
        })
    }

    /// Returning to the foreground. Deliberately runs the same gate as launch — including the stop
    /// latch, which is what stops a scene activation, a glasses reconnect or an audio-route change
    /// putting back a session the wearer took down.
    func activateBlindAssistantOnForeground() {
        guard Config.startBlindAssistantOnLaunch, launchActivationDecided else { return }
        Task { [weak self] in
            await self?.activateBlindAssistant(source: .foreground)
        }
    }

    // MARK: - Explicit entry points

    /// An explicit request for a live session: the Action Button, Siri, the app's own control.
    /// No gate — the wearer asked, and the session manager reports its own failures.
    @discardableResult
    func requestLiveSession(_ mode: AppMode,
                            source: LiveActivationSource,
                            restartIfActive: Bool = false) async -> LiveSessionActivator.Outcome {
        await liveActivator.activate(.init(mode: mode, source: source,
                                           restartIfActive: restartIfActive))
    }

    /// The wearer stopped the session. Cancels any startup still in flight and latches the stop so
    /// nothing ambient restarts it.
    func stopLiveSession(_ mode: AppMode, source: LiveActivationSource) {
        liveActivator.stop(mode, source: source)
    }

    /// What Settings shows for "what happens when I open the app", without the registration wait.
    func blindAssistantLaunchPreview() async -> BlindAssistantLaunchPolicy.Decision {
        BlindAssistantLaunchPolicy.decide(
            await blindAssistantLaunchInputs(awaitRegistration: false))
    }
}
