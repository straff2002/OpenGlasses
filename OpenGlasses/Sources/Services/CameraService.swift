import Foundation
import MWDATCore
import MWDATCamera
import UIKit

/// Service for capturing photos from Ray-Ban Meta smart glasses camera
@MainActor
class CameraService: ObservableObject {
    @Published var lastPhoto: UIImage?
    @Published var isCaptureInProgress: Bool = false

    private var streamSession: StreamSession?
    private var photoListenerToken: (any AnyListenerToken)?
    private var stateListenerToken: (any AnyListenerToken)?
    private var photoContinuation: CheckedContinuation<Data, Error>?

    /// Capture a photo from the glasses camera
    /// Returns JPEG data of the captured photo
    func capturePhoto() async throws -> Data {
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }

        // Request camera permission from the glasses
        let permissionStatus = try await Wearables.shared.requestPermission(.camera)
        guard permissionStatus == .granted else {
            throw CameraError.permissionDenied
        }

        // Create a stream session to access the camera
        let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
        let session = StreamSession(
            streamSessionConfig: StreamSessionConfig(
                videoCodec: .raw,
                resolution: .high,
                frameRate: 15
            ),
            deviceSelector: deviceSelector
        )
        streamSession = session

        // Listen for photo data
        photoListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                self?.handlePhotoData(photoData)
            }
        }

        // Start the stream (required before capture)
        await session.start()

        // Wait briefly for streaming to stabilize
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s

        // Capture the photo
        let photoData: Data = try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation

            let success = session.capturePhoto(format: .jpeg)
            if !success {
                self.photoContinuation = nil
                continuation.resume(throwing: CameraError.captureFailed)
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

        // Stop the stream
        await session.stop()
        cleanup()

        // Store the image for display
        if let image = UIImage(data: photoData) {
            lastPhoto = image
        }

        print("📸 Photo captured: \(photoData.count) bytes")
        return photoData
    }

    private func handlePhotoData(_ photoData: PhotoData) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(returning: photoData.data)
    }

    private func cleanup() {
        photoListenerToken = nil
        stateListenerToken = nil
        streamSession = nil
    }

    /// Save photo to the camera roll
    func saveToPhotoLibrary(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        print("📸 Photo saved to camera roll")
    }
}

enum CameraError: LocalizedError {
    case permissionDenied
    case captureFailed
    case timeout
    case notConnected

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied"
        case .captureFailed: return "Failed to capture photo"
        case .timeout: return "Photo capture timed out"
        case .notConnected: return "Glasses not connected"
        }
    }
}
