import AVFoundation
import Combine
import Foundation
import Photos
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
class CameraService: ObservableObject {
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

    /// The most recent video frame captured from the glasses camera
    private(set) var latestFrame: UIImage?

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
        case .frame(let image):
            latestFrame = image
            guard let image else { return }
            onVideoFrame?(image)
            framePublisher.send(image)
        case .status(let status):
            streamingStatus = status
        case .streamingChanged(let streaming):
            isStreaming = streaming
            if streaming {
                streamingNotice = nil
                NoticeCenter.shared.clear(source: .camera)   // the condition has cleared
            }
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
            NSLog("[Camera] Glasses camera unavailable — capturing from iPhone back camera")
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

    /// Start continuous video streaming from the glasses camera.
    func startStreaming() async throws {
        // Plan CQ P1: refuse with a readable reason on hardware that has no live feed at all,
        // rather than letting the backend fail in a way the caller has to interpret.
        if case .unavailable(let reason) = availability(of: .livePreview) {
            throw CameraError.unsupported(reason)
        }
        isStartingStream = true
        defer { isStartingStream = false }
        try await backend.startStreaming()
    }

    /// Stop continuous video streaming. Session is kept alive for reuse.
    func stopStreaming() async {
        await backend.stopStreaming()
    }

    /// Tear down everything — called on mode switch or app termination.
    func tearDown() async {
        await backend.tearDown()
        latestFrame = nil
    }

    // MARK: - Photo Library

    /// Save photo data to the "Glasses" album in the photo library.
    func saveToPhotoLibrary(_ data: Data) {
        guard let image = UIImage(data: data) else { return }

        GlassesPhotoAlbum.ensureAddOnlyAuthorization { status in
            guard status == .authorized || status == .limited else {
                NSLog("[Camera] Photo library access denied")
                return
            }

            let album = GlassesPhotoAlbum.resolveAlbum()

            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)

                if let album {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    if let placeholder = creationRequest.placeholderForCreatedAsset {
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                    }
                }
            } completionHandler: { success, error in
                if success {
                    print("📸 Photo saved to Glasses album")
                } else if let error {
                    NSLog("[Camera] Save to album failed: %@", error.localizedDescription)
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    print("📸 Photo saved to camera roll (album unavailable)")
                }
            }
        }
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
