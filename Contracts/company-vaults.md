# Company vaults and manuals — contract v1

The licence service publishes, for one company, the vaults it has and the manuals in them; every
phone enrolled in that company installs them and picks up each new version by itself. This is the
contract the phone reads. The reference implementation is
`Tools/LicenceIssuance/Sources/LicenceIssuance/CompanyVaults.swift` (`CompanyVaultContract`), the
phone restates it (`CompanyVaultCatalog`, `CompanyManualSeal`), and both sides' tests read the
golden fixtures in `fixtures/company-vaults-v1/`. Invented content only; the fixture keys are
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

The phone fetches the catalog only when `generation` is above the one it has verified, so the
daily check costs one profile fetch. *Check for Updates* fetches it whatever the generation.

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
pack ≤ 250 MiB with each file ≤ 20 MiB (`checkPackFiles`); everything one company stores ≤ 2 GiB
to start (`check(_:companyTotalBytes:)` takes the company's own); at most 64 vaults and 2,000
manuals per catalog.

## 5. The seat renewal (P2)

A renewal (`SeatRenewRequest`) may carry `vaults: [{vaultId, version}]` — the company vaults
installed on the phone, at most 16, and only when the request still fits in
`SeatWire.maximumRequestBytes`. Absent when the phone has none, so the bytes are what they were.
`SeatPolicy.renew(…, vaults:)` keeps them on the seat (`SeatRecord.vaults`) and
`SeatPolicy.fleetVersions` counts held seats by version for the portal. It is disclosed in the
privacy manifest and the in-app copy.

## Fixtures

`fixtures/company-vaults-v1/`: `fixture-keys.json` (labels and the pack-catalog public key),
`pointer-v1.json`, `catalog-v7.json` (generation 7 for `fixture-company`), `fixture_rtu-1.0.0.zip`
(the pack it lists), `RTU Wiring.md` and `RTU Wiring.md.sealed` (the manual it lists), and
`seat-renew-v1.json`. Regenerate with `REGENERATE_COMPANY_VAULT_FIXTURES=1 swift test --package-path
Tools/LicenceIssuance --filter CompanyVaultTests/testRegenerateFixtures`; the catalog's signature
changes on every run (randomised Ed25519), the sealed manual does not.
