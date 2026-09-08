# Plan BG — Spine Refactor (phased): single-source tool prompts, flow engine, provider adapters, audio-engine merge

**Status:** ✅ Phased, one PR per phase, all shipped; on-glasses smoke test of the P2 voice path
still owed. **P1 shipped** (registry-generated tool prompts).
**P3 shipped** (one tool-loop driver). **P4 shipped** (merged realtime audio engine).
**P5 shipped incrementally** (`@UserDefaultsBacked` cohorts, model types → `Models/`, NotesTool rename).
**P2 complete:** pure `VoiceCommandParser`; `ConversationFlowEngine` + `VoiceCommandHandler`
chains (pre-LLM: teleprompter/HUD task/launcher/intent-ignore; post-store: stop/goodbye/photo);
`resumeListeningOrReturnToWakeWord` dedup; pure `ModelRoutingPolicy`; `ConversationTurnRunner`
(the LLM-turn skeleton — send → post-process → cancel-check → accept → speak → always-finish —
behind testable closure seams, adopted by the photo, normal, and typed turns, all tracked in
`currentLLMTask` so barge-in/stop/cancel stops any turn); `ConversationStartSequence` (the
wake-detected choreography, locking the engine-before-listening ordering). All P2 changes to the
live voice path still want an on-glasses smoke test.

## The problem
The July 2026 audit's clearest structural signal: **whatever got extracted got tested; the three
god objects never got extracted, so the app's spine is untested.** 147 test files cover every
extracted core, but there are zero tests for `AppState`/`handleTranscription` (the main state
machine), `LLMService` (provider parsing + four tool loops), or either realtime session manager.
Concentrated debt:

- `App/OpenGlassesApp.swift` — 3,246 lines; `AppState` holds ~55 service instances, connection
  teardown logic inside an `isConnected` didSet, and `handleTranscription` (~370 lines) with the
  resume-listening block copy-pasted 5+ times. `currentLLMTask` is only assigned in the photo path,
  so cancel/barge-in can't cancel a normal text turn (the response lands later and speaks anyway).
- `Services/LLMService.swift` — 2,268 lines; **four independent copies of the tool-execution
  loop** (Anthropic/OpenAI-compatible/Gemini/local — dispatch at `:1337/:1574/:1896/:2101`); every
  tool-loop bug must be fixed 4×. History is stringly-typed `[[String: Any]]`.
- **Duplicated tool prose:** `LLMService.buildSystemPrompt` (`:213+`) and
  `GeminiLiveSessionManager.buildSystemInstruction` (`:399-583`) carry two independently
  maintained, already-diverging hardcoded lists of ~60 tool one-liners — the CLAUDE.md
  "update both prompts" rule exists because of this. Every `NativeTool` already has a
  `description`; `Models/ToolCallModels.swift` already single-sources the machine-readable
  schemas — only the prose was left behind. (CLAUDE.md also says "36+ tools"; it's ~100.)
- `GeminiLiveAudioManager` (477 lines) and `OpenAIRealtimeAudioManager` (515) are ~90%
  method-for-method identical; interruption fixes need twin edits.
- `Utils/Config.swift` — 3,192 lines, 246 `UserDefaults` references, 8 domain model types that
  belong in `Models/`, and a get-var + set-func idiom repeated hundreds of times.

## Phases (each independently shippable, in order)

### Phase 1 — Registry-generated tool prompts (~½ day)
`SystemPromptBuilder.toolSection(registry:)` renders the tool list from each tool's `name` +
`description` (+ MCP/quick-action extras), replacing both hardcoded prose blocks. Both prompt
builders call it. Delete the CLAUDE.md both-prompts rule; fix the "36+" count. Snapshot test:
generated section contains every registered tool exactly once; no tool in prose that isn't in the
registry (the current drift, made impossible).

### Phase 2 — `ConversationFlowEngine` + `VoiceCommandHandler` chain
Extract `handleTranscription`/`sendTextMessage`/`handleWakeWordDetected`/barge-in/stop-goodbye into
`Services/Flow/ConversationFlowEngine`. Pre-LLM handlers (teleprompter, HUD task card, HUD
launcher, intent classifier, persona detection, stop/photo commands) become an ordered
`[VoiceCommandHandler]` (`handle(_:) async -> Bool`) — they already have exactly that shape.
One `resumeListening()` replaces the 5+ copies. **Every turn runs inside a tracked, cancellable
task** (fixes the can't-cancel bug; `Task.isCancelled` checked before speaking). The engine takes
seams (transcription, TTS, LLM, wake word) as protocol deps → the main state machine gets its
first tests (wake → transcribe → LLM → speak → resume; error mid-flow → returns to wake word —
the audit's stuck-listening scenario as a regression test).

### Phase 3 — `LLMProviderAdapter` + one tool-loop driver
Protocol per provider (`buildRequest / parseResponse / extractToolCalls / appendToolResult`) with a
single shared driver owning the loop (iteration cap, tool dispatch, `yield_to_human`,
Plan BF's `HistoryHygiene` called in exactly one place). Typed `ChatMessage` replaces
`[[String: Any]]` at the driver boundary (adapters translate to wire shape). `ToolDeclarations`
proves the pattern. Ship as: driver + Anthropic first, then fold the other three in mechanically.

### Phase 4 — `RealtimeAudioEngine` merge
One parameterized engine (formats/rates injected) replaces the twin audio managers; the pure
policies (`AudioRoutePolicy`/`AudioInterruptionPolicy`, already extracted + tested in Plan AP)
stay. ~470 duplicated lines deleted.

### Phase 5 — Config split (incremental, lowest urgency)
`@UserDefaultsBacked` property wrapper; per-feature settings structs; move the 8 model types to
`Models/`; keep `Config` as a deprecated façade. `ConfigTests` guards each domain as it moves.
Alongside: file the 62 loose `Services/` root files into the existing folders (XcodeGen makes
moves free); rename `RemindersTool.swift` → `NotesTool.swift` (it contains the notes tools).

## Scope
Pure refactor: no behavior change except the named bug fixes (cancelable turns, prompt-drift
elimination). Each phase lands with tests for the newly extracted seam. Out: SwiftUI view
restructuring, DI framework adoption, new features.

## Why this matters
Adding provider #5 or fixing a tool-loop bug currently costs 4×; the wake→LLM→TTS spine — the
product — has zero regression protection; and two prompt copies have already drifted. Phase 1 pays
for itself the same day; Phases 2–3 are what let Plans BD/BF land safely and stop the god objects
growing.
