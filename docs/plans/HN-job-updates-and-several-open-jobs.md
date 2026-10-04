# Plan HN — Job Updates from the Office, and Several Open Jobs (one clock at a time)

**Status:** 📝 Drafted (not scheduled) 2026-10-03 — the phases below are not implemented. Phone half
and the message contract; the office half is built in the office's own repository. **2026-10-05:**
§2's message contract is drafted as [`Contracts/job-updates.md`](../../Contracts/job-updates.md)
under Plan [HO](HO-office-delivery-phone-half.md) P3 — the update and the phone's receipt, with a
reference implementation and fixtures; it leaves the reply (§5) and attachments out of its first
version.
**Track:** Field Assist (B2B).
**Related:** Plan [FO](FO-guided-job-flow-and-job-tab.md) (the guided job, its thread, "a paused job
is still the open job"), Plan [HC](HC-jobs-list.md) (the Jobs list and links into a job), Plan
[HB](HB-field-assist-mode-and-job-day.md) (the job-day card), Plan
[FX](FX-desktop-office-and-device-sync.md) (the signed office connection, jobs and receipts), Plan
[T](T-offline-field-queue-and-sync.md) (the offline queue), Plan
[EM](EM-work-record-and-parts.md) (the work record and parts), Plan
[GB](GB-field-test-round-3.md) (billable time and the close sequence), Plan
[HE](HE-recorded-session-action-map.md) (senior review moves to the office).

---

## Trigger

Greig, 2026-10-03, after a paused job adopted an unrelated conversation on his phone (fixed
separately: a paused job now claims nothing until it is resumed, and an open job is shown on the
session card). The follow-on questions were the real ones:

- A technician waiting on a part should hear from the office when it changes, and be able to answer.
- He should be able to leave one job and pick up another, with each job's clock counting only its
  own time.
- Senior engineers spend their day supporting other technicians' jobs in short pieces. Today that
  time is not recorded against any job. Billing for it is a guess.

## Outcome

- **The office can send an update to a job that is already on the phone** — a parts update, a
  schedule change, a note. It is signed, attached to the job and kept in the job's record.
- **The notification is only a notification.** It says there is an update on job 1007. Nothing
  starts, pauses or opens until the technician chooses to.
- **Opening the job to read the update makes it the running job.** Its clock starts; the job that
  was running is paused and its time banked. Reading the update is work on that job, and is billed
  as such.
- **The technician can answer.** A reply goes back to the office from the job, by voice or from the
  job's page, confirmed before it leaves the phone, queued when there is no connection.
- **Several jobs can be open; exactly one clock runs.** Moving between jobs is one action, by tap
  or by voice, and never loses time or records it against the wrong job.
- **A senior's support time lands on the job it was spent on**, in the pieces it was actually spent
  in.

## What exists today (verified against main @ 268cec7a)

- **One job is open at a time.** `FieldSessionService` holds a single `activeSession`. On launch
  `restoreInProgressSessionIfAny()` restores the first unfinished job it finds, paused.
- **Pausing banks time and stops the clock.** `pauseSession()` accumulates billable time, sets
  `pausedAt` and clears the running interval; `resumeSession()` starts a new one. An app close
  pauses at the app's last sign of life (GB P3).
- **A paused job is still the open job** (FO P1, restated in HC): another job cannot start until it
  is finished. HC's "Add new job" with a job open offers Resume, Finish or Schedule — never a
  second open job.
- **A job owns a conversation.** `JobThreadPolicy` decides which saved thread a turn joins while a
  job is open. As of the fix above, a paused job binds nothing and pulls nothing.
- **The office can send a new job**, signed, verified against the organisation, office, enrolment
  and this phone, and receipted (FX contracts, `Contracts/`). There is no message that refers to a
  job already on the phone.
- **Outbound work is queued durably.** Closing a job enqueues its work record on the offline queue
  (`QueuedOp`, EM); report delivery is staged and confirmed before it is sent (GB P0).
- **The office connection is not an inbox.** FX: a relay does not hold messages; both ends need
  connectivity and execution time to exchange anything. There is no vendor push service.
- **A scheduled job can raise a notification and open its page** (HC's `JobListRequest` routing).

## Assessment

Three things are being asked for and they should not be built as one.

1. **Several open jobs** is a change to the phone's job model and needs no office at all. It is the
   part that fixes billing accuracy, and it is the foundation the other two stand on.
2. **An update on an existing job** is a new signed message kind over a connection that already
   carries signed jobs. Most of the verification is FX's.
3. **A reply** is the first free-text message from the phone to the office. It needs the same
   confirm-before-send and queueing the report already has.

The decision that opening a job starts its clock is what makes this useful for billing, and it is
also where the model can go wrong: a clock that starts when a page is opened will start by accident.
The design below makes opening deliberate and makes a short accidental interval cheap to correct,
without softening the rule.

## Design

### 1 · Several open jobs, one running

- `FieldSessionService` keeps a set of open jobs and at most one **running** job. Every other open
  job is paused. "The open job" in FO and HC becomes "the running job"; a paused job is open but
  not running.
- **Switching is one operation**, `switchTo(jobId:)`: bank the running job's time and pause it,
  then resume the target. It either completes or changes nothing. A crash between the two halves
  restores both jobs paused, with time counted to the app's last sign of life, as today.
- Each job keeps its own vault, equipment, procedure position, staged figure and conversation
  thread. Switching swaps all of them together. Nothing from one job's context is visible to the
  model while another is running.
- **Every interval is recorded**: when it started, when it ended, and why it started (started,
  resumed, switched to, opened from an update). Billable time is the sum; the intervals are what a
  senior's invoice or a dispute is answered from.
- Finishing a job closes only that job. The close sequence (checks owed, evidence, sign-off) is
  unchanged and runs per job.
- A sensible bound on open jobs (an organisation setting, default a handful) so a phone does not
  quietly collect a dozen forgotten jobs. Reaching it offers the list of open jobs, oldest first.
- Voice: "switch to job 1007", "which jobs are open?", "pause this job". Switching by voice reads
  back the job it is switching to before it does so when the number was recognised, not chosen.

### 2 · A job update is a signed message about a job the phone already has

- A new closed schema beside the job message: organisation, office, enrolment, phone identity, the
  **job's id**, a sequence number within that job, a kind, a body, optional structured fields, and
  attachments with declared lengths and digests. Verified exactly as a job is. An update for a job
  the phone does not hold, or holds as finished, is receipted as such and not shown as live.
- **Kinds, closed:** `parts` (part, quantity, state — ordered, dispatched, arrived, substituted,
  unavailable — and an expected date), `schedule` (a new time or window), `note` (text). A kind the
  phone does not know is kept and shown as a plain note, never dropped.
- **Information only in the first cut.** An update does not edit the job. A schedule update shows
  the new time and offers to apply it; a parts update is shown against the parts the job already
  lists. Changing a job's scope stays a new signed job message.
- The body is untrusted text for the model's purposes: it is read out and shown, and is never
  treated as an instruction.
- Each update is written to the job's record when received and again when first opened, so the
  record shows what the technician knew and when.

### 3 · The notification is only a notification

- When an update is received and committed, the phone raises a **local** notification: the job's
  number and the kind — "Job 1007: parts update". No body text on the lock screen by default (an
  organisation may allow it).
- It arrives when the phone and the office next exchange, not instantly. With no vendor push
  service, a phone that is asleep and off the office's network hears nothing until it reconnects.
  The plan says so in the office's UI as well: sent, delivered, opened are three different states.
- The job's row in the Jobs list and the session card's job pill show an unread mark. Nothing else
  changes. The running job keeps running.

### 4 · Opening the job reads the update and starts its clock

- Tapping the notification, or the job's row, opens the job. If it is not the running job, the
  phone shows one confirmation that says what will happen: "Open job 1007? Job 1009 will be paused."
  Confirming switches (§1), marks the update opened, and shows it — and, in a voice session, reads
  it out.
- The confirmation is the guard against a clock started by accident. There is no "peek" that reads
  the update without switching: Greig's decision is that reading an update is work on that job.
- An interval that began from an update and ended within a short threshold with nothing said or
  done is kept in the record but marked so, and the job's page offers to discard it. The rule is
  not weakened; an obvious mis-tap is cheap to undo.
- With no job running, opening simply resumes that job.

### 5 · The reply

- From the update: **Reply**. By voice: "tell the office I need the three-eighths valve as well."
  The draft is read back and shown; it is sent only on confirmation, as a report is.
- A reply is a signed message from the phone carrying the job's id, the update it answers if any,
  text, and optional photos already attached to the job. It goes on the offline queue and shows on
  the job as pending, then sent, then received by the office.
- Replies and updates are one thread on the job's page, in order, separate from the job's
  conversation with the assistant. Both are in the job's exported record.

### 6 · The senior engineer

- Nothing in §1–§5 is specific to a senior, and that is the point: a senior helping on six jobs in
  a day has six open jobs and switches between them. Each switch is an interval on the right job.
- A support request from another technician arrives as a job update on a job the senior has been
  given, or as a new job of kind "support" referring to the other technician's job. Which of the
  two is an open question below; the phone model is the same.
- The record distinguishes who worked the interval, so one job can carry the technician's time and
  the senior's.

## Phases (one PR each)

- **P0 — Several open jobs, headless.** The job set, `switchTo`, per-job context swap, interval
  records, restore of several paused jobs, the bound. `JobThreadPolicy` inputs become per job.
  Pure policy first; no UI beyond what tests need.
- **P1 — Switching on the phone.** Jobs list shows open jobs with the running one marked; the
  session card pill names the running job; the switch confirmation; voice actions on
  `field_session`. HC's "Add new job" stops requiring the open job to be finished.
- **P2 — The update contract and receipt.** Schema, fixtures and verifier in `Contracts/`; the
  phone's durable store for updates; record entries. No UI, no notification.
- **P3 — Notification, unread, open-to-read.** Local notification, routing into the job, the
  switch-and-show step, read-out, the short-interval discard.
- **P4 — Reply.** Draft, confirm, sign, queue, states on the job's thread, export.
- **P5 — Device and office pass.** Two phones and an office: delivery while backgrounded, after a
  route change, after a day offline; intervals against a stopwatch.

P0 and P1 are useful with no office and should ship on their own.

## Tests

- Switching: time banked to the right job across switch, pause, app close, crash between the two
  halves, and clock changes; no interval overlaps another on the same phone.
- Context isolation: after a switch, the prompt, tools' working state and thread are the target
  job's and contain nothing of the other's.
- Restore with several open jobs: all paused, none running, none claims a conversation.
- Update verification: wrong organisation, office, enrolment or phone; unknown job; finished job;
  replayed or out-of-order sequence; bad digest; unknown kind kept as a note.
- Notification routing: opens the right job from cold launch and from background; unread cleared
  only by opening.
- Open-to-read: confirmation wording names both jobs; declining changes nothing and starts no
  clock; the short empty interval is marked and discardable.
- Reply: nothing leaves without confirmation; queued offline and sent once; pending/sent/received
  states; present in the export.
- Update text containing instructions is read out and not acted on.

## Risks

- **Clocks started by accident.** The confirmation and the discardable short interval are the
  mitigation; device testing has to show they are enough.
- **Delivery that looks instant and is not.** Without a push service an update can sit for hours.
  The office must show delivered and opened separately, or it will be assumed read.
- **Context bleed between jobs.** One customer's readings on another's record is the failure that
  matters most. P0's isolation tests are the gate.
- **Model size on the phone.** Per-job context swap must not reload a vault index on every switch
  if the two jobs share a vault.

## Out of scope

- Editing a job from an update (scope, address, parts list). A new signed job message does that.
- A vendor-hosted push or inbox service.
- Technician-to-technician messaging that does not go through the office.
- Rates, invoicing and what a senior's interval is charged at. The phone records time; the office
  prices it.

## A related direction: the office on an iPad, for senior support

Not part of this plan; recorded here because it came up with it and shapes §6.

Greig, 2026-10-03: seniors who support many technicians will move to the office application, and
it would be useful for that to run on an iPad. That is a different thing from the office an
administrator runs:

- It is a **device with support functions**, not an administrator's console: see the jobs a senior
  is supporting, read their records and updates, answer, and have that time recorded per job.
- It must be **multi-user**: several seniors may share one iPad, none of them administrators. Each
  needs their own identity for signing replies and for whose time an interval is.
- It holds organisation data, so it needs the same enrolment, binding and revocation the phone and
  the office have, and a clear answer to what stays on the iPad when a senior signs out.

Whether this is the office application built for iPad, or the phone app with a support role, is
the first question, and it belongs in a plan of its own once P0–P1 here show what a senior's day of
switching actually looks like.

## Open questions

1. **Does the office see "opened"?** The design records it on the phone. Sending it to the office
   is useful and is also a read receipt on an employee.
2. **A senior's support: an update on the technician's job, or a support job of its own?** The
   first keeps one record per job; the second keeps the senior's time separable without filtering.
3. **The bound on open jobs**, and whether an organisation may raise it.
4. **The short-interval threshold** for offering a discard, and whether discarding needs a reason.
5. **Lock-screen text**: job number and kind only, or may an organisation allow the body?
6. **May a technician start an update thread**, or only reply to one? "Tell the office" with no
   update to answer is the obvious next request.
