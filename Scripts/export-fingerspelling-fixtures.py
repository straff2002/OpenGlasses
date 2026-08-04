#!/usr/bin/env python3
"""Export golden fixtures for the Swift fingerspelling pipeline (Plan CK P2).

Runs the *reference* preprocessing + converted Core ML model over a handful of
competition-corpus sequences and records every intermediate stage:

    raw landmarks -> features (preprocessed) -> logits (Core ML) -> decoded text

`HolisticWindowerTests` / `FingerspellingCTCDecoderTests` then hold the Swift pipeline to
these files (small tolerance on features — the reference reduces in float32, Swift in
double; fp16-scale tolerance on logits; exact match on decode).

Inputs (all kept out of the repo, alongside the unpublished model artefact):
  --preprocess-module  path to the extracted training-pipeline module (provides
                       Preprocess, is_left_handed, filter_nans_tf, MAX_LEN, CHANNELS)
  --mlpackage          path to the converted Fingerspelling2P.mlpackage
  --comp-parquet       competition rerun corpus parquet (543-landmark frames)
  --comp-labels        labels.pq mapping sequence_id -> phrase
  --out-dir            OpenGlassesTests/Fixtures

Sequence selection: one plain right-handed clip, one left-handed clip (exercises the
mirror), one clip with all-NaN frames (exercises the frame drop) — all short, to keep the
fixtures small. Arrays are base64 float32 little-endian (NaNs preserved bit-exactly).
"""
import argparse
import base64
import importlib.util
import json
import os
import sys

import numpy as np
import pandas as pd


def b64(array):
    return base64.b64encode(np.ascontiguousarray(array, dtype="<f4").tobytes()).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preprocess-module", required=True)
    parser.add_argument("--mlpackage", required=True)
    parser.add_argument("--comp-parquet", required=True)
    parser.add_argument("--comp-labels", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--max-frames", type=int, default=150)
    args = parser.parse_args()

    os.environ.setdefault("TF_USE_LEGACY_KERAS", "1")
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import tensorflow as tf  # noqa: E402  (after env setup)
    import coremltools as ct  # noqa: E402

    spec = importlib.util.spec_from_file_location("reference", args.preprocess_module)
    ref = importlib.util.module_from_spec(spec)
    sys.modules["reference"] = ref
    spec.loader.exec_module(ref)

    sel = ([f"x_face_{i}" for i in range(468)]
           + [f"x_left_hand_{i}" for i in range(21)]
           + [f"x_pose_{i}" for i in range(33)]
           + [f"x_right_hand_{i}" for i in range(21)])
    sel = [axis + c[1:] for axis in "xyz" for c in sel]

    labels = pd.read_parquet(args.comp_labels)
    phrase_by_seq = dict(zip(labels.sequence_id, labels.phrase))
    print("loading corpus…", flush=True)
    seqs = pd.read_parquet(args.comp_parquet, columns=sel)

    mlmodel = ct.models.MLModel(args.mlpackage)
    pre = ref.Preprocess()

    wanted = {"plain": None, "left_handed": None, "dropped_frames": None}
    for seq_id in seqs.index.unique():
        if all(v is not None for v in wanted.values()):
            break
        phrase = str(phrase_by_seq.get(seq_id, ""))
        if not phrase:
            continue
        raw = seqs.loc[seqs.index == seq_id].to_numpy(dtype=np.float32)
        if not (10 <= raw.shape[0] <= args.max_frames):
            continue
        frames = np.transpose(raw.reshape(-1, 3, 543), (0, 2, 1))  # (T, 543, 3)

        all_nan = np.all(np.isnan(frames), axis=(1, 2))
        kept = frames[~all_nan]
        if kept.shape[0] < 2:
            continue
        left = bool(ref.is_left_handed(tf.constant(kept)).numpy())

        if left and wanted["left_handed"] is None:
            slot = "left_handed"
        elif all_nan.any() and not left and wanted["dropped_frames"] is None:
            slot = "dropped_frames"
        elif not left and not all_nan.any() and wanted["plain"] is None:
            slot = "plain"
        else:
            continue

        feats = pre(tf.constant(frames)).numpy()[0]  # (T, 1629)
        T = feats.shape[0]
        padded = np.zeros((1, ref.MAX_LEN, ref.CHANNELS), dtype=np.float32)
        padded[0, :T] = feats
        mask = np.zeros((1, ref.MAX_LEN), dtype=np.float32)
        mask[0, :T] = 1.0
        logits = list(mlmodel.predict({"features": padded, "mask": mask}).values())[0]
        t_out = (T + 1) // 2
        rows = logits[0, :t_out].astype(np.float32)

        ids = rows.argmax(-1)
        keep = np.concatenate([ids[:-1][ids[:-1] != ids[1:]], ids[-1:]])
        keep = keep[keep != 0] - 1
        decoded = "".join(ref.REV_CHARACTER_MAP[i] for i in keep if 0 <= i <= 58)

        wanted[slot] = {
            "sequenceId": int(seq_id),
            "phrase": phrase,
            "leftHanded": left,
            "rawFrameCount": int(frames.shape[0]),
            "processedFrameCount": int(T),
            "raw": b64(frames),
            "features": b64(feats),
            "logits": b64(rows),
            "decoded": decoded,
        }
        print(f"  {slot}: seq {seq_id} T_raw={frames.shape[0]} T={T} "
              f"decoded={decoded!r}", flush=True)

    os.makedirs(args.out_dir, exist_ok=True)
    for slot, fixture in wanted.items():
        if fixture is None:
            print(f"WARNING: no sequence found for {slot}", file=sys.stderr)
            continue
        path = os.path.join(args.out_dir, f"fingerspelling_{slot}.json")
        with open(path, "w") as handle:
            json.dump(fixture, handle, separators=(",", ":"))
        print(f"wrote {path} ({os.path.getsize(path) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
