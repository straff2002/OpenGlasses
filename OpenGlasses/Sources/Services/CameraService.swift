import AVFoundation
import Combine
import Foundation
import UIKit

/// Backend-neutral camera coordinator.
///
/// Plan CQ P1 split this in two. Everything that talks to a *device* — sessions, streams,
/// permissions, stall recovery — moved behind `GlassesCameraBackend` (`MetaCameraBackend` is the
/// DAT implementation, extracted unchanged). What stayed here is everything that is true no
/// matter which glasses are connected: the published state features observe, the iPhone-camera
/// fallback, the photo-library write, and the cached frame.
///
/// The public surface is deliberately identical to what it was before the split — roughly fifty
/// files consume this type, and none of them should have to know a backend exists.
@MainActor
class CameraService: ObservableObject, FilteredStillProviding {
    @Published var lastPhoto: UIImage?
    @Published var isCaptureInProgress: Bool = false
    @Published var isStreaming: Bool = false

    /// Something the wearer can fix right now — currently a stream paused by a doff. Cleared when
    /// streaming resumes, so a stale notice cannot outlive the condition it describes.
    @Published var streamingNotice: String?

    /// True while `startStreaming()` is in flight. The glasses camera cold-starts in seconds — a
    /// session, then a stream, then the first frame — and device-traced 2026-08-23 that was up to
    /// 20 s of a button that said "Camera" and looked broken, so the wearer pressed it repeatedly.
    /// Work that takes that long has to say it is working.
    @Published var isStartingStream: Bool = false
    @Published var streamingStatus: CameraStreamingStatus = .stopped

    // MARK: - Readiness (Plan FD P0)

    /// The single answer to "is the camera ready?", for consumers that used to each have their own.
    ///
    /// `isStreaming`, a non-nil cached still, `isStartingStream` and user intent are four different
    /// facts, and reading any one of them as "ready" is what let a control bar say **Streaming**
    /// over a frozen preview and let a vision turn answer from a picture taken in the previous
    /// room. `CameraReadiness` keeps them apart: a phase to show, an age for evidence, a session
    /// identity, and the intent flag that Start/Connect decisions read instead of frames.
    /// Its `frameAge` is as at the moment the snapshot was taken, which is what a view wants: a
    /// view re-renders when the snapshot changes, and the phase is what it shows.
    @Published private(set) var readiness: CameraReadiness = .cleared(session: 0)

    /// The same snapshot with the freshness clock read **now**.
    ///
    /// The two exist separately for one reason: `@Published` fires on an event, and time passing is
    /// not an event. A gate that asked the published snapshot whether its picture was fresh would
    /// really be asking how old that picture was *when the last event happened* — which, for a
    /// stream that simply stopped delivering, is always "brand new". Actions that need to see
    /// something read this; displays read the published one.
    var readinessNow: CameraReadiness { makeReadiness() }

    /// A monotonic clock, injectable so a test can age a frame without waiting.
    ///
    /// `systemUptime` rather than `Date()` deliberately: this measures how long ago something
    /// happened, and a wall clock that a time-zone change or an NTP correction can move backwards
    /// would make a frame look newer than it is.
    var monotonicClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// When the newest *fresh* picture of this session was published, on `monotonicClock`. A held
    /// picture — the decoder handing the previous one over again — does not move it.
    private var lastFreshPictureAt: TimeInterval?

    /// The backend's last reported reason for not delivering pictures. Never inferred here.
    private var waitReason: CameraWaitReason?

    /// Whether continuous streaming is still wanted, as this coordinator was asked. Not a second
    /// owner of the session: the backend keeps its own intent for its recovery ladder, and this is
    /// simply the record of what the app asked *this* object for, which is what a UI gate needs.
    private var userWantsStream = false

    /// Which camera session the service is on. Bumped by every stop, so a snapshot from before a
    /// replacement is recognisably about a camera that no longer exists.
    var streamSessionIdentity: Int { startGeneration.sessionIdentity }

    /// Whether `snapshot` still describes the camera that is running now.
    func isCurrent(_ snapshot: CameraReadiness) -> Bool {
        snapshot.describes(session: streamSessionIdentity)
    }

    private func makeReadiness() -> CameraReadiness {
        CameraReadiness.derive(
            waitReason: waitReason,
            streamIsUp: isStreaming,
            startIsPending: isStartingStream,
            userWantsStream: userWantsStream,
            frameAge: lastFreshPictureAt.map { monotonicClock() - $0 },
            session: streamSessionIdentity)
    }

    private func refreshReadiness() { readiness = makeReadiness() }

    /// Forget everything known about this session's pictures. Called where the camera the pictures
    /// came from has gone away — a cleared cache, a stop, a teardown — so that "no picture yet"
    /// and "a picture from the session before last" can never be the same answer.
    private func clearFrameEvidence() {
        lastFreshPictureAt = nil
        latestFrame = nil
    }

    /// Kept as a nested name for the call sites that grew up with it.
    typealias StreamingStatus = CameraStreamingStatus

    /// BR P2: actionable compatibility copy ("update the Meta AI app…") when the device layer
    /// reports an update requirement. Nil when compatible. Observed by AppState for a
    /// one-time announcement.
    @Published private(set) var compatibilityNotice: String?

    /// The device-facing half. Injectable so tests can drive the coordinator without hardware
    /// (and without touching `Wearables`, which traps in a unit-test process).
    private let backend: GlassesCameraBackend
    private var backendEvents: AnyCancellable?

    /// Callback for continuous video frames (used by Gemini Live mode)
    var onVideoFrame: ((UIImage) -> Void)?

    /// Debug event callback for connection status logging
    var onDebugEvent: ((String) -> Void)?

    /// Combine publisher for video frames (used by recording/broadcast services).
    let framePublisher = PassthroughSubject<UIImage, Never>()

    /// The most recent video frame captured from the glasses camera.
    ///
    /// **Raw pixels.** Only the consumers `OutboundFrameConsumer` lists under an unfiltered scope
    /// may read this — the on-device Vision taps, the phone's own preview, face recognition. Every
    /// reader that sends a still to a model, writes one to disk or Photos, or hands one to another
    /// process goes through `filteredStill(for:source:)` instead, and
    /// `OutboundFrameConsumerTests` fails the build for a reader that does neither.
    private(set) var latestFrame: UIImage?

    /// Whether a still exists at all, without handing anyone the pixels. What a liveness or
    /// readiness check actually wants — reading `latestFrame != nil` for it puts a raw-pixel read
    /// in a file that has no business holding one.
    var hasLatestStill: Bool { latestFrame != nil }

    /// The dimensions of the latest still, without the pixels. Video bitrate and output size are
    /// derived from this; the frame itself is not needed and must not be taken.
    var latestStillSize: CGSize? { latestFrame?.size }

    /// The still-image blur chokepoint. Wired by `AppState`, which owns the filter.
    ///
    /// Weak, and deliberately optional: absent, every filtered scope returns
    /// `.unavailable(.filterNotWired)` rather than raw pixels, so forgetting the wiring costs the
    /// feature rather than the bystander.
    weak var privacyFilter: (any StillImageFiltering)?

    /// Optional callback to report SDK registration progress (state 0–3) back to UI.
    var onRegistrationProgress: ((Int) -> Void)?

    /// Whether camera permission has been granted (cached to avoid re-checking).
    var permissionGranted: Bool {
        get { backend.permissionGranted }
        set { backend.permissionGranted = newValue }
    }

    /// iPhone back-camera fallback, used when the glasses camera is unavailable. Injectable for
    /// the same reason `backend` is: this is the branch taken whenever the glasses camera can't
    /// serve a capture, so a test of *that* decision otherwise reaches real AVFoundation and, on
    /// a simulator with an unresolved camera privacy decision, hangs waiting for a prompt.
    private let phoneSource: PhoneCameraCapturing

    /// `nil` means the default Meta/DAT backend and the real iPhone camera. The backend is built
    /// here rather than as a default argument because a default argument expression is evaluated
    /// nonisolated, and the backend is main-actor bound; the phone source takes the same shape so
    /// both halves of the capture decision are substituted the same way.
    init(backend: GlassesCameraBackend? = nil, phoneCamera: PhoneCameraCapturing? = nil) {
        let backend = backend ?? MetaCameraBackend()
        self.backend = backend
        self.phoneSource = phoneCamera ?? PhoneCameraSource()
        backendEvents = backend.events.sink { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Capabilities (Plan CQ P1)

    /// What the current backend can do. Static per backend.
    var capabilities: CameraCapabilities { backend.capabilities }

    /// Capabilities of the glasses camera *if one is reachable right now*, else nil. This is the
    /// input `GlassesTierPolicy` wants: "connected but limited" and "not connected" are different
    /// statements and Settings must not collapse them.
    ///
    /// Side-effect-free, because this is read from view bodies — see
    /// `GlassesCameraBackend.isReady(configuringIfNeeded:)`.
    var activeCapabilities: CameraCapabilities? {
        backend.isReady(configuringIfNeeded: false) ? backend.capabilities : nil
    }

    /// Whether a feature that needs the camera can run on the connected glasses, and if not,
    /// what to tell the user. Prefer this over discovering the answer as a thrown error.
    func availability(of feature: CameraDependentFeature) -> CameraFeatureAvailability {
        CameraFeatureGate.availability(of: feature, given: backend.capabilities)
    }

    // MARK: - Backend events

    private func handle(_ event: CameraBackendEvent) {
        switch event {
        case .frame(let image, let fresh):
            guard let image else {
                // The backend invalidated the cache: the session that produced those pixels is
                // gone, so the age of its last picture is not a fact about any camera any more.
                clearFrameEvidence()
                refreshReadiness()
                return
            }
            latestFrame = image
            // Only a freshly produced picture moves the clock. The app keeps seeing a held one —
            // that is why one is held — but it is not a new view of the world, and the whole point
            // of the age is that it answers "how long since the camera last saw something".
            if fresh { lastFreshPictureAt = monotonicClock() }
            refreshReadiness()
            onVideoFrame?(image)
            framePublisher.send(image)
        case .status(let status):
            streamingStatus = status
            refreshReadiness()
        case .waitReason(let reason):
            waitReason = reason
            refreshReadiness()
        case .streamingChanged(let streaming):
            isStreaming = streaming
            if streaming {
                streamingNotice = nil
                NoticeCenter.shared.clear(source: .camera)   // the condition has cleared
            }
            refreshReadiness()
        case .debug(let message):
            onDebugEvent?(message)
        case .compatibilityNotice(let notice):
            compatibilityNotice = notice
            if let notice {
                NoticeCenter.shared.post(notice, severity: .warning, source: .glasses)
            } else {
                NoticeCenter.shared.clear(source: .glasses)
            }
        case .transientNotice(let notice):
            streamingNotice = notice
            onDebugEvent?(notice)
            NoticeCenter.shared.post(notice, severity: .advisory, source: .camera)
        case .registrationProgress(let state):
            onRegistrationProgress?(state)
        }
    }

    // MARK: - Permission

    func ensurePermission() async throws {
        try await backend.ensurePermission()
    }

    // MARK: - Photo Capture

    /// Capture a photo. Returns JPEG data.
    /// EVERY captured image is saved to the photo library ("Glasses" album) for later review —
    /// centralized here so no capture path can forget it.
    ///
    /// Deliberately NOT privacy-filtered (product decision, 2026-09-10): this is the wearer's own
    /// framed photograph, their record to keep. The bystander blur applies to ambient and automatic
    /// captures, which go through `filteredStill(for:source:)`; a reader that wants the shutter
    /// image filtered asks for it with `source: .photoOnly` on that accessor instead of calling here.
    func capturePhoto() async throws -> Data {
        // When the glasses camera is offline / not connected / not registered, capture from the
        // iPhone back camera instead so the vision tools keep working without glasses. This is
        // also what lets them work on a device (or simulator) where the glasses SDK never came up.
        //
        // But when the glasses ARE usable, a failed glasses capture must FAIL — not silently
        // swap to the phone camera. Live-traced: the phone was on the desk, every "photo"
        // showed the desk, and the assistant confidently described it while the user pointed
        // their glasses at something else. A wrong-camera photo is worse than an error.
        //
        // Plan CQ P1: a backend that cannot capture stills at all falls the same way as one that
        // isn't ready — the phone is the only camera left, and callers announce the swap.
        let data: Data
        if backend.isReady(configuringIfNeeded: true) && backend.capabilities.stillCapture {
            isCaptureInProgress = true
            defer { isCaptureInProgress = false }
            data = try await backend.capturePhoto()
            lastCaptureSource = .glasses
            if let image = UIImage(data: data) {
                lastPhoto = image
            }
        } else {
            PrivacyLog.camera(.glasses, .unavailable)
            data = try await phoneSource.capturePhoto()
            lastCaptureSource = .phone
        }
        saveToPhotoLibrary(data)
        return data
    }

    /// Which camera actually served the last successful `capturePhoto()`. Callers use this to
    /// ANNOUNCE a phone-camera capture — a silently swapped camera made the assistant describe
    /// the desk the phone was lying on while the user pointed the glasses elsewhere.
    enum CaptureSource { case glasses, phone }
    private(set) var lastCaptureSource: CaptureSource = .glasses

    // MARK: - Continuous Video Streaming

    /// Which start the stream is currently obeying. See `StreamStartGeneration`: the glasses
    /// camera cold-starts in up to 20 s, and a stop issued inside that window used to be lost.
    private var startGeneration = StreamStartGeneration()

    /// The start currently in flight, if any. Plan FD P1 — see `startStreaming()`.
    private var inFlightStart: Task<Bool, Error>?

    /// Plan FD P1 — automatic camera work currently armed, across the coordinator and its backend.
    ///
    /// The assertion behind "stop leaves nothing running": after a stop this is zero, and a late
    /// callback has nothing left to land on. Counts the coordinator's in-flight start plus
    /// whatever the backend reports (retry rungs, stall and idle timers, transitions in flight).
    var scheduledCameraWorkCount: Int {
        backend.scheduledWorkCount + (inFlightStart == nil ? 0 : 1)
    }

    /// Start continuous video streaming, coalescing onto a start already in flight.
    ///
    /// Plan FD P1. Two features can reach for the camera at the same moment — the wearer's own
    /// control and a live session's claim, a claim and a narration session — and the glasses
    /// camera cold-starts for up to twenty seconds, which is a very wide window to be second in.
    /// Both callers used to get their own trip through the backend: two device sessions, two
    /// `addCamera` calls racing for one process-wide capability, and whichever lost threw
    /// `capabilityAlreadyActive` at a caller that had done nothing wrong. Now the second caller
    /// awaits the first start's outcome and gets the same answer, including `false` for a start a
    /// stop superseded.
    ///
    /// - Returns: whether the stream actually came up. `false` means a stop landed while the
    ///   camera was still cold-starting: the start released what it had acquired and is a no-op,
    ///   rather than an error the caller should show anybody. A caller holding something that
    ///   depends on the stream — a claim, a session flag — has to put it back when this is `false`.
    @discardableResult
    func startStreaming() async throws -> Bool {
        // Plan CQ P1: refuse with a readable reason on hardware that has no live feed at all,
        // rather than letting the backend fail in a way the caller has to interpret. Checked
        // before coalescing: it is a fact about the hardware, not about this attempt.
        if case .unavailable(let reason) = availability(of: .livePreview) {
            throw CameraError.unsupported(reason)
        }
        if let existing = inFlightStart { return try await existing.value }
        let start = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.inFlightStart = nil }
            return try await self.performStart()
        }
        inFlightStart = start
        return try await start.value
    }

    private func performStart() async throws -> Bool {
        let token = startGeneration.beginStart()
        isStartingStream = true
        // Intent is recorded *before* the await, and it is what keeps the cold-start window honest:
        // for up to twenty seconds there is no stream and no frame, and the only true statement
        // about the camera in that window is that somebody wants it on.
        userWantsStream = true
        refreshReadiness()
        defer {
            isStartingStream = false
            refreshReadiness()
        }
        try await backend.startStreaming()
        // Plan EW. Everything above this line took seconds, and a stop may have landed inside it.
        // If one did, this start has been superseded: release the stream the cold start just
        // brought up instead of publishing it as running. A late start that claims the camera
        // anyway holds the process-wide capability with nothing consuming its frames.
        guard startGeneration.finish(token) == .commit else {
            await backend.stopStreaming()
            return false
        }
        return true
    }

    /// Stop continuous video streaming. Session is kept alive for reuse.
    ///
    /// Always forwarded, and always safe to repeat: the backend, not this method, decides whether
    /// there is anything left to stop.
    func stopStreaming() async {
        startGeneration.recordStop()   // also ends this camera session, for readiness identity
        userWantsStream = false
        // Plan FD P1: the in-flight start is *not* cancelled here, and that is deliberate. It is
        // inside the backend's cold start, which has device work to unwind; the generation above
        // is what makes it release rather than publish, and it clears its own record on the way
        // out. Cancelling it would abandon that unwinding mid-flight.
        // Readiness does not survive the camera it described: the next start is a different
        // session, and a snapshot taken before this line must not be mistaken for one taken after.
        clearFrameEvidence()
        waitReason = nil
        refreshReadiness()
        await backend.stopStreaming()
    }

    /// Tear down everything — called on mode switch or app termination.
    func tearDown() async {
        startGeneration.recordStop()   // nothing may survive a teardown, a cold start included
        userWantsStream = false
        await backend.tearDown()
        clearFrameEvidence()
        waitReason = nil
        refreshReadiness()   // no readiness describes a camera that no longer exists, either
        streamClaims.reset()   // no claim describes a camera that no longer exists
    }

    // MARK: - Stream claims (Plan CV)

    /// Who is holding the stream open. See `CameraStreamClaims` for why a bare start/stop pair is
    /// not enough once more than one feature can start the camera.
    private var streamClaims = CameraStreamClaims()

    /// The consumers that never claim — recording, broadcast, WebRTC, a live realtime session.
    /// Wired by `AppState`; the neutral default keeps the service constructible in tests.
    var otherStreamConsumersActive: () -> Bool = { false }

    /// True while any feature holds a claim. The unmigrated ad-hoc owners consult this before
    /// their own `stopStreaming()`, so a claim is honoured even by code that doesn't make one.
    var hasStreamClaims: Bool { !streamClaims.isEmpty }

    func holdsStreamClaim(_ owner: CameraStreamClaims.Owner) -> Bool { streamClaims.holds(owner) }

    /// Take a claim on the video stream, starting it if nothing else has.
    ///
    /// Throws whatever `startStreaming()` throws, and drops the claim on the way out — a claim on a
    /// stream that never came up would make every later release think it had something to give
    /// back.
    func claimStream(for owner: CameraStreamClaims.Owner) async throws {
        switch streamClaims.claim(owner, streamRunning: isStreaming) {
        case .alreadyRunning, .alreadyClaimed:
            return
        case .startStream:
            do {
                // A stop that overtook the cold start leaves nothing to hold a claim on, and a
                // claim on a stream that never came up would make every later release think it
                // had something to give back.
                if try await startStreaming() == false { streamClaims.abandon(owner) }
            } catch {
                streamClaims.abandon(owner)
                throw error
            }
        }
    }

    /// Give a claim back, stopping the stream only if this claim started it and nothing else — a
    /// claim or an unclaimed consumer — still wants it.
    func releaseStream(for owner: CameraStreamClaims.Owner) async {
        let outcome = streamClaims.release(owner,
                                           streamRunning: isStreaming,
                                           otherConsumersActive: otherStreamConsumersActive())
        guard outcome == .stopStream else { return }
        await stopStreaming()
    }

    // MARK: - Photo Library

    /// Save photo data to the "Glasses" album in the photo library.
    ///
    /// The album work, and the one authorization prompt behind it, live in `GlassesPhotoAlbum` —
    /// this used to be one of two private copies.
    func saveToPhotoLibrary(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        Task {
            let result = await GlassesPhotoAlbum.saveImage(image)
            if case .notPermitted(let status) = result {
                // Not an error to swallow: on a fresh install this is the whole reason a capture
                // is nowhere to be found afterwards.
                PrivacyLog.camera(.glasses, .photoNotSaved,
                                  state: GlassesPhotoAlbumPolicy.statusToken(status))
            }
        }
    }

    // MARK: - Filtered stills (W04.1)

    /// The single way to obtain a camera still for a purpose.
    ///
    /// Replaces the `latestFrame ?? capturePhoto()` fallback that used to be copied into every
    /// reader, and folds the privacy decision into it so the two cannot drift apart. The scope is
    /// required, not defaulted: a reader that has not decided what its still is *for* has not
    /// decided whether a bystander's face may travel with it.
    ///
    /// Fails closed at every step. No frame is `.unavailable(.noStill)`; a filtered scope with no
    /// filter wired is `.unavailable(.filterNotWired)`; a filtered scope the filter cannot serve
    /// right now — backgrounded, device locked, Vision failed — is `.unavailable(.filterUnavailable)`.
    /// None of them return the source pixels.
    func filteredStill(for scope: PrivacyFilterScope,
                       source: FilteredStillSource = .cachedFrameOnly) async -> FilteredStillResult {
        var image: UIImage?
        /// The bytes a capture arrived as, kept so an unfiltered path can hand them straight on
        /// instead of paying a decode and a re-encode for pixels nothing changed.
        var capturedData: Data?

        // Plan FD P0. The cached picture is only evidence while it is current. A reader asking this
        // accessor is about to answer a question about what is in front of the wearer *now* —
        // "what does this label say", "is there a barcode", "describe the scene" — and a held or
        // aged picture answers it with the previous room. `CameraReadiness.evidenceMaxAge` sits
        // just above the backend's stall threshold on purpose, so the existing stall detector is
        // still the first thing to notice a stopped picture flow and this is the backstop.
        let cached = readinessNow.hasFreshVisualEvidence ? latestFrame : nil

        switch source {
        case .cachedFrameOnly:
            image = cached
        case .cachedFrameThenPhoto:
            if let cached {
                image = cached
            } else if let captured = try? await capturePhoto() {
                capturedData = captured
                image = UIImage(data: captured)
            }
        case .photoOnly:
            if let captured = try? await capturePhoto() {
                capturedData = captured
                image = UIImage(data: captured)
            }
        }

        guard let image else {
            // Say which of the two it is. A reader that held a picture and was refused it because
            // it had gone stale is in a different situation from one the camera never fed at all,
            // and the second answer is the one a wearer can act on.
            return .unavailable(hasLatestStill && source != .photoOnly ? .noFreshView : .noStill)
        }
        // The size the camera produced, recorded before the filter can rewrite it (Plan FF P1/PR4).
        let sourcePixelSize = image.pixelSize
        guard scope.isFiltered else {
            return .still(FilteredStill(image: image, scope: scope, sourceData: capturedData,
                                        sourcePixelSize: sourcePixelSize))
        }
        guard let privacyFilter else { return .unavailable(.filterNotWired) }
        guard let filtered = privacyFilter.filteredOrUnavailable(image, for: scope) else {
            return .unavailable(.filterUnavailable)
        }
        // Identity, not equality: the filter hands back the very same image when it was a no-op
        // (filter off, or Vision verified no faces), and only then may the original bytes stand in.
        return .still(FilteredStill(image: filtered, scope: scope,
                                    sourceData: filtered === image ? capturedData : nil,
                                    sourcePixelSize: sourcePixelSize))
    }

    // MARK: - Audio Session Helpers

    /// Restore audio session configuration for wake word detection after camera streaming.
    func restoreAudioForWakeWord() {
        // No-op: audio session management is handled by WakeWordService
    }

    // Error mapping now lives in the pure, typed `CameraErrorPolicy` (DAT unified `DatError` model).
}

enum CameraError: LocalizedError {
    case permissionDenied
    case captureFailed
    case timeout
    case notConnected
    case sdkNotRegistered
    case streamNotReady
    case sessionBusy
    /// The session was refused for a compatibility reason (e.g. the glasses-side DAT app is
    /// too old for this SDK). Carries the actionable `DATCompatibilityMessage` copy.
    case incompatible(String)
    /// Plan CQ P1: the connected glasses simply cannot do this. Carries the gate's reason,
    /// which is written to be shown to a user as-is.
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied"
        case .captureFailed: return "Failed to capture photo"
        case .timeout: return "Photo capture timed out"
        case .notConnected: return "Glasses not connected"
        case .sdkNotRegistered: return "Meta SDK not registered — open Meta app first"
        case .streamNotReady: return "Camera stream not ready — try again"
        case .sessionBusy: return "The glasses are still releasing a previous camera session — try again in about a minute"
        case .incompatible(let message): return message
        case .unsupported(let message): return message
        }
    }
}
