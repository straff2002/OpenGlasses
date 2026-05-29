import Foundation
import UIKit

/// Identifies a banknote's denomination for a low-vision user. Captures the frame and hands it to the
/// main multimodal LLM with a focused directive (same pattern as `reading_assist` / `capture_photo`),
/// so it works with whichever vision model is configured.
@MainActor
final class MoneyIdentifierTool: NativeTool {
    let name = "identify_money"
    let description = """
    Identify a banknote / bill the user is holding, for low-vision support. Captures the glasses view \
    and reads the currency and denomination aloud. Use for "how much is this note?", "what bill is this?".
    """
    let parametersSchema: [String: Any] = [
        "type": "object", "properties": [:], "required": [] as [String]
    ]

    private let cameraService: CameraService
    init(cameraService: CameraService) { self.cameraService = cameraService }

    func execute(args: [String: Any]) async throws -> String {
        let data: Data?
        if let frame = cameraService.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.85) {
            data = jpeg
        } else {
            data = try? await cameraService.capturePhoto()
        }
        guard let data else {
            return "I couldn't capture the note. Hold it flat in view and try again."
        }
        let directive = "Identify this banknote for a low-vision user: state the currency and " +
            "denomination in one short sentence (e.g. 'This is a US 20 dollar bill'). If it isn't a " +
            "clearly visible banknote, say so — do not guess."
        return "[IMAGE_CAPTURED:\(data.base64EncodedString())] \(directive)"
    }
}
