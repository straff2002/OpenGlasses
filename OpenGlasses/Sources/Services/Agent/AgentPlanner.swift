import Foundation

enum AgentPlannerError: Error { case noCompletion, unparseable, emptyPlan }

/// Builds an `AgentPlan` from a user request (Plan S). The model call is injected as a closure
/// (`complete`) so the planner is testable without a network, and so the call can be made
/// **stateless** — it must not pollute the live conversation history, since tool output (and the
/// planning exchange itself) must never feed back into the agent's reasoning. The JSON→plan
/// decoding is a pure, deterministic function.
@MainActor
final class AgentPlanner {

    /// Performs the planning model call. Returns the model's raw text (expected to contain a JSON
    /// object). Injected by `LLMService` (a tools-off, history-snapshotted completion).
    var complete: ((_ request: String, _ system: String) async throws -> String)?

    func plan(request: String, availableTools: [String]) async throws -> AgentPlan {
        guard let complete else { throw AgentPlannerError.noCompletion }
        let raw = try await complete(request, Self.systemPrompt(tools: availableTools))
        return try Self.decode(raw, goal: request)
    }

    // MARK: - Pure decoding

    /// Parse a plan from the model's raw text. Tolerates code fences / surrounding prose by
    /// extracting the first balanced top-level JSON object. Falls back to `goal` if the model
    /// omits one. Throws when no usable plan can be read.
    static func decode(_ raw: String, goal: String) throws -> AgentPlan {
        guard let json = extractJSONObject(from: raw),
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw AgentPlannerError.unparseable
        }
        let planGoal = (obj["goal"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? goal
        let rawSteps = obj["steps"] as? [[String: Any]] ?? []
        let steps: [AgentStep] = rawSteps.compactMap { dict in
            guard let tool = (dict["tool"] as? String)?.trimmingCharacters(in: .whitespaces), !tool.isEmpty else { return nil }
            let args = dict["args"] as? [String: Any] ?? [:]
            let rationale = (dict["rationale"] as? String) ?? (dict["why"] as? String) ?? ""
            return AgentStep(tool: tool, args: args, rationale: rationale)
        }
        guard !steps.isEmpty else { throw AgentPlannerError.emptyPlan }
        return AgentPlan(goal: planGoal, steps: steps)
    }

    /// Extract the first balanced `{ … }` object from `text` (string-aware, so braces inside
    /// quoted values don't confuse the depth count).
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // MARK: - Prompt

    static func systemPrompt(tools: [String]) -> String {
        """
        You are a planning module. Read the user's request and output a concise JSON plan and NOTHING ELSE.

        Output exactly this shape, JSON only (no markdown, no commentary):
        {"goal": "<short restatement>", "steps": [{"tool": "<tool name>", "args": {<json args>}, "rationale": "<at most 8 words>"}]}

        Rules:
        - Use ONLY these tools: \(tools.sorted().joined(separator: ", ")).
        - If the request needs a capability not in that list, leave it out — never invent a tool.
        - Order the steps so each one can run with what's known at that point. Keep it minimal.
        - High-impact or irreversible steps (sending messages, calling, smart-home, exports) will be
          confirmed with the user at run time — include them when needed, but don't add extras.
        - Output the JSON object only.
        """
    }
}
