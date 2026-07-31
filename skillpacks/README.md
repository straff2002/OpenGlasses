# Skill Pack Catalog

`catalog.json` is the signed index the app fetches (Plan BX). It's served by the repo's GitHub
Pages deployment at:

```
https://straff2002.github.io/OpenGlasses/skillpacks/catalog.json
```

(the default in `Config.skillPackCatalogURL`).

## Publishing a pack

1. Build the pack folder: `skillpack.json` + payload files (manifest reference in
   `docs/plans/BX-skill-packs.md`).
2. Sign it — prints the pack signature for the index entry:
   ```
   swift Scripts/skillpack-sign.swift sign-pack <packDir> <privateKey>
   ```
3. Zip the folder (`cd <packDir> && zip -X -r ../<id>.zip .`), host the zip somewhere stable, and
   note its SHA256 (`shasum -a 256 <id>.zip`).
4. Add an entry to the **index** (the *decoded* payload — see the shape in
   `SkillPackCatalog.Index`): id, version, name, summary, hardware, `downloadURL`, `sha256`,
   `packSignature`.
5. Re-sign the index and overwrite `catalog.json` with the printed envelope:
   ```
   swift Scripts/skillpack-sign.swift sign-catalog index.json <privateKey> > skillpacks/catalog.json
   ```
6. Update `testCommittedCatalogVerifiesAgainstProductionKey` with the new envelope bytes (it pins
   catalog ↔ embedded key coherence), run the suite, commit both together, push. Pages redeploys
   on merge to main.

The private key lives off-repo with the Field Assist licensing key. The public half is embedded at
`SkillPackSignature.productionPublicKeyBase64` — rotating the key means shipping an app update.
