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
    /// Why Social mode is not offered on this phone, or nil when it is (Plan HP P1 item 3). Updated
    /// at start and on every analysis. Since Plan HS P1 item 2 the only reasons are the wearer's
    /// switch and the Accessibility tier, which the switches themselves show.
    @Published private(set) var socialRefusal: AssistiveModePolicy.Refusal?

    /// The Social mode decision, read fresh each analysis. Injectable so a test can drive the
    /// routing without an organisation profile or an edition.
    var socialPolicy: () -> AssistiveModePolicy.Decision = { AssistiveModePolicy.current() }

    /// Social mode answers that named a feeling and were re-asked, since launch (Plan HR P1 item 3).
    /// Counts only; the words are never kept.
    private(set) var socialInferenceRetries = 0
    /// Social mode answers withheld because the re-ask named a feeling too, since launch.
    private(set) var socialInferenceWithheld = 0

    /// Seconds between ambient analyses. Conservative to limit battery + API cost.
    var interval: TimeInterval = 6

    /// The still source, typed as the privacy chokepoint (W04.1).
    weak var camera: (any FilteredStillProviding)?
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

    func start(camera: any FilteredStillProviding, llm: LLMService, tts: TextToSpeechService) {
        guard !isActive else { return }
        self.camera = camera
        self.llm = llm
        self.tts = tts
        isActive = true
        socialRefusal = socialPolicy().refusal
        throttle.reset()   // first analysis runs immediately
        PrivacyLog.vision(.assistiveMode, .started, seconds: interval)
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
        PrivacyLog.vision(.assistiveMode, .stopped)
    }

    func toggle(camera: any FilteredStillProviding, llm: LLMService, tts: TextToSpeechService) {
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

        let mode = routeNextAnalysis(transcription: pendingTranscription)
        // CJ item 4: the ambient loop points a camera at the world continuously — the
        // category-only privacy guarantee rides on every frame prompt (default on).
        var systemPrompt = AssistiveRouter.systemPrompt(for: mode)
        if Config.visionPrivacyCategoriesEnabled {
            systemPrompt += "\n\n" + AssessmentPrivacy.promptFragment
        }
        let userText = AssistiveRouter.userText(for: mode, transcription: pendingTranscription)
        pendingTranscription = nil // consume

        let advice = await resolveAdvice(mode: mode, systemPrompt: systemPrompt, userText: userText) { prompt, text in
            await llm.analyzeFrame(systemPrompt: prompt, userText: text, imageData: imageData, maxTokens: 200)
        }
        guard let advice else { return }
        guard isActive else { return } // may have been stopped during the await

        latestAdvice = advice
        var spoken = advice.advice
        if let followup = advice.followup, !followup.isEmpty { spoken += " " + followup }
        await tts.speak(spoken, urgency: advice.urgency.speechUrgency)
    }

    /// Ask the model about one frame and decide what, if anything, is spoken (Plan HR P1 item 3).
    ///
    /// `ask` sends a system prompt and user text with the frame and returns the raw reply; it is a
    /// parameter so a test drives this with a fake model and no camera. Scene mode is untouched:
    /// whatever parses is spoken, as before. Social mode fails closed against `EmotionLabelFilter`:
    /// an answer that names a feeling, a mood or an intention is never spoken. It is re-asked once,
    /// on the same frame, with `SocialObservationContract.retryInstruction` appended; if the second
    /// answer names one too, the wearer hears `SocialObservationContract.fallbackLine` instead and a
    /// content-free counter is logged. A reply that does not parse is, as always, not spoken.
    func resolveAdvice(mode: AssistiveRouter.Mode, systemPrompt: String, userText: String,
                       ask: @MainActor (_ systemPrompt: String, _ userText: String) async -> String?) async -> AssistiveAdvice? {
        guard let first = await ask(systemPrompt, userText).flatMap(AssistiveAdvice.parse) else { return nil }
        guard mode == .social else { return first }
        if EmotionLabelFilter.check(first).isObservation { return first }

        socialInferenceRetries += 1
        PrivacyLog.vision(.assistiveMode, .inferenceRetried, count: socialInferenceRetries)
        let stricter = systemPrompt + "\n\n" + SocialObservationContract.retryInstruction
        guard let second = await ask(stricter, userText).flatMap(AssistiveAdvice.parse) else { return nil }
        if EmotionLabelFilter.check(second).isObservation { return second }

        socialInferenceWithheld += 1
        PrivacyLog.vision(.assistiveMode, .inferenceWithheld, count: socialInferenceWithheld)
        return AssistiveAdvice(advice: SocialObservationContract.fallbackLine, urgency: .low, followup: nil)
    }

    /// Pick the mode for the next analysis under the current Social mode policy, and publish both
    /// the mode and the refusal. Social mode routes to Scene whenever the policy refuses it, so a
    /// wearer who switched Social mode off never sends a prompt about a person. Internal so
    /// the routing is testable without a camera, a model or a voice.
    @discardableResult
    func routeNextAnalysis(transcription: String?) -> AssistiveRouter.Mode {
        let decision = socialPolicy()
        socialRefusal = decision.refusal
        let mode = AssistiveRouter.route(transcription: transcription, social: decision)
        currentMode = mode
        return mode
    }

    /// The ambient loop points a camera at the world continuously and sends what it sees to a
    /// cloud model, so every frame it takes is filtered under `.assistiveGuidance`. A tick with no
    /// filtered still available simply does not run.
    /// Internal, not private, for the same reason as `LiveCoachService.currentFrame` — the loop
    /// needs a model and a voice, the frame acquisition does not.
    func currentFrameData(_ camera: any FilteredStillProviding) async -> Data? {
        await camera.filteredStill(for: .assistiveGuidance, source: .cachedFrameThenPhoto)
            .jpegData(compressionQuality: 0.7)
    }
}
