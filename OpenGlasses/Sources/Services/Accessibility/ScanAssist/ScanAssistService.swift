import Foundation

/// Owns the one live Scan Assist session: turns `ScanAssistPolicy`'s decisions into scheduled
/// work and spoken reminders, and — more importantly — takes them back again.
///
/// The service holds no rules. Every "when" and "whether" lives in the policy; this type does the
/// three things a policy cannot: sleep until a deadline, hand a line to the speech service, and
/// cancel both. That split is why the plan's cancellation promises are testable at all.
///
/// What it deliberately never does: start itself. There is no restore-on-launch path and no
/// persisted running state — `ScanAssistSettings` cannot even represent one — so a wearer who
/// force-quits mid-session and reopens the app finds it idle (docs/plans/FB-scan-assist.md P1).
///
/// It also never looks at a camera, because there is nothing a frame could tell it. Scan Assist
/// reminds; it does not observe, verify, score, or say "you missed the left side".
@MainActor
final class ScanAssistService: ObservableObject {

    static let shared = ScanAssistService()

    // MARK: - Published state

    @Published private(set) var state: ScanAssistState = .idle
    /// The last thing worth showing the wearer — a refusal, a running/paused note, an ending.
    /// Shown, never spoken: a validation message is not a reminder, and speaking it would put a
    /// second, unrequested voice on the same audio lease.
    @Published private(set) var statusMessage: String?

    /// Session time left, recomputed on demand so the countdown needs no timer in this service.
    var remainingSeconds: TimeInterval? { policy.remainingSeconds }

    var settings: ScanAssistSettings { store.settings }

    // MARK: - Seams

    /// The speech service. `nil` until `configure(speech:)` — a service with no voice refuses to
    /// start rather than running a silent session the wearer thinks is cueing them.
    private weak var speech: (any ScanAssistSpeaking)?

    /// Monotonic seconds, shared with the policy.
    private let clock: () -> TimeInterval

    /// Waits out a cue interval. Matches the repo's existing sleeper seam
    /// (`CustomAgentHarness.sleeper`); tests replace it with one they can release by hand.
    var sleeper: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private let store: ScanAssistSettingsStore
    private var policy: ScanAssistPolicy

    /// The single outstanding wake-up. At most one exists at any moment, which is what makes
    /// "cancel the queued cue" a complete statement rather than a hopeful one.
    private var pendingCue: Task<Void, Never>?
    /// The in-flight spoken reminder, so a stop can cut a cue off mid-sentence.
    private var speakingCue: Task<Void, Never>?

    /// The `.sound` cue: one short, mid-range tone. Low enough not to be piercing at the volume
    /// someone reading has their glasses set to, short enough not to sit on top of a page turn.
    static let toneFrequency: Double = 660
    static let toneDuration: Double = 0.25

    // MARK: - Init

    init(store: ScanAssistSettingsStore = .shared,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.clock = clock
        self.policy = ScanAssistPolicy(side: store.settings.side,
                                       interval: store.settings.interval,
                                       sessionDuration: store.settings.sessionDuration,
                                       now: clock)
    }

    /// Point the service at the app's speech service. Called by the view rather than at launch:
    /// nothing about Scan Assist should run before a wearer opens its screen.
    func configure(speech: any ScanAssistSpeaking) {
        self.speech = speech
    }

    // MARK: - Settings changes

    /// Answer the side question. The only way `side` is ever set — no caller infers one.
    func chooseSide(_ side: ScanAssistSide?) {
        store.settings.side = side
        apply(policy.handle(.sideChanged(side)))
        publish()
    }

    func setCueStyle(_ style: ScanAssistCueStyle) {
        store.settings.cueStyle = style
    }

    func setTiming(interval: ScanAssistInterval, sessionDuration: ScanAssistSessionDuration) {
        store.settings.interval = interval
        store.settings.sessionDuration = sessionDuration
        apply(policy.handle(.timingChanged(interval: interval, duration: sessionDuration)))
        publish()
    }

    func setEnabled(_ enabled: Bool) {
        store.settings.enabled = enabled
        // Turning the feature off ends anything it is doing. A switch that leaves a voice running
        // is not an off switch.
        if !enabled { stop() }
    }

    // MARK: - Session controls

    /// Begin a session. Returns whether one is now running, so a caller can say why it isn't.
    @discardableResult
    func start() -> Bool {
        guard store.settings.side != nil else {
            statusMessage = ScanAssistCopy.needsSideChoice
            return false
        }
        // A second Start on a live session changes nothing — and must not reach
        // `syncConfiguration()` below, which would replace the running session with a fresh one and
        // hand the wearer back their full session length.
        guard !policy.state.isLive else { return policy.state.isRunning }
        // Otherwise the policy may predate the wearer's last edit; re-state the current
        // configuration so a session can never start on a stale side or rhythm.
        syncConfiguration()
        apply(policy.handle(.start))
        publish()
        return policy.state.isRunning
    }

    func pause() {
        apply(policy.handle(.pause))
        publish()
    }

    func resume() {
        apply(policy.handle(.resume))
        publish()
    }

    func stop() {
        apply(policy.handle(.stop))
        publish()
    }

    /// Speak (or sound) the chosen side's cue once, without starting anything.
    ///
    /// The point is audibility on the wearer's actual device and route — whether the cue can be
    /// heard over what they are doing, at the volume they use — which no headless check can answer.
    @discardableResult
    func preview() -> Bool {
        guard let side = store.settings.side else {
            statusMessage = ScanAssistCopy.needsSideChoice
            return false
        }
        guard let speech else { return false }
        switch store.settings.cueStyle {
        case .spoken:
            let line = ScanAssistCopy.preview(for: side)
            speakingCue?.cancel()
            speakingCue = Task { @MainActor in await speech.speakCue(line) }
        case .sound:
            // Previewing a sound cue means hearing the sound, not hearing a sentence about it.
            speech.playTone(frequency: Self.toneFrequency, duration: Self.toneDuration)
        }
        return true
    }

    // MARK: - Output handling

    private func syncConfiguration() {
        policy = ScanAssistPolicy(side: store.settings.side,
                                  interval: store.settings.interval,
                                  sessionDuration: store.settings.sessionDuration,
                                  now: clock)
    }

    private func apply(_ outputs: [ScanAssistOutput]) {
        for output in outputs {
            switch output {
            case .cancelQueuedCue:
                cancelPendingCue()
            case .sessionEnded:
                cancelPendingCue()
                // Queued speech goes with the session. Without this a wearer who stops because the
                // reminders became too much still hears the one already handed to the engine.
                speakingCue?.cancel()
                speakingCue = nil
                speech?.stopSpeaking()
            case .emitCue(let side, _):
                deliver(cueFor: side)
            }
        }
        reschedule()
    }

    private func cancelPendingCue() {
        pendingCue?.cancel()
        pendingCue = nil
    }

    private func deliver(cueFor side: ScanAssistSide) {
        guard let speech else { return }
        switch store.settings.cueStyle {
        case .spoken:
            let line = ScanAssistCopy.cue(for: side)
            speakingCue?.cancel()
            speakingCue = Task { @MainActor in await speech.speakCue(line) }
        case .sound:
            speech.playTone(frequency: Self.toneFrequency, duration: Self.toneDuration)
        }
    }

    /// Arm the single wake-up for whichever comes first, the next reminder or the end of the
    /// session. Always preceded by a cancel, so no two wake-ups can ever be outstanding.
    private func reschedule() {
        cancelPendingCue()
        guard policy.state.isRunning, let deadline = policy.nextWakeDeadline else { return }
        let generation = policy.generation
        let delay = max(0, deadline - clock())
        let sleeper = self.sleeper
        pendingCue = Task { @MainActor [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled else { return }
            self?.wake(generation: generation)
        }
    }

    /// A wake-up arriving. The generation check is the late-callback guard: a task that was
    /// cancelled a moment too late, or that had already left its sleep when the wearer hit Stop,
    /// finds the session has moved on and says nothing.
    ///
    /// The single entry point for time passing, and internal rather than private so a test can
    /// reproduce that race — a callback landing after a stop — without having to win it.
    func wake(generation: Int) {
        guard generation == policy.generation else { return }
        pendingCue = nil
        apply(policy.handle(.tick))
        publish()
    }

    private func publish() {
        state = policy.state
        switch policy.state {
        case .idle: statusMessage = nil
        case .running: statusMessage = ScanAssistCopy.sessionRunning
        case .paused: statusMessage = ScanAssistCopy.sessionPaused
        case .ended(let reason): statusMessage = ScanAssistCopy.sessionEnded(reason)
        }
    }
}
