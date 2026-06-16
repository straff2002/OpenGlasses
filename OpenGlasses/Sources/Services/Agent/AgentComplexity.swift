import Foundation

/// Decides whether a request is worth the deliberate plan-then-execute loop, or should stay
/// single-shot (Plan S). A pure, conservative keyword heuristic — no LLM, so it never adds a
/// round-trip just to classify.
///
/// Deliberately biased toward **single-shot**: a miss is cheap (the normal tool loop can still
/// chain calls, and the `SafetySupervisor` still vetoes each one), whereas a false positive
/// would route ordinary chat ("what's the weather") through the planner. So the bar is a clear
/// sequencer word *and* at least two distinct action cues.
enum AgentComplexity {

    /// Words that chain one action to the next.
    private static let sequencers = [" then ", " and then ", ", then", " after that", " next, ", " and "]

    /// Verb-ish cues that suggest a tool action (kept lowercase; matched as substrings).
    private static let actionCues: [String] = [
        "photo", "photograph", "picture", "capture", "scan",
        "log", "record", "note", "save", "remember",
        "message", "text", "email", "send", "call", "notify", "tell my",
        "find", "search", "look up", "check",
        "summarize", "summarise", "translate",
        "remind", "schedule", "add to", "create",
        "turn on", "turn off", "switch on", "switch off", "lock", "unlock", "set the",
    ]

    static func isMultiStep(_ request: String) -> Bool {
        let lower = request.lowercased()
        guard sequencers.contains(where: { lower.contains($0) }) else { return false }
        let cues = actionCues.reduce(into: Set<String>()) { acc, cue in
            if lower.contains(cue) { acc.insert(cue) }
        }
        return cues.count >= 2
    }
}
