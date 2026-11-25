# Plan NF — Crew Experience Sheet (the company's own fixes, kept in a spreadsheet, answered beside the manuals)

**Status:** 🚧 P0 built 2026-11-25, PR pending: `Contracts/crew-experience.md`, the team-learning amendment (§11 there), the shared core `CrewExperience.swift` beside `VaultPackRules` (parser, row rules, mapping, set, `crew-models.md`, experience-only vault), the `experience` catalog field with its checks, golden fixtures in `Contracts/fixtures/crew-experience-v1/`, and the phone's entry fields (`faultCode`, `tried`, `outcome`, origin `recollection`, IM's symptom subject). Not built: P1 onwards (no phone applies a set, cites *Crew experience* or opens with its lead-in yet), the seal (its domain is fixed in the contract), the safety second confirmation (S1). Drafted 2026-11-25. [Decisions](#decisions-for-greig) taken the same day: 1–8 and
10–14 as recommended; 9 changed to add an on-phone route for a one-person shop (§9, phase P5), built only if the
partner's feedback says one-person shops matter; 15 became its own plan, [NG](NG-team-learnings-reviewed-in-the-portal.md).
**Track:** Field Assist — company knowledge. The licence portal, company vaults, the team-learning corpus.
**Builds on:** Plan [FP](FP-team-learnings.md) P0–P3 (the learning entry, its own corpus beside the manuals,
the citation and the "learning alone" lead-in, the rule that a learning never outranks a safety note), Plan
[LR](LR-company-vaults-from-the-portal.md) (the company-vault catalog, sealed company files, pick-up on every
foreground), Plan [LV](LV-published-vaults.md) §6 (the add-only company layer), Plan
[ND](ND-company-settings-from-the-portal.md) (portal publish, history and revert).
**Sits beside:** Plan [IM](IM-experience-recordings.md) (the same kind of knowledge, recorded by voice; this
plan takes its `recollection` origin and its `tried`/`outcome` fields and builds them first), Plan
[MW](MW-tips-from-the-crew.md) (a tip pinned to a procedure step), Plan
[JL](JL-procedure-deviations-and-learning-round-trip.md) (a learning bound to a step, through an office).
**Service side:** the portal and the signer live in the private service repository. This plan carries the
contract the phone reads, the rules both sides compute the same way, and a one-line outline of each service
step.

---

## Trigger

The sales partner, 2026-11-25, in two parts.

1. **A company's hands-on experience grows; the manuals don't.** The OEM manuals in a vault stay the same until
   the next revision, but what the company's technicians have learned about fixing that equipment keeps growing.
   Customers won't edit Markdown. Could they keep a separate "hands-on experience" list, ideally in a structured
   Excel template with the equipment model, the error code or problem, what they saw, and the fix that worked?
   Could the assistant use the spreadsheet directly, or should it be converted when it's uploaded? Either way,
   customers should be able to update it without rebuilding the vault.
2. **A shop with no manuals.** A small independent shop that repairs European cars buys no repair manuals and
   relies on its own experience. Could the app build a vault from the shop's day-to-day work: vehicle, fault
   codes, symptoms, checks and the fix? The partner's simpler first step was to have the mechanics' notes
   organised with a general chat assistant, then reviewed and uploaded.

The owner's view: experience works best layered on top of definitive knowledge, and turning free talk into a
structured corpus with no manual as a baseline is beyond the app for now. A spreadsheet is the structure,
already filled in by a person. This plan takes the sheet as the way in and leaves free talk to Plan IM.

## Outcome

- The company's administrator downloads the **Crew experience** template from the portal for one of the
  company's vaults. It has one row per case and columns for brand, model, fault code, symptom, what was checked,
  what fixed it, how sure, who and when. They fill in 40 rows and upload the `.xlsx` file.
- The portal shows **38 ready, 2 to fix**: *"Row 17: no model and no equipment type. Row 31: the fix is 640
  characters; at most 500."* They fix both in the browser and press **Publish**. The portal says *"42 fixes
  published. Phones pick them up the next time they're opened."*
- On a job on an SLP99 with fault E228, the technician asks what to check. The answer gives the manual's
  procedure first, then: *"From your company's experience (not the manufacturer's manual): on this model E228
  has usually been the pressure switch harness at the plug, not the switch."* It is cited
  **Crew experience · SLP99UH090XV60CK · 2026-11-25 · approved by Service manager**.
- Three weeks later they add 6 rows and change one, starting from **Download current sheet**. The portal shows
  *"6 new, 1 changed, 0 removed"* before they publish. Nobody rebuilds the vault, and the manuals don't move.
- The car shop starts with an **experience-only vault**, with no manuals in it. Every answer it gives opens with
  the experience lead-in, because there is nothing definitive to put first.

## What exists (verified 2026-11-25 on `origin/main` 2c1276428)

- **The entry and its corpus.** `LearningEntry` (`Services/FieldAssist/TeamLearning/LearningEntry.swift`) has a
  `subject` (`model(modelToken, manufacturer?, equipmentType?)` or `practice(topic)`), `finding` (≤ 2,000),
  `symptom?` and `fix?` (≤ 500 each), `approvedAt`, `approvedByRole`, `authorIsApprover`,
  `contradictsSafetyNote`, `supersedes?`, `origin` and `confirmedJobCount?`. `LearningCandidate.Origin` is
  `spoken | report | reportReview`. IM's `recollection` was proposed and never built.
- **Retrieval.** `LearningCorpus` publishes one single-chunk document per entry per vault under
  `learning:<vaultId>`. Its text is `Model:` / `Symptom:` / `Finding:` / `Fix:` lines
  (`documentText(_:)`), and its name is the citation. An answer resting only on learnings has the named
  `.teamLearningOnly` outcome, and the app adds the lead-in (`TeamLearningDisclosure`).
- **Two gotchas this plan must design around:**
  1. `LearningCorpus.placement(of:among:)` publishes a model entry only to a vault whose `VaultModelIndex`
     knows the token, and the index is read from the vault core's `##` model headings. A vault with no
     manuals and no model headings knows no models, so every model row would be silently left out. That is
     the car shop's case exactly.
  2. `LearningCorpus.reconcile(entries:vaults:store:)` forgets every learning document whose entry is not in
     the list it is given. Applying a portal set with only the portal's entries would delete the phone's own
     reviewed FP entries, and the reverse. Reconcile has to run over the union of every source.
- **Who may use learnings.** Filing and reviewing need the team or enterprise licence
  (`FieldAssistEntitlementStatus.teamLearnings*`). Published learnings stay in use when a licence lapses. HIPAA
  mode withholds them.
- **The carrier.** The company-vault catalog (`Contracts/company-vaults.md`) is signed by the vendor's
  pack-catalog key, is read on every foreground, carries vault rows and sealed manual rows, and gains a
  generation with every change. The add-only company layer (§6) can add files to a vault and never replace
  one. Nothing in the catalog carries learnings.
- **The team-learning contract** (`Contracts/team-learning.md`, draft v1) defines a whole-set learning set
  (§5), a whole-set replace on the phone (§6), the citation (§7.1), model match by identity (§7.2), safety
  (§7.3) and text rules (§7.4), all for an office with its own keys (Plan FX). A company that has only the
  portal has no office key.
- **Spreadsheets today.** The phone reads a CSV in one place (the immunisation list, Plan MY). It reads no
  `.xlsx` anywhere, and the licence service runs Swift on Linux with no zip or XML reader in its core.

## Design

### 1 · The sheet is the way in, not what gets searched

The assistant never reads the spreadsheet. The portal turns each row into one `LearningEntry`, and the phone
receives entries it already knows how to retrieve, cite and keep below the manual. That gives:

- **Better answers.** One case is one short document with its model on it. Search either finds it whole or
  doesn't find it. A spreadsheet chunked by size would split a case or merge two.
- **Identity matching.** The model column becomes `subject.modelToken`, so the case answers only for that model
  (contract §7.2), not for any machine whose text looks similar.
- **Separate updates.** The manuals stay in the vault and the experience is its own set with its own sequence,
  so publishing 6 new rows never touches a manual.
- **Nothing new on the phone.** No spreadsheet parser, and no new retrieval path.

### 2 · The template (v1)

One row per case. The column headers are fixed English keys (the template shows a translated label above
them). Unknown columns are ignored and named in the preview.

| Column | Required | Becomes | Limit |
|---|---|---|---|
| `id` | filled in by the portal | `entryID`. Empty means a new row. Kept on re-upload, so a changed row is an update rather than a duplicate. | 32 hex |
| `brand` | no | `subject.manufacturer` | 80 |
| `model` | one of `model` / `equipment_type` | `subject.modelToken`, after the vault's model spelling rules | 80 |
| `equipment_type` | one of `model` / `equipment_type` | `subject.equipmentType`. Alone, it is a symptom subject (IM decision 4) | closed list per vault |
| `fault_code` | no | `faultCode` (new, decision 5). Also the first words of `symptom`, so search finds the code | 40 |
| `symptom` | yes | `symptom` | 500 |
| `checked` | no | `tried` (IM's field) | 500 |
| `fix` | yes | `fix` | 500 |
| `notes` | no | `finding`. When empty, the portal writes `finding` as "`<fault code>`: `<fix>`" | 2,000 |
| `how_sure` | no | `outcome` (IM's field). In words, never a number. The template offers "fixed it every time / most times / once". | 120 |
| `added_by` | no | the author, for `authorIsApprover` | 120 |
| `date` | no | shown to the reviewer only | ISO or the sheet's date |

There is no customer, site, address or phone column. Site knowledge stays out of learnings (team-learning
contract §8, Plan HV). The portal's redaction pass runs the same `SecretPatterns` the phone runs, plus phone
numbers and e-mail addresses. A row it changes is marked in the preview, never published silently.

### 3 · Spreadsheet in the browser, CSV at the server

The template is offered as `.xlsx` (with drop-down lists for `equipment_type` and `how_sure`) and as `.csv`.
An uploaded `.xlsx` is converted to CSV **in the browser**, so the service parses only one strict CSV dialect
(UTF-8, comma, RFC 4180 quoting, first row headers). The conversion takes the first sheet and its cell values,
never formulas or comments. The service's parser and row rules live in the shared core, beside
`VaultPackRules`, so the phone's tests and the service read the same golden fixtures.

### 4 · Review is the preview, publish is the approval

Each upload shows every row as **ready**, **to fix** (a named reason and the row number) or **changed by
redaction**. The administrator can edit a cell in place, leave a row out, or publish. Publishing approves every
ready row it includes. `approvedByRole` is the administrator's portal role and `authorIsApprover` is true when
`added_by` matches them. There is no second reviewer in v1 (decision 7).

A row whose model the vault doesn't know gets one of two choices: **fix the spelling** (the preview suggests the
vault's nearest spelling), or **add as a model the company services**. The second choice puts it in the
company's model list (§6).

A row whose words collide with the vault's safety file (the office's §7.3 check, in the core) needs a second
confirmation, and is then published with `contradictsSafetyNote: true`.

### 5 · Delivery: a sealed set on the company-vault catalog

Each vault row in the company-vault catalog gains an optional `experience` field:

```json
"experience": { "sequence": 4, "count": 42, "sizeBytes": 31877, "revision": "<sha256 of the plaintext set>",
                "sealedSha256": "<sha256 as served>", "downloadURL": "https://…" }
```

- The file is the team-learning contract's **learning set (§5)** with `kind: avenkin.crew-experience-set`, its
  own envelope domain, and the binding fields replaced by `profileId` and `vaultId`. It is sealed with the
  company secret, the same way `CompanyManualSeal` seals a manual. The catalog's signature covers the pointer,
  and the seal and hash cover the file. No office key is needed.
- Raising `sequence` raises the catalog's `generation`, so a phone sees it on its next foreground.
- The phone refuses a set that is not newer than the one it holds, applies a newer one whole (§6 of the
  team-learning contract), and keeps the last good set when a read fails.
- The set may be fetched on any network. At a 2 MiB cap (decision 13) it is smaller than one photo.

### 6 · A vault with no manuals still knows its models

The portal writes the company's model list as an **add-only company layer file**, `crew-models.md`, with one
`## <model> (<other spellings>)` heading per model. `VaultModelIndex` already reads that format. For an
experience-only vault this file is the whole model index. For a vault with manuals it adds only the models the
administrator chose to add (§4). The layer rule (LV §6) already forbids it from replacing a publisher file.

An **experience-only vault** is a portal starter: a company vault whose core holds the prompt rules the
validator requires ("fabricate" and "cite"), `crew-models.md`, and nothing else. On the phone it is an
ordinary company vault, and because it has no manual every answer from it is `.teamLearningOnly`.

### 7 · On the phone

- **Its own store.** `CompanyExperienceStore` holds each vault's last applied set, file-protected like
  `LearningEntryStore`. Reconcile runs over the union of both stores (gotcha 2). A portal entry and a
  phone-reviewed entry never share an id, because the portal mints its own.
- **Origin `recollection`.** Every sheet entry carries it, with `confirmedJobCount` 0. When FP's merge later
  confirms one on a job, the count rises and the citation earns FP's stronger wording.
- **Citation and lead-in.** *Crew experience · `<model>` · `<date>` · approved by `<role>`*. The lead-in, when an
  answer rests on experience alone, is *"From your company's experience (not the manufacturer's manual):"*.
  The fault code and `how_sure` are part of the document text, so the model can say "fixed it most times".
- **Where it shows.** The company vault's row in Custom Vaults says *Crew experience · 42 fixes · updated 25
  Nov*. There is nothing to edit on the phone.
- **Same rules as FP.** Team or enterprise licence only; kept on a lapsed licence; withheld under HIPAA; part
  of the subject-erasure walk; never shared off the phone; never outranks a safety note.

### 8 · Other ways in, later

The template is the one intake every later source writes to, so nothing built here is thrown away:

- **Now (P3), no build:** a short guide and a prompt that turns a mechanic's typed or dictated notes into
  template rows using any chat assistant. The output is reviewed and uploaded like any sheet. This is the
  partner's suggested first step.
- **Later, in the portal:** paste or upload a meeting transcript (the meeting recorder's whole-meeting notes,
  Plan MX), and a drafting pass splits it into draft rows for the same preview. It runs on the company's own
  provider credentials, and a person approves every row (decision 14).
- **Later, on the phone:** Plan IM's one-case-per-recording, landing in the same preview rather than on a
  reviewer device.

### 9 · A one-person shop, on the phone (decision 9)

A solo subscriber has their own vaults (`.ownVaults`) and no portal. They get the same sheet on the phone. The
parser and row rules are the shared-core files from P0, compiled into the app the way Plan LW's
`VaultDrafts.swift` already is, so the phone and the portal accept exactly the same rows.

- **Three ways in**, from **Add your experience** on an owned vault: import a `.csv` from Files (Numbers, Excel
  and Google Sheets on the phone all export one); **paste rows** copied from any spreadsheet app, which arrive
  on the clipboard as tab-separated text, so no file is needed; or paste a chat assistant's answer to the
  notes-to-rows prompt (§8), using Plan LW's `PromptKit` pattern.
- **One review screen**, the portal's preview on the phone: ready, to fix, changed by redaction. Saving is the
  approval. The owner is author and approver (`authorIsApprover: true`, role "Owner").
- **Kept with the vault.** Entries go into that vault's experience store and through the same union reconcile.
  The citation and lead-in are unchanged.
- **Export current sheet** writes a CSV with its ids to the share sheet, so the owner can edit it in their
  spreadsheet and import it again, and it moves with them to a new phone. This is the owner's own text, not a
  manual, so the rule against sharing manuals doesn't apply to it. A received vault, a My Manuals vault and a
  company vault can't take a sheet (`VaultAuthoring.isOwned`).
- **A new capability, `.ownExperience`,** in the solo tier and above. FP's `.teamLearnings` gate doesn't change.
- **On the job,** a solo technician's "note that fix" (FP's spoken note) files into the same review screen
  instead of a team queue. They are their own reviewer.

## Phases

One PR each on the app side. The service steps are outlined only.

### P0 — The contract and the shared core (headless)

- `Contracts/crew-experience.md`: the template columns and limits (§2), the CSV dialect (§3), the row rules
  and every refusal reason by name, row-to-entry mapping, the set and its `experience` catalog field (§5), and
  `crew-models.md` (§6).
- Amend `Contracts/team-learning.md` v1 additively: origin `recollection`, the entry fields `faultCode?`,
  `tried?` and `outcome?`, and the recollection citation (§7.1).
- The shared core: `CrewExperienceSheet.parse(csv:vault:)` → rows with named problems;
  `CrewExperienceSheet.entries(from:approvedBy:)`; `CrewModelsFile.render(models:)`; the `experience` field in
  `CompanyVaultContract` with its `check`.
- Golden fixtures in `Contracts/fixtures/crew-experience-v1/`: a clean sheet, a sheet with every refusal,
  re-upload with ids (new / changed / removed), redaction hits, an experience-only vault. Invented content only.
- Phone: `LearningEntry` and `LearningCandidate.Origin` gain the new fields and case, decoded with
  `decodeIfPresent` so older files read as before. `documentText` adds `Fault code:`, `Checked:` and `How sure:`
  lines.

### P1 — The phone applies a set

- `CompanyExperienceStore`, the catalog field read, the seal opened, the sequence checked, the set applied
  whole, the last good set kept.
- Reconcile over the union of stores, with a test that applying a portal set leaves FP entries in place and
  the reverse.
- Citation, lead-in and the Custom Vaults line. Subject erasure, lapse, HIPAA and the licence-tier gate, each
  with a test.
- A guard test that no code path reads a `.xlsx` or `.csv` from a company catalog.

### S1 — The portal (private service repository)

Template download, upload with in-browser `.xlsx` → CSV, preview with row problems and cell editing, the
unknown-model choice, the safety second confirmation, publish (sealed set + `crew-models.md` layer + raised
generation), **Download current sheet** with ids, the diff before publish, history and revert (ND's pattern),
and the experience-only vault starter.

### P2 — String catalog sync

The Custom Vaults line, the lead-in and the citation prefix in all 13 languages, add-only.

### P3 — The intake kit (docs)

A customer guide (`docs/field-assist/crew-experience.md`): what makes a good row, three worked examples, how
to start from **Download current sheet**, and the notes-to-rows prompt for a chat assistant (§8).

### P4 — Device pass (owed)

Two phones in one company. Publish 40 rows: both pick them up on the next foreground. Ask about a fault code in
the sheet: the answer has the manual first and then the cited experience. Ask the same on the experience-only
vault: the lead-in opens the answer. Publish a change to one row: the old wording is gone on both phones. Let
the licence lapse: the answers still come. Turn on HIPAA: they don't.

### P5 — One-person shop, on the phone (only if the partner's feedback asks for it)

The §9 route: `.ownExperience`, CSV import, tab-separated paste, the prompt kit, the review screen, export, and
the solo spoken note. It reuses P0's parser and P1's store and reconcile, so it can come after P1 in one PR.

## Decisions for Greig

Taken 2026-11-25: 1–8 and 10–14 as recommended. 9 changed (below). 15 became Plan
[NG](NG-team-learnings-reviewed-in-the-portal.md).

1. **The portal converts; the phone never reads a spreadsheet.** *Recommended:* yes (§1).
2. **`.xlsx` is converted in the browser and the server accepts strict CSV only.** *Recommended:* yes. It keeps
   a zip and XML reader out of the core, and an administrator never has to save the file as CSV themselves.
3. **One origin, `recollection`, for sheet rows and IM's recordings.** *Recommended:* yes. Both are "known
   before a recorded job confirmed it". A sub-kind can be added later if the citations need to differ.
4. **The wording.** *Recommended:* citation *Crew experience · model · date · approved by role*, and lead-in
   *"From your company's experience (not the manufacturer's manual):"*. IM's "(recalled, not yet seen on a
   recorded job)" is accurate but long when spoken.
5. **New entry fields `faultCode`, `tried`, `outcome`.** *Recommended:* all three, in one additive amendment.
   Fault codes are how technicians search.
6. **An `id` column the portal fills in.** *Recommended:* yes. Without it every re-upload duplicates or wipes
   the set.
7. **Publishing is the approval, with no second reviewer in v1.** *Recommended:* yes. The administrator who
   publishes is the approver of record. A two-person rule can come with the portal's roles.
8. **Delivery as a sealed set on the company-vault catalog, not an office channel.** *Recommended:* yes (§5).
   It works for every portal company today, with no office.
9. **Team and enterprise only.** *Recommended:* yes. A solo subscriber has no portal. Their own
   experience is Plan MW's tips and FP's spoken note. **Changed 2026-11-25:** the portal route stays team and
   enterprise, and a one-person shop gets the same sheet on the phone, in its own vaults (§9, P5). Whether to
   build P5 waits on the partner's feedback about one-person shops.
10. **One sheet per vault.** *Recommended:* yes. An "every vault" sheet makes the model check meaningless.
11. **Unknown models are fixed or added as company models, never dropped.** *Recommended:* yes (§4, §6). It
    closes gotcha 1.
12. **No site or customer columns, and contact details are redacted.** *Recommended:* yes (§2).
13. **Limits: 5,000 rows and 2 MiB per set.** *Recommended:* yes. That is the contract's learning-set cap, and
    far more than any first customer has.
14. **Transcript drafting in the portal is a later phase, on the company's own provider credentials.**
    *Recommended:* later. Ship the sheet and the notes-to-rows prompt first, and see what customers actually
    write.
15. **Phone-filed FP candidates reviewed in the portal instead of on a reviewer device.** *Recommended:* a
    separate plan. **Taken:** Plan [NG](NG-team-learnings-reviewed-in-the-portal.md). It is the natural next step once the portal has a review screen, but it needs the phone to
    send candidates to the service, which nothing does today.

## Acceptance

- A clean template uploads, publishes and answers on a phone with the crew-experience citation, below the
  manual's own text.
- Every refusal in the fixtures is named with its row number, and nothing is published from a refused row.
- Re-uploading the downloaded sheet with one edit changes exactly that entry on the phone.
- An experience-only vault answers about its models with the lead-in, and about a model it doesn't list with
  "not in this vault".
- Applying a portal set never removes a phone-reviewed FP entry, and the reverse.
- No app release is needed to add, change or remove a row. P1 needs one app release, the first store update
  after the phone-only submission.
