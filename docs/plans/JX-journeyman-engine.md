# Plan JX — The Journeyman Engine (time to competence: the job tracked, the unit remembered, the master recorded, a person on call, and a record the trade accepts)

**Status:** 📝 Drafted 2026-10-27 — nothing implemented. A twelve-month programme plan: it orders
work that other plans already hold and adds the pieces none of them do. Phases that grow past one
PR are marked **(own plan when scheduled)** and get their own letter then; this plan keeps the
order, the measure and the decisions. Owner decision on logbook ownership taken the same day (§1).
**Track:** Field Assist (B2B), phone and office. HVAC/R and electrical first; the first organisation
is in Winnipeg, Manitoba, so Manitoba is the worked case.
**Related:** Plan [JI](JI-apprentice-support.md) (the apprentice logbook, the journeyman's sign-off,
the scope guard, the call to the journeyman — §1 amends its ownership model), Plan
[JG](JG-regulation-practice.md) (practice from a reviewed bank), Plan [IM](IM-experience-recordings.md)
(experience recordings), Plan [GY](GY-procedure-from-narrated-recording.md) (a procedure drafted from
a narrated recording), Plan [FP](FP-team-learnings.md) (team learnings, the review gate), Plan
[JL](JL-procedure-deviations-and-learning-round-trip.md) (deviations bound to a step), Plan
[F](F-field-assist.md) / [FO](FO-guided-job-flow-and-job-tab.md) (procedures, the guided job), Plan
[GX](GX-photo-checked-procedure-steps.md) (photo-checked steps), Plan [IS](IS-refrigerant-toolkit.md)
(the refrigerant toolkit), Plan [IR](IR-test-sheets-from-a-photo.md) (test sheets), Plan
[IO](IO-sealed-proof-of-work-photos.md) (sealed proof-of-work photos), Plan
[IQ](IQ-closeout-unknown-units-and-calling-base.md) (a close-out the customer can act on), Plan
[EL](EL-equipment-identity.md) (equipment identity), Plan [IT](IT-find-the-manual.md) (find the
manual), Plan [HU](HU-service-history-and-maintenance-flags.md) (service history), Plan
[HV](HV-site-system-vaults.md) (site vaults), Plan [IH](IH-van-stock.md) (van stock), Plan
[GZ](GZ-expert-annotations.md) (expert annotations), Plans [L](L-webrtc-expert-transport.md) /
[M](M-webrtc-infra-and-audio.md) (expert streaming), Plan [IL](IL-technician-app.md) (the technician
app), Plan [IP](IP-organisation-feature-switches.md) (organisation feature switches), Plan
[IV](IV-manual-retrieval-rounds.md) (retrieval measured), Plan [JS](JS-licence-sales-and-device-seats.md)
(licence sales and hosting), [EU AI Act review](../eu-ai-act-review-2026-10.md).
**Origin:** The owner, 2026-10-27: "what would be an absolute moonshot to improve Avenkin? Assume
unlimited dev resources and 12 months." The answer was this plan; the owner asked for it drafted,
phased by quarter, and the same day corrected one part of it: the apprentice logbook is the
organisation's record, not the apprentice's (§1).

---

## Trigger

The October 2026 competitor review found every serious rival converging on the same product: a
nameplate photo, voice-first guidance, cited answers, a generated close-out, a mentor framing. That
product is becoming a commodity. The review's conclusion was that Avenkin's edge has to come from
**reach** (phone, earbuds, CarPlay, watch and glasses, hands-free), **provenance** (the
organisation's own manuals, cited to the page) and **the team layer** (what the crew learns, reviewed
by a supervisor) — and that Avenkin is behind on cross-manufacturer equipment data, on a live human
escalation line, and on placement inside the systems the office already runs.

Underneath all of it is the trades' hardest problem: it takes years for an apprentice to become a
journeyman, mostly because experience arrives at random, and the people who could shorten it are
retiring. The app already holds most of the pieces that bear on that problem — procedures, cited
manuals, team learnings, an apprentice logbook design, sealed photos, expert streaming — and nothing
pulls them toward a single measure.

## Outcome

One measure, five new capabilities, two loops that feed them.

- **The measure: time to competence.** For a cohort of apprentices in an organisation, the days from
  a task class's first attempt to the first time a journeyman signs it as done unaided, with no
  callback within the organisation's window. Built only from human records (§2).
- **On a rooftop at −30 °C.** The apprentice never takes their gloves off. Probe readings arrive over
  Bluetooth; the assistant says "You're four degrees under target subcool — add in short bursts."
  When the camera sees the panel closed, "Panel's back on — step six, restore power?" At the end:
  "Close-out's ready: readings, as-left photos, two parts from the van, and a note for the customer.
  Check it when you're down." One look, one confirm.
- **At a unit the crew has never seen.** "This serial range was built in 2017. Four other companies
  have logged inducer motor failures on it at six to eight years; you're at seven. Check the inducer
  first — service manual, page 22."
- **A master's last forty jobs.** The organisation's most senior technician wears the glasses for a
  month, narrating as they go. The office reviews what comes back: twelve cases, three procedures
  with the reason on each step, a diagnostic tree for a no-heat call, forty practice questions. Each
  one says it came from them.
- **At 2 a.m. on a no-heat call.** "Get me a journeyman." The on-call senior answers on their phone,
  already looking at a briefing card — the unit, the readings, the steps done, what's been ruled out
  — and circles the pressure switch on the apprentice's view.
- **On the equipment, a label.** When the job closes, a QR label goes on the unit. The homeowner
  scans it and sees, in plain words, what was done and when the next service is due. The next
  technician, from any company, scans it and sees the history the organisation chose to publish.
- **When an apprentice moves on.** Their logbook stays with the organisation that signed it. They
  leave with a signed, verifiable copy, and their next employer imports it as a read-only record of
  prior work (§1).

## 0 · What this plan takes over, and what it leaves where it is

This plan **takes over** nothing a drafted plan already designs. JI, IM, GY, IO, IQ, IR, GZ, IT and
IL keep their designs; this plan puts them in an order and names the phase of this plan each one
must land before. It **adds**:

1. The time-to-competence measure (§2).
2. Instrument readings over Bluetooth (§3).
3. Procedure state from evidence — proposals to advance, and a skipped step noticed (§4).
4. The close-out assembled from the job's own records (§5).
5. The unit record, the serial decoders and the shared equipment record across organisations (§6).
6. Succession recording — a master's series of jobs as one reviewed body of work (§7).
7. The expert line: briefed, live, and eventually beyond the organisation (§8).
8. The unit passport (§9).
9. Warranty evidence, aggregate failure reports and dispatch suggestions (office half, §10).
10. The logbook export and import, and a certification pilot (§1, §11).
11. An evaluated on-device trade model for sites with no signal (§12).

**It amends** JI §11 and §12 on who holds the logbook (§1). Nothing else in JI changes.

## What exists today (verified against `main` @ `06986e051`, 2026-10-27)

- **The session knows the machine.** `EquipmentIdentity` keeps the identified model for the session
  until it is corrected or cleared (EL P1–P2); `UnitLedger` puts together every unit a job covered
  and the work recorded under each. Neither outlives the job as a unit-level record, and nothing is
  keyed by serial. EL P3 (nameplate fields) is not started.
- **Procedures run by voice.** `ProcedureRunner` knows next, back, repeat and complete. It has no
  notion of evidence that a step is done, and a departure from the procedure has nowhere to go
  until JL is built.
- **Team learnings are captured and reviewed.** `LearningCandidate` and the unsigned bundle exchange
  (FP P0–P3) exist headless; the office review pass is undrafted.
- **Readings are spoken or photographed.** Structured vision's `instrument_reading` reads a gauge from
  a still; IS P0 gives `domain_calc` saturation tables for thirteen refrigerants, so superheat and
  subcool are computed from numbers the technician says. **Nothing reads an instrument directly:**
  `CoreBluetooth` is imported only by the EVEN display transport.
- **Expert streaming exists app-side.** WebRTC and the base-server MJPEG relay ship; `ExpertBridge`
  is still an interface ("Phase 3 ships the interface only"); GZ's annotations are drafted.
- **Job evidence.** `JobPhotoEvidenceService` keeps job photos; IO's sealed photos are drafted, not
  built.
- **Office knowledge reaches the phone.** HU service history (P0–P3), HV site vaults (P0–P2) and IH
  van stock are built headless, device checks owed.
- **The apprentice is designed, not built.** JI and JG are drafted; nothing is implemented. JI §12
  currently says "An apprentice's data is theirs" — §1 below changes that for the logbook.
- **No unit passport, no cross-organisation record, no instrument link, no marketplace, no
  dispatch suggestion** exist anywhere in the repository.

---

## Design

### 1 · The logbook belongs to the organisation; the apprentice holds a signed copy (owner decision, 2026-10-27)

The owner: "I don't know if we want the apprentice logbook to be owned by the apprentice, as an
organisation will want to see it, so maybe they can import / export, but it's inherently linked to
the organisation."

That matches the law in the worked case: in Manitoba the employer must record an apprentice's hours
and verify their tasks (JI §1). So:

- **The logbook is an organisation record.** Entries, the journeyman's sign-offs and the certificates
  on file belong to the organisation the work was done for. They reach the organisation as part of
  the job's records, by design, not by a share the apprentice chooses. JI §11's "Sharing is the
  apprentice's choice" stops applying to logbook entries and certificates; it still applies to
  everything in the next bullet.
- **What stays the apprentice's own** is unchanged from JI: practice and exam preparation,
  point-and-name drills, debrief answers, learned notes, scope-guard notices and call records. The
  organisation never sees them unless the apprentice sends a progress share (JI §11).
- **Export, at any time, including on leaving.** "Export my logbook" gives the apprentice a signed
  copy: every entry with its job reference (not the customer), hours by task code, the journeyman's
  sign-off and its fingerprint over the entries (JI §9), and the organisation's signature over the
  whole export. The copy is verifiable without the issuing organisation's cooperation. An
  organisation profile cannot switch the export off: the record is of the apprentice's own work.
- **Import at the next organisation, read-only.** A new employer imports the copy as **prior work**:
  shown as signed by the previous organisation, never re-signed, never editable, counted separately
  from hours the new organisation verifies. A failed signature check imports nothing and says why.
- **No AI-derived figure about a person.** The review's design rule holds (AI output is never an
  input to a performance figure; Annex III 3(b) and 4(b) are high-risk from 2 December 2027): a
  logbook entry is drafted by fixed rules, confirmed by the apprentice and verified by a human.
- **JI amendment.** JI §11 and §12 carry a dated note pointing here. When JI P1 is scheduled, its
  stores move the logbook from the apprentice-only store into the organisation's job records, and
  P2b's delivery stops being optional for entries.

### 2 · The measure: time to competence

- **Task classes** come from the organisation's or vault author's task list (JI §3); the app ships
  none.
- **"Done unaided"** is a journeyman's mark on a signed logbook entry — a human judgement recorded
  on the sign-off sheet, never inferred from a recording, a reading or a model.
- **The measure is a cohort figure.** Avenkin Office computes, per organisation and task class, the
  median days from first attempt to first unaided sign-off, with callbacks inside the organisation's
  window excluding an entry. Per-apprentice timelines are the logbook itself, which the
  organisation already holds (§1); no ranking, rating or readiness figure is computed.
- **The 90-day claim is a hypothesis.** P13 designs the cohort comparison; nothing is said in
  marketing until it is measured.
- **Secondary measures:** first-time fix rate, callbacks avoided, minutes of paperwork per job
  (target zero), median expert-call length.

### 3 · Instrument readings over Bluetooth

- **A seam, not a vendor.** `InstrumentLink` (protocol) discovers and connects instruments;
  per-vendor adapters decode their characteristics into `InstrumentReading { quantity, unit, value,
  at, source }`, where `source` is `.instrument(vendor, model, serial)` — distinct from `.spoken`
  and `.photo`, and carried everywhere a reading goes.
- **Where readings go:** `domain_calc` (superheat and subcool live, from IS's tables), IR's test
  sheets, GX's checks, the close-out (§5), the warranty pack (§10).
- **What is said.** The assistant names the source ("from the suction probe"); a reading older than
  its quantity's freshness window is stale and said to be; a disconnected probe is heard once.
- **Safety.** Readings come from instruments, never a model; the model may explain a computed
  figure, not invent one. No reading ever blocks a step.
- **Vendors.** Several refrigeration and electrical meter makers publish or license their Bluetooth
  protocols to app partners; which ones, and on what terms, is open question 1. P0 builds the seam
  and one adapter against recorded traffic, headless.

### 4 · Procedure state from evidence

- A procedure step may carry **`expects`**: an instrument range, a GX photo check, or a spoken
  phrase. When the evidence satisfies it, the runner **proposes** the next step ("Panel's back on —
  step six?"); it never advances silently, and "just go" turns proposals into spoken advances for
  the rest of the job.
- **A skipped step is noticed.** Evidence that belongs to a later step, or a "next" past an
  unsatisfied required check, offers JL's deviation phrase ("skipped", "did it differently", "step's
  wrong") — it never blocks.
- Pure core: `ProcedureEvidencePolicy` over (step, readings, checks, phrases) → proposal or none.

### 5 · The close-out assembled from the job's own records

The work record (EM) is assembled from what the job already holds: the runner's steps and
deviations, instrument readings with their sources, IO's sealed as-found and as-left photos, IH's
van stock used, IQ's customer levels, the unit ledger. The technician confirms once; nothing is
typed unless they choose to. A field with no source is left empty and said to be, never filled by a
model.

### 6 · The unit record and the shared equipment record

- **`UnitRecord`**, org-local first: keyed by normalised (manufacturer, model, serial), with the
  manual it maps to (IT), its revision state (HK), the organisation's service history (HU), its site
  (HV), and the failure modes this organisation recorded on it (FP learnings bound to the unit).
- **Serial decoders are data.** A manufacturer's serial-to-build-date rule ships in a vendor-signed
  directory, the same shape as IT's manufacturer directory; a serial no rule decodes says so.
- **Sharing across organisations is opt-in and reviewed.** A `UnitFact` is a closed type: model,
  serial range (never a full serial), build-year band, a failure-mode code from a fixed vocabulary,
  age band at failure, and the organisation's anonymous contributor id. It carries no customer, no
  address, no site, no job, no technician, no free text and no photo. A supervisor approves each
  batch before it leaves (FP's review pattern).
- **A fact is shown only above a floor**: at least two organisations and a minimum number of
  observations (open question 3). It is said as a known issue with its count, never as a diagnosis:
  "Four other companies have logged …".
- **Hosting.** The aggregator is a vendor service, alongside the licence server's hosting (JS). It
  is a new egress: disclosed in the privacy manifest and the in-app copy in the same PR that turns
  it on, and off until an organisation turns it on (IP).
- **(Own plan when scheduled):** the aggregator service and its contract.

### 7 · Succession recording

A mode for one technician over a series of jobs, built on IM (one case per recording) and GY
(procedure from a narrated recording):

- The office opens a **succession** for a named technician with their written consent; each job they
  record under it is tagged to it.
- What comes back, after office review: cases, procedure drafts with the master's reason on each
  step, diagnostic trees, and practice items for JG's bank. Every item credits the technician by
  name, with their consent, and they can withdraw it.
- Recording follows IM's and CP's rules: every outbound frame filtered, customers told, nothing
  model-judged about the technician.

### 8 · The expert line

- **Stage A — the organisation's own seniors.** JI's "call my journeyman" plus a **briefing card**
  built from session state (unit, readings, steps done, deviations, what's been ruled out), sent to
  the senior's phone before they answer; GZ's annotations on the apprentice's view; `ExpertBridge`
  made live over the existing transports. A call is never recorded by default; "note what you
  learned" afterwards follows JI.
- **Stage B — vetted experts beyond the organisation.** Retired or independent journeymen, by trade
  and code jurisdiction, paid per minute, verified for identity and licence. This is a second
  business: payments, liability, insurance, a contracting entity and a review process. **(Own plan
  when scheduled)**, after Stage A is in use and the owner decides to take it on (open question 5).
- *2026-11-03:* Plan [KM](KM-expert-on-the-job.md) covers Stage A and a step between A and B: experts
  the organisation contracts itself (retired journeymen on call), sent the job as it stands, with their
  time on the record and a monthly statement they invoice against. It has no marketplace and no payments.

### 9 · The unit passport

- **The label carries an opaque identifier only**: no serial, address or name in the URL. It resolves
  to a passport page the organisation publishes (through the office, or a vendor-hosted page for an
  organisation without one).
- **Two views.** The owner view, in plain words: what was done, when, what's recommended, when the
  next service is due. The technician view: the history the organisation chose to publish — by
  default the dates, the work done, the as-left photos and the readings, never technician names or
  customer details.
- **Consent and revocation.** The property owner agrees to the label; the organisation can revoke a
  passport, and a revoked label says so.
- **Another company's technician** scanning it sees the published history and an invitation to try
  Avenkin. That is the distribution loop, and it only works if the page is useful on its own.
- **(Own plan when scheduled)** for the hosting half.

### 10 · Warranty evidence, failure reports and dispatch suggestions (office half)

- **Warranty evidence pack:** sealed photos, instrument readings with their sources, the unit's
  serial and the work record, exported from a job in the format a manufacturer asks for. The
  organisation sends it; Avenkin does not.
- **Aggregate failure reports to a manufacturer** come only from §6's shared record, above the same
  floors, with the contributing organisations' agreement.
- **Dispatch suggestions** in Avenkin Office: from the booking's symptoms and the unit record, the
  likely parts (checked against van stock) and the technicians whose **signed** task classes cover
  the job. Allocating work to people is Annex III 4(b) territory: the suggestion is fixed-rule over
  human records, a dispatcher chooses, and the EU review classifies it before it ships in an EEA
  build (open question 7).

### 11 · The certification pilot

The signed logbook export (§1) plus the evidence it references is the portfolio. The pilot is owner
led: one jurisdiction's apprenticeship authority or training provider agrees to accept it as
evidence toward a level. Until one does, the export is "a record the employer signed", as JI says.
The engineering is the format, the verifier and a printable form; the rest is a conversation.

### 12 · An on-device trade model, evaluated

For basements and plant rooms with no signal: a small on-device model with the trade's tools and the
organisation's retrieval. It is adopted only if it beats the current local model with retrieval on
IV's rounds and a trade question set. **Training data:** organisation-owned and vendor-authored
content only; no licensed manual, code book or exam-derived material is ever used to train or tune.
Local inference keeps its foreground-only rule.

### 13 · Gates and modes

Every capability is an organisation feature switch (IP), off until taken. Glasses are never
required: every flow works on the phone, earbuds and CarPlay. Anything where a model's output marks
a person stays personal and EEA-gated, as JI does. Spoken and shown copy names no plan letter.

---

## Phases (one PR each), by quarter

Prerequisites that land before the phase that needs them: **JI P0–P2a** (before P8), **IO** (before
P2), **IM** and **GY** (before P4), **GZ** (before P7), **IT** (before P3), **IQ** (before P2), **IL**
(before P6's technician view).

### Q1 — the job tracked

- **P0 — Instrument readings, the seam and one adapter (headless).** `InstrumentLink`,
  `InstrumentReading` with its source, one vendor adapter decoded from recorded traffic, the
  freshness window, `domain_calc` reading live values. Tests from fixtures; device pass owed.
- **P1 — Procedure state from evidence.** `expects` on a step, `ProcedureEvidencePolicy`, proposals,
  "just go", the skipped-step offer into JL.
- **P2 — The assembled close-out.** EM's record from the runner, readings, IO, IH, IQ and the ledger;
  one confirm; empty-and-said for unsourced fields.
- **P3 — The unit record and serial decoders (org-local).** `UnitRecord`, the signed decoder
  directory, unit-bound learnings, the brief reading them.

**Proof point:** one organisation's crew closes a hundred jobs with no typed paperwork.

### Q2 — the unit remembered, the master recorded

- **P4 — Succession recording.** The succession on IM and GY, consent, credit and withdrawal.
- **P5 — The shared equipment record, phone half.** `UnitFact`, the review gate, the floors, the
  disclosure. **(Aggregator: own plan.)**
- **P6 — The unit passport, phone half.** Label issue at close-out, opaque id, consent, revocation.
  **(Hosting: own plan.)**

**Proof point:** one master's library reviewed; a thousand unit records; the first passport scanned
by another company's technician.

### Q3 — a person on call, a record that travels

- **P7 — The expert line, Stage A.** `ExpertBridge` live, the briefing card, GZ annotations.
- **P8 — Logbook export and import.** §1's signed export, the verifier, read-only prior work; the JI
  store change.
- **P9 — The on-device trade model, evaluated.** The comparison on IV's rounds; adopt or record why
  not.

**Proof point:** median expert call under four minutes; one training provider reviewing the export.

### Q4 — a record the trade accepts

- **P10 — Certification pilot format.** The printable portfolio and the verifier's public half.
- **P11 — Warranty evidence pack.** Office export from a job.
- **P12 — Dispatch suggestions (office).** Fixed-rule, over signed task classes, EU classification
  first.
- **P13 — The cohort measure.** §2's figure in Avenkin Office and the study design for the 90-day
  hypothesis.

**Proof point:** a cohort's time to competence on five task classes, measured against the same
organisation's previous intake.

## Decisions

### Decided by the owner (2026-10-27)

1. **The logbook is the organisation's record**, with a signed export the apprentice can take and a
   read-only import at the next organisation (§1). JI §11/§12 amended accordingly.

### Proposed (owner to confirm)

2. Time to competence is the programme's single measure, cohort-level only, from human sign-offs.
3. Instruments before cameras: a reading from an instrument outranks one read from a photo.
4. The shared equipment record is opt-in per organisation, reviewed per batch, floored, and carries
   no free text or photos.
5. The expert line starts inside the organisation; Stage B is a separate decision.
6. A twelve-month pause on new consumer-only plans (accessibility excepted), so every new plan
   answers: does this shorten time to competence or make the record more trustworthy?
7. Organisation seats with a free technician app (IL) as the commercial shape; per-minute expert
   calls and manufacturer evidence fees later. No prices in this plan.

## Open questions for the owner

1. Which instrument makers first, and on what terms do they open their Bluetooth protocols?
2. Which trade leads — refrigeration (IS is built) or electrical (IR's test sheets)?
3. The shared record's floors: how many organisations and observations before a fact is shown?
4. Who operates the aggregator and the passport host — the vendor, alongside the licence server, or
   each organisation's office?
5. Stage B experts: a business to take on, partner for, or leave?
6. Which jurisdiction for the certification pilot — Manitoba, through the first organisation, or New
   Zealand?
7. Dispatch suggestions in EEA builds: wait for the EU review's classification, or ship outside the
   EEA first?
8. How a union or works council is briefed: what the organisation sees (the logbook, by law), and
   what it never sees (practice, drills, debriefs, calls, any model output about a person).

## Risks

- **Wrong guidance on gas, refrigerant or live electrical work.** Readings from instruments, answers
  cited or said not to be, never a block, a human one phrase away.
- **Recording in customers' homes.** CP's filtering on every outbound frame, consent on recordings
  and passports, on-device by default, erasure that works.
- **Worker trust.** The organisation holds the logbook because the law asks it to; nothing beyond
  that leaves without the apprentice choosing; no model-derived figure about a person, ever.
- **Federated poisoning or gaming.** Review per batch, floors, provenance on every fact.
- **Platform dependence.** Phone, earbuds and CarPlay stand alone; glasses are one surface.
- **Regulators move slowly.** The export is useful to employers and training providers first;
  certification is upside.
- **Scope.** Twelve phases across a year is a programme; each phase still ships alone and leaves the
  app better if the next never comes.

## Out of scope

- Any score, rank, rating or readiness figure about a person.
- Training or tuning on licensed manuals, code books or exam-derived material.
- Submitting anything to a regulator on an organisation's behalf.
- The phone talking to a field-service system directly (the office remains the bridge).

## Unconfirmed

- That instrument makers will license their protocols on workable terms (open question 1).
- That any apprenticeship authority will accept a signed digital portfolio as evidence.
- The 90-day figure: a hypothesis for P13 to test, not a claim.
