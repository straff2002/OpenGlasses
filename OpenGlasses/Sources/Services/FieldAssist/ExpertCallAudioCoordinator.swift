import Foundation

/// Side-effecting controls a live expert call needs over the app's voice pipeline. Behind a protocol
/// so the coordinator's logic is unit-testable without touching the real audio session.
@MainActor
protocol ExpertCallAudioControlling {
    /// Hand the mic/speaker to the call: stop any TTS and pause wake-word listening.
    func pauseVoicePipeline()
    /// Return control to the normal voice loop.
    func resumeVoicePipeline()
}

/// Coordinates audio-session ownership for a live WebRTC expert call (Plan M3).
///
/// A call must own mic + speaker; the normal wake-word → LLM → TTS loop can't run at the same time
/// (echo, contention, a wedged session). This is a tiny idempotent state machine: `beginCall` pauses
/// the voice pipeline once, `endCall` resumes it once. The real side-effects live in the injected
/// `ExpertCallAudioControlling` adapter, so this logic is fully testable.
@MainActor
final class ExpertCallAudioCoordinator {
    static let shared = ExpertCallAudioCoordinator()

    /// Result of attempting to begin a call.
    enum StartResult: Equatable {
        case started            // pipeline handed to the call
        case alreadyActive      // a call was already running
        case blockedByRealtime  // a Gemini/OpenAI realtime session owns the mic — refused
    }

    private(set) var isCallActive = false
    /// Injected by AppState; nil in tests that supply their own.
    var control: ExpertCallAudioControlling?
    /// Whether a realtime (Gemini Live / OpenAI Realtime) session currently owns the mic.
    /// Injected by AppState (Plan M3 precedence); nil ⇒ no realtime contention assumed.
    var isRealtimeSessionActive: (() -> Bool)?

    init() {}

    /// True if starting a call right now would collide with a realtime session that owns the mic.
    var isBlockedByRealtime: Bool {
        !isCallActive && (isRealtimeSessionActive?() ?? false)
    }

    /// Begin a call: pause the voice pipeline. Idempotent. Refuses (without touching the pipeline)
    /// when a realtime session owns the mic — only one audio owner at a time (Plan M3).
    @discardableResult
    func beginCall() -> StartResult {
        guard !isCallActive else { return .alreadyActive }
        if isRealtimeSessionActive?() == true { return .blockedByRealtime }
        isCallActive = true
        control?.pauseVoicePipeline()
        return .started
    }

    /// End a call: resume the voice pipeline. Idempotent — ending when inactive is a no-op.
    func endCall() {
        guard isCallActive else { return }
        isCallActive = false
        control?.resumeVoicePipeline()
    }
}

/// Real adapter: pauses TTS + wake word for the call, resumes wake word afterward.
@MainActor
struct AppExpertCallAudioControl: ExpertCallAudioControlling {
    let wakeWord: WakeWordService
    let tts: TextToSpeechService

    func pauseVoicePipeline() {
        tts.stopSpeaking()
        wakeWord.stopListening()
    }

    func resumeVoicePipeline() {
        // The master listening switch outlives the call: an expert call ending is not the wearer
        // turning hands-free listening back on.
        guard Config.listeningEnabled else { return }
        Task { try? await wakeWord.startListening() }
    }
}
