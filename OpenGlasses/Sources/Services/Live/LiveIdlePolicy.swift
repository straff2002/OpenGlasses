import Foundation

/// Plan HY P1 — ending a live session nobody is using.
///
/// There was no inactivity timer anywhere on the live path. A session started and forgotten kept
/// the microphone open, the camera at its live interval and a billed socket up for as long as the
/// phone had power. Plan W slows a session when the wearer is away; it never ends one.
///
/// **What counts as activity** is the wearer: a tool call or its result, a typed message, a touch
/// on the live controls, and speech **once the model has answered it**. Speech on its own proves
/// nothing, because the microphone hears the room: a TV left on would hold a session open for ever
/// while the model rightly stayed silent. **Model speech alone does not count.** A session talking
/// to an empty room is exactly the case this exists for, and the warning below is model speech too
/// — counting it would have the warning keep the session alive.
///
/// The decision is pure: the clock that feeds it (``LiveIdleClock``) owns time, and neither knows
/// anything about sockets.
struct LiveIdlePolicy: Equatable {

    /// How long a session may go without the wearer before it ends.
    var idleLimit: TimeInterval = 600
    /// How long before the end the one spoken warning is given.
    var warningLead: TimeInterval = 30
    /// Speech this recent may be someone mid-sentence, so the end waits for the model's answer…
    var speechRecency: TimeInterval = 6
    /// …but no longer than this past the limit, or a TV would hold the session open after all.
    var speechGrace: TimeInterval = 20

    enum Decision: Equatable { case none, warn, end }

    /// What to do now, given when the wearer was last active and whether this quiet spell has
    /// already been warned about.
    ///
    /// The end wins at the limit even if the warning was never given — a clock that slept through
    /// the warning window (a suspended process, say) must not hold the session open a further
    /// thirty seconds to say a line about a limit already passed.
    ///
    /// - Parameter unansweredSpeech: when speech was last heard that the model has not answered.
    func decide(lastActivity: Date, warned: Bool, now: Date,
                unansweredSpeech: Date? = nil) -> Decision {
        let quiet = now.timeIntervalSince(lastActivity)
        if quiet >= idleLimit {
            if let unansweredSpeech, now.timeIntervalSince(unansweredSpeech) < speechRecency,
               quiet < idleLimit + speechGrace { return .none }
            return .end
        }
        if !warned, warningLead > 0, quiet >= idleLimit - warningLead { return .warn }
        return .none
    }

    /// The configured limit as minutes, for the words on the status card.
    var idleMinutes: Int { Int((idleLimit / 60).rounded()) }

    /// The policy `Config.liveIdleMinutes` asks for, or `nil` when the wearer turned it off.
    static func configured(minutes: Int = Config.liveIdleMinutes) -> LiveIdlePolicy? {
        guard minutes > 0 else { return nil }
        return LiveIdlePolicy(idleLimit: TimeInterval(minutes) * 60)
    }

    // MARK: - The words

    /// The one spoken warning, said through the session's own voice.
    static let warningLine = "I'll end this session in 30 seconds unless you say something."

    /// How the warning is put to a model that composes its own speech: the exact line, said once,
    /// and nothing else — no question back, which would invite the wearer to answer a prompt they
    /// may not be there to hear.
    static var warningInstruction: String {
        """
        The app needs the wearer to hear one exact sentence now. Say it once, word for word, and \
        say nothing else: "\(warningLine)"
        """
    }

    /// The Settings row's value: "Off", or the limit.
    static func settingValue(minutes: Int) -> String {
        minutes > 0 ? String(localized: "After \(minutes) min") : String(localized: "Off")
    }

    /// The same value for VoiceOver, without the abbreviation.
    static func spokenSettingValue(minutes: Int) -> String {
        minutes > 0 ? String(localized: "After \(minutes) minutes") : String(localized: "Off")
    }

    /// The status card's line after an idle end.
    static func endedNotice(minutes: Int) -> String {
        String(localized: "Session ended after \(minutes) minutes without activity")
    }
}

/// Why a live session ended, kept on the manager after the stop so the status card can say it.
enum LiveSessionEndReason: Equatable {
    /// Any ordinary stop: the wearer, a mode switch, a failure with its own error message.
    case stopped
    /// No wearer activity for the configured limit (Plan HY P1).
    case idleEnded(minutes: Int)
    /// The wearer said goodbye to the session.
    case saidGoodbye

    /// The line the status card shows while no session is running, or `nil` for none.
    var notice: String? {
        switch self {
        case .stopped, .saidGoodbye: return nil
        case .idleEnded(let minutes): return LiveIdlePolicy.endedNotice(minutes: minutes)
        }
    }

    /// The status card's line: the last end's notice, and only while no session is running — a
    /// new session clears the reason, and a running one has nothing to explain.
    static func cardNotice(sessionActive: Bool, reason: LiveSessionEndReason?) -> String? {
        guard !sessionActive else { return nil }
        return reason?.notice
    }
}

/// Plan HY P1 — the small clock both realtime managers own: it remembers when the wearer was last
/// active, feeds ``LiveIdlePolicy`` on a 5 s tick, and calls back on a warning or an end.
///
/// Time is injected (`now`), and so is whether the tick loop runs at all, so a test drives every
/// branch by moving the clock and calling ``tick()`` itself.
@MainActor
final class LiveIdleClock {

    /// How often the policy is consulted. Coarse on purpose: the limit is minutes long, and a
    /// tighter loop is only wakeups.
    static let tickInterval: TimeInterval = 5

    /// The clock. Replaced in tests.
    var now: () -> Date = { Date() }
    /// Whether ``start(policy:)`` runs the background tick loop. Tests turn it off and tick by
    /// hand, so nothing races the clock they set.
    var runsTickLoop = true

    /// The warning moment arrived. Said once per quiet spell.
    var onWarn: (() -> Void)?
    /// The limit passed. The clock has already stopped itself when this is called.
    var onEnd: (() -> Void)?

    private(set) var policy: LiveIdlePolicy?
    private(set) var lastActivity: Date?
    private(set) var warned = false
    /// When speech was last heard that the model has not answered; see ``noteSpeechHeard()``.
    private(set) var unansweredSpeech: Date?
    private var loop: Task<Void, Never>?

    var isRunning: Bool { policy != nil }

    /// Start timing from now. `nil` is the wearer's "Off": nothing is timed and nothing ends.
    func start(policy: LiveIdlePolicy?) {
        stop()
        guard let policy else { return }
        self.policy = policy
        lastActivity = now()
        warned = false
        guard runsTickLoop else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        policy = nil
        lastActivity = nil
        warned = false
        unansweredSpeech = nil
    }

    /// The wearer did something. Resets the quiet spell, and with it the warning.
    func noteActivity() {
        guard isRunning else { return }
        lastActivity = now()
        warned = false
        unansweredSpeech = nil
    }

    /// Speech was heard. It may be the wearer or the room, so it resets nothing until the model
    /// answers it.
    func noteSpeechHeard() {
        guard isRunning else { return }
        unansweredSpeech = now()
    }

    /// The model is replying: speech heard since the last reply was the wearer after all.
    func noteModelReplied() {
        guard isRunning, unansweredSpeech != nil else { return }
        noteActivity()
    }

    /// Consult the policy once. Internal so tests can tick deterministically.
    @discardableResult
    func tick() -> LiveIdlePolicy.Decision {
        guard let policy, let lastActivity else { return .none }
        let decision = policy.decide(lastActivity: lastActivity, warned: warned, now: now(),
                                     unansweredSpeech: unansweredSpeech)
        switch decision {
        case .none:
            break
        case .warn:
            warned = true
            onWarn?()
        case .end:
            stop()
            onEnd?()
        }
        return decision
    }
}

extension Config {
    /// Plan HY P1 — minutes without the wearer before a live session ends; `0` is Off. Default 10.
    /// Stored values outside the stepper's 5 to 60 are clamped into it, so a hand-edited default
    /// cannot ask for a two-second session.
    static var liveIdleMinutes: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: liveIdleMinutesKey) as? Int else {
                return liveIdleMinutesDefault
            }
            return clampedLiveIdleMinutes(stored)
        }
        set { UserDefaults.standard.set(clampedLiveIdleMinutes(newValue), forKey: liveIdleMinutesKey) }
    }

    static let liveIdleMinutesKey = "liveIdleMinutes"
    static let liveIdleMinutesDefault = 10
    static let liveIdleMinutesRange = 5...60

    static func clampedLiveIdleMinutes(_ minutes: Int) -> Int {
        guard minutes > 0 else { return 0 }
        return min(max(minutes, liveIdleMinutesRange.lowerBound), liveIdleMinutesRange.upperBound)
    }
}
