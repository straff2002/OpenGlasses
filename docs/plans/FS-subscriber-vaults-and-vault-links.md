# Plan FS — Subscriber Vaults and Vault Links (build your own, and receive one by link or QR)

**Status:** 🚧 **PR1 implemented 2026-09-22 (headless).** Owner decisions 2026-09-21: a Field Assist
subscriber may build their own vaults; the perpetual unlock is retired, so monthly and annual are
the only store products; a vault should be receivable from a URL or a QR code issued by a publisher's
site — **receive only; the app never shares a vault** (owner correction the same day).
PR1 shipped §1 and decision 4: `FieldAssistCapability` + `FieldAssistCapabilityCheck` resolved from
the evidence in one pure function, every tier comparison in the app replaced by a capability ask, a
pure `CustomVaultGateState` behind the Custom Vaults screen, and the manuals-out-of-every-export
rule with the `documents_included` manifest marker and the import message that names the files to
supply. Copy updated across the tier descriptions, the paywall, Custom Vaults and both export
footers; guide updated. **PR2 pending** — the vault archive, receiving by link or QR, the publisher
list and the unverified-source path.
**Priority:** next after the FO chain, ahead of [FR](FR-fictional-example-vault.md) (owner decision 2026-09-22). Two PRs.
**Surfaces:** entitlement policy, Custom Vaults UI, the vault import path, one URL scheme / universal
link route and the QR scanner. No new backend; nothing is hosted by the vendor.

## Why

A pilot technician builds a vault from his employer's manuals and wants the next technician to have
it without a computer, a folder picker or an afternoon of on-device text recognition — by buying the
manual set from whoever may lawfully supply it and scanning the code on the confirmation page. Today that is
blocked twice: a store subscriber cannot import a vault with manuals at all, and the only way to
move a vault between phones is an exported folder carried by hand.

The audience is every subscriber, not one pilot: any trade, any equipment, whatever the subscriber
wants the assistant to know. So building your own vault has to be a first-class, documented path —
the vault guide, the off-phone archive script and the fictional example ([FR](FR-fictional-example-vault.md))
are the on-ramp — and receiving one by link serves the people who would rather buy a set than build it.

## Verified starting point (main, re-checked 2026-09-22 against build 415)

- **Every store purchase grants `solo`.** `StoreKitService.fieldAssistProductIds` = the retired
  non-consumable plus monthly and annual; the paywall already offers only the two subscriptions
  (`fieldAssistCatalogProductIds`), and the retired unlock is kept solely so existing owners keep
  passing receipt validation (`ownsFieldAssistUnlock`). The evidence carries the product id
  (`FieldAssistEntitlementEvidence.verifiedStoreProduct(productID:expiration:)`), so a subscription
  can be told from the retired unlock without a new store call — which is what makes decision 1
  implementable as a pure function.
- **Own manuals need `team`.** `VaultImporter.syncDocuments` refuses to ingest unless
  `FieldAssistEntitlement.shared.isGranted(atLeast: .team)`; cleanup-only syncs and manual removal
  are deliberately ungated (FN — `VaultManualRemoval.isPermittedByEntitlement` is `true`, always).
  `FieldAssistTier.team.capabilitySummary` reads "Everything in Solo, plus your own vaults and
  manuals, audited PDF export, and organisation-issued configuration". Team is reached only by a
  signed licence code. Organisation-issued configuration has **no code yet** — CT is unbuilt, so the
  phrase is a promise the tier copy makes and nothing enforces.
- **Every tier comparison in the app, in full** (the migration surface): `VaultImporter`'s ingest
  gate, `SessionExporter.export`'s audited-export gate, `VaultRegistry.isUnlocked`'s `"enterprise"`
  gating case (a customer-imported vault), `VaultManagerView.teamCheck` (the import button and its
  explanation), `VaultPackAccess.isUnlocked`'s `tier == .enterprise` (an enterprise licence includes
  every pack), and `FieldAssistSettingsView`'s `grant.tier == .solo` copy branch. Nothing else
  compares tiers.
- **Moving a vault exists, by hand, through exactly one implementation.** `VaultExporter.export`
  writes a folder (manifest + core files merged overlay-over-baseline + procedures + documents,
  including both the extracted text *and* the manufacturer's original PDF beside it, EK P3), and it
  is reached from two screens: the Custom Vaults row swipe and Field Assist › Reference Files.
  Re-import goes through the folder picker; `VaultValidator` and `VaultImporter.installReporting`
  already treat the folder as untrusted input. There is **no separate pack export**: a
  pack-installed vault fails `VaultExporter.isExportable`, and `VaultPackCatalogService.installPack`
  refuses a pack whose manifest lists documents at all — so the manuals-out rule has one site.
- **Signed downloadable content exists, for a different job.** Vault packs ([EG](EG-vault-packs.md))
  download → checksum → verify signature → unzip → install, from the vendor's signed catalog, and
  **never contain OEM manuals**. The org-profile design ([CT](CT-org-configuration-profiles.md)) fixes the
  rule this plan reuses: *a QR is a pointer, not a payload*.

## Decisions

1. **Custom vaults become a subscriber capability.** Gate manual ingest on a *capability*
   (`ownVaults`) rather than on the tier ordinal: granted by an active monthly/annual subscription
   and by team/enterprise licences; **not** granted by the retired perpetual unlock (grandfathered
   owners keep exactly what they bought: bundled vaults). Audited export and organisation-issued
   configuration stay team-only. Tier copy, paywall copy and the Custom Vaults "needs a
   subscription" explanation change to match; a lapsed subscription keeps installed vaults readable
   and removable but stops new ingest — the FN behaviour, unchanged.
2. **The app receives vaults; it never helps pass them on.** (Owner correction, 2026-09-21: an
   in-app "share this vault" would make every subscriber a redistributor of manufacturers' manuals.)
   There is **no** share-as-link, no QR generation and no upload in the app. A vault link comes from
   a *publisher's* site — for example the page a customer lands on after buying a manual set from a
   distributor who holds the right to supply it — as a URL to paste or a QR to scan. The publisher
   carries the distribution rights; the vendor never hosts, mirrors or proxies a vault, and the
   vendor catalog stays manual-free.
3. **Nothing installs from a scan or a paste alone.** A downloaded vault is untrusted: its core
   files go into the system prompt. Review-then-confirm is mandatory, every time.
4. **Manuals never leave the phone through the app** (owner decision 2026-09-21). Every vault
   export — hand-imported, received by link, pack-based — writes the manifest, core files (with the
   user's overlay edits) and procedures only. Manuals (extracted text, originals, figures,
   recognition checkpoints) are left out, the exported manifest lists them as *required, not
   included*, and the export screen says so. Re-importing such an export on another phone behaves as
   an example vault does on a fresh clone: it asks for the manuals. This **changes existing
   behaviour**: today's folder export includes `documents/`. Session/work-record exports are
   unaffected — they carry citations, not manual text.
5. **Signed is the normal path; unsigned is possible, at the subscriber's own risk, and loudly
   marked** (owner decision 2026-09-21, revising "refuse unsigned" from earlier the same day). A
   validly signed archive from a listed publisher shows "Signed by <publisher>" and installs on one
   confirmation. An **unsigned or unknown-publisher** archive shows a highlighted warning block —
   not signed, the app cannot tell who built it or whether it was altered, its reference files
   will steer the assistant's answers, only continue if you know and trust the source — and
   requires a second, explicit acknowledgement before the install button enables. The vault is then
   badged "Unverified source" wherever it is listed and in the job record of any session that uses
   it. Still refused outright, no override: a **tampered** archive (signature or checksum fails) and
   a **revoked** publisher. An organisation profile (CT) can forbid unsigned installs, and
   medical/HIPAA mode always does. Hand import through the folder picker stays as now.

## Design

### 1 · Capability gate (PR1)
`FieldAssistCapability` (`ownVaults`, `auditedExport`, `orgConfiguration`, …) resolved from the
entitlement evidence in one pure function; `VaultImporter` and the UI ask for the capability, never
compare tiers. Migration is behaviour-preserving for licence holders. Tests: each evidence kind ×
capability table; every export path omits manuals and the re-import asks for them; subscriber can ingest; perpetual-unlock-only cannot; lapsed subscriber cannot
ingest but can remove and re-index-cleanup; team unchanged.

### 2 · Vault archive (a publisher's format, not an app feature)
A zip of the normal vault folder plus a small `vault-archive.json` header (format version, vault
id/name/version, file list with SHA-256, total bytes, publisher name). Pre-extracted manual text is
the point — the customer skips on-device text recognition; original PDFs optional. Built **off the
phone** by `Scripts/make-vault-archive` (new, beside `extract-manual-text.swift`), and **signed**
with a publisher key (Ed25519, reusing the pack signature message shape). Publisher public keys reach
the app through the vendor's signed catalog (a `publishers` list: id, display name, key, status) so a
publisher can be added or revoked without an app release; a revoked publisher's links are refused and
its installed vaults are flagged, not deleted. The app only reads the format: reuse the pack zip reader and its
zip-slip / size / entry-count limits.

### 3 · Add from link or QR (receive only)
Custom Vaults gets one entry point, "Add from link or QR": paste a URL, or scan a QR that encodes an
`https://` archive URL (or `openglasses://vault?src=<https url>` so a phone camera scan opens the
app). Flow: fetch header only (ranged/HEAD where possible) → **review sheet** (vault name, version,
publisher, source host in full, total size, manuals listed by title, and either "Signed by <publisher>" or the highlighted unverified-source
warning with its extra acknowledgement; a tampered or revoked-publisher archive stops here with the
reason and no install button) → confirm → download with progress and a hard byte cap → checksum
every entry → validate with `VaultValidator` → install through `installReporting` under
`VaultOperationLock`, marked `received` → index. HTTPS only, no redirect to another host without
re-showing the review, cellular-data warning above a threshold, failure leaves nothing
half-installed. The link is never stored in a shareable form, never shown as a QR, and not included
in exports, diagnostics or session records (a post-purchase URL may carry the buyer's token — treat
it as a secret: keep it out of logs, show only the host). Same id already installed → the existing
update path (explicit import is authoritative).

### 4 · Guardrails
Requires `ownVaults`. Prompt-rule and core-file budgets are the validator's existing ones. The
review sheet and the install are audit-logged when a field session is active. Registered with
`DataStoreRegistry` if any new store appears; network egress is user-initiated to a user-supplied
host, so the privacy manifest needs no new domain — state that in the PR. HIPAA/medical mode: link
import disabled unless the org profile allows it.

## Phases (one PR each)
- **PR1 — capability gate and subscriber vaults.** §1 plus copy, and the manuals-out export rule. ✅ Implemented 2026-09-22, headless: 16 new tests (the evidence × capability table, the exhaustiveness check, the gate states, the importer gate per evidence kind, and what an export writes), plus four pre-existing export assertions inverted to the new rule; full suite green. The `received` install source is **noted, not built** — `VaultImporter` records where it goes, beside the pack sidecar.
- **PR2 — receive a vault by link or QR.** §2–§4: signed archives, the unverified-source path, the
  publisher list in the catalog, and the archive script. The manuals-out-of-every-export rule ships in **PR1**, because it
  must be in place before subscribers can build vaults at all. Headless: archive round-trip, tamper/size/zip-slip
  refusals, URL policy table, review-model rendering, update-in-place, cancellation leaves no
  residue; a local HTTPS-less test server is not needed — inject the fetcher. Device check owed:
  scan a QR from a web page and install over cellular. A test asserts the app has no code path that
  renders a vault URL as a QR or hands an archive to the share sheet.

## Open questions
- Size ceiling for a link import (proposed 250 MB).
- Publisher onboarding: who may become a listed publisher, and what they attest to about their right
  to supply the manuals — a commercial/legal step outside the repository; the catalog entry is its record.
- One-time or expiring purchase links are the publisher's site feature; the guide should recommend them.
