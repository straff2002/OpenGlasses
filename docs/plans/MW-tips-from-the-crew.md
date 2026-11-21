# Plan MW — Tips from the Crew (a short tip pinned to one step of a procedure, in the technician's own words, for the next person who runs it)

**Status:** 📝 Drafted 2026-11-21. Nothing is implemented. 10 decisions, each with a recommendation.
**Track:** Field Assist procedures. Your own vaults first, then company vaults.
**Builds on:** Plan [MN](MN-answers-the-app-can-check.md) (the phone step screen and its save to
the overlay); Plan [MS](MS-editing-a-procedure-on-the-phone.md) P0–P1 (the step sheet, saved
versions, `ProcedureChanges`); Plan [MT](MT-procedure-edit-grants-and-proposals.md) P0–P2 (the seat
grant, `SeatProcedureProposal`, the portal inbox, the shared checks); Plan
[JI](JI-apprentice-support.md) §7a and P6b (talk-through, being built now); Plan
[FP](FP-team-learnings.md) and Plan [JL](JL-procedure-deviations-and-learning-round-trip.md) (team
learnings, and a learning bound to a step); Plan [FO](FO-guided-job-flow-and-job-tab.md) (the job
close and the debrief).

---

## Trigger

The owner: an experienced technician who has just done a job should be able to give a hint back to
the procedure, pinned to a specific step, so the next person who runs it sees it there. Apprentices
most of all. It should use the same approach as editing a procedure.

Today the only way back is a team learning (FP), which names a machine or a practice, not a step,
or editing the procedure, which only an owned vault allows. A tip is smaller than either: it adds a
line to a step and changes nothing else.

## What exists (verified 2026-11-21 on `origin/main` 3e60f44e3)

- **The step format.** Every optional field on `Procedure.Step` is decoded with `decodeIfPresent`
  and left out when encoding. The fields are constants, so `ProcedureRuleEditing`'s copies rebuild a
  step field by field. JI P6b's branch adds `caution_phrases` this way, through those copies.
- **Saving.** `ProcedureAuthoring.save` writes the edited procedure over the same file in the
  vault's overlay. It is refused unless `VaultAuthoring.isOwned` and the validator passes. There
  is no version bump, no earlier copy and no undo: MS adds them.
- **What "owned" means.** `isOwned` is false for My Manuals, any installed pack (every company vault
  is one), a received vault (it has a receipt), a company layer, and a vault that came with the app
  (never installed). So the personal path covers only a vault the technician made or imported.
- **The screens.** `ProcedureStepScreen` shows the title, safety notes and instruction, then the
  answer and the route. The lens card is `ProcedureHUDTaskSource.current`, a `HUDStep` (`title`,
  `instruction`, `safetyNote`, icon, clip). Both read `ProcedureStepPresentation`.
- **The voice.** With no model, `ProcedureVoiceDecider.stepLine` says the step. With the assistant,
  the step reaches the model through `ProcedureRunner.promptContext` and `ProcedureRunnerTool`.
  `HUDRouter` catches "next", "back" and a button's label before the model.
- **Talk-through** (JI P6b branch, one commit so far) documents the hint order in the vault guide:
  `safety_note`, then `expected_input`, then the `calc_ref` hint. JI §7a adds `why` (P6) and the
  figure (MI) after them.
- **The offline queue** (`OpKind`) has no `procedureProposal`: MT adds it.
- **Team learnings.** A `LearningEntry` names a machine or a practice, never a step; JL P2's
  `LearningCandidate.procedure` is unbuilt. Review is on a reviewer's device
  (`LearningReviewService`; screens are FP P4, unbuilt). `LearningCandidateText.clean` checks length
  and control characters and redacts secrets.
- **The job close.** `JobCloseSequence` runs every close. FO's debrief (`DebriefSummary`) is
  written by a model from the conversation, then read back.

## Design

### 1 · The format

An optional `tips` list on a step:

```json
{
  "id": "check_fuse",
  "title": "Check the fuse",
  "instruction": "Remove the lower panel and check the control fuse.",
  "tips": [
    { "text": "The fuse is behind the lower panel. Pull the clip straight out or it snaps.",
      "added": "2026-11-21" }
  ],
  "default_next": "power_on"
}
```

- `text`: the technician's words, one line, at most 200 characters. At most five on a step.
- `added`: the day, `YYYY-MM-DD`, no time (decision 10), kept as written when decoding, so a bad
  value is the checks' issue and never drops the procedure (MN's rule for `runs`).
- Older procedures decode unchanged; a step with none writes no key.
- **The checks** refuse an empty tip, one over 200 characters, a line break, a bad date and a sixth
  tip. They are procedure checks, so they move into `Tools/LicenceIssuance` when MT moves the rest.
- Every copy in `ProcedureRuleEditing` and MS's step operations carries `tips`, as P6b does for
  `caution_phrases`. The vault guide's procedure section documents the field.

### 2 · Where a tip shows

At most two, newest first (by `added`, then the later in the file).

- **Phone step screen:** a line under the instruction, "Tip from the crew: …" on a company vault,
  "Tip: …" on your own. Also on MS's *Try it*.
- **Lens step card:** one line, the newest tip, cut to fit (a new `tip` on `HUDStep`).
- **Talk-through (JI §7a):** the authored hint order gains a last slot for words: safety note,
  expected reading, calculation, reason, then the tip, then the figure (decision 5). On the lens it
  takes a line only when one is free.
- **In the ear,** only when the step has nothing higher-priority to say: no safety note, expected
  reading, calculation or reason, and no answer, read-back or note waiting. Otherwise "any tips"
  reads them, in the app's own voice.
- **Never from a model.** The app shows and speaks a tip as written. It is not in the assistant's
  context (decision 3), so the assistant cannot reword it, and a tip can't steer the assistant.

### 3 · Adding a tip

The words are the technician's. **A model never writes, shortens or rewords a tip** (decision 2).

- **On the phone step screen:** *Add a tip*, a one-line field with a count to 200, and the note
  "Your words go to the next person who runs this step. No names or customer details."
- **By voice, during a step:** "add a tip: …" or "tip for this step: …". The app catches the phrase
  before the model, in both run modes, with or without glasses, in the intercepts where `HUDRouter`
  catches "next". The words after it are kept as recognised; with none, the app asks "What's the
  tip?". It reads back "Your tip for Check the fuse: … Save it?" Yes saves, no asks once more,
  "cancel" drops it. No assistant tool takes a tip's text. MS keeps edits on the screen (its
  decision 10); a tip is the one spoken change, because it only adds and is heard back first.
- **At the end of a job** (decision 6): a closed job that ran a procedure shows *Tips for the next
  person* on its page, listing the steps run. By voice, after a debrief the technician saved
  (FO §6), the app asks once in its own words, "Anything the next person should know about a
  step?", and then "Which step?", matched against the titles of the steps run. It never holds the
  close (`JobCloseSequence`), and it is not part of FO's model-written summary: the answer is kept
  as said. It comes before JI §8's apprentice questions, and it is not an unprompted offer.
- The text goes through `LearningCandidateText.clean`'s rules. Adding a tip writes nothing to the
  job's log, record or report. **The run in progress keeps its version** (decision 7).

### 4 · Your own vault

On an owned vault the tip is saved straight to the overlay through MS's save: the patch number goes
up, the saved copy goes to *History* with "Added a tip on step Check the fuse", and *Restore* or the
step sheet's *Remove tip* undoes it. The screen says "Saved. The next run shows it."

A vault that is neither owned nor a company vault (one that came with the app, one received from
someone, one bought outside a company) offers no *Add a tip* (decision 8).

### 5 · A company vault

The tip is a **one-row change proposal** through MT's pipeline, unchanged: the company's current
version with the tip added, a single change row ("Added a tip on step Check the fuse"), an optional
note, sent as a `SeatProcedureProposal`, queued offline as `procedureProposal`, and reviewed in the
portal's *Proposed changes* inbox. An accepted tip is in the next company version, delivered as LR
delivers any update. Differences from MT:

- **Run seats may offer tips** (decision 1). A tip adds to a step and changes nothing, so a phone
  on *Run* gets *Add a tip* and nothing else. The service checks that a proposal from a *Run* seat
  changes only `tips` (a pure tips-only check in `Tools/LicenceIssuance` beside the procedure
  checks) and refuses anything more. Changing the procedure itself stays *Propose* / *Publish*. A
  company may turn tips from *Run* phones off in the portal.
- **A *Publish* seat's tip publishes** as any of its changes does, unless the company has *Review
  every change* on (MT decision 2).
- **The reviewer may edit the wording** before accepting (decision 9). It is still a tip from the
  crew.
- **Nothing identifies the technician.** No name, job, customer or photo (MT §3); it reads "Tip
  from the crew". The seat's portal label is shown to reviewers only, as in MT.
- **A publisher's vault** takes a tip as a proposal to the publisher, as MT does for any change.
- **On the sender's phone:** "Sent for review. Every phone gets it once it's accepted." The step
  then shows "Your tip is waiting for review" on the phone only, then MT §6's statuses.

### 6 · From team learnings

A reviewer can turn a team learning into a tip: *Make it a tip* on an approved learning opens the
tip sheet with the learning's finding (cut to 200 characters, for the reviewer to edit) and asks
for the procedure and step, since a learning names a machine, not a step. When JL P2 binds a
learning to a step, that step is chosen already. On the reviewer's device (FP P4's screens) the tip
then takes the vault's path from §4 or §5; in the portal it is a proposal like any other (MT §7).
The sheet says a tip shows on every unit the procedure runs on, so a finding about one model stays a
learning. The learning itself is unchanged.

### 7 · Apprentices

A tip from an apprentice's phone goes through review like any other. Whether a tip was shown,
added or sent never appears in an apprentice's logbook, debrief or record, and nothing about it
leaves the phone except the proposal itself (JI §7a's rule). A test pins that.

## Phases

- **P0 — format, checks, display, talk-through slot (headless).** `Procedure.Step.Tip`, the checks,
  the copies, `ProcedureStepPresentation`'s tip lines, the phone line, the lens line, the ear rule,
  the talk-through slot, the vault guide. After JI P6b. **Exit tests:** an older procedure decodes
  and encodes unchanged; none writes no key; each check; every editing copy keeps tips; two newest
  shown; the slot order and the ear rule; no tip in `promptContext` or the tool's step text; no tip
  in a work record, office payload, logbook entry or learning candidate.
- **P1 — adding a tip on your own vault.** The step screen's *Add a tip*, the voice phrase with its
  read-back, "any tips", the closed job's *Tips for the next person* and the post-debrief question,
  the save through MS's version store, *Remove tip* on MS's step sheet. After MS P0–P1. **Exit
  tests:** the phrase is caught before the model in both run modes; the words are kept as
  recognised; yes saves, no asks again, cancel drops; a save bumps the patch and adds a history
  row; *Restore* undoes it; the running procedure is unchanged; refused on a vault that isn't owned;
  the end-of-job question never holds a close and asks only about steps run.
- **P2 — company vaults.** A tip as MT's proposal, the queue op, the statuses, the *Run* seat's tip
  grant on the phone, the tips-only check shared with the service. After MT P1. The service and the
  portal (the *Run* seat check, the company switch, editing a tip's wording, *Make it a tip*) are
  in the private service repository. **Exit tests:** a tip from a *Run* seat is one row and passes
  the tips-only check; any other change from *Run* is refused; the payload carries no name, job,
  customer or photo; queued offline and sent on signal; a publisher's vault sends to the publisher.
- **P3 — catalog.** The new strings in the 13 complete languages, in its own PR.
- **P4 — device pass (owed).** A tip added by voice and by screen, seen on the next run on the
  phone, the lens and in the ear; a *Run* phone's tip accepted in the portal and on a second phone.

P0 is one PR after JI P6b; P1 its own after MS P0–P1; P2 after MT P1; P3 its own; P4 owed.

## Decisions

1. **Run seats may offer tips, checked on the service as tips-only (recommended).** The alternative
   needs *Propose* for a tip, like any change, which leaves most of a crew with no way to pass one
   on.
2. **A tip is the technician's words only, caught by the app, with no assistant tool that takes a
   tip's text (recommended).** The alternative lets the assistant file a tip, which is easier to
   say and lets a model reword it on the way in.
3. **The assistant never sees tips; the app shows and speaks them (recommended).** The alternative
   gives them to the model under KM's read-as-written rule, so the assistant can use them in an
   answer, at the cost of a model sometimes rewording one and crew text in its context.
4. **At most 200 characters, five kept on a step, two shown newest first (recommended).** The
   alternative keeps no limit on a step and shows all, which crowds a step that many people run.
5. **A tip comes after everything the author wrote: safety note, expected reading, calculation,
   reason (recommended).** So in the ear it is heard only on a step with none of those. The
   alternative, as first proposed, puts it straight after the expected reading, ahead of the
   author's calculation and reason.
6. **The end-of-job question is never unprompted: a row on the closed job, and by voice only after
   a saved debrief (recommended).** The alternative asks at every close that ran a procedure, which
   gets more tips and asks a tired technician one more question every job.
7. **A tip shows from the next run (recommended).** The alternative changes the running procedure,
   which would put two versions on one job's record.
8. **No *Add a tip* on a vault you can neither change nor propose to (recommended).** The
   alternative keeps a phone-only tip there, like a kept chain, which only ever helps the same
   phone.
9. **A reviewer may edit a tip's wording before accepting (recommended).** A reviewer is a person,
   and fixing a typo should not mean rejecting a good tip. The alternative is accept or reject
   only, as MT's rows are.
10. **A tip carries the day it was added, with no time (recommended).** The alternative is a
    timestamp, which a reviewer could match to a job and a technician.

## Not in scope

- **Tips for one model or serial.** A tip is for the step on every unit. A finding about one model
  stays a team learning.
- **Photos or clips on a tip.** A picture of a step is MI's figure, which the author adds.
- **Rating, thanking or ranking tips,** and showing who wrote one.
- **Editing a company tip after it is sent.** Send a new one; the reviewer removes the old.

## Risks

- **A wrong tip, spoken to an apprentice.** The company path is reviewed, a tip never replaces the
  safety note and never comes before the author's words, and *History* / *Restore* (MS, MT) take
  one out. A tip that contradicts a safety note should be rejected; the reviewer sheet flags tips
  on a step with a safety note.
- **A tip lost by an older build.** An older editor would save a procedure without the field. Only
  owned vaults are edited on the phone, by the build that wrote the tip.
- **Names and customer details in a tip.** The field's note says not to, secrets are redacted, and
  the company path is reviewed. A tip on a publisher's procedure goes only to that publisher.
