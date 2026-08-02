# Plan CG — Choice Buttons, Dwell Capture & Badge Scan (interaction pack)

**Status: 🚧 P1+P2 shipped (2026-08-02); P3 device smoke deferred** — `ChoiceDetector` /
`DwellTracker` / `BadgeFieldParser` pure cores with full negative-case suites; wiring:
Direct-mode replies tap `ChoiceDetector` and present a band-selectable choice screen
(selection re-enters as the next user turn), `DwellCaptureService` runs Vision objectness
saliency over the camera publisher into the tracker (crop → Photos → spoken confirm,
default off), `scan_badge` tool OCRs a badge into the brain store with time+place and a
face-recognition handoff line. Toggles in Settings (`hudChoiceButtonsEnabled` default on,
`dwellCaptureEnabled` default off).

Three small interaction features that share one shape:
a pure, unit-testable core turning noisy input (LLM prose, detection boxes, OCR lines) into a
crisp decision, plus a thin wiring layer into surfaces we already have. One PR.

## Why bundle these

Each is too small to carry a PR alone, and all three are pure-core-first by construction —
the house style's best case. None touches the audio stack, none needs new entitlements, and
the wiring layers land behind existing seams (`HUDScreen` DSL, `CameraService` frame
publisher, `NativeToolRegistry`).

## Part 1 — HUD choice buttons (`ChoiceDetector`)

When an assistant reply *contains an enumerated choice* ("A) Riverside walk, B) Museum loop,
C) Coffee first"), the HUD should render those options as band-selectable items, not make the
user re-speak an answer the reply already spelled out.

- **`ChoiceDetector` (pure):** `String → [DetectedChoice]` (label + spoken-form + full text).
  Conservative by design — recognize only explicit enumerations (`A)`, `1.`, `- Option:` and
  the "X, Y, or Z?" tail-question form with ≥2 comma-separated noun phrases). A false button
  is worse than a missed one: every heuristic gets a negative-case test (code blocks,
  addresses, times, ordinal prose like "First, preheat the oven" must NOT match).
- **Wiring:** at the point where a Direct-mode reply is handed to TTS + HUD, run the detector;
  on a hit, append a choice screen (`HUDScreen` of `HUDItem`s, one per choice). An item's
  `action` feeds the choice's spoken form back into the conversation as the next user turn —
  the same path a transcribed utterance takes — so tools, history, and TTS all behave as if
  the user said it. Timeout/next-turn clears the screen. Gated by a settings toggle
  (default on; HUD-capable backends only).

## Part 2 — Dwell capture (`DwellTracker`)

"Hold your gaze on a thing for ~2 s to capture it" — hands-free, wake-word-free photo+note of
a specific object, not the whole scene.

- **`DwellTracker` (pure, CoreGraphics-only):** a state machine over timestamped candidate
  boxes. Box identity across frames via IoU ≥ threshold (a moving/replaced box resets the
  clock); center-region weighting stands in for gaze (the glasses point where the head
  points); dwell ≥ `dwellSeconds` in the center region → `.fired(box)`, then a cooldown so
  one lingering look can't machine-gun captures. Fully deterministic: tests drive it with
  synthetic box sequences (steady, jittering, swapped, drifting out of center).
- **Box source (wiring):** Vision objectness saliency (`VNGenerateObjectnessBasedSaliencyImageRequest`)
  on the existing `CameraService` frame publisher, throttled to ~2 fps through the Plan AT
  frame gate. No bundled detection model — saliency boxes are plenty for "the thing you're
  staring at", and the tracker doesn't care who supplies its boxes (a real detector can slot
  in later without touching the core).
- **On fire:** capture the current frame, crop to the box (+margin), save to the session
  gallery, one-line TTS confirm, optional `vision_assess` follow-up ("what is this?") behind
  the same toggle. Off by default — it's a battery spender.

## Part 3 — Badge scan (`BadgeFieldParser` + `scan_badge` tool)

Conferences: "scan this badge" → name/title/organization parsed on-device, saved as a person
record with time+place, linked to face recognition when a face is in frame.

- **`BadgeFieldParser` (pure):** `[RecognizedLine] → BadgeFields` (name, title, org,
  confidence). Heuristics over line geometry + typography from OCR output: largest/topmost
  text run → name candidate (validated against name-shape rules: 2–4 capitalized tokens, no
  digits); known role keywords (engineer, director, MD, founder…) → title; remaining
  prominent line / logo-adjacent text → org. Every heuristic has fixture tests (real-world
  badge layouts as text+box fixtures, incl. lanyard-flipped and partial-occlusion cases).
  Rejects below a confidence floor rather than guessing — same absence-honesty rule as the
  vision substrate.
- **`BadgePayloadParser` (pure):** most badges carry a QR (vCard/MeCard/URL). The payload
  is machine-authored ground truth, so it's parsed into contact fields (name, title, org,
  phone, email, website) and **wins over the OCR heuristics wherever both speak**
  (`BadgeContact.merged` — OCR fills payload gaps, never overrides it). Opaque lead-scan
  blobs and ticket ids map to nothing rather than to a guess.
- **Wiring — `scan_badge` `NativeTool`:** photo capture → `VNRecognizeTextRequest` +
  `VNDetectBarcodesRequest` (QR/Aztec/DataMatrix/microQR) on the same frame → parse +
  merge → on accept, persist a person record (name, title, org, phone/email/website when
  the QR provides them, met-at time + reverse-geocoded place) into the brain store
  (`BrainStore.shared.ingest`, native-first per house rule) and speak a one-line confirm. If `FaceRecognitionService` has a face in the same frame, offer
  `rememberFace(name:)` enrolment so the badge name and the faceprint join up. Repeat
  sightings of the same name merge into a timeline on the existing record rather than
  duplicating.
- **Privacy:** explicitly user-initiated (voice command / tool call only — never ambient),
  stored local-only, HIPAA mode leaves it enabled (it's the user's own contact capture, not
  patient data) but the privacy filter's bystander rules still apply to the saved photo.

## Phases

- **P1 — cores:** `ChoiceDetector`, `DwellTracker`, `BadgeFieldParser` + full negative-case
  test suites. Headless, zero SDK imports, no `Wearables`.
- **P2 — wiring:** reply-tap + choice screen; saliency feed + capture path; `scan_badge`
  registration + brain-store persistence + face-recognition handoff. Settings toggles.
- **P3 — device smoke (deferred):** band-select feel on real HUD, saliency quality on glasses
  optics, badge OCR under conference lighting, battery cost of the dwell loop.

## Non-goals

- No gaze *tracking* — head-center dwell is the v1 proxy; eye-tracking hardware doesn't exist
  on this device class.
- No LLM in any P1 core — all three are deterministic text/geometry code.
- No cloud OCR/detection — Vision framework only.
