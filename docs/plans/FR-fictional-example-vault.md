# Plan FR — A Fictional Example Vault (the public fixture names no real manufacturer)

**Status:** 📝 Drafted 2026-09-21 — nothing implemented. Owner decision the same day: replace the
public example rather than leave it or seek permission.
**Priority:** after the FO chain and FS (owner decision 2026-09-22). One PR.
**Surfaces:** `examples/vaults/`, the tests that import the example, the vault guide. No app
behaviour changes.

## Why

`examples/vaults/lennox-slp99` is the reference custom vault and a test fixture. The OEM manuals it
was built from are already kept out of the repository (`examples/vaults/*/documents/*` is ignored).
What *is* committed — `error_codes.md`, `service_values.md`, `parts.md`, `models.md`, `safety.md`
and three procedures — is original wording, but it follows a real manufacturer's tables closely
(the diagnostic-code table row by row; every accessory part number; cited page numbers), under that
manufacturer's product name, in a public repository. Individual facts are one thing; a near-complete
restatement of someone else's service tables as our showcase example is a risk we do not need to
carry, and [EG](EG-vault-packs.md) already lists redistribution of OEM-derived text as an open
question. The example's job — show the shape of a customer vault and exercise retrieval, equipment
identity, parts verification and figures headlessly — does not require a real product.

## Outcome

The public example and every committed fixture describe an **invented** appliance from an invented
maker. The real-manual vault keeps working for the owner and the pilot, from a location git never
sees, and the tests that need real manuals skip cleanly when it is absent (as the two PDF-dependent
cases already do).

## Verified starting point (main, 2026-09-21)

- Tracked: 11 files, ~56 KB, under `examples/vaults/lennox-slp99` (core markdown, `manifest.json`,
  three procedures, two READMEs). Manuals ignored by `.gitignore:112-113`.
- Tests that read the folder from disk: `ExampleVaultLennoxTests`, `EquipmentIdentityTests`
  (derives the model index from the example's core). To confirm during implementation: whether
  `RetrievalGateCalibrationTests`, `WorkRecordTests`, `ManualFigureTests`, `FieldSessionServiceTests`
  and the FN removal tests load it or only reuse its names as literals.
- The product's names also appear as **literals** in ~12 test files and in doc-comment examples in
  app sources (`DeliveryRequest`, `EquipmentSurface`, `WorkTask`, `PartsVerifier`, `SessionExport`,
  `FieldSessionService`, `VaultModelIndex`), in `docs/field-assist-vault-guide.md`, and in plans
  EJ/EK/EL/EM/FM/FN/FO/FQ.
- The bundled `refrigeration` vault mentions several real manufacturers generically
  (`manufacturers.md`, `error_codes.md`). That is authored trade knowledge, not a restatement of one
  manual — **out of scope here**, noted so nobody "fixes" it by accident.

## Design

1. **Invent the appliance.** A condensing gas furnace from a made-up maker, with a model-number
   grammar that exercises what the real one exercised: a family prefix, capacity, cabinet-width
   letter, a nameplate spelling that OCR splits in two, a serial that looks model-like (EL's trap),
   six models, unit-size codes, accessories. Codes, pressures, timings and part numbers are
   **invented and internally consistent** — not the real values shifted by one. Safety text is
   generic good practice. State prominently in the README and in `safety.md` that the appliance is
   fictional and the values must never be used on real equipment.
2. **Invent the manuals.** Two short authored "manuals" (service + installation) as committed
   Markdown in `documents/`, written to reproduce the *retrieval-relevant* properties the real pair
   had: the same code printed in both books, a table the chunker must keep together, ALL-CAPS
   wiring-diagram fragments, `Page N` markers, figures/diagram pages, a section the manual is silent
   on. Because they are ours, they are committed — so the example imports on a fresh clone, which
   the real one never could. Add a `.gitignore` exception for this vault's `documents/`.
3. **Re-point the tests.** Rename `ExampleVaultLennoxTests` → `ExampleVaultTests` (keep history with
   `git mv`), update fixtures and literals across the test files to the fictional names, and keep
   every assertion's *intent* (token-beats-semantic ranking, heading detection, page-marker
   stripping, model-scope penalty, serial-not-a-model, parts verification with a page citation).
   Numbers that were measured on the real pair (EJ's tables) stay in the plan docs as history; the
   tests' thresholds are re-measured on the fictional pair and recorded.
4. **Keep the real vault, privately.** Move it to a gitignored path (`examples/vaults-private/` —
   ignored wholesale). A small env/path seam lets the real-manual tests run when the folder exists
   and `XCTSkip` when it does not; CI always skips them. Document this in the private folder's own
   README (ignored) and in one line of the vault guide.
5. **Scrub the names from prose.** App-source doc comments, the vault guide, and the *example
   strings* in plans switch to the fictional names. Plan documents keep their historical narrative
   ("the first real OEM pair exposed…") without the maker/product name. `git mv` the example folder
   so the rename is one reviewable move plus edits.
6. **History is not rewritten.** Removing the folder from `main` does not remove it from earlier
   commits. That is accepted; a history rewrite is a separate, disruptive decision to take only if
   someone asks.

## Tests / gate

- The fictional vault imports on a fresh clone with **no** skipped cases; all retrieval/identity/
  parts/figure suites green against it; a grep gate (test or CI script) fails if the real maker or
  product name reappears under `examples/`, `OpenGlassesTests/`, `OpenGlasses/Sources/Services` or
  `docs/field-assist-vault-guide.md`.
- With the private folder present locally, the real-manual cases still pass; with it absent they
  skip, not fail.
- Full suite and a Release build, per house style.

## Open questions

- Should the fictional vault also ship as the in-app "try a custom vault" sample (it now legally
  could)? Out of scope here; note for EG.
- The pilot's own vault is unaffected — it lives on the pilot's device and was imported from the
  owner's machine, not from the repository.
