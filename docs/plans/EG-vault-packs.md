# Plan EG — Vault Packs (authored vaults as sellable, signed, downloadable content)

**Status:** 🚧 P1 + P2 implemented 2026-09-03 (headless suite green; the signed
`vaultpacks/catalog.json` is minted by the vendor with the off-repo key, App Store Connect products
per pack, and P3's first packs pending). What landed: `VaultPackManifest` (`pack.json`), archive
extraction over the existing zip reader, signature verify/sign reusing the skill-pack message and
key, `VaultPackCatalog` with the BX envelope, the `VaultPackAccess` table, `VaultPackRowState`;
licence payload `packs` claim carried on the evidence and unioned by `livePacks` (a lapsed code
contributes nothing), `--pack` on the generator; `VaultRegistry.isUnlocked` resolves a pack id via
purchase / licence / enterprise; StoreKit records pack purchases apart from feature evidence and
loads pack products from the catalog's ids; `VaultPackCatalogService` runs download → checksum →
signature → structural checks (vault id, gating, no documents, min build) → the existing importer,
records `pack.json` beside the baseline so updates preserve technician edits; a Packs section in
Custom Vaults with Buy / Install / Update / Installed states; paid packs never export; session audit
lines name the pack and author; `Scripts/vaultpack-sign.swift` and `vaultpacks/README.md` +
`index.json` for the vendor to sign. **Resolved from the draft's open questions:** pre-extracted
manual text may ship in a pack only with the manufacturer's written permission, recorded in
`redistributionNote` (Plan EF's Mac extractor produces the text); packs are one-time purchases;
two indexes, one key.
**Origin:** The question "when a partner's vault becomes a standard one, who gets it?" The answer
decided with it: the two bundled vaults stay inside the solo purchase; a partner-authored vertical
is sold on its own, so its author can be paid for it. That needs a pack format, a way to deliver
one without an app update, and entitlement that can name a pack.
**Priority:** P2 — after the first pilot proves the workflow, before the first co-authored vertical
is finished.
**Surfaces:** Custom Vaults screen (browse and install), Field Assist paywall (per-pack purchase),
licence codes (packs included with a team licence).

---

## Product promise

"Buy the HVAC pack and the assistant knows that trade the moment it installs. Your organisation's
licence can include it for everyone. Bring your own manuals as before."

## What a pack is, and is not

A pack is a vault the vendor or a partner authored: the core markdown (fault-code tables, nameplate
references, safety rules) and the procedures. **It never contains OEM manuals.** Those are the
manufacturers' copyright; a customer loads their own into the pack's `documents` tier on their
own phone, exactly as Plan ED shipped. The pack's citations point at manual pages the customer
will have; the pack does not ship the pages.

Three kinds of vault now exist, and the tier model from Plan EE places them:

| Kind | Example | Who gets it |
|---|---|---|
| Bundled | refrigeration, IT | Every Field Assist tier, including solo |
| Pack | a co-authored HVAC vertical | Solo buyers per pack; team licences that list it; enterprise |
| Custom | an organisation's own folder | Team and enterprise only |

## Verified starting point

- **Per-pack gating strings already exist and are unused.** `VaultRegistry.isUnlocked` switches on
  `manifest.gating.iap`; the bundled vaults carry `field_assist_refrigeration` and
  `field_assist_it`, and both resolve to the one Field Assist decision today. That is the hook
  Plan F designed for per-pack products.
- **Signed downloadable content is shipped and tested.** Plan BX's skill packs are a zip plus a
  manifest, signed over the manifest bytes and a sorted digest of every payload file
  (`SkillPackSignature.signingMessage`), listed in a signed catalog envelope the app fetches from
  GitHub Pages and verifies against an embedded public key, with `Scripts/skillpack-sign.swift` for
  keygen / sign-pack / sign-catalog and a test that pins the committed catalog to the embedded
  key. Unsigned packs are admitted only under Developer Mode.
- **Import, validation, baseline and overlay are shipped.** `VaultImporter.install(from:)` takes a
  folder, validates it, lays it down as a read-only baseline, and merges a technician's edits over
  it; a re-push updates the baseline without losing edits. A downloaded pack unzips into exactly
  that folder shape.
- **Entitlement is tiered and evidence-based.** Plan EE's `FieldAssistTier` sits on every piece of
  evidence, licence payloads are versioned and backwards-compatible, and StoreKit evidence is a
  list of products.
- **Bundled vaults live in the app binary.** Updating one means an app release. That is fine for
  two vaults the vendor maintains; it does not scale to partner content on a partner's cadence.

## Design

### Pack format

A vault folder, zipped, plus a `pack.json` beside `manifest.json`:

```json
{
  "id": "com.openglasses.vault.hvac_rtu",
  "vaultId": "hvac_rtu",
  "version": "1.2.0",
  "name": "HVAC Rooftop Units",
  "summary": "Fault codes, nameplate decoding, and diagnostics for packaged rooftop units.",
  "author": "Partner name, as it should appear in Settings",
  "minAppBuild": 364,
  "entitlement": { "product": "com.openglasses.vault.hvac_rtu", "licensePack": "hvac_rtu" }
}
```

The vault manifest inside keeps `gating.iap` equal to the pack id so the registry's existing
switch has one string to resolve. Signing reuses `SkillPackSignature.signingMessage` verbatim over
`manifest.json` + `pack.json` + every file; the catalog reuses the BX envelope with a second index
at `vaultpacks/catalog.json`. One private key, already off-repo, signs both catalogs.

### Entitlement resolution

`VaultRegistry.isUnlocked` gains a table instead of a switch:

| `gating.iap` | Unlocked when |
|---|---|
| `nil` | always |
| `medical_compliance` | Medical Compliance active (unchanged) |
| `field_assist_refrigeration`, `field_assist_it` | any Field Assist tier (unchanged) |
| `enterprise` | tier ≥ team (unchanged, Plan EE) |
| a pack id | a verified store product with that id, **or** the licence payload's `packs` list contains the pack's `licensePack`, **or** tier is enterprise |

The licence payload gains `packs: [String]?` (backwards-compatible, like Plan EE's fields); the
generator gains `--pack hvac_rtu` (repeatable). Store evidence already carries a list of products,
so a pack purchase is one more `.verifiedStoreProduct` in the recorder with the pack's product id.
The evaluator is untouched: pack access is a per-vault question answered by the registry, not a
tier.

### Delivery

- **Catalog browse** in the Custom Vaults screen: a "Packs" section listing the signed index with
  name, author, version, summary, and a state — Buy (solo, not owned), Included (licence lists it
  or enterprise), Install, Update, Installed.
- **Install** downloads the zip, verifies SHA-256 and the pack signature, unzips to a staging
  folder, and calls the existing `VaultImporter.install(from:)`. The pack's `documents` tier is
  empty on arrival; the customer adds manuals through the existing folder import into the same
  vault id, which the importer already treats as a baseline re-push that preserves the overlay.
- **Update** is the catalog's version being newer than the installed pack's: the same path, with
  technician edits preserved because they live in the overlay. Never mid-session — the check runs
  on session start, per Plan F's rule.
- **Purchase** is a StoreKit non-consumable per pack, bought from the pack row or the paywall's
  new Packs section, recorded like any other Field Assist store product.

### Attribution and the partner

`author` renders in Settings and in the session audit log's vault line, so an exported record
says whose knowledge it drew on. Revenue share is an App Store Connect and contract matter, not
code; the plan's contribution is that a pack has a product id, so it can have a price.

## Build order

**P1 — pure core (one PR).**
- `VaultPack` manifest, signature verification over the vault folder (reusing BX's message),
  catalog index decoding with the BX envelope.
- Registry resolution table; licence payload `packs`; generator flag; tests over injected
  evidence for every row of the table.
- Store product ids per pack in `StoreKitService` derived from the catalog (not a hard-coded set).

**P2 — delivery (second PR).**
- `VaultPackCatalog` fetch + verify (mirroring `SkillPackCatalog`), download + unzip + install via
  the importer, update detection at session start.
- Custom Vaults "Packs" section and paywall Packs section; purchase and restore.
- `vaultpacks/catalog.json` signed and committed empty, with the pinning test, like BX.

**P3 — first pack.**
- The bundled refrigeration vault re-published as a pack too (still bundled and still solo), to
  prove the path with content the vendor owns before a partner's content rides it.
- The first co-authored vertical: authored in the partner's folder, signed by the vendor, listed.

## Tests

- Signature: a valid pack verifies; one altered file, one added file, one altered `pack.json`
  each fail; an unsigned pack installs only under Developer Mode.
- Resolution table, one test per row, with solo / team / enterprise evidence and with the pack id
  present and absent in store evidence and in the licence `packs` claim.
- A team code listing `hvac_rtu` unlocks that pack and not another; an enterprise code unlocks
  every pack; a solo purchase of one pack unlocks only it.
- Install through the importer produces the same baseline as a folder import of the unzipped
  pack; a customer's manuals added afterwards survive a pack update; overlay edits survive too.
- Catalog: newer index version refused; version comparison drives the Update state; a pack whose
  `minAppBuild` exceeds this build is shown but not installable, with the reason.
- Audit log line carries the pack author.

## Non-goals

- Shipping OEM manuals in a pack. Ever.
- A marketplace, ratings, or third-party self-publishing. The vendor signs every pack.
- Runtime code in packs. A vault pack is data, like a skill pack.
- Changing what the solo tier includes. Refrigeration and IT stay in.

## Open questions

- Whether a pack may ship pre-extracted OCR text for manuals the *author* is licensed to
  redistribute (a manufacturer partner publishing its own pack). The format allows it; the policy
  is the manufacturer's written permission, recorded in `pack.json`.
- Whether pack purchases should also be available as a monthly subscription for solo buyers, or
  stay one-time. Leaning one-time: a pack is a book.
- Whether the catalog should live beside the skill-pack catalog or in one combined index. Two
  indexes, one key, is simpler to reason about and to test.
