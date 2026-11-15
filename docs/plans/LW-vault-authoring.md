# Plan LW — Vault Authoring (build a vault from your manuals on the phone, and get help with the hard parts)

**Status:** 📝 Drafted 2026-11-15, nothing implemented. Six [decisions](#decisions-for-greig) open.
**Track:** Field Assist — your own vaults. Custom Vaults, manual import, the vault editor, export.
**Builds on:**
- Plan [JK](JK-my-manuals.md) / My Manuals: `ManualFileUpload`, the upload sheet (PDF, Word, Markdown, a publisher
  link, photographed pages), `PersonalManualLibrary`.
- Plan [FS](FS-subscriber-vaults-and-vault-links.md): `FieldAssistCapability.ownVaults`, the archive format,
  export without manuals.
- Plan [Q](Q-vault-and-skills-library-management.md): `VaultFilesEditorView`, in-app editing of core files.
- Plans [JJ](JJ-table-lookup-and-rule-chains.md)/[KR](KR-the-page-it-says.md): `TableExtractor` and `PDFTableReader`, which find tables on a
  manual's pages, numbered row heads and row groups included.
- Plan [EL](EL-equipment-identity.md): `VaultModelIndex` (model tokens from `##` headings), `EquipmentIdentity`,
  and the nameplate read in `EquipmentLookupTool`.
- Plan [IV](IV-manual-retrieval-rounds.md): measuring retrieval against questions with a known answer page.
- Plan [IF](IF-photographed-manuals.md): photographed pages become a manual.

**Sits beside:** Plan [LV](LV-published-vaults.md), which publishes what this plan builds to many companies, and
the private service plan `published-vaults.md`, whose partner library takes the export this plan writes.

---

## Trigger

Two people want the same thing.

- **A solo Field Assist subscriber** wants a vault for the equipment they service. Custom Vaults offers them
  *Import Vault Folder…*, a folder they would write by hand on a computer from the vault guide, and *Add from
  Link or QR…*. The cheaper My Manuals plan has an *Upload manual* button. The person paying more does more work.
- **A partner who writes vaults to sell** (Plan LV) writes the core files by hand, runs
  `Scripts/make-vault-archive.swift` on a Mac, and uploads the archive.

Both need the same three things done well, because they are what make a vault answer well, and all three are
written by hand today:
1. **The fault codes:** which code means what, and the page that says so.
2. **The model-to-manual map:** which manual covers the unit on the nameplate.
3. **The symptoms in a technician's words:** "not cooling, compressor running" → the section that answers it.

## Outcome

- A solo subscriber taps **New Vault…**, gives it a name, picks a trade and lists the models (or leaves them for
  later). The vault exists and works from the first manual added: manual retrieval answers from the manuals
  alone.
- They add manuals the way My Manuals does: a file, a publisher link or photographed pages.
- When a manual finishes indexing, the phone proposes work for the three layers, one card at a time:
  *"Found 3 fault-code tables on pages 41–44. Add 38 codes?"*, *"This manual names 4 models. Add them to the
  map?"*, *"Found a troubleshooting chart on page 60. Draft 12 symptoms?"*. Each card is **Keep / Edit /
  Skip**. Nothing is written without a tap.
- At a unit, *"Add this model"* photographs the nameplate, reads the model and asks which manual covers it.
- **Vault check** runs the trade's starter questions and the author's own, each with the page that should
  answer it, and says *"18 of 20 questions find the right page"*, naming the two that don't.
- A partner builds the same way on their own phone with their own manuals, then **exports** the vault: the
  core files and the list of manuals it expects, without the manuals. They upload that in the portal (Plan LV).
- A My Manuals subscriber who moves up to Field Assist is offered *"Move your manuals into a vault"*.

## What exists, and what doesn't

**Exists (verified against `main` at 8ce913936):**
- `FieldAssistCapability`: a Field Assist store subscription grants `.fieldWork, .bundledVaults, .ownVaults`; a
  My Manuals subscription grants only `.personalManuals`. **An org licence at `.solo` grants `.fieldWork,
  .bundledVaults` without `.ownVaults`**, so a solo operator on a licence code cannot build a vault at all
  ([decision 6](#decisions-for-greig)).
- `PersonalManualLibrary.addPrepared` builds a vault behind the scenes (`id: "my-manuals"`, documents only,
  `gating.iap = "my_manuals"`) and installs it with `origin: .personalPDF`. `ManualQuota` holds the personal
  limits (5 manuals, page caps, additions per 30 days).
- `VaultValidator.validate(directory:manualOnly:)` and `VaultPackRules.manifestIssues` (in the core package): a
  manifest needs `id`, `name`, `version`, at least one file or document, and, unless manual-only,
  `prompt_rules` mentioning *fabricate* and *cite*; every listed file present and non-empty.
- **No code builds an authored vault from scratch.** Manifests are built only for My Manuals, captured
  manuals, and copies made by `VaultDocumentCarry` and `VaultManualRemoval`.
- `TableExtractor` is geometry over `PositionedWord`s (`import CoreGraphics`). `PDFTableReader` gets those words
  from PDFKit, and `VisionTableReader` from photographed tables. `TableLookup` serves `table_lookup`.
- `VaultModelIndex` reads every spelling of a model from a `##` heading: `## MODEL (alias, alias)`.
  `EquipmentLookupTool` reads a nameplate with OCR and pulls model-like tokens (`CodeTokenizer.candidateTokens`).
- `VaultFilesEditorView` edits only files already listed in `manifest.files`. It cannot add one.
- `VaultExporter` exports a user-imported or free vault in the import format, never its manuals.
- `Scripts/extract-manual-text.swift` (Mac) writes page text as Markdown with headings and figure/table
  captions. It does not extract table grids.
- The licence service runs on Linux. PDFKit is not there, so the table reading cannot run on the service as it is.

**Doesn't exist:**
1. *New Vault* on the phone, and a starter that passes the validator.
2. *Add manual* to a vault the subscriber owns.
3. Proposals for the three layers.
4. Adding a file in the editor.
5. A vault check with expected pages.
6. An export that says which manuals the vault was written against.
7. Trade templates.

## Design

### 1 · `VaultStarter` (pure, in the core package)

Input: name, trade template, models (optional). Output: a manifest and core files that pass
`VaultPackRules`:
- `prompt_rules.md` from the template (the *fabricate* and *cite* themes always present);
- `safety.md` from the template's starter, which the author edits;
- `models.md`, one `## MODEL (aliases)` heading per model, so `VaultModelIndex` reads it unchanged;
- `fault-codes.md` and `symptoms.md` with their headings and nothing else.

It lives in `Tools/LicenceIssuance` so the portal can make the same starter from a form later (the service
plan), and so the phone and the service cannot drift.

### 2 · Trade templates (`TradeTemplate`, data)

A template is data, not code:
- **identity:** how a unit is named (nameplate model and serial; a VIN; a part number), and the token pattern
  for it;
- **codes:** what a fault code looks like in this trade (a manufacturer's two- or three-character codes; a
  five-character diagnostic code such as `P0300`);
- **safety starter** and **symptom headings**;
- **starter questions** for the vault check, each with the kind of page that should answer it.

P0 ships **HVAC-R** and **General**. P2 adds **Automotive**, with a VIN as the identity. A VIN's structure
(manufacturer prefix, model year, check digit) is read on the phone with no lookup service; a decode service
would be a new egress and is out of scope. Further trades (electrical, plumbing, lifts, IT) follow as their
templates are written, ideally with an author in that trade.

### 3 · New Vault and Add manual

- **New Vault…** on Custom Vaults, for `.ownVaults`: name, trade, models. The vault installs through the
  existing import path as user-imported, so it is editable and exportable like a hand-built one.
- **Add manual** on a vault the subscriber owns reuses `ManualFileUpload` and the upload sheet from My Manuals
  (file, publisher link, photographed pages). The limits are the per-file caps only, with no `ManualQuota`
  ([decision 3](#decisions-for-greig)).
- Each added manual records its `revision` (content hash) and `edition` (from the author, or proposed from the
  cover page), using Plan LV's `VaultDocument.revision`.

### 4 · Proposals (pure builders, a review screen)

Each builder runs on the phone after a manual indexes and returns proposals. None writes to the vault; the
review screen does, on *Keep*.

- **`FaultCodeProposals`:** `TableExtractor` tables whose first column matches the template's code pattern →
  rows of *code · short label · manual · page*. The label is prefilled from the table and marked *in the
  manual's words* until the author rewrites it. In a private vault that is fine (it is the subscriber's own
  copy). The export's publishing check (§7) lists rows still in the manual's words.
- **`ModelMapProposals`:** model-like tokens from the cover pages and the first specification tables, grouped by
  the template's identity pattern → *"These 4 models, covered by this manual?"*. Aliases group under one heading.
- **`SymptomProposals`:** troubleshooting tables and headings (*Symptom / Possible cause / Check*) → one draft
  symptom per row, pointing at its page. The author rewrites the symptom in a technician's words. This is where
  most of the author's know-how goes in, and the proposal only saves typing.
- **Nameplate → map:** *"Add this model"* reuses `EquipmentLookupTool`'s nameplate read: the tokens it finds,
  then *"Which manual covers it?"* with the vault's manuals listed.
- **The review screen:** one card per proposal, grouped by manual, with **Keep / Edit / Skip** and the page shown
  beside each row. *Keep all* exists per card, never per vault.

Drafting with a language model is off by default ([decision 2](#decisions-for-greig)). The builders above are
deterministic and on the phone.

### 5 · Add a file

`VaultFilesEditorView` gains *Add file* (a Markdown file with a name the author gives), listed in
`manifest.files`. A starter vault grows by adding files; so would a company layer authored on a phone later.

### 6 · Vault check (`VaultCheck`, pure scoring)

Questions come from the template's starter set and the author's own, each with an expected manual and page. The
check runs retrieval only (no model, no network) and scores whether the expected page is among the passages.
The screen shows the score and the misses, each with *what it found instead*. It reruns when a manual or file
changes. This is IV's measuring idea on the author's own vault.

### 7 · Export for publishing

The existing export gains:
- `expects` in the manifest: each manual's key, title, edition and `revision`, for Plan LV's checklist. The
  manuals themselves stay out, as now;
- a **publishing check** before the share sheet: rows still in the manual's words, models with no manual, a
  vault check below the author's own threshold. Warnings, not blocks. A private export shows none of them.

The partner uploads this export in the portal. Publishing straight from the app needs a partner sign-in in the
app, which is out of scope.

### 8 · My Manuals → a vault

When `.ownVaults` arrives on a phone holding `my-manuals`, a one-time card offers *"Move your manuals into a
vault"*: New Vault with those manuals already in it, then the personal library is emptied
([decision 5](#decisions-for-greig)).

### 9 · Where the work runs

On the phone, for the solo subscriber and the partner alike ([decision 1](#decisions-for-greig)). The table
reading needs PDFKit, which the Linux service doesn't have, and keeping the manuals on the phone means the
service never reads one. The portal's part is publishing (Plan LV and the service plan), plus at most a
plain editor for the Markdown files later.

## Decisions for Greig

1. **Where drafting runs.** *Recommended:* on the phone, for partners too. The partner authors on their own
   phone with their own copies and uploads the export. The service never reads a manual, so nothing about
   server-side processing needs disclosing. Not recommended: a drafting workspace on the service, which needs a
   second PDF reader on Linux (the table geometry is pure, but the word positions come from PDFKit) and puts
   the vendor in the business of processing manuals.
2. **Drafting with a language model.** *Recommended:* off for now; deterministic builders only. Turning it on
   later sends manual text to the wearer's chosen provider, and needs a line in the privacy copy. Not
   recommended: model-drafted symptoms in P1, which reads well but sends manuals off the phone by default.
3. **Limits on a solo subscriber's own vaults.** *Recommended:* the per-file caps and the phone's free space
   only. `.fieldWork` already separates a solo subscriber from My Manuals. Not recommended: a manual count, which
   a working technician would hit.
4. **The publishing check.** *Recommended:* warnings only, shown only on export. The author decides. Not
   recommended: blocking export on rows in the manual's words, which would stop a partner exporting to their own
   second phone.
5. **My Manuals carry-over.** *Recommended:* move, so there aren't two copies of every manual. Not
   recommended: copy and keep both, which doubles storage for nothing.
6. **`.ownVaults` for an org licence at `.solo`.** *Recommended:* grant it, so a solo operator on a licence code
   has what a solo store subscriber has. The reason it is missing isn't recorded in the plans; check Plan EE's
   history before changing it. Not recommended: leave it, which means a licence-code solo operator can't use
   this plan at all.

## Phases

### P0 — the pure core (headless)

`VaultStarter` and its tests in the core package (every template's starter passes `VaultPackRules`);
`TradeTemplate` with HVAC-R and General; `FaultCodeProposals`, `ModelMapProposals`, `SymptomProposals` over
fixture tables and pages with **invented** codes, models and wording; `VaultCheck` scoring; `expects` in the
manifest (absent → byte-identical). **Exit:** the tests and `Contracts/tests/*.py` green.

### P1 — the screens (headless, plus a UI test on the simulator)

New Vault, Add manual, the proposal review screen, *Add this model* from a nameplate, *Add file*, the vault
check screen, export with `expects` and the publishing check, the My Manuals card. **Exit:** a UI test that
makes a vault, adds a fixture manual, keeps a fault-code card and exports; the strings synced to the catalog in
a separate PR.

### P2 — Automotive

The Automotive template, VIN identity and a VIN photo read. **Exit:** fixture VINs (invented, with valid check
digits) parsed and placed in the map.

### P3 — device pass (owed)

A real manual pair on the oldest supported phone: time from adding a manual to its first proposals; how many
proposals the author kept; the vault check before and after. A partner builds one vault on their phone,
exports it and uploads it in the portal.

## Risks

- **Proposal quality on real manuals.** IV and KR showed real tables break simple rules. The review screen keeps
  a bad proposal harmless, and P3 measures how many are kept.
- **Time on an old phone.** Proposals run after indexing, in the background, and the vault works before they
  finish.
- **The manufacturer's wording in a sold vault.** Covered by the publishing check (§7) and Plan LV.
- **Templates multiplying.** A template is data and each new one needs an author in that trade. Don't ship one
  nobody has tested on real manuals.

## Out of scope

A drafting workspace on the service; model-drafted content (decision 2); publishing straight from the app; a VIN
decode service; editing a company layer on the phone.
