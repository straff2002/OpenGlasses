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
    /// Stall detection timer — fires if no frame arrives for 1.5 seconds.
    private var stallDetectionTask: Task<Void, Never>?
    /// Whether we're currently recovering from a stall (prevents re-entrant recovery).
    private var isRecoveringFromStall = false
    /// Number of consecutive stall recoveries (for diagnostics).
    private var stallRecoveryCount = 0
    /// BR P2: consecutive FAILED recoveries — drives the rebuild-stream-vs-reset-session
    /// tiering in `StreamRecoveryPolicy`. Reset on any successful recovery.
    private var consecutiveRecoveryFailures = 0
    /// BR P2: listener on the DeviceSession's error stream (update-required and terminal
    /// device errors surface here, not on the camera Stream's errorPublisher).
    private var sessionErrorTask: Task<Void, Never>?

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
            NSLog("[Camera] Cached permission no longer granted — re-running the permission flow")
            permissionGranted = false
        }

        let regState = Wearables.shared.registrationState
        NSLog("[Camera] SDK state: %d (need 3 for camera permissions)", regState.rawValue)
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
            NSLog("[Camera] State %d is not fully registered.", settledState)
            throw CameraError.sdkNotRegistered
        }

        // Check/request Meta camera permission with retries
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                NSLog("[Camera] Permission retry %d/%d...", attempt + 1, maxAttempts)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }

            do {
                let readyState = await waitForRegistration(minState: 3, timeoutSeconds: 10)
                if readyState < 3 { throw CameraError.sdkNotRegistered }

                let status = try await Wearables.shared.checkPermissionStatus(.camera)
                NSLog("[Camera] checkPermissionStatus: %@", String(describing: status))
                if status == .granted {
                    permissionGranted = true
                    return
                }

                let requestStatus = try await Wearables.shared.requestPermission(.camera)
                guard requestStatus == .granted else { throw CameraError.permissionDenied }
                permissionGranted = true
                return
            } catch {
                NSLog("[Camera] Permission attempt %d/%d failed: %@",
                      attempt + 1, maxAttempts, error.localizedDescription)

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
    private func ensureSession() async throws {
        guard streamSession == nil else { return }

        // First call: start tracking the devices list, and give the listener a beat to
        // deliver the current snapshot before we pick a selector.
        if devicesListenerToken == nil {
            devicesListenerToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
                Task { @MainActor in self?.knownDeviceId = deviceIds.first }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // DAT 0.7: DeviceSession owns the connection; Streams hang off it.
        if deviceSession?.state == .stopped {
            deviceSession = nil
        }

        if deviceSession == nil {
            // Bind to the specific discovered device when we know it — field-proven more
            // reliable than AutoDeviceSelector for a device whose link is mid-wake.
            if let id = knownDeviceId {
                NSLog("[Camera] Creating session bound to device %@", id)
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
                // .stopped inside the first moments can be the pre-transition resting state;
                // only treat it as terminal once the state machine has had time to move.
                if deviceSession.state == .stopped && ContinuousClock.now > stoppedGraceEnd { break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        guard deviceSession.state == .started else {
            NSLog("[Camera] Session never reached .started (state: %@)",
                  String(describing: deviceSession.state))
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
            NSLog("[Camera] Resolution floored to %@ for streaming with glasses voice", effectiveResolution)
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
        guard let camera = try deviceSession.addCamera(
            config: MWDATCamera.StreamConfiguration(
                videoCodec: .raw,
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
        NSLog("[Camera] Created persistent Camera capability (.\(effectiveResolution), \(fps)fps)")
    }

    /// BR P2: device-level errors (incl. `.datAppOnTheGlassesUpdateRequired`) arrive on the
    /// DeviceSession's error stream — the camera Stream's errorPublisher never carries them.
    private func watchSessionErrors(on session: DeviceSession) {
        sessionErrorTask?.cancel()
        sessionErrorTask = Task { [weak self] in
            for await error in session.errorStream() {
                guard let self, !Task.isCancelled else { return }
                NSLog("[Camera] DeviceSession error: %@", String(describing: error))
                if let notice = DATCompatibilityMessage.message(for: error) {
                    self.compatibilityNotice = notice
                    self.debug(notice)
                }
            }
        }
    }

    /// Attach all publishers to the session (state, video frames, photo data, errors).
    private func attachListeners(to session: MWDATCamera.Stream) {
        var frameCount = 0

        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                NSLog("[Camera] State changed: %@", String(describing: state))
                let mapped: CameraStreamStatePolicy.StreamState?
                switch state {
                case .streaming:        mapped = .streaming
                case .paused:           mapped = .paused
                case .stopped:          mapped = .stopped
                case .starting:         mapped = .starting
                case .stopping:         mapped = .stopping
                case .waitingForDevice: mapped = .waitingForDevice
                @unknown default:       mapped = nil
                }
                guard let mapped else { return }

                switch CameraStreamStatePolicy.decide(state: mapped,
                                                      streamingIntended: self.continuousStreamingIntent) {
                case .streaming:
                    self.events.send(.status(.streaming))
                case .waiting:
                    self.events.send(.status(.waiting))
                case .stopped:
                    self.events.send(.status(.stopped))
                    self.isStreaming = false
                    self.events.send(.streamingChanged(false))
                case .pausedWhileWanted(let notice):
                    // A paused stream is not streaming, whatever the button says. Since DAT 0.9 a
                    // doff lands here, so this is the state a wearer can actually fix — say so,
                    // stop claiming to stream, and nudge it back up.
                    NSLog("[Camera] Stream paused while streaming was wanted — %@", notice)
                    self.isStreaming = false
                    self.events.send(.streamingChanged(false))
                    self.events.send(.status(.waiting))
                    self.events.send(.transientNotice(notice))
                    self.streamSession?.start()
                }
            }
        }.store(in: streamListenerBag)

        session.videoFramePublisher.listen { [weak self] frame in
            // Immediate pixel buffer copy: `makeUIImage()` copies the pixel data out of
            // the VideoToolbox buffer pool right away, preventing VT pool exhaustion
            // that can occur if the buffer is held across async boundaries.
            let image = frame.makeUIImage()
            Task { @MainActor in
                guard let self, let image else { return }
                frameCount += 1
                self.lastFrameTime = Date()
                self.latestFrame = image
                if frameCount <= 3 || frameCount % 30 == 0 {
                    NSLog("[Camera] Video frame #%d (%dx%d)",
                          frameCount, Int(image.size.width), Int(image.size.height))
                }
                self.events.send(.frame(image))
            }
        }.store(in: streamListenerBag)

        session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                self?.handlePhotoData(photoData)
            }
        }.store(in: streamListenerBag)

        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let message = CameraErrorPolicy.message(for: error)
                NSLog("[Camera] Error: %@", message)
                self.debug("Camera error: \(message)")

                // Fail a pending capture fast on a terminal error (hinges closed, thermal/battery
                // shutdown, device gone) instead of waiting out the 5s timeout below.
                if CameraErrorPolicy.abortsCapture(error), let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    if let fallback = self.latestFrameAsJPEG() {
                        NSLog("[Camera] Terminal error during capture — using latest video frame")
                        cont.resume(returning: fallback)
                    } else {
                        cont.resume(throwing: CameraError.captureFailed)
                    }
                }
            }
        }.store(in: streamListenerBag)
    }

    /// Wait for the session to reach `.streaming` state, starting it if necessary.
    private func waitForStreaming(timeout: TimeInterval = 20) async throws {
        guard let session = streamSession else { throw CameraError.captureFailed }

        // Start the session if it is not already running. `.paused` counts: a stream paused after
        // a one-off capture (see `pauseStreamAfterCapture`) is idle, not broken.
        if session.state == .stopped || session.state == .paused {
            session.start()  // DAT 0.8.0+: Stream.start() is synchronous
        }

        // Wait for streaming state. During a cold start the stream bounces through .stopped
        // (device-traced: ~15-18s of .stopped/.waitingForDevice churn before .streaming), so a
        // transient .stopped is NOT terminal — nudge start() again a few times before giving up.
        var restartNudges = 0
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if session.state == .streaming { break }
            if session.state == .stopped || session.state == .paused {
                if restartNudges < 3 {
                    restartNudges += 1
                    NSLog("[Camera] Stream stopped while warming up — restart nudge %d/3", restartNudges)
                    session.start()
                } else {
                    NSLog("[Camera] Session stopped unexpectedly while waiting for streaming")
                    throw CameraError.streamNotReady
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if session.state != .streaming {
            throw CameraError.streamNotReady
        }

        // Wait for the first video frame to actually arrive — the state becomes
        // .streaming before data flows, and capturePhoto won't work until then.
        NSLog("[Camera] Streaming state reached, waiting for first video frame...")
        while ContinuousClock.now < deadline {
            if latestFrame != nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Even if no frame arrived, let the caller proceed (fallback will handle it)
        NSLog("[Camera] No video frame arrived within timeout, proceeding anyway")
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
        idleTeardownTask?.cancel()   // a capture during the idle grace keeps the session

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
                NSLog("[Camera] ensureSession attempt %d/4 failed: %@", attempt, error.localizedDescription)
                // A compatibility refusal (outdated glasses-side DAT app / firmware) arrives on
                // the session error stream and kills the session before .started. Retrying can
                // never succeed — stop churning and surface the actionable update message.
                if let notice = compatibilityNotice {
                    NSLog("[Camera] Compatibility refusal — aborting session retries")
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

        // Wait for stream to be ready (start if needed)
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await waitForStreaming(timeout: attempt == 1 ? 10 : 20)
                lastError = nil
                break
            } catch {
                NSLog("[Camera] Streaming wait attempt %d failed: %@", attempt, error.localizedDescription)
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

            NSLog("[Camera] Calling capturePhoto(format: .jpeg)...")
            let success = streamSession!.capturePhoto(format: .jpeg)
            if !success {
                self.photoContinuation = nil
                // capturePhoto returned false — fall back to latest video frame
                if let fallback = self.latestFrameAsJPEG() {
                    NSLog("[Camera] capturePhoto returned false, using latest video frame")
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
                        NSLog("[Camera] Photo capture timed out, using latest video frame (%d bytes)", fallback.count)
                        cont.resume(returning: fallback)
                    } else {
                        NSLog("[Camera] Photo capture timed out, no video frame available")
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

        print("📸 Photo captured: \(photoData.count) bytes")
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
        guard let session = streamSession else { return }
        switch session.state {
        case .stopped, .stopping:
            return
        default:
            session.stop()
            lastFrameTime = .distantPast
            NSLog("[Camera] Stream paused after capture (session kept warm)")
        }
    }

    private func scheduleIdleTeardown() {
        idleTeardownTask?.cancel()
        idleTeardownTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionIdleGrace)
            guard let self, !Task.isCancelled else { return }
            guard !self.isStreaming, !self.isCaptureInProgress else { return }
            NSLog("[Camera] Idle grace elapsed — tearing session down")
            await self.resetSession()
        }
    }

    private func handlePhotoData(_ photoData: PhotoData) {
        guard let continuation = photoContinuation else {
            NSLog("[Camera] Photo data received but no continuation waiting (timeout may have fired first)")
            return
        }
        photoContinuation = nil
        NSLog("[Camera] Photo captured via SDK (%d bytes)", photoData.data.count)
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
                NSLog("[Camera] Latest frame is stale (%.0fs old) — refusing frame fallback",
                      Date().timeIntervalSince(lastFrameTime))
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
        continuousStreamingIntent = true

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
            try await ensureSession()
            try await waitForStreaming()
        } catch {
            continuousStreamingIntent = false
            throw error
        }

        isStreaming = true
        events.send(.streamingChanged(true))
        startStallDetection()
        NSLog("[Camera] Streaming started")
    }

    /// Stop continuous video streaming. Session is kept alive for reuse.
    func stopStreaming() async {
        continuousStreamingIntent = false
        guard isStreaming else { return }
        stopStallDetection()
        if let session = streamSession {
            session.stop()
        }
        isStreaming = false
        events.send(.streamingChanged(false))
        latestFrame = nil
        events.send(.frame(nil))
        NSLog("[Camera] Streaming stopped (session kept alive)")
    }

    // MARK: - HEVC Decoder Stall Detection & Auto-Recovery

    /// Start monitoring for decoder stalls (no frames for 1.5 seconds).
    /// If a stall is detected, the session is torn down and recreated.
    private func startStallDetection() {
        stopStallDetection()
        lastFrameTime = Date()
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
                    continue
                }

                let elapsed = Date().timeIntervalSince(self.lastFrameTime)
                if elapsed > 1.5 {
                    NSLog("[Camera] ⚠️ Decoder stall detected (%.1fs since last frame) — auto-recovering", elapsed)
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
        NSLog("[Camera] Stall recovery #%d (%@)", stallRecoveryCount, String(describing: action))
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
            consecutiveRecoveryFailures = 0
            NSLog("[Camera] Stall recovery successful — streaming resumed")
        } catch {
            consecutiveRecoveryFailures += 1
            NSLog("[Camera] Stall recovery failed (%d consecutive): %@",
                  consecutiveRecoveryFailures, error.localizedDescription)
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
        if let camera = cameraCapability {
            camera.stop()  // cascades to the stream
            await awaitCameraStopped(camera)
        }
        await streamListenerBag.cancelAll()
        cameraCapability = nil
        streamSession = nil
        activeStreamResolution = nil
        NSLog("[Camera] Camera capability torn down (session retained)")
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
        NSLog("[Camera] Camera did not reach .stopped within %.0fs — proceeding",
              Double(timeout.components.seconds))
    }

    /// Reset the session completely (for error recovery).
    private func resetSession() async {
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        if let camera = cameraCapability {
            camera.stop()
            // Wait for the capability to actually free (see `awaitCameraStopped`) so the
            // retry loop's next `ensureSession` doesn't collide with the dying camera.
            await awaitCameraStopped(camera)
        }
        deviceSession?.stop()
        await streamListenerBag.cancelAll()
        cameraCapability = nil
        streamSession = nil
        activeStreamResolution = nil
        deviceSession = nil
        // A torn-down session's frames must not survive to serve as "photos" for the next
        // capture — the staleness gate is belt, this is braces.
        latestFrame = nil
        events.send(.frame(nil))
        lastFrameTime = .distantPast
        NSLog("[Camera] Session reset")
    }

    /// Tear down everything — called on mode switch or app termination.
    func tearDown() async {
        await stopStreaming()
        await resetSession()
        permissionGranted = false
        NSLog("[Camera] Torn down completely")
    }
}
