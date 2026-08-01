import Foundation

/// Plan CE — voice control for frame pinning: "pin this", "hold that thought", "let go".
/// Voice is the primary interface on glasses, where there is no screen to long-press. The pin
/// itself lives on AppState (`FramePin`); this tool is a thin voice adapter over it.
struct PinFrameTool: NativeTool {
    let name = "pin_frame"
    let description = """
        Pin the current camera frame so 'this' keeps meaning the same thing while the user \
        looks around: while pinned you receive the pinned frame instead of live video, so keep \
        answering about the pinned scene. Use when the user says 'pin this', 'hold that \
        thought', or asks follow-ups about one object. Unpin ('let go', 'unpin') to resume \
        live view. Actions: 'pin', 'unpin', 'status'.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'pin' (freeze the current frame), 'unpin' (resume live view), or 'status'."
            ]
        ],
        "required": ["action"] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let appState = AppStateProvider.shared else {
            return "Frame pinning isn't available right now."
        }
        guard Config.framePinEnabled else {
            return "Frame pinning is disabled in Settings."
        }

        let action = (args["action"] as? String ?? "status").lowercased()
        switch action {
        case "pin":
            if appState.framePin.isPinned {
                return "A frame is already pinned. Say unpin first to pin a new one."
            }
            return appState.pinCurrentFrame()
                ? "Pinned the current frame. I'll keep looking at this scene until you unpin."
                : "No camera frame available to pin — is the camera streaming?"
        case "unpin", "release":
            guard appState.framePin.isPinned else { return "Nothing is pinned." }
            appState.releaseFramePin(trigger: .explicitUnpin)
            return "Unpinned — back to live view."
        default:
            if let pinnedAt = appState.framePin.pinnedAt {
                let seconds = Int(Date().timeIntervalSince(pinnedAt))
                return "A frame is pinned (\(seconds)s ago). Say unpin to release it."
            }
            return "Nothing is pinned; you're on live view."
        }
    }
}
