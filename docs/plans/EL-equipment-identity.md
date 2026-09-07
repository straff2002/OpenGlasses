# Plan EL — Equipment Identity (the session knows what is in front of the technician)

**Status:** 📋 Planned 2026-09-07. Stacked on [Plan EJ](EJ-manual-retrieval-fidelity.md) (PR #425).
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

- **P1 — pure core (one PR).** §1 index, §2 identity type + session field + service state + logging,
  tool arguments, §3 scope check wired into the three retrieval entry points, §4 penalty and prompt
  block. Headless tests: index derivation from the Lennox core; tool sets/clears identity through a
  fresh `FieldSessionService`; scope check refuses `58MVB` and `XR15` with the named sentence and
  passes `090XV60C`; penalty ordering on the manifold rows; session round-trips `equipment` through
  Codable and decodes old sessions without it; calibration table with identity on. Full suite +
  Release before the PR.
- **P2 — the surface (one PR).** Session card and HUD status line show the active model; the
  session export lists it; the vault guide's step 6 gains "read the nameplate first" and the
  behaviour to expect for another manufacturer. Strings localised through the existing catalog.
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
