# Plan HG — Add-on Catalogue and Premium Gating (shelves, signed entries, entitlement by pack)

**Status:** 📝 Drafted (not scheduled), 2026-10-02 — nothing built.
**Depends on:** Plan [GF](GF-recipe-add-ons.md) P0–P2 and its 2026-10-02 revision (the
`avenkin.addon/1` format, the runner, `AddOnStore`, the install sheet, and P1b's trust classes and
reserved capabilities); Plan [EG](EG-vault-packs.md) (pack ids, `VaultPackAccess`, the licence
`packs` claim — shipped).
**Extends:** GF P3 (the gallery index), which this plan absorbs and extends — see *Relation to
GF P3*.
**Related:** Plan [BX](BX-skill-packs.md) (the signed catalogue envelope), Plan
[CT](CT-org-configuration-profiles.md) (ceilings; entitlement rides the profile), Plan
[EI](EI-licence-issuance-portal.md) (partner issuance), Plan
[FX](FX-desktop-office-and-device-sync.md) (the Office channel for organisation add-ons), Plan
[HF](HF-office-stock-and-capture-contracts.md) (stock with Avenkin Office, which is not an add-on),
Plan [GO](GO-self-built-skills.md).

---

## Trigger

GF gives the format and a starter gallery. It leaves three things open: where add-ons are listed
and how a listing is trusted, whether community entries appear beside first-party ones (GF
decision 7), and how anything can be premium when every add-on's source is readable on the phone.

GF's revision answers the last one in principle: signed add-ons may hold reserved capabilities
that do not exist for unsigned files, and an edited copy loses its signature and with it those
capabilities. This plan turns that into a catalogue and an entitlement rule.

## Outcome

- One **signed catalogue index** for add-ons on the existing Pages site. Each listing shows what
  the add-on can do — its permission summary — **before** anything is downloaded.
- Three shelves: **starter** (first-party, free), **reviewed community** (free), **trade** (signed,
  gated). An organisation's private add-ons are not in the public index; Avenkin Office serves and
  signs those.
- Premium means **signed-only reserved capabilities**, not a hidden file. Premium is trade and
  organisation connectors. Consumer recipes stay free — the app itself is already paid — and
  accessibility add-ons are never gated.
- The **entitlement unit is the pack, not the add-on**. A trade pack is the vault plus its
  connectors under one purchase or one licence claim. There is no store product per add-on.
- A lapsed entitlement stops a gated add-on running and shows a locked row with an honest reason.
  It never deletes the add-on.

## What exists today (verified 2026-10-02)

- **No add-on code.** GF is drafted; there is no manifest, runner, store, sheet or catalogue for
  add-ons in `OpenGlasses/Sources`.
- **Two signed catalogues, one envelope written twice.** `Services/SkillPacks/SkillPackCatalog.swift`
  (`SkillPackCatalog.parse`, `Index { version, packs }`, private `Envelope { payload, signature }`,
  `CatalogError` `notAnEnvelope` / `badSignature` / `unreadableIndex` / `unsupportedVersion`,
  `supportedIndexVersion = 1`, `makeEnvelope`) and `Services/Vault/VaultPack.swift`
  (`VaultPackCatalog.parseIndex`, with the same private `Envelope`, the same four errors and the
  same verification body, plus a `publishers` list). They **share** the key and the pack-signature
  message: `VaultPackSignature.verify` delegates to `SkillPackSignature.verify`, and both
  catalogues default to `SkillPackSignature.productionPublicKeyBase64`. They **do not share** the
  envelope decode-and-verify code; it is duplicated.
- **Entries:** `SkillPackCatalogEntry` and `VaultPackCatalogEntry` (`id`, `vaultId`, `version`,
  `name`, `summary`, `author`, `minAppBuild`, `sizeBytes`, `downloadURL`, `sha256`,
  `packSignature`). Services: `SkillPackCatalogService`, `VaultPackCatalogService`
  (`loadCatalog`, `rowState(for:)`, `install`), `VaultPackRowState`.
- **Pack entitlement:** `VaultPackAccess.isUnlocked(productId:licensePack:purchasedProducts:licensedPacks:capabilities:)`
  — unlocked by `FieldAssistCapability.everyVaultPack`, by a verified store product, or by the
  licence's `packs` claim. `VaultPackManifest.productPrefix` is `com.openglasses.vault.`.
- **Two public keys.** `LicenseService.productionPublicKeyBase64` verifies licence codes (and, by
  default argument, organisation profiles and the Office inline entitlement).
  `SkillPackSignature.productionPublicKeyBase64` verifies skill packs, vault packs and both
  catalogues. They are different keys with different private halves.
- **Fetch:** `Services/Security/BoundedHTTPClient.swift` has a `signedCatalog` profile.
- **Publishing:** `Scripts/stage-pages-site.sh` allowlists `skillpacks/catalog.json`, the two
  skill-pack archives and `vaultpacks/catalog.json`; everything else under those folders is
  excluded. There is no `addons/` entry.
- **Organisation references:** `ConfigProfile` carries `vaultPack` and `skillPacks: [String]?` by
  id ("a profile never embeds one"); `OrgPackInstaller` installs at enrolment. `SettingKey` has no
  add-on key.

## Design

### One verifier, three catalogues

P0 factors the duplicated envelope code into `SignedCatalogEnvelope`: decode `{payload,
signature}`, verify the signature over the exact payload bytes with a supplied key, return the
payload bytes, with one `CatalogError`. `SkillPackCatalog.parse` and `VaultPackCatalog.parseIndex`
become thin callers that decode their own `Index` from those bytes; their public signatures, error
cases and the committed, pinned catalogues do not change. The add-on catalogue is the third caller
rather than a third copy.

**Which key.** The add-on catalogue and vendor-signed add-ons verify against
`SkillPackSignature.productionPublicKeyBase64`: it is the content-signing key, it already signs
both existing catalogues, and reusing it keeps "what the vendor published" under one key. The
licence key (`LicenseService.productionPublicKeyBase64`) is **not** used for content; it answers
only "what is this device entitled to", which is where `requiresPack` is resolved. Keeping the two
apart means a leaked content key cannot mint an entitlement and a leaked licence key cannot publish
an add-on. Tests name the type the key comes from, never a bare constant.

### The index (`addons/catalog.json`)

Signed envelope; payload `{ "version": 1, "addOns": [ … ] }`. Each entry:

| Field | Meaning |
|---|---|
| `id`, `version`, `name`, `summary` | As in the add-on file; `id` + `version` must match the downloaded file exactly |
| `author` | Name and web domain, shown as the domain |
| `category` | Closed list (for example everyday, travel, outdoors, reference, trade, accessibility) |
| `shelf` | `starter`, `community` or `trade` |
| `sha256`, `downloadURL` | Checksum of the exact file bytes; https only |
| `signature` | Signature over the exact file bytes; required for `starter` and `trade`, absent for `community` |
| `permissions` | The **permission summary**: the add-on's `permissions` block and reserved capabilities, verbatim, so the listing can render GF's plain-words lines before download |
| `requiresPack` | Optional pack id; present only on `trade` entries |
| `minAppBuild`, `coverage` | Optional, as in the file |
| `accessibility` | Optional flag; an entry carrying it may not carry `requiresPack` (refused at parse) |

**The summary is a promise the file must keep.** After download the phone recomputes the
summary from the file (`AddOnPermissionSummary`, GF P0). If the file asks for anything the index
did not list — one more host, one more capability — the install is refused as a catalogue
mismatch. The install sheet still shows the file's own permissions; the index only decides what
is shown before download.

### Three shelves

| Shelf | Who | Signed | Reserved capabilities | Gated |
|---|---|---|---|---|
| Starter | first-party | yes (vendor) | none needed | never |
| Reviewed community | anyone, reviewed by the vendor | no | none (they do not exist for unsigned files) | never |
| Trade | vendor, later partners | yes (vendor) | may hold them | by `requiresPack` |

A community entry is listed because the vendor read it and pinned its checksum in the signed
index; that is what "Reviewed" means on its row. The file itself stays unsigned, so it installs
through GF's normal sheet and is editable; editing it drops the badge, as GF already says. This
settles GF decision 7: reviewed community entries are listed, on their own shelf.

**Organisation-private add-ons are not here.** They are referenced by the organisation profile or
delivered and signed through Avenkin Office (GF revision), and they never appear in the public
index. The last phase gives the phone an "From your organisation" shelf fed by that channel.

### Premium is the capability, not the file

A trade add-on's source is as readable as any other. What a buyer gets is an add-on that is
allowed to do things an unsigned file cannot be granted at all: hold an organisation's supplier
key in the Keychain, read the vault's parts index, write to the job's work record. Copy the file
and edit it and the signature no longer verifies; it is then a community file naming capabilities
that do not exist for it, and GF's validator refuses it.

What is premium, and what is not:

- **Premium:** trade and organisation connectors — for example a supplier stock or pricing API
  called with the firm's own key, or a connector to the accounting system a firm already runs.
- **Free:** every consumer recipe (currency, tides, air quality and the like). The app is already
  paid.
- **Never gated:** anything in the accessibility category, at any shelf.

Connectors are an option, not the only door. Rough-input intake in Avenkin Office (Plan HF's
capture path and Office's own inbox) covers the long tail of firms whose stock lives in a
notebook or a spreadsheet. A connector is for a firm that already runs an accounting or supplier
system and wants it wired in.

### Entitlement by pack

`requiresPack: "<pack id>"` is the whole mechanism. `AddOnAccess.isUnlocked(entry:)` asks the
existing resolution — `VaultPackAccess.isUnlocked` with the verified store products, the licence's
`packs` claim and the held capabilities — and adds no logic of its own. So:

- a trade pack is a vault **and** its connectors under one purchase or one licence claim;
- an enterprise licence, which unlocks every pack, unlocks every pack's connectors;
- there is no store product per add-on, and nothing new to restore;
- consumer unlocks go through StoreKit and organisation unlocks through the licence-code path,
  exactly as Field Assist does today. A profile that references a gated add-on installs it, and it
  stays locked unless the code inside the profile lists the pack (CT's rule: a profile may never
  widen entitlement beyond its code).

Access is resolved **at run time, on every call**, from live evidence — never from a stored
"unlocked" flag. When it lapses:

- the add-on's skills are no longer declared to the model;
- its row stays in Settings → Add-ons, locked, with the reason in plain words ("Needs the ⟨pack
  name⟩ pack. Your licence for it ended on ⟨date⟩.");
- its file, settings and stored credentials are kept, so renewal restores it as it was;
- a locked organisation add-on names the organisation as the party to ask.

`requiresPack` naming a pack the catalogue of vault packs does not list is a parse-time refusal
of that entry, not a silent free add-on.

### Partner publishing

Vendor-signed only until Plan EI's issuance service exists. A partner's trade add-ons are reviewed
and signed by the vendor and attributed to the partner in `author`. No partner holds a content
key, and no self-publishing path is added here.

### Relation to GF P3

GF P3 drafted "a signed gallery index on the existing Pages site" plus the starter set and
authoring guide. HG takes over the **index**: its schema is the one above (GF's draft had no
permission summary, shelf or `requiresPack`), and it is built on the shared verifier. GF P3 keeps
the **content**: the first-party starter add-ons under `addons/src/`, their drift-pinning tests,
`docs/addon-authoring.md`, and the gallery screen for free entries. In delivery order, HG P0 lands
before GF P3 so the gallery is built once, on the final index.

### Organisation policy

GF's three CT ceilings apply to the catalogue as they apply to installs: with add-ons disabled
the gallery is absent; with "no community add-ons" the community shelf is absent; with
"organisation-signed only" the public catalogue is not fetched at all.

## Order

GF P0–P1 → GF P1b → GF P2 → **HG P0** → GF P3 with **HG P1** (the free gallery) → **HG P2**
(signed-only capabilities in the catalogue) → **HG P3** (pack gating) → **HG P4** (Office-served
organisation catalogue).

## Phases (one PR each)

**P0 — Shared verifier and index schema (pure).** `SignedCatalogEnvelope` with the two existing
catalogues moved onto it; `AddOnCatalog` (`Index`, `AddOnCatalogEntry`, strict decode, closed
`category` and `shelf` lists, the accessibility-never-gated rule), `AddOnCatalogSummaryCheck`
(index summary against the file's recomputed summary), `Scripts/` signing support for a third
index, an empty signed `addons/catalog.json` committed and allowlisted in
`Scripts/stage-pages-site.sh`. Tests: `SignedCatalogEnvelopeTests` (bad envelope, bad signature,
wrong key — including the licence key being refused), `SkillPackCatalogTests` and
`VaultPackTests` unchanged and green, `AddOnCatalogTests` (unknown shelf, accessibility
with `requiresPack`, trade without a signature, community with one), `AddOnCatalogSummaryCheckTests`
(an extra host or capability in the file is a mismatch), `AddOnCatalogPinningTests` (the committed
index verifies against the embedded key).

**P1 — Free gallery (starter and community shelves).** `AddOnCatalogService` (fetch through
`BoundedHTTPClient`'s `signedCatalog` profile, verify, download → checksum → summary check →
GF's validator and install sheet), `AddOnRowState` (Install / Update / Installed / Not available
on this build), the gallery screen with permission lines on each row, the "Reviewed" badge, CT
ceilings applied. Delivered alongside GF P3's starter content. Tests: `AddOnCatalogServiceTests`
(injected transport: checksum mismatch, summary mismatch, `minAppBuild`), `AddOnRowStateTests`,
`AddOnCatalogPolicyTests` (each ceiling hides the right shelf).
*Owed (device):* browse and install on cellular; VoiceOver over a row's permission lines; the
update row.

**P2 — Signed entries and reserved capabilities in the catalogue.** Trade shelf listed (still
ungated), signature verified over the exact file bytes at install, reserved capabilities shown in
the listing and on the sheet in plain words, the credential-entry step for an add-on holding
`credentials` (typed at install, Keychain, never exported). Tests: `AddOnCatalogSignedInstallTests`
(an altered byte refuses; a signed entry served unsigned refuses), `AddOnReservedSummaryTests`,
`AddOnCredentialStoreTests` (absent from export, source view and diagnostics).
*Owed (device):* one signed connector installed and run against a real supplier test endpoint.

**P3 — Pack gating.** `AddOnAccess` over `VaultPackAccess`, `requiresPack` resolution against the
vault-pack catalogue, the locked row and its reasons, registry rebuild when evidence changes,
Buy / Included states that hand off to the existing pack purchase and licence paths. Tests:
`AddOnAccessTests` (store product, licence `packs` claim, enterprise, none; one row per
`VaultPackAccess` branch), `AddOnLapseTests` (lapse hides the skills, keeps the file and
credentials, restores on renewal), `AddOnLockedReasonTests`, `AddOnCatalogTests` extended (unknown
pack id refused).
*Owed (device):* a sandbox pack purchase unlocking its connector; a licence code with and without
the pack; expiry of a test licence.

**P4 — Organisation catalogue from Avenkin Office.** The phone-side shelf for organisation
add-ons delivered over FX's signed-assignment channel (GF P1b's reference shape): listing,
install at enrolment, read-only source, removal with the profile. The contract for the assignment
is added to `Contracts/` in the same PR; what Office does to author and sign is the private
repository's. Blocked on FX's next milestone, as Plan HF is. Tests:
`OfficeAddOnAssignmentTests` (the usual contract negatives), `AddOnOrganisationShelfTests`.
*Owed (device and Office):* one organisation add-on assigned, installed without a sheet, run,
then removed by removing the profile.

## Risks

- **Upstream API terms.** A paid add-on cannot wrap a free-tier, non-commercial API. Every trade
  entry needs a commercial-terms check recorded with the entry before it is signed, and a
  connector that uses an organisation-held key needs that organisation's own agreement with the
  supplier, not ours. Starter entries keep GF's terms check.
- **App Review.** Guideline 2.5.2: add-ons are interpreted data with a bounded engine, no
  downloaded code, a curated signed index and an explicit install. In-app purchase rules: anything
  a consumer buys in the app goes through StoreKit as a pack; licence codes unlock organisation
  purchases as Field Assist already does, and the app does not steer a consumer to buy outside it.
  A gated add-on must do something real once unlocked and must say plainly why it is locked.
- **Catalogue key handling.** One content key now signs three indexes and every vendor-signed
  add-on, so its loss costs more. It stays off-repo in a 0600 file, is never printed (the lesson
  of the earlier rotation recorded in `SkillPackSignature`), and a rotation re-signs all three
  indexes and every signed file in one release. A pinning test per index catches a missed one.
- **Two keys, easily confused.** `LicenseService.productionPublicKeyBase64` and
  `SkillPackSignature.productionPublicKeyBase64` share a name. Verifying content against the
  licence key would fail closed, but a test written against the wrong one proves nothing. P0's
  wrong-key test exists for that.
- **The index summary drifting from the file.** Handled as a refusal, not a warning.
- **A locked row that looks broken.** The reason line and the kept credentials are what stop a
  lapsed renewal reading as data loss.
- **Review load.** A reviewed community shelf is a commitment to read submissions. It starts
  small, and an entry that changes its permissions is a new review.

## Decisions for Greig

1. Category list: is the closed set above right, and does "accessibility" as a category (never
   gated) suffice, or should the flag be separate so an accessibility add-on can also sit under
   another category? *Recommend the separate flag, as tabled.*
2. Should the starter shelf's files be signed (so they may later hold reserved capabilities) or
   left unsigned like community files? *Recommend signed.*
3. Community submissions: by pull request to the public repository's `addons/` folder, or by
   email to the vendor? *Recommend pull request; the review is then visible.*
4. Does a trade add-on appear in the public index when the viewer holds no pack, as a locked row,
   or only to holders? *Recommend visible and locked: the listing is the honest advertisement.*
5. Product-id prefix for trade packs: keep `com.openglasses.vault.` (existing identifiers stay
   until the rename is reviewed) — confirm.
6. Is a trade connector with no vault a valid pack, or must every pack carry a vault? *Recommend
   every pack carries a vault for now; it keeps `VaultPackAccess` the only resolver.*

UI copy never names plan letters; the user-facing word is "add-on", and a locked row names the
pack, not a tier.

## Out of scope

A store product per add-on; subscriptions for individual add-ons; ratings, reviews or a
marketplace; partner self-publishing and any partner-held signing key (until Plan EI); gating any
consumer recipe or any accessibility add-on; add-ons that reach private or LAN addresses or call
Avenkin Office over HTTP (Plan HF covers Office); Office's authoring, signing and licensing UI
(private repository); and any change to how packs are bought or licensed today.
