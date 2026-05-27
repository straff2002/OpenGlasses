import Foundation
import UIKit

/// Allows the AI to proactively capture a photo from the glasses camera.
/// Unlike the existing DocumentScanTool (OCR-focused) or BarcodeScannerTool,
/// this tool simply captures and returns image data for the LLM to analyze.
/// Inspired by VisionClaw's capture_photo tool.
struct CapturePhotoTool: NativeTool {
    let name = "capture_photo"
    let description = "Capture a photo from the smart glasses camera for visual analysis. Use when you need to see what the user is looking at, or when the user says 'look at this', 'what do you see', 'take a photo'. Returns the image for your analysis."

    let cameraService: CameraService

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "reason": [
                "type": "string",
                "description": "Brief reason for capturing (shown to user). E.g. 'Let me take a look at that.'"
            ]
        ],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        // First check if we have a recent frame already available
        if let latestFrame = await MainActor.run(body: { cameraService.latestFrame }),
           let data = latestFrame.jpegData(compressionQuality: 0.8) {
            let base64 = data.base64EncodedString()
            let sizeKB = data.count / 1024
            NSLog("[CapturePhoto] Using latest frame (%d KB)", sizeKB)
            return "[IMAGE_CAPTURED:\(base64)] Photo captured successfully (\(sizeKB) KB). Analyze the image to respond to the user."
        }

        // Fall back to explicit photo capture
        do {
            let photoData = try await cameraService.capturePhoto()
            let base64 = photoData.base64EncodedString()
            let sizeKB = photoData.count / 1024
            NSLog("[CapturePhoto] Captured photo (%d KB)", sizeKB)
            return "[IMAGE_CAPTURED:\(base64)] Photo captured successfully (\(sizeKB) KB). Analyze the image to respond to the user."
        } catch {
            return "Could not capture photo: \(error.localizedDescription). Make sure the glasses are connected and camera is active."
        }
    }
}
