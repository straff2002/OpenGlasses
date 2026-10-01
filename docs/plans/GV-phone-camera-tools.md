# Plan GV — Camera Tools on the Phone Camera

**Status:** 📋 Planned 2026-10-02 — one PR, P0–P2.

**Related:** Plan [GJ](GJ-remappable-temple-gestures.md) (the glasses-only capture rule this plan
keeps), Plan [FO](FO-guided-job-flow-and-job-tab.md) (the Field Assist job tiles), Plan
[FY](FY-rename-to-avenkin.md) (device-neutral prompt wording: "You have a camera."), Plan
[CQ](CQ-third-party-glasses-backends.md) (the `CameraService` phone fallback), W04.1 (the still
chokepoint, `filteredStill(for:source:)`), and PR #604 (the glasses link flag that no longer
latches true).

---

## Trigger

Avenkin is no longer glasses-first. With no glasses connected, the Field Assist **Fault Code** and
**Safety Check** home tiles took no photo, and the assistant said it could not capture through the
glasses.

## What happens today without glasses (re-checked after #604, 2026-10-02)

#604 fixed the root lie — the connected flag no longer latches true — so `CameraService` now knows
the glasses are away and `capturePhoto()` takes its phone branch. Traced through the code:

- **Fault Code / Safety Check tiles** are `.prompt` actions: the prompt goes to the model, and the
  model is shown tool descriptions that say "through the glasses camera", "point the glasses at
  the nameplate", "from the glasses camera". Those teach it to refuse, and it often does.
- **When the model does call the tool**, the still comes from `filteredStill(for:source:)` with
  `.cachedFrameThenPhoto` or `.photoOnly`. There is no fresh stream frame, so it calls
  `capturePhoto()`, which falls to `PhoneCameraSource`: a **silent iPhone back-camera shot**, no
  preview, no framing, no announcement. The phone is in a pocket or flat on a bench, so
  `equipment_lookup` / `manual_lookup` OCR nothing ("I couldn't read any text on the label"), and
  `safety_assessment` sends a picture of a pocket lining to the cloud HECA model and returns an
  assessment of it. The same silent shot serves `capture_photo`, `photo_log`, `vision_assess`,
  `reading_assist`, `smart_capture`, the identifiers, `study`/`teleprompter` scans, `look_closely`,
  `parking`'s sign photo, and the direct `capturePhoto()` callers `scan_document` and
  `document_knowledge` (`ingest_scan`).
- Tools that ask only for the stream frame (`.cachedFrameOnly`: `scan_code`, `qr_context`) answer
  "No camera frame available. Make sure the glasses are connected…".
- Several failure strings ("Make sure the glasses are connected and the camera is active") are fed
  back to the model and reinforce the refusal.

So the problem moved: no longer a refusal at the camera, but a silent wrong-camera picture behind
tool descriptions that still say "glasses".

## Outcome

- With no glasses connected, every camera tool that needs a picture **opens the phone camera on
  screen**; the user frames the shot and presses the shutter, and the tool carries on with that
  picture. The model's turn waits for it.
- Cancelling, or leaving the camera open for 90 seconds, gives the model a plain sentence saying no
  photo was taken and nothing was seen — never an opaque error, never a description of nothing.
- Tool descriptions say "the camera (the glasses when connected, otherwise the phone)". Only the
  tools that really are glasses-only say "glasses".
- The **Fault Code**, **Safety Check** and **Log Photo** tiles open the phone camera straight away
  when no glasses are connected, then run their prompt; the tool the prompt calls uses that photo.
  With glasses connected they behave exactly as today.
- Glasses-only paths (temple taps, silent Siri / Watch captures, live video tools) stay
  glasses-only.

## Design

### The per-tool table — `PhoneCapturePolicy` (pure)

One table maps each camera tool to its phone route:

- **`.askOnPhone`** — present the phone camera sheet; the user frames and shoots.
- **`.glassesOnly`** — never take a phone picture for this tool.

| Tool | Route | Why |
|---|---|---|
| `capture_photo` | ask on phone | "Take a photo" — framing is the whole request |
| `photo_log` | ask on phone | Job evidence must show the thing, not a pocket |
| `equipment_lookup` (camera) | ask on phone | Nameplate / fault display must be framed to OCR |
| `manual_lookup` (camera) | ask on phone | Same |
| `safety_assessment` (run) | ask on phone | A HECA of the wrong view is worse than none |
| `vision_assess` | ask on phone | Instrument reading / triage need the subject in frame |
| `scan_document` | ask on phone | Document must be framed |
| `document_knowledge` (`ingest_scan`) | ask on phone | Same |
| `reading_assist` | ask on phone | Text must be framed |
| `look_closely` | ask on phone | Fine detail — the reason the tool exists |
| `smart_capture` | ask on phone | Card / receipt / flyer must be framed |
| `identify_medication` | ask on phone | Label must be framed |
| `identify_money` | ask on phone | Note must be framed |
| `identify_color` | ask on phone | Colour of what is framed |
| `scan_code` | ask on phone | Code must be framed (was stream-only) |
| `qr_context` | ask on phone | Same |
| `scan_badge` | ask on phone | Badge must be framed |
| `study` (scan) | ask on phone | Page must be framed |
| `teleprompter` (scan) | ask on phone | Same |
| `parking` (photo) | ask on phone | The sign must be framed; a spot still saves without it |
| `face_recognition` | glasses only | Identifies people from the live glasses view; not a phone feature |
| `fitness_coach` | glasses only | Live pose from the stream |
| `live_coach` | glasses only | Continuous loop over the stream |
| `navigation_assist` | glasses only | Continuous hazard loop over the stream |
| `video_recording` | glasses only | Glasses video + microphone |
| `record_clip` | glasses only | Glasses video clip |
| `pin_frame` | glasses only | Pins the live frame; takes no picture |

A tool name the table does not know is treated as **ask on phone**: the safe default is the user
framing, never a pocket shot. Calls with **no tool in scope** (the app's own photo buttons, the
voice "what am I looking at" turn, remote-invoke, the developer MCP server) keep their current
behaviour — they are out of scope here.

### How a tool waits for a phone photo — `PhonePhotoCoordinator`

- `CameraService.capturePhoto(allowPhoneFallback:)`: when the glasses camera cannot serve the
  capture **and a tool is executing** (`ToolInvocationScope.current`), it asks the policy. Ask on
  phone → `PhonePhotoRequesting.requestPhoto(_:)`, which suspends until the user shoots or the
  request ends. Glasses only → `GlassesOnlyCaptureError`. No tool in scope → the existing silent
  `PhoneCameraSource` path, unchanged.
- `filteredStill(for:source:)`: a `.cachedFrameOnly` request from an ask-on-phone tool with the
  glasses link down is served as `.photoOnly` (there is no stream to hold a frame), so `scan_code`
  and `qr_context` get the sheet instead of "no frame".
- The coordinator holds **at most one** pending request (`@Published pending`). A second request
  while one is open is **rejected** with a sentence (not queued: two sheets in a row from one
  sentence is confusing, and the model can ask again).
- **Timeout 90 s.** Long enough to take the phone out, unlock it and frame a nameplate; short
  enough that an abandoned sheet does not hold a turn open.
- **App not on screen** (backgrounded, locked): no sheet can appear, so the request ends at once
  with a sentence asking the user to open Avenkin.
- **Presentation watchdog (4 s).** The sheet is presented from the root view (`MainView`), like the
  manual-figure sheet, so it appears on any tab. If another sheet is already up, SwiftUI cannot
  present a second one; if the camera view has not appeared within 4 s, the request ends with a
  sentence asking the user to close the open screen.
- Task cancellation (barge-in, conversation reset, router timeout) cancels the request and closes
  the sheet.
- **Router budget.** Camera tools run under the router's 30 s default; a 90 s wait would be cut off.
  When the glasses are not connected and the tool is ask-on-phone, the router's timeout for that
  call is its usual budget **plus** 90 s and the 4 s presentation grace
  (`PhoneCapturePolicy.timeoutBudget`). The "still working" speech is suppressed while a phone photo
  is pending, and the thinking sound pauses while the camera is open.

### What the model is told — `PhoneCaptureScope` + ledger

The router runs each native tool inside a task-local `PhoneCaptureLedger`. `CameraService` records
every phone request's outcome on it. After the tool returns:

- a request that ended without a photo → the outcome's sentence is **prepended** to the tool's own
  result (prepended, not substituted, so a tool that still did something — `parking` saves the spot
  without a photo — keeps saying so);
- a phone photo was used → a short note is appended: "(Photo taken with the phone camera — no
  glasses are connected.)" so the model does not say "through your glasses";
- after one request has ended without a photo, a second request **in the same tool call** fails
  at once with the same outcome (`reading_assist` and `capture_photo` try the stream frame and then
  a shutter photo; a cancel must not open the camera twice).

Sentences (contract, tested):
- cancelled — "The user cancelled the phone camera, so no photo was taken. Nothing was seen — do
  not describe or guess what is in front of them."
- timed out — "No photo was taken within 90 seconds, so the phone camera was closed. Nothing was
  seen — do not describe or guess what is in front of them."
- busy — "The phone camera is already open for another request, so no photo was taken for this
  one. Ask the user to finish or cancel that photo first."
- app not on screen — "No glasses are connected, and the phone camera needs Avenkin open on
  screen, so no photo was taken. Ask the user to open the app and try again, or to describe what
  they see."
- could not present — "The phone camera couldn't open over what is on screen, so no photo was
  taken. Ask the user to close the open screen and try again."

### Field Assist tiles

**Decision: not `.photoThenPrompt`.** That path sends the picture straight to the chat model as an
attachment, which bypasses the job tools: `equipment_lookup` / `manual_lookup` read the nameplate
with **on-device OCR** (the still never leaves the phone) and search the job's manuals;
`safety_assessment` runs the structured HECA with scoring, store, history and PDF; `photo_log`
files the evidence. A Safety Check through `.photoThenPrompt` would also have asked for a *second*
photo when the model then called `safety_assessment`.

Instead, when no glasses are connected, `executeQuickAction` opens the phone camera **before** the
prompt (deterministic, no model round trip) for the tiles in `PhoneCapturePolicy.preCaptureTiles`
— Fault Code, Safety Check and Log Photo. The photo is **staged** on the coordinator (one shot,
120 s lifetime, cleared when the turn ends) and the prompt gains one sentence ("I've just taken
the photo with my phone; use your camera tool to look at it."). The first camera request in that
turn takes the staged photo instead of opening the camera again. Cancelling the camera sends
nothing. With glasses connected the tiles are unchanged.

### Privacy filter

A phone still requested by a tool enters `CameraService` at the source — the same
`capturePhoto()` the glasses still comes from — and leaves through the same accessor:

- tools that read through `filteredStill(for:source:)` get the phone still filtered under **the
  same scope** as a glasses still for that tool (`.toolPhotoCapture`, `.visionAssessment`,
  `.liveSession`, …), and `.unavailable` when the filter cannot run — never the raw pixels;
- `scan_document` and `document_knowledge`'s `ingest_scan` call `capturePhoto()` directly — the
  wearer-photo exemption (2026-09-10). A phone shot the user framed and shot themselves is the
  wearer's own photo, so the exemption covers it exactly as far as it covers the glasses shutter
  and no further;
- `capturePhoto()` files every capture in the Photos album, as it does for glasses stills and for
  the existing phone-camera sheet.

No new consumer reads camera pixels: the coordinator only carries the sheet's bytes *into*
`CameraService`, so the `OutboundFrameConsumer` roster is unchanged, and
`OutboundFrameConsumerTests` must stay green. The routing tests prove the filter runs on a phone
still.

### Glasses-only paths kept

`capturePhoto(allowPhoneFallback: false)` (temple taps, Plan GJ), `capturePhotoSilently()` (Siri
camera intents, the Watch's silent photo, the "capture_photo" built-in action),
`capturePhotoFromGlasses`, `captureAndSharePhoto` (glasses live-preview share button) and
`SubsystemProbes` stay glasses-only: each is a capture the user did not frame on the phone, and a
pocket must never take a hidden shot.

## Phases

**P0 — Pure core.** `PhoneCapturePolicy` (route table, unknown-tool default, framing hints,
pre-capture tiles, timeout budget, tool-result composition), `PhonePhotoOutcome` sentences,
`PhoneCaptureLedger`. Tests: `PhoneCapturePolicyTests`.

**P1 — Coordinator and camera routing.** `PhonePhotoCoordinator` (single pending request, busy,
timeout, app-not-on-screen, presentation watchdog, cancellation, staged photo) with an injected
sleeper and clock; `CameraService` routing; router ledger + budget. Tests:
`PhonePhotoCoordinatorTests`, `PhoneCameraToolRoutingTests` (fake backend, fake phone source, fake
coordinator, fake filter: a tool call with no glasses opens the sheet and never the silent phone
camera; glasses connected never asks; glasses-only tool refuses; a cancel is reported once and not
asked twice; `.cachedFrameOnly` becomes a photo; the phone still is filtered for a filtered scope
and withheld when the filter is unavailable; no tool in scope keeps the silent fallback; the
router prepends the sentence and extends the budget).

**P2 — UI, tiles, descriptions.** Root sheet for tool requests on `MainView` (hint line, watchdog
hook), `executeQuickAction` pre-capture and staging, still-working/thinking-sound handling,
device-neutral descriptions and failure strings. Tests: `CameraToolDescriptionTests` (scrape: no
ask-on-phone tool's source says "glasses camera", "through the glasses", "point the glasses" or
"glasses are connected" outside comments; every tool file that reaches a still is in the table),
`SystemPromptBuilderTests` (existing) stay green.

**P3 — Device checks (owed).** Glasses in the case, glasses on the face, glasses never added — each
with the Fault Code, Safety Check and Log Photo tiles and a spoken "what's this fault code" /
"is this safe" / "read this": the camera opens on the phone, cancel and 90 s timeout are spoken
sensibly, the photo is used once; with glasses on, nothing changes; the locked phone gets the
"open Avenkin" sentence; a sheet already open (e.g. Settings) gets the "close the open screen"
sentence.

## Risks

- **A model that skips the tool.** With the descriptions fixed and the staged-photo sentence, the
  tiles should call the camera tool; if a model answers without it, the staged photo is discarded
  at the end of the turn. Device-checked.
- **Root sheet over another sheet.** The watchdog turns the silent SwiftUI failure into a sentence;
  presenting over every sheet would need a UIKit window and is not worth it yet.
- **Long tool calls.** A longer router budget for one call is only granted with the glasses away
  and only to ask-on-phone tools.

## Decisions

1. **Phone path per tool:** the camera sheet (user frames, shutter) for every camera tool that needs
   a picture; **no tool keeps a silent phone capture** — a voice-initiated tool cannot know the
   phone is pointing at anything. Silent capture stays only on the app's own non-tool paths where it
   already existed and is announced. The table is `PhoneCapturePolicy`.
2. **Waiting:** a continuation-backed request on `PhonePhotoCoordinator`, 90 s timeout, one pending
   request at a time, a second request **rejected** with a sentence; app-not-on-screen and
   could-not-present end at once.
3. **Cancel / timeout → model:** a fixed sentence per outcome, prepended to the tool's result; a
   second request in the same call is not asked.
4. **Descriptions:** device-neutral ("the camera — the glasses when connected, otherwise the phone")
   for ask-on-phone tools; glasses-only tools keep accurate glasses wording; a scrape test holds it.
5. **Field Assist tiles:** not `.photoThenPrompt`; with no glasses, the phone camera opens first and
   the photo is handed to the tool the prompt calls (Fault Code, Safety Check, Log Photo). With
   glasses, unchanged.
6. **Privacy:** phone stills enter at `CameraService` and leave through the same accessor, scope
   and filter as glasses stills; the `capturePhoto()` wearer-photo exemption covers a phone shot
   the user framed exactly as far as the glasses shutter and no further. No roster change.
7. **Glasses-only kept:** temple taps, silent Siri/Watch captures, glasses share, probes, and the
   live-stream tools in the table.
8. **Announcement:** the open camera is the announcement for the user; the model is told by the
   appended note so it never says "through your glasses".

## Out of scope

The non-tool silent phone fallbacks (the voice vision-intent turn, remote-invoke photos, the
developer MCP server's `see_glasses`) — each already announces the phone camera; moving them onto
the sheet is a follow-up. Phone video for the live-stream tools. Choosing the front camera.
