import Foundation

extension Notification.Name {
    /// Posted when the user asks for a fresh conversation ("new topic", "start over"). AppState
    /// observes it and hands the request to the conversation-reset coordinator, which is what
    /// actually retires each backend's context — the tool stays decoupled from those services,
    /// matching how the registry is wired before AppState finishes building.
    static let ogNewTopicRequested = Notification.Name("OGNewTopicRequested")
}

/// Hands-free conversation reset. Reachable two ways: the classifier's Tier-0 deterministic route
/// (a bare "new topic" never burns an LLM turn) and normal tool-calling for phrasings the
/// classifier doesn't match ("please forget everything we just talked about").
///
/// The actual clearing is deferred-safe: the coordinator waits for the turn boundary before it
/// retires anything, because wiping context mid-loop would orphan the pending tool_result and 400
/// the next request — and would rotate a gateway session key out from under a tool result still
/// owed to the old session.
@MainActor
final class NewTopicTool: NativeTool {
    let name = "new_topic"
    let description = """
    Start a fresh conversation: clears the assistant's memory of the current chat so the next \
    question starts with a clean slate. Use when the user says "new topic", "start over", "start \
    fresh", "clear the conversation", or "forget this conversation". Takes no parameters. Saved \
    notes, memories, and settings are NOT affected — only the current chat context.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any]
    ]

    /// Returns a neutral acknowledgement rather than awaiting the reset.
    ///
    /// Awaiting it here would deadlock: the coordinator retires context only after the turn
    /// boundary, and this turn cannot reach its boundary until this tool returns. The alternative
    /// — returning a success line immediately, as this did before — announced a fresh start before
    /// a single backend had been asked, which is the claim this plan exists to stop. So the tool
    /// records the request and the coordinator owns the spoken confirmation, emitted only once the
    /// selected backends have actually crossed the reset boundary. The model's own wording for
    /// this turn belongs to the retired context and is suppressed by the generation gate.
    func execute(args: [String: Any]) async throws -> String {
        NotificationCenter.default.post(name: .ogNewTopicRequested, object: nil)
        return "Conversation reset requested. The app confirms it out loud once the context is "
            + "actually cleared — say nothing further."
    }
}
