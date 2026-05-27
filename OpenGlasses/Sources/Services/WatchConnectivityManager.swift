import Foundation
import WatchConnectivity

/// iPhone-side WatchConnectivity manager. Receives commands from the Watch app
/// and dispatches them to AppState for execution.
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    weak var appState: AppState?

    private var session: WCSession?

    override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            NSLog("[WatchConn] WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        NSLog("[WatchConn] Session activated")
    }

    /// Send current app status to the Watch for display.
    func sendStatusUpdate() {
        guard let session, session.isReachable else { return }
        guard let appState else { return }

        // Recent conversation threads (last 5, title + summary only)
        let recentThreads: [[String: String]] = appState.conversationStore.threads.prefix(5).map { thread in
            [
                "id": thread.id,
                "title": thread.title,
                "summary": thread.summary ?? "",
                "updatedAt": ISO8601DateFormatter().string(from: thread.updatedAt)
            ]
        }

        // Top 4 quick actions
        let quickActions: [[String: String]] = Config.quickActions.prefix(4).map { action in
            [
                "id": action.id,
                "label": action.label,
                "icon": action.icon,
                "type": action.type.rawValue
            ]
        }

        let context: [String: Any] = [
            "status": statusString(),
            "isConnected": appState.isConnected,
            "isProcessing": appState.isProcessing,
            "isListening": appState.isListening,
            "isRecording": appState.transcriptionService.isRecording,
            "lastResponse": String(appState.lastResponse.prefix(200)),
            "deviceName": appState.glassesService.deviceName ?? "",
            "batteryLevel": appState.glassesService.batteryLevel ?? 0,
            "personas": Config.enabledPersonas.prefix(3).map { ["id": $0.id, "name": $0.name] },
            "accentColor": Config.accentColorName,
            "recentThreads": recentThreads,
            "quickActions": quickActions
        ]

        // Use application context for persistent state
        try? session.updateApplicationContext(context)
    }

    private func statusString() -> String {
        guard let appState else { return "idle" }
        if appState.isListening { return "listening" }
        if appState.isProcessing { return "processing" }
        if appState.speechService.isSpeaking { return "speaking" }
        return "idle"
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        NSLog("[WatchConn] Activation: %@ (error: %@)",
              String(describing: activationState),
              error?.localizedDescription ?? "none")
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        NSLog("[WatchConn] Session became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        NSLog("[WatchConn] Session deactivated")
        session.activate()
    }

    /// Handle transferUserInfo payloads from Watch complications (no reply handler).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = userInfo["command"] as? String else { return }
        NSLog("[WatchConn] Received userInfo command: %@", command)

        // Synthesize a fake message and dispatch through the same Task path.
        // Complications use transferUserInfo so there is no reply handler — use a no-op.
        Task { @MainActor in
            guard let appState = self.appState else { return }

            switch command {
            case "toggleListen":
                if appState.isListening {
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.stopRecording()
                    appState.isListening = false
                } else {
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                }

            case "toggleRecord":
                if appState.transcriptionService.isRecording {
                    appState.transcriptionService.stopRecording()
                } else {
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.startRecording()
                }

            case "capturePhoto":
                // Silent capture — no LLM, no TTS, transcription keeps running.
                // Photo is saved to Documents/Photos/ and a timestamped note is
                // injected into the caption stream.
                await appState.capturePhotoSilently()

            default:
                NSLog("[WatchConn] Unknown userInfo command: %@", command)
            }

            self.sendStatusUpdate()
        }
    }

    /// Handle real-time messages from the Watch with reply handler.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = message["command"] as? String else {
            replyHandler(["error": "No command specified"])
            return
        }

        NSLog("[WatchConn] Received command: %@", command)

        Task { @MainActor in
            guard let appState = self.appState else {
                replyHandler(["error": "App not ready"])
                return
            }

            switch command {
            case "ask":
                // Trigger wake word flow — start listening
                appState.wakeWordService.stopListening()
                try? await Task.sleep(nanoseconds: 100_000_000)
                await appState.handleWakeWordDetected()
                replyHandler(["status": "listening"])

            case "persona":
                // Activate a specific persona agent and start listening
                if let personaId = message["persona_id"] as? String,
                   let persona = Config.enabledPersonas.first(where: { $0.id == personaId }) {
                    appState.activePersona = persona
                    Config.setActiveModelId(persona.modelId)
                    Config.setActivePresetId(persona.presetId)
                    appState.llmService.refreshActiveModel()
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                    replyHandler(["status": "listening", "persona": persona.name])
                } else {
                    replyHandler(["error": "Persona not found"])
                }

            case "photo":
                await appState.captureAndAnalyzePhoto()
                replyHandler([
                    "status": "completed",
                    "response": appState.lastResponse
                ])

            case "describe":
                await appState.capturePhotoAndSend(prompt: "Describe what you see in detail.")
                replyHandler([
                    "status": "completed",
                    "response": appState.lastResponse
                ])

            case "connect":
                await appState.connectAndListen()
                replyHandler([
                    "status": "connecting",
                    "isConnected": appState.isConnected
                ])

            case "toggleListen":
                if appState.isListening {
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.stopRecording()
                    appState.isListening = false
                    replyHandler(["status": "stopped", "isListening": false])
                } else {
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                    replyHandler(["status": "listening", "isListening": true])
                }

            case "toggleRecord":
                let isRecording = appState.transcriptionService.isRecording
                if isRecording {
                    // Stop transcription-only recording
                    appState.transcriptionService.stopRecording()
                    NSLog("[WatchConn] Transcription recording stopped via Watch")
                    replyHandler([
                        "status": "stopped",
                        "isRecording": false
                    ])
                } else {
                    // Start transcription-only recording (no LLM, no wake word)
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.startRecording()
                    NSLog("[WatchConn] Transcription recording started via Watch")
                    replyHandler([
                        "status": "recording",
                        "isRecording": true
                    ])
                }

            case "quickAction":
                if let actionId = message["action_id"] as? String,
                   let action = Config.quickActions.first(where: { $0.id == actionId }) {
                    switch action.type {
                    case .photo, .photoThenPrompt:
                        await appState.captureAndAnalyzePhoto()
                    case .prompt:
                        await appState.capturePhotoAndSend(prompt: action.label)
                    default:
                        await appState.capturePhotoAndSend(prompt: action.label)
                    }
                    replyHandler([
                        "status": "completed",
                        "response": appState.lastResponse
                    ])
                } else {
                    replyHandler(["error": "Quick action not found"])
                }

            case "resumeThread":
                if let threadId = message["thread_id"] as? String {
                    appState.conversationStore.activeThreadId = threadId
                    // Start listening for follow-up in the resumed thread
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                    replyHandler(["status": "resumed", "thread_id": threadId])
                } else {
                    replyHandler(["error": "No thread ID"])
                }

            case "disconnect", "sleep":
                appState.disconnectGlasses()
                replyHandler(["status": "disconnected"])

            case "status":
                replyHandler([
                    "status": self.statusString(),
                    "isConnected": appState.isConnected,
                    "lastResponse": String(appState.lastResponse.prefix(200))
                ])

            default:
                // Treat as a custom prompt
                if let prompt = message["prompt"] as? String {
                    await appState.capturePhotoAndSend(prompt: prompt)
                    replyHandler([
                        "status": "completed",
                        "response": appState.lastResponse
                    ])
                } else {
                    replyHandler(["error": "Unknown command: \(command)"])
                }
            }

            self.sendStatusUpdate()
        }
    }
}
