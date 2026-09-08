# Plan AW — Skill Self-Evolution (learn new skills from failed turns, with human review)

**Status: ✅ Spine shipped (this PR), user-correction capture shipped since.** The deterministic loop is built: `FailureSample` +
`SkillEvolutionPrompt`, pure `EvolutionTrigger` (accumulation **or** burst-rate) + `SkillDeduplicator`
(name Jaccard + body overlap) + `SkillProposal.validate` (slug rules, required fields, length caps,
auto `dyn-N`), the `EvolvedSkillStore` (SQLite pending/approved/dismissed lifecycle, "never re-propose"
by name), and `SkillEvolutionService` (Agent-Mode-gated `record` → `evolveIfNeeded` over a
`SkillEvolutionAnalyzer` seam; `approve` routes to a `VoiceSkill`). The loop now runs **end-to-end**:
the `NativeToolRouter` capture hook records genuine tool-execution errors (pure `ToolFailureFilter`
keeps timeouts/safety-declines out), `AppState` wires the `LLMSkillEvolutionAnalyzer`, and the
**Suggested Skills** review inbox (Settings, Agent-Mode-gated, pending-count badge) is where the user
approves/dismisses. **Agent-Mode-gated** and **human-in-the-loop by design** — the loop *proposes*, the
user *approves*; nothing self-authored is injected unreviewed. 21 tests. **User-correction capture
shipped** ([#151](https://github.com/straff2002/OpenGlasses/pull/151), 2026-06-30): `UserCorrectionDetector`
("no, that's wrong") feeds the same signal tool errors do, with 22 tests. The embedding-based **skill
retrieval companion** already shipped ([#127](https://github.com/straff2002/OpenGlasses/pull/127)/[#129](https://github.com/straff2002/OpenGlasses/pull/129)).

## The problem
OpenGlasses' skills are **static**: `InstalledSkillStore`, `VoiceSkillStore`, OpenClaw skills, and the
`ShortcutsCatalog` are all hand-curated and injected into prompts as-is. When the agent repeatedly
fumbles the same kind of task — a tool it keeps calling wrong, a phrasing the user keeps correcting,
a workflow it forgets — there's no mechanism to **learn** from those failures. The knowledge to fix
it exists in the transcript; nothing harvests it.

## What we build
A closed-but-supervised improvement loop:
1. **Capture** unsatisfactory turns as `FailureSample`s — a tool call that errored, an explicit user
   correction ("no, that's wrong" / "I meant…"), a retried/abandoned request.
2. **Trigger** evolution when enough accumulate (batch size **or** failure rate over a window).
3. **Analyse** the batch with one LLM call that proposes a small, named **skill** — a `SKILL.md`-style
   instruction ("when the user asks X, do Y; avoid Z") addressing the recurring failure.
4. **Dedup** the proposal against existing skills (name overlap + token similarity) so we don't pile
   up near-duplicates.
5. **Review** — surface the proposal in a "Suggested Skills" inbox. The user **approves** (→ added to
   `InstalledSkillStore`, injected like any installed skill) or **dismisses** (recorded so it isn't
   re-proposed). Never auto-applied.

### The deterministic core (pure, tested)
- **`FailureSample`** — `{ kind, prompt, response, toolName?, userCorrection?, at }`. `kind` ∈
  `{toolError, userCorrection, retry, abandoned}`.
- **`EvolutionTrigger`** — `shouldEvolve(samples, now) -> Bool`: true when `count ≥ batchThreshold`
  **or** `failureRate(window) ≥ rateThreshold`. Pure; time injected.
- **`SkillDeduplicator`** — `isDuplicate(candidate, existing) -> Bool` via name-token **Jaccard** +
  body token-overlap above a threshold. Pure.
- **`SkillProposal`** — parse + **validate** the LLM's output: slug rules (`^[a-z][a-z0-9-]+$`),
  required fields, length caps, auto-name `dyn-NNN` when unnamed. Reject malformed proposals (never
  surface garbage for review). Pure.

## Safety posture (non-negotiable)
- **Agent-Mode-gated** — the whole feature is behind `agentModeEnabled`; off by default, like every
  other autonomous/gateway capability.
- **Human-in-the-loop** — proposals are *suggestions*. A self-authored instruction only ever enters
  the prompt after explicit user approval. This is the key divergence from a fully-autonomous evolver:
  an always-on assistant must not silently rewrite its own behaviour.
- **Screened** — an approved skill is still routed through the existing prompt-injection / tool-poison
  screens (Plan R) before it can take effect, exactly like an imported skill.
- **Reversible** — approved evolved skills are tagged `source: evolved`, listed separately, and
  one-tap removable; dismissals are remembered.

## Scope
In:
- `Sources/Services/Skills/FailureSample.swift`, `EvolutionTrigger.swift`, `SkillDeduplicator.swift`,
  `SkillProposal.swift` (pure core).
- `Sources/Services/Skills/SkillEvolutionService.swift` — collect samples from the agent loop, run the
  trigger, make the LLM call, dedup, enqueue proposals for review. Agent-Mode-gated.
- `Sources/Services/Skills/EvolvedSkillStore.swift` — pending proposals + approved/dismissed state
  (SQLite), feeding `InstalledSkillStore` on approval.
- Capture hooks: `AgentRunner` / `NativeToolRouter` (tool errors) and `AppState` (user corrections /
  retries) emit `FailureSample`s.
- A "Suggested Skills" review surface (Settings) — approve / edit / dismiss.

Out (deferred):
- Fully-autonomous apply (no review) — explicitly **not** building; review is the safety boundary.
- Evolving *tool definitions* or code — proposals are prompt-level instructions only.
- Cross-device sync of evolved skills — local first; rides the existing skills export/import later.
- RL-style scoring/reward of skills — start with explicit user approve/dismiss as the signal.

## Architecture — the seam
```swift
struct FailureSample { enum Kind { case toolError, userCorrection, retry, abandoned }
    let kind: Kind; let prompt: String; let response: String
    let toolName: String?; let userCorrection: String?; let at: Date }

enum EvolutionTrigger {
    static func shouldEvolve(_ samples: [FailureSample], now: Date,
                             batchThreshold: Int, rateThreshold: Double, window: TimeInterval) -> Bool
}
enum SkillDeduplicator { static func isDuplicate(_ candidate: SkillDraft, against existing: [SkillDraft]) -> Bool }
enum SkillProposal { static func validate(_ raw: String, existingNames: Set<String>) -> SkillDraft? }  // nil = reject
```
`SkillEvolutionService` orchestrates these and is the only piece that calls the LLM or touches stores;
the decisions that matter (when to evolve, is it a dup, is it well-formed) are pure and tested.

## Build order
1. **Pure core + tests** — `EvolutionTrigger`, `SkillDeduplicator`, `SkillProposal`. Fully
   deterministic; no LLM, no store.
2. **`EvolvedSkillStore`** — pending/approved/dismissed persistence + round-trip tests.
3. **Capture hooks** — emit `FailureSample`s from tool errors + user corrections (cheap, additive,
   Agent-Mode-gated).
4. **`SkillEvolutionService`** — wire trigger → LLM analysis → dedup → enqueue. (LLM edge.)
5. **Review UI** — Suggested Skills inbox; approval routes through the Plan R screen into
   `InstalledSkillStore` tagged `evolved`.

## Tests
- `EvolutionTrigger`: under threshold and low rate → false; batch threshold reached → true; high
  failure rate in-window → true; old samples outside the window don't count. Time injected.
- `SkillDeduplicator`: identical/near-identical name+body → duplicate; distinct → not; threshold
  boundaries.
- `SkillProposal.validate`: valid slug + fields → draft; bad slug / missing field / over-length →
  nil; unnamed → auto `dyn-NNN` not colliding with `existingNames`.

## Open questions / decisions needed
- **What counts as a failure** — start conservative (explicit tool errors + explicit user
  corrections); add "retry/abandoned" heuristics only once the signal proves clean (false positives
  pollute the skill bank).
- **Review friction vs. value** — a proposal the user must read is the safety cost; keep proposals
  short, few, and high-confidence (dedup hard, require a real recurring pattern) so the inbox is rare
  and worth opening.
- **Which model analyses** — reuse the active provider, or pin a stronger model for the analysis step
  (it's infrequent). Surfaces in the [cost tracker](llm-cost-usage-tracker.md).
- **Edit-on-approve** — let the user tweak the wording before accepting; treat the LLM output as a
  draft, not a verdict.

## Companion: embedding-based skill retrieval

**Status: ✅ shipped ([#127](https://github.com/straff2002/OpenGlasses/pull/127), default-on
[#129](https://github.com/straff2002/OpenGlasses/pull/129)).** The pure `SkillRetriever` +
`SkillCandidate`, `for turn:` overloads on both skill stores, the three `Config.skillRetrieval*` flags
(now default on for beta), and the `turn`-threading into `LLMService` are built, tested, and merged.
The evolution loop above is still 📋 Planned; retrieval shipped first because it stands alone and fixes
a bloat issue that exists today.

Evolution has a tail problem. Every approved skill is injected into **every** system prompt, because
both skill stores dump their whole library unconditionally today:
- `VoiceSkillStore.promptContext()` emits a `LEARNED SKILLS` block listing *all* voice skills.
- `InstalledSkillStore.promptContext()` does the same for ClawHub/installed skills.

That's fine at three skills. But the whole point of evolution is that the bank **grows** with what
this user keeps needing — and a 30-skill dump bloats the prompt, burns tokens, and dilutes attention
across instructions that are irrelevant to the turn at hand. The fix is to inject only the skills
**relevant to the current turn**, selected on-device with the `Embedder` we already ship.

### The deterministic core (pure, tested)
- **`SkillRetriever`** — `select(turn:, candidates:, similarity:, topK:, alwaysIncludeTriggerMatches:)
  -> [skill]`. Pure ranking:
  - **Always** include any skill whose explicit `trigger` substring-matches the turn — an exact
    voice trigger must *never* be dropped by a similarity cutoff (the current behaviour is exact-match
    on trigger, and we preserve it).
  - Then fill the remaining budget with the top-`k` candidates by injected cosine similarity between
    the turn and the skill's `trigger + instruction` text.
  - Stable, deterministic ordering; similarity injected so it's testable without a model.
- A unified `SkillCandidate` view (`{ id, trigger, body, source }`) so voice, installed/ClawHub, and
  `evolved` skills rank in one pool against one budget.

### How it flows
`promptContext()` gains a `for turn:` variant on both stores that runs the candidates through
`SkillRetriever` (embedding the turn via `Embedder`) and formats only the survivors — same block
shape as today, fewer lines. Gated by `skillRetrievalEnabled` (default off) **and** a count floor: below
`skillRetrievalMinCount` skills, dump-all is cheaper and clearer, so retrieval only kicks in once the
library is large enough to matter — which is exactly when evolution has been doing its job.

### Scope (additive to this plan)
In: `Sources/Services/Skills/SkillRetriever.swift` (+ `SkillCandidate`); `for turn:` overloads on
`VoiceSkillStore`/`InstalledSkillStore`/`EvolvedSkillStore`; `Config.skillRetrievalEnabled`,
`skillRetrievalTopK`, `skillRetrievalMinCount`. Out: re-ranking by recency/usage (start with
relevance only); a cross-store usage counter (a later salience signal).

### Tests
- `SkillRetriever.select`: a turn containing a skill's `trigger` always includes it regardless of
  similarity; the rest are the top-k by injected similarity; below `minCount` → all returned (today's
  behaviour, no change); empty candidates → empty; ties break stably.

### Why fold it in here
Retrieval isn't worth building for a hand-curated handful of skills — dump-all is fine there. It
becomes necessary *because* evolution grows the bank, so it belongs with the feature that creates the
pressure. It also rides the same `Embedder` seam as the [memory taxonomy](memory-taxonomy.md)'s
semantic recall, and the same default-off-flag posture as the rest of this plan.

## Why this matters
It's the one genuinely *self-improving* capability in the set: the assistant gets better at the things
*this* user keeps needing, by harvesting fixes that are already sitting in the transcript. The risk —
an always-on agent rewriting its own instructions — is contained by making the loop **propose, not
apply**, gating it behind Agent Mode, and running approvals through the existing safety screen. The
hard logic (when to evolve, dedup, validate) lands as a pure, fully-tested core; the LLM and the
review inbox are the deferred live edge.
