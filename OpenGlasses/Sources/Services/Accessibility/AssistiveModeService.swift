import Foundation
import UIKit

/// Orchestrates Assistive Modes (A3): a periodic ambient loop that captures a glasses frame, routes
/// it to Scene or Social analysis, asks the LLM for concise JSON advice, and speaks it with an
/// urgency-graded voice (A2). Runs only while explicitly active; gated behind the Accessibility tier.
///
/// Dependencies are injected (weakly) on `start` so the service doesn't retain AppState's services.
@MainActor
final class AssistiveModeService: ObservableObject {
    static let shared = AssistiveModeService()

    @Published private(set) var isActive = false
    @Published private(set) var currentMode: AssistiveRouter.Mode = .scene
    @Published private(set) var latestAdvice: AssistiveAdvice?

    /// Seconds between ambient analyses. Conservative to limit battery + API cost.
    var interval: TimeInterval = 6

    private weak var camera: CameraService?
    private weak var llm: LLMService?
    private weak var tts: TextToSpeechService?

    private var timer: Timer?
    private var analyzing = false
    /// Latest user transcription, used once to bias routing (scene vs social), then consumed.
    private var pendingTranscription: String?

    /// Presence-aware throttle (Plan W). Injected by AppState; nil ⇒ full cadence. As an
    /// accessibility loop a user is relying on, it floors at `.present` — trimmed to 2× when idle,
    /// but never paused or quartered by mere disengagement.
    weak var presence: PresenceMonitor?
    private var throttle = LoopThrottle()

    private init() {}

    // MARK: - Lifecycle

    func start(camera: CameraService, llm: LLMService, tts: TextToSpeechService) {
        guard !isActive else { return }
        self.camera = camera
        self.llm = llm
        self.tts = tts
        isActive = true
        throttle.reset()   // first analysis runs immediately
        NSLog("[AssistiveMode] Started (interval %.0fs)", interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() } // run one immediately
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        pendingTranscription = nil
        NSLog("[AssistiveMode] Stopped")
    }

    func toggle(camera: CameraService, llm: LLMService, tts: TextToSpeechService) {
        isActive ? stop() : start(camera: camera, llm: llm, tts: tts)
    }

    /// Provide a recent transcription to bias the next analysis toward Scene or Social.
    func noteTranscription(_ text: String) {
        pendingTranscription = text
    }

    // MARK: - Loop

    private func tick() async {
        guard isActive, !analyzing, let camera, let llm, let tts else { return }
        // Don't talk over ongoing speech.
        if tts.isSpeaking { return }

        // Presence throttle (Plan W), floored at `.present`: trim the analysis cadence while idle
        // (2× base) but never pause or quarter an accessibility loop the user depends on.
        if let presence, !throttle.shouldRun(now: Date(), base: interval, decision: presence.decision(minMode: .present)) {
            return
        }

        analyzing = true
        defer { analyzing = false }

        guard let imageData = await currentFrameData(camera) else { return }

        let mode = AssistiveRouter.route(transcription: pendingTranscription)
        currentMode = mode
        let systemPrompt = AssistiveRouter.systemPrompt(for: mode)
        let userText = AssistiveRouter.userText(for: mode, transcription: pendingTranscription)
        pendingTranscription = nil // consume

        guard let raw = await llm.analyzeFrame(systemPrompt: systemPrompt, userText: userText, imageData: imageData, maxTokens: 200),
              let advice = AssistiveAdvice.parse(raw) else {
            return
        }
        guard isActive else { return } // may have been stopped during the await

        latestAdvice = advice
        var spoken = advice.advice
        if let followup = advice.followup, !followup.isEmpty { spoken += " " + followup }
        await tts.speak(spoken, urgency: advice.urgency.speechUrgency)
    }

    private func currentFrameData(_ camera: CameraService) async -> Data? {
        if let frame = camera.latestFrame, let data = frame.jpegData(compressionQuality: 0.7) {
            return data
        }
        return try? await camera.capturePhoto()
    }
}
