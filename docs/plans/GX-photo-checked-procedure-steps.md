# Plan GX — Photo-Checked Procedure Steps

**Status:** 📝 Drafted 2026-10-02 — nothing implemented.
**Track:** Field Assist (B2B). One of three gaps found when Field Assist was compared feature by
feature against industrial remote-assistance products (with [GY](GY-procedure-from-narrated-recording.md)
and [GZ](GZ-expert-annotations.md)).
**Related:** Plan [F](F-field-assist.md) (procedures), Plan [GB](GB-field-test-round-3.md) P3 (retest
gate, `SpokenReading`), Plan [AD](structured-vision-assessment.md) (`instrument_reading`), Plan
[U](U-structured-capture-flows.md) (capture-flow camera bindings), Plan [EL](EL-equipment-identity.md)
(model matching), Plan [EM](EM-work-record-and-parts.md) (work record, `PartsVerifier`), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (job evidence and close), Plan [GV](GV-phone-camera-tools.md)
(phone camera when no glasses), Plan [GE](GE-automatic-offline-handoff.md) (offline tool set),
Plan [CP](CP-outbound-frame-privacy.md) / W04.1 (privacy chokepoint and roster).

---

## Trigger

A procedure today trusts what the technician says. "Manifold pressure is 3.6" is recorded as the
technician's report (`SpokenReading`, Plan GB P3), which is right — but a reviewer has nothing to
look at, and a misheard or misread number is indistinguishable from a correct one. Remote-assist
products in this market let a procedure step ask for camera evidence that it was done. Field
Assist has every piece of that (camera stills, on-device OCR, a structured instrument reader, a job
record with photos) except the step that asks for it.

**Not the goal:** continuous per-frame recognition of what the technician is doing. The glasses
stream at a low frame rate, and a camera that runs all job long costs battery and heat the glasses
cannot spare. This plan is **spot-check evidence at steps the procedure author chose**.

## Outcome

- A procedure step may declare a **check**: read a value and test it against a range, read a
  label/serial/part number and match it, decode a barcode/QR, or confirm a visual condition.
- Arriving at the step, the technician is asked for the photo ("Photograph the manifold gauge").
  The app captures, assesses and records **passed / failed / couldn't tell**, with the evidence
  photo filed on the job and what was read.
- Every verdict is **spoken with what was read** — "I read 3.6 inches of water, inside 3.5 to 3.8.
  Check passed." There is no silent pass, and "couldn't tell" is never turned into a pass.
- The technician can **always override** with a spoken reason; the reason, the overridden verdict
  and the photo are all recorded. An AI verdict never, on its own, either blocks or clears a step
  the author marked safety-critical — the technician's confirmation is what moves past it.
- Text, number and code checks run **on the phone** (on-device Vision), so they work without signal
  and with the phone locked in a pocket. Visual-condition checks and analogue gauges need a cloud
  vision model; offline they record the photo, say so, and fall back to the technician's report.
- Old procedures load and run exactly as today; a malformed check is rejected at import.

## What exists today (verified against main @ build 447)

- **Procedure model.** `Services/FieldAssist/Procedure.swift` — `Procedure.Step` has `id`, `title`,
  `instruction`, `expected_input`, `safety_note`, `calc_ref`, `citations`, `branches`,
  `default_next`, `terminal`, `outcome`, `requires_confirmation`. `Step.init(from:)` is hand-written
  with `decodeIfPresent` for every optional field, and `JSONDecoder` ignores unknown keys — so an
  added optional `check` key is invisible to old procedures. The top-level `Procedure` uses the
  synthesized decoder, so `safety_notes` is a **required** key there.
- **Runner and retest gate.** `ProcedureRunner.swift` drives the graph, logs `procedureStarted` /
  `procedureStep` / `procedureCompleted` to `SessionLogger`, and refuses `advance` on a terminal step
  with `requires_confirmation` (`RunnerError.awaitingConfirmation`, Plan GB P3). `promptContext()`
  writes the active step into the system prompt. `FieldSessionService.startProcedure` /
  `advanceProcedure` / `completeProcedure` own it; `VerificationRequirement`
  (`TaskClosePolicy.swift`) is the open "Verify: …" item.
- **Tool.** `NativeTools/ProcedureRunnerTool.swift` (`procedure_runner`: list, start, next,
  previous, repeat, status, complete). Classified `.local` in `Offline/Handoff/OfflineToolPolicy.swift`.
- **Spoken readings.** `SpokenReading.swift` + `FieldSessionService.recordReading` /
  `correctReading` — a reading is the technician's report, never "observed"; corrections supersede.
- **Validator.** `Vault/VaultValidator.swift` — `validateProcedureGraph(_:)` (entry, targets, dead
  ends, reachable terminal), run by `validate(directory:)` before `VaultImporter` installs a pack.
  **But** `FieldAssist/ProcedureLibrary.swift` loads every decodable JSON from the bundle and the
  `Documents/Vaults/{id}/` overlay **without** running the graph validator.
- **On-device reading.** `Accessibility/OCRService.swift` (Vision `VNRecognizeTextRequest`, text +
  normalized boxes) used by `equipment_lookup`, `manual_lookup`, `reading_assist` and others;
  `NativeTools/BarcodeScannerTool.swift` runs `VNDetectBarcodesRequest` inline.
  **Correction to the brief:** `EquipmentRecognition.swift` is not OCR — it is the pure matcher of
  a stated model number against the vault's model index (`exact` / `alias` / `near` within edit
  distance 2, `normalised(_:)`). It is the right matcher for "is this the model on the job"; OCR is
  `OCRService`.
- **Cloud structured reading.** `StructuredVision/` — `InstrumentReadingSchema` (`instrument_reading`)
  returns typed `InstrumentReading`s (value, unit as displayed, confidence, region);
  `applyingReadingPolicy` converts low confidence to a re-capture; `InstrumentPlausibility` rejects
  impossible values; `UnitNormalizer.convert`; `AssessmentCertainty` / `ImageQualityProbe` band the
  certainty. The call is `LLMService.analyzeFrameStructured` (forced schema per provider).
  `vision_assess` is `.needsNetwork` offline.
- **Part numbers.** `PartsVerifier.swift` — normalise + vault parts table + exact manual token.
- **Evidence.** `FieldSessionService.attachPhoto(_:caption:origin:filterWasOn:)` files a photo into
  the session's `photos/`, `JobMediaItem` (origins `photo_log`, `capture`, `phone_camera`, …), and
  `WorkTask.Evidence` (`readings`, `photos`, `pagesVerified`, …). `JobPhotoEvidenceService` is the
  chokepoint for pixels the phone already holds. `SessionExporter` folds the log into the JSON audit
  and the PDF work order.
- **Audit.** The job record is `SessionLogger`'s append-only `log.jsonl`. **Correction to the
  brief:** `AuditChain.swift` is the hash-chained, content-free compliance log written only by
  `HIPAAComplianceService` (`AuditEvent` carries classes, counts and digests — never content). A
  check belongs in the session log; the compliance chain gets at most a content-free event.
- **Privacy.** Still readers call `CameraService.filteredStill(for:source:)`;
  `OutboundFrameConsumer` is the roster `OutboundFrameConsumerTests` enforces. A still a tool keeps
  on the wearer's instruction is `.toolPhotoCapture` — the parking sign (Plan GH) is the precedent
  for "filter, then OCR, then keep the same filtered still".
- **Phone camera.** `Camera/PhoneCapturePolicy.swift` (Plan GV) routes a tool's capture to the
  on-screen phone camera when no glasses are connected; `CameraToolDescriptionTests` requires every
  tool file that reaches a still to be in its table.

## Design

### Schema — `Procedure.Step.check` (optional)

```json
"check": {
  "kind": "reading",
  "prompt": "Photograph the manifold gauge on the gas valve outlet.",
  "quantity": "manifold pressure", "unit": "inWC", "range": [3.5, 3.8],
  "display": "digital",
  "safety_critical": true
}
```

| `kind` | Required fields | Assessed by |
|---|---|---|
| `reading` | `quantity`, `unit`, `range` [low, high]; `display` `digital` (default) or `analog` | digital: on-device OCR number extraction, cloud `instrument_reading` when online as a second read; analog: cloud only |
| `text_match` | `expected` (literal) or `expected_from` (`job.equipment_model`); `match` `exact` / `normalised` (default) / `near` | on-device OCR + `EquipmentRecognition.normalised` / `distance`, or `PartsVerifier.normalise` for a part number |
| `code` | `symbology` `qr` / `barcode`; optional `expected` | on-device `VNDetectBarcodesRequest` |
| `condition` | `condition` (≤ 200 chars, phrased as a yes/no statement) | cloud vision, new `step_condition` schema |

Common optional fields: `prompt` (what to photograph; defaults from the kind), `safety_critical`
(default **true when the step has a `safety_note`**, else false), `required` (default true — the
step needs *an* outcome before `next`).

**Backward compatibility.** `check` is decoded with `decodeIfPresent` in `Step.init(from:)` and left
out when encoding when nil, as `requires_confirmation` is. Every bundled and example procedure
decodes and encodes byte-identically (test). **Validation** (`ProcedureCheckValidator`, called from
`VaultValidator.validateProcedureGraph` so the importer and GY share it): unknown `kind`; missing
required field; `range` not two numbers with low ≤ high; a `unit` `UnitNormalizer` does not know
(warning, not issue); empty `expected`; `expected_from` not in the allowed set; `condition` empty or
over length; `match: near` on a string shorter than `EquipmentRecognition.minimumNearLength`.
`ProcedureLibrary` additionally skips (and logs) a procedure whose check fails validation, so an
overlay hand-edit cannot put a malformed check in front of a technician.

**Old app builds** ignore the key and run the step unchecked. A vault pack that uses checks sets
`minAppBuild` (`VaultPack.swift` already refuses a pack that needs a newer app); a hand-copied folder
cannot be protected and the vault guide says so.

### Pure core

- `ProcedureCheck` (Codable model above) + `ProcedureCheckValidator`.
- `StepCheckEvaluator` — pure: `(check, reading input) → Verdict`. Inputs are values, not images:
  `OCRService.Result`, decoded barcode payloads, `InstrumentReading`s, a `StepConditionAnswer`, the
  job's equipment model. `Verdict` = `.passed(observed:)`, `.failed(observed:expected:)`,
  `.couldNotTell(reason:)`. Rules: an OCR number is accepted only when exactly one numeric token
  near the unit (or the only numeric token) parses; two candidate numbers → couldn't tell, never the
  first; a cloud reading below the confidence floor or failing `InstrumentPlausibility` → couldn't
  tell; units converted with `UnitNormalizer`, incompatible → couldn't tell; when on-device and cloud
  both read and disagree beyond the display's last digit → couldn't tell.
- `StepCheckOutcome` — what is recorded: verdict, `source` (`onDevice` / `cloud` / `technician`),
  photo file name, observed text/value, `overriddenBy` (spoken reason + prior verdict),
  `assessedLater` flag.
- `StepCheckGate` — pure decision for the runner: a step with a `required` check needs a recorded
  outcome before `next`; for `safety_critical` checks a `.passed` from the camera still needs the
  technician's "yes" (one word, read-back of the value), and a `.failed` or `.couldNotTell` needs an
  override reason or a re-take. Non-critical checks advance on any recorded outcome.
- `StepCheckPhrasing` — the spoken lines (contract-tested): passed, failed, couldn't tell (with why:
  blurry, two numbers, no signal), offline, override recorded. Never names plan letters.

### Runner and tool

- `ProcedureRunner.advance` throws a new `RunnerError.checkOutstanding(prompt)` when
  `StepCheckGate` says so — the same pattern as `awaitingConfirmation`. `promptContext()` adds one
  line for a checked step: what to photograph, and "call procedure_runner action 'check'".
- `procedure_runner` gains `check` (capture + assess the current step's check), `override`
  (`reason` required, non-empty after trimming), and `confirmed` is reused for the safety-critical
  read-back. The tool is added to `PhoneCapturePolicy` as **ask on phone** (no glasses → the user
  frames the shot on the phone, Plan GV) and to `CameraToolDescriptionTests`' table.
- A **technician's spoken value** at a reading step (no photo, or couldn't tell) is recorded through
  `recordReading` as today *and* evaluated against the range, giving `source: technician` — labelled
  in the record as reported, not camera-checked.

### Capture, privacy, and where pixels go

- One still per check, via `filteredStill(for: .toolPhotoCapture, source: .photoOnly)` (a fresh
  shutter photo; a cached stream frame is too small for a gauge face). `.unavailable` → the spoken
  "couldn't prepare the picture" line and the technician's report path; never the raw frame.
- The **same filtered still** is OCR'd, decoded, sent to the cloud (when needed) and filed — the
  parking-sign precedent. The face blur does not touch display or label text, and one still for all
  purposes means the evidence photo is exactly what was assessed.
- New roster entry `procedureStepCheck` (owner `StepCheckService`, tap `filteredStill`, mechanism
  `chokepoint`, scope `.toolPhotoCapture`).
- Filed through `attachPhoto(…, origin: .stepCheck)` (new `JobMediaItem.Origin`), attached to the
  procedure's task evidence, so the FO close-out selection decides whether it reaches the customer.

### Online, offline, locked, backgrounded

| Check | Online | Offline (GE) | Phone locked / app backgrounded |
|---|---|---|---|
| reading (digital) | on-device OCR, cloud second read | on-device OCR only | on-device OCR (Vision runs backgrounded) |
| reading (analog) | cloud `instrument_reading` | couldn't tell → technician reads it aloud | cloud if online, else as offline |
| text_match / code | on-device | on-device | on-device |
| condition | cloud `step_condition` | photo filed, technician confirms by voice; assessed later | cloud if online |

No check uses an on-device MLX model (it cannot run backgrounded). Under Medical Local Only, cloud
checks behave as offline. "Assessed later" runs from the offline queue (Plan T) when signal returns;
it **adds** a line to the record ("assessed after the step: passed/failed") and, on a fail, flags the
step on the Job tab — it never rewrites the outcome recorded at the time.

### Record and export

- New `SessionLogger.Event.Kind.stepCheck` (`step_check`) — payload: procedure/step id, kind,
  verdict, source, observed value/text, expected/range, photo name, override reason. Content stays
  in the session log; with HIPAA mode on, `HIPAAComplianceService` gets only a content-free event.
- `SessionExporter`: a "Checks" block per procedure run in the JSON and PDF — "Manifold pressure
  3.6 inWC, range 3.5–3.8 — passed (read from photo)", "Flame — couldn't tell (no signal);
  technician confirmed: 'blue, no lifting'". Overrides print the reason and the verdict overridden.
- Meta Display HUD (where present): one `showNotification` line with the verdict; no images.

## Phases (one PR each)

**P0 — Schema, validator, evaluator (headless).** `ProcedureCheck`, `ProcedureCheckValidator` wired
into `validateProcedureGraph`, `StepCheckEvaluator`, `StepCheckOutcome`, `StepCheckGate`,
`StepCheckPhrasing`; the `ProcedureLibrary` skip. Tests: `ProcedureCheckCodingTests` (every bundled
procedure round-trips unchanged; check encodes only when present), `ProcedureCheckValidatorTests`
(each malformed shape is an issue; unknown unit is a warning), `StepCheckEvaluatorTests` (OCR
fixtures: one number, two numbers, unit conversion, near-match, wrong code, low confidence,
implausible, on-device vs cloud disagreement), `StepCheckGateTests`, `StepCheckPhrasingTests`,
`ProcedureLibraryTests` (malformed check skipped).

**P1 — Runner, tool, record.** `RunnerError.checkOutstanding`, `procedure_runner` `check` /
`override`, `StepCheckService` (injected still provider, OCR, barcode, structured-vision and clock
seams), `step_condition` schema registered in `StructuredVisionService`, `stepCheck` log event,
`JobMediaItem.Origin.stepCheck`, roster entry, `PhoneCapturePolicy` row, exporter block. Tests:
`StepCheckServiceTests` (fake filtered still: `.unavailable` never falls back to raw; the filed photo
is the assessed one), `ProcedureRunnerTests` additions, `ProcedureRunnerToolTests` (override needs a
reason; safety-critical pass needs `confirmed`), `OutboundFrameConsumerTests`,
`CameraToolDescriptionTests`, `SessionExporterTests` (checks block, override line), one bundled
procedure gains a check (refrigeration `system_startup`) as the worked example.

**P2 — Offline and assess-later.** `OfflineToolPolicy` note for `procedure_runner` (`.local`, with
cloud checks degraded), offline-queue op for deferred condition checks, Job-tab flag on a late fail.
Tests: `StepCheckOfflineTests` (no signal → technician path; later fail flags, never rewrites).

**P3 — Device checks (owed).** Digital multimeter and manometer at arm's length on the glasses and
on the phone; an analogue gauge online and offline; a nameplate `text_match`; a QR asset tag; a
flame `condition` check; phone locked in a pocket; Meta Display HUD line; battery cost of a
ten-check procedure.

## Risks

- **Seven-segment displays** read poorly with general OCR. The evaluator prefers "couldn't tell"
  over a guess; P3 measures how often, and a digital-display recogniser is a follow-up, not v1.
- **Authors over-using checks** turns a job into a photo shoot. The vault guide recommends checks
  only where a reviewer would want the photo; the validator warns above five checks per procedure.
- **Over-trust.** A "passed" can be read as certification. The record says "read from photo" and
  the source, and the PDF footnote says checks are evidence, not inspection.

## Open decisions for Greig

1. **Safety-critical default.** Infer `safety_critical` from a step's `safety_note` (recommended),
   or require authors to set it explicitly.
2. **Second read for digital readings.** When online, also run the cloud reader and call
   disagreement "couldn't tell" (recommended), or trust on-device OCR alone when it is unambiguous
   (cheaper, no egress).
3. **Do checks choose branches?** Recommended **no** in v1: a verdict gates `next` and is evidence;
   the technician still picks the branch. Auto-routing a fail to an `on_fail` branch is a later step.
4. **Assess later when signal returns.** Recommended yes, recorded as a separate line, never
   rewriting the step's outcome.
5. **Does a passed check satisfy the GB retest confirmation on a last step?** Recommended **no** —
   the technician's "yes" is still the confirmation; the photo is the evidence attached to it.
6. **Evidence photo to the customer by default?** Recommended: selected by default at close like
   `photo_log` photos, deselectable.

## Out of scope

Continuous per-frame step recognition; detecting that a step was done without being asked; video
checks; checks that measure geometry (torque marks, gaps) from a photo; checks in capture flows
(Plan U keeps its own bindings); an in-app editor for checks (authors edit the JSON; GY's review
surface edits check text only); certifying anything.
