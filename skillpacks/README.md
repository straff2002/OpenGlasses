# Skill Pack Catalog

`catalog.json` is the signed index the app fetches (Plan BX); `index.json` is its decoded payload
(the thing you edit and re-sign); `packs/` holds the published pack zips (also Pages-served), and
`src/` their unpacked sources — edit in `src/`, then re-zip, re-sign, and update the index per the
flow below. `SkillPackCatalogTests` embeds byte-copies of the committed catalog *and* zips, so
drift between what's published and what's tested fails the suite.

It's served by the repo's GitHub Pages deployment at:

```
https://straff2002.github.io/OpenGlasses/skillpacks/catalog.json
```

(the default in `Config.skillPackCatalogURL`).

## Publishing a pack

1. Build the pack folder: `skillpack.json` + payload files (manifest reference in
   `docs/plans/BX-skill-packs.md`).
2. Sign it — prints the pack signature for the index entry:
   ```
   swift Scripts/skillpack-sign.swift sign-pack <packDir> secrets/skillpack-signing-key.txt
   ```
3. Zip the folder (`cd <packDir> && zip -X -r ../<id>.zip .`), host the zip somewhere stable, and
   note its SHA256 (`shasum -a 256 <id>.zip`).
4. Add an entry to `index.json` (the *decoded* payload — see the shape in
   `SkillPackCatalog.Index`): id, version, name, summary, hardware, `downloadURL`, `sha256`,
   `packSignature`.
5. Re-sign the index and overwrite `catalog.json` with the printed envelope:
   ```
   swift Scripts/skillpack-sign.swift sign-catalog skillpacks/index.json secrets/skillpack-signing-key.txt > skillpacks/catalog.json
   ```
6. Update `testCommittedCatalogVerifiesAgainstProductionKey` with the new envelope bytes (it pins
   catalog ↔ embedded key coherence), run the suite, commit both together, push. Pages redeploys
   on merge to main.

## The signing key

Mint it once, into a file — never onto your screen:

```
swift Scripts/skillpack-sign.swift keygen secrets/skillpack-signing-key.txt
```

`keygen` writes the private half to that path with mode 0600, refuses to overwrite an existing
file, and prints **only** the public key. **A private key is written to a file at generation and is
never printed** — not by a script, not into a terminal, a chat, or a log. The signing subcommands
take the key file's path (as above) rather than the key itself, so it never reaches shell history
either. A key that has been printed is a key that must be rotated.

The private key lives off-repo in `secrets/` (gitignored), with the Field Assist licensing key —
one key signs both this catalog and `vaultpacks/catalog.json`. The public half is embedded at
`SkillPackSignature.productionPublicKeyBase64` — rotating the key means shipping an app update,
re-signing every pack and both catalogs, and updating the pinning tests in the same change.
The key in use was rotated on 2026-09-03 after the previous one was exposed in terminal
scrollback and chat transcripts.
