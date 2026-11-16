# Company vaults and manuals — contract v1, with the v2 published-vault fields and v3 shared manuals

The licence service publishes, for one company, the vaults it has and the manuals in them; every
phone enrolled in that company installs them and picks up each new version by itself. This is the
contract the phone reads. The reference implementation is
`Tools/LicenceIssuance/Sources/LicenceIssuance/CompanyVaults.swift` (`CompanyVaultContract`), the
phone restates it (`CompanyVaultCatalog`, `CompanyManualSeal`), and both sides' tests read the
golden fixtures in `fixtures/company-vaults-v1/`, for the published-vault fields of §6 (Plan LV)
`fixtures/company-vaults-v2/`, and for the shared manuals of §8 (Plan LV P3) `fixtures/company-vaults-v3/`. Invented content only; the fixture keys are
SHA-256 of the public labels in `fixture-keys.json` and have no authority anywhere.

## 1. The profile's pointer

The signed organisation profile gains one optional field (`ProfileContract.CompanyVaults`):

```json
"companyVaults": { "catalog": "https://…/c/<opaque>/vaults.json", "generation": 7, "minAppBuild": 680 }
```

- `catalog`: HTTPS, a host, no credentials, no fragment. `ProfileContract.checkCompanyVaults`.
- `generation`: 1 or more; raised with **every** change to the company's vaults or manuals.
- `minAppBuild`: optional; the oldest build that can read the catalog. Older builds ignore the field.
- Absent on every profile without company vaults; encoded with the profile's usual encoder, a
  profile without it is the bytes it always was. Never write the old `vaultPack` field for a
  company vault.

The phone reads the catalog at launch, on every foreground, right after enrolment and on *Check for
Updates*, whatever the generation, so an upload reaches it the next time the app comes forward rather than
at its daily profile renewal. A catalog newer than the pointer is used (the rules below). When a read fails
and the pointer names nothing newer than the catalog it has verified, it carries on with that one; a job
closing and *Download now* work from the verified catalog unless the pointer has moved past it.

## 2. The catalog

An envelope `{"payload": base64, "signature": base64}`, at most 1 MiB, served as
`application/json`. The signature is Ed25519 by the **vendor's pack-catalog key** (the key that
signs the public vault-pack catalog and every pack) over the UTF-8 bytes
`openglasses.company-vault-catalog.v1\n` followed by the exact payload bytes. The public pack
catalog is signed over its payload with no prefix, so neither document verifies as the other.

Payload (`CompanyVaultContract.Catalog`; encode with `CompanyVaultContract.encoder()`: sorted keys,
ISO 8601 dates, unescaped slashes):

| Field | Meaning |
|---|---|
| `format`, `version` | `openglasses.company-vault-catalog`, `1` |
| `profileId` | The company's profile id. A catalog for another profile is refused. |
| `generation` | Equal to the pointer's. Lower than the pointer's: refused as not caught up. Lower than any the phone verified: refused as a replay. |
| `issued` | ISO 8601 |
| `manualsOnAnyNetwork` | The company's *Manuals on any network* setting. False: manuals wait for Wi-Fi unless the technician taps *Download now*. |
| `vaults` | Rows below |
| `manuals` | Rows below |

A **vault** row is an EG vault pack row (`VaultPackCatalogEntry`) with `sizeBytes` required:
`id` (`com.openglasses.vault.<…>`), `vaultId`, `version`, `name`, `summary?`, `author?`,
`minAppBuild?`, `sizeBytes` (the archive), `downloadURL` (HTTPS), `sha256` (lowercase hex of the
archive), `packSignature` (`VaultPackSignature`: Ed25519 by the pack-catalog key over `pack.json`
then `\nsha256(<path>)=<hex>` for every other file, sorted by path). The pack is the EG format in
every byte: `pack.json`, `manifest.json` with `gating.iap` equal to the pack id, core files, **no
documents and no sites**, and it must pass the phone's vault validator (`VaultValidator`): among
other things its `prompt_rules` must address fabrication and source citation (rules containing
"fabricate" and "cite"), or the install is refused with the validator's words. Serve it as `application/zip` or `application/octet-stream`.

A **manual** row: `vaultId` (a vault in the same catalog), `fileName` (its identity in the vault;
the citation title is the name without its extension), `revision` (lowercase hex SHA-256 of the
plaintext), `sizeBytes` (plaintext), `sealedSha256` (lowercase hex SHA-256 of the sealed file as
served), `downloadURL` (HTTPS, served as `application/octet-stream`), `kind` (`pdf`, `docx`, `md`;
the extension must agree). One row per file: adding or changing a manual moves only that file.

`CompanyVaultContract.sign(_:signer:)` checks the catalog (`check`) and returns the envelope;
`open(_:publicKeyBase64:profileId:highWater:profileGeneration:)` is the phone's verification.

## 3. The sealed manual

`CompanyVaultContract.ManualSeal` — AES-256-GCM in 1 MiB chunks:

```
key     = HKDF-SHA256(ikm: company secret, salt: none, info: "openglasses.company-manual.v1"), 32 bytes
sealed  = header ‖ chunk₀ ‖ … ‖ chunkₙ₋₁
header  = "OGCM" ‖ 0x01 ‖ 0x00100000            (chunk size, UInt32 big-endian)
chunkᵢ  = nonce (12 random bytes) ‖ ciphertext ‖ tag (16)
AADᵢ    = "openglasses.company-manual.v1\n" + profileId + "\n" + vaultId + "\n" + fileName + "\n" + revision + "\n"
          ‖ header ‖ i (UInt64 big-endian) ‖ (0x01 last chunk, else 0x00)
```

Every chunk but the last holds exactly 1 MiB of plaintext; a file of n bytes seals to
`sealedLength(plaintextBytes: n)` = 9 + n + 28·⌈n / 1 MiB⌉ bytes, and the phone refuses any other
length. The company secret is the 32 bytes the version 2 activation file carries
(`ProfileContract.Credential`); it never travels anywhere else. Use
`ManualSeal.sealFile(at:to:profileId:vaultId:fileName:companySecret:)` for uploads: it streams one
chunk at a time and returns the row's `revision`, `sizeBytes` and `sealedSha256`.

The phone downloads into protected staging, checks the length and `sealedSha256`, opens each
chunk, checks the plaintext against `revision`, and only then lays the manual into its vault.

## 4. Limits

`CompanyVaultContract.Limits` (decision 2), refused by the service before anything is stored and
checked again by the phone: a PDF ≤ 128 MiB; a Word manual ≤ 100 MiB; Markdown ≤ 20 MiB; a vault's
pack ≤ 250 MiB with each file ≤ 20 MiB (`checkPackFiles`); everything one company stores ≤ 1 GiB
to start (`check(_:companyTotalBytes:)` takes the company's own); at most 64 vaults and 2,000
manuals per catalog.

## 5. The seat renewal (P2)

A renewal (`SeatRenewRequest`) may carry `vaults: [{vaultId, version}]` — the company vaults
installed on the phone, at most 16, and only when the request still fits in
`SeatWire.maximumRequestBytes`. Absent when the phone has none, so the bytes are what they were.
`SeatPolicy.renew(…, vaults:)` keeps them on the seat (`SeatRecord.vaults`) and
`SeatPolicy.fleetVersions` counts held seats by version for the portal. It is disclosed in the
privacy manifest and the in-app copy.

## 6. Published vaults and company layers (Plan LV, additive)

A vault row may carry five more fields. Each is optional and absent from the JSON when unset, so a
row without them is the bytes of a v1 row and behaves exactly as one; the catalog stays
`version: 1`. The service raises the row's (or the pointer's) `minAppBuild` to the first build that
reads them, so an older build never receives a row it cannot open.

```json
{
  "id": "com.openglasses.vault.fixture-split-systems", "vaultId": "fixture-split-systems", "version": "7", "…": "…",
  "publisher": { "id": "p-fixture", "name": "Fixture Publishing", "version": 5 },
  "sealedCore": true,
  "expects": [ { "key": "install-manual", "title": "Installation manual", "edition": "Rev C",
                 "revision": "<sha256 of the plaintext>" } ],
  "frozen": false
}
```

| Field | Meaning |
|---|---|
| `publisher` | `{id, name, version}`: the partner whose vault this is. `id` a safe identifier, `name` 1–200 printable characters, `version` (the partner's own number, the one people talk about) 1 or more. `version` on the row stays the per-company number the phone compares. |
| `sealedCore` | True: the archive is the pack sealed for this company (§7). `sizeBytes` and `sha256` are the **sealed** file's; `packSignature` is over the plaintext pack, checked after opening. Absent or false: a plain pack. Any company vault row may be sealed, published or not. |
| `expects` | The manuals the vault was written against: `{key, title, edition?, revision?}`, at most 500. `key` a safe identifier, unique in the row (the key the vault's index rows cite); `title` 1–200 printable characters; `edition` 1–80 if present; `revision` lowercase hex SHA-256 of the plaintext if known. |
| `frozen` | True: the publisher has ended. The phone keeps the version it has, compares no versions for the row and never updates it; it still installs it on a phone that has none, and the company removes it in the portal when it wants to. |
| `extends` | A **company layer**: the `vaultId` of another row in the same catalog that this one adds files and prompt rules to. It must name a row that is present and is not itself a layer, never itself, and a layer never carries `publisher`. |

`CompanyVaultContract.check` refuses a catalog that breaks any of these (`publishingProblem(with:)`
for one row; the `extends` rules across rows); the phone leaves out a row that breaks them and names
it on that vault's row.

**The company layer is add-only** (decision 4). Its pack is an EG pack whose `files` must not name a
file the vault it extends already lists (compared case-insensitively, after any leading `./`), and
which carries no documents and no site documents: `VaultPackRules.layerIssues(_:baseFiles:)`, the
same code on both sides. The phone reads publisher baseline → company layer → technician overlay, the
overlay winning; a layer that would replace a publisher file is refused, never applied.

## 7. The sealed core (Plan LV)

`CompanyVaultContract.CoreSeal`: the construction of §3 in every byte (both seals are one
`ChunkedSeal`, parameterised by domain and magic), under its own domain and magic:

```
key     = HKDF-SHA256(ikm: company secret, salt: none, info: "openglasses.company-core.v1"), 32 bytes
header  = "OGCP" ‖ 0x01 ‖ 0x00100000
AADᵢ    = "openglasses.company-core.v1\n" + profileId + "\n" + vaultId + "\n" + packId + "\n" + version + "\n"
          ‖ header ‖ i (UInt64 big-endian) ‖ (0x01 last chunk, else 0x00)
```

`packId` and `version` are the row's `id` and `version`, so a sealed core cannot be moved to another
company, vault, pack or version. A pack of n bytes seals to `sealedLength(plaintextBytes: n)`. Use
`CoreSeal.sealFile(at:to:context:companySecret:)` for uploads: it returns the row's `sizeBytes` and
`sha256` (the sealed file's) and the plaintext pack's digest. The phone (`CompanyCoreSeal`) checks the
sealed length and `sha256`, opens each chunk, and hands the plaintext pack to the installer, which
checks `packSignature` as for any pack.

## 8. Shared manuals (Plan LV P3)

A partner who may distribute a manual uploads it once. The service encrypts it **once**, under a
random 32-byte content key, and gives each company that receives it only that key, wrapped with a key
derived from the company's secret. The reference is
`Tools/LicenceIssuance/Sources/LicenceIssuance/SharedManuals.swift`; the phone restates it
(`CompanySharedManualSeal`, `CompanySharedManualKey`).

**The row.** A manual row may carry one more optional field, absent from the JSON when unset, so a
company-sealed row is the bytes it always was:

```json
{ "vaultId": "fixture-split-systems", "fileName": "Installation manual.md", "kind": "md",
  "revision": "<sha256 of the plaintext>", "sizeBytes": 186, "sealedSha256": "<sha256 of the shared file>",
  "downloadURL": "https://…/s/c-fixture-installation-manual/1",
  "shared": { "contentId": "c-fixture-installation-manual", "keyId": 1, "wrappedKey": "<80 characters of base64>" } }
```

| Field | Meaning |
|---|---|
| `shared.contentId` | The shared file's id, a safe identifier, the same for every company. |
| `shared.keyId` | The content key's number, 1 or more. A rotation raises it. |
| `shared.wrappedKey` | The content key wrapped for this company: standard base64 of exactly 60 bytes. |

With `shared`, `downloadURL` and `sealedSha256` describe the one shared file, which is the same for
every company; `sizeBytes` is the plaintext's length and `revision` its SHA-256, exactly as for a
company-sealed manual, so the phone's length check (`sealedLength(plaintextBytes: sizeBytes)`), the
limits, the space and Wi-Fi rules and the revision comparison are unchanged.

**The file** (`CompanyVaultContract.SharedManualSeal`): the construction of §3 in every byte (the
same `ChunkedSeal`), keyed from the content key, under its own domain and magic:

```
key     = HKDF-SHA256(ikm: content key, salt: none, info: "openglasses.shared-manual.v1"), 32 bytes
header  = "OGSM" ‖ 0x01 ‖ 0x00100000
AADᵢ    = "openglasses.shared-manual.v1\n" + contentId + "\n" + keyId + "\n"
          ‖ header ‖ i (UInt64 big-endian) ‖ (0x01 last chunk, else 0x00)
```

`keyId` is written in decimal. The context names no company, because the file is every company's.
Use `SharedManualSeal.newContentKey()` for a new file or a rotation and
`SharedManualSeal.sealFile(at:to:context:contentKey:)` to seal it; it returns the rows' `revision`,
`sizeBytes` and `sealedSha256`.

**The key, per company** (`CompanyVaultContract.SharedManualKey`):

```
context = "openglasses.shared-manual-key.v1\n" + profileId + "\n" + contentId + "\n" + keyId + "\n"
KEK     = HKDF-SHA256(ikm: company secret, salt: none, info: context), 32 bytes
wrapped = base64( nonce (12 random bytes) ‖ AES-256-GCM(KEK, content key, AAD: context) ‖ tag (16) )
```

`SharedManualKey.wrap(_:context:companySecret:)` writes it; `unwrap` refuses a key wrapped for another
company's secret, another profile, another file or another `keyId` (`unreadable`; the phone says
`tampered`).

**Rules** (`CompanyVaultContract.check`, again on the phone): `contentId` a safe identifier, `keyId`
1 or more, `wrappedKey` 60 bytes of base64; and a row with `shared` must be in a vault row that
carries a `minAppBuild`, so a build that cannot open it never receives it. The service passes its
`sharedManualsMinAppBuild` setting to `check`/`sign` (`sharedManualsMinAppBuild:`) and that
`minAppBuild` must be at least it. A phone below a vault row's `minAppBuild` skips the whole vault,
its manuals included.

**On the phone.** It unwraps the content key with the company secret and
`[profileId, contentId, keyId]` (before downloading), downloads the shared file into protected
staging, checks its length and `sealedSha256`, opens it, checks `sizeBytes` and `revision`, and lays
the manual in as any company manual (`origin: company`, `revision`).

**Rotation.** The service re-encrypts the one file under a new content key with a higher `keyId`, at a
new address, wraps the new key for each company that remains and deletes the old file. A phone that
already holds the manual at that `revision` keeps it: the plaintext is unchanged, so nothing is
downloaded. A phone that does not yet hold it downloads the new file. A new `revision` replaces the
manual as any new revision does. A key a phone kept from before opens nothing still served.

**Visible to a holder of two catalogs**: that two companies share a file (the same `contentId`,
`downloadURL` and `sealedSha256`). Not its contents.

## Fixtures

`fixtures/company-vaults-v1/`: `fixture-keys.json` (labels and the pack-catalog public key),
`pointer-v1.json`, `catalog-v7.json` (generation 7 for `fixture-company`), `fixture_rtu-1.0.0.zip`
(the pack it lists), `RTU Wiring.md` and `RTU Wiring.md.sealed` (the manual it lists), and
`seat-renew-v1.json`. Regenerate with `REGENERATE_COMPANY_VAULT_FIXTURES=1 swift test --package-path
Tools/LicenceIssuance --filter CompanyVaultTests/testRegenerateFixtures`; the catalog's signature
changes on every run (randomised Ed25519), the sealed manual does not.

`fixtures/company-vaults-v2/` (Plan LV): `fixture-keys.json` (adds a second company,
`fixture-other-company`, and its secret's label), `catalog-v12.json` (generation 12: the published
vault `fixture-split-systems`, sealed, with `publisher` and three `expects` — one matched, one at a
different revision, one missing — and its plain company layer `fixture-split-systems-company`),
`catalog-frozen-v13.json` (the same, `frozen`), `fixture-split-systems-7.zip` and its `.sealed`,
`fixture-split-systems-company-2.zip`, two sealed manuals, `layer-collides-manifest.json` (a layer
that would replace a publisher file), and `negative-catalogs.json` (unsigned payloads the service
refuses: `extends` naming a vault not in the catalog, `extends` with `publisher`, `extends` naming a
layer, an `expects` key twice — each with the words of its refusal). Regenerate with
`REGENERATE_COMPANY_VAULT_V2_FIXTURES=1 swift test --package-path Tools/LicenceIssuance --filter
CompanyVaultV2Tests/testRegenerateV2Fixtures`; the sealed files and packs regenerate to the same
bytes, the catalogs' signatures do not.

`fixtures/company-vaults-v3/` (Plan LV P3): `fixture-keys.json` (adds a third company,
`fixture-third-company`, the content keys' labels and `sharedManualsMinAppBuild` 692),
`Installation manual.md` (the plaintext), `installation-manual.k1.sealed` and, after a rotation,
`installation-manual.k2.sealed` (the one shared file under `keyId` 1 and 2), `fixture-split-systems-8.zip`
(the plain pack of the vault both companies hold, `minAppBuild` 692),
`catalog-fixture-company-v20.json` and `catalog-fixture-other-company-v20.json` (the same shared row
with each company's own wrapped key), `catalog-fixture-company-v21.json` and
`catalog-fixture-other-company-v21.json` (the rotation), `negative-catalogs.json` (a `shared` row under
a vault row without `minAppBuild`, `keyId` 0, an unsafe `contentId`, a short wrapped key, each with the
words of its refusal) and `negative-keys.json` (keys that never open the manual: a third company's
secret, a key wrapped for another profile, the `keyId` 1 key against the rotated file, the new key
named with the old `keyId`; `fails` says whether the unwrap or the open refuses). Regenerate with
`REGENERATE_COMPANY_VAULT_V3_FIXTURES=1 swift test --package-path Tools/LicenceIssuance --filter
CompanyVaultV3Tests/testRegenerateV3Fixtures`; the shared files and wrapped keys regenerate to the
same bytes, the catalogs' and pack's signatures do not.
