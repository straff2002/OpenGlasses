# Plan FF — Blind Assistant Readiness

**Status: 🚧 P0 PR1+PR2 and P1 PR3–PR5 (headless parts) implemented 2026-09-16 — one shared blind-assistance contract composed across the live preset, both realtime backends and the assistive services; an audible session lifecycle (four earcons plus short spoken lines) that queues, coalesces and expires its notices so a cue is true at the moment it is heard; one activation owner behind every live-session entry, with an opt-in start-on-launch that says out loud why it did not start; every requested sharp capture filtered, measured and identity-checked before it can reach the model, with a bounded retry, honest degraded copy and a recorded synthetic baseline; and a recovery that is proven as *usable conversation* — six faults injected at the socket's own handlers, four independent recovery facts (socket, microphone, visual evidence, and whether the conversation's thread survived), a bounded locally-rebuilt handover when the server will not resume, a stop that cancels every retry phase, and a paused camera that is never started into. PR6–PR7 unbuilt. Gate A's remaining exit evidence is a device and blind-participant matter, not code: heard cues through the glasses with the phone pocketed, live model outputs against the response audit, the on-device reading measurement, recovery time and repeated flapping on real glasses, and a blind participant completing setup and use without a sighted operator. Gate C stays blocked on a supported background-inference path — on-device MLX cannot run backgrounded, so the pocketed-phone offline promise has no supported implementation today. **PR8 (readiness walk-through + processing summary) built 2026-09-17** — five checks in order, each with one spoken status, one next instruction and a retry, where a connected SDK, a running stream and a `true` flag all fail the camera step because none of them is a picture; and a five-row account of where each part of a request goes that names a mixed setup as mixed, refuses "fully on-device" to any setup whose local assets are not downloaded, and reduces a configured endpoint to its host. Its participant runs are owed. Participant-led task acceptance added to Gate A.**

Origin: a blind-user readiness request naming seven areas — non-visual activation, a blind-user prompt, reading-quality capture, audible state, session resilience, offline local vision and safety framing.
Baseline: OpenGlasses working tree at `4573210f`, including existing local changes. Existing plan status is context, not proof of current device behaviour.

## Assessment

**Priority update — 2026-09-16:** a first-person account from a blind business owner of building an accessible
API interface
reinforces task-based, participant-led validation. A public discussion of alternatives to the stock assistant on these glasses
also surfaces setup and processing-choice questions. These are qualitative signals, not a user study
or evidence that our implementation works. Prioritise usable setup, reading and recovery over new
presets. The requirements below are pending; this update does not advance delivery status.


We are substantially closer than a developer demo: six of the seven requested areas have relevant implementation. That is architectural coverage, not six completed requirements. Automatic cloud-to-offline visual conversation is the largest missing capability. Prompt consistency, audible recovery and independent end-to-end use are the immediate gaps.

The online experience looks close enough for a focused hardening and user-validation milestone. Daily-use offline reliability is a separate, larger milestone. A numerical completion percentage would hide the difference between an implemented policy and a proven pocketed-phone experience.

## Requirement-to-code map

| Requested area | Current evidence | Remaining gap |
|---|---|---|
| Non-visual activation | **P1/PR3 done in code.** `LiveSessionActivator` is the one owner behind launch, foreground, the Action Button, every Siri shortcut and the app's own control; `BlindAssistantLaunchPolicy` decides the opt-in start-on-launch and names the nine ways it declines. VoiceOver semantics and UI audits exist, and the non-visual journey is walked in [FF-entry-journey-audit.md](FF-entry-journey-audit.md). | A blind participant completing setup and use without a sighted operator — the acceptance bar — and the device checks listed in the PR3 evidence note. Temple media trigger stays experimental; the pinned DAT SDK exposes no gesture or capture-button API (re-checked, see the audit). |
| Blind-user prompt | **P0 done.** `BlindAssistanceContract` holds the rules once; the Blind Assistant preset prefix is composed from it, both realtime backends apply the preset through one seam, and navigation, narration, assistive-mode and reading compose the fragments that apply to them. | Live model outputs still to be captured against `BlindAssistanceResponseAudit` on device (see the P0 evidence note). |
| Reading-quality capture | **P1/PR4 done in code.** The capture goes through the privacy chokepoint under the live-session scope, is measured into a `CaptureQualityReport` (both pixel sizes, bytes, sharpness, luma, camera and session identity), and is refused rather than injected when it predates the request or belongs to a replaced session or camera. Blur and darkness get one automatic re-capture and then a reposition or light instruction, or a confidence-floored partial transcription. The tool description now names the wearer's own phrases, composed from `ReadingRequestClassifier`; the routing audit is in [FF-reading-routing.md](FF-reading-routing.md). | Glare and occlusion are **not** detected by the quality gate and are injected as usable (see the PR4 baseline table). No on-device measurement: real mail and labels through the production adapters, and whether the model actually calls the tool on a spoken "read this". Targets are agreed after that baseline. |
| Audible state | **P0/PR2 done in code.** `AudibleLifecyclePolicy` + `AudibleLifecycleCoordinator` give session-usable, connection-lost, service-usable-again and requested-capture-succeeded a distinct earcon and a short spoken line, delivered through the app's own speech path with VoiceOver on or off; the recovery cue is evaluated from evidence rather than at callback time, and `SessionAnnouncementPolicy` now subtracts the transitions the cues own. | Nothing heard on hardware yet: glasses output with the phone pocketed, a queued cue distinguished from a heard one, and VoiceOver on a device are all owed (see the PR2 evidence note). |
| Session resilience | **P1/PR5 done in code.** Six faults are injected at the socket's own named handlers — loss mid-turn, setup timeout, server rotation, a refused resumption handle, an audio restart that throws, and frames missing after the reconnect — and each produces a step of the existing ladder. `LiveRecoveryAssessment` keeps socket, microphone, visual evidence and conversation continuity as four separate facts; `LiveContextHandover` rebuilds a bounded six-turn handover when the server will not resume, marking an interrupted answer as never delivered and an in-flight side-effecting call as outcome-unknown rather than re-issuing it; a stop during backoff, setup, handover assembly or capture restart cancels the rest; and `LiveRecoveryCameraPolicy` cannot express a start into a paused stream. | Recovery time end to end, repeated network flapping and a real server rotation, all on glasses; and the acceptance sentence itself — a follow-up answered correctly *by the model* from the rebuilt block (see the PR5 evidence note). |
| Offline local vision | MLX local vision and capability guards exist; offline turn-loop/freshness/assembler tests exist. | BU explicitly leaves offline service device wiring pending. No automatic takeover exists in the inspected Gemini failure path. llama.cpp currently advertises no vision and rejects images; a downloaded text model is not a visual fallback. |
| Safety framing | **P0 done for the online paths.** `clear path` is gone from the navigation prompt and from every prompt this app composes; the shared safeguards reach Blind Assistant, navigation, reading, narration and the assistive-mode prompts. | The local/offline fallback prompts are PR6-7 work and do not compose the contract yet. |

### Evidence locations

- [Live presets](../../OpenGlasses/Sources/Models/LiveAIMode.swift), [navigation prompt](../../OpenGlasses/Sources/Services/Accessibility/NavigationAssistService.swift), [assistive routing](../../OpenGlasses/Sources/Services/Accessibility/AssistiveRouter.swift).
- [Action Button intent](../../OpenGlasses/Sources/App/Intents/ToggleGeminiLiveIntent.swift), [application wiring](../../OpenGlasses/Sources/App/OpenGlassesApp.swift), [media trigger plan and device caveats](CH-media-button-trigger.md).
- [Sharp capture tool](../../OpenGlasses/Sources/Services/NativeTools/LookCloselyTool.swift), [capture policy](../../OpenGlasses/Sources/Services/Live/LookCloselyPolicy.swift), [quality report](../../OpenGlasses/Sources/Services/Vision/CaptureQualityReport.swift), [filtered sharp capture](../../OpenGlasses/Sources/Services/Vision/SharpStillCapture.swift), [degraded outcomes](../../OpenGlasses/Sources/Services/Live/ReadingCaptureOutcome.swift), [reading-request predicate](../../OpenGlasses/Sources/Services/Accessibility/ReadingRequestClassifier.swift).
- [Announcement policy](../../OpenGlasses/Sources/Services/Accessibility/SessionAnnouncementPolicy.swift), [audio cues](../../OpenGlasses/Sources/Services/TextToSpeechService.swift).
- [Gemini session manager](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift), [socket recovery](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift), [resumption helpers](../../OpenGlasses/Sources/Services/GeminiLive/GeminiSessionResumption.swift), [fault vocabulary](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveFaultInjector.swift).
- [Recovery facts](../../OpenGlasses/Sources/Services/Live/LiveRecoveryAssessment.swift), [reconnect decisions](../../OpenGlasses/Sources/Services/Live/LiveRecoveryDriver.swift), [bounded handover](../../OpenGlasses/Sources/Services/Live/LiveContextHandover.swift), [the local record](../../OpenGlasses/Sources/Services/Live/LiveConversationRecorder.swift), [the reconnect pause rule](../../OpenGlasses/Sources/Services/Live/LiveRecoveryCameraPolicy.swift).
- [Local MLX service](../../OpenGlasses/Sources/Services/LocalLLMService.swift), [llama.cpp backend](../../OpenGlasses/Sources/Services/LocalInference/LlamaCpp/LlamaCppLocalInferenceBackend.swift), [offline core tests](../../OpenGlassesTests/OfflineLiveSessionTests.swift).
- [Onboarding UI audit](../../OpenGlassesUITests/OnboardingAccessibilityTests.swift): stops before glasses registration; does not establish that the complete real setup is accessible. [DF](DF-app-accessibility.md) also explicitly leaves hardware VoiceOver and blind-user validation pending.

## P0 / PR1 — One blind-assistance contract

Extend existing prompt composition; avoid another mode or parallel assistant service.

- Share a blind-assistance instruction block across the selected live preset and relevant visual assistance paths, preserving each tool's output format.
- Default to one short useful observation, relevant observed hazards first; give more detail on request. Use clock positions and approximate distance only when supported by the image, otherwise say the position/distance is uncertain.
- Read requested text faithfully; distinguish exact transcription, partial text and interpretation. Never fill in unreadable medication names, quantities, dates or instructions.
- Remove `clear path` from navigation guidance. Prohibit assurances that movement/crossing is safe or that an unseen hazard is absent. Describe limited visual evidence and preserve cane/guide-dog framing.
- Exclude visual assumptions such as “as you can see.” Audit generic system instructions for conflicts with the selected preset.
- Support progressive detail: give the requested answer first, then offer more. For tables and
  structured results, provide an overview and navigable rows/items by voice rather than reading a
  whole table unprompted. Support repeat, next, back and stop without losing the selected item.

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
- Add a guided readiness walk-through by extending PR3's `BlindAssistantLaunchPolicy`/`LiveSessionActivator` (they already decide registration → permissions → provider → glasses with a spoken reason): the walk-through adds fresh camera evidence and microphone/spoken-output steps, one spoken status, an accessible retry and one next instruction per step. Steps: registration → permissions → fresh camera
  evidence → microphone/spoken output → first useful reading request. Each step has a spoken status,
  accessible retry and one next instruction. A connected SDK or socket alone does not pass the check.
- Extend the existing settings/network surfaces with an accessible processing summary: image,
  transcription, AI response, spoken voice and enabled remote tools, each showing its configured
  destination. Identify mixed local/cloud setups and missing downloaded assets before promising
  offline use. Settings describe intended routing; observed requests are separate evidence, and
  the network monitor is not a complete packet audit. Recompute after provider/engine changes.
- Keep installation and companion-app steps in the tested journey. Publish the actual distribution
  route and prerequisites; do not assume access to a Mac, a sighted helper or a public beta invitation.
  Installation support and an independently completed install are recorded separately.
Also verify focus after errors, permission returns and completed actions; announce status without
re-reading the entire screen or competing with VoiceOver. Test the processing summary with local AI
plus cloud speech, cloud AI plus local speech, unavailable assets and a provider change. It must not
label any of those mixed configurations “fully local”.


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

### P1 / PR4 evidence note — headless part implemented 2026-09-16

Build: worktree on `feat/ff-p4-reading-detail` from `c1db0f67`, build 400. Debug simulator build,
the ten focused classes (146 executed), the full `OpenGlassesTests` suite (6076 executed, 0
failures, 13 skipped) and a Release simulator build all green on an iPhone 17 Pro simulator. No
hardware run, no live model output.

**The routing audit is its own document**, [FF-reading-routing.md](FF-reading-routing.md): the five
findings, the deterministic assist that was chosen, and the three that were rejected with reasons.
In short — nothing in the app decided whether a request was a reading request; `look_closely`'s
description named receipt line items and gauge markings and none of the phrases a wearer actually
says; its no-session fallback pointed at `read_text`, a tool that does not exist; `reading_assist`
is registered only under the accessibility-mode gate; and Direct mode's Tier 0 has no reading route
and should not get one here. The assist chosen is the smallest that the audit justifies:
`ReadingRequestClassifier`, a pure predicate whose `triggerPhrases` **compose** the tool description,
so the phrases the model is shown and the phrases the app recognises cannot drift; the same
predicate picks between two guidance lines and decides whether a failed capture is worth an
on-device recognition pass. No new router, no pre-capture, no new contract fragment, no change to
streaming bandwidth. Pre-capturing before the turn is the reliable version and is recorded as PR5/PR6
work, because it means owning the live turn boundary that PR5's reconnect work also edits.

**A privacy correction came out of the pipeline verification.** `look_closely` captured through
`CameraService.capturePhoto()` — the unfiltered accessor, which is the wearer's own framed shot by
product decision — and pushed the pixels into a cloud realtime session. It now goes through
`filteredStill(for:source:)` under `PrivacyFilterScope.liveSession`, the scope the streamed frames
beside it already travel under, and a scope that cannot be filtered yields `.unavailable` rather
than the source pixels. The roster scraper could not have caught it: `NativeToolRegistry` contained
`capturePhoto()`, but the sink it fed — `injectSharpImage` — was not one of the six patterns the
sink test knew. That pattern is added, and `SharpStillCapture` is on the roster as
`lookCloselyCapture`.

**The quality report.** `CaptureQualityReport` is produced at the capture boundary and carries the
pixel size before the privacy filter and after it, the encoded JPEG byte count, Laplacian sharpness
(`ImageSharpness`, reused), mean luma (`ImageBrightness`, new, the darkness half of the same pair),
the privacy scope, the camera session, the live session and the moment of capture. `sendHighResImage`
was checked on both wires: it neither resizes nor re-encodes — it base64s the bytes as given — so
the delivered size is the encoded still's own and the byte count is the wire payload.

**The freshness and identity guard, asserted in code.** Injection goes through one function, and it
re-reads the world *after* the capture rather than trusting what it read before: pixels older than
the request, a live session whose identity has moved (a reconnect inside the capture window, with
`canInject` true again for a different conversation), a camera session that has been replaced, or an
injector that has gone — each is refused, and each reports `noFreshView`, the existing name for
"there is a picture and it is not a current view". `LiveSessionInjecting` gained
`liveSessionIdentity` for this; both realtime managers bump it on every start. One request injects
at most one image.

**Degraded outcomes and their thresholds.** Darkness is checked before blur, because an underexposed
frame also scores low on the Laplacian and would otherwise send a wearer to hold still in a dark
room. Blur threshold 55, derived *below* `ImageSharpness.blurThreshold` (90): the existing number is
tuned for "should I suggest holding steady when OCR found nothing", where a false positive is a
nagging message, and here a false positive costs a whole extra capture and several seconds. Darkness
threshold 0.18 mean luma, taken unchanged from `ImageBrightness` — roughly a stop and a half under a
dim indoor scene, low enough that a badly-lit-but-readable label is never blamed on the light.
Exactly one automatic re-capture; the retry re-checks power posture, so it is a request rather than a
bypass, and the cooldown deliberately does not gate it because nothing was injected. The cooldown
clock moved from "last capture" to "last *injected* capture", which is what its own decline text
already claimed.

The instruction, the partial transcription and the unavailable copy are all directives to the model
in the shape PR1 established — the one sentence to say, then "the detail is still unread", then
never guess. The live model holds the audio floor during a session, so this is how a spoken
instruction reaches the wearer; a second app voice speaking over the model is a PR5 concern. A
partial transcription only carries blocks at or above 0.5 Vision confidence — above `OCRService`'s
own 0.3 floor, because this text is read aloud verbatim to someone who cannot check it.

**Baseline — simulator, synthetic corpus, no thresholds set.** Four invented documents (a council
rates notice, a block of small print, a shelf price tag, and a medication-style label with a made-up
name, dose and lot) rendered with Core Graphics in
`OpenGlassesTests/Fixtures/ReadingCorpus/reading-corpus.json`, each in four conditions: clear,
Gaussian blur at an eighth of the cap height, a hard glare band over the middle 40%, and the left 34%
occluded. Real `OCRService` over all sixteen; capture success through `look_closely` itself with a
fake camera; time from request to tool result through the tool's injected clock.

| document | variant | char acc | digit acc | bytes | sharpness | luma | verdict | tool outcome |
|---|---|---|---|---|---|---|---|---|
| mail | clear | 1.000 | 1.000 | 54359 | 4593 | 0.981 | usable | read-from-image |
| mail | blurred | 0.932 | 1.000 | 25363 | 11 | 0.990 | tooBlurry | partial transcription |
| mail | glared | 0.699 | 0.538 | 37609 | 2191 | 0.990 | usable | read-from-image |
| mail | occluded | 0.204 | 0.385 | 25289 | 1182 | 0.741 | usable | read-from-image |
| small print | clear | 1.000 | 1.000 | 42856 | 1161 | 0.992 | usable | read-from-image |
| small print | blurred | 0.993 | 1.000 | 20874 | 26 | 0.995 | tooBlurry | partial transcription |
| small print | glared | 0.324 | 0.500 | 18373 | 15 | 1.000 | tooBlurry | partial transcription |
| small print | occluded | 0.131 | 0.000 | 20555 | 336 | 0.744 | usable | read-from-image |
| price tag | clear | 1.000 | 1.000 | 40219 | 4766 | 0.964 | usable | read-from-image |
| price tag | blurred | 0.000 | 0.000 | 15177 | 3 | 0.981 | tooBlurry | reposition |
| price tag | glared | 0.868 | 0.545 | 29696 | 2829 | 0.977 | usable | read-from-image |
| price tag | occluded | 0.289 | 0.273 | 19953 | 1621 | 0.736 | usable | read-from-image |
| medication-style | clear | 1.000 | 1.000 | 41326 | 4547 | 0.982 | usable | read-from-image |
| medication-style | blurred | 0.607 | 0.923 | 19276 | 5 | 0.991 | tooBlurry | partial transcription |
| medication-style | glared | 0.643 | 0.538 | 26352 | 1762 | 0.992 | usable | read-from-image |
| medication-style | occluded | 0.125 | 0.000 | 18622 | 856 | 0.743 | usable | read-from-image |

Capture success through the tool: 15 of 16 variants reached the model's view; the sixteenth spent its
one retry and returned a partial transcription. Request to tool result, in process: 11–17 ms when the
first capture is usable, 488–1606 ms when it is not (a second capture plus the on-device recognition
pass). That excludes everything this harness cannot see — the glasses shutter, the Bluetooth or Wi-Fi
transfer, the model's own latency and its speech — so it is a floor, not an end-to-end figure. No
targets are set: the plan agrees them after a baseline with blind participants, and this is a
simulator measuring clean synthetic renders, which bounds the pipeline from above.

**The two gaps the table shows, stated rather than buried.** Blur and darkness are caught; **glare
and occlusion are not**. Three of the four glared variants and all four occluded variants score
`usable` on sharpness and luma and are injected, at character accuracies as low as 0.125 and digit
accuracies of 0.000. Sharpness and luma are global statistics and cannot see a bright band or a thumb
over the left margin. What stands between that and a wrong answer today is the PR1 faithful-reading
contract — the model reads what it can see and says the reading is partial — which is prompt content
and not a guarantee. A detector for either is not in PR4 and is not implied by it. Second: a partial
transcription of a glared still can be confidently wrong, because Vision's own confidence is the only
signal available to the 0.5 floor.

**Still owed.** The on-device measurement: real mail, real small print and real labels photographed
through the glasses at reading distance, through the production adapters, against the same metrics;
a session per trigger phrase under the Blind Assistant preset, recording the model and version and
whether `look_closely` actually fired; and the end-of-question to first-spoken-word figure a wearer
experiences, which this harness cannot produce. Performance targets are agreed after that, not
before.

## P1 / PR5 — Prove recovery through usable conversation

Extend the existing Gemini recovery implementation, coordinating with FD camera readiness and EW resource cleanup.

- Fault-inject socket loss, setup timeout, server rotation, expired resumption handle, audio-restart failure and missing/stale camera frames.
- Resume valid context; if resumption is unavailable, explicitly rebuild a bounded handover from existing conversation state. Do not replay side-effecting tool calls or pretend an interrupted answer completed.
- Verify stop during every retry phase cancels future work and old callbacks. Respect DAT pause semantics; no competing camera restart while paused.
- Treat socket, microphone and visual readiness as separate recovery facts. Surface degraded operation audibly rather than logging it as the only response.

Acceptance: recover from a short outage without user action and answer a context-dependent follow-up correctly, using current visual evidence. A long outage exits predictably into the offline policy below or an audible limitation. Measure recovery time and test repeated network flapping on real glasses.

### P1 / PR5 evidence note — headless part implemented 2026-09-16

Build: worktree on `feat/ff-p5-recovery-conversation`, stacked on the PR4 branch, build 401. Debug
simulator build, twelve focused classes, the full `OpenGlassesTests` suite and a Release simulator
build all green on an iPhone 17 Pro simulator. No hardware run, no real network loss, no glasses.

**Where the faults are injected, and why there.** The recovery ladder this phase has to prove —
coalesced reconnects, capped backoff, the ten-attempt limit, resumption handles, the server's own
rotation — lives inside `GeminiLiveService`, wired to `URLSessionWebSocketTask` through three
delegate closures and one timeout task. Replacing the socket wholesale would mean a second transport
whose agreement with the real one is itself unproven. So the close, the error, the connect timeout
and the `goAway` each became a named method, and `injectFaultForTesting(_:)` calls those same
methods: everything downstream is the production path, unaware it was not a socket that spoke. The
two faults that are about an attempt *failing to come up* rather than a connection dying are scripted
instead (`ScriptedConnectOutcome`), and a `holdAtSetupForTesting` hook parks an attempt at the setup
boundary so a stop can be landed there deterministically rather than raced into place.

| Injected fault | Observed path |
|---|---|
| Socket loss mid-turn | `onDisconnected` once → one scheduled reconnect → `reconnecting`, attempt 1. Close + error + receive-loop for the same failure still coalesce to one attempt. |
| Setup timeout | The attempt resolves false with no close and no error event; `connectionState` is `Connection timed out`; the reconnect task drives the next attempt itself. |
| Server rotation (`goAway` then close) | Announcement schedules the reconnect, the close coalesces into it — one attempt, session not torn down. This is not an edge case: the server rotates every long conversation. |
| Expired / rejected resumption handle | Setup went out carrying the handle and the attempt did not come up → the handle is **dropped**, `lastResumptionHandleRejected` set, the next attempt cold-starts, and continuity is not `resumed`. |
| Audio-restart failure on reconnect | `recoveryIncomplete` — the microphone fact is false while the socket fact is true, and the wearer is told which. |
| Camera frames missing / stale after reconnect | Driven through FD P0's readiness snapshot: no fresh visual evidence inside the bounded window → `serviceRestored(.cameraUnavailable)`. |

**One production rule came out of the handle fault.** The wire cannot tell "your handle is stale"
from "the socket died after setup", so the app does not claim to either — it acts on the only reading
that is safe for both. A handle the server will not take, retried, walks the entire ten-attempt
ladder to exhaustion and ends a session a cold start would have recovered on the first attempt. The
handle is therefore dropped on any failure of an attempt that *sent setup*, and kept when the attempt
never opened a socket, because then nothing was offered and nothing was refused.

**Four facts, not one.** `LiveRecoveryAssessment` carries socket-ready, microphone-restored,
visual-evidence-fresh and `contextContinuity: .resumed | .rebuilt(turns:) | .lost`, each assertable on
its own. Continuity is derived in one place: the server resuming makes the local record irrelevant;
otherwise a handover with turns is `rebuilt` and a handover with none is `lost` — "the last thing we
were on was …" may only be said when there is a last thing. `AudibleLifecyclePolicy.RecoveryShape`
gained the two cases that follow (`contextLost`, `cameraUnavailableAndContextLost`), built from the
two facts by `make(cameraUsable:contextCarried:)` so the four cannot be assembled inconsistently, and
`RecoveryEvidence` gained `contextCarried` — defaulting to `true`, because the OpenAI Realtime wire
has no resumption concept and must claim nothing about context rather than guess. No existing
assertion had to change: nothing in the suite pinned "recovery = socket up".

**The record a handover is rebuilt from did not exist.** Live turns are persisted nowhere — not in
`ConversationStore`, not in `LLMService.conversationHistory`. Both realtime managers keep two strings
cleared at each turn boundary, read by two transcript views. So `LiveConversationRecorder` records the
minimum, and its privacy posture is stated rather than implied: **in memory only** (never a file,
never a thread, never a log — `PrivacyLog` keeps counts, not speech), bounded to twelve turns, each
clipped to 300 characters when carried, and reset both when a session starts and when it stops, so
ending a session is the same act as forgetting it.

**The handover.** `LiveContextHandover` is pure and builds a block headed
`RECOVERED CONVERSATION CONTEXT:` from the last **six** turns — roughly three exchanges, enough that
"and the other one?" has a referent. It is composed into the new session's system instruction
alongside the other injected contexts, after PR1's preset prefix and precedence note, so it rides in
the *setup message* rather than being injected into a conversation that has already started without
it. Three rules make it safe:

* **An interrupted answer is marked interrupted** — "the connection dropped before you finished. They
  may have heard none of it. Do not treat this answer as delivered." An answer cut off by the loss, or
  spoken over by the wearer, is never handed back as delivered.
* **A side-effecting tool call in flight is named and never re-issued** — names only, no arguments,
  no call: "the outcome is unknown: 'send_via'. Do NOT run it again." Read-only tools are excluded
  (repeating a lookup changes nothing), and the journal read is bounded to this session, because
  `OperationJournal` is durable and carries rows recovered from a process that died days ago.
* **The block closes by forbidding a replay of anything in it**, and tells the model to say it lost
  the thread rather than invent what is missing.

**Stop, in every phase.** The service's `disconnect()` already advanced a generation gate; it now also
disarms the reconnect work, and the reconnect task re-checks cancellation and the deliberate-disconnect
flag after `connect()` returns, so a superseded attempt cannot publish a ready state or fire
`onReconnected` over the stop. `LiveRecoveryDriver` holds the manager's own stop generation, captured
at the top and re-checked after the handover assembly, the reconfigure, the microphone restart and the
camera start — each of the four is covered by a test that stops the session *inside* that step and
asserts nothing further ran and nothing was claimed. `GeminiLiveService.scheduledWorkCount` (the shape
EW's camera backend uses) makes "nothing is left scheduled" an assertion rather than a reading of the
teardown.

**The pause rule, made structural.** `LiveRecoveryCameraPolicy` is the only way the reconnect path can
reach a camera start, and it has no case that starts into a `.paused` stream — FD P1's rule, enforced
by shape rather than remembered. A paused camera at reconnect issues no start, the SDK is left to move
the stream, and the wearer hears the camera-unavailable line. The same policy closed a real gap in the
other direction: a session whose camera was `.stopped` while streaming was still wanted now gets one
start on reconnect, where before it never retried.

**After exhaustion.** There is no offline hand-off point to exit into — BU's offline loop has no
takeover from a cloud session, and PR6 owns building one. So exhaustion ends where PR2 left it: one
terminal `recoveryFailed` cue, allowed to take the floor, superseding a queued "trying to get it
back", with the retry work disarmed *before* the cue goes out so the statement is true at the moment
it is heard. The test asserts one cue for ten failed attempts and `scheduledWorkCount == 0` after it.

**New user-visible strings** — two, both spoken lines on the existing cue path:
"Connected again, but I lost the thread of our conversation. You may need to tell me again." and
"Connected again. I can't see, and I lost the thread of our conversation." The handover block itself
is a directive to the model, not something a wearer sees or hears.

**Still owed — on glasses.** Everything above is fixture-level and the acceptance bar is not.
**Recovery time** end to end — the wearer's last word before the drop to the first usable word after
it — cannot be produced by this harness, which measures a ladder with no network in it. **Repeated
network flapping on real glasses**: loss, recovery, loss inside one conversation, confirming one
notice per episode through the glasses route with the phone pocketed rather than through a recorded
sink. **A real `goAway` rotation** on a conversation long enough to meet one, confirming the wearer
notices nothing. And the acceptance sentence itself: a short outage, no user action, and a
context-dependent follow-up answered correctly *by the model* from the rebuilt block — this proves the
block is assembled and delivered, not that a model uses it well. Whether six turns is the right number,
and whether the two new lines are the right words, are proposals until a wearer has heard them.

## P2 / PR6–7 — Offline takeover, then field qualification

This is the largest gap. Extend BU/DW/DZ/FC rather than introducing a second local model manager.

1. Finish the production offline voice/vision loop behind actual model capability, locale/ASR, TTS, memory and foreground-execution readiness checks. Validate the currently available MLX VLM; do not select a model solely because a request mentions it. The text-only llama.cpp path cannot meet this requirement.
2. Add opt-in automatic handover from the existing cloud session owner. Announce the change, release/transfer audio and camera ownership once, retain a bounded context and cancel outstanding cloud speech/inference. Use a finite outage threshold; do not wait indefinitely for retries.
3. If the VLM is unavailable, use a verified on-device OCR/basic-perception tier where supported, with explicit capability limits. Missing assets or unsupported background execution must produce local feedback, not fabricated visual answers. No model download can be assumed possible after connectivity is lost.
4. Return to cloud only under the chosen user preference after a stable connection and at a turn boundary. Avoid oscillation, duplicate answers and replayed tools. Stop cancels both recovery and local work.
5. Qualify phone lock/background behaviour separately. Existing MLX guards constrain inference in the background, making the pocketed-phone offline promise a release blocker until a supported alternative is proven. Foreground-only offline support must be labelled as such.

Acceptance: airplane-mode scene question and text reading with assets preinstalled; absent/corrupt/text-only model; unsupported ASR locale; low memory; thermal pressure; lock/unlock; cloud loss during speech; network flapping; stop during handover. Trace permitted network activity to prove the fallback does not quietly call cloud services. Measure first spoken feedback, first useful answer, accuracy, battery and thermal behaviour per target phone.

## P1 / PR8 — Readiness walk-through and processing summary

**Status: 🚧 Implemented 2026-09-17 — the walk-through, the processing summary and both UI surfaces are built and covered headlessly; the participant runs below are owed and are what close the phase.**

- Readiness walk-through: extend PR3's `BlindAssistantLaunchPolicy` and `LiveSessionActivator` into a guided sequence — registration → permissions → fresh camera evidence (FD's `CameraReadiness`) → microphone and spoken output (FE P2 listener health, FE P4 delivery outcome) → first useful reading request (PR4's capture quality report). Each step has one spoken status, an accessible retry and one next instruction; a connected SDK or socket alone never passes a step. No second onboarding owner.
- Processing summary: one accessible screen and one spoken summary naming, for image, transcription, AI response, spoken voice and enabled remote tools, the configured destination (on device / which provider / which endpoint). Recomputed on every provider or engine change. It describes intended routing; the existing network monitor is separate observed evidence and is not a packet audit. A mixed configuration is named as mixed and never labelled fully local; missing downloaded assets are named before any offline promise.
- Installation path: the tested journey starts at the App Store listing and includes the companion-app steps recorded in `FF-entry-journey-audit.md`; prerequisites are published, and independent installation is recorded separately from assisted installation.

Acceptance: fake-owner tests drive every walk-through step to pass, fail and retry with the spoken status asserted; processing-summary fixtures cover local AI + cloud speech, cloud AI + local speech, unavailable assets and a provider change, none of which may read as fully local; VoiceOver focus lands on the step status after each result. Participant runs (below) close the phase, not the fixtures.

### P1 / PR8 evidence note — implemented 2026-09-17

Build: worktree on `feat/ff-p8-readiness-summary` from `c16e908c`, build 404. Debug simulator
build, the focused classes, the full `OpenGlassesTests` suite and a Release simulator build all
green on an iPhone 17 Pro simulator, plus one UI-test case on the same simulator. No hardware run.

**The walk-through adds no facts.** `ReadinessWalkthrough` (`Services/Flow/`) is a decision table
over evidence five existing owners already produce, and the ordering is the design: each step is a
precondition of the next, so the sequence stops at the first failure and the wearer is handed one
instruction rather than four caused by the same cause.

| Step | Probe reads | Passes on | Releases |
|---|---|---|---|
| Glasses | `BlindAssistantLaunchPolicy.Inputs` (`glassesReady`, `isPastOnboarding`) | Registration settled — or **no glasses**, which is a pass *with a note* naming audio-only, not a failure | nothing acquired |
| Permissions | the same inputs (microphone, speech recognition, camera) | Microphone and speech recognition granted; camera off is a pass with the audio-only note | nothing acquired |
| Camera picture | a claim on the stream, then `CameraService.readinessNow` polled to a bounded deadline | `CameraReadiness.hasFreshVisualEvidence` — a decoded picture inside the freshness bound | the claim, through `releaseStream(for:)` |
| Microphone and voice | `WakeWordService.healthState(origin:permission:)` → `ListenerHealthPolicy`, then one short line through `speakReporting` | decision `.healthy` or `.startFresh` **and** `SpeechDeliveryOutcome.completed` | nothing started; the health read is a question, not a request to listen |
| Reading something | `SharpStillCapture` through the privacy chokepoint, measured by `CaptureQualityReport` | quality `.usable`; on the simulator, a rendered fixture, reported as a pass **with a note saying it was a fixture** | the claim |

The two rules worth naming. **A part reporting that it exists never passes a step:** a stream that
is up, a socket that is open and a flag that says listening all land on the camera or voice
failure, because the step wants a decoded picture and a delivery outcome, not a component's
opinion of itself. And **the release is the runner's obligation, not each probe's good manners** —
`ReadinessWalkthroughRunner` calls `release(after:)` on every path including the failing one, which
is what the fake's claim and listener counters assert. The claim goes through the existing ledger
(`CameraStreamClaims.Owner.readinessCheck`), so a check run while a live session holds the camera
gives back exactly what it took and stops nothing the session wanted.

The reading step's wearer-facing sentences are *lifted out of* `ReadingCaptureOutcome`'s model
directive rather than copied — `spokenInstruction(for:isReadingRequest:)` and
`spokenUnavailable(_:)` — so the live session and this screen say the same words for the same
condition. The registration and permission sentences are `BlindAssistantLaunchPolicy.SkipReason`'s
own, for the same reason.

**The processing summary is composed, not observed.** `ProcessingSummary.compose(facts:)` produces
five rows from a `ProcessingFacts` value; `ProcessingFactsProvider` is the only thing that reads
`Config`, and it reads each value from the owner that already decides it.

| Row | Read from | Destination it can report |
|---|---|---|
| What the camera sees | the live mode, else the active model's `visionEnabled` and provider | the realtime provider, the model's provider, a configured host, `disabled` when the model takes no images |
| What you say | the live mode, else `Config.isDiarizationConfigured`, else `ASREngineSelector.select` over `OnDeviceASREngine.isReady` | the realtime provider, the diarization vendor, on device, or `unavailable` when the on-device recognizer is selected and absent |
| The answer | `Config.activeModel` — provider, base URL, and for `.local` whether the weights are downloaded | on device, a provider, a host, or `unavailable(asset)` |
| The voice you hear | the live mode, else `TTSEngineSelector.select` over the ElevenLabs key and `KokoroTTSEngine.isReady` | the realtime provider, ElevenLabs, or on device |
| Tools on other machines | `Config.isOpenClawAgentActive` and the highest-priority enabled gateway's host | a configured host, the gateway, or `disabled` |

**The mixed rule.** A row is *active* unless it is `disabled`. The verdict is `fullyOnDevice` only
when every active row is `onDevice`; `cloud` only when every active row leaves; otherwise `mixed`,
naming the rows. `unavailable` is deliberately in neither bucket, so a selected-but-undownloaded
local model cannot satisfy either — and the mixed sentence separates "leaves this device" from "is
set to run here and isn't downloaded", because a row that sends nothing must never appear in a
sentence about sending. Worked examples: **fully on-device** — local model present, on-device
recognizer, Kokoro, remote tools off. **Mixed** — the same local model with ElevenLabs and Apple's
recognizer, named as "What you say and The voice you hear leave this device". **Cloud** — Gemini
Live, where the frames, the audio, the reasoning and the reply all travel on the one socket.
**Not fully on-device** — every row local but the model not downloaded: the answer row reads
`unavailable`, the verdict is mixed, and the offline line names the model.

**The offline line** has two sources: an `unavailable` row's asset, and the on-device alternative
for a row that currently leaves the device and has nothing installed to fall back to. Medical
local-only does not reroute quietly — a row that would leave reads `disabled`, which is what the
wearer will actually experience, and a configuration where that switches off every row says
"Nothing that would leave this device is switched on" rather than claiming everything is local.

**Host only, ever.** `ProcessingFacts.host(of:)` reduces a configured URL to host and non-default
port, dropping path, query and user-info. A test asserts a base URL carrying a key in its query
reaches neither the row nor the spoken paragraph.

**Where it lives.** Settings → Accessibility gains **Before You Rely on It** with the two rows,
beside PR3's *Opening the App*; the same summary is linked from Settings → Glasses & Privacy. Each
result row is a single accessibility element (title as label, status and instruction as value), and
`focusTarget` is set *before* the status is spoken so a wearer reaching for the row finds it under
their finger. The retry re-runs its own step and carries on, rather than charging four passing
steps for one permission.

**One voice phrase, and one deliberately withheld.** `processing_summary` is reachable through the
classifier's existing Tier-0 route, bare-query gated exactly like `new_topic`, so "how are my
requests processed" answers without an LLM turn and the same words inside a longer sentence stay
content. **The readiness check has no phrase**: it claims the camera and speaks a test line, both
of which a live session is already holding, so running it from inside a conversation would measure
the fight rather than the assistant.

**Evidence.** 43 new headless tests. `ReadinessWalkthroughTests` (24): every step's pass, failure
and exact spoken status; a connected camera with no frame and a stale frame both failing; a healthy
listener with an interrupted test line failing with a retry; the audio-only path passing
registration and the camera with notes and skipping the reading step; a failure stopping the
sequence with the fix spoken; a retry re-running one step and continuing; release counters at zero
with the two camera steps never overlapping; and focus landing on each step before its status is
spoken. `ProcessingSummaryTests` (19): the four required configurations, the host reduction in
four shapes, recomputation after a provider change, medical local-only, both realtime modes,
remote tools off, and the caveat closing every spoken summary.

**What the simulator could not exercise.** No glasses, so the camera step's real claim, the twelve-
second wait and a genuine `hasFreshVisualEvidence` were never run; the reading step takes the
documented fixture path there and reports it as a fixture. Nothing was *heard*: the spoken statuses,
the test line and the spoken summary were asserted as strings handed to an injected sink, not as
audio through the glasses. And `ProcessingFactsProvider` itself is not unit-tested — it reads
`Config`, the Keychain and the model stores, so a headless assertion would be an assertion about
this machine's settings; the table it feeds is what the tests exercise.

**Owed.** The participant runs below, which are what close the phase. With them, on device: the
whole walk-through on real glasses, including a camera that comes up slowly and one that does not;
the spoken statuses heard with the phone pocketed; and the summary checked against what the network
monitor actually observed for each of the five rows.

### Participant-led task acceptance and public guidance

Recruit blind participants who use their own assistive technology; agree tasks and success criteria
with them before testing. Include different levels of technical confidence. Run installation/setup,
read a label, correct a misread, check appointments, cancel an action and recover after connection
loss. FH owns its action implementation and FG owns connected-service integration; FF owns the
common non-visual interaction requirements. Their unfinished features must not block independent
acceptance of current reading and native-calendar tasks.

For each task record independent completion, assistance requested, focus/announcement failures,
unintended actions, recovery steps and time to useful output. Separate automated accessibility
checks, researcher-assisted completion and independent completion. Use participant feedback to
revise the interaction and retest; passing a label audit is not the exit criterion. Do not retain
participant recordings or personal task data without an agreed research consent/retention process.

Keep a dedicated public accessibility section with current features, free accessibility access
(provider charges may still apply), tested setup paths and explicit offline/background limitations.
Use reading and everyday-task demonstrations whose build/device configuration is stated; no claim
of independent blind-user readiness until the corresponding gate passes. Gate A includes the
readiness/processing summary and participant evidence above; Gates B/C retain their offline gates.


## Delivery gates and order

| Gate | Exit evidence | Current status |
|---|---|---|
| A — Coherent online Blind Assistant | PR1–5 implemented; complete VoiceOver journey; heard lifecycle feedback; successful sharp reading and reconnect scenarios | PR1–PR5 implemented headlessly. Remaining exit evidence is all device- or participant-bound: the three on-glasses audio checks (PR2), live model outputs against `BlindAssistanceResponseAudit` (PR1), the on-device reading measurement (PR4), recovery time and repeated flapping on glasses (PR5), and a blind participant completing setup and use without a sighted operator (PR3). **2026-09-17:** PR8's readiness walk-through and processing summary are **built** (see its evidence note); the participant-led task acceptance recorded above is still owed, as is running the walk-through on glasses |
| B — Foreground offline continuity | Production offline loop and automatic handover; capability failures audible; airplane-mode evidence | Pending |
| C — Daily-use qualification | Blind-user sessions on target phones/glasses, pocketed/locked behaviour established, latency and power results, unresolved limitations published | **Blocked** on a supported background-inference path: on-device MLX cannot run backgrounded, so the pocketed-phone offline promise has no supported implementation today. Nothing in PR1–PR5 changes that, and none of it should be read as progress against this gate |

Gate C's pocketed-phone offline promise depends on the on-device MLX background constraint recorded in this repository — local inference cannot run backgrounded — so it is a release blocker to schedule early rather than a late qualification step.

Recommended order: PR1 → PR2 → PR3/PR4 → PR5 → PR6–7. Start the offline hardware feasibility check early because background execution may constrain Gate C. Gate A can ship independently with truthful offline limitations.

Existing work to reuse: DF accessibility, CH media trigger, BU offline session, DW offline perception, CV narration, DZ local runtime, FC local-model remediation, FD camera recovery, EW resource cleanup and FE voice delivery. This plan owns the complete blind-user acceptance journey, not duplicate implementations of those systems.

For each gate record build/commit, provider/model, phone/iOS, glasses/firmware/SDK, enabled settings, expected/observed outcome and remaining failures. Establish latency budgets from a baseline with blind participants; report p50/p95 end-of-question to first useful audio, rather than token throughput alone. Tests already present in the repository were inspected, not rerun for this plan.
