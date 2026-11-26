# Crew experience — contract v1 (Plan NF)

A company keeps its own fixes in a spreadsheet, one row per case, and the assistant answers from
them beside the manuals. This is the agreement between the licence portal, which reads the sheet and
publishes it, and the phone, which receives it. The phone never reads a spreadsheet: the portal turns
each row into one learning entry (the [team-learning contract](team-learning.md) §5, origin
`recollection`), and the phone retrieves, cites and ranks entries as it already does.

The reference implementation is `Tools/LicenceIssuance/Sources/LicenceIssuance/CrewExperience.swift`
(`CrewExperienceSheet`, `CrewExperienceSet`, `CrewModelsFile`) and the `experience` field in
`CompanyVaults.swift`. The sheet's file is Foundation only and self-contained beside `VaultStarter.swift`,
so the service compiles it on Linux and the phone can compile it into its own target, as it does
`VaultDrafts.swift`. Both sides' tests read the golden fixtures in `fixtures/crew-experience-v1/`.
Invented brands, models, codes and people only.

**What exists.** The parser, the row rules, the mapping, the set and its checks, the `crew-models.md`
writer, the experience-only vault and the catalog field with its checks (P0); the seal
(`CompanyVaultContract.ExperienceSeal`, with `sealSet` writing the vault row's pointer), and the phone
fetching, opening, checking and applying a set (`CompanyExperienceSeal`, `CompanyExperienceStore`, the
company vault pass; P1). Nothing serves a set yet: the portal's screens and storage are the service's (S1).

## 1. Roles

| | Portal (licence service) | Phone |
|---|---|---|
| Offers the template (`.xlsx` and `.csv`); converts an uploaded `.xlsx` to CSV in the browser | ✔ | |
| Parses the CSV, holds every row to §4, shows the preview | ✔ | |
| Publishes: the administrator's press is the approval (Plan NF decision 7) | ✔ | |
| Seals the set, writes `crew-models.md`, raises the catalog's generation | ✔ | |
| Fetches, opens and applies the set whole; cites it as crew experience | | ✔ (P1) |

## 2. The template (v1)

One sheet per vault (decision 10), one row per case. The columns are fixed English keys; a header
cell is compared trimmed, case-insensitively, with spaces and hyphens read as underscores
(`Fault code` is `fault_code`). A header cell that is not one of these is **ignored and named** in the
preview (`Parsed.ignoredColumns`); an empty one is ignored. Columns may come in any order.

| Column | Required | Becomes | Limit |
|---|---|---|---|
| `id` | filled in by the portal | `entryID`. Empty: a new row. Kept on re-upload (§5). | 32 lowercase hex |
| `brand` | no | `subject.manufacturer` | 80 |
| `model` | one of `model` / `equipment_type` | `subject.modelToken`, as the vault's own spelling (§4.2) | 80 |
| `equipment_type` | one of `model` / `equipment_type` | `subject.equipmentType`; alone, a symptom subject (§4.3) | the vault's closed list |
| `fault_code` | no | `faultCode`, and the front of `symptom` (§4.4) | 40 |
| `symptom` | yes | `symptom` | 500, with the fault code in front |
| `checked` | no | `tried` | 500 |
| `fix` | yes | `fix` | 500 |
| `notes` | no | `finding`; empty: `"<fault_code>: <fix>"`, or the fix alone | 2,000 |
| `how_sure` | no | `outcome`, in words (§4.5) | 120 |
| `added_by` | no | the author, for `authorIsApprover`; never published | 120 |
| `date` | no | shown to the reviewer only; never published | `YYYY-MM-DD` |

The template offers `fixed it every time`, `fixed it most times` and `fixed it once` for `how_sure`
(`CrewExperienceSheet.howSureChoices`) and the vault's equipment types for `equipment_type`, as
drop-down lists in the `.xlsx`. There is **no customer, site, address or phone column**: what a
company knows about a site stays out of learnings (team-learning §8).

The `.xlsx` template shows a translated label above each key. The browser conversion drops every row
above the key row, so the CSV's first row is always the keys. Format the `id` column as text in the
`.xlsx`: a spreadsheet that reads `12e45…` as a number would rewrite it, and the row is refused
`badId` rather than published under another id.

## 3. The CSV dialect

The service parses one dialect, strictly (`CrewExperienceSheet.parse(csv:vault:)`):

- **UTF-8.** A leading byte-order mark is skipped. Anything that is not UTF-8 is refused `notUTF8`.
- **Comma** between cells. **RFC 4180 quoting:** a cell holding a comma, a quote or a line break is in
  double quotes; a quote inside one is doubled (`""`).
- **Records** end at CRLF, LF or a lone CR. A line break inside a quoted cell is part of the cell. A
  file that ends with a line break has no empty record after it.
- **The first record is the header** (§2).
- A **blank row** (every cell empty or spaces) is skipped wherever it is; row numbers are still the
  sheet's own, the header being row 1, so "Row 17" is the row the administrator sees as 17.
- A row with **fewer cells** than the header reads the missing ones as empty; one with **more** is
  refused `extraCells` when any extra cell holds anything.
- **Text in a cell** is normalised as the phone normalises a captured finding (team-learning §7.4):
  a tab becomes a space, CRLF and CR become LF, LF becomes a space except in `notes`, and the cell is
  trimmed. Any other control character, or a bidirectional embedding, override or isolate, refuses
  the cell (`controlCharacter`). Lengths are counted in Unicode scalars, after redaction.

The `.xlsx` is converted **in the browser** (decision 2): the first sheet, its cell values, never its
formulas or comments. A date cell converts to ISO 8601; `YYYY-MM-DDT…` and `YYYY-MM-DD …` are read as
their day.

## 4. Row rules

### 4.1 Refusing the whole sheet

`CrewExperienceSheet.SheetRefusal` — nothing in the file is read:

| Name | When |
|---|---|
| `tooLarge` | over 2 MiB (`Limits.bytes`) |
| `notUTF8` | not UTF-8 |
| `noHeader` | no header row, or a header of empty cells |
| `missingColumn` | no `symptom` column, or no `fix` column |
| `noSubjectColumn` | neither `model` nor `equipment_type` is a column |
| `duplicateColumn` | a template column twice |
| `unterminatedQuote` | a quoted cell runs to the end of the file (the row it started on) |
| `strayQuote` | a quote inside an unquoted cell, or text after a closing quote |
| `tooManyRows` | more than 5,000 non-blank rows below the header (`Limits.rows`, decision 13) |

### 4.2 Refusing a row

`CrewExperienceSheet.Problem` — the row is shown as **to fix** with its number and every reason, and
nothing is published from it. The preview's words are `Problem.message` after `Row <n>: `.

| Name | When |
|---|---|
| `noSubject` | no model and no equipment type |
| `unknownModel` | the model is not one of the vault's spellings (§4.2.1); `nearest` names the vault's closest, if one is close |
| `unknownEquipmentType` | the equipment type is not on the vault's list |
| `missingSymptom`, `missingFix` | the required cell is empty |
| `tooLong` | over the column's limit, with `count` and `limit`; for `symptom`, counted with the fault code in front |
| `controlCharacter` | §3; reported once, never also as missing |
| `badId` | the id is not 32 lowercase hex characters |
| `duplicateId` | a row above has the same id |
| `unknownId` | the id is not in the set now published for the vault (checked when the portal passes `currentEntryIDs`) |
| `howSureIsANumber` | `how_sure` is only digits, spaces and `. , % / + -` ("90%", "9/10") |
| `badDate` | not the `YYYY-MM-DD` of a real day |
| `extraCells` | §3 |

**4.2.1 Model spelling.** The vault's spellings are every token its model index knows: the `##`
headings of its core and of `crew-models.md` (§7). A row's model matches a spelling when the two are
equal uppercased with hyphens and spaces removed, and the entry carries **the vault's spelling** (the
first that matches), so the phone's identity match (team-learning §7.2) finds it. A model that matches
none is never dropped (decision 11): the administrator fixes the spelling (the preview suggests the
nearest: at most two edits, or a quarter of the spelling's length if that is more) or **adds it as a
model the company services**, which puts it in `crew-models.md` and makes it a spelling on the next
parse. A spelling the phone's index could not read as a model is refused there
(`CrewModelsFile.Problem.notAModelNumber`), so a heading is never written that knows nothing.

### 4.3 Equipment type alone

`equipment_type` must be on the vault's closed list, compared case-insensitively with runs of spaces
as one, and is stored as the list spells it. A row with an equipment type and no model becomes the
**symptom subject** `{ kind: "symptom", equipmentType, phrase }` (Plan IM decision 4), `phrase` being
the symptom as written without the fault code. It answers only within that equipment type, so a
dryer's row never answers for a dishwasher. A row with both is a model subject carrying the type.

### 4.4 Fault codes

`symptom` is `"<fault_code>: <symptom>"` unless the symptom already contains the code
(case-insensitive), so a search for the code finds the case. `faultCode` carries the code alone.

### 4.5 How sure, in words

`how_sure` is the crew's confidence in words, never a number (Plan IM decision 3). The answer can then
say "fixed it most times".

### 4.6 Redaction

The free-text cells (`symptom`, `checked`, `fix`, `notes`, `how_sure`) pass through the phone's
`SecretPatterns` — restated in `CrewExperienceRedaction.patterns`, name for name and expression for
expression, which the app's `CrewExperienceSheetTests` holds to the phone's own list — and then
`phone`: digit groups separated by single spaces, dots or hyphens, optionally an international prefix
and a bracketed area code, standing alone, with 9 to 15 digits (a date or a reading is not one). E-mail
addresses are among the phone's patterns. Each match becomes `‹redacted›`. A row the pass changed is
**changed by redaction**: publishable, and marked in the preview with each cell and the pattern names
(never the text they matched). It is never published silently. Redaction is a floor: it will not catch
a customer's name, so the administrator reads every row.

### 4.7 Status

`ready` (no problem), `to_fix` (at least one problem; never published) or `changed_by_redaction`.
`CrewExperienceSheet.report(_:)` is the preview as data, and what the fixtures pin.

## 5. Publishing, ids and re-upload

`CrewExperienceSheet.entries(from:approvedBy:current:newID:)` makes one entry per publishable row, in
sheet order:

| Entry field | From |
|---|---|
| `entryID` | the row's `id`, or a new one (`mintID`, a UUID's 128 bits as 32 lowercase hex) |
| `subject` | §4.2–4.3 |
| `vaultIDs` | `[<the sheet's vault>]` |
| `finding`, `symptom`, `fix`, `faultCode`, `tried`, `outcome` | §2 |
| `approvedAt` | the press of **Publish**, Unix UTC seconds |
| `approvedByRole` | the administrator's portal role, 1–80 characters |
| `authorIsApprover` | `added_by` equals the administrator's name, case-insensitively, runs of spaces as one; false when empty |
| `contradictsSafetyNote` | false; the safety second confirmation is the portal's (S1) |
| `origin` | `recollection` |
| `confirmedJobCount` | absent: no recorded job has confirmed it (read as 0) |

There is no second reviewer in v1 (decision 7). A row whose id is in the current set and whose
content is unchanged **keeps the current entry exactly**, approval included, so re-publishing an
unedited sheet changes nothing.

**Download current sheet** (`CrewExperienceSheet.csv(entries:)`) writes every entry back as a row with
its id, CRLF line ends, `notes` holding the finding and `added_by` and `date` empty. Uploaded again
unedited, it publishes the same set. Before publishing, the portal shows
`CrewExperienceSheet.diff(current:next:)`: *"6 new, 1 changed, 0 removed"* (`Diff.summary`). New ids
are those not in the current set; removed ids are those no longer in the sheet; a changed entry is a
different entry under the same id.

## 6. The set and its seal

The file a phone receives for one vault: the team-learning learning set (§5) with its binding fields
replaced, applied whole (§6 there).

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.crew-experience-set` |
| `profileId` | the company's profile id |
| `vaultId` | the one vault the set is for |
| `sequence` | rises with every publish for this vault; a phone refuses a set not newer than the one it holds |
| `issuedAt` | Unix UTC seconds |
| `entries[]` | §5; every entry's `vaultIDs` is exactly `[vaultId]` |
| `retracted[]` | `{ entryID, retractedAt, reason }`, as team-learning §5 |

`CrewExperienceSet.check` is what both sides hold a set to: the kind and version, safe identifiers, at
most 5,000 entries, ids unique and 32 lowercase hex, every entry's vault the set's, origin
`recollection`, the text rules of team-learning §7.4 with the limits of §2, a retracted id not also
published, and at most **2 MiB** encoded (`CrewExperienceSet.encoder()`: sorted keys, unescaped
slashes — the bytes `revision` is computed over).

**The seal.** The set is sealed with the company secret the way a manual is (company-vaults §3), under
its own domain and magic so neither opens as the other:

```
key     = HKDF-SHA256(ikm: company secret, salt: none, info: "openglasses.crew-experience-set.v1"), 32 bytes
header  = "OGCX" ‖ 0x01 ‖ 0x00100000
AADᵢ    = "openglasses.crew-experience-set.v1\n" + profileId + "\n" + vaultId + "\n" + sequence + "\n" + revision + "\n"
          ‖ header ‖ i (UInt64 big-endian) ‖ (0x01 last chunk, else 0x00)
```

`sequence` in decimal, `revision` the plaintext's SHA-256, both the catalog pointer's. The reference is
`CompanyVaultContract.ExperienceSeal` (the chunked seal of company-vaults §3 under this domain); the
service seals with `ExperienceSeal.sealSet(_:downloadURL:companySecret:)`, which checks the set, encodes
it with `CrewExperienceSet.encoder()` and returns the sealed bytes with the vault row's `experience`
pointer. A set of n bytes seals to `sealedLength(plaintextBytes: n)`.

**On the phone** (`CompanyVaultService`, every catalog pick-up): only for a vault it has installed, not
while the open job uses that vault, and only on a team or enterprise licence. A pointer whose `sequence`
is not above the held set's is not fetched. Otherwise it downloads at most the sealed length on any
network through the same bounded client as a manual, checks the length and `sealedSha256`, opens it with
the company secret for `[profileId, vaultId, sequence, revision]`, checks the plaintext's length and
`revision`, decodes it, holds it to `CrewExperienceSet.check`, and refuses it unless its `profileId`,
`vaultId`, `sequence` and entry count are the pointer's. A set that passes replaces the vault's set whole
(`CompanyExperienceStore`); one that fails is logged by its case and the last good set keeps answering. A
pointer the company removed removes the set; one the phone could not use (`screen`) does not. The
documents are placed by a reconcile over the phone-reviewed entries and every set together, so neither
source removes the other's. A lapsed licence keeps the held set; HIPAA mode publishes nothing and reads
no learning namespace.

## 7. The `experience` catalog field

A vault row in the company-vault catalog (company-vaults §2) may carry:

```json
"experience": { "sequence": 4, "count": 42, "sizeBytes": 31877, "revision": "<sha256 of the plaintext set>",
                "sealedSha256": "<sha256 as served>", "downloadURL": "https://…" }
```

Optional and absent from the JSON when unset, so a row without it is the bytes of a v1 row; the
catalog stays `version: 1`, and a phone that does not know the field ignores it (the app's
`CompanyVaultCatalog` decodes and screens the fixture catalog unchanged). The catalog's signature
covers the pointer; the seal and `sealedSha256` cover the file.

`CompanyVaultContract.check` refuses a row whose experience is on a **company layer** (it belongs on the
vault it extends), has `sequence` below 1, `count` outside 0–5,000, `sizeBytes` outside 1 byte–2 MiB, a
`revision` or `sealedSha256` that is not a lowercase SHA-256, or a download address that is not HTTPS.
The set's size counts toward the company's total. `experienceAdvanceProblem(previous:next:)` is the
service's check against the catalog it replaces: a vault's sequence never goes down, a changed set has a
higher sequence, and any change to any vault's experience — added, changed or removed — comes with a
higher `generation`, so a phone sees it on its next foreground. The set may be fetched on any network:
at 2 MiB it is smaller than a photo.

## 8. `crew-models.md` and the experience-only vault

The company's model list is an **add-only company layer file** (company-vaults §6), `crew-models.md`,
written by `CrewModelsFile.render(models:)`:

```
# Crew models

The models this company services, from its crew experience. One section per model; the other spellings are in brackets.

## QXRT-990 (QXRT990)

## ZPL-2040 (ZPL2040)
```

One `## <model> (<other spellings>)` heading per model, the format the phone's `VaultModelIndex` reads,
names and spellings cleaned as the starter vault cleans them (brackets, `#`, commas and line breaks out;
spellings de-duplicated case-insensitively), sorted by name so the same list gives the same bytes. Every
spelling must be one the index reads as a model token (`CrewModelsFile.isIndexable`: letters, digits and
hyphens, at least five long, two digits and a letter, not the shape of a fault code, a refrigerant or a
bare size), or the file is refused by name. For a vault with manuals it adds only the models the
administrator chose to add (§4.2.1); the layer rule already forbids it from replacing a publisher's file.

An **experience-only vault** (`CrewModelsFile.experienceOnlyVault(name:id:models:)`) is a company vault
whose core is its prompt rules — which carry the validator's "fabricate" and "cite" and the lead-in —
and `crew-models.md`, and nothing else. On the phone it is an ordinary vault with no manual, so every
answer from it rests on crew experience alone and opens with the lead-in.

## 9. Citation and lead-in

`Crew experience · <subject> · <YYYY-MM-DD> · approved by <role>`, where `<subject>` is the model token,
or the equipment type for a symptom subject, and the date is `approvedAt` in UTC
(`CrewExperienceSheet.citationName`). An answer that rests on crew experience alone opens with
*"From your company's experience (not the manufacturer's manual):"* (`CrewExperienceSheet.leadIn`). The
fault code and `how_sure` are in the entry's document text (`Fault code:`, `Checked:`, `How sure:`), so
the answer can use them. Both are amendments to team-learning §7.1.

## 10. Privacy

The same duties as team-learning §8: no site or customer columns; the redaction floor of §4.6 with the
administrator reading every row; `added_by` and `date` never published; entries internal to the company
and never in a customer-facing document. On the phone (P1): team or enterprise licence only, kept on a
lapsed licence, withheld under HIPAA, part of the subject-erasure walk, never outranking a safety note.

## Fixtures

`fixtures/crew-experience-v1/`. Hand-written inputs: `vault.json` (the sheet's vault: spellings and
equipment types), `vault-with-set.json` (the same with one published id), `approval.json`
(*Service manager*, 2026-11-25), `clean.csv` (a byte-order mark, CRLF, quoted commas, a line break inside
`notes`, doubled quotes, an unknown `photo` column, a symptom subject, blank trailing rows),
`refusals.csv` (every row refusal of §4.2, one or two a row), `redaction.csv` (a phone number, an e-mail
address, a key, an IRD number, and a date and pressure that are not redacted) and `sheet-refusals.json`
(each sheet refusal of §4.1 but the two sizes, as base64 bytes; the sizes are tested in code).

Written by `REGENERATE_CREW_EXPERIENCE_FIXTURES=1 swift test --package-path Tools/LicenceIssuance
--filter CrewExperienceTests/testRegenerateFixtures`, byte for byte the same on every run:
`clean.expected.json`, `refusals.expected.json`, `redaction.expected.json` (`Report`s);
`clean.entries.json` (the clean sheet's entries, ids `00…01`–`00…04`); `set-v1.json` (them as a set for
`fixture-company`, sequence 1); `current-sheet.csv` (**Download current sheet**); `reupload.csv` (that
sheet three weeks later: one fix changed, one row deleted, two rows added), `vault-reupload.json` and
`reupload.expected.json` (its report, entries and diff: 2 new, 1 changed, 1 removed); `citations.json`;
`experience-only-vault/` (`manifest.json` and `crew-models.md`); `set-v1.sealed` (`set-v1.json` sealed
for `fixture-company`, vault `fixture-crew-units`, sequence 1, with the company-vault fixtures' company
secret and nonces derived from the chunk index, so it regenerates to the same bytes);
`catalog-experience-v1.json` (an unsigned catalog payload whose row carries `experience` for
`set-v1.sealed`); `negative-catalogs.json` and `negative-advances.json` (each refusal
of §7 with its words).
