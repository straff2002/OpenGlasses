import Foundation

/// A completed user↔assistant exchange, as fed to the self-improving analyzers. Plain value
/// type so the heuristics are pure and headless-testable.
struct CompletedTurn: Equatable {
    let userText: String
    let assistantText: String
    let toolNames: [String]

    init(userText: String, assistantText: String = "", toolNames: [String] = []) {
        self.userText = userText
        self.assistantText = assistantText
        self.toolNames = toolNames
    }
}

/// A proposed memory the user can one-tap confirm. Never acts on its own — it's a suggestion
/// surfaced through `ProactiveAlertService` (Phase 3).
struct MemoryNudge: Equatable {
    enum Kind: Equatable { case fact }
    let kind: Kind
    let prompt: String
    let payload: String
}

/// Detects a durable personal fact worth offering to remember. Conservative by design —
/// explicit "remember that…" cues and first-person durable statements only, never questions —
/// so it rarely false-fires. Pure → fully unit-tested.
enum MemoryNudgeAnalyzer {
    /// Explicit "save this" cues; the payload is whatever follows the cue.
    static let explicitCues = [
        "remember that ", "remember to ", "remember ", "note that ",
        "don't forget that ", "dont forget that ", "keep in mind that ", "for future reference ",
    ]

    /// First-person durable-statement openers (statement must *start* with one, for precision).
    static let durableOpeners = [
        "my ", "i live ", "i work ", "i prefer ", "i'm allergic", "im allergic",
        "i am allergic", "i drive ", "i'm from ", "im from ", "i was born ", "call me ",
    ]

    /// Plan LN: never offer to keep what the write gate would refuse — a card number, someone
    /// else's diagnosis, an instruction to skip a check. Judged as the told-me write an accepted
    /// offer would become; the wearer's own allergy is still offered (it is kept, locally).
    static func nudge(for turn: CompletedTurn) -> MemoryNudge? {
        guard let nudge = candidate(for: turn) else { return nil }
        let decision = MemoryWriteGate.decide(key: "", value: nudge.payload, origin: .toldMe,
                                              destination: .offer)
        return decision.isKept ? nudge : nil
    }

    private static func candidate(for turn: CompletedTurn) -> MemoryNudge? {
        let raw = turn.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 8 else { return nil }
        let lower = raw.lowercased()

        // Never nudge on a question.
        if lower.hasSuffix("?") { return nil }
        let questionStarts = ["what ", "when ", "where ", "who ", "why ", "how ", "which ",
                              "is ", "are ", "do ", "does ", "can ", "could ", "would ", "should "]
        if questionStarts.contains(where: { lower.hasPrefix($0) }) { return nil }

        // Explicit cue → payload is the clause after the cue.
        for cue in explicitCues {
            if let range = raw.range(of: cue, options: .caseInsensitive) {
                let payload = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard payload.count >= 3 else { continue }
                return MemoryNudge(kind: .fact, prompt: "Want me to remember that?", payload: payload)
            }
        }

        // First-person durable statement → remember the whole line.
        if durableOpeners.contains(where: { lower.hasPrefix($0) }) {
            return MemoryNudge(kind: .fact, prompt: "Want me to remember that?", payload: raw)
        }
        return nil
    }
}
