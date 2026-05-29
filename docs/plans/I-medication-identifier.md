# Plan I — Medication Identifier

**Cross-feature:** combines [Plan A1's](A-accessibility-tier.md) `OCRService` with [Plan B's](B-personal-health-vault.md) Personal Health Vault. The user points the glasses at a pill bottle / blister pack; we OCR the label on-device and cross-check it against their `medications.md`.

**Strategic fit:** High-utility, low-code consumer feature that makes the Health Vault feel alive and reinforces the Medical Compliance value prop. Safety-positive (flags mismatches), and entirely on-device for the OCR step.

**Effort:** ~1-2 days.

---

## What already exists

- `OCRService.recognizeText(in:)` — on-device Vision OCR (text + blocks).
- `HealthVaultTool` / `VaultRegistry.store(forId: "health")` — reads `medications.md`.
- `LLMService.analyzeFrame` — available if we want the model to read a messy label instead of raw OCR.
- `TextToSpeechService.SpeechUrgency` — `.high` for a "this isn't on your list / possible interaction" warning.

## New work

**`Sources/Services/NativeTools/MedicationIdentifierTool.swift`** (`identify_medication`):
1. Capture frame → `OCRService` extracts label text (drug name, strength, directions).
2. If OCR is weak/garbled, fall back to `LLMService.analyzeFrame` with a "read this medication label, return name + strength" prompt.
3. Cross-check the parsed name against `medications.md` (case-insensitive, fuzzy on the drug name token).
4. Return one of:
   - **match** — "That's your Metformin 500 mg, twice daily with meals. (Source: medications.md)"
   - **not on list** — surfaced for the model to caution (urgency cue), never a clinical claim.
   - **strength mismatch** — "Your record says 500 mg; this bottle reads 1000 mg — please confirm."

Gated by the Medical Compliance unlock (same as Health Vault); returns a "locked" message otherwise.

**Touched:** register in `NativeToolRegistry` (needs `cameraService`); add tool descriptions to both system prompts.

## Tool spec

```
identify_medication:
  args: { }            // reads the current frame
  returns: label readout + cross-check result + source
  use: "what's this pill?", "is this my medication?", "what does this bottle say?"
```

## Guardrails (must-haves for a health-adjacent feature)

- Never assert identity from OCR alone for a *dangerous* action — phrase as "the label reads X", not "this is X".
- Cross-check is informational; always cite `medications.md` and defer to the label/pharmacist.
- No fabrication: if the name isn't in the vault, say so; don't guess interactions.

## Build order

1. Tool skeleton: capture → OCR → return raw label readout (no cross-check). Test OCR on a rendered label image (reuse `OCRServiceTests` pattern).
2. Parse drug name + strength from OCR text (token heuristic, unit-tested).
3. Cross-check against `medications.md`; structured result.
4. Wire urgency on mismatch via the assistant reply.

## Open questions

- Barcode/NDC scan as a more reliable identifier than OCR? `BarcodeScannerTool` already exists — could read the NDC and look it up. *Recommendation: try barcode first, fall back to OCR.*
- Ship an offline NDC→name table, or keep it vault-only (user's own meds)? *Recommendation: vault-only for v1 — no external drug DB, no fabrication risk.*

## Dependencies

- A1 `OCRService` (shipped), B Health Vault (shipped), Medical Compliance IAP.
