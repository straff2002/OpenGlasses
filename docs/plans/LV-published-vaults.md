# Plan LV — Published Vaults (one partner's vault, many companies, each with its own manuals)

**Status:** 🚧 P0 built 2026-11-15 (headless): the contract's new optional fields (`publisher`, `sealedCore`,
`expects`, `frozen`, `extends`) and the sealed core (`CoreSeal`, domain `openglasses.company-core.v1`, sharing one
chunked construction with the manual seal, whose bytes are unchanged) in the core package, with
`company-vaults-v2` fixtures; on the phone `VaultLayerMerge`, `ExpectedManualMatch`, `CitationEditionCheck`, a
frozen entry never updated, and `VaultDocument.revision`/`.origin`. The catalog version stays 1 (the fields are
additive); the service raises `minAppBuild` to the first LV build. **P1 built 2026-11-16 (headless + one UI test):**
the company vault pass opens a sealed core (length, `sha256`, company secret) before the installer, which skips the
archive checksum for it and still checks the pack signature; a company layer installs as `_baselines/{id}.company`,
validated as a layer and refused whole when it would replace a publisher file; the plan orders a layer after its
base, lays it again over a base that changed and removes it with its base; the registry and `VaultStore` read
publisher → company → technician; company manuals carry `revision` and `origin: company` (My Manuals uploads
`technician`, photographed ones `capture`); the rows say "from ⟨partner⟩ · version ⟨n⟩", the manual checklist
(opening a list naming each), frozen and "⟨vault⟩ was removed by ⟨partner⟩"; an answer's prompt carries the
source line and `CitationEditionCheck`'s notes for pages the vault's index cites, beside the downloading note. **P3 (shared manuals) planned 2026-11-16, not built:** a partner who may distribute a manual uploads it once; it is
encrypted once and each subscribed company receives a small wrapped key ([§8](#8--shared-manuals-one-copy-a-key-per-company)).
P2 device pass owed; catalog sync of the new strings owed. All six [decisions](#decisions-for-greig) taken: 1–3 by the owner while discussing, 4–6 as
recommended (2026-11-15). Manual matching treats one-sided evidence as no difference: an edition or revision known on only one side is
not a difference.
**Track:** Field Assist — fleet and publishing. Company vaults, the vault store, manuals, answers.
**Builds on:**
- Plan [LR](LR-company-vaults-from-the-portal.md): `CompanyVaultCatalog`, the pure `CompanyVaultPlan`, the
  renewal pass in `CompanyVaultService`, `CompanyManualSeal`, the job and Wi-Fi waits, the rows under
  *Managed by ⟨org⟩*.
- Plan [EG](EG-vault-packs.md): signed packs, and `VaultImporter.installValidated`'s baseline re-push, which
  keeps the technician's overlay across an update.
- Plan [FS](FS-subscriber-vaults-and-vault-links.md): the archive format and the *Signed by ⟨publisher⟩* badge.
- Plan [HK](HK-controlled-document-revisions.md) (drafted): document revisions. This plan takes only the part
  it needs, a content hash on a manual.

**Sits beside:**
- Plan [LW](LW-vault-authoring.md): building a vault from manuals on the phone, which is how a partner writes
  the vault this plan publishes.
- The service plan `docs/plans/published-vaults.md` in the private service repository: the partner's library,
  subscriptions and the per-company checklist. This plan carries only what the phone reads.

---

## Trigger

A partner writes good vaults: the model-to-manual map, the fault codes, the symptoms in a technician's words,
the chains. They want to sell the same vault to many companies and invoice each one themselves. Each company
supplies its own copies of the manuals, because the partner cannot resell a manufacturer's manuals.

Today the partner would upload every improvement once per company. A preset hands a company its vaults only at
sign-up, as version 1, and after that each company holds a separate copy with nothing linking it back. Twenty
customers means twenty uploads of version 5.

## Outcome

- The partner publishes version 5 of their vault once. Every company subscribed to it has it on its phones by
  their next foreground, installed after any open job, as LR does today.
- Each company's phones show the vault as the partner's: *"Residential split systems · from ⟨partner⟩ ·
  version 5"*. An answer that comes from the partner's files says whose they are.
- The vault knows which manuals it was written against. The row says *"9 of 12 manuals · 2 are a different
  revision · 1 missing"*, and names them. The company's administrator uploads the missing ones in the portal.
- An answer that cites a page in a manual the company holds at a different revision says so: *"Your copy of
  the installation manual is a different revision from the one this vault was written for; check page 42."*
- The company adds its own files on top (its own site notes, its own preferred parts) without forking the
  vault. The partner's version 6 arrives and the company's additions are still there. So are the technician's
  own edits.
- The partner stops a subscription (an unpaid invoice) → the vault leaves that company's phones after the
  current job, with a notice naming the partner.
- The partner stops being a partner → every subscribed company keeps the last version, marked *"No longer
  updated by ⟨partner⟩"*. Nothing is removed until the company removes it.
- A partner with a manufacturer's distribution agreement uploads that manual **once**. Every subscribed company
  has it, nobody else can read it, and the service stores one copy however many companies there are. The
  agreement ends → it is removed once and leaves every company's phones after the current job.
- The partner's files cannot be read by anyone outside a subscribed company, even with the download URL, and
  cannot be exported from a phone.

## What exists, and what doesn't

**Exists (verified against `main` at 8ce913936):**
- A company catalog per company (`CompanyVaultCatalog`): vault entries (an EG pack) and manual rows. Manual rows
  are sealed with the company secret (`CompanyManualSeal`, domain `openglasses.company-manual.v1`) and carry
  `revision`, the SHA-256 of the plaintext. Installed revisions live in `CompanyVaultState.manuals`.
- Vault core packs are **signed, not sealed**: the phone checks the checksum and `VaultPackSignature.verify`,
  and no company secret is involved. Anyone holding a catalog's download URL can read the core files.
- Export is already closed for these vaults. `VaultExporter.isExportable` refuses any vault with a `pack.json`
  sidecar, which every signed-pack install writes (org packs and LR company vaults included).
- The overlay: `installValidated` replaces only the baseline on an update. The technician's edits to existing
  core files, the document ledger and table checks survive. `VaultFilesEditorView` edits only files already in
  `manifest.files`; it cannot add one.
- Manuals are carried across an update by `VaultDocumentCarry`, with no record of where each came from (the
  company, the partner's list or the technician).
- `VaultDocument.edition` is a free-text label. There is no content hash on a document; a company manual is
  laid in as `kind: "company_manual"` without its revision.
- Service side: versions are numbered per company per vault, the vault library is vendor-only, and presets give
  vaults only at sign-up. No vault is owned by a partner across companies.

**Doesn't exist:**
1. A vault that belongs to a publisher and is delivered to many companies, with the publisher named on the
   phone.
2. A sealed core, so the partner's files are useless without a subscribed company's activation file.
3. The list of manuals a vault expects, and a check of the company's copies against it.
4. A company layer between the publisher's files and the technician's overlay.
5. A frozen vault: kept, never updated, said so.

## Design

### 1 · The contract (additive)

A vault entry in the company catalog gains optional fields. An entry without them behaves exactly as today.

```json
{
  "id": "…", "vaultId": "…", "version": "12", "…": "…",
  "publisher": { "id": "p-…", "name": "⟨trading name⟩", "version": 5 },
  "sealedCore": true,
  "expects": [ { "key": "install-manual", "title": "Installation manual", "edition": "Rev C",
                 "revision": "<sha256 of the plaintext>" } ],
  "frozen": false
}
```

A company layer is a second vault entry with `"extends": "<vaultId>"` and no `publisher`.

- `publisher.version` is the partner's own number, the one people talk about. `version` stays the per-company
  number the service already writes, so LR's comparisons are unchanged.
- `sealedCore`: the pack zip is sealed with the company secret under a new domain
  (`openglasses.company-core.v1`), the same chunked construction as `CompanyManualSeal`. The checksum covers the
  sealed bytes, the signature the plaintext pack, as for manuals.
- `expects` comes from the archive the partner uploaded (Plan LW writes it). `revision` is optional: a partner
  may name a manual by title and edition only.
- `frozen` is written by the service when a publisher ends. The phone stops comparing versions for that entry.

The fixtures go in `Contracts/fixtures/company-vaults-v2/`, shared with the service as `company-vaults-v1` is.
The catalog's `minAppBuild` keeps older builds from receiving entries they cannot open.

### 2 · Three layers on the phone

Reading order, last one wins: **publisher baseline → company layer → technician overlay**.

- The company layer installs as its own baseline beside the vault's (`_baselines/{id}.company`), so a publisher
  update and a company update never replace each other.
- `VaultStore`'s merge takes the layers in that order. A pure `VaultLayerMerge` decides what each file resolves
  to and is tested headless.
- The company layer may **add** files and add prompt rules ([decision 4](#decisions-for-greig)). A file the
  company layer adds is listed in the merged manifest like any other.
- The technician's overlay keeps working as today. Removing the company layer leaves the publisher's vault and
  the technician's edits.

### 3 · Where each manual came from

`VaultDocument` gains two optional fields: `revision` (the content hash, written when the manual is laid in;
company manuals take it from the catalog row) and `origin` (`company`, `technician`, `capture`).
`VaultDocumentCarry` keeps both across an update. That is what lets the checklist tell a company copy from a
technician's own copy, and lets the next section compare revisions.

### 4 · Expected manuals (`ExpectedManualMatch`, pure)

The entry's `expects` × the vault's installed documents → per expected manual: *matched*, *different
revision*, *missing*, plus any extra manual the vault holds that is not expected. Matching goes by `revision`
when both sides have one, then by title and edition.

The vault's row under *Managed by ⟨org⟩* shows the summary and opens a list naming each manual. The phone
never reports this list anywhere: the portal works out the same checklist from what was uploaded to the
company (service plan), so a technician's own manuals stay off the service.

### 5 · Answers that cite a page (`CitationEditionCheck`, pure)

Plan LW's index rows carry the manual's key and a page. When an answer cites one, and the company's copy of
that manual is a *different revision*, the answer carries one line saying so and the page. When the manual is
*missing*, the answer says the vault expects a manual the phone doesn't hold, by title. This sits beside LR's
*"still downloading"* line and uses the same place in the answer.

### 6 · The publisher on the phone

- The row: *"⟨vault⟩ · from ⟨partner⟩ · version ⟨publisher.version⟩"*.
- The source line on an answer from the partner's files: *"From ⟨partner⟩'s vault"*, beside the manual and
  page citations the answer already gives.
- A removal notice: *"⟨vault⟩ was removed by ⟨partner⟩"*.
- Frozen: *"No longer updated by ⟨partner⟩ · version 5 kept"*. The company removes it in the portal when it
  wants to; the phone gains no new control.

### 7 · What does not change

The job wait, the Wi-Fi wait for manuals, the space check, lapse locks and erasure on leaving all come from LR
and CT unchanged. The company's licence lapsing still locks a published vault like any other company vault. No
new data leaves the phone: the fleet view's installed versions (LR P2, disclosed) already cover published vaults.

### 8 · Shared manuals (one copy, a key per company)

Added 2026-11-16, when the partner asked to upload a manual once rather than to each company (P3). Sealing a copy
per company stores the manual once per company: 30 manuals of 20 MB is 60 GB at 100 companies. Instead the manual
is encrypted **once** and only its key is given to each company (envelope encryption).

- **The file:** the service encrypts the manual with a random 32-byte content key, using the same chunked
  AES-GCM construction as `CompanyManualSeal` under its own domain (`openglasses.shared-manual.v1`), with the
  context `[contentId, keyId]`. One file, one URL, served like any sealed manual.
- **The key, per company:** the content key wrapped with a key derived from that company's secret (HKDF-SHA256,
  domain `openglasses.shared-manual-key.v1`, context `[profileId, contentId, keyId]`), then AES-GCM. About 100
  bytes, carried on the company's own manual row.
- **The manual row** gains an optional `shared {contentId, keyId, wrappedKey}`. With it, `sealedSha256` and
  `sizeBytes` describe the shared file, and `revision` is still the plaintext's SHA-256. Without it, the row is a
  company-sealed manual exactly as today.
- **On the phone:** unwrap the content key with the company secret, open the shared file with it, check
  `revision`, then lay the manual in as any company manual (`origin: company`). Everything after that (the
  checklist, the revision line, the Wi-Fi wait, the job wait, removal) is unchanged.
- **Rotation:** when a company leaves (unsubscribed, the manual's company list changed, the agreement's end date
  passed), the service re-encrypts the one file under a fresh content key with a new `keyId`, and wraps it again
  for the companies that remain. A company's phones may have kept the old key; the old file is deleted, so the
  old key opens nothing that is still served. The remaining companies download the manual again, the same cost
  as replacing it.
- **Older phones:** a phone without P3 would treat a `shared` row as a company-sealed manual and fail to open it.
  So the service writes `shared` rows only into a vault row whose `minAppBuild` is at least the first P3 build
  (its own setting, `sharedManualsMinAppBuild`, alongside `publishedVaultsMinAppBuild`).
- **What anyone can see:** two companies' catalogs point at the same file, so someone holding both could tell
  they share a manual. They still cannot read it. Accepted as the price of storing it once.
- **The company's own copy wins:** a company that uploaded its own copy of the same manual (same `revision`)
  keeps its copy; the service writes no `shared` row for it there.

## Decisions for Greig

**Taken while this was discussed, 2026-11-15:**

1. **Payment.** ✅ The partner invoices their own customers. Avenkin delivers and takes no payment for a
   published vault. Unsubscribing is the partner's lever. A catalogue run by Avenkin, with a revenue share, is
   out of scope.
2. **A company may extend a published vault.** ✅ As a company layer, kept across the partner's updates.
3. **A publisher who leaves.** ✅ Every subscribed company keeps the last version, frozen.

**Taken as recommended, 2026-11-15:**

4. **May the company layer replace one of the partner's files?** *Recommended:* not at first. Add files and
   prompt rules only, so a partner's update can never collide with a company's change. Replacing comes when a
   pilot asks for it, with the row saying which partner file the company has replaced. Not recommended: allow
   replacement now, which needs a conflict rule for every update.
5. **Seal every company vault's core, or only published ones?** *Recommended:* every company vault from this
   build on. One rule, a small cost, and a company's own vault files are as private as its manuals. Not
   recommended: seal only published vaults, which leaves two kinds of company vault to reason about.
6. **The revision line in answers.** *Recommended:* only when the vault's index cites a page in a manual held at
   a different revision. Not recommended: a line on every answer from that vault, which would be noise on most
   answers.

**Taken by the owner, 2026-11-16, with the partner's agreement:**

7. **Shared manuals.** ✅ A partner who may distribute a manual uploads it once, under a rights line that says
   so, and it reaches every company they choose, encrypted once with a key per company (§8). The storage counts
   against the partner, not each company's 1 GB.

**Proposed to the partner, 2026-11-16 (confirm before P3 is built):**

8. **Which companies.** *Recommended:* every company subscribed to the vault, with a per-manual *only these
   companies* option for agreements limited to some customers or regions.
9. **End date.** *Recommended:* an optional agreement note and end date on the manual; after the end date the
   service stops delivering it and rotates it away, with a line in the portal a week before.
10. **A company's own copy.** *Recommended:* if a company already holds the same manual (same revision) it
    keeps its own copy and receives no shared key for it.

## Phases

The service plan's S0 and this plan's P0 land together (the contract lives in `Tools/LicenceIssuance`, pinned
by the service's `core.lock`). The phone's P1 is useless until the service's S1 is deployed.

### P0 — the contract and the pure core (headless)

- `CompanyVaults.swift` in the core package: the new fields, the core seal (shared with the service), the
  `company-vaults-v2` fixtures and their negative cases (a sealed core opened with another company's secret, a
  frozen entry offered an update, an `extends` naming a vault not in the catalog).
- `VaultLayerMerge`, `ExpectedManualMatch`, `CitationEditionCheck`; `VaultDocument.revision` and `.origin`
  decoding (absent → byte-identical behaviour).
- **Exit:** the tests, `Contracts/tests/*.py` green, and a v1 catalog applying exactly as before.

### P1 — on the phone (headless, plus one UI test on the simulator)

- `CompanyVaultService` opens a sealed core before handing it to the installer; installs a company layer as its
  own baseline; skips updates on a frozen entry.
- Documents laid in with `revision` and `origin`; `VaultDocumentCarry` keeps them.
- The rows: publisher, version, the manual checklist, frozen; the answer's source line and revision line.
- **Exit:** an in-memory transport and a fixture company: subscribe → install; v5 → v6 with a company layer and a
  technician edit, all three kept; a manual at a different revision named on the row and in an answer; a frozen
  entry never updated; a sealed core refused with the wrong secret.

### P2 — device pass (owed)

Two phones in two companies subscribed to one partner vault, one company with an extra layer: one publish
reaches both; each row's checklist matches what that company uploaded; an answer citing a different revision
says so; the partner ends → both keep the last version, marked frozen.

### P3 — shared manuals (headless; with the service's S4)

- Core package: the shared-manual seal, the key wrap and unwrap, the row's `shared` field and its checks (a
  `shared` row must name a vault row whose `minAppBuild` is high enough), fixtures `company-vaults-v3` with
  negatives (another company's secret, a rotated `keyId`, a wrapped key for another profile).
- Phone: the manual download unwraps the key and opens the shared file; a rotation replaces the manual like a
  new revision.
- **Exit:** two fixture companies with one shared file: both open it; a third company's secret can't; after a
  rotation the old key opens nothing served and both remaining companies still open the new file.

## Risks

- **Page references move between revisions.** The checklist and the revision line make that visible; they
  cannot fix it. A partner who supports several revisions lists each in `expects`.
- **The same manual is stored once per company.** Each copy is sealed with a different secret, so it cannot be
  shared. It counts against each company's own limit.
- **Rights.** The company's administrator ticks the rights line for its own copies. A partner who uploads on a
  company's behalf makes that claim for each company.
- **Liability between the partner and their customer** (a wrong figure in a published chain) is a matter for
  their terms of sale. The phone's part is to say plainly whose files an answer came from. Get those terms
  reviewed before the first sale.
- **The manufacturer's wording.** A published vault should index a manual (code, short label, page), not copy
  its tables. Plan LW's publishing check flags rows still in the manual's words.

## Out of scope

A catalogue or payments run by Avenkin; selling to solo subscribers through in-app purchase; assigning a vault
to some of a company's phones rather than all; a company layer that replaces partner files (decision 4); a
partner signing in from the app to publish (Plan LW hands off by export).
