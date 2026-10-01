# Plan GU — Wake Word Without the Call-Quality Link (phone-mic listening, speech gate, clean hand-back)

**Status:** 📋 Planned 2026-10-01 — nothing built.
**Depends on:** the glasses link-state PR (branch `fix/glasses-true-link-state`, read at `65eb417e`):
`GlassesConnectionPhase`, `GlassesUse` (`inUse`, `stoodDown`, `voiceInputAvailable`), worn state on
`GlassesConnectionSnapshot`, `GlassesSleepPolicy`, `GlassesAudioHandoffPolicy`, `TalkEntryPolicy`,
`WakeLaunchPolicy`. GU lands after it merges and treats those types as given.
**Related:** Plan [AS](audio-session-lease-coordinator.md) (lease coordinator), Plan
[AP](audio-session-resilience-p2.md) (interruption/route policies), Plan [BE](BE-wake-word-hardening.md)
(wake-word hardening), Plan [BJ](BJ-audio-activation-offmain.md) (off-main activation), Plan
[BV](BV-power-policy.md) (power posture), Plan [CL](CL-design-language-and-field-polish.md) P3
(`MicRoute`), Plan [CU](CU-voice-turn-latency.md) P2 (`SpeechActivityGate`, detector seam), Plan
[FE](FE-agent-voice-reliability-and-feedback.md) P2 (listener health), Plans
[CH](CH-media-button-trigger.md)/[GJ](GJ-remappable-temple-gestures.md) (temple taps).

---

## Trigger (device-verified 2026-10-01)

1. **Media sounds "off" while Avenkin listens.** Meta glasses play media over Bluetooth A2DP. The
   moment any app opens their mic, iOS moves the link to HFP — mono, narrowband, call quality — in
   both directions. The wake-word listener holds the glasses' mic open all the time (log:
   `wakeWord preferredInputSet route=glasses … BluetoothHFP`, `sessionConfigured route=BluetoothHFP`,
   `otherAudioPaused`/`otherAudioResumed` around turns), so a podcast stays in call quality for as
   long as wake word is on, and after every turn the listener takes HFP straight back.
2. **Power.** Wake word on = continuous on-device recognition on the phone plus an open HFP link
   draining the glasses. Plan BV's posture throttles only camera/frames; nothing cheapens listening.
3. **Turns go silent** (link-state branch device logs): dictation starts on `MicrophoneBuiltIn` and
   the route moves to HFP only *after* `dictation started`; some turns then get error 1110 (no
   speech), others with the identical log sequence transcribe. In push-to-talk the turns use
   `TranscriptionService`'s dedicated fallback engine (`engineDedicated`) and were all silent.

## Outcome

- With glasses connected and wake word on, a podcast plays in full A2DP quality while Avenkin waits.
- HFP is open only for a conversation, and is fully handed back afterwards so the paused app
  resumes — in A2DP.
- A turn never starts recording until its mic is live: the acknowledgement tone means "talk now"
  on the mic that will actually hear you.
- Full speech recognition runs only while somebody is talking (behind a flag until tuned).
- Push-to-talk and listening-off turns use the shared engine and leave no microphone open after.
- No Meta DAT experimental API is used (§8).

## What exists today (verified by reading, 2026-10-01)

- **Routes.** `MicRoute` (`.phone`/`.glasses`/`.headset`, `Services/Audio/MicRoutePolicy.swift`) is
  one preference for *all* capture. `Config.micRoute` falls back to the legacy
  `useGlassesMicForWakeWord`, whose default is `true` — so anyone who never chose is on `.glasses`.
  `MicRoutePolicy.categoryOptions`: glasses/headset → `.allowBluetoothHFP` + `.allowBluetoothA2DP`;
  phone → **no Bluetooth option at all** (not even A2DP output).
- **Idle listener** (`WakeWordService.configureAudioSession`): `assumeOwnership(.wakeWord)`, then
  `AudioSessionCoordinator.reconfigure(.playAndRecord, .default, options + .mixWithOthers)` and
  `preferConfiguredMicIfAvailable` → `setPreferredInput(glasses)`. That is the HFP hold in issue 1.
- **Turn start** (`ConversationStartSequence.run`): configure (a no-op once configured) → shared
  engine (`ensureAudioEngineRunning` = `startListening()` + `pauseRecognitionForSharedEngine()`) →
  mark listening → `pauseOtherAudio()` (non-mixable reconfigure **and** `setPreferredInput`) → ack
  tone → `transcriptionService.startRecording()` (async setup on the next tick). The input route is
  changed *after* the engine is already running on whatever input it had.
- **No engine reconfiguration handling.** Nothing observes `AVAudioEngineConfigurationChange`. The
  SDK header (`AVAudioEngine.h`) says the engine **stops itself** when the input's sample rate or
  channel count changes — built-in mic (48 kHz) → HFP (16 kHz wideband) is such a change.
  `handleRouteChange` rebuilds only on a 0 Hz format. This is the most likely cause of issue 3's
  silent turns (device-confirm in P2).
- **Turn end** (`AppState.returnToWakeWord`): `resumeOtherAudio()` → disconnect tone → "Resuming
  <media>" (TTS, which itself calls `pauseOtherAudio`/`resumeOtherAudio` via `beginPause`/`endPause`)
  → `WakeRearmPolicy`. `resumeOtherAudio` passes `.notifyOthersOnDeactivation` to
  `setActive(true)`; the SDK header says that option is **"only valid on session deactivation"**, so
  it does nothing. Between turns the session is never deactivated (only `deactivateAudioSession`
  and `AudioSessionCoordinator.release` do that), so paused apps are never told to resume, and the
  session stays on HFP options with the glasses mic preferred.
- **Replies.** `TextToSpeechService.beginPause` → `pauseOtherAudio` → replies play over HFP. Barge-in
  and the stop phrase come from `startStopListener()` (wake-word recognizer, `listenForStop`,
  `BargeInPolicy`), which needs a mic during playback.
- **Push-to-talk.** `ListenerHealthPolicy.decide` → `.refuse(.silentMode)`, so `startListening()`
  builds no engine and the turn falls to `TranscriptionService`'s dedicated engine. The skip branch
  of `returnToWakeWord` tears nothing down, so after an explicit turn with listening off an engine
  started for it may stay up (pinned by a test in P0). `SessionRecorderController` already has the
  right shape: `ensureAudioEngineRunningForConsumers()`, then stop at the end if it started it.
- **No wake carry-over.** `handleWakeWordDetected` passes only the matched phrase; the request is
  spoken after the tone into a fresh recognizer. "Hey Avenkin what's the weather" in one breath
  loses the request today; GU does not change that (Out of scope).
- **Shared-tap consumers** ride the listener's engine: `AmbientCaptionService`,
  `MemoryRewindService`, `AudioRecordingService`, `VideoRecordingService`, `BroadcastService`,
  `TeleprompterService`, `CaptureAudioRouter` (→ `StandaloneMicTapService` when the tap is down).
- **Glasses-in-case heuristic.** `SilenceTracker` (RMS < 0.005 for 600 buffers) → `onSilenceDetected`
  → `glassesIdle`; the link-state branch keeps it only for glasses whose worn state is unknown.
- **Recovery gates on Bluetooth.** `handleAudioInterruption(.ended)` restarts only when a Bluetooth
  mic is in the route — a phone-mic listener would never come back after a phone call.
- **Speech-activity pieces** (CU P2 PR1): `SpeechActivityGate` (pure two-threshold hysteresis),
  `SpeechActivityDetecting` seam, `NoSpeechActivityDetector`. The Silero backend (CU P2 PR2) is
  unbuilt; nothing uses `SoundAnalysis` or iOS 26 `SpeechDetector` for speech.
- **iOS 26 SDK** (deployment target 26.0): `.allowBluetoothA2DP` with `.playAndRecord` lets "a paired
  Bluetooth A2DP device appear as an available route for output, while recording through the
  category-appropriate input"; with HFP also allowed, a device supporting both is routed HFP.
  `.bluetoothHighQualityRecording` (mode `.default` only) enables full-bandwidth audio both ways
  when the route supports it (some AirPods), falling back to HFP when combined with
  `.allowBluetoothHFP`; probe with `port.bluetoothMicrophoneExtension?.highQualityRecording`.
- **Copy.** Info.plist mic/speech strings, onboarding ("processed on-device for wake word
  detection") and `privacy.html` §4 never say which microphone. The Settings → Hardware & Privacy
  "Microphone" footer explains the glasses mic's battery cost and the Display call-screen effect.

## Design

### 1. Where idle listening happens — `WakeListenPolicy` (pure)

Split today's one preference in two: **`Config.micRoute` stays the conversation mic** (where your
request is heard and, during a conversation, where replies play), and a new **`Config.wakeListenMic`**
(`.iPhone` | `.sameAsMicrophone`) says where the idle listener waits. `WakeListenPolicy.decide(_:)` →
`IdleAudioPlan { listen: .off | .phone | .bluetooth(MicRoute); options; preferredInput; gate }`.

| Situation | Idle plan |
|---|---|
| listening off, push-to-talk, muted, stood down (`voiceInputAvailable == false`) | `.off` — no session held |
| CarPlay (`carPlayMode`) | unchanged (the car owns the route; `.voiceChat` + HFP as today) |
| a realtime session or expert call owns the lease | not ours — no change |
| a shared-tap consumer that wants the wearer's own audio (glasses recording/broadcast, captions, teleprompter) runs with a Bluetooth conversation mic | `.bluetooth(route)` — today's hold, released when it stops |
| `wakeListenMic == .sameAsMicrophone` | `.bluetooth(route)` (today's behaviour, by choice) |
| otherwise | `.phone`: `.playAndRecord`, `.default`, `[.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]`, preferred input = built-in mic |

The A2DP-only option set is new for every route, phone-only included: today's `.phone` options give
the system no Bluetooth output, which may pull a headphone podcast onto the loudspeaker while the
listener is active (device-pending).

**Phone-mic idle, honestly:**
- **Phone on a desk or in a hand:** at least as good as the glasses mic for the wake phrase
  (wideband, no call screen), and media stays A2DP.
- **Phone in a pocket or bag:** muffled; wake recall may drop and rustle opens the gate. Unknown
  until measured (P2). The glasses choice is the escape hatch. There is no reliable background
  pocket signal (proximity monitoring is foreground and blanks the screen), so no auto-switch.
- **Glasses-only wearers** (phone left elsewhere in Bluetooth range): choose the glasses mic.
- **Display glasses:** an idle phone-mic listener never raises the call screen over the lens HUD —
  what `.headset` was added for, now true for everyone while idle.
- **AirPods** (`.headset`): same split — idle on the phone, the conversation on the AirPods, with
  `.bluetoothHighQualityRecording` so supported models stay full-bandwidth.
- **Phone-only users:** listen and talk on the phone as now; they gain the A2DP output option and
  the gate, and never touch HFP. The link-state branch turns the always-on wake word on for them at
  launch; whichever default Greig keeps, GU makes it cheaper (Open question 5).

With the phone as the idle input, silence no longer means "glasses in the case": the plan reports
`silenceMeansGlassesIdle == false` for `.phone`, and `onSilenceDetected` → `glassesIdle` is skipped
(the link state already covers case/off).

### 2. The turn: switch first, then listen — `TurnMicHandoff` (pure sequencing)

For a wake word, tap, Action Button or temple tap, in this order:

1. Stop the idle recognizer and the engine (a route change would stop the engine anyway — do it on
   purpose, not mid-dictation).
2. Reconfigure for the conversation: non-mixable (pauses other audio, as now), conversation-route
   options (+ `.bluetoothHighQualityRecording`), `setPreferredInput(conversation mic)`.
3. **Wait for the route to be live:** `currentRoute.inputs` resolves to that mic
   (`MicRoutePolicy.resolvedRoute`; `setPreferredInput` is not synchronous on Bluetooth) **and** the
   first buffers on the rebuilt engine are above an absolute floor (not the all-zero frames of a
   half-up link). Deadline `turnMicDeadline`, provisional 2.0 s.
4. Build the engine on the live input format; attach the dictation forwarder.
5. Play the acknowledgement tone; start recording.
6. Deadline missed → this turn uses the phone mic (`turnMicFellBack` logged); a slow link never eats
   the request. Glasses not in use (`GlassesUse.inUse == false`) → phone directly.

`ConversationStartSequence` gains a `handOffMic` stage between `pauseOtherAudio` and the tone; the
decision (`TurnMicHandoff.next(state, event)` over `routeObserved`, `framesNonSilent`, `deadline`)
is pure. The wearer already waits for the tone, so the switch adds time before the tone, not
clipped words. **Explicit turns with no wake listener** (push-to-talk, listening off) start the
shared engine with `ensureAudioEngineRunningForConsumers()` and record that they did
(`TurnEngineOwnership.startedForTurn`) so the hand-back stops it. Guarantee, tested: after any turn
ends with no listener wanted, no engine runs and no lease is held.

### 3. Hand-back after the conversation — `TurnAudioRelease` (pure ordering)

At `returnToWakeWord`, in order:

1. Finish the app's own audio: disconnect tone, then "Resuming <media>" — moved **before** the
   release so it no longer re-pauses the app it is announcing.
2. Stop the recognizer and engine (deactivating with running I/O fails).
3. **Deactivate with `.notifyOthersOnDeactivation`** — the only call that tells Podcasts or Music to
   resume — through a new coordinator method `handBack(_ lease:)`. Its ledger decision
   (`HandBackDecision`, pure) deactivates only when wake word or dictation is the current owner and
   no coexisting rider (TTS, the temple-tap claim) is active; otherwise it leaves the session to
   that owner.
4. Re-arm per `WakeRearmPolicy`: `.restart` → reactivate in the idle plan (mixable, A2DP-only,
   built-in mic), start the engine and the listener; `.skip` → stay deactivated.

Our own route changes are expected, not disruptions: each switch carries a `RouteSwitchGeneration`,
and `handleRouteChange` ignores `.categoryChange`/`.override`/`.oldDeviceUnavailable` inside one
(today `.oldDeviceUnavailable` calls `pauseForAudioDisruption()` even when Bluetooth output is
retained, which would kill the fresh idle listener). A switch nobody in the app asked for (another
app, "Hey Meta") is still a disruption. `handleAudioInterruption(.ended)` restarts per
`WakeListenPolicy` (owner free and plan not `.off`) instead of "a Bluetooth mic is in the route".
`AudioInterruptionPolicy.mayResume` and the lease ledger are unchanged; the realtime modes keep
their own sessions and, when they release, wake word re-arms into the idle plan.

### 4. Replies

**P1: hold the conversation mic for the whole conversation** — replies and follow-ups stay on HFP as
today: one switch in, one hand-back out. Barge-in and the stop phrase keep working as now.
**P3 (device-gated, Developer flag): replies over A2DP** — release HFP before a reply, run the
stop/barge-in listener on the phone mic (the glasses' speakers are at the ear, so the phone hears
little of the reply — less self-interruption than the open-speaker case `BargeInPolicy` already
guards), and re-take HFP only when a follow-up starts. Worth it only if P2 measures the switch well
under a second, since each follow-up pays it twice.

### 5. Speech gate — `WakeSpeechGate`

| Option | Cost | False opens | First syllables | Verdict |
|---|---|---|---|---|
| Energy (RMS vs tracked noise floor) + zero-crossing band | negligible arithmetic on the tap | any loud sound (speaker music, traffic, rustle) | onset within one buffer (~21 ms) | **Recommended first stage** |
| `SoundAnalysis` speech class | a neural model on ~1 s windows | low | ~0.5–1 s late, needs ≥ 1.5 s pre-roll | later second stage if false opens dominate |
| Silero VAD (CU P2 PR2) | small model, new dependency | low | ~30 ms hops | swap in behind the same seam when CU ships it |
| iOS 26 `SpeechDetector` | runs inside a `SpeechAnalyzer` pipeline | low | unknown | not now — the wake path is `SFSpeechRecognizer`; revisit if it moves |

**Design.** `EnergySpeechScorer` (pure: buffer → score 0…1, an adaptive noise floor that follows
down fast and up slowly, a zero-crossing band that rejects rumble and hiss) feeds the existing
`SpeechActivityGate` with a new `Configuration.wakeIdle` preset. On `speechStarted` the service
creates the recognition request, **replays the pre-roll** — `PreRollBuffer`, a preallocated ring of
the last `preRollSeconds` = 1.0 s, written on the render thread, drained and switched to live append
atomically under `WakeTapState`'s lock so no frame is lost or doubled — and starts recognition. On
`speechEnded` plus `recognitionTail` (1.5 s, for the final partial) the task is cancelled unless a
wake phrase matched. A gate open longer than `maxOpenSeconds` (60 s — a conversation nearby) falls
back to today's restart-on-final.

**Unchanged:** the engine and tap keep running while the gate is closed. That keeps the app alive in
the background (`audio` background mode), keeps every shared-tap consumer fed ungated, and keeps the
system microphone indicator truthful. `ListenerHealthPolicy` gains
`ListenerPauseReason.speechGateClosed`, so engine up / tap up / no task reads as healthy rather than
`.rebuild(.noRecognitionTask)`. Constants live in `WakeSpeechGate.Thresholds`, all provisional:
absolute floor −55 dBFS, onset +10 dB over the floor, release +6 dB, zero crossings 150–5,000 per
second, minimum speech 0.10 s — tuned in P2 against missed wakes.

### 6. Modes and power

- **Wake word on:** §1–§5. **Push-to-talk / listening off:** no idle session at all, so media never
  leaves A2DP; turns use §2 and §3, which is where the hand-back fix matters most.
- **Worn / not:** with the link up and the glasses off the face, replies go where `GlassesUse` says
  (stood down → phone speaker; `glassesOnlyAudio` withholds as today).
- **Power posture** (the `PowerPosture` consumer contract — flags, no `switch` in consumers):
  `prefersStrictWakeGate` (conserve and up: onset +13 dB, tail 1.0 s); `prefersPhoneWakeMic`
  (reserve: a glasses idle choice is overridden to the phone mic, saving the glasses' radio); and in
  reserve one dismissible Home card suggesting push-to-talk — never spoken, at most once a day.

### 7. Privacy

Same guarantees as today: on-device wake recognition where available (`onDeviceWakeWordEnabled`),
nothing stored. The gate sends strictly less audio to the recognizer; the pre-roll is 1 s held in
memory, overwritten continuously, never logged or persisted. New `PrivacyLog.AudioEvent` cases carry
counts and route tokens only: `idlePlanSelected`, `turnMicLive`, `turnMicFellBack`, `handedBack`,
`gateOpened`/`gateClosed` (hourly counts), `highQualityRecordingSupport`. No consent or privacy copy
promises the glasses mic, so none changes; only the Hardware & Privacy "Microphone" footer is
rewritten for the new choice.

### 8. Meta DAT

None of this touches Meta's SDK: the glasses' mic is ordinary Bluetooth HFP/LE under iOS's audio
session. GU **does not adopt** `MWDATSpeech`, `MWDATInputs`, voice invocations
(`VoiceInvocationsStream`) or camera audio (`StreamConfiguration.audioCodec`) — all Experimental in
DAT 1.0.0 and unpublishable. Worn state comes from the stable `DeviceState`, via the link-state branch.

## Settings (glasses section only)

Settings → Hardware & Privacy, as the first row of the glasses section (prominent — Greig wants to flip it per situation): **"Listen for the wake word on"** — *iPhone*
(default) / *Same as Microphone*. Footer: "iPhone keeps music and podcasts on your glasses in full
quality and saves their battery. Choose Same as Microphone if your phone is usually in a bag." The
"Microphone" picker keeps its meaning for the conversation itself. Nothing appears outside the
glasses/hardware section.

## Phases

**P0 — Deterministic core (headless).** `WakeListenPolicy`, `MicRoutePolicy.idleCategoryOptions` /
`conversationCategoryOptions`, `TurnMicHandoff`, `TurnAudioRelease`, `HandBackDecision`,
`TurnEngineOwnership`, the `RouteSwitchGeneration` filter, `EnergySpeechScorer`, `WakeSpeechGate`
(+ `SpeechActivityGate.Configuration.wakeIdle`), `PreRollBuffer`,
`ListenerPauseReason.speechGateClosed`, the two `PowerPosture` flags. Tests:
- `WakeListenPolicyTests` — every table row, posture override, CarPlay unchanged, consumer hold.
- `MicRoutePolicyTests` (extended) — idle is A2DP without HFP for every route; conversation options
  add high-quality recording.
- `TurnMicHandoffTests` — route then frames, deadline → phone, glasses not in use → phone, tone
  never before live.
- `TurnAudioReleaseSequenceTests` — announcement before deactivate, engine stopped before
  deactivate, skip → no reactivation.
- `HandBackDecisionTests` — a realtime owner or a live TTS rider defers the deactivate.
- `ExplicitTurnEngineTests` — a push-to-talk turn uses the shared consumer engine; after the turn no
  engine runs and no lease is held.
- `SelfRouteChangeFilterTests` — own switches ignored, foreign ones still disrupt.
- `EnergySpeechScorerTests`, `WakeSpeechGateTests` — synthetic PCM: digital silence, steady noise at
  several levels, low rumble, hiss, amplitude-modulated speech-like bursts, a rising floor.
- `PreRollBufferTests` — wrap-around, oldest-first drain, sequence-numbered attach with no loss or
  duplicate.
- `ListenerHealthPolicyTests`, `ConversationStartSequenceTests` (extended) — gate closed is healthy;
  hand-off stage precedes the tone.

**P1 — Wiring.** `WakeWordService` idle configure from the plan, gated recognizer lifecycle,
pre-roll attach, an `AVAudioEngineConfigurationChange` observer (rebuild on the live format), the
interruption and route-change rules; the `ConversationStartSequence` hand-off; the `returnToWakeWord`
order; coordinator `handBack`; `TranscriptionService` attaching only after the hand-off; the settings
row; high-quality-recording support logged on connect. **Flags:** the hand-off, hand-back and
explicit-turn engine fixes ship **on, unflagged** — they fix silent turns and the podcast that is
never told to resume. `wakeListenMic` defaults to **iPhone**; the setting is the rollback. The
speech gate ships behind `Config.wakeSpeechGateEnabled`, **default off**, with a Developer panel
toggle, until P2 shows no missed wakes.

**P2 — Device tuning (owed; Greig).** Capture the log for each step.
1. Podcast on the glasses, wake word on, phone on a desk: 2 min idle — full quality (no mono or
   muffle)? Say the wake phrase 10 times at normal voice: hits out of 10, wake→tone ms (log).
2. Same with the phone in a front pocket, then in a bag: hits out of 10; gate opens per minute
   while walking.
3. After each of 5 conversations: does the podcast resume by itself, in full quality, within 2 s?
4. Push-to-talk on, tap the capsule, ask 5 questions: all transcribed? Mic indicator off after each?
5. Glasses worn, then taken off with the link up: where does the reply play; does the wake word
   still answer on the phone?
6. AirPods instead (Microphone = Headset): steps 1 and 3; read `highQualityRecording`
   supported/enabled from the log — and the same line for the glasses.
7. A CarPlay drive: wake word and replies unchanged.
8. Switch timing: 10 conversations, median and worst `turnMicLive` latency; any `turnMicFellBack`.
9. **Battery:** glasses charged to 100 %, the same podcast, phone screen off, three 2-hour runs on
   separate days — (A) Same as Microphone, gate off (today); (B) iPhone, gate off; (C) iPhone, gate
   on. Record glasses % (device card) and phone % at start and end, Settings → Battery's per-app
   share, and the hourly gate and recognizer counts. Then set the thresholds and the gate default.

**P3 — Optional, after P2.** Replies over A2DP (§4) behind a Developer flag; a second-stage
classifier if pocket rustle dominates gate opens; Silero as the scorer when CU P2 PR2 lands.

## Risks

- **Pocket recall** may be poor enough that iPhone is the wrong default for some wearers — the
  setting and P2 step 2 exist for that.
- **Switch latency** of HFP set-up is unmeasured; the deadline and phone fallback bound it.
- **Route behaviour** — A2DP output held while recording on the built-in mic, another app's media
  staying on A2DP under our mixable session, Podcasts resuming on notify — is documented by Apple
  but device-pending for these glasses.
- **Gate misses** clip or drop a wake phrase; pre-roll covers onset lag, the flag covers the rest.
- **"Hey Meta"** can take the glasses' mic route mid-conversation; only our own switch generation is
  ignored, so that still recovers as a disruption.

## Decisions (recommended)

1. Idle wake listening on the **iPhone mic** by default; the glasses mic by choice or while a
   consumer needs it.
2. HFP held for the **whole conversation** in P1, ended with a real deactivate + notify.
3. A turn records only on a **live** mic; phone fallback after 2 s.
4. **Energy + zero-crossing gate** over `SpeechActivityGate`, 1 s pre-roll, off until tuned.
5. Push-to-talk turns use the **shared engine** and leave nothing running.
6. Settings stay in the **glasses section**.
7. **No DAT experimental** APIs.

## Answered by Greig (2026-10-01)

1. **Idle mic for glasses wearers:** a setting, defaulting to the iPhone, placed prominently — first
   row of the glasses section, not buried under Microphone — so it can be flipped per situation
   (phone in a bag → glasses). Revisit the default if P2 pocket recall is under 8/10.
2. **Glasses off the face, link up:** keep the wake word listening on the phone; replies to the phone
   speaker. This replaces the link-state PR's doff → 30 s → automatic stand-down *for the wake word*
   (`GlassesSleepPolicy`): with idle listening on the phone there is no glasses mic to release. The
   wearer's own Disconnect still closes voice input. Update `GlassesSleepPolicy` and its tests in P1.
3. **Speech gate:** off until tuned; on by default only after the P2 battery comparison shows a clear
   saving and no missed wakes.
4. **Replies in full quality (P3):** only if P2 measures a median switch under ~0.7 s; otherwise the
   whole conversation stays on the call link.
5. **Phone-only users:** the always-on wake word follows the Listening switch (shipped in the
   link-state PR); the gate's default flips for them at the same time as for glasses wearers.

## Out of scope

Carrying words spoken after the wake phrase into the request (today's behaviour already drops them);
a custom wake-word model; changes to the realtime modes' sessions; automatic pocket detection; LE
Audio-specific tuning beyond logging the port type.
