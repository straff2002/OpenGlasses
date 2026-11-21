# Plan MS — Editing a Procedure on the Phone (steps and routes, a new procedure, a map of the routes, a practice run, saved versions, and a change described in words)

**Status:** 📝 Drafted 2026-11-21. Nothing is implemented. 10 decisions below, each with a
recommendation.
**Track:** Field Assist, your own vaults. The same editor suits personal guides (Plan
[MJ](MJ-personal-guides.md)), which use the procedure step format.
**Builds on:**
- Plan [F](F-field-assist.md): `Procedure` / `Procedure.Step` / `Procedure.Branch`, `ProcedureRunner`,
  and Plan [H](H-custom-vault-import.md)'s `VaultValidator.validateProcedureGraph`.
- Plan [MN](MN-answers-the-app-can-check.md) P3: the procedure screen (`ProcedureRulesView`,
  `ProcedureRulesModel`), the pure `ProcedureEditing` (every edit a new copy, checked by the import
  validator, its messages placed beside the step and route they name), `AnswerDraft` / `RuleDraft`,
  `ProcedureReadiness`, and the save to the overlay (`ProcedureAuthoring`).
- Plan [LW](LW-vault-authoring.md): *Build this vault* (`VaultAuthoringView`), owned vaults only
  (`VaultAuthoring.isOwned`), the trade templates, `PromptKit` and the strict paste parsers, and the
  draft review screen's keep / skip / undo rows.
- Plan [JJ](JJ-rule-chains.md) P3: `KeptChains`, the precedent for a file in a vault's overlay that
  stays on the phone and never goes into an export.
- Plan [MI](MI-steps-you-can-see.md) (drafted): steps drafted from a manual's step pages, and a
  step's `figure` and `needs`. Plan [MR](MR-procedures-that-call-procedures.md) (drafted): `call` and
  `hand_off`. Each adds controls to the editor this plan builds.

---

## Trigger

Asked how an author changes what the app proposes, the honest answer was: on the phone, only a
step's typed answer and the rule on each route. MN's procedure screen shows a step's instruction
as read-only text. Nobody can add, remove or reorder a step, change its words, point a route at a
different step, or make a new procedure. Changing any of that means exporting the vault, editing
JSON on a computer, bumping `version` and importing again. That contradicts the rule that a
technician must be able to do everything from the phone, and MI's drafted steps would land in a
review screen that cannot finish the job, because MI says branches are still added "as they do
today".

Surveying on-device automation tools shows a consistent set of editing aids that suit this: a
map of the graph that is laid out automatically, so positions never need hand-placing; running one
piece on its own to see what it does before wiring the rest; saved versions kept on the device, with
restore; and a file format documented well enough that a model can write a valid file from a
description. This plan brings each in, shaped for procedures that are spoken and run hands-free.

## What exists (verified 2026-11-21 on `origin/main` 299119ab7)

- *Build this vault* lists a vault's procedures when the manifest has `proceduresDir`, each opening
  `ProcedureRulesView`. With no procedures it says "This vault has no procedures yet." and offers
  nothing to make one.
- `ProcedureRulesView` shows each step's title and instruction as text (`ProcedureRulesView.swift`
  line 239). Its controls are *Edit answer* / *Remove answer*, a rule per route, *Remove the rules
  on this step*, and the *conditions to rules* kit's accept / reject.
- `ProcedureEditing` already has `with(steps:)` and `replacing(_:)` on `Procedure`, and
  `with(branches:)` on a step: the pure seams a step editor needs, unused for anything but answers
  and rules.
- `ProcedureAuthoring.save` writes the edited procedure over the same file name in the overlay,
  only for an owned vault and only with no validator issue. It does not bump `version`, keeps no
  earlier copy, and there is no undo within an edit.
- `VaultValidator.validateProcedureGraph` refuses a missing entry, duplicate ids, a route to an
  unknown step, a dead end, and a procedure with no reachable terminal. A step that nothing leads
  to is not mentioned.
- `VaultExporter` writes every file in the bundle's and the overlay's procedures folders, the
  overlay's in place of the bundle's of the same name. So nothing that must stay on the phone can
  live inside that folder.
- `ProcedureRunner` needs a `SessionLogger`, which writes to a folder (`init(session:root:)`), so a
  run outside a job can use a temporary folder.

## Design

### 1 · The step list, editable

The procedure screen becomes the editor. The list stays the main surface: it works on the smallest
phone, with VoiceOver and with large text. Each step row opens a step sheet:

- **Words:** title, instruction, safety note, what the technician reports (`expected_input`),
  citations (picked from the vault's files), a video link.
- **How it ends:** *This is a last step* (`terminal`), its outcome, *Needs the technician to confirm*
  (`requires_confirmation`).
- **Where it goes next:** the *Then* route (`default_next`) and each route (`branches`): its words
  (`condition`) and where it goes, picked from the steps by title, or *A new step*, which adds one
  after this and opens it. MN's answer and rule controls stay on the same sheet.

On the list: *Add a step* (after this one, or at the end), *Duplicate*, *Delete*, drag to reorder,
and *Start here* (`entry_step`). Order in the file is the reading order; only `entry_step` and the
routes decide the run, and a new step added after another takes over its *Then* route so a
straight procedure stays straight.

- **Step ids are made from titles** ("Check the fuse" → `check_the_fuse`, with `_2` on a clash) and
  shown only under *Details* (decision 3). Renaming an id rewrites every route that points at it,
  in this procedure and in any procedure of the vault that calls it (MR).
- **Deleting a step that routes lead to** lists those routes and asks where each goes now, defaulting
  to the deleted step's own *Then* (decision 4). Nothing is left pointing at a step that isn't
  there.
- **Undo and redo** on the screen: every edit is a new `ProcedureEditing` copy already, so the
  stack is the copies.

Every edit runs the validator, as MN P3 does, and its messages sit beside the step and route they
name. Save stays refused while there is an issue.

### 2 · New, duplicate, remove

- *New procedure* on *Build this vault*: a title, then one step to start. On a vault with no
  procedures folder, the first new procedure gives it one (`"procedures_dir": "procedures"` in its
  manifest), so *Build this vault* lists procedures from then on.
- *Duplicate* makes a copy with a new id and "(copy)" in the title, so an author can try a change
  without touching the procedure technicians run.
- *Remove* deletes a procedure that exists only in the overlay. One that came with the vault is
  removed by a list at the overlay's root (`_removed_procedures.json`) that `ProcedureLibrary` and the
  exporter both honour (decision 7). Removing a procedure another one calls (MR) is refused with
  the caller named.

### 3 · The map

*Map* on the procedure screen draws the routes: a card per step (title, a mark for an answer, a
rule, a call or a last step) and an arrow per route, labelled with its words. It is laid out
automatically every time (`ProcedureLayout`, pure): layers from the entry step by longest path,
routes ordered left to right as listed, a route back to an earlier step (a retest loop) drawn up
the side. No position is stored (decision 2), so the map can never disagree with the file, a
pasted or imported procedure needs no layout, and nothing about it reaches the run.

- What the validator flags shows on the map: a dead end, a route to nowhere, a step nothing leads
  to (§7), each in the warning colour with its message.
- Tap a card to open its step sheet. On iPad and the larger phones, drag from a route's end onto a
  card to point it there. The same change is *Point to…* on the route in the step sheet, which is
  also what VoiceOver offers. The map's accessibility summary reads it as a list.
- Pinch to zoom; *Fit* shows it all. No freehand drawing and no backgrounds.

The list is the editor and the map is the way to see a procedure's shape and fix a route quickly
(decision 1).

### 4 · Try it

*Try from here* on any step, and *Try it* on the procedure, runs the draft as it stands through the
real `ProcedureRunner`, with a `SessionLogger` on a temporary folder deleted when the try ends. No
job, no task, no record, no queue, no assistant (decision 9).

- The phone step screen (MN P2) shows each step as a technician would see it. Answers are typed.
  On a step the rules decide, the route taken is shown with the rule in words ("pH 4.60 is above
  4.4, so the next step is Adjust acid"); on a step decided from words, the author picks.
- **Routes tried:** each try marks the routes it took. The procedure screen lists the routes no try
  has taken yet, so an author can see what is still unproven before handing it to technicians.
  The marks live in memory for the editing session only.
- **Check an answer:** on a step the rules decide, type a value and see which route it would take,
  without a run. It calls `BranchRuleEvaluator.decide` with that answer and the earlier answers the
  author fills in.

### 5 · Saved versions

Every save keeps the file it replaces in the overlay, in `_procedure_versions/<procedure id>/` at
the overlay's root, outside the procedures folder the export copies,
named by date and version: the last 20 per procedure (decision 5). Like a kept chain, it stays on
this phone: never exported, never in a pack or a link, removed with the vault.

- **Version number:** each save raises the patch number (`1.2.0` → `1.2.1`) unless the author
  changed it on *Details* (decision 6), so a job's record always names the procedure it ran.
- **History** on the procedure screen lists the saves with their date, version and what changed in
  words (`ProcedureChanges`, pure: "Added step Check the fuse; route *low* now goes to Recharge;
  removed the rule on *high*"). *Restore* makes that version the next save, so restoring is itself
  in the history and can be undone.

### 6 · Describe a change in words

A prompt kit (LW's `PromptKit`): *Change this procedure*. The author writes what they want ("add a
step to check the fuse before the meter reading, and send a reading over 30 to Escalate") and
copies the kit, which carries the procedure's JSON, the format reference (§8) and the request, into
whatever model they use. The reply, a whole procedure, is pasted back:

- read strictly (`ProcedureDraftParser`): anything that isn't a procedure in this format is shown
  as it is, never guessed into one;
- checked by the validator;
- shown as change rows from `ProcedureChanges`, each accepted or rejected on its own, as the
  conditions-to-rules kit does. Accepted rows apply to the draft, which still needs a save.

The app sends nothing to any model for this (decision 8).

### 7 · What the validator adds

- **A step nothing leads to:** a warning, named on the step and the map. It is not an error, since
  an author may park a step while rewiring.
- **Step ids:** letters, digits and `_`, unique, at most 48 characters, so ids made from titles and
  pasted procedures meet the same rule.
- The `_removed_procedures.json` list names only procedures the vault has.

### 8 · The format reference

The vault guide's procedure section becomes a full reference: every key with its type, default and
meaning; the validity rules in the validator's own words; and complete example files in
`examples/vaults/`. It should be detailed enough to write a valid procedure from scratch without
opening the app, and the prompt kits quote it rather than restating it. It grows with MN, MI and MR,
which each add keys.

## Phases

- **P0 — the core (headless).** Step operations on `ProcedureEditing` (insert, duplicate, delete
  with re-pointed routes, move, set entry, set a route's target, rename an id with every reference
  rewritten), new / duplicate / remove a procedure, ids from titles, `ProcedureLayout`,
  `ProcedureChanges`, the version store's naming, pruning and patch bump, the practice run wrapper
  over a temporary logger, the §7 validator additions. Tests: each operation and its validator
  result, delete re-pointing, rename across a call, layout of a straight, a branching and a looping
  procedure, change summaries, pruning at 21 saves, restore as a new save, a practice run leaving no
  file behind, the exporter skipping `_procedure_versions`.
- **P1 — the editor.** The step sheet, the list controls, undo and redo, *New procedure*, *Duplicate*,
  *Remove*, *History* and *Restore*, *Try it* / *Try from here*, routes tried, *Check an answer*.
- **P2 — the map.**
- **P3 — words.** The *Change this procedure* kit, `ProcedureDraftParser`, the change rows, and the
  guide's format reference.
- **P4 — catalog.** The new strings in the 13 complete languages, in its own PR.
- **P5 — device pass (owed).** Build a branching procedure from nothing on an iPhone, try every
  route, restore an earlier version, run it on a job with and without the assistant; the map on an
  iPad and with VoiceOver.

P0–P1 are one PR, P2–P3 another, P4 its own, and P5 is owed after.

## Decisions

1. **The list is the editor and the map is a view you can rewire from (recommended).** The
   alternative makes the map the main editor, which is hard to use on a small phone, with
   VoiceOver or with large text.
2. **The map is always laid out by the app, and no position is stored (recommended).** The
   alternative keeps positions in a layout file in the overlay, which lets an author arrange a big
   procedure but goes stale whenever steps change, and means nothing for a pasted procedure.
3. **Step ids are made from titles and shown only under Details (recommended).** The alternative
   asks the author to type ids, which is what the JSON does today and what trips people up.
4. **Deleting a step asks where its incoming routes go, defaulting to its own Then (recommended).**
   The alternative refuses the delete until the author has re-pointed them by hand.
5. **Keep the last 20 saves per procedure (recommended).** The alternatives are keeping every save
   (unbounded on a phone) or none (no way back from a bad save).
6. **A save raises the patch number unless the author set one (recommended).** The alternative
   leaves the version to the author, so two different procedures can be recorded on jobs under
   the same version.
7. **A procedure that came with the vault is removed by a list in the overlay that the library and
   the export honour (recommended).** The alternative lets only procedures made on the phone be
   removed.
8. **Describing a change works by copy and paste with the author's own model (recommended),** as
   LW's kits do. The alternative also lets the assistant configured in the app make the change,
   which is quicker and sends the procedure to that provider from inside the app.
9. **A practice run leaves nothing behind (recommended):** no job, no record, no queue, not in a
   support report. The alternative keeps the last try's path for the author to look back at.
10. **Editing happens on the phone and iPad screens only (recommended),** not by voice or on the
    lens. The alternative adds spoken edits through the assistant, which needs §6's change rows to
    review them first and belongs in a later plan.

## Not in scope

- **Editing a vault an organisation publishes** (Plan LR) on the phone. It stays read-only there;
  the office edits it. A *Copy into my vault* is a later plan.
- **Two people editing the same vault** and merging their changes.
- **Freehand drawing, notes or backgrounds on the map.** It shows the procedure and nothing else.
- **Spoken edits through the assistant** (decision 10).
- **Editing capture flows and playbooks** in this editor. MJ's guides use the step format and can
  adopt it when MJ is built.

## Risks

- **Small screens.** A step sheet holds a lot. Sections fold, and what matters most (words, where it
  goes next) comes first.
- **Rewriting ids.** A rename that misses a reference breaks a route. The rename is a pure
  operation tested across this procedure's routes and other procedures' calls, and the validator
  runs on the result before anything can be saved.
- **Overlay files that must not travel.** `_procedure_versions/` and `_removed_procedures.json`
  live in the overlay beside files that do go into an export. The exporter's tests pin that
  neither leaves the phone, and that a removed procedure is left out.
- **A practice run that leaks into a job.** It never gets a session, a task or the queue. A test
  asserts that the temporary folder is gone after the run and that no job file changed.
