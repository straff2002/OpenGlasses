# Plan — Structured Vision Assessment (schema-validated `analyzeFrame`)

**Status: 🚧 Core shipped on `feat/structured-vision` (Phases 1–3).** Drafted + built 2026-06-19.
Shipped: the pure core (`AssessmentCard`/`AssessmentTier`/`AssessmentFinding`/`InstrumentReading`,
`UnitNormalizer`, `AssessmentSchema`/registry, tolerant `AssessmentJSON`); `LLMService.analyzeFrameStructured`
+ per-provider `StructuredVisionParser` (forced tool-use / function / JSON, text fallback);
`StructuredVisionService` + `vision_assess` tool + `AssessmentCardView`/HUD; and the built-in
**`instrument_reading`** ("read the instrument") consumer. **46 tests, Debug + Release green.**
**Follow-up shipped (`feat/first-aid-triage`):** first-aid casualty-triage consumer —
`FirstAidTriageSchema` + the `first_aid` `action=triage`, with a deterministic safety backstop
(not-breathing / unresponsive / severe-bleeding → critical + "call emergency services", overriding the
model). Advisory only — not a medical device; not behind the Medical Compliance IAP.
**Still deferred:** Gemini `responseSchema` translation, CaptureFlow `voice_number` auto-fill.

**Strategic fit:** Today every camera-reasoning feature funnels through
[`LLMService.analyzeFrame`](../../OpenGlasses/Sources/Services/LLMService.swift) (line 848), which returns
**free text**. Each consumer then either narrates that text (Assistive Modes, Live Coach, Navigation Assist)
or — for anything that needs to *branch* on the result — would have to re-invent "prompt for JSON, scrape it
out of a markdown fence, decode it, hope it validates." The planned [Safety Assessment / HECA](safety-assessment.md)
vertical already proposes exactly that, bespoke, inside its own service.

This plan adds the **missing substrate**: a reusable, **schema-validated** structured-vision call. One frame
(or a few) → a **typed, validated assessment** → a normalized result card + HUD surface + optional audit/export.
Each vertical becomes *data + an adapter*, not a new prompt-and-parse pipeline. It uses **forced tool-use /
response-schema** per provider so the model returns validated JSON natively, instead of regex-scraping free text.

**First consumer:** **First-aid casualty triage** — directly on the in-flight `feat/first-aid-assist`
line, extending [`FirstAidAssistService`](../../OpenGlasses/Sources/Services/FirstAid/FirstAidAssistService.swift)
rather than duplicating it.

**Downstream consumers (separate PRs, not this one):** HECA (its plan collapses to "define a schema + adapter"),
and CaptureFlow `.photo` steps that auto-grade instead of just filing a path.

**Effort:** ~1 week. The deterministic core (Phase 1) and the per-provider parsers (Phase 2) are pure and fully
unit-testable with **no live API**; only the tool wiring + card view (Phase 3) touch the app shell.

---

## Concept

```
            ┌─────────────────────── reusable primitive (this plan) ───────────────────────┐
 camera ───▶│ StructuredVisionService.assess(kind:image:context:)                           │
            │   → AssessmentSchemaRegistry[kind]  (jsonSchema + systemPrompt + card adapter) │
            │   → LLMService.analyzeFrameStructured(schema, image)   ← forced tool-use       │
            │        Anthropic: tools + tool_choice:{type:tool}                              │
            │        OpenAI-compat: tools + tool_choice:{type:function}                      │
            │        Gemini: responseMimeType:application/json + responseSchema              │
            │        local/appleOnDevice: free-text + tolerant JSON extraction (fallback)    │
            │   → decode → schema.makeCard(...) → deterministic backstop → AssessmentCard    │
            └──────────────────────────────────────────────────────────────────────────────┘
                         │                         │                        │
                  AssessmentCardView        GlassesDisplayService     SessionLogger / SessionExporter
                  (phone card)              (.hazard HUD card)        (audit + PDF, when in a Field session)
```

A **schema** is the whole contract for one vertical: a JSON Schema, a system prompt, and an adapter that maps
its decoded payload onto a **normalized `AssessmentCard`** (tier · findings · recommended action · still-needed ·
measurements · confidence · disclaimer). The generic card view and HUD path render *any* `AssessmentCard`, so
adding a vertical never touches the renderer, the networking, or the tool.

---

## Files

```
OpenGlasses/Sources/Services/StructuredVision/
├── AssessmentCard.swift            // normalized view-model: AssessmentTier, AssessmentFinding, InstrumentReading, AssessmentCard
├── AssessmentSchema.swift          // protocol AssessmentSchema (kind, jsonSchema, systemPrompt, makeCard, backstop)
├── AssessmentSchemaRegistry.swift  // register/lookup schemas by `kind`
├── UnitNormalizer.swift            // PURE: canonical units + conversions (°F↔°C, psi↔kPa, lb↔kg, …) for instrument readings
├── StructuredVisionService.swift   // @MainActor ObservableObject: assess(kind:image:context:) → AssessmentCard
├── StructuredVisionParser.swift    // PURE per-provider response → [String:Any] JSON object (no network)
└── Schemas/
    ├── FirstAidTriageSchema.swift     // first consumer: casualty triage schema + adapter + deterministic backstop
    └── InstrumentReadingSchema.swift  // built-in "read the instrument" schema: gauges/thermometers/scales/refractometers/meters

OpenGlasses/Sources/Services/NativeTools/
└── VisionAssessTool.swift          // `vision_assess` { kind, note? } — generic, schema-parameterized

OpenGlasses/Sources/App/Views/
└── AssessmentCardView.swift        // renders any AssessmentCard (tier chip, findings, action, still-needed)
```

**Touched (small, additive):**
- [`LLMService.swift`](../../OpenGlasses/Sources/Services/LLMService.swift) — add `analyzeFrameStructured(...)`
  mirroring `analyzeFrame`'s provider switch (line 848); reuse the per-provider tool-declaration formatting in
  [`ToolCallModels.ToolDeclarations`](../../OpenGlasses/Sources/Models/ToolCallModels.swift) to declare the single
  forced tool. Add the `vision_assess` line to the tool catalog (~line 209–291).
- [`GeminiLiveSessionManager.swift`](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift)
  — add the `vision_assess` description to `buildSystemInstruction()` (~line 393–502).
- [`NativeToolRegistry.swift`](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift) — register
  `VisionAssessTool`; respect `Config.hipaaMode` like other camera/PII tools (line 226–227).
- [`FirstAidTool.swift`](../../OpenGlasses/Sources/Services/NativeTools/FirstAidTool.swift) — add a `triage`
  action that delegates to `vision_assess kind:"first_aid_triage"` so the existing first-aid intent covers it.

**Reuse (no new infrastructure):**
- **Vision transport** — extends the existing multi-provider `analyzeFrame`.
- **Camera frame** — `CameraService` periodic capture (glasses POV) + iPhone-camera fallback (same source the
  assistive loops already use).
- **HUD** — [`GlassesDisplayService`](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift):
  `showNotification(...)` / `showNavigation(_:icon:)` with the existing `.hazard` / `.warning` / `.info` icons.
- **Audit + PDF** — when invoked inside a Field session,
  [`FieldSessionService`](../../OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift) + `SessionLogger`
  + [`SessionExporter`](../../OpenGlasses/Sources/Services/FieldAssist/SessionExporter.swift). Optional, not required.
- **Result surfacing pattern** — `@Published latest` on the service observed by a SwiftUI view, exactly as
  `NavigationAssistService.lastAdvice` / `LiveCoachService.lastAdvice` do today.

---

## Model (sketch)

```swift
/// Normalized 3-level status every vertical maps onto. Semantic status colours
/// (green/amber/red) — distinct from the coral AI-attribution accent used on the card chrome.
enum AssessmentTier: String, Codable { case ok, caution, critical }

struct AssessmentFinding: Codable, Identifiable {
    let id: UUID
    let label: String          // "Suspected arterial bleeding"
    let detail: String?        // short note
    let severity: AssessmentTier
    let confidence: Double      // 0.0–1.0
    let region: [Double]?       // optional normalized [x,y,w,h] for an overlay
}

/// A numeric value read off a physical instrument in-frame — the "read the instrument" capability.
struct InstrumentReading: Codable, Identifiable {
    let id: UUID
    let quantity: String        // "temperature", "pressure", "brix", "weight", "voltage", "flow", "spo2"…
    let instrument: String?     // "probe thermometer", "manifold gauge", "refractometer", "scale", "multimeter"
    let value: Double
    let unit: String            // AS DISPLAYED on the device: "°F", "psig", "°Bx", "lb", "V"
    let canonical: Double?       // value normalized to the canonical unit for `quantity` (filled by UnitNormalizer)
    let canonicalUnit: String?
    let confidence: Double       // 0.0–1.0 — low confidence drives a re-capture prompt, never a silent guess
    let region: [Double]?        // normalized [x,y,w,h] of the display, for an overlay highlight
}

/// What the generic renderer + HUD + audit consume. Schemas produce this; nothing
/// downstream knows about any vertical's private payload type.
struct AssessmentCard: Codable {
    let kind: String                    // schema id, e.g. "first_aid_triage"
    let title: String
    let subtitle: String?
    let tier: AssessmentTier
    let summary: String                 // 1–2 sentence plain-English
    let findings: [AssessmentFinding]
    let recommendedAction: String?
    let stillNeeded: [String]           // "what to check / capture next"
    let readings: [InstrumentReading]   // "read the instrument" — first-class, see below
    let confidence: Double
    let disclaimer: String?             // e.g. advisory / not a medical device
}

@MainActor
protocol AssessmentSchema {
    var kind: String { get }
    var jsonSchema: [String: Any] { get }   // the tool input_schema / responseSchema
    var systemPrompt: String { get }
    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard
    /// Deterministic guardrail run AFTER the model — can only ESCALATE tier / force an action.
    func backstop(_ card: AssessmentCard) -> AssessmentCard
}

@MainActor
final class StructuredVisionService: ObservableObject {
    @Published private(set) var latest: AssessmentCard?
    @Published private(set) var isAnalyzing = false
    func assess(kind: String, image: Data, context: String?) async throws -> AssessmentCard
}
```

**First consumer — `FirstAidTriageSchema`.** Payload: responsiveness, breathing (yes/no/unsure), severe external
bleeding, suspected conditions, per-condition severity, recommended action (`call_emergency` / `start_cpr` /
`recovery_position` / `control_bleeding` / `monitor`), ordered steps, `still_to_check`, confidence.
**Deterministic backstop** (consistent with the `SafetySupervisor` / health-advisor "rubric backstops the LLM"
house pattern): if `breathing == no` OR `responsiveness == unresponsive` OR `severe_bleeding == true`, force
`tier = .critical` and surface "Call emergency services now" regardless of what the model returned. Every card
carries the existing first-aid **advisory disclaimer**.

---

## Read the instrument (first-class)

"Read the instrument" — glasses pull a **number** off a physical display hands-free: a probe/dial thermometer,
manifold/pressure gauge, refractometer (°Bx), scale, multimeter, flow meter, even a BP cuff or pulse-ox. It's the
highest-leverage reuse of the primitive, so it's built into the model rather than bolted on as a loose dictionary.

- **Typed readings on every card.** `AssessmentCard.readings: [InstrumentReading]` carries quantity · instrument ·
  value · **unit exactly as displayed** · confidence · optional region box. The base system-prompt fragment shared
  by *every* schema includes a standing instruction: *"read any visible instrument, gauge, label, or meter and
  report value + unit + confidence; never guess an off-screen or illegible value — lower the confidence instead."*
- **Deterministic unit normalization.** `UnitNormalizer` (pure, Phase 1) fills `canonical`/`canonicalUnit` —
  °F↔°C, psi/psig↔kPa↔bar↔inHg, lb↔kg, etc. — so range checks, HUD, and audit records are unit-stable regardless
  of what the gauge shows. No model involvement; fully unit-tested.
- **Confidence → re-capture, never a silent guess.** A reading below the schema's confidence floor doesn't quietly
  land; the adapter pushes "re-capture the &lt;quantity&gt; display" into `stillNeeded` and (inside a flow) re-prompts —
  the same posture as the [`CaptureFlowRunner`](../../OpenGlasses/Sources/Services/CaptureFlow/CaptureFlowRunner.swift)
  bad-answer re-prompt.
- **Built-in `instrument_reading` schema.** A generic, domain-free schema (second consumer, Phase 3): point at a
  display, get the number(s) and nothing else. Usable on its own via `vision_assess kind:"instrument_reading"`, or
  by Field Assist / Live Coach — no vertical required.
- **CaptureFlow killer combo (downstream PR).** A `voice_number` step in
  [`CaptureFlow`](../../OpenGlasses/Sources/Services/CaptureFlow/CaptureFlow.swift) already carries a `unit` and a
  `[min,max]` range (`Completion.range`). An instrument reading can **fill that step instead of dictation** — read →
  normalize to the step's unit → range-validate → store, with voice as the fallback. This makes hands-free
  instrument capture an opt-in property of *existing* flows; wiring is a follow-on PR, but the model and normalizer
  here are built to support it now.

---

## Phases (single PR, deterministic core first)

Per the project's plan-delivery rhythm: ship the deterministic, testable core before the risky live-API
integration; full suite + **Release** build green before the PR.

- **Phase 1 — Pure core (no network).** `AssessmentCard`, `AssessmentTier`, `AssessmentFinding`,
  `InstrumentReading`, `UnitNormalizer`, `AssessmentSchema`, `AssessmentSchemaRegistry`, and a tolerant
  JSON-object decoder (handles bare object, ```json fences, and first-`{`…last-`}` slices — the local/fallback
  path). Fully unit-tested against golden payloads. No app-shell changes.
- **Phase 2 — `analyzeFrameStructured` + parsers.** Add the provider switch to `LLMService` (Anthropic forced
  `tool_choice`, OpenAI-compatible forced function, Gemini `responseSchema`, local/appleOnDevice → free-text +
  Phase-1 tolerant decode). Factor each provider's **response → `[String:Any]`** extraction into the pure
  `StructuredVisionParser` so it's unit-tested with recorded response bodies (no live calls).
- **Phase 3 — Tools + first consumers + UI.** `StructuredVisionService`, `VisionAssessTool` (`vision_assess`),
  registry registration + system-prompt entries (both LLM + Gemini Live), `AssessmentCardView` (renders findings
  *and* readings), HUD surfacing. Two consumers: `FirstAidTriageSchema` + its backstop + the `first_aid triage`
  action, and the built-in `InstrumentReadingSchema` ("read the instrument"). Tests for tool routing, the first-aid
  adapter, the backstop escalation table, and the instrument-reading adapter.

**Sequencing note:** this plan branches from `main`, so the **domain-free `InstrumentReadingSchema`** ("read the
instrument") is the first end-to-end consumer shipped here — it depends on nothing outside the primitive. The
**first-aid triage** consumer depends on `FirstAidAssistService`, which lands with PR #82 (`feat/first-aid-assist`);
it follows as a small Phase 3 addition once #82 merges. Phases 1–2 + `instrument_reading` are independent of #82.

---

## Tests (headless, device-independent)

- Tolerant decoder: bare JSON, fenced JSON, prose-wrapped JSON, malformed → typed error.
- Per-provider parser: golden Anthropic `tool_use`, OpenAI `tool_calls.arguments`, Gemini JSON-text bodies →
  identical `[String:Any]`.
- Registry: register/lookup/unknown-kind.
- `FirstAidTriageSchema.makeCard`: representative payload → expected `AssessmentCard`.
- **Backstop table:** not-breathing / unresponsive / severe-bleeding each force `.critical` + emergency action,
  including when the model under-rates them.
- **Read the instrument:** `UnitNormalizer` round-trips and canonicalization (°F↔°C, psig↔kPa↔bar, lb↔kg);
  `InstrumentReadingSchema` golden payloads (thermometer / manifold gauge / refractometer / scale) → typed
  `InstrumentReading`s with displayed + canonical units; a below-floor confidence pushes a re-capture into
  `stillNeeded` rather than landing the value.
- `VisionAssessTool`: unknown kind → graceful message; HIPAA-mode gating; happy path via a mock LLM seam.

---

## Decisions / risks

- **Gating.** First-aid shipped as **advisory** and ungated (bystander aid). Triage-from-camera is more
  interpretive. Default: keep it advisory with the spoken disclaimer and the deterministic backstop; do **not**
  put it behind the Medical Compliance IAP (that gate is for the personal Health Vault). Revisit if it ever moves
  toward diagnosis. *(Flag for confirmation before Phase 3.)*
- **Forced-tool support across "OpenAI-compatible" providers.** groq/zai/qwen/etc. vary in function-calling
  fidelity. Mitigation: the local/fallback tolerant-decode path doubles as the universal fallback — if a forced
  tool call comes back empty, retry once as prompt-instructed JSON before failing.
- **Latency / cost.** One extra vision round-trip per assessment; `vision_assess` is user/agent-invoked, not a
  background loop, so no new always-on cost. On-device (MLX) vision is out of scope — guarded by the existing
  local-model background restriction.
- **Don't duplicate HECA.** This plan deliberately ships the *substrate*; the HECA plan should be retrofitted to
  define a `SafetyAssessmentSchema` + adapter on top of it rather than its own service. Noted there as a
  follow-up, not done here.
