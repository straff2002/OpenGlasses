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

/// Plan HY P2 — what Live Coach may send, and when: a change gate and a call budget, in that order.
///
/// Each tick's frame used to go to a cloud model whether or not the view had changed, up to 7,200
/// times in a session. Two rules bound that:
///
/// * **Unchanged is not re-sent.** The frame runs through ``FrameGate`` (Plan AT's content gate)
///   with a ``heartbeat`` of 30 s: a view that has not changed goes again only when the heartbeat
///   comes round, so a still scene costs one call every 30 s rather than one every tick.
/// * **Only a forwarded frame spends.** The ``CallBudget`` is charged for a frame the gate lets
///   through, never for one it drops. When the window is spent the coach says so, once
///   (``spentLine``), and checks in less often: ticks are skipped until the window frees a call.
///   It never stops on its own account — the session's own `maxDuration` is still the only end.
///
/// The budget is consulted *before* the gate so a refused tick never captures a frame and never
/// moves the gate's "last sent" mark — a frame the budget refused was not sent, and must not stand
/// in for one when the next distinct view arrives.
///
/// Pure value type with time passed in.
struct LiveCoachPacer {

    /// The heartbeat for an unchanged view.
    static let heartbeat: TimeInterval = 30

    /// Said once a session, when the budget is first spent.
    static let spentLine = "I've given a lot of advice this hour; I'll check in less often."

    enum BudgetCheck: Equatable {
        /// There is room: capture a frame and ask the gate.
        case open
        /// The window is spent. `announce` is true the first time in a session.
        case spent(announce: Bool)
    }

    enum FrameDecision: Equatable {
        /// Send it; one call has been charged.
        case send
        /// The view has not changed since the last send and the heartbeat has not come round.
        case unchanged
    }

    private(set) var gate = FrameGate(heartbeat: LiveCoachPacer.heartbeat)
    private(set) var budget: CallBudget
    private(set) var spentAnnounced = false

    init(budget: CallBudget = CallBudget()) {
        self.budget = budget
    }

    /// Step one, before any capture: is there a call to spend?
    mutating func checkBudget(now: Date) -> BudgetCheck {
        guard budget.remaining(now: now) == 0 else { return .open }
        defer { spentAnnounced = true }
        return .spent(announce: !spentAnnounced)
    }

    /// Step two, with the captured frame's perceptual hash: send it or not. A frame whose hash
    /// could not be computed is sent — an unreadable frame is no evidence of an unchanged view.
    mutating func consider(hash: UInt64?, now: Date) -> FrameDecision {
        if let hash, gate.evaluate(hash: hash, now: now.timeIntervalSinceReferenceDate) == .drop {
            return .unchanged
        }
        _ = budget.admit(now: now)
        return .send
    }

    /// When the coach will next be able to make a call.
    func nextCallAt(now: Date) -> Date { budget.nextAvailable(now: now) }
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

    /// The still source, typed as the privacy chokepoint (W04.1) — the coach only ever wanted a
    /// still, and this way the filtered path is the only one available to it.
    weak var camera: (any FilteredStillProviding)?
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
    /// Plan HY P2 — the change gate and the call budget. Fresh per session.
    private(set) var pacer = LiveCoachPacer()

    private init() {}

    /// Wire the app's services once at launch.
    func configure(camera: any FilteredStillProviding, llm: LLMService, tts: TextToSpeechService) {
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
        pacer = LiveCoachPacer()
        throttle.reset()   // first tick of a new session runs immediately
        isActive = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        PrivacyLog.vision(.liveCoach, .started, seconds: interval,
                          detail: PrivacyToken(domain.rawValue))
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        startedAt = nil
        PrivacyLog.vision(.liveCoach, .stopped)
    }

    func statusSummary() -> String {
        guard isActive else { return "Live Coach is not running." }
        let elapsed = startedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        let pacing = pacer.budget.remaining(now: Date()) == 0
            ? " Checking in less often: the hour's advice budget is spent." : ""
        return "Live Coach is running (\(domain.rawValue), ~\(elapsed) min). Last: \(lastAdvice ?? "—")\(pacing)"
    }

    // MARK: - Loop

    private func tick() async {
        guard isActive, !analyzing, let camera, let llm, let tts else { return }

        // Safety cap on session duration.
        if let startedAt, Date().timeIntervalSince(startedAt) >= maxDuration {
            stop()
            await tts.speak("Coaching session complete.", source: .coaching, urgency: .low)
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

        // Plan HY P2: within the hour's budget, and only for a view that changed (or whose
        // heartbeat came round). A spent budget is said once, then the coach simply waits for the
        // window to free a call — it checks in less often, it does not go quiet without a word.
        let now = Date()
        if case .spent(let announce) = pacer.checkBudget(now: now) {
            if announce {
                PrivacyLog.vision(.liveCoach, .budgetSpent, count: pacer.budget.limit)
                await tts.speak(LiveCoachPacer.spentLine, source: .coaching, urgency: .low)
            }
            return
        }
        guard let frame = await currentCoachingFrame(camera) else { return }
        guard isActive else { return }
        guard pacer.consider(hash: frame.hash, now: Date()) == .send else { return }
        let imageData = frame.jpeg
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
        await tts.speak(advice, source: .coaching, urgency: .medium)
    }

    /// A coaching frame goes to a cloud model every few seconds for as long as the session runs,
    /// which makes this the highest-volume still egress in the app. Unavailable means this tick is
    /// skipped; the next one tries again.
    /// Internal, not private, so the privacy routing can be driven headless — the tick above
    /// needs a live LLM and TTS, this needs neither.
    func currentFrame(_ camera: any FilteredStillProviding) async -> Data? {
        await currentCoachingFrame(camera)?.jpeg
    }

    /// The tick's frame: the filtered still's JPEG, and its perceptual hash for the change gate
    /// (Plan HY P2). The one still read this service makes — hashing the filtered pixels, never
    /// raw ones, so the gate sees exactly what would be sent.
    func currentCoachingFrame(_ camera: any FilteredStillProviding) async -> (jpeg: Data, hash: UInt64?)? {
        let still = await camera.filteredStill(for: .assistiveGuidance)
        guard let jpeg = still.jpegData(compressionQuality: 0.7) else { return nil }
        return (jpeg, still.image.flatMap(PerceptualHash.dhash))
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
