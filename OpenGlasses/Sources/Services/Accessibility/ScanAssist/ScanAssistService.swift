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

    /// Why the session paused, when something other than the wearer paused it. `nil` for an idle,
    /// running or hand-paused session (docs/plans/FB-scan-assist.md P2).
    @Published private(set) var pauseReason: ScanAssistPauseReason?

    /// How many reminders this service has asked to be played.
    ///
    /// **Delivered means playback was requested.** It does not mean the reminder was audible, was
    /// heard, or was acted on: nothing in this app observes any of those, and no copy derived from
    /// this number may imply otherwise.
    @Published private(set) var deliveredCueCount = 0

    /// The pause reason as a line to show. `nil` when there is nothing automatic to explain.
    var pauseReasonText: String? { pauseReason.map(ScanAssistCopy.pauseReason) }

    /// Session time left, recomputed on demand so the countdown needs no timer in this service.
    var remainingSeconds: TimeInterval? { policy.remainingSeconds }

    var settings: ScanAssistSettings { store.settings }

    // MARK: - Seams

    /// The speech service. `nil` until `configure(speech:)` — a service with no voice refuses to
    /// start rather than running a silent session the wearer thinks is cueing them.
    private weak var speech: (any ScanAssistSpeaking)?

    /// Monotonic seconds, shared with the policy.
    private let clock: () -> TimeInterval

    /// What the audio route looks like right now. Injected rather than read here so this service
    /// owns no subscriptions of its own — the app screen wires the real speech, voice-activity and
    /// announcement signals, and a test supplies them by hand. Defaults to a free route, which is
    /// what a Scan Assist session sees when nothing else in the app is talking.
    var signals: @MainActor () -> ScanAssistAudioSignals = { .clear }

    /// Whether VoiceOver is on. Only ever used with `lastAnnouncementAt` to bound the wait
    /// described in `ScanAssistAudioSignals.voiceOverLikelySpeaking` — never as a reason on its
    /// own, which would silence the feature for its likeliest users.
    var voiceOverRunning: @MainActor () -> Bool = { SessionAnnouncer.voiceOverRunning }

    /// When this app last posted a VoiceOver announcement, in the clock's units.
    private var lastAnnouncementAt: TimeInterval?

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

    /// Decides whether each reminder plays, waits or is thrown away. Holds at most one waiting
    /// reminder — see `ScanAssistCueGate`.
    private var gate = ScanAssistCueGate()
    /// The bounded retry for a waiting reminder. At most one, like everything else here.
    private var deferredCue: Task<Void, Never>?

    /// How often a waiting reminder asks whether the route has freed. Short enough that a cue
    /// released the moment the assistant stops speaking still feels like a response to the gap.
    static let deferralRetryInterval: TimeInterval = 0.5

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

    /// Point the service at the app's speech service.
    ///
    /// Wiring, not starting: this stores a weak pointer and nothing else. The app calls it at
    /// launch alongside the audio-event observers (P2), because the voice phrases have to work for
    /// a wearer who turned the feature on once and never reopened its screen — but no session
    /// exists, no audio is claimed and nothing is scheduled until Start.
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
        pauseReason = nil
        // Otherwise the policy may predate the wearer's last edit; re-state the current
        // configuration so a session can never start on a stale side or rhythm.
        syncConfiguration()
        apply(policy.handle(.start))
        publish()
        return policy.state.isRunning
    }

    /// The wearer's own pause. It carries no reason, and — because it is theirs — no audio event
    /// may lift it (`ScanAssistInterruptionPolicy`).
    func pause() {
        pauseReason = nil
        apply(policy.handle(.pause))
        publish()
    }

    func resume() {
        pauseReason = nil
        apply(policy.handle(.resume))
        publish()
    }

    func stop() {
        pauseReason = nil
        apply(policy.handle(.stop))
        publish()
    }

    // MARK: - Interruptions

    /// Answer an audio or lifecycle event. The decision is
    /// `ScanAssistInterruptionPolicy`'s; this method only carries it out.
    ///
    /// Note what is *not* here: nothing acquires, releases, overrides or reroutes an audio
    /// session. Scan Assist speaks through the speech service's lease, on whatever output the
    /// wearer has chosen, and a route it does not own is not a route it may take back.
    func handleAudioEvent(_ event: ScanAssistAudioEvent) {
        switch ScanAssistInterruptionPolicy.recovery(for: event,
                                                     state: policy.state,
                                                     pauseReason: pauseReason) {
        case .none:
            return
        case .pause(let reason):
            apply(policy.handle(.pause))
            pauseReason = reason
            publish()
        case .resume:
            // Certain recovery: the policy's resume gives a fresh interval and no backlog, so
            // nothing that came due during the call is owed.
            pauseReason = nil
            apply(policy.handle(.resume))
            publish()
        case .requireExplicitResume(let reason):
            pauseReason = reason
            publish(needsExplicitResume: true)
        }
    }

    /// Record that the app has just posted a VoiceOver announcement, so the next reminder waits
    /// out the bounded window rather than talking over a screen reader whose speech nothing can
    /// observe finishing.
    func noteAnnouncementPosted() {
        lastAnnouncementAt = clock()
    }

    /// Speak (or sound) the chosen side's cue once, without starting anything.
    ///
    /// The point is audibility on the wearer's actual device and route — whether the cue can be
    /// heard over what they are doing, at the volume they use — which no headless check can answer.
    ///
    /// Deliberately not gated by `ScanAssistCueGate`: a preview is a direct request made while
    /// looking at the screen, not a reminder arriving unasked, so it plays now or not at all.
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
                discardWaitingCue()
            case .sessionEnded:
                cancelPendingCue()
                discardWaitingCue()
                // An ended session explains nothing about a pause; the ending is its own line.
                pauseReason = nil
                // Queued speech goes with the session. Without this a wearer who stops because the
                // reminders became too much still hears the one already handed to the engine.
                speakingCue?.cancel()
                speakingCue = nil
                speech?.stopSpeaking()
            case .emitCue(let side, let generation):
                offer(cueFor: side, generation: generation)
            }
        }
        reschedule()
    }

    private func cancelPendingCue() {
        pendingCue?.cancel()
        pendingCue = nil
    }

    /// Hand one due reminder to the gate and act on its answer.
    private func offer(cueFor side: ScanAssistSide, generation: Int) {
        act(on: gate.offer(side: side,
                           generation: generation,
                           currentGeneration: policy.generation,
                           isRunning: policy.state.isRunning,
                           signals: currentSignals(),
                           at: clock()))
    }

    /// Ask again whether a waiting reminder may play. Internal so a test can drive the retry
    /// without depending on the sleeper's timing.
    func recheckWaitingCue() {
        deferredCue = nil
        act(on: gate.recheck(currentGeneration: policy.generation,
                             isRunning: policy.state.isRunning,
                             signals: currentSignals(),
                             at: clock()))
    }

    private func act(on decision: ScanAssistCueDecision) {
        switch decision {
        case .deliver(let side, _):
            cancelDeferredCue()
            play(cueFor: side)
        case .deferred:
            scheduleDeferredRecheck()
        case .dropped, .nothingWaiting:
            // Nothing is replayed and nothing is owed. A dropped reminder is simply gone: the
            // next one comes at the next interval, like every other one.
            cancelDeferredCue()
        }
    }

    /// The single wake-up for a waiting reminder. Bounded by the gate's budget, not by this timer:
    /// the retry only asks, the gate decides when asking has gone on long enough.
    private func scheduleDeferredRecheck() {
        cancelDeferredCue()
        let sleeper = self.sleeper
        let delay = Self.deferralRetryInterval
        deferredCue = Task { @MainActor [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled else { return }
            self?.recheckWaitingCue()
        }
    }

    private func cancelDeferredCue() {
        deferredCue?.cancel()
        deferredCue = nil
    }

    /// Forget the waiting reminder entirely — the session it belonged to has moved on.
    private func discardWaitingCue() {
        gate.cancelHeld()
        cancelDeferredCue()
    }

    /// The audio situation, with the app's own VoiceOver window folded in.
    private func currentSignals() -> ScanAssistAudioSignals {
        var current = signals()
        if !current.voiceOverIsSpeaking {
            current.voiceOverIsSpeaking = ScanAssistAudioSignals.voiceOverLikelySpeaking(
                voiceOverRunning: voiceOverRunning(),
                lastAnnouncementAt: lastAnnouncementAt,
                now: clock())
        }
        return current
    }

    /// Ask for playback. "Delivered" stops here: what the wearer heard is not observable, and this
    /// counter must never be read as saying it is.
    private func play(cueFor side: ScanAssistSide) {
        guard let speech else { return }
        deliveredCueCount += 1
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

    private func publish(needsExplicitResume: Bool = false) {
        state = policy.state
        switch policy.state {
        case .idle:
            statusMessage = nil
        case .running:
            statusMessage = ScanAssistCopy.sessionRunning
        case .paused:
            guard let pauseReason else {
                statusMessage = ScanAssistCopy.sessionPaused
                return
            }
            statusMessage = needsExplicitResume ? ScanAssistCopy.pausedNeedsResume(pauseReason)
                                                : ScanAssistCopy.pauseReason(pauseReason)
        case .ended(let reason):
            statusMessage = ScanAssistCopy.sessionEnded(reason)
        }
    }
}
