import Foundation
import AVFoundation
import Combine
import Photos
import MWDATCore
import MWDATCamera
import UIKit

/// Service for capturing photos and streaming video from Ray-Ban Meta smart glasses.
///
/// Uses a single persistent `StreamSession` for both photo capture and video streaming,
/// following Meta's official sample app pattern.
@MainActor
class CameraService: ObservableObject {
    @Published var lastPhoto: UIImage?
    @Published var isCaptureInProgress: Bool = false
    @Published var isStreaming: Bool = false
    @Published var streamingStatus: StreamingStatus = .stopped

    enum StreamingStatus: String {
        case streaming, waiting, stopped
    }

    private let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var streamSession: StreamSession?
    private var photoListenerToken: (any AnyListenerToken)?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?
    private var photoContinuation: CheckedContinuation<Data, Error>?

    /// Whether camera permission has been granted (cached to avoid re-checking).
    var permissionGranted = false

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

    /// Name of the Photos album where glasses photos are saved.
    private nonisolated static let albumName = "Glasses"

    // MARK: - Permission

    private func waitForRegistration(minState: Int, timeoutSeconds: Double) async -> Int {
        let waitStart = ContinuousClock.now
        while true {
            let state = Wearables.shared.registrationState.rawValue
            onRegistrationProgress?(state)
            if state >= minState { return state }
            if ContinuousClock.now - waitStart > .seconds(timeoutSeconds) { return state }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func ensurePermission() async throws {
        if permissionGranted { return }

        let regState = Wearables.shared.registrationState
        NSLog("[Camera] SDK state: %d (need 3 for camera permissions)", regState.rawValue)
        onRegistrationProgress?(regState.rawValue)

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
                if (error as? CameraError) == .permissionDenied { throw error }
                if attempt == maxAttempts - 1 { throw CameraError.sdkNotRegistered }
            }
        }
    }

    // MARK: - Persistent Session

    /// Ensure the persistent stream session exists. Creates it on first call.
    private func ensureSession() {
        guard streamSession == nil else { return }
        let session = StreamSession(
            streamSessionConfig: StreamSessionConfig(
                videoCodec: .raw,
                resolution: .high,
                frameRate: 15
            ),
            deviceSelector: deviceSelector
        )
        streamSession = session
        attachListeners(to: session)
        NSLog("[Camera] Created persistent StreamSession (.high, 15fps)")
    }

    /// Attach all publishers to the session (state, video frames, photo data, errors).
    private func attachListeners(to session: StreamSession) {
        var frameCount = 0

        stateListenerToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                NSLog("[Camera] State changed: %@", String(describing: state))
                switch state {
                case .streaming:
                    self.streamingStatus = .streaming
                case .waitingForDevice:
                    self.streamingStatus = .waiting
                case .stopped:
                    self.streamingStatus = .stopped
                    self.isStreaming = false
                case .stopping, .starting, .paused:
                    self.streamingStatus = .waiting
                @unknown default:
                    break
                }
            }
        }

        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                guard let self else { return }
                frameCount += 1
                if let image = frame.makeUIImage() {
                    self.latestFrame = image
                    if frameCount <= 3 || frameCount % 30 == 0 {
                        NSLog("[Camera] Video frame #%d (%dx%d)",
                              frameCount, Int(image.size.width), Int(image.size.height))
                    }
                    self.onVideoFrame?(image)
                    self.framePublisher.send(image)
                }
            }
        }

        photoListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                self?.handlePhotoData(photoData)
            }
        }

        errorListenerToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                let message = Self.friendlyErrorMessage(error)
                NSLog("[Camera] Error: %@", message)
                self?.onDebugEvent?("Camera error: \(message)")
            }
        }
    }

    /// Wait for the session to reach `.streaming` state, starting it if necessary.
    private func waitForStreaming(timeout: TimeInterval = 20) async throws {
        guard let session = streamSession else { throw CameraError.captureFailed }

        if session.state == .streaming { return }

        // Start the session if not already running
        if session.state == .stopped {
            await session.start()
        }

        // Poll for streaming state
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if session.state == .streaming { return }
            if session.state == .stopped {
                NSLog("[Camera] Session stopped unexpectedly while waiting for streaming")
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw CameraError.streamNotReady
    }

    // MARK: - Photo Capture

    /// Capture a photo from the glasses camera. Returns JPEG data.
    /// Reuses the persistent session — starts it if needed, does NOT stop it after capture.
    func capturePhoto() async throws -> Data {
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }

        try await ensurePermission()
        ensureSession()

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
                    ensureSession()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        if let error = lastError { throw error }

        // Capture using continuation
        let photoData: Data = try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation

            NSLog("[Camera] Calling capturePhoto(format: .jpeg)...")
            let success = streamSession!.capturePhoto(format: .jpeg)
            if !success {
                self.photoContinuation = nil
                continuation.resume(throwing: CameraError.captureFailed)
                return
            }

            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    cont.resume(throwing: CameraError.timeout)
                }
            }
        }

        if let image = UIImage(data: photoData) {
            lastPhoto = image
        }

        // Stop streaming after capture to save battery (unless explicitly streaming)
        if !isStreaming {
            if let session = streamSession {
                await session.stop()
            }
        }

        print("📸 Photo captured: \(photoData.count) bytes")
        return photoData
    }

    private func handlePhotoData(_ photoData: PhotoData) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(returning: photoData.data)
    }

    // MARK: - Continuous Video Streaming (for Gemini Live)

    /// Start continuous video streaming from the glasses camera.
    func startStreaming() async throws {
        guard !isStreaming else { return }

        try await ensurePermission()
        ensureSession()
        try await waitForStreaming()

        isStreaming = true
        NSLog("[Camera] Streaming started")
    }

    /// Stop continuous video streaming. Session is kept alive for reuse.
    func stopStreaming() async {
        guard isStreaming else { return }
        if let session = streamSession {
            await session.stop()
        }
        isStreaming = false
        latestFrame = nil
        NSLog("[Camera] Streaming stopped (session kept alive)")
    }

    /// Reset the session completely (for error recovery).
    private func resetSession() async {
        if let session = streamSession {
            await session.stop()
        }
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoListenerToken = nil
        errorListenerToken = nil
        streamSession = nil
        NSLog("[Camera] Session reset")
    }

    /// Tear down everything — called on mode switch or app termination.
    func tearDown() async {
        await stopStreaming()
        await resetSession()
        permissionGranted = false
        NSLog("[Camera] Torn down completely")
    }

    // MARK: - Photo Library

    /// Save photo data to the "Glasses" album in the photo library.
    func saveToPhotoLibrary(_ data: Data) {
        guard let image = UIImage(data: data) else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                NSLog("[Camera] Photo library access denied")
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)

                // Find or create the "Glasses" album
                if let album = self.fetchGlassesAlbum() {
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
                    // Fallback: save without album
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    print("📸 Photo saved to camera roll (album unavailable)")
                }
            }
        }
    }

    /// Fetch the "Glasses" album, creating it if it doesn't exist.
    private nonisolated func fetchGlassesAlbum() -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", CameraService.albumName)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)

        if let existing = collections.firstObject {
            return existing
        }

        // Create the album synchronously
        var localIdentifier: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: CameraService.albumName)
                localIdentifier = createRequest.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            NSLog("[Camera] Failed to create Glasses album: %@", error.localizedDescription)
            return nil
        }

        guard let identifier = localIdentifier else { return nil }
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
        return result.firstObject
    }

    // MARK: - Audio Session Helpers

    /// Restore audio session configuration for wake word detection after camera streaming.
    func restoreAudioForWakeWord() {
        // No-op: audio session management is handled by WakeWordService
    }

    // MARK: - Error Mapping

    /// Map StreamSession errors to user-friendly descriptions.
    private static func friendlyErrorMessage(_ error: any Error) -> String {
        let description = String(describing: error).lowercased()
        if description.contains("hingesclosed") {
            return "Glasses hinges are closed — open them to use the camera"
        } else if description.contains("thermalcritical") || description.contains("thermal") {
            return "Glasses are too hot — let them cool down"
        } else if description.contains("permission") {
            return "Camera permission required"
        } else if description.contains("devicenotavailable") || description.contains("notavailable") {
            return "Glasses camera not available — check Bluetooth connection"
        }
        return error.localizedDescription
    }
}

enum CameraError: LocalizedError {
    case permissionDenied
    case captureFailed
    case timeout
    case notConnected
    case sdkNotRegistered
    case streamNotReady

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied"
        case .captureFailed: return "Failed to capture photo"
        case .timeout: return "Photo capture timed out"
        case .notConnected: return "Glasses not connected"
        case .sdkNotRegistered: return "Meta SDK not registered — open Meta app first"
        case .streamNotReady: return "Camera stream not ready — try again"
        }
    }
}
