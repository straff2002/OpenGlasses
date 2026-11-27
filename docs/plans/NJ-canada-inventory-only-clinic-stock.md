# Plan NJ — Canada, Inventory Only (a clinic's shared stock can never carry a patient, the Medical Compliance claims say only what the app does, and Canada's health acts are named)

**Status:** 🚧 P0–P1 built (headless) 2026-11-27. Decisions 1–6 taken as recommended; Decision 7
deferred, so P3 (§9, vaccine records) is not built. Built: `ClinicalStockShareRow` and its allow-list
guard, the per-day aggregator behind the clinical spreadsheet export, the handover workbook and the
period report's "By day" sheet, the fail-closed sheet check for clinical lists, no job on a clinical
movement, the staff code (Decision 3), the billing-export reader and `BillingReconciliation` with
the shared-code case, the 1,461-day clinical history window, the sensitive flag and small-cell rule
(5), `CanadianHealthAct` with the Canada entry and province picker, the ceiling keys `hipaaMode`,
`hipaaLocalOnly` and `hipaaRetentionDays` (a new `daysCeiling` kind), the claims rewritten, the lock
screen's "Medical mode", and the support report's clinical lines. 82 new tests in 9 classes.
Owed: P2 catalog sync; P3 (deferred); P4 counsel; P5 device pass and pilot; a Stock screen entry
for the billing check (the core is headless only). Retention is read as the longest a phone keeps
clinical files, never longer (CT is silent; the stricter reading). It still waits on the clinic's
province and on whether it needs patient linkage (open questions 1 and 3).
**Track:** Field Assist stock, for a medical clinic, and the Medical Compliance mode.
**Builds on:**
- Plan [MY](MY-vaccine-stock.md): lots, waste and expiry; the check against the EMR (§8); stock
  lowered by billing (§8a, Decision 13); one fridge, several staff (§8b).
- Plan [IH](IH-van-stock.md): the movement log and its fold (`VanStockStore`, `VanStockLedger`).
- Plan [CT](CT-org-configuration-profiles.md): organisation profile keys, and the ceiling-only
  HIPAA pin it decided but did not build.
- Plan [DL](DL-medical-secret-and-export-lifecycle.md) and Plan [DM](DM-privacy-safe-production-logging.md):
  the medical mode's file protection, audit log and logging rules.
- The network route registry (`NetworkRouteRegistry`, `MedicalEgressGuard`).

**Followed by:** Plan [NK](NK-clinic-stock-in-the-clinics-own-workbook.md) (the shared count in the
clinic's own Microsoft 365 workbook) and, only if the clinic needs it, Plan
[NL](NL-canada-patient-linked-clinical-data.md) (patient-linked data in Canada).

---

## Trigger

A Canadian clinic wants to pilot vaccine stock (Plan MY). Its brief asks for stock lowered by
billing, and several staff share one fridge, so the count has to be one shared record (MY §8b).
The owner's position is that the shared record must not be a server of ours, and that patient data
should stay out of the app. The partner is asking the clinic which province it is in.

A research report on Canadian health-privacy law (2026-11-27, kept outside the repo; not legal
advice) answered the question this plan turns on: **is vaccine stock with no patient linked
"personal health information"?** It is not, in any province or territory. Vaccine, lot, expiry,
quantity and the date received describe vials, not people. The record becomes health information
when it becomes, in effect, "this dose went to this person": a dose timed to the minute, the staff
member named on each dose, a rare product (one rabies dose today says who was bitten), or a tariff
claim tied to a patient.

So the pilot can be health-privacy compliant anywhere in Canada without a server, a certification or
a provincial agreement, **if the shared record is inventory-only by construction**. That is what
this plan builds, along with correcting what Medical Compliance mode claims, which the same
research found overstated in places.

## The point, said once

What leaves a clinic's phone describes the fridge, not a patient: a day, a line, a lot, a kind of
movement, a quantity and, for waste, a reason. A test fails if anything else can get in. The
Medical Compliance screens name Canada's health acts and say only what the code does.

## What the law says (from the research; [confirm] marks a point for a Canadian lawyer)

- **The tests differ by province, and the strictest one sets the design.** Ontario, Nova Scotia and
  PEI count information as identifying when it is "reasonably foreseeable" that it could identify
  someone "alone or with other information", which includes the clinic's own appointment book.
  Alberta asks whether identity is "readily ascertained from the information" itself. A per-dose
  log could be outside the act in Alberta and inside it in Ontario [confirm]. The federal courts ask
  whether there is a "serious possibility" of identification (*Gordon v. Canada (Health)*, 2008 FC
  258).
- **A staff member's name is that person's personal information, not health information.** It
  becomes part of the *patient's* record only on a dose that can be linked to a patient (Ontario,
  Nova Scotia; Alberta HIA s.1(4)). Staff data is regulated personal information under BC PIPA,
  Alberta PIPA and Quebec's private-sector Act, and largely unregulated in Ontario and the Atlantic
  provinces [confirm]. So staff stay off whatever leaves the phone.
- **A tariff code on its own is not personal information.** Attached to a claim for a patient it is
  health information. Some codes also reveal eligibility (age, risk group, pregnancy).
- **Small cells identify.** Federal practice cites a minimum cell of 10 for less sensitive data and
  20 for more sensitive data. Ontario's regulator does not expect zero re-identification risk, but
  sets a lower acceptable risk for high-impact data.
- **Vaccine stock records must be kept 1–4 years, by province:** Ontario 1 year or until the next
  inspection, BC and the national guideline at least 3 years, Quebec 4 years. Retention for
  Manitoba, Saskatchewan, Nova Scotia, New Brunswick and Newfoundland was not found. Until the
  province is known, 4 years is the safe floor.
- **One question needs a lawyer before the pilot:** does the company become the clinic's agent or
  information manager because its app reads the EMR's export (which carries patient details) on the
  clinic's phone, even though the company never runs the reader or sees its input? Ontario's
  O. Reg. 329/04 s.6 may reach a supplier whose software lets a custodian use health information
  electronically [confirm]. A licence that says the company receives no health information, has no
  remote support access to it and collects no telemetry carrying it is the cheapest way to stay a
  software supplier. That is an inference, not a regulator's statement [confirm].

## What exists (verified 2026-11-27 on `origin/main` a93bd76b5)

- **No patient field anywhere in the stock model.** `VanStockMovement` (`VanStockMovement.swift`
  L88-116) holds item, kind, quantity, time, batch, source, job session, `jobReference`, removal
  reason, request, reversal, attribute edits, opening flags, `lotID` and `wasteReason`. It has **no
  staff field**. `jobReference` is free text taken from the active field session
  (`VanStockService.swift` L151, L317, L363), and nothing stops it on a clinical list.
- **The EMR file is stripped on the phone.** `ImmunisationRecord` holds `day`, `vaccine` and `lot`
  only (`ImmunisationListReader.swift` L6-10), and the column mapping holds column names, never
  values.
- **History folds after 400 days.** `VanStockStore.historyDays = 400` (`VanStockStore.swift` L27),
  applied at load (L84-85). Levels stay exact, but the movements a 3–4 year vaccine record needs are
  gone.
- **Waste has structured reasons** (`WasteReason`: expired, cold chain, drawn up and not given,
  broken, opened vial discarded, other; `VanStockMovement.swift` L48-57).
- **The FHIR export is the one clinical write-back Local Only allows,** because its destination is
  "the operator's own record system" (`NetworkRouteRegistry.swift` L451-453). Every other route is
  `blockedWhenLocalOnly`.
- **Local Only is off by default** (`Config.hipaaLocalOnly`, `Config.swift` L3326-3328), so the
  spoken sentence ("gave Mrs Smith her flu shot") goes to the chosen cloud model (MY §10).
- **No organisation key pins Medical mode or Local Only.** `SettingKey` has
  `organizationStockClinical` (L86), `interpreterEnabled` (L131) and `cloudDictationEnabled` (L146),
  but no `hipaaMode`, `hipaaLocalOnly` or retention key. CT decided a ceiling-only HIPAA pin and did
  not build it.
- **Canada appears once in Medical Compliance:** `MedicalFramework.pipeda`
  (`HIPAASettingsView.swift` L12), with the same safeguards as NZ's code and the duty "Privacy
  breach reporting to OPC" (L131). No provincial act is named anywhere in `OpenGlasses/Sources`.
- **Claims the code does not back** (`HIPAASettingsView.swift`):
  - L196 "Supports secure deletion (data overwrite before removal)". The code deletes logically on
    purpose (`HIPAAComplianceService.swift`), because overwriting achieves nothing on flash storage.
  - L353 "No clinical data is sent to cloud providers". The FHIR export can reach a cloud-hosted EMR.
  - L198 says Local Only avoids the agreement requirement and names no Canadian agreement.
  - L87 "Signed BAA with each cloud LLM provider" omits any service the app's vendor runs.
  - L114 NZ "Health agency registration". The research found no such requirement in the NZ code.
  - L107 "Registration with Australian Digital Health Agency". My Health Records Act s.77 binds
    only the system operator and registered operators, not a stock app.
  - L96 "Meaningful use attestation". The research flagged the programme as renamed (unverified).
  - L194 and L268 "All data access events are logged … Exportable". The log is on the phone, kept
    only while the mode is on, capped at 1,000 entries, with no per-user or per-record field.
  - L200 says leakage tools are off "to prevent clinical data from leaving the device".
  - `MedicalEgressGuard.swift` L10 and L12 "nothing derived from what was captured may leave this
    device". Plan NK's workbook route has to be squared with this.
  - `BiometricLockView.swift` L26 "HIPAA Protected", a US label on every lock screen.

## Design

### 1 · Inventory-only by construction

A list marked clinical (`organizationStockClinical`, or the list's own flag, MY §9) gets one
allow-list of what may leave the phone, `ClinicalStockShareRow` (pure):

| Field | Kept | Notes |
|---|---|---|
| day | yes | a `StockDay`, never a time |
| line | yes | the line's number (the tariff, where the clinic's list made it one) and name |
| lot | yes | code and expiry; recalls need lots |
| kind | yes | received, given, wasted, returned, counted, adjusted |
| quantity | yes | doses (`each`) |
| waste or return reason | yes | `WasteReason` only, never free text |
| staff | **no** | see §3 |
| job reference, free text, patient, appointment | **never** | the guard test fails on them |

- **A guard test reads the type's stored properties and fails on any name outside the
  allow-list,** the way `ImmunisationRecord`'s test does. Adding a field means editing the test,
  which makes it a decision rather than an accident.
- **Inbound rows fail closed.** An import or a feed row for a clinical list that carries a column
  matching a patient pattern (name, date of birth, health number, MRN, appointment) is refused with
  a plain message, not silently stripped. The one exception is the EMR file read by MY §8, which
  stays as built: it is read in memory, three columns are kept and nothing is stored.
- **`jobReference` is never set on a clinical list.** `VanStockService` stops taking it from the
  field session there.

### 2 · What leaves the phone is per day, and the phone keeps the minute

The phone's own log keeps its timestamps: the daily check (MY §8) needs the day, and the count
needs the order of events. Whatever is shared (Plan NK's workbook, a takeover workbook, a period
report, a spreadsheet export) is built from `ClinicalStockShareRow`: **one row per day, line, lot,
kind and reason**, quantities summed. A per-dose row with a time never leaves the phone.

Decision 2 asks whether the phone should also fold its own minute timestamps to the day once the
daily check has run, since the `vanStock` store sits in the device's backups.

### 3 · Staff

The movement log has no staff field today, and this plan adds none to routine doses. Where
accountability needs a person (wasted doses, adjustments, a count that disagrees, a cold-chain
event), Decision 3 offers a clinic-local code or initials on those kinds only. It is kept on the
phone and never shared.

### 4 · Tariffs: find the line, then let go

The tariff is the line's number (MY P3b), so a billing export finds the line with no mapping step.
This plan adds:
- **A tariff that covers more than one line asks for the product.** A catch-all code (Ontario's
  G538 covers MMRV, shingles and RSV) or one tariff over several brands must not lower the wrong
  line. The billing-export check (MY Decision 13) reports these as "billed under a shared code" and
  leaves them for staff to assign.
- **No tariff is kept on a movement.** The billing export is read like the immunisation export: in
  memory, under medical mode, with date and tariff only and the lot optional. It is compared by day
  and line.

### 5 · Four years for a clinical list

`VanStockStore` takes its history window from the list: 400 days for a van, as now, and **1,461 days
(four years)** for a clinical list until the clinic's province sets its own (Decision 4). The fold
still runs past the window and no movement is hard-deleted inside it. `VaccineStockPolicy` holds the
figure, and the support report prints it.

### 6 · Sensitive products and small cells

A line can be marked **sensitive** (rabies, yellow fever and other travel vaccines, HPV, hepatitis
B; the clinic chooses). Reports, exports and shared rows show a sensitive line weekly rather than
daily, and print any figure below the threshold as "fewer than N" (Decision 5). The phone's own
Stock screen still shows the exact count to the person holding it.

### 7 · Pin on-device processing for a clinic's phones

- **Now, with no new code:** the pilot's organisation profile pins the on-device model (`aiModel` /
  `aiChoices`) and pins cloud dictation and the interpreter off, so a spoken patient name never
  reaches a cloud model.
- **Built here:** the ceiling keys CT decided: `hipaaMode` (on, locked), `hipaaLocalOnly` (on,
  locked) and `hipaaRetentionDays`. Each can only make a phone stricter, never looser.
  `hipaaRetentionDays` is a ceiling: the longest a phone keeps Medical mode's transcripts and
  recordings. A shorter setting on the phone stands, and "Never" is held to the figure. This
  follows CT's rule that a ceiling only subtracts, and the expert-handover retention key. It does
  not touch the stock store, whose four years come from §5 (2026-11-27; the draft said "a floor").

### 8 · Medical Compliance says only what the app does, and names Canada

- **Canada's acts by name.** `.pipeda` stays for the federal act. A Canada entry gains a province
  (or territory) picker backed by a pure table, `CanadianHealthAct`. For each jurisdiction it gives
  the act that governs a private clinic, what the vendor is called and which agreement that needs,
  the breach notice and who receives it, the user-activity log rule and the PIA duty:

  | Jurisdiction | Act | Breach notice goes to |
  |---|---|---|
  | BC | PIPA | no mandatory notice |
  | AB | HIA | the Commissioner, the Minister and the individual |
  | SK | HIPA | no statutory notice |
  | MB | PHIA | the Ombudsman and the individual |
  | ON | PHIPA | the individual, and the IPC in prescribed cases |
  | QC | R-22.1 | the CAI and the Minister |
  | NS | PHIA | the individual, or the commissioner if the individual is not told |
  | NB | PHIPAA | the Ombud |
  | NL | PHIA | the commissioner, for a material breach |
  | PEI | HIA | the commissioner (PEI is not on the federal substantially-similar list, so PIPEDA probably applies too) |
  | Territories | HIPMA (Yukon), HIA (NWT) | per act; Nunavut falls under PIPEDA |

  The user's duties come from the same table: an information-manager agreement before any patient
  data flows (with "not needed while the list is inventory-only" said plainly); Alberta's PIA
  submitted to the OIPC; Quebec's PIA before data leaves Quebec; Manitoba's and Nova Scotia's
  records of user activity; and PIPEDA's 24-month breach record where it applies. **"Breach
  reporting to OPC" is corrected:** custodians in Ontario, Nova Scotia, New Brunswick and
  Newfoundland report to their provincial commissioner.
- **The claims listed under "What exists" are reworded to match the code.**
  - Deletion: "files are deleted; flash storage cannot be overwritten; backups and shared copies are
    not reached".
  - Cloud: "no clinical data is sent to an AI provider; it leaves the phone only to your own record
    system".
  - Agreements: name Canada, and limit "Local Only avoids this" to AI providers.
  - Audit log: "on this phone, while Medical mode is on".
  - Remove NZ "health agency registration"; limit the My Health Records entry to users who connect
    to My Health Record; check "Meaningful use" before renaming or removing it.
  - The lock screen says "Medical mode", not "HIPAA Protected".
- **The paywall's disclaimer stays** ("A subscription does not certify legal compliance or clinical
  accuracy", `MedicalCompliancePaywallView.swift` L69). It is accurate.

### 9 · Records the clinic's duties need (recommended, P3)

From the provincial vaccine-management guides (the national guideline's 2015 edition; the 2026
edition was not read):
- **Funding source on a line** (publicly funded or privately bought; MY Decision 6) and **supply
  source** (public health unit, depot, wholesaler).
- **Storage unit** (which fridge).
- **A return record:** a `returned` kind with the depot's form or authorisation number. Expired and
  spoiled funded vaccine goes back to its source and is not discarded locally. BC's field return
  form (product, lot, expiry, reason, doses) is the shape to follow.
- **Recall lookup by brand and lot:** which lots do we hold, and how many doses of each.
- **An order-form export:** current inventory per vaccine, which an Ontario order to the health unit
  needs.
- **Monthly count per lot,** beside MY's weekly count.

Fridge temperature logging stays out of scope (MY "Not in scope"). The clinic's log book or data
logger remains the record an inspector reads.

### 10 · Written down (P4, owner and counsel, outside the repo)

- **A one-page data-flow note:** fields in, fields dropped, where the stripping happens, what is
  shared and where. That is the evidence a regulator looks for.
- **A clinic-facing data schedule** and a **licence privacy schedule:**
  - No health information received.
  - No remote support access to it.
  - No telemetry carrying it.
  - A dormant processing schedule that applies only if the company ever handles patient data.
  - Reviewed by Canadian counsel in the clinic's province.

## Phases

The house rhythm puts the code in one PR, with the device and owner edges named as owed.

- **P0 — the core (headless).**
  - `ClinicalStockShareRow` and its allow-list guard.
  - The fail-closed inbound check.
  - No `jobReference` on a clinical list.
  - Per-day aggregation for anything shared.
  - Tariff-to-line with the shared-code case.
  - The billing-export reader (date and tariff, lot optional) beside `ImmunisationListReader`.
  - The history window per list (1,461 days clinical).
  - The sensitive flag and small-cell rule in `StockPeriodReport` and the exports.
  - `CanadianHealthAct`.
- **P1 — wiring and copy.**
  - The ceiling keys `hipaaMode`, `hipaaLocalOnly` and `hipaaRetentionDays`.
  - The Canada entry and province picker.
  - The claims rewritten.
  - The lock screen label.
  - Decision 3's staff code, if taken.
  - Support report lines: clinical history window, share mode, ceiling keys.
- **P2 — catalog sync.** The changed and new Medical Compliance strings in the 13 complete
  languages, add-only.
- **P3 — vaccine records (recommended).** §9. It can be dropped or deferred without affecting P0–P2.
- **P4 — owner and counsel (outside the repo).** §10, and Canadian counsel's answer to the
  agent-or-supplier question.
- **P5 — device pass and pilot.** The clinic's real export and billing export read on a phone; the
  pinned profile applied; a shared row inspected for anything that is not on the allow-list.

**Rough size:**

| Phase | Size |
|---|---|
| P0–P1 | 2–3 weeks for one developer |
| P2 | 1–2 days |
| P3 | 1–2 weeks |
| P4 | 2–3 days of drafting, plus counsel review (not priced) |

The clinic's shared count itself is Plan NK (1–2 weeks). Together they are the research's 4–8
weeks for an inventory-only pilot.

## Tests

- `ClinicalStockShareRowTests`:
  - The allow-list guard fails on an added property.
  - Rows aggregate per day, line, lot, kind and reason.
  - No time survives.
  - A waste reason passes through; free text cannot be represented.
- `ClinicalStockInboundGuardTests`: a sheet or feed with a patient-pattern heading is refused for a
  clinical list and accepted for a van; the MY §8 EMR read still drops those columns as before.
- `VanStockServiceClinicalTests`: `jobReference` is nil on a clinical list with an active session.
- `BillingExportReaderTests`:
  - Date and tariff, lot optional.
  - A tariff over two lines is reported as shared and not assigned.
  - Nothing is stored.
- `VanStockStoreHistoryWindowTests`: a clinical list keeps a 1,000-day-old movement and a van list
  folds it; no movement is deleted inside the window.
- `StockSmallCellTests`: a sensitive line reports weekly; a figure below the threshold prints as
  "fewer than N"; the phone's own screen is unchanged.
- `CanadianHealthActTests`: every province and territory has an act, an agreement name, a breach
  recipient and a PIA flag, and Ontario, Nova Scotia, New Brunswick and Newfoundland breaches never
  go to the OPC.
- `HIPAACeilingKeyTests`: each key only tightens (a profile can turn Local Only on, never off), and
  it shows as locked.
- `MedicalComplianceClaimsTests`: the strings named under "What exists" no longer appear, and
  "HIPAA Protected" is gone from the lock screen.
- Every existing stock, org-profile, settings-visibility, catalog and brand guard class, the
  security-regression classes, the full suite and a Release build.

## Decisions for Greig

1. **Shared granularity.** *Recommend:* per day, line, lot, kind and reason (§2). *Alternative:*
   per week, which is safer for a small clinic but too coarse for the daily check against the EMR.
2. **Minute timestamps on the phone.** *Recommend:* keep them. The phone is the clinic's own device,
   and the order of events matters for counts. *Alternative:* fold them to the day once the daily
   check has run, so a device backup holds no times.
3. **Staff.** *Recommend:* none on routine doses. A clinic-local code on waste, adjustments,
   disagreeing counts and cold-chain events, kept on the phone only. *Alternative:* no staff at all
   for the pilot.
4. **Retention.** *Recommend:* four years for a clinical list until the province is known, then the
   province's figure if it is longer. *Alternative:* the province's own figure from the start, which
   for Ontario is only one year.
5. **Small-cell threshold.** *Recommend:* 5 for a clinic-internal report, weekly for sensitive
   lines. *Alternative:* the federal 10/20, which would hide most of a small clinic's lines.
6. **The Canada entry.** *Recommend:* one Canada framework with a province picker over the pure
   table, keeping `.pipeda` for the federal act. *Alternative:* one `MedicalFramework` case per act
   (eleven cases on an already long screen).
7. **P3.** *Recommend:* build it with P0–P1 if the clinic's stock is publicly funded (returns and
   order forms are where the app saves staff time). *Alternative:* defer it until after the pilot's
   first month.

## Open questions for the clinic

The partner is already asking 1–3.

1. Which province? The list's 4-digit tariffs (such as 8161) are not Ontario's G-codes, so
   confirm.
2. Does the EMR store inventory, or can it export a stock or billing report?
3. Does the clinic need patient linkage in the app at all? A yes moves the pilot to Plan NL.
4. Which EMR and version, cloud or installed? Is there a stock module or a published API?
5. Is the stock publicly funded, privately bought, or both, and who supplies it?
6. Is a tariff billed per dose or per vial? Does it bill catch-all codes? Do private vaccines have
   codes?
7. Which vaccines are stocked, and are any sensitive (rabies, travel, HPV, hepatitis B)?
8. Does the clinic want staff named on stock movements at all?
9. How many staff record doses, on clinic-owned or personal phones, and with what device
   management?
10. Is the clinic a physician practice, a group practice, a pharmacy, or a company employing
    nurses? Does it vaccinate under a health-authority contract?
11. Who approves a new app handling clinic data, and does that person need a PIA, Canadian
    residency, SOC 2 or insurance from us?
12. Who keeps the temperature logs, and who reports to the registry and for adverse events, from
    which system?
13. Would support from New Zealand ever need to see clinic data, for example by screen-share?
14. Does the clinic's insurer or college require storage in Canada?

## Not in scope

- **Where the shared count lives:** Plan NK.
- **Anything patient-linked:** Plan NL, only if question 3 comes back yes.
- **Stock lowered by a live EMR feed** (MY §8a). It waits on the EMR's name, an API and the vendor's
  permission. A live per-claim feed into a shared record would cross the line this plan draws.
- **Fridge temperature logging, registry reporting and adverse-event reporting.** These stay in the
  clinic's log book, its EMR and the provincial systems.
- **A certification.** No Canadian act requires one for inventory-only data.

## Risks

- **A shared record that looks inventory-only but is not.** A single-dose drop on a rare product is
  a dose event. §6 and the guard test are the defence. Decision 1 decides how coarse the rows are.
- **The agent-or-supplier question goes the other way.** Then the EMR check needs an agreement
  even for an inventory pilot. P4 asks counsel before the pilot, not after.
- **The rewritten claims weaken a sales line.** They are accurate. The research found that the
  present ones (secure deletion, "no clinical data to cloud providers") would not survive a
  clinic's privacy officer.
- **Province unknown.** The design is province-neutral. Only retention (Decision 4) and the
  Medical Compliance text change with the answer.
