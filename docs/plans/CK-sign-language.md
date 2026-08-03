# Plan CK — Sign-Language Recognition (fingerspelling first)

**Status: 🚧 P0 shipped; gate corpus corrected, passing model converted — publish pending
approval (2026-08-03)** — `LandmarkWindower` (canonical
21-joint order, wrist-origin/palm-scale/mirror/y-flip normalisation, CMVN, windowing) and
`DecodeStabilityPolicy` (confidence floor → OOV rejection → majority vote → display streak →
gap-commit with dictionary gate) shipped pure with full synthetic-stream suites, plus the
download-on-demand model layer (`FingerspellingModelBundle/Store/Downloader`, Kokoro/ASR
discipline: staging → verify → atomic install; repo configurable so publishing the artefact
needs no app update) and `Scripts/convert-fingerspelling-model.py`.

**Model story (resolved; artefact published 2026-08-03):** an MIT-licensed reference
implementation surfaced by the 2026-08-02 survey ships a Conformer-CTC checkpoint (12 blocks
/ 384 dim / 6 heads) trained on **FSboard** (Google, CC BY 4.0, 3M+ characters) with a KenLM
rescoring option. The checkpoint was converted (fp16 Core ML, 79 MB; strict state-dict load;
100% argmax parity vs the source) and published unpacked to the HuggingFace repo that
`Config.fingerspellingModelRepo` now defaults to — the in-app downloader works out of the box.
FSboard attribution is owed in the About screen when the feature ships (P2).

**P1 eval gate (corrected 2026-08-03 late): the FSboard Kaggle release is garbled; on clean
data the first candidate still fails.** The original ~91% CER verdict (and the upstream
runtime's ~96%) was measured on the FSboard Kaggle release (daun_v3), which is **unusable**:
each frame's x/y/z lists are stride-1 windows at offsets 0/1/2 of one interleaved buffer, so
only ~⅓ of each frame's landmarks exist and the rest are unrecoverable (the official
arrow→parquet conversion script inherits the garble; decision: never gate on it). The
standing gate corpus is now the **ASL-fingerspelling competition rerun set** (CC-BY 4.0 with
commercial use expressly allowed; parses clean with pandas) via
`Scripts/eval-fingerspelling-model.py --comp-parquet/--comp-labels`. Clean-data verdicts
(greedy CER): the converted first candidate **61% torch / 63% Core ML** — it decodes real
text (the 91% was a garbled-input artifact) but sits 2.4× over the bar, so the condemnation
stands on honest evidence; a competition-winning TFLite control scores **15.3%** on the same
harness, validating the ~25% bar. `fingerspellingModelRepo` stays empty (feature dormant);
the condemned artefact's hosting repo stays **private** ("keep and hide"); the P2 cores +
download layer stay dormant awaiting a candidate that passes the gate.

**Replacement candidate: PASSES the gate and is converted (2026-08-03).** The competition's
2nd-place CTC model — Apache-2.0 under the competition's winner-license rule, which
expressly forbids limits on commercial use of the code or model; training data is the
competition corpus (CC-BY 4.0, commercial use allowed) — scores **20.7% CER greedy over 300
gate sequences** from the published solution weights, and the converted **fp16 Core ML
artefact (15 MB) scores 20.8%** on the same gate. Conversion notes: fixed 768-frame window
with an explicit float mask input (the architecture is mask-aware, so masked-fixed inference
is equivalent to variable-length for real frames — verified to ~1e-6 in Keras and 100%
argmax parity in Core ML; coremltools cannot convert the dynamic-length path or the RNN
while_loop, hence a hand-unrolled GRU head, verified bit-exact). Its input contract differs
from P0's `LandmarkWindower`: MediaPipe Holistic **543 landmarks × xyz (1629 features)** with
per-sequence standardisation, all-NaN frame drop, and left-hand mirror — P2 wiring must
extend the landmark pipeline (face mesh + full pose) before this ships, and About
attribution for this model is the competition dataset (Google / Deaf Professional Arts
Network, CC-BY 4.0) rather than FSboard. The artefact is staged locally; **publishing to the
model repo awaits approval** — nothing default-on changes in-app. Fallback if a smaller or
retrainable model is ever needed: the Apache-2.0 competition-winning recipe on FSboard
(~20–25% CER at ≤40 MB; GPU run, venue/budget decision owed).

Two contract corrections found by inspecting the real checkpoint (vs. the survey notes):
the input is **162 features = 54 landmarks (21 dominant-hand + 33 pose) × 3**, all
wrist-origin/palm-scale normalised — not hand-only 63; and CMVN is **per-utterance**
(computed from the clip's own valid frames), not fixed shipped stats. `LandmarkWindower`
therefore needs a P1 extension: a pose-landmark channel (Vision's body-pose request has 19
joints vs the 33 expected — mapping + zero-fill strategy to be validated by the eval
harness) and utterance-level CMVN. Provenance note: the training pipeline is not published
(hyperparameters are recorded in the checkpoint); the P1 eval harness on the competition
rerun corpus is the accuracy gate before anything ships to users. (These corrections apply
to the now-condemned first candidate; the passing replacement above has its own, larger
contract — 543 Holistic landmarks — which supersedes this for P2 wiring.)

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

- **P0 ✅ (2026-08-03):** `LandmarkWindower` + `DecodeStabilityPolicy` + fixtures, plus the
  model download layer + conversion script (model story resolved — see Status).
- **P1 (unblocked; needs the converted artefact published):** model eval harness — offline
  accuracy on recorded landmark fixtures before any live wiring; Vision→canonical joint-order
  extractor.
- **P2:** live pipeline behind an accessibility-tier toggle; TTS output; HUD caption mirror;
  FSboard attribution in About.
- **P3:** device smoke — frame rate vs. battery, distance/angle envelope (FSboard is
  selfie-framed; glasses are 1–2 m), two-person UX.

## Open questions

- Model provenance/licensing (must be clean for a proprietary app — trained-by-us is
  cleanest).
- Latency budget: fingerspelling at conversational speed is ~5 letters/s; end-to-end must
  stay under ~1 s to be usable.
- Does hand-pose hold up at glasses distance (1–2 m) vs. the datasets' webcam framing?
