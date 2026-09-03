# Vault Pack Catalog

`catalog.json` is the signed index of vault packs the app fetches (Plan EG); `packs/` holds the
published pack zips, served by the same GitHub Pages deployment as the skill packs:

```
https://straff2002.github.io/OpenGlasses/vaultpacks/catalog.json
```

(the default in `Config.vaultPackCatalogURL`). Same envelope shape and the same vendor key as
`skillpacks/catalog.json`; one private key signs both.

A pack is a vault folder — `manifest.json`, the core markdown files, `procedures/` — plus a
`pack.json` beside the manifest. **A pack never contains manufacturer manuals.** Customers add
their own to the pack's documents tier on their phone. Pre-extracted manual text may only be
included where the author is licensed to redistribute it; record that in `redistributionNote`.

## Publishing a pack

1. Build the vault folder as the vault guide describes, with no `documents`, and set the inner
   manifest's `gating.iap` to the pack id (`com.openglasses.vault.<vaultId>`).
2. Add `pack.json`:
   ```json
   {
     "id": "com.openglasses.vault.hvac_rtu",
     "vaultId": "hvac_rtu",
     "version": "1.0.0",
     "name": "HVAC Rooftop Units",
     "summary": "Fault codes, nameplate decoding, and diagnostics for packaged rooftop units.",
     "author": "Partner name as it should appear in Settings",
     "minAppBuild": 366,
     "licensePack": "hvac_rtu"
   }
   ```
3. Sign it — prints the pack signature for the index entry:
   ```
   swift Scripts/vaultpack-sign.swift sign-pack <vaultDir> secrets/skillpack-signing-key.txt
   ```
4. Zip the folder (`cd <vaultDir> && zip -X -r ../<vaultId>-<version>.zip .`), host the zip under
   `vaultpacks/packs/`, and note its SHA256 (`shasum -a 256 <zip>`).
5. Add an entry to `index.json`: `id`, `vaultId`, `version`, `name`, `summary`, `author`,
   `minAppBuild`, `downloadURL`, `sha256`, `packSignature`.
6. Re-sign the index and overwrite `catalog.json`:
   ```
   swift Scripts/vaultpack-sign.swift sign-catalog vaultpacks/index.json secrets/skillpack-signing-key.txt > vaultpacks/catalog.json
   ```
7. Create the pack's App Store product with the same id as `pack.json`'s `id` (a non-consumable),
   so solo buyers can buy it. Team licences include a pack with `--pack <licensePack>`.

`catalog.json` is committed as a signed, empty index until the first pack ships, so the app's Packs
list resolves cleanly rather than reporting an unreachable catalog.

## The signing key

The same vendor key signs this catalog and `skillpacks/catalog.json`. Mint it into a file — never
onto your screen:

```
swift Scripts/skillpack-sign.swift keygen secrets/skillpack-signing-key.txt
```

**A private key is written to a file at generation and is never printed** — not by a script, not
into a terminal, a chat, or a log. Pass the key *file's path* to `sign-pack` / `sign-catalog`, as
above, so the key never reaches shell history either; a key that has been printed is a key that
must be rotated. The key in use was rotated on 2026-09-03 for exactly that reason.
