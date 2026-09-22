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

    /// The open job, when there is one (Plan FO P2a). A plain capture taken during a visit is
    /// evidence of that visit — the technician said "look at this" while standing in front of the
    /// machine — so it joins the job's photos with its time, its task and the reason it was taken,
    /// and is then offered (not assumed) at the close-job review. Nil when nothing is wired, which
    /// is every build of this tool that is not the app's own.
    var jobEvidence: (any JobEvidenceFiling)?

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
        let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Two requests rather than one `.cachedFrameThenPhoto`, so the log still distinguishes a
        // reused stream frame from a fresh shutter — the two have different battery and latency
        // stories and the diagnostics pane reads them apart.
        if let still = await cameraService.filteredStill(for: .toolPhotoCapture).still,
           let raw = still.jpegData(compressionQuality: 0.8) {
            fileOnTheJob(raw, reason: reason)
            return reply(LLMImagePreparer.prepared(raw), event: .captureFallbackUsed)
        }

        // `source: .photoOnly` and not `CameraService.capturePhoto()`: the shutter image is exempt
        // for its *existing* consumer — the wearer's own framed shot in their Photos library — and
        // this one is neither. It goes to a cloud model and, while a job is open, into a record a
        // customer will read.
        let captured = await cameraService.filteredStill(for: .toolPhotoCapture, source: .photoOnly)
        guard let raw = captured.jpegData(compressionQuality: 0.8) else {
            return "Could not capture photo. Make sure the glasses are connected and camera is active."
        }
        fileOnTheJob(raw, reason: reason)
        return reply(LLMImagePreparer.prepared(raw), event: .photoCaptured)
    }

    /// Attach the still to the open job, if one is open. The bytes are the filtered ones the
    /// accessor returned — the same copy the model gets — because filtering is not inherited and
    /// the archive is the copy that survives.
    private func fileOnTheJob(_ data: Data, reason: String?) {
        guard let jobEvidence, jobEvidence.isOpenForEvidence else { return }
        jobEvidence.attachPhoto(data,
                                caption: reason?.isEmpty == false ? reason : nil,
                                origin: .capture,
                                filterWasOn: Config.privacyFilterEnabled)
    }

    /// `data` is already bounded by `LLMImagePreparer` — Anthropic's 5 MB inline cap.
    private func reply(_ data: Data, event: PrivacyLog.CameraEvent) -> String {
        let sizeKB = data.count / 1024
        PrivacyLog.camera(.glasses, event, kilobytes: sizeKB)
        return "[IMAGE_CAPTURED:\(data.base64EncodedString())] Photo captured successfully (\(sizeKB) KB). Analyze the image to respond to the user."
    }
}
