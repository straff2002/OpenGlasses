# Plan MR — Procedures That Call Procedures (a step runs another procedure and comes back with how it ended, and a last step hands the job to another procedure)

**Status:** 📝 Drafted 2026-11-21. Nothing is implemented. 9 decisions below, each with a
recommendation.
**Track:** Field Assist procedures. The same shape suits any site whose checks share a section
(lock-out before an adjustment, a leak check inside a diagnostic, a sanitation round inside a
changeover).
**Builds on:**
- Plan [F](F-field-assist.md): `Procedure` / `Procedure.Step` / `Procedure.Branch`, `ProcedureRunner`,
  the `procedure_runner` tool (`ProcedureRunnerTool`), and Plan [H](H-custom-vault-import.md)'s
  `VaultValidator.validateProcedureGraph`.
- Plan [MN](MN-answers-the-app-can-check.md): `StepAnswer` (`record_as`), `BranchRule` (`when`),
  `BranchRuleEvaluator`, `KnownAnswer`, who decides a route (`ProcedureDecider`, override with a
  reason), `ProcedureRunMode` and the no-model `ProcedureVoiceLoop`, `ProcedureStepPresentation`
  and the phone step screen, `ProcedureReadiness`, the record (`CaptureRecord` per run, flow id
  `procedure:<id>@<version>`; `SessionExport.ProcedureRecord`), and the P3 authoring screen
  (`ProcedureEditing`, `ProcedureAuthoring`).
- Plan [GB](GB-field-test-round-3.md) P3: a last step that needs a confirmation completes only on
  an explicit `complete`, and a procedure attaches to a task (`attachProcedureTask`).
- Plan [HE](HE-recorded-session-action-map.md): `ProcedureCandidateDetector` and the recorded-session
  contract (`Contracts/recorded-session.md`), which read the `procedure_*` events.
- Plan [MI](MI-steps-you-can-see.md) (drafted): `ProcedureShape` ("Step 3 of 12"). When it lands it
  counts within one procedure, never across a call.

---

## Trigger

Surveying adjacent automation tools shows one feature in nearly all of them: one workflow runs
another like a function, gets its result back, and the caller decides what to do with it. Proven
pieces are reused instead of copied. Our procedures cannot do this, and the bundled vaults show
what that costs:

- `low_pressure_diagnostic` ends by *recommending* the leak check in prose. `leak_check` has a step
  that says "return to the main diagnostic". The two point at each other in words, and the runner
  refuses to start one while the other is running (`procedureAlreadyRunning`). The technician has
  to finish the diagnostic, start the leak check by name, and remember where they were.
- `server_hot_swap` has a terminal step, *Use the cold-swap procedure*, whose whole instruction is
  to switch procedures. Nothing switches. The task, the photos and the readings stay with the
  procedure that ended.
- `start_of_shift_check` says "with the filler locked out" and "with the capper locked out" on
  separate steps. A lock-out written once, with its own confirmation, would be checked the same way
  every time instead of being a phrase in each instruction.

MN made a route something the app can decide from an answer. This plan makes *how a called
procedure ended* an answer, so the caller's existing rules decide what happens after it.

## What exists (verified 2026-11-21 on `origin/main` 321354c7a)

- `Procedure` has `id`, `title`, `version`, `vault`, `safety_notes`, `entry_step`, `steps`, and
  `runs` (MN). `Step` has `instruction`, `expected_input`, `safety_note`, `calc_ref`, `citations`,
  `branches`, `default_next`, `terminal`, `outcome`, `requires_confirmation`, `video_url` and
  `answer` (MN). `Branch` has `id`, `condition`, `next` and `when` (MN). Nothing on a step names
  another procedure.
- `ProcedureRunner` walks one procedure. `visited` is the back-stack; `answers` are keyed by step;
  `pathAnswers` keys them by `record_as` for the rules. `advance(choice:by:)`, `override`,
  `answer`, `confirmReadBack`, `addCorrectiveNote`, `goBack`, `complete` and `captureRecord` are
  per procedure.
- `FieldSessionService` holds one `runner`. `startProcedure(id:)` refuses while one runs.
  `reconstructRunner(from:logger:)` replays `procedure_started` / `procedure_step` /
  `procedure_completed` and rebuilds one runner from the last step's `stack`.
- `SessionExporter` aggregates runs by `procedure_id` in the order `procedure_started` events
  arrive (`proceduresRun`, `procedureRecords`). `ProcedureCandidateDetector` pairs each
  `procedure_started` with the next `procedure_completed`; a second `procedure_started` before it
  closes the first run.
- The recorded-session contract lists the `procedure_*` kinds and says a reader ignores unknown
  kinds, never refuses them.
- Terminal `outcome`s are coarse and repeat within a procedure: `leak_check` ends
  `no_leak_indicated` → `deferred`, `document_and_repair` → `resolved`, `no_leak_found` →
  `escalated`, and `low_pressure_diagnostic` has two `deferred` and two `resolved` ends. An outcome
  alone cannot tell a caller which end was reached; the terminal step id can.
- `ProcedureLibrary` loads one vault's procedures (overlay over bundle). Expert coaching
  procedures (Plan KM P3) come from the job's own record, not the library, and are read as written.
- `VaultValidator.validateProcedureGraph` checks one procedure's graph; MN's checks cover answers
  and rules. Nothing checks across procedures.

## Design

### 1 · Two additions to the format

**A call step.** A non-terminal step may carry `call`:

```json
{
  "id": "run_leak_check",
  "title": "Leak check",
  "instruction": "Next, the leak check. We'll come back here when it's done.",
  "call": { "procedure": "leak_check", "record_as": "leak_check" },
  "branches": [
    { "id": "repaired", "condition": "the leak was found and repaired", "next": "recharge",
      "when": { "answer": "leak_check", "is": "document_and_repair" } },
    { "id": "not_loss", "condition": "the symptoms don't point to refrigerant loss",
      "next": "check_airflow", "when": { "answer": "leak_check", "is": "no_leak_indicated" } }
  ]
}
```

(The step's `default_next` covers the callee's other end, `no_leak_found`.)

Entering the step says its instruction and starts the called procedure at its entry step in the
same transition, so the technician does not say "next" twice. When the called procedure completes,
**the terminal step it ended on** is recorded on the call step under `record_as`, with that step's
`outcome` beside it, and the run returns to the call step's route. The recorded value is a `choice`
answer whose options are the callee's terminal steps (labelled by their titles), so MN's `is` and
`in` tests read it unchanged, and a call step whose branches have no `when` is routed from words as
any step is. A call step takes no `answer` of its own (its answer is how the callee ended).

**A hand-off.** A terminal step may carry `hand_off`:

```json
{ "id": "defer_to_cold", "terminal": true, "outcome": "handed_to_cold_swap",
  "instruction": "This replacement isn't safe to do live. Moving to the cold-swap procedure.",
  "hand_off": "server_cold_swap" }
```

Completing the step completes this procedure with its outcome, then starts the named one on the
same task. Nothing comes back. A hand-off step may still need a confirmation
(`requires_confirmation`), and then hands off only on `complete`.

Both keys are optional and are left out when encoding, so a procedure without them stores exactly
what it stored before.

### 2 · What can be called

- A procedure in **the same vault** (decision 4), by `id`, from the library the run started from.
  The callee's version at call time is the one that runs, and it is recorded (decision 5).
- Never an expert's coaching (Plan KM): it belongs to one job and is read as written. A coaching
  procedure neither calls nor is called.
- At most **three levels** (the procedure the technician started, and two calls inside it,
  decision 3). The validator refuses deeper call chains, and the runner refuses at run time as a
  backstop.
- No procedure already on the stack, so a cycle cannot run even if a vault edit slips past the
  validator.

### 3 · The call stack

`ProcedureRunner` stays a walker for one procedure. A new `ProcedureCallStack` (`@MainActor`, the
only thing `FieldSessionService` now holds as `runner`) keeps one frame per level: the runner, the
call step it was entered from, and the callee version. It forwards every action to the top frame
and handles the edges:

- **Entering a call step:** pushes a frame and starts the callee. Transition `.called(step, entry)`.
- **The callee completes:** pops the frame, records the end it reached on the call step
  (`RecordedProcedureAnswer`, with a new `ProcedureAnswerMethod.called`), then advances the caller from the call step by its
  rules or waits for a choice, exactly as after any answer. Transition `.returned(end, next)`.
- **Back on the callee's entry step** leaves the callee and returns to the caller's call step,
  logged as `abandoned` (decision 2). Back is never refused at a boundary.
- **Hand-off:** the frame's procedure completes; if it was the top-level procedure, the stack is
  replaced with the hand-off target. A hand-off from inside a call replaces only that frame, and the
  caller's call step receives the end the target reaches (a hand-off inside a call is still inside
  the call).
- **Override (MN decision 3)** applies to the step on top, as now. An override on a call step's
  route names the callee's end in its record.
- **Stopping the run** stops every frame, innermost first, each logged.

The rules read only the answers of their own procedure. A caller sees what the callee *found* only
through the end it reached (decision 1). That keeps a vault's procedures independent: renaming an
answer inside `leak_check` cannot break `low_pressure_diagnostic`'s rules. Renaming one of its
terminal steps can, and the validator says so at import (§7).

### 4 · The log, and coming back after a relaunch

The existing kinds keep their meaning for the procedure the technician started, so every current
reader keeps working:

- `procedure_started` / `procedure_completed`: the top-level run only.
- **New** `procedure_called` (`procedure_id`, `version`, `called_by` `{procedure_id, step_id}`,
  `depth`) and `procedure_returned` (`procedure_id`, `ended_at`, `outcome`, `abandoned`, `called_by`).
- **New** `procedure_handed_off` (`from`, `to`, `outcome`) between the first procedure's
  `procedure_completed` and the next one's `procedure_started`.
- `procedure_step` keeps `procedure_id` (the frame on top) and `stack`, and adds `call_stack`: one
  `{procedure_id, version, stack}` per frame below, outermost first. Left out at depth 0.

`reconstructRunner` rebuilds every frame from the last step's `call_stack`, with answers per frame
from `restoredAnswers(from:procedure:)`, read per frame. A callee missing from the vault after an update leaves the run on the
caller's call step with a sentence ("The leak check is no longer in this vault"), not a crash.

The office reads unknown kinds as nothing, so an older reader sees one run whose steps include the
callee's. `ProcedureCandidateDetector` is unchanged: a call no longer closes the run because it is
not a `procedure_started`.

### 5 · The record

- The callee's run is **its own `ProcedureRecord`**, with a new `calledBy` (`procedureId`,
  `stepId`) and, when it was left early, `abandoned: true` (decision 9). The caller's row for the
  call step shows the end the callee reached and its outcome. The callee's answers fold into its own `CaptureRecord` (flow id
  `procedure:<callee>@<version>`), so the queue and the office need no new op.
- `proceduresRun` lists the callee after its caller, and `stepsCompleted` counts each procedure's
  own steps, never the callee's within the caller's.
- A hand-off is the first procedure's outcome (`handed_to_cold_swap`) and the next procedure's
  `handedOffFrom`.
- Contract: `Contracts/recorded-session.md` gains the three kinds and `call_stack`, pinned by
  `Contracts/tests/test_recorded_session_contracts.py`. `SessionExport` gains `calledBy`,
  `abandoned` and `handedOffFrom` on `ProcedureRun` / `ProcedureRecord`. All optional, and all
  absent for a run with no calls.

### 6 · What the technician sees and hears

- **The assistant's prompt** names both levels: "ACTIVE PROCEDURE — Refrigerant Leak Check, called
  from Low Pressure Diagnostic (step 'Leak check'). When it completes, the run returns there with
  how it ended." The route lines after a return are MN's, unchanged.
- **Safety notes:** a callee's `safety_notes` are said when it starts, except a note whose text was
  already said in this run (decision 8). Step safety notes are always said.
- **The phone step screen** shows a breadcrumb above the step (*Low pressure diagnostic › Leak
  check*). The step count, when MI lands, counts within the procedure on top.
- **The lens** keeps one title line: the callee's title with "from Low pressure" when it fits, the
  callee's alone when it doesn't.
- **The no-model voice loop** says "Starting the leak check" on a call and "Back to the low
  pressure diagnostic: the leak check ended at Document and repair" on the return, the end named
  by its terminal step's title.
- **Readiness (MN §6):** a procedure runs with no assistant only when every procedure it can call
  or hand off to does. `ProcedureReadiness` names the callee that stops it.

### 7 · What the validator checks

Across the vault, after each procedure's own graph:

- `call.procedure` and `hand_off` name a procedure in this vault, and not the procedure itself.
- The call graph has no cycle and no chain deeper than three levels (hand-offs do not count toward
  depth, and a hand-off loop is a warning, not an error: A may hand to B and B back to A by
  choice).
- A call step is not terminal, has no `answer`, and its rules test only its own `record_as` with
  `is` / `in` / `present`, naming terminal steps the callee actually has. A name the callee does
  not have (including one renamed by a vault update) is an error; a callee end no branch covers, on
  a step with no `default_next`, is a coverage warning (MN's coverage rule, applied to ends).
- `hand_off` sits only on a terminal step.
- A procedure that is called and declares `runs: without_assistant` makes no difference to its
  caller's mode; a caller that declares it requires the same of its callees (an error if not).

### 8 · Authoring

MN P3's procedure screen gains two controls: *Run another procedure here* on a step (a picker of
this vault's procedures, which sets `call` and offers the callee's terminal steps as rule options) and
*Hand off to* on a terminal step. Both go through the validator on every edit, as the rest of the
screen does. The prompt kits (`PromptKit`) and the vault guide document the two keys, so a pasted
draft can use them.

The bundled vaults change where they already say it in words (decision 7):
`low_pressure_diagnostic`'s *suspect undercharge* end becomes a step that calls `leak_check` and
routes on how it ended (the example in §1), so `leak_check`'s "return to the main diagnostic"
instruction becomes literally true; `server_hot_swap`'s *Use the cold-swap procedure* hands
off to `server_cold_swap`. The bottling-line example gains a `lock_out` procedure called by its
three adjustment steps.

## Phases

- **P0 — format and checks (headless).** `call` / `hand_off` on `Step` (lenient decode, left out
  when absent), the call's answer (a `StepAnswer` derived from the callee's terminal steps), the cross-procedure
  validator checks of §7, readiness across calls. Tests: decode/encode round trip with and without
  the keys, every §7 issue, a vault with a cycle, depth 4 refused, coverage warning on an uncovered
  end, an error for a renamed terminal step.
- **P1 — the stack and the log (headless).** `ProcedureCallStack`, the three new event kinds and
  `call_stack`, `reconstructRunner` over frames, the tool's step text and prompt context, the
  record and contract fields of §5, `procedureAlreadyRunning` unchanged for a *new* procedure
  started by name. Tests: call → return → rule picks the branch; back out of a callee; hand-off at
  depth 0 and inside a call; relaunch mid-callee restores both frames and their answers; a callee
  removed by a vault update; exporter output for a run with a call and one with a hand-off;
  `ProcedureCandidateDetector` sees one run; contract tests updated.
- **P2 — surfaces.** The phone step screen breadcrumb, the lens title line, the voice loop's lines,
  the authoring screen's two controls, the bundled procedures and the vault guide section.
- **P3 — catalog.** The new strings in the 13 complete languages, in its own PR.
- **P4 — device pass (owed).** The leak check called from the low-pressure diagnostic on Ray-Ban
  Meta and on a Display, with and without the assistant; a relaunch mid-callee; a hand-off.

P0–P2 are one PR; P3 another; P4 is owed after.

## Decisions for Greig

1. **What a called procedure gives back: the end it reached, with that end's outcome
   (recommended).** The caller's rules read which terminal step the callee ended on; the callee's
   answers stay its own. Outcomes alone are too coarse (`leak_check` has `deferred`, `resolved` and
   `escalated` ends that mean three different things to its caller). The alternative lets a callee
   declare `returns` (answers its caller may read), which is more powerful and couples the two
   procedures' answer names.
2. **Back on a called procedure's first step leaves it (recommended).** The run returns to the call
   step and the callee is recorded as abandoned. The alternative refuses back at the boundary, which
   strands a technician who called the wrong thing.
3. **Three levels at most (recommended):** the procedure started and two calls inside it. The
   alternative is two, which is enough for today's vaults but not for a lock-out inside a leak
   check inside a diagnostic.
4. **Same vault only (recommended).** A company vault (Plan LR) that wants a shared lock-out
   includes it. The alternative is calling across installed vaults, which makes a vault's
   procedures depend on another vault being installed and at a compatible version.
5. **The callee's current version runs, and is recorded (recommended).** The alternative lets the
   author pin a version (`"version": "1.2.0"`) and refuses the call when the vault holds another,
   which is safer for audited sites and stops a run whenever a vault updates.
6. **Include hand-off (recommended).** It is small, and two bundled procedures already need it. The
   alternative ships calls only.
7. **Change the bundled procedures where they already say it in words (recommended).** The
   alternative leaves them and adds new examples, which keeps the two procedures that point at each
   other in prose.
8. **Say a callee's safety notes when it starts, skipping a note already said word for word in this
   run (recommended).** The alternatives are always saying them (repetitive inside a loop that
   calls the lock-out three times) or never (a callee started inside another depends on the caller
   having said them).
9. **A called run is its own record with `calledBy` (recommended).** The alternative folds the
   callee's rows into the caller's record, which reads well on one page and loses the callee's own
   outcome, version and answers record.

## Not in scope

- **A drawn map or node canvas.** Procedures are authored as reviewed rows and JSON (LW, MN P3) and
  run by voice and on the lens, so a drag-and-drop graph editor is a lot of phone UI for little
  gain. A read-only map of a procedure (its steps, branches and calls, with dead ends marked) could
  help authors later and is not this plan.
- **Inputs into a called procedure.** A callee reads none of its caller's answers. A later plan may
  add declared inputs if a real vault needs them.
- **Running a procedure once per item** (each unit on the job, each bay on the line). A later plan.
- **Calling a rule chain, an add-on or a capture flow from a step.** Those have their own runners
  and gates; a step that needs one says so in words, as now.
- **Calls across vaults** (decision 4).

## Risks

- **Every reader of the `procedure_*` events.** Keeping `procedure_started` / `procedure_completed`
  for the top-level run is what keeps the exporter, the candidate detector, the office and an older
  build reading the log correctly. P1's tests cover each reader by name.
- **Recovery across frames.** A relaunch mid-callee is the hardest path. The `call_stack` snapshot
  on every step event means recovery reads one event, as today, and never replays the call history.
- **Rules that read how a callee ended.** A callee whose terminal steps are renamed in a vault
  update breaks its callers' rules. The validator catches it at import, which is why decision 1
  keeps the interface to the callee's ends and never its answers.
- **Length on the lens.** Two titles rarely fit one line. The callee's title alone is the fallback,
  and the phone carries the breadcrumb.
