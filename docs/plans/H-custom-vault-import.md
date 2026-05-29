# Plan H — Custom / Enterprise Vault Import

**Builds on:** [Plan F](F-field-assist.md) foundation. `VaultStore` already merges a bundled baseline with a **user overlay** in `Documents/Vaults/{id}/`, and `ProcedureLibrary` already loads `procedures/*.json` from that overlay. This plan adds the UI + validation to let a customer bring their own pack — unlocking the Enterprise tier.

**Strategic fit:** Enterprise sales motion. "Upload your own equipment manuals + procedures" is the differentiator for customers whose vertical we don't ship a pack for (in-house engineering, niche OEMs).

**Effort:** ~3-4 days.

---

## What already exists

- `VaultStore.write` / `append` write to the Documents overlay; `read`/`readAll` merge overlay over bundle.
- `ProcedureLibrary.load` already enumerates overlay `procedures/*.json` and the bundle, overlay winning.
- `Procedure` is `Codable` with a defined schema → validation is "does it decode + are step/branch targets resolvable".

## New work

**Runtime vault registration** — today `VaultRegistry.builtInManifests` is a hardcoded array. Add a second source: user manifests loaded from `Documents/Vaults/_registry/*.json` (the README already anticipates this). `allManifests` returns built-in + user.

**New files:**
- `Sources/Services/Vault/VaultImporter.swift` — accepts a `.zip` or a folder (manifest.json + *.md + procedures/*.json), validates, and installs into the overlay + `_registry`.
- `Sources/Services/Vault/VaultValidator.swift` — checks: manifest decodes; every listed `.md` present; each procedure decodes; every `branch.next` / `default_next` / `entry_step` resolves to a real step id; no orphan/unreachable terminal-less cycles.
- `Sources/App/Views/VaultManagerView.swift` — list installed vaults, import button (Files picker), per-vault delete, validation-error display.

**Touched:**
- `VaultRegistry` — load user manifests; `isUnlocked` returns true for custom vaults under an `enterprise` entitlement (or dev-unlock).
- Settings — entry point to `VaultManagerView`.

## Validation contract (surface errors before a session starts)

```
- manifest.json present and decodes to VaultManifest
- every file in manifest.files exists in the bundle
- procedures_dir (if set) exists; each *.json decodes to Procedure
- entry_step resolves; every branch.next and default_next resolves
- at least one reachable terminal step per procedure (no dead ends / infinite loops)
- prompt_rules non-empty (enforce grounding discipline on customer content)
```

## Build order

1. `VaultValidator` + tests (pure, table-driven — great unit-test target).
2. `VaultImporter` (zip/folder → overlay + `_registry`), with rollback on validation failure.
3. `VaultRegistry` user-manifest loading + `enterprise` gating.
4. `VaultManagerView` UI.

## Open questions

- Distribution format: zip upload, or a signed pack URL the app downloads? *Recommendation: both — local zip for dev, signed URL for managed fleets.*
- Versioning/update of an installed custom vault mid-use? Reuse F's "auto-pull on session start, never mid-session" rule.
- Trust: should customer prompt_rules be allowed to *weaken* grounding (e.g. drop "cite sources")? *Recommendation: enforce a minimum rule set regardless of uploaded manifest.*

## Dependencies

- Plan F foundation (shipped). Enterprise IAP/entitlement (new).
