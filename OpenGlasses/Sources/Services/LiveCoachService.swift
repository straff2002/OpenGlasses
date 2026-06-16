import Foundation
import UIKit

/// Coaching domains for the Live Coach (Plan C). Each supplies a focused, one-sentence system prompt.
/// Adapted from sidelineiq's tight-token live feedback pattern.
enum LiveCoachDomain: String, CaseIterable {
    case sportsTactics = "sports_tactics"
    case cookingForm = "cooking_form"
    case posture
    case guitar
    case climbing
    case custom

    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "sports_tactics", "sports", "tactics": self = .sportsTactics
        case "cooking_form", "cooking": self = .cookingForm
        case "posture": self = .posture
        case "guitar": self = .guitar
        case "climbing": self = .climbing
        case "custom": self = .custom
        default: return nil
        }
    }

    private var focus: String {
        switch self {
        case .sportsTactics: return "Identify the single most important tactical problem and the fix, in plain language."
        case .cookingForm: return "Watch knife grip, cutting technique, heat/stove safety, and ingredient ordering."
        case .posture: return "Watch spine alignment, shoulder position, screen distance, and ergonomic issues."
        case .guitar: return "Watch finger placement, chord shape, wrist angle, and picking technique."
        case .climbing: return "Watch route reading, weight distribution, balance, and suggest the next hold."
        case .custom: return ""
        }
    }

    func systemPrompt(maxWords: Int, customPrompt: String?) -> String {
        let directive = (self == .custom ? (customPrompt ?? "Give one concise piece of coaching feedback.") : focus)
        return """
        You are a real-time coach. \(directive) Respond with exactly one sentence of at most \
        \(maxWords) words: name the issue and the fix in the same breath. If everything looks good, \
        say so briefly. No markdown, no preamble.
        """
    }

    var userText: String {
        switch self {
        case .sportsTactics: return "What's the key tactical adjustment right now?"
        case .cookingForm: return "How's my technique?"
        case .posture: return "How's my posture?"
        case .guitar: return "How's my hand position?"
        case .climbing: return "What's my best next move?"
        case .custom: return "Give me your coaching feedback on what you see."
        }
    }
}

/// Drives the Live Coach (Plan C): a periodic frame loop that sends the glasses view to the LLM with
/// a per-domain prompt and speaks concise, deduplicated feedback. Deps are configured once by
/// AppState; the `live_coach` tool only starts/stops sessions.
@MainActor
final class LiveCoachService: ObservableObject {
    static let shared = LiveCoachService()

    @Published private(set) var isActive = false
    @Published private(set) var domain: LiveCoachDomain = .posture
    @Published private(set) var lastAdvice: String?

    private weak var camera: CameraService?
    private weak var llm: LLMService?
    private weak var tts: TextToSpeechService?

    private var timer: Timer?
    private var analyzing = false
    private var startedAt: Date?
    private var interval: TimeInterval = 2

    /// Presence-aware throttle (Plan W). Injected by AppState; when nil the loop runs at full
    /// cadence (unchanged pre-Plan-W behaviour).
    weak var presence: PresenceMonitor?
    private var throttle = LoopThrottle()
    private var maxWords = 20
    private var maxDuration: TimeInterval = 1800
    private var customPrompt: String?

    private init() {}

    /// Wire the app's services once at launch.
    func configure(camera: CameraService, llm: LLMService, tts: TextToSpeechService) {
        self.camera = camera
        self.llm = llm
        self.tts = tts
    }

    var isConfigured: Bool { camera != nil && llm != nil && tts != nil }

    // MARK: - Lifecycle

    @discardableResult
    func start(domain: LiveCoachDomain, customPrompt: String?, intervalSeconds: Double, maxWords: Int, maxDurationMinutes: Double) -> Bool {
        guard isConfigured else { return false }
        stop() // restart cleanly if already running
        self.domain = domain
        self.customPrompt = customPrompt
        self.interval = min(max(intervalSeconds, 1), 10)
        self.maxWords = min(max(maxWords, 5), 60)
        self.maxDuration = min(max(maxDurationMinutes, 1), 120) * 60
        self.lastAdvice = nil
        self.startedAt = Date()
        throttle.reset()   // first tick of a new session runs immediately
        isActive = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NSLog("[LiveCoach] Started domain=%@ interval=%.0fs", domain.rawValue, interval)
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        startedAt = nil
        NSLog("[LiveCoach] Stopped")
    }

    func statusSummary() -> String {
        guard isActive else { return "Live Coach is not running." }
        let elapsed = startedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        return "Live Coach is running (\(domain.rawValue), ~\(elapsed) min). Last: \(lastAdvice ?? "—")"
    }

    // MARK: - Loop

    private func tick() async {
        guard isActive, !analyzing, let camera, let llm, let tts else { return }

        // Safety cap on session duration.
        if let startedAt, Date().timeIntervalSince(startedAt) >= maxDuration {
            stop()
            await tts.speak("Coaching session complete.", urgency: .low)
            return
        }
        if tts.isSpeaking { return }

        // Presence throttle (Plan W): the timer keeps waking at the session's base interval, but the
        // expensive frame-capture + LLM call only runs once `interval × the presence multiplier` has
        // elapsed — every tick when the user is active, a quarter as often when idle, never when away
        // (disconnected/backgrounded). No `minMode` floor: a quietly-watched session slowing to 4×
        // is fine, and an away/disconnected session can't capture frames anyway.
        if let presence, !throttle.shouldRun(now: Date(), base: interval, decision: presence.decision) {
            return
        }

        analyzing = true
        defer { analyzing = false }

        guard let imageData = currentFrame(camera) else { return }
        let systemPrompt = domain.systemPrompt(maxWords: maxWords, customPrompt: customPrompt)
        guard let raw = await llm.analyzeFrame(systemPrompt: systemPrompt, userText: domain.userText, imageData: imageData, maxTokens: 80) else {
            return
        }
        guard isActive else { return }

        let advice = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !advice.isEmpty else { return }
        // Dedup: don't repeat near-identical feedback.
        if let last = lastAdvice, Self.isSimilar(advice, last) { return }

        lastAdvice = advice
        await tts.speak(advice, urgency: .medium)
    }

    private func currentFrame(_ camera: CameraService) -> Data? {
        camera.latestFrame?.jpegData(compressionQuality: 0.7)
    }

    // MARK: - Dedup

    /// Token-overlap (Jaccard) similarity; true when two advice strings are near-duplicates.
    static func isSimilar(_ a: String, _ b: String, threshold: Double = 0.6) -> Bool {
        let setA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let setB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !setA.isEmpty, !setB.isEmpty else { return a == b }
        let intersection = Double(setA.intersection(setB).count)
        let union = Double(setA.union(setB).count)
        return (intersection / union) >= threshold
    }
}
