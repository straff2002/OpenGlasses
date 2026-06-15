# Plan — Safety Assessment (High-Energy Control Assessment)

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
- **Advisor follow-up** — the existing conversational `LLMService` ("does a spotter count as a direct control here?").

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

/// The 13 categorical high-energy hazards (EEI Appendix 3).
enum HighEnergyHazard: String, Codable, CaseIterable, Identifiable {
    case suspendedLoad, fallFromElevation, mobileEquipment, motorVehicleSpeed,
         mechanicalRotating, highTemperature, steam, fire, explosion,
         electricalContact, arcFlash, trenchCollapse, highDoseToxic
    var id: String { rawValue }
    var displayName: String { /* … */ "" }
    var energyThreshold: String { /* "> 500 ft-lbs" copy per hazard */ "" }
}

struct EvidenceBox: Codable, Equatable {
    let note: String
    let box: [Int]   // [ymin, xmin, ymax, xmax], normalized 0–1000
}

struct HazardFinding: Codable, Equatable {
    let hazard: HighEnergyHazard
    let isPresent: Bool
    let directControl: String      // "" if none
    let indirectControl: String    // "" if none
    let comments: String
    let evidence: [EvidenceBox]
    var controlStatus: ControlStatus {
        !directControl.isEmpty ? .direct : (!indirectControl.isEmpty ? .indirect : .none)
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
2. `SafetyAssessmentService` — build the structured prompt, call `analyzeFrame`, parse + validate (all 13 present, ids valid). Test the parser against fixture JSON.
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
- **Control status**: direct beats indirect beats none; empty strings → none.
- **Overlay mapping** (pure): normalized `[ymin,xmin,ymax,xmax]` 0–1000 → CGRect in a given image size (orientation-correct).

---

## Open questions / decisions

- **Model tier.** Accuracy matters for safety — default to a *Best*-tier cloud model for the assessment; allow on-device for offline sites (lower accuracy, clearly labelled). *Recommendation: Best tier by default; on-device behind a toggle with a "reduced accuracy" note.*
- **Standalone vs Field Assist.** Run as a one-shot `safety_assessment` tool *and* as a loggable step inside a Field Assist session. *Recommendation: ship the standalone tool first; the session hook is a thin add.*
- **Liability framing.** This is decision *support*, not a certified inspection. *Recommendation: every report + the PDF carries a clear "advisory only — verify on site" disclaimer; the advisor prompt never claims a real-world action was taken.*
- **HUD noise.** Surfacing every hazard would spam. *Recommendation: HUD shows only the single highest-severity *uncontrolled* hazard + the score; full list on the phone.*

---

## Dependencies / prereqs

- [LLMService.analyzeFrame](../../OpenGlasses/Sources/Services/LLMService.swift) (existing) — structured vision call.
- `SessionExporter` + [FieldSessionService](../../OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift) / `SessionLogger` (existing) — audited report + PDF export, see [Plan F](F-field-assist.md).
- `CameraService` (existing) — glasses-POV frame + iPhone fallback.
- [GlassesDisplayService](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift) (existing) — `.hazard` HUD card.

---

## Why this matters

It turns the glasses into a hands-free **safety second-opinion** on a real, regulated workflow: a worker looks at the site and immediately sees which high-energy hazards lack a *direct* control — the single strongest predictor of serious injuries and fatalities. It's a natural, sellable extension of Field Assist that reuses the vault/procedure/audit machinery already built, adds an auditable PDF trail compliance teams want, and — because it runs on our multi-LLM `analyzeFrame` — works across providers and degrades to on-device offline. Small new surface, large B2B story.
