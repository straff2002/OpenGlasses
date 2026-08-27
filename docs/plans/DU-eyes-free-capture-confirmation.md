# Plan DU — Eyes-Free Capture Confirmation

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review — our capture tools assume a glanceable screen; the wearer
usually doesn't have one.
**Priority:** P2 (barcode double-read) is a 10-line hardening with immediate payoff; P1 is the
substantive UX upgrade; P3 is a new capability on the same substrate.

Three capture paths take one frame and hope: `DocumentScanTool`
([DocumentScanTool.swift](../../OpenGlasses/Sources/Services/NativeTools/DocumentScanTool.swift))
does a single-shot capture + boundary crop; `BadgeScanTool`
([BadgeScanTool.swift](../../OpenGlasses/Sources/Services/NativeTools/BadgeScanTool.swift)) accepts
Vision's top candidate from a single frame; a misread barcode or a blurry page silently produces a
wrong result the wearer can't see to reject. On glasses, *audio* has to do the job a viewfinder
overlay does on a phone.

---

## Relevant seams

- `OpenGlasses/Sources/Services/NativeTools/DocumentScanTool.swift`, `BadgeScanTool.swift`,
  `BarcodeScannerTool.swift`, `DocumentRAGTool.swift` (scan output consumer)
- `OpenGlasses/Sources/Services/Interaction/DwellTracker.swift`, `DwellCaptureService.swift`
  (existing dwell-to-snap substrate — P1 composes with it, does not duplicate it)
- `OpenGlasses/Sources/Services/TextToSpeechService.swift` (audio cues; existing tones/earcons)
- `OpenGlasses/Sources/Services/Interaction/BadgeFieldParser.swift`, `BadgePayloadParser.swift` (P3)
- `OpenGlasses/Sources/Services/NativeTools/ContactsTool.swift`, `FaceRecognitionService.swift` (P3 consumers)

## Decisions and invariants

1. **Stability is a gate with hysteresis, not a threshold.** Auto-capture fires only after N
   consecutive frames (default 8) whose detected document boundary moved less than a normalized
   threshold (default 0.03, max corner displacement). On movement the counter *decays by 2* rather
   than resetting — a one-frame jitter costs two frames of progress, not all of it. Pure
   `StabilityGate`: sequence of boundary quads in, `progress / hold / fire` out.
2. **Audio narrates the gate.** Progress milestones (25/50/75%) tick via the existing earcon path;
   a regression after near-fire gets one "hold steady" cue. Cues are spoken/tonal state changes only —
   never a per-frame sound. Distinct capture modes (document / whiteboard / barcode) get distinct
   ready-cues; whiteboard mode treats "no boundary found" as expected and processes the full frame
   rather than erroring (frameless target).
3. **A code isn't read until it's read twice.** Any barcode/QR/badge-barcode acceptance requires the
   identical payload on 2 consecutive frames. Vision occasionally misreads a partially occluded code
   with full confidence; one repeat kills that class silently and costs one frame of latency.
   Applies to `BadgeScanTool`, `BarcodeScannerTool`, and P1's barcode mode uniformly.
4. **Badges are structured data, not just OCR.** Many event badges carry vCard/MECARD payloads in
   their barcode — parse those as the high-confidence source and use OCR text only to fill fields the
   payload lacks. Unescape-before-split ordering matters in vCard parsing (escaped separators shear
   values otherwise) — the parser is pure Foundation with fixture tests for exactly that.
5. **Contact capture is explicit and local.** P3 writes a contact card / person record only on the
   wearer's confirmation ("save contact?"), stores locally alongside the existing face-recognition
   person model, and never sends the badge crop anywhere the current vision-consent settings wouldn't
   already send a frame. No lookup of the *person* beyond what they printed on their own badge — the
   badge is consented public presentation; their face and web presence are not (see the privacy
   stance in Plans CO/CP).

## Phases

**P1 — Stability-gated auto-capture (pure core + tool wiring).** `StabilityGate` + `CaptureNarrator`
(gate events → cue plan, testable as data) + mode enum; wire into `DocumentScanTool` as the new
default flow (single-shot stays as the immediate-capture fallback and the no-camera path). Composes
with `DwellTracker` where dwell already triggers capture: dwell chooses *when to start*, the gate
chooses *when to fire*.

**P2 — Double-read acceptance.** `RepeatReadConfirmer` (payload equality across consecutive frames,
per-symbology) shared by the three barcode consumers; fixture tests with a mid-sequence misread.

**P3 — Badge contact capture.** vCard/MECARD parser (pure, fixture-tested) + merge with OCR fields
(`preferred()` precedence: barcode > OCR; never average) + confirm-and-save flow into Contacts and
the person timeline. `BadgeScanTool` output gains the structured record; existing badge-OCR behavior
unchanged when no barcode is present.
