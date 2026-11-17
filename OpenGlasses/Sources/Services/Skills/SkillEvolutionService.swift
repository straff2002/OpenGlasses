import Foundation

/// Turns a failure batch into a proposed-skill string (or nil). The seam that isolates the one LLM
/// call, so the orchestration around it is testable with a stub.
protocol SkillEvolutionAnalyzer {
    func analyze(_ samples: [FailureSample]) async -> String?
}

/// Production analyzer: one LLM completion over the [[SkillEvolutionPrompt]]. The completion is a
/// closure so the Skills layer stays decoupled from `LLMService` (AppState wires
/// `llmService.completeStateless`).
struct LLMSkillEvolutionAnalyzer: SkillEvolutionAnalyzer {
    let complete: (_ system: String, _ user: String) async throws -> String

    func analyze(_ samples: [FailureSample]) async -> String? {
        guard !samples.isEmpty else { return nil }
        return try? await complete(SkillEvolutionPrompt.systemPrompt(for: samples), SkillEvolutionPrompt.build(samples))
    }
}

/// The closed-but-supervised improvement loop: collect failure samples, and when the batch warrants
/// it, ask the analyzer for one skill, validate + dedup it, and enqueue it **for human review**. It
/// never auto-applies — approval is the safety boundary, the whole thing is **Agent-Mode-gated**, and
/// an approved skill rides the same prompt-injection screen as any other.
///
/// The decisions that matter are pure ([[EvolutionTrigger]] / [[SkillDeduplicator]] / [[SkillProposal]]);
/// this service is the only piece that calls the LLM or touches [[EvolvedSkillStore]].
@MainActor
final class SkillEvolutionService: ObservableObject {

    static let shared = SkillEvolutionService()

    private let store: EvolvedSkillStore
    /// Injected by AppState (the real LLM analyzer). Nil → the loop is inert.
    var analyzer: SkillEvolutionAnalyzer?

    private(set) var samples: [FailureSample] = []

    // Trigger thresholds.
    var batchThreshold = 8
    var rateThreshold = 6.0          // failures/hour for the burst path
    var window: TimeInterval = 1800  // 30 min

    // Default resolved in the body: `.shared` is main-actor-isolated and can't be a default
    // argument (evaluated in the caller's possibly-nonisolated context) under Swift 6.
    init(store: EvolvedSkillStore? = nil) { self.store = store ?? .shared }

    /// Record an unsatisfactory turn. No-op unless Agent Mode is on (the whole feature is gated).
    func record(_ sample: FailureSample) {
        guard Config.agentModeEnabled else { return }
        samples.append(sample)
    }

    /// Capture a **user-correction** signal (Plan AW): when a new user message corrects
    /// the assistant's previous answer, record it against that prior exchange and let the
    /// loop evolve if the batch now warrants it. No-op when the message isn't a correction,
    /// there was no prior answer, or Agent Mode is off.
    @discardableResult
    func noteUserTurn(message: String, priorPrompt: String, priorResponse: String) async -> SkillDraft? {
        // Plan LU §3: a private turn is not a correction to learn from.
        guard !PrivateConversationGate.skips(.skillEvolutionNoteUserTurn) else { return nil }
        guard Config.agentModeEnabled,
              !priorResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UserCorrectionDetector.detect(message) != nil else { return nil }
        record(FailureSample(kind: .userCorrection, prompt: priorPrompt, response: priorResponse,
                             userCorrection: message, at: Date()))
        return await evolveIfNeeded()
    }

    /// If the accumulated batch warrants it, propose one skill and enqueue it for review. Returns the
    /// enqueued draft (tests/telemetry) or nil. The batch is consumed whenever the analyzer runs, so a
    /// no-op proposal doesn't re-trigger immediately.
    @discardableResult
    func evolveIfNeeded(now: Date = Date()) async -> SkillDraft? {
        guard Config.agentModeEnabled, let analyzer else { return nil }
        guard EvolutionTrigger.shouldEvolve(samples, now: now,
                                            batchThreshold: batchThreshold,
                                            rateThreshold: rateThreshold,
                                            window: window) else { return nil }

        let batch = samples
        defer { samples.removeAll() }
        guard let raw = await analyzer.analyze(batch) else { return nil }
        // A second kind of proposal, an add-on idea: accepted only when the batch
        // really is mostly "no tool could get it", whatever the analyser says, and only ever as an
        // inbox suggestion — nothing is fetched until the wearer taps Build it.
        if let goal = AddOnIdeaClassifier.idea(in: raw) {
            if AddOnIdeaClassifier.isDominatedByMissingCapability(batch) {
                store.enqueueAddOnIdea(goal: goal)
            }
            return nil
        }
        guard let draft = SkillProposal.validate(raw, existingNames: store.knownNames()),
              !SkillDeduplicator.isDuplicate(draft, against: store.activeDrafts()) else { return nil }
        return store.enqueue(draft) ? draft : nil
    }

    // MARK: - Review actions

    /// Approve a pending proposal → it becomes a voice skill, injected like any other and subject to
    /// skill retrieval and the prompt-injection screen. Self-authored instructions only ever enter the
    /// prompt through this explicit user action.
    func approve(id: String) {
        guard let item = store.pending().first(where: { $0.id == id }), item.kind == .voiceSkill else { return }
        store.approve(id: id)
        VoiceSkillStore.shared.save(VoiceSkill(id: UUID().uuidString,
                                               trigger: item.draft.trigger.lowercased(),
                                               instruction: item.draft.instruction,
                                               createdAt: Date()))
    }

    func dismiss(id: String) { store.dismiss(id: id) }

    /// The wearer tapped Build it on an add-on idea: the idea leaves the inbox and an ordinary
    /// building session starts (with every gate it has). Returns what to tell the wearer, or nil
    /// when `id` isn't a pending idea.
    func buildAddOn(id: String, with service: AddOnAuthoringService?) -> String? {
        guard let item = store.pending().first(where: { $0.id == id }), let goal = item.addOnGoal else { return nil }
        guard let service else { return String(localized: "Building add-ons isn't available right now.") }
        let outcome = service.start(goal: goal)
        if case .started = outcome { store.approve(id: id) }
        return outcome.text
    }
}
