# Plan — Safety Assessment (High-Energy Control Assessment)

**Status: 📋 Planned (not built).** Plan refined 2026-06-18 (structured-output + catalog); no code yet —
none of the named files exist. Sequenced as a Field Assist vertical after the in-flight #8 (ASR) / #9
(SOP spotter) cores.

**Strategic fit:** A B2B safety capability that slots into the **Field Assist** line: a technician glances at a job site and gets a structured, audited assessment of the **high-energy hazards** present and whether each is safeguarded by a *direct* control. Grounded in the published EEI / Construction Safety Research Alliance (CSRA) energy-based "Serious Injury & Fatality (SIF) prevention" methodology — the same vault/procedure/audit shape we already ship, applied to safety. Utilities and construction are exactly the verticals Field Assist targets, and SIF-prevention is a budgeted, regulated spend.

**Effort:** ~1 week (≈80% reuses existing engines; the score, overlay, and report view are the only genuinely new pieces).

---

## Concept

Capture one job-site frame → a multi-LLM **structured vision assessment** against the catalog of **13 high-energy hazards** (each "almost always > ~500 ft-lbs / 1,500 J", i.e. capable of a serious injury or fatality). For every hazard the model decides:

- **present?** — is this high-energy hazard in the scene;
- **control** — is it safeguarded by a **DIRECT** control (engineered, targeted, effective *even if a worker errs* — fall arrest, lockout/tagout, machine guarding, trench shoring) vs only an **INDIRECT** control (training, signage, PPE, spotters — vulnerable to human error) vs none;
- **evidence** — a short note + a normalized bounding box for any specific unsafe condition.

The **HECA score** = fraction of *present* high-energy hazards that have a **direct** control. Output: an annotated overlay, the score, an audited + exportable report, and an optional spoken safety-advisor follow-up.

---

## Files

```
Sources/Services/SafetyAssessment/
├── SafetyHazard.swift            // EEI energy-source wheel + the 13 high-energy hazard catalog + ControlStatus
├── SafetyAssessment.swift        // report model: per-hazard finding, evidence boxes, score, summary
├── SafetyAssessmentService.swift // frame → structured LLM assessment (prompt + parse), provider-agnostic
├── SafetyAssessmentStore.swift   // persist report JSON + original/annotated images; history
└── NativeTools/SafetyAssessmentTool.swift  // safety_assessment: run | score | last | history
Sources/App/Views/
├── SafetyAssessmentOverlay.swift     // bounding-box + control-status overlay on the captured frame
└── SafetyAssessmentReportView.swift  // findings list, score, export button
```

Reuse (no new infrastructure):
- **Vision** — [LLMService.analyzeFrame](../../OpenGlasses/Sources/Services/LLMService.swift) (multi-LLM: Claude / Gemini / OpenAI / on-device — a step up from a single-provider assessment).
- **PDF export** — `SessionExporter` (the same path Field Assist / Medical export use).
- **Audit + persistence** — [FieldSessionService](../../OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift) + `SessionLogger`: a safety assessment is logged as a session event, so it inherits the append-only audit log and export.
- **HUD** — [GlassesDisplayService](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift): surface the top uncontrolled hazard as a `.hazard` card, and the score as a notification.
- **Camera frame** — `CameraService` periodic capture (glasses POV) with the iPhone-camera fallback.
- **Advisor follow-up** — the existing conversational `LLMService`, formalized (from v2) as an
  **image-seeded safety-partner chat**: the assessed frame is kept in context so the worker can ask
  "does a spotter count as a direct control here?" and get a specific answer. Dedicated system prompt —
  a calm, collaborative safety partner *"like talking on the radio"*, who helps decide whether a control
  is truly DIRECT and suggests specific direct controls, and **never claims a real-world action was
  taken** (it only assesses + advises). The "never claims an action" guardrail dovetails with the
  liability framing below.

---

## Model

```swift
/// EEI/CSRA "energy wheel" sources.
enum EnergySource: String, Codable, CaseIterable {
    case gravity, motion, mechanical, electrical, pressure, temperature
    case chemical, radiation, biological, sound, other
}

/// Whether a present high-energy hazard is safeguarded.
enum ControlStatus: String, Codable { case direct, indirect, none }

/// The 13 categorical high-energy hazards (EEI Appendix 3). **Snake_case raw ids** (LLM-friendly —
/// they are the exact category ids in the prompt + response schema), each mapped to its energy-wheel
/// source and an SF Symbol for the overlay/HUD.
enum HighEnergyHazard: String, Codable, CaseIterable, Identifiable {
    case suspendedLoad = "suspended_load"
    case fallFromElevation = "fall_from_elevation"
    case mobileEquipment = "mobile_equipment"          // Mobile Equipment / Traffic
    case motorVehicleSpeed = "motor_vehicle_speed"
    case mechanicalRotating = "mechanical_rotating"    // Heavy Rotating Equipment
    case highTemperature = "high_temperature"
    case steam, fire, explosion
    case excavation                                    // Trench / Excavation (was trenchCollapse)
    case electricalContact = "electrical_contact"
    case arcFlash = "arc_flash"
    case toxicChemicalRadiation = "toxic_chemical_radiation"  // folds toxic + radiation (was highDoseToxic)

    var id: String { rawValue }
    var displayName: String { /* per-case copy */ "" }
    var energyThreshold: String { /* "almost always > ~500 ft-lbs / 1,500 J" copy per hazard */ "" }
    /// Energy-wheel grouping (for the overlay legend + summary). e.g. excavation → .gravity,
    /// explosion → .pressure, steam → .temperature, arcFlash → .electrical.
    var energySource: EnergySource { /* per-case map */ .other }
    /// SF Symbol for the finding row / HUD card (e.g. suspendedLoad → "shippingbox.fill").
    var systemImage: String { /* per-case */ "exclamationmark.triangle.fill" }
}

struct EvidenceBox: Codable, Equatable {
    let note: String
    let box: [Int]   // box_2d = [ymin, xmin, ymax, xmax], normalized 0–1000
}

struct HazardFinding: Codable, Equatable {
    let hazard: HighEnergyHazard
    let isPresent: Bool
    // Explicit booleans (the model decides has_*_control directly) + the named control. Both come
    // from the structured schema, so control status doesn't hinge on a non-empty-string heuristic.
    let hasDirectControl: Bool
    let directControl: String      // "" if none
    let hasIndirectControl: Bool
    let indirectControl: String    // "" if none
    let comments: String
    let evidence: [EvidenceBox]
    var controlStatus: ControlStatus {
        hasDirectControl ? .direct : (hasIndirectControl ? .indirect : .none)
    }
}

struct SafetyReport: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let summary: String
    let findings: [HazardFinding]   // all 13, present or not

    /// Score = present hazards with a direct control / present hazards. nil if none present.
    var score: Double? {
        let present = findings.filter(\.isPresent)
        guard !present.isEmpty else { return nil }
        return Double(present.filter { $0.controlStatus == .direct }.count) / Double(present.count)
    }
}
```

The 13-hazard catalog and the direct-vs-indirect rubric are injected into the system prompt so the model returns all 13 with the exact category ids; parsing validates completeness.

**Structured output.** Rather than free-form JSON, drive the assessment with a
**provider structured-output schema**: an object `{ summary, assessments: [...] }` where each assessment
is `{ category (enum, the 13 ids), is_present (bool), has_direct_control (bool), direct_control (str),
has_indirect_control (bool), indirect_control (str), comments (str), evidence: [{ note, box_2d:[ymin,
xmin,ymax,xmax] }] }`, all `required`. `LLMService.analyzeFrame` already speaks to each provider, so it
passes the schema where supported (Gemini `responseSchema`, OpenAI/Anthropic structured-output / forced
tool-call) and falls back to schema-in-prompt + lenient parse elsewhere. This makes "all 13 present,
ids valid, controls explicit" the contract instead of a hope.

**Grid system prompt (tightened, from v2).** Frame the model as a *certified occupational-safety
expert* running a HECA per the EEI/CSRA "Power to Prevent SIF" methodology, with the rigorous **3-part
DIRECT-control test** — a safeguard that is (1) specifically *targeted* to that high-energy hazard,
(2) drops the energy below the SIF threshold when installed/verified/used properly, and (3) stays
effective **even if a worker makes an unintentional mistake** (fall arrest, fixed guarding,
de-energization + LOTO, trench shields, arc-rated suits) — vs INDIRECT (training, signage, PPE,
spotters, awareness). Guard: *if the image isn't a job-site scene, mark everything not-present and say
so in the summary*; the summary is one–two sentences naming the scene + key SIF risks.

---

## Flow

```
"assess this site" / safety_assessment tool / Field Assist step
   ▼
CameraService frame (glasses POV, iPhone fallback)
   ▼
SafetyAssessmentService: structured prompt (13-hazard catalog + control rubric) + frame
   → LLMService.analyzeFrame  → JSON → [HazardFinding] + summary
   ▼
SafetyReport (score computed) 
   ├─ SafetyAssessmentOverlay: draw evidence boxes, colored by control status
   ├─ HUD: .hazard card for the top uncontrolled high-energy hazard + score notification
   ├─ SessionLogger: append a `safetyAssessment` event (audited, exportable)
   └─ SafetyAssessmentStore: persist report + original/annotated image
   ▼
optional: PDF export (SessionExporter) · spoken advisor follow-up
```

---

## Build order

1. `SafetyHazard` catalog (13 + energy sources + thresholds) + `SafetyReport`/`HazardFinding` models + **pure `score`** — with tests. No LLM.
2. `SafetyAssessmentService` — build the structured prompt + **response schema**, call `analyzeFrame`, parse + validate (all 13 present, ids valid, control booleans consistent). Test the parser against fixture JSON.
3. `safety_assessment` native tool (run on the current frame; return the summary + score) + registration + prompt descriptions (LLMService + GeminiLive).
4. `SafetyAssessmentStore` (persist + history) + `SafetyAssessmentReportView`.
5. `SafetyAssessmentOverlay` (normalized box → view-coord mapping; tested pure).
6. HUD surfacing (top uncontrolled hazard `.hazard` card + score) and PDF export via `SessionExporter`.
7. Optional: tie into a Field Assist session as a logged step; advisor follow-up.

---

## Tests (headless)

- **Score** (pure): present-with-direct / present; nil when none present; all-controlled → 1.0; none-controlled → 0.0.
- **Report parsing**: fixture JSON → `SafetyReport`; rejects/repairs missing categories (must return all 13); unknown ids ignored.
- **Catalog**: 13 hazards, stable raw ids, every case has displayName + threshold copy.
- **Control status**: `hasDirectControl` → direct; else `hasIndirectControl` → indirect; else none.
- **Schema/parse**: required fields enforced; `category` outside the 13-id enum rejected; control-name string present whenever its boolean is true.
- **Overlay mapping** (pure): normalized `[ymin,xmin,ymax,xmax]` 0–1000 → CGRect in a given image size (orientation-correct).

---

## Open questions / decisions

- **Model tier.** Accuracy matters for safety — default to a *Best*-tier cloud model for the assessment; allow on-device for offline sites (lower accuracy, clearly labelled). *Recommendation: Best tier by default; on-device behind a toggle with a "reduced accuracy" note.*
- **Standalone vs Field Assist.** Run as a one-shot `safety_assessment` tool *and* as a loggable step inside a Field Assist session. *Recommendation: ship the standalone tool first; the session hook is a thin add.*
- **Liability framing.** This is decision *support*, not a certified inspection. *Recommendation: every report + the PDF carries a clear "advisory only — verify on site" disclaimer; the advisor prompt never claims a real-world action was taken.*
- **HUD noise.** Surfacing every hazard would spam. *Recommendation: HUD shows only the single highest-severity *uncontrolled* hazard + the score; full list on the phone.*

---

## Refinements (structured output + catalog)

Concrete refinements in this revision of the plan — native-first on `analyzeFrame`, no external REST /
backend coupling:

1. **Structured-output response schema** (enum-constrained `category`, explicit `is_present` /
   `has_direct_control` / `has_indirect_control` booleans, evidence `box_2d`, all `required`) instead of
   free-form JSON — reliability over a string heuristic.
2. **Explicit control booleans** on `HazardFinding` (model decides `has_direct/indirect_control`, not
   "did it fill the string").
3. **Reconciled 13-hazard catalog**: exact **snake_case ids**, a per-hazard **energy-source** map, and
   an **SF Symbol** per hazard; `excavation` (was `trenchCollapse`) and `toxic_chemical_radiation`
   (folds toxic + radiation; was `highDoseToxic`).
4. **Tighter grid prompt**: the rigorous 3-part DIRECT-control test + the non-job-site guard + the
   one–two-sentence summary format.
5. **Image-seeded advisor chat** with a defined radio-style safety-partner system prompt + the
   "never claim a real-world action" guardrail.
6. *(optional)* a few **bundled sample job-site frames** (scaffold, hot work, confined space/manhole,
   man-lift, formwork, shotcrete) for a demo/try-it path and as parser test fixtures.

Transport stays native: the assessment runs through `analyzeFrame` (multi-provider, offline-degrading)
with our own SwiftUI + audit/PDF stack — no external REST endpoint or backend service.

## Dependencies / prereqs

- [LLMService.analyzeFrame](../../OpenGlasses/Sources/Services/LLMService.swift) (existing) — structured vision call.
- `SessionExporter` + [FieldSessionService](../../OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift) / `SessionLogger` (existing) — audited report + PDF export, see [Plan F](F-field-assist.md).
- `CameraService` (existing) — glasses-POV frame + iPhone fallback.
- [GlassesDisplayService](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift) (existing) — `.hazard` HUD card.

---

## Why this matters

It turns the glasses into a hands-free **safety second-opinion** on a real, regulated workflow: a worker looks at the site and immediately sees which high-energy hazards lack a *direct* control — the single strongest predictor of serious injuries and fatalities. It's a natural, sellable extension of Field Assist that reuses the vault/procedure/audit machinery already built, adds an auditable PDF trail compliance teams want, and — because it runs on our multi-LLM `analyzeFrame` — works across providers and degrades to on-device offline. Small new surface, large B2B story.
