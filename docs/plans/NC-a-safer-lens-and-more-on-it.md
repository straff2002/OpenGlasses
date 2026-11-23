# Plan NC — A Safer Lens, and More on It (Deny first on what can't be undone, presses that land only on the screen they were made on, a lens that opens only when it should, timed holds, a nameplate read blind, a diagnosis loop, finding the unit, and talk points)

**Status:** 📝 Drafted 2026-11-23; nothing built; 16 decisions with recommendations.
**Track:** Display (Meta Ray-Ban Display through the stable `MWDATDisplay`, DAT 1.1.0), Field Assist,
and the consumer app. P0–P9 are headless cores with thin wiring. P10 is the catalog sync. P11 needs the
glasses. Nothing here needs an experimental DAT API; the one place that could use one (a head heading
for arrows, §5) is a later TestFlight-only option and is not planned.
**Source:** field experience with the Display, read against `origin/main` at `51375930a` on
2026-11-23. The DAT 1.1 docs (`search_dat_docs`) for `Image`, `VideoPlayer` and `TextStyle`.
**Related:** Plan [LC](LC-the-lens-made-ready.md) (the approval card, dismissal, the turn arrow,
pacing), Plan [KP](KP-answers-you-can-act-on.md) (`PageTurnGate`), Plan
[MU](MU-the-lens-read-at-work.md) (the button-row width model), Plan [MG](MG-reading-the-conversation-on-the-lens.md)
("show that again"), Plan [X](X-interactive-hud-now-next-tasks.md) (the Now/Next band), Plan
[KE](KE-symptom-diagnosis-and-vault-only.md) and Plan [HU](HU-service-history-and-maintenance-flags.md)
(diagnosis and service history), Plan [IS](IS-refrigerant-toolkit.md) (gauge readings), Plan
[KM](KM-expert-on-the-job.md) (coaching replies), Plan [MI](MI-steps-you-can-see.md) (a step's
figure), Plan [CA](CA-walking-navigation.md) (walking routes), Plan [AG](teleprompter.md) (the
teleprompter), Plan [GL](GL-cycling-driving-navigation-and-road-alerts.md) (cycling; see below).

**Cycling facts** (heading from the track, speed that dims without a fix, moving time, a dimmed glance
strip) went into Plan GL as its 2026-11-23 amendment, not into a phase here. NC's P1 builds the shared
track heading that amendment uses.

The web mirror is out of scope; it is being retired separately.

---

## Why

Three kinds of work, all about what reaches the lens.

1. **Safety and lifecycle on the native lens.** A stray pinch on an approval card approves, because
   Approve has focus. A press from a screen that has since been replaced can still act. The lens
   opens for frames it should not: while the glasses are off the face, for a two-second line, or
   again straight after a failed open.
2. **Field Assist work the lens can carry.** A pressure hold that runs while the technician does
   other work. A nameplate read without being told what to expect. A short, checked diagnosis
   loop. Big gauge numbers. A diagram from an expert. Finding the right unit on a big site.
3. **Consumer modes.** Talk points that tick as you say them. A labelled card while an answer is
   written. Lines that fit by width, not by character count. Reply ideas in translation. A
   curated Home Assistant set. Meeting action items that must quote the meeting. A watch shortcut.
   An alarm that a word can stop but its own sound can't.

## What exists today (verified 2026-11-23 on `origin/main` 51375930a)

**Approvals.**
- The approval card focuses **Approve** on every ask:
  `OpenGlasses/Sources/Services/Display/HUDApprovalCardBuilder.swift:130` (and the doc table at :20).
  Details focuses **‹ Back** (:152).
- Nothing classifies an ask as reversible or not. The asks come from two lists:
  `PromptInjectionPolicy.highImpactTools` (`Services/PromptInjectionPolicy.swift:81-90`: messages,
  calls, HomeKit and Home Assistant actuation, Shortcuts, medical export, `execute`) plus
  `code_agent` start (:103), and `HighImpactToolPolicy` (`Services/HighImpactToolPolicy.swift:38`:
  security actuation such as unlock). `PendingToolConfirmation` carries the tool name, summary and
  source (`Services/ToolConfirmationCoordinator.swift:54-61`), not the arguments.
- An unanswered card denies after 20 s (`Services/Display/HUDApprovalCard.swift:35`).

**Stale presses.**
- Every frame bumps `frameRevision`, and a held screen records `heldScreenRevision`
  (`Services/GlassesDisplayService.swift:1163-1164`). `acceptsHeldScreenPress(issuedAgainst:)` drops a
  press whose revision is not the current frame (:1034-1036, via `Services/Display/PageTurnGate.swift:10-13`).
- **The gap:** the revision a press is checked against is read when the press arrives, not stamped
  when the button was sent. `HUDApprovalCard.handle` passes `display.heldScreenRevision` at press
  time (`Services/Display/HUDApprovalCard.swift:117`), as does `HUDRouter.pressCard`
  (`Services/Display/HUDRouter.swift:387`). The SDK button's `onClick` carries only the item id
  (`Services/Display/MetaDisplayBackend.swift:506-509`). So a press made on screen A that arrives after
  held screen B was drawn is checked against B's revision and passes; the gate only catches a press
  made under a notification. Item ids such as `back` and `close` repeat across screens.

**Lens session rules.** Checked one by one:

| Rule | Today |
|---|---|
| Open only with content | **Exists.** A clear with no Display is a no-op (`MetaDisplayBackend.swift:385`). |
| A dismissed card can't reopen the lens | **Exists.** `lensDismissed` drops every frame until a wearer-led one (`GlassesDisplayService.swift:541-570`, `:1157`). |
| Open only while worn | **Missing.** `DisplayAvailability` reads `.off` when the glasses are off the face (`Services/Display/DisplayAvailability.swift:30-34`), but `.off` "changes nothing about rendering" (`GlassesDisplayService.swift:507`). Only the prepared-card glances check worn (`Services/Display/PreparedCardGlances.swift:80`). |
| Back off failed opens | **Partial.** A refused start waits a fixed 30 s (`MetaDisplayBackend.swift:227`). Any other failure tears down and the next frame tries again at once (`GlassesDisplayService.swift:1352` onwards). |
| Hold the lens while a photo is taken | **Partial.** When a photo stops the Display, the lens is redrawn afterwards (`GlassesDisplayService.swift:653-657`). Frames still go during the capture. |
| No session for a short acknowledgement | **Missing.** `flash` and `showNotification` open a session for any duration (`GlassesDisplayService.swift:805-812`); a two-second line is flashed at `App/OpenGlassesApp.swift:9025`. |
| Space sends | **Exists.** 0.4 s after text, 1 s after a picture (`Services/Display/HUDSendPacer.swift`). |

**Bringing the lens back.** "Show that again" and its phrases bring back the last **answer** only
(`Services/Display/HUDVoiceCommand.swift:83-104`, `Services/Display/HUDAnswerCard.swift:742`). A task
card the glasses ended "stays resumable from the launcher" (`GlassesDisplayService.swift:547`): by the
menu, not by voice.

**Arrows.** `HUDTurnArrow` draws an arrow at any angle (`Services/Display/HUDTurnArrow.swift:75`)
but is fed only six fixed maneuver angles (:30-39), for walking turns
(`Services/Navigation/WalkingRouteService.swift:305-307`). Parking says the direction as a compass
point in words (`Services/Parking/ParkingRecallPhraser.swift:112`). **The app reads no heading at all:**
no `CLHeading`, `startUpdatingHeading` or `CLLocation.course` anywhere in `OpenGlasses/Sources`.

**Field Assist.**
- `Procedure.Step` has no hold, duration or timer field (`Services/FieldAssist/Procedure.swift:76-115`).
  The Now/Next card shows step count, instruction, safety note and next title
  (`Services/Display/HUDRouter.swift:579-594`). Timers exist apart from procedures
  (`Services/NativeTools/TimerCompletionWatch.swift`, the lens card at
  `Services/Display/HUDTimerCard.swift:65`).
- The nameplate camera path is already blind at the recognizer: on-device OCR gets the still and no
  expected value (`Services/NativeTools/EquipmentLookupTool.swift:327-338`). Then the raw OCR text
  goes to the model, and with no vault match the tool asks the model to "identify the code/model from
  the text above" (:367): a guess by another name. Nothing shows the read value on the lens to
  confirm. Nothing reads a serial as its own field. `EquipmentIdentity` keeps `nameplateText` for
  audit (`Services/FieldAssist/EquipmentIdentity.swift:22`).
- No diagnosis loop exists: no tool or state machine for hypotheses and checks. Service history and
  structured vision do (`Services/NativeTools/ServiceHistoryTool.swift`,
  `Services/NativeTools/VisionAssessTool.swift`).
- Gauge readings never reach the lens. DAT text has three presets only, `heading`, `body` and `meta`
  (DAT 1.1 `TextStyle`; used at `MetaDisplayBackend.swift:272-286`), so a number larger than a heading
  must be drawn as a picture.
- The live-support data channel is ignored (`Services/FieldAssist/WebRTCPeerTransport.swift:237`), and
  the live transport itself waits on the separate decision recorded in Plan L's row. DAT's
  `VideoPlayer` on iOS plays an `https` MP4 from a URL, at most 400 px a side and 70,000 pixels; it
  cannot carry a live stream. `Image(image:sizePreset:)` takes a local `UIImage`, so a still diagram
  can go natively.
- A site unit has `id`, `model`, `serial`, `label`, `covered` and `externalIDs`. It has no position,
  access note or photo (`Services/Vault/SiteSystemDocument.swift:35-48`). No file imports CoreNFC.
  The app has a QR scanner for organisation codes (`App/Views/OrgCodeScannerView.swift`). Geofences
  use `CLCircularRegion` (`Services/NativeTools/GeofenceTool.swift:264`).

**Consumer.**
- The teleprompter has three modes: audio-paced, voice and auto-scroll
  (`Services/Teleprompter/TeleprompterService.swift:9-13`). No talk-points mode.
- While an answer is written, the lens shows Thinking (`Services/Display/HUDTurnStateBuilder.swift:72`).
- Lines are fitted by character count: `HUDTextShaper` (`Services/Display/HUDScreen.swift:30-32`),
  `HUDAnswerPager` (`Services/Display/HUDAnswerPager.swift:176`) and the teleprompter
  (`Services/Teleprompter/TeleprompterPaginator.swift:23`, 32 characters). Only MU's button row uses a
  width model, 13 px a character and 24 px a full-width one (`Services/Display/LensButtonRowBudget.swift:54-56`).
- The interpreter translates both ways and offers no reply ideas (`Services/Translation/Interpreter.swift:4-10`).
- The lens's Home list is the wearer's own quick actions (`Services/Display/HUDHomeFavourites.swift:1-8`).
  The Home Assistant tool calls `/api/services` and `/api/states` only
  (`Services/NativeTools/HomeAssistantTool.swift:197-238`).
- Meeting action items are picked locally as whole transcript sentences
  (`Services/NativeTools/MeetingSummaryTool.swift:185-205`), so they are verbatim already. The model
  is then told to present the summary "conversationally" (:118), and the live assistant's prompt asks
  it to attribute action items (`Services/MeetingAnalysisSink.swift:53`). Model wording is unchecked.
- The watch has three complications: listen, record, photo note
  (`OpenGlassesWatch/WatchComplicationLink.swift:19-21`). Its tiles can already take a photo and ask
  about it (`OpenGlassesWatch/WatchMainView.swift:424-425`).
- A finished timer or alarm is stopped from the lens card or the phone (`App/OpenGlassesApp.swift:3255`).
  No spoken words stop it.

## Scope

| § | What | Phase |
|---|---|---|
| 1 | Irreversible asks open on **Deny** | P0 |
| 2 | Every lens send carries its generation | P0 |
| 3 | Lens session rules: worn, back-off, the photo hold, no session for a short line, a gap between sessions | P0 |
| 4 | "Show the lens" brings back what was last held | P1 |
| 5 | Arrows at any bearing, from the track's heading | P1 |
| 6 | Dim a held card after a read interval | P1 |
| 7 | DAT field rules, recorded and checked | P0 (gap), P11 (checks) |
| 8 | Timed holds in procedures | P2 |
| 9 | A nameplate read blind, confirmed on the lens | P3 |
| 10 | Big gauge numbers | P3 |
| 11 | The diagnosis loop | P4 |
| 12 | A diagram from the expert | P5 |
| 13 | Finding the unit on a big site | P6 |
| 14 | Talk points | P7 |
| 15 | A labelled card while the answer is written | P7 |
| 16 | Lines fitted by width | P7 |
| 17 | Reply ideas in translation | P8 |
| 18 | Home Assistant: a labelled set and thermostat steps | P8 |
| 19 | Action items that quote the meeting | P9 |
| 20 | A watch "what's wrong with this?" | P9 |
| 21 | An alarm stopped by two words | P9 |

## Design

### 1 · Irreversible asks open on Deny (P0)

A pinch on a focused button is the cheapest press there is. For an ask that cannot be called back,
the cheapest press should refuse.

- **`ApprovalReversibility` (new, pure).** `classify(toolName:args:) -> .irreversible | .reversible`.
  An ask is **irreversible** when what it does leaves the phone, or changes the physical world, and
  cannot be called back by the app:
  - a message, email or post sent; a call placed;
  - data uploaded, exported or shared (`medical_export`);
  - something deleted that the app cannot restore;
  - a lock opened, an alarm disarmed, a garage or gate opened (`HighImpactToolPolicy`'s set);
  - an arbitrary command or Shortcut run (`execute`, `run_shortcut`, `code_agent` start);
  - a job signed off, or a record published to the office.

  **Reversible:** lights, media, a thermostat step, a reminder, a note. **A tool the table does not
  name is irreversible** (fail safe). The table is data, with one test per row.
- `PendingToolConfirmation` gains `reversibility`, set where the ask is made, from the tool name and
  the arguments the router already has.
- `HUDApprovalCardBuilder.card` focuses **Deny** when irreversible and **Approve** otherwise. Details
  keeps **‹ Back**. The phone's consent card is unchanged; it already needs a deliberate tap.
- The spoken prompt is unchanged. A voice "yes" still approves; the change is the band only.

### 2 · Every lens send carries its generation (P0)

- **`LensPressToken` (new, pure):** the frame revision a screen was enqueued at, plus the item id.
  `GlassesDisplayService` stamps each `.screen` with its revision when it enqueues it, and the backend
  builds every button's `onClick` to report `(id, revision)`, not `id` alone. The Even G2 backend and
  the test sink do the same.
- `acceptsHeldScreenPress` takes the stamped revision. Every caller that passes
  `display.heldScreenRevision` at press time (the approval card, the prepared cards, the router's task
  card and menus, the turn state, the timer card, the page view, band practice) passes the token's
  revision instead.
- A press whose revision is not the held screen's is dropped and logged as today
  (`hudPageTurnStale`). That now covers the case the gate misses: a press from screen A arriving after
  held screen B replaced it.
- `SharedLensPressGuardTests` scrapes `Services/Display` for `acceptsHeldScreenPress(issuedAgainst:
  display.heldScreenRevision)` and fails on any left.

### 3 · Lens session rules (P0)

Only the gaps from the table above. **`LensOpenPolicy` (new, pure)** decides whether a frame may open
a session that is not open now:

- **Worn.** With `worn == false`, a frame that would open the lens is not sent. Held state (a task
  card, an answer card, a menu) stays held and is drawn once when the glasses go back on, as
  `resumeLens()` does after another app. Transient lines are dropped (they were spoken). `nil` is
  unknown, not off, as everywhere else.
- **Back-off.** After a failed open (not a refusal, not a timeout, which have their own rules), the
  next open waits 1, 2, 4, 8, then 15 s, and a frame that arrives meanwhile replaces the waiting one
  (latest wins, as the queue already is). A successful send resets the ladder. A wearer-led frame
  does not skip the wait, but it is never dropped: it goes when the wait ends.
- **Photo hold.** While a photo is owed (`PhotoCaptureLedger`,
  `Services/Camera/PhotoCaptureLedger.swift:40`, has a request outstanding), frames wait,
  latest wins, and go once the photo lands or the ledger gives up. This replaces the redraw-after
  with one send at the end.
- **Short lines.** A transient of 2 s or less (decision 5) never opens a session. With the lens
  already open it shows as today; with it closed, the line is spoken or the earcon plays.
- **A gap between sessions.** `DeviceSessionCoordinator` waits at least 2 s after a session stops
  before it starts the next (decision 4). See §7.

`LensOpenPolicy` reads only values (`worn`, the last failure and its time, whether a photo is owed,
the frame's kind and duration, whether a session is open), so its tests need no SDK.

### 4 · "Show the lens" (P1)

The Back gesture ends a Display session and is not delivered to the app. Today the words bring back
an answer; a procedure card needs the menu.

- `HUDReopenCommand` gains "show the lens", "show the glasses", "show the screen", "bring the lens
  back" and "show me where I was", whole utterances only, as its other phrases are.
- **`LensReturn` (new, pure)** picks what comes back: the screen that was held when the lens was
  dismissed, if it is still live (a running task card as it is now, a timer card still ringing, a
  page view whose answer is still there), else the last answer card when it can be reopened
  (`HUDAnswerCard.canReopen`, `Services/Display/HUDAnswerCard.swift:728`), else nothing. Nothing comes back: "Nothing to show on the lens" is spoken, and no session opens.
- It is a wearer-led frame, so it clears `lensDismissed` as "show that again" does today.

### 5 · Arrows at any bearing (P1)

- **`LensBearingArrow` (new):** `HUDTurnArrow`'s drawing (white or the highlight colour on black,
  on a strip that `Image(.fill)` keeps at its own size) for any angle, rounded to 15° so the cache stays
  small and the render queue's de-duplication still works. `HUDTurnArrow` becomes a caller.
- **The angle needs the wearer's heading, and the app has none.** **`TrackHeading` (new, pure):**
  the bearing between the latest fix and the earliest fix within the last ~12 m of track, from
  fixes whose horizontal accuracy is good enough; held while the wearer is stopped (under ~0.7 m/s for
  3 s); nil until there is a track. The same type feeds GL's cycling amendment.
- The arrow is `bearing to target − TrackHeading`. With no heading, the line goes alone in words, as
  today ("300 m NE"). The phone's compass is not used: in a pocket it points wherever the pocket does
  (decision 7).
- Uses: the parked car (`ParkingRecallPhraser`'s line gains the arrow when walking towards it), a unit's
  pin (§13), and GL's road alerts later.
- A head-relative arrow from the glasses' own motion sensor would need `MWDATMotion`, which is
  experimental. That is a TestFlight-lane option for later and is not planned here.

### 6 · Dim a held card after a read interval (P1)

- **`LensDimPolicy` (new, pure):** after `dimAfter` seconds with no change and no press, a held card
  is sent once more with its body lines in the secondary colour. It is offered per surface, never
  globally: talk points (§14, 10 s) and GL's cycling glance strip. Answer cards, approvals and task
  cards never dim.
- It costs one send. The Display dims by itself at 20 s, so whether ours adds anything is a P11 check.

### 7 · DAT field rules, recorded and checked (P0, P11)

Three reports from field experience, none seen on our glasses yet. This PR adds them to the "Field
reports" section of `.claude/rules/dat-conventions.md`, worded as unconfirmed:

1. **Leave at least 2 s between one DAT session stopping and the next starting.** Cheap and harmless,
   so P0 builds it (§3) without waiting for the check.
2. **Keep the HFP link up rather than cycling it.** Opening and closing the glasses mic repeatedly may
   end sessions, on top of the known HFP report. Nothing is built for it; P11 checks it, by
   counting session ends while the wake word starts and stops.
3. **After Back, the Display may report `started` while the lens shows Meta's home.** If true, a
   send after Back may land nowhere. P11 checks it with the probe; if it holds, `LensReturn` (§4)
   restarts the Display rather than sending into a session that reports started.

### 8 · Timed holds in procedures (P2)

A decay test, a standing pressure test or a cure time: the technician starts it and does other work.

- **`Procedure.Step.hold` (new, optional):** `{ "seconds": 900, "label": "Standing pressure", "end":
  "check" | "advance" }`. Decoded unchanged when absent; checked by the procedure checks (1 s to 24 h,
  a label of at most 40 characters).
- **`HoldClock` (new, pure):** the hold's start time is a wall-clock date written with the run, so the
  time left survives the app being suspended or killed. It says `running(left)`, `ended(at)` or
  `endedWhileAway(at)`.
- **The band.** The Now/Next card's top line becomes "Standing pressure · 12 min left". It updates
  every minute, every 10 s in the last minute, and nowhere else, to keep sends rare. Other steps can be
  worked while it runs only if the step's `end` is `check`: the card then shows the hold above the
  current step. With `advance`, **Done** is replaced by the countdown and "end the hold early", spoken
  or pressed, is recorded as such (decision 9).
- **At the end,** while the app runs: a short tone and one spoken line ("Standing pressure: time's
  up"), the card back to the hold's step. The lens dims at 20 s and sleeps at 25 s, so the cue is
  sound.
- **Ended while the app was away:** a passive local notification at the due time, no sound
  (decision 8). On return, the card shows "Standing pressure ended 6 min ago, at 10:32" once, in the
  meta style. No alarm.
- The record keeps the hold's start, end and whether it was ended early.

### 9 · A nameplate read blind, confirmed on the lens (P3)

The recognizer is already blind. What is missing is the confirmation, the "uncertain" answer and
the capture id.

- **`NameplateRead` (new, pure over OCR output):** from Vision's recognised lines with their
  confidences, pick a model candidate and a serial candidate by shape and label ("M/N", "MODEL",
  "S/N", "SERIAL"). Each is `read(value, confidence)` or `uncertain(reason)`. Uncertain when any
  character of the token is below the confidence floor or the token fails its shape. Never
  "corrected" towards anything.
- **The expected value is never given to the reader.** The job's unit and the vault's models are
  used only afterwards, to compare: `same`, `near` (`EquipmentRecognition`'s existing distance) or
  `different`. A `different` is said as a finding ("The plate says …; the job says …"), not fixed.
- **Confirm on the lens.** A crop of the plate's text region (decision 11; never the whole frame) as a
  picture, the read model and serial under it, and **Confirm** · **Retake** · **Say it**. **Retake**
  is focused. Confirmed values go to `EquipmentIdentity` with `.nameplate`; a spoken correction goes
  with `.technician`.
- **Capture id.** Each read carries the id of the still it came from. A result for a still that is
  not the latest request is dropped, so a slow read can't land on a later confirm card.
- `EquipmentLookupTool`'s "identify the code/model from the text above" line goes. With nothing
  confirmed, the tool says the plate could not be read with confidence and asks for it to be said.

### 10 · Big gauge numbers (P3)

- **`LensNumeralStrip` (new):** the readings drawn as a picture: two or three values in large digits
  of fixed width, so digits don't shift as they change, each with its unit and a one-word label
  ("Suction 118 psi", "SH 9 °F"). One strip a frame, drawn on the `HUDTurnArrow` canvas pattern and
  cached by its text.
- `refrigerant_gauges` sends it when the lens shows pictures and a reading is complete. Spoken
  output is unchanged.

### 11 · The diagnosis loop (P4)

- **`DiagnosisLoop` (new, pure state machine):** symptom → at most three hypotheses → one check at a
  time → a verdict per check → the next hypothesis or a cause.
- **Hypotheses** are drafted by the model from the job's manuals and the unit's service history. Each
  must cite at least one source the job holds (a manual page, a history entry from HU). An uncited
  hypothesis is dropped by the app before it is shown (decision 12). Each carries one check that takes
  about two minutes or less.
- **The check's verdict:** `confirmed`, `ruledOut` or `unclear`. The technician says it or presses it;
  or the camera's structured verdict (AD's `vision_assess`) proposes it and the technician confirms.
  **`unclear` never advances** to a cause; it asks for the check again or for the next hypothesis.
- **The camera question is about the cause, not the target.** The prompt asks whether what is seen
  supports or refutes "the capacitor has failed", not whether "the capacitor" is in view.
- **Fix steps come only from the manual.** With a confirmed cause, the loop opens the vault's
  procedure for it. With none on file it says "No procedure on file for this", never steps of the
  model's own.
- The camera looks at equipment. Nothing in the loop looks at the people on site.
- The lens shows one hypothesis and its check at a time, with **Confirmed** · **Ruled out** ·
  **Unclear**; **Unclear** is focused.

### 12 · A diagram from the expert (P5)

- **Native as a still, not as live video.** `VideoPlayer` takes an `https` MP4 by URL and cannot carry
  a stream; `Image` takes a local picture. So the expert sends a still.
- **Carrier:** KM's coaching reply. A coaching step may carry one picture (a diagram or a marked-up
  photo), using MI's step `figure` shape. It passes KM's checks as today (it must answer a handover
  this phone sent), and the picture goes through the same size limits as a page view.
- **On the lens:** the step's words, the picture under them, and the page view's zoom for detail.
- **Not planned:** mirroring a screen. A laptop screen needs three to four times zoom to read on the
  lens, and the controllers on site can't share a screen anyway.

### 13 · Finding the unit on a big site (P6)

- **The unit record gains** `position` (latitude, longitude, accuracy), `access_note` (at most 200
  characters: "Roof, east hatch, key at security") and `photo` (one picture of the unit in place). All
  optional; decoded unchanged when absent.
- **Captured on site:** "pin this unit here" saves the current fix, a photo and a spoken access note
  to the job's unit, and proposes them to the site record through the existing office path
  (decision 13).
- **Getting there:** "take me to the rooftop unit" starts CA's walking route to the pin.
- **The last 50 m:** inside 50 m, GPS can't be trusted to the metre, so the route hands over to a
  card: the arrow (§5), the distance in words, the access note and the photo.
- **Confirming:** a QR label on the unit, scanned with the existing scanner, settles which unit it is.
  NFC later (decision 14).
- **Not Bluetooth beacons.** The contractor doesn't own the site's beacons, they need batteries and
  upkeep, their range is coarse, and regions they need would share iOS's 20-region limit with the
  wearer's geofences.

### 14 · Talk points (P7)

- **A fourth teleprompter mode, `talkPoints`.** The script is a list of points, not prose. Each point
  has its words and two to four key words (drawn from the point by default, editable).
- **`TalkPointTracker` (new, pure):** heard words in, the points' states out: `pending`, `said`,
  `skipped`. A point is `said` when enough of its key words are heard close together. A later point
  said while an earlier one is pending marks that one `skipped`, and the card shows a small "skipped:
  …" line once.
- **Pacing:** a total time set before starting; each point's share by its length. The card's meta line
  says "4 of 9 · 6 min left · on time" (or "2 min behind").
- **The card** shows the current point large and the next one small; after 10 s it dims (§6), so the
  speaker looks back at the room.
- Recognition is on-device, of what the speaker says, as the audio-paced mode already does. Nothing
  heard is kept.

### 15 · A labelled card while the answer is written (P7)

- **`InterimCard` (new, pure):** while the model writes, if the app already holds a strong match for
  the question (a talk point, a vault table row, a manual hit above the retrieval floor), the
  Thinking card shows it with a label: "While I check: from the manual, p.19". The answer card
  replaces it in place when its first page is ready.
- Never a guess, never the model's own partial text, and off for general chat (decision 15).

### 16 · Lines fitted by width (P7)

- **`LensTextWidth` (new, pure):** a line's width in lens pixels from per-character advances: the
  measured 13 px for ordinary characters, 24 px for full-width characters (East Asian Width wide or
  fullwidth), and an emoji class. MU P5 measured both numbers on the simulated Display.
- `HUDAnswerPager`, `HUDTextShaper` and the teleprompter wrap by width against the column, not by
  `maxChars`. A line of Chinese or Japanese then holds about half the characters of a line of
  English, as it should. A run with no spaces breaks between characters, never inside a grapheme.
- A CoreText measure is not used: the lens's font is not on the phone (decision 16).

### 17 · Reply ideas in translation (P8)

- In an interpreter session, after the other person's line, the lens (or phone) offers **two short
  reply ideas** in their language, each with its meaning in the wearer's language under it, and **Hear
  it** to play it in the wearer's ear first.
- **`ReplyIdeas` (new, pure)** builds the request and checks the result: two ideas, each at most 12
  words, each with a gloss; anything else is dropped.
- Made by the on-device model when it is loaded; by the cloud model only inside a session the
  interpreter's gate already allows. Nothing new leaves the phone otherwise.

### 18 · Home Assistant: a labelled set and thermostat steps (P8)

- **A label chooses the set.** Entities with the Home Assistant label "Glasses" (the name is a
  setting) form the lens's Home list, read through `/api/template` with `label_entities`. The wearer's
  own quick actions stay as they are, after the labelled ones.
- **Thermostat steps.** A climate entity shows its target with **−** and **+**. Presses change the
  shown target at once and are sent as one `set_temperature` 1.5 s after the last press, so five presses
  are one call. The lens has no release event, so the pause stands in for one.

### 19 · Action items that quote the meeting (P9)

- The local list is verbatim already. The rule is for model wording: **`ActionItemQuoteCheck`
  (new, pure)** keeps an action item the model writes only if it carries a quote found word for word
  (case and punctuation aside) in the transcript.
- It applies to the saved summary note and the live assistant's update: the model is asked for items
  as `item — "quote"`, and items whose quote isn't found are dropped before they are shown or saved.

### 20 · A watch "what's wrong with this?" (P9)

- A fourth complication runs a fixed prompt with a fresh glasses photo, through the same path as the
  watch's photo tiles. In a Field Assist job it uses the job's manuals; otherwise it is an ordinary
  question.

### 21 · An alarm stopped by two words (P9)

- **`AlarmStopCommand` (new, pure):** "stop alarm", "stop timer", "alarm off", "timer off", "silence
  alarm", whole utterances only. A bare "stop" does not stop an alarm (it still stops speech, as
  today).
- **Ignored for the first 2 s** after the alarm starts, so the alarm's own sound can't trigger it.
- It calls the timer card's existing **Stop**.

## Phases (one PR each)

**P0 — Lens safety and lifecycle (headless).** `ApprovalReversibility` and the focus rule;
`LensPressToken` through every held-screen press; `LensOpenPolicy` (worn, back-off, photo hold, short
lines); the 2 s session gap; the three field reports in `dat-conventions.md` (already in this docs PR).
Tests: `ApprovalReversibilityTests` (one per row, unknown tool irreversible),
`HUDApprovalCardBuilderTests` (Deny focused when irreversible), `LensPressTokenTests` (a press from A
after B is dropped; under a notification is dropped; a current press passes),
`SharedLensPressGuardTests`, `LensOpenPolicyTests` (each rule both ways), `DeviceSessionGapTests`
(fake clock).

**P1 — Getting the lens back, arrows, dimming.** `HUDReopenCommand` phrases, `LensReturn`,
`LensBearingArrow`, `TrackHeading`, the parking arrow, `LensDimPolicy`. Tests: `LensReturnTests`,
`TrackHeadingTests` (straight line, a turn, stopped, poor accuracy, no track), `LensBearingArrowTests`
(rounding, cache key), `LensDimPolicyTests`.

**P2 — Timed holds.** `Procedure.Step.hold`, the checks, `HoldClock`, the band line, the end cue, the
passive notification, the quiet note, the record. Tests: `ProcedureHoldDecodingTests`, `HoldClockTests`
(suspended and relaunched, ended while away), `TaskCardHoldTests`, `HoldRecordTests`.

**P3 — Nameplate and gauge numbers.** `NameplateRead`, the comparison, the lens confirm card, the
capture id, the tool's new no-guess line; `LensNumeralStrip`. Tests: `NameplateReadTests` (recorded OCR
fixtures: clean, smudged character, two candidates, serial only), `NameplateCompareTests`,
`NameplateCaptureIdTests`, `LensNumeralStripTests` (text key, layout).

**P4 — The diagnosis loop.** `DiagnosisLoop`, the citation check, the verdict rules, the
cause-centred prompt, the "no procedure on file" ending, the lens card. Tests: `DiagnosisLoopTests`
(three at most, uncited dropped, unclear never advances, manual-only fix), `DiagnosisPromptTests`.

**P5 — A diagram from the expert.** A picture on a coaching step, KM's checks, the lens view. Tests:
`CoachingStepFigureTests` (accepted only on an answering reply, size limits).

**P6 — Finding the unit.** The unit's `position`, `access_note`, `photo`; "pin this unit here"; the
walking route to a pin; the last-50 m card; QR confirm. Tests: `SiteUnitLocationDecodingTests`,
`UnitPinTests`, `LastFiftyMetresTests`, `UnitQRConfirmTests`.

**P7 — Talk points, interim card, width fitting.** `talkPoints` mode, `TalkPointTracker`, pacing;
`InterimCard`; `LensTextWidth` in the pager, shaper and teleprompter. Tests: `TalkPointTrackerTests`
(said, skipped, re-said, filler), `TalkPointPacingTests`, `InterimCardTests` (never a guess, label,
replaced in place), `LensTextWidthTests` (English, Chinese, Japanese, mixed, emoji, the 13 languages).

**P8 — Translation replies and Home Assistant.** `ReplyIdeas`; the labelled set; thermostat steps.
Tests: `ReplyIdeasTests`, `HALabelSetTests` (template answer parsing), `ThermostatStepCoalescerTests`
(fake clock).

**P9 — Meetings, watch, alarm.** `ActionItemQuoteCheck`, the watch complication, `AlarmStopCommand`.
Tests: `ActionItemQuoteCheckTests`, `AlarmStopCommandTests` (two words, bare stop, the 2 s window).

**P10 — Catalog sync.** New strings into the 13 complete languages, add-only, its own PR.

**P11 — Device pass (owed, on the glasses).**
- An irreversible ask on the lens: a stray pinch denies.
- A press on a replaced screen is dropped (two screens with a shared **Close**).
- Glasses off the face: nothing opens; on again: the held card returns once.
- A failed open backs off; a photo during a card: one send after it.
- "Show the lens" after Back: the task card returns.
- The three field rules (§7): sessions started under 2 s apart; HFP cycled ten times; a send after
  Back.
- Dimming: does ours add anything before the Display's own dim at 20 s?
- A 15-minute hold with the phone locked; the passive notification; the quiet note.
- A nameplate in poor light reads "uncertain"; a clean one confirms.
- Talk points over a five-minute talk; a Chinese answer fills its lines.

## Decisions

1. **What counts as irreversible.** *Recommend:* the rule in §1 (leaves the phone or changes the
   physical world, and the app can't call it back), as a table with unknown tools irreversible.
   *Alternative:* every approval card opens on Deny.
2. **Deny first, or a second press.** *Recommend:* focus Deny on irreversible asks; Approve stays one
   press once the wearer moves to it. *Alternative:* Approve needs two presses, as Thinking's Cancel
   does.
3. **Reversible asks.** *Recommend:* keep Approve focused. *Alternative:* Deny focused everywhere.
4. **The 2 s session gap before the check.** *Recommend:* build it in P0; it is cheap and harmless.
   *Alternative:* wait for P11.
5. **Short lines.** *Recommend:* 2 s or less never opens a session. *Alternative:* 3 s.
6. **Off the face.** *Recommend:* hold state and draw it once on return; drop transients.
   *Alternative:* drop everything while off.
7. **The heading for arrows.** *Recommend:* the track's heading only; words when there is none.
   *Alternative:* the phone's compass when the phone is held flat.
8. **A hold that ends while the app is away.** *Recommend:* a passive local notification (no sound)
   plus the quiet note on return. *Alternative:* the note only.
9. **Ending a hold early.** *Recommend:* allowed by voice or press, and recorded as ended early.
   *Alternative:* not allowed for `advance` holds.
10. **The confidence floor for a plate.** *Recommend:* set from recorded fixtures in P3 and kept as
    data; any character under it makes the read uncertain. *Alternative:* a fixed 0.5.
11. **What the confirm card shows.** *Recommend:* a crop of the text region only. *Alternative:* the
    whole still.
12. **Uncited hypotheses.** *Recommend:* dropped by the app. *Alternative:* shown marked "no source".
13. **Where a pin lives.** *Recommend:* on the job's unit at once, proposed to the site record through
    the office path. *Alternative:* the site record only, set from the office.
14. **QR or NFC.** *Recommend:* QR first with the existing scanner; NFC later, as it adds an
    entitlement and a CoreNFC dependency. *Alternative:* both in P6.
15. **The interim card's sources.** *Recommend:* only what the app already holds (a talk point, a
    table row, a manual hit above the floor); never in general chat. *Alternative:* also the last
    answer on the same subject.
16. **Width model.** *Recommend:* the advance table, with MU P5's measured numbers. *Alternative:*
    CoreText with a stand-in font.

## Privacy and safety

- Nothing identifies a person by face or voice. Talk points and the alarm words listen to the
  wearer's own speech on the device, as the teleprompter and wake word already do; nothing heard is
  kept.
- The diagnosis loop's camera questions are about equipment. Nothing analyses coworkers or anyone
  else on site.
- Every still goes through `CameraService.filteredStill(for:source:)`; the nameplate crop is made
  after that.
- Reply ideas leave the phone only inside an interpreter session its gate already allows.
- A unit's position and photo are business records of the customer's site, held like the job's
  address.
- Nothing here touches the capture LED.

## Risks and open questions

1. **The press token on Even G2.** Its buttons are numbered cells; the token must survive its own
   press path. Checked headless in P0 against its mock transport.
2. **The worn reading can lag.** A pair just put on may still read off for a moment; the held card
   then appears a beat late, which is acceptable.
3. **Track heading at walking speed** is noisy near buildings. The 12 m window and the accuracy floor
   are data and may change after P11.
4. **Hold sends.** A 15-minute hold sends about 25 frames. If that shows on the link, the band goes to
   five-minute steps until the last minute.
5. **OCR fixtures.** The confidence floor is only as good as the recorded plates; P3 needs real ones
   from pilot jobs.

## Not in scope

The web mirror. Mirroring a laptop or controller screen. Live video to the lens. Bluetooth beacons.
Video quality that steps down on stalls: a step clip is fetched by the glasses from its URL, and live
support waits on its own transport decision. A reading layout with the current sentence large: MU
already opens a page with the answer highlighted and the rest dimmed. Anything that needs an
experimental DAT API in a store build.
