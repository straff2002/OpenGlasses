# Plan CB — Live-Session Vision Detail & Async Delivery

**Status:** 📋 Planned (2026-07-30)

## Problem

Three related gaps, all in the live-voice modes (Gemini Live / OpenAI Realtime), all with the
same root cause: **the live session has exactly one image path and no text path.**

1. **Detail is destroyed before inference starts.** The only frame path into a live session is
   `FrameThrottler` → `GeminiLiveService.sendVideoFrame(image:)`, encoded at
   `Config.geminiLiveVideoJPEGQuality = 0.5`. A stream and a reading task want opposite things:
   the stream is throttled to roughly a frame a second and must stay small; resolving fine print
   needs one sharp frame and does not care about frame rate. No single setting satisfies both.
   Hold a receipt, a medication label, or a serial-number plate up to the glasses and the model
   gets the large text and nothing else — printed line items are a few pixels tall at that size,
   and JPEG discards thin strokes first.

   OpenGlasses does have a partial mitigation the live model cannot use well: a native tool
   (`vision_assess`, `instrument_reading`, `read_text`) can call `CameraService.capturePhoto()`
   itself and run a *second* model over the sharp still. That works, but it costs an extra round
   trip and the live model never sees the detail — it only hears another model's summary of it,
   so it cannot be asked a follow-up about the same image.

2. **Nothing can be put into a live model's mouth.** `GeminiLiveService` exposes `sendAudio`,
   `sendVideoFrame`, and `sendToolResponse` — there is no way to hand the session text and have
   it speak. Anything asynchronous (a proactive alert, a deferred agent answer, a face
   announcement) has to go out over `TextToSpeechService` *on top of* a session that may be
   mid-utterance, in a different voice, with two audio producers contending for the route.

3. **A long tool call announces itself in a robot voice.** `NativeToolRouter` fires
   `onLongRunningUpdate?("Still working on that...")` every 10 s — a fixed string, spoken
   verbatim. It reads as a status message rather than as part of the conversation the assistant
   is already having.

## Approach

One new primitive, three consumers. Everything below the service edge is pure and headless-testable.

### The primitive: mid-turn injection

Add to the live-session services a way to inject content and *close the turn*:

```swift
func sendText(_ text: String, completeTurn: Bool)          // GeminiLiveService
func sendImage(_ jpeg: Data, prompt: String?, completeTurn: Bool)
```

The `completeTurn` flag is the whole point and the easiest thing to get wrong. On the Gemini wire,
`clientContent` without `turnComplete: true` only **appends to context** — the model accepts the
text and generates nothing. The failure is silent and looks like a delivery bug: the user hears an
acknowledgement, then nothing, re-asks, and each re-ask spawns another duplicate task. The same
trap exists on the Realtime wire, where `conversation.item.create` must be followed by
`response.create` to produce a turn.

**Latent instance already in-tree:** `OpenAIRealtimeService.sendImageFrame` (line ~215) sends
`conversation.item.create` with no following `response.create`. It currently has **zero callers**,
so it is dead rather than broken — but it is the exact shape of the bug, and it must not become
the template when someone wires it up. Fix it as part of P1.

### Consumer 1 — `look_closely`

A tool the live model calls when the answer depends on detail it cannot resolve. It captures one
full-resolution still at quality ~0.95 (`CameraService.capturePhoto()` on glasses,
`PhoneCameraSource.capturePhoto()` in phone mode — both already exist and both already return
`Data`), injects it into the session's own view, and returns text.

Two constraints drive the shape:

- **Live function results carry text only.** The tool cannot return the image. It returns an
  *instruction* — "a sharp full-resolution image has just arrived in your view; read the detail
  from it" — and the image arrives separately via `sendImage`. Ordering matters: inject first,
  then answer the function call.
- **The capture provider must outlive the session.** The obvious wiring — write the provider onto
  the tool router — fails: the router is built in `startSession()` and dropped on `stopSession()`,
  while camera attach happens when the view appears. Assigning directly hits a nil router and
  silently does nothing, and the tool then reports "no camera is streaming" forever, which reads
  as a hardware fault rather than a wiring mistake. The provider belongs on the long-lived
  session manager (`GeminiLiveSessionManager` / `AppState`), which the router reads through.
- **Bounded.** A capture that never arrives would strand the tool call, so the capture races a
  ~6 s timeout and returns a plain "couldn't get a sharp frame" on expiry.

Power interaction: a full-res still is a real cost spike. Gate frequency under Plan BV — in
`.reserve` posture, serve the latest throttled frame and say so rather than firing the camera.

### Consumer 2 — sensor zoom (phone mode)

Reading a distant sign is a losing fight against resolution, and zooming at the sensor wins it
outright: detail is *captured* larger rather than enlarged afterwards, so both the preview and the
frames the model sees improve — they come off the same `AVCaptureSession`.
`PhoneCameraView` already draws from `AVCaptureVideoPreviewLayer`, so this is `videoZoomFactor`
plus a magnification gesture.

Two details worth writing down: cap at 8× (past roughly there the wide sensor is upscaling, which
spends bytes without adding detail — the opposite of the point) while respecting a lower
`videoMaxZoomFactor`; and a magnification gesture reports scale against *its own start*, not the
last committed value, so capture the zoom at gesture start and multiply, rather than accumulating.
Show the readout only above ~1.05× so a label isn't sitting on the scene at rest.

Glasses mode is untouched — 720×1280 is the SDK ceiling, not a setting.

### Consumer 3 — conversational async delivery

Replace the fixed `"Still working on that..."` string, and route deferred results through the model
instead of over it.

Three rules, each earned from a specific failure mode:

1. **The acknowledgement is an instruction, not a sentence.** Injecting a fixed string gets it
   spoken verbatim and sounds like a status readout. Injecting *"acknowledge in your own words
   that you're looking this up"* produces cover that fits the conversation already in progress.
2. **The instruction must forbid answering from memory.** A model handed "task started" with no
   further constraint will confabulate the answer — invent the calendar, guess the number. The
   injected instruction says so explicitly.
3. **The late result is framed as the answer to what was asked.** Delivered as a bare
   notification, it gets announced as fresh news seconds after the question, which is disorienting.
   It carries its question with it.

In Direct mode (no live session) the existing TTS path stays, but the phrasing comes from the same
`AsyncDeliveryPhrasing` type so the two modes don't drift.

## Phases

### P1 / PR1 — Injection primitive + phrasing core 🟢
- `sendText`/`sendImage` with `completeTurn` on `GeminiLiveService` and `OpenAIRealtimeService`;
  fix the missing `response.create` in `sendImageFrame`.
- Pure `LiveInjectionEnvelope` — builds the exact wire dictionaries for both providers, so the
  `turnComplete` / `response.create` contract is asserted in tests rather than trusted.
- Pure `AsyncDeliveryPhrasing` — acknowledgement instruction (with the no-memory clause) and
  result framing (question carried alongside answer); deterministic Direct-mode fallback strings.
- Pure `LookCloselyPolicy` — decides capture-vs-latest-frame from power posture and a
  minimum-interval floor; returns the instruction text.
- Tests: envelope shape for both providers incl. the turn-completion flag present/absent,
  append-only vs generate distinction asserted explicitly, phrasing invariants (no verbatim status
  strings, no-memory clause always present, result always carries its question), policy gating at
  each `PowerPosture`, injection-then-respond ordering.

### P2 / PR2 — `look_closely` tool + wiring
- `LookCloselyTool` implementing `NativeTool`; registered in `NativeToolRegistry`; description
  written for the system-prompt generator (`SystemPromptBuilder`) so both Direct and Live prompts
  learn it exists and *when* to reach for it.
- Capture provider hung on the long-lived session manager, read through by the tool router;
  6 s timeout; glasses and phone capture sources both wired.
- `onLongRunningUpdate` and the deferred-agent-result path switched to injection when a live
  session is active, TTS otherwise.
- Device-pending: whether raising `geminiLiveVideoJPEGQuality` for the *streaming* path is worth
  the bandwidth once `look_closely` exists (suspicion: no — that was the point of splitting them).

### P3 / PR3 — Sensor zoom
- `videoZoomFactor` on `PhoneCameraSource` (8× cap, respect `videoMaxZoomFactor`), magnification
  gesture on `PhoneCameraView`, readout above 1.05×.
- Pure `ZoomFactorPolicy` (gesture-start × delta, clamped) — tests cover accumulation-not-drift
  and the device-ceiling clamp.

## Open decisions

- **Does `look_closely` need a region argument?** "Read the bottom-left of the label" would let the
  model crop before inference. Deferred: no evidence yet that the model can localise reliably
  enough for the crop to be trustworthy, and a wrong crop is worse than a full frame.
- **Should injection be exposed to `ProactiveAlertService` and face announcements in P2, or held
  back?** Voice-in-the-model's-mouth is a bigger behavioural change for unsolicited alerts than
  for a result the user just asked for. Leaning: hold to a follow-up, so P2 changes only
  user-initiated turns.

## Escape hatch

If mid-turn injection proves unreliable on device (the model ignoring the injected image, or
turn-completion racing the audio stream), `look_closely` degrades to the existing pattern: run a
native vision tool over the sharp still and return its text. Slower and non-conversational, but
it needs no new wire behaviour, and the phrasing work in P1 stands on its own either way.
