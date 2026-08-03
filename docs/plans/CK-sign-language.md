# Plan CK — Sign-Language Recognition (fingerspelling first)

**Status: 🚧 P0 shipped, model story resolved (2026-08-03)** — `LandmarkWindower` (canonical
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

**P1 eval gate: the first candidate FAILED (2026-08-03).** `Scripts/eval-fingerspelling-model.py`
scored the converted checkpoint against 197 real FSboard held-out test clips: **~91% CER**
(greedy; the upstream project's own runtime with its KenLM decoder scores ~96% on the same
clips, confidences 0.1–0.4). Conversion parity was perfect, and a 32-variant feature-pipeline
grid probe found no configuration that helps — the gate condemns the checkpoint, not the
pipeline: it does not generalise to conversational-speed continuous fingerspelling (its
upstream app demos slow deliberate spelling through a 192-frame windowed commit policy).
`fingerspellingModelRepo` therefore stays empty (feature dormant); the converted artefact's
hosting repo is kept **private** ("keep and hide", 2026-08-03) with the eval warning on its
model card — retained for diffing against a future retrained candidate, invisible otherwise.
Everything in-app was already invisible: P2 never wired any UI, so the cores + download layer
stay dormant in the codebase awaiting a candidate that passes the gate. **Next candidate: retrain on FSboard with the Apache-2.0
Kaggle-winning recipe** (the paper-adjacent bar: winning models reached ~20–25% CER greedy at
≤40 MB) — needs a GPU training run (decision owed: where/budget). The eval harness is the
standing gate: any candidate must clear ~25% CER greedy before P2 wiring begins.

Two contract corrections found by inspecting the real checkpoint (vs. the survey notes):
the input is **162 features = 54 landmarks (21 dominant-hand + 33 pose) × 3**, all
wrist-origin/palm-scale normalised — not hand-only 63; and CMVN is **per-utterance**
(computed from the clip's own valid frames), not fixed shipped stats. `LandmarkWindower`
therefore needs a P1 extension: a pose-landmark channel (Vision's body-pose request has 19
joints vs the 33 expected — mapping + zero-fill strategy to be validated by the eval
harness) and utterance-level CMVN. Provenance note: the training pipeline is not published
(hyperparameters are recorded in the checkpoint); the P1 eval harness on FSboard's held-out
test split is the accuracy gate before anything ships to users. The small-model alternative
remains retraining on FSboard with the Apache-2.0 Kaggle-winning recipe (≤40 MB).

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
