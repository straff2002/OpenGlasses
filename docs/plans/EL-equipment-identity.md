# Plan EL — Equipment Identity (the session knows what is in front of the technician)

**Status:** 🚧 P1 + P2 implemented 2026-09-08 (headless); device smoke pending. P3 (nameplate fields
beyond the model) not started. Stacked on
[Plan EJ](EJ-manual-retrieval-fidelity.md) (PR #425) and [Plan EK](EK-manual-structure-and-figures.md).
**Origin:** EJ P2 measured the evidence gate against the Lennox SLP99 pair and left a residue that
words cannot close: a quarter of out-of-scope questions still get an answer, every one of them on a
subject a furnace manual genuinely covers, asked about a machine it does not — *"replace the heat
exchanger on a Carrier 58MVB"*, *"defrost board wiring on a heat pump"*. Rejecting those needs
equipment identity, not term overlap. Today identity is per question: `equipment_lookup` reads a
nameplate or a spoken model, matches it against `##` sections in the core files, answers, and
forgets. The session records an `assetId` string handed in at start and nothing else about the
machine; the gate never sees a model at all.
**Priority:** P1 for the Field Assist commercial track — it is the piece that turns "the manuals do
not cover this" from a word-overlap guess into a statement about the equipment in the room, and it
is what a customer's step-6 test actually probes.
**Surfaces:** Session state, one tool, the gate, prompt context, audit log; a line on the session
card in P2. Independent of [Plan EK](EK-manual-structure-and-figures.md).

---

## Verified starting point

- **Recognition exists, memory does not.** `EquipmentLookupTool` runs `OCRService.recognizeText`
  on the latest frame or a fresh photo, extracts `CodeTokenizer.candidateTokens`, searches core
  sections (EJ: heading matches first), falls through to the manuals, and returns text. Nothing is
  written back to the session. `FieldSession.assetId` is an opaque string set at `startSession`.
- **The vault already names its models.** The vault guide's convention, enforced by the Lennox
  example, puts every spelling of a model in that model's `##` heading (`## SLP99UH090XV60CK
  (090XV60C, -090-060C, SLP99UHXV-090-60C, SLP99UH090V60CK; …)`). Those headings are a machine-
  readable model index nobody reads by machine.
- **Codes are recognisable as codes.** `CodeTokenizer.isCodeLike` (digit-bearing, 2–14 chars)
  already separates `58MVB`, `E223`, `090XV60C` from words; nothing separates a *model* token from a
  *fault* token, and nothing asks whether a token belongs to this vault.
- **The gate is per passage.** `RetrievalEvidencePolicy.isEvidence` (EJ) sees similarity, matched
  tokens and shared terms. It has no notion of the question's subject.
- **Prompt and audit are extensible.** `VaultPromptBuilder` and `FieldSessionService.promptContext`
  concatenate blocks; `SessionLogger` appends typed events with payloads. `FieldSession` is
  `Codable` with synthesized keys, so an optional field decodes as nil from old files.

## Product promise

"Read the nameplate once. From then on the assistant knows which machine it is talking about, says
so, and refuses questions about a different one instead of answering from the wrong book."

## Design

### 1 · A model index derived from the vault

`VaultModelIndex(store:)` — pure over the core files. For every `##`/`###` heading, take the
code-like tokens that look like model numbers: `CodeTokenizer.isCodeLike` and at least 5
characters with at least 2 digits and at least 1 letter (drops fault codes like `E223` and page
refs like `p.64`; keeps `SLP99UH090XV60CK`, `090XV60C`, `SLP99UHXV-090-60C` split into its parts).
Each token maps to its heading and file. The index also exposes `knownModelTokens: Set<String>`
(uppercased). Built once per session; a vault with no such headings yields an empty index and every
identity feature below is a no-op, so bundled vaults are unaffected.

### 2 · The session holds the active equipment

`EquipmentIdentity: Codable, Equatable` — `modelToken` (as matched), `heading` (the section
title, what is spoken), `file`, `source` (`.spoken`, `.nameplate`), `recognisedAt`, and
`nameplateText` when read from the camera (kept for the audit log, never sent to a provider).
`FieldSession` gains `var equipment: EquipmentIdentity?`; `FieldSessionService` publishes
`activeEquipment`, persists it through the existing session update path, and logs
`equipmentRecognised` / `equipmentCleared` events with the heading in the payload.

`EquipmentLookupTool` sets it: when a spoken query or a nameplate read resolves to exactly one
model heading in the index, the tool records it and prefixes its answer with
`Active equipment: SLP99UH090XV60CK (from the nameplate).` A read that matches several models
lists them and asks; the tool gains `set_equipment` (a token) and `clear_equipment` arguments so
the technician can correct a wrong read by voice ("no, it's the 070"). Starting a session with an
`assetId` that itself matches a model token seeds the identity as `.asset`.

### 3 · The gate uses identity

Before retrieval, `FieldSessionService.manualPassagesContext` and both lookup tools run
`EquipmentScopeCheck`:

- Extract the turn's model-like tokens (same rule as §1, applied to the question and to any
  nameplate text). Any token **not** in `knownModelTokens` and not a substring of one is an unknown
  machine: the outcome is `.insufficient` with a specific sentence — `The loaded manuals cover
  <vault name> models <up to three headings, "and N more">; <token> is not one of them. Confirm the
  nameplate or load its manual.` The vault rules already tell the model to relay an insufficiency
  sentence verbatim.
- A turn whose model token *is* known but differs from the active equipment is not refused; it is
  answered for the model named and the prompt says so, because a technician does compare units.
- Manufacturer names without a digit are not checked (no generic list exists and a vault name is
  not a manufacturer); they ride on the model-token rule, which catches the cases EJ measured
  (`58MVB`, `XR15`, `TEM6`).

### 4 · Retrieval and the prompt scope to the machine

- When `activeEquipment` is set, `VaultRetriever` ranks down a passage that contains a known model
  token other than the active one and does not contain the active one (`score − modelMismatchPenalty`,
  default 0.5; token hits stay ahead of prose as EJ made them). Deterministic, tested with the
  Lennox tables: on an active 070, the `-090-060C Only` manifold row falls below the all-models
  row; on an active 090XV60C it rises.
- `promptContext` adds `ACTIVE EQUIPMENT: SLP99UH090XV60CK — "<heading>" (from the nameplate,
  14:02). Answer for this model; say when a passage is for another model.` and the core lookup
  tool adds the active model's section to its default search order.
- The calibration instrument (`RetrievalGateCalibrationTests`) gains model-bearing out-of-scope
  questions and reports the refusal rate with identity on, so the plan records a number.

## Phases

- **P1 — pure core (one PR).** ✅ 2026-09-07. §1 index, §2 identity type + session field + service state + logging,
  tool arguments, §3 scope check wired into the three retrieval entry points, §4 penalty and prompt
  block. Headless tests: index derivation from the Lennox core; tool sets/clears identity through a
  fresh `FieldSessionService`; scope check refuses `58MVB` and `XR15` with the named sentence and
  passes `090XV60C`; penalty ordering on the manifold rows; session round-trips `equipment` through
  Codable and decodes old sessions without it; calibration table with identity on. Full suite +
  Release before the PR.
- **P2 — the surface (one PR).** ✅ 2026-09-08. Session card and HUD status line show the active
  model; the session export lists it; the vault guide's step 6 gains "read the nameplate first" and
  the behaviour to expect for another manufacturer. Strings localised through the existing catalog.
- **P3 — deferred.** Nameplate field parsing beyond the model (serial, refrigerant, charge) into the
  identity, and using it to pre-fill capture flows.

## Acceptance

- With the Lennox vault active and no equipment set, *"how do I replace the heat exchanger on a
  Carrier 58MVB"* and *"what is the defrost board wiring on a Trane XR15"* return the scope sentence
  naming `58MVB` / `XR15` and the vault's models; *"what is the manifold pressure on high fire"* is
  unaffected.
- After `equipment_lookup` resolves `090XV60C`, the session persists `equipment`, the prompt carries
  the `ACTIVE EQUIPMENT` block, and the `-090-060C` manifold row outranks the all-models row for a
  manifold question; the reverse on an active `070`.
- `set_equipment` / `clear_equipment` work by voice through the tool and are logged.
- Bundled vaults (no model headings) behave exactly as before; every existing test stays green.

## Risks and non-goals

- **A model token in a question is not always the machine in the room** ("is the 090 the same as
  mine?"). Known-but-different is therefore answered, not refused; only unknown is refused.
- **Nameplate OCR splits tokens** (`SLP99UH 090XV60CK`). The index matches on parts as well as
  wholes, and an ambiguous read asks rather than guesses.
- **Not in scope.** Manufacturer detection without a model number, cross-vault switching on
  recognition ("this is a Carrier, load the Carrier vault"), and any change to the live sessions.

---

## P1 findings (2026-09-07)

**The token rule in §1 could not have refused the questions the Acceptance names.** "At least 5
characters with at least 2 digits and at least 1 letter" admits every spelling in the Lennox example
and excludes `E223` and `p.64`, as the design says — and it also excludes `XR15`, `XR95` and `TEM6`,
which are four characters long and are exactly the machines EJ §2 measured getting answered. It
admits two other things that are not machines: `R-454B` and `R-410A`, which is the same shape as
`E223` with one more letter, and `454B` / `060C`, which fall out of splitting a hyphenated form.
What shipped instead, tested against both lists:

- **four characters, two digits, at least one letter**, *minus* two shapes that are never a machine:
  a single letter with digits and at most one trailing letter (`E223`, `E203`, `R-410A`, `R-22` — a
  fault code or an ASHRAE refrigerant designation), and digits with one trailing letter (`454B`,
  `060C`, `36B`). `XR15`, `58MVB`, `GMVC96`, `090-060C`, `SLP99UH090XV60CK` all survive.
- **a heading token needs five**, a question's token four. A four-character heading token is more
  often a family label than a model — `30RB` / `30XA` in the bundled refrigeration vault — and a
  heading is the one place the guide can ask an author to write the model out; a question has to
  take what the technician says. This is what makes the bundled vaults' index empty, and with it
  every identity feature there a no-op, which is what the plan promised.

**A refusal now needs the turn to name *no* model the vault knows, not merely one it doesn't.** The
design says any unknown model-like token refuses. Run against a nameplate that is what it does: a
nameplate read carries a serial number (`SER 5820A12345`), which is model-like and belongs to no
model, so the camera path would have refused every machine it correctly recognised. The rule shipped
is: refuse when the text carries model-like tokens and *none* of them is anything the vault's core
names. That keeps every acceptance case (`58MVB`, `XR15` — a Lennox core says nothing about either)
and costs one edge: "is the 58MVB the same as my 090XV60C" is answered rather than refused, which is
the same call the design already made for known-but-different.

**The vault's own prose is the safety net.** A token in a heading is a model; a token anywhere else
in the core (`SLP99UHVK`, the series name in an H1; `65W77`, a changeover kit; `R-454B`) is merely
known, and a known token is never refused. Without this, "what is the AFUE of the SLP99UHVK" — the
name printed on the front of both manuals — would have been told the manuals are not about it.

**Measured, `nl-word.en`, the Lennox pair, 701 chunks** (`RetrievalGateCalibrationTests`, 17
in-scope / 18 out-of-scope after the three model-bearing questions were added):

| | insufficiency recall | in-scope questions the check refuses |
|---|---|---|
| identity off (the measured gate alone) | 0.778 (14/18) | — |
| **identity on** | **0.889 (16/18)** | **0.000** |

Recall@4 and the gate's own numbers are untouched — the scope check runs before retrieval and
refuses no in-scope question, so the default's recall@4 (0.765) and in-scope refusals (0.118) are
the EK figures unchanged. The two questions identity adds are *"how do I replace the heat exchanger
on a Carrier 58MVB"* and *"how do I wire a Trane XR95 two stage thermostat"* — both named in EJ §2
as unreachable by any lexical rule. The two still answered are *"how do I charge the refrigerant on
the outdoor unit"* and *"how do I reset the defrost board on a heat pump"*: neither names a model at
all, so identity has nothing to compare and the plan's own non-goal (no manufacturer detection
without a model number) is what leaves them. `XR15` and `GMVC96` were already refused by the lexical
gate on this corpus, so identity's contribution is 2 questions and not 3.

**The penalty moves a real row on the real manuals.** Table 39 of the service manual prints one set
of manifold pressures for every model and a second set headed `-090-060C Only`. Among the passages
that mention the manifold, that row sits at rank 8 with no identity and at rank 8 with the 090XV60C
active; on a 070 it takes the 0.5 penalty and falls to rank 29. Nothing in the words of the question
can make that choice, which is the whole argument for the feature.

**What P1 does not do.** A wiring-diagram label (`24VAXC`) is model-shaped and lives only in the
manuals, not in the core, so a turn that names one and nothing else would be refused. It has not
been seen in a spoken turn and the fix — checking the manuals' tokens as well as the core's — costs
an index over 700 chunks; recorded here rather than pre-emptively built.

---

## P2 findings (2026-09-08)

**There is one session card, and it is on the Field Assist screen.** The plan says "session card
and the main-screen session pill"; there is no main-screen pill for a field session — the main
screen carries the persona sheet's Field Assist panel (vault switcher, per-vault model, a link),
and the only place a running session is drawn is `FieldAssistSettingsView`'s **Active Session**
section. The equipment rows went there: the model token collapsed, the matched heading and
*"from the nameplate at 14:02"* expanded, **Change** listing the vault's own model headings and
**Clear**. A vault whose index is empty draws no rows at all rather than an empty picker, which is
what keeps the bundled vaults' screen identical.

**Picking a model on the phone is not a spoken correction.** The plan offered `.spoken` for the
picker; the audit record would then say the technician read the model out when they tapped a row.
`EquipmentIdentity.Source` gained `.manual` ("picked on the phone") instead — a new case on a
`String`-backed `Codable` enum, so every session written by P1 still decodes.

**The lens gets a flash, not a status bar.** The HUD has no persistent status line to add a field
to: `showText`/`showNavigation` own the ambient frame, and an interactive task card suppresses
anything persistent. So identity reuses the figure cue's path exactly — a transient
`showNotification` of `SLP99UH090XV60CK · Lennox SLP99 Furnace Service`, five seconds, on every
change. The nil a session end publishes is filtered out (the session is already gone by then), so
ending a session does not flash "No equipment set" at a technician who is walking away.

**The work order prints the machine first.** `Equipment: SLP99UH090XV60CK — from the nameplate at
14:02` is the first summary line, above `Asset:` — a reviewer of a refrigerant log or a warranty
claim asks what unit before anything else. The plate's own text stays in the event log where P1
wrote it; the exported document names the machine, not the plate, and a test asserts the serial
number never reaches the JSON. `equipment` is an optional field with a synthesized key, so an audit
exported before this decodes with it nil and prints nothing.

**Step 6 could not open with the nameplate.** The plan asks for "a new first item"; item 1 chooses
a vault and item 2 starts the session, and neither can be preceded by reading a plate. It is the
first thing done *inside* the session (item 3), and it absorbed the old item 4, which said the same
thing with none of the consequences. The old item 5's paragraph also had to change: it told the
reader that a question about a subject the manuals cover asked about a machine they do not is
**not** refused, which is exactly what P1 made false for a vault with model headings.

