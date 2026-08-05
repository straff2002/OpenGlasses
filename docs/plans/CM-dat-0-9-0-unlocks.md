# Plan CM — DAT 0.9.0 Feature Unlocks

**Status: 📋 Planned** — follow-up to the SDK 0.9.0 adoption ([#298](https://github.com/straff2002/OpenGlasses/pull/298)).
The bump was API migration only; this plan turns the *new capabilities* into features. One
shared gate: the glasses-side DAT rollout for 0.9.0 hadn't shipped as of 2026-08-05
(`datAppOnTheGlassesUpdateRequired` on every session), so **all device smoke tests here queue
behind the same rollout** — but every core below is headless-buildable now, per house style.

What 0.9.0 gives us that 0.8.0 didn't:

1. `StreamError.hingesClosed` now also fires when the glasses are **doffed** mid-stream
   (previously a silent generic pause) — a free wear/doff signal.
2. Meta's rebuilt Camera Access sample demonstrates **recording with sound-in-video continuing
   while the app is backgrounded** — a sanctioned pattern for background capture.
3. `Camera.state` / `Camera.statePublisher` — capability lifecycle distinct from stream state.
4. Display result builder completes **if/else** (`buildEither(second:)`) and makes **flex
   modifiers on buttons sanctioned** (previously the label-clipping `FlexChildWrapper` trap);
   `ButtonGroup` shipped in #298.
5. Info.plist crash-reporting opt-out (`MWDAT > CrashReporting > OptOut`).

## P1 — Doff-aware auto-pause (PR 1, highest certainty)

Taking the glasses off should pause what's *about* the wearer: the meeting recorder and
ambient captions keep transcribing desk noise today; a video recording keeps rolling on the
inside of a case.

- **Pure core: `WearStatePolicy`.** Input: the doff/fold signal plus the set of active
  consumers (meeting recording, ambient captions, video recording, continuous streaming
  intent, Live Coach). Output: per-consumer action (`pause`, `stopAndSave`, `announce`,
  `ignore`) + resume behavior on re-don. A table of cases, tested as data.
- **Wiring:** `CameraService` already receives `hingesClosed` via `CameraErrorPolicy`; add a
  wear-state fan-out (publisher on the service, consumers subscribe — same shape as
  `framePublisher`). `PowerPolicyService` gets the signal as a presence input.
- **Caveat baked into the policy:** 0.9.0 conflates fold and doff in one case — treat both as
  "not being worn"; do not attempt to distinguish.
- Device-pending: none for the core; live verification of signal timing only.

## P2 — Background meeting recording from glasses (PR 2, spike-gated)

The meeting recorder (#297) currently records with the app foregrounded. The 0.9.0 sample
pattern suggests glasses capture can continue backgrounded — the feature users actually want
in a meeting (phone face-down in a pocket).

- **P2a (headless):** `SessionRecorderController` continuation across scene-phase transitions —
  background-task begin/end around active recording, state machine survives
  suspend/resume, recording finalizes cleanly if iOS kills the task. Seam-injected, no
  hardware.
- **P2b (device spike):** does the glasses-mic HFP route + DAT stream actually keep delivering
  backgrounded on our stream config? Verify against the sample's session shape; document
  required `UIBackgroundModes` (audio is likely sufficient for the mic-only recorder).
- **Constraint carried over:** on-device MLX inference can't run backgrounded — transcription
  stays deferred (pending → transcribing on foreground return) or goes cloud; the existing
  pending-state machine already models this.

## P3 — Camera lifecycle surfacing (PR 3, small)

`Camera.statePublisher` distinguishes "capability attaching" from "stream warming" — today both
render as a generic wait.

- Pure mapping: `CameraState` × `StreamState` → user-facing phase ("waking camera…",
  "starting stream…", "waiting for glasses…") for the status card pills and debug overlay.
- Stall recovery gains a cheap precondition: skip the stream-rebuild tier when the *camera*
  is the part that's down.

## P4 — HUD conditional layouts & button-row polish (PR 4)

With full if/else in the component builder and sanctioned flex on buttons:

- `HUDScreen` button rows get alignment + equal-width options, plumbed through
  `MetaDisplayBackend` (`ButtonGroup(alignment:)` + `flexGrow`) and mirrored in
  `HUDPreviewView`.
- Conditional screen variants (e.g. compact vs full line sets) become single builder
  expressions instead of pre-shaped model branches where that simplifies call sites.
- Tests: tree-shape assertions, headless (same seams as X/Y plan suites).

## P5 — Crash-reporting opt-out (rider, ship-time decision)

Set `MWDAT > CrashReporting > OptOut = true` in the committed Info.plist: no crash telemetry
to Meta by default, consistent with the privacy posture and the Medical Compliance story.
One-line change + a note in `docs/BUILDING.md`; fold into whichever PR ships first.

## Order & gating

P1 → P3 → P4 are buildable and testable immediately; P5 rides along. P2a is buildable now;
P2b (and every physical smoke above) waits on Meta's device-side 0.9.0 rollout — the same
gate as #298's owed smoke test. When the rollout lands, run #298's smoke first (streaming,
capture, ButtonGroup rendering), then P2b.
