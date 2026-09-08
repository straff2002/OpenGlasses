# Plan AB — Personal Health-Safety Advisor

**Status: 🚧 Core shipped; the OCR-label camera path is the one unbuilt item.** The deterministic core is built and tested: pure `SubstanceCatalog`
(drug-class / food-tag / condition synonyms), `VaultGrounding` (selects the relevant vault meds /
conditions / allergies), `InteractionRubric` (curated **high-severity** interactions — authoritative,
the LLM can't downgrade a hit), and `HealthSafetyResponseBuilder` (cite + mandatory disclaimer). The
`@MainActor HealthSafetyAdvisor` reads the Medical-Compliance-gated Health Vault, runs the rubric, and
grounds the LLM long-tail via `completeStateless`; `HealthSafetyTool` (`health_check` —
`can_i_take`/`can_i_eat`) is registered + advertised in both prompt builders. 34 tests green in
Release.

**Updated 2026-07-10 (code-verified review):**
- **Rubric breadth: SHIPPED** (was listed deferred) — +7 drug classes and the paired rules
  (`InteractionRubric.swift:61-97,139-152`, `SubstanceCatalog.swift:14-20`).
- **OCR-label photo path: re-scoped, build half is buildable now.** The assumed blocker (camera+OCR
  plumbing) evaporated: `MedicationIdentifierTool` already does camera-frame →
  `OCRService.recognizeText`, and `health_check` already has the `label_text` seam — the build is
  glue (a `use_camera` flag that captures, OCRs, feeds `label_text`; or a `food_label`
  `AssessmentSchema` on the Plan AD vision substrate for a typed ingredients/warnings read). Only
  *accuracy on real labels* stays device-gated.
- **Three rubric false-negative gaps — shipped in BM P4 (`7ec070f`, [#197](https://github.com/straff2002/OpenGlasses/pull/197)):**
  1. `.anticoagulated` is now consumed by `check()` (`InteractionRubric.swift:35`) — a vault saying
     "on blood thinners" with no recognized drug name now hits the flagship high-severity NSAID rule.
  2. `.asthma` now feeds a rule — NSAID + aspirin-exacerbated respiratory disease
     (`InteractionRubric.swift:44-48`).
  3. `Substance.isClassified` is now consulted (`HealthSafetyResponseBuilder.swift:48-50`): an
     unrecognized brand name reads "I don't recognise X in my interaction table" instead of the
     same authoritative-sounding negative a genuinely-checked substance gets.
- **Upstream bypass — closed.** A system-prompt rule now forces health/medication safety questions
  through `health_check` (`SystemPromptBuilder.swift:26-30`, BM P4/#197) — Direct mode can no longer
  answer "can I take ibuprofen?" from the model's own weights with no rubric, citation, or
  disclaimer. (The disclaimer was already solid within the tool — `compose()` appends it
  unconditionally — and the Medical-Compliance gate is service-layer, `HealthSafetyAdvisor.swift:28-30`.)

Original plan below.

**Strategic fit:** Turns the **Health Vault** (Plan B) from passive storage into an *active* "is this safe
for **me**?" advisor: a hands-free, vault-grounded check for **drug interactions, contraindications, and
dietary conflicts** — "Can I take ibuprofen?", "Can I eat this?" (point at the label). Reuses the Health
Vault, Medication Identifier (OCR), and `LLMService`; the only genuinely new piece is a **deterministic
known-interaction rubric** that backstops the model.

**This is advisory, NOT medical advice** — every answer cites the vault entries it used and ends with
"confirm with your pharmacist or doctor." Gated behind the Medical Compliance entitlement.

**Effort:** ~0.5–1 week (≈80% reuse; the grounding selector + the interaction rubric are the new pieces).

---

## Concept

A `health_check` flow grounds LLM reasoning in the user's Health Vault (current meds, conditions,
allergies, and an optional pharmacogenomic / PGx profile) to answer two question shapes:

- **"Can I take X?"** — cross-reference the substance against current prescriptions, conditions (e.g.
  kidney disease, ulcers, anticoagulation), allergies, and PGx → flag interactions / contraindications
  with a **severity** and the specific reason ("you take warfarin; ibuprofen raises bleeding risk").
- **"Can I eat this?"** — optionally OCR a food/label (reuse the Medication Identifier capture path),
  check against conditions (gout/uric acid, diabetes, sodium) and meds (warfarin↔vitamin K,
  MAOI↔tyramine).

**Two-layer safety** (the architectural point):
1. **Deterministic rubric first** — a curated table of well-established **high-severity** interactions /
   contraindications is checked in code. A model hallucination can never downgrade a known-dangerous combo
   to "safe": if the rubric fires, the warning is authoritative.
2. **LLM for the long tail** — grounded in the selected vault entries, for everything the rubric doesn't
   cover, clearly labelled advisory.

---

## Files

```
Sources/Services/HealthSafety/
├── HealthSafetyQuery.swift      // the structured query (substance | food + optional captured label)
├── VaultGrounding.swift         // PURE: select the vault entries relevant to a query (meds/conditions/allergies)
├── InteractionRubric.swift      // PURE: curated deterministic high-severity interaction/contraindication table
├── HealthSafetyAdvisor.swift    // @MainActor: rubric check + grounded LLM reason + cite + disclaim
└── NativeTools/HealthSafetyTool.swift // health_check: can_i_take <substance> | can_i_eat <food|photo>
```

Reuse (no new infrastructure):
- **Grounding data** — [HealthVaultTool](../../OpenGlasses/Sources/Services/NativeTools/HealthVaultTool.swift) / the Health Vault (Plan B): meds, conditions, allergies.
- **Capture/OCR** — [MedicationIdentifierTool](../../OpenGlasses/Sources/Services/NativeTools/MedicationIdentifierTool.swift) + `OCRService` for a pill/label photo.
- **Reasoning + voice** — [LLMService](../../OpenGlasses/Sources/Services/LLMService.swift) (grounded prompt with the selected vault entries) + `TextToSpeechService`.

---

## Deterministic core (the testable part)

```swift
/// PURE: pick the vault entries relevant to a query, to ground the prompt + drive the rubric.
struct VaultGrounding {
    func relevantEntries(for query: HealthSafetyQuery, in vault: HealthVault) -> GroundingContext
}

/// PURE: curated, well-established, high-severity interactions/contraindications. Authoritative when it
/// fires — the model is never allowed to override a hit. Deliberately NOT exhaustive (the LLM covers the
/// long tail); each rule cites a clinical basis.
struct InteractionRubric {
    enum Severity: Int, Comparable { case info, caution, high }
    struct Hit { let reason: String; let severity: Severity; let basis: String }
    func check(_ substance: Substance, against context: GroundingContext) -> [Hit]
    // e.g. warfarin + NSAID → .high (bleeding); MAOI + tyramine-rich food → .high (hypertensive crisis);
    //      ACE-inhibitor + potassium → .caution; known allergy match → .high.
}
```

- **`VaultGrounding`** — pure selection of the meds/conditions/allergies relevant to a query (so the
  prompt is grounded and small); testable: given a vault + query, returns exactly the right entries.
- **`InteractionRubric`** — the deterministic high-severity table; testable: known-dangerous combos fire
  with correct severity; safe combos don't; severity ordering holds.
- The **LLM reasoning** + the **OCR/camera** are device/LLM-gated; the grounding + the rubric + the
  disclaimer gating are the headless core.

---

## Tests (headless)

- **VaultGrounding**: "can I take ibuprofen" with a warfarin vault → warfarin selected; unrelated meds
  excluded; allergy entries always included.
- **InteractionRubric**: warfarin+NSAID → `.high`; MAOI+tyramine → `.high`; ACE-inhibitor+potassium →
  `.caution`; allergy match → `.high`; an unrelated pairing → no hit; `Severity` ordering.
- **Authority**: when the rubric returns a `.high` hit, the advisor surfaces it as a definite warning
  regardless of any LLM text (the model can't downgrade it).
- **Disclaimer gating**: every response carries "advisory only — confirm with your pharmacist/doctor" and
  never asserts a definitive clinical decision.

---

## Deferred / risk

- **Liability / scope.** Advisory only; not medical advice; not a substitute for a pharmacist or doctor.
  The deterministic rubric is **curated high-severity only** (clearly stated; the LLM long-tail is labelled
  non-authoritative). Strong, unavoidable disclaimer on every answer.
- **PGx is optional/advanced** — most users won't have a pharmacogenomic profile; the feature degrades
  gracefully to meds + conditions + allergies.
- **Entitlement** — gated behind the Medical Compliance IAP (see [medical pricing]).
- **Device/LLM-gated:** the OCR-a-label path and the LLM long-tail accuracy are validated on device; the
  grounding selector + rubric are the headless gate.

---

## Why this matters

It makes the Health Vault *do something* at the moment of decision — a hands-free, personalised "is this
safe for me?" that backstops the model with a deterministic rule set for the genuinely dangerous combos.
A natural, sellable extension of the Medical Compliance line that reuses the vault, OCR, and LLM machinery
already shipped, with a small, well-tested new core and an honest, deterministic safety floor.
