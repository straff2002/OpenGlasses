# Plan LR — Company Vaults from the Portal (upload once, every phone has it, updates arrive by themselves)

**Status:** 📝 Drafted 2026-11-13. Nothing built. [Decisions](#decisions-for-greig) open; decision 1 (manuals
may be uploaded, with size limits) was given while drafting.
**Track:** Field Assist — fleet. The organisation profile, vault packs, manuals.
**Builds on:** Plan [CT](CT-org-configuration-profiles.md) (the signed profile, the daily renewal, *Managed by
⟨org⟩*, pack at enrolment), Plan [EG](EG-vault-packs.md) (signed packs, the catalog fetch/verify/install path,
the baseline re-push that keeps the technician's overlay), Plan [JS](JS-licence-sales-and-device-seats.md)
(the vendor-run service, one profile per company, the sealed activation file and its company secret, device
seats), Plan [FS](FS-subscriber-vaults-and-vault-links.md) (archive limits, staging, review-before-install).
**Sits beside:** Plan [HO](HO-office-delivery-phone-half.md) (manuals from Avenkin Office, for a firm that runs
one), Plan [FN](FN-vault-manual-removal.md) (removing a manual), Plan [HK](HK-controlled-document-revisions.md)
(document revisions).
**Service side:** planned in the private service repository; this plan carries only the contract the phone
reads.

---

## Trigger

A partner running pilots with technicians in other cities: installing and updating vaults on every phone by
hand is the bottleneck, and it is the customer's first impression. Taking a technician's phone to set it up,
or sending instructions to work through, makes the app feel complicated before it has shown its value. The
ask: upload a vault to the portal, assign it to a company, and have the phones download it and pick up each
new version by themselves. The partner, or the customer, may upload the company's own manuals too.

## Outcome

- A technician in another city enters the company's activation key once (or scans its code). Every vault the
  company has, with its manuals, arrives on the phone. Nobody touches the phone after that.
- The partner uploads version 4 of a vault on Tuesday morning. Each phone has it by its next profile check
  (launch, coming to the foreground, or daily). *Check for Updates* under *Managed by ⟨org⟩* fetches it now.
- A technician is on a job when version 4 lands → nothing changes under them. The update installs when the job
  closes, and the row says so: *"Version 4 ready — installs after this job."*
- The technician's own edits and notes on that vault survive the update (EG's baseline re-push, unchanged).
- A 60 MB wiring manual is added to a vault → phones download just that file, on Wi-Fi by default. The vault
  works in the meantime, and an answer that would have cited that manual says it is still downloading.
- The partner removes a vault from the company → it leaves each phone after the current job, with a notice.
- The licence lapses → the company's vaults lock and nothing is deleted (CT/JS, unchanged). The technician
  leaves the firm → they are erased with the rest of the firm's packs (CT PR 4, unchanged).
- *Managed by ⟨org⟩* lists each company vault: name, version, when it updated, and any failure by name
  (*"Not enough space for the Lennox manuals: 420 MB needed"*), retried at launch and foreground.

## What exists, and what doesn't

**Exists (verified against `main` at ed0d3ac66):**
- `ConfigProfile.vaultPack: VaultPackReference?` (`packId`, `documentsSource`), set from the portal by choosing
  among a vendor preset's packs. `OrgProfileManager` installs it at enrolment through `OrgPackInstaller`,
  holding back the default vault and the Field Assist switch until it lands, and reinstalls it after a lapse
  erasure.
- `OrgPackInstaller.install(packId:)` reads the one public signed catalog (`Config.vaultPackCatalogURL`) and
  **returns at once if any version of that pack is installed**. Nothing ever updates an org pack.
- `VaultPackCatalogService` takes the catalog URL and the public key as parameters. `install(_:)` downloads,
  checks the catalog's sha256, verifies the pack signature over every file, runs the structural checks and
  hands the pack to `VaultImporter`. `VaultPackRowState` already resolves *update available* from
  `installedVersion` vs the entry's `version`, but only for a tap on the Vault Packs screen.
- `VaultPackCatalogEntry` has `version`, `minAppBuild`, `sizeBytes`, `sha256`, `packSignature`.
- `OrgProfileManager.renewIfDue(force:)` runs at launch, on foreground, daily and on *Check for Renewal*.
  `seams.activeJobId()` already tells it whether a job is open (the lease's mid-job grace uses it).
- `OrgCredentialSeal`: AES-GCM under HKDF-SHA256 of the company secret, which reaches the phone only inside
  the sealed activation file. The Workiz key already travels this way in a public profile.
- Size caps today: a pack entry ≤ 20 MB (`VaultPack.maxEntryBytes`), a link archive ≤ 250 MB
  (`Config.vaultLinkMaxBytes`), with entries ≤ 96 MB; a PDF ≤ 128 MiB (`CapturedManualContract.maximumPDFBytes`);
  a Word manual ≤ 100 MB and its text copy ≤ 20 MB (`ManualFileUpload`).

**Doesn't exist:**
1. A company-owned vault. A profile can only name a pack in the vendor's public catalog, which lists none.
2. Updates. Nothing compares the installed version with the catalog, outside a tap on Vault Packs.
3. More than one vault per company: `vaultPack` is singular.
4. Manuals delivered to a phone. EG packs never carry OEM manuals by design, and the 20 MB entry cap would
   refuse most PDFs anyway.
5. Any way for the partner to see which phones have which version.

## Design

### The contract

The profile gains one optional field, a pointer and never content:

```json
"companyVaults": { "catalog": "https://…/c/<opaque>/vaults.json", "generation": 7, "minAppBuild": 680 }
```

`generation` rises with every change the partner makes. The phone fetches the catalog only when the generation
is above the one it has applied, so the daily check costs one profile fetch, as today.

The **company vault catalog** is signed by the vendor's pack-catalog key (the same verification as EG's, with a
different document type) and is bound to one company. It authenticates `profileId` and `generation`, so one
company's catalog cannot be served to another and an older catalog cannot be replayed. It lists:

- **vaults**: `id`, `vaultId`, `version`, `name`, `sizeBytes`, `downloadURL`, `sha256`, `packSignature`,
  `minAppBuild`. This is an EG pack in every byte (core files only, no manuals), so `VaultPackCatalogService`
  installs it unchanged.
- **manuals**: `vaultId`, `fileName`, `revision` (content hash), `sizeBytes`, `sealedSha256`, `downloadURL`,
  `kind` (pdf / docx / md). One row per file, so adding or changing a manual moves only that file.

Manual files are **sealed** with the company secret (`OrgCredentialSeal`'s construction, a new info string,
chunked so a 128 MB file never sits in memory twice). The catalog and the profile are as public as the profile
is today. A manual is useless to anyone without the activation file.

Older builds ignore `companyVaults`. The service never writes the old `vaultPack` field for a company vault, and
the portal shows the `minAppBuild` the company's phones need.

### On the phone

- **`CompanyVaultPlan`** (pure): installed state + the verified catalog + whether a job is open + the network
  + free space → a list of steps: *install*, *update*, *remove*, *download manual*, *remove manual*, *wait for
  the job*, *wait for Wi-Fi*, *not enough space (bytes)*. Every decision is in here and tested headless.
- **The renewal pass** runs the plan after a successful profile renewal, and on *Check for Updates*. Vaults
  first (small, any network), then manuals. Each manual downloads into protected staging, is checked against
  `sealedSha256`, unsealed, checked against `revision`, and handed to the existing manual import, which indexes
  it on the phone. Failures are named on the vault's row and retried at launch and foreground, as
  `packInstallError` is today.
- **Never mid-job.** An update or removal that would change a vault while `activeJobId` is set waits. A *new*
  vault, or a new manual in a vault the job isn't using, may install during a job.
- **Wi-Fi for manuals** by default ([decision 3](#decisions-for-greig)). A *Download now* on the row uses
  cellular once. Vault core files use any network.
- **Space:** before a manual set, the plan needs its size × 2 plus 1 GB free; otherwise it names the shortfall.
- **The technician's own manuals** added to a company vault are kept across updates. They are removed with
  the vault only after the removal notice.
- **Updating, removal, lapse and leaving** reuse what exists: EG's baseline re-push for an update, FN's
  removal for a manual the partner deletes, CT's lock on a lapse and erase on leaving or revocation.
- **Rights:** a manual comes down only to phones enrolled in the company it was uploaded for. The app never
  sends one anywhere (the FS rule that manuals never leave the phone through the app stands).

### What the partner sees (service side, outlined)

Upload a vault archive (the `make-vault-archive` format) for a company, or for every company on a preset.
Upload or replace manuals into a vault, by the partner or, in a later phase, the company's own administrator.
Each upload states that the uploader may give the file to that company's technicians. Every change raises the
generation. A per-company storage meter, and the limits below, enforced before anything is stored.

### Size limits ([decision 2](#decisions-for-greig))

| What | Limit | Why that number |
|---|---|---|
| One PDF manual | 128 MiB | the phone's own captured-manual PDF cap |
| One Word manual | 100 MB (text copy ≤ 20 MB) | `ManualFileUpload` today |
| One Markdown / text file | 20 MB | `ManualFileUpload` today |
| A vault's core files (one pack) | 250 MB, each file ≤ 20 MB | the link cap and the pack entry cap |
| Everything one company stores | 2 GB to start, the vendor can raise it | the vendor's disk and backups |
| What one phone downloads | the company's total | the free-space rule above decides, not a second cap |

The service refuses an over-limit upload with the limit in the message. The phone enforces the per-file caps
again, because a signed catalog is not a reason to trust a size.

### Later: which phone has what

The daily seat renewal (JS P2) could also carry the vault ids and versions installed, so the portal shows
*"7 of 9 phones on version 4"*. That is a new disclosed field, so the privacy manifest and in-app copy change in
the same PR ([decision 4](#decisions-for-greig)). Assigning a vault to specific phones rather than the whole
company hangs off the same seat identity, a seat-scoped catalog. Not planned until a pilot needs it.

## Phases

One PR each, headless first; the service has its own phases in the private repository, and the app's P1 is
useless until the service's first phase is deployed.

- **P0 — the contract and the plan (headless).** `ConfigProfile.companyVaults` (decode, absent → byte-identical
  apply), `CompanyVaultCatalog` (decode, verify, bound to `profileId`, generation high-water mark stored on the
  record, a replayed or lower generation refused), the manual seal/unseal (chunked, pinned by fixtures shared
  with the service package as `OrgCredentialTests` are), `CompanyVaultPlan` with every case above.
  **Exit:** the tests, plus a profile fixture with and without `companyVaults` applying identically otherwise.
- **P1 — delivery.** The renewal pass, *Check for Updates*, staging and per-file downloads, the job and Wi-Fi
  waits, the space check, the rows under *Managed by ⟨org⟩*, failures named and retried, the answer that says a
  manual is still downloading. `OrgPackInstaller` learns to update a public-catalog pack too (the same version
  comparison), so existing profiles get updates as well. **Exit:** an in-memory transport and a fixture company:
  v1 → v2 with an open job (waits, then installs), a manual added (only it moves), a manual replaced, a vault
  removed, a tampered manual refused, a replayed catalog refused, not enough space named.
- **P2 — optional, the fleet view.** Installed versions on the seat renewal, with the disclosure. Only on
  [decision 4](#decisions-for-greig).
- **P3 — device pass.** Two phones on different networks, one enrolled fresh from the activation key: every
  vault and manual arrives; v2 uploaded mid-job installs after the job; a 100 MB manual waits for Wi-Fi, then
  *Download now* on cellular; airplane mode mid-download resumes at the next foreground.

## Decisions for Greig

1. **Manuals in company vaults.** *Given 2026-11-13:* the partner or the customer may upload their own manuals,
   with size limits. They are delivered sealed to that company's phones only, never through the public catalog,
   and the app still never sends a manual off the phone.
2. **The limits** in the table. *Recommended:* as written. The 2 GB company total is the only one not already
   set by the app.
3. **Manuals over cellular.** *Recommended:* Wi-Fi by default with *Download now* per vault, and a company
   setting the partner can switch to "any network" for crews who live on hotspots.
4. **The fleet view (P2).** *Recommended:* yes, after P1. It answers "has everyone got the new version?" without
   a phone call, at the cost of one more disclosed field on the seat renewal.
5. **Customer self-upload.** *Recommended:* the partner first; the company's own administrator uploads manuals
   in the service's second phase, limited to their own company and to manuals (not vault core files).
