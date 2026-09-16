# Plan FB — Scan Assist

**Status: 🚧 PR1 + PR2 implemented 2026-09-16.** P3 and P4 are unbuilt; device and user
validation pending.
Shipped: `ScanAssistSettings`/`ScanAssistSettingsStore`, `ScanAssistPolicy`, `ScanAssistService`,
`ScanAssistCopy` and the `ScanAssistSpeaking` seam over `TextToSpeechService`, plus
`ScanAssistSettingsView` reached from Settings › Accessibility (PR1); and `ScanAssistCueGate`,
`ScanAssistInterruptionPolicy` and the deterministic `ScanAssistTool` (`scan_assist`) with its
Tier-0 classifier phrases (PR2). Off by default, no side until the wearer answers the question, no
camera, no auto-start, no entitlement, and no audio lease of its own.

Bring user-configurable directional reminders into OpenGlasses for people who want help checking
one side during reading or seated everyday tasks, including people living with hemispatial neglect.
The first release supports intentional scanning practice and task reminders; it does not diagnose,
score or claim to treat neglect.

## Product decisions

- Users configure the feature themselves. Clinician/caregiver help is optional, never required to
  unlock settings. No diagnosis, referral or clinician account is required.
- Ask **“Which side would you like reminders to check?”** Offer **Left / Right**, explicitly from
  the wearer's perspective. Require an explicit first selection; never infer a side from a camera,
  medical history, handedness or device placement. Allow changes at any time.
- Offer spoken direction or a gentle sound, an adjustable interval, a cue preview, and an explicit
  session start. Spoken direction is the initial suggested style; a sound is a learned reminder,
  not a promise of spatial audio. Do not require a cue to be heard only on the selected side.
- Pause/stop is always available in the app and through existing voice controls when listening is
  active. State when voice control is unavailable; basic cueing does not require continuous mic use.
- Scan Assist is **free**, following [Plan A](A-accessibility-tier.md). Do not route it through the
  Medical Compliance subscription or introduce another IAP.

## Evidence and scope

[NICE](https://www.nice.org.uk/guidance/ng236/chapter/Recommendations#cognitive-functioning)
recommends assessment of functional effects and task-specific approaches, including scanning and
auditory cues. [Canadian Stroke Best Practices](https://www.strokebestpractices.ca/recommendations/stroke-rehabilitation-delivery/8-visual-and-visual-perceptual-impairment)
supports considering visual scanning. The [2021 Cochrane review](https://www.cochrane.org/evidence/CD003586_non-drug-treatments-spatial-neglectinattention-following-stroke-or-adult-brain-injury)
found substantial uncertainty about lasting functional benefit from neglect interventions. These
sources motivate investigation; they do not validate this app. Recheck evidence before clinical claims.

Initial tasks: seated reading and tabletop search with familiar, non-hazardous items. Optional
clinician-supported evaluation can assess usefulness without becoming a configuration requirement.
Exclude driving, road crossing, walking navigation, collision prevention, prism simulation and
automated treatment plans. Existing navigation features are not silently activated by this mode.

**Observation boundary:** a camera frame does not establish eye position or attention. Head motion,
an object being visible or a user acknowledgment cannot establish recovery from neglect. Never
announce “you missed the left side,” “you checked everything” or “safe to proceed” from camera data.
Do not assume a monocular HUD places a marker in the intended part of the user's visual field.

## Existing owners and integration points

- Accessibility settings and [DF](DF-app-accessibility.md): controls, VoiceOver, Dynamic Type,
  contrast, Reduce Motion and localisation. No separate onboarding framework.
- `TextToSpeechService`, existing audio lease/route coordination, and announcement policy: cue
  delivery. Scan cues must not be VoiceOver-only announcements or a new private audio player.
- `ReadingCompanionService`, `ReadingSessionStore`, `OCRService` and
  [BT](BT-reading-companion.md): optional reading association and page evidence.
- [CW](CW-realtime-audio-rig-recovery.md) / [EW](EW-session-resource-cleanup.md): interruption,
  cancellation and resource ownership. Reuse existing camera claims for optional capture.
- Existing phrase matching and tool dispatch: deterministic start/pause/resume/stop/side controls.
  Feature operation cannot depend on an LLM choosing a reminder or interpreting a clinical state.

## P1 — Settings and deterministic session core

Proposed small types under `Services/Accessibility` (confirm names against the tree when implementing):

- `ScanAssistSettings`: side, cue style, interval and finite session duration. Persist configuration
  locally; persist no inferred diagnosis. Default disabled, no selected side, no auto-start on launch.
- `ScanAssistPolicy`: injected monotonic clock; idle/running/paused/ended states, next cue deadline,
  session expiry and generation identifier. Events drive outputs; no hardware inside this type.
- `ScanAssistService`: main-actor observable owner that schedules and cancels work and uses existing
  speech/audio services. One live session and at most one pending cue.

Initial engineering defaults for usability testing: spoken prompts, 30-second interval, five-minute
session; offer 15/30/60/120-second intervals and 2/5/10-minute duration. These are product settings,
not prescribed therapeutic doses, and must be adjustable following user feedback.

Example copy: “Check to your left when you're ready.” Preview explicitly announces the selected
side. Changing side invalidates queued old-side cues; changing timing schedules from the change
time. Pause cancels queued cues; resume schedules a new interval with no backlog. Stop and expiry
cancel all owned work, including queued speech; reopening the app never resurrects a session.

**Acceptance:** clock-driven tests cover no selection/no start, left and right copy, repeated start,
side change during a queued cue, timing changes, pause/resume, finite expiry, repeated stop, and late
callbacks after stop. Assertions cover emitted/suppressed cues and actual service cancellation via
fakes, not only a settings serialization round trip.

## P2 — Accessible controls and audio delivery

Add Scan Assist to existing accessibility settings with a compact active-session surface:
selected side, cue style, interval, remaining duration, Preview, Start, Pause/Resume and Stop.
Keep critical controls centrally reachable and labelled; do not put the only stop control on the
side the person may have trouble noticing. Use words as well as arrows/colour.

- Respect the existing output route and audio ownership; never force audio to one ear or replace a
  selected route silently. Offer preview on the actual device so the user can judge audibility.
- Suppress/defer cues during user speech, assistant speech, VoiceOver speech or higher-priority
  announcements using available audio signals. Drop stale cues rather than replay a burst. If a
  required signal is unavailable, document and test the conservative fallback before release.
- Pause on calls, output loss and relevant interruption events. Show the reason; require explicit
  resume after uncertain recovery. Never claim a cue was heard because playback was requested.
- First release pauses on background/lock with a clear notice when possible. No silent keep-alive
  audio; screen-off cueing is a later capability only after legitimate background audio behaviour
  and stop/recovery are proven on device.
- Register explicit voice phrases through existing dispatch: start/pause/resume/stop scan reminders,
  remind me to check left/right. Announce the resulting side so an accidental change is apparent.
- No scene capture, cloud model or continuous microphone is needed for this baseline.

**Acceptance:** UI audit with Dynamic Type, VoiceOver and both side selections; cue preview;
interruption, route changes and lock; no overlap/burst on recovery; no cue after stop. Validate phone
speaker, glasses and headset routes on hardware. Test voice controls only in modes where their
listener is active, including recognition failure and the touch fallback.

## P3 — Optional task context and reading support

After P1/P2 device validation, associate a session with Reading or Tabletop without changing the
core cue semantics. Begin with user-selected task labels and fixed prompts; no object detection is
needed to make tabletop reminders useful.

For reading, reuse existing OCR/page identity to help locate a user-chosen page edge or physical
coloured anchor and to open the current source on the phone. Only describe an edge/anchor when the
image supports it; clipped pages, glare, ambiguous orientation and low-confidence OCR produce
“I can't locate the page edge.” Image coordinates are not automatically wearer/body coordinates:
test rotation/mirroring and never convert them to clinical left/right without validated mapping.

Page transitions may update the task context but cannot increase cue frequency beyond the user's
chosen limit or establish that a line was read. Optional capture is explicit, follows existing privacy
and local-only routing, and acquires/releases only its own camera claims. No continuous snapshots
or page content retained by Scan Assist by default. Visual anchors remain optional, never the sole cue.

**Acceptance:** fixtures for full/clipped/rotated pages, ambiguous anchors, OCR failure and source
loss; shared Reading Companion continues when Scan Assist stops; selected side remains independent
of camera inference; no camera permission requested for basic cueing. Tabletop cues make no claims
about unseen objects or successful attention.

## P4 — Optional session review and evaluation

Offer opt-in local summaries: task label, duration, side, cue attempts, completed playback if
observable, skipped cues, user confirmations, early stops and optional usefulness/fatigue feedback.
Name each count accurately: completed playback does not mean heard; confirmed does not mean scanned.
Use existing protected storage patterns, deletion controls and privacy-safe logging. No recordings,
clinical scores, diagnostic inference, caregiver sharing or automatic exports by default.

Co-design with people living with neglect and an occupational therapist. First check comprehension,
audibility, control accessibility and fatigue during a short seated task. Then compare matched tasks
with ordinary cues and app cues, recording missed items and assistance through human observation.
Include a later task without app cues if investigating carry-over. Stop a session if the participant
wants to stop or experiences distress/discomfort. A small usability pilot establishes usability,
not treatment efficacy; clinical efficacy claims need a separately designed study and applicable
clinical/regulatory review.

## Delivery and release gates

1. PR1: P1 plus configuration/preview UI; no auto-start, camera or model dependency.
2. PR2: active controls, audio arbitration and voice wiring; P2 device evidence before availability.
3. PR3: optional task/reading support only after basic cues prove useful; no new vision framework.
4. PR4: optional summary and evaluation improvements based on feedback.

Ship an off-by-default user-enabled accessibility feature after P1/P2 acceptance and usability
review. Keep unvalidated P3 functions unavailable. No clinician approval gate on user configuration.
Update user documentation and privacy disclosures with actual behaviour, and keep efficacy language
out of product copy. Localisation must preserve wearer-relative left/right and clear stop wording.

| Evidence | Status |
|---|---|
| Cue arbitration, interruptions and voice phrases | Done 2026-09-16 (PR2) — see the PR2 note below. `ScanAssistCueGateTests` (17), `ScanAssistInterruptionPolicyTests` (9), `ScanAssistToolTests` (13), 15 added `ScanAssistServiceTests` and 6 added `ConversationClassifierTests`. Full suite green (5911, 13 skipped); Release simulator build green |
| Session policy/service tests | Done 2026-09-16 — `ScanAssistPolicyTests` (27), `ScanAssistServiceTests` (21), `ScanAssistSettingsStoreTests` (6), `ScanAssistCopyTests` (6) on a fake clock, a releasable sleeper and a recording speech sink: start refused with no side and nothing spoken, left/right copy, repeat start/stop harmless, side change during a queued cue, timing changes from the change time, pause/resume with no backlog, finite expiry cancelling the pending cue and queued speech, late generation callbacks silent, preview once, and no running state surviving a fresh service. Full suite green (5742) |
| UI accessibility and left/right comprehension | Pending |
| Device audio, interruption, stop and lock checks | Pending |
| User/OT usability feedback | Pending |
| Optional OCR/task-context checks | Pending |

### PR2 note — what the code now guarantees, and what only a device can show

**Cue arbitration (`ScanAssistCueGate`).** Each reminder is offered to a pure gate with the audio
signals as they are at that instant, and the answer is deliver, defer with a reason, or drop.
It defers while the wearer is speaking, while the assistant is speaking (`TextToSpeechService.isSpeaking`),
while VoiceOver is speaking, while a session lifecycle notice is being announced, or while a
higher-priority notice holds the route — in that priority order. **At most one reminder is ever
outstanding:** a newer one replaces the one waiting rather than queueing behind it, so when the
route frees exactly one plays and nothing is replayed as a burst. A waiting reminder is dropped
instead of played if the session stopped, paused, changed side or moved generation under it, or if
it has waited longer than the gate's budget (10 s, deliberately shorter than the shortest
selectable interval so a held cue can never land on the next one's slot).

**The one signal iOS does not offer.** Nothing reports when VoiceOver has *finished* an
announcement — only whether VoiceOver is running. Treating "running" as "speaking" would silence
the feature for its likeliest users, so the documented conservative fallback is a bounded wait: the
app assumes VoiceOver is busy for 2.5 s after *it* posted an announcement, then delivers. Tested
both ways in `ScanAssistCueGateTests` and `ScanAssistServiceTests`.

**Delivered never means heard.** The service counts playback *requests* (`deliveredCueCount`) and
nothing else; `ScanAssistCopyTests` scans every user-facing line for claims to the contrary.

**Pauses carry a reason** (`pauseReason` / "Paused — phone call", "Paused — audio output changed",
"Paused — another app is using the audio", "Paused — app went to the background"). A call is read
from the same `CXCallObserver` source `WakeWordService` uses, at the moment the audio interruption
arrives. Output loss comes from `oldDeviceUnavailable` or an empty output route; background and
lock from `didEnterBackgroundNotification` and `protectedDataWillBecomeUnavailableNotification`.
There is no keep-alive audio and no background cueing in this release.

**Resume is only automatic when recovery is certain** — the pause was ours, the interruption ended
*with* `.shouldResume`, and the output route is the one we were paused on (compared by port UID).
Then the session resumes with a fresh interval and no backlog. Every other ending — no
`.shouldResume`, a different route, an output-loss pause, a return from the background — stays
paused and asks for an explicit Resume. A pause the wearer asked for is never lifted by an audio
event.

**Route ownership:** Scan Assist acquires no audio lease, never overrides the output port and never
steers a cue to one ear; cues and the preview play on whatever route the speech service is already
using.

**Voice phrases** reach `ScanAssistTool` (`scan_assist`) through the existing Tier-0 classifier
route, bare-query gated the way `new_topic` is, so the same words inside a sentence stay content:
start/pause/resume/stop scan reminders (and "turn on/off scan assist"), "remind me to check my
left/right", "switch/move the reminders to …", and "which side am I checking". A phrase that names
no side — or names both, or says "the other side" — routes with **no** side and the tool asks;
"right now" is never read as a side. Every answer names the resulting side, so an accidental change
is audible at once. The session surface says "Voice control is off in this mode. Use the buttons on
this screen…" whenever the wake-word listener is not running.

**Device checks still owed (none of these can be closed headlessly):** phone speaker, glasses and
headset routes, including audibility of the preview on each; a real phone call, a real interruption
from another audio app, and a real lock/background cycle, checking the reason shown and that no
burst follows recovery; recognition failure and the touch fallback for every voice phrase, in the
modes where the listener actually runs; and a UI audit with VoiceOver and Dynamic Type on both side
selections, covering the pause-reason line and the centred worded Stop.

Record build/commit, hardware/OS, scenario, result and remaining gap here as implementation proceeds.
Headless checks cannot close device or participant evidence. This plan adds assistive controls;
it does not expand Medical Compliance claims or certify clinical effectiveness.
