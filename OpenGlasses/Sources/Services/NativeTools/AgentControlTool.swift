import Foundation

/// Voice control for a remote coding/agent session (Plan N): the on-device LLM calls this to start,
/// check, cancel, or confirm a run on the active `AgentHarness`. Gated behind `agentModeEnabled` —
/// the project convention for gateway/autonomous features — so it's inert unless the user opts in.
/// Dispatch + narration live in `AgentSessionService`; this is just the tool surface.
@MainActor
struct AgentControlTool: NativeTool {
    let name = "code_agent"

    let description = """
    Control a remote coding agent (e.g. via the OpenClaw gateway) hands-free. Use action "start" with \
    a "prompt" (and optional "project") to dispatch a task like adding a feature or fixing a bug; \
    "status" to hear how the current run is going; "cancel" to stop it; "confirm"/"deny" to answer a \
    safety confirmation the agent is waiting on (e.g. before pushing). Only available when Agent Mode \
    is enabled in Settings. The result is spoken; the agent narrates progress and a final summary.
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["start", "status", "cancel", "confirm", "deny", "switch_harness"],
                    "description": "What to do. Defaults to start.",
                ],
                "prompt": [
                    "type": "string",
                    "description": "For action=start: the task for the agent, e.g. 'add a dark-mode toggle'.",
                ],
                "project": [
                    "type": "string",
                    "description": "Optional project/repo the agent should act on.",
                ],
                "harness": [
                    "type": "string",
                    "enum": AgentHarnessKind.allCases.map(\.rawValue),
                    "description": "For action=switch_harness: which configured backend to make the default.",
                ],
                "attach": [
                    "type": "boolean",
                    "description": "For action=start: attach what the camera is looking at. Set true "
                        + "for tasks about something physically present (a label, serial plate, "
                        + "receipt, form) so the agent reads it directly instead of your description "
                        + "of it; set false to keep the task text-only. Omit to decide automatically.",
                ],
            ],
            "required": [] as [String],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.agentModeEnabled else {
            return "Agent Mode is off. Turn it on in Settings to dispatch or control a remote coding agent."
        }

        let session = AgentSessionService.shared
        let action = (args["action"] as? String ?? "start").lowercased()

        switch action {
        case "start":
            guard let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else {
                return "What should the agent do? Give me a task to start."
            }
            let project = (args["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch await session.dispatch(prompt: prompt,
                                          project: project?.isEmpty == false ? project : nil,
                                          explicitAttach: args["attach"] as? Bool) {
            case .success(let run):
                return "Started the agent on \(run.project ?? "your task"). I'll let you know when it's done."
            case .failure(let error):
                return "Couldn't start the agent: \(error.localizedDescription)"
            }

        case "status":
            return session.currentStatusLine()

        case "cancel":
            await session.cancel()
            return "Cancelling the agent run."

        case "confirm", "approve", "yes":
            // BN P1: the tool call only ASKS — approval comes from the user-distinct consent
            // prompt. A prompt-injected turn can reach this case; it must never self-approve.
            return await session.confirmPendingActionViaUserPrompt()

        case "deny", "decline", "no":
            await session.respondToConfirmation(approved: false)
            return "Okay, I won't proceed."

        case "switch_harness", "switch":
            guard let raw = args["harness"] as? String,
                  let kind = AgentHarnessKind.matching(raw) else {
                let options = AgentHarnessKind.allCases.map(\.displayName).joined(separator: ", ")
                return "Which agent backend? Options: \(options)."
            }
            guard session.registry?.harness(for: kind)?.isConfigured == true else {
                return "\(kind.displayName) isn't configured. Set it up in Settings first."
            }
            Config.setDefaultAgentHarness(kind)
            return "Switched the agent backend to \(kind.displayName)."

        default:
            return "Unknown agent action '\(action)'. Try start, status, cancel, confirm, or deny."
        }
    }
}
