# Plan DW — Offline Perception Tier: Local STT and Vision Fallback

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review. Completes the keyless/offline story Plan DH started for the
LLM and Kokoro finished for TTS: hearing and seeing without a network or a key.
**Priority:** P0 is an audit that protects everything after it; P1 is the substantive bet; P3 is
small and independently shippable (could land first if sequencing demands).

Transcription today is `SFSpeechRecognizer` end to end — wake word
([WakeWordService.swift](../../OpenGlasses/Sources/Services/WakeWordService.swift)) and command
transcription ([TranscriptionService.swift](../../OpenGlasses/Sources/Services/TranscriptionService.swift)) —
locale-gated, with a server-recognition fallback when the locale isn't supported on-device. That
leaves two honest gaps: unsupported locales silently become a cloud dependency, and fully-offline
sessions (Plan BU) have no STT floor. Vision has the same shape: when cloud vision is unavailable
and the local VLM can't run (backgrounded — MLX/Metal cannot execute in the background, a documented
hard constraint), a vision question currently gets nothing.

---

## Relevant seams

- `OpenGlasses/Sources/Services/TranscriptionService.swift`, `WakeWordService.swift`
- `OpenGlasses/Sources/Services/ASR/` (SenseVoice already lives here for the on-device translation
  tier — P1 sits beside it behind the same kind of seam)
- `OpenGlasses/Sources/Services/Audio/` (`AudioSessionCoordinator` et al. — P0's subject)
- `OpenGlasses/Sources/Services/ModelDownload/`, `ModelFetcher.swift`, `LocalModelBudget.swift`,
  `MemoryHeadroom.swift` (download + memory discipline for a ~450 MB ASR model)
- `OpenGlasses/Sources/Services/LocalLLMService.swift` + `ModelFallbackChain.swift` (P3 slots below
  the local VLM in the chain)
- `OpenGlasses/Sources/Services/Offline/` (offline-session availability messaging)

## Decisions and invariants

1. **P0 — one decoded stream, audited fan-out.** Before adding another mic consumer, inventory every
   current tap (wake word, ambient captions, diarization, memory rewind, live translation, realtime
   sessions) and assert the invariant: audio is decoded/tapped once per source and fanned out to
   subscribers through the coordinator, not re-tapped per feature. Where that's already true, the
   audit documents it; where it isn't, the fix is part of P0. Exit artifact: a short map in this plan
   doc (consumer → tap point) that P1 then plugs into rather than adding tap #7.
2. **The new ASR is a tier, not a replacement.** A locale-independent on-device transducer model
   (multilingual, GPU-accelerated, permissively licensed upstream) slots in as
   `LocalTranscriptionProvider` behind the existing transcription seam. Selection policy (pure,
   honest-reasons style like `TranslationTierPolicy`): explicit user opt-in per the model-download
   conventions → offline/HIPAA prefers local → unsupported-`SFSpeech` locale prefers local over the
   server fallback → otherwise `SFSpeech` stays default. Wake word stays `SFSpeech` — it's cheap,
   always-on, and latency-critical; the new tier transcribes *commands*, not the trigger.
3. **Transducer hygiene is part of the port.** Two known field behaviors ship as tested code, not
   lore: trim the trailing silence tail before decode (a silence tail can lock a streaming
   transducer decoder into a repeated-word loop), and split the no-speech timeout from the
   post-speech endpoint (initial ~2.5 s vs trailing ~1.2 s) so slow starters aren't cut off. Both are
   pure-testable on PCM fixtures.
4. **Model lifecycle follows house rules.** Download via the existing `ModelDownload` machinery
   (byte-progress, resumable, Application Support), load lazily, respect `MemoryHeadroom`, and
   guard the local-inference-in-background rule: ASR here is CoreML/ANE-eligible — verify
   background execution explicitly on device before claiming it; if it shares MLX's constraint, the
   tier is foreground-only and the policy says so honestly.
5. **P3 — seeing floor: composition, not intelligence.** When every better tier is unavailable, a
   vision question still gets: Apple Vision classification (confidence-filtered) + fast-path OCR,
   composed into one terse factual caption ("Objects: … Text: …") clearly framed as a basic look, not
   an AI answer. Pure `FallbackCaptionComposer` (observations in, sentence out, fixture-tested);
   Vision framework at the edge. It runs backgrounded — that's the point — and slots as the terminal
   link in `ModelFallbackChain` below the local VLM, surfaced through the existing
   honest-availability messaging rather than pretending to be the assistant.

## Phases

**P0 — Mic fan-out audit** (map + fixes if any). **P1 — ASR tier core**: provider behind the seam,
selection policy, transducer hygiene, PCM fixture tests; no UI. **P2 — Lifecycle + settings**:
download/opt-in surface per DH conventions, background-execution verdict, offline-session wiring.
**P3 — Vision floor**: composer + chain wiring (independent of P1/P2; may land first).
