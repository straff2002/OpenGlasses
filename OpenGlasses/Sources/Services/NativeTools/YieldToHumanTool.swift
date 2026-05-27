import Foundation

/// Lets the AI hand control back to the human for tasks it cannot perform:
/// payments, logins, CAPTCHAs, physical actions, or anything requiring human judgment.
///
/// When called, the tool breaks out of the LLM tool-calling loop and speaks the reason
/// to the wearer. The conversation resumes naturally when the wearer says "done" or "continue".
struct YieldToHumanTool: NativeTool {
    let name = "yield_to_human"
    let description = """
        Hand control to the human for tasks you cannot do: payments, logins, CAPTCHAs, \
        physical actions, or anything requiring human judgment. Explain what they need to do \
        and wait for them to say "done" or "continue" before resuming. Only use in agentic mode.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "reason": [
                "type": "string",
                "description": "What the human needs to do and why"
            ],
            "instructions": [
                "type": "string",
                "description": "Step-by-step instructions for the human (optional)"
            ]
        ],
        "required": ["reason"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard Config.agentModeEnabled else {
            return "yield_to_human is only available in agentic mode. Enable it in Settings → Agent."
        }

        let reason = args["reason"] as? String ?? "Human intervention needed"
        let instructions = args["instructions"] as? String

        var response = "YIELD_TO_HUMAN: \(reason)"
        if let instructions {
            response += "\nInstructions: \(instructions)"
        }
        response += "\nWaiting for you to say \"done\" or \"continue\" when ready."

        NSLog("[YieldToHuman] Yielding control: %@", reason)
        return response
    }
}
