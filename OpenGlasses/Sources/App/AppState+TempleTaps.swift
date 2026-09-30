import Foundation

/// The app side of the temple taps (Plan GJ P1): what the app is doing, as a `TempleContext`, and
/// the calls that carry out each `TempleEffect`. Every decision lives in `TempleActionResolver`;
/// this file only reads state and calls entry points that already exist.
extension AppState: TempleActionPerforming {

    func templeContext() -> TempleContext {
        TempleContext(
            activity: templeActivity,
            agentModeEnabled: Config.agentModeEnabled,
            agentAvailable: Config.isOpenClawAgentActive,
            micMuted: micMuted,
            liveMicMuted: activeLiveMicMuted,
            recording: videoRecorder.isRecording,
            glassesCameraReady: cameraService.activeCapabilities?.stillCapture == true,
            digestEnabled: Config.digestEnabled,
            quickActionIDs: Set(Config.quickActions.map(\.id)))
    }

    private var templeActivity: TempleContext.Activity {
        if geminiLiveSession.isActive || openAIRealtimeSession.isActive { return .liveSession }
        if AssistiveModeService.shared.isActive { return .busy }
        if isProcessing { return .thinking }
        if speechService.isSpeaking { return .speaking }
        if inConversation { return .listening }
        return .standby
    }

    private var activeLiveMicMuted: Bool {
        if geminiLiveSession.isActive { return geminiLiveSession.micMuted }
        if openAIRealtimeSession.isActive { return openAIRealtimeSession.micMuted }
        return false
    }

    func performTempleEffect(_ effect: TempleEffect) async {
        switch effect {
        case .startListening:
            // The tap starts whatever "talk" means in the chosen mode — the same choice the
            // Action Button makes.
            if currentMode == .direct {
                await handleWakeWordDetected(manual: true)
            } else {
                await requestLiveSession(currentMode, source: .templeTap)
            }
        case .interruptAndListen:
            await interruptSpeechAndListen()
        case .endConversation:
            await hangUpConversation()
        case .endLiveSession:
            stopLiveSession(geminiLiveSession.isActive ? .geminiLive : .openaiRealtime,
                            source: .templeTap)
        case .setMicMuted(let muted):
            micMuted = muted
        case .muteAndEndConversation:
            // Muted first, so the end of the conversation does not re-arm the wake word only for
            // the mute to take it straight down again.
            micMuted = true
            await hangUpConversation()
        case .setLiveMicMuted(let muted):
            if geminiLiveSession.isActive { geminiLiveSession.micMuted = muted }
            if openAIRealtimeSession.isActive { openAIRealtimeSession.micMuted = muted }
        case .photoDescribe:
            await captureAndAnalyzePhoto(glassesOnly: true)
        case .photoToCameraRoll:
            await capturePhotoFromGlasses(glassesOnly: true)
        case .readDigest:
            await notificationDigest.presentGlance(explicit: true)
        case .toggleRecording:
            await toggleRecording()
        case .askAgent:
            pendingAgentTurn = true
            await handleWakeWordDetected(manual: true)
        case .quickAction(let id):
            guard let action = Config.quickActions.first(where: { $0.id == id }) else { return }
            await executeQuickAction(action)
        }
    }

    func playTempleEarcon(_ earcon: TempleEarcon) {
        var offset: TimeInterval = 0
        for tone in earcon.tones {
            let delay = offset
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.speechService.playTone(frequency: tone.frequency, duration: tone.duration)
            }
            offset += tone.duration + 0.03
        }
    }

    func announceTempleLine(_ line: String) async {
        await speechService.speak(line)
    }
}
