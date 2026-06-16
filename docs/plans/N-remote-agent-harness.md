# Plan N — Remote Agent Harness (phone-only, harness-agnostic agent control)

**Source pattern:** The concept of voice-driving a coding agent (e.g. Claude Code) from smart glasses via a relay. This is a clean-room design — concept only, no third-party code reused. Also informed by OpenAI Codex cloud agents and our own OpenClaw gateway. Related to [Plan E](E-mcp-server-mode.md) (MCP server mode), but inverted: here OpenGlasses is the *controller*, not the tool surface.

**Strategic fit:** Extends OpenGlasses from "assistant" to "hands-free remote for an autonomous coding/agent session." Lets a user dispatch a task by voice ("have the agent add a dark-mode toggle to my-app") and hear a spoken summary of what it did. Differentiator vs a dumb-pipe relay: ours isn't a dumb pipe — the on-device LLM decides *when* to dispatch and *narrates* the result, and `MCPGlassesServer` means the agent can even call back to the glasses ("what does the error on screen say?").

**Effort:** Core + OpenClaw adapter (Phase 1 MVP): ~3–4 days. Each additional adapter: ~1–2 days.

**Status:** 🚧 Phase 1 core shipped (`feat/remote-agent-harness`). The deterministic, harness-agnostic core is complete and headless-tested:
- **Models + protocol** — `AgentModels` (`AgentHarnessKind`, `AgentRunStatus`, `AgentRun`, normalized `AgentEvent`, `AgentRunResult` with a pure `apply`/`reduce` reducer) + the `AgentHarness` protocol (`start`/`events`/`status`/`cancel`/`respondToInput`) + `AgentHarnessError`.
- **Summarizer** — pure `AgentSummarizer`: event/result → one spoken line ("The agent created two files, … and opened a pull request. Done."), with a `maxLength` cap, singular/plural counts, failed/cancelled variants, and per-event `narration(...)`. The highest-value tested unit — written once, every adapter benefits.
- **Session service** — `@MainActor AgentSessionService`: dispatch via the active harness, aggregate the event stream into `AgentRunResult`, narrate key moments + the final summary via injected TTS, cancel, and the `awaitingInput` confirmation gate (decline → cancel, the safety default). The `handle(_:)` state machine is unit-tested directly.
- **OpenClaw adapter** — `OpenClawAgentHarness` over a new public `OpenClawBridge.agentRequest(method:params:)`. Its gateway-JSON → `AgentEvent` `normalize(...)`, `parseStatus(...)`, `runID(...)`, and `start(...)` are pure-tested against a mock sender; a status-poll event stream drives terminal events today.
- **Tool + wiring** — `AgentControlTool` (`code_agent`: start/status/cancel/confirm/deny), **gated on `Config.agentModeEnabled`**, registered in `NativeToolRegistry` and described in both the `LLMService` and `GeminiLive` system prompts. `AgentSessionService.shared.configure(...)` wired at launch to the OpenClaw harness + TTS.
- **Tests:** 31 headless (`AgentSummarizerTests` 17, `AgentSessionTests` 14) covering the summarizer permutations, result aggregation, the session state machine (dispatch/complete/error/awaitingInput/cancel/confirm), and the adapter normalization + tool gate. Full suite 705 green, Debug + Release.

**Phase 2 shipped** (`feat/remote-agent-harness-phase2`) — the Custom URL adapter + multi-harness selection + settings UI:
- **`CustomAgentHarness`** — a generic HTTP adapter for any endpoint the user already runs: POST to start, GET-poll status, optional POST cancel. Request building + response mapping are pure (`CustomHarnessConfig.startRequest/statusRequest/cancelRequest` + `JSONPath` dot-path extraction with number/bool coercion), tested through a `URLProtocol` stub; the adapter is the thin async layer (injectable `URLSession`).
- **`AgentHarnessRegistry`** — lists the configured harnesses and resolves the *active* one: the user's configured default wins, else the first configured, else none. `AgentSessionService` now dispatches through `registry.active`, so a default switch or a new endpoint applies live. `code_agent` gains a **`switch_harness`** action.
- **Config** — `Config.defaultAgentHarness` (UserDefaults) + Keychain-backed `Config.customAgentHarness` (registered in the sensitive-keys list; status parsing shared via `AgentRunStatus.parse`).
- **`AgentHarnessSettingsView`** — default-backend picker + custom endpoint form (URLs, auth, field mapping), surfaced from Agentic Features (Agent-Mode-gated). `AppState.rebuildAgentHarnessRegistry()` re-reads it on save.
- **Tests:** +17 headless (`AgentCustomHarnessTests`) — config round-trip, `JSONPath`, request building + `start`/`status` over the stub, registry resolution, registry-backed dispatch, and the `switch_harness` action. Full suite 722 green, Debug + Release.

**Still deferred (per the build order):** the gateway-side `agent.*` methods + the rich live event stream (Phase 1's live half — needs a running gateway that exposes them; the adapter is ready and `normalize` maps the schema); the **Codex-cloud / Claude-remote adapters** (Phase 3, pending the Phase 0 trigger verification); and live token-streaming + the HUD confirm view (Phase 4).

---

## Constraints (the design contract)

1. **Phone-only.** OpenGlasses ships **no companion binary we build or maintain.** A coding agent fundamentally cannot run on iOS (no shell, no arbitrary filesystem, App Store sandbox) — so execution is *always* remote. "Phone-only" therefore means: the phone is the voice remote, and every harness is just a remote endpoint it connects to (cloud service, or a URL the user already runs). We integrate; we don't host.
2. **Harness-agnostic.** Support any agent backend — OpenClaw, OpenAI Codex, Claude Code (remote), or a custom endpoint — behind one adapter protocol, mirroring how `LLMProvider` abstracts LLM backends ([LLMService.swift:7](../../OpenGlasses/Sources/Services/LLMService.swift)).
3. **Gated.** The whole capability sits behind `agentModeEnabled` ([Config.swift:2213](../../OpenGlasses/Sources/Utils/Config.swift)), per the project convention for gateway/autonomous features.

---

## Architecture

Mirrors existing patterns: a provider abstraction (`LLMProvider`), a `@MainActor ObservableObject` manager (`FieldSessionService`/`LiveCoachService`), a single `NativeTool` entry point, and one shared summarizer (`MeetingSummaryTool`).

```
Sources/Services/AgentHarness/
├── AgentModels.swift          // Harness-agnostic core types (below)
├── AgentHarness.swift         // protocol AgentHarness + AgentHarnessKind
├── AgentHarnessRegistry.swift // Lists harnesses that are actually configured
├── AgentSessionService.swift  // @MainActor manager: dispatch, subscribe, narrate
├── AgentSummarizer.swift      // AgentRunResult → one spoken line (harness-agnostic)
└── Adapters/
    ├── OpenClawAgentHarness.swift   // REAL — reuses OpenClawBridge + OpenClawEventClient
    ├── CustomAgentHarness.swift     // Generic URL + token + field mapping
    ├── CodexCloudHarness.swift      // Stub until cloud trigger verified (Phase 0)
    └── ClaudeRemoteHarness.swift    // Stub until routines/web trigger verified (Phase 0)
```

### Core model (`AgentModels.swift`)

```swift
enum AgentHarnessKind: String, CaseIterable { case openclaw, codexCloud, claudeRemote, custom }

enum AgentRunStatus { case queued, running, awaitingInput, completed, failed, cancelled }

struct AgentRun: Identifiable {
    let id: String
    let harness: AgentHarnessKind
    let prompt: String
    let project: String?
    var status: AgentRunStatus
    let startedAt: Date
}

/// Normalized across every harness — adapters translate native events into these.
enum AgentEvent {
    case started(AgentRun)
    case progress(String)
    case fileCreated(String)
    case fileModified(String)
    case commandRun(command: String, ok: Bool)
    case prOpened(url: String)
    case pushed
    case assistantText(String)
    case completed(AgentRunResult)
    case error(String)
}

struct AgentRunResult {
    var filesCreated: [String] = []
    var filesModified: [String] = []
    var commandsRun: [String] = []
    var prURL: String?
    var pushed = false
    var finalText: String?
    var error: String?
}
```

### Protocol (`AgentHarness.swift`)

```swift
protocol AgentHarness {
    var kind: AgentHarnessKind { get }
    var displayName: String { get }
    var isConfigured: Bool { get }              // creds/endpoint present?
    func start(prompt: String, project: String?) async throws -> AgentRun
    func events(for run: AgentRun) -> AsyncStream<AgentEvent>   // stream- or poll-backed
    func status(_ run: AgentRun) async throws -> AgentRunStatus
    func cancel(_ run: AgentRun) async throws
}
```

The payoff is the **normalized `AgentEvent`**: one `AgentSummarizer` produces the spoken line ("Created two files, ran the tests, opened a PR. Done.") regardless of which harness ran. Write the summarizer once; every adapter benefits — a single provider-agnostic summarization kernel.

---

## Adapters & viability (honest, today)

| Harness | Connects via | Phone-only w/o a user box? | Status |
|---|---|---|---|
| **OpenClaw** | `OpenClawBridge.sendRequest(method:params:)` ([:439](../../OpenGlasses/Sources/Services/OpenClawBridge.swift)) — already speaks `{type:"req",id,method,params}` JSON over WS with LAN/remote reachability; progress via `OpenClawEventClient` | Yes — gateway runs wherever the user runs it; phone needs only URL+token | ✅ ~90% wired |
| **OpenAI Codex** | Codex *cloud* agent API | Yes, if the cloud trigger is real | ⚠️ verify (Phase 0) |
| **Claude Code** | Routines / web (claude.ai/code) | Partly — UI-only or unverified trigger; async only, not interactive | ⚠️ verify (Phase 0) |
| **Custom** | User-supplied URL + token + JSON field mapping (same spirit as Custom Tools / MCP servers) | Yes | ✅ trivial once protocol exists |

**OpenClaw is the only genuinely real, phone-only path today.** Codex-cloud and Claude-routines *might* offer no-box cloud execution but need their programmatic triggers confirmed before we build adapters. Anything self-hosted (an Agent SDK bridge) is just a "custom URL" a power user can opt into — supported, never required.

> OpenClaw protocol note: the gateway must expose an agent method (e.g. `agent.start` / `agent.status` / `agent.cancel`). We control the OpenClaw repos, so Phase 1 scope depends on whether that method exists or we define it on the gateway side too.

---

## Session flow (OpenClaw MVP, summary mode)

```
1. User (voice): "Hey [persona], have the agent add a dark-mode toggle to my-app"
2. On-device LLM recognizes intent → calls code_agent { action: "start", prompt: "...", project: "my-app" }
3. AgentControlTool checks Config.agentModeEnabled → AgentSessionService.start(harness: .openclaw, ...)
4. OpenClawAgentHarness.sendRequest(method: "agent.start", params: {...}) → AgentRun
5. OpenClawEventClient streams gateway events → normalized AgentEvent (.fileModified, .commandRun, ...)
6. AgentSessionService aggregates into AgentRunResult; speaks brief progress on key events
7. On .completed → AgentSummarizer → TTS: "Added a toggle, modified two files, opened a pull request. Done."
8. (optional) "Hey [persona], agent status" → code_agent { action: "status" } → spoken state
```

---

## Native tool surface & integration points

- **`AgentControlTool.swift`** (`NativeTool`, name `code_agent`) — actions `start | status | cancel | switch_harness`. Guards on `Config.agentModeEnabled`; returns a "turn on Agent Mode in Settings" message otherwise. Conforms to the protocol at [NativeTool.swift:7](../../OpenGlasses/Sources/Services/NativeTools/NativeTool.swift).
- Register in `NativeToolRegistry.init()`.
- Add tool description to system prompts in **both** `LLMService.swift` and `GeminiLiveSessionManager.swift` (CLAUDE.md step 3).
- `AgentSessionService.shared.configure(tts:registry:)` at launch in `OpenGlassesApp.swift` (alongside `LiveCoachService.configure`).
- **Settings:** `AgentHarnessSettingsView` to pick the default harness and configure a custom endpoint; visible only when Agent Mode is on (reuse `MCPServersView` patterns).
- **project.pbxproj:** add PBXBuildFile / PBXFileReference / group / Sources entries for each new file (CLAUDE.md step 4). *(Plan-adjacent: PR #2's XcodeGen migration would remove this chore.)*

---

## Safety (high blast radius — design in, not bolt on)

Autonomous code changes from a voice command can push, open PRs, run destructive commands. Default posture:

- **Spoken confirmation before irreversible actions** — push, PR, `rm`/`git reset`/migrations. The agent proposes, the summary asks ("I'm about to push to main — say 'confirm' to proceed"), execution waits on `awaitingInput`.
- This is exactly the **validation-on-notification** idea worth pairing with a display: on a HUD, show the diff/action and a confirm affordance instead of audio-only. The `awaitingInput` status is the seam for it.
- Surface the active harness + project prominently so the user always knows *where* the agent is acting.

---

## Build order

### Phase 0 — verify (½ day)
1. Confirm Codex-cloud and Claude routines/web programmatic triggers. Locks the viability matrix; decides whether Phase 3 is real.

### Phase 1 — MVP, shippable (~3–4 days)
2. `AgentModels` + `AgentHarness` protocol + `AgentRunResult`.
3. `AgentSummarizer` (+ unit tests — highest value).
4. `AgentSessionService` (dispatch, event aggregation, TTS narration, cancel).
5. `OpenClawAgentHarness` over `OpenClawBridge` + `OpenClawEventClient`.
6. `AgentControlTool` + registry registration + system-prompt wiring + `agentModeEnabled` gate.
7. `AgentHarnessSettingsView` + launch wiring + pbxproj.

### Phase 2 — Custom URL adapter (~1–2 days)
8. `CustomAgentHarness` — generic POST start + poll/stream + user field mapping.

### Phase 3 — Cloud adapters (pending Phase 0)
9. `CodexCloudHarness` and/or `ClaudeRemoteHarness` for no-box cloud execution (async "fire-and-forget, speak summary on completion").

### Phase 4 — optional
10. Live token-streaming mode (vs summary-only).
11. HUD progress + confirm view (ties to the display/validation direction).

---

## Tests (mirror the green feature-test target)
- `AgentSummarizer` — event lists → expected spoken strings (created/modified/commands/PR/error permutations, ≤320-char cap, "Done." terminator).
- `AgentSessionService` — state-machine transitions, cancel mid-run, error propagation, `awaitingInput` confirmation gate.
- `OpenClawAgentHarness` — gateway-event → `AgentEvent` normalization against a mock WebSocket.

---

## Open questions / decisions needed
1. **Summary-only vs live streaming for v1?** Summary-only is simpler and matches the glasses UX; streaming is Phase 4. *Recommendation: summary-only MVP.*
2. **OpenClaw gateway side** — does it already expose an `agent.*` run method, or do we define it together? Sets Phase 1's true scope.
3. **Safety confirmation** — require spoken (or HUD) confirmation before push/PR/destructive ops? *Recommendation: yes, on by default, via `awaitingInput`.*
4. **Model selection** — does each harness use its own model, or do we pass one from the Fast/Balanced/Best tiers? *Recommendation: harness-native for v1; expose an override later.*

---

## Dependencies / prereqs
- **`OpenClawBridge` + `OpenClawEventClient`** (existing) — WS transport, auth, LAN/remote reachability, event stream. The MVP adapter rides entirely on these.
- **`agentModeEnabled`** (existing) — the gate. Note this is the *agentic* gate, distinct from any IAP gating.
- **`LLMProvider` pattern** (existing) — the abstraction to mirror.
- **`MeetingSummaryTool` / `ConversationSummaryTool`** (existing) — summarizer prior art.
- **`MCPClient` / `MCPServersView`** (existing) — pattern for the Custom URL adapter + settings UI; `MCPGlassesServer` enables agent→glasses callback.
- Relation to **[Plan E](E-mcp-server-mode.md)**: Plan E exposes OpenGlasses *as* an MCP server (tool surface); Plan N makes OpenGlasses a *controller* of remote agents. Complementary, not overlapping.

---

## Why this matters strategically
Turns the glasses into a universal, hands-free remote for autonomous work — coding today, any agent harness tomorrow — without OpenGlasses owning or hosting the execution environment. Phone-only keeps support burden low; harness-agnostic keeps us un-bet on any single vendor; the on-device LLM as orchestrator + narrator is the moat a dumb-pipe relay design can't match.
