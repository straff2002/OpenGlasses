# Plan B — Personal Health Vault

**Source repo:** [soma-hud](https://github.com/CarlKho-Minerva/soma-hud)

**Strategic fit:** Extends the existing Medical Compliance IAP with editable markdown grounding + source attribution. **First applied instance of the generic `VaultStore`** introduced in [Plan F](F-field-assist.md). The Health Vault is one of several domain vaults (refrigeration, IT, electrical, automotive) that ride on the same foundation.

**Depends on:** Generic `VaultStore` from [Plan F Phase 1](F-field-assist.md#phase-1-foundation-1-week). Build Plan F Phase 1 first, then layer this on as a vault definition + thin tool wrapper.

**Effort:** ~1-2 days *(reduced from ~2-3 because Plan F builds the storage layer)*

---

## Files

This plan is much smaller once VaultStore is shared infrastructure.

**New (specific to Health Vault):**
- `Sources/Vaults/health/manifest.json` — vault definition (files list, IAP gate, prompt rules)
- `Sources/Vaults/health/{biometrics,conditions,dietary_context,lab_baselines,medications,wearables}.md` — empty templates
- `Sources/Services/NativeTools/HealthVaultTool.swift` — `health_vault_query`, `health_vault_log` (thin wrapper around generic VaultStore queries; convenience API for medical-specific fields)
- `Sources/Views/HealthVaultEditorView.swift` — Files-tab UI for the health vault

**Reused from Plan F:**
- `VaultStore`, `VaultLoader`, `VaultRegistry`, `VaultManifest`, `VaultPromptBuilder` — all generic
- Settings UI scaffolding for vault gating + listing

**Touched:**
- `Sources/Services/LLMService.swift` — already vault-aware via Plan F; just needs Health vault registered
- `Sources/Utils/Config.swift` — `healthVaultEnabled` is `VaultRegistry.isUnlocked("health")` now
- `NativeToolRegistry.init()` — register HealthVaultTool
- `project.pbxproj` — standard entries

---

## Vault manifest

```json
{
  "id": "health",
  "name": "Personal Health Vault",
  "version": "1.0.0",
  "files": [
    "biometrics.md",
    "conditions.md",
    "dietary_context.md",
    "lab_baselines.md",
    "medications.md",
    "wearables.md"
  ],
  "gating": { "iap": "medical_compliance" },
  "prompt_rules": [
    "Never fabricate chart data.",
    "Use only the visible markdown vault, the user's message, attached image, or attached audio transcript.",
    "Be concise, concrete, and grounded.",
    "For food and medication questions, first ground yourself in the chart before giving a caution.",
    "Distinguish clearly between chart facts and general safety guidance."
  ],
  "source_attribution_format": "Source: {files}",
  "source_attribution_required": true
}
```

---

## Vault file contents

Stored in Documents directory (or iCloud if enabled). Six default files mirroring soma-hud:

| File | Contents |
|---|---|
| `biometrics.md` | Height, weight, BMI, blood pressure baseline |
| `conditions.md` | Diagnosed conditions, ongoing health issues |
| `dietary_context.md` | Diet preferences, allergies, intolerances |
| `lab_baselines.md` | Recent lab results with reference ranges |
| `medications.md` | Current medications, dosages, schedule |
| `wearables.md` | Connected wearables, baseline metrics |

User-editable in the Files-tab UI. Empty templates by default — user populates over time. HealthKit auto-population is an option (see Open Questions).

---

## Tool spec

```
health_vault_query:
  args: { question: string }
  returns: relevant excerpts + source files
  use: When user asks a health question; pre-fetches grounded context

health_vault_log:
  args:
    file: "biometrics"|"conditions"|"dietary_context"|"lab_baselines"|"medications"|"wearables"
    entry: string
    date?: ISO
  returns: confirmation
  use: When user wants to log new info ("log that I took my blood pressure: 120/80")
```

The query/log tools are thin convenience wrappers — generic vault search + append are provided by the foundation. The wrappers add type-safe file enums and medical-specific input parsing (e.g., recognising "BP 120/80" → biometrics.md format).

---

## Build order

Assumes Plan F Phase 1 (VaultStore foundation) has shipped.

1. Author manifest + empty markdown templates
2. Register `health` vault with `VaultRegistry`, gated on Medical Compliance IAP
3. Thin `HealthVaultTool` wrapping generic vault query/log with medical conveniences
4. `HealthVaultEditorView` UI (Files-tab)
5. Verify source-attribution rule fires — test with prompt that must cite `medications.md`

---

## Open questions

- **Storage location:** Documents directory (simple) vs iCloud Drive (synced) vs Keychain-wrapped encrypted blob (most private)? *Recommendation: Documents with opt-in iCloud sync toggle.*
- **HealthKit auto-population:** Pull recent vitals from HealthKit into `biometrics.md` and `wearables.md` automatically? Would need user permission + Settings toggle.
- **Export format:** Stay markdown-only, or offer FHIR/JSON export for healthcare provider sharing?
- **Encryption at rest:** Required for App Store medical app review? Check current Medical Compliance attestation requirements. *Action: verify before ship.*

---

## Dependencies / prereqs

- **Plan F Phase 1** (generic VaultStore foundation) — must ship first
- Existing Medical Compliance IAP unlocks the gate
- New Files-tab entry in main navigation (may need tab-bar extension if not already present)
