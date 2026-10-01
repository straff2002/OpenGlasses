import Foundation
import AVFoundation
import Speech
import CallKit
import os.lock

/// Handles wake word detection using iOS Speech Recognition
/// Listens for "Hey Claude" to trigger voice queries
@MainActor
class WakeWordService: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    @Published var lastDetectionTime: Date?
    @Published var errorMessage: String?
    @Published var debugTranscript: String = ""

    /// Called when a wake word is detected. Passes the matched phrase so the caller can route to the right persona.
    var onWakeWordDetected: ((String) -> Void)?
    var onStopCommand: (() -> Void)?
    /// Called when the user starts speaking during TTS (voice-activity barge-in).
    /// Passes the partial transcript so the app can use it as the start of a new query.
    var onBargeIn: ((String) -> Void)?
    /// Called when Bluetooth audio route is lost (glasses in case / powered off)
    var onBluetoothDisconnected: (() -> Void)?
    /// Called when sustained silence is detected (glasses likely in case).
    var onSilenceDetected: (() -> Void)?
    /// Called when audio resumes after silence (glasses taken out of case).
    var onAudioResumed: (() -> Void)?
    /// Called when Bluetooth audio reconnects (glasses powered back on / out of case).
    var onBluetoothReconnected: (() -> Void)?

    /// Whether the mic is currently paused due to silence (glasses in case).
    @Published var pausedForSilence: Bool = false

    /// RMS threshold below which a buffer is considered "silent".
    /// Glasses mic in a closed case typically produces near-zero signal.
    private let silenceRMSThreshold: Float = 0.005
    /// Number of consecutive silent buffers before declaring silence. At 1024-frame buffers this is
    /// ~13s at 48kHz (Bluetooth) / ~38s at 16kHz — well short of a literal minute (comment corrected
    /// per Plan BE); tune here if the in-case mic shutoff feels too eager.
    private let silenceBufferThreshold: Int = 600
    /// Whether silence was already reported (prevents repeated callbacks).
    private var silenceReported: Bool = false

    private var audioEngine: AVAudioEngine?
    /// Set before an *intentional* recognition cancel (e.g. pausing the wake-word task so
    /// only the buffer forwarder feeds TranscriptionService). Tells `handleRecognitionResult`
    /// to ignore the resulting cancellation error instead of auto-restarting a competing recognizer.
    /// Set when a recognition task is cancelled on purpose, so the resulting error callback is
    /// consumed instead of auto-restarting a competing recognizer. `private(set)` rather than
    /// `private` so the shared-engine handoff can be asserted in tests.
    private(set) var suppressAutoRestart = false

    /// Whether an automatic restart (route change, interruption ended, `resumeListening`) may
    /// re-open the microphone. Injected by `AppState` from the master listening toggle.
    ///
    /// `startListening()` enforces push-to-talk but never knew about the master toggle, so the
    /// service restarted itself on a route change and heard a wake word while listening was
    /// switched off (issue 427 follow-up). Explicit callers still decide for themselves — this
    /// gates only the restarts the service initiates on its own. Defaults to "allowed" so the
    /// service keeps working standalone (and in tests) until AppState wires the toggle in.
    var shouldAutoRestart: () -> Bool = { true }

    /// Whether the wearer has disconnected the app from the glasses while their link stays up
    /// (`AppState.glassesStoodDown`). Injected by `AppState`; defaults to "not stood down" so the
    /// service keeps working standalone and in tests.
    ///
    /// A Bluetooth route flip — HFP↔A2DP renegotiation, the glasses' or someone's headphones'
    /// audio reappearing — can arrive with the link never having dropped, and the restart it
    /// triggers must not re-open the mic the wearer just closed with Disconnect.
    var glassesStoodDown: () -> Bool = { false }

    // MARK: - Plan GU: idle plan, turn hand-off, hand-back

    /// Everything `WakeListenPolicy` reads that the service cannot see for itself. `AppState`
    /// injects the live answer (listening toggle, mute, stand-down, power posture); the default
    /// reads the settings so the service works standalone and in tests. `carPlayMode`,
    /// `foreignOwner` and the consumer flag are filled in by the service.
    var wakeListenInputs: @MainActor () -> WakeListenPolicy.Inputs = {
        WakeListenPolicy.Inputs(listeningEnabled: true, silentMode: Config.silentMode,
                                wakeListenMic: Config.wakeListenMic, micRoute: Config.micRoute,
                                speechGateEnabled: Config.wakeSpeechGateEnabled)
    }

    /// The glasses facts a turn's mic choice reads (`TurnMicHandoff.target`): stood down, and worn
    /// (nil when unknown). Injected by `AppState`.
    var glassesTurnState: @MainActor () -> (stoodDown: Bool, worn: Bool?) = { (false, nil) }

    /// The session coordinator. A closure so tests inject a fresh one over a fake session and the
    /// shared one is never touched there.
    var sessionCoordinator: () -> AudioSessionCoordinator = { .shared }

    /// The idle plan the session was last configured for.
    private(set) var appliedIdlePlan: IdleAudioPlan?
    /// Our own route switches, so their route-change notifications are not taken for disruptions.
    private var routeSwitch = RouteSwitchGeneration()
    /// Whether the engine running now was started for the turn in progress.
    private var turnEngine = TurnEngineOwnership()
    /// The mic the current conversation records on, once its hand-off is done.
    private(set) var turnMicRoute: MicRoute?
    /// A turn's hand-off is rebuilding the engine itself; the configuration-change observer stands
    /// back while it does.
    private var handOffInProgress = false
    /// The end-of-conversation release is running and owns the hand-back.
    private var conversationReleaseInProgress = false
    /// A reply released the hands-free link (Reply audio: full quality); the next follow-up takes
    /// it back before it records.
    private(set) var callLinkReleasedForReply = false
    /// Consecutive live buffers, counted on the render thread for the hand-off.
    private let liveFrames = LiveFrameCounter()
    /// Observer for `AVAudioEngineConfigurationChange` on the current engine.
    private var engineConfigObserver: NSObjectProtocol?
    /// Speech-gate counts for the hourly log line.
    private var gateOpens = 0
    private var gateCloses = 0
    private var lastGateReport = Date()

    /// Test seams for the explicit-turn engine (Plan GU P0 `ExplicitTurnEngineTests`).
    /// Replaces the consumer-engine start (permission + session + engine).
    var consumerEngineStartOverride: (@MainActor () async throws -> Void)?
    /// Replaces the push-to-talk / listening-toggle read that picks a turn's engine source.
    var turnListeningOverride: (@MainActor () -> (silentMode: Bool, listeningEnabled: Bool))?

    /// The gate every restart the service initiates on its own passes: the master listening
    /// toggle, and no glasses stand-down. Explicit `startListening()` callers decide for themselves.
    func mayAutoRestart() -> Bool {
        shouldAutoRestart() && !glassesStoodDown()
    }
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? {
        didSet { tapState.setRequest(recognitionRequest) }   // keep the tap's view in sync (Plan BE)
    }
    private(set) var recognitionTask: SFSpeechRecognitionTask?
    private var audioSessionConfigured: Bool = false

    // MARK: - Listener health (Plan FE P2)

    /// Which start the listener is obeying, and whether anybody still wants one.
    ///
    /// Intent is granted only by `startListening()` and withdrawn only by `stopListening()` /
    /// `deactivateAudioSession()`. Everything the service does to itself — a route flap, an
    /// interruption, a handoff to another consumer, a wake word firing — is a *pause*: it
    /// invalidates the starts in flight without deciding on the wearer's behalf that the
    /// microphone should stay shut.
    private var startGeneration = ListenerStartGeneration()

    /// The start currently climbing, if any. A second caller awaits this one's result instead of
    /// opening a rival microphone: two concurrent callers both cleared the old
    /// `guard !isListening` before either of them had set the flag.
    private var inFlightStart: Task<Void, Error>?

    /// How many start requests have been satisfied by a start already in flight. Diagnostics — and
    /// the signal a test waits on rather than guessing how long a second caller needs.
    private(set) var coalescedStartCount = 0

    /// Whether the input tap is installed. Part of the graph the health decision reads — an engine
    /// running with no tap feeds neither the recognizer nor the shared consumers.
    private var tapIsInstalled = false

    /// Bumped whenever a recognition task is created or torn down. The recognizer's completion
    /// handler captures the value it was created under, and a callback arriving from an older
    /// generation is dropped — so a cancelled task can no longer restart, pause or barge in on the
    /// listener that replaced it.
    private var recognitionGeneration = 0

    /// Whether the last recognition callback carried an error. Carried into the health snapshot
    /// for logging; an ended recognizer is broken listening whether or not it ended badly.
    private var lastRecognitionFailed = false

    /// A pause somebody took on purpose, which the health decision must not mistake for a fault.
    private(set) var deliberatePause: ListenerPauseReason?

    // MARK: - Injected seams (Plan FE P2)
    //
    // The start sequence's decisions are the thing worth testing, and none of the states that
    // provoke them can exist in a test process: a simulator has no microphone route and
    // `SFSpeechRecognizer` never reports itself available there. `nil` means the real path —
    // these are non-nil only where the live audio graph cannot be.

    /// Replaces the microphone + speech-recognition authorization await.
    var permissionOverride: (@MainActor () async -> Bool)?
    /// Replaces the `SFSpeechRecognizer.isAvailable` check.
    var recognizerAvailabilityOverride: (@MainActor () -> Bool)?
    /// Replaces `configureAudioSession()` — the audio-session activation and lease bookkeeping.
    var audioSessionConfigureOverride: (@MainActor () async -> Void)?
    /// Replaces `startRecognition()`. Throwing from it is how a test drives the retry path.
    var startRecognitionOverride: (@MainActor () throws -> Void)?
    /// Replaces `cleanupAudioEngine()` for the start sequence's own rebuilds.
    var cleanupAudioEngineOverride: (@MainActor () -> Void)?
    /// Replaces the observed audio-graph snapshot.
    var graphSnapshotOverride: (@MainActor () -> ListenerGraphSnapshot)?
    /// Replaces "is the audio-session lease held".
    var leaseHeldOverride: (@MainActor () -> Bool)?

    /// Plan FE P3 — whether general speech-triggered barge-in is on, read at the moment a
    /// transcript arrives rather than captured at launch. Overridable for tests; the default reads
    /// the live preference.
    var generalBargeInEnabledOverride: (@MainActor () -> Bool)?

    /// What the app is playing as a transcript arrives, so `BargeInPolicy` can tell the wearer's
    /// voice from the assistant's own coming back through the mic. Wired by `AppState` to the
    /// speech service.
    ///
    /// Unset, this reports `.speaking(text: nil)` for the playback window — the safe answer, not
    /// the convenient one. The barge-in branch below only runs while `listenForStop` is set, i.e.
    /// while a reply is being read out, and an unwired app has no way to tell an echo from speech.
    var assistantSpeechContext: (@MainActor () -> BargeInPolicy.AssistantSpeech)?
    /// Our claim on the shared session with the coordinator. Wake word is the always-on baseline
    /// owner: it self-activates with its tuned config and registers ownership so a live session
    /// (Gemini/OpenAI) supersedes it cleanly, and its release deactivates only if still current.
    ///
    /// Internal (not private) so a test can hand the service a lease from a fake coordinator.
    var sessionLease: AudioSessionLease?
    /// When true, don't start continuous wake word listening — only listen when explicitly triggered.
    /// Set to true when CarPlay is active so we don't hold a recording session open.
    var carPlayMode: Bool = false

    /// When true, also listen for "stop" commands (used during TTS playback)
    var listenForStop: Bool = false
    /// Track whether we already fired a stop for this listening session
    private var stopFired: Bool = false
    /// Track whether wake word already fired for this recognition session (prevent double-fire)
    private var wakeWordFired: Bool = false

    /// Multiple audio buffer consumers keyed by ID (transcription, captions, rewind, etc.)
    private var audioBufferForwarders: [String: @Sendable (AVAudioPCMBuffer) -> Void] = [:]

    /// Lock-guarded state the audio-render thread reads from the tap (Plan BE). The tap block used
    /// to touch `@MainActor` storage (`recognitionRequest`, `audioBufferForwarders`) directly from
    /// the Core Audio thread while the main actor mutated them — a torn read / EXC_BAD_ACCESS on
    /// the app's hottest path. The tap now only ever touches this box; the main actor publishes
    /// changes into it under the same lock.
    private let tapState = WakeTapState()

    /// Owned NotificationCenter observer tokens (Plan BE). Discarding these leaked a fresh
    /// interruption+route observer pair on every reconfigure, so after N glasses reconnects one
    /// route change fired N duplicate handlers.
    private var sessionObservers: [NSObjectProtocol] = []

    /// All active wake phrases from all enabled personas.
    private var allWakePhrases: [String] { Config.allActiveWakePhrases }
    /// Legacy single phrase for backward compatibility.
    private var wakePhrase: String { Config.wakePhrase }
    /// Alternatives for the global phrase. The matcher used to read the persona alternatives and
    /// not these, so a wearer who set a custom phrase in Settings got no misrecognition cover at
    /// all — which is precisely where it is needed, since a phrase nobody shipped is a phrase
    /// nobody tuned the recogniser against.
    private var alternativePhrases: [String] { Config.alternativeWakePhrases }
    private let stopPhrases = ["stop", "stop stop"]

    /// Dynamic stop phrases that include all persona wake words
    private var allStopPhrases: [String] {
        var phrases = stopPhrases
        for persona in Config.enabledPersonas {
            let base = persona.wakePhrase.replacingOccurrences(of: "hey ", with: "")
            phrases.append("\(persona.wakePhrase) stop")
            phrases.append("\(base) stop")
        }
        return phrases
    }

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    }

    /// Force reconfigure audio session (e.g. when mic source changes)
    func reconfigureAudioSession() async {
        audioSessionConfigured = false
        await configureAudioSession()
    }

    /// Pause other audio (podcasts, music) while actively listening.
    /// Skips if a phone/FaceTime call is in progress so we don't interrupt it.
    /// Call when transitioning from wake-word standby to active conversation.
    /// Reference count for hold requests. The pause is applied once for the first holder
    /// and released only when the last holder asks to resume. This lets the mic-active
    /// flow and the TTS-speaking flow nest cleanly — Music/Podcasts stay paused for the
    /// whole interaction and only resume after everything finishes.
    private var pauseHoldCount: Int = 0

    /// Plan GU §2 — the first hold also asks for the **conversation** mic: non-mixable (other audio
    /// pauses, as before), the conversation route's options, and that route's port preferred. The
    /// route chosen here is provisional; `handOffMic()` waits for it to be live and falls back to
    /// the phone when it is not.
    func pauseOtherAudio() async {
        guard !carPlayMode else { return }
        // Never interrupt an active phone or FaceTime call
        let callObserver = CXCallObserver()
        let hasActiveCall = callObserver.calls.contains { $0.hasConnected && !$0.hasEnded && !$0.isOnHold }
        guard !hasActiveCall else {
            PrivacyLog.audio(.wakeWord, .pauseSkippedActiveCall)
            return
        }
        // BJ PR2: mutate the refcount synchronously *before* the first await, so nested
        // beginPause/endPause still nest cleanly across the suspension point below.
        pauseHoldCount += 1
        guard pauseHoldCount == 1 else {
            PrivacyLog.audio(.wakeWord, .otherAudioHeld, count: pauseHoldCount)
            return
        }
        await applyConversationRoute()
        let session = AVAudioSession.sharedInstance()
        PrivacyLog.audio(.wakeWord, .otherAudioPaused,
                         route: PrivacyToken(session.currentRoute.outputs.first?.portType.rawValue ?? "none"))
    }

    /// Reconfigure for the conversation mic and prefer its port. Shared by the first pause hold and
    /// by a follow-up taking the hands-free link back after a full-quality reply.
    private func applyConversationRoute() async {
        if turnSwitchStartedAt == nil { turnSwitchStartedAt = Date() }
        // The engine will reconfigure under this switch; the turn's hand-off rebuilds it on the
        // live input, so the configuration-change observer stands back meanwhile.
        handOffInProgress = true
        defer { handOffInProgress = false }
        let generation = routeSwitch.begin()
        defer { routeSwitch.end(generation, at: Date()) }
        let configured = wakeListenInputs().micRoute
        let glasses = glassesTurnState()
        // First the route the wearer configured (unless the glasses are stood down or off the
        // face). Whether its port is really there can only be read once the category allows it —
        // a phone-mic idle session lists no hands-free inputs at all.
        let wanted = TurnMicHandoff.target(micRoute: configured, glassesStoodDown: glasses.stoodDown,
                                           glassesWorn: glasses.worn, routePortAvailable: true)
        // Omitting mixWithOthers/duckOthers causes iOS to interrupt (pause) other audio apps.
        // .default (NOT .measurement): .measurement disables system audio processing/gain, which
        // makes TTS playback extremely quiet on the iPhone speaker.
        // BJ PR2: the blocking setCategory→setActive runs off-main through the coordinator's
        // `reconfigure` (no deactivate-first, no fallback — the hand-tuned options are preserved).
        try? await sessionCoordinator().reconfigure(
            category: .playAndRecord, mode: .default,
            options: MicRoutePolicy.conversationCategoryOptions(for: wanted))
        let session = AVAudioSession.sharedInstance()
        let available = wanted == .phone || preferredPort(for: wanted, in: session) != nil
        let target = TurnMicHandoff.target(micRoute: configured, glassesStoodDown: glasses.stoodDown,
                                           glassesWorn: glasses.worn, routePortAvailable: available)
        turnMicRoute = target
        // Cheap, non-blocking route hints stay inline.
        if MicRoutePolicy.shouldOverrideToSpeaker(outputs: session.currentRoute.outputs.map(\.portType)) {
            try? session.overrideOutputAudioPort(.speaker)
        }
        if target == .phone {
            preferBuiltInMic(session)
        } else {
            preferConfiguredMicIfAvailable(session, route: target)
        }
    }

    /// Restore other audio (podcasts, music) after active listening ends.
    ///
    /// Plan GU §3: when the last hold goes outside a conversation's own release (an announcement
    /// spoken while idle, push-to-talk's reply arriving after the turn closed), this hands the
    /// session back for real — engine stopped, a deactivation with `.notifyOthersOnDeactivation`
    /// (the old code passed that option to an *activation*, where it does nothing) — and puts the
    /// idle listener back the way it was. Inside a conversation's release, `endConversationAudio`
    /// owns the hand-back and this only counts.
    func resumeOtherAudio() async {
        guard !carPlayMode else { return }
        guard pauseHoldCount > 0 else { return }
        // BJ PR2: decrement synchronously before any await (see pauseOtherAudio).
        pauseHoldCount -= 1
        guard pauseHoldCount == 0 else {
            PrivacyLog.audio(.wakeWord, .otherAudioHeld, count: pauseHoldCount)
            return
        }
        guard !conversationReleaseInProgress else { return }
        let wasListening = isListening || recognitionTask != nil
            || deliberatePause == .speechGateClosed || deliberatePause == .sharedEngine
        await handBackSession()
        PrivacyLog.audio(.wakeWord, .otherAudioResumed)
        if wasListening && startGeneration.wantsListening && mayAutoRestart() {
            deliberatePause = nil
            try? await autoStartListening()
        }
    }

    /// Force release of any held pauses — used when listening is toggled off entirely.
    func forceResumeOtherAudio() async {
        guard pauseHoldCount > 0 else { return }
        pauseHoldCount = 1  // resumeOtherAudio will decrement to 0 and restore
        await resumeOtherAudio()
    }

    /// Whether anything other than dictation is feeding off the shared tap.
    private var sharedConsumersActive: Bool {
        audioBufferForwarders.keys.contains { $0 != "default" }
    }

    /// Plan GU §3 — stop what must stop, then hand the session back per `HandBackDecision`.
    ///
    /// With shared consumers on the tap the engine keeps running for them, the session cannot be
    /// deactivated, and it is reconfigured in place to the idle shape instead. Another owner's
    /// session is left alone. Otherwise: engine down, lease released, session deactivated with
    /// notify, and the next configure activates the idle plan afresh.
    private func handBackSession() async {
        let consumers = sharedConsumersActive
        if !consumers {
            // Deactivating with running I/O fails; the recognizer goes with the engine.
            cleanupAudioGraph()
            setListening(false)
        }
        let generation = routeSwitch.begin()
        defer { routeSwitch.end(generation, at: Date()) }
        let decision = await sessionCoordinator().handBack(sessionLease, sharedConsumersActive: consumers)
        switch decision {
        case .deactivate:
            sessionLease = nil
            audioSessionConfigured = false
            appliedIdlePlan = nil
        case .reconfigureInPlace:
            // Something still rides the session: the old behaviour, minus the hands-free hold —
            // mixable, in the idle shape. The next configure re-applies the plan in full.
            let plan = currentIdlePlan()
            try? await sessionCoordinator().reconfigure(category: .playAndRecord, mode: plan.mode,
                                                        options: plan.categoryOptions)
            if plan.preferredInput == .phone { preferBuiltInMic(AVAudioSession.sharedInstance()) }
            audioSessionConfigured = false
        case .leaveToOwner:
            break
        }
        turnMicRoute = nil
        turnSwitchStartedAt = nil
        callLinkReleasedForReply = false
    }

    /// Prefer the phone's built-in mic (Plan GU: the idle phone listener, and a turn on the phone).
    /// Explicit because, with A2DP allowed, leaving the preference unset is not a promise iOS keeps.
    private func preferBuiltInMic(_ session: AVAudioSession) {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        guard session.preferredInput?.portType != .builtInMic else { return }
        do {
            try session.setPreferredInput(builtIn)
            PrivacyLog.audio(.wakeWord, .preferredInputSet, route: PrivacyToken(MicRoute.phone.rawValue),
                             detail: PrivacyToken(builtIn.portType.rawValue))
        } catch {
            PrivacyLog.audio(.wakeWord, .preferredInputFailed, route: PrivacyToken(MicRoute.phone.rawValue),
                             error: SafeErrorSummary(error))
        }
    }

    /// The available input `route` would prefer, if it is there.
    private func preferredPort(for route: MicRoute, in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        guard route != .phone, let inputs = session.availableInputs else { return nil }
        let ports = inputs.map { (name: $0.portName, type: $0.portType) }
        return MicRoutePolicy.preferredInputIndex(for: route, ports: ports).map { inputs[$0] }
    }

    /// Explicitly prefer the Bluetooth input the configured route asks for.
    /// On iOS 26 Ray-Ban audio rides Bluetooth LE Audio (LC3), so the glasses
    /// mic can surface as `.bluetoothLE` rather than `.bluetoothHFP`, and the
    /// system default input may otherwise stay on the iPhone. The headset
    /// route (Plan CL P3) prefers a non-glasses Bluetooth mic and never falls
    /// back to the glasses — an active glasses hands-free link is what puts
    /// their call screen over the lens HUD. No-op on the phone route or when
    /// no matching input is present, so the iPhone-mic fallback path is never
    /// affected. (Additive and guarded; needs hardware to verify live.)
    private func preferConfiguredMicIfAvailable(_ session: AVAudioSession, route: MicRoute) {
        guard route != .phone else { return }
        guard let input = preferredPort(for: route, in: session) else {
            if route == .headset {
                PrivacyLog.audio(.wakeWord, .noMatchingInput, route: PrivacyToken(route.rawValue))
            }
            return
        }
        do {
            try session.setPreferredInput(input)
            PrivacyLog.audio(.wakeWord, .preferredInputSet, route: PrivacyToken(route.rawValue),
                             device: PrivateIdentifier(input.portName),
                             detail: PrivacyToken(input.portType.rawValue))
        } catch {
            PrivacyLog.audio(.wakeWord, .preferredInputFailed, route: PrivacyToken(route.rawValue),
                             error: SafeErrorSummary(error))
        }
    }

    /// The idle plan for now (`WakeListenPolicy`), with what only the service can see filled in.
    func currentIdlePlan() -> IdleAudioPlan {
        var inputs = wakeListenInputs()
        inputs.carPlayMode = carPlayMode
        inputs.wearerAudioConsumerActive =
            !Set(audioBufferForwarders.keys).isDisjoint(with: WakeListenPolicy.wearerAudioConsumerIDs)
        if let owner = sessionCoordinator().currentOwner, !HandBackDecision.handBackOwners.contains(owner) {
            inputs.foreignOwner = true
        }
        return WakeListenPolicy.decide(inputs)
    }

    /// Configure the shared audio session once — call before first use.
    ///
    /// Plan GU §1: the shape comes from `WakeListenPolicy` — by default the phone's mic, mixable,
    /// with Bluetooth output on A2DP, so a podcast on the glasses stays in full quality while the
    /// app waits; the glasses' (or a headset's) hands-free mic only by the wearer's choice or while
    /// a consumer that wants the wearer's own voice is running. An explicit turn with no idle
    /// listener (`.off`) starts from the phone shape and `pauseOtherAudio` moves it on. The old
    /// `.notifyOthersOnDeactivation` passed to this *activation* is gone: the SDK documents it as
    /// valid only on deactivation, and the hand-back now deactivates for real.
    ///
    /// BJ PR2: records baseline ownership (`assumeOwnership`) then activates **off-main** through the
    /// coordinator's `reconfigure` (no deactivate-first, no `.default` fallback — the hand-tuned
    /// `mixWithOthers` options must survive). `assumeOwnership` is deliberately kept rather than
    /// retired: wake word must not deactivate-first, so `acquireOffMain` (which does) is wrong here —
    /// ownership is recorded and the activation runs through the no-deactivate `reconfigure`.
    func configureAudioSession() async {
        guard !audioSessionConfigured else { return }
        // Register as the baseline owner first (supersedes any prior lease); the reconfigure below
        // performs the real activation while keeping the tuned config.
        sessionLease = sessionCoordinator().assumeOwnership(.wakeWord)

        // CarPlay keeps its own shape whatever the listening settings say: it is only configured
        // when voice control is asked for.
        var plan = currentIdlePlan()
        if carPlayMode, plan.listen != .carPlay {
            plan = IdleAudioPlan(listen: .carPlay, speechGate: false, strictGate: false)
        }

        let generation = routeSwitch.begin()
        defer { routeSwitch.end(generation, at: Date()) }
        do {
            try await sessionCoordinator().reconfigure(
                category: .playAndRecord, mode: plan.mode, options: plan.categoryOptions)
        } catch {
            PrivacyLog.audio(.wakeWord, .sessionConfigureFailed, error: SafeErrorSummary(error))
            return
        }
        audioSessionConfigured = true
        appliedIdlePlan = plan

        let audioSession = AVAudioSession.sharedInstance()
        switch plan.listen {
        case .carPlay:
            PrivacyLog.audio(.wakeWord, .modeSelected, detail: PrivacyToken("carPlayVoiceChat"))
        case .bluetooth(let route):
            preferConfiguredMicIfAvailable(audioSession, route: route)
            PrivacyLog.audio(.wakeWord, .modeSelected, route: PrivacyToken(route.rawValue))
        case .phone, .off, .notOurs:
            preferBuiltInMic(audioSession)
            PrivacyLog.audio(.wakeWord, .modeSelected, route: PrivacyToken(MicRoute.phone.rawValue))
        }
        PrivacyLog.audio(.wakeWord, .idlePlanSelected, route: PrivacyToken(Self.token(for: plan.listen)),
                         detail: PrivacyToken(plan.speechGate ? (plan.strictGate ? "gateStrict" : "gate") : "noGate"))

        // Port *types* only. A port name is the wearer's own device name — "Greig's Ray-Ban
        // Meta" — and naming both ends of the route would say who they are and what they own.
        let route = audioSession.currentRoute
        PrivacyLog.audio(.wakeWord, .sessionConfigured,
                         route: PrivacyToken(route.inputs.first?.portType.rawValue ?? "none"),
                         detail: PrivacyToken(route.outputs.first?.portType.rawValue ?? "none"))

        // Handle audio interruptions + route changes. Tokens are owned and removed before any
        // re-registration (Plan BE) — the old code discarded them, leaking a fresh pair on
        // every reconfigure so one route change fired N duplicate handlers after N reconnects.
        installSessionObservers(audioSession: audioSession)
    }

    static func token(for listen: IdleAudioPlan.Listen) -> String {
        switch listen {
        case .off: return "off"
        case .notOurs: return "notOurs"
        case .carPlay: return "carPlay"
        case .phone: return "phone"
        case .bluetooth(let route): return route.rawValue
        }
    }

    /// Register the interruption + route-change observers exactly once per configuration, removing
    /// any previously-owned tokens first so they can never accumulate.
    private func installSessionObservers(audioSession: AVAudioSession) {
        removeSessionObservers()
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: nil
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioInterruption(notification) }
        }
        let route = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: nil
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        }
        sessionObservers = [interruption, route]
    }

    private func removeSessionObservers() {
        for token in sessionObservers { NotificationCenter.default.removeObserver(token) }
        sessionObservers.removeAll()
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            PrivacyLog.audio(.wakeWord, .interruptionBegan)
            // A pause, not a stop: the OS took the microphone, the wearer did not ask for it to
            // stay shut. Intent survives so `.ended` below is allowed to bring the listener back.
            pauseForAudioDisruption()
        case .ended:
            // Don't fight a live session (Plan BE). If a Gemini/OpenAI realtime session now owns the
            // shared audio session, it handles its own interruption recovery — reactivating here
            // with our .playAndRecord/.default config would stomp its .videoChat setup and spin up a
            // second engine contending for the mic. Only reclaim when wake word is the owner.
            let owner = sessionCoordinator().currentOwner
            guard owner == nil || owner == .wakeWord else {
                PrivacyLog.audio(.wakeWord, .interruptionEndedNotResuming,
                                 owner: PrivacyToken(owner?.rawValue ?? "unknown"))
                return
            }
            guard mayAutoRestart() else {
                PrivacyLog.audio(.wakeWord, .interruptionEndedNotResuming,
                                 detail: PrivacyToken("listeningDisabled"))
                return
            }
            // Plan GU §3: restart per the idle plan, not "a Bluetooth mic is in the route" — a
            // phone-mic listener has no Bluetooth mic and used to stay down after every phone call.
            let plan = currentIdlePlan()
            if plan.holdsSession {
                PrivacyLog.audio(.wakeWord, .interruptionEnded,
                                 detail: PrivacyToken(Self.token(for: plan.listen)))
                // BJ PR2: reactivate off-main through the coordinator (was a main-thread setActive),
                // then restart — one Task so the reactivate precedes the listener start.
                Task {
                    await sessionCoordinator().ensureActiveOffMain()
                    try? await autoStartListening()
                }
            } else {
                PrivacyLog.audio(.wakeWord, .interruptionEndedNotResuming,
                                 detail: PrivacyToken(Self.token(for: plan.listen)))
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        let route = AVAudioSession.sharedInstance().currentRoute
        PrivacyLog.audio(.wakeWord, .routeChanged,
                         route: PrivacyToken(route.inputs.first?.portType.rawValue ?? "none"),
                         detail: PrivacyToken(String(describing: reason)))

        // Plan GU §3: our own switches (idle → conversation, the hand-back, the re-arm) are
        // expected, not disruptions. A switch nobody in the app asked for — another app, "Hey
        // Meta" — still is, and so is a Bluetooth device that really went away mid-switch.
        let lostBluetooth = !hasBluetoothAudioRoute()
        if SelfRouteChangeFilter.verdict(reason: reason,
                                         ownSwitchInFlight: routeSwitch.isOwnSwitch(at: Date()),
                                         bluetoothLost: lostBluetooth) == .ignore {
            PrivacyLog.audio(.wakeWord, .ownRouteChangeIgnored, detail: PrivacyToken(String(describing: reason)))
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            // Bluetooth device disconnected — kill the engine so it's recreated fresh.
            // Judged on inputs *and* outputs: when playback starts the mic port can drop out of
            // the route while the glasses are still the speaker, and that is not a disconnect.
            PrivacyLog.audio(.wakeWord, .deviceDisconnected,
                             detail: PrivacyToken(lostBluetooth ? "bluetoothLost" : "bluetoothRetained"))
            // Plan GU: an idle listener on the phone's own mic did not lose its input when a
            // Bluetooth *output* went away — leave it listening (the configuration-change observer
            // rebuilds the engine if its format moved). Anything else is torn down as before.
            let phoneInputIntact = turnMicRoute == nil && appliedIdlePlan?.listen == .phone
                && route.inputs.contains { $0.portType == .builtInMic }
            if !phoneInputIntact { pauseForAudioDisruption() }
            if lostBluetooth {
                onBluetoothDisconnected?()
            }
        case .newDeviceAvailable:
            // New device connected — only restart if it's Bluetooth (glasses back on)
            let newRoute = AVAudioSession.sharedInstance().currentRoute
            let isBluetooth = MicRoutePolicy.containsBluetoothMic(newRoute.inputs.map(\.portType))
            if isBluetooth {
                PrivacyLog.audio(.wakeWord, .deviceReconnected)
                pauseForAudioDisruption()
                onBluetoothReconnected?()
                // The glasses coming back is not permission to listen: the master toggle decides.
                guard mayAutoRestart() else {
                    PrivacyLog.wakeWord(.listenerSkippedDisabled)
                    return
                }
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    audioSessionConfigured = false
                    await configureAudioSession()
                    try? await autoStartListening()
                }
            } else {
                PrivacyLog.audio(.wakeWord, .deviceIgnored)
            }
        case .override, .categoryChange:
            // Check if format is still valid — if not, rebuild engine
            if let engine = audioEngine {
                let format = engine.inputNode.outputFormat(forBus: 0)
                if format.sampleRate == 0 || format.channelCount == 0 {
                    PrivacyLog.audio(.wakeWord, .formatInvalid,
                                     detail: PrivacyToken("routeChange"))
                    pauseForAudioDisruption()
                }
            }
        default:
            break
        }
    }

    /// Ask for the wake-word listener.
    ///
    /// This is the *explicit* request: it records the wearer's intent, which an automatic restart
    /// never does and only an explicit stop withdraws. Push-to-talk (silent mode) is still the
    /// single chokepoint — every auto-start path (launch, foreground, glasses connect,
    /// returnToWakeWord, autoStart) funnels through here, so the mic is never held for constant
    /// listening. On-demand triggers (Action Button → `startDirectTranscription`) bypass this and
    /// still work.
    func startListening() async throws {
        startGeneration.recordIntent()
        try await start(origin: .explicit)
    }

    /// The service asking itself: a route change, an ended interruption, a recognition restart,
    /// `resumeListening()`. Never grants intent — if an explicit stop withdrew it, this is refused,
    /// which is what stops a glasses reconnect from re-opening a microphone the wearer closed.
    ///
    /// Internal rather than private so the recovery path can be awaited directly in tests: the
    /// callers that reach it in production are fire-and-forget `Task`s inside notification
    /// handlers, and asserting on those means racing them.
    func autoStartListening() async throws {
        try await start(origin: .automatic)
    }

    /// Coalesce. Starting is not instant — two authorization awaits, a session activation and up
    /// to three retries with sleeps — and every one of those suspensions used to be a window in
    /// which a second caller cleared `guard !isListening` and began a rival start.
    private func start(origin: ListenerStartOrigin) async throws {
        if let inFlight = inFlightStart {
            coalescedStartCount += 1
            PrivacyLog.wakeWord(.listenerStartCoalesced, reason: PrivacyToken(origin.rawValue))
            return try await inFlight.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightStart = nil }
            try await self.performStart(origin: origin)
        }
        inFlightStart = task
        try await task.value
    }

    private func performStart(origin: ListenerStartOrigin) async throws {
        let token = startGeneration.beginStart()

        // Pre-flight, before anything is awaited: the cheap answers. A listener that is already
        // working satisfies the request; a refusal or a deliberate pause ends it here.
        switch ListenerHealthPolicy.decide(healthState(origin: origin, permission: .unknown)) {
        case .healthy:
            PrivacyLog.wakeWord(.listenerHealthy, reason: PrivacyToken(origin.rawValue))
            return
        case .pausedDeliberately(let reason):
            PrivacyLog.wakeWord(.listenerPausedDeliberately, reason: PrivacyToken(reason.rawValue))
            return
        case .refuse(.silentMode):
            PrivacyLog.wakeWord(.listenerSkippedPushToTalk)
            return
        case .refuse(let refusal):
            PrivacyLog.wakeWord(.listenerRefused, reason: PrivacyToken(refusal.rawValue))
            return
        case .rebuild, .startFresh:
            break
        }

        stopFired = false
        wakeWordFired = false
        silenceTracker.reset()
        silenceReported = false
        pausedForSilence = false
        if deliberatePause == .silence { deliberatePause = nil }

        let hasPermission = await listenerPermissionsGranted()
        // A `stopListening()` that landed during the authorization prompt wins. The late start
        // built nothing yet, so abandoning is simply declining to build one.
        guard startGeneration.checkpoint(token) == .proceed else { return abandonStart() }
        guard hasPermission else {
            errorMessage = "Speech recognition permission denied"
            throw WakeWordError.microphonePermissionDenied
        }

        guard recognizerIsAvailable() else {
            errorMessage = "Speech recognition not available"
            throw WakeWordError.configurationError("Speech recognizer not available")
        }

        // Ensure audio session is configured
        await configureSessionThroughSeam()
        guard startGeneration.checkpoint(token) == .proceed else { return abandonStart() }

        // Retry up to 3 times with increasing delay if audio engine fails
        var lastError: Error?
        for attempt in 1...3 {
            // Re-decide every attempt: the graph left behind by a failed attempt is not the graph
            // the pre-flight saw. A rebuild goes through the existing `cleanupAudioEngine()` and
            // then `startRecognition()`, keeping whatever session lease is held — the lease is
            // never released and re-acquired around a rebuild, because other consumers coexist on
            // it and wake word is the baseline owner.
            if case .rebuild(let reason) =
                ListenerHealthPolicy.decide(healthState(origin: origin, permission: .granted)) {
                PrivacyLog.wakeWord(.listenerRebuilt, reason: PrivacyToken(reason.rawValue),
                                    attempt: attempt)
                cleanupAudioGraph()
            }
            do {
                try startRecognitionThroughSeam()
                deliberatePause = startedBehindClosedGate ? .speechGateClosed : nil
                setListening(true)
                PrivacyLog.wakeWord(.listenerStarted, attempt: attempt)
                return
            } catch {
                lastError = error
                PrivacyLog.wakeWord(.listenAttemptFailed, attempt: attempt,
                                    error: SafeErrorSummary(error))
                cleanupAudioGraph()
                // CoreAudio '!pla' (2003329396): the AVAudioSession lost activation — usually a
                // Bluetooth route flap mid-start (device-traced: Action-button intent in the
                // background burned all 3 attempts inside the same broken window, then went
                // silent). Re-activating the session before the retry is what actually
                // recovers; the half-second sleeps alone never did.
                if (error as NSError).code == 2003329396 || attempt > 1 {
                    audioSessionConfigured = false
                    await configureSessionThroughSeam()
                    guard startGeneration.checkpoint(token) == .proceed else { return abandonStart() }
                }
                let delay = UInt64(attempt) * 700_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard startGeneration.checkpoint(token) == .proceed else { return abandonStart() }
            }
        }
        throw lastError ?? WakeWordError.configurationError("Failed to start after 3 attempts")
    }

    /// A stop or a pause landed while this start was suspended.
    ///
    /// Deliberately does **nothing** but record it. Every abandon point is before the start has
    /// built anything, so the graph standing at that moment belongs to whoever put it there — the
    /// stop that overtook us (which already cleaned up), or another consumer whose engine a late
    /// start has no business tearing down. The session lease is likewise left alone: wake word is
    /// the baseline owner and `stopListening()` idles the mic without surrendering ownership, so
    /// there is nothing here for a late start to release.
    private func abandonStart() {
        PrivacyLog.wakeWord(.listenerStartAbandoned)
    }

    /// Stop listening at somebody's explicit request.
    ///
    /// The one thing that withdraws intent. Nothing the service does on its own — a route flap, an
    /// interruption, a handoff — puts it back, so the microphone stays off until a caller asks
    /// again. Any start still climbing is invalidated and will decline to claim a listener.
    func stopListening() {
        startGeneration.recordStop()
        deliberatePause = nil
        cleanupAudioEngine()
        setListening(false)
    }

    /// The listener went down for a reason that was not the wearer's decision: an interruption, a
    /// route flap, an invalid input format. Tear the graph down but keep intent, so the matching
    /// recovery path is allowed to bring it back.
    ///
    /// Internal for the same reason as `autoStartListening()`: in production it is only ever
    /// reached from inside a `NotificationCenter` handler, and asserting on those means posting
    /// audio-session notifications at observers that only exist once a real session has been
    /// configured.
    func pauseForAudioDisruption() {
        startGeneration.recordPause()
        // A deliberate pause is a claim on a *running* graph — the shared-engine handoff means
        // "another consumer is using this engine, leave it alone". The engine is about to be gone,
        // so the claim is void, and an automatic restart standing off for it would leave nothing
        // listening and nothing feeding the consumers either.
        deliberatePause = nil
        cleanupAudioEngine()
        setListening(false)
    }

    // MARK: - Health inputs and seams

    /// The single writer of `isListening`.
    ///
    /// The flag is no longer a health check — `ListenerHealthPolicy` reads the engine, the tap and
    /// the recognition task, because a flag left `true` by an audio disruption is precisely the
    /// defect this phase exists to fix. It remains what the UI shows and what the rest of the app
    /// reads, so every path that changes it comes through here, and the only place that sets it
    /// `true` is the one that has just created a recognition task.
    private func setListening(_ value: Bool) {
        guard isListening != value else { return }
        isListening = value
    }

    /// What the recognizer is actually doing.
    private var liveRecognitionState: ListenerRecognitionState {
        guard let task = recognitionTask else { return .none }
        switch task.state {
        case .starting, .running: return .running
        case .finishing, .canceling, .completed: return .ended(failed: lastRecognitionFailed)
        @unknown default: return .ended(failed: lastRecognitionFailed)
        }
    }

    private func graphSnapshot() -> ListenerGraphSnapshot {
        if let graphSnapshotOverride { return graphSnapshotOverride() }
        return ListenerGraphSnapshot(engineRunning: audioEngine?.isRunning == true,
                                     tapInstalled: tapIsInstalled,
                                     recognition: liveRecognitionState)
    }

    /// Everything the health decision is allowed to look at, read off the live service.
    func healthState(origin: ListenerStartOrigin,
                     permission: ListenerHealthState.Permission) -> ListenerHealthState {
        ListenerHealthState(
            flagSaysListening: isListening,
            graph: graphSnapshot(),
            captureShared: !audioBufferForwarders.isEmpty,
            deliberatelyPaused: deliberatePause,
            leaseHeld: leaseHeldOverride?() ?? (sessionLease != nil),
            intent: startGeneration.wantsListening,
            silentMode: Config.silentMode,
            permission: permission,
            origin: origin)
    }

    private func listenerPermissionsGranted() async -> Bool {
        if let permissionOverride { return await permissionOverride() }
        return await requestPermissions()
    }

    private func recognizerIsAvailable() -> Bool {
        if let recognizerAvailabilityOverride { return recognizerAvailabilityOverride() }
        return speechRecognizer?.isAvailable == true
    }

    private func configureSessionThroughSeam() async {
        if let audioSessionConfigureOverride {
            await audioSessionConfigureOverride()
            return
        }
        await configureAudioSession()
    }

    private func cleanupAudioGraph() {
        recognitionGeneration &+= 1
        if let cleanupAudioEngineOverride {
            cleanupAudioEngineOverride()
            return
        }
        cleanupAudioEngine()
    }

    private func startRecognitionThroughSeam() throws {
        recognitionGeneration &+= 1
        startedBehindClosedGate = false
        if let startRecognitionOverride {
            try startRecognitionOverride()
            return
        }
        try startRecognition()
    }

    /// Fully deactivate the audio session — use when CarPlay voice control is dismissed
    /// so car audio (FM radio, other apps) can resume.
    func deactivateAudioSession() async {
        // Surrendering the session is an explicit teardown, so intent goes with it.
        startGeneration.recordStop()
        deliberatePause = nil
        cleanupAudioEngine()
        setListening(false)
        audioSessionConfigured = false
        if let lease = sessionLease {
            // Release through the coordinator: it deactivates only if wake word is still the
            // current owner, so this can't tear down a live Gemini/OpenAI session that preempted us.
            // The deactivation itself runs off-main on the coordinator's sessionIOQueue (BJ PR1).
            sessionLease = nil
            sessionCoordinator().release(lease)
            PrivacyLog.audio(.wakeWord, .sessionReleased)
        } else {
            // BJ PR2: rare no-lease fallback — deactivate off-main via the coordinator too.
            await sessionCoordinator().deactivateOffMain()
            PrivacyLog.audio(.wakeWord, .sessionDeactivated)
        }
    }

    /// Bring the listener back after a pause the service took itself.
    ///
    /// No `guard !isListening` any more — that guard is the defect. The health decision answers
    /// the same question from the graph, so a stale flag can neither suppress a needed restart nor
    /// hide a listener that is genuinely already up.
    func resumeListening() {
        guard mayAutoRestart() else {
            PrivacyLog.wakeWord(.listenerSkippedDisabled)
            return
        }
        Task { try? await autoStartListening() }
    }

    // MARK: - Turn mic hand-off and hand-back (Plan GU §2–§4)

    /// When the current conversation's route switch began (the first pause hold), for the
    /// switch-time measurement.
    private var turnSwitchStartedAt: Date?

    /// Switch first, then listen: wait until the conversation mic `pauseOtherAudio` asked for is
    /// live — the route resolves to it **and** a rebuilt engine delivers buffers carrying sound —
    /// then return, so the caller's tone means "talk now" on the mic that will hear it. At
    /// `TurnMicHandoff.deadline` the turn moves to the phone mic instead (`turnMicFellBack`); a
    /// slow link never eats the request.
    func handOffMic() async {
        guard !carPlayMode else { return }
        let session = AVAudioSession.sharedInstance()
        // No pause hold means the session was not moved (a phone call is active): record on
        // whatever is there, exactly as before.
        guard pauseHoldCount > 0, let target = turnMicRoute else {
            if audioEngine?.isRunning != true { try? createAndStartAudioEngine() }
            return
        }
        handOffInProgress = true
        defer { handOffInProgress = false }
        let generation = routeSwitch.begin()
        defer { routeSwitch.end(generation, at: Date()) }
        let began = turnSwitchStartedAt ?? Date()
        let deadline = Date().addingTimeInterval(TurnMicHandoff.deadline)
        var machine = TurnMicHandoff.Machine(target: target)

        // Already there: an engine running on a valid format on the target mic.
        if resolvedInput(session) == target, let engine = audioEngine, engine.isRunning,
           engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 {
            finishHandOff(on: target, fellBack: false, began: began, session: session)
            return
        }
        // Stop on purpose rather than mid-dictation: the route change would stop it anyway.
        stopEngineKeepingRecognition()
        while true {
            var action: TurnMicHandoff.Action = .none
            switch machine.state {
            case .waitingForRoute:
                action = machine.handle(.routeObserved(resolvedInput(session)))
            case .waitingForFrames:
                if audioEngine?.isRunning != true { rebuildHandOffEngine() }
                if liveFrames.consecutive >= TurnMicHandoff.liveFramesRequired {
                    action = machine.handle(.framesNonSilent)
                }
            case .live, .fellBack:
                break
            }
            if action == .buildEngine {
                rebuildHandOffEngine()
                action = .none
            }
            if action == .none, Date() >= deadline {
                action = machine.handle(.deadline)
            }
            switch action {
            case .startTurn(let route):
                finishHandOff(on: route, fellBack: false, began: began, session: session)
                return
            case .fallBackToPhone:
                await fallBackToPhoneMic(session)
                finishHandOff(on: .phone, fellBack: true, began: began, session: session)
                return
            case .none, .buildEngine:
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func rebuildHandOffEngine() {
        stopEngineKeepingRecognition()
        do { try createAndStartAudioEngine() } catch {
            // A half-up link can report a zero format for a moment; the loop tries again.
            stopEngineKeepingRecognition()
        }
    }

    /// The deadline passed: move this turn to the phone mic (conversation shape, no hands-free
    /// link). A2DP output stays allowed, so a reply still plays in the wearer's AirPods or glasses.
    private func fallBackToPhoneMic(_ session: AVAudioSession) async {
        try? await sessionCoordinator().reconfigure(
            category: .playAndRecord, mode: .default,
            options: MicRoutePolicy.conversationCategoryOptions(for: .phone))
        preferBuiltInMic(session)
        if MicRoutePolicy.shouldOverrideToSpeaker(outputs: session.currentRoute.outputs.map(\.portType)) {
            try? session.overrideOutputAudioPort(.speaker)
        }
        rebuildHandOffEngine()
    }

    private func finishHandOff(on route: MicRoute, fellBack: Bool, began: Date, session: AVAudioSession) {
        turnMicRoute = route
        turnSwitchStartedAt = nil
        let elapsed = Date().timeIntervalSince(began)
        let ms = Int((elapsed * 1000).rounded())
        if fellBack {
            PrivacyLog.audio(.wakeWord, .turnMicFellBack, route: PrivacyToken(route.rawValue), milliseconds: ms)
            return
        }
        PrivacyLog.audio(.wakeWord, .turnMicLive, route: PrivacyToken(route.rawValue), milliseconds: ms)
        guard route != .phone, let port = session.currentRoute.inputs.first else { return }
        // The measurement Automatic reply audio reads: a rolling median per device, keyed by an
        // opaque hash of the port UID — never its name.
        var ledger = Config.micSwitchTimes
        ledger.record(elapsed, device: SwitchTimeLedger.deviceKey(portUID: port.uid))
        Config.setMicSwitchTimes(ledger)
        if let hq = port.bluetoothMicrophoneExtension?.highQualityRecording {
            PrivacyLog.audio(.wakeWord, .highQualityRecordingSupport,
                             route: PrivacyToken(port.portType.rawValue),
                             detail: PrivacyToken("supported-\(hq.isSupported)-enabled-\(hq.isEnabled)"))
        }
    }

    /// Which route the session's live input is on (`MicRoutePolicy.resolvedRoute`).
    private func resolvedInput(_ session: AVAudioSession) -> MicRoute? {
        MicRoutePolicy.resolvedRoute(from: session.currentRoute.inputs.map { (name: $0.portName, type: $0.portType) })
    }

    /// The measured switch time for the device the conversation is on, if any.
    func measuredSwitchSeconds() -> Double? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first,
              port.portType != .builtInMic else { return nil }
        return Config.micSwitchTimes.median(device: SwitchTimeLedger.deviceKey(portUID: port.uid))
    }

    /// Plan GU §3 step 2 — the conversation is over: stop the recognizer and the engine (shared
    /// consumers permitting). Deactivating with running I/O fails, so this precedes the hand-back.
    func stopConversationEngine(listenerWanted: Bool) {
        guard !carPlayMode else { return }
        conversationReleaseInProgress = true
        let consumers = sharedConsumersActive
        _ = turnEngine.endTurn(listenerWanted: listenerWanted, consumersActive: consumers)
        if !consumers {
            cleanupAudioGraph()
            setListening(false)
        }
    }

    /// Plan GU §3 step 3 — drop every pause hold the conversation took and hand the session back
    /// (`HandBackDecision`: a real deactivation with notify when nothing else rides it).
    func handBackConversationAudio() async {
        guard !carPlayMode else {
            await forceResumeOtherAudio()
            return
        }
        conversationReleaseInProgress = true
        defer { conversationReleaseInProgress = false }
        pauseHoldCount = 0
        await handBackSession()
        PrivacyLog.audio(.wakeWord, .otherAudioResumed)
    }

    /// Steps 2 and 3 together.
    func endConversationAudio(listenerWanted: Bool) async {
        stopConversationEngine(listenerWanted: listenerWanted)
        await handBackConversationAudio()
    }

    /// The re-arm was skipped (push-to-talk, listening off, muted, stood down): nothing may be left
    /// running or held. Shared consumers keep their engine.
    func ensureReleasedAfterTurn() {
        guard !sharedConsumersActive else { return }
        if audioEngine != nil || recognitionTask != nil {
            cleanupAudioGraph()
            setListening(false)
        }
        deliberatePause = nil
    }

    /// Plan GU §4 — a reply in full quality: release the hands-free link (A2DP output only,
    /// non-mixable so other audio stays paused) and move the engine to the phone mic, where the
    /// stop phrase and barge-in listen. The next follow-up takes the link back
    /// (`retakeConversationMicIfReleased`). No-op unless the policy chose `.fullQuality` and the
    /// conversation is on a Bluetooth mic.
    func applyReplyRoute(_ route: ReplyRoute) async {
        guard route == .fullQuality, !carPlayMode, pauseHoldCount > 0,
              let current = turnMicRoute, current != .phone, !callLinkReleasedForReply else { return }
        handOffInProgress = true
        defer { handOffInProgress = false }
        let generation = routeSwitch.begin()
        defer { routeSwitch.end(generation, at: Date()) }
        stopEngineKeepingRecognition()
        try? await sessionCoordinator().reconfigure(
            category: .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        preferBuiltInMic(AVAudioSession.sharedInstance())
        rebuildHandOffEngine()
        callLinkReleasedForReply = true
        PrivacyLog.audio(.wakeWord, .replyRouteSelected, detail: PrivacyToken("fullQuality"))
    }

    /// A follow-up after a full-quality reply: take the conversation mic back before recording.
    func retakeConversationMicIfReleased() async {
        guard callLinkReleasedForReply else { return }
        callLinkReleasedForReply = false
        if recognitionTask != nil { pauseRecognitionForSharedEngine() }
        turnSwitchStartedAt = Date()
        await applyConversationRoute()
        await handOffMic()
    }

    // MARK: - Shared Audio Engine (for TranscriptionService)

    /// Ensure the shared audio engine is running (creates one if needed).
    /// Call this before `TranscriptionService.startRecording()` to guarantee
    /// the buffer-forwarding path is alive — e.g. after TTS playback which
    /// may have interrupted or stopped the engine.
    ///
    /// Plan GU §2: a push-to-talk or listening-off turn used to get nothing here — the listener
    /// refuses to start in push-to-talk — and fell to `TranscriptionService`'s dedicated engine,
    /// which device logs show silent. Such a turn now starts the shared engine for consumers only
    /// (`TurnEngineOwnership`), and the turn's end stops it.
    func ensureAudioEngineRunning() async throws {
        let settings = turnListeningOverride?()
            ?? (silentMode: Config.silentMode, listeningEnabled: shouldAutoRestart())
        let source = TurnEngineOwnership.source(engineRunning: graphSnapshot().engineRunning,
                                                silentMode: settings.silentMode,
                                                listeningEnabled: settings.listeningEnabled)
        switch source {
        case .reuseRunning:
            return
        case .consumerEngineForTurn:
            PrivacyLog.audio(.wakeWord, .engineRestarted, detail: PrivacyToken("turnOnly"))
            try await ensureAudioEngineRunningForConsumers()
            turnEngine.noteStarted(source)
        case .wakeListener:
            // Engine is nil or stopped — restart it (without starting recognition)
            PrivacyLog.audio(.wakeWord, .engineRestarted, detail: PrivacyToken("sharedUse"))
            try await startListening()
            pauseRecognitionForSharedEngine()
            turnEngine.noteStarted(source)
        }
    }

    /// Hand the running audio engine over to another consumer: tear down the wake-word recognizer
    /// but leave the engine (and its buffer forwarders) alive.
    ///
    /// The cancel is marked intentional so its error callback doesn't auto-restart a competing
    /// recognizer — that would fight `TranscriptionService` and make tap-to-talk stop the instant
    /// it starts.
    ///
    /// `isListening` **must** drop with the recognizer. `startListening()` opens with
    /// `guard !isListening else { return }`, so leaving the flag set after the recognizer is gone
    /// made every later auto-restart a silent no-op: the service reported that it was listening
    /// while nothing was recognising, and the wake word worked exactly once per launch (issue 427).
    /// `pauseRecognition()` already drops the flag for the same reason.
    func pauseRecognitionForSharedEngine() {
        // A deliberate pause: the engine and its tap stay up for the consumer that now owns the
        // capture, intent survives, and an *automatic* restart is declined until the owner asks.
        startGeneration.recordPause()
        deliberatePause = .sharedEngine
        recognitionGeneration &+= 1
        suppressAutoRestart = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        setListening(false)
    }

    /// Start the shared engine for an explicit audio-buffer consumer even when always-on wake-word
    /// listening is disabled. Unlike `startListening()`, this only needs microphone permission and
    /// does not create a Speech recognition task.
    func ensureAudioEngineRunningForConsumers() async throws {
        if let consumerEngineStartOverride {
            try await consumerEngineStartOverride()
            return
        }
        if let engine = audioEngine, engine.isRunning { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone permission denied"
            throw WakeWordError.microphonePermissionDenied
        }

        await configureAudioSession()
        if audioEngine != nil { stopEngineKeepingRecognition() }
        try createAndStartAudioEngine()

        guard audioEngine?.isRunning == true else {
            throw WakeWordError.configurationError("Shared audio engine did not start")
        }
    }

    /// Get the current audio engine (for shared use by TranscriptionService)
    func getAudioEngine() -> AVAudioEngine? {
        return audioEngine
    }

    /// Legacy single-forwarder API — routes through the multi-consumer system with key "default"
    func setAudioBufferForwarder(_ forwarder: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        if let forwarder = forwarder {
            audioBufferForwarders["default"] = forwarder
        } else {
            audioBufferForwarders.removeValue(forKey: "default")
        }
        tapState.setForwarders(audioBufferForwarders)
    }

    /// Add a named audio buffer consumer. Multiple consumers can listen simultaneously.
    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        audioBufferForwarders[id] = handler
        tapState.setForwarders(audioBufferForwarders)
        reapplyIdlePlanIfChanged()
    }

    /// Remove a named audio buffer consumer.
    func removeAudioBufferConsumer(id: String) {
        audioBufferForwarders.removeValue(forKey: id)
        tapState.setForwarders(audioBufferForwarders)
        reapplyIdlePlanIfChanged()
    }

    /// Plan GU §1 — a consumer that wants the wearer's own voice (captions, the teleprompter, a
    /// glasses recording or broadcast) started or stopped while the app was idle: move the idle
    /// session to the plan's new mic. The engine reconfigures under the switch and the
    /// configuration-change observer rebuilds it, consumers and recognizer included. Never under a
    /// turn — a conversation owns the route until its hand-back.
    private func reapplyIdlePlanIfChanged() {
        guard audioSessionConfigured, pauseHoldCount == 0, turnMicRoute == nil, !carPlayMode,
              let applied = appliedIdlePlan else { return }
        let plan = currentIdlePlan()
        guard plan.holdsSession, plan.listen != applied.listen else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pauseHoldCount == 0, self.turnMicRoute == nil else { return }
            await self.reconfigureAudioSession()
        }
    }

    private func cleanupAudioEngine() {
        // Obsolete recognition callbacks die with the task they belonged to.
        recognitionGeneration &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        stopEngineKeepingRecognition()
    }

    /// Stop the engine and remove its tap; leave the recognition state and the forwarders alone.
    /// The forwarders are re-published into the next tap, so consumers survive a rebuild.
    private func stopEngineKeepingRecognition() {
        // The gate's pre-roll is in the old engine's format; `startRecognition` re-enables it on
        // the next one when the plan still wants it.
        tapState.disableGate()
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        tapIsInstalled = false
        audioEngine = nil
    }

    /// Set by `startRecognition()` when it left the recognizer waiting behind a closed speech gate
    /// (Plan GU §5), so the start records that deliberate pause instead of clearing it.
    private var startedBehindClosedGate = false
    /// After the gate gave up (open longer than `WakeSpeechGate.maxOpenSeconds` — a conversation
    /// nearby), listen continuously until this time, then gate again.
    private var gateRetryAfter: Date?
    private static let gateRetryInterval: TimeInterval = 300

    private func startRecognition() throws {
        // A fresh recognizer consumes no older cancel: `suppressAutoRestart` belongs to the task
        // being replaced, and the generation tag below is what actually silences its callbacks.
        suppressAutoRestart = false
        startedBehindClosedGate = false
        // Cancel any existing recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        try ensureEngineForRecognition()

        // Plan GU §5 — behind the flag, full recognition runs only while somebody is talking. The
        // engine and tap keep running (the app stays alive in the background, every shared
        // consumer stays fed, the mic indicator stays truthful); only the task waits. Never while
        // a reply plays — barge-in and the stop phrase need the recognizer continuously.
        if let plan = appliedIdlePlan, plan.speechGate, !listenForStop,
           gateRetryAfter.map({ Date() >= $0 }) ?? true,
           let format = audioEngine?.inputNode.outputFormat(forBus: 0), format.sampleRate > 0 {
            gateRetryAfter = nil
            tapState.enableGate(format: format, strict: plan.strictGate) { [weak self] output in
                Task { @MainActor [weak self] in self?.handleGateOutput(output) }
            }
            startedBehindClosedGate = true
            return
        }
        tapState.disableGate()
        try openRecognizer()
    }

    /// Reuse a running engine with a valid format, or build one.
    private func ensureEngineForRecognition() throws {
        if let engine = audioEngine, engine.isRunning {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0 && format.channelCount > 0 {
                PrivacyLog.audio(.wakeWord, .engineReused)
            } else {
                // Engine is running but format is invalid (Bluetooth route lost)
                PrivacyLog.audio(.wakeWord, .formatInvalid, detail: PrivacyToken("running"),
                                 hertz: Int(format.sampleRate), channels: Int(format.channelCount))
                stopEngineKeepingRecognition()
                try createAndStartAudioEngine()
            }
        } else {
            // Clean up old engine if it exists but isn't running
            if audioEngine != nil { stopEngineKeepingRecognition() }
            try createAndStartAudioEngine()
        }
    }

    /// Create the wake-word recognition request and task on the running engine.
    private func openRecognizer() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device wake-word spotting (Plan BE): the always-on listener no longer streams mic
        // audio to Apple's servers 24/7 — the single largest steady battery/data drain. Short-phrase
        // spotting works well on-device (contextualStrings still apply); real queries keep server
        // recognition in TranscriptionService. Falls back to server if the locale can't do on-device.
        let wantsOnDevice = Config.onDeviceWakeWordEnabled
        let canDoOnDevice = speechRecognizer?.supportsOnDeviceRecognition ?? false
        request.requiresOnDeviceRecognition = wantsOnDevice && canDoOnDevice
        if wantsOnDevice && !canDoOnDevice {
            PrivacyLog.wakeWord(.onDeviceUnavailable)
        }
        request.taskHint = .search  // Short phrase detection
        // Boost recognition of all persona wake phrases
        let personaPhrases = Config.allActiveWakePhrases
        let contextPhrases = personaPhrases.isEmpty ? [wakePhrase] : personaPhrases
        request.contextualStrings = contextPhrases
        // The contextual-boost list *is* the wake phrases, and the persona names beside them are
        // what the wearer called their assistants — often a real name. Only how many there are.
        PrivacyLog.wakeWord(.contextConfigured, count: contextPhrases.count)
        // Publishing the request into the tap replays the gate's pre-roll first, if one is held.
        recognitionRequest = request

        // Tag the handler with the generation it was created under. A task that has been
        // cancelled or replaced still delivers a final callback, and that callback used to be
        // indistinguishable from the live one — it could restart, pause or barge in on its own
        // successor. An older generation is now simply dropped.
        lastRecognitionFailed = false
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                self.handleRecognitionResult(result: result, error: error)
            }
        }
    }

    // MARK: - Speech gate (Plan GU §5)

    /// A transition from the gate, on the main actor.
    private func handleGateOutput(_ output: WakeSpeechGate.Output) {
        guard isListening, appliedIdlePlan?.speechGate == true, !listenForStop else { return }
        switch output {
        case .open:
            guard recognitionTask == nil else { return }
            do {
                recognitionGeneration &+= 1
                try openRecognizer()
                if deliberatePause == .speechGateClosed { deliberatePause = nil }
                gateOpens += 1
            } catch {
                PrivacyLog.wakeWord(.listenAttemptFailed, error: SafeErrorSummary(error))
                pauseForAudioDisruption()
                resumeListening()
                return
            }
        case .close:
            guard recognitionTask != nil, !wakeWordFired else { return }
            recognitionGeneration &+= 1
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            deliberatePause = .speechGateClosed
            gateCloses += 1
        case .giveUpGating:
            // A conversation nearby: stop gating and recognise continuously (restart-on-final, as
            // before the gate) for a while. The recognizer that is open stays open.
            PrivacyLog.audio(.wakeWord, .gateAbandoned)
            tapState.disableGate()
            gateRetryAfter = Date().addingTimeInterval(Self.gateRetryInterval)
        }
        reportGateCountsIfDue()
    }

    /// Gate opens and closes are logged as hourly counts, never per event.
    private func reportGateCountsIfDue() {
        guard Date().timeIntervalSince(lastGateReport) >= 3600 else { return }
        PrivacyLog.audio(.wakeWord, .gateOpened, count: gateOpens)
        PrivacyLog.audio(.wakeWord, .gateClosed, count: gateCloses)
        gateOpens = 0
        gateCloses = 0
        lastGateReport = Date()
    }

    private func createAndStartAudioEngine() throws {
        tapIsInstalled = false
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate format before installing tap — prevents crash on invalid Bluetooth route
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            audioEngine = nil
            PrivacyLog.audio(.wakeWord, .formatInvalid, detail: PrivacyToken("engineStart"),
                             hertz: Int(recordingFormat.sampleRate),
                             channels: Int(recordingFormat.channelCount))
            throw WakeWordError.configurationError("Audio input format invalid — is Bluetooth connected?")
        }

        PrivacyLog.audio(.wakeWord, .engineStarted, hertz: Int(recordingFormat.sampleRate),
                         channels: Int(recordingFormat.channelCount))

        // The tap runs on the Core Audio render thread. It must NOT touch any @MainActor state —
        // it reads everything it needs from the lock-guarded `tapState` box (Plan BE).
        let tapState = self.tapState
        liveFrames.reset()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            tapState.dispatch(buffer)
            // Silence detection is nonisolated and does its own (batched) main-actor hop.
            self?.checkAudioLevel(buffer: buffer)
        }

        tapIsInstalled = true

        // Plan GU §2/P1: the engine **stops itself** when its input's sample rate or channel count
        // changes (built-in 48 kHz → hands-free 16 kHz is one). Nothing used to listen for that, so
        // a route flip mid-listen left a stopped engine that every check still believed in.
        if let observer = engineConfigObserver { NotificationCenter.default.removeObserver(observer) }
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine else { return }
                self.handleEngineConfigurationChange(engine)
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// The engine reconfigured itself (a route or format change). Rebuild it on the live format,
    /// keeping whatever was running: the recognizer if it was listening, the consumers either way.
    /// A turn's hand-off rebuilds the engine itself and is left to it.
    private func handleEngineConfigurationChange(_ engine: AVAudioEngine) {
        guard engine === audioEngine, !handOffInProgress else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        PrivacyLog.audio(.wakeWord, .engineConfigurationChanged,
                         detail: PrivacyToken(engine.isRunning ? "running" : "stopped"),
                         hertz: Int(format.sampleRate), channels: Int(format.channelCount))
        guard !engine.isRunning else { return }
        let hadRecognizer = recognitionTask != nil || startedBehindClosedGate && isListening
        do {
            if hadRecognizer {
                // The recognizer's request was fed by the old tap; a fresh one on the new format.
                cleanupAudioGraph()
                try startRecognition()
            } else {
                stopEngineKeepingRecognition()
                try createAndStartAudioEngine()
            }
            PrivacyLog.audio(.wakeWord, .engineRebuilt, hertz: Int(format.sampleRate),
                             channels: Int(format.channelCount))
        } catch {
            PrivacyLog.audio(.wakeWord, .engineRestartFailed, error: SafeErrorSummary(error))
            pauseForAudioDisruption()
            resumeListening()
        }
    }

    // MARK: - Silence Detection (Glasses in Case)

    /// Silence counting runs entirely on the audio thread (Plan BE); we hop to the main actor only
    /// on a state *transition* (silence entered / audio resumed) instead of spawning a MainActor
    /// Task per buffer (~10-15/sec, forever).
    private let silenceTracker = SilenceTracker()

    private nonisolated func checkAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Calculate RMS of the buffer
        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<frames {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))
        liveFrames.observe(rms: rms)

        switch silenceTracker.observe(rms: rms, threshold: silenceRMSThreshold, limit: silenceBufferThreshold) {
        case .none:
            break
        case .enteredSilence(let count):
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Plan GU §1: silence means "glasses in the case" only when the idle mic *is* the
                // glasses'. On the phone's mic it means a quiet room — and stopping the listener
                // for it would turn the wake word off whenever the room went quiet.
                guard self.appliedIdlePlan?.silenceMeansGlassesIdle ?? true else { return }
                self.silenceReported = true
                self.pausedForSilence = true
                PrivacyLog.wakeWord(.sustainedSilence, count: count)
                self.onSilenceDetected?()
            }
        case .resumed:
            Task { @MainActor [weak self] in
                guard let self else { return }
                PrivacyLog.wakeWord(.audioResumed)
                self.silenceReported = false
                self.pausedForSilence = false
                self.onAudioResumed?()
            }
        }
    }

    private func generalBargeInEnabled() -> Bool {
        generalBargeInEnabledOverride?() ?? Config.speechBargeInEnabled
    }

    private func assistantSpeech() -> BargeInPolicy.AssistantSpeech {
        assistantSpeechContext?() ?? .speaking(text: nil)
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        // An intentional cancel (ensureAudioEngineRunning pausing the wake-word task so
        // the buffer forwarder can feed TranscriptionService) surfaces here as an error.
        // Consume it once and don't auto-restart — otherwise a second recognizer spins up
        // and fights the transcription task, making tap-to-talk stop the instant it starts.
        if suppressAutoRestart {
            suppressAutoRestart = false
            return
        }
        lastRecognitionFailed = error != nil
        if let error = error {
            let nsError = error as NSError
            // Code 1110 = "No speech detected" — just restart
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                restartRecognition()
                return
            }
            PrivacyLog.wakeWord(.recognitionFailed, error: SafeErrorSummary(error))
            restartRecognition()
            return
        }

        guard let result = result else { return }
        let transcript = result.bestTranscription.formattedString.lowercased()
        debugTranscript = transcript

        // During TTS playback: what this transcript is allowed to do is `BargeInPolicy`'s call
        // (Plan FE P3). The word-count test that used to live here is now a documented noise floor
        // inside it, and the wearer can switch general speech-triggered interruption off without
        // losing the explicit stop phrase or the wake phrase.
        if listenForStop && !stopFired {
            switch BargeInPolicy.decide(transcript: transcript,
                                        isStopPhrase: containsStopPhrase(transcript),
                                        matchedWakePhrase: matchedWakePhrase(transcript),
                                        generalBargeInEnabled: generalBargeInEnabled(),
                                        assistantSpeech: assistantSpeech()) {
            case .stop:
                PrivacyLog.wakeWord(.stopCommand)
                stopFired = true
                pauseRecognition()
                onStopCommand?()
                return

            case .newConversation(let matched):
                PrivacyLog.wakeWord(.bargeIn, trigger: .wakePhrase)
                stopFired = true
                wakeWordFired = true
                pauseRecognition()
                onStopCommand?()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self.onWakeWordDetected?(matched)
                }
                return

            case .interrupt(let text):
                PrivacyLog.wakeWord(.bargeIn, trigger: .voiceActivity,
                                    count: text.split(whereSeparator: { $0.isWhitespace }).count)
                stopFired = true
                pauseRecognition()
                onBargeIn?(text)
                return

            case .ignore:
                break
            }
        }

        // Normal wake word detection (not during TTS)
        if let matched = matchedWakePhrase(transcript) {
            if !wakeWordFired {
                // Normal wake word detection (not during TTS)
                tapState.noteWakeMatched()
                PrivacyLog.wakeWord(.detected)
                wakeWordFired = true
                handleWakeWordDetected(matchedPhrase: matched)
            }
        }

        if result.isFinal { restartRecognition() }
    }

    /// Whole-token stop matching, shared with `VoiceCommandParser` (see `PhraseMatcher`).
    ///
    /// This used to be `transcript.contains(phrase)`, which fired on any word *containing* "stop":
    /// "it stopped working yesterday", "nonstop", "stops" and "unstoppable" all cut the assistant
    /// off — and worse, routed the utterance to `onStopCommand` (discarded) rather than `onBargeIn`
    /// (answered), so the user's sentence vanished instead of being replied to.
    ///
    /// `.anywhere` here, unlike the parser's `.utteranceEdge`: this list is only "stop" plus persona
    /// variants, and a missed stop means the user cannot interrupt.
    private func containsStopPhrase(_ transcript: String) -> Bool {
        PhraseMatcher.containsStopPhrase(transcript, phrases: allStopPhrases, position: .anywhere)
    }

    /// Every phrase that may wake the app: each enabled persona's, its alternatives (reporting the
    /// persona's primary phrase), and the global wake phrase.
    private var wakeCandidates: [WakePhraseMatcher.Candidate] {
        Config.enabledPersonas.flatMap { persona in
            [WakePhraseMatcher.Candidate(phrase: persona.wakePhrase)] +
            persona.alternativeWakePhrases.map {
                WakePhraseMatcher.Candidate(phrase: $0, primary: persona.wakePhrase)
            }
        } + [WakePhraseMatcher.Candidate(phrase: wakePhrase)]
        + alternativePhrases.map { WakePhraseMatcher.Candidate(phrase: $0, primary: wakePhrase) }
    }

    /// Check all persona wake phrases and return the matched one, or nil.
    ///
    /// Whole-token matching first, then a length-scaled fuzzy pass — see `WakePhraseMatcher` for
    /// why a single-word phrase gets no fuzzy allowance at all.
    private func matchedWakePhrase(_ transcript: String) -> String? {
        let candidates = wakeCandidates
        let tokens = PhraseMatcher.tokenize(transcript)
        guard !tokens.isEmpty else { return nil }

        for candidate in candidates where !candidate.phrase.isEmpty {
            if PhraseMatcher.contains(candidate.phrase, in: tokens) { return candidate.primary }
        }
        if let fuzzy = WakePhraseMatcher.fuzzyMatch(tokens: tokens, candidates: candidates) {
            PrivacyLog.wakeWord(.fuzzyDetected, distance: fuzzy.distance)
            return fuzzy.primary
        }
        return nil
    }

    private func handleWakeWordDetected(matchedPhrase: String) {
        lastDetectionTime = Date()
        pauseRecognition()
        onWakeWordDetected?(matchedPhrase)
    }

    /// Stop the recognition task without killing the audio engine
    private func pauseRecognition() {
        startGeneration.recordPause()
        recognitionGeneration &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        setListening(false)
    }

    /// Public version of pauseRecognition — stops recognition but keeps engine alive
    func pauseRecognitionPublic() {
        pauseRecognition()
    }

    /// Whether the live audio route still carries a Bluetooth mic or speaker.
    ///
    /// An observation, taken now — what the route-change handler uses to tell a lost Bluetooth
    /// device from a mic port that merely dropped out while the glasses kept playing.
    func hasBluetoothAudioRoute() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        return MicRoutePolicy.containsBluetoothMic(route.inputs.map(\.portType)) ||
               MicRoutePolicy.containsBluetoothOutput(route.outputs.map(\.portType))
    }

    /// Re-configure audio session if Bluetooth route changed (glasses disconnect/reconnect)
    /// Call this before startListening() when recovering from background or route change
    func reconfigureAudioSessionIfNeeded() async {
        let route = AVAudioSession.sharedInstance().currentRoute
        let hasBluetooth = MicRoutePolicy.containsBluetoothMic(route.inputs.map(\.portType)) ||
                           MicRoutePolicy.containsBluetoothOutput(route.outputs.map(\.portType))

        // Check if current engine format is valid
        if let engine = audioEngine {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate == 0 || format.channelCount == 0 {
                PrivacyLog.audio(.wakeWord, .formatInvalid, detail: PrivacyToken("preflight"))
                cleanupAudioEngine()
            }
        }

        PrivacyLog.audio(.wakeWord, .routeChanged,
                         route: PrivacyToken(hasBluetooth ? "bluetooth" : "builtIn"),
                         detail: PrivacyToken("reconfigure"))

        // Force reconfigure to pick up new route
        audioSessionConfigured = false
        await configureAudioSession()
    }

    private func restartRecognition() {
        guard isListening else { return }
        Task {
            // Pause recognition (keep engine alive) and restart just the task
            pauseRecognition()
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await autoStartListening()
        }
    }

    private func requestPermissions() async -> Bool {
        let micPermission = await AVAudioApplication.requestRecordPermission()
        guard micPermission else { return false }

        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return speechPermission
    }
}

enum WakeWordError: LocalizedError {
    case microphonePermissionDenied
    case configurationError(String)
    case activationError(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone permission required"
        case .configurationError(let msg): return "Configuration error: \(msg)"
        case .activationError(let msg): return "Activation error: \(msg)"
        }
    }
}

/// Audio-thread silence accumulator (Plan BE). Counts consecutive low-RMS buffers and reports only
/// the two transitions the main actor cares about, so silence detection costs one locked increment
/// per buffer instead of a spawned MainActor Task per buffer.
final class SilenceTracker: @unchecked Sendable {
    enum Transition: Equatable { case none, enteredSilence(count: Int), resumed }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State { var count = 0; var reported = false }

    func observe(rms: Float, threshold: Float, limit: Int) -> Transition {
        lock.withLock { state in
            if rms < threshold {
                state.count += 1
                if state.count >= limit && !state.reported {
                    state.reported = true
                    return .enteredSilence(count: state.count)
                }
                return .none
            } else {
                let wasReported = state.reported
                state.reported = false
                state.count = 0
                return wasReported ? .resumed : .none
            }
        }
    }

    /// Reset when listening restarts so a fresh session starts from silence-clear.
    func reset() { lock.withLock { $0 = State() } }
}

/// Lock-guarded box the audio-render thread reads from the wake-word tap (Plan BE).
///
/// The tap runs on the Core Audio render thread and must never touch `@MainActor` state. The main
/// actor publishes the current recognition request and forwarder set into this box under the lock;
/// the tap reads a consistent snapshot under the same lock and never sees a torn dictionary or a
/// half-torn-down request. `SFSpeechAudioBufferRecognitionRequest.append` is itself thread-safe;
/// what wasn't safe was the concurrent mutation of the *references* the old tap dereferenced.
final class WakeTapState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    /// Plan GU §5 — the speech gate's render-thread half: scorer, gate and pre-roll, mutated in
    /// place under the lock (never copied out — the pre-roll's storage must not reallocate on the
    /// render thread).
    private struct GateState {
        var router: GatedTapRouter
        var scorer: EnergySpeechScorer
        var gate: WakeSpeechGate
        let format: AVAudioFormat
        let onOutput: @Sendable (WakeSpeechGate.Output) -> Void
    }

    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var forwarders: [@Sendable (AVAudioPCMBuffer) -> Void] = []
        var gate: GateState?
    }

    private struct Snapshot {
        let request: SFSpeechAudioBufferRecognitionRequest?
        let forwarders: [@Sendable (AVAudioPCMBuffer) -> Void]
        let output: WakeSpeechGate.Output?
        let onOutput: (@Sendable (WakeSpeechGate.Output) -> Void)?
    }

    /// Publish the recognizer's request. With the gate in use, attaching a request replays the
    /// pre-roll into it first and switches to live in the same locked step — so no frame is lost
    /// between the two and none is delivered twice (`GatedTapRouter`). Clearing it goes back to
    /// buffering.
    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { state in
            if let request, state.gate != nil {
                if state.gate?.router.attached == false, let held = state.gate?.router.attach(),
                   let format = state.gate?.format,
                   let replay = Self.makeBuffer(held.samples, format: format) {
                    request.append(replay)
                }
            } else if request == nil {
                state.gate?.router.detach()
            }
            state.request = request
        }
    }

    func setForwarders(_ forwarders: [String: @Sendable (AVAudioPCMBuffer) -> Void]) {
        let values = Array(forwarders.values)
        lock.withLock { $0.forwarders = values }
    }

    /// Start gating on `format`. A request already attached stays live.
    func enableGate(format: AVAudioFormat, strict: Bool,
                    onOutput: @escaping @Sendable (WakeSpeechGate.Output) -> Void) {
        let preRoll = PreRollBuffer(seconds: WakeSpeechGate.preRollSeconds, sampleRate: format.sampleRate)
        lock.withLock { state in
            state.gate = GateState(router: GatedTapRouter(preRoll: preRoll),
                                   scorer: EnergySpeechScorer(thresholds: strict ? .strict : .standard),
                                   gate: WakeSpeechGate(strict: strict),
                                   format: format, onOutput: onOutput)
            if state.request != nil { _ = state.gate?.router.attach() }
        }
    }

    func disableGate() {
        lock.withLock { $0.gate = nil }
    }

    /// A wake phrase matched: the gate must not close under the turn that follows.
    func noteWakeMatched() {
        lock.withLock { $0.gate?.gate.noteWakeMatched() }
    }

    /// Called from the audio thread: score for the gate, append to the recognizer and fan out to
    /// consumers, all from a single locked snapshot.
    func dispatch(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        let snapshot: Snapshot = lock.withLock { state in
            var output: WakeSpeechGate.Output?
            if state.gate != nil, let channels = buffer.floatChannelData, buffer.frameLength > 0 {
                let mono = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
                let score = state.gate?.scorer.score(mono, sampleRate: buffer.format.sampleRate) ?? 0
                output = state.gate?.gate.observe(score: score, at: now)
                _ = state.gate?.router.route(mono)
            }
            return Snapshot(request: state.request, forwarders: state.forwarders,
                            output: output, onOutput: state.gate?.onOutput)
        }
        snapshot.request?.append(buffer)
        for handler in snapshot.forwarders { handler(buffer) }
        if let output = snapshot.output { snapshot.onOutput?(output) }
    }

    /// The pre-roll as one buffer in the tap's format (channel 0 copied to every channel).
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(from: source.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}

/// Plan GU §2 — consecutive live buffers on the current engine, counted on the render thread for
/// the turn hand-off's "frames non-silent" check.
final class LiveFrameCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    func observe(rms: Float) {
        let live = TurnMicHandoff.isLiveFrame(rms: rms)
        lock.withLock { $0 = live ? $0 + 1 : 0 }
    }

    func reset() { lock.withLock { $0 = 0 } }

    var consecutive: Int { lock.withLock { $0 } }
}


// BS P2: the broadcast's mic source is the same shared tap the video recorder and
// captions ride — the consumer API already matches; this just names the seam.
extension WakeWordService: BroadcastAudioProviding {}
