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
    private var sessionLease: AudioSessionLease?
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
        // Omitting mixWithOthers/duckOthers causes iOS to interrupt (pause) other audio apps
        let options = MicRoutePolicy.categoryOptions(for: Config.micRoute, mixWithOthers: false)
        // .default (NOT .measurement): .measurement disables system audio processing/gain,
        // which makes TTS playback extremely quiet on the iPhone speaker. The wake-word /
        // command capture works fine in .default (see resumeOtherAudio, which already does this).
        // BJ PR2: the blocking setCategory→setActive runs off-main through the coordinator's
        // `reconfigure` (no deactivate-first, no fallback — the hand-tuned options are preserved).
        try? await AudioSessionCoordinator.shared.reconfigure(
            category: .playAndRecord, mode: .default, options: options)
        // Cheap, non-blocking route hints stay inline (they are not the TPC hang source — the
        // blocking activation above is what moved off-main).
        let session = AVAudioSession.sharedInstance()
        let onBluetooth = session.currentRoute.outputs.contains {
            [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType)
        }
        if !onBluetooth { try? session.overrideOutputAudioPort(.speaker) }
        preferConfiguredMicIfAvailable(session)
        PrivacyLog.audio(.wakeWord, .otherAudioPaused,
                         route: PrivacyToken(session.currentRoute.outputs.first?.portType.rawValue ?? "none"))
    }

    /// Restore other audio (podcasts, music) after active listening ends.
    /// The .notifyOthersOnDeactivation flag tells paused apps to resume.
    func resumeOtherAudio() async {
        guard !carPlayMode else { return }
        guard pauseHoldCount > 0 else { return }
        // BJ PR2: decrement synchronously before any await (see pauseOtherAudio).
        pauseHoldCount -= 1
        guard pauseHoldCount == 0 else {
            PrivacyLog.audio(.wakeWord, .otherAudioHeld, count: pauseHoldCount)
            return
        }
        let options = MicRoutePolicy.categoryOptions(for: Config.micRoute, mixWithOthers: true)
        // .default (not .measurement) so concurrent music/podcasts keep playing cleanly
        // while the wake-word listener runs — .measurement disables system audio
        // processing and fights other audio even with .mixWithOthers.
        // notifyOthersOnDeactivation tells paused apps (Music, Podcasts) they can resume.
        try? await AudioSessionCoordinator.shared.reconfigure(
            category: .playAndRecord, mode: .default, options: options,
            activeOptions: .notifyOthersOnDeactivation)
        PrivacyLog.audio(.wakeWord, .otherAudioResumed)
    }

    /// Force release of any held pauses — used when listening is toggled off entirely.
    func forceResumeOtherAudio() async {
        guard pauseHoldCount > 0 else { return }
        pauseHoldCount = 1  // resumeOtherAudio will decrement to 0 and restore
        await resumeOtherAudio()
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
    private func preferConfiguredMicIfAvailable(_ session: AVAudioSession) {
        let route = Config.micRoute
        guard route != .phone, let inputs = session.availableInputs else { return }
        let ports = inputs.map { (name: $0.portName, type: $0.portType) }
        guard let index = MicRoutePolicy.preferredInputIndex(for: route, ports: ports) else {
            if route == .headset {
                PrivacyLog.audio(.wakeWord, .noMatchingInput, route: PrivacyToken(route.rawValue))
            }
            return
        }
        let input = inputs[index]
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

    /// Configure the shared audio session once — call before first use.
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
        sessionLease = AudioSessionCoordinator.shared.assumeOwnership(.wakeWord)

        let category: AVAudioSession.Category = .playAndRecord
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        if carPlayMode {
            // In CarPlay mode, only activate recording when explicitly requested (voice control
            // template showing). Otherwise use playback-only to avoid disrupting car audio.
            mode = .voiceChat
            options = [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        } else {
            // .default (not .measurement) so other audio coexists cleanly with the always-on
            // listener — see resumeOtherAudio for the same rationale.
            mode = .default
            options = MicRoutePolicy.categoryOptions(for: Config.micRoute, mixWithOthers: true)
        }

        do {
            try await AudioSessionCoordinator.shared.reconfigure(
                category: category, mode: mode, options: options,
                activeOptions: .notifyOthersOnDeactivation)
        } catch {
            PrivacyLog.audio(.wakeWord, .sessionConfigureFailed, error: SafeErrorSummary(error))
            return
        }
        audioSessionConfigured = true

        let audioSession = AVAudioSession.sharedInstance()
        if carPlayMode {
            PrivacyLog.audio(.wakeWord, .modeSelected, detail: PrivacyToken("carPlayVoiceChat"))
        } else {
            preferConfiguredMicIfAvailable(audioSession)
            PrivacyLog.audio(.wakeWord, .modeSelected, route: PrivacyToken(Config.micRoute.rawValue))
        }

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
            let owner = AudioSessionCoordinator.shared.currentOwner
            guard owner == nil || owner == .wakeWord else {
                PrivacyLog.audio(.wakeWord, .interruptionEndedNotResuming,
                                 owner: PrivacyToken(owner?.rawValue ?? "unknown"))
                return
            }
            // Only restart if Bluetooth (glasses) route is available
            let route = AVAudioSession.sharedInstance().currentRoute
            let hasBluetooth = MicRoutePolicy.containsBluetoothMic(route.inputs.map(\.portType))
            guard shouldAutoRestart() else {
                PrivacyLog.audio(.wakeWord, .interruptionEndedNotResuming,
                                 detail: PrivacyToken("listeningDisabled"))
                return
            }
            if hasBluetooth {
                PrivacyLog.audio(.wakeWord, .interruptionEnded,
                                 detail: PrivacyToken("bluetoothActive"))
                // BJ PR2: reactivate off-main through the coordinator (was a main-thread setActive),
                // then restart — one Task so the reactivate precedes the listener start.
                Task {
                    await AudioSessionCoordinator.shared.ensureActiveOffMain()
                    try? await autoStartListening()
                }
            } else {
                PrivacyLog.audio(.wakeWord, .interruptionEndedNotResuming,
                                 detail: PrivacyToken("noBluetooth"))
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

        switch reason {
        case .oldDeviceUnavailable:
            // Bluetooth device disconnected — kill the engine so it's recreated fresh.
            // Judged on inputs *and* outputs: when playback starts the mic port can drop out of
            // the route while the glasses are still the speaker, and that is not a disconnect.
            let lostBluetooth = !hasBluetoothAudioRoute()
            PrivacyLog.audio(.wakeWord, .deviceDisconnected,
                             detail: PrivacyToken(lostBluetooth ? "bluetoothLost" : "bluetoothRetained"))
            pauseForAudioDisruption()
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
                guard shouldAutoRestart() else {
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
                deliberatePause = nil
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
            AudioSessionCoordinator.shared.release(lease)
            PrivacyLog.audio(.wakeWord, .sessionReleased)
        } else {
            // BJ PR2: rare no-lease fallback — deactivate off-main via the coordinator too.
            await AudioSessionCoordinator.shared.deactivateOffMain()
            PrivacyLog.audio(.wakeWord, .sessionDeactivated)
        }
    }

    /// Bring the listener back after a pause the service took itself.
    ///
    /// No `guard !isListening` any more — that guard is the defect. The health decision answers
    /// the same question from the graph, so a stale flag can neither suppress a needed restart nor
    /// hide a listener that is genuinely already up.
    func resumeListening() {
        guard shouldAutoRestart() else {
            PrivacyLog.wakeWord(.listenerSkippedDisabled)
            return
        }
        Task { try? await autoStartListening() }
    }

    // MARK: - Shared Audio Engine (for TranscriptionService)

    /// Ensure the shared audio engine is running (creates one if needed).
    /// Call this before `TranscriptionService.startRecording()` to guarantee
    /// the buffer-forwarding path is alive — e.g. after TTS playback which
    /// may have interrupted or stopped the engine.
    func ensureAudioEngineRunning() async throws {
        if let engine = audioEngine, engine.isRunning { return }
        // Engine is nil or stopped — restart it (without starting recognition)
        PrivacyLog.audio(.wakeWord, .engineRestarted, detail: PrivacyToken("sharedUse"))
        try await startListening()
        pauseRecognitionForSharedEngine()
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
        if let engine = audioEngine, engine.isRunning { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone permission denied"
            throw WakeWordError.microphonePermissionDenied
        }

        await configureAudioSession()
        if let oldEngine = audioEngine {
            oldEngine.stop()
            oldEngine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
            audioEngine = nil
        }
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
    }

    /// Remove a named audio buffer consumer.
    func removeAudioBufferConsumer(id: String) {
        audioBufferForwarders.removeValue(forKey: id)
        tapState.setForwarders(audioBufferForwarders)
    }

    private func cleanupAudioEngine() {
        // Obsolete recognition callbacks die with the task they belonged to.
        recognitionGeneration &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        tapIsInstalled = false
        audioEngine = nil
    }

    private func startRecognition() throws {
        // A fresh recognizer consumes no older cancel: `suppressAutoRestart` belongs to the task
        // being replaced, and the generation tag below is what actually silences its callbacks.
        suppressAutoRestart = false
        // Cancel any existing recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw WakeWordError.configurationError("Unable to create recognition request")
        }

        recognitionRequest.shouldReportPartialResults = true
        // On-device wake-word spotting (Plan BE): the always-on listener no longer streams mic
        // audio to Apple's servers 24/7 — the single largest steady battery/data drain. Short-phrase
        // spotting works well on-device (contextualStrings still apply); real queries keep server
        // recognition in TranscriptionService. Falls back to server if the locale can't do on-device.
        let wantsOnDevice = Config.onDeviceWakeWordEnabled
        let canDoOnDevice = speechRecognizer?.supportsOnDeviceRecognition ?? false
        recognitionRequest.requiresOnDeviceRecognition = wantsOnDevice && canDoOnDevice
        if wantsOnDevice && !canDoOnDevice {
            PrivacyLog.wakeWord(.onDeviceUnavailable)
        }
        recognitionRequest.taskHint = .search  // Short phrase detection
        // Boost recognition of all persona wake phrases
        let personaPhrases = Config.allActiveWakePhrases
        let contextPhrases = personaPhrases.isEmpty ? [wakePhrase] : personaPhrases
        recognitionRequest.contextualStrings = contextPhrases
        // The contextual-boost list *is* the wake phrases, and the persona names beside them are
        // what the wearer called their assistants — often a real name. Only how many there are.
        PrivacyLog.wakeWord(.contextConfigured, count: contextPhrases.count)

        // Reuse existing engine if it's already running AND has a valid format
        if let engine = audioEngine, engine.isRunning {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0 && format.channelCount > 0 {
                PrivacyLog.audio(.wakeWord, .engineReused)
            } else {
                // Engine is running but format is invalid (Bluetooth route lost)
                PrivacyLog.audio(.wakeWord, .formatInvalid, detail: PrivacyToken("running"),
                                 hertz: Int(format.sampleRate), channels: Int(format.channelCount))
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                tapIsInstalled = false
                audioEngine = nil
                // Fall through to create a new engine below
                try createAndStartAudioEngine()
            }
        } else {
            // Clean up old engine if it exists but isn't running
            if let oldEngine = audioEngine {
                oldEngine.inputNode.removeTap(onBus: 0)
                tapIsInstalled = false
                audioEngine = nil
            }
            try createAndStartAudioEngine()
        }

        // Tag the handler with the generation it was created under. A task that has been
        // cancelled or replaced still delivers a final callback, and that callback used to be
        // indistinguishable from the live one — it could restart, pause or barge in on its own
        // successor. An older generation is now simply dropped.
        lastRecognitionFailed = false
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                self.handleRecognitionResult(result: result, error: error)
            }
        }
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            tapState.dispatch(buffer)
            // Silence detection is nonisolated and does its own (batched) main-actor hop.
            self?.checkAudioLevel(buffer: buffer)
        }

        tapIsInstalled = true

        engine.prepare()
        try engine.start()
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

        switch silenceTracker.observe(rms: rms, threshold: silenceRMSThreshold, limit: silenceBufferThreshold) {
        case .none:
            break
        case .enteredSilence(let count):
            Task { @MainActor [weak self] in
                guard let self else { return }
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
    /// An observation, taken now. `AppState.isConnected` is a cached flag that only clears on a
    /// Bluetooth event, so a handler that latched it false leaves it false; anything deciding
    /// whether it may open the mic should ask the route as well as the flag.
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

    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var forwarders: [@Sendable (AVAudioPCMBuffer) -> Void] = []
    }

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { $0.request = request }
    }

    func setForwarders(_ forwarders: [String: @Sendable (AVAudioPCMBuffer) -> Void]) {
        let values = Array(forwarders.values)
        lock.withLock { $0.forwarders = values }
    }

    /// Called from the audio thread: append to the recognizer and fan out to consumers, all from a
    /// single locked snapshot.
    func dispatch(_ buffer: AVAudioPCMBuffer) {
        let snapshot = lock.withLock { $0 }
        snapshot.request?.append(buffer)
        for handler in snapshot.forwarders { handler(buffer) }
    }
}


// BS P2: the broadcast's mic source is the same shared tap the video recorder and
// captions ride — the consumer API already matches; this just names the seam.
extension WakeWordService: BroadcastAudioProviding {}
