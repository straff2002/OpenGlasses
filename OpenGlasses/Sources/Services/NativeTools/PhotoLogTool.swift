import Foundation
import UIKit

/// Capture a photo from the glasses camera and attach it to the active Field Assist session's
/// audit log with a caption (e.g. a gauge reading at a procedure step). The image is also returned
/// for immediate analysis, so the AI can read the captured value in the same turn.
///
/// Photos are stored under the session's `photos/` directory and referenced in `log.jsonl`,
/// preserving a defensible record for warranty / EPA 608 / work-order export.
@MainActor
final class PhotoLogTool: NativeTool {
    let name = "photo_log"
    let description = """
    Capture a photo from the glasses camera and attach it to the active Field Assist session log \
    with a caption (e.g. 'suction gauge 118 PSIG', 'nameplate', 'leak site'). Returns the image for \
    analysis too. Use to document readings and evidence during a session. Requires an active session.
    """
    /// Typed as the privacy chokepoint (W04.1): the still is archived in the session log *and*
    /// sent to the model, so both copies must be the filtered one.
    let cameraService: any FilteredStillProviding

    /// Where the still is filed. The app's shared session service; injected in a test, which must
    /// not write into the real Documents directory to prove a caption reached a log (Plan FO P2a).
    let jobEvidence: any JobEvidenceFiling

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "caption": [
                "type": "string",
                "description": "Caption describing what the photo documents (e.g. 'suction gauge reading', 'compressor nameplate')."
            ]
        ],
        "required": [] as [String]
    ]

    init(cameraService: any FilteredStillProviding,
         jobEvidence: (any JobEvidenceFiling)? = nil) {
        self.cameraService = cameraService
        self.jobEvidence = jobEvidence ?? FieldSessionService.shared
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard jobEvidence.isOpenForEvidence else {
            return "No active Field Assist session. Start a session before logging photos."
        }
        let caption = (args["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let imageData = await cameraService
            .filteredStill(for: .toolPhotoCapture, source: .cachedFrameThenPhoto)
            .jpegData(compressionQuality: 0.8) else {
            return "Could not capture a photo. Make sure the glasses are connected and the camera is active."
        }

        guard jobEvidence.attachPhoto(imageData, caption: caption, origin: .photoLog,
                                      filterWasOn: Config.privacyFilterEnabled) != nil else {
            return "Captured the photo but could not attach it to the session log."
        }

        let sizeKB = imageData.count / 1024
        // Archive the full-res original (attachPhoto above); cap only the copy bound for the LLM.
        let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
        let captionNote = caption.map { " Caption: \($0)." } ?? ""
        return "[IMAGE_CAPTURED:\(base64)] Photo logged to the session (\(sizeKB) KB).\(captionNote) Analyze the image to read any values, then continue."
    }
}
