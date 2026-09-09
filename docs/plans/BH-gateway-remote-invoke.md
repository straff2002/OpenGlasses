# Plan BH — Gateway Remote Invoke (agent-initiated glasses control)

**Status:** 🚧 Core shipped — pure `RemoteCommandParser` (alias table, total: command / unsupported /
malformed) + `RemoteCommandPolicy` (deny-by-default on `agentModeEnabled`, per-class consent
toggles with capture OFF, `halt` class for stops, token-bucket rate limits) + `RemoteInvokeReply`
envelope + `RemoteCommandExecutor` (closure seams onto the live services; capture = confirm →
announce → act via `ToolConfirmationCoordinator`) + `RemoteInvokeService` (pipeline + persisted
audit ring) wired into `OpenClawEventClient` (`type:"req"` frames answered on the existing
socket). Settings: per-class toggles + activity log in Gateway settings. Hardening riders:
reconnect jitter, `LLMImagePreparer.isDegenerate` frame guard, `SecretInputField` (paste + reveal)
swapped into 12 token/key forms. Token-in-URL hygiene was already fixed (handshake auth +
`LogRedaction`). Follow-up shipped: signed Ed25519 device identity on both gateway handshakes (`OpenClawDeviceIdentity` + shared `OpenClawConnectParams`, protocol v3/v4 — remote gateways can zero-scope token-only connects), capability advertisement at connect time, and `device.event` push (connection + glasses attach/detach, observe-consent-gated). Deferred: live end-to-end against a real gateway (device/backend-pending).

## The problem
The gateway link is one-directional in practice: the phone initiates every exchange
(transcription → chat → response). An agent living on the gateway cannot initiate anything on the
glasses — it can answer "what do you see?" only if the phone happened to attach a frame, and it
cannot ask the glasses to take a photo, start a recording, push text to the HUD, or speak. This
caps the agent at "voice chatbot" when the natural product is a bidirectional terminal: the same
agent a user talks to elsewhere (desktop, chat clients) should be able to reach back to the
glasses it is paired with.

Concretely missing:
1. **No inbound RPC.** `OpenClawEventClient` sends `connect`/`send` requests and consumes chat
   events; unsolicited server→client method calls are not recognized, so there is no way for the
   gateway to invoke device actions.
2. **No command surface.** Even if a frame arrived, nothing maps "capture_photo" to
   `CameraService`, "speak" to TTS, or "show_text" to the HUD.
3. **No capability discovery.** The gateway can't ask what this device can currently do (glasses
   connected? display present? recording available?), so server-side agents must guess.
4. **No policy layer.** Remote actuation is the single highest-impact surface in the app — a
   prompt-injected or compromised gateway agent asking the glasses to record is a wiretap. This
   must be deny-by-default and auditable, not bolted on. The threat is not only a bad agent at the
   far end: in LAN mode the socket is cleartext `ws://`, so an on-path attacker on the same network
   can inject frames. That pre-auth injection window is now closed by the handshake gate below —
   inbound `req` frames and spoken `heartbeat`/`cron` events are dropped until the connect
   handshake completes. Hardening the transport itself (so a *post*-auth on-path attacker cannot
   read or tamper with the stream) is Plan DO's, not this plan's.

## What we build

### The deterministic core (headless-testable, no sockets)
`Sources/Services/OpenClaw/RemoteInvoke/`:

- **`RemoteCommandParser`** (pure): JSON-RPC-ish frame (`method`, `id`, `params`) → typed
  `RemoteGlassesCommand`. Data-driven alias table (multiple verbs per command, locale-alias
  friendly) mapping onto one canonical enum:
  `capturePhoto`, `startAudioRecording` / `stopAudioRecording`, `startVideo` / `stopVideo`,
  `startTranslation(source, target)` / `stopTranslation`, `startTranscription` /
  `stopTranscription`, `speak(text)`, `displayShow(text, icon)` / `displayClear`,
  `deviceStatus`, `deviceCapabilities`, `addNote(text)`, `getTranscript`, `stopAll`.
  Unknown method/action → typed `.unsupported(action)` — never a crash, never silence.
- **`RemoteCommandPolicy`** (pure): decides `allow / deny(reason)` from
  (command class, `Config.agentModeEnabled`, per-class user toggles, rate state).
  - Everything is **deny-by-default when Agent Mode is off** (house rule: all
    gateway/autonomous features gate on `agentModeEnabled`).
  - Command classes: *observe* (status, capabilities, transcript), *output* (speak, display),
    *capture* (photo, video, audio recording, transcription, translation). Capture is its own
    consent toggle and routes through the Plan BC `HighImpactToolPolicy` gate when that lands
    (BH does not block on BC — until then capture defaults OFF).
  - Simple token-bucket rate limit per class; over-limit → `deny(.rateLimited)`.
- **`RemoteInvokeReply`** (pure): success/deny/unsupported/error → response envelope with the
  request `id`. The parser + policy + reply trio is a total function: every inbound frame yields
  exactly one well-formed reply. Table-driven tests over the frame × config matrix (the
  ReconnectMachine/AudioRoutePolicy test pattern).

This is deliberately the same command taxonomy as the BG P2 `VoiceCommandParser`: two front
doors (wake-word voice, gateway RPC), one set of device verbs. Where the taxonomies overlap the
enums should converge rather than duplicate.

### Wiring (thin edge)
- `OpenClawEventClient`: recognize unsolicited request frames on the existing socket, hand them
  to the parser/policy on a `@MainActor` executor, send the reply. Requires the event socket to
  be *held open* while Agent Mode is on (it already reconnects for events; remote invoke just
  raises the stakes of that persistence).
- **`RemoteCommandExecutor`**: maps each allowed command onto the existing services —
  `CameraService` (photo/video), audio recording, `AmbientCaptionService` (transcription),
  live translation, `TextToSpeechService` (speak), the HUD display path (`displayShow`/`clear`),
  battery/connection status, notes. `deviceCapabilities` reports what is *currently* true
  (glasses connected, display supported, recording available), not what the app theoretically has.

### Non-negotiable safety properties
- **Nothing remote is ever silent.** Every remote-initiated *capture* command announces itself
  (TTS or tone) before acting; every remote command of any class is logged to an inspectable
  audit trail (reuse the existing tool-call log surface).
- Agent Mode off ⇒ every command is policy-denied before the executor is consulted. (Corrected
  2026-07-10: the shipped behavior — the right one — keeps the socket up and returns structured
  denials with Agent Mode off (`RemoteInvokeService.swift:73-83`); the executor is never
  *consulted*, but the parse+policy pipeline is reachable and replying. The earlier "executor is
  unreachable" wording overstated it.)
- Per-class toggles live in the gateway settings UI with capture OFF by default.
- Deny replies carry structured reasons so the server-side agent can explain itself instead of
  retrying.

### Risks flagged by the 2026-07-10 review (fold into the live-edge PR)
- **Pre-auth frames were processed — fixed 2026-09-09 ([#444](https://github.com/straff2002/OpenGlasses/pull/444)).** `handleRequestFrame` used to
  handle any `type:"req"` frame with no check that the connect handshake completed. Combined with
  cleartext `ws://` in LAN mode, an on-path LAN attacker could inject frames — with Agent Mode on
  and default toggles (`observe`/`output` ON), that meant silent transcript reads and arbitrary
  speech. `OpenClawEventClient` now gates inbound frames on the handshake: a `req` arriving before
  the connect `res` is dropped with **no reply of any kind** (a reply would confirm a listening
  client to the attacker) and the remote-invoke handler is never reached, and `heartbeat`/`cron`
  events — which are spoken to the wearer — are dropped the same way. Both drops are recorded as
  `requestDroppedPreAuth` / `eventDroppedPreAuth`, carrying nothing from the attacker-controlled
  frame. `establishConnection` clears the authenticated flag before every new socket, so a
  reconnect cannot inherit the previous socket's handshake. `connect.challenge` and `res` frames
  stay ungated — they *are* the handshake — and `device.paired` stays ungated because pairing
  depends on it arriving pre-auth (narrowing it to the bootstrap window is Plan AR's item).
  Covered by `OpenClawEventClientScriptedSocketTests`
  (`testRequestBeforeHelloOkIsDroppedWithoutReply`, `testHeartbeatBeforeHelloOkIsNotSpoken`). The
  ws:// LAN caveat is now stated in the threat model above.
- **`getTranscript` is misclassed.** It's *observe* (default ON) yet returns the last 20 ambient
  captions (`OpenGlassesApp.swift:3017-3022`) silently — recorded conversation content is
  capture-adjacent by this doc's own wiretap framing. Give it its own toggle or promote it to
  the capture class.
- **`speak` lacks source attribution.** The executor speaks remote text verbatim
  (`RemoteCommandExecutor.swift:99-101`) — indistinguishable from the local assistant. Align
  with BL P2 / BK P2c narration ("Message from the gateway: …").
- **Scope statement:** deny-by-default covers `type:"req"` frames only; inbound *event* text
  (`heartbeat`/`cron` → `onNotification` → TTS/LLM, `OpenClawEventClient.swift:271-346`) is
  unscreened. BK P0 gates the delegate loop; the event *text* deserves BL P2's hygiene
  treatment (length cap, sanitization, `PromptInjectionPolicy` wrap).

### Shared consent seam (Plan BL P4) — pre-BL refactor
BL P4 routes MCP-peer See/Act/Agent calls through this plan's `RemoteCommandPolicy`/
`RemoteCommandExecutor`, but the shipped seam is **peer-blind**: `decide(command:…)` takes no
origin (`RemoteCommandPolicy.swift:99-105`), `RemoteInvokeAuditEntry` records only
action+disposition, and rate state is one shared bucket set — a chatty MCP peer would starve the
gateway's budget, and BL P4's "every call attributed to the peer's API key" is unimplementable.
Small refactor before BL P4: thread an `origin` through `decide()` and the audit entry, and key
rate state per origin. (Peer identity for inbound MCP callers is BL P4; the gateway-socket
identity is Plan AR.) **This refactor shipped as Plan BN P2** (2026-07-12), the day after this
section was written; the shared confirm surface it pairs with, BN P1, shipped the same day
([#205](https://github.com/straff2002/OpenGlasses/pull/205)).

### Same-theme hardening (fold into this PR — small, adjacent)
- **Token hygiene:** the gateway token is interpolated into the WS URL
  (`OpenClawEventClient.swift:126`) — ensure no log line ever prints the URL/token
  (redact helper). Remote invoke makes the socket long-lived, so every reconnect re-presents
  the token; redaction must cover the reconnect path too.
- **Reconnect-loop polish:** the client already does exponential backoff (2 s → 30 s cap,
  reset on success) but retries forever at a fixed cadence — add jitter, and consider a
  give-up-after-N with user-visible state once the socket is load-bearing for inbound commands
  (a permanently-flapping socket should surface, not spin silently).
- **Degenerate-frame guard:** `LLMImagePreparer` accepts any `CGImage`; frames below a sane
  minimum edge (e.g. < 32 px — the 1×1 placeholder failure mode) should be rejected before they
  are base64'd into a conversation and poison context. Guard + unit test.
- **Paste-friendly secret entry:** the plain `SecureField`s used for API keys/tokens fight
  iOS paste; a small shared field component (secure + paste button + reveal toggle) swapped into
  the settings forms that take long random strings.

### Assessed and already handled / not applicable (no action)
- *Internal-port probing on HTTPS hosts:* gateway reachability here already uses `/health` on
  the configured base URL only (`OpenClawBridge.swift:216-248`) — no internal-port probe exists.
- *Unbounded chat-turn loop:* no client-side turn loop exists in the bridge to bound.
- *Endpoint URL validation/guard utility:* endpoint resolution (LAN/tunnel/auto with fallback)
  already lives in the bridge; no separate validator needed for this plan.

## Out of scope (separate candidates, not this plan)
- Additional LLM provider cases (e.g. xAI) — provider plumbing, independent of the gateway.
- OAuth-based provider login in `ModelFormView` — bigger, own plan if wanted.
- Locale packs / non-English wake phrases — the alias table is built to accept them later.
- Any server-side gateway work — BH is client-side; the contract is "respond correctly to
  `node.invoke`-style frames," testable headlessly with recorded frames.

## Test plan
- Parser/policy/reply matrix tests (pure, no sockets, no `Wearables`).
- Executor tested behind protocol seams with fresh instances (never `.shared` — house rule).
- Edge: one integration test feeding canned frames through a fake socket into the client.

## Sequencing
After BG P2 (shares the command taxonomy). Before BC lands, capture class stays default-off;
when BC lands, capture routes through `HighImpactToolPolicy` like any direct-actuation tool.
