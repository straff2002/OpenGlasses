# Plan BK — Adversarial Review Remediation (local model, agentic gating, feature honesty)

**Status:** ✅ Shipped (2026-07-12/13, one PR per phase) — P0 `e75c0b4`; P1 geofencing `35b2b42`
([#208](https://github.com/straff2002/OpenGlasses/pull/208)); P2 local-model prompt budget `24ae5a8`
([#213](https://github.com/straff2002/OpenGlasses/pull/213)); P2b model cascade `2b43eb1`
([#214](https://github.com/straff2002/OpenGlasses/pull/214)); P2c narrate model switches `05f0d5f`
([#215](https://github.com/straff2002/OpenGlasses/pull/215)); P3 `c28b0e8`; P4 `9f92286`; P5
`a205790`; P6 `6ca4783`.
**Origin:** Adversarial review (2026-07-10) of local-model paths, agentic/gateway gating, and
feature-claim honesty. Each finding below was re-verified against source before inclusion.

House style applies: deterministic, headless-testable core first; one PR per phase. Phases are
independent and can ship in any order — **P0 and P1 are the priority** (a security gap and a
"never worked" feature respectively).

---

## P0 — OpenClaw `execute` bypasses the Agent-Mode gate 🔴 Critical

**The bug.** The house rule is that all gateway/autonomous features sit behind `agentModeEnabled`
([[feedback_agentic_toggle]]). Nine of the ten gateway methods in `OpenClawBridge` honour it, but
`delegateTask` — the one that actually opens the WebSocket and ships the task — does not:

- `OpenGlasses/Sources/Services/OpenClawBridge.swift:691` (`delegateTask`) has **no**
  `guard Config.agentModeEnabled` (contrast the nine siblings at lines 506/532/555/574/589/614/634/653/672).
- Tool exposure to the LLM gates only on `Config.isOpenClawConfigured`, not agent mode:
  `LLMService.swift:434`, `:1235`, `:1435`, `:1747` (`includeOpenClaw`), and the prompt text at `:251`.
- Router fallback delegates to the gateway on `Config.isOpenClawConfigured` alone:
  `NativeToolRouter.swift:145`.
- `OpenClawSkillsTool.swift:35` has the identical gap and calls `delegateTask` directly.
- **Gemini Live mode has the same exposure** (found in the 2026-07-10 re-verification): the `execute`
  tool declaration is emitted via `ToolDeclarations.allDeclarations(… includeOpenClaw:)` gated only on
  `isOpenClawConfigured` (`GeminiLiveSessionManager.swift:134-138`, `:219-220`), and the Gemini Live
  system prompt advertises the gateway at `:238-241` and `:472/:503`. (OpenAI Realtime is clean —
  zero OpenClaw references.)
- Two more direct `delegateTask` callers for the test matrix: `ToolCallRouter.swift:38-40` (Gemini
  Live legacy fallback when `nativeToolRouter` is nil) and the `ToolDispatcher` bridge fallback at
  `LLMService.swift:402-404`.
- Compounding: the `SafetySupervisor` confirmation backstop is itself only invoked
  `if Config.agentModeEnabled` (`NativeToolRouter.swift:81`), and `HighImpactToolPolicy`'s
  unconditional floor covers only `smart_home`/`home_assistant`, not `execute`. So with Agent Mode
  **off**, `execute` is reachable *and* unconfirmed.

**Impact.** A user who configures a gateway (common for smart-home use) but deliberately leaves
Agentic Features off still gets an LLM whose system prompt advertises full access to "files, browser,
apps, messages… everything on their machine," invocable from ordinary conversation **or from
prompt-injected content** in a web-search result / OCR'd sign / ambient caption.

**Fix.**
1. Add `guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }` to the top
   of `OpenClawBridge.delegateTask` (mirror the sibling methods verbatim).
2. Gate `includeOpenClaw` on `Config.isOpenClawConfigured && Config.agentModeEnabled` at all four
   `LLMService` sites + the prompt-text site.
3. Gate the `NativeToolRouter.swift:145` fallback on `Config.agentModeEnabled`.
4. Gate `OpenClawSkillsTool.execute` on `Config.agentModeEnabled` — **and** its registration:
   `NativeToolRegistry.swift:83` registers the tool at init on `isOpenClawConfigured` alone, so with
   only the execute-gate the tool still appears in the SystemPromptBuilder-generated tool list while
   agent mode is off (a P6-style honesty violation). Gate registration too.
5. **Gate the Gemini Live surface identically:** `allDeclarations(… includeOpenClaw:)` call sites and
   the gateway prompt text in `GeminiLiveSessionManager` (`:134-138`, `:219-220`, `:238-241`,
   `:472/:503`). Without this, Gemini Live still hands the model an `execute` schema and a prompt
   claiming full machine access; the calls would die safely at the new `delegateTask` guard, but as
   confusing failures that violate the P6 honesty principle.
6. `PromptInspectorView.swift:91` renders the OpenClaw block on `isOpenClawConfigured` — update so the
   prompt preview matches the real gated prompt.
7. **Two Plan N paths with the same shape (from the gateway-line review):** `OpenClawBridge.agentRequest`
   (`OpenClawBridge.swift:441-447`) is a public pass-through to `sendRequest` with no gate, unlike the
   nine gated siblings; and `AgentSessionService.dispatch` (`AgentSessionService.swift:61`) has no
   service-layer gate — the only gate in the Plan N chain is tool-layer (`AgentControlTool.swift:47`).
   Both are latent today (their only callers are gated), but they are exactly the
   gate-at-the-service-layer lesson this phase codifies. Guard both.

**Tests.** Agent-mode-off: `delegateTask` returns failure without opening a socket; `includeOpenClaw`
is false so the prompt omits the OPENCLAW block and no `execute` tool schema is emitted — asserted for
Direct mode **and** `ToolDeclarations.allDeclarations` (Gemini Live); the registry omits
`openclaw_skills`; router fallback returns "Unknown tool" rather than delegating; the
`ToolCallRouter.swift:38-40` and `LLMService.swift:402-404` fallback callers fail closed.
Agent-mode-on: unchanged behaviour.

**Decide in this PR — the autonomous triage loop.** `OpenClawEventClient.connect()` runs on
`isOpenClawConfigured` alone (`OpenGlassesApp.swift:1050`); inbound gateway events flow to
`triageOpenClawNotification` (`:3055`), which feeds untrusted gateway output to the LLM, and its
CLARIFY/FIX branches call `delegateTask` (`:3143`, `:3200`, guarded only by `isOpenClawConfigured`).
That is an inbound-gateway → LLM → outbound-gateway loop running with Agent Mode off. Fix #1 severs
the outbound leg, but event listening + LLM triage is *itself* an autonomous background LLM action on
untrusted content — the recommendation is to gate `connect()` and the triage entry on
`agentModeEnabled` as well, not just the outbound call.

**Open question.** Outbound third-party MCP routing (`NativeToolRouter.swift:125-142`, `MCPClient.swift`)
also has no `agentModeEnabled` awareness. It's arguably a per-server opt-in integration rather than a
"gateway," so it's out of P0 scope — but decide explicitly whether the house rule extends to it.
(Note: Plan BL commits its peer-MCP routing to the agent-mode gate at the service layer, so if the
answer here is "no," BL's gate must live in its own adapter, not rely on shared MCP plumbing.)

---

## P1 — Geofencing has never fired an alert 🔴 Critical

**The bug.** `GeofenceTool` is listed Tier 2 **DONE** in CLAUDE.md but is a silent stub end-to-end:

- `GeofenceTool.swift:69` allocates its own `CLLocationManager` and **never sets `.delegate`** (grep:
  zero `delegate` assignments in the file — only a comment at `:245` claiming "Called by LocationService
  delegate").
- The app's only `CLLocationManagerDelegate` (`LocationService.swift:86`) implements
  `didUpdateLocations` / `didChangeAuthorization` / `didFailWithError` — **no `didEnterRegion` /
  `didExitRegion` / `monitoringDidFailFor`.**
- `handleRegionEvent(region:didEnter:)` (`GeofenceTool.swift:246`), the only path to the TTS/HUD alert
  wired at `OpenGlassesApp.swift:1004`, has **zero callers** — dead code.
- The app never calls `requestAlwaysAuthorization()` anywhere (grep: zero occurrences); region
  monitoring needs Always, not When-In-Use (`LocationService.swift:27`).

**Impact.** User says "remind me when I get to the office." `createGeofence` responds *"I'll alert you
when you arrive,"* persists the reminder, calls `startMonitoring` — and no alert can ever fire.

**Fix.**
1. Give geofence monitoring a real delegate — **route region monitoring through `LocationService`'s
   existing manager** (the better of the two options: one manager, created on the main thread, one
   delegate) and add the missing `didEnterRegion`/`didExitRegion`/`monitoringDidFailFor` callbacks
   there, forwarding to `handleRegionEvent`. If a wrapper delegate is used instead, it **must be
   strongly retained** by the tool/service — `CLLocationManager.delegate` is weak, and an unretained
   wrapper silently re-introduces this exact bug. Delegate callbacks arrive on the creating thread's
   runloop, so the manager must be created on main (today `GeofenceTool` builds its own manager on
   whatever thread constructs the tool, `GeofenceTool.swift:71`).
2. Request Always authorization before registering the first region — **including the missing
   `NSLocationAlwaysAndWhenInUseUsageDescription` Info.plist key** (`OpenGlasses/Info.plist` has only
   When-In-Use at `:144`; without the key, `requestAlwaysAuthorization()` is a documented silent
   no-op; the plist is hand-maintained via `INFOPLIST_FILE`, `project.base.yml:115`).
3. In `createGeofence`, check authorization status + `CLLocationManager.isMonitoringAvailable(for:
   CLCircularRegion.self)` **+ the iOS 20-region cap** (`monitoredRegions.count` — `registerRegion`
   never checks it today, and past 20 `startMonitoring` silently fails) and return an honest message
   when monitoring can't be armed, instead of an unconditional success.
4. This fix introduces the injectable location-manager seam — none exists today (the manager is a
   `private let` built inline). That seam is part of the deliverable, not an assumption.

**Tests.** Injected fake location manager: entering/exiting a registered region invokes
`handleRegionEvent` → `onAlert`. `createGeofence` with denied/When-In-Use auth returns a
can't-arm message rather than a success promise; the 21st region returns a can't-arm message.

---

## P2 — Local-model prompt budget: hard-fail, model-agnostic cap, unbounded growth 🟠 Important

**Answering "is the max-token issue fixed?": the crash is fixed; the failure experience is not.**
The 2D-batch fix + `maxPromptTokens = 4096` reject-before-submit guard
(`LocalLLMService.swift:266`) stops the uncatchable Jetsam OOM. But three real issues remain, which
is why long turns "still have issues":

**(a) The cap is a hard reject with no truncation and no auto-fallback.** `generate()` throws
`promptTooLong`; `sendLocal` re-throws it (`LLMService.swift:1955-1960`); the turn's `onError` speaks a
hardcoded *"Sorry, I encountered an error"* (`OpenGlassesApp.swift:2748`). The helpful
`promptTooLong.errorDescription` — *"Switch to a cloud model for this request"* (`LocalLLMService.swift:408`)
— is never surfaced, and there is no automatic cloud fallback. User-visible result: the turn just
errors.

**(b) 4096 is model-agnostic and ignores generation headroom.** It's a single `static let`
(`LocalLLMService.swift:113`) regardless of the loaded model (Qwen2.5-0.5B vs gemma-2-2b have
different real context windows), and it does **not** subtract the 512-token generation budget
(`GenerateParameters(maxTokens: 512…)`, `LocalLLMService.swift:287`). A model with a real 4096 window
fed a 4096-token prompt overflows *during* generation (prompt + up to 512 new tokens) — relocating the
uncatchable per-token OOM from submit-time to mid-stream.

**(c) The growth vector is unbounded memory injection — and it's wider than persona/gateway.** The
lean prompt carries `memoryContext` from `SemanticMemoryStore.systemPromptContext(query:)`. The
"capped at 8 semantic hits" path applies only when a query is passed AND `embedder.isAvailable` AND
results are non-empty; otherwise the global branch dumps the **entire global store** sorted
(`SemanticMemoryStore.swift`, global branch ~`:195-200`). And AppState passes
`query: Config.userMemoryRetrievalEnabled ? query : nil` (`OpenGlassesApp.swift:2697/:2706`) — so
with retrieval disabled, every turn injects all global memories. **Persona and gateway memories are
injected in full, unbounded** on every path (`:206-214`), and individual values are unbounded length.
As the memory store grows, the prompt silently balloons past 4096 and turns that worked last week
start failing.

**Fix.**
1. **Budget from the model, not a constant.** Derive `maxPromptTokens` from the loaded model's real
   context window minus the generation budget (and a small safety margin): `promptBudget =
   contextWindow − generationMaxTokens − margin`. **No context-window metadata exists today** —
   `RecommendedModel` has no `contextWindow` field, and `LocalModelManagerView.swift:159` accepts
   arbitrary user-typed model ids — so the lookup needs a table **plus a conservative default** for
   unknown ids. Keep the pre-submit guard, but computed.
2. **Truncate to fit instead of hard-failing — at every `generate()` entry, not just `sendLocal`.**
   Tokenization via the chat template happens *inside* `generate()` (`LocalLLMService.swift:242`), and
   `generate()` has three callers that bypass `sendLocal`'s history trimming: the tool-result
   re-generation (`LLMService.swift:2001`), the UncertaintyReask regenerate closure (`:2036`), and
   `sendViaLocalAgent`. Truncation applied only at the first call leaves the mid-stream overflow (b)
   alive on the second. Trim in priority order — drop oldest history first, then clamp the memory
   block — and only throw `promptTooLong` when even the minimal prompt (system + current turn)
   exceeds the window.
3. **Bound memory injection on all three paths.** Cap persona + gateway memories the same way the
   semantic-hit path is capped (top-N by relevance), **clamp the global fallback branch** (no query /
   embedder unavailable / retrieval off — currently dumps the whole store), and clamp per-value
   length in `systemPromptContext`.
4. **On genuine overflow, degrade usefully** — hand off to the P2b cascade (below) rather than
   speaking the generic error line.
5. **Add the empty-response guard** (see P3) — an over-trimmed prompt is a prime source of empty
   local completions.

**Tests (pure, headless).** Token-budget calculator: `contextWindow=4096, gen=512 ⇒ budget=3584−margin`.
Truncation: an over-budget history trims oldest-first until under budget and preserves the current
turn + system prompt. Memory clamp: N persona + N gateway memories inject at most the cap. Overflow:
minimal-prompt-still-too-big throws `promptTooLong`.

---

## P2b — Model cascade / fallback chain 🟠 Important (primary user need)

**The gap.** Today there is **no failover between models**. `ModelRoutingPolicy.decide`
(`ModelRoutingPolicy.swift:30`) selects one model up front from the classified turn tier; the turn is
strictly single-shot (`ConversationTurnRunner.run`, `ConversationTurnRunner.swift:40` calls `send()`
once); any error — `promptTooLong`, a `429`/quota `apiError` (`LLMService.swift:1266`, which *does*
carry the status code), an empty completion — falls straight to `onError` and speaks *"Sorry, I
encountered an error."* (`OpenGlassesApp.swift:2748`). The intent-to-fail-over is thrown away even
though the rate-limit is perfectly distinguishable.

**Target behaviour (the stated use case: prefer local for cost; spill to cloud when local can't
handle it; spill to the next cloud when one hits its limit).** A turn walks an ordered chain of models
and only surfaces an error when *every* candidate is exhausted.

**Design (deterministic core first).**
1. **`ModelFallbackChain` (pure).** Given the ordered candidate list (active/tier model first, then a
   user-defined fallback order) and a classification of the last failure, return the next model to try
   or `nil` (exhausted). Classify errors into *retry-on-different-model* vs *terminal*:
   - Retry-worthy: `promptTooLong` (→ next model with a bigger window, skipping any that also can't
     fit), `apiError` with `429` / quota / `insufficient_quota` / 402, network timeout, empty
     completion.
   - Terminal (don't cascade, don't burn the whole chain): `missingAPIKey`, `invalidConfiguration`,
     4xx auth/validation errors that would fail identically everywhere, user cancellation.
   - Respect the background rule: while backgrounded, skip on-device MLX candidates (they'd throw
     `.backgrounded`) and go straight to cloud ones. ([[project_local_model_background]])
2. **Cascade driver.** Wrap `send()` so that on a retry-worthy throw it consults the chain, switches
   the active model for that turn (reuse the existing temporary-switch/restore machinery at
   `OpenGlassesApp.swift:2651-2678,2753`), and re-invokes. Cap attempts (e.g. ≤ chain length, or a
   small N) to bound latency and token spend. **Announce the switch out loud** (see P2c).
3. **Config.** A user-ordered fallback list (or a simple "local → cloud A → cloud B" preference) plus a
   toggle. Default: cascade **on**, ordered by the user's cost preference (local first).
4. **Budget interaction.** P2's overflow path becomes "ask the chain for the next model with a larger
   context window" instead of a one-off cloud hop — the two phases share the same driver.

**Guardrails.**
- Don't cascade a turn whose failure is deterministic everywhere (bad API key, malformed request) —
  that just delays the same error N times.
- **Capability-filter the candidates.** A hop must respect the turn's needs:
  `requiresVision` / `requiresTools` / `handsFreeSafe` predicates per candidate. A vision turn
  (`imageData != nil`) or a tool-needing turn skips text-only candidates (`.appleOnDevice`, models
  with `visionEnabled == false`), and a foreground-hop provider is **never** an automatic cascade
  candidate (breaks hands-free, can't preserve history/tool state). (Plan AI is an auth-path
  reference, not a failure cascade — no ownership overlap; these predicates are its handoff to P2b.)
- **Expired/missing OAuth credential is skip-to-next, not chain-terminal.** With Sign in with Claude
  shipped, a refresh failure surfaces as `missingAPIKey` (`LLMService.swift:1169`) — terminal *for
  that provider*, retryable on the next. The `missingAPIKey` classification below is per-candidate,
  not chain-killing, for OAuth-backed candidates.
- **Set the restore bookkeeping on every hop.** `originalModelId` is captured only in the
  `.switchModel` route today (`OpenGlassesApp.swift:2671-2673`) and `finish` restores only when set
  (`:2750-2755`); a cascade that switches models on a `.keepCurrent`/`.localAgent` turn without
  setting it permanently changes the user's active model.
- **Re-check `Task.isCancelled` between hops** — a barge-in during hop 1 must not launch hop 2
  (ties to P4).
- **P3 lands first**: "empty completion" is only a retry-worthy classification once the P3 guard
  exists to surface it as an error — the dependency direction is explicit.
- Preserve conversation history correctly across a mid-turn model switch (don't double-append the user
  turn; the current single-shot appends live inside `sendLocal`/`sendCloud`).
- Count each attempt toward usage/cost tracking (Plan AU) so a silent cascade doesn't hide spend.
- Agentic gating unchanged: a cloud fallback is a normal provider call, not a gateway action.

**Tests (pure, headless).** Chain returns the next candidate for `429`/`promptTooLong`/timeout and
`nil` for `missingAPIKey`; backgrounded chain skips MLX candidates; exhausted chain surfaces the
*last* real error (not the generic line); attempt cap is honoured; a bigger-window model is chosen for
`promptTooLong`.

---

## P2c — Narrate what the app is doing (audible model-switch notification) 🟠 Important

**Principle (user request).** The app should *tell the user what it's doing* rather than silently
change behaviour. Model switches are the first and most important case: when the assistant falls back
from the preferred local model to a cloud model (cost/latency implication), the user should hear it.

**The gap today.** Every model switch is silent — the cascade doesn't exist yet, and even the existing
auto-routing switch just `print`s (`OpenGlassesApp.swift:2671`, `.switchModel` case). The user has no
signal that the model — or the cost profile — changed under them.

**Mechanism (already present, no new infra).** `TextToSpeechService.speak(_:urgency:mirrorToHUD:)`
(`TextToSpeechService.swift:160`) speaks and mirrors to the HUD; earcon tones
(`playAcknowledgmentTone`/`playConnectTone`, `TextToSpeechService.swift:373,404`) give a sub-second
non-verbal cue.

**Behaviour.**
- **On the first fallback hop of a turn only** (not once per hop, not on the final restore): a brief
  spoken line, mirrored to HUD, at low urgency, *before* the retry so it fills the latency beat rather
  than adding to it. Word it by reason and destination:
  - local → cloud on overflow/local failure: *"That's a bit much for the on-device model — switching
    to <cloud model name>."*
  - cloud → next on `429`/quota: *"<Model> is rate-limited — switching to <next model name>."*
  - name the destination when the user has multiple cloud models so "cloud" isn't ambiguous.
- Optionally precede the phrase with a short earcon so a user who's tuned out the words still gets a
  "something changed" signal.
- When the chain is **exhausted**, speak the real reason, not the generic line — e.g. *"All my models
  are unavailable right now — the last one was rate-limited."*
- Apply the same one-line narration to the **existing** silent auto-routing `.switchModel` case so the
  principle holds everywhere a model changes, not just on failure. (A persona/session switch the user
  initiated doesn't need narrating — they did it on purpose.)

**Two behavioral guards (from the 2026-07-10 re-verification):**
- **Restart the thinking sound after narrating.** `speak()` calls `stopThinkingSound()`
  (`TextToSpeechService.swift:196`); the turn starts the thinking sound at
  `OpenGlassesApp.swift:2682` and only `finish` stops it. A mid-turn narration that doesn't restart
  it (`startThinkingSound`, `:708`) makes the retry latency dead air — exactly the P3 symptom the
  narration was meant to fill.
- **Narrate interactive turns only.** `sendMessage` is also driven by notification triage
  (`OpenGlassesApp.swift:3087`), scheduled agent runs, and meeting summaries; speaking a model-switch
  notice during a background turn is noise and contradicts Plan W's presence principle. Add an
  interactive-turn predicate on the announce (Plan W's presence signal is the right gate; Plan W has
  no narration machinery of its own, so no conflict).

**Config.** A "Narrate model switches" toggle (default **on**, matching the stated preference for the
app to talk about what it's doing). Respect the existing emotion/urgency + sanitization path so the
notice doesn't stomp an in-flight reply.

**Tests (pure/headless where possible).** The narration builder returns the correct phrase for
`local→cloud` overflow vs `cloud→cloud` rate-limit vs exhaustion, names the destination model, and
fires once per turn (a recorder asserts a single announce across a two-hop cascade). Toggle off ⇒ no
announce, cascade still works.

---

## P3 — Local path silently produces dead air 🟠 Important

**The bug.** Anthropic and Gemini both reject an empty completion (`LLMService.swift:1328`, `:1818`);
`sendLocal` has no equivalent guard. `TextToSpeechService.speak` drops an empty string silently
(`TextToSpeechService.swift:161`). A sub-1B model emitting only `<tool_call>` markup (stripped to
empty) or an immediate EOS yields total silence — no TTS, no tone, no HUD, no error.

**Fix.** Add `guard !finalAnswer.isEmpty else { throw LLMError.invalidResponse("Local") }` to
`sendLocal`, matching the cloud providers — on **both** return paths: `finalAnswer` (`LLMService.swift:2047`)
*and* the tool-call path's `cleanFinal` (`:2017`), which is also markup-stripped and can be empty
(model answers the tool result with another `<tool_call>`). (Pairs with P2 — over-trimming raises
empty-completion odds.)

**Seam (required for the test).** No stub seam exists: `LLMService.localLLMService` is a concrete
`LocalLLMService?` (`LLMService.swift:150`) and `generate()` requires a loaded `ModelContainer`.
Either extract the empty-check into a pure helper (cheapest) or add a generator protocol/closure
seam — the phase includes whichever is chosen; the test is not writable headlessly without it.

**Tests.** The guard (via the pure helper or a stubbed generator) rejects "" / whitespace /
tool-call-only on both return paths, throwing `invalidResponse` rather than returning an empty
string to the speaker.

---

## P4 — Local generation ignores cancellation (barge-in) 🟠 Important

**The bug.** `generate()`'s token loop checks background state every iteration but never
`Task.isCancelled` (`LocalLLMService.swift:295-313`). `currentLLMTask?.cancel()` on "stop"/barge-in
(`OpenGlassesApp.swift:1676`, `:1739`) marks the task cancelled, but the loop doesn't poll it, so MLX
inference runs to completion (GPU/battery burn) even though the reply is correctly not spoken. There's
also no `isGenerating` entry guard, so a fast follow-up can enter `generate()` concurrently on one
`ModelContainer`.

**Fix.** Check `Task.isCancelled` inside the `while true` loop. **Cancellation always *throws*
`CancellationError`** — never the background check's return-partial-output behavior
(`LocalLLMService.swift:298-299`): `ConversationTurnRunner` maps `CancellationError` → `onCancelled`
(`ConversationTurnRunner.swift:49-50`), which is the only way a barge-in doesn't speak the partial
reply. Guard `generate()` entry with `guard !isGenerating else { throw … }` (the sequential
second/third `generate()` calls inside `sendLocal` — `LLMService.swift:2001`, `:2036` — are
one-at-a-time and won't trip it).

**Seam (required for the test).** "Cancelling mid-stream stops token production" needs a real MLX
model on GPU as written. Extract the token loop around an injected `AsyncSequence`/iterator so a fake
stream can drive it headlessly — that seam is part of this fix.

**Tests.** Cancelling the wrapping task mid-stream stops consumption of the fake stream promptly and
throws `CancellationError` (not a partial return); re-entering `generate()` while `isGenerating`
throws instead of running two generations on one container.

---

## P5 — Download "Cancel" is a UI-only no-op 🟠 Important

**The bug.** `activeDownloadTask` (`LocalLLMService.swift:24`) is declared but **never assigned** — the
real `Task` lives in the caller (`AgenticFeaturesView.swift:104`). `cancelDownload()`
(`LocalLLMService.swift:148`) cancels a permanently-nil task and just resets published UI state, while
`hub.downloadSnapshot` keeps running. Because `isDownloading` is cleared, the user can start a second
multi-GB download; both write the same shared progress state and both run to completion, silently
eating bandwidth/disk/battery.

**Fix.** Make the service own the cancellable unit: wrap `hub.downloadSnapshot` in a `Task` assigned to
`activeDownloadTask`, await it from `downloadModel`, and have the progress closure honour
`Task.isCancelled` (or pass a cancellable `Progress`) so cancellation reaches the network/disk layer.
**Both download UIs route through the service:** `AgenticFeaturesView` (the Task actually lives at
`:331`) *and* `LocalModelManagerView.swift:199-204`, which starts downloads in its own `Task` and has
**no cancel button at all** — add one. Adjacent gap to cover or explicitly defer: `loadModel()`
(`LocalLLMService.swift:181-189`) drives hub downloads through `factory.loadContainer` with the same
shared `downloadProgress` and no cancellation path. Also: the `guard !isDownloading` rejection
(`:126`) is silent — return a message (or throw) so a swallowed tap doesn't look like a dead button.

**Seam (required for the test).** `HubClient` is a concrete `private let` (`:32-37`) — cancelling a
real in-flight download in a unit test means network. Inject a download function so the test drives
a fake; that seam is part of this fix.

**Tests.** `cancelDownload()` cancels the in-flight (fake) download task; a second `downloadModel`
while one is active is rejected **with a visible message** by `guard !isDownloading` (which now
reflects a truly-live download); both views' downloads are cancellable through the service.

---

## P6 — Feature-claim honesty fixes 🟡 Minor

Small, mechanical truthfulness fixes surfaced by the review:

- **`fitness_coach` `check_form` is a hardcoded deflection** (`FitnessCoachingTool.swift:73`) — the
  built `PoseAnalyzer.analyzeForm` is never called (dead code). Either inject `CameraService` (mirror
  `ColorIdentifierTool`) and call `PoseAnalyzer` on the latest frame, or change the tool `description`
  to stop claiming "check form via camera." (If wired: inject the camera seam — tests must never
  exercise `.shared` services that touch Wearables.)
- **"Send" tool descriptions overpromise.** `MultiChannelMessageTool` (`send_via`,
  `SendEmailTool.swift:6`) and `SendMessageTool` (`send_message`, `SendMessageTool.swift:8`) only open a
  pre-filled compose screen (correct safety design), but their LLM-facing `description` says "Send."
  Reword to "Opens WhatsApp/Telegram/Email/Messages with a pre-filled message for the user to review
  and send — cannot send automatically." (Return strings are already honest.)
- **`PrivacyFilterService.exemptFaceprints`** (`PrivacyFilterService.swift:18`) is declared but never
  populated or read — decide whether "don't blur known contacts" is intended (wire it) or drop the
  dead field.

---

## What held up under attack (no change needed)

Recorded so the remediation doesn't accidentally "fix" working code:

- Core MLX **background constraint is properly enforced** — both GPU entry points re-check foreground
  state before Metal work and per-token during generation, throwing catchable `.backgrounded`; every
  caller handles it. No routing TOCTOU crash. ([[project_local_model_background]])
- **RemoteInvoke** (Plan BH) is exemplary: deny-by-default when Agent Mode is off, per-class toggles,
  token-bucket limits, capture = confirm→announce→act, closed-table alias parsing, full audit. The
  `delegateTask` gap (P0) is an outlier against this standard, not the norm.
- `AgentScheduler`, `MemoryLoopService`, `SkillEvolutionService`, `AgentControlTool`, `MCPGlassesServer`
  (bearer-token auth, Plan BC) all gate correctly and re-check the flag live.
- On-device ASR/Kokoro TTS are CPU/ONNX, not MLX — background-safe.
