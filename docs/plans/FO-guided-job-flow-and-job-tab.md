# Plan FO — Guided Job Flow and the Job Tab

**Status:** 🚧 Drafted 2026-09-21; evidence-at-close addendum (§5, P2a/P2b) added 2026-09-21;
**P0 implemented 2026-09-21** (inventory below + the typed tab identifier);
**P1 implemented 2026-09-22, headless and wired into Direct mode** — see *P1 as built* below;
**P2 implemented 2026-09-22** — the Job tab, verified headless and on a simulator (accessibility
audits in three states at the default and largest text sizes, screenshots in both appearances); see
*P2 as built* below.
**P2a implemented 2026-09-22** — photo evidence at close, verified headless and on a simulator; see
*P2a as built* below.
**P2b implemented 2026-09-22** — clips as evidence, verified headless and on a simulator; see
*P2b as built* below.
**Owner addendum 2026-09-22 (§6–§9):** a spoken job debrief in the car, a brief before site with a
hand-off to the technician's maps app, a job that arrives by email as an `.ogjob` file, and
customer sign-off on the phone — P2c and a P3 split into P3a / P3b / P3c below.
**P2c implemented 2026-09-23** — customer sign-off, verified headless and on a simulator; see
*P2c as built* below.
**P3b implemented 2026-09-23** — the job debrief on the phone and in the car, the summary schema
and its validation, `WorkRecord.Debrief`, the addendum as a second document, and the spoken send
with its delivery queue; verified headless and on a simulator. No car and no model. See *P3b as
built* below.
**P3a implemented 2026-09-23, headless** — one guided-job seam applied by both live backends,
Field Assist wired into OpenAI Realtime for the first time, a lens cue for the two questions, a
read-only CarPlay Jobs list and read-only job state on the watch; see *P3a as built* below. No
device, car, glasses or watch run. P3b, P3c and P4 unbuilt.
The voice-turn reliability fixes
from the same field report (wake word re-arm, self-interrupted speech, `new_topic` misfire, short
wake phrases, and the narrow "keep the saved thread while a field session is active" rule) landed
alongside this draft in the same PR; they are a **prerequisite**, not part of this plan, and a
device run confirming them is still owed.
**Trigger:** A pilot technician on build 407 asked for three workflow changes: one continuous chat
per job, the assistant asking for the job number by itself when a job starts, and a confirmation
when the conversation moves to different equipment. The stated bar: *the workflow should guide the
technician automatically, without requiring familiarity with AI or chat apps.*

## Outcome

A technician with Field Assist enabled opens the app and sees a **Job** tab. One tap (or one spoken
phrase) starts a job; the assistant asks for the job number and records what it hears; everything
said, measured, photographed and cited until the job is closed lives in one thread, reviewable
later under that job number. If the technician starts talking about a different unit, the assistant
asks whether the previous job is finished before anything is re-scoped. Closing the job reads back
the record, lets the technician pick which photos and clips go with it, and offers delivery. None of
this requires knowing what a "chat", "thread" or "session id" is.

## Verified starting point (main @ build 408)

- `FieldSession.jobReference` exists, persists, and flows into `WorkRecord`, delivery file names
  and summaries. `FieldSessionTool` has `set_job_reference` (added in #521). `startSession(…,
  jobReference:)` accepts one, but the tool's `start` action never passes it and its reply
  ("Started … Session id: 1a2b3c4d.") neither asks for a job number nor tells the model to. Whether
  the technician is asked is left to the model's initiative.
- `FieldSession` has **no thread id field**, and `FieldSessionService` never mentions
  `ConversationStore`. The coupling runs the other way and is one line: `returnToWakeWord()` asks
  `ConversationThreadContinuityPolicy.shouldEndSavedThread(…, fieldSessionActive:)` — the
  accompanying fix's narrow rule, already shipped — before ending the thread. The other coupling is
  `FieldSessionService.recordConversationTurn`, an event-log dedup hook. This plan replaces the
  narrow rule with an explicit binding.
- **Correction to the draft:** a saved thread does *not* live "exactly as long as
  `AppState.inConversation`". The two are unrelated pieces of state. `inConversation` is a mic flag,
  never `@Published`, and has no reference to `ConversationStore` at all; the thread is
  `ConversationStore.activeThreadId`, created lazily on the first turn's text and restored at launch
  if under two hours old. A thread routinely outlives `inConversation` — see the inventory below.
- `FieldSessionService.setEquipment` **silently re-scopes** when the recognised heading changes:
  new `continuityScope`, procedure runner dropped (FM). Correct for continuity, but nobody is asked
  whether the previous job is finished, and a forgotten open job keeps accruing billable time.
- The tab bar (`MainView.swift`) is Voice / Modes / Chat / Settings, `Tab(value: Int)`. Field
  Assist today is reachable through a quick action, Settings → Field Assist, and tool calls. There
  is no surface that shows "the job I am on" as a first-class thing. `WorkRecordSurface`,
  `EquipmentSurface`, `ManualPageSheet` and the session history exist as components.
- `Config.fieldAssistActive` already gates the feature (licence + toggle).

## Decision: a Job tab, shown only when Field Assist is active

**Yes.** Reasons, on the merits:

1. The pilot audience is technicians, not chat-app users. The thing they think in is *the job*.
   Today the job is invisible unless you ask the assistant about it; the Chat tab shows a flat list
   of conversations titled by their first sentence, which is the wrong index for this user.
2. A fifth tab costs nothing for everyone else: it appears only when `fieldAssistActive`, so the
   consumer/accessibility experience is unchanged. Five is within the platform's comfortable limit.
3. It gives the guided flow a home. "Start job", "job number", "current unit", "close job" and
   "past jobs" need buttons somewhere for the moments voice fails (noisy plant room, customer
   present), and Settings is the wrong place for operational controls.
4. It gives review a home: past jobs listed by job number/date, each opening its single thread and
   its work record.

Constraints: the Voice tab stays the primary capture surface (the capsule stays primary — existing
UI decision); the Job tab is a *dashboard and review* surface plus explicit controls, not a second
chat UI. It must not appear, flash, or reorder tabs for users without Field Assist, and a licence
lapsing mid-job must not strand an open job (tab stays while a session is active).

## Scope and invariants

- Never end, switch, or start a job without the technician's say-so. One job may cover several
  units; equipment change is a *question*, never an automatic switch.
- A job number is recorded exactly as given — never invented, normalised or guessed from context.
  "I don't have one" is a valid answer and is recorded as such (no nagging loop).
- Guidance is deterministic app behaviour, not model goodwill: the prompts that must happen
  (ask for job number; confirm job change) are driven by app state and survive a model that
  ignores instructions, a provider switch, and a context compaction (FM).
- Job threads are ordinary saved conversations; deletion, export, privacy scopes and HIPAA
  restrictions keep their existing semantics. No second conversation store.
- Works in Direct mode first. Gemini Live / OpenAI Realtime get the same state machine through
  their setup/context snapshots in a later phase; they are not silently covered.

## Design

### 1. Job ↔ thread binding
`FieldSession` gains `conversationThreadId: String?` (decode-if-present, so old sessions load).
Starting a job binds the active thread, or starts one if none. While a job is active, every
Direct-mode turn — wake word, tap-to-talk, typed — resolves to the bound thread through one pure
function, `JobThreadPolicy.thread(for:)` (inputs: active session, bound id, whether that thread
still exists, explicit user "new chat"). Ending/returning to wake word no longer ends a bound
thread. An explicit "new chat" during a job asks first ("You're on job 1005 — keep this in the job,
or start a separate chat?"). A restored in-progress session re-binds on launch. The thread's title
becomes "Job 1005 — Lennox SLP99" once known, not the first sentence.

### 2. Job-number prompt
A small pure state machine, `JobIntakeState`: `needsReference → asked → recorded | declined`.
`FieldSessionTool.start` accepts `job_reference` (so "start job 1005" is one step) and, when it is
absent, returns a result that states the job number is outstanding. Independently of the model,
the app speaks the intake question after the start confirmation when state is `needsReference`,
and treats the next utterance as the answer candidate — confirmed by read-back ("Job 1005 —
right?") because speech-recognised digits are error-prone. `declined` is logged in the audit
record. The Job tab shows the same state with a text field, so it can be typed instead.

### 3. Possible change of job
Pure `JobChangeDetector`: compares a newly recognised `EquipmentIdentity` (or a spoken
model/serial that resolves through `VaultModelIndex`) with the session's current equipment and
returns `.same | .additionalUnit(candidate) | .unclear`. On a candidate, the app **holds** the
re-scope and asks: *"That sounds like a different unit. Is job 1005 finished, or is this another
unit on the same job?"* Answers: same job → re-scope exactly as `setEquipment` does today, and
record the unit on the job; finished → run the normal close flow, then start a new job (intake
asks for its number); not sure/no answer → nothing changes, ask again at most once per candidate.
A wrong nameplate read must not trigger a close: the question is only raised on a confident
identity (same threshold EL uses to set equipment at all).

### 4. Job tab
Shown when `fieldAssistActive || activeSession != nil`. Tabs move to a typed identifier instead of
bare `Int` values first, so inserting one cannot shift persisted selections or deep links.
- **No active job:** vault in use, a large *Start job* button (optional job-number field),
  past jobs by job number/date/outcome.
- **Active job:** job number (editable), elapsed/billable state with pause/resume, current unit(s),
  task list and readings from `WorkRecordSurface`, *Open conversation* (the bound thread),
  *Read back*, *Close job* (→ existing export/delivery flow).
- **Past job:** the work record, its thread (read-only), re-send delivery.
- A "Wake word" row is **not** duplicated here — the accompanying fix puts it in Field Assist settings.
VoiceOver order, Dynamic Type and the HUD-less case are acceptance criteria, not afterthoughts.

### 5. Evidence review at close (photos and clips in what gets sent)

Owner request, 2026-09-21: the technician wants to send evidence of the fault and of the fix. The
moment for that is the end of the job — *Close job* walks through choosing the pictures and clips
before anything is rendered or sent. Owner decisions the same day: video clips are **in scope**;
full-size originals are offered through the share sheet; Fault/Fix marking is **optional**.

**Verified starting point.** `photo_log` already saves a filtered still into the session's `photos/`
directory with a caption, records it on the current task's `Evidence.photos` (or the session's
`jobEvidence` when no task is open), and queues a `.photoUpload` for the offline sink. But nothing
the recipient gets contains a picture: `SessionExporter` prints each photo as a text bullet
(`"• \(photo.path)" + caption`), and its private `PDFLayout` has no image-drawing method at all;
`DeliveryRequest.Attachment.Kind` is `pdf | json` only. Photos taken any other way during a job (a
plain capture, a picture added in chat from the phone) are not attached to the job at all —
`attachPhoto` has exactly one caller, `PhotoLogTool`. There is no clip/video evidence on a session:
`Task.Evidence` is `readings`, `photos`, `citationsOpened`, `pagesVerified`.

**Design.**
- *During the job, capture stays cheap.* Every photo taken while a job is active — `photo_log`, a
  plain capture, a phone-camera or library picture added from the Job tab or the job's thread — lands
  in the job's evidence with its time, task and caption. No question is asked mid-job. Filtering is
  not inherited: `photo_log` goes through `CameraService.filteredStill(for: .toolPhotoCapture,
  source:)`, but `capturePhoto()` is deliberately exempt (the wearer's own framed shot), and the
  phone-camera path (`handlePhoneCapture`) is filtered by neither. So each newly attached route must
  ask for a filtered still explicitly — `filteredStill(for:source: .photoOnly)` for the shutter
  image, the same privacy filter applied to a phone-sourced picture before it is stored — or the job
  would carry unblurred bystanders while `photo_log` does not.
- *Close job → evidence review.* The close flow gains one step before the read-back and delivery:
  a grid of the job's photos and clips, grouped by task, newest last. Each item can be included or
  left out, captioned/re-captioned, and **optionally** marked **Fault** or **Fix** — never prompted,
  never required (pure `EvidenceSelection` model: item id, included, role?, caption, order).
  Default: everything captured through `photo_log` included, everything else offered but not
  pre-selected. Skipping the step is one tap and sends the text-only record exactly as today. By
  voice: "include all", "skip photos", and a per-item yes/no read-out for the hands-busy case; the
  HUD-less/VoiceOver path is an acceptance criterion.
- *The PDF carries the pictures.* `SessionExporter` renders selected photos inline under their task,
  Fault before Fix before unmarked, downscaled (long edge and JPEG quality fixed by a pure
  `EvidenceImageBudget` so a twenty-photo job still produces a mailable PDF), each with caption and
  timestamp. `PDFLayout` gains an image method — it has only `heading`/`section`/`body`/`spacer`
  today. Unselected photos stay in the on-device record and the JSON's `photos` list (marked
  `included: false`) but are not rendered and never leave the device through delivery.
- *Full-size originals by share sheet.* The review step and a past job's record both offer "Share
  full-size photos" for the selected items: the stored (already privacy-filtered) originals go to
  the system share sheet, so the technician picks the route (AirDrop, Files, Mail, a job system's
  share extension). The PDF keeps the downscaled copies; the composer-based delivery channels are
  not asked to carry originals.
- *Clips.* A PDF cannot carry video. A selected clip is sent as its own attachment where the channel
  can take it, bounded by a per-channel size budget; over budget, the flow says so and offers the
  share sheet for that clip instead of silently dropping it. `DeliveryRequest.Attachment.Kind` gains
  `video`; `DeliveryChannel.carriesAttachments` — today a plain `Bool` that zeroes attachments for
  channels that cannot carry files — grows a size-aware check. The PDF lists each included clip
  (caption, time, duration) under its task so the record is complete even when the clip travels
  separately. Clip *capture* during a job ("record a clip of this") subscribes to
  `outboundFrames.publisher` like every other camera-rate consumer (bystander blur shared via
  `OutboundFrameRelay`), registers in the `OutboundFrameConsumer` roster, is length-capped, and is
  stored under the session like photos.
- *Face blur follows the global setting, and says so.* `Config.privacyFilterEnabled` is one app-wide
  toggle with no per-call override, and the copy stored for a filtered route is the filtered one —
  raw pixels are never kept — so nothing can be un-blurred at review time. The Job tab and the
  close-job review show the current state in plain words ("Face blur: On/Off", linking to the
  setting), and an item captured while the filter was on is labelled as such in the review grid so
  the technician knows what the recipient will see. There is no per-job or per-photo override
  (owner decision 2026-09-21). The filter touches faces only; nameplates, gauges and fault sites are
  unaffected.
- *Invariants.* Nothing is sent without the technician's Send tap (EM) — enforced by the composer
  sheet on `AppState.deliveryComposerRequest`, with `completeDelivery` recording `.sent` only on a
  real send outcome; the share sheet is likewise only ever opened by a tap. The selection is part of
  the work record, so a re-send from a past job reproduces the same PDF. HIPAA/medical restrictions
  and the privacy-filter scope rules are unchanged; any new store registers with `DataStoreRegistry`.
  **Deletion is an open problem, not an invariant:** there is no way to delete a field session
  today, and `DataStoreRegistry` marks `.fieldSessionLogs` `deleteAll: .unavailable("a session log
  is the engineer's compliance record")`. Adding media does not change that posture, but it raises
  the stakes, so P2a records the media under the same store and the deletion question moves to the
  open list rather than being answered here.

### 6. Job debrief in the car (CarPlay)

Owner request, 2026-09-22: after a job, the technician drives to the next one and wants to talk the
job over with the assistant — what they found, what they'd flag, what base should know — and have
that captured on the job without touching the phone. CarPlay is a first-class surface in this app;
P0's inventory found its new/resume conversation paths already routed through the P1 chokepoint
(verified again at build 417: `CarPlaySceneDelegate` and `WatchConnectivityManager` reach
`GuidedJobFlow` for both, and neither touches `ConversationStore` directly).

**What it is.** A **debrief**: a voice conversation about one chosen job, whose outcome is a short
structured summary appended to that job's record. It is not a re-opening of the job — time on the
job does not restart, tasks are not re-scoped, equipment is not changed — and it is not a new job.

**Design.**
- *Job selection on CarPlay.* A "Jobs" list (`CPListTemplate`) reachable from the app's CarPlay root:
  the active job first if there is one, then recent past jobs by job number · date · outcome (a
  declined number shows "No job number"). Selecting a past job offers one action, **Debrief**, and
  reads the job's name aloud. Selecting the active job resumes its bound conversation exactly as the
  phone would (P1's `requestResume`), no new mode. Nothing on the list is more than one glance: job
  number and date only; the work record is never rendered on the car screen.
- *The debrief conversation.* Starts a debrief turn sequence bound to the job's thread (P1's
  `JobThreadPolicy` gains a `.debrief(jobId)` source; turns land in the job's own conversation so
  review later shows them in place, marked as debrief). The assistant is told, through the same
  bounded snapshot FM/FO use, which job this is, its equipment, tasks, readings and outcome, and
  that it is in a debrief: listen, ask at most one clarifying question at a time, never propose
  work, never treat anything said as a completed task. Voice only — no HUD, no phone screen needed,
  wake word or steering-wheel button as the app already supports.
- *Capture, read back, save.* When the technician says they're done (or on silence + confirmation),
  the app asks the model for a summary in a fixed schema — `findings`, `follow_ups`, `for_base`,
  `parts_or_materials`, `customer_notes` — each a list of short verbatim-leaning items, each citing
  the debrief turn it came from. The app reads the summary back; the technician says "save", "change
  <item>" or "scrap it". Only a spoken **save** writes a `WorkRecord.Debrief` entry (dated, source
  turn ids, model provenance) to the job. Unsaved debriefs leave the turns in the thread, marked
  unsaved, and nothing on the record. The record's PDF/JSON gain a **Debrief** section; the Job tab's
  past-job page shows it and offers **Send addendum** through the existing delivery flow (the same
  channel and recipients as the original send, editable) — never sent automatically. From the car
  the same send is spoken, immediate or staged as described below.
- *Updating and sending from the car* (owner question, 2026-09-22). **Update: yes** — a spoken
  "save" is the write; the debrief is on the record before the car is parked. **Send: yes, by
  voice, within what the channel can do without the phone.** After a save (or at any time on a
  selected job: "send the job", "send the report"), the app names what would go and to whom — "the
  work order for job 1005, with the debrief addendum, to base by email" — and only a spoken
  **"send it"** counts as the Send tap EM requires. Then:
  - a channel that needs no phone screen — the configured endpoint sink, or a share target the
    organisation has set as the job-report route in Settings — sends immediately and the app says
    when it has gone (or that it is queued offline, as the existing store-and-forward queue does);
  - Mail and Messages need their composer on the phone, which CarPlay cannot present. The send is
    **staged**: everything is prepared and queued as "ready to send", the app says so ("Ready on your
    phone — one tap when you stop"), the Job tab shows the staged send at the top with one **Send**
    button that opens the composer already filled, and a notification on the phone offers the same.
    Nothing goes without that tap. A staged send survives restart and is cancellable.
  Recipients are never taken from speech: they come from the job's previous delivery, the vault's
  delivery settings, or the org profile; a spoken new address is refused with "add it on the phone".
- *Several jobs on one journey* (owner, 2026-09-22). A drive may cover the whole day's jobs. The
  technician moves between them by voice — "next job", "debrief job 1006", "the one before that" —
  or from the CarPlay Jobs list at a stop; each debrief is bound to its own job's thread and each
  save writes to its own record, so nothing said about one job can land on another (the app names
  the job on every switch: "Job 1006, Carrier rooftop, closed at 2:15"). Sends accumulate in one
  **delivery queue**: immediate-channel sends go as they are spoken; staged ones line up in order.
  The Job tab shows the queue as one card — "3 reports ready to send" — with **Send all** (opens
  the composers one after another, each pre-filled; a cancelled one stays queued) and a per-report
  Send; the phone notification offers Send all. "What's waiting?" reads the queue back in the car.
  The queue is persisted, survives restart, and is per device; it is separate from the offline
  store-and-forward queue, which is for sends already authorised to an endpoint.
- *Invariants.* Spoken items are the technician's report, not verified facts: the schema keeps them
  as reports with a source, and the summary never promotes a "should check X" into a completed
  check or a reading. One debrief per session may be repeated; each is its own dated entry. A job
  whose record was already delivered keeps the original PDF unchanged; the addendum is a second
  document. A debrief never alters a customer sign-off (§9): the summary the customer put their
  name to is frozen at the moment they signed. Medical/HIPAA restrictions and audit logging apply
  as to any job turn. Works on the phone too (the Job tab past-job page gets the same **Debrief**
  action) — CarPlay is the reason, not the only surface.
- *Driving safety.* Nothing to read, nothing to tap during the conversation; the only list is the
  job picker, shown before the drive or at a stop as CarPlay's own templates allow; the summary
  read-back is spoken, and "save" is spoken. If the app cannot be sure which job was meant (two
  with the same number), it asks by date, never guesses.

### 7. Brief before site (the next job, spoken on the way there)

Owner request, 2026-09-22: on the way to a job the technician should get a briefing — the site's
known equipment, the fault report against likely causes, what the organisation has learned about
that kit, anything else on file — and be handed to their maps app for directions.

**Verified starting point** (read against main at build 417). `FieldSession` carries
`jobReference`, equipment (once read), tasks, evidence — nothing about the *site*: no customer,
address or fault report, because today a job is born on site by voice. `get_directions` already
opens Apple Maps or Google Maps with a destination (`comgooglemaps` is in
`LSApplicationQueriesSchemes`; `waze` is not); there is no preferred-maps setting and no Waze.
Session history is a flat list sorted by start date and is not indexed by site or serial.
Organisation learnings are [FP](FP-team-learnings.md), drafted and unbuilt.

**Design.**
- *A job ahead.* A job can now exist **before** it starts: `FieldSession` gains an optional
  `site` (customer name, address, contact — decode-if-present) and `faultReport` (the words the
  office or customer gave, verbatim, with its source) and a `scheduled` state alongside active /
  paused / ended. Created by voice ("next job: 1007, no heat, Smith Street, the Lennox furnace we
  did in May"), typed on the Job tab (Upcoming section), or — when [BL](BL-ops-platform-agent-bridge.md)
  lands — pushed by the office. Starting it on site is the same `startJob`, carrying its site and
  fault report; the intake still confirms the number. Nothing about a scheduled job is guessed:
  fields the technician did not give stay empty and the brief says so.
- *The brief.* One spoken action — "brief me on the next job", the CarPlay Jobs list's **Brief**
  action on an upcoming job, or automatic when CarPlay connects with an upcoming job selected
  (off by default; a setting). Assembled by the app from sources it can cite, in this order, each
  section skipped aloud when empty:
  1. **Site and history** — customer, address, contact; previous jobs at this site or on this
     serial/model (session history gains a site/serial index), with their outcome, open follow-ups
     and any debrief items (§6) — "Last visit 14 May, job 0993: replaced pressure switch; follow-up
     noted: check flue length."
  2. **Known equipment** — models on file for the site and what the vault has for them
     (`VaultModelIndex` sections: nameplate spellings, unit size code, accessories) so the
     technician knows what to look for before the panel is off.
  3. **Fault report against likely candidates** — the report's words matched to the vault's
     error-code and symptom sections and the manual retrieval (EJ's evidence gate, citations
     attached): "The office says E223 and no heat. In the service manual E223 is a low-pressure
     lockout — three listed causes: blocked flue, failed pressure switch, condensate trap. Two of
     those were the fix on this model's last two visits." Ranked by evidence, never asserted as
     the diagnosis; every candidate carries its citation, and an unmatched report says "nothing in
     the manual matches those words."
  4. **What the crew learned** — FP learnings for the model/site when FP exists; until then the
     section reads from the site's past debriefs and follow-ups only (the hook is the same
     `RetrievalSource` seam so FP slots in without touching the brief).
  5. **Parts and prerequisites** — parts the candidates call for (`VaultPartsIndex`), and the
     vault's safety prerequisites for those procedures.
  The brief is a `JobBrief` value (pure, testable), rendered to speech with a spoken length cap
  and "say more about <section>" follow-ups; the full brief is on the Job tab's upcoming-job page
  and saved on the job so the site visit's model context starts from it (the FM snapshot gains a
  bounded brief section). Sources: vault, manuals, this device's session history, FP when built —
  never the open web unless the technician asks, and then labelled as such.
- *Directions.* "Take me there" / the CarPlay **Directions** action hands the site address to the
  technician's **maps app of choice** — Apple Maps, Google Maps or Waze, chosen once in Settings
  (`preferredMapsApp`; `waze` added to `LSApplicationQueriesSchemes`; falls back to Apple Maps and
  says so if the chosen app is missing). From CarPlay the hand-off uses the CarPlay scene's
  own open-URL path so the maps app takes the car screen; the brief can keep speaking. The
  existing `get_directions` tool gains the preference and Waze rather than a second tool.
- *Invariants.* A brief cites or says "nothing on file"; it never invents history, models or
  causes. It is advisory context, not a task list: nothing in it becomes a task until the
  technician creates one on site. Scheduled jobs count no time. Medical/HIPAA: site and customer
  fields are personal data — covered by the session store's existing protection, listed in
  `DataStoreRegistry`, included in deletion semantics exactly as the session is.

### 8. A job that arrives by email (open with Field Assist)

Owner request, 2026-09-22: the office emails the technician the job; tapping the attachment opens it
in the app, which loads it as the job ahead (§7).

**Verified starting point.** The app declares no `CFBundleDocumentTypes` and no
`UTExportedTypeDeclarations` at all today, so there is no document type to extend — the format and
its registration are both new.

**Design.**
- *A job file.* A small JSON document, `.ogjob` (registered as an exported UTI with
  `CFBundleDocumentTypes`, so Mail, Files and Messages offer **Open with OpenGlasses**): format
  version, job reference, site (customer, address, contact), fault report verbatim, known
  equipment (model / serial if the office has them), scheduled time, notes, optional attachments
  by reference (never embedded manuals), and an optional organisation signature over the whole
  document. **The key that signs a job file is the organisation's, carried in its
  [CT](CT-org-configuration-profiles.md) profile — not the vendor's content-signing key** that
  vault packs and skill packs are verified against; an office signs its own jobs, and the app has
  to be told whose signature to expect before it can check one. Signing and verification therefore
  land with P3c and CT rather than here. A publisher-side helper (`Scripts/make-job-file`, and a
  one-line spec in the vault guide) lets an office system or a person produce one; the ops bridge
  (BL) will use the same format when it pushes jobs.
- *Opening it.* The app receives the file through the scene's open-URL/document path (also
  `openglasses://job?…` is **not** offered — a URL cannot carry a signed document safely and an
  email link is a phishing shape; files only). It validates schema, size (≤ 64 KB) and content
  (text fields only, length-capped, no HTML), then shows a **review sheet**: job number, site,
  fault report, equipment, "Signed by <organisation>" or **"From email — not signed; check it's
  from your office"**, and one button, **Add to upcoming jobs**. Nothing is created without that
  tap. Same job reference already on the device → "Update job 1007 or keep both?" — never a silent
  overwrite. In HIPAA/medical mode an unsigned job file is refused (an org profile can require
  signing anywhere).
- *After that* it is a scheduled job exactly as §7 defines: it appears under Upcoming on the Job tab
  and the CarPlay Jobs list, can be briefed, navigated to, started on site (the intake confirms the
  number it already has), debriefed and sent. The job record keeps the file's provenance (source:
  email/file, signer, received-at) in the audit log and the export.
- *Invariants.* Receive only — the app never emails a job file out. A job file cannot start a job,
  change equipment, create tasks or send anything; it only proposes an upcoming job. Fields the
  office left out stay empty. Personal data in the file is under the session store's protection
  from the moment it is saved.

### 9. Customer sign-off on the phone

Owner request, 2026-09-22: at the end of the job the customer signs on the technician's phone.

**Verified starting point.** There is **no customer-facing subset of the record today**, and the
draft's "the same customer-facing lines the PDF prints" describes something that does not exist:
the work order prints `WorkRecord.summaryLines` whole, which carries the technician's completion
notes, why each task was recommended, escalations, verified manual pages and the evidence phrases.
So the customer summary is a *new* derivation over the record — work done, parts used, time or
billing units — and the acceptance block prints exactly it. The existing Work Record section of the
PDF is unchanged: the customer signs the summary, not the whole work order.

**Design.**
- *Where it sits.* A step in the close flow after the evidence review and the read-back and
  before delivery: **Customer sign-off**, optional per job (skip is one tap and the record says
  "not signed"), and available again from a past job until the report has been sent.
- *Hand-over mode.* The technician taps **Hand to customer**; the phone shows a full-screen,
  customer-facing sheet and nothing else: the organisation/technician name, job number, date, the
  **customer summary** (work done, parts used, time or billing units; **never** internal notes,
  fault candidates, the brief or debriefs), an optional one-line customer comment, a **name**
  field, a large **signature pad** (PencilKit canvas; finger or Pencil), and **Done**. The sheet
  cannot be dismissed by a swipe; leaving it needs the technician's confirmation ("Cancel
  sign-off?"), and it suggests Guided Access in a footnote for organisations that want the phone
  locked to it. Dynamic Type and VoiceOver apply; a customer who cannot sign can type their name
  and tap **Confirm** instead (recorded as typed, not drawn).
- *What is recorded.* `WorkRecord.SignOff` (decode-if-present): the customer's name, the drawing
  as PNG plus its stroke data, the typed comment, the time, the method, and a **digest of exactly
  what was on the sheet** (the customer summary text) so the record can show what was agreed to.
  The signed summary is frozen: later debrief addenda (§6) are separate documents and never alter
  it. The PDF gets a **Customer acceptance** block — summary, name, signature image, time, method —
  and the JSON carries the same minus the image (a file reference). The audit log records sign-off,
  a decline and any cancel.
- *Invariants.* Sign-off never sends anything; delivery is still the technician's Send. The
  signature is personal data: stored under the session's protected store, listed in
  `DataStoreRegistry`, never shown outside the sign-off sheet, the PDF and the past-job page,
  never used for matching or anything else. This is a record of acceptance, not a legal
  e-signature service — the copy says "signed on the technician's phone" and makes no claim
  beyond that. An organisation can make sign-off required (close blocked until signed or an
  explicit "customer declined to sign" reason is recorded). That switch is
  `Config.organizationRequiresCustomerSignOff`, **a documented stand-in that CT P1 replaces** —
  written the way FS PR2 wrote `Config.organizationAllowsUnsignedVaults`: a key with a stated
  default, read by the behaviour it governs, and no CT machinery ahead of CT.

## Phases (one PR each)

- **P0 — inventory and seams.** ✅ **Implemented 2026-09-21.** Every place a thread is
  started/resumed/ended and every entry point that starts, re-scopes or ends a field session,
  mapped in *P0 inventory* below — including six findings that change P1's scope. `MainTab`
  replaces the bare-`Int` tab identifier, with the legacy numbers frozen; no visible change.
- **P1 — deterministic core, headless.** ✅ **Implemented 2026-09-22.** `JobThreadPolicy`,
  `JobIntakeState`, `JobChangeDetector`, the `FieldSession` fields + migration test,
  `FieldSessionTool.start` accepting `job_reference`. Wired into Direct mode. See *P1 as built*.
- **P2 — Job tab.** ✅ **Implemented 2026-09-22.** The three states above over existing components;
  the past-jobs list; UI audits with Field Assist off (tab absent) and on (three states, default and
  AX5 text). See *P2 as built*.
- **P2a — photo evidence at close.** ✅ **Implemented 2026-09-22.** See *P2a as built*. Headless first: `EvidenceSelection`, `EvidenceImageBudget`,
  job-scoped attachment of photos from every capture route (each asking for a filtered still in its
  own right), `SessionExporter` inline rendering, the selection persisted in the work record
  (decode-if-present) and honoured on re-send. Then the close-flow review step in the Job tab with
  its voice path, and "Share full-size photos". Tests are the gate: PDF contains the selected images
  and none of the unselected; Fault → Fix → unmarked ordering with marking absent entirely also
  valid; size budget holds at 20+ photos; skip reproduces today's output; re-send determinism;
  every newly attached capture route stores a filtered copy; the share-sheet item list is exactly
  the selected originals.
- **P2b — clips.** Length-capped clip capture as a rostered `OutboundFrameConsumer` on the blurred
  relay, stored under the session; clips in the review grid; `video` attachment kind with the
  per-channel size budget and the share-sheet fallback; clip lines in the PDF. Tests: roster/guard
  suites stay green, over-budget never silently drops, re-send determinism.
- **P2c — customer sign-off.** ✅ **Implemented 2026-09-23.** See *P2c as built*. Independent of CarPlay; small; first in line after FS. The
  `SignOff` model and the customer summary's digest, the hand-over sheet, the close-flow step,
  past-job re-entry, the PDF's Customer acceptance block, the JSON, the audit events, the
  organisation "required" stand-in and the `DataStoreRegistry` entry. Tests: the digest matches the
  rendered summary exactly and excludes internal content; skip / declined / typed / drawn are
  recorded honestly; sign-off never triggers delivery; the signed summary is unchanged by a later
  addendum; required-by-org blocks close until signed or a reason is recorded; an accessibility
  audit of the sheet at AX5. Device acceptance: sign with a finger.
- **P3a — live modes and surfaces.** ✅ **Implemented 2026-09-23, headless.** Gemini Live /
  OpenAI Realtime parity via a shared, refreshable job block; HUD cue for the two questions;
  CarPlay/watch read-only job state (the Jobs list of §6, without Debrief). See *P3a as built*.
- **P3b — debrief.** ✅ **Implemented 2026-09-23.** See *P3b as built*. `JobThreadPolicy.debrief` source, the debrief snapshot/instructions, the
  summary schema + validation, `WorkRecord.Debrief` (decode-if-present), the read-back/save state
  machine (pure, like `JobIntakeState`), the PDF/JSON section, Send addendum, the spoken send with
  the immediate/staged split per channel and the staged-send card + notification on the phone, and
  the CarPlay Debrief action and the phone's. Tests are the gate: summary items cite turns and
  never become tasks or readings; unsaved = nothing on the record; the addendum reproduces
  deterministically; an ambiguous job is asked about; time on job unchanged; a customer sign-off's
  summary is unchanged by an addendum; spoken send — the endpoint channel sends and reports, Mail
  and Messages stage and never send without the tap, spoken recipients are refused, a staged send
  survives restart; several debriefs on one journey each land on their own job and the queue holds
  them in order, Send all opens each composer in turn and a cancelled one stays queued; the CarPlay
  list model (pure) shows number and date only. Device/car acceptance owed to P4.
- **P3c — job ahead, brief, directions, and the job file.** `site`/`faultReport`/`scheduled` on the
  session (decode-if-present), Upcoming on the Job tab and CarPlay, the site/serial history index,
  `JobBrief` assembly with the five cited sections and its spoken renderer, the FM snapshot
  section, `preferredMapsApp` + Waze + the CarPlay hand-off — and §8's `.ogjob` format and
  validator (pure), the UTI/document-type registration, the open path and review sheet, duplicate
  handling, the signature check against the organisation's key from its CT profile, and the
  provenance on the record. Tests: a brief from fixtures cites every claim; empty sections are
  spoken as empty; an unmatched fault report says so; ranking follows evidence; the history index
  finds by site and by serial and never across devices; a scheduled job started on site keeps its
  number, site and fault report; the maps preference table including the missing-app fallback;
  legacy sessions decode; valid / invalid / oversized / HTML-bearing job files; signed vs unsigned
  vs bad signature; a duplicate reference; the HIPAA refusal; a job file never creates tasks or
  starts a job; a fixture `.ogjob` opens on the simulator in the audit. Car, site and device
  acceptance (opening one from Mail on the phone) owed to P4.
- **P4 — device acceptance (owed to a pilot run).** One real job end-to-end by a technician who
  has not been coached: start by voice, number captured, two units on one job, a forgotten-close
  caught by the change question, close and deliver, review later by job number.

## P1 as built (2026-09-22)

Everything under `OpenGlasses/Sources/Services/FieldAssist/Job/`: the four pure types and the one
`@MainActor` coordinator, `GuidedJobFlow`, that composes them and touches the app.

### Decisions the draft left open

- **Binding is lazy, with adopt-if-one-exists.** Starting a job binds the conversation that is
  already open; with none, the first turn's thread is bound. Eager creation was rejected for the
  reason `ConversationContinuity.startFresh` already gives — an empty thread up front litters the
  switcher with conversations nobody had, and a job started from a settings screen and abandoned
  would leave one every time. In practice the adopt path is the normal one: "start a job" is itself
  a turn, so by the time the tool runs its thread exists.
- **"Start a separate chat" detaches rather than unbinds.** The job keeps `conversationThreadId` so
  it can still be reviewed under the job; a new `conversationThreadDetached` flag stops turns
  resolving to it. Unbinding would have lost the job's conversation; doing nothing would have made
  the answer a lie, because the very next turn would have gone straight back into the job's thread.
- **A paused job is still the job.** The binding, the intake and a held change question all key on
  `endedAt == nil`, not `isActive`. `isActive` means "accepting input", and launch-restore pauses
  every recovered session on purpose — reading it there orphaned a crash-restored job's
  conversation on the first tap.
- **A job number is never normalised.** The only text removed is a leading carrier phrase
  ("it's job number 1005" → "1005"), matched ignoring punctuation and case, dropped by whole words,
  and the remainder kept character for character. The read-back shows the result before it is
  written down.
- **Declined does not block delivery** (owner decision, 2026-09-21, now implemented): the record is
  flagged in the audit log, `workRecord()` and the export are untouched, and the question is never
  asked again.
- **Gemini Live's missing `recordConversationTurn` stays a P3 item.** The binding did not close it.
  Closing it means giving the live path an audit hook it has never had, which belongs with the rest
  of the live-mode parity work rather than bolted onto a Direct-mode state machine.
- **The equipment question is raised only where recognition *happened to* the session** — a spoken
  model number, a nameplate the camera read. A spoken correction ("no, it's the 070") and a tap on
  the phone's model list still go straight to `setEquipment`: those are the technician saying which
  machine this is, and a question there would be the app arguing with an instruction.
- **CarPlay and the watch have nowhere to put the question**, so they ask
  `leaveJobThreadQuestion()` and, when there is one, leave the job's conversation alone. The phone
  surfaces (conversation page, its switcher, Chat list, Chat thread) present a shared alert.
- **Spoken strings are plain Swift strings**, as every other Field Assist spoken line already is
  (`EquipmentIdentity.announcement`, the tool results). The one new rendered surface — the
  "keep this in the job?" alert — uses ordinary SwiftUI `Text`/`Button` literals, which the string
  catalog picks up on its own.

### What the draft got wrong

- §1 says the thread's title "becomes *Job 1005 — Lennox SLP99* once known". It cannot become
  anything until a number is known, and there is no sensible title from equipment alone, so a job
  with no number keeps whatever title the store gave it. Renaming is also narrower than drafted: a
  title the wearer chose is never replaced, so only the placeholder, the store's own auto-title and
  an earlier title for the same job are.
- §3's `.unclear` needed a *reason*, because the two cases behave the same but are different facts
  for the corpus: a read that matched several models, and a model-like token the vault mentions in
  prose but never as a machine (a board, a kit part number).
- The P0 inventory's "the quick action is a prompt" is addressed but not by changing its type:
  `AppState.executeQuickAction` starts the job itself for the built-in action and the prompt text
  now says the session is already running. Adding a `QuickAction.ActionType` case would have put a
  creatable "start a field session" row in the quick-action settings picker for everyone.

### Seams P2 calls

On `AppState.guidedJobFlow`:

```swift
@discardableResult func startJob(vaultId: String, assetId: String? = nil,
                                 mode: FieldSession.Mode = .aiOnly,
                                 jobReference: String? = nil) throws -> FieldSession
@discardableResult func closeJob(outcome: FieldSession.Outcome = .resolved) throws -> FieldSession
func supplyJobReference(_ text: String)          // typed on the Job tab
func declineJobReference()                       // "I don't have one", by button
var intakeState: JobIntakeState { get }          // badge the outstanding number
var boundThreadId: String? { get }               // "Open conversation"
@Published private(set) var pendingUnitQuestion: JobUnitChangeQuestion?
func answerUnitChange(_ answer: JobUnitChangeAnswer) async
func leaveJobThreadQuestion(switchingTo threadId: String? = nil) -> JobThreadQuestion?
func confirmLeaveJobThread()
```

`FieldSession` now also carries `conversationThreadId`, `conversationThreadDetached`, `jobIntake`,
`pendingUnitChange` and `visitedUnits` (the multi-unit list §"Open questions" asked about — one
`equipment` plus a list, scoped by FM's continuity scope so the export can partition later).

## P2 as built (2026-09-22)

Two pure types beside P1's (`OpenGlasses/Sources/Services/FieldAssist/Job/`) and five thin views
(`OpenGlasses/Sources/App/Views/Job/`). `JobTabPresence` decides whether the bar carries the tab;
`JobTabModel` derives every state, row, label and button enablement from `FieldSessionService` and
`GuidedJobFlow`. The views hold no job state of their own.

### Decisions the draft left open

- **Position: between Chat and Settings**, not at the end. Settings is the drawer everything else is
  kept out of and stays last; Voice is the capture surface and stays first; the job is content, so
  it belongs with the content tabs. Inserting it there moves only Settings, and nothing in the app
  addresses a tab by position — the UI tests use `AccessibilityAudit.openTab(_:in:)`, which is the
  spoken label. `MainTab.displayOrder` now carries every tab and `visibleOrder(showingJob:)` is what
  the bar is built from, so the four that shipped keep their order exactly.
- **"Not entitled" and "not asked yet" are different answers.** `StoreKitService.hasCheckedEntitlements`
  is false until the store check has run, and a false `fieldAssistUnlocked` before then means
  *unknown*. `JobTabPresence.Decision` therefore has three cases, not two: `.undetermined` draws
  exactly what `.hidden` draws, so the tab can only ever appear, never flash away. A signed
  organisation licence verifies synchronously and never waits on the store at all.
- **An open job outranks the entitlement and the wearer's own switch.** Keyed on `endedAt`, like the
  rest of P1: a licence lapsing mid-visit, or the toggle going off, must still leave the technician
  able to close, read back and send. Only `.job` is ever bounced out of the selection, and only to
  Voice.
- **The two questions are cards in the page, not alerts.** A modal that steals focus is the wrong
  shape for a question a technician may want to leave sitting while they finish tightening
  something. The unit-change card renders `JobUnitChangeQuestion.spoken` verbatim; the
  leave-the-job's-conversation card renders `JobThreadQuestion.spoken` verbatim. The shipped
  `jobThreadQuestionAlert` is untouched on the four surfaces that already use it.
- **"Open conversation" goes through `requestResume`**, never by assigning `activeThreadId` — the
  id-without-history defect P1 fixed on CarPlay and the watch. Selecting the tab needed a seam that
  did not exist: `AppState.openChatThread(_:)` sets a requested tab and a thread for `MainView` and
  `ChatListView` to consume and clear. It is a request, not a second copy of the selection.
- **A past job's conversation is a separate read-only view**, not `ChatThreadView`. That view
  activates the thread it shows the moment it appears, which is right for live chat and wrong here:
  reviewing last Tuesday and then speaking would have appended to last Tuesday. `JobTranscriptView`
  renders the stored messages through the shipped `MessageBubble` with no composer and no activation.
- **Closing lands on the finished job's own page**, which already has the record, the conversation
  and Send report. So "close, check, send" is one movement, and the confirmation step is the natural
  place for P2a's evidence review to slot in.
- **`.ogQuiet` is not used for these rows.** It centres its label, paints it in the secondary label
  colour and swallows a destructive role, which turned four distinct actions — one of which ends the
  job — into four identical grey centred strings. Plain `Form` buttons are leading-aligned, tinted
  and keep their role. Related trap, hit twice: `.foregroundStyle(.primary)`/`.secondary` inside a
  tinted button resolve against the *tint*, so content inside a button row uses `Color.primary` /
  `Color.secondary`.
- **The elapsed line is minute-grained and ticks once a minute** (`JobClock`). The record's exact
  seconds go in the export; a live second counter would redraw sixty times a minute and re-announce
  itself under a VoiceOver cursor. Both phrases (`billableMinutes`, `billableUnits`) are the work
  record's own fields, so the screen and the PDF cannot disagree.

### What the draft got wrong

- §4 says the empty state offers "past jobs by job number/date/outcome" and says nothing about how a
  job with no number renders. A declined or never-asked number is a real state, and a row rendering
  as a blank line is untappable with any confidence, so it reads **"No job number"** — asserted.
- §4's "job number (editable)" understates the intake: the field has to say *which* of the seven
  `JobIntakeState` cases it is in, including "asked, waiting" and "declined", or the technician
  cannot tell whether the app is waiting on them. `JobTabModel.IntakeCopy` is one line per case.
- The tab needed no accessibility identifier: nothing in this app sets one. Every tab and row is
  addressed by its spoken label, which is what makes a VoiceOver user and a UI test walk the same
  tree.

### A P1 defect found and left alone

`GuidedJobFlow.leaveJobThreadQuestion(switchingTo:)` documents itself as "a query, not an action",
and it **writes an audit event every time it is called** (`logThreadQuestion`). P1's four callers all
call it from a tap, so nothing is wrong today — but a view body calling it would fill the session log
with questions nobody was asked. P2 works around it (the card is raised by a tap and held in view
state, never queried during a render) and does not change P1's behaviour. Worth splitting the log
from the query when P3 touches this.

### Slots left for P2a

- A **Photos** section in `ActiveJobView`, marked in place, between the work list and the actions.
- The **close confirmation** is the step the evidence review goes in front of: `JobTabModel.closeJob`
  already takes the record before the session ends, which is what a review of that record needs.
- `PastJobView` is where "Share full-size photos" and the re-rendered PDF land; its Send report
  already re-exports the finished session by id, so a selection persisted on the record is honoured
  by the existing path without another call site.
- The plain "Face blur: On/Off" line is **not** in P2, on purpose — it arrives with the photos it
  describes.

### Verification

Headless: `JobTabModelTests` (40) and `JobTabPresenceTests` (15) new, `MainTabTests` extended to 16.
Full suite 6689 tests, 13 skipped, 0 failures. Simulator: `JobTabAccessibilityTests` (5) runs
`performAccessibilityAudit` on the tab absent, the empty state, the past-job list, a past job, a job
in progress and its controls, and the whole screen again at `AccessibilityXXXL`. No device run.

## P2b as built (2026-09-22)

Clips as evidence. One new recorder (`JobClipRecorder`, beside the P1/P2a types under
`OpenGlasses/Sources/Services/FieldAssist/Job/`), one pure per-channel budget
(`AttachmentBudget` + `ClipDeliveryPlan`, under `Sources/Services/FieldAssist/`), one native tool
(`record_clip`), and the delivery, export and Job-tab work that lets a clip reach a customer
without ever being silently dropped.

### The caps, and the audio decision

- **Thirty seconds by default, sixty at most** (`Config.jobClipDefaultSeconds` /
  `jobClipMaximumSeconds`; the plan's open question asked for defaults to be confirmed on a pilot
  device, and these are stored rather than hard-coded so that confirmation is a setting and not a
  build). Thirty is long enough to show a fault behaving — a compressor short-cycling, a fan
  wobbling, a flame lifting — and short enough that the file still emails. A request longer than
  the maximum is **clamped and said out loud**, not refused: the technician gets the longest clip
  there is and is told what they got.
- **No audio, deliberately.** `VideoRecordingService` does capture microphone audio through
  `CaptureAudioRouter`, so the machinery was there to reuse — but the *policy* around it does not
  transfer. That recorder's audio is something the wearer starts, is told about and stops; a job
  clip is started by a sentence in the middle of a service visit, in a customer's plant room, very
  likely with the customer standing in it. Recording bystander speech onto a file that is then
  attached to a report is a consent question this plan has not asked; it has no equivalent of the
  face blur to fall back on, because there is no way to blur a voice; and in medical/HIPAA mode it
  would put a third party's voice into a compliance record that `DataStoreRegistry` already refuses
  to delete. So v1 is silent, the refusal is written at the top of `JobClipRecorder` rather than
  left as an unset flag, and the tool's own description tells the model the clip has no sound.

### Decisions the draft left open

- **A clip is never pre-selected, whatever route it arrived by.** P2a's default keys on the
  *origin* — a `photo_log` picture is in unless removed, everything else is offered. That rule
  cannot be extended to clips by adding an origin, because the reason is different: a clip is the
  one piece of evidence that may not fit down the channel at all, so sending it is always something
  the technician chose. `JobMediaItem.isIncludedByDefault` is therefore `kind == .photo &&
  origin.isIncludedByDefault`, and the new `.clipRecord` origin answers false as well — belt and
  braces, in the one place a wrong default would put a customer's plant room on a stranger's
  laptop.
- **Scope `.recording`, not a scope of its own.** A `PrivacyFilterScope` classifies a consumer by
  where its pixels go, and a clip is frames written to a file on this device, which is exactly what
  `.recording` already means. What differs from the long-form recorder is the length cap and where
  the file is filed — neither of which is a privacy classification. The roster carries
  `jobClipRecording` as a `.relay`-fed consumer on the `.outboundRelay` tap, and
  `JobClipRecorderTests` scrapes the recorder's own source to prove it names no raw tap and takes
  its publisher as a parameter, plus `AppState`'s one call site to prove that parameter is the
  relay's.
- **The stall window is four seconds, not the recorder's fifteen.** A thirty-second clip cannot
  spend half of itself waiting for a stream that is not coming. The same rule differs in a second
  way: a clip that has never seen a frame is judged from when it *started*, while
  `VideoRecordingService` leaves a never-started recording alone indefinitely. A technician who
  asked for a clip asked for a clip of something they can see.
- **The job closing is noticed by the tick, not hooked onto the four ways a job can close.**
  `isOpenForEvidence` is asked once a second while a clip runs — the same question every other
  evidence route asks before it writes anything — which covers the tool, the Job tab, Settings and
  the guided flow without four hooks that can each be forgotten.
- **The poster frame is the first frame off the relay**, kept at capture and written beside the
  clip as `<clip>.mp4.jpg`. Decoding one out of the file at review time would be a second pass over
  pixels whose blur is already baked in, and would fail in exactly the case where the file is the
  thing that went wrong. It is also what lets a scrolling grid draw a clip without an
  `AVAssetImageGenerator` per row.
- **The clips are partitioned before the PDF is rendered, against a stated reserve.** The work
  order prints which clips travelled and which did not, so a partition that depended on the PDF's
  own size would depend on a file it is printed into. `FieldSessionService.reportFileReserveBytes`
  (3 MB) is the room the PDF and the JSON are given first; the clips take what is left. Stated
  rather than measured, for the same reason `EvidenceImageBudget` is: the same job on the same
  channel has to produce the same report twice, or a re-send is not a re-send.
- **The endpoint sink refuses a clip permanently, with a reason.** It POSTs one JSON envelope per
  op to an endpoint whose upload shape nobody has agreed — the same reason it has always delegated
  photo uploads. Falling through to the local sink would have marked the clip *delivered*, to
  nowhere. `EndpointSyncSink.carriesFiles` is the named seam for the day that changes, and
  `clipOutcome(carriesFiles:)` is the decision, so the branch that matters is provable without a
  network.
- **A clip is queued under its own `OpKind.clipUpload`, not `photoUpload`.** `prunePhotoEvidence`
  deletes the *files* behind delivered `photoUpload` ops under disk pressure, and a clip belongs to
  a session log the store already calls a compliance record. Nothing prunes a clip.
- **A clip with no measured size is never attached.** The honest answer for an unmeasurable file is
  the route with no limit, which is the share sheet the technician taps.

### The budgets, and how honest they are

`AttachmentBudget.standard(for:canSendAttachments:)`:

| Channel | Per file | Total | Notes |
|---|---|---|---|
| Email | 20 MB | 20 MB | Under the ~25 MB most mail providers refuse above |
| Messages | 5 MB | 5 MB | Zero when `MFMessageComposeViewController.canSendAttachments()` says no |
| Share sheet | no stated limit | no stated limit | The destination states its own |
| Endpoint | 0 | 0 | Posts JSON; has never been handed a file |
| WhatsApp / Telegram | 0 | 0 | Opened by URL scheme, which cannot attach |

**These are conservative defaults, not device measurements, and the plan should not be read as
claiming otherwise.** Neither MessageUI composer publishes a limit: Mail accepts whatever it is
handed and the provider refuses it later, and `canSendAttachments()` answers yes or no without
saying how large. The two numbers are `Config` values (`jobReportEmailBudgetBytes`,
`jobReportMessagesBudgetBytes`) precisely so a pilot device can move them without a build. The open
question about per-channel size therefore stays open, narrowed from "what are they?" to "are these
two numbers right?".

### What the draft got wrong

- §5 says `DeliveryChannel.carriesAttachments` "grows a size-aware check". It did not, and should
  not: `carriesAttachments` answers whether a channel can carry a file *at all*, which is a
  property of the channel, while the size question also depends on what the device said about
  Messages and on how large the report itself is. Making one boolean answer both would have put
  the device's answer inside an enum that has no way to ask. The size lives in `AttachmentBudget`,
  which takes both as inputs, and `carriesAttachments` is unchanged.
- §5's "a selected clip is sent as its own attachment where the channel can take it" is right about
  the mechanism and silent about the *order*. The order is the design, and getting it wrong
  produces a PDF that describes a delivery that did not happen: partition first, render second,
  attach third.
- P2a's "slots left for P2b" said a clip "needs a line rather than an image, which is a branch in
  `SessionExporter.drawEvidence` and nothing else". It was one branch there plus the heading (a job
  with clips reads "Photos and clips"), the count the image budget is derived from (a clip must not
  shrink the pictures, since it is not one of them), and the JSON's own `clips` list — the last of
  which did not exist at all.

### What is on screen

- The Job tab's Photos section becomes **"Photos and clips"** the moment the job carries one, and
  stays "Photos" otherwise. The kit's copy allowed it: the heading is an authored `Text`, and
  `EvidenceReviewModel.sectionTitle` is the single place that decides. The close-job review's title
  follows the same rule — "Photos for the report" becomes "Evidence for the report".
- **Record a clip** sits in that section with a live countdown (`0:12 of 0:30`) while one runs, and
  becomes **Stop the clip** with a destructive role. The countdown is stated in words as the
  button's accessibility value, because a technician who cannot see how long is left either stops
  too early or is surprised when it stops itself.
- A clip's tile draws its poster frame with a timecode badge and a play glyph, and plays on the
  phone in an `AVPlayer` sheet. Both overlays are pixels, so the row's spoken label leads with
  "Clip, twelve seconds, …" and the review's row states the length, "cut short" where it applies,
  and that a clip is sent as a file of its own.
- A finished job's page gains **Clips with this report**: one row per included clip saying whether
  it goes with the report or is over the size limit for the channel, and a **Share this clip**
  button for each one that is. That is the over-budget notice, put where the share sheet is still a
  tap away rather than in a body that has already been sent.

### Verification

Headless: `JobClipEvidenceTests`, `AttachmentBudgetTests`, `JobClipRecorderTests` and
`JobClipDeliveryTests` new; the P1/P2/P2a suites, `DeliveryTests`, `FieldSessionServiceTests`,
`OutboundFrameConsumerTests`, `TelemetryOptOutGuardTests` and the privacy/data-store guards
unchanged and green; full suite green; Release app build green. Simulator: `JobTabAccessibilityTests`
gains a seeded-clip flow (`-OGUITestSeedFieldClips`, DEBUG-only seeding) auditing the
photos-and-clips section and the review with a clip on the job, plus screenshots in both
appearances. **No device run** — the recorder has never seen a real glasses stream, so the frame
rate it actually receives, the file sizes a thirty-second clip really produces, and therefore
whether the two budgets above are right, are all owed to P4.

### Slots left for later

- A clip is silent. If a pilot asks for sound, the consent question has to be answered first, and
  HIPAA mode has to be decided separately from the rest.
- The office endpoint cannot take a file. `EndpointSyncSink.carriesFiles` is where that changes.
- Clips are not grouped by unit any more than photographs are — the multi-unit export question in
  *Open questions* now covers three kinds of evidence rather than two.

## P2c as built (2026-09-23)

One pure file under `OpenGlasses/Sources/Services/FieldAssist/Job/` (`CustomerSignOff`, the
`CustomerSummary` derivation and `SignOffPolicy`), one view file
(`OpenGlasses/Sources/App/Views/Job/CustomerSignOffView.swift`: the technician's step, the
customer's screen, the PencilKit pad and the acceptance block), and the service, exporter and Job
tab work that gets a signature onto the record without letting it near anything that sends.

### Decisions the draft left open

- **The customer summary is a new derivation, and it is an allow-list.** There is no customer-facing
  subset of the record today — the work order prints `WorkRecord.summaryLines` whole — so
  `CustomerSummary` names the three things §9 says belong on the sheet (completed work by title,
  parts used, time or billing units) and can only ever print those. Written as an allow-list rather
  than as a filter over the record's lines on purpose: a deny-list would have to be extended every
  time the record grows a field, and the field it forgot would be the one on the page somebody
  signed. The first draft *was* a filter, and it leaked a part's verification provenance — the
  manual and page a part number was found on, which is the technician's audit trail and not a
  customer's business. Parts now print as number and description and nothing else.
- **The lines are stored, not only their digest.** A digest alone proves a summary was not altered
  and cannot say what it was. The record therefore carries both, and `digestMatchesSummary` is the
  check. That is also what freezes the summary: a later addendum moves `customerSummaryLines` and
  leaves `signOff.summaryLines` exactly where it was.
- **"Not asked" is not a method.** `Method` is `drawn | typed | declined`, and skipping the step
  writes **no sign-off at all** rather than a fourth case. A job nobody was asked about and a job
  where the customer said no are different facts, and collapsing them would have made the record
  claim a conversation that never happened.
- **A decline satisfies a required sign-off only when it is stated.** "They refused", with no
  reason, is indistinguishable from nobody having asked, so `SignOffPolicy` treats a reasonless
  decline as unanswered — and the step's own button is disabled until a reason is typed, but only
  where the organisation requires one.
- **The rule is enforced at the close, not at the sheet.** `JobTabModel.closeJob` is the single
  method every route closes through, so the check lives there and a screen that forgot to ask
  cannot close past it. The sheet's copy states the same sentence, from the same constant.
- **A signature is not evidence.** It is filed beside the job's photographs, under the same store
  and the same posture, but it is deliberately **not** appended to `session.media` — the catalogue
  the evidence review reads. A signature in that list would be offered to a customer's report as a
  picture of the job, ticked or unticked like a photograph of a fault.
- **The ink is black and the canvas is pinned to the light appearance.** PencilKit's default ink
  adapts to the interface style, so a signature drawn in dark mode renders white — invisible on the
  white page it is printed onto. The flattened PNG is drawn onto white for the same reason. The
  colour of somebody's signature is not a theming decision.
- **The customer's screen is presented from the step, not from the page under it.** Two
  presentations from one view is how a full-screen cover ends up fighting the sheet that raised it;
  the cover lives inside `JobSignOffStepView`, so cancelling it returns the technician to the step
  rather than to a closed job.
- **"Until the report has been sent" is read off the session's own log.** `reportWasSent` looks for
  a `report_sent` event rather than a flag, because that log is what actually records a send and it
  survives a relaunch — and a cancelled composer, correctly, leaves the job still signable. It is
  read through a new static `SessionLogger.readEvents(at:)` so that asking a finished session a
  question does not rewrite its `session.json`, and the past-job page caches the answer in view
  state because a `List` re-evaluates its body far more often than a report is sent.
- **Two `Config` stand-ins, not one.** The sheet has to be headed with somebody's name, and there is
  no organisation identity anywhere in the app today. `organizationRequiresCustomerSignOff` and
  `organizationDisplayName` are both written the way FS PR2 wrote
  `organizationAllowsUnsignedVaults` — a documented key with a stated default — and CT P1 replaces
  both. An unset name omits the line rather than inventing a business.
- **No new top-level field in the audit JSON.** The sign-off rides inside `work_record`, which
  already carries the file reference rather than the picture. A second copy at the top level would
  be two places to disagree.
- **The log carries the fact and the digest, and neither the drawing nor the customer's words.** An
  audit needs to know what was agreed to; it does not need a second copy of it, and a signature is
  a picture of somebody's name.

### What the draft got wrong

- §9's "the same customer-facing lines the PDF prints" describes something that does not exist. See
  above; the PDF's own Work Record section is unchanged, and the acceptance block prints the
  customer summary beside it.
- §9 puts the step "after the evidence review and the read-back". There is no read-back *in* the
  close flow: "Read back the job" is a separate control on the open job's page, and the evidence
  review is the last thing before the close. The step goes after the review and after the close
  confirmation for a job with no evidence.
- §9 says the audit log records "sign-off and any cancel". It records three things, because a
  decline is neither: `customer_sign_off` carries the method, and `customer_sign_off_cancelled` is
  the sheet that was shown and closed without an answer.

### What is on screen

- **Customer sign-off** is a step, not an alert: the summary the customer would read, then *Hand to
  customer*, *The customer declined to sign* (which reveals a reason field), and — only where the
  organisation does not require a signature — *Close without a signature*.
- The customer's screen has the organisation's name, the job number and date, the summary, a name
  field, one optional line, and a large pad. It cannot be swiped away; leaving it takes a
  confirmation; a footnote points the technician at Guided Access. The primary button reads **Done**
  once something is drawn and **Confirm** when nothing is — two words for two different records, so
  nobody is told they signed when they did not.
- A finished job shows **Customer acceptance**: the summary that was agreed to, the method in words,
  the reason or the customer's note where there is one, the attribution line, the picture, and the
  sentence that says this is not a legal e-signature. A job that was not signed offers to ask, until
  the report has gone, and then says plainly that it is too late.

### What the screenshots changed

Two things the photographs caught that no assertion would have. The customer screen's title,
*Please check and sign*, truncated to "Please ch…" between its two toolbar buttons — on the one
screen in this app read cold by a stranger — so the title is now two words and the sentence it was
trying to say is a line in the page, where it fits and where it is read at AX5 as well. And the
keyboard covers the lower half of the sheet while a name is being typed, which is correct
behaviour and meant the first pass photographed a "signed" sheet with nothing drawn on it; the
screenshot helper now dismisses the keyboard before it touches the pad.

### The pad's border, measured

The pad has no label beyond its heading: what says *where to sign* is its border. Drawn the way the
rest of the app draws a hairline — `Color.secondary.opacity(0.6)` on
`Color(.secondarySystemBackground)` — it measures **1.92:1 in light**, well under the 3:1 floor a
non-text indicator has to clear. At full strength it measures **3.30:1 light / 5.95:1 dark**.
`JobSignOffContrastTests` asserts both, the rejected pairing included, so a revert fails there.

### Verification

Headless: `CustomerSignOffTests` (26) and `JobSignOffContrastTests` (4) new; the P1/P2/P2a/P2b
suites, `WorkRecordTests`, `DeliveryTests`, `FieldSessionServiceTests`, `FieldContinuityTests`,
`DataStoreRegistryTests`, `TelemetryOptOutGuardTests` and `MedicalComplianceTests` unchanged and
green. Full suite **6980 tests, 13 skipped, 0 failures**; Release app build green. Simulator: `JobTabAccessibilityTests` gains three
audits (the step, the hand-over sheet, and a past job's acceptance block) plus the sheet at AX5 —
**11 of 11 green** — with a new DEBUG-only `-OGUITestSeedFieldSignOff` that puts a real recorded sign-off on the seeded
finished job; `JobSignOffScreenshotTests` photographs the step, the sheet empty and signed, and the
acceptance block in both appearances and at AX5, and the headless suite writes one rendered work
order page beside them. **No device run** — signing with a finger on real glass, and what a real
signature looks like in the PDF at that size, are owed to P4.

## P3a as built (2026-09-23)

One pure contract and one coordinator under `OpenGlasses/Sources/Services/FieldAssist/Job/`
(`LiveJobContract`, `LiveJobBridge` with `LiveJobSnapshot`/`LiveJobSnapshotPolicy`), three pure
surface models beside them (`JobQuestionHUDCue`, `CarPlayJobsList`, `JobWatchPayload`) and the one
trigger they all hang off (`JobSurfaceRefresh`) — plus the transport work that gives OpenAI
Realtime a tool path it has never had.

### The seam, and why it is a block rather than a state machine

```swift
enum LiveJobContract {
    static let heading = "FIELD JOB STATE:"
    static let characterLimit = 1_600
    static let jobToolNames: Set<String> = ["field_session", "equipment_lookup"]
    static func block(session: FieldSession?) -> String?
    static func jobToolDeclarations(in declarations: [[String: Any]]) -> [ToolShape]
}

@MainActor final class LiveJobBridge {
    struct Seams { /* activeSession, generation, canInject, isBusy, injectText,
                      consumeUtterance, speakPendingQuestion, recordTurn */ }
    func setupBlock() -> String?
    @discardableResult func refresh() -> LiveJobSnapshot?
    @discardableResult func flushHeldBlock() -> LiveJobSnapshot?
    @discardableResult func handleTranscript(_ text: String, sourceID: String) async -> Bool
    func turnCompleted() async
    func sessionEnded()
}
```

Both session managers own a `LiveJobBridge` as a stored property and reach it in exactly four
places: the setup instruction, the wearer's completed transcript, the turn boundary, and the
teardown. Everything device-facing is a closure, so the whole thing is exercised headlessly —
neither manager can be constructed in a test, because each builds a `RealtimeAudioEngine` at init.
That is also why the parity claim is checked by scraping both managers' own source for the four
calls rather than by a reading of the code.

### Decisions the draft left open

- **The per-provider audio decision is the same on both: the app speaks.** Neither backend can be
  made to say an exact sentence. `injectText(_:completeTurn: true)` asks the model to *compose* a
  reply, which is precisely the model goodwill this plan exists to remove; `completeTurn: false`
  produces no speech at all. So both providers put the two questions through the same
  `TextToSpeechService` seam Direct mode uses, with the wording `JobIntakePrompt` and
  `JobUnitChangeQuestion` already own, and both put them only at a turn boundary —
  `turnCompleted()`, which by definition is a moment the model has stopped talking. A question that
  cannot be put is not dropped: `JobIntakeState` is still holding it, and the ask budget still
  bounds how often it is put at all. **Whether the app's TTS is actually audible over a live
  session's audio route is a device question, and is owed to P4.**
- **The classification cannot precede the provider, only the app.** In a live session the wearer's
  audio is on the wire before any transcript exists, so "classified before the turn" means before
  the *app* treats it as one. The state machine consumes it, and the next refreshed block tells the
  model the number is recorded and not to ask again. Stated here rather than implied, because the
  Direct-mode guarantee — the answer never reaches the model — is one live mode cannot make.
- **A block, refreshed, rather than the continuity render re-sent.** Gemini Live already injected
  `FieldSessionService.promptContext()` — which contains the job lines — but only once, at connect.
  A job started, numbered or re-scoped mid-session was therefore invisible for the rest of that
  session. The plan's "parity via their context snapshots" understates the work: the snapshot had
  to become something small enough to re-send. Hence a 1,600-character bounded block against the
  8,000-character continuity render, injected with `completeTurn: false` on every change.
- **The bound clips the job number last.** The heading, the lede and the "job is open" line are
  protected, and among the rest the number and the pending question are ranked first. A model that
  has lost the number line asks for the number again, over the top of an app that is already
  asking, which is the one failure the block exists to prevent.
- **Generation safety is the session's own identity, not a new counter.** Both managers already
  bump `sessionIdentity` on every start, and EX resets a conversation by cycling the session — so a
  block assembled before a reset fails `LiveJobSnapshotPolicy`'s check afterwards rather than
  landing in a conversation that was deliberately emptied. A block that is ready while the session
  is busy is *held*, not sent, and goes out at the next turn boundary.
- **OpenAI Realtime declares the job tools, not the registry.** This backend had never executed a
  tool of any kind. Handing it all 36+ native tools would be a far larger change than the guided
  flow needs and one no headless test could stand behind, and it would make "keep the
  non-Field-Assist behaviour byte-for-byte" impossible to keep. So the declared surface is
  `LiveJobContract.jobToolNames`, which is empty whenever Field Assist is off — and an empty list
  means `session.update` carries no `tools` key at all. A golden fixture pins that payload.
  `ToolDeclarations.openAIRealtimeTools` is the seam for widening it.
- **A separate router for the Realtime transport.** `ToolCallRouter`'s two-phase
  `willContinue`/`scheduling` ack is Gemini's wire contract and has no Realtime equivalent, where a
  result is one `conversation.item.create` followed by a `response.create`. Folding both into one
  router would have put a Gemini-shaped branch in every Realtime path. What is shared is what
  decides behaviour: `NativeToolRouter.executeRoot`, `ToolCallBreaker` and
  `PromptInjectionPolicy` — so the runaway-loop bound and the untrusted-output framing are the same
  on both backends by construction.
- **A function call is dispatched once, from whichever of two events completes it.**
  `response.function_call_arguments.done` does not reliably carry the tool's name, so the name is
  learned from `response.output_item.added` and `response.output_item.done` is handled as well;
  `call_id` deduplicates. Running a tool twice because the server was thorough is not a failure
  mode worth having, and both maps are cleared on disconnect so a call id cannot cross a reconnect.
- **One publisher is the trigger set.** All three triggers the plan names — a tool mutation, an
  equipment change, an intake change — write the session back through
  `FieldSessionService.mutateSession`, which republishes `activeSession`. So there is one
  subscription, and what it de-duplicates on (`JobSurfaceRefresh.key`) is *the three surfaces
  rendered and compared*, not a hand-picked list of fields. A key built from named fields is a
  fourth place to remember that the job number matters, and the field it forgets is the one that
  stops reaching the model.
- **The lens cue is a notification, not a screen.** Same transient path `TaskHUDCue` uses: it never
  blocks speech, it clears itself, and it is a no-op without a display because
  `GlassesDisplayService.present` already decides that once. The unit question outranks the intake
  (it is the one holding a re-scope), and `.needsReference` — a question the app has not asked yet
  — draws nothing, so the lens never gets ahead of the voice.
- **The watch gains state and no controls.** Four bounded strings: the number, running or paused,
  the unit, and what the app is waiting on. Nothing on the wrist starts, closes or answers
  anything, because every one of those is a decision that belongs where the question can actually
  be put. The key is absent when no job is open, so a finished job cannot linger there looking open.
- **CarPlay's Jobs tab is last in the bar.** The four tabs that shipped keep their order and the
  index arithmetic in `refreshConversationsTab`/`refreshPlaybooksTab` is untouched. Selecting the
  active job goes through `GuidedJobFlow.requestResume` — never an `activeThreadId` assignment,
  which is the id-without-history defect P1 fixed on this very surface — and selecting a finished
  job reads its name and does nothing else.

### What the draft got wrong

- **P3a's bullet lists three tools; there are two.** `set_job_reference` is an *action* on
  `field_session`, declared inside that tool's `action` enum, not a tool of its own. The surface is
  `field_session` + `equipment_lookup`, and the diff test additionally asserts that
  `field_session`'s schema still carries the `set_job_reference` action on both providers — which is
  the thing that actually matters, and which a tool-name check would have missed.
- **§6 says the Jobs list carries "job number and date only" and, three sentences earlier, "by job
  number · date · outcome".** Both cannot be true. The list carries number, date and outcome; the
  sentence the design actually needs is the one that follows it — *the work record is never
  rendered on the car screen* — and that is what is implemented.
- **"Gemini Live never calls `recordConversationTurn`" was right, and the fix is not where P0
  implied.** There is no "input transcription finished" event on that transport: the wearer's words
  arrive as deltas. The completed utterance is the accumulated transcript at the turn boundary, so
  the audit hook lives in `onTurnComplete` beside the recorder, not on the transcription callback.
  OpenAI Realtime does emit a completed transcript, and records it there.

### A defect found in a neighbouring surface, and left alone

`CarPlaySceneDelegate.refreshConversationsTab()` and `refreshPlaybooksTab()` have **no callers
anywhere in the app**. The Conversations tab is built with one "New Conversation" row at connect
and is never filled in, and the Playbooks tab is built empty and stays empty. That predates this
plan and is not P3a's to fix — the Jobs tab is refreshed on connect and on every job change
precisely so it does not join them — but it is a real CarPlay defect and is recorded here rather
than left for the next reader to rediscover.

### An in-PR cleanup: the captions-overlay accessibility audit

`SessionSurfaceAccessibilityTests.testCaptionsOverlayPassesAccessibilityAudit` had been failing
intermittently on CI with five `sufficientElementDescription` findings. They were never captions
elements: every one resolved to a `StaticText` reading "Voice-Powered AI Assistant", which exists
only on the launch screen. On a loaded runner the two-second splash was still in the accessibility
tree when the audit ran. `RootView` hides everything *under* the splash for exactly this reason;
the splash itself was the half missing. It is now `.accessibilityHidden(true)` — it is decorative,
and VoiceOver should never land on it — and the audit's launch helper no longer waits for a
decorative string to *exist* (a hidden element never will); it waits for the app underneath,
whose tab bar cannot be reached while the splash holds the screen. `LaunchScreenAccessibilityTests`
is the gate on both halves.

### Verification

Headless: `LiveJobContractTests` (18), `LiveJobBridgeTests` (13), `LiveJobBridgeWiringTests` (3),
`OpenAIRealtimeJobToolsTests` (6), `JobSurfacesTests` (20) and `LaunchScreenAccessibilityTests` (2)
new; the P1/P2/P2a/P2b/P2c suites, `FieldSessionServiceTests`, `FieldContinuityTests`, the Gemini
Live suites, `BlindAssistanceContractTests`, the EX reset suites, the HUD/display suites,
`OutboundFrameConsumerTests`, `TelemetryOptOutGuardTests` and the privacy guards unchanged and
green; full suite green; Release app build and the watch target both green.

**Nothing here has been run on hardware.** No glasses, so the lens cue has never been drawn; no
car, so the Jobs list has never been rendered by CarPlay; no watch, so the payload has never been
delivered over `WCSession`; and no provider credentials, so neither live backend has been asked to
call a job tool for real. In particular the per-provider audio decision — whether the app's own
speech is audible while a live session holds the audio route, and whether it can be heard without
talking over the model — is **owed to P4** and is the one decision here that a headless test cannot
stand behind.

### Seams left for P3b

- `CarPlayJobsList.Selection` is where the **Debrief** action goes: a third case, and the row's
  handler already routes by it. The list template and its refresh need no further change.
- `JobThreadPolicy` gains `.debrief(jobId)` as §6 describes; `LiveJobBridge.handleTranscript`'s
  return value is already the "the app consumed this turn" signal a debrief's save/scrap state
  machine will need.
- The lens cue model takes a fourth `Kind` without reshaping, and the watch payload's
  `nextAction` is the one line a staged send would be announced on.

## P3b as built (2026-09-23)

The debrief, the delivery queue and the spoken send. Nine new types under
`OpenGlasses/Sources/Services/FieldAssist/Job/` — five of them pure — plus one extension file on
`GuidedJobFlow`, two SwiftUI files, and the surfaces on the phone and the car screen.

```swift
enum DebriefJobResolver {                       // which job was meant
    struct Candidate { sessionId, jobReference, startedAt, outcomeLabel, isActive; var spoken }
    enum Resolution { resolved(sessionId:), ambiguous(question:sessionIds:),
                      notFound(question:), notAReference }
    static func resolve(_ spoken: String, candidates: [Candidate], current: String?) -> Resolution
    static func looksLikeASwitch(_ text: String) -> Bool
}

struct DebriefSummary {                          // the schema, validated
    enum Category { findings, follow_ups, for_base, parts_or_materials, customer_notes }
    enum Flag { reportedNotVerified }
    struct Item { text; sourceTurnIds: [String]; flag: Flag? }
    static let maximumItemsPerCategory = 6, maximumItems = 20, maximumItemCharacters = 240
    static var jsonSchema: [String: Any]
}
enum DebriefSummaryDecoder {
    enum Failure: Error { notAnObject, empty, itemWithoutCitation, unknownTurnId, tooManyItems }
    static func decode(_ json: [String: Any], turnIds: [String]) -> Result<DebriefSummary, Failure>
    static func readsAsCompletedWork(_ text: String) -> Bool
}

enum DebriefReviewState {                        // pure, like JobIntakeState
    listening, summarising, readBack(_), awaitingDecision(_), editing(category:index:summary:),
    failed(reason:), saved, discarded
    func advance(_ event: DebriefReviewEvent) -> DebriefReviewOutcome   // state, prompt,
}                                                // consumesUtterance, recordsTurn, action

struct JobDebrief: Codable {                     // == WorkRecord.Debrief
    id, recordedAt, entries: [Entry], turns: [Turn], unsummarised, provenance: AIProvenance?,
    threadId
}
enum DebriefDocumentPolicy {
    static func placement(debriefs:reportAlreadySent:) -> Placement  // inWorkOrder | asAddendum
}
enum DebriefContract { block(job:record:), summarySystemPrompt, summaryUserText(job:turns:) }

struct QueuedSend: Codable { sessionId, jobNumber, documentKind, channel, recipients,
                             recipientSource, createdAt, updatedAt, attempts, state }
struct DeliveryQueue: Codable { entries; waiting; staged; append/update/cancel; cardHeadline;
                                spokenReadBack }
@MainActor final class DeliveryQueueStore: ObservableObject   // Application Support/FieldAssist
enum SpokenSendPolicy { handling(for:), recipients(channel:previousDelivery:settings:
                        organisation:spokenAddress:), confirmation(...), outcome(...),
                        isSendConfirmation(_:), isQueueQuery(_:) }
@MainActor final class JobSendService: ObservableObject { propose(...), confirm(), present(_:),
                        sendAll(), completePresented(outcome:), cancel(id:) }

extension GuidedJobFlow {                        // the coordinator half
    func startDebrief(jobId:) async -> Bool
    func switchDebrief(to:) async -> DebriefJobResolver.Resolution
    func endDebrief(); func debriefBlock() -> String?
    func handleDebriefUtterance(_:) async -> Bool; func prepareThreadForDebriefTurn()
    func finishDebrief()/saveDebrief()/discardDebrief()/retryDebriefSummary()/keepDebriefRaw()
}
```

### The channel partition, as shipped

| Channel | Spoken send | Why |
|---|---|---|
| `endpoint` | **immediate** | nobody taps anything; the existing store-and-forward queue carries it offline |
| `email` | staged | the Mail composer only opens on the phone |
| `messages` | staged | the Messages composer only opens on the phone |
| `whatsapp` / `telegram` | staged | opened by URL scheme, which needs that app in the foreground |
| `shareSheet` | staged | somebody has to pick a destination |

`SpokenSendPolicy.handling(for:)` is a total function over `DeliveryChannel`, so a channel added
later cannot default to "sends itself".

### Decisions the draft left open

- **The summary's cap is six per list and twenty in all, and an item is 240 characters.** A debrief
  is a short account of one visit; a model returning thirty "findings" has started transcribing,
  and a read-back nobody listens to the end of is a read-back nobody confirmed. Over-long lists are
  **clipped** to the per-category cap rather than refused — the technician still gets a summary —
  while a total over twenty is refused, because that is a summary of a different shape.
- **An uncited item is refused; a promotion is flagged.** The two failures are not the same kind of
  thing. An item nobody said has no place on a record at all, so the whole summary is thrown away
  and the technician is offered a retry. An item that *reads* as completed work ("replaced the
  drier") is something they did say: it is kept word for word with "reported, not verified" beside
  it, in `findings` and `parts_or_materials` only. A follow-up or a customer note saying somebody
  had already cleaned something is not a claim about this visit's work and is never marked.
- **A debrief turn is not consumed.** `handleDebriefUtterance` returns false for an ordinary line:
  it is written into the job's log with the id the summary will cite *and* reaches the model,
  because the model is the one holding the conversation. Only the settling utterances — "that's
  it", "save it", "scrap it", "change …" — are consumed.
- **An automatic job switch needs more than a number.** The first draft treated any
  reference-shaped token as a job switch, and a debrief is full of model numbers: "what's the
  superheat target on an SLP99" moved the conversation onto another customer's job. So
  `looksLikeASwitch` is the gate the conversation applies — a relative phrase, or a number said
  next to "job", "debrief", "switch" — while `resolve` itself stays generous for the deliberate
  "switch to this" path. This was caught by a test, not by review.
- **Turn ids are the debrief's own, not the conversation store's.** `"<debriefId>-t3"`, assigned as
  each line is said and written into the session log beside its text. A citation therefore resolves
  to a line a person can find, and the ids exist before any thread does — which matters, because a
  debrief on a job that never had a conversation creates one.
- **A debrief on a finished job binds that job's thread, and creates one if it has none.**
  `JobThreadPolicy` gains `.debrief(jobId)` and a `DebriefBinding` beside the active job's, because
  the two are routinely different: a debrief on job 1004 while job 1005 is open belongs to 1004.
  With no binding the policy resolves to `proceedUnbound` rather than falling back to the open job
  — a debrief turn filed against the wrong job is the one failure §6 exists to prevent.
- **The work order never gains a line after it has gone.** `DebriefDocumentPolicy` decides where a
  debrief prints: in the work order while the report has not been sent, and in an addendum of its
  own once it has. That is what makes "the original PDF is unchanged" a property rather than a
  hope, and `SessionExporter.export` reads `reportWasSent(sessionId:)` to apply it.
- **Only a spoken "send it" sends, and only the endpoint can be sent to.** The proposal is held on
  `JobSendService` and cleared by any refusal, so a "send it" cannot complete a send that was
  refused. Staged sends never touch the delivery route at all: the test asserts the seam recorded
  **zero** deliveries.
- **Send all is an offer.** It opens each composer in turn and a cancelled one stays queued — the
  walk steps over it rather than reopening it, so a technician cannot be trapped in a loop by
  dismissing one.
- **The notification is asked for only when it is first needed, and a refusal costs nothing.** The
  card at the top of the Job tab carries the same fact. The router implements only `didReceive`,
  so every other notification in the app behaves exactly as it did — a delegate answering
  `willPresent` would have changed the foreground behaviour of every timer, alarm and geofence.
- **The queue is its own store, protected and not backed up.** It holds recipients, which are
  somebody's contact details, and a queue restored onto another phone would offer to send a report
  that already went. Registered as `SensitiveStore.jobDeliveryQueue`.
- **CT stand-ins:** `Config.organizationJobReportChannel` (the route an organisation sets, which is
  what makes the immediate branch reachable at all) and `Config.organizationReportRecipients`, on
  exactly the terms P2c's `organizationRequiresCustomerSignOff` is a stand-in. Both empty by
  default, so a phone with no profile behaves as it does today.

### What the draft got wrong

- **"Recipients come from the job's previous delivery" cannot be implemented as written.** Plan EM
  decided, deliberately, that `completeDelivery` writes down *how many* recipients a report went to
  and never *who* — "a work order that leaks a customer's inbox is a different problem". So the
  previous delivery contributes its **channel** (recoverable from the `reportSent` event) and not
  its addresses; those come from the device's delivery settings, then the organisation profile.
  `SpokenSendPolicy.recipients` keeps the three-step order as the plan states it — it is the rule,
  and it is tested — but the app can only feed the first step on a device that has stored
  addresses elsewhere. Changing EM's decision to store recipients was not this phase's to make.
- **"The original PDF bytes are unchanged" is checked as text, not bytes.** A `UIGraphicsPDFRenderer`
  document carries its own creation date, so two renders of identical content are never byte-equal.
  P2b's determinism tests compare the extracted text with a pinned provenance block, and so does
  this one. Stated here because "byte-identical" appears in the phase's own bullet and is not what
  is proven.
- **§6 says "the lens cue model takes a fourth `Kind`".** It does not need one. The read-back is
  spoken and the decision is spoken; a lens cue during a debrief would be something to read while
  driving, which is the one thing §6's driving-safety paragraph forbids. No HUD change shipped.
- **The watch payload is unchanged.** §6's seam note suggests announcing a staged send on
  `nextAction`; that line is about the *job* the wearer is on, and a queue entry for a job that
  finished hours ago is not that. The card and the notification carry it instead.

### What is on screen

- **The past job's page** gains a Debrief section (each debrief dated, its items under their
  headings, marks in words, and "What was said" opening the turns), a **Debrief this job** action,
  and **Send addendum…** — which appears only when the report has already gone, because before
  that the debrief is in the work order itself.
- **The Job tab** gains a Send card at the top of both states: "3 reports ready to send", a row per
  report saying what it is, where it would go and why it is waiting, a Send per report, **Send
  all** when there is more than one, and a cancel.
- **CarPlay's Jobs list** gains the Debrief action on past jobs and, when the queue is not empty, a
  first row that reads it back. Still number, date and outcome only; the work record is never drawn
  on the car screen.
- **The debrief sheet on the phone** mirrors the spoken flow: what has been said, "That's it —
  write it up", the summary, Save / Scrap, and — when the model call fails — Try again / Keep what
  I said / Scrap it.

### Verification

Headless: `DebriefCoreTests` (30), `DeliveryQueueTests` (30) and `JobDebriefFlowTests` (19) new;
the P1/P2/P2a/P2b/P2c/P3a suites, `FieldSessionServiceTests`, `FieldContinuityTests`,
`WorkRecordTests`, `DeliveryTests`, `SessionExporterTests`, `DataStoreRegistryTests`,
`TelemetryOptOutGuardTests` and `MedicalComplianceTests` unchanged and green; full suite green;
Release app build green. Two accessibility audits and nine screenshots cover the Send card, the
past job's debrief and the debrief sheet, in both appearances and at AX5.

**Nothing here has been run in a car or on hardware.** No CarPlay, so the Debrief row has never
been tapped on a car screen and the queue read-back has never been heard there; no provider
credentials, so no model has ever produced a real summary — every summary in these tests is a
fixture through the `summarise` seam. Whether a technician can hold a five-minute debrief by voice
at motorway speed, and whether the summary a real model returns survives the decoder often enough
to be useful, are **owed to P4**.

### What P3b's accessibility run actually measured (corrected 2026-09-24)

The paragraph above says two accessibility audits and nine screenshots covered the Send card, the
past job's debrief and the debrief sheet. **They did not.** The audit job on the merging PR failed
twenty-six of its sixty-five cases — every Job-tab case in all three suites, including cases
written before this phase existed — and the three screenshot cases that "passed" assert nothing at
all: they wait on the card with the result discarded and then photograph whatever is on screen. So
the two new audits never reached a card to measure, and no picture of these screens was ever
looked at.

The cause was one line of seeding, not the tab. `seedStagedSends` *appends* three reports to the
delivery queue, which is durable state in Application Support: the defaults wipe at the top of
`applyLaunchState` does not reach it, and nothing else removed it. Three launches into a run the
card was nine reports tall, seven into it twenty-one — taller than the screen — and everything
below it on the Job tab is in a lazily built `List`, so the vault row, "Start job" and every past
job stopped existing in the accessibility tree. The failing run's own tree recorded it: a test that
passes no seeding flags at all showed a card headed "21 reports ready to send".

A UI-test launch now clears the queue where it already clears the sessions, and the store names its
own file so the two cannot drift apart (`DeliveryQueueStore.eraseStoredQueue`). The claim above
holds only from the run that fixed it onwards.

### Seams left for P3c

- `DebriefJobResolver.Candidate` is the shape the job-ahead list needs, and `debriefCandidates()`
  already sorts the day's work newest-first.
- `JobSendService.propose`'s `spokenChannel` is where a `.ogjob`-supplied route would arrive, and
  `QueuedSend.DocumentKind` takes a third case without reshaping the queue.
- `DebriefContract.block` is the second bounded block on the same pattern as P3a's; a third (the
  brief before site) composes beside them rather than inside either.

## Open questions

- ~~Should a declined job number block delivery, or only flag the record?~~ **Answered in P1:**
  flagged in the audit log, never blocking.
- Multi-unit jobs: `visitedUnits` (P1) is the list, each with the FM continuity scope its work was
  recorded under. Still open: whether the *export* needs to group tasks and evidence by unit rather
  than listing them flat.
- Auto-suggest closing a job after long inactivity or a large location change — useful, but it is
  a nag risk and touches billing; out of scope until a pilot asks.
- Team tier: does the office need to push a job number/assignment to the phone (ops bridge)
  instead of the technician speaking it? Natural follow-on, not v1.
- ~~Clip limits: maximum length per clip and total size per delivery channel.~~ **Narrowed in
  P2b:** 30 s default / 60 s maximum, and 20 MB (email) / 5 MB (Messages) per report, all four
  stored in `Config` rather than compiled in. They are conservative defaults chosen from what a
  mail provider and a carrier reliably accept, **not** device measurements — neither MessageUI
  composer publishes a limit. Still open: whether those four numbers are right, which only a pilot
  device with a real glasses stream can say.
- Audio on a clip: v1 is silent, because recording a bystander's voice onto a file that goes to a
  customer is a consent question this plan has not asked and a face blur has no equivalent for.
  Open if a pilot asks for it, and HIPAA mode has to be answered separately.
- Should the office also receive full-resolution originals automatically through the sync sink, in
  addition to the share-sheet route?
- Deleting a job's media: sessions cannot be deleted at all today (`DataStoreRegistry` calls a
  session log a compliance record). Photos and clips make that harder to defend — does a job's media
  need its own retention rule, separate from the log it belongs to?
- Should base be able to trigger a debrief request ("call in when you're done") through the ops
  bridge (BL)? Later.
- Auto-suggest a debrief when CarPlay connects within N minutes of a close? A nag risk; off until a
  pilot asks.
- Office push of scheduled jobs (BL) is the natural source of a site and a fault report; until then
  it is voice or typed.
- Should the brief include the customer's phone number as a "call ahead" action? Leaning yes, via
  the existing call tool, on request only.

## P0 inventory (2026-09-21)

Read, not grepped, against main at build 410; symbols are the durable reference. All types
named are `@MainActor` unless the row says otherwise, so P1's hooks can be plain MainActor calls.

### 1. Where a conversation thread begins, resumes, switches or ends

The thread is `ConversationStore.activeThreadId` (a `UUID` string, persisted in `conversations.json`).
`AppState.inConversation` is a separate mic flag; nothing links them.

| Surface | Symbol | Thread effect | Modes |
|---|---|---|---|
| Wake word / tap-to-talk / Action Button | `AppState.handleWakeWordDetected(manual:)` → `ConversationStartSequence.run` | sets `inConversation = true`; the thread itself is created later, in `AppState.handleTranscription`, only once transcript text exists (`ConversationStore.startThread`) | Direct |
| Typed chat | `ChatThreadView.send` → `AppState.sendTextMessage` | `startThread` if none active | Direct/cloud/local |
| Return to wake word | `AppState.returnToWakeWord()` | `inConversation = false`, then `endThread()` **only if** `ConversationThreadContinuityPolicy.shouldEndSavedThread(persistenceEnabled:hasActiveThread:fieldSessionActive:)` says so | Direct |
| `new_topic` (spoken, Tier-0) | `ConversationClassifier` → `AppState.handleTranscription` → `ConversationResetCoordinator.requestReset(source: .voiceCommand)` | retires every live backend at a turn boundary, then `clearLocalHistory` + `startThread` | all |
| `new_topic` (model tool) | `NewTopicTool.execute` posts `.ogNewTopicRequested`; observer calls `requestReset(source: .modelToolCall)` | as above | Direct, Gemini Live |
| Chat tab → New chat | `ChatListView.startNewChat()` → `requestReset(source: .userInterface)` | as above | all |
| Chat tab → open a thread | `ChatThreadView.activateThread` → `AppState.activateConversationThread` → `ConversationContinuity.resume` | sets `activeThreadId` **and** replays history into `LLMService` | Direct |
| Chat tab → delete | `ChatListView` `.onDelete` → `ConversationStore.deleteThread` | destroys the thread, no confirmation (the switcher sheet has one; the list does not) | — |
| Conversation page header → New conversation | `ConversationPageHeader.newConversation()` → `ConversationContinuity.startFresh` | **bypasses `ConversationResetCoordinator`** — ends the thread and clears local history without retiring Gemini Live / Realtime / gateway context | all |
| Siri: ask / run action | `AskOpenGlassesIntent` (`startDirectTranscription`), `AskQuestionIntent` / `RunGlassesActionIntent` (`sendTextMessage`) | start or continue | Direct |
| Siri: persona | `AskPersonaIntent` → `ConversationStore.continueRecentOrStartThread(mode:within:)` | the only recency-based resume in the app (5 min) | Direct |
| CarPlay | `CarPlaySceneDelegate.startVoice/stopVoice/startNewConversation/resumeConversation` | `stopVoice` sets `inConversation = false` without `returnToWakeWord()`; `startNewConversation` calls `endThread()` **directly**, bypassing the coordinator; `resumeConversation` assigns `activeThreadId` **directly** — no `resumeThread()` log, no history replay | Direct |
| Watch | `WatchConnectivityManager` `"ask"` / `"persona"` / `"resumeThread"` | same direct-assignment resume gap as CarPlay | Direct |
| Notification reply | `AgentNotificationQueue.deliver` / `deliverSummary` | sets `inConversation = true` **directly**, bypassing `ConversationStartSequence`; never touches `ConversationStore`, so the reply is not in any thread | Direct |
| Deep links | `openglasses://persona/<id>`, `action/ask` → `connectAndListen`; `disconnect` → `disconnectGlasses()` which ends the thread | start / end | Direct |
| Widget quick action | `AppState.executeQuickAction` → `LLMService.sendMessage` | **none** — a quick-action reply is never saved to a thread | Direct |
| Launch | `ConversationStore.restoreActiveSession()` | restores `activeThreadId` if the thread is under 2 h old; no history replay, `inConversation` always starts false | — |
| Glasses disconnect (BT drop) | `AppState.isConnected` didSet | `inConversation = false`, thread left open | — |
| Background / foreground / termination | — | no handler touches the thread | — |

### 2. Where a field session begins, is re-scoped, or ends

`FieldSessionTool` actions: `start`, `set_job_reference`, `pause`, `resume`, `end`, `status`,
`list`, `recall`, `vaults`, `escalate`, `export`.

| Surface | Symbol | Session effect | Modes |
|---|---|---|---|
| Tool `start` | `FieldSessionTool.startSession(args:service:)` → `FieldSessionService.startSession(vaultId:assetId:mode:startLocation:jobReference:)` | reads `vault` / `asset_id` / `mode` only — **never passes `jobReference`**, though the service parameter exists | Direct, Gemini Live |
| Tool `set_job_reference` | `FieldSessionTool` → `FieldSessionService.setJobReference` | the only way a job number is recorded today | Direct, Gemini Live |
| Tool `pause` / `resume` / `end` | `FieldSessionService.pauseSession/resumeSession/endSession(outcome:)` | billable-time accumulation | Direct, Gemini Live |
| Quick action "Field Assist" | `QuickAction` `.prompt` — sends *text* asking the model to start a session | **indirect**: it is a prompt, not a call, so whether a session starts is the model's decision | whichever mode is live |
| Settings → Field Assist | `FieldAssistSettingsView` Pause / Resume / End / "Start Default Session" | calls the service directly, bypassing the tool (and so any tool-level guard) | UI only |
| Launch restore | `FieldSessionService.restoreInProgressSessionIfAny()` (from `init`) | rebuilds vault/parts index and `ProcedureRunner`, then **auto-pauses** unless already paused | — |
| Equipment set | `FieldSessionService.setEquipment` ← `EquipmentLookupTool` (spoken, spoken-correction, nameplate/OCR), `EquipmentSurface` (manual tap), `startSession` (work-order `asset_id` match) | on a changed `identity.heading`: new `continuityScope`, `runner = nil`, `activeProcedureId = nil` — **silently**, as drafted | Direct, Gemini Live / UI |
| Equipment clear | `FieldSessionService.clearEquipment()` | same reset, unconditional | Direct, Gemini Live |
| Offline queue | `OfflineQueue.recoverInFlight()` | re-arms stranded ops that *reference* a session id; never starts or ends a session | — |
| Licence lapse | `Config.fieldAssistActive` re-checked inside each tool's `execute` | refuses **new** tool actions; an already-open session is untouched — which is what "a lapse must not strand an open job" needs | — |
| Audit hook | `FieldSessionService.recordConversationTurn(_:sourceID:)` ← `LLMService` | appends a `.userMessage` event tagged with `continuityScope` and `activeTask?.id`, deduped by `sourceID`. Confirmed: an event-log hook, nothing more | Direct only |

Persistence: `Documents/FieldSessions/{id}/{session.json, log.jsonl, photos/}` via `SessionLogger`,
registered as `DataStoreRegistry.SensitiveStore.fieldSessionLogs`. `FieldSession` has a hand-written
`init(from:)` precisely so new fields can be added — `continuityScope = try
c.decodeIfPresent(String.self, forKey: .continuityScope) ?? "initial"` is the pattern P1's
`conversationThreadId` should copy.

### 3. What P1 has to hook, and what the draft got wrong

- **`JobThreadPolicy` hooks one place for the happy path and four for correctness.** The happy path
  is `returnToWakeWord()`, where `ConversationThreadContinuityPolicy` already stands — P1 replaces
  that call. The four that bypass it: `ConversationPageHeader.newConversation()` (no coordinator),
  `CarPlaySceneDelegate.startNewConversation/resumeConversation` (direct `endThread()` / direct
  `activeThreadId` assignment), `WatchConnectivityManager` `"resumeThread"` (same), and
  `AppState.disconnectGlasses()` (ends the thread with no field-session check). A binding that only
  covers `returnToWakeWord` is a binding a CarPlay tap breaks.
- **Thread *creation* is lazy and late.** `startThread` runs inside `handleTranscription` after ASR
  produces text, so "start a job" cannot bind a thread that does not exist yet. `JobThreadPolicy`
  must tolerate `boundThreadId == nil` until the first turn, or bind at `startThread` time.
- **Resume is two-step and three callers skip step two.** `ConversationContinuity.resume` sets
  `activeThreadId` *and* replays history into `LLMService`; CarPlay, Watch and launch-restore set
  the id only. A job thread rebound on launch through the id-only path would be an empty-context
  thread wearing a job number — P1's re-binding must go through `ConversationContinuity.resume`.
- **The quick action cannot start a job deterministically.** It sends prompt text; the plan's
  "guidance is deterministic app behaviour, not model goodwill" therefore does not hold for the one
  entry point a technician is most likely to tap. P1 or P2 should give the Job tab (and ideally the
  quick action) a direct `startSession` call.
- **OpenAI Realtime has no Field Assist at all.** Not "parity deferred": `OpenAIRealtimeSessionManager`
  has no `ToolCallRouter` / `ToolDeclarations` reference and its `buildSystemInstruction()` never
  calls `FieldSessionService.promptContext()`. P3's scope for that mode is *wiring tools at all*,
  not adding a state machine to existing ones.
- **Gemini Live does not write to the session audit log.** `recordConversationTurn` is called only
  from `LLMService`, so a job run in Gemini Live has no `.userMessage` events. P1 should decide
  whether the binding also closes that gap.
- **There is a second gate.** Besides `Config.fieldAssistActive` (licence + toggle),
  `FieldSessionTool` checks `AIFeatureGate.isEnabled(.fieldAssist)` (`Config.fieldAssistToolsEnabled`).
  The Job tab's visibility rule should say which gate it follows. HIPAA does **not** gate
  `field_session` — it is not in `Config.hipaaDisabledTools`.
- **No `UIApplicationShortcutItem` exists** anywhere in the app. "Quick action" always means the
  in-app `QuickAction` grid, and P0 found no home-screen shortcut to inventory.

### 4. Readers and writers of the tab selection

One writer, one reader, both in `MainView`: `@State private var selectedTab` and the
`.onChange(of:initial:)` that logs `PrivacyLog.app(.tabSelected, …)`. Nothing else in the app reads
or writes it — no `@AppStorage`, no `@SceneStorage`, no deep link (`onOpenURL` handles callbacks,
trust, personas, skill packs; never a tab), no App Intent, no quick action, no notification, no
launch argument. The UI tests address tabs by their button label through
`AccessibilityAudit.openTab(_:in:)`, never by index. So the typed identifier landed without a
compatibility shim being needed anywhere; `MainTab.legacy(_:)` exists because the numbers *were* the
API while the bare-`Int` bar shipped, and freezing the mapping is what lets P2 insert `.job` without
auditing this again.

## P2a as built (2026-09-22)

Six pure types under `OpenGlasses/Sources/Services/FieldAssist/Job/` (`JobMediaItem`,
`EvidenceSelection`, `EvidenceImageBudget`, `EvidenceRenderPlan`, `EvidenceReviewModel`,
`EvidenceReviewVoiceState` with its classifier), one privacy chokepoint service
(`JobPhotoEvidenceService`), an image renderer, the exporter's new image path, and three view files.

### Decisions the draft left open

- **Phone-sourced pictures reuse `.toolPhotoCapture` rather than getting a scope of their own.**
  A `PrivacyFilterScope` classifies a consumer by where its pixels *go* — a still captured on the
  wearer's instruction that is then filed in a session log or sent to a model — and that is exactly
  what a phone-camera or library picture attached to a job is. Which lens produced the pixels
  changes neither the egress nor the policy, and a second scope answering `isFiltered` and
  `usesOutboundRelay` identically would be a second name for one rule. Where the source *does*
  belong is the roster, which carries it separately as `OutboundFrameConsumer.jobPhoneEvidence`
  with a new `tap` case, `heldImage`: pixels the consumer already holds, that never came from
  `CameraService`, and that therefore have no camera tap to police but still have an egress. A
  `heldImage` consumer is explicitly **not** in `typesAllowedOnARawStill`.
- **Exclude, never delete.** `.fieldSessionLogs` is `deleteAll: .unavailable` because a session log
  is the engineer's compliance record, and media lives under that same store. So leaving a photo
  out of the report leaves it in the record, and the review step says so in as many words rather
  than offering a delete that would contradict the store's posture. The deletion question stays
  open and stays a *product* question — whether a field session can ever be deleted at all — not
  something photographs get a private answer to.
- **A skipped review and an emptied one are different values.** `EvidenceSelection.reviewed` starts
  false and stays false when the step is skipped; the exporter branches on *whether the review
  happened*, not on whether anything was selected. A job that never reached the step prints the
  text bullets it always printed, byte for byte; a job that was reviewed and had everything
  unticked prints "No photos were sent with this report." Collapsing the two would have made the
  record claim a decision nobody took.
- **The budget is arithmetic, not measurement.** `EvidenceImageBudget` picks a long edge and a JPEG
  quality from the photo *count* alone, off a fixed ladder with a floor. It never measures the
  actual images, so the same job always produces the same file — which is what makes a re-send
  reproduce the PDF that went out rather than a differently compressed one — and the floor means an
  absurd job produces an honestly larger file instead of illegible evidence.
- **Downscaling happens before drawing, not at draw time.** A PDF that draws a 3024×4032 still into
  a 400-point box still embeds every pixel, so `EvidenceImageRenderer` re-encodes first. Without
  that the budget would describe a file that never existed.
- **Captions, times and both headings are drawn as real text**, never baked into the image, so a
  reader who cannot see a photograph can still find out what it was of and when it was taken.
- **A finished job states the blur that was applied, not the setting as it stands.** The Job tab's
  "Face blur: On/Off" line is the live setting while the job is open — it is what the next picture
  gets, and it is still changeable. Once the job is closed nothing about those files can change, so
  the past-job page counts the items' own `filterWasOn` and says "Face blur: On when these were
  taken", or "On for 2 of 3" when the setting moved mid-visit, and offers no link to a setting that
  could not affect them. `EvidenceReviewModel.FaceBlur` is the two-case type that keeps the two
  questions apart.
- **The spoken review only claims "yes" while it is actually open.** `GuidedJobFlow.evidenceReview`
  is nil at every other moment, whole-phrase matching decides what counts as an answer, and a yes
  or no with nothing being read out is passed through to the model untouched — "no pressure on the
  switch" must never drop a photograph.

### What the draft got wrong

- §5 says photos taken any other way "are not attached to the job at all" and names `attachPhoto`'s
  single caller. True, but it understates the fix: `attachPhoto` also had to start recording *when*,
  *by which route*, *against which task* and *whether the blur was on*, because none of that existed
  and all four are what the review is made of. `FieldSession.Evidence.photos` records only that a
  file exists, and it stays that way — `JobMediaItem` is a catalogue beside it, not a replacement.
- §5's "paused counts" was stated for the guided flow but not for evidence. It is now one property,
  `FieldSessionService.isOpenForEvidence`, keyed on `endedAt == nil` and a non-cancelled outcome,
  and every route asks it rather than each deciding for itself.
- The draft assumed the close flow could write the selection whenever. It cannot: `closeJob` takes
  the work record *before* the session ends, and `setEvidenceSelection` requires an open session, so
  the order is selection → record → close. `JobTabModel.closeJob(outcome:evidence:)` is that order
  in one place.
- P2's own notes claimed `leaveJobThreadQuestion` had to be called from a tap because it logged.
  That was a defect in the query, not a property of it — fixed here (below).

### Two in-PR cleanups

- `GuidedJobFlow.leaveJobThreadQuestion(switchingTo:)` documented itself as a query and wrote an
  audit event on every call. Raising the question is now `raiseLeaveJobThreadQuestion`, which the
  four surfaces call; the query is pure and safe from a view body. P1's tests keep their intent —
  they assert the log entry against the raising call.
- `WorkRecord.line(for:)` printed "…tested.." whenever a technician's completion note arrived
  already punctuated. The line is now terminated with exactly one sentence-ending mark.

### The chips, measured

P2's screenshots raised the task status chip ("Done" / "In progress"). Measured against WCAG AA
with the same arithmetic `OGDesignContrastTests` uses, `Color.secondary` on a
`Color.secondary.opacity(0.15)` capsule over an inset-grouped row is **3.24:1 in light** — below the
4.5:1 floor for 11-point text — and 5.14:1 in dark. The evidence review's unmarked Fault/Fix chips
had the same shape at 0.12 opacity: **3.28:1 light**, 5.32:1 dark. Both now draw the primary label
on a slightly stronger fill: the status chip measures **16.7:1 light / 11.8:1 dark**, the role chip
**17.4:1 light / 12.7:1 dark**. Neither is accent-tinted — a task's status is not an AI affordance —
and the marked role chip's coral is a fill behind an opaque label rather than coloured text.
`JobChipContrastTests` asserts all of it, including that the pairing this replaced is still below
AA, so a revert fails there rather than shipping.

### Slots left for P2b

- `JobMediaItem.Kind` already carries `.clip`, and `EvidenceSelection.Entry` carries the kind, so
  the selection model and the grid hold a second media kind without reshaping.
- `EvidenceRenderPlan` groups entries without caring what they are; a clip needs a line rather than
  an image, which is a branch in `SessionExporter.drawEvidence` and nothing else.
- `DeliveryRequest.Attachment.Kind` is still `pdf | json`; the `video` case, the per-channel size
  budget and the over-budget share-sheet fallback are untouched and remain P2b's.
- Clip *capture* is unwritten: it subscribes to `outboundFrames.publisher` and joins the roster as
  a relay consumer, which is a different mechanism from anything P2a added.

Related: [F Field Assist](F-field-assist.md), [EL equipment identity](EL-equipment-identity.md),
[EM work record](EM-work-record-and-parts.md), [FM context and field continuity](FM-conversation-context-and-field-continuity.md),
[FE voice reliability](FE-agent-voice-reliability-and-feedback.md).
