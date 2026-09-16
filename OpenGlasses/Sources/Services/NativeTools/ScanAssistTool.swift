import Foundation

/// Hands-free control of Scan Assist's directional reminders.
///
/// Deterministic on purpose (docs/plans/FB-scan-assist.md P2: "feature operation cannot depend on
/// an LLM choosing a reminder"). Every branch below is a `switch` over an action string and an
/// optional side; nothing here asks a model anything, and the classifier's Tier-0 route reaches it
/// without a model in the loop at all. The model-invoked path exists only for phrasings the
/// classifier doesn't match, and it lands in the same `switch`.
///
/// Two rules the code enforces rather than documents:
///
/// **The side comes from the phrase, or it is asked for.** There is no inference — not from the
/// previous session, not from which side the wearer used last time, not from anything a camera
/// saw. An action that needs a side and wasn't given one returns the question.
///
/// **Every answer names the side.** A misheard "left" for "right" is otherwise invisible until the
/// first reminder arrives thirty seconds later, pointing the wrong way.
@MainActor
struct ScanAssistTool: NativeTool {
    let name = "scan_assist"
    let description = """
    Control Scan Assist, the accessibility feature that plays a spoken or sounded reminder to \
    check one side (the wearer's own left or right) at a set interval during a finite session. \
    Actions: "start", "pause", "resume", "stop", "status", and "set_side" (with "side": "left" or \
    "right") to choose which side reminders point to. Use for "start/pause/stop scan reminders", \
    "remind me to check my left", "which side am I checking". If the request does not clearly say \
    left or right, call set_side WITHOUT a side and the tool will ask — never guess a side, and \
    never infer one from a photo, a previous session, or the user's history. Scan Assist does not \
    use the camera and cannot tell whether the user actually checked anything.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "pause", "resume", "stop", "status", "set_side"],
                "description": "What to do. Defaults to \"status\"."
            ] as [String: Any],
            "side": [
                "type": "string",
                "enum": ["left", "right"],
                "description": "The wearer's own left or right, taken only from what they said. Omit when they did not say."
            ] as [String: Any]
        ] as [String: Any],
        "required": ["action"]
    ]

    /// Resolved at execution time, like the other tools that reach live app state: the registry is
    /// built before the session service is wired, and capturing it here would capture nothing.
    var serviceProvider: @MainActor () -> ScanAssistService? = { ScanAssistService.shared }

    func execute(args: [String: Any]) async throws -> String {
        guard let service = serviceProvider() else {
            return "Scan Assist isn't available right now."
        }

        let action = (args["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "status"
        let side = (args["side"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap(ScanAssistSide.init(rawValue:))

        switch action {
        case "set_side":
            // No side in the phrase means no side change. Asking costs one exchange; guessing
            // costs a whole session spent practising the side the wearer didn't choose.
            guard let side else { return ScanAssistCopy.whichSideQuestion }
            service.chooseSide(side)
            // Naming a side is also how someone starts: "remind me to check my left" is a request
            // for reminders, not a preference edit. An already-live session keeps its own timing —
            // `start()` is a no-op on one, so this never resets the wearer's remaining minutes.
            service.start()
            return answer(from: service)

        case "start":
            if let side { service.chooseSide(side) }
            guard service.settings.side != nil else { return ScanAssistCopy.needsSideChoice }
            service.start()
            return answer(from: service)

        case "pause":
            service.pause()
            return answer(from: service)

        case "resume":
            if let side { service.chooseSide(side) }
            service.resume()
            return answer(from: service)

        case "stop":
            service.stop()
            return answer(from: service)

        case "status":
            return answer(from: service)

        default:
            return "Scan Assist can start, pause, resume or stop reminders, set which side they "
                + "point to, or say which side is set."
        }
    }

    /// The one place an answer is built, so no branch above can accidentally reply without saying
    /// which side the wearer is now on.
    private func answer(from service: ScanAssistService) -> String {
        guard let side = service.settings.side else { return ScanAssistCopy.needsSideChoice }
        switch service.state {
        case .running: return ScanAssistCopy.remindersRunning(side)
        case .paused: return ScanAssistCopy.remindersPaused(side)
        case .ended(.stopped): return ScanAssistCopy.remindersStopped(side)
        case .ended(.expired), .idle: return ScanAssistCopy.remindersNotRunning(side)
        }
    }
}
