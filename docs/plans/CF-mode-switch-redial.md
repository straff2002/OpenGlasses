# Plan CF — Mode-Switch Auto-Redial (switching brains shouldn't hang up)

**Status: ✅ P1 shipped (2026-08-01)** — `ModeSwitchPolicy` (pure: the switch sequence as data;
`.startSession` appended exactly when `wasSessionActive && target.isRealtime && autoRedial`;
ordering invariants tested) + `switchMode` executes the action list, capturing
`wasSessionActive` from the outgoing manager before teardown. Redial errors surface via the
managers' published `connectionState`/`errorMessage` exactly as a manual connect (verified: the
automatic path awaits `startSession()` and adds nothing that could swallow them). Success
haptic on ready. CE interplay resolved "yes": a redial keeps a held frame pin and re-pushes it
into the new session (sharp-inject + heartbeat credit); only a non-redialing switch releases.
Kill switch `modeSwitchAutoRedialEnabled` (default on). Spoken-cue decision + settle-delay
tuning remain **P2 (device-pending)**.

Make switching between live modes mid-call **hang up and redial automatically** instead of
going silently dead. Picking a different brain is a user intent about *who they're talking to*,
not a request to stop talking — the app should honor the intent end-to-end.

## Today's behavior (verified against `switchMode(to:)`)

`AppState.switchMode(to:)` (`OpenGlassesApp.swift`) tears down the old mode — `stopSession()`
on the live session managers, background-voice end, camera teardown — waits 500 ms for the
audio session to release, then starts the *substrate* for the new mode: wake-word listening for
Direct, `backgroundVoice` + `cameraService.startStreaming()` for the realtime modes. **It never
starts the new realtime session.** Switching Gemini Live → OpenAI Realtime (or either direction)
mid-conversation therefore ends the call and leaves the app idle with a live camera preview and
a dead session, until the user notices and manually reconnects. Mislabeled-but-alive is bad;
silently-idle is worse.

Context does not survive the swap — that is inherent to changing brains, not a defect of the
redial. What we owe the user is a fast, automatic reconnect and an honest signal about what
carried over (nothing) — not an error state dressed up as a mode switch.

## Pure core (the testable half)

- **`ModeSwitchPolicy`** (pure): given `(oldMode, newMode, wasSessionActive, autoRedial)`
  returns an ordered action list — e.g. `[.teardown(oldMode), .settleDelay, .startSubstrate(newMode),
  .startSession(newMode)]` — with `.startSession` appearing **only** when a live session was
  active at switch time (`isActive` on the outgoing session manager) and the target is a
  realtime mode. Switching *from* Direct never fabricates a call that didn't exist; switching
  *to* Direct is already handled by wake-word restart. Encoding the sequence as data makes the
  one interesting rule (`wasSessionActive` propagation) unit-testable without any audio stack.
- **Failure surface:** if the redial's `startSession()` lands in `.error`, that error must reach
  the UI/TTS exactly as a manual failed connect would — the automatic path may not swallow it.

## Wiring (thin)

- `switchMode(to:)` captures `wasSessionActive` from the outgoing manager **before** teardown,
  runs the policy, and executes the actions — the only new step is awaiting
  `geminiLiveSession.startSession()` / `openAIRealtimeSession.startSession()` at the end.
- **Feedback during the gap:** the ~3 s of teardown + settle + reconnect gets the existing
  connecting affordances (status pill + spinner), plus a success haptic when the new session
  reaches ready — the same `UINotificationFeedbackGenerator` grammar used elsewhere. A short
  spoken cue ("Switching to OpenAI") is optional and settings-gated; silence-then-new-voice may
  be the better UX. Decide in P2.
- **Persistence:** a redial starts a fresh `ConversationStore` thread (mode changed → thread
  breaks there anyway), keeping history honest about the context reset.
- **Plan CE interplay:** if a frame pin is held across the swap, re-push the pinned frame into
  the new session on connect (see CE's open question — resolved "yes" here).

## Phases

- **P1 — policy + wiring:** `ModeSwitchPolicy` + tests; `switchMode` executes it; error
  pass-through verified in tests via the managers' published `connectionState`.
- **P2 — feel (device-pending):** on-device timing of the settle delay (can the 500 ms shrink
  when no session was active?), the spoken-cue decision, and confirming the audio session
  survives back-to-back teardown/redial on real hardware.

## Non-goals

- Carrying conversation context across providers (a transcript-replay bridge is a different,
  bigger plan; do not smuggle it in here).
- Any change to Direct-mode switching, which already restarts its listener correctly.
