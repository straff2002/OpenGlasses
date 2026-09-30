# Plan GJ — Remappable Temple Taps (one, two, three taps)

**Status:** 🚧 P0 + P1 + P3 built 2026-10-01 (one PR) — pure core, wiring, settings and in-session
mute are in and headlessly tested; **P2, the device run, is owed**, and with it every tap→AVRCP
mapping: the calibration table (1 = play/pause, play or pause; 2 = next track; 3 = previous track)
is still the conventional assumption, never observed on glasses, and "session control" (taps
reaching the app during its own Direct, Gemini Live or OpenAI Realtime conversation) is equally
unverified. Also owed on device: single-tap latency, locked-phone behaviour, taps with music
playing, glasses-camera capture from a locked phone, and how each live provider treats a muted
(silent) mic. "Experimental" stays on the setting until P2 confirms at least one model.
**Continues:** Plan [CH](CH-media-button-trigger.md) (media-button trigger). CH's P1 policy and P2
wiring shipped 2026-08-02; its P3 device smoke — *which temple gestures arrive as which AVRCP
commands* — was never run, and this plan cannot be finished without it.
**Related:** Plan AS (audio-session lease coordinator), Plan BZ (notification digest), Plan GA (photo
from a non-glasses camera), `QuickAction` (the action vocabulary reused here).

---

## Trigger

The temple tap today does exactly one thing (double-tap starts listening), is buried under
"Voice & Triggers" as experimental, and goes dead during a conversation, which is exactly when a
wearer wants a tap to hang up or mute. Wearers want a few taps they can assign to what they
actually do: start talking, hang up, mute, "what am I looking at", save a photo.

## Outcome

- **Defaults:** one tap = start talking, two taps = hang up, three taps = mute/unmute the mic.
- **Each count remappable** to: start talking, hang up, mute/unmute, photo + describe, photo to
  camera roll, read my digest, start/stop recording, ask my agent (only with Agent Mode on), any
  saved Quick Action, or nothing.
- Works in **standby** with the phone locked in a pocket.
- The glasses maker's own gestures stay theirs: the long press that summons the maker's assistant
  and the capture button are not touched and cannot be remapped.
- Honest about what is not yet verified on the glasses.

## What exists today (verified 2026-10-01)

- `Services/Triggers/MediaTriggerPolicy.swift`: `MediaRemoteCommand` `nextTrack` (commented as
  double-tap), `togglePlayPause` (single), `previousTrack` (triple) — **the mapping is an assumption
  in comments, never observed**. `decide(_:)` claims Now Playing only when the feature is on, no
  user audio plays, no realtime session runs and the lease owner does not block;
  `ownerBlocksClaim` returns true for `.transcription`, `.geminiLive`, `.openAIRealtime`,
  `.liveTranslation`, `.expertCall`. `firesTrigger` accepts `.nextTrack` only.
- `Services/Triggers/MediaTriggerService.swift`: `SilentNowPlayingClaimer` plays a silent WAV and
  registers `nextTrackCommand`, `togglePlayPauseCommand`, `previousTrackCommand` — **not
  `playCommand` / `pauseCommand`**, which is how many Bluetooth AVRCP devices deliver a single press.
- `Services/Triggers/AlternativeTrigger.swift`: the DAT SDK exposes no raw touchpad stream; AVRCP
  through Now Playing is the only route (still true for DAT 1.0.0's stable surface; the
  experimental `MWDATInputs` module is not adopted, per house rule).
- Setting: "Temple Tap (Experimental)" in `VoiceTriggersSettingsScreen` (`SettingsScreens.swift`),
  `Config.mediaTriggerEnabled`, default off.
- Actions available to call: `AppState.micMuted` (stops the wake-word listener), `endListeningSession()`,
  `geminiLiveSession.stopSession()` and the OpenAI Realtime stop, `captureAndAnalyzePhoto()`,
  `capturePhotoSilently()`, `GlassesPhotoAlbum.saveImage(_:)`, `toggleRecording()`,
  `NotificationDigestService.presentGlance(explicit:)`, `executeQuickAction` (`QuickAction.ActionType`:
  prompt, photo, photoThenPrompt, homeAssistant, siriShortcut, openApp, toggleRecording).
- "Read new messages" in the honest sense: iOS does not let an app read other apps' messages. The
  mappable action is **read my digest** (Plan BZ items), and the picker says so.

## Design

**Gesture layer (pure).** `TempleGesture` = `.one`, `.two`, `.three`. `TempleGestureDecoder` maps
incoming `MediaRemoteCommand`s to gestures through a **calibration table**, not a hard-coded
assumption: default table `togglePlayPause | play | pause → .one`, `nextTrack → .two`,
`previousTrack → .three`, replaceable per glasses model after the device run. A command arriving
within 150 ms of another is treated as one gesture (some stacks send `pause` then `play`).

**Action layer (pure).** `TempleAction` enum (the list above plus `.quickAction(id)` and `.none`).
`TempleGestureMap` holds three assignments, persisted as raw strings. `TempleActionResolver.resolve(
gesture:map:context:)` → `TempleOutcome` (`.run(action)`, `.ignored(reason)`), where `context` =
standby / listening / speaking / live session, Agent Mode on/off, recording on/off:
- `.hangUp` in standby → `.ignored(.nothingToEnd)` with a soft tone.
- `.startTalking` while listening → no-op; while the assistant is speaking → barge-in (stop speech,
  listen), matching the wake-word path.
- `.askAgent` with Agent Mode off → `.ignored(.agentModeOff)`; the picker hides it then too.
- Every outcome has an earcon, so a pocketed phone still confirms which action fired.

**Claim policy change.** CH releases the claim whenever a conversation owns the audio lease, which
makes "two taps = hang up" impossible. `MediaTriggerPolicy` gains a second mode:
- **Standby claim** (today): silent player, only when nothing else plays.
- **Session control:** while *our own* conversation holds the lease (transcription, Gemini Live,
  OpenAI Realtime), keep the remote-command handlers registered without the silent player — the
  session's own audio should make the app the Now Playing owner. *Device-unverified:* whether iOS
  routes AVRCP to a `playAndRecord` session app. If it does not, hang-up and in-session mute are
  shown as unavailable in settings rather than silently failing.
- The wearer's own music still always wins; with music playing, taps control the music.
`ownerBlocksClaim` keeps blocking `.liveTranslation` and `.expertCall` (another person is on the line).

**Mute.** Standby: toggles `micMuted`. In a session: a new `mute(_:)` seam on the live session
managers stops sending mic audio without ending the session (P3; until then three taps in a session
ends with a "mic muted" tone only for Direct mode).

**Photos.** `photoDescribe` → `captureAndAnalyzePhoto()`; `photoToCameraRoll` → capture then
`GlassesPhotoAlbum.saveImage`. Both follow Plan GA's source rules; from a locked phone without the
glasses camera they refuse with a tone and a short line, never a hidden phone-camera shot.
Whether the glasses camera can be driven while the phone app is backgrounded is part of the device
run.

**Settings.** Move temple taps to the **glasses** section ("Glasses & Privacy" →
"Temple taps"), since the feature needs glasses: on/off, then three rows ("One tap", "Two taps",
"Three taps") with pickers, a "Test" mode that just announces the detected gesture (which doubles
as the calibration run), and a footer: "Pauses while your own music plays. The long press and
capture button stay with your glasses." Strings localised; no plan letters. The current
"Voice & Triggers" toggle becomes a link to the new place.

## Phases (one PR each)

**P0 — Pure core.** `TempleGesture`, `TempleGestureDecoder` (calibration table, coalescing),
`TempleAction`, `TempleGestureMap` (persistence, unknown raw value → `.none`), `TempleActionResolver`,
policy session-control mode. Tests: `TempleGestureDecoderTests` (default table; `play`/`pause`
count as one tap; coalescing window), `TempleActionResolverTests` (every action × context; agent
gate; hang-up in standby ignored), `MediaTriggerPolicyTests` additions (session-control keeps
handlers for our own sessions only; expert call and live translation still block).

**P1 — Wiring and settings.** Register `playCommand`/`pauseCommand`; dispatch through the resolver
into `AppState`; earcons; the new glasses-section screen with the test mode; migrate
`mediaTriggerEnabled` (on stays on with the defaults, which keep double-tap-to-talk working for
current users only if the device run confirms double = next-track — otherwise the migration keeps
the old single binding). Tests: `TempleGestureSettingsMigrationTests`, dispatcher tests with a fake
`AppState` seam.

**P2 — Device run (owed; this is CH P3).** Ray-Ban Meta (and any other supported model): which
command each of one/two/three taps sends, whether a single tap is delayed while the firmware waits
for a second, behaviour with the phone locked, with music playing, during a Gemini Live and an
OpenAI Realtime session, and glasses-camera capture from a locked phone. Results go into the
calibration table and this plan's status.

**P3 — In-session mute.** Mute seams on both live session managers and Direct-mode transcription.

## Risks

- **Firmware owns the gestures.** Counts and command mapping may differ by model and firmware and
  can change with an update; the calibration table and the test mode are the mitigation.
- **Now Playing during sessions** may not be granted; then hang-up by tap is not offered.
- **Accidental taps** (adjusting the glasses) on a destructive mapping: hang-up is harmless;
  recording start is confirmed by an earcon and shows on the phone.

## Decisions for Greig

1. Defaults as briefed (1 talk, 2 hang up, 3 mute) — but today's users know **double-tap = talk**.
   *Recommend the briefed defaults for new users, and keep double-tap = talk for anyone who had the
   experimental toggle on.*
2. Move the setting to the glasses section (recommended, per the settings rule).
3. Drop "Experimental" once P2 confirms the mapping on at least one glasses model.
4. Offer "ask my agent" on a tap at all (Agent Mode only)? *Recommend yes, hidden when off.*

## As built (2026-10-01)

Decisions taken (Greig: proceed with the recommendations): briefed defaults for new wearers, and
double tap = start talking (one and three taps unassigned, exactly as before) for anyone who had the
old switch on — `TempleGestureSettingsMigration`, once, behind a flag, never over a saved map; the
setting lives under Hardware & Privacy (the plan's "Glasses & Privacy" is that screen) with a link
from Voice & Triggers; "Experimental" kept; "ask my agent" offered only under Agent Mode.

- **P0.** `TempleGesture`, `TempleCalibration` (table + `deviceConfirmed` /
  `sessionControlAvailable` / `sessionControlConfirmed` flags, all honest-false except the
  assumed availability), `TempleGestureDecoder` (150 ms coalescing from the most recent command),
  `TempleAction` (unknown raw value → nothing), `TempleGestureMap` + store,
  `TempleActionResolver` → `TempleOutcome`, `TempleEarcon`. `MediaTriggerPolicy` now returns
  `.claim(.standby | .sessionControl)`: the app's own conversation (transcription / Gemini Live /
  OpenAI Realtime lease, or the app's conversation flags) keeps the handlers without the silent
  player; live translation and expert calls still block; the wearer's music still wins.
- **P1.** `play`/`pause` registered alongside toggle/next/previous; `MediaTriggerService` emits
  decoded taps (1 s repeat guard) instead of a single trigger; `TempleGestureDispatcher` resolves
  against `AppState` (`AppState+TempleTaps.swift`), plays the earcon, then acts; claim mode is
  re-evaluated when conversation state changes, not only on audio notifications. The
  session-control claimer touches no audio session (no player, no activation, no ledger entry), so
  AO/AP interruption and resume handling is untouched. Test mode announces each tap with its raw
  command. Tap photos use `capturePhoto(allowPhoneFallback: false)`: glasses camera or a spoken
  refusal, never a hidden phone shot. "Ask my agent" opens a turn whose utterance goes to the tool
  router as a user-origin `execute` call, so the Agent Mode gate and authorization policy apply.
- **P3.** `micMuted` on both live session managers, enforced in the shared captured-buffer gate
  (`EchoSuppressionPolicy.shouldForwardCapturedBuffer`), cleared on start/stop. In a Direct-mode
  conversation, mute ends the conversation and leaves the wake-word mic muted.

Where the plan was wrong: `CameraService.capturePhoto()` itself swaps to the phone camera whenever
the glasses backend is not ready (not only `captureAndAnalyzePhoto`'s explicit screen), so a
glasses-only flag was needed; the camera-roll action is `capturePhotoFromGlasses()` because every
capture already lands in the Glasses album (`GlassesPhotoAlbum.saveImage` is not called directly);
and there was no existing "ask my agent" route to reuse. Found on the way: the standby claimer's
deferred `play()` could start silence after its claim had been released — now guarded.

## Out of scope

Raw touchpad or swipe access (not in the stable DAT surface), the maker's long press and capture
button, volume swipes, and any experimental DAT input module.
