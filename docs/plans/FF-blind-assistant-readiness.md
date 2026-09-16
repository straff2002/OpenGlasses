# Plan FF — Blind Assistant Readiness

**Status: 🚧 P0 PR1+PR2 and P1 PR3 (headless part) implemented 2026-09-16 — one shared blind-assistance contract composed across the live preset, both realtime backends and the assistive services; an audible session lifecycle (four earcons plus short spoken lines) that queues, coalesces and expires its notices so a cue is true at the moment it is heard; and one activation owner behind every live-session entry, with an opt-in start-on-launch that says out loud why it did not start. PR4–PR7 unbuilt. Gate C stays blocked on a supported background-inference path. No hardware validation, no live model output, no on-glasses audio check and no blind-participant journey has been captured yet.**

Origin: a blind-user readiness request naming seven areas — non-visual activation, a blind-user prompt, reading-quality capture, audible state, session resilience, offline local vision and safety framing.
Baseline: OpenGlasses working tree at `4573210f`, including existing local changes. Existing plan status is context, not proof of current device behaviour.

## Assessment

We are substantially closer than a developer demo: six of the seven requested areas have relevant implementation. That is architectural coverage, not six completed requirements. Automatic cloud-to-offline visual conversation is the largest missing capability. Prompt consistency, audible recovery and independent end-to-end use are the immediate gaps.

The online experience looks close enough for a focused hardening and user-validation milestone. Daily-use offline reliability is a separate, larger milestone. A numerical completion percentage would hide the difference between an implemented policy and a proven pocketed-phone experience.

## Requirement-to-code map

| Requested area | Current evidence | Remaining gap |
|---|---|---|
| Non-visual activation | **P1/PR3 done in code.** `LiveSessionActivator` is the one owner behind launch, foreground, the Action Button, every Siri shortcut and the app's own control; `BlindAssistantLaunchPolicy` decides the opt-in start-on-launch and names the nine ways it declines. VoiceOver semantics and UI audits exist, and the non-visual journey is walked in [FF-entry-journey-audit.md](FF-entry-journey-audit.md). | A blind participant completing setup and use without a sighted operator — the acceptance bar — and the device checks listed in the PR3 evidence note. Temple media trigger stays experimental; the pinned DAT SDK exposes no gesture or capture-button API (re-checked, see the audit). |
| Blind-user prompt | **P0 done.** `BlindAssistanceContract` holds the rules once; the Blind Assistant preset prefix is composed from it, both realtime backends apply the preset through one seam, and navigation, narration, assistive-mode and reading compose the fragments that apply to them. | Live model outputs still to be captured against `BlindAssistanceResponseAudit` on device (see the P0 evidence note). |
| Reading-quality capture | `LookCloselyTool` captures a sharp still and injects it into the active live session, with timeout and power/cooldown policy. **P0 rewrote the failure and decline copy**: it no longer permits answering the fine-detail question from the stream. | Establish that natural reading requests reliably invoke it and that delivered image detail survives the complete pipeline (PR4). |
| Audible state | **P0/PR2 done in code.** `AudibleLifecyclePolicy` + `AudibleLifecycleCoordinator` give session-usable, connection-lost, service-usable-again and requested-capture-succeeded a distinct earcon and a short spoken line, delivered through the app's own speech path with VoiceOver on or off; the recovery cue is evaluated from evidence rather than at callback time, and `SessionAnnouncementPolicy` now subtracts the transitions the cues own. | Nothing heard on hardware yet: glasses output with the phone pocketed, a queued cue distinguished from a heard one, and VoiceOver on a device are all owed (see the PR2 evidence note). |
| Session resilience | Gemini has coalesced bounded reconnects, ten-attempt limit, resumption handles and server-rotation handling. | Verify actual context continuity and usable microphone/frame recovery. Audio restart failure is logged in the reconnect callback; connection success alone is insufficient. Exhaustion ends the session. |
| Offline local vision | MLX local vision and capability guards exist; offline turn-loop/freshness/assembler tests exist. | BU explicitly leaves offline service device wiring pending. No automatic takeover exists in the inspected Gemini failure path. llama.cpp currently advertises no vision and rejects images; a downloaded text model is not a visual fallback. |
| Safety framing | **P0 done for the online paths.** `clear path` is gone from the navigation prompt and from every prompt this app composes; the shared safeguards reach Blind Assistant, navigation, reading, narration and the assistive-mode prompts. | The local/offline fallback prompts are PR6-7 work and do not compose the contract yet. |

### Evidence locations

- [Live presets](../../OpenGlasses/Sources/Models/LiveAIMode.swift), [navigation prompt](../../OpenGlasses/Sources/Services/Accessibility/NavigationAssistService.swift), [assistive routing](../../OpenGlasses/Sources/Services/Accessibility/AssistiveRouter.swift).
- [Action Button intent](../../OpenGlasses/Sources/App/Intents/ToggleGeminiLiveIntent.swift), [application wiring](../../OpenGlasses/Sources/App/OpenGlassesApp.swift), [media trigger plan and device caveats](CH-media-button-trigger.md).
- [Sharp capture tool](../../OpenGlasses/Sources/Services/NativeTools/LookCloselyTool.swift), [capture policy](../../OpenGlasses/Sources/Services/Live/LookCloselyPolicy.swift).
- [Announcement policy](../../OpenGlasses/Sources/Services/Accessibility/SessionAnnouncementPolicy.swift), [audio cues](../../OpenGlasses/Sources/Services/TextToSpeechService.swift).
- [Gemini session manager](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift), [socket recovery](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift), [resumption helpers](../../OpenGlasses/Sources/Services/GeminiLive/GeminiSessionResumption.swift).
- [Local MLX service](../../OpenGlasses/Sources/Services/LocalLLMService.swift), [llama.cpp backend](../../OpenGlasses/Sources/Services/LocalInference/LlamaCpp/LlamaCppLocalInferenceBackend.swift), [offline core tests](../../OpenGlassesTests/OfflineLiveSessionTests.swift).
- [Onboarding UI audit](../../OpenGlassesUITests/OnboardingAccessibilityTests.swift): stops before glasses registration; does not establish that the complete real setup is accessible. [DF](DF-app-accessibility.md) also explicitly leaves hardware VoiceOver and blind-user validation pending.

## P0 / PR1 — One blind-assistance contract

Extend existing prompt composition; avoid another mode or parallel assistant service.

- Share a blind-assistance instruction block across the selected live preset and relevant visual assistance paths, preserving each tool's output format.
- Default to one short useful observation, relevant observed hazards first; give more detail on request. Use clock positions and approximate distance only when supported by the image, otherwise say the position/distance is uncertain.
- Read requested text faithfully; distinguish exact transcription, partial text and interpretation. Never fill in unreadable medication names, quantities, dates or instructions.
- Remove `clear path` from navigation guidance. Prohibit assurances that movement/crossing is safe or that an unseen hazard is absent. Describe limited visual evidence and preserve cane/guide-dog framing.
- Exclude visual assumptions such as “as you can see.” Audit generic system instructions for conflicts with the selected preset.

Acceptance: prompt-composition tests across Gemini, OpenAI Realtime and local/direct paths that support the preset; evaluated image/transcript cases for stairs, partial labels, no visible obstacle, blurred text and requests for unsafe certainty. Static phrase checks alone are insufficient. Record model/version and observed outputs; no safety certification is implied.

### P0 / PR1 evidence note — implemented 2026-09-16

Build: worktree on `feat/ff-p0-blind-assistance-contract` from `1e33ceb6`, build 393. Debug
simulator build, the focused classes, the full `OpenGlassesTests` suite and a Release simulator
build all green on an iPhone 17 Pro simulator. No hardware run.

**Where the rules live.** `Services/Accessibility/BlindAssistanceContract.swift` holds seven
fragments — brevity and hazards first, spatial certainty, faithful reading, no safety assurance,
mobility-aid framing, no visual assumptions, format preserved — plus a lede, a heading, three named
subsets (environment / reading / spoken-output) and `applying(_:to:)`, which skips a fragment the
base prompt already carries. Nothing is copy-pasted; a path composes the subset that applies to it,
always emitted in the one canonical order.

**Which paths compose it, and in what order.**

| Path | Composition |
|---|---|
| Blind Assistant live preset | `promptPrefix` **is** the full contract (`presetPrefix`). No literal text in `LiveAIMode` any more. |
| Gemini Live | preset prefix → configured system prompt → precedence note → vision/tools/location/vault/visual-state/project/reading contexts → injection policy |
| OpenAI Realtime | preset prefix → configured system prompt → precedence note → vision → location |
| Navigation assist | mobility prompt (JSON contract intact) → environment fragments |
| Assistive scene | scene prompt + JSON contract → environment fragments |
| Assistive social | social prompt + JSON contract → spoken-output fragments |
| Scene narration | narration prompt → environment fragments minus `preserveFormat` |
| Reading (all five modes) | mode directive → reading fragments |

The two realtime backends share one pure seam, `composeLiveInstruction(modePrefix:basePrompt:modeID:)`,
which is what makes the order the same on both by construction rather than by review.

**The OpenAI preset gap, closed.** `OpenAIRealtimeSessionManager.buildSystemInstruction()` started
from `Config.systemPrompt` and applied no preset at all: `Config.activeLiveAIMode` was read in
exactly one place in the app, the Gemini manager. A wearer who selected Blind Assistant and happened
to be on that backend silently got the generic assistant. Both builders now go through the seam.

**Phrases removed.** `low = clear path` in the navigation prompt became
`low = no hazard observed in view`, followed by an explicit "seeing no hazard in one frame does not
establish that the way ahead is clear, empty or safe". The `look_closely` timeout and capture-failure
results, and the power-reserve and cooldown decline reasons, no longer tell the model to answer from
the streamed view and hedge — unreadable stays unreadable. The old preset wording ("describe the
environment in detail", "be specific about distances") is gone. A negative audit runs over every
composed prompt.

**Conflicts with the generic prompt, resolved by precedence.** `Config.defaultSystemPrompt` asks for
two-to-four-sentence answers and carries its own brevity guidelines; it is the user's, shared by
every preset and by Direct mode, so rewriting it to suit one preset would be the wrong repair.
Ordering settles most of it (the preset leads) and an explicit precedence note settles the rest.
`PromptInjectionPolicy.systemPromptPolicy` was audited and does not conflict — it governs untrusted
content, not response style or visual framing.

**Direct mode: decided.** Direct mode does **not** consume the live preset. `LiveAIMode` is a
realtime-session concept end to end, and teaching the Direct-mode builders to read it would hand a
wake-word turn the Golf Caddy and Museum Guide personas too. The contract reaches Direct mode
through the assistive services instead — navigation, narration, assistive mode, reading and
`look_closely` — all of which a Direct-mode wearer uses and all of which carry it unconditionally
rather than gated on a preset they never select. Both halves are pinned by tests.

**Response auditing.** `BlindAssistanceResponseAudit` is a pure classifier over a model answer:
`assertedSafety`, `assertedAbsenceOfHazard`, `inventedDetail`, `visualAssumption` and
`unhedgedDistance`. It reads the clause in front of an assurance so a refusal ("I can't tell you
whether it's safe to cross") is not confused with the assurance it refuses, and it accepts an
illegible detail only when hedged within the same clause. `Scenario.p0Fixtures` carries the five
cases this plan names — stairs, a partial medication label, no visible obstacle, blurred text, and a
request for a safety judgement — and lives in the app so a device harness can replay them.

**Still owed.** No live model output has been captured against this auditor. The device capture —
ask each fixture's `request` on real glasses under the Blind Assistant preset, record the model and
version and the spoken text, run it through `flags(for:transcript:)` — is PR1's remaining evidence
and should be recorded here. A clean audit means only that nothing this checker recognises went
wrong. No safety certification is implied by any of this.

## P0 / PR2 — Audible lifecycle that survives interruptions

Reuse TTS/earcons, `SessionAnnouncementPolicy` and existing speech/audio arbitration.

- Define distinct feedback for session usable, connection lost/retrying, service usable again, and successful requested photo capture. Offer a short cue-learning/help flow.
- Work with VoiceOver both enabled and disabled when Blind Assistant is selected; deduplicate speech and tones across transport, Bluetooth and UI events.
- A recovery cue requires restored audio and, for visual assistance, fresh visual evidence. Explicitly describe audio-only or camera-unavailable recovery.
- Queue/coalesce essential loss/recovery notices if speech occupies the route; expire obsolete notices so “disconnected” cannot play after successful recovery. Do not drop the only failure notice indefinitely.
- Make cue settings accessible. Announce requested capture success only after capture succeeds, not on button press or repeated background sampling.

Acceptance: injected transition sequences plus actual audio delivery checks for start, loss, retry, recovery, exhaustion, capture timeout, assistant speaking and VoiceOver speaking. Verify glasses output with the phone pocketed and distinguish a queued cue from a heard cue. Coordinate with FE's delivery feedback work.

### P0 / PR2 evidence note — implemented 2026-09-16

Build: worktree on `feat/ff-p1-audible-lifecycle`, stacked on the PR1 branch, build 394. Debug
simulator build, the focused classes, the full `OpenGlassesTests` suite (5826 tests, 13 skipped,
0 failures) and a Release simulator build all green on an iPhone 17 Pro simulator. No hardware run.

**The four feedbacks.** `Services/Accessibility/AudibleLifecyclePolicy.swift` is pure and holds the
whole decision; `AudibleLifecycleCoordinator.swift` holds the queue, the generation counter and the
injected clock. Each notice is one earcon plus — under the wearer's chosen style — one short line:

| Notice | Earcon | Line |
|---|---|---|
| Session usable | rising pair | "Ready. I'm listening." |
| Connection lost / retrying | falling pair | "Connection lost. Trying to get it back." |
| Service usable again | rising triad | "Back. I'm listening." |
| …audio back, camera not | rising triad | "Audio is back. The camera isn't — I can hear you, but I can't see." |
| Requested photo captured | short bright blip | "Photo taken." |
| Reconnected, microphone did not restart | low double | "Connected again, but the microphone didn't come back. Stop and start the session to try again." |
| Retries exhausted (terminal) | low double | "Connection lost. I couldn't get it back." |

The last two are not extra features; they are the two honest endings the same signals produce. The
degraded-reconnect line replaces a `PrivacyLog` entry that was previously the only response to an
audio restart that threw.

"Usable" is all three facts — audio session active, transport ready, microphone capture started —
not the socket alone; a connected session with a dead microphone says nothing rather than inviting
the wearer to talk into a void. The recovery shape is derived from evidence
(`RecoveryEvidence`: audio restored, whether the session needs to see, `CameraReadiness`'s fresh
visual evidence) and never from the callback's timing.

**Queue, coalesce, expire.** A notice arriving while speech occupies the route — the assistant
speaking, or an announcement this app posted to VoiceOver still in flight — is queued, not dropped
and not played over the top. Then:

* A recovery statement **expires a queued, never-delivered loss**, so "disconnected" cannot play
  after the connection came back. A loss *after* a delivered recovery is a new notice.
* A recovery whose loss was never heard is itself dropped when it is the plain "back, I'm listening"
  — the wearer experienced no interruption, so there is nothing to correct. A *degraded* recovery is
  said regardless, because a camera that is no longer usable is new information either way.
* Failure notices never go stale by time; notices about a moment do (capture 4 s, ready 10 s,
  recovery 20 s) and are dropped rather than played late.
* The only outstanding failure notice is never dropped: after a bounded 8 s wait it goes out even on
  a busy route, and the terminal exhaustion cue goes out with `interrupts: true` — the one notice
  allowed to take the floor.
* The queue is bounded at four and evicts by priority, so a backlog of capture cues can never push
  the failure out. A notice from a replaced session is dropped by generation.
* Cues are audible with VoiceOver **off**; with VoiceOver on, `AnnouncementContext.blindAssistantCuesActive`
  makes `SessionAnnouncementPolicy.hasOwnAudioCue` claim the live-session and reconnecting
  transitions, so the screen reader stops reading what the cues now say. The other transitions
  (camera, mic mute, errors) are untouched in both directions.

**Signals wired, per backend.** Both realtime managers gained one seam, `onLifecycle`, returning
whether the coordinator took responsibility — which is what lets each manager keep its existing
`speakLocalCue` for every wearer who has *not* selected Blind Assistant without two voices saying
the same thing.

| Signal | Gemini Live | OpenAI Realtime |
|---|---|---|
| Session usable | end of `startSession()`, connection state re-read | same, from `connectionState == .ready` |
| Connection lost, retrying | `reconnecting` false→true edge in the state poll | same edge on its own poll |
| Connection lost, terminal | `onDisconnected` where no retry is running, reported *before* the teardown | same |
| Reconnected | `onReconnected`, carrying whether `startCapture()` actually restarted | same |
| Retries exhausted | `onReconnectExhausted` | same |

**Not exposed by either backend**, and therefore not claimed: neither service reports *which* retry
attempt is running or how many remain, so the retry cue is one statement rather than a countdown;
neither reports the audio route separately from capture, so "audio session active" is inferred from
a capture that started without throwing; and neither has a post-setup "ready" callback distinct from
its polled `connectionState`. OpenAI Realtime has no resumption-handle concept, so its recovery
carries no claim about context continuity — that is PR5's to establish.

**Where the capture cue moved.** It did not move away from a button press, because there was none:
`look_closely` — the requested sharp capture a blind wearer's reading request goes through — had no
audible confirmation at all, and `capturePhotoFromGlasses` had only a haptic and a screen banner.
The cue is now fired from `LookCloselyTool` at the capture-succeeded boundary, after the timeout,
failure, power-reserve and cooldown paths have all already returned, and from
`capturePhotoFromGlasses` on success. The live session's periodic frame sampling is untouched and
silent. `capturePhotoSilently`'s existing tone is unchanged: it is one deliberate silent capture,
not repeated background sampling.

**Cue learning and settings.** Accessibility settings gained a **Session Sounds** section: a
"Play the Sounds" button that plays each earcon and then says what it means, and a
"Speak What Each Sound Means" toggle (on by default) selecting spoken lines or tones only — turning
the words off never makes an event silent. The tour runs whichever preset is selected, so a wearer
deciding *whether* to use Blind Assistant can hear what it will sound like first.

**Evidence.** 48 new headless tests: `AudibleLifecycleTests` (35) drives the coordinator through the
same `handle(_:)` the managers call, with a fake clock, a fake route and a recording tone/speech
sink, asserting the recorded order — start→usable, the two unusable start shapes, loss→recovery,
"disconnected" after recovery, a loss after a recovery, the recovery not decided at callback time,
the camera-unavailable variant, the audio-only variant, the degraded reconnect, exhaustion through a
busy route, exhaustion superseding a queued loss, the bounded wait, capture success, a stale capture
dropped, queue-then-deliver, an announcement in flight as a busy route, VoiceOver on and off,
the bound, priority order, generation expiry, the repeat window, tones-only, another preset left
alone, and the cue tour — plus `LookCloselyToolTests` (13, five new) pinning that the cue fires only
after a capture succeeds and on no decline, timeout or failure path.
`SessionAnnouncementTests` (16), `RealtimeReconnectTests` (19), `BlindAssistanceContractTests` (32)
and `CameraReadinessTests` (6) stay green unchanged.

**Owed — hardware.** Everything above is fixture-level. Three device checks remain and none can be
made in a simulator: **glasses output with the phone pocketed** (the cues must arrive in the ear,
through the same route the assistant's voice uses, with the screen off); **a queued cue distinguished
from a heard cue** (drop the network while the assistant is mid-answer and confirm the wearer hears
the loss cue only when the answer ends, or at the 8 s bound, and never after a recovery); and
**VoiceOver on hardware**, confirming the cue is heard with VoiceOver both on and off and that the
screen reader no longer reads the session transitions the cues now own. The 8 s bound, the 3 s
recovery-evidence window and the five tone contours are proposals until a wearer has heard them.

## P1 / PR3 — Complete the non-visual entry journey

- Add an explicit opt-in “Start Blind Assistant when I open the app” setting using the existing session activation owner. Gate on completed setup, permissions, provider readiness and user intent.
- Coalesce launch/shortcut/wake requests. User Stop cancels pending startup; ordinary foreground events must not repeatedly restart a stopped session.
- Validate existing Action Button and Siri paths first. Treat temple-tap support as experimental until CH's device gate passes. Audit the pinned DAT API before proposing capture-button handling; do not promise an unsupported hardware gesture.
- Extend DF coverage through actual registration, permission denial/retry, provider setup, mode selection, session start/stop and error recovery. Audit all controls encountered, focus order, state values and accessible alternatives to gestures.

Acceptance: a blind participant can complete supported setup and use the assistant without a sighted operator. Record any unavoidable OS/companion-app step, plus an accessible instruction for it. Test cold launch, repeated activation, cancellation during permission checks, lock/unlock and external audio coexistence.

### P1 / PR3 evidence note — implemented 2026-09-16

Build: worktree on `feat/ff-p3-entry-journey` from `6f485ba6`, build 397. Debug simulator build,
seven focused classes (135 tests, of which 45 are new), the full `OpenGlassesTests` suite
(5996 tests, 13 skipped, 0 failures) and a Release simulator build all green on an iPhone 17 Pro
simulator, plus one UI-test case run on the same simulator. No hardware run.

**The journey itself is [FF-entry-journey-audit.md](FF-entry-journey-audit.md)** — per step: the
controls encountered, focus order, what carries state, the accessible alternative to every gesture,
and the four steps that genuinely happen outside this app with the instruction each one gets. Read
that for the walk; this note records what changed in code.

**One activation owner.** Five entry points each carried their own copy of *switch mode, sleep
600 ms, start a session*: `ToggleGeminiLiveIntent`, `StartLiveAIModeIntent` and the three preset
shortcuts, `RunGlassesActionIntent`'s two paths, and the session capsule. The 600 ms was nobody's
measurement; two of those paths racing produced two sessions; and a wearer pressing Stop while one
was in flight got a session anyway a second later.

`LiveSessionActivator` (`Services/Flow/`) holds the sequence, over a `LiveSessionActivationOwner`
seam that `AppState` implements and a recording fake stands in for:

* **Coalescing** — a second request for the same mode awaits the first's outcome and returns it. A
  request for a *different* mode waits its turn rather than joining.
* **The sleep is gone** — replaced by awaiting `AppState.performModeSwitch(to:)`, the switch body
  extracted out of `switchMode(to:)`'s fire-and-forget `Task` so it can be awaited to completion.
  The only delay left is the audio handover on a deliberate restart (the preset shortcuts, whose
  purpose is to bring a running session back under a new preset), and it is now
  `ModeSwitchPolicy.settleDelay` rather than a second guess at the same number.
* **A stop cancels a pending start** — a stop generation is captured at the top of the activation
  and re-checked after every await, so a Stop during the permission wait, during the mode switch,
  or while `startSession` is still in flight leaves nothing running and nothing scheduled. The last
  case tears the half-started session back down rather than leaving it up.
* **The stop latch** — `stoppedByUserThisForeground` is set by a user stop and cleared only by an
  explicit request or by relaunching. Plan FF's name is kept; the cycle it actually spans is the
  app's lifetime, because clearing it on backgrounding would hand every return to the foreground a
  fresh restart, which is the repeat it exists to prevent. A session that ends on its own — retries
  exhausted, a teardown — does not latch, because the wearer did not ask for it to stay down.

**The launch decision.** `BlindAssistantLaunchPolicy` is pure and ordered: setting on → past
onboarding → Blind Assistant is the selected preset → no session already running → not stopped by
the wearer → not Silent Mode → microphone → speech recognition → provider key. Then a start, which
is **audio-only when the camera permission is off or the glasses never reported in**, and says which.

Speech recognition is required even though the live session streams raw audio and never touches
`SFSpeechRecognizer`: the wake word does, and the wake word is how a wearer reaches the app again
without looking at it. Starting a session the wearer has no non-visual way back to is worse than
declining and naming the permission.

Five of the nine skips are spoken, once each, through the app's own voice — not a VoiceOver
announcement, so they are heard with VoiceOver off as well. Four are deliberately silent: three
describe a state the wearer set seconds earlier (the setting is off, they stopped it, a session is
already running) and the fourth is Silent Mode, where speaking the reason would contradict the
setting being reported. All nine still carry a sentence for Settings to show, because a settings
screen that goes blank is the same dead end as a launch that goes quiet.

**Intent, twice.** The setting on its own does not start anything: Blind Assistant has to be the
selected live mode as well. A setting that quietly re-selected the preset would take a choice away
from a wearer who uses a different one, and the launch path is where a taken choice is hardest to
notice. Settings → Accessibility → **Opening the App** carries the switch, a live status sentence
computed from the same policy, a **"Use Blind Assistant as the Live Mode"** button when that is what
is in the way, and **"Open iOS Settings for OpenGlasses"** for the permissions.

**The one code gap the walk found.** iOS asks for a permission exactly once. After a refusal,
onboarding's row still rendered a "Grant" button that could never work again — and without sight, a
refusal and a tap that did not register are the same experience. The row now offers **"Open
Settings"** instead, seeded from the authorization status so a refusal from a previous run comes up
that way too, and the spoken refusal says which button replaced it. Nothing else in the walk needed
a code change: the controls it passes through were already named, grouped and announced by DF.

**DAT gestures, re-checked.** `MWDATCore`, `MWDATCamera` and `MWDATDisplay`'s pinned
`.swiftinterface` files contain zero occurrences of `gesture`, `captureButton`, `shutter`, `temple`,
`captouch`, `buttonPress` or `hardwareButton`. The only `onTap` (2, in `MWDATDisplay`) is on HUD
`Button` views this app renders. No capture-button handling is proposed, and CH's temple trigger
stays experimental and off by default with its device gate unpassed.

**Evidence.** 45 new headless tests. `BlindAssistantLaunchPolicyTests` (20) covers every input that
changes the decision, the reason names, the evaluation order, which reasons are spoken and the exact
lines. `LiveSessionActivatorTests` (25) drives a recording owner: cold launch → one start; two
concurrent requests → one start; launch plus an intent → one start; a Plan CF redial during the
switch → no second start; a stop during the permission wait, during the settle and during
`startSession` → no start and nothing left running; a foreground event after a user stop → no
restart, repeatedly; an explicit request after a stop → starts; an audio-only start → starts, with
its cue; a skip spoken once, a different skip still reported, a silent skip silent, a cancellation
silent; a teardown that is not the wearer's cancelling a pending start without latching; and the
restart path using the shared settle constant.
`ModeSwitchPolicyTests`, `AudibleLifecycleTests`, `ListenerHealthPolicyTests`,
`BlindAssistanceContractTests` and the intent tests stay green unchanged.
`SettingsAccessibilityTests` gained one case — the launch switch is named, turning it on reveals the
status sentence and the route to the iOS permission page, and the revealed section passes the
accessibility audit — run once on the simulator (59 s, 1 test, 0 failures).

**Owed.** The acceptance bar is a person, not a test: **a blind participant completing the supported
setup and using the assistant without a sighted operator.** With it, on device: cold launch,
repeated activation, cancellation during the permission checks, lock/unlock, and coexistence with
external audio; VoiceOver through the whole walk on hardware; and the audio-only cue heard through
the glasses with the phone pocketed. The headless tests assert the decisions. They cannot assert
what a wearer hears.

## P1 / PR4 — Make reading requests reliably obtain usable detail

- Reuse `look_closely` and existing reading tools; do not raise continuous streaming bandwidth globally.
- Ensure Blind Assistant routes “read this,” expiry dates, menus and label requests to a sharp capture when required. Evaluate existing model tool selection before adding deterministic intent routing.
- Verify image dimensions/quality after privacy filtering, capture, provider preparation and injection. Ensure one fresh still precedes the corresponding answer and stale captures cannot attach to a replacement session.
- On blur, darkness or timeout, speak a concise reposition/hold-steady instruction or partial transcription. Never infer missing digits from packaging context. Bound retries and retain power/privacy controls.

Acceptance: a fixed corpus of mail, small print, prices and synthetic medication labels, including blur/glare/occlusion; measure character/digit accuracy, capture success and end-of-question to first useful spoken text. Test capture failure and session replacement through production adapters. Proposed performance targets must be agreed after a baseline, before declaring the milestone complete.

## P1 / PR5 — Prove recovery through usable conversation

Extend the existing Gemini recovery implementation, coordinating with FD camera readiness and EW resource cleanup.

- Fault-inject socket loss, setup timeout, server rotation, expired resumption handle, audio-restart failure and missing/stale camera frames.
- Resume valid context; if resumption is unavailable, explicitly rebuild a bounded handover from existing conversation state. Do not replay side-effecting tool calls or pretend an interrupted answer completed.
- Verify stop during every retry phase cancels future work and old callbacks. Respect DAT pause semantics; no competing camera restart while paused.
- Treat socket, microphone and visual readiness as separate recovery facts. Surface degraded operation audibly rather than logging it as the only response.

Acceptance: recover from a short outage without user action and answer a context-dependent follow-up correctly, using current visual evidence. A long outage exits predictably into the offline policy below or an audible limitation. Measure recovery time and test repeated network flapping on real glasses.

## P2 / PR6–7 — Offline takeover, then field qualification

This is the largest gap. Extend BU/DW/DZ/FC rather than introducing a second local model manager.

1. Finish the production offline voice/vision loop behind actual model capability, locale/ASR, TTS, memory and foreground-execution readiness checks. Validate the currently available MLX VLM; do not select a model solely because a request mentions it. The text-only llama.cpp path cannot meet this requirement.
2. Add opt-in automatic handover from the existing cloud session owner. Announce the change, release/transfer audio and camera ownership once, retain a bounded context and cancel outstanding cloud speech/inference. Use a finite outage threshold; do not wait indefinitely for retries.
3. If the VLM is unavailable, use a verified on-device OCR/basic-perception tier where supported, with explicit capability limits. Missing assets or unsupported background execution must produce local feedback, not fabricated visual answers. No model download can be assumed possible after connectivity is lost.
4. Return to cloud only under the chosen user preference after a stable connection and at a turn boundary. Avoid oscillation, duplicate answers and replayed tools. Stop cancels both recovery and local work.
5. Qualify phone lock/background behaviour separately. Existing MLX guards constrain inference in the background, making the pocketed-phone offline promise a release blocker until a supported alternative is proven. Foreground-only offline support must be labelled as such.

Acceptance: airplane-mode scene question and text reading with assets preinstalled; absent/corrupt/text-only model; unsupported ASR locale; low memory; thermal pressure; lock/unlock; cloud loss during speech; network flapping; stop during handover. Trace permitted network activity to prove the fallback does not quietly call cloud services. Measure first spoken feedback, first useful answer, accuracy, battery and thermal behaviour per target phone.

## Delivery gates and order

| Gate | Exit evidence | Current status |
|---|---|---|
| A — Coherent online Blind Assistant | PR1–5 implemented; complete VoiceOver journey; heard lifecycle feedback; successful sharp reading and reconnect scenarios | Pending |
| B — Foreground offline continuity | Production offline loop and automatic handover; capability failures audible; airplane-mode evidence | Pending |
| C — Daily-use qualification | Blind-user sessions on target phones/glasses, pocketed/locked behaviour established, latency and power results, unresolved limitations published | Blocked on a supported background-inference path |

Gate C's pocketed-phone offline promise depends on the on-device MLX background constraint recorded in this repository — local inference cannot run backgrounded — so it is a release blocker to schedule early rather than a late qualification step.

Recommended order: PR1 → PR2 → PR3/PR4 → PR5 → PR6–7. Start the offline hardware feasibility check early because background execution may constrain Gate C. Gate A can ship independently with truthful offline limitations.

Existing work to reuse: DF accessibility, CH media trigger, BU offline session, DW offline perception, CV narration, DZ local runtime, FC local-model remediation, FD camera recovery, EW resource cleanup and FE voice delivery. This plan owns the complete blind-user acceptance journey, not duplicate implementations of those systems.

For each gate record build/commit, provider/model, phone/iOS, glasses/firmware/SDK, enabled settings, expected/observed outcome and remaining failures. Establish latency budgets from a baseline with blind participants; report p50/p95 end-of-question to first useful audio, rather than token throughput alone. Tests already present in the repository were inspected, not rerun for this plan.
