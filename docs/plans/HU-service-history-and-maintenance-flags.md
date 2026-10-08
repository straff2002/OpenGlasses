# Plan HU — Service History on Request, and Maintenance Flags (what the office knows about this unit reaches the technician)

**Status:** 📝 Drafted 2026-10-08 — nothing implemented. Phone half only: the office compiles the
history from its field service management system (FSM) and computes the flags with a
deterministic rule engine in office plan FX21 (private); the phone reads, briefs and answers from
what the signed job file carries, offline, and computes nothing.
**Track:** Field Assist (B2B).
**Related:** Plan [HT](HT-external-job-references.md) (format 3 and the `external` block this rides
beside), Plan [FO](FO-guided-job-flow-and-job-tab.md) (the brief before site, §7), Plan
[HB](HB-field-assist-mode-and-job-day.md) (Field Assist mode and the job-day card), Plan
[HC](HC-jobs-list.md) (the job's page), Plan [FP](FP-team-learnings.md) (the crew's learnings, a
separate section on purpose), Plan [HD](HD-report-transcript-audience.md) (who a report is for),
Plan [EM](EM-work-record-and-parts.md) (the work record), Plan
[EL](EL-equipment-identity.md) (the unit in front of the technician), Plan
[HO](HO-office-delivery-phone-half.md) (office delivery), and office plans FX20 (learnings) and
FX21 (FSM connectors, history and flag rules).

---

## Trigger

The same pilot conversation as [HT](HT-external-job-references.md). Two asks beyond the job itself:

- **Service history on request.** "What was done on this unit last time? Has this compressor been
  replaced before?" answered from the business's own records, by equipment, without the
  technician opening another app.
- **Preventive-maintenance insight.** A unit that keeps failing the same way, or keeps eating the
  same part, should be flagged before the next breakdown, not discovered after it.

The brief before site already has a "Site and history" section. It only knows this phone's own
finished jobs, and says so: "no earlier visit on this phone". The organisation's real history is
in its FSM, and Avenkin Office is the only thing that can reach it.

## Outcome

- **A job file may carry a `history` block**: for each unit on the job, by serial, the office's
  record of earlier visits, bounded and dated, and any maintenance flags the office's rules raised.
- **The brief merges it in, with provenance.** "From the office: 3 earlier visits, as of 7 Oct" is
  never confused with "on this phone".
- **Flags are said once, at the start of the job,** and stay on the brief and the job's page.
- **A `service_history` tool** answers "what was done last time" from that block only, offline,
  always naming the date it is as of and where it came from, and says plainly when nothing is on
  file.
- **It stays internal.** History never reaches the work order, the customer's summary or the
  sign-off, and it is not added to the wearer's personal memory.

## What exists today (verified against main @ 447d35ec)

- **The brief is assembled, never written by a model.** `JobBriefAssembler.assemble` builds five
  `JobBrief.SectionKind`s in a fixed order (`siteAndHistory`, `knownEquipment`, `faultCandidates`,
  `crewLearnings`, `partsAndPrerequisites`); `JobBrief.init` forces exactly those five. Every
  `JobBrief.Item` has a `text` and a `citation`.
- **History is this phone's only.** `JobHistoryIndex(sessions:)` indexes finished, non-cancelled
  sessions and "has no store, no network and no notion of another device". `matches(for:)` finds
  visits by site (`siteKey`), serial (`normalised`) and model (`modelTokens`), keeping the strongest
  `MatchReason`. `siteItems` names at most `visitLimit = 3`, each cited "Job 0993, 14 May 2026 —
  this phone's job history". The empty line is "Nothing on file about the site, and no earlier
  visit on this phone."
- **Learnings are a separate seam.** `Inputs.learnings` is empty until FP exists; `learningItems`
  meanwhile reads this phone's follow-ups and debrief notes, capped at `learningLimit = 6`.
- **How the brief is heard.** `GuidedJobFlow.briefAloud` assembles and speaks
  `JobBriefSpeech.spoken` (about 900 characters, two items a section). It is reached from the job
  ahead's page, the `field_session` tool's `brief_next_job` action and CarPlay. A job ahead is
  started only from its page (`UpcomingJobViews`), which speaks `GuidedJobFlow.startedLine(for:)`.
  `applyJobAhead` copies the job's site, fault report, brief, provenance and needs onto the session.
- **What the model sees.** `JobBriefContract.lines` puts the brief in the session's continuity
  snapshot as quoted lines with sources, bounded at `characterLimit = 1_200`, under a lede saying
  none of it is a task, a reading or a diagnosis.
- **The job file is strict and small.** See HT: closed member sets, 64 KiB per file
  (`JobFile.maximumBytes`, `OfficeManagedJob.maximumJobBytes`), so about 48 KiB of job bytes in
  format 2's base64 wrapping. Format-1 fields at their limits take about 9 KiB.
- **Field tools are gated four ways.** `NativeToolRegistry` registers Field Assist tools only under
  `Config.fieldAssistActive` (switch and entitlement), and each re-checks it in `execute`
  (`PartsRequestTool`). `FieldToolProfile.names` is the allow-list offered during a job.
  `OfflineToolPolicy` classifies every tool (`equipment_lookup` is `.local`). Tools declare
  `executionSemantics` (`ToolEffectClassification.swift`, `.read()` for read-only).
  `AIFeatureGate.disabledFeature(forTool:)` refuses a tool whose `AIFeatureRegistry` record is
  switched off; the `.fieldAssist` record lists only `field_session` today. The prompt's tool list
  is generated from each tool's `description` (`SystemPromptBuilder.toolLines`).
- **The customer's view is an allow-list.** `CustomerSummary.lines` prints only work done, parts
  used and time. The work order PDF prints `WorkRecord.summaryLines` whole and is treated as the
  customer's document (HD); `ReportTranscriptPolicy` keeps the transcript off it for everybody.
  The brief is on the session but in neither the work record nor `SessionExport`.
- **Nothing in Field Assist feeds the personal brain.** `BrainStore.shared.ingest` is called from
  memory, meeting, parking, reading, social and badge paths; no file under `Services/FieldAssist`
  or `Services/OfficeSync` calls it.

## Assessment

Two decisions shape the rest.

**The phone does not compute flags.** A recurring-failure rule needs the whole history of a unit,
across technicians and years, which only the FSM has. Computing on the phone from a ten-visit
window would produce confident patterns from too little evidence. The office's rule engine
(FX21) is deterministic, can show its evidence, and can be fixed once for every phone. The phone's
job is to say what the office flagged, with the office's evidence, as the office's.

**History rides the job file, not the `bulk` folder.** A larger history could follow a job as a
bulk attachment (`Contracts/office-bulk.md`), but bulk is paused by default and fetched on request,
and the history is most needed in the van, offline, before site. Inline, it is covered by the
job's signature and arrives with the job. The price is a hard size bound, which is also what keeps
a brief readable. If 24 KiB proves too small in the pilot, bulk is the next step, not a bigger
job file.

## Design

### 1 · The `history` block (format 3)

One optional member of the format-3 job HT introduces. Plain text under `checkText` rules.

```json
"history": {
  "as_of": "2026-10-07T18:00:00Z",
  "units": [
    { "serial": "5919K01234",
      "visits": [
        { "date": "2026-05-14", "job_number": "0993", "summary": "No heat, E200.",
          "findings": ["Inducer bearing noisy"], "parts_replaced": ["Inducer motor 14T65"],
          "technician_initials": "JR", "source": "servicetitan" } ] } ],
  "flags": [
    { "kind": "replacement_pattern", "unit": "5919K01234",
      "text": "Inducer motor replaced twice in 14 months.",
      "evidence": ["0871", "0993"], "severity": "warning" } ]
}
```

- `as_of` (required): when the office compiled it, ISO 8601. Every spoken or shown use says it.
- `units[].serial` (required): must equal a `serial` in the job's `equipment`. A unit with no serial
  carries no history (open question 3).
- Visit members: `date` (ISO 8601 date, required), `summary` (required, ≤ 600), `job_number` (≤ 64),
  `findings` (≤ 6 × 200), `parts_replaced` (≤ 8 × 80), `technician_initials` (≤ 4 letters),
  `source` (a token `[a-z0-9_-]{1,32}`, as HT's `system`). Newest first.
- Flag members: `kind` one of `recurring_failure`, `replacement_pattern`, `overdue_maintenance`,
  `recall_or_bulletin` (an unknown kind refuses: the review would not be the whole truth);
  `unit` (a serial in `units`); `text` (≤ 240); `evidence` (≤ 10 job numbers); `severity` `info` or
  `warning`.
- **Bounds:** ≤ 10 visits per unit, ≤ 3 flags per unit and ≤ 12 in all, each visit ≤ 2 KiB encoded,
  and the whole member ≤ 24 KiB. Over any bound the job is refused with a sentence; the office
  trims, the phone never truncates. With HT's 2 KiB `external` and format 1's fields at their
  limits, the job stays under the 48 KiB the 64 KiB file allows.
- **Authored only by the office.** A history block or a flag is never created, edited or inferred
  on the phone.

The job-file contract's §10 (HT) gains the block; the Go `jobfile` package and a signed fixture
`job-file-v3-history.ogjob` change with it. If HT and HU land apart, HU's addition to format 3 is
made under §9.1 only while no released phone reads format 3; otherwise it is format 4.

### 2 · The model on the phone

- `OfficeServiceHistory` (`Codable`, `Equatable`, `Sendable`): `asOf`, `units: [Unit]`,
  `flags: [Flag]`, decoded from the validated job.
- `UpcomingJob.officeHistory` (decoded with `decodeIfPresent`, so every saved job loads), copied to
  `FieldSession.officeHistory` by `applyJobAhead`, and **cleared when the job closes.** The record
  does not need it, and organisation data should not outlive the visit on the phone. What the
  technician actually heard stays in `session.brief`, as today.
- The session log records counts only (`office_history_units`, `office_flags`), never the text.

### 3 · The brief

- `JobBriefAssembler.Inputs` gains `officeHistory: OfficeServiceHistory?`. `JobHistoryIndex` is
  unchanged: it stays "this phone's", and the office's history is a second source beside it, never
  merged into it.
- **Site and history** keeps this phone's visits first, then the office's: up to
  `officeVisitLimit = 3` lines, newest first across the job's units, each cited
  "Office service history (ServiceTitan), as of 7 Oct 2026" from `external.system_name` when HT
  supplied one, else "Office service history, as of …". More than three adds one line: "And 4 more
  earlier visits from the office: ask for the service history."
- **One visit, once.** A phone visit and an office visit with the same job number on the same
  serial is shown as the phone's line with "(also in the office's history)".
- The empty line becomes "Nothing on file about the site, no earlier visit on this phone, and no
  history from the office."
- **Flags are not a sixth section.** `JobBrief` keeps exactly five; flags are a new optional
  `JobBrief.flags: [JobBrief.Item]?` (absent in every brief written before, so they decode
  unchanged), each `text` prefixed by its kind in words ("Replacement pattern: …") and cited
  "Flagged by the office, as of 7 Oct 2026 (evidence: jobs 0871, 0993)".
- **Learnings stay separate.** `crewLearnings` and FP's `Inputs.learnings` are untouched. A
  learning is what the crew found about a model; history is what happened to this unit.

### 4 · Hearing the flags

- `JobBriefSpeech.spoken` reads `warning` flags straight after "Brief for Job 1007.", before the
  sections, two at most and "and N more flags". `info` flags are on the page and in "say more about
  history", not read unprompted.
- **Once at the start.** `GuidedJobFlow.startedLine(for:)` becomes `startedLines(for:)`: the
  existing line, then each `warning` flag in one sentence. An `officeFlagsSpoken` log event records
  that they were said, so resuming the job does not repeat them.
- `JobBriefContract.lines` adds `OFFICE FLAG:` lines among its protected lines, inside its 1,200
  characters, under one more sentence of lede: these are the office's flags with its evidence, not
  a diagnosis, and the history they cite is internal.
- The job's page shows flags above the brief. The Jobs list and the job-day card gain no badge in
  this plan (open question 4).

### 5 · The `service_history` tool

- `ServiceHistoryTool: NativeTool`, `name = "service_history"`, `executionSemantics = .read()`.
- Parameters: `unit` (a serial, a model, or omitted for the unit in front of the technician) and
  `about` (a word to look for: "compressor", "inducer").
- **Source:** the open job's `officeHistory`; with no job open, the next job ahead's
  (`GuidedJobFlow.nextUpcomingJob`), and the answer names which job. Nothing else: no FSM, no
  network, no model call.
- **Which unit:** a named serial or model resolved against the job's `equipment`; omitted, the
  active unit's serial from `identityFields` or `visitedUnits`; if that is unknown and the job has
  one unit with history, that one; if several, the tool lists them and asks.
- **The answer is deterministic text** that starts with its provenance: "From the office's service
  history for serial 5919K01234, as of 7 Oct 2026:" then the matching visits newest first, then any
  flags. `about` filters visits by word over summary, findings and parts. The description tells the
  model to keep the as-of date and the source in anything it says.
- **Nothing on file is said:** "The office sent no service history for this unit with Job 1007."
  When this phone's `JobHistoryIndex` has visits for it, one more sentence points to them in the
  brief; the tool never presents them as the office's.
- **Gating, as every Field Assist tool:** registered inside the `Config.fieldAssistActive` block,
  re-checked in `execute`, added to `FieldToolProfile.names`, `.local` in `OfflineToolPolicy`, and
  listed in the `.fieldAssist` record's `toolNames` so its switch refuses it through
  `AIFeatureGate`. Its description is written to stand alone, since `SystemPromptBuilder` lists it.

### 6 · Audience and privacy

- **Internal, always.** History text may name customers, addresses and colleagues. Nothing in
  this plan adds it to `WorkRecord`, `WorkRecord.summaryLines`, `CustomerSummary`, the sign-off,
  the PDF, `SessionExport` or any `QueuedOp`. The block does not go back to the office: it came
  from there.
- **The residual risk is the model.** It can repeat history in a turn (the transcript, governed
  by `ReportTranscriptPolicy`, never on the PDF) or copy it into a task title, which the PDF does
  print. The brief lede and the tool description say not to; P1 adds a test that no app-assembled
  record path carries history text, and P2's device run checks the model's behaviour.
- **Not the personal brain.** Office history is not passed to `BrainStore.shared.ingest`. It is
  the organisation's data, delivered on a signed job under an enrolment it can revoke; once in the
  wearer's personal graph it would outlive the job, the enrolment and the organisation's say over
  it, and would surface in non-work conversations. FP and FX20 are the route for what the crew
  learns; this is not that.

## Phases (one PR each)

- **P0 — Contract, model, fixture (headless).** The `history` member in format 3,
  `OfficeServiceHistory`, the validator's rules and bounds, `UpcomingJob`/`FieldSession` fields,
  clear-on-close, the Go package and signed fixture, contract §10.
- **P1 — Brief merge.** Inputs, office visit lines and their citations, de-duplication, the empty
  line, `JobBrief.flags`, `JobBriefContract` lines, the job's page, the privacy assertions.
- **P2 — The tool.** `ServiceHistoryTool`, its gating, offline class and semantics.
- **P3 — Spoken flags.** `JobBriefSpeech` ordering, `startedLines(for:)`, the `officeFlagsSpoken`
  event and no repeat on resume.
- **Device check owed:** a job from a real office with history for two units and one warning
  flag; the brief read in the van with no signal; the flag said once at Start and not on resume;
  "has the inducer been replaced before?" answered with its date and source; the work order and the
  customer summary free of history.

## Tests

- `OfficeServiceHistoryValidationTests` — a valid block decodes; every bound refuses (visits, flags,
  per-visit size, member size, text lengths); a `units[].serial` not on the job refuses; a flag for
  a unit not in `units` refuses; an unknown flag kind or severity refuses; a bad `as_of` or visit
  date refuses; `history` in format 2 refuses; the signed fixture verifies.
- `JobBriefOfficeHistoryTests` — office lines after this phone's, cited with the as-of date and
  source; the limit and the "more" line; the shared-job-number de-duplication; the new empty line;
  a job without a block assembles byte for byte as before; `JobHistoryIndex` never contains an
  office visit.
- `JobBriefFlagsTests` — flags carried with kind and evidence; a brief encoded before `flags`
  existed decodes; `JobBriefContract.lines` keeps flags inside its limit; `info` flags not spoken,
  `warning` flags first.
- `JobStartFlagSpeechTests` — `startedLines(for:)` includes warning flags once; resume says
  nothing more; the log records counts only.
- `ServiceHistoryToolTests` — answers for a named serial, a model, the active unit, and the next
  job ahead; filters by `about`; lists units and asks when ambiguous; says nothing is on file;
  refuses with Field Assist off; never calls the network (an injected source only).
- `FieldToolProfileTests`, `OfflineToolPolicyTests`, `ToolEffectClassificationTests` (extended) —
  the tool is offered during a job, local offline, and declared read-only.
- `OfficeHistoryAudienceTests` — with history on the session, `WorkRecord`, `summaryLines`,
  `CustomerSummary.lines`, `SessionExport` JSON and the rendered PDF text contain none of its
  strings; the history is gone from the session after close.

## Risks

- **Stale history read as current.** Every use carries `as_of`. A job ahead for a week still says
  the date it was compiled.
- **The office's rule was wrong.** A flag is said as the office's, with its evidence, and never
  as a diagnosis; the technician can open the evidence jobs' lines in the history.
- **A long history crowding the brief.** Three office visits shown; the tool has the rest.
- **Text copied into the work order by the model.** Covered above; it is the one path tests cannot
  close, so the device run looks for it.

## Out of scope

- Computing flags or patterns on the phone, from any source.
- Any call from the phone to an FSM or to the office to fetch more history.
- The office's rule engine, its thresholds and its FSM queries: office plan FX21.
- Sending the technician's findings back as history. They already travel in the work record;
  the office turns them into FSM history.

## Open questions

1. **Bounds.** Ten visits a unit and 24 KiB in all are guesses until the pilot's units are seen.
2. **Clear on close.** The plan drops the raw block when the job closes. Should a finished job's
  page still show what the office sent?
3. **Units without a serial.** Allow history keyed by the FSM's equipment identifier from HT's
  `equipment_ids`, or by model, when the job's unit has no serial?
4. **A flag mark on the Jobs list and the job-day card** before the job is opened?
5. **Live sessions.** `LiveJobContract.jobToolNames` is `field_session` and `equipment_lookup`.
  Add `service_history`, or fold it into `field_session` as an action so live sessions get it?
6. **A phone removed from the organisation.** Jobs ahead, and so their history, are not touched
  by a removal today. Should a removal erase office-supplied history on jobs ahead?
