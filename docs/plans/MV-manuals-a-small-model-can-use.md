# Plan MV — Manuals a Small Model Can Use

**Status:** 📝 Drafted 2026-11-21 · nothing built · 10 decisions below, each with a recommendation

The owner wants Field Assist to run on a downloaded model (Gemma 4 E2B, a Qwen-class 1.5–4B, 4K–8K
windows) so that cloud AI costs fall: "i want local, how can we break down manuals to be easier to
use for local?" [Plan MQ](MQ-local-model-tool-harness-and-qualification.md) fixes the tool harness and
found that the Lennox example vault's job context alone is 7.8k–10k tokens, more than any catalog
model can hold. MQ P1 replaces that block with a compact job tier, and the model then reaches manual
content only through tools.

This plan decides what those tools hand back. **The app reads the manual; the small model doesn't.**
A 2B model is good at understanding the question, picking the lookup and phrasing a short answer. It
is bad at choosing the right row from a big table and at copying numbers exactly. So the manual is
broken down once, ahead of time, into typed facts the app finds and speaks itself, and short cards
for the prose, until the model has almost nothing to read.

## What happens today (read from the code, 2026-11-21)

1. **The whole core rides every turn, on every provider.** `FieldSessionService.promptContext` calls
   `VaultPromptBuilder.promptContext`, bounded by `VaultPromptBuilder.referenceByteLimit`. That is
   `VaultValidator.coreBudgetCharacters` (32,768 characters) for every provider but ChatGPT, `.local`
   included. A file named `safety` is never omitted. MQ's `FieldAssistContextAuditTests` measured the
   result on the Lennox vault: 7,792 tokens with a job open, against a 3,456-token prompt budget on a
   4K model (`LocalModelBudget.promptBudget`).
2. **A vault's own tables are text to the model, not lookups.** `table_lookup` (`TableLookupTool`)
   resolves only against `DocumentStore.storedTables`: tables `TableExtractor` / `PDFTableReader`
   pulled from a loaded PDF at import (Plan JJ), plus photographed manuals (Plan JN). The pipe tables
   in a core file, such as the five in `service_values.md`, are never sources. The example vault's
   manuals are not committed, so there `table_lookup` answers `.noTables` and the manifold table
   reaches the model only as markdown inside the core block.
3. **Typed structures already exist, without conditions or scope.**
   - `ManualTable` (`Services/Vault/TableExtractor.swift`) holds rows by header path, cells with
     `value`, `unit` and footnote `markers`, each row's printed page, notes, and the uncertainty of
     a cell read from a picture.
   - `TableRowPassage` writes one searchable sentence per row.
   - `TableLookup.resolve` never interpolates. It returns both rows when a number falls between
     them, and asks when the words fit more than one row, column, table or book.
   - `VaultModelIndex` reads every model spelling from `##` headings. `VaultPartsIndex` reads
     `| Part | Description | Fits | Supersedes |` tables. Both are pure over the core text, and
     both are empty for a vault without the convention.

   None of these knows that a row is "low fire, natural gas, 090XV60C only". JJ decision 1 says an
   extracted table is derived on the phone from the organisation's own PDF and never shipped in a
   pack, export or link.
4. **The unit on the job scopes passages, not rows.** `equipment_lookup` and the nameplate read set
   `FieldSessionService.activeEquipment` (`EquipmentIdentity`). `equipmentScope(turn:)` refuses
   passages about a machine the vault isn't for. Nothing removes the rows of a table that don't
   apply to the unit, so a 090XV60C job still gets all four manifold rows. The row a small model
   gets wrong is "Low, all models except 090XV60C" against "Low, 090XV60C natural gas".
5. **Passages are already card-sized, but not self-contained.** `DocumentChunker` packs to 700
   characters (900 at most) with 100 of overlap, about 175–225 tokens, and `VaultRetriever` hands
   over 4 (`Request.limit`). A passage keeps its `section`, but a chunk can start mid-section on
   overlap. Units stay as printed ("in. w.c.", "SM p.67"). `ManualReadingCheck` (MQ P0) exists;
   MP's `ManualPassageFitter` doesn't.
6. **No Field Assist answer works without a model.** `OfflineKeywordRouter.route` serves the time,
   timers, notes, parking, objects and step count. `fieldToolHints` only orders the tools offered
   (MQ P0). With the phone locked no Metal model runs (Plan GE's ladder), so every manual question
   is held.
7. **Authoring covers codes, models and symptoms, not values.** Plan LW built:
   - `FaultCodeProposals` from `TableExtractor` tables;
   - `PromptKit` and `PastedDraftParser` (`Tools/LicenceIssuance/VaultDrafts.swift`) for
     bring-your-own-model drafts;
   - `DraftRowCheck`, which checks every pasted row against the manual's page text on the phone;
   - `TradeTemplate` in the core package.

   No layer exists for service values or their conditions. LW decision 2: the app drafts with no
   model of its own.
8. **The corpus parses the vault a second time.** `Scripts/local-tool-eval/generate-corpus.py` has
   its own markdown table reader (`sections`, `tables`, `table_passage`). It also scripts `reading`
   results that name the manual's range ("inside it"), which the shipped `ReadingTool` never does.

## Design

### 1 · Facts as typed records

A **`ManualFact`** is one value cell of one table row:

| Field | Example |
|---|---|
| `quantity` | manifold pressure |
| `conditions` | firing rate = low · fuel = natural gas |
| `scope` | models 090XV60C · or all models except 090XV60C · or unread |
| `value` | range 0.30–0.85 (or a single value, or a word such as "manual reset") |
| `unit` | `in. w.c.`, spoken "inches of water column" |
| `source` | file `service_values.md`, table "Table 39", document "Service Manual", page 67 |
| `row`, `column` | the header paths as printed, kept for the read-back and `show_source` |

Facts are **built from `ManualTable`**, never beside it. P0 adds a `CoreTableReader` that turns a
core file's pipe tables into `ManualTable`s (in memory, a new `Source` case for the vault core,
never stored in `doc_tables`). `FactReader` then turns any `ManualTable` row and column into facts,
whether it came from a core file, a PDF or a photographed page. So `TableLookup`, the row passages
and the uncertainty rules stay the one implementation.

`FactReader` reads conditions and scope from the row and column headings through the vault's
vocabulary (§4), deterministically:

- "Low, all models except 090XV60C" → firing rate low, scope all but 090XV60C;
- "Manifold, natural gas" (column) → quantity manifold pressure, fuel natural gas;
- "-090XV36C/48C" → 090XV36C and 090XV48C, read against `VaultModelIndex`;
- "-090" → the three models in the 090 input group.

A heading it can't read leaves the fact's scope **unread**. An unread fact is never hidden by
scoping; it is given with its row label read out as printed. Citations come from the section
heading ("TABLE 39 SM p.67, TABLE 35 II p.64") where the vault writes them that way, and fall back to
the file and heading, as the vault's `source_attribution_format` does today.

Worked example, `service_values.md`'s manifold table:

- High fire · natural gas · all models → 3.0–3.8 in. w.c. (Table 39, SM p.67)
- Low fire · natural gas · all models except 090XV60C → 0.40–0.95 in. w.c.
- Low fire · natural gas · 090XV60C → 0.30–0.85 in. w.c.
- Low fire · LP · 090XV60C → 1.2–2.8 in. w.c.

The section's nameplate line ("3.5 in. w.g. natural … at maximum input") is a different quantity
(manifold pressure, nameplate) and stays a separate fact, so "what's the manifold pressure" on high
fire never mixes the two.

The same reader covers diagnostic codes (code → meaning, action), parts (`VaultPartsIndex`'s rows
become facts with `fits` read as scope), clearances, timings and model and size codes. A code
table's "value" is its meaning and action text, said as written.

### 2 · Scoped to the unit on the job

`FactScope.applies(to: EquipmentIdentity?)` answers **applies / excluded / unread**. A lookup drops
only the excluded facts. With the 090XV60C on the job, "low fire manifold" has one natural-gas
answer. With no unit known, a question whose facts differ only by model gets the question back
("Which model is it?"), the same as `TableLookup`'s `.ambiguous` today. No model is involved in
either.

### 3 · The app speaks the fact

The model's job is to fill a lookup's arguments: what is asked, and the conditions it heard. The app
finds the fact and speaks it from a template:

> "Low fire, natural gas, on the 090XV60C: manifold pressure 0.30 to 0.85 inches of water column.
> Table 39, service manual page 67."

`FactAnswer` holds the spoken form (units and abbreviations written out from the vocabulary), the
display form (as printed) and the citation. On the local path the model does not rephrase it, so
the numbers cannot drift (decision 4). When the words fit several facts, the app asks which one
("Low fire or high fire?"), using only the conditions that tell them apart.

With facts in place, a logged reading can be compared too. "Manifold 0.6 on low fire" gets "inside
the manual's 0.30 to 0.85 range" or "below it". It never gets "OK", and never advice to adjust: the
vault's rules say the gas valve is factory set. That is the result MQ's corpus already scripts for
`reading`.

### 4 · Technician vocabulary

The words technicians say map onto fact fields:

- "inches of water", "inches w.c." → `in. w.c.`;
- "gas valve outlet" → the manifold tap, so manifold pressure;
- "the board" → integrated control;
- "propane" → LP;
- "high side" or "second stage" → high fire, where the vault says so.

Vocabulary comes from two places:

- **Trade-wide words** live in `TradeTemplate` (the core package), so every HVAC-R vault gets them.
- **Vault words** live in the vault's own optional `facts.json`, because the same phrase differs
  by vault. "Low side" is suction pressure on an air-conditioning vault and means nothing on this
  furnace, so it must never be read there as low fire.

A company layer may add words (add-only, as LR/LV layers are) and never redefines a base word.

With vocabulary and scope, `OfflineKeywordRouter` gains a Field Assist route. When a turn names one
quantity, every condition that separates its facts and an active unit, and those resolve to exactly
one fact, the fact is said with no model at all. That covers the locked phone, where no Metal model
runs. Anything less certain is held, as GE holds it today (decision 10).

### 5 · Cards for the prose

A **`ManualCard`** is one self-contained piece of prose, 100–200 tokens:

- it starts with its heading path ("Service values › Flame signal");
- its units and abbreviations are written out ("Service Manual", "inches of water column");
- it is cut at sentence or bullet boundaries with no overlap.

From a core file, `CardBuilder` makes cards at install from the `##` sections: the Lennox
"Heating sequence timings" section (837 characters, about 210 tokens, over the cap) becomes two
cards. From a manual, a card is
the existing retrieved chunk with its `section` path put in front and the vocabulary's expansions
applied. P0 measures before anything re-chunks (decision 6).

On a local reader turn the app retrieves at most two cards, and the model answers from them or says
it isn't in the manual. This is MP's reader shape: a tool-less turn that returns
`found / answer / passage / quote`, and `ManualReadingCheck` accepts it only when the quote and every
number with a unit are in the cited card.

**Safety cards ride along.** `safety.md`'s sections are already by hazard (electrical, gas,
refrigerant). A card or fact that touches gas, power or pressure (the trade template's hazard words
plus the vault's) brings the matching safety card. The manifest's `prompt_rules` stay in every
prompt.

What a 4K window holds on a reader turn (budget 3,456; the tokens are the local path's own estimate):

| Part | Tokens |
|---|---:|
| Persona, rules, the vault's `prompt_rules` | ~1,000 (to confirm on the local prompt) |
| Job tier (MQ P1) | ≤ 400 |
| Tool definitions | 0 on a reader turn (≤ 864 on an action turn) |
| Two cards | ≤ 400 |
| One safety card | ≤ 150 |
| History and the turn | the rest, about 1,500 |

### 6 · Procedures stay as they are

Procedures are already structured JSON run by `ProcedureRunner`, with MN's typed answers and the
no-model voice. MV changes nothing in them. A step that asks for a value the vault has facts for
can name the fact in a later plan.

### 7 · Where the breakdown happens

- **(a) Core files: on the phone, at install, deterministically.** `CoreTableReader`, `FactReader`
  and `CardBuilder` run over the merged core (base plus any company layer), as `VaultModelIndex`
  and `VaultPartsIndex` do today. They are cached by vault id, version and a hash of the core.
  Nothing new has to ship for the example vault or for a hand-authored vault.
- **(b) A customer's PDFs: on the phone, at import, from the organisation's own copy.** Facts come
  from the `ManualTable`s JJ already extracts there, and cards from the chunks. They are stored
  beside the document, like its tables, and never packed or exported (JJ decision 1, Plan FS). What
  a person adds is the part the reader can't infer. Through LW's authoring, a vault's `facts.json`
  carries **annotations only**: for "Table 39, row 'Low, 090XV60C natural gas'", the scope is
  090XV60C and the fuel is natural gas. It carries no values. Each company's phone fills the values
  from its own PDF, so a published vault (LV) ships no table content. The annotations are written
  in three ways:
  - LW's review screen proposes them, one card per table ("Table 39: 3 rows whose models I couldn't
    read. Check them?"), Keep / Edit / Skip;
  - a bring-your-own-model `PromptKit` layer has the return format
    `table | row as printed | models | conditions | page`;
  - by hand.

  `DraftRowCheck` checks every pasted row against the page. Avenkin runs no model for this
  (LW decision 2 stands; decision 5).
- **Fit with the existing plans:**
  - **LW:** a fourth authoring layer beside codes, model map and symptoms.
  - **LV:** `facts.json` is a core-side file, so it is sealed with the core, and its annotations are
    checked against `expects`.
  - **LR:** delivered like any company vault file.
  - **EG:** a pack may carry `facts.json`, never a table.
  - **FR:** when the fictional vault replaces the Lennox one, only the fixtures change; nothing in
    the reader names a manufacturer.

### 8 · The same facts generate the tests

P0's tests write the Lennox facts to a committed JSON fixture (the regenerate-and-compare pattern the
contract fixtures use). `generate-corpus.py` reads its service values, codes and parts from that
fixture instead of parsing the markdown a second time. So MQ's corpus follows the facts, and a
reader change that alters a fact fails the corpus hash check in CI. New categories:

- scoped facts: the wrong model's row must not be said;
- condition questions asked back;
- keyword-routed answers with no model;
- reader turns over cards.

## Phases (one PR each)

- **P0 — headless core.**
  - `ManualFact`, `FactScope`, `FactCondition`, `FactAnswer`; `CoreTableReader` (core pipe tables
    → `ManualTable`); `FactReader`; `FactVocabulary` (trade words from `TradeTemplate`, vault
    words from `facts.json`, with its decoder and `schema_version`);
    `FactScope.applies(to:)`; `FactResolver` (arguments plus the turn's own words → one fact,
    a question back, or nothing); the spoken, display and citation templates.
  - `ManualCard` and `CardBuilder` for core prose, and the safety-card pick.
  - The budget table as a test against `LocalModelBudget`.
  - Tests on the Lennox core:
    - every numeric cell of `service_values.md` becomes a fact, with the four manifold rows above
      exact;
    - `-090XV36C/48C` and `-090` scope as stated;
    - no excluded fact survives a 090XV60C scope, and no unread one is dropped;
    - "low fire manifold" with no unit asks for the model;
    - every code and part becomes a fact;
    - `CardBuilder` keeps every card ≤ 200 tokens with its heading path.
  - The facts fixture and `generate-corpus.py` reading it, with the corpus regenerated.
- **P1 — wired into `table_lookup` and the local path**, behind `Config.manualFactsEnabled`
  (default off).
  - Core tables become `table_lookup` sources.
  - `table_lookup` takes `what` and `condition` beside `table` / `row` / `column`. The short local
    wording goes in JD's planned `onDeviceDescription`, which isn't built yet; if it still isn't
    here, it lands with this phase.
  - A turn-scoped `FactAnswer` that MQ's `LocalToolLoop` speaks as is. How the loop learns a
    result is final is to settle here; `noteLookedUpTable` is the existing pattern for a tool
    leaving state for the turn.
  - The local job tier carries no core files: a line saying which facts and cards the vault has,
    the safety rules, and cards on reader turns (with MQ P1's job tier and MP's reader).
  - `ReadingTool`'s range comparison.
  - The `OfflineKeywordRouter` fact route.
  - `show_source` on a fact opens the cited manual page when that manual is on the phone (through
    its printed-page map), and otherwise reads the citation.
- **P2 — manuals and authoring.**
  - Facts and cards from imported PDFs' `ManualTable`s and chunks, at import and on the stored
    manuals' migration, stored beside the document.
  - `facts.json` annotations: LW's proposal card, the `PromptKit` layer with `PastedDraftParser`
    and `DraftRowCheck`, the validator's checks (a row that names no table or row in the vault's
    manuals is warned of and kept, as JJ treats chains), and the vault guide section.
  - LW's vault check gains fact questions.
- **P3 — device pass (owed, not automatable).** On a downloaded model in airplane mode, on each RAM
  tier MQ qualifies:
  - a scoped value with the unit set, and the model asked for with it unset;
  - a condition asked back;
  - a reading compared;
  - a card answer and a decline;
  - the same value with the phone locked (keyword route), and a held question.

  Record, through MQ P3's runner, the Field Assist group with facts on and off.

## Decisions

1. **Facts derived on the phone, or shipped in the vault?** *Recommend derived* (at install for the
   core, at import for manuals), with `facts.json` for annotations and vocabulary only. Nothing new
   ships with a hand-authored vault, and no table content leaves a phone.
2. **Versioning.** *Recommend a `schema_version` inside `facts.json` and a new optional manifest key
   `facts` naming it.* The file is kept out of the prompt the way `chains.md` and table checks are.
   An older build ignores the key, since unknown manifest keys don't fail decoding. A newer major
   version is refused with a validator warning, and the vault still installs. Derived facts carry
   the reader's version in their cache key, so a reader change rebuilds them.
3. **Does the cloud path use facts too?** *Recommend yes for `table_lookup`'s resolution* (one
   resolver, scoped and exact for every model), while the core tier stays in the cloud prompt as
   today. Template answers spoken as is and the keyword route are local only at first.
4. **May the local model reword a fact?** *Recommend no*: the app's sentence is spoken as is. The
   model may ask a follow-up on the next turn.
5. **Authoring model and review rules.** *Recommend LW's rules unchanged*:
   - deterministic proposals on the phone;
   - an author's own model only by copy and paste;
   - every pasted row checked against its page;
   - Keep / Edit / Skip per card, *keep all checked* and never *keep all*;
   - no Avenkin-run extraction service. An Avenkin cloud model reading customer manuals would be a
     new processor of licensed text, needing its own disclosure and organisation key (as MP's
     `apple_cloud`).
6. **Card size.** *Recommend at most 200 tokens (800 characters), two cards plus one safety card a
   turn on a 4K window, three on 8K.* P0 measures how many of today's chunks already fit before any
   re-chunking. The chunker's 700/900 targets are left alone unless P2's retrieval eval says
   otherwise.
7. **Who owns the vocabulary.** *Recommend:*
   - trade words in `TradeTemplate`, maintained with the app;
   - vault words in `facts.json`, the author's;
   - a company layer adds and never redefines;
   - no per-technician words yet.
8. **Old vaults.** *Recommend no migration.* A vault with no tables has no facts, and its local
   reader turns use cards from its prose and chunks. A vault whose rows can't be scoped gets
   unread-scope facts that are never hidden. The cloud path is unchanged either way.
9. **`safety.md` on the local path: whole, or as cards?** *Recommend cards by hazard on the local
   path only*, with the manifest's safety rules in every prompt. The whole file is about 1,150
   tokens, a third of a 4K budget. The cloud path keeps it whole and protected, as today.
10. **Model-free answers with the phone locked.** *Recommend yes, behind the flag*: only a single
    fact that is unit-scoped, with every separating condition said. Anything else is held.

## Non-goals

- Shipping extracted tables, manual text or values from a customer's PDF in any pack, export or link
  (JJ decision 1, Plan FS).
- A model of Avenkin's own reading manuals, on the phone or in a service.
- Changing procedures, `ProcedureRunner` or MN's answers.
- Judging a reading as good or bad, or advising an adjustment.
- Fine-tuning a model, or a new embedder or ranking. Retrieval is FQ's and IV's.
- Vision and photographed-page reading beyond what JN already extracts.
- The tool harness and model qualification, which are MQ's; Apple's reader and PCC, which are MP's.
