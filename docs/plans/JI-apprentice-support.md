# Plan JI — Apprentice Support (an hours logbook a journeyman signs, a scope-of-practice guard that never blocks, a call to the journeyman in one phrase, and practice that stays the apprentice's own)

**Status:** 📝 Drafted 2026-10-19 — nothing implemented. Revised the same day with the owner's
logbook sign-off design: "journeyman" throughout, the customer sign-off sheet reused, by the day,
the signer chosen from staff, bound to the entries by a fingerprint, and three levels of
self-signing protection (§9).
**Track:** Field Assist (B2B): apprentices in the regulated trades, HVAC/R and electrical first. The
first organisation is in Winnipeg, Manitoba, so Manitoba's rules are the worked case; nothing in the
design is Manitoba-only.
**Related:** Plan [JG](JG-regulation-practice.md) (regulation practice: the role model
`PracticeRole`, the question-bank format, the grader, the drive rules and the anonymous
candidates; this plan reuses all of them and adds nothing beside them), Plan
[IQ](IQ-closeout-unknown-units-and-calling-base.md) (calling base: the organisation's contact
list and `call_base`; IQ named "apprentice logbooks" as not in its plan, and this plan takes that
item over, see §0), Plan [IW](IW-goals-and-activity-trail.md) (goals, steps, check-ins, the
activity trail), Plan [EM](EM-work-record-and-parts.md) (the work record and the Send tap), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (the guided job, the CarPlay debrief, the brief), Plan
[F](F-field-assist.md) (vault procedures), Plan [FP](FP-team-learnings.md) (team learnings),
Plan [IM](IM-experience-recordings.md) (experience recordings), Plan
[GZ](GZ-expert-annotations.md) (expert annotations), Plans [L](L-webrtc-expert-transport.md) /
[M](M-webrtc-infra-and-audio.md) (expert streaming), Plan [EL](EL-equipment-identity.md)
(equipment identity), Plan [AD](structured-vision-assessment.md) (structured vision,
`instrument_reading`), Plan [IS](IS-refrigerant-toolkit.md) (the refrigerant toolkit and its
2026-10-19 jurisdiction amendment, being drafted on its own branch), Plan
[CT](CT-org-configuration-profiles.md) (organisation profiles), Plan [IP](IP-organisation-feature-switches.md)
(organisation feature switches), Plans [HO](HO-office-delivery-phone-half.md) /
[FX](FX-desktop-office-and-device-sync.md) (the office transport and Avenkin Office), Plan
[CP](CP-outbound-frame-privacy.md) (outbound frames), [EU AI Act review](../eu-ai-act-review-2026-10.md).
**Origin:** The owner, 2026-10-19, after drafting JG: everything else that helps an apprentice,
nine features, "add those in". On calling a journeyman: "all of them won't use glasses yet so it
would only be voice call, or FaceTime". Glasses are not the primary device. Every feature here works
on the phone alone (voice, the phone's camera, CarPlay), and glasses are an enhancement where they
add something.

---

## Trigger

An apprentice in a compulsory trade is never working alone in the eyes of the law. In Manitoba the
employer must make sure a journeyperson in the trade directly supervises the apprentice while they
gain practical experience (M.R. 154/2001 s. 10). The apprentice must record the hours worked and the
tasks learned or completed (s. 6(a)), and the employer must record the hours and verify the tasks
(s. 7(b)). Separately, only a trained service technician may install, repair or service equipment
that contains a regulated refrigerant (M.R. 103/94 s. 6), and that certificate expires every year
(s. 20(4)).

The app already knows most of what a logbook entry needs by the end of a job: time on the job, the
tasks done, the procedures run, the equipment, the debrief. Today it throws that away as far as the
apprentice is concerned. It also has no idea who the apprentice's journeyman is, what certificates
the apprentice holds or when they expire, or that a step in a procedure is one an apprentice should
not do without a journeyman present. And the one thing an apprentice most often needs on a job,
someone who knows to look at it, is three taps away in another app.

## Outcome

- After job 1007 closes: "I've drafted today's logbook entry: two hours ten on the job, mostly
  servicing the heat pump, and forty minutes commissioning the new thermostat. Check it on your
  phone when you stop." The apprentice opens it, moves ten minutes from one task to another, and
  confirms it. At the end of the day the apprentice hands the phone to Sam: the day's entries, each
  with its job, hours by task code. Sam strikes one he didn't see, picks his name from the staff
  list, enters his PIN and signs. Or, when Sam uses the app himself, "Ask Sam to confirm" and the
  day reads "Waiting for Sam to confirm" until his phone confirms it.
- An apprentice with no office: the same draft and the same sheet, with the journeyman's name typed
  and labelled as typed. At the end of the month, "Export my logbook" gives a record of hours by
  task and a summary of hours since the employer last reported them.
- At the step "Recover the refrigerant" in a procedure: "This step is for a trained service
  technician. I don't have your certificate on file. Want me to call Sam?" The step stays where it
  is; the apprentice can carry on, add the certificate, or call.
- "Call my journeyman." → the phone call is set up to Sam, from the organisation's list; iOS asks
  for the tap. "FaceTime Sam so I can show them." → a FaceTime video call, with "Flip to the back
  camera to show the job." When the call ends: "Want to note what you learned?" A sentence or two
  becomes a step on the apprentice's own learning goal. The call is never recorded.
- With the role set to apprentice, a procedure step comes with its reason, cited: "Isolate the power
  at the disconnect. Why: the capacitor can hold a charge after the breaker is off. Service manual,
  page 14." "Just the steps" turns the reasons off for the rest of the job.
- On the drive away from 1007: "Two minutes on what you learned?" Three fixed questions, answered
  by voice, then the logbook draft read back and confirmed by voice.
- "Show me what the crew knows about this heat pump." → the organisation's approved team learnings
  and experience recordings for that model, with a study prompt each.
- "Quiz me for my Red Seal." → original practice questions from a bank in a vault the organisation
  bought, keyed to the occupational standard's task list, never real exam questions.
- "Test me on this gauge." → the apprentice reads the gauge aloud; the phone's camera reads it too;
  the two are compared. This is personal practice only and is never shared.
- "My apprenticeship" shows hours this level by task, certificates with their expiry, goals and
  practice. "Send my progress to the office" sends exactly what the apprentice ticked, after a
  preview.

## 0 · What this plan takes over, and what it leaves where it is

- **From IQ.** IQ's "Not in this plan" lists "Apprentice logbooks. Waiting on a partner's answers
  about whether apprentices must keep a record, who signs it, and in what format." **JI takes that
  item over.** The public rules answer the first two for Manitoba (§1): yes, the apprentice must
  keep a record of hours and tasks, and the employer records hours and verifies tasks. The format is
  still open, so IQ's question survives as open question 1. **IQ keeps** `call_base`, the help pack,
  the organisation contact list (`organizationEscalationContacts`, IQ decision 6) and the close-out
  levels. JI's call to the journeyman (§6) is built on IQ's contact list and `call_base`, not
  beside them.
- **From JG.** JG's out-of-scope list names "exam material of any kind" and "apprentice logbooks
  (IQ, waiting on a partner's answers)". JI's exam preparation (§10) is a **deliberate exception**
  carried by this plan: original questions only, in JG's bank format, with an attestation field and
  validator rules JG does not need. JI's logbook is the logbook JG pointed at. JG has merged, so
  this plan adds one pointer to each of those two lines in JG's out-of-scope list and changes
  nothing else in JG.
- **Reused from JG, not restated.** Passenger mode in the car (JG §6, `DriveRole`), the solo
  technician's self-reviewed own questions (JG §3a), the optional syllabus in a bank (JG §2, §7),
  the suggested employee-notice wording (JG §10, `PracticeResultsNotice.suggestedWording`) and the
  owner's AI Act decision that transcription plus validation against a human-approved key is not
  an AI system (JG decision 10). Where JI touches the same ground it points at those sections.
- **The role.** There is one role model: JG's `PracticeRole { apprentice, qualified }`. JI does not
  add another. Everything here that differs by role reads `PracticeRole`, and the extra facts an
  apprentice has (trade, level, journeyman) live in an `ApprenticeProfile` that exists only when
  the role is `apprentice` (§2).
- **Other plans' text.** Apart from JG's two out-of-scope pointers, no other plan's file is edited
  here. FO's apprentice mode (§7) and the apprentice debrief (§8) are carried in this plan as
  amendments, referenced from here only. House style has no convention for a pointer line in an
  amended plan, so none is added to FO or F.

## 1 · What the public rules require (Manitoba, read 2026-10-19)

Everything in this section was read on 2026-10-19 from official sources (listed under Sources). Where
a source was seen only as a search summary or could not be opened, it says so, and the claim is
also in Unconfirmed.

**The apprentice's record.** The *Apprenticeship and Certification — General Regulation*, M.R.
154/2001 (consolidation current to 2026-10-19, in effect since 2024-10-30, last amended by M.R.
96/2024):

- **s. 6(a)–(b).** An apprentice must "document accurately in his or her practical experience
  record book the hours of practical experience worked and the tasks learned or completed", and make
  the record book available to the employer (to complete the employer's part) and to the executive
  director on request.
- **s. 7(b).** The employer must accurately document in that record book the hours of practical
  experience, verification of the tasks completed, and anything else the employer's part needs.
- **s. 1(1), "tasks".** The tasks, including the sub-tasks, specified in the *occupational
  analysis* for the trade. The occupational analysis is the Red Seal Occupational Standard or the
  National Occupational Analysis, or, where neither exists, the provincial occupational standard.
- **s. 9.** Overtime hours may count as practical experience.
- **s. 7(d).** The apprentice's daily hours may not start earlier or end later than the supervising
  journeyperson's working hours.
- **s. 7(e)(ii.1).** The employer notifies the executive director within 15 days when the
  journeyperson primarily responsible for supervising the apprentice changes.

**How hours reach the province today.** The AccessManitoba page says employers use AccessManitoba
to "log their apprentice's hours"; an apprentice "cannot log onto AccessManitoba to report or see
their hours"; only users linked to the company may report; and an apprentice cannot report hours for
the employer to approve. The employer FAQ says hours may be reported "as often as you like", at least
each time the apprentice begins technical training. An Apprenticeship Manitoba notice that the
paper "report of hours (blue book)" ended in January 2023 was seen in a search summary; its URL now
redirects to the home page, so that date is unconfirmed. **There is no file the province accepts
from an app**: hours are typed into AccessManitoba by a linked employer user. Whether AccessManitoba
takes hours by task or as a total was not visible (Unconfirmed).

So the regulation still names a record book of hours and tasks that the apprentice keeps and the
employer completes, and the province's own system takes only the employer's hours. JI's logbook is
that record book in digital form, plus a summary the employer can type in.

**Supervision.**

- **s. 1(2), direct supervision.** On-site access to a journeyperson with mutual communication; the
  journeyperson gives the technical information and guidance needed; and the extent of supervision
  is proportionate to the degree of risk of the task.
- **s. 1(1.1), final level.** An apprentice at the final level of a program with at least three
  levels is deemed directly supervised if they can reach a journeyperson by telephone or other
  telecommunication at all times while performing a task, the journeyperson gives the guidance
  needed, and supervision is proportionate to risk. This is the case where "call my journeyman"
  is part of the supervision itself, not a convenience.
- **s. 10.1.** Apprentices to journeypersons may not exceed 1:1; an employer who is a journeyperson
  counts, and a final-level apprentice in a program of three or more levels may be left out of the
  count.
- **s. 11(1).** A designated trainer may stand in for a journeyperson only in a *non-compulsory*
  trade. Refrigeration and Air-Conditioning Mechanic and Construction Electrician are compulsory
  certification trades (the employer fact sheet lists nine), so their apprentices are supervised by
  certified journeypersons only.

**The two first trades.**

| | Refrigeration and Air Conditioning Mechanic | Construction Electrician |
|---|---|---|
| Kind | Compulsory; Red Seal (commercial, 4 levels); a provincial residential stream (3 levels) | Compulsory; Red Seal; 4 levels |
| Hours | 1,800 per level, on-the-job and technical training together; 9 weeks of technical training per level | 1,800 per level, on-the-job and in-class together; 10 weeks in-class per level |
| Task list | Red Seal Occupational Standard (2019) for commercial; 2023 provincial occupational standard for residential | Red Seal Occupational Standard (edition not checked) |
| Certification | Red Seal interprovincial exam (commercial); provincial exam (residential) | Red Seal interprovincial exam, and a further mandatory licence after the certificate of qualification (issuer not checked) |
| Other | A trained service technician certificate for regulated refrigerants (M.R. 103/94) | — |

**How an occupational standard's task list is built.** A Red Seal Occupational Standard divides the
trade into major work activities (lettered, A to F for the refrigeration trade), tasks (numbered
through the standard, A-1 to F-15) and sub-tasks (A-1.01 and so on). Each sub-task has performance
criteria, evidence of attainment and a range of variables, and knowledge (learning outcomes and
objectives). The exam weighting is published per major work activity (the refrigeration trade's
interprovincial exam has 125 questions). JI uses only the shape: codes, short titles, the
hierarchy. It does not copy a standard's text (§3).

**The refrigerant certificate.** M.R. 103/94 (*Ozone Depleting Substances and Other Halocarbons
Regulation*, current to 2026-10-19, last amended by M.R. 178/2005):

- **s. 6.** No person other than a trained service technician shall install, repair or service
  equipment that contains or uses a Class 1, 2 or 3 substance, or do other work on it that may
  release one. Class 3 is the hydrofluorocarbons, "plus all other hydrofluorocarbons, whether
  existing alone or in a mixture", so R-410A and R-32 are in.
- **s. 20.** Certification follows a course approved by the minister; the certificate has a number
  (s. 20(3)); it expires on June 1 of the year after the year it was issued, and may be renewed no
  earlier than 30 days before it expires (s. 20(4)).
- **s. 8(1) and s. 25(2).** A trained service technician records each service in an approved form
  and puts their certificate number on a recharge label.
- **No apprentice exemption** appears in the regulation's text. Whether an apprentice working
  beside a certified journeyman needs their own certificate to do s. 6 work is therefore unclear
  from the text and is in Unconfirmed.

**IS does not yet model Manitoba.** IS's 2026-10-19 amendment models Canada federal, Ontario,
British Columbia and Alberta. Manitoba's regulation is the one that matters for the first
organisation's certificates and labels; adding a Manitoba policy is IS's work (open question 13).
JI only needs the certificate as a record with an expiry, which does not wait on IS.

## What exists today (verified against `main` @ `e69c114a4`, 2026-10-19)

- **Calls.** `phone_call` (`PhoneCallTool`) resolves a name through `ContactLookupHelper.resolve(name:)`,
  strips the number to digits and `+`, checks `UIApplication.shared.canOpenURL` and opens
  `tel://<number>`. It returns "Calling …" whether or not the call connects. `open_app`
  (`OpenAppTool`) maps "facetime" to `facetime://`, which opens the FaceTime app with nobody to
  call. Nothing places a FaceTime call to a person. `WakeWordService.pauseOtherAudio()` reads
  `CXCallObserver().calls` and never interrupts a connected phone or FaceTime call;
  `ScanAssistInterruption` treats a call as an interruption.
- **IQ's contact list is drafted, not built.** `SettingKey` has no `organizationEscalationContacts`;
  its `Kind` is `profileOwned(ValueType)`, `ceiling(pinnedTo:)` or `startingValue(ValueType)`, with
  `ValueType` `bool`, `string` or `strings`. A structured key is carried as a JSON string with a
  strict decoder, as `capturedManualsPolicy` is.
  *2026-11-06:* Plan [KM](KM-expert-on-the-job.md) P0 built `EscalationContact`, `CallRoute` and
  `CallPlacement`, with the list as the profile-owned JSON string `organizationExperts`; JI reuses them.
- **Who the technician is.** `Config.technicianDisplayName` (profile-owned when a profile sets it;
  `TechnicianName.clean`). CT's rule: identity is per person, policy is per device; the app has no
  user account.
- **The job.** `UpcomingJob { id, jobReference, site: JobSite { customer, address, contact },
  faultReport, equipment: [KnownEquipment { model, serial }], scheduledFor, notes, attachments,
  origin }`. No field names a crew or a supervisor. `Contracts/job-file.md` has none either.
- **Time and work.** `BillableClock` credits time on the job (pauses and uncounted time excluded).
  `WorkRecord` carries `tasks: [FieldSession.Task]` (status `recommended`, `accepted`, `declined`,
  `deferred`, `in_progress`, `done`, `abandoned`), `equipment` (model, vault section), parts and
  evidence. `JobHistoryIndex` indexes finished visits by site, serial and model.
- **Procedures.** `Procedure { id, title, version, vault, safetyNotes, steps }`, each
  `Procedure.Step { id, title, instruction, expectedInput?, safetyNote?, calcRef?, citations,
  branches, defaultNext?, terminal, outcome?, requiresConfirmation? }`, run by `ProcedureRunner`
  through the procedure tool. Steps have citations but no reason field.
- **The debrief.** `GuidedJobFlow.startDebrief(jobId:)`; `DebriefSummary.Category` is `findings`,
  `follow_ups`, `for_base`, `parts_or_materials`, `customer_notes`; a spoken "save" writes a
  `JobDebrief` (entries with their source turns) to the job. CarPlay's Jobs list
  (`CarPlayJobsList`) offers Debrief on a past job.
- **Sign-off on the phone.** `CustomerSignOff` (`Job/CustomerSignOff.swift`) records an acceptance
  with `Method` `drawn` | `typed` | `declined`, the summary word for word (`summaryLines`) and
  `summaryDigest` (`sha256:` over those lines), and the signature's picture and PencilKit strokes.
  `App/Views/Job/CustomerSignOffView.swift` holds `JobSignOffStepView` (hand the phone over, or
  record a decline), `CustomerSignOffSheet` (full screen, the frozen summary, "a record of what you
  agreed to, not a legal e-signature", a Guided Access hint) and `SignatureCanvas` (`PKCanvasView`
  pinned to light style with black ink). No staff roster exists anywhere: `SettingKey` has
  `technicianDisplayName` only, and HO's enrolments name phones, not people. Each enrolled phone
  and the office hold an Ed25519 application key (`Contracts/office-reports.md` §2).
- **Goals and the trail.** IW's `Goal` with `GoalSource` `wearer` | `proposed`, `GoalStep`,
  `StepAction` (six kinds; JG proposes a seventh, `practise`), `GoalDrafter`, `GoalAdvancePolicy`
  (two unprompted goal sentences a day), `ActivityKind` (`action`, `planned_step`, `scheduled_run`,
  `told_you`, `held`, `refused`), `GoalStore` and `ActivityStore` as sensitive stores.
- **Team learnings.** `LearningEntry`, `LearningEntryStore`, `LearningCorpus`;
  `LearningCandidate.Origin` is `spoken`, `report`, `reportReview` (IM proposes `recollection`);
  `FieldAssistCapability.teamLearnings` is granted to team and enterprise licences only.
- **Camera.** `PhoneCameraSource` captures one still from the back camera with no preview;
  `CameraService.filteredStill(for:source:)` is the only still reader;
  `PrivacyFilterScope.visionAssessment` covers stills sent to a vision vertical; every camera-pixel
  consumer is listed in `OutboundFrameConsumer`, enforced by `OutboundFrameConsumerTests`.
  `StructuredVisionService` with `InstrumentReadingSchema` returns a typed reading; `vision_assess`
  is the tool.
- **Expert view.** `EscalationCoordinator`, `ExpertStreamBridge` (MJPEG one-way, a meeting link,
  WebRTC selectable) and the expert transports exist; live support needs a relay or a meeting, and
  the office's live-support phase is FX8. GZ (annotations) is drafted, not built.
- **Office transport.** `DeliveryRequest.Payload`, `OpKind` (`Services/Offline/QueuedOp.swift`),
  `OfficeReportSink.handledKinds`, FP's outbox pattern (`LearningBundleOutbox`), and the strict
  reader `LearningBundleJSON`.
- **Privacy and markets.** `SensitiveStore` cases are registered in `DataStoreRegistry` and walked
  by the subject erasure. `MarketAvailabilityPolicy.Capability` is `faceRecognition`,
  `emotionInference`, `firstAidTriageBusiness`.
- **Not built:** JG (all of it, including `PracticeRole` and the bank format), IQ, IS, IM, GZ, IP.
  JI depends on JG P0 for §10 and on IQ P3 or its own first slice of it for §6; everything else
  stands on built code.

## Design

### 2 · The apprentice, their trade and their journeyman

**`PracticeRole` is the role** (JG §9). JI reads it; it does not redefine it. When it is
`apprentice`, the phone also keeps an **`ApprenticeProfile`**:

```swift
struct ApprenticeProfile: Codable, Equatable {
    var taskListID: String?          // the trade's task list (§3), e.g. "mb-racm-commercial"
    var level: Int?                  // 1…n, from the task list's levels
    var levelStartedOn: Date?        // a day
    var registrationNumber: String?  // the province's apprenticeship number, optional
    var journeyman: SupervisorContact?
}
struct SupervisorContact: Codable, Equatable {
    var name: String
    var phone: String?               // E.164 after cleaning
    var faceTime: String?            // a phone number or an Apple Account email
    var source: Source               // .job, .office, .profile, .personal
}
```

- **Who the journeyman is, in order:** the job (when the job file names one; a job-file contract
  addition, office half), the office's assignment for this enrolment (office half), the organisation
  profile (a per-person link may name the assigned journeyman by staff id in `organizationStaff`,
  §9's roster, which IQ's contacts also read, so there is one list of people, not two), and the
  apprentice's own setting. `SupervisorResolver` (pure) picks the first present and says where it came from. A name
  alone ("Sam") is resolved through Contacts at call time, as `phone_call` does now.
- **Level matters only where a rule says so**: s. 1(1.1)'s final-level deeming (§5), and the
  progress screen (§11). The phone never moves an apprentice up a level; the apprentice sets it.
- Settings › Field Assist › Apprenticeship holds the role (the same switch JG puts in Practice
  questions, shown in both places), the profile and the certificates (§4). An organisation profile
  may set the role's default and the task list; it may not hide the setting (JG §9).

### 3 · Task lists are data the organisation or vault author supplies

The app ships **no task list**. An occupational standard is Crown copyright, its wording is the
publisher's, and the right list depends on the trade, the stream and the edition. A task list
arrives inside a vault, beside JG's banks:

- `VaultManifest` gains `tasklists_dir`; each `tasklists/<id>.json` is one trade's list for one
  standard edition (`kind: "avenkin.task-list"`, `schemaVersion: 1`).
- **Fields.** `id`; `trade` (a display name); `jurisdiction` (ISO 3166-2, `CA-MB`); `standard`
  (`{ name, edition, url }`, where the URL points at the publisher's own copy); `levels` (`[{ level,
  hours, technicalTrainingWeeks? }]`, as the province states them); `items` (`[{ code, title,
  parent?, kind: "activity" | "task" | "subTask" }]`, codes in the standard's own syntax, titles at
  most 80 characters and written by the author, not pasted); optional `procedureCodes` (`{
  procedureID: [code] }`, a vault procedure maps to the sub-tasks it exercises); optional `hints`
  (`{ code: [word] }`, up to eight lowercase equipment or work words per code, for drafting, §5).
- **Validated where the vault is.** `TaskListValidator` (pure, over bytes, on the strict reader JG
  reuses) runs inside `VaultValidator`, so a bad list refuses the vault at import like a bad
  procedure: unknown keys refused by path, codes unique, every `parent` present, at most 2,000 items,
  every string capped, no control or bidirectional characters. The same source is run by the author
  through a `Scripts/check-task-list.swift`, as JG's bank checker is.
- **Rights.** The vault guide gains a paragraph: the author must hold the right to publish what they
  put in a task list. Codes and a short structure are what the app needs; the standard's
  performance criteria, ranges and learning objectives are not wanted and have no field to go in.
- **Trust.** A task list counts the same whether its vault is signed or not, because it carries no
  answers: it is a list of headings the apprentice files time against. It is shown with its source
  ("From your organisation's vault" / "From <vault name>").
- **Fixtures are invented** ("X-1.01 (invented) Performs widget safety checks"), and a guard test
  fails on a task-list fixture without the "(invented)" marker, as JG's practice fixtures do.

### 4 · Certificates and their expiry

`CredentialRecord` (pure value, stored in `SensitiveStore.apprenticeship`):

```swift
struct CredentialRecord: Codable, Equatable, Identifiable {
    let id: String
    var kind: Kind      // .apprenticeshipRegistration, .certificateOfQualification,
                        // .refrigerantHandling, .electricalLicence, .other(String)
    var jurisdiction: String   // "CA-MB"
    var title: String          // as the issuer names it: "Trained service technician"
    var number: String?
    var issuedOn: Date?        // a day
    var expiresOn: Date?       // a day
    var issuer: String?
}
```

- Entered by the apprentice (typed, or read from a photo of the card through the same on-device OCR
  `scan_code` and the medication tool use, with every field read back for correction), or given by
  the organisation through the office half. A photo is not kept.
- **Expiry is a date, not a judgement.** `CredentialStatus.of(record, today)` is `valid`,
  `expiresSoon(days)` (inside 45 days), `expired(on)` or `noExpiry`. One reminder 45 days out and one
  on the day before, as `ScheduledTaskKind` tasks that make no model call, worded with the issuer's
  rule where the record carries one ("Your trained service technician certificate expires on June
  1. It can be renewed from May 2."). For Manitoba's certificate the renewal window comes from s.
  20(4); a starter rules file (§5) supplies it, the app does not hard-code it.
- IS's open question 5 (certificate numbers on the work order) reads these records when it lands.
  JI does not put a certificate number on any work order by itself.

### 5 · The scope-of-practice guard: it informs, it never blocks

**What a step requires.** A requirement is a tag on something the phone already runs:

- a procedure step's optional `requires` (a new optional field on `Procedure.Step`, authored in the
  vault: `["refrigerant_handling", "direct_supervision"]`); older builds ignore it;
- IS's refrigerant events, when IS lands (opening a circuit, adding, recovering, decommissioning),
  each tagged `refrigerant_handling`;
- nothing else in P-phases here. The phone does not guess a requirement from a step's words.

**What the organisation says a tag means.** A profile key, `organizationScopeRules` (profile-owned,
a JSON string with a strict decoder), maps a tag to a rule: `{ "refrigerant_handling": {
"credential": "refrigerantHandling", "supervision": "direct" }, "live_electrical": { "supervision":
"direct" } }`, each with an optional citation (instrument, section, as-at date) and the role it
applies to (default `apprentice`). The app ships one **starter file for Manitoba** as data, with the
citations from §1 (M.R. 103/94 s. 6 and s. 20(4); M.R. 154/2001 s. 1(2), s. 1(1.1) and s. 10), which
an organisation adopts by naming it in its profile. It is never applied by default. Without rules,
the guard says nothing.

**What the phone knows about today.** `SupervisionToday` is `onSite(name)`, `reachable(name)` or
`unknown`. It comes from the apprentice, asked once when a job starts with the role set to apprentice
and rules present ("Is Sam with you on this one?"), or from the job when the job file names a crew.
The phone cannot see whether anyone is on site, and does not try.

**`ScopeGuardPolicy.check(requirements, role, profile, credentials, supervisionToday, rules, today)
-> [ScopeNotice]`** (pure). A notice is `credentialMissing(kind)`, `credentialExpired(kind, on)`,
`credentialExpiresSoon(kind, on)` or `supervisionNeeded(.direct | .reachable)`, each with the rule's
citation and one offer, **call the journeyman** (§6), when one is known. Two rule-specific cases:

- **Final level.** With `supervision: "direct"` and the apprentice at the final level of a task
  list with three or more levels, `reachable(name)` satisfies the rule (s. 1(1.1)), and the notice
  becomes a reminder only when the journeyman is unknown: "If Sam can't be reached, this step
  waits for them."
- **Proportionate to risk** (s. 1(2)(c), s. 1(1.1)(d)) is a judgement for people. The guard does not
  grade risk; it says what the organisation's rule says.

**How it speaks.** Once per step per job, before the step is read, then shown on the step's card. It
never stops the procedure, never asks for a confirmation before the step can continue, and never
changes the step's state. The apprentice can say "carry on", "add my certificate" or "call Sam".

**What it never does.** A notice is **not** written to the work record, the logbook, the activity
trail's shared report or anything sent to the office. Whether an apprentice did a step without the
journeyman is between the apprentice, the journeyman and the employer, and a phone that
reported it would be a monitoring tool. The trail keeps a `told_you` entry on the phone, title only
("Mentioned the certificate for one step"), which the apprentice can see and delete.

**Wording.** IS decision 4 applies: inform, never accuse or block. JI reuses IS's wording guard (no
"violation", "illegal", "fine", "offence", "breach", "penalty" or "contravene") and adds the words
that point at the person: "unqualified", "unlicensed", "unauthorised", "not allowed to", "you can't",
"you must stop". A test runs every notice template through the combined list. Examples (exact
strings, in `ScopeNoticePhraser`):

- "This step is for a trained service technician. I don't have your certificate on file. Want me to
  call Sam?"
- "Your trained service technician certificate on file expired on June 1. Want me to call Sam?"
- "This step is one your organisation has a journeyman on site for. Is Sam with you?"

### 6 · Ask my journeyman, live: phone first

**Phrases.** "Call my journeyman", "call Sam", "FaceTime Sam", "video call my journeyman so I
can show them", "audio FaceTime Sam".

**One contact list.** The journeyman is §2's `SupervisorContact`; "call base" and "call the
office" stay IQ's. JI's call lands on IQ P3's `call_base` when that has shipped (`who:
journeyman`, `via: phone | facetime | facetimeAudio`), or ships as the first slice of it when JI
P4 comes first: whichever lands first builds `EscalationContact`, the CT key and the call route, and
the other reuses them. *2026-11-03:* Plan [KM](KM-expert-on-the-job.md) P0 now builds `EscalationContact`,
`CallRoute` and `CallPlacement` first; JI reuses them. IQ's help pack (readings, chosen photos, cited pages) is offered before the
call when IQ P3 exists; a call never waits for it.

**The route (pure).** `CallRoute.make(contact, via) -> CallRoute?` builds `tel:<number>`,
`facetime:<handle>` or `facetime-audio:<handle>` from a cleaned number or an email handle, and
refuses anything else. `CallPlacement` (a seam over `UIApplication.open(_:options:)` with its
completion) reports whether iOS accepted the URL; the tool's reply says what happens next, honestly:
"Calling Sam. Your phone will ask you to tap Call." It never says the call connected, because the
app cannot know until `CXCallObserver` sees it.

**What iOS allows** (device checks owed, Unconfirmed):

- An app opens `tel:` and FaceTime URLs; iOS shows its own confirmation before dialling. The app
  cannot place a call without that tap, and cannot open a URL while it is in the background.
- In the car, the confirmation is on the phone. JI does not try to get round it: in CarPlay, "call
  Sam" answers "I can't start a call from the car without a tap on the phone. Say 'Hey Siri, call
  Sam', or use the car's phone." (P4's device pass measures what actually appears.) For Siri to find
  Sam they must be in Contacts; the Apprenticeship screen offers "Add Sam to Contacts" (a Contacts
  write, asked for at that moment only).
- **FaceTime video is never offered while CarPlay is connected.** "Video calls wait until you've
  stopped."
- FaceTime starts on the front camera. The reply says "Flip to the back camera to show the job",
  and the phone's own camera use is stopped first (`PhoneCameraSource` holds nothing).
- A FaceTime call to someone without an Apple device fails in FaceTime; the tool offers a voice call
  instead when a phone number exists.

**Glasses later.** When glasses are connected and the organisation runs live support (Plans L/M and
the office's FX8), "show Sam through my glasses" uses the existing `EscalationCoordinator` and
`ExpertStreamBridge`, and GZ's annotations reach the apprentice as words, a phone overlay and a HUD
line. That is a later phase (P4b) and depends on those plans; nothing in P4 needs glasses.

**No call recording, and why.** The call is never recorded, transcribed or summarised by the app.
The journeyman did not agree to be recorded, a customer may be in the frame or within earshot,
and an employee's calls to a supervisor are exactly the record an employee-privacy notice (§13) has
to justify. iOS does not give an app the audio of a phone or FaceTime call in any case, and this
plan does not look for a way round that.

**Afterwards: what was learned.** When `CXCallObserver` sees a call end within 30 minutes of one
this tool started, and the app is in use, it offers once: "Want to note what you learned?" The
apprentice speaks a sentence or two; on-device transcription keeps it as said. It becomes a
**proposed step** on the apprentice's standing learning goal ("What I'm learning on the job"), held
and read back through IW's `GoalDrafter` and stored only on yes. The note is the apprentice's: it
stays on the phone, and leaves only if the apprentice puts their goals in a progress share (§11).
The logbook draft for the job gains one line the apprentice may keep or remove: "Called Sam during
this job." (For a final-level apprentice that line is part of how s. 1(1.1) supervision is shown.)

### 7 · Apprentice mode in procedures (an amendment to FO and F, carried here)

- **The same steps, with the reason.** `Procedure.Step` gains an optional `why` (at most 240
  characters, authored in the vault) and keeps its `citations`. With the role set to apprentice,
  `ApprenticeStepPhraser` (pure, exact strings) reads the instruction, then "Why: <why>", then the
  first citation ("Service manual, page 14"). A step with no `why` but a citation reads the cited
  passage's first located sentence from the loaded manual through `PassageLocator`, introduced as
  "The manual says: …". A step with neither gets no reason. **The model never invents a reason**: a
  reason is the author's or the manual's, and it is always cited.
- **"Just the steps"** turns reasons off for the rest of the job; "explain that one" gives one step's
  reason when they are off. The qualified role hears just the steps by default and can ask the same
  way.
- **Safety notes are not reasons.** A step's `safetyNote` is read for every role, as today, before
  the instruction. Apprentice mode adds, never removes.
- **Scope notices (§5) sit before the instruction**, after the safety note.
- The vault guide's procedure section gains the `why` and `requires` fields, with an example.

### 8 · The post-job debrief, for an apprentice (an amendment to FO §6, carried here)

FO's debrief stays the job's: findings, follow-ups, for base, parts, customer notes, written to the
job's record by a spoken "save". The apprentice part is separate and is the apprentice's:

- **Three fixed questions**, asked after FO's debrief is saved, or on their own: "What did you
  learn?", "Anything you'd like to practise?", "Anything you weren't sure about?" They are fixed
  strings, not model questions. Each answer is kept as said (trimmed), in `ApprenticeDebrief`
  (`SensitiveStore.apprenticeship`), never on the work record, the work order or the customer
  summary.
- **Then the logbook draft, read back** (§9): "About two hours ten. I've put an hour forty under
  servicing HVAC/R systems and thirty minutes under commissioning. Right?" "Yes" confirms it. "Move
  ten minutes to commissioning" and "put it all under servicing" are understood when the words match
  a task title or code; anything else gets "Fix it on your phone when you stop."
- **What feeds what.** "What did you learn" and "practise" become proposed steps on the standing
  learning goal (§6), held until yes. An "unsure" answer that names a code clause JG's
  `ClauseReference` recognises becomes JG's gap candidate (JG §8 trigger (b)), anonymous,
  organisations only, inside JG's caps and switch; anything else stays on the phone.
- **About two minutes.** Each answer window is 20 seconds; the whole is offered as "two minutes".
- **CarPlay rules are JG's** (§6 there): the offer is an unprompted goal sentence under IW's cap of
  two a day; it starts only after 20 seconds of quiet and never over a navigation prompt; "stop",
  "not now", a call or CarPlay disconnecting ends it at once; nothing is shown on the car screen.
  JG's passenger mode applies unchanged: the same once-a-drive question sets `DriveRole`, and as a
  passenger the phone's screen may show the logbook draft while it is read back, so a correction
  can be made by tap; as a driver or unknown, voice only.
  **One unprompted apprentice offer per drive** covers this debrief and JG's drive questions: after
  a job closes the debrief is offered; on the way to a job, JG's questions.

### 9 · The apprenticeship hours logbook

**An entry.**

```swift
struct LogbookEntry: Codable, Equatable, Identifiable {
    let id: String
    let day: Date                         // a day, local
    var jobReference: String?             // and the session id, when drafted from a job
    var allocations: [TaskAllocation]     // { code, minutes }, codes from the task list
    var unassignedMinutes: Int
    var supervision: SupervisionNote      // { journeyman?, kind: onSite | reachable | none | unknown }
    var note: String?                     // the apprentice's own words, optional
    var origin: Origin                    // .drafted, .manual
    var state: State                      // see below
    var revision: Int                     // raised by every edit; earlier revisions are kept
}
```

**Drafting is deterministic.** `LogbookDrafter` (pure) builds a draft for a closed job from what the
phone already holds:

- **Minutes** from `BillableClock`'s credited time for the session, rounded to five minutes. Drive
  time is not counted unless the organisation's rule says it is (open question 4). Overtime counts
  (s. 9). The phone does not check s. 7(d)'s working-hours rule; it cannot see the journeyman's
  day.
- **Which tasks**, in order: procedures run (`procedureCodes` in the task list); done work tasks and
  the equipment's vault section matched against `hints`; then the debrief's findings matched the
  same way. Minutes are shared between matched codes in proportion to procedure-step time where the
  runner has it, else evenly. Whatever matches nothing goes to `unassignedMinutes`, which the
  apprentice files.
- **No model.** A model could guess codes from a transcript; this plan does not, so that every
  allocation can be traced to a procedure, a task or a word the author listed (open question 5 asks
  whether a labelled model suggestion is wanted later).
- Drafted when the job closes, read back in the debrief (§8), shown on the Job tab's past-job page
  and on the Apprenticeship screen, and offered once as a notification when nothing else is.

**States.** An entry is `draft` → `confirmed` (the apprentice, by tap or a spoken yes) or
`returned(reason)` (struck by the journeyman, or returned by the office) → edited → `confirmed`
again. Every edit raises the entry's `revision`, and earlier revisions are kept. An unconfirmed draft
older than 14 days is kept but flagged ("3 drafts to check"). Signing is not an entry state: it is a
**sign-off over a day** (or a job), below, and `LogbookDayStatus` (pure) reads it as `unsigned`,
`waitingForConfirmation(signer)`, `signed(signOff)` or `changedAfterSigning(signOff)`.

**Verification: the journeyman signs on the apprentice's phone, by the day** (owner decision,
2026-10-19).

*What the signature is, legally.* M.R. 154/2001 s. 7(b) puts verification of the tasks on the
**employer**, and the employer reports hours in AccessManitoba (§1). The journeyman's signature on
the phone is **evidence the employer relies on** when it verifies and reports. It is not the
submission, and the phone sends nothing to the province. Whether Apprenticeship Manitoba accepts a
digital record book with this sign-off is still a partner question (open question 1). The sheet's
copy says so in plain words, as the customer sheet does: "This records that you checked these
entries, for <organisation>'s records. It isn't a legal e-signature, and nothing is sent to the
province."

*The sheet.* `JourneymanSignOffSheet` is built from the customer sign-off's parts in
`App/Views/Job/CustomerSignOffView.swift`: the flow of `JobSignOffStepView` (hand the phone over),
the full-screen frozen summary of `CustomerSignOffSheet`, its Guided Access hint, and
`SignatureCanvas` (the `PKCanvasView` pinned to the light style with black ink). The phone is handed
over and shows exactly what is being agreed:

- the apprentice's name, the day, and each of the day's confirmed entries: hours by task code with
  the code's short title, the job each came from (job number, or "No job number"), and the
  supervision note; then the day's total;
- **strike** and **edit** on each entry before signing. A struck entry leaves this sign-off and goes
  back to the apprentice as `returned("Struck by Sam")`; an edit (minutes, or the task code from the
  task list) is made on the sheet, shown as edited, and is what gets signed. The apprentice sees
  both afterwards ("Sam moved 20 minutes to X-11 (invented)");
- the signer's name (below), the protection step (below), the drawn signature, and **Sign these
  entries**.

*By the day, or by the job.* `organizationLogbookSignOffScope` (a profile-owned string, `day` or
`job`, default `day`) sets the unit. A day not signed on the day stays `unsigned` and is signed in a
**weekly catch-up**: one sheet listing each unsigned day as its own section, each signed separately
(its own fingerprint and its own sign-off record; the protection step is taken once per sitting of
at most ten minutes). A weekly reminder, a `ScheduledTaskKind` task with no model call: "Three days
to get signed this week."

*Who signs: chosen from the organisation's staff, never typed.* Nothing on the phone lists an
organisation's people today: `SettingKey` holds `technicianDisplayName` only, IQ's
`organizationEscalationContacts` (name, role, phone, channel) is drafted and unbuilt (*2026-11-06:*
KM P0 built it as `organizationExperts`), and HO's
enrolments know phones, not people. JI proposes **one staff roster** that IQ's contacts and JI's
journeyman both read:

```swift
struct StaffMember: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var roles: [StaffRole]            // .journeyman, .apprentice, .office, .other(String)
    var trades: [String]              // trade ids, matched against the task list's trade
    var certificate: CertificateOnFile?   // { number?, expiresOn? }
    var phone: String?
    var faceTime: String?
    var signOffPIN: PINVerifier?      // salted hash only, see protection (b)
    var enrolmentID: String?          // the journeyman's enrolled phone, for protection (c)
}
```

carried by a new profile-owned key, `organizationStaff` (a JSON string with a strict decoder, as
`capturedManualsPolicy` is), and refreshed by the office over HO's delivery route once the office
half publishes it. IQ's escalation list becomes staff ids plus outside numbers, so there is one list
of people (open question 19). The sheet's picker shows **only staff with the `journeyman` role for
the apprentice's trade**, each with their certificate's expiry when it is on file ("certificate on
file expires 2027-06-01"; an expired one is shown as expired and recorded with the sign-off). The
apprentice's assigned journeyman (§2) is preselected and can be changed. **An organisation has no
free-text name.** A solo setup with no roster may type a name; it is recorded as
`nameSource: .typed` and labelled "Name typed on this phone" wherever the sign-off is shown or
printed, as the customer sheet labels a typed name.

*Bound to exactly what was shown.* `LogbookDayFingerprint` is SHA-256 over a canonical encoding of
exactly the entries on the sheet after strikes and edits: entry ids and revisions, the day,
allocations (code, minutes), job references and supervision notes, in a fixed order with fixed
number formatting, pinned by a fixture. The sign-off keeps the lines word for word and the digest,
as `CustomerSignOff` keeps `summaryLines` and `summaryDigest`:

```swift
struct JourneymanSignOff: Codable, Equatable, Identifiable {
    let id: String
    let scope: Scope                  // .day(Date) or .job(String)
    let entryIDs: [String]
    let entryLines: [String]          // what was on the screen, verbatim
    let fingerprint: String           // "sha256:<hex>"
    let signer: Signer                // { staffID?, name, nameSource: .roster | .typed }
    let signerCertificateExpiresOn: Date?
    let signedAt: Date
    let signatureImageId: String?     // nil when confirmed from the journeyman's own device
    let strokeDataId: String?
    let protection: Protection        // { level, pinVerified, coarseLocation? }
    var deviceConfirmation: DeviceConfirmation?
}
```

**Any later change** to a signed entry (an edit, a move between codes, a removal) recomputes the
day's fingerprint; when it no longer matches, the day reads **"Changed after signing"** and needs
signing again. The earlier sign-off stays, with its lines, and both are in the export. Nothing is
silently kept and nothing silently dropped. Editing a signed entry first says so: "Sam signed this
day. Changing it means it needs signing again."

*Protection against self-signing, three levels.* An organisation setting,
`organizationLogbookSignOffProtection` (profile-owned string: `audit`, `pin` or `device`); the
default for an organisation is **`pin`**, and a solo setup has `audit` only.

- **(a) Audit only.** The sign-off records its time and the phone. Coarse location (rounded to about
  a kilometre) is added only when the organisation turns on `organizationLogbookSignOffLocation`, and
  the apprentice's notice (§13) says so.
- **(b) A PIN per staff member** (the organisation default). Entered in a secure field after the name
  is picked and before the pad appears. The profile carries only a verifier per staff member:
  `PINVerifier { algorithm: "pbkdf2-sha256", iterations, salt, hash }`, with its own salt, set in the
  Office (office half) and delivered in the profile or the roster refresh. The phone verifies
  locally. **Lockout:** five misses lock that staff member on this phone for 15 minutes, doubling on
  each further lockout up to 24 hours; while locked, the sheet says "Too many tries. Sam can confirm
  from his own phone or from the office instead." **The PIN is never shown, logged, stored, sent or
  printed**: the field is cleared after each try, autofill and the clipboard are off, `PrivacyLog`
  records only that a check passed or failed, and no payload, export or support report has a field
  for it. Honest limit: the verifier sits on the apprentice's phone inside the profile, and a short
  PIN behind a hash can be guessed offline by someone who extracts it. The PIN stops casual
  self-signing; (c) is the strong check.
- **(c) Confirmation from the journeyman's own device.** Preferred whenever the journeyman uses the
  app. Instead of handing the phone over, the apprentice taps "Ask Sam to confirm":
  1. the apprentice's phone sends `LogbookConfirmationRequest { requestID, day or job, fingerprint,
     entryLines, signerStaffID }` over HO's office transport (`DeliveryRequest.Payload.logbookConfirmationRequest`,
     `OpKind.logbookConfirmationRequest`);
  2. the office shows it in the Office app or passes it to the journeyman's enrolled phone (office
     half), where the same lines are shown and confirmed;
  3. the journeyman's phone signs `Avenkin.LogbookConfirmation.v1` over the request id, the
     fingerprint, the staff id and the time with its **phone application key** (the Ed25519 key each
     enrolled phone already holds, `Contracts/office-reports.md` §2), or the Office signs it with the
     office application key when confirmed in the Office;
  4. the office checks that signature against that enrolment's binding and that the enrolment
     belongs to that staff member, and sends the apprentice's phone a receipt signed with the office
     application key, carrying the confirmation and its digest;
  5. the apprentice's phone verifies the receipt under the office key its binding names, checks that
     its fingerprint equals the one stored for that day, and records "Confirmed by Sam on his phone".
  Until it arrives the day reads **"Waiting for Sam to confirm"**. A receipt whose fingerprint does
  not match is refused and the day keeps waiting. Changing an entry while waiting withdraws the
  request and sends a new one. When Sam does not use the app, the sheet falls back to (b).

*Sending entries to the office* is separate from signing. Confirmed entries, with their sign-offs,
go to the office when the apprentice sends them (each, or "send confirmed entries automatically", a
switch the apprentice sets and an organisation may set as a starting value but not lock on). The
office may return an entry with a reason. Office half: the employer's verification, returning, the
AccessManitoba summary, the staff roster and PINs, routing confirmation requests and signing
receipts are designed in a private FX-series plan, not here.

**Wording.** The app says **journeyman** in every string, on every screen and throughout this plan's
design. **Journeyperson** appears only where Manitoba's regulation is quoted or cited. An organisation
can set the word in its profile (`organizationSupervisorTerm`, a profile-owned string, default
"journeyman"; for example "journeyperson" or "senior technician"), and every string takes it as a
parameter.

**Export.** `LogbookExport` (pure layout over the entries, rendered with the work order's PDF
machinery) gives:

- **Practical experience record**: by level, then by task code, each day's minutes, the supervision
  note, and each day's sign-off: who (with "Name typed on this phone" for a typed name), when, the
  protection level, a device confirmation when there is one, and "Changed after signing" with both
  sign-offs where it applies;
- **Hours for the employer to report**: hours since a chosen date (default: the last export, or the
  start of the level), split signed / confirmed-not-signed, in a form an employer user can type
  into AccessManitoba;
- **CSV** of the same rows.

Sent through EM's `DeliveryChannel` (share sheet, email, files), always by the apprentice's tap.
There is no direct submission to the province: an apprentice cannot use AccessManitoba to report
hours (§1).

**Storage.** `SensitiveStore.apprenticeship` (entries and their revisions, sign-offs and their
signature files, PIN lockout state, credentials, the profile, the
apprentice debrief): wearer-linked, first-unlock protected, registered in `DataStoreRegistry`,
walked by the subject erasure, excluded from backups like the other sensitive stores. Because the
regulation makes the record book the apprentice's to keep, the screen says plainly that the phone
copy is not a backup: with no office, it offers a monthly export (open question 7).

**The contract.** `Contracts/apprentice-logbook.md` (draft v1, P2b): the entries message (phone →
office; exactly the entry fields above with their sign-offs, the apprentice's display name and role,
the task list's id and edition), the canonical encoding behind `LogbookDayFingerprint` with fixtures,
the confirmation request (phone → office), the journeyman's confirmation (`Avenkin.LogbookConfirmation.v1`,
journeyman's phone → office), the office's confirmation receipt and return-with-reason (office →
phone), the staff roster's shape and `PINVerifier`, refusal reasons, fixtures with invented codes,
and the requirements on the office half: the PIN never leaves the Office in clear, no
model-derived score, rating or "readiness" is computed from entries.

### 10 · Practice: exam preparation, crew cases, point-and-name

**10.1 · Exam preparation for the certificate of qualification (an extension of JG's bank format).**
JG's bank format is for a regulation's clauses; JG puts "exam material of any kind" out of scope.
This section is a deliberate exception carried by JI, under one hard rule: **original questions
only, never a real exam question or anything derived from one.** Red Seal and provincial exams are
the province's and the program's; their questions are not published, and practice that reproduced
them would be both a breach of the exam's terms and useless as learning.

- **The format change** (`Contracts/question-bank.md`, an additive v1 section, or v2 if JG's
  reader cannot take it additively): a bank file gains `purpose: "regulation" | "examPrep"`
  (absent means `regulation`, so every JG bank is unchanged). An `examPrep` bank has `subject: {
  taskList, edition }` naming a task list in the same vault (§3) instead of a `standard` document;
  its items carry `taskCode` (a code in that list) and may also carry a `clause` and `anchor` when
  they cite a loaded standard, which then follows JG's anchor and edition rules. It adds one answer
  kind, `choice` (two to four short options, one correct), graded by fixed rules: the spoken letter,
  or the option's words, matched after folding; anything else is `notHeard`.
- **The attestation, mandatory for `examPrep`.** `originality: { statement: "original-work",
  authoredBy: { role, name? }, attestedOn, method }`, where `statement` must be exactly that value
  and `method` is a short free text ("written from the occupational standard and public
  references"). The vault author's catalogue terms (EG / FS listing) require it to be true.
- **What the validator enforces.** `PracticeBankValidator`, extended: the attestation is present and
  well-formed; every `taskCode` exists in the named task list; `choice` items have two to four
  distinct options and exactly one correct; no item text says or implies it came from an exam
  ("exam question", "from the exam", "recalled", "actual question", "past paper", and the like, in a
  list kept with the validator); and **no item matches the vendor's denylist**, a signed list of
  folded-question digests (`ExamItemDenylist`, delivered with app updates and the vault catalogue)
  for items reported as exam-derived. A bank that fails is refused at import, and the archive script
  refuses to build it.
- **What it cannot enforce.** It cannot tell a reworded recalled question from an original one; it
  cannot check that the attestation is true or that the author holds rights to their references;
  and the denylist only knows what has been reported. Those rest on the publisher's signature (JG
  §3: only signed banks are ever asked), the catalogue's terms, and revocation: a revoked publisher's
  banks go dormant, and a reported item's digest goes on the denylist, which retires it on every
  phone at the next update.
- **Asking.** A sibling tool, `exam_practice`, runs JG's engine (selector, grader, Leitner schedule,
  phraser) over `examPrep` banks, with its own description, its own IP switch and the same live /
  dormant rules. Learning goals are IW goals with JG's `practise` step action. JG's optional
  `syllabus` is reused as it is, with one change for `examPrep` banks: a topic lists task-code
  ranges ("X-13–X-15 (invented)") instead of clause ranges, so a vault author can lay out a course by level
  and "make a learning goal from the course" follows it exactly as JG §7 describes. Without a
  syllabus, topics are the task list's major work activities. `choice` items are not asked to a
  driver (four options are too much to hold while driving); JG's passenger mode may ask them with
  the options on the phone's screen.
- **The apprentice's own exam questions.** JG §3a's self-review route is reused for exam
  preparation with one change: an own question may be keyed to a task code instead of a clause in
  a loaded standard. It is written by hand only. JG's drafting route needs the technician's own
  copy of a standard to draft from, and there is no such text for an exam's topics, so the phone
  does not draft exam-prep questions. Labelled, graded "against your own answer" and never shared,
  as §3a sets out.
- **Results stay on the phone in these phases.** Exam-prep results are not put in JG's
  organisation results feed by this plan (`PracticeResultsBatch` drops `purpose == examPrep`).
  They would qualify on JG's terms (rule-graded against a human-approved key), but JG's feed, its
  disclosure and its suggested notice wording all speak of clauses of a code; adding exam
  preparation is a choice for the owner (open question 18), not a side effect. The phone computes
  no pass prediction, no "readiness" and no score. The apprentice's own progress share (§11) may
  include the count of items learned per major work activity, and nothing per item.

**10.2 · Learning from senior technicians' cases (organisations only).** The organisation's approved
team learnings (FP) and, when IM lands, experience recordings (origin `recollection`) are the crew's
experience. An apprentice-facing **From the crew** list on the Apprenticeship screen reads
`LearningCorpus`:

- filtered by today's jobs' equipment words (JG §5's rule: equipment words only, never the customer,
  address, contact or fault text) and by the task codes the apprentice has logged;
- each entry as FP already shows it (the crew's words, the model, the approving role and date), with
  one **study prompt** from fixed templates over the entry's fields: "Before 1007: the crew noted this
  about the <model>. What would you check first?" and "Talk it through", which opens an ordinary
  turn with the entry as its source;
- read entries are marked read on the phone; nothing about what an apprentice read is sent anywhere.
- Gated by `FieldAssistCapability.teamLearnings` (team and enterprise licences). No questions are
  generated from learnings (JG keeps practice from learnings out of scope, and so does JI).

**10.3 · Point-and-name practice with the phone's camera (glasses optional).**

- **Two drills.** *Name it*: the apprentice points the phone at a component and names it ("that's
  the contactor"). *Read it*: the apprentice reads a gauge or meter aloud ("about 118 psi"), then the
  camera reads it too. Glasses can be the camera when connected; the phone is the default.
- **Checked by the existing vision seams.** *Read it* uses `StructuredVisionService` with
  `InstrumentReadingSchema` and compares the spoken value with JG's `SpokenAnswerParser` and
  `UnitNormalizer`, within a tolerance the drill states ("The camera read 118 psi. You said 120: within
  2."). *Name it* uses a `component_name` structured-vision schema whose answer must come from a
  vocabulary the vault author supplies (`components` in the task list, up to 200 words); the
  apprentice's word is matched to it by fixed rules. EL's nameplate path is used when the drill is
  "which model is this?". When the model's own confidence is low, or the frame is poor, the result is
  "I'm not sure: the camera couldn't read it clearly", never a miss.
- **Camera rules (CLAUDE.md).** Every still is read through `CameraService.filteredStill(for:
  .visionAssessment, source:)`, so the privacy filter's scope applies before anything leaves the
  phone; the drill is a new `OutboundFrameConsumer` case, `pointAndNamePractice`, with its scope and
  mechanism, so `OutboundFrameConsumerTests` covers it. Under Medical Local Only or with cloud models
  off, the drill runs only on the on-device model, or not at all. The still is not kept.
- **Personal practice only.** Results are shown and spoken in the moment and kept as a count on the
  phone ("12 drills this week"). They are **never shared**: not in JG's results feed, not in the
  apprentice's progress share, not in the logbook, not to the office.
- **This is AI grading, and the EU AI Act notices it.** The camera's answer is a model's output, so
  a drill marks a person's answer against an AI system. Annex III 3(b) lists systems that evaluate
  learning outcomes in vocational training as high-risk from 2 December 2027. Personal practice that
  never leaves the phone is the design's position (§12), and the drill is unavailable on EEA
  storefronts until `docs/eu-ai-act-review-2026-10.md` has a section on it:
  `MarketAvailabilityPolicy.Capability` gains `pointAndNamePractice`, and an unreadable storefront is
  treated as EEA for this row, as JG does for its results row.

### 11 · The apprentice's progress screen, and what they choose to share

> **Amended 2026-10-27 by Plan [JX](JX-journeyman-engine.md) §1 (owner decision):** logbook entries,
> sign-offs and certificates are the organisation's record and reach it with the job's records, not
> by the apprentice's share; the apprentice can always export a signed copy and import it read-only at
> a new employer. Everything else below stays the apprentice's choice.

**My apprenticeship** (Settings › Field Assist › Apprenticeship, and a row on the Job tab when the
role is apprentice), from `ApprenticeProgress` (pure, over local stores only):

- **Hours this level**: confirmed and verified minutes, separately, against the task list's level
  hours where it gives them. The province's hours include technical training (§1), so the screen
  says "on the job" and does not compute what remains.
- **Hours by task**: by major work activity, expandable to tasks and sub-tasks; codes never logged
  are shown as such, without a target (a standard sets no hours per task).
- **Certificates** with their status (§4).
- **Goals**: IW goals, the standing learning goal, and JG/JI practice goals.
- **Practice**: JG's learned clauses, exam-prep items learned by major work activity, point-and-name
  drill counts. No score, no pass, no rank, no rating anywhere on the screen.
- **What's shared**: what has gone to the office and when (logbook entries, any progress shares, and
  JG's results feed if the organisation has turned it on).

**Sharing is the apprentice's choice.** "Send my progress to the office" builds `ProgressShare`
(pure) from sections the apprentice ticks: logbook totals by task (already in the office if the
entries were sent), certificates and expiry, goal titles with step states, practice counts (JG
learned clauses, exam-prep items by activity). A preview shows exactly the payload before it goes.
It can be one-off (default) or weekly, a switch the apprentice turns on and off; an organisation
profile may switch sharing off and lock it, and cannot turn it on. **Never in a share:** point-and-name
results, any model-judged result, debrief answers, the learned notes' text unless the apprentice
ticks goals with their steps, notices from the scope guard, call records. The share rides HO's office
transport (`DeliveryRequest.Payload.progressShare`, `OpKind.progressShare` in
`OfficeReportSink.handledKinds`), and is beyond JG's organisation results setting, which stays as JG
designs it.

### 12 · Roles, consent and the EU AI Act

> **Amended 2026-10-27 by Plan [JX](JX-journeyman-engine.md) §1:** "An apprentice's data is theirs"
> no longer covers the logbook, its sign-offs or certificates, which are held by the organisation.

- **An apprentice's data is theirs.** Everything in §§2–11 lives on the phone in
  `SensitiveStore.apprenticeship` (and JG's `practice`, IW's goals and trail). The office sees only
  what JG's organisation setting sends (disclosed as JG §10 sets out), the logbook entries the
  apprentice sends, and the progress shares the apprentice sends. The Apprenticeship screen lists
  all three under **What's shared**.
- **Logbook entries and verification are human records.** A draft is built by fixed rules from the
  job's own records; the apprentice confirms or changes it; a journeyman verifies it. No model
  output decides an allocation, and no model-derived competence score, readiness or rating is
  computed on the phone or ever leaves it. The contract states the same as a requirement on the
  office half (§9).
- **Where AI is in the loop, it stays personal.** Point-and-name drills (§10.3) are graded against a
  model's reading: personal only, never shared, EEA-gated. Speech recognition transcribes; a
  mishearing is `notHeard`, never a miss (JG §4).
- **Annex III 3(b) and 4(b).** Evaluating learning outcomes in vocational training, and evaluating
  workers' performance, are high-risk from 2 December 2027. The review's design rule (§3.8 there:
  AI output is never an input to a performance figure) holds: nothing here gives an employer a
  model-derived figure about an apprentice. Exam preparation's `choice` grading is a fixed-rule
  match against a human-approved key, so JG decision 10 covers it as it covers JG's own items. The
  drills are the one place a model's output marks a person's answer, which is why they alone are
  EEA-gated. **Owed:** JG P1 adds the review's section on the results feed; JI adds to the same
  section, in P2b, the logbook and the progress share, and in P10 the drills (open question 14).

### 13 · An employee-records notice (Canada)

The first organisation is a provincially regulated private employer in Manitoba. JG §10 already
carries the reading this plan relies on, in the note beside its suggested notice wording: PIPEDA
covers employees' personal information only for federally regulated employers, and Manitoba has no
private-sector privacy statute in force that covers employees, so such an employer may have no
statutory notice duty; a clear notice is still the right thing to give. JG's open question 3 asks
the owner's adviser to confirm that reading, and JI waits on the same answer rather than asking it
again. JI reuses JG's two-part pattern:

- **Suggested wording for the employer** (a P2b deliverable, beside JG's): `ApprenticeRecordsNotice.suggestedWording`,
  shown to the operator when a profile that names an apprentice's journeyman or sets the task
  list is applied, and copied into `Contracts/apprentice-logbook.md` so the Office shows it
  identically. Same headings as JG's (why, what is collected, who sees it, how long it is kept,
  your questions), covering the logbook entries the apprentice sends, the journeyman's
  verification, certificates when the organisation supplies them, and progress shares. It says that
  calls are never recorded and that scope reminders are never sent. Bracketed fields are the
  employer's; the same not-legal-advice note as JG's sits beside it.
- **What the apprentice sees on the phone**, before the first logbook entry is sent and before the
  first progress share, and kept on the Apprenticeship screen: what the phone keeps; what goes to
  the organisation, when and why (the record book the regulation requires, the employer's
  verification); who at the organisation sees it, as the employer's filled-in wording says; how to
  see, correct (an edit, which keeps the earlier revision) and delete the phone's copy; and that deleting the phone's copy
  does not delete what the office already holds, and who to ask about that.
- Both texts are plain and specific, take no plan letters, and name no law until the adviser has
  answered.

### 14 · Gates and modes

Field Assist only, inside its tool block and `FieldToolProfile`; IP feature switches
`apprentice_logbook`, `scope_guard`, `call_journeyman`, `exam_practice`, `point_and_name`;
`closedTools` closes each with no code of its own. The role decides the defaults, not the gates: a
qualified technician can still use the call and the exam practice. HIPAA-only and Medical setups get
none of it. HIPAA mode sends nothing to the office from JI. Agent Mode is not required: nothing here
acts on its own; the offers are goal sentences under IW's cap. Each tool's description stands alone
(`SystemPromptBuilder` lists it). Spoken and shown copy names no plan letter.

## Phases (one PR each)

### P0 — The apprentice's profile, task lists and certificates (headless core)

`ApprenticeProfile`, `SupervisorContact`, `SupervisorResolver` (personal setting and profile key
live; job and office sources as empty seams); `VaultManifest.tasklistsDir`, `TaskListFile`,
`TaskListValidator` in `VaultValidator`, `Scripts/check-task-list.swift`; `CredentialRecord`,
`CredentialStatus`, the two expiry reminders as `ScheduledTaskKind` tasks; `SensitiveStore.apprenticeship`
(+ `DataStoreRegistry`, ET matrix, erasure walk); Settings › Field Assist › Apprenticeship (role,
profile, certificates); the vault guide's task-list section; invented fixtures. Depends on JG P0 for
`PracticeRole`; if JI P0 comes first it lands `PracticeRole` exactly as JG §9 specifies it.

**Exit tests:** `TaskListValidatorTests` (the invented list passes; one refusal per rule: unknown
key by path, duplicate code, missing parent, title over 80 characters, bidirectional override, a
`performanceCriteria` key refused as unknown); `SupervisorResolverTests` (order and source;
personal fallback; none); `CredentialStatusTests` (valid, 45 days, the day before, expired, no
expiry; the renewal sentence only when a rule gives a window); a guard test that every task-list
fixture carries "(invented)"; `DataStoreRegistryTests` / `SubjectErasureTests` green.

### P1 — The logbook on the phone: draft, confirm, export

`LogbookEntry` (with revisions), `TaskAllocation`, `SupervisionNote`, `LogbookDrafter`,
`LogbookEntryReview`; `LogbookExport` (record, hours summary, CSV) through `DeliveryChannel`; the
`apprentice_logbook` tool (`draft`, `list`, `confirm`, `move`, `export`); drafting on job close; the
Job tab's past-job row and the Apprenticeship screen's list; `ApprenticeRecordsNotice` (on-phone
parts); `organizationSupervisorTerm` and the strings that take it.

**Exit tests:** `LogbookDrafterTests` — a scripted job with a procedure mapped to two codes, a done
task matched by a hint and an unmatched finding → the minutes split as specified, the remainder
unassigned, the total equal to `BillableClock`'s credited time rounded to five minutes; drive time
not counted; **no model call is made** (a fake `LLMService` asserts zero calls). `LogbookEntryReviewTests`
— every transition; an edit raises the revision and keeps the earlier one. `LogbookExportTests` — the
record groups by level and code; the employer summary splits signed and confirmed; the CSV
round-trips. `SupervisorTermTests` — every logbook and call string uses the profile's term, and
"journeyman" when none is set. Privacy-log and trail tests: no entry note text or job customer
field in any log.

### P2a — The journeyman's sign-off on the phone

`JourneymanSignOffSheet` from `CustomerSignOffView.swift`'s parts (`JobSignOffStepView`'s hand-over,
`CustomerSignOffSheet`'s frozen summary and copy, `SignatureCanvas`); strike and edit on the sheet;
`organizationLogbookSignOffScope` (day by default, job as an option) and the weekly catch-up with its
reminder; `StaffMember`, `organizationStaff` and its strict decoder, and the journeyman picker
(role and trade filter, certificate expiry, the assigned journeyman preselected); the solo typed
name; `LogbookDayFingerprint` and its canonical encoding; `JourneymanSignOff`; `LogbookDayStatus`
with "Changed after signing"; `organizationLogbookSignOffProtection` with (a) audit and the optional
coarse location, and (b) `PINVerifier`, the secure PIN step and the lockout.

**Exit tests:**
- `LogbookDayFingerprintTests` — the fixture's digest is reproduced exactly; **an entry edited after
  signing turns the day to "Changed after signing"** and asks for a new signature, with the earlier
  sign-off kept and exported; a strike before signing leaves the struck entry out of the fingerprint
  and returns it to the apprentice.
- `JourneymanPickerTests` — **only staff with the journeyman role for the apprentice's trade are
  listed**; certificate expiry shown when on file, an expired one marked; the assigned journeyman
  preselected and changeable; **an organisation offers no free-text name**.
- `SoloSignOffTests` — **a typed name is recorded as typed** and labelled "Name typed on this phone"
  on the sheet's record, the past-day view and the export.
- `SignOffPINTests` — **a wrong PIN gives no signature** (the pad never appears); the right PIN
  verifies against the salted PBKDF2 verifier; **five misses lock that staff member** for 15
  minutes, then doubling, with the fallback sentence; a lockout survives relaunch.
- `SignOffPINLeakTests` — **the PIN appears in no payload, export, support report, `PrivacyLog`
  event or trail entry** (each wire form and log asserted against a sentinel PIN), and the field
  is empty after every try.
- `SignOffScopeTests` — day by default; job when the profile says so; the weekly catch-up gives
  each day its own fingerprint and sign-off.
- `SignOffCopyTests` — the sheet says it is not a legal e-signature and that nothing is sent to the
  province.

### P2b — Entries to the office, and confirmation from the journeyman's own device (phone half)

`Contracts/apprentice-logbook.md` (draft v1) with fixtures (`apprentice-logbook-entries-v1.json`,
`apprentice-logbook-fingerprint-v1.json`, `apprentice-logbook-confirmation-v1.json`,
`apprentice-logbook-receipt-v1.json`, a negative set) and a portable check in `Contracts/tests`;
`LogbookOutbox` on FP's pattern; `DeliveryRequest.Payload.logbookEntries` and
`.logbookConfirmationRequest`, the matching `OpKind`s in `OfficeReportSink.handledKinds`; level (c):
"Ask Sam to confirm", "Waiting for Sam to confirm", the receipt verified under the office key and
matched to the day's fingerprint, withdrawal when an entry changes; the journeyman's side on a
qualified technician's phone (the request shown, confirmed and signed with the phone application
key); returned entries; the apprentice's "send automatically" switch; the apprentice's notice
before the first send and `ApprenticeRecordsNotice.suggestedWording` for the employer; the logbook's
part of the AI Act review section.

**Exit tests:** the contract test green; `LogbookConfirmationTests` — **a device confirmation whose
fingerprint matches the day's verifies and records "Confirmed by Sam on his phone"**; a receipt with
a different fingerprint, a bad office signature or another enrolment's identity is refused and the
day keeps waiting; changing an entry while waiting withdraws the request; the journeyman's phone
signs the exact request it showed. `LogbookOutboxTests` — **nothing leaves before the apprentice
sends or turns on automatic sending**, and **nothing before the notice is shown**; the payload's
keys are exactly the allowed set and carry no PIN or PIN verifier (asserted on the wire form); a
receipt for an unknown entry is refused; a returned entry goes back to `draft` with its reason; HIPAA
mode sends nothing; the ops ride the office sink only.

### P3 — My apprenticeship, and the apprentice's own share

`ApprenticeProgress`, the screen and its Job tab row; `ProgressShare` with the section picker and
preview; `DeliveryRequest.Payload.progressShare`, `OpKind.progressShare`; the profile ceiling (off,
locked) and no way to force it on.

**Exit tests:** `ApprenticeProgressTests` (confirmed and verified apart; codes with no hours shown as
none; no score, pass or rank field exists on the type); `ProgressShareTests` — **only ticked
sections are in the payload**; **point-and-name counts, model-judged results, debrief answers and
scope notices can never be in it** (asserted on the wire form, so a field added later fails);
a profile can turn sharing off and lock it, not on; the weekly switch is the apprentice's.

### P4 — Ask my journeyman (phone and FaceTime) and the learned note

`CallRoute`, `CallPlacement`, the `call_journeyman` tool (or `call_base`'s `who: journeyman`
when IQ P3 has shipped; whichever lands first builds `EscalationContact` and the CT key);
the journeyman resolved from `organizationStaff` (P2a) when it is there, else the personal setting;
the CarPlay refusal wording; "Add Sam
to Contacts"; the post-call offer through `CXCallObserver`; the learned note as a proposed IW step;
the logbook's "Called Sam" line.

**Exit tests:** `CallRouteTests` (tel, FaceTime and FaceTime audio URLs from a number and from an
email; anything else refused; no handle → offers the voice call); `CallJourneymanToolTests` —
**FaceTime video refused while CarPlay is connected**; the reply never says "connected"; no contact
→ refuses by name and points to settings; `PostCallOfferTests` (one offer, only after a call this
tool started inside 30 minutes; none after an unrelated call); `LearnedNoteTests` (held until yes;
stored on the goal; not in any office payload).
**Device pass (owed):** the confirmation for `tel:` and FaceTime on the phone and with CarPlay
connected; whether FaceTime can be told to start on the back camera (assumed not); a FaceTime call to
a number without an Apple device; the post-call offer after a real call.

### P4b (deferred) — The glasses view

"Show Sam through my glasses" over `EscalationCoordinator` and `ExpertStreamBridge` when glasses are
connected and the organisation runs live support; GZ's annotations as words, a phone overlay and a HUD
line. Depends on FX8 and GZ.

### P5 — The scope-of-practice guard

`Procedure.Step.requires`, `organizationScopeRules` and its strict decoder, the Manitoba starter
rules file with citations, `SupervisionToday` and its once-per-job question, `ScopeGuardPolicy`,
`ScopeNoticePhraser`; the notice in `ProcedureRunner`'s step read-out; IS's event hook as an empty
seam until IS lands.

**Exit tests:** `ScopeGuardPolicyTests` — a table: no rules → nothing; missing, expired and
expiring-soon certificate; direct supervision with `onSite`, `reachable` and `unknown`; **a
final-level apprentice in a three-level list with `reachable` passes, a level-2 apprentice does not**;
the qualified role → nothing for apprentice-only rules. `ScopeNoticeWordingTests` — every template
against IS's list plus JI's person-directed words. `ScopeNoticeIsolationTests` — **a notice never
changes the step's state, never blocks the next step, and is never in the work record, the logbook,
an export or any office payload**. `ManitobaStarterRulesTests` (every row has an instrument, section
and as-at date).

### P6 — Apprentice mode in procedures

`Procedure.Step.why`, `ApprenticeStepPhraser`, the located-sentence fallback, "just the steps" and
"explain that one"; the vault guide's procedure section.

**Exit tests:** `ApprenticeStepPhraserTests` (exact strings: with `why`; with a citation only; with
neither; the safety note first; the scope notice after it); **no model call is made for a reason**;
the qualified role hears no reason unless asked; older procedures without the fields read as today.

### P7 — The apprentice debrief and the logbook read-back

`ApprenticeDebrief`, the three fixed prompts after FO's save or alone, the logbook read-back and
spoken corrections, the IW proposals, the JG gap candidate, the CarPlay offer under JG's drive policy
and IW's cap, one apprentice offer per drive.

**Exit tests:** `ApprenticeDebriefTests` (fixed prompts; answers kept as said; **nothing on the work
record or the customer summary**); `LogbookReadBackTests` ("move ten minutes to commissioning" moves
ten minutes; an unknown task word → "fix it on your phone"; "yes" confirms); `ApprenticeDriveOfferTests`
(one offer per drive across debrief and JG questions; no offer past IW's cap; a stop word ends it;
the draft on the phone's screen only when JG's `DriveRole` is `passenger`, never on the car screen);
the JG candidate only for a recognised clause, only in an organisation, inside JG's caps.

### P8 — From the crew

The apprentice-facing list over `LearningCorpus`, the equipment-word and task-code filter, the study
prompt templates, "talk it through", read marks.

**Exit tests:** `CrewCasesFilterTests` (equipment words only; a job's customer, address, contact and
fault text never reach the filter); `StudyPromptTests` (exact strings); not shown without
`FieldAssistCapability.teamLearnings`; read marks never leave the phone.

### P9 — Exam preparation

The `examPrep` purpose, `subject`, `taskCode`, the `choice` answer kind and its grader, the
`originality` attestation, the validator rules and `ExamItemDenylist`, the contract section and
fixtures, `exam_practice`, task-code learning goals and syllabus topics, own exam questions by
hand on JG §3a's route, the results-feed exclusion. Depends on JG P0 (and
P3 for goals).

**Exit tests:** `PracticeBankValidatorTests` extended — an `examPrep` bank with no attestation, a
wrong `statement`, a `taskCode` not in the list, a `choice` item with one option or two correct, an
item saying "from the exam" — each refused by name; **an item whose folded digest is on the denylist
refuses the bank**; a JG regulation bank without `purpose` is unchanged. `ChoiceGraderTests` (letters,
option words, anything else not heard). `PracticeResultsBatchTests` extended — **no `examPrep` result
is ever in JG's results feed**. `ExamPracticeToolTests` (signed bank live; unsigned dormant; choice
items not asked to a driver, shown on the phone to a passenger); `ExamSyllabusTests` (topics by
task-code range; a topic with no live items skipped); own exam questions keyed to a task code are
labelled and in no payload, and **no exam-prep draft is ever produced by a model**.

### P10 — Point-and-name practice

`component_name` schema, the `components` vocabulary in the task list, the two drills over
`PhoneCameraSource` (glasses when connected), `OutboundFrameConsumer.pointAndNamePractice`,
`MarketAvailabilityPolicy.Capability.pointAndNamePractice` (EEA and unreadable storefronts
unavailable), the drill counts.

**Exit tests:** `OutboundFrameConsumerTests` green with the new case (the still read through
`filteredStill(for: .visionAssessment, …)`, never `latestFrame`); `PointAndNameDrillTests` (within
tolerance → right; outside → the camera's value said; low confidence or no reading → "not sure", never
a miss; a component word outside the vocabulary → not heard); `MarketAvailabilityPolicyTests` (EEA
and unreadable storefronts unavailable; a Canadian storefront available); **no drill result in any
payload, export or share** (asserted on every wire form JI defines); Medical Local Only without the
on-device model → the drill is unavailable and says why.
**Device pass (owed):** gauge readings in a mechanical room's light, on the phone's camera.

### The office half (not a phone phase)

Verifying and returning logbook entries, the employer's hours summary for AccessManitoba, the staff
roster and its refresh, setting and resetting journeymen's sign-off PINs (stored as verifiers only),
routing confirmation requests to a journeyman's phone or the Office and signing the confirmation
receipts, assigning an apprentice's journeyman (and naming a crew in the job file), an apprentice's record and shared
progress (with no model-derived score, ranking or rating), and publishing task lists and exam-prep
banks inside the organisation's vault: an FX-series plan in the private office repository, against
`Contracts/apprentice-logbook.md` and `Contracts/question-bank.md`. Nothing on the phone waits for it
except P2b's and P3's routes having a reader.

## Decisions

### Decided by the owner (2026-10-19): the journeyman's sign-off

A. **"Journeyman"** in every string, screen and design text; "journeyperson" only where Manitoba's
   regulation is quoted or cited. An organisation may set its own word (`organizationSupervisorTerm`,
   default "journeyman").
B. **The sign-off reuses the customer sign-off sheet**: the phone is handed over, it shows exactly
   what is agreed, the journeyman draws a signature (PencilKit). It is an acceptance, not a legal
   e-signature, and the copy says so.
C. **By the day by default, by the job as an organisation option**; the sheet lists the day's
   entries with hours by task code and the job each came from; the journeyman may strike or edit
   before signing; unsigned days are signed in a weekly catch-up.
D. **The signer is chosen from the organisation's staff**: only journeymen for the apprentice's
   trade, certificate expiry shown when known, the assigned journeyman preselected; no free-text
   name in an organisation; a solo setup's typed name is recorded as typed.
E. **Bound to the content**: a SHA-256 fingerprint of exactly the entries shown; any later change
   marks the day "Changed after signing" and needs a new signature; nothing silently kept.
F. **Self-signing protection in three levels**, an organisation setting: (a) audit (time, coarse
   location if enabled), (b) a PIN per staff member, salted hash only, lockout after repeated
   misses, never shown or logged (**the organisation default**), (c) confirmation from the
   journeyman's own device over the office route, preferred whenever the journeyman uses the app.
G. **Legal framing**: s. 7(b) puts verification on the employer, which reports hours in
   AccessManitoba; the phone's signature is evidence the employer relies on, not the submission.

### Design decisions (proposed, owner to confirm)

1. **JI takes apprentice logbooks over from IQ**; IQ keeps `call_base`, the help pack and the
   contact list, and JI's call builds on them.
2. **One role: JG's `PracticeRole`.** An `ApprenticeProfile` (task list, level, journeyman)
   exists only for the apprentice role.
3. **The logbook is the regulation's record book in digital form**: hours by task-list code,
   drafted by fixed rules from the job's own records, confirmed by the apprentice, signed by a
   journeyman as decided above; every edit keeps the earlier revision.
3a. **One staff roster** (`organizationStaff`, profile-owned, refreshed by the office) that IQ's
   contact list and JI's journeyman both read, rather than a second list of people.
4. **No model in logbook drafting.** Every allocation traces to a procedure, a task or an author's
   hint word.
5. **No submission to the province**: an export (record, employer's hours summary, CSV) the
   apprentice sends by tap, because AccessManitoba takes hours only from the employer.
6. **Task lists are data in a vault**, codes and short titles only; the app ships none.
7. **Certificates are records with expiry dates**, with two reminders; renewal windows come from
   rules data, not code.
8. **The scope guard informs and never blocks**; it speaks once per step, offers the call, and is
   never recorded anywhere the office can see. IS's wording guard plus person-directed words.
9. **Scope rules are the organisation's**, from a profile key; a cited Manitoba starter file ships as
   data and applies only when adopted.
10. **Calls are phone first**: `tel:`, FaceTime and FaceTime audio from one contact list; iOS's tap is
    never bypassed; FaceTime video never while CarPlay is connected; glasses view later.
11. **No call recording**; afterwards one offer to note what was learned, kept as the apprentice's
    goal step.
12. **Apprentice mode reads an authored or manual-cited reason, never a model's**; "just the steps" at
    any time; safety notes for everyone.
13. **The apprentice debrief is separate from the job's**: three fixed questions, the logbook
    read-back, nothing on the work record; one unprompted apprentice offer per drive, JG's car rules.
14. **Exam preparation is a deliberate exception to JG's scope**: original questions only, an
    attestation, validator rules and a vendor denylist; JG's syllabus by task code; an apprentice's
    own questions by hand through JG §3a, never drafted; results not in the organisation's feed in
    these phases.
15. **Point-and-name is personal practice only**: never shared, never in a payload, EEA-gated.
16. **Sharing progress is the apprentice's choice**, section by section, with a preview; an
    organisation may switch it off, never on.
17. **No model-derived competence score, readiness, pass prediction or rating** is computed on the
    phone or sent from it.
18. **An employee-records notice** before the first send, whichever privacy law applies, on JG's
    pattern: suggested wording for the employer and a plain notice for the apprentice.

## Open questions for the owner

1. **The record book's format, a partner question (IQ's, carried over).** Does Apprenticeship
   Manitoba accept a digital practical experience record book under s. 6 **with this sign-off** (a
   journeyman's drawn signature bound to the day's entries, with a PIN or a confirmation from their
   own device), and is there a current official form after the paper report of hours ended? Ask the
   organisation's apprenticeship training coordinator. Until answered, the export is "a record the
   apprentice keeps", not "the province's form".
2. **Who signs (IQ's question) is answered**: the journeyman, chosen from staff (decision D). Does
   the organisation also want a named office person to countersign on the employer's behalf, in the
   Office (office half)?
3. **Whether apprentices must keep a record (IQ's pending question, carried over)** is answered for
   Manitoba (yes, s. 6(a)); is the second organisation, wherever it is, a reason to model a second
   province's rules now?
4. **Drive time.** Does the organisation count travel between jobs as practical experience?
5. **A labelled model suggestion for task codes**, later, when hints match nothing? Recommendation:
   not until the deterministic draft has been used for a month.
6. **Who sets the apprentice's level** — the apprentice, or the office through the enrolment?
7. **Backups.** The record book is the apprentice's to keep, and sensitive stores are excluded from
   backups. Keep the exclusion and rely on the office copy and exports, or let the apprentice include
   the logbook in their own backup?
8. **The journeyman's details on the apprentice's phone** (name, certificate number, signature
   image). Acceptable to the organisation and to journeymen?
9. **Scope rules beyond refrigerants.** Which steps does the organisation want tagged for direct
   supervision (live electrical work, gas)? The vault author tags procedures; the organisation decides
   the rule.
10. **Supervision today.** Ask once per job ("Is Sam with you?"), or only when a tagged step comes up?
11. **Calls in the car.** If the device pass shows the `tel:` confirmation cannot be answered from the
    car, is "say 'Hey Siri, call Sam'" enough, or should calls from CarPlay be left out entirely?
12. **Exam-prep publishers.** Only the vault author, or may an organisation build its own exam-prep
    bank in Avenkin Office under the same attestation?
13. **Manitoba in IS.** IS's amendment models federal, Ontario, British Columbia and Alberta rules.
    Should IS add M.R. 103/94 (trained service technician, records, labels) for the first
    organisation?
14. **EU AI Act.** Agree the position in §12, and owe a review section covering the logbook, drills
    and progress share before any of it is offered on an EEA storefront?
15. **Canadian privacy.** The same adviser confirmation JG's open question 3 asks for covers JI's
    records too (logbook, certificates, the journeyman's details). Agree that JI waits on that one
    answer, and that the apprentice-records wording names no law until then?
16. **JG's out-of-scope pointers.** This PR adds a pointer to JI on JG's "exam material" and
    "apprentice logbooks" lines and changes nothing else in JG. Agree?
17. **The apprentice's refrigerant certificate.** Must an apprentice hold their own trained service
    technician certificate to do s. 6 work beside a certified journeyman? The answer changes what
    the Manitoba starter rules say.
18. **Exam-prep results in the organisation's feed.** They would meet JG's terms (rule-graded,
    human-approved key). Keep them on the phone, as this plan does, or add them to JG's feed later
    with the disclosure and notice wording extended to task codes?
19. **One list of people.** IQ's drafted `organizationEscalationContacts` would become staff ids
    plus outside numbers in `organizationStaff`. Agree, so IQ P3 is built on the roster?
20. **PIN rules.** Four to eight digits, five misses, 15 minutes doubling to 24 hours: right? Who
    sets and resets a journeyman's PIN: the office only, or the journeyman on their own phone
    through the office route?
21. **Coarse location.** About a kilometre, or only "near the job's site: yes / no" against the
    job's address?
22. **An expired journeyman certificate.** Shown as expired and recorded, as proposed; or should the
    picker leave that journeyman out?

## Risks

- **A logbook nobody trusts.** A draft that misfiles time teaches apprentices to ignore it. The
  defence is that every allocation is traceable and editable, unassigned time is shown as unassigned,
  and verification is a person's.
- **Self-signing.** An apprentice signing their own day defeats the record. The defences are the
  staff picker (no free-text name in an organisation), the PIN by default, the journeyman's own
  device where they use the app, the fingerprint, and the audit fields. Honest limit: a PIN behind a
  hash on the apprentice's phone can be guessed offline by someone determined; the device
  confirmation is the strong check, and the employer's own verification (s. 7(b)) stays the
  employer's.
- **The guard becoming a monitor.** If notices reached the office, the guard would record apprentices
  doing steps without supervision. They never leave the phone, and a test pins it.
- **Nagging.** Offers sit under IW's cap; one apprentice offer per drive; notices once per step per job.
- **Exam leakage.** A recalled question reworded by a publisher would pass the validator. The
  signature, the catalogue terms, the denylist and revocation are the remedy; the plan says plainly
  that the validator cannot prove originality.
- **AI grading reaching an employer.** Drill results have no field in any payload, and the EEA gate
  holds until the review says otherwise.
- **Calls that silently fail.** The reply never claims a connection, and the device pass checks the
  confirmation in the car.
- **Shared phones.** A pool phone shared between apprentices would mix records. CT's rule applies:
  identity is per person; until the app has sign-in, the Apprenticeship screen says the records belong
  to the phone's current technician name and asks before changing it.

## Out of scope

Submitting hours to the province; any task list, question bank or exam material shipped with the
app; real exam questions or anything derived from them; recording, transcribing or summarising calls;
a model-derived score, rating, readiness or pass prediction of any kind; reporting scope notices; the
office half; provinces other than Manitoba as worked rules (the design takes any province's rules as
data); languages other than English for spoken answers (EC).

## Sources (official; read 2026-10-19 unless marked)

- Manitoba, *Apprenticeship and Certification — General Regulation*, M.R. 154/2001. Consolidation
  current as of 2026-10-19, in effect since 2024-10-30, last amendment M.R. 96/2024. ss. 1(1), 1(1.1),
  1(2), 6, 7, 9, 10, 10.1, 11, 20 read.
  <https://web2.gov.mb.ca/laws/regs/current/154-2001.php?lang=en>
- Manitoba, *Ozone Depleting Substances and Other Halocarbons Regulation*, M.R. 103/94.
  Consolidation current as of 2026-10-19, in effect since 2005-12-09, last amendment M.R. 178/2005.
  ss. 1, 6, 8(1), 20, 25(2) and the Schedule (Class 3) read.
  <https://web2.gov.mb.ca/laws/regs/current/103-94.php?lang=en>
- Apprenticeship Manitoba, *AccessManitoba* (apprentice and employer questions on reporting hours).
  No date shown. <https://www.gov.mb.ca/apprenticeship/access-manitoba/index.html>
- Apprenticeship Manitoba, *Employer FAQs* (ratio, designated trainers, reporting hours, notice when
  an apprentice leaves). No date shown. <https://www.gov.mb.ca/apprenticeship/employers/faqs.html>
- Apprenticeship Manitoba, *Manage your apprenticeship* (journeyperson or designated trainer
  assigned; about 80 % of an apprenticeship on the job; one technical training session per level).
  <https://www.gov.mb.ca/apprenticeship/apprenticeship-program/manage-your-apprenticeship.html>
- Apprenticeship Manitoba, *Refrigeration and Air Conditioning Mechanic* trade profile (levels, hours,
  technical training weeks, the 2019 Red Seal Occupational Standard and the 2023 provincial standard
  for the residential stream). No date shown.
  <https://manitoba.ca/apprenticeship/explore-trades/trade-profiles/refrigeration-and-air-conditioning-mechanic.html>
- Apprenticeship Manitoba, *Construction Electrician — Manitoba Compulsory Certification Trade* fact
  sheet (PDF, file created 2024-11-26).
  <https://www.gov.mb.ca/apprenticeship/asset_library/en/apprenticeship/Construction-Electrician_CTFS_NewVI_2024_ENG-p9.pdf>
- Apprenticeship Manitoba, *Facts About Compulsory Certification Trades: For Employers* (PDF; the
  nine compulsory trades; journeyperson supervision).
  <https://www.gov.mb.ca/apprenticeship/asset_library/en/apprenticeship/Compulsory-Trades-Employers_NewVI_2024_ENG-p10.pdf>
- Apprenticeship Manitoba, *Online report of hours* notices (the paper report of hours ending in
  January 2023). **Seen as a search summary only**; the URL now redirects to the home page.
  <https://www.gov.mb.ca/aesi/apprenticeship/pdfpubs/pubs/manage/online_report_of_hours_faq.pdf>
- Red Seal Program, *Refrigeration and Air Conditioning Mechanic — examination weightings* (major work
  activities, tasks, 125 questions). No date shown.
  <https://red-seal.ca/eng/trades/refridgacmech/exam-weightings.shtml>
- Red Seal Program, *Refrigeration and Air Conditioning Mechanic Red Seal Occupational Standard*
  (2019). The structure (major work activity, task, sub-task; skills and knowledge per sub-task) was
  **seen through a search summary**; the PDF was not read in full.
  <https://www.red-seal.ca/_conf/assets/custom/docms/racm_rsos2019_eng.pdf>

## Unconfirmed

- Whether Apprenticeship Manitoba accepts a digital practical experience record book, and whether a
  current official record-book form exists (s. 6 still names one).
- The January 2023 end of the paper report of hours (search summary only).
- Whether AccessManitoba takes hours by task or as a total.
- Whether an apprentice needs their own trained service technician certificate to do M.R. 103/94 s. 6
  work under a certified journeyman (the text has no apprentice exemption).
- The issuer and terms of the electrician's licence after the certificate of qualification.
- The edition of the Construction Electrician Red Seal Occupational Standard.
- Red Seal's own wording on exam confidentiality (not found on red-seal.ca; the design's rule does
  not depend on it).
- Which privacy statute, if any, covers a Manitoba private employer's employee records: PIPEDA's
  employee provisions apply to federally regulated employers, and the status of Manitoba's
  private-sector act was not confirmed.
- iOS behaviour: the confirmation for `tel:` and FaceTime URLs on current iOS, what CarPlay shows,
  whether FaceTime can be asked to start on the back camera, and a FaceTime call to a number without
  an Apple device. All are device checks in P4.
