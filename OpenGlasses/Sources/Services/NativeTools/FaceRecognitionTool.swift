import Foundation
import UIKit

/// Tool for face recognition — enrol, forget and list the people the wearer has enrolled, and switch
/// recognition on or off. Matching runs in `FaceRecognitionService`, and only after `toggle`/`on`
/// has started it; with nobody enrolled there is nothing to match.
///
/// `remember` is the one action that is asked about first: it is classed `.biometricEnrolment`
/// (`ToolEffectClassifier.isFaceEnrolment`), so the shared approval card and the spoken "Approve?"
/// come before any template is stored (Plan HP P2 item 9).
struct FaceRecognitionTool: NativeTool {
    let name = "face_recognition"
    let description = "Enrol, forget or list the faces of people the user has chosen to enrol, and switch face recognition on or off. Recognition only runs after it has been switched on ('on' or 'toggle'), and it only ever names people the user enrolled with 'remember'; nobody is recognised automatically before that. Enrolling asks the user to approve first, and the person being enrolled isn't told. Use 'remember' with a name while the person is in view, 'forget' with a name to remove them, 'list' to say who is enrolled."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'remember' (enrol the face in view under a name, after the user approves), 'forget' (remove by name), 'list' (who is enrolled), 'toggle', 'on' or 'off' (start or stop recognising enrolled people)"
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
