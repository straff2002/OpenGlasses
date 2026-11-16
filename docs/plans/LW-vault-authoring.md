# Plan LW — Vault Authoring (build a vault from your manuals on the phone, and get help with the hard parts)

**Status:** 🚧 P0 built 2026-11-16 (headless): the starter, the trade templates (HVAC-R, General), the prompt
kits and the paste parser in the core package; the row check, the three proposal builders, the vault check's
scoring and `expects` in the export on the phone. **P1 built 2026-11-16** (the screens, headless tests and a UI
test on the simulator; [as built](#p1--the-screens-headless-plus-a-ui-test-on-the-simulator)). P2 Automotive;
P3 device pass owed; the P1 strings' catalog sync owed (a separate PR).
[Decisions](#decisions-for-greig) taken 2026-11-16: 1, 3, 4 and 5 as recommended; 2 replaced by the owner's own
call (bring your own model by copy and paste, §4a); 6 investigated (the gap is unreachable in production).
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
- For the three layers they can also **bring their own model**: the app gives a prompt kit for the layer and
  trade, they run it in whatever model they use with their own copy of the manual, and paste the answer back.
  The phone reads the answer and checks every row against the manual before it can be kept (§4a).
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
- the manifest's `prompt_rules` from the template (the *fabricate* and *cite* themes always present). They live
  in the manifest, not a `prompt_rules.md` core file: that is where `VaultPackRules` and the importer read them,
  and a core file would send them to the model a second time on every turn;
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

The builders above are deterministic and on the phone. The app never drafts with a language model of its own
([decision 2](#decisions-for-greig)); an author who wants one brings it, by copy and paste (§4a). Proposals and
pasted rows are the same row types, so the review screen and the check below are shared.

### 4a · Paste and check (bring your own model)

Avenkin provides no model and pays for none. An author who wants a model's help uses their own:

1. **The prompt kit.** For each layer (fault codes, model map, symptoms) and trade template, the app shows a
   prompt the author copies (`PromptKit`). It says what to read (the author's own copy of the manual, attached
   in their model), what to leave out (anything the manual doesn't say; codes or models not printed in it),
   to write labels in a few words of their own rather than the manual's sentences, and the **exact return
   format**, one row per line:
   - fault codes: `code | what it means | page`;
   - model map: `model | other spellings, comma-separated, or - | page`;
   - symptoms: `what the technician says | likely cause | first check | page`.

   `page` is the number printed on the page, or the PDF page when none is printed.
2. **Paste.** The author pastes the answer into the layer's file on the phone. `PastedDraftParser` reads it into
   rows, tolerating what models add: code fences, numbered or bulleted lists, bold, a Markdown table (its
   header and rule rows are formatting, not content), leading prose. **Every line that does not fit the format
   is shown as unparsed, with its text, never dropped.**
3. **Check.** Every row is checked against the manual's page text on the phone (`DraftRowCheck`) before it can be
   kept. Nothing leaves the phone.

The check, by row:
- **Fault code** (`code · label · page`): the printed page is mapped to the PDF page through the manual's
  printed-page map (`DocumentStore.pageLabels`, the map the page viewer reads; a photographed manual's own
  `printedPage` per page); when no page prints that number, the number is read as the PDF page. The code,
  normalised (case, spaces, hyphen and en dash alike; on a photographed page also O/0, I/1, S/5), must be on
  that page, and the label's key words near it. Not there, but on exactly one other page: *found on page N*, a
  suggestion. On several: the list. Nowhere: *not in this manual*. Six or more consecutive words of the label
  matching the page: *in the manual's words*.
- **Model row:** each spelling must be printed in the manual (normalised the same way). A model printed only
  once, deep in the manual, is kept with a soft note: *mentioned once, page N*.
- **Symptom row:** only partly checkable. The page exists and shares key words with the row's cause and check;
  any code or part number in the row gets the code check. The result is *section checked · wording is yours*,
  never a full tick.
- **Page text unclear** (recognition confidence low, or garbled): *page text unclear*, neither pass nor fail.

The marks: **checked**, **found on another page**, **not found**, **in the manual's words**, **section checked**,
**page text unclear**. *Keep all checked* exists; *keep all* doesn't.

**Index rows** are written so Plan LV's revision check can read them: the expected manual's `key` (the one the
export's `expects` carries, §7) followed by `p. N`, the PDF page, with the printed page beside it when it
differs (`install-manual p. 43 (printed 41)`). The phone's answer note reads `key p. N`, `page N` and `pp.`.

A later, opt-in *Draft with my AI* through the user's own configured provider is out of scope: it would send
manual text off the phone, and needs a line in the privacy copy.

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

1. **Where drafting runs.** ✅ *Taken as recommended, 2026-11-16.* *Recommended:* on the phone, for partners too. The partner authors on their own
   phone with their own copies and uploads the export. The service never reads a manual, so nothing about
   server-side processing needs disclosing. Not recommended: a drafting workspace on the service, which needs a
   second PDF reader on Linux (the table geometry is pure, but the word positions come from PDFKit) and puts
   the vendor in the business of processing manuals.
2. **Drafting with a language model.** ✅ *Replaced by the owner's own call, 2026-11-16:* Avenkin provides no
   model and pays for none. **Bring your own model by copy and paste:** a prompt kit per layer and trade, the
   author runs it with their own copy of the manual and pastes the answer back, and the phone parses it (what
   doesn't fit is shown, never dropped) and checks every row against the manual before it can be kept (§4a).
   A later opt-in *Draft with my AI* through the user's own configured provider is out of scope: it would send
   manual text off the phone and needs a privacy line. (Was recommended: off for now, deterministic builders
   only.)
3. **Limits on a solo subscriber's own vaults.** ✅ *Taken as recommended, 2026-11-16.* *Recommended:* the per-file caps and the phone's free space
   only. `.fieldWork` already separates a solo subscriber from My Manuals. Not recommended: a manual count, which
   a working technician would hit.
4. **The publishing check.** ✅ *Taken as recommended, 2026-11-16.* *Recommended:* warnings only, shown only on export. The author decides. Not
   recommended: blocking export on rows in the manual's words, which would stop a partner exporting to their own
   second phone.
5. **My Manuals carry-over.** ✅ *Taken as recommended, 2026-11-16.* *Recommended:* move, so there aren't two copies of every manual. Not
   recommended: copy and keep both, which doubles storage for nothing.
6. **`.ownVaults` for an org licence at `.solo`.** *Recommended:* grant it, so a solo operator on a licence code
   has what a solo store subscriber has. Not recommended: leave it, which means a licence-code solo operator
   can't use this plan at all.

   🔎 *Investigated 2026-11-16; no entitlement change in P0.* **No reason for leaving it out is recorded**, and
   **the case cannot arise in production**:
   - Plan EE (P1–P4, `f30c43720`, 2026-09-03) drew the tier table when *Solo* meant the store purchase: custom
     vault import was a Team column, and "teams are licensed by signed code, not StoreKit".
   - Plan FS decision 1 (`f442fc6d4`, 2026-09-22) moved the gates to capabilities and granted `.ownVaults` to
     the subscriptions and to team and enterprise licences, "behaviour-preserving for licence holders". The
     org `.solo` row kept what it had (bundled vaults only). Neither plan mentions a licence code at solo.
     `bd36c5990` (My Manuals, 2026-10-25) added `.fieldWork` to the row and nothing else.
   - But `LicenseService.LicensePayload.resolvedTier` has read a signed `solo` claim as **team** since
     `f30c43720` (`parsed == .solo ? .team : parsed`), and anything below team as team since `bd36c5990`
     (`parsed < .team ? .team : parsed`). `FieldAssistEntitlementProvider` builds the evidence with
     `payload.resolvedTier`, and the licence core's issuance policy delegates only `team`. So a licence code
     never produces `.verifiedOrganizationLicense(tier: .solo)`; a solo operator on a code gets team's
     capabilities, `.ownVaults` included. The row is reached only by `FieldAssistCapabilityTests`, which pins
     it to the bundled set.

   So this plan works for a licence-code solo operator today. Granting `.ownVaults` in the row is a consistency
   change with no effect on any shipped code; it needs only the test updated, and can wait for a licence that
   really issues solo.

## Phases

### P0 — the pure core (headless)

`VaultStarter` and its tests in the core package (every template's starter passes `VaultPackRules`);
`TradeTemplate` with HVAC-R and General; the prompt kits (`PromptKit`) and `PastedDraftParser`, with the row
types they share, also in the core package so the portal can show the same kits; `DraftRowCheck` over injected
page text; `FaultCodeProposals`, `ModelMapProposals`, `SymptomProposals` over fixture tables and pages with
**invented** codes, models and wording; `VaultCheck` scoring; `expects` in the manifest (absent →
byte-identical). **Exit:** the tests and `Contracts/tests/*.py` green.

**As built (2026-11-16).** Core package (`Tools/LicenceIssuance`, compiled into the app beside
`VaultPackRules.swift`): `TradeTemplate.swift`, `VaultStarter.swift`, `VaultDrafts.swift` (`DraftRow` and its
row types, `PromptKit`, `PastedDraftParser`, `IndexRowWriter`). App (`Services/Vault/Authoring/`):
`DraftPageText` (the page-text seam, `ManualPageText`), `DraftRowCheck`, `DraftProposals`
(`FaultCodeProposals`, `ModelMapProposals`, `SymptomProposals`), `VaultCheck`, `VaultExpects`; `VaultExporter`
writes `expects`. An expected manual's key is made from its file name (stable across exports; P1 may store it
on the document if a rename must keep it). Symptom proposals read troubleshooting tables and `Problem:` /
`Cause:` / `Check:` blocks; headings alone are not read yet.

### P1 — the screens (headless, plus a UI test on the simulator)

New Vault, Add manual, the proposal review screen, the prompt kit and paste screen (the same review screen),
*Add this model* from a nameplate, *Add file*, the vault check screen, export with `expects` and the publishing check, the My Manuals card. **Exit:** a UI test that
makes a vault, adds a fixture manual, keeps a fault-code card and exports; the strings synced to the catalog in
a separate PR.

**As built (2026-11-16).** Services (`Services/Vault/Authoring/`): `VaultAuthoring` (*New Vault* installs the
starter through `VaultImporter.installReporting` as a user-imported vault, with `freeId` numbering an id that is
taken; *Add manual* re-lays the vault through `VaultDocumentCarry.relay` with the document's `revision` (SHA-256 of
the indexed file, the ledger's digest), `origin` (`.technician`, `.capture` for photographed pages) and `edition`;
*Add file* re-lays it with one more file in `manifest.files`; *Keep* writes through `VaultStore.write`, the
editor's overlay path), `VaultAuthoringRecord` (beside the overlay, never exported: the trade, the check's
questions and bar, the last score, kept rows still in the manual's words), `DraftKeeper` (pure: a fault code
under `VaultStarter.faultCodeTableHeader`, a model merged into the `##` section any of its spellings names or a new
one, a symptom as the next numbered check under its heading), `LiveDraftPageText` (the live `DraftPageText`:
the stored page text with each chunk cut at the page breaks it packs across (`DocumentStore.pageTextsSplitAtBreaks`,
so a short page keeps its own words), `pageLabels` or a reviewed capture's `printedPage`, recognised pages from the ledger, unclear pages by
`looksGarbled`, and nothing for a manual `availabilityCheck` refuses), `DraftReview` (the review rows: checked,
*Use page N*, edit clears the manual's words, *Keep all checked* per card), `PublishingCheck`, `VaultCheckRunner`
(the session's own `makeRetriever`, no model, no network), `NameplateModelRead` (`OCRService` and the model-map
token read, no field session), `ScannedPagesPDF`, `AuthoringLinkIntake` and `MyManualsMove` (make the vault, copy
the manuals renamed by title, check every copied file's SHA-256 against its source, and only then uninstall My
Manuals; any failure before that uninstalls the new vault and leaves the library as it was). Screens
(`App/Views/VaultAuthoring/`): *New Vault…* (Custom Vaults, with `.ownVaults`), *Build this vault* on a vault of
your own (`VaultAuthoringView`: manuals, *Add manual*, *Review drafts*, *Add this model from a nameplate…*, files,
vault check, *Export for publishing…* and *Export a private copy*), the draft review screen (also opened from
*Review drafts* under an indexed manual in Custom Vaults), the vault check, *Add file…* in the files editor, and
the one-time *Move your manuals into a vault* card. Owned means installed from a folder or made here: not My
Manuals, not a pack, not received from a link, no company layer.

Differences from the design above: *Add manual* from a publisher link reviews the link as the link sheet always
does and adds the archive's manuals to the vault, never its core files. A Word or Markdown upload keeps the My
Manuals shape (the upload as `file`, its PDF reading copy as `source`). The vault check reruns when its screen
opens and on *Run check*, not on every change. The prompt kits, the starter files and the template data stay
English in P1: the kits are read by the author's own model and the starter files become the author's own text;
the screens' strings are localised as usual and synced to the catalog separately. The author's own check
questions live on the phone and are not exported yet. The UI test shows the review screen (Debug only) in place of the
app's screens, on a vault made and a manual added by the shipping paths, with the manual's page text and the
pasted reply handed in rather than indexed and typed; it checks the reply's marks and the unparsed line and keeps
a checked row. The export is covered by a headless test.

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

A drafting workspace on the service; a model the app provides or pays for (decision 2); an in-app *Draft with
my AI* through the user's own provider (it would send manual text off the phone); publishing straight from the app; a VIN
decode service; editing a company layer on the phone.
