import Foundation
import Combine

/// What the memory loop decided to do for a completed turn. Returned by `decide` so the
/// decision logic is unit-testable without touching `BrainStore` / `VoiceSkillStore` / TTS.
enum MemoryAction: Equatable {
    case nudgeFact(String)                          // speak an offer to remember a stated fact
    case saveFact(String)                           // silently ingest the fact (Agent Mode)
    case nudgeSkill(String)                         // speak an offer to save a repeated request
    case saveSkill(trigger: String, instruction: String)   // silently save the skill (Agent Mode)
}

/// The self-improving loop (Memory & Recall Phase 3): after each completed turn it spots a
/// durable fact (`MemoryNudgeAnalyzer`) or a repeated multi-step request (`SkillPatternDetector`)
/// and either **offers** to save it (spoken nudge, opt-in) or **silently saves** it when Agent
/// Mode is on. Presence-aware and rate-limited so nudges never nag.
///
/// `decide(...)` is pure of `Config`/singletons/TTS (flags are parameters) → fully unit-tested;
/// `observeTurn` reads `Config`, calls `decide`, and performs the side effects.
@MainActor
final class MemoryLoopService: ObservableObject {
    static let shared = MemoryLoopService()

    private let skillDetector: SkillPatternDetector
    /// Spoken nudges are suppressed unless this many turns have passed since the last one.
    private let nudgeCooldownTurns: Int
    private var turnsSinceNudge: Int

    weak var presence: PresenceMonitor?
    /// Speak a nudge through TTS. Wired by `AppState`.
    var speak: ((String) -> Void)?

    init(skillDetector: SkillPatternDetector = SkillPatternDetector(), nudgeCooldownTurns: Int = 4) {
        self.skillDetector = skillDetector
        self.nudgeCooldownTurns = nudgeCooldownTurns
        self.turnsSinceNudge = nudgeCooldownTurns   // allow the first nudge immediately
    }

    func configure(presence: PresenceMonitor?, speak: @escaping (String) -> Void) {
        self.presence = presence
        self.speak = speak
    }

    /// Live entry point — call at turn completion.
    func observeTurn(userText: String, assistantText: String = "", toolNames: [String] = []) {
        let nudges = Config.memoryNudgesEnabled
        let agent = Config.agentModeEnabled
        guard nudges || agent else { return }
        let turn = CompletedTurn(userText: userText, assistantText: assistantText, toolNames: toolNames)
        let actions = decide(turn: turn, nudgesEnabled: nudges, agentMode: agent, present: isPresent)
        perform(actions)
    }

    /// Decide what to do for a turn. Deterministic given the flags + internal detector/cooldown
    /// state — the unit-tested core.
    func decide(turn: CompletedTurn, nudgesEnabled: Bool, agentMode: Bool, present: Bool) -> [MemoryAction] {
        turnsSinceNudge += 1
        var actions: [MemoryAction] = []

        if let nudge = MemoryNudgeAnalyzer.nudge(for: turn) {
            if agentMode {
                actions.append(.saveFact(nudge.payload))
            } else if nudgesEnabled, present, canNudge() {
                actions.append(.nudgeFact("I can remember that — just say \u{201C}remember it.\u{201D}"))
                markNudged()
            }
        }

        // Always feed the detector so repeat-counts accrue, even when nudges are suppressed.
        if let suggestion = skillDetector.record(toolNames: turn.toolNames, triggerHint: turn.userText) {
            let trigger = Self.triggerPhrase(from: suggestion.triggerHint)
            let instruction = "Repeat what we did before: \(suggestion.toolSignature.joined(separator: ", "))."
            if agentMode {
                actions.append(.saveSkill(trigger: trigger, instruction: instruction))
            } else if nudgesEnabled, present, canNudge() {
                actions.append(.nudgeSkill("You've done that a few times — say \u{201C}save that as a skill\u{201D} and I'll learn it."))
                markNudged()
            }
        }
        return actions
    }

    // MARK: - Side effects

    private func perform(_ actions: [MemoryAction]) {
        for action in actions {
            switch action {
            case .saveFact(let payload):
                BrainStore.shared.ingest(text: payload, sourceRef: "memory-loop", sourceKind: "fact")
            case .saveSkill(let trigger, let instruction):
                VoiceSkillStore.shared.save(VoiceSkill(id: UUID().uuidString, trigger: trigger,
                                                       instruction: instruction, createdAt: Date()))
            case .nudgeFact(let message), .nudgeSkill(let message):
                speak?(message)
            }
        }
    }

    // MARK: - Helpers

    private var isPresent: Bool {
        guard let presence else { return true }
        return presence.mode >= .present   // active or present, not idle/away
    }

    private func canNudge() -> Bool { turnsSinceNudge >= nudgeCooldownTurns }
    private func markNudged() { turnsSinceNudge = 0 }

    /// A short, lower-cased trigger phrase from the user's wording (first few words).
    static func triggerPhrase(from hint: String) -> String {
        let words = hint.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .prefix(6)
        return words.joined(separator: " ")
    }
}
