# Plan EH — OpenClaw 2.0 Wire Alignment & New Surfaces

**Status:** 🚧 P1 implemented 2026-09-03 (branch `feat/eh-p1-openclaw-2-wire`; full unit suite 381 suites green, Release build green, privacy scanner PASS); P2–P4 planned
**Origin:** OpenClaw v2026.8.1 ("OpenClaw 2.0", 2026-08-31) and v2026.8.2 (2026-09-01). The wire was
verified against the gateway's own protocol schemas and method catalog on `main` (2026-09-02), not
against the release prose.
**Depends on:** Plan AR (device pairing), Plan BH (remote invoke), Plan BK P0 (Agent-Mode gate),
Plan N (agent harness), Plan CN (vision attachment)
**Unblocks:** the live round trips that AR, BH, V, N and CN P3 defer as "backend-pending"; the
first-class question and approval surfaces that N P4 / BN / AR keep waiting on
**Shape:** P1 wire fix (one PR, pure cores first), P2 questions + approvals, P3 node role + tool
descriptors, P4 gateway-in-CI live edge

---

## The problem

Our gateway client was written against a protocol we inferred from docs and other clients. The 2.0
gateway validates every request against **closed** JSON schemas (unknown keys are rejected, not
ignored) and its method catalog has moved. Read against the current schemas, the client does not
connect, and where it would connect it would lose the answer to every delegated task:

| We sent | 2.0 wire |
|---|---|
| `connect` with an extra `deviceCapabilities` key and a `client.deviceId` key; `role: "operator"` + `client.mode: "node"` | Closed schema — either unknown key rejects the frame. Node semantics (`caps`, `commands`, inbound invoke) apply only to `role: "node"`. Protocol is 4 (nodes get a 3–4 window). |
| Device signature over `v3\|…\|ios\|iphone`, signed with the phone clock | Gateway rebuilds the v3 payload from `client.platform` and `client.deviceFamily`. We never sent `deviceFamily`, so the signature never verified and the socket closed. The challenge carries `payload.ts`; first-party clients sign with it (±2 min skew window on the gateway). |
| `sessions.send {sessionKey, text, imageBase64, imageMimeType, agentId}` | Closed `{key, message, agentId?, thinking?, attachments?, timeoutMs?, idempotencyKey?}`. The response carries a `runId`; the answer arrives later as `chat` events (`state: "delta"` → `deltaText`, `state: "final"` → `message.content[0].text`), keyed by `runId`/`seq`. |
| Listeners for `session.chunk`, `stream.chunk`, `session.compacted`, `session.truncated`, `device.paired` | None of these exist. `GATEWAY_EVENTS` has `chat`, `agent`, `heartbeat`, `cron`, `node.invoke.request`, `device.pair.requested/resolved`, `question.requested/resolved`, `exec.approval.requested/resolved`, … |
| `tools.available` | `tools.catalog` / `tools.effective` |
| `cron.create` / `cron.delete` with `{expression, task}` | `cron.add` / `cron.remove` with `{name, schedule, sessionTarget, wakeMode, payload, …}` |
| `memory.query` / `memory.store` | Only `memory.search` exists |
| `channels.send` / `channels.list` | Gone (`channels.status/start/stop/logout` only) |
| `agent.start` / `agent.status` / `agent.cancel` (Plan N harness) | Never existed. Equivalent: `sessions.create` (placement: local / cloud worker / paired device) + `chat.send` + `agent` events + `sessions.abort`. |
| Inbound invoke as a `{type:"req", method:"node.invoke"}` frame answered by a `res` frame (Plan BH) | `{type:"event", event:"node.invoke.request", payload:{id, nodeId, command, paramsJSON, timeoutMs, idempotencyKey, sessionKey}}`, answered by the RPC `node.invoke.result {id, nodeId, ok, payload\|payloadJSON, error}` with optional `node.invoke.progress {invokeId, nodeId, seq, chunk}`. |
| `device.event` pushed as a bare event frame | Node-originated events go through the RPC `node.event {event, payload\|payloadJSON}` |
| Device token read from `res.result.token` | `hello-ok.auth.deviceToken`; pairing pending is a typed error with `details.code: "PAIRING_REQUIRED"` and `recommendedNextStep` |
| `X-Scopes` and `x-openclaw-message-channel` headers on the socket | Read on HTTP routes only, never on the WebSocket handshake (BR P4's channel tagging is inert — harmless) |

Still valid: the `heartbeat` event (`status: "sent"`, `preview`, `silent`) and the `cron` event
(`action: "finished"`, `summary`) that feed `triageOpenClawNotification`. Note `cron` events are now
scoped to the owning session, so a job created elsewhere does not reach the glasses socket.

The consequence: with Agent Mode on and a 2.0 gateway configured, neither `OpenClawBridge` nor
`OpenClawEventClient` could authenticate. No feature regressed visibly because the gateway is
optional (BrainStore is native-first), which is exactly why this needed a plan and tests rather
than a field report.

## Relevant seams

- `OpenGlasses/Sources/Services/OpenClaw/GatewayWire.swift` — **new (P1)**: wire constants, the
  `connect.challenge` and `hello-ok` parsers, `GatewayAttachment`, the `GatewayRequestCatalog`
  (the only place a method name or params key is spelled), and the spoken-reply control-line
  sanitizer
- `OpenGlasses/Sources/Services/OpenClaw/ChatRunTracker.swift` — **new (P1)**: `runId`
  correlation, delta/final folding, park-not-drop on timeout
- `OpenGlasses/Sources/Services/OpenClaw/GatewaySocket.swift` — **new (P1)**: the one transport
  seam; production wraps `URLSessionWebSocketTask`, tests script frames
- `OpenGlasses/Sources/Services/OpenClaw/OpenClawConnectParams.swift` — the one handshake builder
  both sockets share (keep it one builder; the signature covers what it emits)
- `OpenGlasses/Sources/Services/OpenClaw/OpenClawDeviceIdentity.swift` — v3 payload was already
  byte-correct; the fix was in what the connect frame declares, not in the signer
- `OpenGlasses/Sources/Services/OpenClawBridge.swift`, `OpenClawEventClient.swift`
- `OpenGlasses/Sources/Services/Gateway/PairingResponseInterpreter.swift`
- `OpenGlasses/Sources/Services/OpenClaw/RemoteInvoke/` (Plan BH core — parser/policy/executor
  survive; only the frame shapes change, in P3)
- `OpenGlasses/Sources/Services/AgentHarness/Adapters/OpenClawAgentHarness.swift` (Plan N)
- `OpenGlasses/Sources/Services/NativeTools/OpenClawSkillsTool.swift`
- Tests: `GatewaySchemaPinTests`, `GatewayWireTests`, `ChatRunTrackerTests`,
  `OpenClawScriptedSocketTests`, `OpenClawConnectParamsTests`, `OpenClawDeviceIdentityTests`,
  `PairingResponseInterpreterTests`, `AgentSessionTests`

## Decisions and invariants

1. **Schemas are the contract, not prose.** Every frame we emit is pinned by a test against a
   checked-in copy of the relevant 2.0 schema key set (`GatewaySchemaPinTests.schemaKeys`, a
   fixture, not a dependency). A closed object means a new key is a wire break; the test says so
   before the gateway does.
2. **Reply correlation by `runId`.** `delegateTask` returns when the `chat` event with
   `state: "final"` for its `runId` arrives (or `aborted`/`error`), with the run's deltas streamed
   to `onStreamChunk`. A late final for a run we stopped waiting on is announced through
   `onLateResult` as the answer it is, not handed to the triage pass built for unsolicited news.
   Nothing is dropped on the floor.
3. **Capability gating from `hello-ok`.** `features.methods` decides what we call. A method absent
   from the catalog is reported as unsupported, never attempted, so the next protocol move
   degrades honestly. An unknown catalog (pre-2.0 gateway) means "try it".
4. **One node, one role.** The event/invoke socket connects as `role: "node"` and declares
   `commands` and `caps` (P3); the chat socket stays an operator. Node commands are gated
   server-side by `node.pair.approve` (device pairing alone no longer exposes commands) and, for
   capture, by the gateway's own dangerous-command allow-list. Our BH policy (deny-by-default,
   Agent-Mode gated, capture consent off) stays as the client-side floor beneath that; neither
   replaces the other.
5. **Agent Mode still gates everything** (BK P0): both sockets, questions, approvals, node
   commands. HIPAA hard-disable is unchanged.
6. **Privacy logging rules apply to the new payloads.** Question text, option labels, approval
   summaries and node command params are wearer content; `PrivacyLog` records counts, ids and
   outcome classes only.

## Phase P1 — Wire fix (one PR) — implemented 2026-09-03

- `OpenClawConnectParams`: `deviceCapabilities` and `client.deviceId` gone; `client.deviceFamily`
  (the same value the signer normalises) and `client.instanceId` for the paired device id; `caps`
  / `commands` only when declared; the challenge `ts` as `signedAt`; `minProtocol 4, maxProtocol
  4` for the operator role, `3…4` for node.
- `OpenClawDeviceIdentity`: unchanged payload layout; the signer now takes `platform` and
  `deviceFamily` explicitly so the frame and the signature cannot disagree (tested).
- `PairingResponseInterpreter`: reads `hello-ok` (`auth.deviceToken`, `features`, `policy`) and
  the pairing-required details (`requestId`, `recommendedNextStep`, `pauseReconnect`); a stale
  device signature is an error, not a pending approval.
- `GatewayRequestCatalog`: `sessions.send`, `chat.send`, `sessions.abort`, `tools.catalog`,
  `tools.effective`, `cron.add/update/remove/list`, `memory.search`, `skills.status/search/detail`,
  `node.event`. `GatewayWire.removedMethods` lists what is gone; `agentRequest` refuses them.
- `ChatRunTracker`: runId → chunks / awaitable outcome; `park` on timeout; late final →
  `onLateResult` (AppState enqueues it as "From OpenClaw: …" on the agent notification queue,
  bypassing triage). The spoken-reply control line (`{"voice":…,"once":true}`) is withheld while
  it may still be arriving and stripped from both deltas and finals.
- `OpenClawBridge`: challenge → connect → hello-ok on a `GatewaySocket`; `chat` events routed to
  the tracker, `agent` events exposed raw; `tools.effective` (falling back to `tools.catalog`)
  feeds the prompt's tool list; cron and memory wrappers rebuilt on the catalog; `storeMemory`
  and the channel wrappers report honestly (the gateway has no such methods; the channel wrappers
  had no callers and are gone).
- `OpenClawEventClient`: same handshake and interpreter; device events are sent only once the
  socket holds the node role (P3), never as a frame the gateway would refuse.
- `OpenClawAgentHarness` (Plan N): `sessions.send` into `agent:main:glass:tasks` → `runId`;
  status and completion from the tracker; `sessions.abort` to cancel; approvals throw until P2.
- `OpenClawSkillsTool`: `skills.status` / `skills.search` / `skills.detail` when the catalog offers
  them; the prompt-based fallback otherwise.
- Plan CN P3: the frame rides `attachments: [{type, mimeType, fileName, content, sizeBytes}]`,
  bounded by `hello-ok.policy.attachments.maxImageBytes`; oversize frames are dropped before
  sending. `agentVisionAttachmentEnabled` now defaults **on**.
- Tests: `GatewaySchemaPinTests` (every builder's keys ⊆ the recorded schema, removed methods
  never built), `GatewayWireTests`, `ChatRunTrackerTests`, and `OpenClawScriptedSocketTests`, which
  drives **both sockets** through challenge → connect → hello-ok → `sessions.send` → delta → final
  against a scripted gateway and pins what went over the wire. **The fixtures are schema-derived,
  not captured from a live gateway** — P4 records real frames and replaces them.

## Phase P2 — Structured questions and approvals

- **Questions.** Subscribe with scope `operator.questions`. On `question.requested` (1–3 questions,
  2–4 options each, optional `multiSelect`, free-text "Other" always allowed, default 900 s
  timeout): speak the header and options, show a HUD `ButtonGroup`, accept a spoken answer
  (option label, ordinal, or free text) and call `question.resolve {id, answers}`; `cancel: true`
  on explicit "skip". `question.list` on connect backfills anything asked while we were away.
  This retires the "parse choice buttons out of LLM prose" backlog item: the protocol object *is*
  the choice set.
- **Approvals.** Scope `operator.approvals`, `caps: ["exec-approvals"]`. `exec.approval.requested`
  → the shared consent surface (BN) with the typed operation summary; `exec.approval.resolve`;
  `exec.approval.list` backfill on connect. One-time grants (`exec.approval.grants.*`) are shown
  for revocation in Gateway settings; we never create one from voice.
- **Tool events.** `caps: ["tool-events"]`; `agent` events with tool activity feed the spoken
  progress beats (CB/CE) instead of the current guess-from-latency behaviour.
- Pure cores: `QuestionPresenter` (question record → spoken script + HUD layout + answer
  matcher), `ApprovalPresenter`; both headless-tested with the schema fixtures.

## Phase P3 — Node role and tool descriptors

- The invoke socket connects as `role: "node"`. Advertise the standard command families we can
  honour so the gateway agent's existing node tooling drives the glasses without custom prompting:
  `camera.snap`, `camera.clip`, `location.get`, `system.notify`, `device.info`, `device.status`,
  and `talk.ptt.start/stop/cancel/once` via the `talk` cap. Map each onto the existing
  `RemoteGlassesCommand` cases; aliases stay in `RemoteCommandParser`.
- Our glasses-specific actions (display show/clear, translation, transcription, add note,
  transcript) publish as node plugin tool descriptors (`node.pluginTools.update`), which is the
  documented way for a node to expose agent-visible tools.
- Frame shapes: consume `node.invoke.request` events, answer with `node.invoke.result`, stream
  long captures with `node.invoke.progress`; `sendDeviceEvent` becomes `node.event` (already
  built, gated on the node role).
- Capability approval UX: surface `node.pair.requested/resolved` in Gateway settings so the wearer
  understands why a command is "pending on the gateway" rather than silently filtered.

## Phase P4 — Live edge: a gateway in CI

2.0 publishes versioned Docker images. A gateway container in the test lane, paired once with a
device identity fixture, closes the "backend-pending" deferrals in one place: AR approval round
trip, BH invoke round trip, N event stream, V's SSE handshake, and the CN attachment size bound.
The A2A 1.0 channel plugin the same gateway exposes (`/.well-known/agent-card.json`,
`SendMessage`/`GetTask`) is a real peer for Plan BL's bridge tests. Keep it opt-in (`OPENCLAW_LIVE`)
so the ordinary suite stays hermetic; record fixtures from it to replace P1's schema-derived ones.

## Non-goals, with reasons

- **Widgets, canvas, A2UI.** `canvas.present` is macOS-only today; HUD-as-canvas is a future idea,
  not this plan.
- **Gateway memory as a store.** `memory.search` is read-only from our side; BrainStore stays the
  native-first memory. Two memories that disagree is worse than one that is thin.
- **Cloud workers, Fleet, Swarm, the web UI rebuild, desktop apps.** Server-side products we
  consume, if at all, through `sessions.create` placement later.
- **The 2.0 breaking migrations** (OpenProse, `openai-codex/*` model refs, plugin SDK import paths,
  SQLite session store) touch nothing in our tree; our ChatGPT-subscription provider (BW) talks to
  the backend directly, not through a gateway model ref.
- **Being the OpenClaw iOS node.** The official iOS app is now a full node (camera, location,
  HealthKit, Talk, Watch relay). Our value is the glasses and the on-device tools; we interoperate,
  we do not compete on client surface.

## Risks

- The gateway pins clients and servers together and calls a wire bump "an explicit breaking event";
  the schema pins must be re-recorded on each gateway minor we claim support for.
  `GatewayWire.pinnedGatewayVersion` names the one they were taken from.
- Node capability approval is a human step on the gateway host; without it P3 commands are
  silently filtered. The settings surface in P3 exists to make that visible, not optional.
- `client.mode: "node"` on an operator-role socket was accepted by the pre-2.0 gateway and is in
  the 2.0 closed mode enum, but the gateway's policy hooks branch on mode in a few places
  (`backend`, `ui`, `webchat`, `cli`). P4's live run is where a mode-specific refusal would show.
