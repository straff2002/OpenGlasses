import Foundation
import UIKit

/// Allows the AI to proactively capture a photo from the glasses camera.
/// Unlike the existing DocumentScanTool (OCR-focused) or BarcodeScannerTool,
/// this tool simply captures and returns image data for the LLM to analyze.
/// Inspired by VisionClaw's capture_photo tool.
struct CapturePhotoTool: NativeTool {
    let name = "capture_photo"
    let description = "Capture a photo from the smart glasses camera for visual analysis. Use when you need to see what the user is looking at, or when the user says 'look at this', 'what do you see', 'take a photo'. Returns the image for your analysis."

    /// Typed as the privacy chokepoint (W04.1): this tool's whole job is to produce a still that
    /// goes to the model, so the unfiltered accessor must not be within its reach.
    let cameraService: any FilteredStillProviding

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
        // Two requests rather than one `.cachedFrameThenPhoto`, so the log still distinguishes a
        // reused stream frame from a fresh shutter — the two have different battery and latency
        // stories and the diagnostics pane reads them apart.
        if let still = await cameraService.filteredStill(for: .toolPhotoCapture).still,
           let raw = still.jpegData(compressionQuality: 0.8) {
            return reply(LLMImagePreparer.prepared(raw), event: .captureFallbackUsed)
        }

        let captured = await cameraService.filteredStill(for: .toolPhotoCapture, source: .photoOnly)
        guard let raw = captured.jpegData(compressionQuality: 0.8) else {
            return "Could not capture photo. Make sure the glasses are connected and camera is active."
        }
        return reply(LLMImagePreparer.prepared(raw), event: .photoCaptured)
    }

    /// `data` is already bounded by `LLMImagePreparer` — Anthropic's 5 MB inline cap.
    private func reply(_ data: Data, event: PrivacyLog.CameraEvent) -> String {
        let sizeKB = data.count / 1024
        PrivacyLog.camera(.glasses, event, kilobytes: sizeKB)
        return "[IMAGE_CAPTURED:\(data.base64EncodedString())] Photo captured successfully (\(sizeKB) KB). Analyze the image to respond to the user."
    }
}
