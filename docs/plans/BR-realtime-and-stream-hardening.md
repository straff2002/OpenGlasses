# Plan BR — Realtime Session & Camera Stream Hardening

**Status: 🚧 Implemented (PR [#236](https://github.com/straff2002/OpenGlasses/pull/236), 2026-07-15); on-device smoke owed.** Four
verified gaps (P4 added after a gateway-hygiene review), each with a deterministic core;
one PR. Sourced from a systematic review of community work on comparable glasses apps
(techniques adopted on their own merits) — everything below was checked against this
codebase first; the many techniques we already have (context-window compression,
background HEVC decode, audio-only mode, `voiceChat` AEC, gateway-gated tool advertising)
are *not* re-listed.

## P1 — Live-session tool-call circuit breaker

**Gap (code-verified):** the Gemini Live path doesn't bound tool calling. A model looping
the same failing tool — or ping-ponging between tools — burns battery and quota
mid-session with no exit. `SafetySupervisor` (Plan S) governs *planned agent runs*, not
the realtime path. **As-built discovery:** `OpenAIRealtime/` has *no tool calling at all*
(no `tools` in `session.update`; function-call events fall through to `default:`) — so
there is nothing to bound there; if tools are ever added, the breaker is ready to reuse.

- Pure `ToolCallBreaker` (as-built): per-session windows for (a) consecutive calls with no
  intervening user turn (default 12), (b) repeated identical tool+args failures (default
  3, SHA-fingerprinted args). On trip → the tool is suspended for the session and the
  refusal/notice rides back **in-band as the tool result**, instructing the model to tell
  the user and stop — no side-channel TTS fighting the live audio (deliberate deviation
  from the drafted BK-P2c narration).
- Wired in `ToolCallRouter` (admit-before-dispatch + outcome recording), user-turn reset
  via `onInputTranscription`, and suspended tools filtered out of re-declared tool lists
  on reconnect.
- Tests: threshold trips, user-turn reset, identical-failure streaks (per-args, cleared by
  success), args-key stability, suspension persistence.

## P2 — Camera stream resilience + compatibility surfacing

**Gap:** a stream failure can silently wedge the session, and an outdated Meta AI app /
glasses firmware presents as a mystery connection failure.

- As-built: stall recovery (the existing trigger) is now **tiered** — `teardownStreamOnly()`
  rebuilds the `Stream` on the retained `DeviceSession` first (DAT 0.8 has no
  `removeStream`; rebuild = stop + `addStream(config:)`), escalating to a full session
  reset only after two consecutive failed recoveries (`StreamRecoveryPolicy`); a failed
  stream-tier attempt immediately resets the session so the next pass starts clean. The
  Stream `errorPublisher` handling is deliberately unchanged (capture fast-fail only) —
  recovery stays stall-driven, avoiding churn on benign errors.
- Compatibility (verified against the 0.8 `.swiftinterface`): update-required signals live
  in **MWDATCore**, not the camera stream — `DeviceSessionError
  .datAppOnTheGlassesUpdateRequired` (thrown by `start()` and emitted on
  `DeviceSession.errorStream()`, both now observed) and `Compatibility
  .deviceUpdateRequired/.sdkUpdateRequired`. `DATCompatibilityMessage` maps them to
  actionable copy, published as `CameraService.compatibilityNotice` and announced once via
  the AppState TTS sink (voice-first; the phone may be pocketed).
- Tests: tiering table, compatibility message mapping (update-required vs thermal vs
  compatible).
- Follow-up (2026-09-06): the `.stopped` row of the state table was still terminal, so a
  wanted stream that dropped mid-session cleared `isStreaming` — which disarms the stall
  detector, the only thing left that would have rebuilt it — and the preview stayed dead
  until a manual restart; `stoppedWhileWanted` now drives a bounded reconnect ladder
  (`StreamRecoveryPolicy.reconnectDelay`, ~90 s) over the same tiered recovery, and the
  preview placeholder gains a delayed cold-start hint naming folded hinges and doffed
  glasses.

## P3 — Realtime WebSocket connection-generation guard

**Gap (code-verified):** `GeminiLiveService` overwrites its shared delegate's
`onClose`/`onError` closures on every `connect()`. A cancelled task's late terminal
callback therefore fires against the *new* connection — spurious failure/reconnect on
top of a healthy socket. Plan BD's `reconnectPending` coalescing narrows but does not
close this.

- As-built: pure `ConnectionGenerationGate`; `connect()` advances and captures a
  generation, every callback (open/close/error, connect-timeout, receive-loop failure)
  no-ops if superseded, and `disconnect()` advances so post-teardown stragglers are stale
  by construction. Applied identically to `GeminiLiveService` and
  `OpenAIRealtimeService`.
- Tests: gate supersession semantics (the callback wiring is mechanical capture of the
  gate — exercised by the full-suite session tests).

## P4 — Gateway session hygiene (added 2026-07-15)

**Gap (code-verified):** our gateway sessions carried timestamp-suffixed keys
(`agent:main:glass:<ISO8601>`) regenerated on every Live session start — the gateway
accumulates one dead session per conversation and its agent starts amnesiac each time —
and no channel classification header, so sessions appear as generic webchat in
`sessions_list`.

- As-built: stable `agent:main:glass` key by default; `resetSession()` is now a
  *deliberate* act (persisted monotonic generation → `agent:main:glass:<n>`), no longer
  called automatically per Live session. `x-openclaw-message-channel: glass` sent on both
  gateway sockets (bridge + event client). Behaviour change, documented: the gateway-side
  agent now retains context across Live sessions (Agent-Mode-gated surface).
- Tests: default-key stability across bridge instances, explicit rotation + persistence,
  channel constant.

## Rider — Live-model migration checklist (documentation only)

Community migrations to the newer Gemini Live models (`3.1-flash-live-preview`) hit a
consistent minefield; recorded here for when we bump models:
- Empty `inputAudioTranscription` / `automaticActivityDetection.disabled` in setup →
  server closes 1011.
- `TEXT` response modality rejected on 3.x Live (AUDIO + `outputAudioTranscription`
  instead — we already use audio, but the classifier/quick paths should be checked).
- Oversized setup/turn payloads → close 1007; truncate context injected into setup.
- On connect failure, fetch and log the key's Live-capable model list — turns "1011, no
  reason" into "your key lacks access to X".
- Endpoint remains v1beta (we're already there).

## Explicitly evaluated and skipped
- Mic-mute-during-AI-speech speaker mode — incompatible with barge-in by design.
- Glasses long-press assistant activation — Android-only package-squat of another app's
  bundle id; unshippable, fragile. (Noted for Plan BA as a community signal that the
  long-press surface is in demand.)
- Indefinite unbounded WS reconnect — our BD policy (bounded, backoff, presence-aware) is
  strictly better.
- Face-recognition thumbnails, phone-camera tap-to-focus/pinch-zoom — real but cosmetic;
  candidates for a UX-polish pass, not this plan.

## Verification
Headless: breaker/policy/generation tests + full suite + Release green. Device: one
glasses session covering a forced stream failure (walk out of BT range mid-stream),
a live-session tool failure loop (misconfigured tool), and a reconnect under network flap.
