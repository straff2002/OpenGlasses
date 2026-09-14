# Plan BV — Power Policy

**Status: 🚧 P1 + P2 core shipped (2026-07-18); device tuning + remaining consumers deferred.**
P1 pure fusion + table: `ThermalPressure`, `PowerState` (four optional signals + Low Power
Mode), `PowerPosture` (normal/conserve/reserve + shared consumer-flag contract), `PowerPolicy`
(worst-signal-wins, battery **hysteresis** with differing enter/exit bands, one-line
`explanation`), `Config.powerThresholds`. P2 wiring: `PowerPolicyService.shared` (mirrors
`PresenceMonitor` — injected signal seams, holds `previous` for hysteresis, publishes
`posture`+`explanation`), the DAT `ThermalLevel → ThermalPressure` mapping, AppState wiring of
the real phone signals (battery/thermals/Low Power Mode) + glasses battery, and two consumers:
live-mode `FrameThrottler` interval stretch (Gemini Live + OpenAI Realtime) and `device_info`
posture surfacing. 30 tests (`PowerPolicyTests` + `PowerPolicyServiceTests`).

**Deferred:** glasses thermal (needs the DAT `deviceStateStream` observed — device-pending),
the deeper consumers (camera snapshot-first escalation + idle stream teardown, smaller
local-model tier, reading-companion checkpoint), and the device drain/hot-day pass to tune
thresholds.

A battery- and thermal-aware power policy for all-day
wear, built on one principle: **use the lowest-power combination of sensing, compute and
networking capable of completing the request.** Today the app has no systematic power
posture — `batteryLevel` is display-only, the only low-power-mode read is a tool string,
and presence throttling (Plan W) is the sole load-shedder. Presence decides *whether* a
loop should work; this plan decides *how expensively* — the two compose, deliberately.

OpenGlasses can do this better than a phone-only app: the DAT SDK exposes **glasses-side
thermal state** (`deviceStateStream` → `ThermalLevel`), so the policy fuses four signals —
phone battery (`UIDevice`), phone thermals (`ProcessInfo.thermalState`), glasses battery
(`GlassesConnectionService.batteryLevel`), glasses thermals (DAT) — plus iOS Low Power
Mode.

## P1 / PR1 — Policy core (pure, headless)

- `PowerState` (pure fusion): the four signals + low-power flag → one struct; each input
  optional (glasses absent, battery unknown) with honest defaults.
- `PowerPolicy` (pure table): `PowerState → PowerPosture` where posture ∈
  `normal / conserve / reserve`, mirroring Plan W's `ThrottleDecision` shape:
  - **normal** — no constraint;
  - **conserve** (battery below threshold on either device, or elevated thermals) —
    snapshot-before-stream, longer idle teardowns, frame-rate floors raised, prefer the
    smaller local model tier;
  - **reserve** (critical battery or serious thermals) — voice-first: camera only on
    explicit request, no continuous streams without confirmation, heartbeats stretched.
- Thresholds in `Config` (UserDefaults-backed, code-only knobs — the `frameDedup*`
  posture), not hard-coded.
- Tests: fusion with missing inputs, table boundaries, hysteresis (a posture must not
  flap when a signal hovers at a threshold — enter/exit bands differ).

## P2 / PR2 — Adoption by the spenders

Consumers read one API (`PowerPolicyService.shared.posture` + a change publisher), each
applying it in its own terms — the service never reaches into features:

- **Camera**: snapshot-first escalation (a visual request tries `latestFrame`/photo
  before starting a stream); idle stream teardown when nothing consumed frames recently
  (the keep-streaming consumer set already exists from the Plan BT P2.1 work).
- **Live modes** (Gemini Live / OpenAI Realtime / BU offline): frame interval raised
  under `conserve`; session-start confirmation under `reserve`.
- **Local models**: prefer the smaller tier under thermal pressure; defer opportunistic
  work (embedding refresh, study-deck generation timing).
- **Reading companion**: checkpoint interval widened; `conserve` noted in status line.
- Surfaces a one-line posture explanation for status/tool queries ("conserving — glasses
  battery 18%").

## Explicitly out of scope
- Named user-facing profiles (All-Day / Performance) — posture is automatic; profiles can
  follow once the primitives exist.
- Killing user-started recordings/broadcasts — user intent outranks posture; those only
  get the confirmation-before-start treatment under `reserve`.

## Risks / escape hatches
- Glasses thermal/battery signal availability varies by firmware — every glasses input is
  optional in the fusion, and phone-only posture must be useful on its own.
- Over-eager downgrade annoys more than it saves: hysteresis bands + conservative default
  thresholds; the P-pass on device (with Plan BT's battery measurements) tunes them.

## Verification
Headless: fusion/table/hysteresis tests + full suite + Release green. Device: a scripted
drain session comparing posture transitions against logged battery/thermal curves, and a
hot-day live-session run confirming `conserve` engages before iOS thermal throttling does.

## Coverage review — 2026-09-12

P2 remains partial;
semantic flags alone do not establish camera or model enforcement. Existing additional posture
readers (walking routes, digest and look-closely) do not close the following checklist.

- [ ] Apply snapshot-first escalation to eligible visual requests; leave the camera off for
  non-visual work. Do not end a stream held by recording, broadcast, HUD or assistive consumers.
- [ ] Apply shorter inactivity and bounded maximum live-vision durations under power pressure.
  Correct the earlier “longer idle teardowns” wording: idle retention must shorten to save power.
- [ ] Enforce reserve-mode admission at every voice/UI/tool live-video entry. Reconcile CX's
  stricter conserve/reserve refusal with BV's confirmation contract in one decision table before
  wiring: a generic confirmation must not override an existing refusal or device thermal stop.
- [ ] Define transitions for an already-running conversation: stop/downgrade its video with an
  audible reason and retain voice when supported. User-started recordings/broadcasts retain their
  separate ownership and device limits; never silently kill them through this policy.
- [ ] Wire smaller local-model selection for eligible opportunistic work and widened reading
  checkpoints; do not replace a model underneath active inference.
- [ ] Wire optional glasses thermal observations with missing/stale signal handling, then validate
  on firmware that supplies them. Build fake-stream tests now; only real signal validation needs hardware.
- [ ] Record drain/hot-day evidence before claiming energy savings or tuning shipped defaults.

Acceptance uses fake clocks, posture changes and resource claims across Direct/offline/Gemini/OpenAI
routes. Test low-battery entry/recovery, charging with high thermal pressure, unavailable glasses
signals, reserve transitions during active video and every stream entry's denial/confirmation path.
Consumer tests must observe actual camera/task actions, not only `PowerPosture` properties.

### Ownership of adjacent gaps

| Gap | Canonical owner |
|---|---|
| Automatic enforcement and signal integration | BV P2, composed with [CX](CX-live-session-vision-choice.md) |
| Every-exit resource release and warm-up cancellation | [EW](EW-session-resource-cleanup.md) |
| User profiles, threshold UI, battery diagnostics | [EY](EY-power-controls-and-diagnostics.md); replaces the former unowned “can follow” |
| Dedup default-on motion validation | [AT](frame-dedup-change-gate.md) |
| Adaptive source capture FPS/resolution | [EZ](EZ-adaptive-camera-capture.md), after [EO](EO-hevc-glasses-stream.md) measurements |
| Resetting current context across backends | [EX](EX-conversation-reset-across-backends.md) |
| OpenClaw LAN/auth compatibility validation | [EH](EH-openclaw-2-0-wire-alignment.md) / [AR](gateway-device-pairing.md) |
