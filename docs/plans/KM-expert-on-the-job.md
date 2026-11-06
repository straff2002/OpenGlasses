# Plan KM — An Expert on the Job (the job sent to a named expert, their advice walked through, their time on the record)

**Status:** 🚧 P0–P3 built 2026-11-06 (headless; device checks owed): the expert list, the pick
and the call by name or by specialty (P0); the handover — `.ogcase`, PDF and text, the staged send and
generations (P1); Assisting mode — the read-only copy, the expert's clock, the staged `time` reply and
the expert card (P2); coaching steps — the expert's step editor and the staged `coaching` reply, loaded
on the technician's open job only for its own handover, walked as written with the safety rule first
and readings against each step (P3). P4–P5 not started. Drafted 2026-11-03 from the owner's question; the owner
took all ten decisions as recommended the same day. Revised the same day: the expert's side belongs to no
organisation, so one expert can serve many.
**Track:** Field Assist. Phone first: every part works without glasses, and the expert side needs no
glasses at all.
**Related:** Plan [IQ](IQ-closeout-unknown-units-and-calling-base.md) P3 (calling base, the help pack,
`organizationEscalationContacts`), Plan [JI](JI-apprentice-support.md) §6 (`CallRoute`, "FaceTime Sam"),
Plan [JX](JX-journeyman-engine.md) §8 (the expert line, Stage A and Stage B), Plan
[GZ](GZ-expert-annotations.md) (annotations on the technician's view), Plan
[HD](HD-report-transcript-audience.md) (who a transcript may go to), Plan
[FO](FO-guided-job-flow-and-job-tab.md) P3c (`.ogjob`), Plan [EM](EM-work-record-and-parts.md) (the
send tap), Plan [GB](GB-field-test-round-3.md) P3 (`BillableClock`), Plan
[CT](CT-org-configuration-profiles.md) (profile-owned keys), Plan [CP](CP-outbound-frame-privacy.md)
(outbound frames), Plan [FX](FX-desktop-office-and-device-sync.md) (FX8, live support).

---

## Why

The owner asked for escalation to reach a **named** expert, chosen by what they know: "call a furnace
expert", when the organisation has three. The expert should get **the job as it stands**, including the
work done, the readings and the conversation so far. They then give advice or coach the technician
through it, and **their time on the job is recorded**.

**The usual expert is the organisation's own senior** (JX Stage A): a journeyman with a seat, on the
same team, called by an apprentice or a newer technician. That case comes first and needs no billing at
all. P0–P3 deliver it in full, and P4's rates and statements only matter for contracted experts.

It also opens a commercial route that JX §8 only names. Retired journeymen can be on call for several
organisations, each under that organisation's own agreement, and bill each one from a record the app
keeps. There is no marketplace, and the app never handles money.

## What exists, and what doesn't

- **Escalation pages a pool, not a person.** `EscalationCoordinator.requestExpert(reason:)` records the
  escalation on the session (`recordEscalation`). It then calls `notifyExpertPool`, which is a local
  notification plus an optional webhook. No expert has a name, a number or a specialty.
- **Calling a person is drafted, not built.** IQ P3 designs an org-owned contact list and a help pack
  sent before the call. JI §6 designs `CallRoute` (`tel:`, `facetime:`, `facetime-audio:`) and
  `CallPlacement`. Neither exists in code: `SettingKey` has no `organizationEscalationContacts`.
  (*2026-11-06:* P0 built them; see "P0 as built" below.)
  `phone_call` (`PhoneCallTool`) resolves a name through Contacts and dials `tel://`.
- **The pieces the handover needs already exist:**
  - The job's thread and `JobTranscriptExport`, which renders who said what for a job.
  - `ReportTranscriptPolicy`: who may read the conversation (deny by default).
  - `SessionExporter`, which keeps cited manual pages out of an export and lists them by reference.
  - `EvidenceSelection` and `EvidenceImageRenderer` for photos, with `AttachmentBudget` for size.
  - `JobSendService`: staged sends, where only "send it" or a tap sends.
  - `CameraService.filteredStill(for:source:)` and the `OutboundFrameConsumer` roster.
- **A job file exists, but only inbound.** `.ogjob` (`JobFile`) is signed by the organisation and
  receive-only: "the app never writes one out". Info.plist already declares the document type and the
  open-as-copy behaviour this plan copies.
- **Time is counted for the technician.** `BillableClock` recovers a job's billable time after the app
  dies. Nothing counts anyone else's time.
- **A call already takes the voice loop.** `ExpertCallAudioCoordinator` pauses TTS and the wake word for a
  call, then resumes them.

## The flow

1. **Choose.** The technician says "get me a furnace expert". The app replies: "Three furnace experts. Sam
   is on call. Send him the job and call?"
2. **Send.** The handover sheet shows what goes. The technician says "send it", and the handover goes by
   Sam's channel (Messages, WhatsApp, email or AirDrop).
3. **Call.** FaceTime rings. The assistant goes quiet for the call, and nothing is recorded.
4. **Review.** Sam opens the handover in Avenkin and taps **Take this job**, which starts his clock. He
   reads the unit, the steps done, the readings, what has been ruled out and the conversation, and looks
   at the photos.
5. **Coach.** Sam advises on the call. He can also send back **coaching steps**, such as "check the
   inducer pressure switch hose for water; read the switch with the inducer running; if open, …". The
   technician's assistant then walks those steps one at a time and records a reading against each.
6. **Update.** "Send Sam the latest" sends the next version of the handover, which replaces the earlier
   one on Sam's phone.
7. **Close.** Sam taps **Done**, and his reply carries his time and a short note. The technician's phone
   attaches it to the job and checks it against the call it saw. The job record and the month's
   statement for Sam show the minutes. Sam invoices the organisation, and the app moves no money.

## Design

### 1 · Who the experts are

- **`EscalationContact`** is IQ P3 and JI §6's type, which this plan builds first; IQ and JI reuse it.
  It has these fields:
  - name, phone, FaceTime handle, and the channel the handover goes by;
  - `specialties`: tags from the organisation's vocabulary (trade, equipment kind, brand), such as
    `furnace`, `heat pump`, `refrigeration`, `Lennox`;
  - `kind`: `staff` (the organisation's own seniors, JX Stage A) or `contracted` (paid per the
    organisation's agreement);
  - `onCall`: weekly windows in the expert's time zone, where empty means any time;
  - `rate`, for `contracted` only: per hour, minimum minutes and rounding grain, in the organisation's
    currency. It is a figure for the statement and is never charged by the app.
- **Two sources, one list:**
  - The organisation profile sets the list through a new CT `profileOwned` key, `organizationExperts`.
  - The technician can add personal experts in Field Assist settings. These are always `staff` and carry
    no rate (decision 1).
  - Without a profile, the device owner is the organisation and sets the list, including rates, on the
    phone. A sole operator has no office.
- **Tags live in the app, not in iOS Contacts:**
  - Writing to a contact's notes needs a restricted entitlement that Apple grants case by case.
  - Contact groups aren't available in every account type (Exchange has none).
  - A tag in Contacts would also travel to every app that reads Contacts.
- **Adding an expert who uses Avenkin means importing their expert card** (§7): a file or QR code with
  their name, number, handle, specialties and licences, so nothing is retyped and a reply matches its
  entry exactly. The organisation adds its own `kind`, on-call windows and rate.
- **Adding anyone else uses `CNContactPickerViewController`.** It runs out of process and needs no Contacts
  permission. The app keeps a snapshot of the name, number and handle, because contact identifiers don't
  survive a restore or a second device.

### 2 · Choosing among three

- **`ExpertPicker`** is pure. The inputs are the request's words, the job's trade and equipment
  (`EquipmentIdentity`: kind and brand), the list, the time, and the rota position. It filters in this
  order:
  1. Specialty match: words first, then the job's equipment.
  2. On call now.
  3. Rota order, rotating per phone from the last expert called.

  It returns an ordered list and one sentence.
- **Fixed rules only.** No expert or technician is ranked by outcomes, ratings or call history. Allocating
  work to people is the Annex III 4(b) area JX §10 flags, and a fixed rule over human-set fields keeps the
  choice the technician's.
- **"Sam didn't answer. Try Priya?"** The offer comes when the call ends without connecting, read from
  `CXCallObserver` (`hasConnected`). Whether a FaceTime call placed by URL shows up there is a device
  check (P5). If it doesn't, the offer falls back to the technician saying "no answer".
- **By name always works.** "Call Sam" skips the picker, as JI §6 says.

### 3 · The handover: the job as it stands

**`ExpertHandover`** is a pure builder over session state, the job's thread and the work record. It
contains:

- **The job.** Reference, trade, fault report, and the unit (model, serial, decoded identity). The site is
  given by town only. The customer's name, address and contact stay out by default (decision 2): the
  expert needs the unit, not the customer.
- **The work so far:**
  - tasks and their status;
  - procedure steps done;
  - readings with their units and sources (`SpokenReading`);
  - deviations;
  - what has been ruled out, which means only what the technician said or recorded as ruled out. The app
    never infers it.

  This is the same session state the work record renders, so the expert reads what the record says.
- **The conversation so far.** The job's thread: the technician's words and the assistant's answers,
  rendered as `JobTranscriptExport` renders a job. HD's policy gains an audience, `expert`, with these
  rules:
  - It is included by default for experts on the organisation's list.
  - For personal additions, the technician turns it on for each send.
  - An organisation can set `expertHandoverTranscript` to `include`, `ask` or `never` (decision 3).
  - Troubleshooting details (model names, prompt sizes) never go.
- **Photos.** The technician chooses which go. The sheet preselects the most recent four (decision 4).
  Every image comes from `filteredStill(for: .expertHandover, …)`. That is a new `PrivacyFilterScope` and
  a new `OutboundFrameConsumer` row, so bystander faces are blurred, and an image that can't be filtered
  is left out and counted, never sent raw. Recorded clips are not in KM.
- **Manual pages by reference only:** document title, page and section, as `SessionExporter` lists
  citations. No page image is ever included. A manufacturer's manual, a code book or a My Manuals upload is
  not the technician's to redistribute. If the expert has the same document, the reference opens it there.
- **The question.** The technician says what they want help with ("it's tripping the pressure switch and
  I can't see why"). It goes in as said.
- **Identity and rules.** A handover id, the job reference, a **generation number** that increases with
  each send, the organisation's name, "Confidential to <organisation>", and the retention period the
  expert's app applies (§7). It carries no rate.

It is written two ways from the same value:

- **`.ogcase`**, a new document type (`openglasses.handover`, version 1). It is a package holding
  `handover.json` and the filtered images, and it opens in Avenkin. It is declared beside `.ogjob` in
  Info.plist and opened as a copy, but unlike `.ogjob` the app writes it.
- **A PDF and a text file** for an expert without Avenkin, rendered from the same value.

**Sending** goes through `JobSendService` as a staged send. The sheet names the expert, the channel and
what goes, and only "send it" or the tap sends (EM). `AttachmentBudget` caps the size. If it's over the
cap, photos drop oldest-first and the sheet says how many were dropped. **"Send Sam the latest"** builds
generation n+1, and the expert's app replaces the earlier generation and marks what changed.

### 4 · The call

- `CallRoute` and `CallPlacement` as JI §6 designs them: phone, FaceTime, or FaceTime audio. The handover
  is sent first, and the call never waits for it.
- `ExpertCallAudioCoordinator` hands the microphone and speaker to the call and takes them back afterwards.
- **Nothing is recorded**, neither the audio nor a transcript of the call. JX §8 keeps calls unrecorded
  by default, and iOS gives an app no access to a FaceTime call's audio anyway.
- The technician's phone logs what it can see: dialled, connected if observable, and ended. This goes in
  the job log (`SessionLogger`) and on the escalation record, which gains the expert's id and the times.
- After the call: "What did Sam say?" Whatever the technician says is kept as the expert's advice,
  credited to Sam, as JI's "note what you learned" does.

### 5 · Coaching steps

- **The expert writes the walkthrough.** In Assisting mode (§7), Sam types or dictates numbered steps.
  Each step has:
  - an instruction;
  - an optional reading to take, with its unit;
  - an optional "stop if", such as "stop if the hose is clear and the switch still reads open".
- **They come back in a reply** (`.ogcase`, kind `coaching`), sent by Sam's channel.
- **A reply is accepted only if it answers a handover this phone sent**, on a job that is still open,
  from the expert it was sent to (same handover id and list entry). Anything else is shown as a file
  this phone didn't ask for and is never loaded. A crafted coaching file is instructions from a stranger,
  so it must never reach `ProcedureRunner`.
- **Coaching steps live with the job.** They are never saved straight to the procedure library, so an
  expert without a seat can't use replies to author procedures for an organisation.
- **A senior's walkthrough can become the team's.** When the steps came from a `staff` expert, the
  technician can offer them as a team learning. They then go through the existing review
  (`LearningReview`), and the office or owner decides whether they join the library, credited to the
  senior. This is how a senior's fix for one job reaches the next apprentice, the way JX §7 describes. It
  is never offered for a `contracted` expert's steps unless the organisation's agreement with them covers
  it (decision 10).
- **The technician's app loads them as a procedure** in `ProcedureRunner`, credited to "Sam (contracted
  expert)". The assistant walks it one step at a time, and each reading is recorded against its step, so
  the record shows the expert's walkthrough and what was found at each point.
- **A step never overrides a safety rule.** Each step goes through `LearningSafetyCheck`'s matcher, and a
  step that hits the safety file is read with that rule first and flagged in the record.
- **Coaching steps are human advice.** The assistant reads them as written. It may answer questions about
  a step from the manual, but it never rewrites one.
- **Live coaching** (seeing the technician's view and circling the part) is GZ over FX8's live view,
  which is not in KM. Until then, the call plus photos sent with "send Sam the latest" is the live path.

### 6 · Time on the job

- **The expert's clock** runs on Sam's phone in Assisting mode:
  - It starts at **Take this job**, which is also the receipt that he took it.
  - It runs while the handover is open or a call is on, and Sam can pause it.
  - It stops at **Done**.
  - It uses `BillableClock`'s recovery, so an app killed mid-review loses only the time since the last
    sign of life, and the reply says how much was lost.
- **The reply** (`.ogcase`, kind `time`) carries:
  - the handover id and the generations seen;
  - accepted at, review minutes and call minutes;
  - the coaching steps sent, and a short note;
  - Sam's name as the organisation's list has it.

  It is the same file whether or not coaching steps went earlier.
- **The technician's phone counts independently:** the call times it observed (§4).
- **`ExpertTimeReconciler`** is pure. It compares the reply's call minutes with the observed call. The
  result is either "agrees" or "differs by 6 minutes". A difference is shown on the job and on the
  statement and never resolved by the app (decision 5). With no reply, because the expert hasn't got
  Avenkin, the record carries the observed call only, labelled as such.
- **Billable minutes** follow the expert's `rate` rule: rounding grain and minimum.
- **Where it goes:**
  - The work record JSON gains `expertTime`: expert, kind, accepted at, review, call, billable minutes,
    reconciliation.
  - The office audience's report includes it.
  - The customer's work-order PDF doesn't include it unless the organisation turns on "show expert time on
    the customer's report" (decision 8), because what the customer is billed is the organisation's
    business.
- **`ExpertStatement`** has one row per job for each expert and month: date, job reference, minutes,
  billable minutes, rate and amount, plus a total for the organisation's records. The phone exports it as
  CSV and PDF, so a sole operator needs no office, and Avenkin Office shows it once FX sync carries the
  work record. The statement is what the expert invoices against. The app never takes or sends a payment.

### 7 · Assisting mode (the expert's side)

**The expert's side belongs to the expert, not to an organisation.** A retired journeyman is useful to
several companies, and nothing on the expert's side needs a company to own it.

- **What ties an expert to an organisation is the organisation's list, on the sending side.** An
  organisation chooses who it sends jobs to, agrees a rate and signs its own agreement. The expert's
  app installs no profile, holds no licence and joins no organisation.
- **Assisting mode is not something you turn on.** There is no "I'm an expert" switch, setting or
  sign-up. It is only what the app shows when an `.ogcase` is opened, and it unlocks nothing else in the
  app.

  | Assisting mode opens | It never opens |
  | --- | --- |
  | The handovers it was sent: read-only, one organisation at a time | Field Assist mode, the job flow, or starting a job |
  | **Take this job**, **Pause**, **Done**, and its own clock | Vaults, bundled or custom; procedures; the procedure library |
  | **Call back** (a phone or FaceTime link) | Manual or code-book pages. A handover lists them by reference only, and a reference opens only a document the expert's own app already has under its own entitlement |
  | Coaching steps, written for **that** handover and sent back | The domain calculators, refrigerant toolkit, parts, van stock or connectors |
  | The expert card and the expert's own ledger | Work-record, debrief, PDF or audit export, beyond the expert's own ledger |
  | | Any Field Assist tool in the expert's assistant. Handovers aren't fed to it (see below) |

  The test for this is `FieldAssistEntitlement`: every Field Assist surface still checks it, and Assisting
  mode never grants or consults it, so a phone with no entitlement is a phone with no Field Assist.
- **An expert who is also a member of the organisation** (a senior with a seat, JX Stage A) already has
  Field Assist from that seat, not from being an expert:
  - Their app opens the handover's manual references in the organisation's own vault.
  - The organisation may include the customer's address for its own staff (decision 2).
  - Their entry is `staff`: time is recorded for the job's costing, with no rate or statement.
  - Two rules still apply. A coaching reply must answer a handover the technician's phone sent, because
    that guards against forged instructions, whoever the sender is. And a member of one organisation who
    is also a contracted expert for another keeps the other organisation's handovers out of their own
    organisation's vault, team learnings and memory.
- **What a self-made handover gets someone: nothing.** Anyone can write an `.ogcase` and open it, but all
  they get is a read-only view of what they typed in. A handover is a document, not a key, so it carries no
  signature to check. The value is in jobs that a paying organisation's technicians send.
- **Opening an `.ogcase`** in Avenkin shows a read-only job view: the handover, its generation, what
  changed since the last one, and the photos. It has **Take this job**, **Call back**, **Coaching steps**,
  **Pause** and **Done** controls.
- **It can't touch the technician's job.** No tool acts on it. The only things that leave are the replies
  (accepted, coaching steps, time), each staged and sent by Sam's own tap.
- **Every handover carries its own rules:**
  - the organisation's name;
  - the retention period, 30 days after **Done** by default and shortened if the organisation wants;
  - whether the conversation is included.

  The expert's app follows what each handover says, so it needs nothing from any organisation beforehand.
- **Many organisations, kept apart:**
  - Handovers are grouped by organisation, with no search across organisations.
  - Nothing from a handover goes into the expert's own assistant memory (`BrainStore`), conversation
    threads or team learnings. An answer for one company can never draw on another company's job, which
    matters when two clients are competitors.
  - The app can't stop a recipient forwarding a file. The sheet says so, and each handover is marked
    "Confidential to <organisation>".
- **The expert card.** In Assisting mode the expert fills in a card once: name, number, FaceTime handle,
  specialties, the trades and places they're licensed for, and how to send them jobs. They share it as a
  file or QR code. An organisation imports it into its list (§1), adds its own rate, and nothing else is
  typed. One card serves every company the expert works with.
- **The expert's own month.** The replies the expert sent build an `ExpertLedger` on their phone: jobs,
  minutes and billable minutes, grouped by organisation and month, at the rate the expert set for that
  organisation (the card's standard rate unless changed). Handovers carry no rate, so the technician
  never sees one (decision 6). It exports as CSV and PDF, one per organisation, so the expert can invoice
  each company from their own record. The organisation's `ExpertStatement` (§6) is built from the same
  replies, so the two sides should agree, and a difference points at a reply one side never got.
- **The expert is recognised** by an organisation when a reply's name and number match its list entry,
  which the expert card made exact.
- **Price:** decision 7.

### 8 · Privacy, compliance and what KM leaves out

- **Minimal by default:** no customer identity, troubleshooting details or page images, and every photo
  blurred, each through an existing policy or chokepoint, so a test can assert it.
- **Disclosure.** The in-app privacy copy and the manifest note gain one line: job details go to an expert
  the technician chooses, by the technician's channel. No new service or egress is involved, because the
  file goes the way any attachment goes.
- **Medical mode** never offers the handover, and a P1 test asserts it.
- **App Store.** Nothing is bought in the app. The expert is paid by the organisation outside it, under
  their own agreement.
- **Not in KM:**
  - live sync of the handover through Avenkin Office (FX);
  - the live view and annotations (FX8, GZ);
  - signed replies with enrolled expert keys;
  - **JX Stage B**, an open marketplace of experts the organisation doesn't know, which needs identity and
    licence checks per jurisdiction, liability for advice, insurance and payments. KM's `contracted`
    experts are ones the organisation vetted and signed itself, the way it already takes on
    subcontractors. One expert can work for many organisations (§7), but each organisation adds them
    itself.
  - **A directory where experts are found.** The step between KM and Stage B would be an opt-in list where
    organisations find experts they don't know yet, with Avenkin introducing and nothing more. It needs a
    server, and the moment Avenkin lists someone, it is implicitly vouching for them. That is decision 9.

## Decisions (owner, 2026-11-03: all ten taken as recommended)

1. **Who sets the list.** The organisation's profile sets the experts, and only it (or the device owner,
   with no profile) can add a `contracted` expert with a rate. A technician's personal additions are
   `staff` and unpaid. This answers IQ's decision 6 with "both". *Taken.*
2. **The customer's identity stays out of the handover** by default. The town is shown, but not the name,
   address or contact. An organisation may turn on the address for its own staff experts. *Taken.*
3. **The conversation goes to experts on the organisation's list by default.** Personal additions get it
   only when the technician turns it on for that send. Organisations can choose include, ask or never. *Taken.*
4. **The technician chooses the photos**, with the most recent four preselected. *Taken.*
5. **Billable time is the expert's reply, checked against the call the phone saw.** A difference is shown
   and never settled by the app. *Taken.*
6. **The technician sees minutes, not rates.** Rates and amounts appear only on the statement, for the
   device owner or the office. *Taken.*
7. **Assisting mode costs nothing on top of the app, and belongs to no organisation.** It can open
   handovers from any organisation, send replies, keep the expert card and the ledger, and nothing else.
   It needs no Field Assist seat, licence or profile, because the organisation that sends the job is the
   paying customer. While the app itself is a paid download, the expert still buys the app, or reads the
   PDF without it. The alternative, a seat per expert, would make a retiree pay before earning anything. *Taken.*
8. **Expert time stays off the customer's report** unless the organisation turns it on. *Taken.*
9. **No directory in KM.** Organisations add experts they already know, through the expert card. A list
   where organisations find experts they don't know is the first step of Stage B, and is its own plan
   if the owner wants it. *Taken.*
10. **A contracted expert's coaching steps are never offered as a team learning** unless the organisation
    turns that on for that expert. Who owns a paid adviser's method is a matter for the agreement, not
    the app. *Taken.*

## Phases (one PR each)

### P0 — the list and the pick (headless core, plus the settings rows)

- `EscalationContact` with `specialties`, `kind`, `onCall` and `rate`; the CT key `organizationExperts`;
  the personal store; and the contact-picker add flow.
- `ExpertPicker`, and "call a furnace expert" or "call Sam" through `CallRoute` and `CallPlacement`.
- The escalation record carries the expert and the observed call times.
- **Tests:** specialty from words and from the job's equipment; on-call windows across time zones; rota
  rotation; no ranking input exists; a personal addition can't carry a rate; `CallRoute` refuses anything
  but a cleaned number or handle.

**P0 as built (2026-11-06, headless).**

- **Types** (`Services/FieldAssist/Experts/`): `EscalationContact` (kind, specialties, `OnCallWindow`s in
  the expert's own zone, `Rate` for contracted only — the init drops a staff rate and decoding refuses
  one), `PersonalExpert` (no kind, no rate field at all), `ExpertListStore` (the two sources merged and
  marked, the rota position), `ExpertPicker` (words → equipment → on call → rota, one sentence that names
  the expert), `ExpertNameMatch`, `NoAnswerOffer`, `CallRoute`/`CallVia`/`CallPlacing`, and
  `ExpertCallMonitor` over a `CallObserving` seam on `CXCallObserver`.
- **The CT key** `organizationExperts` is profile-owned and carries the list as one JSON string; one bad
  entry drops the whole key by name. With no profile, the device owner writes the same key on the phone;
  with a profile, only the profile's list counts and the owner's waits under it.
- **The tool.** `escalate_to_expert` gains `call` and the `specialty`, `expert_name` and `via` parameters.
  With experts listed, `request` calls nobody and returns the offer ("Two furnace experts. Sam is on call.
  Call Sam?"); `call` by name never consults the picker. With none listed, `request` pages the pool as
  before. The expert gate also passes "call Sam" and a yes to a question that named the expert. The
  approval card reads "Call Sam".
- **The record.** `FieldSession.Escalation` gains the expert snapshot (id, name, kind), the route, and the
  observed call started, connected and ended times; older sessions decode unchanged. The job log gets an
  `expert_call` line per change. While the observed call is up the voice loop is paused through
  `ExpertCallAudioCoordinator`.
- **Settings.** Field Assist › Experts: the organisation's rows read-only under a profile, the device
  owner's list with kind, hours and rate without one, and the technician's own additions picked with
  `CNContactPickerViewController` (no Contacts permission; a snapshot, not an identifier).
- **Owed.** The P5 device check that a call placed by URL shows in `CXCallObserver` (and so the voice
  pause and the no-answer offer); the no-answer offer is given when asked (`status`, a bare `call`) and
  is not yet spoken unprompted; JI's CarPlay FaceTime refusal; the in-app privacy copy line comes with P1's
  handover, since P0 sends nothing off the phone.

### P1 — the handover (headless core, then the sheet)

- `ExpertHandover`, HD's `expert` audience, the `.ogcase` writer and reader, and the PDF and text
  renderings.
- The `expertHandover` filter scope and roster row, and the staged send through `JobSendService`.
- Generations and "send the latest".
- **Tests:**
  - no customer identity by default;
  - no page image under any setting;
  - every image passed the filter, and an unfilterable one is dropped and counted;
  - the transcript is denied by default for personal additions;
  - the budget drops the oldest photos and says so;
  - generation n+1 replaces n.

  `OutboundFrameConsumerTests` passes with the new consumer.

**P1 as built (2026-11-06, headless).**

- **The value** (`Services/FieldAssist/Experts/`): `ExpertHandover` (type `openglasses.handover`,
  version 1, kind `handover`) and the pure `ExpertHandoverBuilder` over the session, the job's
  conversation lines (`JobTranscriptExport.job`'s selection: the thread, else the log), the cited
  sources and procedure runs `SessionExporter.buildExport` already collects, and the photos already
  blurred. The site is `SiteTown` — the town read conservatively from the address (never the first
  comma part, never a digit) — and the address only for the organisation's own `staff` experts with
  the new profile-owned `expertHandoverIncludesAddress`; the customer's name and contact have no
  field. Readings go as corrected, with their unit and how they were taken. **Ruled out** is only
  what the technician writes on the sheet or says (`ruled_out`, verbatim), carried forward from the
  last generation sent; nothing on the record is read as ruled out. **Deviations** are an empty list
  until Plan JL P1 records them. Manuals by `CitationLineParser` reference (title, page, section),
  team learnings only to the organisation's own staff. No rate, model, usage or prompt field exists.
- **The conversation:** `ReportAudience.expert` and `ReportTranscriptPolicy.forExpert` — on (and
  editable) for the organisation's list, off unless turned on for a personal addition; the new
  profile-owned `expertHandoverTranscript` = `include` (locked on for the list), `ask` (off until
  turned on) or `never` (locked off).
- **Photos:** `ExpertHandoverPhotos` — the newest four preselected; each stored photo through
  `filteredOrUnavailable(_:for: .expertHandover)`, a new **mandatory** `PrivacyFilterScope` (blurred
  whatever the switch says), on the roster as `expertHandoverPhotos` (held image, chokepoint); an
  unfilterable one dropped and counted; clips never read; downscaled to 1,280 px; then
  `AttachmentBudget.photosFittingNewestFirst` drops the oldest until both copies (package and PDF)
  fit, and the sheet and the renderings say how many stayed.
- **Files:** `ExpertHandoverFile` — a stored-entry zip (`handover.json` + `photos/NN.jpg`) written by
  the new `StoredZipWriter`, read by `ZipArchiveReader`; the reader refuses another type or version,
  a missing manifest, any unsafe path, an unlisted entry and a listed photo that is missing.
  `com.openglasses.app.handover` (`.ogcase`) is exported and claimed in `OpenGlasses/Info.plist`,
  opened as a copy; opening one in this version checks it, removes the inbox copy and keeps nothing.
  `ExpertHandoverRendering` writes the text and the PDF (the shared `PDFLayout`; stamped AI-generated
  with no model named). Retention is 30 days, shortened by the profile-owned
  `expertHandoverRetentionDays` (1–30).
- **The send:** `JobSendService.proposeHandover` puts the draft on `ExpertHandoverSheet` (from the
  open job's "Send the job to an expert…" or by voice); only the sheet's Send or a spoken "send it"
  (`confirmHandover`) builds the files (`ExpertHandoverService`, protected staging) and opens the
  ordinary composer — Messages or Mail by the expert's handover channel, the share sheet for WhatsApp
  and AirDrop — whose own Send is the tap. A confirmed send writes `ExpertHandoverSent` (generation,
  photo ids, counts, never pixels) to `FieldSession.expertHandovers` and an `expert_handover_sent`
  log line; `ExpertHandoverLedger` gives the next send the same handover id and generation n+1.
  `escalate_to_expert` gains `send` (by name or the expert offered; `question`, `ruled_out`) and
  `send_it` (gated on the words being "send it"); the tool says to send first and call after, and the
  call never waits for it. Medical Compliance never offers it (`ExpertHandoverAvailability`, checked
  by the row, the tool, the draft and the build).
- **Disclosure:** the Privacy footers in Settings, `PrivacyInfo.xcprivacy`'s notes and
  `privacy.html`'s Field Assist row. No new service or route.
- **Owed.** P5 device checks: the composer and the FaceTime prompt in sequence; an `.ogcase` arriving
  by Messages, Mail, WhatsApp and AirDrop; the real blur on stored photos; Messages' real attachment
  ceiling. The PDF's photo layout on a phone. JL P1's deviations.

### P2 — Assisting mode

- Open an `.ogcase` as a copy into a read-only job view; **Take this job**, pause and **Done**; the clock
  with `BillableClock` recovery.
- The `time` reply, staged.
- Handovers grouped by organisation, with each handover's own retention applied.
- The expert card: filled in once, shared as a file or QR code, and imported on the organisation's side
  into the P0 list.
- **Tests:**
  - the clock across a kill and relaunch;
  - a reply carries every generation seen;
  - nothing in the view can reach the technician's job;
  - nothing from a handover reaches `BrainStore`, threads, team learnings or a search across
    organisations;
  - Assisting mode works with no licence, entitlement or profile installed, and with one installed it
    opens no Field Assist surface: every row of the "never opens" table is a test;
  - an imported card fills the list entry and a reply matches it.

**P2 as built (2026-11-06, headless).**

- **Where it lives** (`Services/Assisting/`, `App/Views/Assisting/`): Everyday › **Assisting**, shown
  whatever is installed, and a sheet on any tab when an `.ogcase` is opened. No switch, no setting,
  no plan letter in the UI. The list is one section per organisation, newest first, with no search;
  each row opens a read-only view of that handover (the question, the job, the unit, tasks,
  procedures, readings, ruled out, deviations, the conversation, the photos, manuals by name).
- **The store** (`AssistingHandoverStore`): Application Support/Assisting — `handovers.json` and one
  photo folder per handover named by a digest of its id. Registered as `assistingHandovers`:
  third-party, first-unlock, backup-excluded, cap 200, `deleteMatching` in the subject-erasure walk
  (a handover that names the subject goes whole), `removeAll`. **Retention** is each handover's own
  `retentionDays` after Done, or after the last change for one never Done, applied by a new
  `RetentionScheduler` target (`assistingHandovers`) with a per-record override, and on opening the
  list. **Generations:** a later generation with the same id, organisation and addressee replaces the
  held one and marks the changed sections (`HandoverChanges`); an earlier or repeated one is kept as
  it was; one from another organisation or to another expert is refused (`conflicting`).
- **The clock** (`AssistingClock`): Take this job, Pause, Resume, Done; a checkpoint every minute
  while it runs and when the app leaves the foreground; a relaunch that finds it running pauses it at
  the last checkpoint with `BillableClock.recover` (now also over plain fields), and the time since is
  carried as uncounted minutes.
- **The `time` reply** (`ExpertTimeReply`): an `.ogcase` of kind `time` — the same zip and manifest
  name, holding only `handover.json` — so no new UTI. It carries the handover id, every generation
  seen, accepted and done times, minutes and uncounted minutes, call minutes (nil: the expert's app
  sees no call), a note of up to 500 characters, and the expert as the list has them (`listId`,
  `listName`) plus their card's id, number and handle. No rate. Built and shown on Done; only Send
  Time Reply writes it into its own staging family (`StagedExportCoordinator.assistingReply`) and
  opens the share sheet, whose own Send sends; a completed share marks it sent.
- **The technician's side** (`ExpertReplyIntake`, `ExpertReplyMatch`): `ExpertHandoverFile.received`
  reads the kind first. A reply is attached only when its handover id is in a job's sent ledger, it
  is addressed to the expert that handover went to, an entry made from a card is answered by the same
  card, and every generation it claims was sent; otherwise it is refused by name and never kept.
  Accepted, it goes on `FieldSession.expertReplies` (open job or history; never a job locked for a
  departure) with an `expert_reply_received` log line (no note words). Reconciliation is P4.
- **The expert card** (`ExpertCard`, `.ogexpert`, `com.openglasses.app.expert-card`, JSON): card id
  `card-<uuid>`, name, number, FaceTime handle, channel, specialties, licences; no kind, hours or rate,
  and a decoder that drops any written in. Shared as a file or a QR code (the compact JSON, up to
  1,200 bytes; a longer card goes as the file). Kept in preferences (`expertCard`). The organisation
  opens the file or scans the code (Field Assist › Experts › Import a Card File / Scan a Card's Code),
  reviews it and adds it: under the card's id, staff with no rate, on the device owner's list (or the
  technician's own under a profile); a refreshed card keeps the organisation's kind, hours and rate.
  Licences are shown on the review, not stored on the list (the P0 entry has no field for them).
- **Unlocks nothing:** no Assisting source names `FieldAssistEntitlement`, a licence or a profile,
  and the flow runs identically with none or every entitlement installed without one read of it.
  `AssistingIsolationTests` has one test per "never opens" row, each scraping the Assisting sources
  for every type that surface declares, plus the reverse: only Assisting, the app's wiring and the
  erasure and retention walks may name the store, so nothing reaches `BrainStore`, threads, team
  learnings, retrieval or a tool.
- **Medical Compliance:** the plan closes the *sending* (§8) and says nothing of receiving, so
  Assisting stays available there: read-only, no network route, and the only egress is the expert's
  own reply by their own share.
- **Disclosure:** the Privacy footers, `PrivacyInfo.xcprivacy`'s notes and `privacy.html`'s Field
  Assist row say a handover sent to you stays on the phone for its period and never reaches the
  assistant, and the reply goes only when you share it.
- **Owed.** **Call back** (§7's "opens" column): a handover carries no number for the technician, so
  P2 has no call-back control; it needs a field P1's handover does not have. The P5 device checks: an
  `.ogcase` and an `.ogexpert` arriving by Messages, Mail, WhatsApp and AirDrop; the QR scan; the
  clock across a real kill and a FaceTime call with the app suspended.

### P3 — coaching steps

- The step editor, with dictation, and the `coaching` reply.
- Loading on the technician's side as a credited procedure, readings recorded against each step, and the
  safety check.
- **Tests:**
  - a step that hits the safety file is read with its rule and flagged;
  - the steps are read as written;
  - a reply with an unknown handover id, a closed job or another sender is never loaded;
  - coaching steps never reach the procedure library.

**P3 as built (2026-11-06, headless).**

- **The expert's side** (`Services/Assisting/ExpertCoachingReply.swift`, `App/Views/Assisting/
  AssistingCoachingSection.swift`): a Coaching steps section on every held handover — numbered steps,
  each an instruction with an optional reading (what, and its unit) and an optional "stop if"; add,
  edit, reorder and delete; typed, or dictated with the keyboard's own microphone (no new speech
  pipeline). `CoachingStep` tidies only white space and control characters and never shortens: a
  step over its limit (500 characters; 30 steps) is refused by name. The draft is kept on the held
  handover (`coachingDraft`, and the time reply's note as `noteDraft`), so a relaunch loses neither;
  the subject erasure reads both. **The reply** is an `.ogcase` of kind `coaching` — the same zip and
  manifest as the time reply, holding only `handover.json` — with the handover id, every generation
  seen, the expert exactly as the time reply carries them, and the steps; no rate. Its id is a digest
  of the handover and the steps, so the same steps sent twice are one reply. Staged into the
  `assistingReply` family; only the share sheet's own Send sends.
- **Accepting** (`Services/FieldAssist/Experts/ExpertCoachingIntake.swift`): `ExpertHandoverFile.received`
  reads the kind first and hands a coaching reply to `ExpertReplyIntake`. `CoachingReplyMatch` reuses
  the time reply's checks (`ExpertReplyMatch.verify`: the list entry, the same card, only generations
  sent) and adds: the handover must be the **open** job's (a closed or departure-locked job takes
  nothing, and says so), not already on it, and not in Medical Compliance mode. Anything else is "a
  file this phone didn't ask for" and nothing of it is kept. **Structural:** the only key to the job
  is `AcceptedCoaching`, whose init is private to that file and made only by the matcher;
  `FieldSessionService.loadCoaching` takes nothing else, and a source-scrape test holds that only the
  matcher makes the token, only the loader writes `FieldSession.expertCoaching`, and the reply file's
  type is named by neither the service, the runner, the tool nor the record.
- **The walkthrough:** `CoachingProcedure` builds a procedure in memory from the job's own record
  (`coaching-1`, `coaching-2`, …) whenever it is started or recovered after a relaunch — never written
  to a vault and never in `ProcedureLibrary`. One step per expert step; a "stop if" offers `continue`
  or `stop` (a closing step that says to call the expert back, outcome `escalated`); the last leads to
  an end step. It is credited "<name> (staff expert)" or "<name> (contracted expert)" — contracted if
  the sent record or the organisation's list says so. `Procedure.coaching` carries the credit and is
  not a coding key, so no vault file can claim to be someone's coaching. **Voice:** `procedure_runner`
  lists and starts coaching like any procedure, its description names "walk Sam's steps" / "load the
  coaching", and while coaching waits unwalked the prompt says which id to start; the Job tab shows it
  with a Walk these steps button.
- **Safety first:** at acceptance every step goes through `LearningSafetyCheck.check`; a step that
  collides carries `CoachingStepSafety` — the matched words and the rule, which is the safety file's
  own section (by heading, then by its words) or, for a fixed-list hazard no section names, the
  standing rule. The rule is the step's `safetyNote`, put before the step wherever it is shown to the
  model, and the step's words are never changed around it.
- **Read as written:** `ProcedureRunner.promptContext` and the tool's answer both use
  `CoachingProcedure.stepLines` — the read-as-written instruction (word for word; questions may be
  answered from the manual, saying where from; the step is never changed), the safety rule first,
  then "Read exactly as written:" and the stored instruction. `CoachingProcedure.isVerbatim` is checked
  before a coaching procedure starts; one that no longer matches the expert's words is refused.
- **Readings against steps:** `SpokenReading` gains `procedure_id` and `procedure_step_id`, stamped
  while any procedure runs on the current unit and carried by a correction; absent otherwise, so other
  readings store exactly what they did. The work record gains `coaching_walkthroughs` (credit, status,
  each step as written, the safety rule read first where flagged, the reading asked for, the stop-if,
  and what was found at that step), printed in the record's lines and so in the job report's PDF; the
  coaching task's line says "Coaching steps finished as …".
- **Never the library; the team's by review only:** `LearningCandidateService.offerCoaching` files the
  steps as an ordinary candidate for `LearningReview`, the finding credited to the expert. Offered for
  a `staff` expert; for a `contracted` one only when the organisation's own list entry has the new
  `coachingMayBecomeTeamLearning` (JSON `coachingToTeam`; off by default, dropped on a staff entry, set
  only on the profile's or the device owner's list — a personal addition has no such field). A
  refreshed card keeps it. The P0 Mirror allow-list is updated deliberately, with a test.
- **Medical Compliance:** P1 never offers the send, so no coaching should arise; if a file arrives
  anyway it is not loaded, and coaching already on a job is not walked or offered in the prompt in that
  mode.
- **Owed.** The P5 end-to-end device run (coaching arriving by each channel, walked by voice on the
  phone and on glasses); whether the keyboard's dictation suffices on a job site; a P4 question — the
  plan's §6 has the time reply carry "the coaching steps sent", which P2's reply does not (the
  coaching reply carries them on its own).

### P4 — time on the record and the statement

- `ExpertTimeReconciler`, `expertTime` on the work record, and the audience rules for both reports.
- `ExpertStatement` exported as CSV and PDF from the phone.
- The expert's `ExpertLedger`, by organisation and month, exported one organisation at a time.
- **Tests:** agree, differ, no reply; rounding and minimums; the customer's PDF never carries expert time
  unless the organisation turns it on; the technician's views never show a rate; a ledger built from the
  same replies matches the organisation's statement.

### P5 — device checks (owed, two phones)

- `CXCallObserver` sees a FaceTime call placed by URL, and whether it connected.
- An `.ogcase` opens from Messages, WhatsApp, Mail and AirDrop.
- An end-to-end run: send, take, call, coaching steps walked, Done, the reply attached, and the statement
  row.

## Acceptance

- "Get me a furnace expert" offers the right person by fixed rules in one sentence, and "call Sam" calls
  Sam.
- The expert receives the job as it stands: the unit, the work, the readings, what's been ruled out and,
  where allowed, the conversation. The customer's identity, page images and unblurred faces are never in
  it.
- Coaching steps come back, are walked one at a time, and leave readings against each step on the record.
- The expert's minutes are on the job, checked against the call. The month's statement exports from the
  phone. No money moves through the app.

## Open

- Whether a FaceTime call placed by URL is visible to `CXCallObserver` (P5).
- Whether replies should be signed with an expert key enrolled through the organisation's profile, so a
  statement can show a reply wasn't edited in transit. This is deferred until an organisation asks;
  reconciliation against the observed call covers the honest case.
