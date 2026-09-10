import Foundation
import UIKit

/// Tool for face recognition — remember, forget, and list known faces.
/// The actual recognition happens continuously via FaceRecognitionService;
/// this tool handles the "remember this person" / "who do I know" commands.
struct FaceRecognitionTool: NativeTool {
    let name = "face_recognition"
    let description = "Remember, forget, or list known faces. Say 'remember this person as [name]' to save a face, 'forget [name]' to remove, or 'list faces' to see who you know. Faces are recognized automatically when the camera is active."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'remember' (save face with name), 'forget' (remove by name), 'list' (show all known faces), 'toggle' (enable/disable recognition)"
            ],
            "name": [
                "type": "string",
                "description": "Person's name for remember/forget actions"
            ]
        ],
        "required": ["action"]
    ]

    weak var faceService: FaceRecognitionService?
    /// Stays a `CameraService`: the "toggle" action starts `FaceRecognitionService`, which needs
    /// the raw frame publisher. The still this tool takes for enrolment still goes through
    /// `filteredStill(for:)` — under `.faceRecognition`, the scope that says do not filter.
    weak var cameraService: CameraService?

    init(faceService: FaceRecognitionService, cameraService: CameraService) {
        self.faceService = faceService
        self.cameraService = cameraService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.faceRecognition) else {
            return AIFeatureGate.disabledMessage(.faceRecognition)
        }
        guard let action = args["action"] as? String else {
            return "No action specified. Use 'remember', 'forget', 'list', or 'toggle'."
        }

        guard let service = faceService else {
            return "Face recognition service not available."
        }

        switch action.lowercased() {
        case "remember":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "Please provide a name for the person."
            }
            // `.faceRecognition` is the one model-facing scope that is never filtered, and it
            // says so here rather than by omitting the call: the blur is indiscriminate, so
            // filtering ahead of enrolment would blur the very face being enrolled.
            let frame = await cameraService?.filteredStill(for: .faceRecognition).image
            guard let image = frame else {
                return "No camera frame available. Make sure the glasses camera is active."
            }
            return await service.rememberFace(name: name, from: image)

        case "forget":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "Please specify whose face to forget."
            }
            return await MainActor.run { service.forgetFace(name: name) }

        case "list":
            return await MainActor.run { service.listKnownFaces() }

        case "toggle", "on", "off":
            let isCurrentlyActive = await MainActor.run { service.isActive }
            let shouldEnable = action == "on" || (action == "toggle" && !isCurrentlyActive)
            if shouldEnable {
                guard let camera = cameraService else {
                    return "Camera service not available."
                }
                await MainActor.run { service.start(cameraService: camera) }
                return "Face recognition enabled. I'll quietly tell you when I recognize someone."
            } else {
                await MainActor.run { service.stop() }
                return "Face recognition disabled."
            }

        default:
            return "Unknown action '\(action)'. Use 'remember', 'forget', 'list', or 'toggle'."
        }
    }
}
