# Plan U — Structured Capture-Flow / Action-Form Schema

**Source pattern:** The trainable-flow / action-form-builder / generic-capture-flow ideas from our idea-source repo `~/Code/qaeros` (`plans/327-trainable-web-flows.md`, `plans/366-workshop-actionform-builder.md`, `plans/552-generic-cross-pack-capture-flows.md`), plus geofenced preconditions from `plans/547` (phase E). Concept only; clean-room Swift, reframed for voice + camera instead of a browser/desktop form.

**Strategic fit:** Turns Field Assist from a set of ad-hoc step tools into a **typed, declarative capture schema**. Today `ProcedureRunner` ([Sources/Services/FieldAssist/ProcedureRunner.swift](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureRunner.swift)) walks free-form steps; there's no notion of a step *capturing a typed value* (a reading, an enum choice, a barcode, a photo bound to a field) or *validating completion criteria*. This plan adds a `CaptureFlow` schema where each step declares its prompt, its input binding (voice / enum-by-voice / camera-OCR / barcode / photo), its completion criterion, and optional geofenced preconditions — so one inspection/work-order template produces a structured, validated record across asset types. It's the single highest-leverage field upgrade and it composes directly with the offline queue in [Plan T](T-offline-field-queue-and-sync.md).

**Effort:** ~1–1.5 weeks.

---

## The gap (verified)

- `Procedure.swift` / `ProcedureLibrary.swift` / `ProcedureRunner.swift` (existing) model **steps as narration + manual advance** — good for "do this, then say done", but the step doesn't *collect* a typed value or *check* it.
- Capture today is side-channel: `PhotoLogTool` attaches a photo, `EquipmentLookupTool` OCRs a label, `scan_code` reads a barcode — but none of these are *bound to a field in the current step*, so the output isn't a structured record, it's a transcript + loose attachments.
- No field reuse: a refrigeration inspection and an IT inspection can't share a "location + condition photo + severity" core because there's no shared field schema (qaeros's *field binding* idea).

---

## Files

```
Sources/Services/CaptureFlow/
├── CaptureFlow.swift          // Flow + FlowStep + FieldBinding + Completion models
├── CaptureFlowLibrary.swift   // loads flows from vault/flows/*.json (alongside procedures/)
├── CaptureFlowRunner.swift    // drives a flow: prompt → capture → validate → next; emits CaptureRecord
├── FieldResolver.swift        // maps a captured input to a typed field value; binds across asset types
└── CaptureRecord.swift        // the structured output (per-field values + provenance)
```

- New: `Sources/Services/NativeTools/CaptureFlowTool.swift` (`NativeTool`, name `capture_flow`) — `start | answer | skip | back | status | finish`. Registered in `NativeToolRegistry.init()`; system-prompt description added to **both** `LLMService.swift` and `GeminiLiveSessionManager.swift` (CLAUDE.md step 3).
- Touch: `ProcedureRunner` — a procedure step may *embed* a capture step (procedures and flows interoperate; a flow is a procedure whose steps have bindings).
- Touch: `GeofenceTool` — expose a query the runner uses for `precondition: insideRegion(...)`.
- New: `Sources/App/Views/CaptureFlowAuthorView.swift` — minimal in-app editor (qaeros's no-code builder, slimmed): add steps, pick binding type, set completion criterion. Optional for v1 (JSON authoring works without it).

---

## Schema

A flow is a JSON file in `vault/flows/` (mirrors how procedures live in `vault/procedures/`, per [Plan F](F-field-assist.md)):

```json
{
  "id": "asset_inspection_v1",
  "title": "Asset Inspection",
  "applies_to": ["refrigeration", "it_network", "electrical"],
  "steps": [
    { "field": "asset_id", "prompt": "Scan the asset barcode or say the code.",
      "binding": { "type": "barcode_or_voice" }, "required": true },
    { "field": "location", "prompt": "Where is this unit?",
      "binding": { "type": "voice" }, "completion": { "min_len": 2 } },
    { "field": "gauge_psi", "prompt": "Read the suction gauge.",
      "binding": { "type": "voice_number", "unit": "psig" },
      "completion": { "range": [0, 600] } },
    { "field": "condition_photo", "prompt": "Show me the nameplate.",
      "binding": { "type": "photo" }, "required": true },
    { "field": "severity", "prompt": "Severity? Minor, major, or critical.",
      "binding": { "type": "enum", "options": ["minor","major","critical"] } }
  ],
  "preconditions": [
    { "type": "inside_region", "region": "site_boundary", "message": "You're outside the work zone." }
  ]
}
```

### Binding types

| `type` | Captured via | Notes |
|---|---|---|
| `voice` / `voice_number` | existing transcription | `voice_number` parses + range-checks |
| `enum` | enum-by-voice | model maps the spoken phrase to an option (few-shot), like qaeros's decision node |
| `barcode_or_voice` | `scan_code` then fall back to voice | auto-fills `asset_id` |
| `photo` | `CapturePhotoTool` | stored as a file ref + provenance, bound to the field |
| `ocr_text` | `EquipmentLookupTool` OCR | reads a label into the field |

`FieldResolver` is what makes a flow authored for one pack work from another: if `asset_inspection_v1.applies_to` includes the active vault and the bound fields exist, the same flow runs — qaeros's *field binding* idea, reduced to "shared field names across packs".

---

## Output: `CaptureRecord`

```swift
struct CapturedField: Codable { let field: String; let value: CaptureValue; let provenance: Provenance }
struct CaptureRecord: Codable {
    let flowId: String; let sessionId: String; let assetId: String?
    var fields: [CapturedField]; let startedAt: Date; var finishedAt: Date?
}
// Provenance = how it was captured (voice / barcode / photo path / ocr) + timestamp + GPS
```

`CaptureRecord` is a first-class durable object — it's exactly what [Plan T](T-offline-field-queue-and-sync.md)'s `OfflineQueue` persists and syncs, and it slots into the existing `SessionExporter` audit JSON.

---

## Flow (hands-free)

```
1. User: "Start asset inspection for unit 47B."
2. CaptureFlowTool.start(flow="asset_inspection_v1") → CaptureFlowRunner checks preconditions
   (inside_region via GeofenceTool) → if outside: "You're outside the work zone — proceed anyway?"
3. Runner → HUD + TTS: "Step 1 of 5: Scan the asset barcode or say the code."
   → scan_code fills asset_id="47B" (or voice fallback)
4. "Step 3: Read the suction gauge." → "118" → voice_number, range-checked → gauge_psi=118 psig
5. "Step 4: Show me the nameplate." → CapturePhotoTool → photo bound to condition_photo
6. "Severity? Minor, major, or critical." → "major" → enum resolved
7. finish → CaptureRecord emitted → enqueued (Plan T) → folded into session audit (Plan F)
```

HUD shows `Step n/N` + the current prompt via `GlassesDisplayService.showNotification` ([:122](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift)); a failed completion check re-prompts ("That's out of range — read it again").

---

## Build order

1. `CaptureFlow`/`FlowStep`/`FieldBinding`/`Completion` models + JSON loader (`CaptureFlowLibrary`).
2. `CaptureValue` + `CaptureRecord` + provenance.
3. `CaptureFlowRunner` core: prompt → capture (voice first) → completion check → next; `voice` + `voice_number` + `enum` bindings.
4. `CaptureFlowTool` + registry + system-prompt wiring (both services).
5. Camera bindings: `barcode_or_voice` (scan_code), `photo` (CapturePhotoTool), `ocr_text` (EquipmentLookupTool).
6. `preconditions` via `GeofenceTool` (inside_region) — spoken/HUD gate.
7. `FieldResolver` cross-pack binding + a shared `asset_inspection_v1` flow that runs under refrigeration + IT vaults.
8. (optional) `CaptureFlowAuthorView` no-code editor.

---

## Tests
- `CaptureFlowLibrary` — loads/validates flow JSON; rejects malformed bindings.
- `CaptureFlowRunner` — step advance/back/skip; `voice_number` range reject + re-prompt; `enum` phrase→option mapping; required-field enforcement at `finish`.
- `FieldResolver` — same flow runs under two vaults when fields exist; refuses when they don't.
- Precondition — outside-region → gated; inside → silent pass.
- Output — `CaptureRecord` round-trips through the export JSON; photo provenance preserved.

---

## Open questions / decisions needed
- **Enum-by-voice resolution:** on-device parse (fast, offline) or LLM few-shot (robust to phrasing)? *Recommendation: deterministic match first, LLM fallback only on ambiguity — keeps it offline-capable.*
- **Author UI in v1?** JSON authoring is enough to ship; the no-code editor is a fast-follow. *Recommendation: ship JSON-authored flows + 2 hero flows (refrigeration inspection, IT site survey); defer the editor.*
- **Procedure vs flow split:** keep them separate types or unify (flow = procedure with bindings)? *Recommendation: unify the runner so a procedure step can carry an optional binding; avoids two parallel engines.*
- **Validation severity:** hard-block on a failed completion check, or warn-and-allow override? *Recommendation: warn + spoken override for soft checks, hard-block only `required` fields.*

---

## Dependencies / prereqs
- `Procedure.swift` / `ProcedureLibrary.swift` / `ProcedureRunner.swift` (existing) — the engine this generalizes; flows live beside procedures in the vault.
- `scan_code` (BarcodeScanner), `CapturePhotoTool`, `EquipmentLookupTool` OCR (existing) — the camera bindings.
- `GeofenceTool` (existing) — preconditions.
- [GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift) (existing) — step prompts on the HUD.
- [Plan T](T-offline-field-queue-and-sync.md) — persists/sync `CaptureRecord`; build U's record as T's queued payload.
- [Plan F](F-field-assist.md) — vault/session/audit foundation; `CaptureRecord` folds into the session export.

---

## Why this matters specifically for you
This is what makes Field Assist a *product* rather than a guided chat: a technician's session comes out the other end as a structured, validated, audit-ready record — typed readings, an enum severity, a nameplate photo bound to the right field, all with provenance — instead of a transcript with loose attachments. One template works across packs, so every new vertical (electrical, automotive) gets inspection/work-order capture for free. It's the field analogue of qaeros's action-form builder, but the input device is a voice and a camera on someone's face.
