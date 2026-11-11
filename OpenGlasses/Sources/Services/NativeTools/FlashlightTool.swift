import Foundation
import AVFoundation

/// Toggles the device flashlight (torch) on or off.
struct FlashlightTool: NativeTool {
    let name = "flashlight"
    let description = "Turn the device flashlight (torch) on or off."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'on', 'off', or 'toggle'. Defaults to toggle."
            ]
        ],
        "required": [] as [String]
    ]

    /// Plan LA: the torch's new state is set on the device itself, so it is done.
    static func completion(turnedOn: Bool) -> ActionCompletion {
        .done(summary: turnedOn ? "Torch on" : "Torch off")
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else {
            return "This device doesn't have a flashlight."
        }

        let action = (args["action"] as? String ?? "toggle").lowercased()

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let newState: Bool
            switch action {
            case "on":
                newState = true
            case "off":
                newState = false
            default: // toggle
                newState = device.torchMode != .on
            }

            if newState {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                ActionCompletionReport.record(Self.completion(turnedOn: true))
                return "Flashlight turned on."
            } else {
                device.torchMode = .off
                ActionCompletionReport.record(Self.completion(turnedOn: false))
                return "Flashlight turned off."
            }
        } catch {
            return "Couldn't control the flashlight: \(error.localizedDescription)"
        }
    }
}
