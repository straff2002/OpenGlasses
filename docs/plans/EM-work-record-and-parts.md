# Plan EM — Work Record and Parts (what was recommended, what was done, what base needs)

**Status:** ✅ P1 + P2 implemented 2026-09-08 (headless); one real email and one real message
from a device still pending. P3 (with BL) not started.
Sequenced after [Plan EL](EL-equipment-identity.md) so the record
carries the equipment identity; builds on [Plan EK](EK-manual-structure-and-figures.md) P3's
verified-page audit trail. Independent of [Plan BL](BL-ops-platform-agent-bridge.md) but is the
payload BL will carry.
**Origin:** With EJ/EK/EL a Field Assist session can answer from the manuals, show the page, and
know which machine it is talking about. Nothing ties that to a decision. The session audit log
records questions, answers, tool calls, photos, procedure steps and outcomes, citations and
escalations, and exports as PDF; procedures end in a named outcome; capture flows record typed
readings; the offline queue syncs typed operations to a configured sink. There is no object that
says *the assistant recommended replacing the flame sensor, the technician accepted, here is the
evidence it was done, here are the parts to order*. That object is what a job system, a dispatcher
or a customer's compliance reviewer wants back from a site visit — and the part numbers on it are
what base validates against stock.
**Priority:** P1 for the Field Assist commercial track: it is the deliverable a paying customer
receives per job.
**Surfaces:** Session state, three tools, the export, the offline queue, the share/compose paths;
a task list on the session screen in P2. Voice-first throughout.

Decisions taken with the product owner (2026-09-07): a task may be created by the operator without
a recommendation; a parts request may be raised without an active task (it is tagged to the job);
base's stock answer is **reported to the technician, never allowed to change a recommendation**;
a model-written summary is never the record — the deterministic summary is, and a model paraphrase
may sit beside it, labelled.

---

## Verified starting point

- `FieldSession` (`Codable`, synthesized keys) has `assetId`, mode, outcome, location, escalations,
  billable time. `SessionLogger` has typed events with payloads; `SessionExport` renders transcript,
  photos, procedure runs, capture runs, citations, escalations to JSON and PDF via `SessionExporter`.
- `ProcedureRunner` completes with an `outcome` string; `ProcedureLibrary` loads a vault's
  procedures; `CaptureFlow` records typed fields against an asset (`CaptureRecord` →
  `captureRecordSaved` event, `QueuedOp.captureRecord`).
- `OfflineQueue` / `QueuedOp` (`logEntry`, `photoUpload`, `llmGrounding`, `auditExport`,
  `captureRecord`) with pending / in-flight / done / conflict / failed states and a configured sink.
- Delivery today: the session export leaves through the system share sheet (`ShareSheet`, so Mail,
  Messages, AirDrop, Files, installed apps, with the PDF attached); `send_via` opens email, WhatsApp
  or Telegram by URL scheme (text only, no attachment).
- The vault already carries part numbers as prose: the Lennox example's `models.md` lists
  conversion kits (`65W77`, `20A26`, `20A88`, `20A89`), high-altitude pressure switches (`14T65`,
  `20A87`), the pressure test adapter `10L34`, transformer kit `27J32`, sensor kit `27V53`; the
  installation instructions carry a repair parts list (p.69) and the integrated control's own part
  number on its diagram (p.44). `CodeTokenizer` recognises them as code-like; nothing indexes them.
- Organisation profiles ([Plan CT](CT-org-configuration-profiles.md)) can carry per-org settings;
  nothing carries delivery destinations yet.

## Product promise

"Every recommendation is a task the technician accepts or declines by voice. Every task done carries
its evidence. Every part named comes from the book. At the end of the job the record goes to base
by whatever channel the organisation uses, and base's answer about parts comes back to the glasses."

## Design

### 1 · Recommendation as a structured act

A `propose_task` tool the model calls instead of recommending in prose: `title`, `why`,
`procedure_id` (optional; must exist in the vault), `parts` (part numbers; each verified against the
vault, see §4), `safety_note`, `citation`. The tool validates (procedure exists, parts resolve),
records a `Task` in state `recommended`, and returns the sentence to speak: *"I recommend checking the
pressure switch tubing. Say 'do it' to add it to the job."* A recommendation without a citation is
refused by the tool — the model may only recommend what it can cite.

### 2 · The operator decides, and the evidence attaches

`Task` (`Codable`): id, title, why, origin (`recommended` | `operator`), status
(`recommended` → `accepted` | `declined` | `deferred`; `accepted` → `in_progress` → `done` |
`abandoned`), linked `procedureId` and its outcome, `parts` (numbers, verified flag, page),
`readings` (capture-record ids), `photos`, `citationsOpened` / `pagesVerified` (EK P3 events),
`completionNote` (what the technician said they did), timestamps and elapsed time.

A `task` tool handles the voice verbs: *"do it"* / *"skip that"* / *"later"* on the latest
recommendation; *"add a task: cleaned the condensate trap"* creates an operator task already
`in_progress`; *"done"* / *"replaced the ignitor, 47 ohms before"* closes the active task with the
note. Accepting a task with a procedure starts it; the procedure's terminal outcome closes the task.
Readings, photos and verified pages recorded while a task is active attach to it; with none active
they attach to the job. Declines and deferrals are kept — "recommended, not done" is information.

### 3 · Job and work record

`FieldSession` gains `jobReference: String?` (entered at start by voice or from an organisation
profile QR; `assetId` stays) and `tasks: [Task]`, `partsRequests: [PartsRequest]`,
`equipment` (from EL). `WorkRecord` is assembled deterministically at session end (and on demand:
*"read back the job"*): equipment identity (model, serial, board part number, firmware/version,
refrigerant — each with source and time), tasks by status with evidence, readings before/after,
parts used and requested, pages verified against the manufacturer's document, time per task,
escalations, and what was declined. The technician hears it and confirms before anything leaves
(*"send it"*). An optional model paraphrase can be attached, labelled as such; it is never the
record.

### 4 · Parts and device identity base can trust

- **Parts convention in the vault.** A `parts.md` core file (or `## Parts` sections per model)
  with `| Part | Description | Fits | Supersedes |`. `VaultPartsIndex` — pure over the core files
  like EL's model index — maps part tokens to description, models and file/heading. The Lennox
  example gets one built from its accessories and conversion tables; the guide tells authors how.
- **Verification before it is written.** A part number named by the model or the technician is
  looked up as an exact token in the parts index, then the manuals (`passages(containingToken:)`),
  and recorded with the page it was found on. A number nothing knows is recorded as **unverified**
  and spoken as such — base validates a number that came from the book, not from a misheard sentence.
- **Device identity fields.** Model and serial from the nameplate (on-device text recognition, read
  back for confirmation before recording, because digits are where recognition fails quietly);
  board/component part number and firmware or software version where the technician can see them;
  refrigerant type and charge from the plate. Each is a named field with `source`
  (`nameplate` | `spoken` | `display`) and time. EL's identity supplies the model.
- **`PartsRequest`**: part number, description, quantity, `taskId` (optional), model it fits,
  urgency, `onVan: Bool`, verified flag and page, status (`requested` → `sent` → `answered`) and
  base's answer text when one arrives. Raised by voice (*"request two 14T65 pressure switches for
  this job"*) or from an accepted task that names a part. Goes out with the work record and on its
  own as a queued operation, so a stock check can leave before the job is finished.
- **Base's answer is reported, not acted on.** When a reply arrives (BL's bridge; until then a
  message read out like any other), it is spoken and attached to the request. It never changes a
  task or a recommendation by itself.

### 5 · Delivery: by whatever channel the organisation uses

One record, three shapes from the same data: PDF for a person, structured JSON for a system, a short
plain summary for a message body. They cannot disagree.

- **Composer, with the operator's thumb on Send.** *"Send the job report to base"* / *"email this
  to the office"* opens the in-app Mail or Messages composer (`MFMailComposeViewController` /
  `MFMessageComposeViewController`) with recipient, subject and summary pre-filled and the PDF and
  JSON attached. iOS requires the person to tap Send — which is the human-in-the-loop step.
  WhatsApp / Telegram through the existing `send_via` get the summary text and job reference (their
  schemes cannot attach a file). The share sheet remains for everything else.
- **Recipients from the organisation.** The CT profile gains `delivery`: default addresses and
  numbers, an endpoint, and the channels allowed (site data is the organisation's call). The
  technician can override by naming a contact through the existing contact lookup.
- **Unattended delivery.** `QueuedOp.workRecord` and `QueuedOp.partsRequest` through the offline
  queue to the organisation's endpoint (which emails or files server-side), and to the operations
  platform when BL lands. Composer and queue are not exclusive: a record can go both ways.
- **Nothing is silently lost.** A dismissed composer leaves the record `pending` in the queue view;
  the session card shows unsent records; "send it" retries.

## Phases

- **P1 — pure core (one PR).** ✅ 2026-09-08. `Task`, `PartsRequest`, `WorkRecord` and its deterministic
  renderers (summary, JSON, PDF section), `VaultPartsIndex` + verification, device identity fields,
  `propose_task` / `task` / `parts_request` tools, session fields and events, `QueuedOp` kinds.
  Headless tests: the full task state machine by voice verbs; recommendation refused without a
  citation or with an unknown procedure; parts verified / unverified from the Lennox core and
  manuals; the record rendered from a scripted session; old sessions decode without the new fields;
  export includes tasks and parts.
- **P2 — delivery and surface (one PR).** ✅ 2026-09-08. Composer paths with attachments,
  `DeliverySettings`/`DeliveryPolicy` (shaped for CT's profile to supply later), channel
  restrictions, `deliver_report` + staging, `EndpointSyncSink`, queue view for pending records, the
  session screen's task list and read-back, HUD line for the active task, guide Step 7. Live edge:
  one real email and one real message from a device, **not yet run** — no device in this session.
- **P3 — with BL.** Post the record and parts requests to the operations platform; speak its
  answers. Deferred to BL's own phases.

## Acceptance

- A scripted session on the Lennox vault: the model proposes "check pressure switch tubing" with
  the procedure and `14T65`; "do it" starts the procedure; its outcome closes the task; "request
  two 14T65 for this job" creates a verified request citing the manual page; "add a task: cleaned
  the condensate trap" and "done" record an operator task; the read-back names all three with their
  status; the export carries them; an unknown part `99Z99` is recorded unverified and spoken as such.
- No task, request or record ever leaves the device without either the operator's Send tap or a
  configured endpoint under the organisation profile.
- Bundled vaults without a parts file behave as before; every existing test stays green.

## Risks and non-goals

- **Voice verbs are ambiguous** ("done" could close a task or a procedure step). The tool resolves
  against the active task first and confirms aloud what it closed.
- **A parts index cannot know stock or price**; the record says what the book says and what the
  technician asked for. Stock is base's answer.
- **Not in scope.** Scheduling, invoicing, a general job list across sessions (a job here is one
  session's reference), and any change to the live Gemini / OpenAI sessions.

---

## P1 findings (2026-09-08)

**`Task` cannot be a top-level type in this module.** A module-level `struct Task` shadows
`_Concurrency.Task` in every file that does not qualify it, and the app is full of `Task { … }`.
It ships as `FieldSession.Task`, which keeps the plan's name and reads correctly at every use site
(`session.tasks`, `FieldSession.Task.Status`). `PartsRequest`, `TaskPart` and `DeviceIdentityField`
are top-level; only the one that collides is nested.

**"Optional-or-empty so old sessions decode" is not enough for a collection.** Swift's synthesized
`Decodable` throws `keyNotFound` for a missing key on a non-optional property — the property's
default value is *not* consulted — so `tasks`, `partsRequests`, `identityFields` and `jobEvidence`
would each have broken every session written before this PR. `FieldSession` now has a hand-written
`init(from:)` using `decodeIfPresent ?? []`. It lives in an **extension**, because an initializer in
the main declaration suppresses the memberwise init that `startSession` and half the test suite
call. An optional field (`jobReference`, `equipment`) needed nothing, which is why EL P1 got away
with adding one.

**Evidence is one type, seen from two places.** `FieldSession.Evidence` (readings, photos, opened
citations, verified pages) is used both as `Task.evidence` and as `FieldSession.jobEvidence`, rather
than four flat arrays duplicated on each. A reading taken with no task running belongs to the visit,
not to nothing, and the two collections have to render the same way in the record.

**`activeTask` is the *last* task in progress, not the first.** "Add a task: cleaned the condensate
trap" while something else is open means the technician has moved on; the evidence should follow
them. This is also what makes an operator task usable while a recommended one is still running.

**`accepted` stays a real resting state.** Accepting starts the task's procedure when it names one
and otherwise makes the task active — but if something else is already in progress it rests at
`accepted` and the `start` verb picks it up later, so two tasks are never in progress by accident.
With no id given, `start` resolves to the most recent `accepted`-or-`deferred` task, which is what
"pick that back up" means; `accept` / `decline` / `defer` resolve to the latest recommendation and
`done` / `abandon` to the task in progress.

**A capture record had no identity.** `CaptureRecord` carries `flowId` + `startedAt` and no id, so
a task's `readings` had nothing to hold. It gained a *derived* `id` (`flowId@<ISO-8601 startedAt>`)
rather than a stored one, so a record written before this PR identifies itself the same way.

**The parts convention needs a scope rule, not just a table shape.** `parts.md` is read as parts
throughout; in any other core file only the tables under a `## Parts` heading count. Without that,
any core table with a "Part" column — a specifications table, a wiring legend — would become
orderable stock. `Supersedes` turned out to be worth reading in both directions: a technician reads
the number printed on the old component, and what the record should carry is the one that replaced it.

**Verification has two routes and they measure differently.** Against the Lennox example: `14T65`
resolves in `parts.md` and cites `parts.md § Conversion and high altitude (fits 070, 090XV36C,
090XV48C, 110, 135)`; `67M41`, the defrost tempering kit, is named only on the service manual's
wiring diagram and is deliberately **not** in `parts.md`, so it exercises the
`passages(containingToken:)` route and cites the printed page; `99Z99` resolves nowhere and is
recorded unverified and named out loud as unverified in the tool's reply. The example's core went
from 25,243 to 29,242 characters against the validator's 32,768 budget.

**What P1 does not do.** The plan's §3 says "readings before/after"; what is recorded is the
capture-record ids in the order they were taken — the before/after split lives inside the capture
flow's own fields, and inventing a second one here would be a second source of truth. There is no
voice route to the job reference yet: it is `startSession(jobReference:)` and
`FieldSessionService.setJobReference`, and P2's organisation-profile QR is where it gets one. The
`sent` state of a `PartsRequest` is never entered, because nothing sends anything in P1 — the
queued operations are durable local tombstones until P2 configures an endpoint.


---

## P2 findings (2026-09-08)

**A staged report is the only shape that stays honest headless.** `deliver_report` builds the
request and publishes it on the session; `AppState` subscribes and opens the composer, exactly the
way `manual_figure` reaches the phone. The tool therefore behaves identically with no app around
it, which is what makes every one of its decisions — channel, recipients, refusal — a headless
test rather than a UI test. It also means the WhatsApp/Telegram route goes through staging too and
is fired by the app from `MultiChannelMessageTool`, rather than the tool opening a URL itself.

**Only a confirmed send is a send, and three of the five outcomes are not one.** Mail's *saved*
(a draft), a dismissal, and a hand-off to an app that reports nothing back all leave the record
where it was: the queued operation stays `pending` and the `PartsRequest`s stay `requested`. The
hand-off case needed its own outcome (`DeliveryOutcome.handedOff`) because WhatsApp and Telegram
are opened by URL scheme and *cannot* tell us whether the person tapped Send — calling that "sent"
would mark parts ordered that nobody ordered. The endpoint channel is the same shape: it enqueues
and reports what the queue then says, rather than what it hoped.

**Mail and Messages number their results differently.** `MFMailComposeResult` is
cancelled/saved/sent/failed (0–3); `MessageComposeResult` is cancelled/sent/failed (0–2). A
`.sent` case matched on the wrong enumeration silently marks a cancelled report as sent, so the
mapping is its own pure type (`ReportComposerOutcome`) with the raw values pinned in a test.

**`canSendMail()` is false on the simulator, and that is the general case, not a test artefact.**
A phone with no Mail account, or an iPad with no SMS, has the same problem. `ReportComposerAvailability`
resolves the channel against what the device can actually do and falls back to the share sheet with
both files, saying so out loud — a composer that cannot appear is worse than a different route.

**A name cannot become an email address here.** `ContactLookupHelper` returns phone numbers, which
is all `send_via` ever needed. So a spoken contact resolves for Messages/WhatsApp/Telegram and an
email needs an actual address; the tool says that rather than guessing, because the wrong inbox is
the one mistake in this flow nobody would notice until the customer's job record was in it.

**The bearer token is absent from `DeliverySettings` by construction, not by discipline.** Its
`CodingKeys` omit it, so it cannot reach the stored blob, a future exported organisation profile,
or anything else the type is serialised into; `load`/`save` move it through the Keychain, and the
key joins `Config.migratableStringSecretKeys` so it is also masked in diagnostics.

**`EndpointSyncSink` composes rather than replaces.** It handles `workRecord` and `partsRequest`
and delegates every other kind — and *everything*, when no endpoint is configured — to
`LocalSyncSink`, so a device that has never been told where base is behaves exactly as it did
before this PR. 409 is the only 4xx treated as a conflict (the receiver saying the job moved on,
which is what `ConflictResolver` was written for); the rest are permanent, because burning six
attempts on a malformed body helps nobody.

**A composer can outlive its session.** "Send it" then "end session" leaves the sheet open, and
`endSession` had already released the logger — so the outcome would have been written nowhere. The
service now keeps the ended session's logger for exactly this, and writes the outcome only when the
request's session id matches, so a late completion can never land in a different visit's log. What
it still cannot do is move that session's parts requests to `sent`: they belong to a session that
is no longer active. Sending before ending is the flow the surfaces encourage.

**What P2 does not do.** No organisation profile supplies these settings — CT is not built — so
they are device-local, with `DeliverySettings.applying(organisation:)` written and tested against
the ceiling rule (an organisation may subtract a channel, never add one the device refused) so the
handover is a wiring change. "Send by email instead" on the sync screen sends the record as the
body without attachments: the exported files belong to a session that may be long finished, and a
body a person can read beats an attachment that may no longer be on disk. And no real email or
message has left a device yet — the live edge named in the phase list stands.
