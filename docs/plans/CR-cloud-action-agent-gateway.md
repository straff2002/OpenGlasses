# Plan CR — Cloud Action-Agent Gateway (a real backend for the gateway client)

**Status:** 📝 Drafted (not scheduled), 2026-08-09
**Depends on:** Plan N (Remote Agent Harness), Plan AR (Gateway Device Pairing), Plan BH (Gateway
Remote Invoke), Plan BK P0 (Agent-Mode gate on `delegateTask`)
**Unblocks:** the "backend-pending" deferral shared by AR, BH, V, N and CN P3
**Shape:** pure cores first (P1), app wiring (P2), reference backend under `docs/gateway/` (P3),
connected apps (P4), live/device edge deferred (P5)

---

## The gap

We have a complete gateway *client* and no gateway. `OpenClawEventClient` handshakes, signs a device
identity into a challenge nonce, parses `heartbeat`/`cron` events, and services inbound remote-invoke
frames. `OpenClawBridge` dispatches work over `sessions.send`. Both are tested. Neither has ever
completed a round trip against a server we control, and the consequence is spread across the index:

- **AR** — "Deferred: live approval round-trip (backend-pending)"
- **BH** — "Deferred: live gateway round-trip (backend-pending)"
- **V** — live SSE handshake, still waiting on something to handshake with
- **N** — "Deferred: live event stream, live endpoint verification of the preset contracts"
- **CN P3** — "does a real gateway ignore or 400 on the unknown `image_base64` param?" is the stated
  reason that feature ships with its setting off

Five plans blocked on the same missing artefact. It is cheaper to build the artefact once than to keep
deferring against it, and the deferral is now load-bearing: CN's default-off setting is justified by an
unknown that a backend we own would answer in an afternoon.

The second half of the gap is that a *cloud* action agent is a different product from the LAN gateway
we assume today. `Config.openClawLanHost` defaults to `http://macbook.local`. That model requires the
user to run a machine, and it dies the moment they leave the house — which is exactly when
glasses-first assistance is worth the most. A hosted action agent with its own persistent memory,
its own credential vault, and its own connected apps is the shape that survives walking out the door.

## Why a managed-agents backend rather than another LLM proxy

The provider now exposes a first-class agent surface — environments, agents, sessions, memory stores,
credential vaults, MCP toolsets — which moves four things we would otherwise build and operate:

| We would have to build | The surface provides |
|---|---|
| Durable per-user conversation history | a long-lived session; only the newest turn is sent |
| A memory store with read/write instructions | a mounted memory resource, addressed by the agent directly |
| OAuth token storage + refresh for every connected app | a vault holding `mcp_oauth` credentials, refreshed provider-side, injected as bearer |
| A sandbox for agent-run code/tooling | a cloud environment with a declared networking policy |

That collapses the backend to roughly: provision idempotently, run one turn, push the result. Small
enough to own; large enough to unblock five plans.

## Non-goals

- **Replacing the LAN/self-hosted gateway.** This is a *second* gateway kind alongside the existing
  one, selected per `GatewayConfig`. Users running their own stay on it, unchanged.
- **Routing realtime audio through a server worker.** A server-mediated voice path buys server-side
  echo cancellation and playback-position-aware interruption — both of which we already solved
  on-device (Plans AO, CO) — and pays for them in a permanent added hop on every utterance plus a
  second service to operate. Direct-connected Gemini Live / OpenAI Realtime stay as they are. Named
  here because the pattern is attractive and the trade is against us.
- **A hosted multi-tenant service.** Single-tenant, self-deployed, one token per user. Multi-tenancy
  is a business decision, not a technical one, and it drags in billing, abuse and support.
- **Moving the on-device model.** The fast conversational brain stays on the phone; this backend is
  the slow, tool-holding, memory-holding half that `delegateTask` already assumes exists.

---

## P1 — Pure cores (headless, no wiring)

### `GatewayTaskTransport`

`delegateTask` hard-codes one wire: a WebSocket RPC `sessions.send` with `agentId`/`sessionKey`/`text`
([`OpenClawBridge.swift:736`](../../OpenGlasses/Sources/Services/OpenClawBridge.swift)). A cloud
backend of this shape is far more naturally an HTTP request-response — the socket is then only ever a
push channel, which is what our event client already treats it as.

So: a protocol with one method, `dispatch(task:image:) async -> DispatchOutcome`, and two
implementations — the existing RPC one (extracted, behaviour unchanged, covered by its current tests)
and an HTTP one. `DispatchOutcome` is the point of the exercise:

```
.answered(String)          // the result came back inline
.acknowledged(ack: String, correlation: DispatchID)   // a result will arrive later
.failed(reason:)
```

Today those first two collapse into `.success(String)` and the caller cannot tell an answer from a
receipt. That conflation is the root of the defect below.

### `DeferredTaskLedger`

**The sharpest app-side defect, and it exists already.** When `delegateTask` returns `"Task dispatched
(runId: …)"`, the real answer arrives later as a `heartbeat` preview on the socket — and
[`OpenGlassesApp.swift:1379`](../../OpenGlasses/Sources/App/OpenGlassesApp.swift) hands every inbound
notification to `triageOpenClawNotification`, an LLM pass built for *unsolicited* content. The answer
to a question the user asked forty seconds ago is therefore judged on whether it is worth interrupting
them, and announced as news if it survives. Nothing correlates it back to the question.

`DeferredTaskLedger` is a pure, clock-injected store: `record(DispatchID, prompt, at:)`,
`match(incoming:) -> .answerTo(DispatchID) | .unsolicited`, `expire(now:)`. Rules, each with a reason:

| Rule | Behaviour |
|---|---|
| One dispatch outstanding | next inbound result is its answer — no matching heuristics needed for the common case |
| Several outstanding | match on the correlation id the transport carried; unmatched ⇒ `.unsolicited` |
| Older than `maxWait` (default 5 min) | expired — and expiry is **surfaced**, not silent: the user asked a question and is owed "that didn't come back", not silence |
| Matched | routes as an answer (spoken in the assistant's voice, in the conversation) — **bypasses triage entirely** |

Bounded, persisted (a dispatch must survive a backgrounding), and never unbounded-growing.

### `SpawnAckPolicy`

With a cloud agent, most tasks exceed a conversational beat, so nearly every dispatch returns an
acknowledgement rather than an answer. Two things about that acknowledgement are non-obvious and both
are one-line-to-get-wrong:

1. **The ack must be an instruction to the model, not a line to read out.** A fixed string
   ("I'm still working on that") reaches TTS verbatim and sounds like a status message from a machine.
   Handing the model *"acknowledge briefly and naturally in your own words, one short sentence, no
   promises about timing"* produces cover that fits the conversation already in progress.
2. **It must forbid answering from memory.** Without an explicit clause, a model told a calendar
   lookup is running will cheerfully invent the calendar rather than wait for it. This is the same
   failure class as Plan BK P6 (feature-claim honesty) and deserves the same intolerance.

Pure: composes the instruction, and a test asserts the ack text is routed as a tool result and never
reaches the TTS path directly.

---

## P2 — App wiring

- `GatewayKind` on `GatewayConfig` (`.rpc` / `.cloud`), settable in Gateway settings; the bridge picks
  its transport from it. Existing configs decode as `.rpc` — no migration, no behaviour change.
- `delegateTask` returns the richer outcome; `.acknowledged` records to the ledger.
- The `onNotification` handler consults the ledger *before* triage. Unmatched notifications keep the
  existing triage path exactly as it is.
- Expiry surfaces through the existing `AgentNotificationQueue`, so a task that dies while the glasses
  are off still reaches the user on reconnect, with the same staleness rules as everything else.
- Settings: cloud endpoint + token (Keychain, via the existing `openClawGatewayToken` storage),
  reachability probe, and the ledger's outstanding count as a visible "in flight" line.

Gates, non-negotiable: the whole path stays behind `Config.agentModeEnabled` per
[`agentic_toggle`](../../CLAUDE.md) and BK P0, and HIPAA mode hard-disables it — this ships user
prompts, and under CN camera frames, to a hosted agent with a *persistent memory store*. That is a
wider egress than any gateway we have shipped, and the memory store makes it durable.

---

## P3 — Reference backend (`docs/gateway/`)

Following the Plans L/M precedent, where the signaling relay and expert client shipped as reference
implementations under `docs/webrtc/` rather than pretending to be app code. A small service that:

- serves the client's existing handshake — `connect.challenge` on open, accepts
  `{type:"req", method:"connect", params.auth.token}`, pushes `heartbeat` (`status`, `preview`,
  `silent`) and `cron` (`action`, `summary`) in the shapes
  [`OpenClawEventClient.swift:267`](../../OpenGlasses/Sources/Services/OpenClawEventClient.swift)
  already parses;
- provisions idempotently: one shared environment + agent, per-user memory store, vault and session,
  IDs persisted in a file (a JSON file is the right size until the user count says otherwise);
- runs one turn against the session and pushes the result.

**The traps, written down because every one of them is silent.** These are the difference between a
weekend and a fortnight:

| Trap | Consequence if missed |
|---|---|
| Open the event stream **before** sending the turn | events emitted pre-open are not replayed; the first turn hangs |
| A session parked on an unanswered tool confirmation rejects every subsequent user message | one interrupted turn (client hang-up, service restart) wedges that user **permanently**; needs a scan of the recent event tail and an explicit resolve on startup |
| Drift detection must compare only the fields we manage | the server normalizes stored tool configs and returns shapes you never sent, so a whole-shape comparison is unequal on every request — an agent update plus a session update before every single turn, forever |
| Model/effort config is read **only at agent-create time** | changing it later appears to work and silently does nothing; any latency measurement taken afterwards is measuring the old setting |
| A live session keeps the tool slate it was created with | an app connected today is invisible to a session created yesterday unless the session is updated too |
| A system-message rides only *trailing* a user message | side-channel context (a voice-session summary, what the wearer is looking at) must be queued and attached to the next turn, not sent standalone |
| Streaming deltas are best-effort prefixes | the buffered message is authoritative; emit the remainder on arrival or the tail of long answers is dropped |

Deployment is out of scope for the plan; the artefact is the service plus a README that states the
required environment and the one-command run.

---

## P4 — Connected apps (OAuth → vault)

Once a vault exists, connecting a third-party app is one entry in a registry plus a redirect. Worth
doing here rather than in Plan V, because V's OAuth device-code flow was explicitly deprioritized and
this is the cheaper shape: the provider owns refresh, so the app never holds a third-party token.

App-side surface: an `/apps` list (id, display name, connected, available), an in-app auth sheet, and a
custom-scheme bounce-back so the sheet closes itself instead of stranding a web page. Four server-side
details that are each a day lost if discovered late:

- **Granted scopes can be narrower than requested** — a user may decline individual permissions, and
  the failure surfaces much later as an opaque "the caller does not have permission". Log granted vs.
  requested at exchange time; that log is the whole diagnosis.
- **The health check must be a real tool call.** `initialize` and a tool listing succeed against
  servers that then refuse every data call. Probing with anything less means telling the user they are
  connected when they are not.
- **Refresh tokens are not free** — a provider that is not explicitly asked for offline access with a
  forced consent prompt returns none, and the credential dies at the first expiry, silently.
- **One credential per server URL** — replace, don't accumulate.

Read-only apps first. A destructive tool must not auto-approve its confirmation; it routes to the
shipped consent surface (Plan N P4 / BH) as a spoken confirmation.

---

## P5 — Deferred (live/device)

- End-to-end round trip on device: dispatch → ack → late answer → spoken in the assistant's voice.
- The answer AR/BH/V/N/CN P3 are each waiting for, recorded back into those plans.
- **Specifically, CN's open question**: does a real gateway ignore or 400 on an unknown
  `image_base64` parameter? Answering it is the gate on CN's setting shipping non-default-off.
- Latency profile: how often a task actually finishes within a conversational beat, which is the only
  evidence that would justify keeping an inline-answer path at all.

---

## Open questions

- **Is the managed-agents surface stable enough to depend on?** It is a beta API. Pin the SDK exactly
  (CD P3 precedent) and expect shape drift; the reference service should fail loudly on an unexpected
  event type rather than dropping it.
- **Does the cloud kind deprecate `sessions.send`, or coexist forever?** Leaning coexist — the LAN
  gateway is a real deployment for users who want nothing hosted, and it is already built.
- **Where does the on-device memory line (Plans AX/AY, `BrainStore`) meet a server-side memory store?**
  Two memories that disagree is worse than one that is thin. The likely answer is that the server
  memory is scoped to what the *action agent* needs (connected-app context, ongoing task threads) and
  the device stays authoritative for the wearer's own recall — but that boundary needs stating before
  P3, not after.
- **Should the ledger's expiry be user-visible as a failure or quietly retried?** Leaning visible: a
  silent retry is how "it just didn't do it" becomes unreportable.
