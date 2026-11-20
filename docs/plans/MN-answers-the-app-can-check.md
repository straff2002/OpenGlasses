# Plan MN — Answers the App Can Check (typed answers on procedure steps, and branches the app decides from them, so a fixed procedure runs on the phone with no model)

**Status:** 🚧 P0–P3 built 2026-11-20; the P4 device pass is owed. P3 (authoring): a vault of your
own lists its procedures under *Build this vault*, and each opens a review screen with answer and
rule editing (the pure `AnswerDraft` / `RuleDraft` / `ProcedureEditing`, checked by the import
validator on every edit, with issues, coverage warnings and the condition-against-rule warning
beside the step and route they name, all-or-none enforced at save, and the procedure's readiness
on top); the *conditions to rules* kit (`PromptKit.conditionsToRules`, `RuleProposalParser`,
`ProcedureRuleReview`) that lands each proposed rule or answer beside its sentence, to accept or
reject one at a time; and the save to the vault's overlay (`ProcedureAuthoring`), which the export
now merges file by file with the baseline's procedures. The authoring flow writes no `pack.json`
(a vault of your own is never a pack), so `minAppBuild` stays the importer's warning on a pack.
P0–P2 built 2026-11-20. P0 and P1 (headless): the `answer` / `when` format,
`AnswerReader` (with the `SpokenNumber.decimal(in:)` words reader), `BranchRuleEvaluator`,
`RuleCoverage`, `ProcedureReadiness`, the §7 checks in `ProcedureAnswerValidator` (run from
`VaultValidator.validateProcedureGraph`), the import summary line, the worked example in
`examples/vaults/bottling-line-check` and the vault guide section; then `ProcedureRunner.answer` /
`override`, rule-decided `advance`, the read-back and the corrective note, the `CaptureRecord`
fold and the `procedureStep` keys, `procedure_runner` `answer` / `override` (an override is
confirmed by the person), the prompt lines and the export's "Procedure record" block. P2 (simulator):
the procedure-level `"runs": "without_assistant"` key (validated, guide line); the pure
`ProcedureRunMode` with its four triggers, including the organisation ceiling
`organizationRunsProceduresWithoutAssistant`; `ProcedureStepPresentation` (position, trail, answer,
route, lens buttons); `ProcedureStepScreen` from the open job's procedure row, in both modes; the
no-model voice (`ProcedureVoiceDecider` + `ProcedureVoiceLoop`, on the existing wake-word and
transcription path, recognised on the phone where the locale allows, said with the on-device voice);
lens buttons for `choice` and `yes_no` answers and the read-back, and the recorded number on the
card; the "Runs with no assistant" badge on the scenario list. MI's `ProcedureShape` isn't on main,
so the position is "Step 3 of 12" only for a straight-line procedure and "Step 3" otherwise. The
`code` kind is typed on the screen (no barcode scan yet). All eight decisions were taken on 2026-11-20 as recommended.
**Track:** Field Assist procedures. The same shape suits any site that runs a fixed check
(production lines, cleaning and sanitation rounds, start-of-shift checks).
**Builds on:**
- Plan [F](F-field-assist.md): `Procedure` / `Procedure.Step` / `Procedure.Branch`, `ProcedureRunner`,
  the `procedure_runner` tool, and Plan [H](H-custom-vault-import.md)'s `VaultValidator`, which
  checks the graph at import.
- Plan [U](U-structured-capture-flows.md): `FieldBinding`, `CaptureValue`, `Provenance`,
  `CaptureRecord` and its `.captureRecord` op in the offline queue (Plan [T](T-offline-field-queue-and-sync.md)),
  plus `CaptureFlowRunner.parseNumber` / `resolveOption`. This plan reuses that vocabulary and does
  not invent a second record.
- Plan [GB](GB-field-test-round-3.md) P3: `requires_confirmation` on a last step, and `SpokenReading`
  (a reading is the technician's report, never "verified").
- Plan [GX](GX-photo-checked-procedure-steps.md) (drafted): `check` on a step, where the camera
  assesses the evidence. This plan is the technician's own answer. The two sit side by side (§8).
- Plan [MI](MI-steps-you-can-see.md) (drafted): `ProcedureShape` ("Step 3 of 12") and the step's
  picture and needs, which the phone step screen (§4) shows when they exist.
- Plan [GE](GE-automatic-offline-handoff.md): the offline hand-off and the offline tool set.
- `HUDVoiceCommand` ("next step", "go back") and `ProcedureHUDTaskSource.choose(_:)`, the lens's
  branch buttons, which already advance a procedure with no model.

---

## Trigger

A prospective customer in beverage production asked whether a worker following a simple, fixed
procedure needs a cloud AI subscription, or whether the phone could do it alone. The procedure
guides the worker, records their answers and measurements, and takes a few photos. Reviewing the
photos with AI is a separate requirement from attaching them.

The honest answer is that this workflow needs no model at all. It is ordinary software, it runs
offline, and it should not depend on a model's judgement. Ours can't do it yet, though, for two
reasons:

1. **A step has no typed answer.** `expected_input` is a sentence for the model ("the pressure in
   psig"), not a field. A reading goes to the job's `spokenReadings` only if the model decides to
   record it.
2. **Every branch is chosen by the model.** `Branch.condition` is free text ("pH above 4.4") that
   the model matches against what it heard, and it passes the id as `choice`. Nothing in the app can
   tell that 4.6 is above 4.4.

So today a procedure needs a model on every branching step, and a pass/fail route depends on a
model reading a sentence. For a food-safety or quality check, that is the wrong way round: the
rule should decide, and the model should help with the rest.

---

## What exists (verified 2026-11-20 on `origin/main` 64f2708a4)

- `Procedure.Step` (`Services/FieldAssist/Procedure.swift:63`) has `expected_input` (a string),
  `branches`, `default_next`, `terminal`, `outcome`, `requires_confirmation` and `video_url`.
  `Procedure.Branch` (`:156`) is `id`, `condition` (free text) and `next`. Optional keys are
  decoded with `decodeIfPresent` and unknown keys are ignored, so an older build skips new fields.
- `ProcedureRunner.advance(choice:)` (`ProcedureRunner.swift`) takes the branch whose id matches
  `choice`. With no choice it follows `default_next`. Its `promptContext()` lists each branch's
  `condition` and asks the model to pick one. Every transition is logged as a `procedureStep`
  event carrying the visited stack and `branch_taken`.
- `procedure_runner` actions: `list`, `start`, `next` (with `choice`), `previous`, `repeat`,
  `status`, `complete`. There is no action for giving an answer.
- **The phone has no step screen.** The active job row shows one procedure line
  (`ActiveJobView.swift:419`). Stepping happens by voice through the model, by `HUDVoiceCommand`
  on a lens, or by the lens's branch buttons (`ProcedureHUDTaskSource.choose`).
- Plan U's `CaptureFlowRunner` already validates typed answers deterministically: `voice_number`
  with a unit and a `range`, `enum` options, `photo`, `barcode_or_voice` and `ocr_text`. It writes a
  `CaptureRecord` with provenance, which goes to the offline queue and `SessionExporter`. Its
  `range` **rejects** an out-of-range value as misheard. That is right for "is this a plausible
  reading?" and wrong for "is this reading within spec?" (§1).
- `CaptureValue.number` is a `Double`. `SpokenReading.value` keeps the text as said. Plan
  [ML](ML-measured-quantities.md) keeps stock quantities exact as thousandths, for the same reason
  this plan compares readings exactly (§2).
- `VaultPack.minAppBuild` refuses a pack that needs a newer app (`VaultCompanyLayer.swift:86`).
- On-device speech recognition is checked per locale with `supportsOnDeviceRecognition`
  (`TranscriptionService.swift:482`, `WakeWordService.swift:1631`).
- `OnDeviceJobRoutePolicy` sends job turns away from Apple's on-device model, because its
  4,096-token window can't hold a job and its manuals.

---

## Design

### 1 · A typed answer on a step

```json
{
  "id": "check_ph",
  "title": "Check the pH",
  "instruction": "Take a sample from tank 3 and read the pH meter.",
  "answer": {
    "record_as": "ph",
    "kind": "number",
    "label": "pH",
    "decimals": 2,
    "plausible": [0, 14],
    "spec": [3.8, 4.4],
    "critical": true
  },
  "branches": [
    { "id": "in_spec", "condition": "pH 3.8 to 4.4", "when": { "answer": "ph", "between": [3.8, 4.4] }, "next": "record_brix" },
    { "id": "high",    "condition": "pH above 4.4",  "when": { "answer": "ph", "gt": 4.4 },             "next": "adjust_acid" },
    { "id": "low",     "condition": "pH below 3.8",  "when": { "answer": "ph", "lt": 3.8 },             "next": "hold_batch" }
  ]
}
```

`answer` is optional and holds one answer per step. Its kinds reuse Plan U's bindings:

| `kind` | Fields | Read from |
|---|---|---|
| `number` | `unit` (optional), `decimals` 0–3 (default 0), `plausible` [lo, hi], `spec` [lo, hi] (optional) | typed on the number pad; spoken digits; spoken words ("four point two", `SpokenNumber`) |
| `choice` | `options`: 2–12 of `{ "id", "label", "says": [synonyms] }` | a tap; a lens button; a spoken label or synonym (`resolveOption`, extended with `says`) |
| `yes_no` | none | a tap; a lens button; a fixed word list (yes / yeah / done / pass; no / nope / fail) |
| `text` | `min_len`, `max_len` (default 1 and 500) | typing or dictation, kept as said |
| `photo` | `min` 1–5 (default 1), `max` up to 5 | the job photo path (§5); attached, never assessed |
| `code` | `symbology` `qr` / `barcode`; optional `expected` | on-device barcode decode; typing as a fallback |

Fields every kind shares:
- **`record_as`** names the answer in the record and in rules. It is snake_case and unique within
  the procedure.
- **`label`** is the short name printed and spoken ("pH").
- **`required`** defaults to true, so the step needs an answer before `next`.
- **`critical`** marks a critical limit (§3).

**Two ranges, with different meanings (decision 1).**
- **`plausible`** is what a reading can be at all. A value outside it is taken as misheard or
  mistyped. The app asks again ("pH 42? Read it again") and records nothing. This is Plan U's
  `range`.
- **`spec`** is what the reading should be. A value outside it is **accepted and recorded as out of
  spec**. It is a real reading, and it is the reason the check exists. Rules can test it (§2).

Steps without `answer` behave exactly as today.

### 2 · Branches the app decides

A branch gains an optional **`when`**: a small rule in JSON, not a string language, so the app
needs no parser that could misread it.

- **A test:** `{ "answer": "<record_as>", <op>: <value> }`. Ops:
  - `eq`, `ne`, `lt`, `lte`, `gt`, `gte`
  - `between` [lo, hi] and `outside` [lo, hi], both with inclusive bounds
  - `in` [option ids], for `choice`
  - `is` `"yes"` / `"no"`, for `yes_no`
  - `out_of_spec` true / false, for any kind with `spec`
  - `present` true / false, for any answer
- **Combining tests:** `{ "all": [...] }`, `{ "any": [...] }`, `{ "not": {...} }`, nested at most
  three deep.
- **Which answers a rule can use:** this step's answer or any earlier step's, so "brix low *and*
  pH high → dump" works. An answer that isn't on the path taken makes a test false, except
  `present: false`.

**Evaluation (`BranchRuleEvaluator`, pure).**
- Branches are tried in listed order, and the first rule that holds wins.
- When none holds, the runner follows `default_next` if the step has one.
- Otherwise it **stops and says so**: "pH 3.75 matches none of this step's routes". It then offers
  the branches as buttons for the person to choose, and records `decided_by: person` with the reason
  "no rule matched". It never guesses.

**Exact comparison.** A number is compared as a `Decimal` built from the entered text and rounded to
the step's `decimals`, never as a `Double`. So 4.40 against `gt 4.4` is false every time, and a
boundary means what the author wrote. The record keeps the entered text beside the value, as
`SpokenReading` does.

**`condition` stays required.** It is what an older build's model still reads, what the lens and
phone print on a button, and the rule in words for the record. The validator warns when a
`condition` reads differently from its rule (for example, numbers in the text that don't appear in
the rule).

**All or none on a step (decision 2).** A step's branches either all have `when` (the app decides)
or none do (the person or the assistant chooses, as today). A step can't be half and half.

### 3 · Who decides, and what the assistant may do

`ProcedureRunner` gains `answer(_:)` and `override(branch:reason:)`.

- **A step the app decides:** `answer` validates the value (§1), records it, and `advance()`
  evaluates the rules. A `choice` passed to `advance` is accepted only if it matches what the rules
  give. Otherwise the call is refused with the reason: "The reading decides: pH 4.6 is above 4.4,
  so the next step is *Adjust acid*". **The assistant can't override a rule.**
- **The person can override (decision 3),** on the phone or by voice, with a reason that is
  non-empty after trimming. It is recorded as `decided_by: override`, together with the branch the
  rule gave and the reason, and the record flags it.
- **Critical answers.**
  - A spoken `critical` answer is read back before it decides anything ("pH 4.6, out of spec, is
    that right?"). A typed answer is already on the screen (decision 4).
  - An out-of-spec critical answer needs a corrective note before the run continues ("added 2 L
    acid, retesting"). The note goes on the record with the reading (decision 7).
- **A step the person or assistant chooses:** unchanged. The model reads `condition`, or the person
  taps a branch.
- **`promptContext()`** for a step the app decides tells the model the answer's kind, label and
  unit, and asks it to call `procedure_runner` `answer` with the value it heard. It also tells the
  model the route follows from the answer and the model doesn't choose it. The model's job on these
  steps is to hear the value and help the person, not to judge it.
- **`procedure_runner`** gains `answer` (`value`, plus `note` for a corrective note) and `override`
  (`branch`, `reason`). The model can call `override` only on the person's spoken instruction, with
  their words as the reason, and `ToolAuthorizationPolicy` classes it as an action the person
  confirms.

### 4 · Running with no model

`ProcedureRunMode` is either `.assistant` (today) or `.noModel`.

- **When `.noModel` is used (decision 5):**
  - automatically when no usable model is configured, or when the offline hand-off finds no
    on-device model to hand to;
  - when a procedure says `"runs": "without_assistant"`, for checks a site wants rule-only every
    time;
  - when an organisation profile forces it;
  - when the person chooses it on the procedure screen.
- **The phone step screen (`ProcedureStepScreen`, new; works in both modes).** It shows:
  - the title, safety note, instruction and position (MI's "Step 3 of 12" when the procedure is
    linear), and MI's picture and needs once they exist;
  - the answer control for the step's kind, with large targets for gloves and a number pad with
    the unit beside it, plus a spec hint ("3.8 to 4.4") when the author wants the person to see it;
  - Next and Back, branch buttons on steps the person chooses, and the trail so far.

  A run started by voice or on the lens shows here too.
- **Voice without a model.**
  - The instruction is spoken with the on-device voice. On-device speech recognition listens for
    `HUDVoiceCommand`'s words (next, back, repeat) and for the step's answer, read by kind (§1).
  - Anything else gets one fixed line: "I can take the answer to this step, or next, back or
    repeat". Questions aren't answered in this mode, and the app says so rather than guessing.
  - Where the locale has no on-device recognition, the phone screen is the way in, and the app says
    so once.
- **On the lens.** The existing branch buttons, plus buttons for `choice` and `yes_no` answers. A
  number is spoken or typed on the phone, and the lens shows what was recorded.
- **Hardware.** `.noModel` uses no model, so it runs on every phone the app supports. It uses no
  Metal, so iOS's foreground-only rule for on-device models doesn't apply to it. Whether a run
  started by voice from the glasses carries on with the phone locked is measured in P4.

### 5 · The record

Each run produces one record, built from pieces that already travel:

- **Answers** fold into a `CaptureRecord` with `flowId` `procedure:<id>@<version>`, one
  `CapturedField` per answer.
  - `Provenance.method` is `typed`, `spoken`, `lens`, `scanned` or `photo`. When GX lands,
    `camera` is added, and later still, `instrument_reading`.
  - The fields gain the entered text, `spec_status` (`in` / `out` / none) and the corrective note.
  - So the offline queue's `.captureRecord` op and `SessionExporter`'s fold carry it with **no new
    op kind**.
- **The route** rides the existing `procedureStep` events, with new payload keys:
  - `decided_by`: `rule`, `person`, `assistant` or `override`;
  - `rule_text`: the rule in words ("pH 4.6 is above 4.4");
  - for an override, the branch the rule gave and the reason.
- **Photos** are attached through the job photo path (`attachPhoto`, which records whether the
  bystander filter was on) and listed by id. They are evidence only and are **not assessed**.
  Assessment is GX's work and a separate requirement. This plan adds no camera consumer. If P2
  finds the step screen needs its own capture tap, that tap gets an `OutboundFrameConsumer` roster
  entry and the filtered-still accessor, like every other one.
- **Export.** The JSON and PDF gain a "Procedure record" block. It has one row per step: the
  answer with its unit, in or out of spec, how it was entered, the route and why, notes and photo
  thumbnails. Overrides and out-of-spec rows are marked. Nothing in the block is model-written. An
  assistant's summary, when there is one, is printed apart from the block and labelled as such.
- **Sign-off** reuses `requires_confirmation` on the last step and the report identity already on
  the export.

### 6 · "Runs on this phone with no assistant": the criteria, as a fact the app states

`ProcedureReadiness` (pure) reads a procedure and returns either `.runsWithoutModel` or
`.needsModel([step: reason])`. A procedure runs without a model when:

- every step that branches has rule branches (§2), or exactly one way forward;
- every answer it records is typed (§1); and
- no step depends on anything only a model can do. Today that is a branch chosen from text. When
  GX lands, a `condition` check (judging a photo) also counts, while GX's on-device `reading`,
  `text_match` and `code` checks don't.

The import summary shows the result ("8 procedures, 6 run with no assistant; *Line changeover*
step 4 chooses its route from words"). So does the procedure list, as a badge, and the vault guide
explains it. This turns "can it work without the cloud?" from an opinion into something the author
sees for their own procedures, with the step that stops it.

What a model still adds, for the guide and for sales conversations:

| Need | No model | Model on the phone | Cloud model |
|---|---|---|---|
| Steps, typed answers, rule routes, photos attached, the record | ✅ | — | — |
| Turning a loose spoken answer into one of a few options | synonyms only | ✅ | ✅ |
| Short questions about the current step | — | ✅ (the current step only) | ✅ |
| Questions answered from manuals, a summary of a long shift | — | — | ✅ |
| Reading a label, code or digital display in a photo | ✅ (on-device text and barcode reading, GX) | — | ✅ |
| Judging a photo (seal, fill level, contamination) | — | not reliable | ✅, checked by a person (GX `condition`) |

### 7 · What the validator checks

These run in `VaultValidator.validateProcedureGraph`, so the importer, the authoring screen and
`ProcedureLibrary` share them.

**Answers:**
- `record_as` is present, snake_case and unique.
- `kind` is known, and only that kind's fields are present.
- `number`: `decimals` is 0–3, `plausible` has lo < hi, and `spec` lies inside `plausible`. A
  unit `UnitNormalizer` doesn't know is a warning.
- `choice`: 2–12 options with unique ids, and no synonym shared by two options.
- `photo`: `min` ≤ `max` ≤ 5.

**Rules:**
- Every `answer` a rule names is recorded on this step or on a step that can come before it. One
  that is reachable on only some paths is a warning.
- The op fits the kind (`gt` on a `choice` is an issue).
- `between` and `outside` have lo ≤ hi, and rules nest no more than three deep.
- A step's branches are all rules or none (decision 2).

**Coverage (`RuleCoverage`, pure).** For a step whose rules test only its own `number` answer, the
intervals are checked across `plausible`, rounded to `decimals`. A gap is a warning ("a pH of
3.75 matches no route and there is no default"), and so is an overlap ("4.4 matches both *in_spec*
and *high*; the first listed wins").

**Packs.** A pack whose procedures use `answer` or `when` sets `minAppBuild`. On an older build a
hand-copied folder runs as today, with the model choosing from `condition`, and the vault guide
says so.

### 8 · How this sits with GX and with capture flows

- **GX `check`** is the camera's evidence that a step was done, assessed on the phone or in the
  cloud. **MN `answer`** is the person's value. On one step a GX `reading` check can later
  **fill** the MN number answer (provenance `camera`), and the same rules then decide the route.
  GX's own decision 3 ("checks don't choose branches in v1") holds until then, because the rule
  reads the answer, not the verdict.
- **Plan U capture flows** stay as they are. A linear procedure whose steps have answers does
  everything a capture flow does, plus routing. Whether flows later become procedures is decision 6,
  and it isn't part of this plan.

---

## Phases

- **P0, the format and pure core (headless).** This phase covers:
  - `StepAnswer` and `BranchRule` on `Procedure.Step` / `Procedure.Branch`, with round-trip tests
    (present, absent, older JSON, unknown keys, every bundled and example procedure encoding
    byte-identically);
  - `AnswerReader` (number from typed text, digits and words, and decimal comma by locale; `choice`
    with synonyms; `yes_no`);
  - `BranchRuleEvaluator` with exact decimal comparison;
  - `RuleCoverage`, `ProcedureReadiness`, the §7 validator checks and the import summary line;
  - a worked example procedure in `examples/` (a generic bottling-line start-of-shift check with
    numbers, choices, a critical limit and photos);
  - a "Answers and routes the app decides" section in the vault guide's Step 4.

  About 45 tests.
- **P1, the runner, the record and the tool (headless).** This phase covers:
  - `ProcedureRunner.answer` and `override`, rule-decided `advance`, the refusal of a choice that
    disagrees with the rule, the read-back and the corrective note;
  - the `CaptureRecord` fold and the `procedureStep` payload keys;
  - `procedure_runner` `answer` and `override` actions, with `ToolAuthorizationPolicy` and the tool
    description;
  - the `promptContext()` lines;
  - the `SessionExporter` JSON and PDF block.

  About 35 tests.
- **P2, the phone step screen and no-model mode (simulator).** This phase covers:
  - `ProcedureStepScreen` in both modes, `ProcedureRunMode` and its triggers;
  - the voice loop without a model, the locale fallback, and lens answer buttons;
  - simulator screenshots in both appearances and at the largest text size, an accessibility audit,
    and a run with no provider configured and the network off.
- **P3, authoring.** The LW review screen gains answer and rule editing, with the coverage warnings
  shown inline. LW's `PromptKit` gains a kit that turns a procedure's existing `condition` text into
  proposed `when` rules, using the author's own model by copy and paste, and lands each one in the
  review screen beside its sentence. Nothing becomes a rule until the author saves it.
- **P4, the device pass (owed).** The phone runs in airplane mode with no model configured. A
  20-step procedure is run 20 times with scripted answers, including mumbled and off-script ones,
  in a quiet room and in machine noise. The pass measures:
  - answers captured correctly, by kind and by entry method;
  - wrong routes, which must be zero on steps the app decides;
  - seconds per step;
  - battery over an hour;
  - gloves on the number pad;
  - running from the glasses with the phone locked.

P0–P2 are one PR, per the house rhythm. P3 is another, and P4 is a device report.

---

## Decisions for Greig

**Taken 2026-11-20: all eight as recommended.** The recommended option in each item below is the
one the build follows.

1. **Two ranges per number, `plausible` and `spec` (recommended; taken).** A value outside `plausible` is
   asked again. A value outside `spec` is recorded as out of spec. The alternative is one range,
   which forces the author to choose between rejecting real out-of-spec readings and accepting
   "pH 42".
2. **A step's branches are all rules or none (recommended; taken).** This keeps "who decided this route"
   unambiguous. The alternative lets rules and model choices mix on one step, with the model
   choosing only when no rule holds.
3. **The person can override a rule with a reason; the assistant never can (recommended; taken).** The
   override is recorded and flagged. The alternative is no overrides, which leaves a wrong rule
   blocking the run until the vault is fixed.
4. **Read back a spoken critical answer before it decides (recommended; taken).** Typed answers aren't
   read back. The alternatives are reading back every spoken number, or none.
5. **When no-model mode runs (recommended; taken):** automatically when no model is usable, when a
   procedure asks for it, when an organisation profile forces it, or when the person chooses it.
   The alternative is only by choice.
6. **Capture flows stay separate in this plan (recommended; taken).** A later plan may fold Plan U's flows
   into linear procedures with answers. The alternative folds them now and migrates the bundled
   flows.
7. **An out-of-spec critical answer needs a corrective note before continuing (recommended; taken).** The
   alternative records the reading and leaves corrective action to the procedure's own next step.
8. **Included with Field Assist at no extra charge (recommended; taken),** since it uses no model and costs
   nothing to run. The alternative is a separate tier for rule-only procedures, aimed at sites that
   want no AI at all.

---

## Not in scope

- **Judging photos**, which is GX's `condition` check, and **reading values from the camera**,
  which is GX's `reading` and Plan AD's instrument reading. This plan attaches photos and records
  what the person reports.
- **An on-device model for job turns.** `OnDeviceJobRoutePolicy` is unchanged. Keeping a procedure
  turn that carries only the current step on the phone's model is a later question, to be measured
  first.
- **Compliance claims.** The record supports a site's own food-safety or quality plan. The app
  doesn't make a plan compliant, and the copy never says it does.
- **Scheduling.** Recurring checks ("every 2 hours on line 3") and reminders are not covered.
- **Sending records to a site's quality system.** Records leave by the existing export and the
  offline queue's peer. A connector to a specific system is its own plan, as Plan MM is for stock.
- **Signatures beyond the report identity and `requires_confirmation`.**

---

## Risks

- **Numbers misheard in a loud plant.** Typing on the phone is always there. A spoken critical
  answer is read back (decision 4), and `plausible` catches the gross errors. P4 measures it in
  noise.
- **Decimal commas and spoken decimals.** "4,2" and "four point two" are read by locale and tested
  in P0. The record keeps the entered text, so a misread can be seen.
- **Authors writing wrong rules.** Coverage warnings, the validator's text-against-rule warning and
  the worked example catch most of them. An override exists for the rest, and every override is on
  the record.
- **Boundary drift.** Comparing exact decimals at the step's `decimals` removes 4.4 vs
  4.3999999. P0 tests every op at its bounds.
- **Older builds.** They ignore `answer` and `when`, and the model chooses from `condition` as
  today. Packs set `minAppBuild`, and only a hand-copied folder can still reach an old build.
