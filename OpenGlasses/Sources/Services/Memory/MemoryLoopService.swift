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
    /// The conversation a saved fact came from. Wired by `AppState`; `nil` keeps the loop working
    /// with the fact simply unattributed — the graph then treats it as a claim from nowhere, which
    /// can be reinforced but never corroborated.
    weak var conversationStore: ConversationStore?
    /// Speak a nudge through TTS. Wired by `AppState`.
    var speak: ((String) -> Void)?
    /// One structured completion against the wearer's configured provider — the seam
    /// `LLMService.completeStructured(systemPrompt:userText:jsonSchema:)` is wired into by
    /// `AppState`. A closure rather than a service reference so the loop owns no model, and so
    /// nothing here can reach the network unless someone wired it.
    var completeStructured: ((String, String, [String: Any]) async -> [String: Any]?)?

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

    /// Read a completed turn for relationships the on-device patterns missed, and file what comes
    /// back as *unconfirmed*.
    ///
    /// Deliberately separate from `observeTurn`: that path is pure of the network and stays that
    /// way. This one sends the wearer's words to the configured model, so it is refused outright
    /// unless [[RelationEnrichmentPolicy]] agrees, and it runs after the reply has already been
    /// accepted — a memory pass must never be something the wearer waits for. Only the wearer's
    /// own utterance is sent: the assistant's reply is the model's own prose, and mining it for
    /// facts would let the model corroborate itself.
    ///
    /// Nothing here throws or surfaces. A failed call, an empty answer and a refusal the wearer
    /// asked for are each one counted line and no edges; the feature merely being off is silent.
    func enrich(turn: CompletedTurn, sessionID: String?) async {
        let outcome = RelationEnrichmentPolicy.decide(
            agentMode: Config.agentModeEnabled,
            enrichmentEnabled: Config.brainEnrichmentEnabled,
            hipaaMode: Config.hipaaMode,
            provider: Config.activeModel?.llmProvider)
        if let reason = outcome.skipReason {
            // Only the refusals the wearer asked for and did not get: a wearer who never switched
            // enrichment on would otherwise get one line per turn for a feature that is simply off.
            if reason.isWorthLogging {
                PrivacyLog.store(.brain, .saveSkipped, detail: PrivacyToken(reason.rawValue))
            }
            return
        }

        let utterance = turn.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, let complete = completeStructured else { return }

        let answer = await complete(RelationEnrichmentParser.systemPrompt, utterance,
                                    RelationEnrichmentParser.jsonSchema)
        let relations = RelationEnrichmentParser.relations(from: answer, sourceText: utterance)
        guard !relations.isEmpty else {
            PrivacyLog.store(.brain, .saveSkipped, detail: PrivacyToken("nothingUsable"))
            return
        }

        let brain = BrainStore.shared
        for relation in relations {
            brain.addEdge(srcKind: relation.srcKind, srcName: relation.src,
                          relation: relation.relation, dstKind: relation.dstKind,
                          dstName: relation.dst, sessionID: sessionID,
                          confidence: brain.policy.provisionalConfidence, state: .provisional)
        }
        PrivacyLog.store(.brain, .ingested, count: relations.count,
                         detail: PrivacyToken("enrichment"))
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
                BrainStore.shared.ingest(text: payload, sourceRef: "memory-loop", sourceKind: "fact",
                                         sessionID: conversationStore?.activeThreadId)
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
