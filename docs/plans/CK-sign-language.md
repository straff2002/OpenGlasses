# Plan CK — Sign-Language Recognition (fingerspelling first)

**Status: 🚧 P0 + P2 wiring shipped (2026-08-04); publish pending approval** — the P2
live-decode pipeline (MediaPipe holistic landmarks → `HolisticWindower` →
`FingerspellingLiveDecoder` → `DecodeStabilityPolicy`) is implemented behind seams and
golden-fixture-tested against the Python reference; the feature stays dormant until the
model artefact is published (see P2 section). Earlier state: `LandmarkWindower` (canonical
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
- **P2 ✅ core wiring (2026-08-04):** the live-decode pipeline below — MediaPipe Tasks
  dependency, `HolisticLandmarkService` seam, `HolisticWindower` + CTC decode pure cores,
  golden fixtures from the Python reference. The activation surface (accessibility-tier
  toggle, TTS hookup, HUD caption mirror, About attribution) lands with the model publish —
  wiring a user-visible toggle to a `.notConfigured` download would be dead UI.
- **P3:** device smoke — frame rate vs. battery with the holistic landmarker live,
  distance/angle envelope (the corpus is selfie-framed; glasses are 1–2 m), decode cadence
  tuning, two-person UX.

## P2 — live decode wiring (architecture set by the 2026-08-03 ablation)

**Why MediaPipe:** the passing model consumes the full MediaPipe Holistic contract
(543 landmarks × xyz = 1629 features). Ablation on the gate corpus: full **21.1%** CER,
hands+full-pose **29.2%** (over the bar), hands+pose+lips **31.1%** (partial face perturbs
the per-sequence normalisation), hands-only **55.6%**. Apple Vision cannot express the
contract (19 body joints vs 33 BlazePose; ~76 face points vs 468 mesh), so the landmark
source is **MediaPipe Tasks iOS** — the extractor family that produced the training corpus,
i.e. the model's native input distribution. Known fallback curve if the landmarker is too
heavy on device: drop face → 29.2%.

**Camera geometry note:** corpus clips are signers facing their own phone camera; the
glasses wearer faces a signing interlocutor who faces the glasses camera — same facing
geometry, no mirroring correction expected. Distance/angle/stability shift remains a P3
device-smoke question.

### Components (deterministic core first, integration behind seams)

1. **Dependency** (decided 2026-08-04): MediaPipe Tasks Vision 1.0.0 as a **vendored local
   SPM package** (`Vendor/MediaPipeTasks`, mirroring `Vendor/SherpaOnnx`) — CocoaPods would
   bolt a second dependency manager onto the XcodeGen+SPM project. Twist: the graph static
   libraries are 410 MB / 818 MB — over GitHub's 100 MB per-file hard limit — so unlike
   SherpaOnnx the binaries are **fetched, not committed**: `Scripts/fetch-mediapipe-frameworks.sh`
   (pinned version + sha256, Google's official artefacts) populates the gitignored
   `Frameworks/`, locally and in `ci_post_clone.sh`. The graph runtime's per-SDK
   `-force_load` lives on the app target in `project.base.yml` (SPM can't express
   sim-vs-device linker flags) and is **Release-only**: unit tests never execute the
   graph, and force-loading the 818 MB simulator archive into Debug bloated the debug
   dylib ~76 MB and hung the XCTest runner at bootstrap — a Debug *device* run of the real
   landmarker needs the flags copied to Debug for that session (P3 does exactly that).
   The landmark model (`holistic_landmarker.task`, ~14 MB) ships through the existing
   fingerspelling download bundle rather than the app bundle.

2. **`HolisticLandmarkService`** (integration, behind the `HolisticLandmarkProviding`
   protocol so unit tests never touch the SDK): MediaPipe 1.0.0 ships a **single holistic
   landmarker task** (face + pose + both hands in one video-running-mode call, monotonic
   timestamps) — supersedes the drafted three-landmarker assembly. Output assembled as
   (543, 3) in canonical order — face 0–467 (first 468 of the tasks-API's 478), left hand
   468–488, pose 489–521, right hand 522–542 — NaN where a part is undetected.

3. **`HolisticWindower`** (pure core; replaces `LandmarkWindower`'s contract for this
   model): per window ≤ 768 frames: drop all-NaN frames, whole-window handedness vote →
   mirror (x → 1−x plus the left/right landmark swap table, shipped as a Swift constant
   generated from the training pipeline's correspondence tables), per-window per-channel
   standardisation over present values, NaN→0, flatten to 1629, zero-pad to 768 + float
   mask.

4. **Inference + decode** (pure core + Core ML): `FingerspellingInferenceEngine` compiles
   and runs the downloaded mlpackage (features (1,768,1629) + mask (1,768) → logits
   (1,384,62)); `FingerspellingCTCDecoder` reads the first ⌈T/2⌉ rows (greedy collapse,
   blank 0, ids−1 → 59-char charset shipped in code with a `vocab.txt` sanity sidecar);
   `FingerspellingLiveDecoder` feeds per-row observations into the existing
   `DecodeStabilityPolicy` — with vote window and display streak of 1 the policy *is* the
   greedy CTC collapse, plus the commit/streak/gap word logic P0 established; committed
   words → TTS (hookup at publish).

5. **Artifact plumbing**: publish the mlpackage + vocab sidecar + landmarker task to the
   HF model repo (**approval + fresh token consent required — not done**), then flip
   `Config.fingerspellingModelRepo`. Apache-2.0 LICENSE + competition-dataset CC-BY 4.0
   attribution live in the HF repo; the About screen gains the competition-dataset
   attribution (not FSboard) when the feature ships.

6. **Tests as the gate (no device needed)**: golden fixtures exported from the Python
   reference (`Scripts/export-fingerspelling-fixtures.py`: three gate-corpus sequences —
   plain, left-handed, and with dropped all-NaN frames — recording raw landmarks →
   features → logits → decoded text) with the Swift pipeline held to them (small tolerance
   on features/logits, exact on decode). Synthetic-stream suites for buffer/mask edge
   cases (short clips, all-NaN runs, >768 overflow, left-hand flip). MediaPipe seam mocked
   throughout; no `.shared` service exercise in unit tests.

### Explicitly deferred to P3
Frame-rate/battery envelope with the holistic landmarker live, distance/angle robustness,
decode cadence tuning (per-second re-decode vs gap-triggered; re-feeding refined rows),
confidence-floor tuning against live logit distributions, and the drop-face fallback
decision if perf demands it.

## Open questions

- Model provenance/licensing (must be clean for a proprietary app — trained-by-us is
  cleanest).
- Latency budget: fingerspelling at conversational speed is ~5 letters/s; end-to-end must
  stay under ~1 s to be usable.
- Does hand-pose hold up at glasses distance (1–2 m) vs. the datasets' webcam framing?
