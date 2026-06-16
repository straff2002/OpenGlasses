import Foundation

/// How hard an action is to undo — drives the safety rules (irreversible actions always
/// confirm, never auto-run) and the validator (an irreversible step must be confirmed).
enum Reversibility: String, Codable, Equatable {
    case reversible          // read-only / informational (web_search, weather, …)
    case partiallyReversible // has external effect but recoverable (a note, a draft)
    case irreversible        // outward-facing / hard to take back (send a message, place a call)
}

/// One concrete action in an agent plan (Plan S). `args` is JSON-shaped (`[String: Any]`),
/// so `AgentStep` can't be auto-`Equatable`; equality compares the stable, comparable fields.
struct AgentStep: Identifiable {
    let id: UUID
    let tool: String                 // qualified tool name the NativeToolRouter understands
    let args: [String: Any]
    let rationale: String            // one line, for the HUD / spoken trace
    let reversibility: Reversibility // from the static `ToolReversibility` table unless overridden
    /// Set by `PlanValidator` for steps that must get an explicit user confirmation before running.
    var requiresConfirmation: Bool

    init(id: UUID = UUID(),
         tool: String,
         args: [String: Any] = [:],
         rationale: String = "",
         reversibility: Reversibility? = nil,
         requiresConfirmation: Bool = false) {
        self.id = id
        self.tool = tool
        self.args = args
        self.rationale = rationale
        self.reversibility = reversibility ?? ToolReversibility.of(tool)
        self.requiresConfirmation = requiresConfirmation
    }
}

extension AgentStep: Equatable {
    /// Compares everything except the opaque `args` bag (not `Equatable`); `id` plus the
    /// comparable fields are enough to distinguish steps in tests and de-dup.
    static func == (lhs: AgentStep, rhs: AgentStep) -> Bool {
        lhs.id == rhs.id &&
        lhs.tool == rhs.tool &&
        lhs.rationale == rhs.rationale &&
        lhs.reversibility == rhs.reversibility &&
        lhs.requiresConfirmation == rhs.requiresConfirmation
    }
}

/// A validated, ordered list of steps toward a goal. The executor treats this as the single
/// source of truth — tool output is never fed back into planning, so an injected instruction
/// in a result can't rewrite the goal.
struct AgentPlan: Equatable {
    let goal: String
    var steps: [AgentStep]

    init(goal: String, steps: [AgentStep]) {
        self.goal = goal
        self.steps = steps
    }
}

/// Static reversibility classification for known tools. Kept deterministic and dependency-free
/// so it's usable from the pure planner/validator/supervisor. Defaults to `.reversible`
/// (read-only) for anything not listed; the conservative entries are the outward-facing tools.
enum ToolReversibility {
    /// Irreversible / hard-to-undo, outward-facing actions. Seeded from the same list the
    /// inbound defense already treats as high-impact, so the two stay in sync.
    static var irreversible: Set<String> { PromptInjectionPolicy.highImpactTools }

    /// Has an external effect but is recoverable (drafts, notes, calendar entries).
    static let partiallyReversible: Set<String> = [
        "create_note", "contextual_note", "meeting_summary", "calendar", "set_reminder",
    ]

    static func of(_ tool: String) -> Reversibility {
        if irreversible.contains(tool) { return .irreversible }
        if partiallyReversible.contains(tool) { return .partiallyReversible }
        return .reversible
    }
}
