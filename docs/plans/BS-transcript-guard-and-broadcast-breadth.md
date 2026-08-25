# Plan BS — STT Transcript Guard & Broadcast Breadth

**Status: 🚧 Implemented — all three phases in one PR ([#238](https://github.com/straff2002/OpenGlasses/pull/238), 2026-07-15); endpoint/device smoke owed.**
Two workstreams in one plan: a correctness fix for the speech stack, and feature breadth
for the RTMP broadcast vertical.

**As-built notes:**
- P1: ambient captions and memory rewind turn out to use Apple Speech/Deepgram (not the
  SenseVoice path), so the guard is layered: energy gate + filter in `OnDeviceASREngine`
  (the SenseVoice choke point), and the conservative artifact filter additionally at
  `AmbientCaptionService.finalizeCaption` and the memory-rewind result — defense-in-depth
  across engines, since the downstream propagation (summaries → Spotlight → Brain) doesn't
  care which engine hallucinated. There is no single cross-engine post-text choke point.
- P2: platform ingest presets were already shipped in Settings (dropped from scope).
  Delivered: mic audio + orientation + an aspect-fit letterbox fix (the old path stretched
  to fill). Audio rides the shared wake-word tap (`BroadcastAudioProviding` seam — the
  same fan-out the video recorder uses; no second engine, no session churn); documented
  limitation: the stream is silent while listening is disabled, because the tap isn't
  running. **Closed by [CZ](CZ-independent-capture-audio.md)** — the seam now points at
  `CaptureAudioRouter`, which swaps to its own engine in that gap.
- P3: `PhoneCameraSource` is still-capture only, so a new `PhoneVideoSource`
  (`AVCaptureVideoDataOutput` → UIImage frames, audio-session non-configuring) feeds the
  phone sources. Mid-stream switching via a debounced `BroadcastSourceSelector` and a
  camera menu on the live controls; dual capture composites the cached secondary frame
  through `FrameCompositor` on the existing CPU path.

## P1 — Transcript guard (silence-artifact protection)

**Gap (code-verified):** nothing in `Sources/Services/ASR/` gates what audio reaches the
on-device recognizer or filters what comes back. Speech models of this family have a
well-known failure mode: silence or noise decodes as training-corpus boilerplate (news
sign-offs, subtitle credits — frequently CJK text for models trained on Asian corpora).
Our wake-word flow is largely protected (speech triggers it), but **ambient captions and
memory rewind hand the recognizer arbitrary buffers including long silences**, and the
fully-offline voice mode advertises this path as primary. A hallucinated caption feeds
downstream consumers: caption history → meeting summaries → Spotlight index (BQ) →
BrainStore ingestion.

- Pure `TranscriptGuard`:
  - **Energy gate (pre-recognition):** RMS/peak check over the candidate buffer — below
    threshold, skip recognition entirely (also saves battery in quiet rooms).
  - **Artifact filter (post-recognition):** drop transcripts matching artifact heuristics —
    script mismatch (CJK output when the session/recognition language isn't CJK),
    known-boilerplate patterns, and degenerate repetition (same short phrase N times).
    Conservative by design: when in doubt, keep the transcript; the filter targets the
    unmistakable artifact shapes only.
- Wire into the on-device ASR chain (`OnDeviceASREngine` / `SenseVoiceRecognizer`
  consumers): ambient captions, memory rewind transcription, offline transcription
  fallback. Apple Speech output is left unfiltered (different failure profile; revisit if
  reports appear).
- Tests: energy-gate thresholds (silence vs quiet speech fixtures as raw sample arrays),
  script-mismatch detection, repetition collapse, keep-when-uncertain cases, and a
  regression fixture for the news-sign-off artifact class.

## P2 — Broadcast quick wins (presets, orientation, **audio**)

**Gap (code-verified):** `BroadcastService` is video-only — **no microphone audio is
attached to the stream at all** — with output hardcoded to 720×1280 portrait, one custom
RTMP URL + key in Config, and the glasses `framePublisher` as the only source.

- **Mic audio on the stream** (the headline gap — a voice-less live stream is nearly
  useless): attach the mic through the existing audio-session machinery as a coexisting
  rider (Plan AS lease semantics; broadcast must not steal the session from the wake
  word/TTS owners). Pure part: an `AudioTapFormat` adapter from the shared mic tap to
  HaishinKit's expected sample format.
- **Platform presets:** `BroadcastPreset` (YouTube / Twitch / Kick / custom) with known
  ingest URL templates — user pastes only the stream key; picker in the existing broadcast
  settings. Pure model + tests (URL assembly, key redaction in logs).
- **Orientation:** portrait / landscape output (dimension swap + optional 90° frame
  rotation in the existing CPU pixel-buffer path). Pure part: `BroadcastGeometry`
  (dimensions, rotation, aspect-fit letterboxing decision table).
- Edge verification: one real stream per preset (endpoint-gated), audio sync spot-check.

## P3 — Source switching & dual capture (device-gated)

- **Mid-stream source switch** (glasses ↔ phone camera): both sources already produce
  `UIImage` streams; the broadcast subscribes to a `BroadcastSourceSelector` that swaps the
  upstream publisher without tearing down the RTMP connection. Pure part: selector state
  machine (switch debounce, placeholder frame while the new source warms up).
- **Dual capture (picture-in-picture):** pure `FrameCompositor` — main source full-frame,
  secondary inset (corner, sizing, mirroring rules) — composited before encoding, in the
  same CPU path (no Metal, preserving background safety). Testable with fixture images.
- Edge: sustained dual-source session on device (thermals + frame-rate ceiling: two
  sources through one CPU composite at 15 fps is the risk; the plan's escape hatch is
  shipping switch-only and deferring composite if thermals say no).

## Explicitly out of scope
- Streaming overlays/effects ("reactions", HUD burn-ins) — cosmetic vertical, revisit on
  demand.
- Multi-destination simulcast — one endpoint at a time.
- Replacing the CPU encode path with Metal — background safety is the priority.

## Verification
Headless: guard/preset/geometry/selector/compositor tests + full suite + Release green.
Device/endpoint: silence session produces zero captions (P1), one live stream per preset
with audible mic audio (P2), mid-stream source switch + a timed dual-capture thermal run
(P3).
