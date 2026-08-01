# Plan BY — Live Translation Captions

**Status:** 🚧 P1 shipped (2026-08-01) — pure caption mechanics: `ScriptAwareJoiner` (CJK
word-gap collapse, single script-range source shared with `TranscriptGuard`, applied live at both
Gemini transcript accumulators, the Realtime output accumulator, and the compactor seams),
`EndpointDebouncer` (hold ~500 ms, tokens discard premature endpoints), `CaptionCompactor`
(stable-prefix + revisable tail; final == last interim by construction; bounded on monologues;
segment/continuation mode for SFSpeech restarts + delta mode for chunk providers),
`TranslationSegment`/`TranslationDirectionPolicy`/`TranslationCaptionProvider` seam,
`TranslationCaptionFormatter` (change-only speaker labels, tail-biased window wrap). Wired under
ambient captions behind `captionCompactionEnabled` (default ON — behavior-preserving for short
utterances, proven by test; the flag is a kill switch). Cloud-provider parser deferred with the
bake-off (P2) — the likely cloud tier rides the existing Gemini Live wire, whose parser already
exists. Next: P2 cloud tier live + settings + HIPAA gate; P3 on-device tier + two-way + HUD.

Subtitle the world: real-time translated captions of surrounding speech, on the phone overlay
and the in-lens HUD — "they're speaking Spanish, you read English." Plus a **two-way
conversation mode** for a bilingual exchange, where each side's speech is rendered in the
other's language. This is a genuine capability gap: ambient captions (transcription) and
speaker diarization exist; translation does not.

## Architecture: a seam, two tiers, and hardened caption mechanics

### Provider seam
`TranslationCaptionProvider` protocol next to the existing `DiarizationProvider` seam in the
caption path: audio/transcript in → `TranslationSegment` out
(`text`, `originalText`, `sourceLanguage`, `targetLanguage`, `speakerId?`, `utteranceId`,
`isFinal`). Two implementations:

1. **Cloud tier — unified stream.** Prefer a provider whose single websocket does
   STT + language auto-detect + translation (+ diarization) in one stream — one connection,
   one latency budget, interim+final semantics for both transcript and translation. Soniox's
   realtime API is the lead candidate (evaluate against wiring translation on top of the
   existing Deepgram stream as the fallback shape). Key pool + health/fallback per the
   provider-resilience house patterns.
2. **On-device tier — offline & HIPAA.** SenseVoice ASR (already vendored, multilingual with
   language ID) → Apple's Translation framework for on-device translation. Lower quality,
   zero cloud egress. **HIPAA mode hard-disables the cloud tier at start AND kills a running
   cloud stream on mid-session toggle** (the AQ lesson — start-time-only gating is a hole).

### Caption mechanics (pure, provider-agnostic — the quality layer)
These harden *existing* ambient captions too, and are fully headless-testable:

- **`EndpointDebouncer`** — when the provider signals an utterance endpoint, hold ~500 ms; if
  more tokens arrive, the endpoint was premature — discard it. Kills the mid-sentence caption
  splits that make live captions feel broken.
- **`CaptionCompactor`** — rolling compaction for long utterances: finalized tokens collapse
  into a stable prefix string, only the unstable tail stays token-granular. Interim render =
  prefix + tail; the final always equals the last interim (no jarring rewrite), and memory
  stays bounded on a monologue.
- **`TranslationCaptionFormatter`** — speaker-change labels (`[2]:` only when the diarized
  speaker *changes*, stable across interim→final), original-text ribbon (optional smaller
  line), HUD line shaping via the existing condense/width rules.
- **`ScriptAwareJoiner`** — fixes a live-caption defect that exists *today*, independent of
  translation. Live transcription arrives in word-segmented chunks with separator spaces
  (ASR-style), and every consumer concatenates them naively — `GeminiLiveSessionManager`
  does `userTranscript += text`. Between Latin words those spaces are correct; between CJK
  characters they are arbitrary mid-sentence gaps, so Chinese renders as `你手里 拿的 是`.
  This is not a font problem: the spaces are in the string. Collapse whitespace **only** where
  both neighbours are CJK characters or CJK punctuation, so a mixed sentence keeps exactly the
  spaces that belong there (`你手里拿的是 Hypervolt Go 3 按摩枪`). Reuse the script ranges
  already in `TranscriptGuard.cjkFraction` — that type detects majority-CJK *hallucinations*,
  a different problem, so extract the ranges rather than duplicating them. Applies to Gemini
  Live input/output transcripts, OpenAI Realtime transcripts, and ambient captions.

### Two-way mode
One session, two language legs (A→B and B→A). The provider seam takes a
`TranslationDirectionPolicy`: `oneWay(target)` or `twoWay(a, b)` — in two-way, each final
segment renders in the *counterpart* language, labeled per speaker. Phone UI splits top/bottom;
HUD shows the line addressed to the wearer.

## Surfaces

- **Phone:** the ambient-caption overlay grows a translation mode (target-language picker,
  show-original toggle) — settings live with the existing caption/diarization settings.
- **HUD:** translated line via `GlassesDisplayService.showText` path, throttled to final
  segments + slow interims (BLE budget); respects interactive-screen suppression as captions
  do today.
- **Meeting summaries / BrainStore:** translated finals feed the same caption history, so
  `MeetingSummaryTool` summarizes a foreign-language meeting for free; ingest tagged with
  source language.

## Phases

### P1 / PR1 — Deterministic core 🟢
- `TranslationSegment`, `TranslationDirectionPolicy`, `TranslationCaptionProvider` protocol.
- `EndpointDebouncer`, `CaptionCompactor`, `TranslationCaptionFormatter`, `ScriptAwareJoiner` (pure).
- Wire compactor + debouncer under the existing ambient-caption path behind a flag
  (`captionCompactionEnabled`, default on — behavior-preserving for short utterances by
  construction, tests prove it).
- Stream-message parser for the chosen cloud provider's wire shape (pure decode of recorded
  fixtures — no network in tests).
- Tests: debounce discard/commit timing, compaction invariants (final == last interim; bounded
  memory), speaker-label transitions, two-way routing table, parser fixtures incl. malformed
  frames, joiner behaviour on pure-CJK / pure-Latin / mixed / CJK-punctuation boundaries (Latin
  spacing must be provably untouched).

### P2 / PR2 — Cloud provider live + settings
- Websocket client on the parser (connection lifecycle per the realtime-hardening patterns:
  bounded in-flight sends, drop-don't-queue under backpressure, stall detector).
- Settings UI: enable, target language, auto-detect source, show-original, provider key.
- HIPAA gate (start + runtime), Medical-Compliance copy.
- Device-pending: live latency/quality validation.

### P3 / PR3 — On-device tier + two-way + HUD
- SenseVoice → Translation-framework pipeline as the offline provider; automatic tier
  selection (offline/HIPAA → on-device; else cloud) surfaced honestly in the UI.
- Two-way conversation mode UI (phone split view; HUD wearer-leg rendering).
- Device-pending: mic distance/diarization quality in two-way mode.

## Open decisions
- Provider bake-off (Soniox-class unified stream vs. Deepgram+LLM-translate) — pick after P1
  fixtures make swapping cheap; the seam means it's not a blocker.
- Whether translated captions join the diarized speaker-chip UI once AQ's chips land
  (leaning yes — same rail).
- Language-pair scope for v1 UI (free-pick vs. curated top-10; Translation framework's
  download-per-pair management applies on the offline tier).
