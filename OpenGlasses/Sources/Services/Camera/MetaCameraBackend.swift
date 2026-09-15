import AVFoundation
import Combine
import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// Plan CQ P1 — the Meta/DAT camera, extracted out of `CameraService` behind
/// `GlassesCameraBackend`.
///
/// This is a **pure extraction**: the DAT session and stream lifecycle, the permission flow, the
/// stall detection and tiered recovery, the idle teardown and the retry loops are the same code
/// that shipped, comments and all. The only changes are structural — state that `CameraService`
/// published is now emitted on `events` for the coordinator to publish, and callbacks became
/// cases of `CameraBackendEvent`.
///
/// Uses a persistent `DeviceSession` + `Stream` pair for both photo capture and video streaming,
/// following Meta's official sample app pattern (DAT SDK 0.7+).
@MainActor
final class MetaCameraBackend: GlassesCameraBackend {

    let capabilities = CameraCapabilities.meta
    let events = PassthroughSubject<CameraBackendEvent, Never>()

    /// Lazily initialized after Wearables.configure() has been called.
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var deviceSession: DeviceSession?
    /// DAT 0.9.0: the `Camera` owns the camera hardware resource; the `Stream` hangs off it.
    /// Detaching the capability is `camera.stop()` (cascades to the stream) — `stream.stop()`
    /// alone only pauses streaming and keeps the capability attached for cheap restarts.
    private var cameraCapability: MWDATCamera.Camera?
    private var streamSession: MWDATCamera.Stream?
    /// DAT 0.9.0 `ListenerTokenBag`: the four per-stream listeners (state, video frame,
    /// photo, error) live and die together, so they're cancelled as one in teardown.
    private let streamListenerBag = ListenerTokenBag()
    private var photoContinuation: CheckedContinuation<Data, Error>?

    /// Whether camera permission has been granted (cached to avoid re-checking).
    var permissionGranted = false

    /// Mirrors of the state the coordinator publishes. Held here too because the recovery,
    /// teardown and fallback logic below branches on them.
    private var isStreaming = false
    private var isCaptureInProgress = false
    private var latestFrame: UIImage?

    // MARK: - HEVC Decoder Stall Detection
    /// Timestamp of the last successfully decoded video frame.
    private var lastFrameTime: Date = .distantPast
    /// EO P1: the decoder and the two liveness clocks, off the main actor. One instance for the
    /// life of the backend — a stream teardown resets it rather than replacing it, so the
    /// listener closure can capture it once.
    private let framePipeline = GlassesFramePipeline()
    /// Stall detection timer — fires if no frame arrives for 1.5 seconds.
    private var stallDetectionTask: Task<Void, Never>?
    /// Whether we're currently recovering from a stall (prevents re-entrant recovery).
    private var isRecoveringFromStall = false
    /// Number of consecutive stall recoveries (for diagnostics).
    private var stallRecoveryCount = 0
    /// BR P2: consecutive FAILED recoveries — drives the rebuild-stream-vs-reset-session
    /// tiering in `StreamRecoveryPolicy`. Reset on any successful recovery.
    private var consecutiveRecoveryFailures = 0

    /// Plan FD P0 — why pictures are not flowing, as last reported to the coordinator.
    ///
    /// Held so `report(waitReason:)` can emit on *change*: the sources below fire at frame rate and
    /// at the stall detector's half-second tick, and a readiness snapshot rebuilt thirty times a
    /// second would make `@Published` churn out of an answer that did not move.
    private var currentWaitReason: CameraWaitReason?

    /// Tell the coordinator why pictures are not flowing — or that there is no longer a reason.
    ///
    /// Every caller passes something the backend *watched happen*: a state the SDK reported, or a
    /// verdict from the decoder's liveness clocks. Nothing infers a cause from a quiet moment.
    private func report(waitReason: CameraWaitReason?) {
        guard currentWaitReason != waitReason else { return }
        currentWaitReason = waitReason
        events.send(.waitReason(waitReason))
    }
    /// True while `warmUpStream()` owns the stream. A cold start churns through `.stopped` for
    /// 15-18 s on its way up (`StreamRecoveryPolicy.observedColdStart`), and warmup already has
    /// its own nudge-and-rebuild ladder — a reconnect ladder layered on top would fight it for
    /// the camera capability and report a failure warmup is about to report itself.
    private var isWarmingUp = false

    /// Plan EW — which start the stream is currently obeying. A stop landing inside the cold
    /// start used to be lost to `stopStreaming()`'s `isStreaming` guard, and the start still
    /// climbing then claimed the stream anyway. See `StreamStartGeneration`.
    private var startGeneration = StreamStartGeneration()

    /// Plan FD P1 — which set of stream listeners is current. `ListenerTokenBag.cancelAll()` is
    /// async, so a callback from the stream we just tore down can still land on the one that
    /// replaced it. See `StreamListenerGeneration`.
    private var listenerGeneration = StreamListenerGeneration()

    /// Plan FD P1 — serialises the transitions that create or destroy the process-wide camera
    /// capability. Taken by `ensureSession()`, `teardownStreamOnly()` and `resetSession()` and by
    /// nothing else; never by a stop. See `CameraTransitionLock`.
    private let transitionLock = CameraTransitionLock()

    /// When the SDK most recently put the stream into `.paused`, or nil when it is not paused.
    ///
    /// Plan FD P1: a pause is waited out rather than started out of, so a *start* that runs into
    /// one needs to know how long it has stood — see `StreamPausePolicy.pauseHoldGrace`.
    private var pausedSince: Date?

    /// The pending reconnect after a wanted stream dropped to `.stopped`, and how many rungs of
    /// `StreamRecoveryPolicy.reconnectDelay` we have climbed. Both reset the moment frames flow.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// True from the drop until the stream is back or the budget is spent — so the notice is
    /// said once rather than once per rung, and so a `.streaming` that ends a *reconnect* can be
    /// told from the one that ends a normal start.
    private var isReconnecting = false

    /// BR P2: listener on the DeviceSession's error stream (update-required and terminal
    /// device errors surface here, not on the camera Stream's errorPublisher).
    private var sessionErrorTask: Task<Void, Never>?
    /// The most recent error the DeviceSession's error stream delivered, kept only for the
    /// duration of one `ensureSession()` attempt.
    ///
    /// The watcher used to log each session error and then drop it unless
    /// `DATCompatibilityMessage` recognised it, so a session that died 120 ms into startup was
    /// still waited on for the full grace window and then reported as the generic
    /// `streamNotReady` — four attempts, ~21 s, and a user-facing reason that named nothing.
    /// Holding the error lets the start wait fail fast *with the SDK's own reason*.
    private var lastSessionError: Error?
    /// The most recent stream error seen while waiting for `.streaming`. Cleared at the top of
    /// each warmup wait, so it only ever describes the attempt in progress.
    private var lastStreamError: StreamError?

    /// BR P2: actionable compatibility copy ("update the Meta AI app…") when the DAT layer
    /// reports an update requirement. Nil when compatible. Read by the retry loop to stop
    /// churning on a refusal that can never succeed, and emitted for AppState to announce once.
    private var compatibilityNotice: String? {
        didSet { events.send(.compatibilityNotice(compatibilityNotice)) }
    }

    /// Glasses are usable for the camera only once fully registered (state 3). An unconfigured
    /// SDK is indistinguishable from unregistered glasses as far as this decision goes, and
    /// falls the same way — reporting not-ready rather than trapping on `Wearables.shared`.
    ///
    /// The short-circuit is load-bearing in both modes: reading `registrationState` on an
    /// unconfigured SDK is a `fatalError`, not a throw.
    func isReady(configuringIfNeeded: Bool) -> Bool {
        let configured = configuringIfNeeded
            ? WearablesBootstrap.ensureConfigured()
            : WearablesBootstrap.isConfigured
        return configured && Wearables.shared.registrationState.rawValue >= 3
    }

    private func debug(_ message: String) { events.send(.debug(message)) }

    /// Plan FD P1 — how much automatic work this backend currently has armed.
    ///
    /// "No automatic loop remains after a stop" is an assertion, and this is what makes it one
    /// rather than a hope. Counts the reconnect rung, the stall detector, the idle-teardown timer,
    /// a start still climbing, and a device transition in flight.
    ///
    /// Deliberately **not** counted: the device session's error watcher. It is a subscription to a
    /// session the app keeps warm on purpose after a capture or a stop, not work that will fire on
    /// its own; `tearDown()` is what ends it, and the audit row that covers it says so.
    var scheduledWorkCount: Int {
        var count = 0
        if reconnectTask != nil { count += 1 }
        if stallDetectionTask != nil { count += 1 }
        if idleTeardownTask != nil { count += 1 }
        if startGeneration.isStartPending { count += 1 }
        if transitionLock.isBusy { count += 1 }
        return count
    }

    // MARK: - Permission

    private func waitForRegistration(minState: Int, timeoutSeconds: Double) async -> Int {
        guard WearablesBootstrap.ensureConfigured() else { return 0 }
        let waitStart = ContinuousClock.now
        while true {
            let state = Wearables.shared.registrationState.rawValue
            events.send(.registrationProgress(state))
            if state >= minState { return state }
            if ContinuousClock.now - waitStart > .seconds(timeoutSeconds) { return state }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func ensurePermission() async throws {
        // No SDK, no glasses permission to grant. Throwing here (rather than touching
        // `Wearables.shared`, which traps when unconfigured) surfaces as the existing
        // "Meta SDK not registered" state.
        guard WearablesBootstrap.ensureConfigured() else { throw CameraError.sdkNotRegistered }
        // The cached flag is only a fast path PAST the iOS prompt + registration wait — the
        // Meta permission itself is re-verified live every time. Live-traced: the user revoked
        // the app in the Meta AI app mid-session, and the stale flag sailed straight past the
        // permission step instead of re-asking.
        if permissionGranted {
            if let status = try? await Wearables.shared.checkPermissionStatus(.camera),
               status == .granted {
                return
            }
            PrivacyLog.camera(.glasses, .permissionRevalidating)
            permissionGranted = false
        }

        let regState = Wearables.shared.registrationState
        PrivacyLog.camera(.glasses, .registrationState, count: regState.rawValue)
        events.send(.registrationProgress(regState.rawValue))

        // iOS Camera Permission
        let iosVideoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if iosVideoStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CameraError.permissionDenied }
        } else if iosVideoStatus == .denied || iosVideoStatus == .restricted {
            throw CameraError.permissionDenied
        }

        // Wait for full SDK registration
        let settledState = await waitForRegistration(minState: 3, timeoutSeconds: 15)
        if settledState < 3 {
            PrivacyLog.camera(.glasses, .notRegistered, count: settledState)
            throw CameraError.sdkNotRegistered
        }

        // Check/request Meta camera permission with retries
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                PrivacyLog.camera(.glasses, .permissionRetry,
                                  attempt: attempt + 1, ofAttempts: maxAttempts)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }

            do {
                let readyState = await waitForRegistration(minState: 3, timeoutSeconds: 10)
                if readyState < 3 { throw CameraError.sdkNotRegistered }

                let status = try await Wearables.shared.checkPermissionStatus(.camera)
                PrivacyLog.camera(.glasses, .permissionChecked,
                                  state: PrivacyToken(String(describing: status)))
                if status == .granted {
                    permissionGranted = true
                    return
                }

                let requestStatus = try await Wearables.shared.requestPermission(.camera)
                guard requestStatus == .granted else { throw CameraError.permissionDenied }
                permissionGranted = true
                return
            } catch {
                PrivacyLog.camera(.glasses, .permissionFailed,
                                  attempt: attempt + 1, ofAttempts: maxAttempts,
                                  error: SafeErrorSummary(error))

                if let nsError = error as NSError?, nsError.domain == "MWDATCore.PermissionError" {
                    let currentState = Wearables.shared.registrationState.rawValue
                    if currentState < 3 { throw CameraError.sdkNotRegistered }
                }
                if case .permissionDenied? = error as? CameraError { throw error }
                if attempt == maxAttempts - 1 { throw CameraError.sdkNotRegistered }
            }
        }
    }

    // MARK: - Persistent Session

    /// Last device id seen on the SDK's devices stream — lets the session bind to THE known
    /// device (`SpecificDeviceSelector`) instead of asking `AutoDeviceSelector` for any
    /// "eligible" device, which throws `noEligibleDevice` during the discovery/wake window.
    private var knownDeviceId: String?
    private var devicesListenerToken: Any?

    /// True while `startStreaming()`'s continuous mode owns the stream (live voice modes
    /// put the mic on the glasses concurrently) — drives the low-res contention floor in
    /// `ensureSession`. Discrete photo sessions leave it false.
    private var continuousStreamingIntent = false
    /// Resolution tier the current stream was actually built at (post-policy), so
    /// `startStreaming` can rebuild a photo-era low-res stream that would starve voice.
    private var activeStreamResolution: String?

    /// Ensure the persistent stream session exists. Creates it on first call.
    ///
    /// Plan FD P1: serialised. Four callers create or destroy the process-wide camera capability —
    /// a start's warm-up, a capture's session acquisition, the stall ladder and the reconnect
    /// ladder — and they used to be kept apart by booleans, which can only refuse, never wait. A
    /// second caller therefore either raced for the capability (`capabilityAlreadyActive`) or gave
    /// its work away. Now it queues, and finds the session already built when its turn comes.
    private func ensureSession() async throws {
        try await transitionLock.withLock { try await self.ensureSessionLocked() }
    }

    private func ensureSessionLocked() async throws {
        guard streamSession == nil else { return }

        // Fresh attempt, fresh verdict: an error from a previous attempt must not abort this one.
        lastSessionError = nil

        // First call: start tracking the devices list, and give the listener a beat to
        // deliver the current snapshot before we pick a selector.
        if devicesListenerToken == nil {
            devicesListenerToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
                Task { @MainActor in self?.knownDeviceId = deviceIds.first }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // DAT 0.7: DeviceSession owns the connection; Streams hang off it.
        //
        // Plan FD P1: a session that is still `.stopping` is awaited before it is dropped. This
        // used to look only for `.stopped`, so a session caught mid-teardown was *reused* — and a
        // new session created against a device whose previous one has not finished is exactly what
        // `sessionAlreadyExists` reports, the phantom the capture path already spends four
        // attempts waiting out.
        if let existing = deviceSession, existing.state == .stopped || existing.state == .stopping {
            await awaitSessionStopped(existing)
            deviceSession = nil
        }

        if deviceSession == nil {
            // Bind to the specific discovered device when we know it — field-proven more
            // reliable than AutoDeviceSelector for a device whose link is mid-wake.
            if let id = knownDeviceId {
                PrivacyLog.camera(.glasses, .sessionBound, device: PrivateIdentifier(id))
                deviceSession = try Wearables.shared.createSession(
                    deviceSelector: SpecificDeviceSelector(device: id))
            } else {
                deviceSession = try Wearables.shared.createSession(deviceSelector: deviceSelector)
            }
        }

        guard let deviceSession else { throw CameraError.captureFailed }

        // Watch the session's error stream BEFORE starting it — the reason a session dies
        // during startup (update-required refusal, device drop) arrives there, and attaching
        // after the state check meant every early stop was an unexplained "stream not ready".
        watchSessionErrors(on: deviceSession)

        if deviceSession.state != .started {
            do {
                try deviceSession.start()
            } catch {
                // BR P2: an update-required refusal must read as "go update", not a
                // generic failure.
                if let notice = DATCompatibilityMessage.message(for: error) {
                    compatibilityNotice = notice
                    debug(notice)
                }
                throw error
            }
            let deadline = ContinuousClock.now + .seconds(20)
            let stoppedGraceEnd = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if deviceSession.state == .started { break }
                // The SDK has already said why this session will not start. Waiting out the rest
                // of the window cannot change that, and the generic timeout that follows throws
                // away the only useful diagnostic — so stop here and carry the real error.
                if let sessionError = lastSessionError, deviceSession.state != .started {
                    PrivacyLog.camera(.glasses, .sessionStartAborted,
                                      state: PrivacyToken(String(describing: deviceSession.state)),
                                      error: SafeErrorSummary(sessionError))
                    throw sessionError
                }
                // .stopped inside the first moments can be the pre-transition resting state;
                // only treat it as terminal once the state machine has had time to move.
                if deviceSession.state == .stopped && ContinuousClock.now > stoppedGraceEnd { break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        guard deviceSession.state == .started else {
            PrivacyLog.camera(.glasses, .sessionNotStarted,
                              state: PrivacyToken(String(describing: deviceSession.state)))
            // Prefer the SDK's reason over "stream not ready" whenever there is one: the retry
            // loop's `sessionAttemptFailed` line and the error the caller finally sees should
            // both name what actually happened.
            if let sessionError = lastSessionError { throw sessionError }
            throw CameraError.streamNotReady
        }

        // Continuous streaming in the live voice modes runs alongside glasses-mic audio;
        // the policy floors "low" to "medium" there so video can't starve the voice link
        // off the shared Bluetooth radio (see `StreamConfigPolicy`).
        let effectiveResolution = StreamConfigPolicy.effectiveResolution(
            requested: Config.cameraResolution,
            concurrentGlassesVoice: continuousStreamingIntent
        )
        if effectiveResolution != Config.cameraResolution {
            PrivacyLog.camera(.glasses, .resolutionFloored,
                              resolution: PrivacyToken(effectiveResolution))
            debug("Camera: low-res floored to medium while voice is on the glasses")
        }
        let resolution: StreamingResolution = {
            switch effectiveResolution {
            case "low": return .low
            case "medium": return .medium
            default: return .high
            }
        }()
        let fps = UInt(Config.cameraFrameRate)
        // EO P1: the tier the SDK resolves is the only number that matters, and until now no log
        // has ever carried it — `capabilityCreated` reports the *label*. Record what all three
        // tiers actually are on this SDK and device, and which one was asked for.
        for tier in StreamingResolution.allCases {
            let size = tier.videoFrameSize
            PrivacyLog.camera(.glasses, .tierResolved,
                              detail: PrivacyToken(tier == resolution ? "requested" : "available"),
                              resolution: PrivacyToken(String(describing: tier)),
                              width: Int(size.width), height: Int(size.height))
        }
        // EO P1: hvc1 by default. Raw pixels do not fit the link, so the ladder steps the source
        // down and the delivered rate sags no matter what was asked for; compressed frames are
        // decoded in-process by `GlassesFramePipeline`.
        let codec = StreamCodecPolicy.videoCodec(for: Config.cameraCodec)
        guard let camera = try deviceSession.addCamera(
            config: MWDATCamera.StreamConfiguration(
                videoCodec: codec,
                resolution: resolution,
                frameRate: fps
            )
        ) else {
            throw CameraError.streamNotReady
        }
        cameraCapability = camera
        streamSession = camera.stream
        activeStreamResolution = effectiveResolution
        attachListeners(to: camera.stream)
        // (session error watcher already attached above, before start)
        PrivacyLog.camera(.glasses, .capabilityCreated,
                          detail: PrivacyToken.caseName(of: codec),
                          resolution: PrivacyToken(effectiveResolution), frameRate: Int(fps))
    }

    /// BR P2: device-level errors (incl. `.datAppOnTheGlassesUpdateRequired`) arrive on the
    /// DeviceSession's error stream — the camera Stream's errorPublisher never carries them.
    private func watchSessionErrors(on session: DeviceSession) {
        sessionErrorTask?.cancel()
        sessionErrorTask = Task { [weak self] in
            for await error in session.errorStream() {
                guard let self, !Task.isCancelled else { return }
                PrivacyLog.camera(.glasses, .sessionError, error: SafeErrorSummary(error))
                self.lastSessionError = error
                if let notice = DATCompatibilityMessage.message(for: error) {
                    self.compatibilityNotice = notice
                    self.debug(notice)
                }
            }
        }
    }

    /// The SDK's stream states, mapped onto the pure policy's table. One mapping, used by both the
    /// state listener and the start-side wait, so the two can never read the same state differently.
    private static func mapped(_ state: MWDATCamera.StreamState) -> CameraStreamStatePolicy.StreamState? {
        switch state {
        case .streaming:        return .streaming
        case .paused:           return .paused
        case .stopped:          return .stopped
        case .starting:         return .starting
        case .stopping:         return .stopping
        case .waitingForDevice: return .waitingForDevice
        @unknown default:       return nil
        }
    }

    /// Attach all publishers to the session (state, video frames, photo data, errors).
    private func attachListeners(to session: MWDATCamera.Stream) {
        var frameCount = 0
        // Plan FD P1: everything installed before this line is stale from here on. The bag's
        // cancellation is async, so the generation — not the cancel — is what actually stops a
        // callback from the previous stream acting on this one.
        let generation = listenerGeneration.rotate()
        // EO P1: the size the app actually receives, logged on the first frame and whenever it
        // changes. The SDK's ladder can step the source down mid-stream, and until now the only
        // size in any log was the tier *label* we asked for.
        var lastLoggedFrameSize: CGSize = .zero

        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.listenerGeneration.accepts(generation) else { return }
                PrivacyLog.camera(.glasses, .streamState,
                                  state: PrivacyToken(String(describing: state)))
                guard let mapped = Self.mapped(state) else { return }
                // How long a pause has stood, for the start-side wait. Recorded before the
                // decision below because it is a fact about the stream, not about what we want.
                self.pausedSince = mapped == .paused ? (self.pausedSince ?? Date()) : nil

                // Warmup and stall recovery both stop the stream on purpose with these listeners
                // still attached, so their `.stopped`s are ours and map to `.waiting`. That also
                // means `isStreaming` now stays TRUE across a successful stall recovery, which is
                // the point: the old flat `.stopped` cleared it, nothing ever set it back (
                // `recoverFromStall` assumes it is still true), and `startStallDetection`'s
                // `guard self.isStreaming` therefore went permanently false after the first
                // recovery — the detector silently disarmed itself. The failure path in
                // `recoverFromStall` still clears the flag explicitly, so a recovery that really
                // fails is still reported.
                switch CameraStreamStatePolicy.decide(
                    state: mapped,
                    streamingIntended: self.continuousStreamingIntent,
                    transitionIsOurs: self.isWarmingUp || self.isRecoveringFromStall) {
                case .streaming:
                    self.events.send(.status(.streaming))
                    // A healthy stream clears the verdict the retry gate reads. Without this the
                    // last error of an episode the stream recovered from — a fold that was undone,
                    // a permission that was granted on the second ask — would still be sitting
                    // there hours later, ready to stop the ladder for an unrelated drop.
                    self.lastStreamError = nil
                    // A stream that reached `.streaming` has no reason left to be waiting. The
                    // first *picture* is what makes it `ready` — until one arrives the coordinator
                    // reports "awaiting first frame", which is the honest gap this used to hide.
                    self.report(waitReason: nil)
                    if self.isReconnecting {
                        self.finishReconnect()
                    } else if StreamPausePolicy.restoresStreamingClaim(
                        streamingIntended: self.continuousStreamingIntent,
                        alreadyStreaming: self.isStreaming,
                        transitionIsOurs: self.isWarmingUp || self.isRecoveringFromStall) {
                        // Plan FD P1. The SDK resumed the stream itself — a temple tap, the
                        // glasses going back on. With the old `start()` nudge gone this is the
                        // only way back, and nothing used to act on it: `isStreaming` stayed
                        // false for the rest of the session while frames flowed, which also left
                        // the stall detector disarmed (it guards on exactly that flag) and the UI
                        // saying the camera was waiting.
                        PrivacyLog.camera(.glasses, .streamResumedBySDK)
                        self.restoreStreamingClaim()
                    }
                case .waiting:
                    self.events.send(.status(.waiting))
                    // FD P0: `.waiting` is four situations wearing one word. Say which one, from
                    // the state the SDK actually reported.
                    switch mapped {
                    case .stopping: self.report(waitReason: .stopping)
                    case .paused: self.report(waitReason: .paused)
                    default: self.report(waitReason: .connecting)
                    }
                case .stopped:
                    self.events.send(.status(.stopped))
                    self.report(waitReason: nil)
                    self.isStreaming = false
                    self.events.send(.streamingChanged(false))
                case .stoppedWhileWanted(let notice):
                    // The stream died under a session we still want. Reporting `.stopped` here
                    // would be honest about the wire and wrong about the app: a reconnect is
                    // already being scheduled, so the UI must read as connecting, not dead.
                    PrivacyLog.camera(.glasses, .streamStoppedWhileWanted)
                    self.isStreaming = false
                    self.events.send(.streamingChanged(false))
                    self.events.send(.status(.waiting))
                    // A reconnect is being scheduled below, so "connecting" is what is true —
                    // and it is what the reconnect ladder is about to do, not a guess at why the
                    // stream went away.
                    self.report(waitReason: .connecting)
                    if !self.isReconnecting {
                        self.isReconnecting = true
                        self.events.send(.transientNotice(notice))
                    }
                    self.scheduleReconnect()
                case .pausedWhileWanted(let decisionNotice):
                    // A paused stream is not streaming, whatever the button says. Since DAT 0.9 a
                    // doff lands here, so this is the state a wearer can actually fix — say so and
                    // stop claiming to stream.
                    //
                    // Plan FD P1: and then **wait**. This used to call `streamSession?.start()`
                    // immediately. There is no documented same-session resume in the pinned SDK —
                    // `Stream` offers start/stop and nothing else — and every recorded cause of a
                    // pause (temple-tap hold, doff, folded hinges) is cleared by the wearer, not
                    // by an API call. The paused session, its listeners and the camera capability
                    // are all kept exactly as they are; the SDK's own resume is what brings it
                    // back, and the `.streaming` row above is what acts on it.
                    PrivacyLog.camera(.glasses, .streamPausedWhileWanted)
                    self.isStreaming = false
                    self.events.send(.streamingChanged(false))
                    self.events.send(.status(.waiting))
                    self.report(waitReason: .paused)
                    switch StreamPausePolicy.response(streamingIntended: true) {
                    case .awaitSDKResume(let notice):
                        self.events.send(.transientNotice(notice))
                    case .staySilent:
                        // Unreachable under `.pausedWhileWanted`, which is by definition a wanted
                        // stream; spelled out rather than defaulted so the table stays readable.
                        self.events.send(.transientNotice(decisionNotice))
                    }
                }
            }
        }.store(in: streamListenerBag)

        // EO P1: the decoder and the liveness clocks live off the main actor, in the pipeline.
        // Captured by value so the listener never touches `self` before it hops.
        let pipeline = framePipeline
        session.videoFramePublisher.listen { [weak self] frame in
            // Runs on the SDK's delivery thread, and everything expensive stays here.
            // `makeUIImage()` copies the pixel data out of the VideoToolbox buffer pool right
            // away, preventing VT pool exhaustion if the buffer were held across an async
            // boundary; a compressed sample is decoded inline instead, and either way what
            // crosses to the main actor is a finished picture — plus whether that picture is new
            // or the last good one handed over again while the decoder waits for a keyframe.
            let picture = pipeline.picture(for: frame)
            Task { @MainActor in
                // A picture from a stream that has since been replaced is not a view of anything
                // that exists: it would refresh the freshness clock and the cached still for a
                // camera that is gone.
                guard let self, self.listenerGeneration.accepts(generation),
                      let image = picture.image else { return }
                frameCount += 1
                // Only a fresh picture makes the frame clock fresh. The app still sees the held
                // image — that is the point of holding one — but `lastFrameTime` also gates the
                // photo-capture fallback, and stamping it here would let that fallback hand over
                // a picture as old as the encoder's keyframe interval while looking seconds new.
                if picture.isFresh {
                    self.lastFrameTime = Date()
                    // A picture just came out of the pipeline, so whatever the stall detector or
                    // the state listener last reported as a reason for not delivering has ended.
                    // Only a *fresh* one clears it: a held frame is the decoder still waiting.
                    self.report(waitReason: nil)
                }
                self.latestFrame = image
                if frameCount <= 3 || frameCount % 30 == 0 || image.size != lastLoggedFrameSize {
                    lastLoggedFrameSize = image.size
                    PrivacyLog.camera(.glasses, .frameReceived,
                                      width: Int(image.size.width),
                                      height: Int(image.size.height), count: frameCount)
                }
                self.events.send(.frame(image, fresh: picture.isFresh))
            }
        }.store(in: streamListenerBag)

        session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                guard let self, self.listenerGeneration.accepts(generation) else { return }
                self.handlePhotoData(photoData)
            }
        }.store(in: streamListenerBag)

        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                // An error raced out of a stream we already replaced describes that stream, not
                // this one — and it would otherwise abort this stream's warm-up and stop this
                // stream's reconnect ladder.
                guard let self, self.listenerGeneration.accepts(generation) else { return }
                let message = CameraErrorPolicy.message(for: error)
                PrivacyLog.camera(.glasses, .streamError, error: SafeErrorSummary(error))
                self.debug("Camera error: \(message)")
                self.lastStreamError = error

                // Device-traced 2026-08-23: this copy already said exactly what was wrong
                // ("hinges are closed", "too hot", "battery is too low") and went only to the log
                // unless a photo capture happened to be pending. During streaming the wearer saw
                // the glasses flash amber and the app say nothing. The message is the whole point
                // of mapping the error — surface it.
                self.events.send(.transientNotice(message))

                // Fail a pending capture fast on a terminal error (hinges closed, thermal/battery
                // shutdown, device gone) instead of waiting out the 5s timeout below.
                if CameraErrorPolicy.abortsCapture(error), let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    if let fallback = self.latestFrameAsJPEG() {
                        PrivacyLog.camera(.glasses, .captureFallbackUsed)
                        cont.resume(returning: fallback)
                    } else {
                        cont.resume(throwing: CameraError.captureFailed)
                    }
                }
            }
        }.store(in: streamListenerBag)
    }

    /// Wait for the session to reach `.streaming` state, starting it if necessary.
    private func waitForStreaming(
        timeout: TimeInterval = StreamRecoveryPolicy.warmupTimeout
    ) async throws {
        guard let session = streamSession else { throw CameraError.captureFailed }
        // Only errors from THIS attempt may abort it.
        lastStreamError = nil

        // Wait for streaming state. During a cold start the stream bounces through `.stopped`
        // (device-traced: ~15-18 s of `.stopped`/`.waitingForDevice` churn before `.streaming`),
        // so a transient `.stopped` is NOT terminal — nudge `start()` again a few times before
        // giving up.
        //
        // Plan FD P1: `.paused` no longer travels with `.stopped`. A paused stream is a hold the
        // system imposed — temple tap, doff, folded hinges — and the pinned SDK offers nothing to
        // lift it, so a nudge into one is a competing restart that cannot work. The comment this
        // replaces claimed `.paused` was where a one-off capture parks the stream; it is not.
        // `pauseStreamAfterCapture()` calls `Stream.stop()`, so a parked stream sits at `.stopped`
        // and still gets its start. `StreamPausePolicy` owns the whole table.
        var nudges = 0
        var pausedAt: Date?
        let deadline = ContinuousClock.now + .seconds(timeout)
        warmup: while ContinuousClock.now < deadline {
            // An unrecognised state is churn, not a verdict: wait it out under the timeout.
            let state = Self.mapped(session.state) ?? .starting
            pausedAt = state == .paused ? (pausedAt ?? pausedSince ?? Date()) : nil
            let action = StreamPausePolicy.warmupAction(
                state: state,
                pausedFor: pausedAt.map { Date().timeIntervalSince($0) },
                nudgesUsed: nudges)
            if action == .ready { break warmup }
            // A start that already failed will not be rescued by more nudges or more waiting —
            // the stream needs rebuilding, and only the caller can do that. Without this, a dead
            // start spends the whole timeout going through the motions.
            if let error = lastStreamError, CameraErrorPolicy.abortsWarmup(error) {
                PrivacyLog.camera(.glasses, .warmupAborted, error: SafeErrorSummary(error))
                throw CameraError.streamNotReady
            }
            switch action {
            case .ready, .wait:
                break
            case .nudgeStart(let attempt):
                nudges = attempt
                PrivacyLog.camera(.glasses, .warmupNudged, attempt: attempt,
                                  ofAttempts: StreamPausePolicy.maxColdStartNudges)
                session.start()  // DAT 0.8.0+: Stream.start() is synchronous
            case .giveUp(.pauseHeld):
                // Nothing this start can do lifts a hold, and sitting out the rest of the
                // twenty-second timeout only delays the honest answer. The wearer already has the
                // notice that names the move that does lift it.
                PrivacyLog.camera(.glasses, .pauseHeldDuringStart,
                                  seconds: pausedAt.map { Date().timeIntervalSince($0) })
                throw CameraError.streamNotReady
            case .giveUp(.nudgesSpent):
                PrivacyLog.camera(.glasses, .warmupSessionStopped)
                throw CameraError.streamNotReady
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if session.state != .streaming {
            throw CameraError.streamNotReady
        }

        // Wait for the first video frame to actually arrive — the state becomes
        // .streaming before data flows, and capturePhoto won't work until then.
        PrivacyLog.camera(.glasses, .streamingReached)
        while ContinuousClock.now < deadline {
            if latestFrame != nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Even if no frame arrived, let the caller proceed (fallback will handle it)
        PrivacyLog.camera(.glasses, .firstFrameTimedOut)
    }

    // MARK: - Photo Capture

    /// Capture a photo from the glasses camera. Returns JPEG data.
    ///
    /// NOTE (device-reported, unverified here): `capturePhoto` also works on a stream that
    /// was added but never `start()`ed, and capturing on a *streaming* stream has been
    /// reported to race the frame flow and trip the glasses-side frame-stall watchdog.
    /// Our start-then-capture path is field-traced and carries the frame fallback, so it
    /// stays; if captures ever start stalling the stream, try the no-start discrete path
    /// before reaching for bigger hammers.
    func capturePhoto() async throws -> Data {
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }
        // Cleared as well as cancelled: a cancelled task that is still referenced would keep
        // counting towards `scheduledWorkCount`, which is meant to be the truth about what is armed.
        idleTeardownTask?.cancel()   // a capture during the idle grace keeps the session
        idleTeardownTask = nil

        try await ensurePermission()

        // The DAT link drops when the glasses idle (battery saving) and discovery lags app
        // launch by seconds — a session created in that window throws noEligibleDevice
        // ("all discovered devices are powered off or disconnected") even though the glasses
        // are registered and on the user's face. Live-traced: discovery failed at +0.3s after
        // launch, link up at +4.7s. Retry with backoff (~12s window) while the link returns.
        var sessionError: Error?
        var firstError: Error?
        // Fresh cycle, fresh verdict — a stale notice from before a glasses update must not
        // abort attempts that could now succeed (the watcher re-sets it if still true).
        compatibilityNotice = nil
        for attempt in 1...4 {
            do {
                try await ensureSession()
                sessionError = nil
                break
            } catch {
                if firstError == nil { firstError = error }
                sessionError = error
                PrivacyLog.camera(.glasses, .sessionAttemptFailed, attempt: attempt,
                                  ofAttempts: 4, error: SafeErrorSummary(error))
                // A compatibility refusal (outdated glasses-side DAT app / firmware) arrives on
                // the session error stream and kills the session before .started. Retrying can
                // never succeed — stop churning and surface the actionable update message.
                if let notice = compatibilityNotice {
                    PrivacyLog.camera(.glasses, .incompatibleDevice)
                    throw CameraError.incompatible(notice)
                }
                if Self.isSessionAlreadyExists(error) {
                    // The phantom is a glasses-side session still tearing down — either our
                    // own previous one, or one LEAKED by a killed/reinstalled app instance
                    // (nothing ever stops it; the glasses hold it until their own timeout).
                    // Resetting again re-poisons the window — just wait it out.
                    if attempt < 4 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                    }
                } else {
                    await resetSession()
                    if attempt < 4 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    }
                }
            }
        }
        if let finalError = sessionError {
            // Surface the FIRST error (the root cause), not the Nth "already exists"
            // collision that our own retry teardown caused — unless the first error IS the
            // busy session, which gets the actionable message.
            let rootError = firstError ?? finalError
            if Self.isSessionAlreadyExists(rootError) || Self.isSessionAlreadyExists(finalError) {
                throw CameraError.sessionBusy
            }
            throw rootError
        }

        // Wait for stream to be ready (start if needed). Both attempts get the full warmup window
        // — see `StreamRecoveryPolicy.warmupTimeout` for why a shortened first attempt punished
        // healthy cold starts instead of broken ones.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await waitForStreaming()
                lastError = nil
                break
            } catch {
                PrivacyLog.camera(.glasses, .waitAttemptFailed, attempt: attempt,
                                  ofAttempts: 2, error: SafeErrorSummary(error))
                lastError = error
                if attempt < 2 {
                    // Reset session and retry
                    await resetSession()
                    try await ensureSession()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        if let error = lastError { throw error }

        // Capture using continuation — with video frame fallback
        let photoData: Data = try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation

            PrivacyLog.camera(.glasses, .captureRequested)
            let success = streamSession!.capturePhoto(format: .jpeg)
            if !success {
                self.photoContinuation = nil
                // capturePhoto returned false — fall back to latest video frame
                if let fallback = self.latestFrameAsJPEG() {
                    PrivacyLog.camera(.glasses, .captureRejected, bytes: fallback.count)
                    continuation.resume(returning: fallback)
                } else {
                    continuation.resume(throwing: CameraError.captureFailed)
                }
                return
            }

            // Timeout after 8 seconds — fall back to latest video frame. (5s was too tight on
            // a cold WiFi-transport capture; the photo often lands at 5-7s.)
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    if let fallback = self.latestFrameAsJPEG() {
                        PrivacyLog.camera(.glasses, .captureTimedOut, bytes: fallback.count)
                        cont.resume(returning: fallback)
                    } else {
                        PrivacyLog.camera(.glasses, .captureTimedOut)
                        cont.resume(throwing: CameraError.timeout)
                    }
                }
            }
        }

        // Keep the session WARM after capture instead of tearing it down immediately
        // (device-traced: the glasses-side teardown lags the app-side stop, so the next
        // capture's createSession collided with the dying session — "A session already
        // exists for this device" — while long-lived preview sessions never hit it).
        // Battery is protected by the idle timer: teardown happens after a quiet minute,
        // and back-to-back photos skip the multi-second session cold-start entirely.
        // The *stream* is paused rather than left running, which is the battery half of that
        // trade without giving up the warm session.
        if !isStreaming && !continuousStreamingIntent {
            pauseStreamAfterCapture()
            scheduleIdleTeardown()
        }

        PrivacyLog.camera(.glasses, .photoCaptured, bytes: photoData.count)
        return photoData
    }

    /// The SDK's one-session-per-device refusal — matched on the message because the thrown
    /// error type differs between the create and start paths.
    nonisolated private static func isSessionAlreadyExists(_ error: Error) -> Bool {
        String(describing: error).localizedCaseInsensitiveContains("already exists")
            || error.localizedDescription.localizedCaseInsensitiveContains("already exists")
    }

    /// Tear the session down after a minute of camera idleness (cancelled and re-armed by
    /// each capture; cancelled outright when explicit streaming starts).
    private var idleTeardownTask: Task<Void, Never>?
    private static let sessionIdleGrace: Duration = .seconds(60)

    /// Stop the stream but keep the session, after a one-off capture.
    ///
    /// `latestFrame` is deliberately **kept**. It is a cached still, not stream state, and three
    /// things read it after a capture: the photo-capture timeout fallback
    /// (`latestFrameAsJPEG()`), `waitForStreaming`'s first-frame wait, and — the one that bites
    /// silently — the recording/broadcast start paths, which derive the encoder's output size and
    /// therefore its bitrate from `latestFrame?.size`, falling back to a hardcoded 720×1280.
    /// Clearing it here would send "photo, then record" back to that constant, which is precisely
    /// what deriving the bitrate from the picture was meant to stop.
    private func pauseStreamAfterCapture() {
        // Discrete-capture parking only. The caller already checks this, and it is checked again
        // here because the `.stopped` this provokes is indistinguishable on the wire from a real
        // drop: `continuousStreamingIntent` is the ONLY thing that tells them apart, so a stray
        // call would schedule a reconnect for a stream nobody wanted running.
        guard !continuousStreamingIntent else { return }
        guard let session = streamSession else { return }
        switch session.state {
        case .stopped, .stopping:
            return
        default:
            session.stop()
            lastFrameTime = .distantPast
            PrivacyLog.camera(.glasses, .streamPausedAfterCapture)
        }
    }

    private func scheduleIdleTeardown() {
        idleTeardownTask?.cancel()
        idleTeardownTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionIdleGrace)
            guard let self, !Task.isCancelled else { return }
            self.idleTeardownTask = nil
            guard !self.isStreaming, !self.isCaptureInProgress else { return }
            PrivacyLog.camera(.glasses, .idleTeardown)
            await self.resetSession()
        }
    }

    private func handlePhotoData(_ photoData: PhotoData) {
        guard let continuation = photoContinuation else {
            PrivacyLog.camera(.glasses, .photoUnexpected)
            return
        }
        photoContinuation = nil
        PrivacyLog.camera(.glasses, .photoReceived, bytes: photoData.data.count)
        continuation.resume(returning: photoData.data)
    }

    /// How old a video frame may be and still stand in for a failed photo capture. Beyond
    /// this, the frame shows where the camera pointed SECONDS AGO — live-traced: repeated
    /// capture failures kept donating one stale frame, and the assistant confidently
    /// described the same scene while the user pointed the glasses at different things.
    private static let frameFallbackMaxAge: TimeInterval = 10

    /// Convert the latest video frame to JPEG data for use as a photo fallback — but ONLY if
    /// it's fresh. A stale frame is worse than an honest failure: it hallucinates a scene.
    private func latestFrameAsJPEG(quality: CGFloat = 0.85) -> Data? {
        guard let frame = latestFrame,
              Date().timeIntervalSince(lastFrameTime) < Self.frameFallbackMaxAge else {
            if latestFrame != nil {
                PrivacyLog.camera(.glasses, .frameStale,
                                  seconds: Date().timeIntervalSince(lastFrameTime))
            }
            return nil
        }
        return frame.jpegData(compressionQuality: quality)
    }

    // MARK: - Continuous Video Streaming (for Gemini Live)

    /// Start continuous video streaming from the glasses camera.
    func startStreaming() async throws {
        guard WearablesBootstrap.ensureConfigured() else { throw CameraError.sdkNotRegistered }
        guard !isStreaming else { return }
        idleTeardownTask?.cancel()   // explicit streaming owns the session now
        idleTeardownTask = nil
        continuousStreamingIntent = true
        // A hand-started stream supersedes any reconnect still climbing from an earlier drop.
        cancelReconnect()
        // Everything from here to the first frame is a cold start — including the rebuild
        // below, which stops the stream on purpose. Marked as warmup so none of the `.stopped`
        // churn it produces is mistaken for the stream dropping out from under us.
        isWarmingUp = true
        defer { isWarmingUp = false }
        let startToken = startGeneration.beginStart()

        // A stream left behind by the discrete photo path may sit at the user's "low"
        // tier; continuous streaming with glasses-mic voice needs the contention floor
        // (see `StreamConfigPolicy`), so rebuild it at the effective tier first.
        if let active = activeStreamResolution,
           StreamConfigPolicy.effectiveResolution(
               requested: Config.cameraResolution,
               concurrentGlassesVoice: true) != active {
            await teardownStreamOnly()
        }

        do {
            try await ensurePermission()
            try await warmUpStream()
        } catch {
            continuousStreamingIntent = false
            // The last `.stopped` of a failed warmup is one of ours, so it reported `.waiting` —
            // correct while the ladder was climbing, wrong now that it has given up. Say stopped
            // explicitly, or the preview sits on "Connecting…" forever instead of showing the
            // error this throw is about to produce.
            events.send(.status(.stopped))
            report(waitReason: nil)   // the ladder has stopped climbing; nothing is pending
            throw error
        }

        // Plan EW. The warmup above took seconds; a stop may have landed inside it. If one did,
        // this start has been superseded — release the stream it just brought up rather than
        // publish it as running. A late start that claims the camera anyway holds the
        // process-wide capability with nothing consuming its frames.
        guard startGeneration.finish(startToken) == .commit else {
            releaseSupersededStart()
            return
        }

        isStreaming = true
        events.send(.streamingChanged(true))
        startStallDetection()
        PrivacyLog.camera(.glasses, .started)
    }

    /// Take back a stream whose start a stop overtook. It came up, so there is something real to
    /// release, but it was never published as running — hence no `streamingChanged(false)` for a
    /// `true` nobody ever saw.
    private func releaseSupersededStart() {
        continuousStreamingIntent = false
        cancelReconnect()
        stopStallDetection()
        streamSession?.stop()
        latestFrame = nil
        events.send(.frameCleared)
        events.send(.status(.stopped))
        report(waitReason: nil)
        PrivacyLog.camera(.glasses, .stopped)
    }

    /// Bring the session up and wait for frames, retrying once through the recovery ladder.
    ///
    /// The retry exists because a stream left `.paused` by a one-off capture can fail its next
    /// `start()` outright — the warmup aborts on that error rather than sitting out the timeout,
    /// and what it needs is a rebuilt stream, which is exactly what this does before trying again.
    ///
    /// Which teardown the retry uses comes from `StreamRecoveryPolicy` on the same
    /// `consecutiveRecoveryFailures` counter stall recovery uses. That is what makes the
    /// escalation real: counting only *this call's* attempts, the count could never exceed one and
    /// the session-reset tier would be unreachable, so a camera failing every warmup would rebuild
    /// the cheap half forever. The count resets on the first success.
    private func warmUpStream() async throws {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await ensureSession()
                try await waitForStreaming()
                consecutiveRecoveryFailures = 0
                return
            } catch {
                PrivacyLog.camera(.glasses, .warmupAttemptFailed, attempt: attempt,
                                  ofAttempts: 2, error: SafeErrorSummary(error))
                lastError = error
                let action = StreamRecoveryPolicy.action(consecutiveFailures: consecutiveRecoveryFailures)
                consecutiveRecoveryFailures += 1
                guard attempt < 2 else { break }
                PrivacyLog.camera(.glasses, .warmupRetry, detail: PrivacyToken.caseName(of: action))
                switch action {
                case .rebuildStream: await teardownStreamOnly()
                case .resetSession: await resetSession()
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw lastError ?? CameraError.streamNotReady
    }

    /// Stop continuous video streaming. Session is kept alive for reuse.
    func stopStreaming() async {
        // Cleared BEFORE anything stops the stream: the `.stopped` this is about to provoke is
        // one we asked for, and the reconnect row keys off exactly this flag to tell the two
        // apart. Every other deliberate teardown path relies on the same ordering.
        continuousStreamingIntent = false
        cancelReconnect()
        // Plan EW: recorded before the `isStreaming` guard, because during a cold start that guard
        // is exactly what swallowed the stop. The warmup now finds its token stale and releases.
        startGeneration.recordStop()
        guard isStreaming else { return }
        stopStallDetection()
        if let session = streamSession {
            session.stop()
        }
        isStreaming = false
        events.send(.streamingChanged(false))
        latestFrame = nil
        events.send(.frameCleared)
        report(waitReason: nil)
        PrivacyLog.camera(.glasses, .stopped)
    }

    // MARK: - Reconnect After an Unwanted Stop

    /// Schedule the next rung of the reconnect ladder.
    ///
    /// Deliberately does nothing while warmup or stall recovery is in flight: both already own
    /// the stream, both run the same `StreamRecoveryPolicy` ladder, and both report their own
    /// failure. Two rebuilders racing for one process-wide camera capability is how you turn a
    /// dropped stream into `capabilityAlreadyActive`.
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        // Plan FD P1: the gate is a table now (`StreamReconnectPolicy`), because it answers four
        // separate questions and one of them — "can a retry succeed at all, given what the SDK
        // last said went wrong" — was never asked. A revoked permission, a companion app that
        // needs updating, glasses too hot or folded: the ladder used to spend its full ~88 s
        // budget on all of them and then say nothing the wearer could have acted on sooner.
        switch StreamReconnectPolicy.next(
            attempt: reconnectAttempt,
            streamingIntended: continuousStreamingIntent,
            transitionIsOurs: isWarmingUp || isRecoveringFromStall || isCaptureInProgress,
            lastFailure: lastStreamError.map(CameraErrorPolicy.retryDisposition(for:))) {

        case .standDown:
            isReconnecting = false
            reconnectAttempt = 0

        case .deferToOwner(let delay):
            // A warm-up, a stall recovery or a capture already owns the stream, and two rebuilders
            // racing for one process-wide camera capability is how a dropped stream becomes
            // `capabilityAlreadyActive`. Look again shortly — and do not spend a rung on it: the
            // budget is for the glasses being unreachable, not for waiting out our own work.
            PrivacyLog.camera(.glasses, .reconnectDeferred, seconds: delay)
            scheduleRung(after: delay, attempt: nil)

        case .giveUp(let notice):
            giveUpReconnecting(notice: notice)

        case .retry(let delay, let attempt):
            PrivacyLog.camera(.glasses, .reconnectScheduled, attempt: attempt + 1, seconds: delay)
            reconnectAttempt += 1
            scheduleRung(after: delay, attempt: attempt)
        }
    }

    /// Arm one rung. `attempt` is `nil` for a deferral, which only looks again rather than acting.
    private func scheduleRung(after delay: TimeInterval, attempt: Int?) {
        // Which camera session this rung belongs to. A rung sleeps for up to five seconds, and a
        // stop — or a replacement — inside that window makes it a rung of a ladder that was
        // climbing a camera which no longer exists.
        let scheduledUnder = startGeneration.sessionIdentity
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard StreamReconnectPolicy.mayAct(
                streamingIntended: self.continuousStreamingIntent,
                alreadyStreaming: self.isStreaming,
                scheduledUnderSession: scheduledUnder,
                currentSession: self.startGeneration.sessionIdentity) else {
                // The wearer stopped the camera, the session was replaced, or the stream came
                // back on its own while we slept.
                PrivacyLog.camera(.glasses, .reconnectStoodDown)
                self.isReconnecting = false
                return
            }
            guard let attempt else {
                // A deferral: re-ask the table now that time has passed.
                self.scheduleReconnect()
                return
            }
            PrivacyLog.camera(.glasses, .reconnectAttempt, attempt: attempt + 1)
            // Reuse the tiered ladder rather than writing a third teardown path: rebuild the
            // cheap half first, escalate to a session reset once that keeps failing.
            self.isRecoveringFromStall = true
            await self.recoverFromStall()
            self.isRecoveringFromStall = false
            // `.streaming` arriving on the state publisher is what ends a reconnect (see
            // `finishReconnect`); if it hasn't, climb the next rung.
            if self.isReconnecting && !self.isStreaming { self.scheduleReconnect() }
        }
    }

    /// The ladder has stopped climbing — either the budget is spent or the failure is one no retry
    /// can clear. Retract the promise the first notice made, and end the intent that drives it.
    private func giveUpReconnecting(notice: String) {
        PrivacyLog.camera(.glasses, .reconnectGaveUp, count: reconnectAttempt,
                          seconds: StreamRecoveryPolicy.reconnectBudget)
        isReconnecting = false
        reconnectAttempt = 0
        // Plan FD P1. The intent goes with the ladder. Left set, it meant the next stray `.stopped`
        // from the SDK re-entered the ladder at rung zero — an automatic loop outliving the
        // give-up that was supposed to end it, and a second ~88 s of "reconnecting" for a camera
        // that has already been declared gone. The wearer's next Start is a deliberate, fresh
        // session, which is the only honest thing left to offer.
        continuousStreamingIntent = false
        stopStallDetection()
        if isStreaming {
            isStreaming = false
            events.send(.streamingChanged(false))
        }
        events.send(.status(.stopped))
        report(waitReason: nil)   // the ladder is finished, so nothing is connecting any more
        events.send(.transientNotice(notice))
    }

    /// Frames are flowing again. Restores the streaming claim the drop cleared — `recoverFromStall`
    /// only ever ran underneath a session that still believed it was streaming, so nothing else
    /// puts `isStreaming` back.
    private func finishReconnect() {
        cancelReconnect()
        PrivacyLog.camera(.glasses, .reconnected)
        restoreStreamingClaim()
    }

    /// Put the streaming claim back after the stream came back **without a start of ours**: the
    /// SDK lifted a pause it had imposed, or a reconnect rung succeeded.
    ///
    /// Plan FD P1. With the pause nudge gone, the SDK's own resume is the only way back from a
    /// pause, so it has to be acted on — and nothing acted on it before. `isStreaming` stayed
    /// false for the rest of the session while frames flowed: the UI said the camera was waiting,
    /// and the stall detector, which guards on exactly that flag, was disarmed for good.
    private func restoreStreamingClaim() {
        guard continuousStreamingIntent, !isStreaming else { return }
        isStreaming = true
        events.send(.streamingChanged(true))
        lastFrameTime = Date()
        framePipeline.restartClocks()
        startStallDetection()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
    }

    // MARK: - HEVC Decoder Stall Detection & Auto-Recovery

    /// Start monitoring for decoder stalls (no frames for 1.5 seconds).
    /// If a stall is detected, the session is torn down and recreated.
    private func startStallDetection() {
        stopStallDetection()
        lastFrameTime = Date()
        framePipeline.restartClocks()
        stallDetectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5s
                guard !Task.isCancelled, let self else { break }
                guard self.isStreaming, !self.isRecoveringFromStall else { continue }

                // Temple-tap pause is a system hold: no frames is expected, there is no
                // app-callable resume, and tearing down collapses the channel the next
                // tap would resume. Sit it out (and keep the clock fresh so recovery
                // doesn't fire the instant the tap resumes the stream).
                if !StreamRecoveryPolicy.shouldRecoverFromStall(state: self.streamSession?.state) {
                    self.lastFrameTime = Date()
                    self.framePipeline.restartClocks()
                    continue
                }

                // EO P1: two clocks, two different faults. Frames stopping because the glasses
                // stopped sending is the stall this detector was written for; frames arriving
                // and never becoming pictures is a decoder problem, and tearing the stream down
                // for it restarts the wait for a keyframe — i.e. makes it worse.
                switch self.framePipeline.verdict() {
                case .healthy:
                    continue
                case .decodeStalled:
                    PrivacyLog.camera(.decoder, .stalled,
                                      seconds: self.framePipeline.secondsSinceLastPicture())
                    // FD P0: this detector is the only thing in the app that can tell the two
                    // stalls apart, so it is the only thing entitled to report either. The next
                    // fresh picture clears it.
                    self.report(waitReason: .decodingStalled)
                    self.framePipeline.rebuildDecoder()
                case .linkStalled:
                    let elapsed = Date().timeIntervalSince(self.lastFrameTime)
                    PrivacyLog.camera(.glasses, .stallDetected, seconds: elapsed)
                    self.report(waitReason: .framesUnavailable)
                    self.isRecoveringFromStall = true
                    self.stallRecoveryCount += 1
                    await self.recoverFromStall()
                    self.isRecoveringFromStall = false
                }
            }
        }
    }

    /// Stop stall detection monitoring.
    private func stopStallDetection() {
        stallDetectionTask?.cancel()
        stallDetectionTask = nil
    }

    /// Recover from a decoder stall. BR P2: tiered — rebuild only the Stream on the
    /// retained DeviceSession first (the session is the expensive half: BT connection +
    /// permission state); escalate to a full session reset only after repeated failures.
    private func recoverFromStall() async {
        let action = StreamRecoveryPolicy.action(consecutiveFailures: consecutiveRecoveryFailures)
        PrivacyLog.camera(.glasses, .stallRecovery, detail: PrivacyToken.caseName(of: action),
                          count: stallRecoveryCount)
        debug("Camera stall recovery #\(stallRecoveryCount) (\(action))")

        switch action {
        case .rebuildStream:
            await teardownStreamOnly()
        case .resetSession:
            await resetSession()
        }

        do {
            try await ensureSession()
            try await waitForStreaming()
            lastFrameTime = Date()
            framePipeline.restartClocks()
            consecutiveRecoveryFailures = 0
            PrivacyLog.camera(.glasses, .stallRecovered)
        } catch {
            consecutiveRecoveryFailures += 1
            PrivacyLog.camera(.glasses, .stallRecoveryFailed,
                              count: consecutiveRecoveryFailures,
                              error: SafeErrorSummary(error))
            if case .rebuildStream = action {
                // Stream-only rebuild failed — make the next attempt (or the next stall
                // tick) escalate rather than looping at the cheap tier.
                await resetSession()
            }
            isStreaming = false
            events.send(.streamingChanged(false))
        }
    }

    /// BR P2: drop the Camera capability and its listeners but keep the DeviceSession alive —
    /// a failed stream must not strand a half-open session (`ensureSession` re-adds the camera
    /// on the retained session).
    private func teardownStreamOnly() async {
        await transitionLock.withLock { await self.teardownStreamOnlyLocked() }
    }

    private func teardownStreamOnlyLocked() async {
        if let camera = cameraCapability {
            camera.stop()  // cascades to the stream
            await awaitCameraStopped(camera)
        }
        await streamListenerBag.cancelAll()
        cameraCapability = nil
        streamSession = nil
        activeStreamResolution = nil
        // The next stream gets a fresh decompression session, and reports its own frame shape.
        framePipeline.reset()
        PrivacyLog.camera(.glasses, .capabilityTornDown)
    }

    /// Bounded wait for a stopped Camera to actually reach `.stopped`. The camera
    /// capability is process-wide and is freed when the Camera finishes stopping — not
    /// when the session is torn down — so arming a replacement camera before then throws
    /// `capabilityAlreadyActive`. `stop()` is synchronous but the state transition isn't.
    private func awaitCameraStopped(_ camera: MWDATCamera.Camera, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if camera.state == .stopped { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        PrivacyLog.camera(.glasses, .capabilityStopTimedOut,
                          seconds: Double(timeout.components.seconds))
    }

    /// Bounded wait for a stopped `DeviceSession` to actually reach `.stopped`.
    ///
    /// The camera capability has had `awaitCameraStopped` since Plan BR; the session had nothing.
    /// `DeviceSession.stop()` is synchronous but the transition is not, and creating a session
    /// against a device whose previous session has not finished is what the SDK answers with
    /// `sessionAlreadyExists` — the "phantom" the capture path already spends four attempts and
    /// ~12 s waiting out.
    private func awaitSessionStopped(_ session: DeviceSession, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if session.state == .stopped { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        PrivacyLog.camera(.glasses, .sessionStopTimedOut,
                          seconds: Double(timeout.components.seconds))
    }

    /// Reset the session completely (for error recovery).
    private func resetSession() async {
        await transitionLock.withLock { await self.resetSessionLocked() }
    }

    private func resetSessionLocked() async {
        // A reset with the intent already cleared is a deliberate teardown (stop, idle grace,
        // mode switch) — nothing should be trying to bring the stream back afterwards. A reset
        // *with* the intent still set is recovery, and the ladder is what called it.
        if !continuousStreamingIntent { cancelReconnect() }
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        if let camera = cameraCapability {
            camera.stop()
            // Wait for the capability to actually free (see `awaitCameraStopped`) so the
            // retry loop's next `ensureSession` doesn't collide with the dying camera.
            await awaitCameraStopped(camera)
        }
        if let session = deviceSession {
            session.stop()
            // The replacement boundary, at the session level: a new session may not be created
            // until this one is observably finished.
            await awaitSessionStopped(session)
        }
        await streamListenerBag.cancelAll()
        cameraCapability = nil
        streamSession = nil
        activeStreamResolution = nil
        deviceSession = nil
        // A torn-down session's frames must not survive to serve as "photos" for the next
        // capture — the staleness gate is belt, this is braces.
        latestFrame = nil
        events.send(.frameCleared)
        report(waitReason: nil)
        lastFrameTime = .distantPast
        framePipeline.reset()
        PrivacyLog.camera(.glasses, .sessionReset)
    }

    /// Tear down everything — called on mode switch or app termination.
    func tearDown() async {
        // Nothing may outlive a teardown, a scheduled one included: a pending idle teardown would
        // re-enter `resetSession()` on a backend that has already given everything back.
        idleTeardownTask?.cancel()
        idleTeardownTask = nil
        await stopStreaming()
        await resetSession()
        permissionGranted = false
        PrivacyLog.camera(.glasses, .tornDown)
    }
}
