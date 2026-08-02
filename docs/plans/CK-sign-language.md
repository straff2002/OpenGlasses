# Plan CK — Sign-Language Recognition (fingerspelling first)

**Status: 📝 Drafted (2026-08-02), not scheduled** — the one genuinely new capability class
surfaced by the 2026-08-02 field survey. Real-time sign-to-speech is squarely in the
accessibility tier's mission (Plan A) and nothing we ship touches it. Drafted now so the
shape is agreed before anyone starts; blocked on the model story, not on app code.

## What v1 would be (and what it wouldn't)

**ASL fingerspelling → spoken text**: the wearer faces a signing person; the glasses camera
feeds hand landmarks through a sequence model; decoded letters accumulate into words spoken
via TTS. Fingerspelling-only is the honest v1 — full ASL grammar (two-handed signs, facial
grammar, classifiers) is a research project, not a feature. Fingerspelling covers names,
places, and the spell-it-out fallback deaf signers already use with non-signers.

## Architecture (deterministic core first, as always)

1. **Landmark extraction (on-device, no new deps):** Vision's
   `VNDetectHumanHandPoseRequest` — 21 landmarks/hand, on-device. No third-party landmark
   runtime.
2. **`LandmarkWindower` (pure):** timestamped landmark sets → fixed-length, normalized
   windows (wrist-origin, scale-normalized, handedness-mirrored). Fixture-tested.
3. **Sequence model (the blocker):** windows → per-frame letter logits. Needs a trained
   CTC-style model converted to Core ML. Options, in order of preference: (a) train on the
   public fingerspelling datasets and convert; (b) an off-the-shelf ONNX/CoreML conversion
   if one with a compatible license exists; (c) cloud inference as a stopgap — worst option,
   this feature wants to be offline like the rest of the accessibility tier.
4. **`DecodeStabilityPolicy` (pure, buildable today):** the piece worth writing before any
   model exists — turning a noisy per-frame classifier stream into displayed/committed/spoken
   text: confidence floor, N-frame majority vote, streak requirement to *display*, longer
   streak + dictionary check to *commit*, out-of-vocabulary rejection. Same
   noisy-classifier-to-action shape as the wake-word and frame-gate work; tests drive it
   with synthetic logit streams. Reusable by any future streaming classifier we ship.

## Sequencing

- **P0 (anytime, cheap):** `LandmarkWindower` + `DecodeStabilityPolicy` + fixtures.
- **P1 (blocked on model):** model eval harness — offline accuracy on recorded landmark
  fixtures before any live wiring.
- **P2:** live pipeline behind an accessibility-tier toggle; TTS output; HUD caption mirror.
- **P3:** device smoke — frame rate vs. battery, distance/angle envelope, two-person UX.

## Open questions

- Model provenance/licensing (must be clean for a proprietary app — trained-by-us is
  cleanest).
- Latency budget: fingerspelling at conversational speed is ~5 letters/s; end-to-end must
  stay under ~1 s to be usable.
- Does hand-pose hold up at glasses distance (1–2 m) vs. the datasets' webcam framing?
