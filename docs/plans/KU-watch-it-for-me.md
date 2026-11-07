# Plan KU — Watch It for Me (a camera that waits quietly and speaks when the gauge, the light or the job gets there)

**Status:** 📝 Drafted 2026-11-08. Nothing built. The owner asked for it after asking how a camera that waits
could help Field Assist, and whether the glasses could be the camera. The [decisions](#decisions-for-greig-open)
below are recommendations and are still open.
**Track:** Field Assist first (evacuation, decay and pressure tests, recovery, readings settling, indicator
lights). The general kinds ("tell me when it boils", "tell me when it finishes") work outside Field Assist too.
**Builds on:** Plan [IS](IS-refrigerant-toolkit.md) (`refrigerant_gauges`, `instrument_reading`,
`GaugeRoleResolver`, `RefrigerantGaugeChain`, `UnitNormalizer`, `InstrumentPlausibility`, P5's micron reading
and decay sequence, P6's evacuation procedure), Plan [C](C-live-coach-tool.md) (Live Coach's loop and
`LiveCoachPacer`), the [change gate](frame-dedup-change-gate.md) (`FrameGate`, `PerceptualHash`), Plan
[HY](HY-live-session-hygiene.md) (`CallBudget`), [structured vision](structured-vision-assessment.md)
(`StructuredVisionService`, schema-checked answers, `ImageQualityProbe`), Plan [CP](CP-outbound-frame-privacy.md)
(`CameraService.filteredStill(for:source:)`, the `OutboundFrameConsumer` roster), Plan
[GV](GV-phone-camera-tools.md) (`PhoneCapturePolicy`: no silent phone capture), Plan [BV](BV-power-policy.md)
(`PowerPolicyService`, glasses thermal), Plan [FO](FO-guided-job-flow-and-job-tab.md) (the open job, its
photos, `JobPhotoEvidenceService`), `SpokenReading`, `ProcedureRunner`, `LiveActivityManager`.
**Sits beside:** Plan [JO](JO-watchers.md) (a watcher is a standing question about the outside world, checked
from data sources; a KU watch is one the wearer asked for, read off the camera, and it ends). Plan
[JI](JI-apprentice-support.md) (the logbook takes a KU record as evidence when it lands). Plan
[KP](KP-answers-you-can-act-on.md) (the Display card patterns).

---

## Trigger

Surveying adjacent multimodal-agent work turned up a pattern Avenkin lacks: a camera loop that stays
**silent** until a condition is true, then acts. Avenkin's camera loops all talk. Live Coach speaks every few
seconds; scene narration speaks on every change; Plan JO's watchers read data sources, not the camera. Nothing
answers "tell me when the gauge reads under 500 microns".

For a technician, that is a lot of the working day. An evacuation can take most of an hour, a standing
pressure test 15 to 30 minutes, a decay test 10. While the technician waits, their hands are on something else.
Smart digital probes have their own alarms, but only for themselves, and they write nothing on the job. A
watch that works with whatever gauge is in the van, analogue or digital, and puts the readings on the job,
answers both.

The owner then asked whether the glasses could provide the input. They can, with one honest constraint: the
glasses camera looks wherever the technician looks. §4 is designed around that.

## Outcome

- "Watch the gauge, tell me when it's under 500 microns." Avenkin takes a still, confirms what it read ("Watching
  the micron gauge: 4,200 now. I'll tell you under 500."), and goes quiet. Each time the technician looks at the
  gauge, it reads it. When the reading has been under 500 on two looks in a row, it says "480 microns, 31 minutes.
  Isolate and start the decay test?"
- "Yes." It watches the same gauge for the procedure's standing time, judged against the vault's pass figure,
  and says pass or fail. A rise past the limit is said as soon as it is seen twice, not at the end.
- "How's the vacuum?" → "1,200 microns, falling about 100 a minute: roughly 7 minutes to 500."
- No glance for a while → "Glance at the gauge." Once, then not again for the same interval.
- For a long, unattended wait the technician props the phone facing the gauge and says "watch it on the phone".
  The phone shows the camera, the reading and a Stop button, and keeps its screen awake.
- On the job: "Evacuated to 480 microns in 31 min. Standing 10 min, rose to 620 (limit 1,000): pass." Stills
  from the start, the moment it fired and the end are attached (all filtered).
- Outside the trade: "Tell me when the kettle light goes off." "Tell me when the print finishes." The same
  machinery, without the job record.

## What exists, and what doesn't

**Exists (verified against `main` at 1e0cfe948):**
- `refrigerant_gauges` (`RefrigerantGaugeTool`) reads one filtered still of a manifold or digital set through
  `instrument_reading`, resolves roles (`GaugeRoleResolver`) and chains to superheat and subcool
  (`RefrigerantGaugeChain`). It is one-shot: one still, one answer.
- `UnitNormalizer` and `InstrumentPlausibility` (per-refrigerant pressure bands). **Microns are not there yet**:
  they are Plan IS P5, unbuilt.
- `FrameGate`: pure dHash change gate with an adaptive threshold and a heartbeat; reports `.distinct`,
  `.firstFrame` or `.heartbeat`. `PerceptualHash.dhash` and `.hamming`.
- `LiveCoachPacer`: change gate plus `CallBudget`, budget asked first so a refused tick never captures.
  `CallBudget` is a rolling-window cap and is **not for safety loops** (a test scans those files).
- `CameraService.filteredStill(for:source:)` and the `OutboundFrameConsumer` roster, enforced by
  `OutboundFrameConsumerTests`. Live Coach (`liveCoach`) and the gauge reader (`refrigerantGaugeReading`)
  are on it.
- `PhoneCapturePolicy`: a tool never takes a silent phone picture; the phone camera opens on screen.
  `JobRecordingCoordinator` already keeps the screen awake for a job clip (`isIdleTimerDisabled`).
- `SpokenReading` with `method` (nil or `instrument_reading`) and `photoId`. `ProcedureRunner` drives a vault
  procedure's step graph. `TimerTool` (local notifications). `GlassesActivityAttributes` (Live Activity).
- `PowerPolicyService` (battery and thermal posture, glasses thermal folded in) and the doffed stand-down.

**Doesn't exist:**
- A loop that is silent until a condition holds, or anything that judges a series of camera readings.
- A "target in view" check, a glance prompt, or a phone live-view mode for a tool.
- Microns, inches of water column or a decay sequence in the reading code (IS P5).
- A watch record on the job, or a procedure step that starts a watch.

## Design

### 1 · The watch (`CameraWatch`, pure)

A value the tool builds from the wearer's words (or a procedure step), and the only thing the loop runs:

- `target`: the wearer's words for it ("the micron gauge", "the left gauge", "the flame window", "the kettle
  light"), plus an **anchor**: the filtered still taken at the start, and its dHash.
- `condition`: one of the kinds in §2.
- `source`: `.glasses` or `.phone` (§4). It can change mid-watch.
- `limits`: maximum duration (default 60 min, ceiling 2 h), the check interval for the kind, a call budget.
- `jobId`: the open job when there is one; the record goes there (§7).
- `origin`: `.spoken`, `.tile` or `.procedure(stepId)`.

One watch at a time in v1 (decision 3). Starting a second asks to replace the first.

**Every number that decides comes from the wearer or the vault, never from the model.** "Under 500" is the
wearer's 500; the decay limit is the procedure's figure. A watch with no figure (a reading kind the wearer did
not give a number for, and no procedure) asks for one rather than guessing.

### 2 · The kinds

| Kind | Example | Fires when |
|---|---|---|
| `reachesReading(quantity, ≤/≥, figure, unit)` | "tell me when it's under 500 microns", "when the scale reads 12.4 kg" | K good readings in a row past the figure (§3) |
| `holdsReading(quantity, maxChange, duration)` | decay test, nitrogen standing test | **fail** as soon as the change passes the limit on K readings; **pass** at the end of the duration |
| `settles(quantity, band, window)` | "tell me when superheat settles" (IS's chain each check) | every good reading in the window sits inside the band |
| `yes(question)` | "is the flame lit", "is the light green" | the answer is yes with certainty ≥ the floor, K times in a row |
| `choice(question, options)` | "what colour is the board light" | a chosen option other than the start one, K times |
| `changes` | "tell me when it finishes", "tell me when anything changes" | §3's baseline rule: the answer has moved away from where it started and stayed there |

`changes` is for when the wearer can't say what "done" looks like. The first three good checks set a baseline
(their mean certainty, or the start choice or reading), and it fires once three checks in a row sit clearly
away from it. A print head that stops moving, a pot that starts to boil and a progress light that goes out all
fit.

The reading kinds go through `UnitNormalizer` and `InstrumentPlausibility`, so microns, psig, kPa, kg, lb and
inches of water column are compared in one unit. If IS P5 has not landed when KU P0 is built, KU P0 adds the
micron and inches-of-water units as IS P5 describes them, and IS P5's row says so.

### 3 · Deciding (`WatchJudge`, pure)

The judge takes one observation at a time and returns at most one event. Time is passed in.

**An observation** is what one check yields: `targetInView` (Bool), `quality` (from `ImageQualityProbe`), and
either a reading (`value`, `unit`) or an answer (`yes` certainty, or a choice and its certainty). Readings that
fail `InstrumentPlausibility` become **no reading**: not a miss, not a disagreement.

**The rules:**
- **Only good observations count.** Target not in view, a blurred or dark frame, or an implausible reading is
  skipped: it neither advances nor resets the run. A technician who looks away does not break a run of two.
- **K in a row.** Default K = 2 for the reading kinds (a needle has to be read twice past the line), K = 3 for
  the yes/choice/changes kinds (decision 7). One misread frame cannot fire a watch.
- **Hysteresis on readings.** Once fired, a watch is done; for `holdsReading` the run must clear the limit by a
  margin, so a needle trembling on the line is not reported twice.
- **Baseline.** The first three good observations set `start`. `holdsReading` takes its start value at
  isolation (the moment the wearer says "isolated", or the procedure step begins), not at watch start.
- **Progress.** A pure `WatchProgress` fits the recent good readings (log-linear for vacuum, linear otherwise)
  and gives a rate and a rough time to the figure. It is only said when asked, and only when the fit is steady
  (enough readings, residual under a bound); otherwise "1,200 now, too early to say how long".

**Events:** `.started(baseline)`, `.progress(reading, rate?, eta?)`, `.fired(reason, evidence)`,
`.passed`/`.failed` (`holdsReading`), `.lostSight(since)`, `.needGlance`, `.expired`, `.stopped(why)`.

### 4 · Where the pictures come from (`WatchPacer`, pure)

**Glasses: read on a look.** The glasses camera sees the gauge only while the technician looks at it, so the
watch does not pretend to be a fixed camera. It reads opportunistically:

1. A frame comes through `FrameGate` as usual (changed, or the heartbeat).
2. **The anchor gate.** Its dHash is compared with the anchor's. A frame close to the anchor (Hamming at or
   under a tuned bound) means the wearer is probably looking at the target again, so it goes on to a check. A
   frame far from it costs nothing. This is pure and cheap, and it is what keeps a glasses watch affordable.
3. The check (cloud or on-device, §5) answers `targetInView` itself too, so the anchor gate is a cost filter,
   never the judge.
4. A minimum interval per kind between checks (vacuum about 20 s; a light or a flame about 5 s) and the
   watch's `CallBudget`.
5. **The glance prompt.** No good observation for the kind's glance interval (default 5 min for a vacuum, 2 min
   for a light) → `.needGlance`: "Glance at the gauge." Once per interval. Never during a call or a live
   session's reply.

**Phone: a fixed camera on screen.** For a long, unattended wait the technician props the phone facing the
gauge. In keeping with `PhoneCapturePolicy` there is no silent phone capture: the phone mode is an on-screen
watch view (camera preview, the target box from the anchor, the current reading, elapsed time, Stop). It keeps
the screen awake as the job clip does. Frames still go through `FrameGate`, so a still needle costs one check
per heartbeat. iOS does not give a backgrounded app the camera, so the phone mode needs the app on screen; the
view says so, and locking the phone pauses the watch and says it paused.

**Switching.** "Watch it on the phone" or "back to the glasses" changes `source` mid-watch. The anchor is
retaken from the new camera; the run and baseline carry over, as they are readings, not pictures.

**Power and the glasses.** A long glasses watch drains and heats the glasses. `PowerPolicyService` posture
stretches the intervals. A hot glasses reading stops glasses checks and says "The glasses are warm: prop the
phone, or I'll ask you to glance." Taking the glasses off pauses a glasses watch (the existing stand-down); a
phone watch carries on.

**Safety kinds and the budget.** `CallBudget` is not for safety loops, and a recovery cylinder reaching its
target weight is safety-adjacent. Kinds marked `safety` (decision 8: recovery weight, and any vault figure the
vault marks as a safety threshold) take no budget; they are bounded by their interval and maximum duration
instead. The existing scan test is extended to cover them.

### 5 · Reading a frame

- **Every frame goes through the chokepoint.** Glasses frames come from `CameraService.filteredStill(for:
  .cameraWatch, …)`; phone-mode frames go through the same scope's filter before they leave the view. New roster
  entries `cameraWatch` and `cameraWatchPhone` in `OutboundFrameConsumer`; `OutboundFrameConsumerTests`
  enforce them.
- **Cloud check.** A new structured-vision schema `watch_check`: `target_visible`, `value` + `unit` (reading
  kinds), `answer` + `certainty` (yes/choice), and a short `seen` note for the record. The schema is validated
  like every structured-vision answer; an answer that fails validation is no observation. The reading kinds
  reuse `instrument_reading`'s prompt and labels so a manifold watch can read several gauges at once (for
  `settles` on superheat, `RefrigerantGaugeChain` runs each check).
- **Certainty is measured, not trusted.** P0 includes a fixture corpus of our own gauge and indicator stills
  (taken by us, never from a licensed manual or a vendor's material). P1 measures whether the schema's
  `certainty` separates right from wrong on it before the floor is set.
- **On-device later.** A local vision model can answer yes/no from its token probabilities without writing
  text, which would be cheaper and private. On-device models can't run with the app in the background, so this
  is a foreground-only option, kept for later ([What KU leaves out](#what-ku-leaves-out)).

### 6 · Saying it

- **The wearer asked for it.** A watch's result is not an unprompted finding, so it is outside Plan JO's three
  a day and is not held for quiet hours (decision 4). It waits for the end of a sentence being spoken; it never
  barges into a reply mid-word. A `safety` kind speaks at once, like IS's CO flag.
- **Words.** The reading, the time it took and the next step: "480 microns, 31 minutes. Isolate and start the
  decay test?" A yes chains to `holdsReading` with the procedure's figure. A `changes` watch says what changed:
  "The print light went out, 42 minutes in."
- **No glasses.** If the glasses are not connected when it fires: a local notification (as `TimerTool`) and a
  haptic on the Apple Watch.
- **Stopping.** "Stop watching", Stop on the phone view or the Live Activity, or the maximum duration. The end
  is always said: "Stopped watching the gauge: last read 1,050."
- **While it watches.** The Live Activity shows the target, the last reading and the figure. On a Display, a
  one-line card with the reading and the figure, using KP's card rules; it never covers an answer card.

### 7 · On the job, and in procedures

- **Readings.** The start, each distinct reading the judge used, the firing reading and the end are written as
  `SpokenReading`s with `method: "camera_watch"` and the evidence still's `photoId`. A reading taken from a
  photo is recorded as read from a photo, never as verified, as IS P1 does.
- **The record.** A `WatchRecord` on the open job: target, kind, figure and its source (wearer or vault page),
  start and end times, outcome (fired / passed / failed / expired / stopped), the readings used, and the three
  stills. The report gets one line ("Evacuated to 480 microns in 31 min. Standing 10 min, rose to 620 (limit
  1,000): pass.").
- **The logbook.** When Plan JI lands, a `WatchRecord` is evidence an apprentice's entry can cite.
- **Procedures.** A vault procedure step can carry a `watch` block (kind, quantity, comparator, figure,
  duration). Entering the step offers the watch ("Watch the gauge down to 500 microns?"), with the vault's
  figure and page. Plan IS P6's evacuation and vacuum decay procedure is the first to use it.

### 8 · Privacy and cost

- A watch never runs silently: it is spoken at the start and the end, visible on the Live Activity and the
  phone, and ends at its maximum duration.
- No video is kept. Only the three evidence stills are stored, all filtered, on the job when there is one;
  otherwise they are dropped when the watch ends.
- Identifying people is out of scope: "tell me when my colleague arrives" is refused. Face recognition stays its own
  opt-in feature.
- An organisation profile can turn cloud watches off. What a watch may do in HIPAA mode is settled in P1 against
  what structured vision is allowed there today.
- The cost tracker counts a watch's checks under its own row, so the P5 device pass can say what a 45-minute
  evacuation costs in each mode.

## What KU leaves out

- Watching the phone's own screen (a screen-broadcast extension): little use for a glasses app, and a heavy
  battery cost.
- Rules or scripts the wearer writes. The kinds are fixed; the wearer's words fill them.
- Sending to outside channels (SMS, calls, chat bots). The app's own speech, notification and watch haptic only.
- Reading Bluetooth probes directly: better data than a picture, and its own plan if the owner wants it.
- **Later:** counting a board's blink code (needs a steady frame rate the cloud path can't afford; on-device
  brightness tracking in a marked region is the likely route); sound triggers from the glasses microphones
  ("tell me when the recovery machine stops", using the system sound classifier); the on-device yes/no check
  from §5; two watches at once.

## Decisions for Greig (open)

Recommendations first.

1. **Who gets it.** All kinds for everyone; Field Assist adds the job record, vault figures, procedure steps and
   the gauge-specific kinds' wording. (Alternative: Field Assist only.)
2. **Duration.** Default 60 minutes, ceiling 2 hours.
3. **One watch at a time** in v1.
4. **A requested result is outside JO's daily cap and quiet hours.** It still never barges in mid-sentence.
5. **The phone mode needs the app on screen.** Accept the iOS limit and say it on the view, rather than
   designing round it.
6. **Figures only from the wearer or the vault.** A reading kind with neither asks.
7. **K = 2** good readings in a row for reading kinds, **K = 3** for yes/choice/changes.
8. **Safety kinds take no call budget**: recovery weight, and any figure the vault marks as a safety threshold.
9. **Budget for everything else:** 120 checks an hour per watch, on top of the anchor gate and intervals.

## Phases (one PR each)

### P0 — the pure core (headless)

- `CameraWatch`, the kinds, the parser from tool arguments (figures and units through `UnitNormalizer`; a reading
  kind with no figure → a question).
- `WatchJudge` (good-observation rule, K in a row, hysteresis, baseline, `holdsReading` pass/fail),
  `WatchProgress` (rate and time to figure, with its steadiness rule), `WatchPacer` (anchor gate, per-kind
  intervals, budget, glance prompt, power posture, safety kinds without a budget), and the wording for every
  event.
- Microns and inches of water column in `UnitNormalizer`/`InstrumentPlausibility` if IS P5 has not landed.
- **Exit tests:** a vacuum series that dips once under 500 then bounces (no fire), and one that holds (fires on
  the second); a decay series that fails early and one that passes at the end; looking away mid-run doesn't
  reset it; an implausible reading is skipped; `changes` over yes-certainty, choice and reading series; the
  anchor gate over fixture hashes; the glance prompt's timing; budget refusal; the safety kind ignoring the
  budget; progress steady vs too early.

### P1 — the tool, on the glasses (headless, wired)

- `camera_watch` native tool (`start`, `status`, `stop`, `switch`), with a self-contained description for
  `SystemPromptBuilder`. In `PhoneCapturePolicy`'s table.
- The `watch_check` schema and its fixture corpus; the certainty measurement that sets the yes/choice floor.
- Roster entry `cameraWatch`; frames from `filteredStill`; the loop owned by a `CameraWatchService` modelled on
  `LiveCoachService`.
- Speech for start, fire, glance, progress on request and stop; the Live Activity line; thermal and doff hooks.

### P2 — the phone mode (headless, wired)

- The on-screen watch view (preview, target box, reading, elapsed, Stop), screen kept awake, roster entry
  `cameraWatchPhone`, frames through the filter, pause on lock, switching between glasses and phone mid-watch.

### P3 — on the job, and in procedures (headless)

- `SpokenReading` method `camera_watch`, `WatchRecord`, the evidence stills, the report line.
- The procedure step `watch` block in the vault manifest format, the offer on entering the step, and the IS P6
  evacuation and decay procedure using it (if P6 has not landed, the block ships with a test procedure only).

### P4 — the other surfaces (headless)

- The Display one-line card, the Apple Watch notification and haptic, "how's it going?" on every surface.

### P5 — device pass (owed)

- A real analogue and digital micron gauge, a manifold set and a scale; a 30-minute glasses watch read on
  glances; a propped-phone evacuation start to finish; the warm-glasses hand-off; what happens when the phone
  locks during a glasses watch; the cost of a 45-minute evacuation in each mode.

## Acceptance

- A watch never fires on one frame, never fires twice, and never decides on a figure the model supplied.
- Every frame it sends passes the privacy chokepoint, and the roster test covers both routes.
- Looking away does not break a watch; not looking for a while gets one glance prompt per interval.
- A safety kind is never silenced by the budget.
- The job shows the readings and the outcome with the stills, and the report line matches them.
- Start and end are always said; nothing runs past its maximum duration.

## Open

- Whether the glasses camera keeps streaming with the phone locked in the way a long watch needs: P5 answers it
  on a device.
- The anchor gate's Hamming bound: tuned on the P0 fixtures, then on the device.
- Whether the cloud schema's `certainty` is calibrated well enough for K = 3, or whether a provider's token
  probabilities are needed (P1 measures it).
