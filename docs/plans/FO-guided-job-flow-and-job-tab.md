# Plan FO — Guided Job Flow and the Job Tab

**Status:** Drafted 2026-09-21. Nothing in this plan is implemented. The voice-turn reliability fixes
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
the record and offers delivery. None of this requires knowing what a "chat", "thread" or "session
id" is.

## Verified starting point (main @ build 408)

- `FieldSession.jobReference` exists, persists, and flows into `WorkRecord`, delivery file names
  and summaries. `FieldSessionTool` has `set_job_reference` (added in #521). `startSession(…,
  jobReference:)` accepts one, but the tool's `start` action never passes it and its reply
  ("Started … Session id: 1a2b3c4d.") neither asks for a job number nor tells the model to. Whether
  the technician is asked is left to the model's initiative.
- `FieldSession` has **no link to a conversation thread**. A saved thread lives exactly as long as
  `AppState.inConversation`; `returnToWakeWord()` ends it. The only coupling is
  `FieldSessionService.recordConversationTurn`, an event-log dedup hook. (The accompanying fix adds the
  narrow rule "don't end the saved thread while a field session is active"; this plan replaces that
  rule with an explicit binding.)
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

## Phases (one PR each)

- **P0 — inventory and seams.** Map every place a thread is started/ended and every entry point
  that starts/ends a field session (tool, quick action, Siri/App Intents, CarPlay, watch, offline
  queue restore). Typed tab identifier refactor with no visible change. Output: the inventory in
  this doc + the refactor.
- **P1 — deterministic core, headless.** `JobThreadPolicy`, `JobIntakeState`,
  `JobChangeDetector`, the `FieldSession` field + migration test, `FieldSessionTool.start`
  accepting `job_reference`. Wired into Direct mode. Tests are the gate: thread continuity across
  wake-word cycles and app restart; intake including declined and misheard-digits read-back;
  change detector corpus (same model different serial, accessory vs unit, low-confidence read);
  compaction does not lose intake/change state.
- **P2 — Job tab.** The three states above over existing components; thread titling; past-jobs
  list. Snapshot/UI tests with Field Assist off (tab absent) and on.
- **P3 — live sessions and other surfaces.** Gemini Live / OpenAI Realtime parity via their
  context snapshots; HUD cue for the two questions; CarPlay/watch read-only job state.
- **P4 — device acceptance (owed to a pilot run).** One real job end-to-end by a technician who
  has not been coached: start by voice, number captured, two units on one job, a forgotten-close
  caught by the change question, close and deliver, review later by job number.

## Open questions

- Should a declined job number block delivery, or only flag the record? Leaning: flag, never block.
- Multi-unit jobs: is one `equipment` plus a list of visited units enough for the work record, or
  does each unit need its own task/evidence grouping in the export? (FM's scopes already partition
  tasks; the export does not show it yet.)
- Auto-suggest closing a job after long inactivity or a large location change — useful, but it is
  a nag risk and touches billing; out of scope until a pilot asks.
- Team tier: does the office need to push a job number/assignment to the phone (ops bridge)
  instead of the technician speaking it? Natural follow-on, not v1.

Related: [F Field Assist](F-field-assist.md), [EL equipment identity](EL-equipment-identity.md),
[EM work record](EM-work-record-and-parts.md), [FM context and field continuity](FM-conversation-context-and-field-continuity.md),
[FE voice reliability](FE-agent-voice-reliability-and-feedback.md).
