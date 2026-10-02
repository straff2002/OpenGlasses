# Plan HL — Revision Impact (what a changed manual touches)

**Status:** 📝 Drafted (not scheduled) 2026-10-03 — nothing implemented. Depends on Plan
[HK](HK-controlled-document-revisions.md) P0 + P1.
**Track:** Field Assist (B2B).
**Related:** Plan [HK](HK-controlled-document-revisions.md) (revisions and notices — this plan's
input), Plan [FO](FO-guided-job-flow-and-job-tab.md) (`JobHistoryIndex`, the brief, upcoming jobs),
Plan [EL](EL-equipment-identity.md) (`VaultModelIndex`), Plan [EM](EM-work-record-and-parts.md)
(the work record), Plan [HC](HC-jobs-list.md) (the Jobs list and what is owed), Plan
[FX](FX-desktop-office-and-device-sync.md) (the connection to the office), Plan
[HD](HD-report-transcript-audience.md) (office versus customer).

---

## Trigger

Greig, 2026-10-03: knowing a manual was replaced is half of change control. The other half is
knowing what the replaced one already touched — the job booked for tomorrow on that model, the job
finished last week that followed the old torque figure — before the next job starts, not after.

## Outcome

- **When a document is replaced or withdrawn, the phone says what it affects on this phone:** open
  job, scheduled jobs, and finished jobs that relied on it.
- **The Jobs list marks them.** A scheduled job on affected equipment and a finished job that cited
  the replaced document each carry a mark and one line saying why.
- **The office gets the same answer for the whole crew** as a signed report from each phone, so a
  person there can decide what needs a call-back.
- **Nothing is reopened or rescheduled by the app.** It reports; a person decides.

## What exists today (verified against main @ f2f49220)

- **Finished jobs are indexed, but not by what they cited.** `JobHistoryIndex` reduces each
  finished visit to models, serials, site, work done and follow-ups, matched by serial, site or
  model. It holds no citations.
- **Citations are recorded per session.** `SessionLogger` writes `citation` and `citation_opened`
  events, and `SessionExport.Citation` carries them into the export. HK adds the revision and the
  document's content hash.
- **Scheduled jobs name their equipment.** `UpcomingJob.equipment` is a list of `KnownEquipment`
  with optional `model` and `serial`.
- **A model resolves to a document.** `VaultModelIndex` maps model tokens to the vault headings
  that cover them.
- **The Jobs list already badges what is owed** through `JobDayComposer.owed`, shared with the
  job-day card.

## Design

### 1 · A footprint index

`RevisionFootprintIndex` — pure, rebuilt from the sessions and upcoming jobs it is handed, in the
same shape and with the same limits as `JobHistoryIndex` (no store, no network, this phone only).
For a document content hash it answers three questions:

| Question | Source | Strength |
|---|---|---|
| Which finished jobs **cited** it? | Citations carrying `document_hash` (HK P1) | `cited` |
| Which finished jobs **ran a procedure** from it? | Procedure events and the procedure's hash | `followed` |
| Which open or scheduled jobs are **on equipment it covers**? | `UpcomingJob.equipment` and the open session's equipment, through `VaultModelIndex` | `covers` |

A finished job recorded before HK has no hashes. It is matched by document title only, reported at
a fourth strength, `titleOnly`, and always worded as uncertain.

### 2 · What the technician hears and sees

When a notice arrives (HK §2) and the footprint is not empty, the announcement gains one sentence:
*"It affects the job you have open and two scheduled this week. One finished job cited it."* Asked
"which ones?", the app reads them, soonest first.

On the Jobs list, each affected job carries a mark and a line:

- Scheduled: "Manual updated — RTU-500 Service Manual, now revision C."
- Finished, `cited` or `followed`: "Cited revision B, since replaced. The office has been told."
- Finished, `titleOnly`: "May have used a manual that was since replaced."

The mark clears on a scheduled job once the replacement is installed, and on a finished job when
the technician or the office dismisses it. It is never an item the technician owes: it does not
enter `JobDayComposer.owed`, because the decision belongs to the office.

A withdrawal is worded more strongly than a replacement, and its mark does not clear on its own.

### 3 · The report to the office

Each phone sends one signed **impact report** per notice over the FX connection: the notice it
answers, and for each affected job its reference, date, strength and — for `cited` — the page.
No transcript, no claim text and no customer details beyond the job reference, following HD's
office-versus-customer split. A phone with an empty footprint still reports, so the office can tell
"nothing affected" from "not heard from".

The report's schema and fixtures live in `Contracts/`. What the office does with the reports —
collating them across the crew, raising call-backs — is specified by the contract and built
elsewhere.

### 4 · Narrowing by section (deferred)

A replaced manual usually changes a few pages. Once both revisions are on the phone, their
structured headings (EK) can be compared: a section whose text is unchanged between revisions
drops out of the footprint, so "one finished job cited it" becomes "one finished job cited section
7.3, which changed". This needs both revisions present and a stable section identity, so it waits.

## Phases

- **P0 — the index.** `RevisionFootprintIndex` and its four strengths. Pure.
- **P1 — the technician's view.** The extra sentence on the announcement, "which ones?", and the
  marks on the Jobs list.
- **P2 — the report.** The signed impact report, its contract and fixtures, sent once per notice
  and retried through the existing queue.
- **P3 — by section.** Deferred as described.

## Tests

- A finished job that cited the hash appears as `cited`; one that ran a procedure from it as
  `followed`; neither appears for a different hash.
- A scheduled job whose equipment model resolves to the document appears as `covers`; one with no
  model, or a model the vault does not know, does not.
- A pre-HK session matches by title as `titleOnly` and is worded as uncertain everywhere.
- The index never includes a job from another device, whatever it is handed.
- A scheduled job's mark clears when the replacement installs; a withdrawal's does not.
- The mark never appears in `JobDayComposer.owed`.
- The impact report contains job references, dates, strengths and pages, and no transcript, claim
  or customer field; an empty footprint still produces a report.
- A report is sent once per notice and survives a restart before the office acknowledges it.

## Out of scope

- Reopening, rescheduling or flagging a job as non-conforming. The app reports; a person decides.
- Anything across devices on the phone. The crew-wide view is the office's.
- Parts. A superseded part number is a different record with different sources.

## Open questions

1. Should a customer-facing report ever mention that a cited manual was later replaced, or is that
   for the office alone?
2. How far back does the footprint look by default — every stored job, or a bounded window an
   organisation can set?
3. Does a solo technician, with no office to report to, want the marks at all?
