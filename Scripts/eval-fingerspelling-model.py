#!/usr/bin/env python3
"""FSboard CER eval for fingerspelling model candidates (Plan CK P1 — the ship gate).

Scores a candidate against real held-out FSboard test clips (real Deaf signers at
conversational speed): parses the Kaggle arrow shards (tf.train.SequenceExamples of
MediaPipe Holistic landmarks), rebuilds the model's input contract (dominant hand + pose,
left mirrored x→1−x, invalid-hand frames dropped, wrist/palm normalised, NaN→0,
per-utterance CMVN), greedy-CTC decodes, and reports character error rate.

Two scorers: --checkpoint runs the PyTorch reference full-clip (model truth); --mlpackage
runs the converted Core ML in fixed 96-frame chunks (the deployed configuration). Pass either
or both.

History: the first candidate (the converted MIT reference checkpoint) FAILED this gate on
2026-08-03 — ~91% CER (its own upstream runtime + KenLM: ~96%). Conversion parity was
perfect, so the gate condemns the checkpoint, not the pipeline. Any future candidate
(e.g. retrained on FSboard via the Apache-2.0 Kaggle-winning recipe) must beat ~25% CER
greedy before P2 wiring begins.

Setup:
  uv venv --python 3.12 venv && uv pip install --python venv/bin/python \
      "torch==2.8.0" "torchaudio==2.8.0" "coremltools==9.0" numpy pyarrow tensorflow kaggle
  KAGGLE_API_TOKEN=… kaggle datasets download googleai/fsboard \
      -f "daun_v3/landmarks/daun_v3-test.arrow-00000-of-00020" -p .

Usage:
  python3 Scripts/eval-fingerspelling-model.py --shard daun_v3-test.arrow-00000-of-00020 \
      [--checkpoint best.ckpt] [--mlpackage FingerspellingConformer.mlpackage] [--clips 200]
"""

import argparse
import re
import sys

import numpy as np
import pyarrow.feather

WINDOW = 96
FSBOARD_CHARS = " !#$%&'()*+,-./0123456789:;=?@[_abcdefghijklmnopqrstuvwxyz~"
VOCAB = ["<blank>"] + list(FSBOARD_CHARS)
CHARSET = set(FSBOARD_CHARS)


def parse_clip(serialized, tf):
    ex = tf.train.SequenceExample()
    ex.ParseFromString(serialized)
    ctx = ex.context.feature
    prompt = ctx["prompt"].bytes_list.value[0].decode("utf-8") if "prompt" in ctx else None
    n = int(ctx["num_frames"].int64_list.value[0])
    fl = ex.feature_lists.feature_list

    def part(name, size):
        arr = np.full((n, size, 3), np.nan, dtype=np.float32)
        for ai, axis in enumerate("xyz"):
            key = f"{axis}_{name}"
            if key not in fl:
                continue
            feats = fl[key].feature
            for f in range(min(n, len(feats))):
                vals = feats[f].float_list.value
                if len(vals) == size:
                    arr[f, :, ai] = np.asarray(vals, dtype=np.float32)
        return arr

    return prompt, part("right_hand", 21), part("left_hand", 21), part("pose", 33)


def build_features(right, left, pose):
    """The model's input contract — must match the app's LandmarkWindower P1 extension."""
    frames = []
    for f in range(right.shape[0]):
        if np.isfinite(right[f]).all():
            hand, ps = right[f], pose[f]
        elif np.isfinite(left[f]).all():
            hand = left[f].copy(); ps = pose[f].copy()
            hand[:, 0] = 1 - hand[:, 0]; ps[:, 0] = 1 - ps[:, 0]
        else:
            continue
        frames.append(np.concatenate([hand, ps], axis=0))
    if len(frames) < 4:
        return None
    lm = np.stack(frames)
    out = lm - lm[:, 0:1, :]
    palm = np.linalg.norm(out[:, 9, :], axis=-1, keepdims=True)
    out /= np.maximum(palm, 1e-6)[:, :, None]
    feats = np.where(np.isnan(out), 0.0, out).reshape(out.shape[0], -1).astype(np.float32)
    mean = feats.mean(axis=0, keepdims=True)
    std = np.maximum(feats.std(axis=0, keepdims=True), 1e-6)
    return (feats - mean) / std


def greedy_decode(log_probs):
    ids = np.asarray(log_probs).argmax(-1)
    out, prev = [], -1
    for i in ids:
        if i != prev and i != 0:
            out.append(VOCAB[i])
        prev = i
    return "".join(out)


def norm_text(t):
    t = "".join(c for c in t.lower().strip() if c in CHARSET)
    return re.sub(r"\s+", " ", t).strip()


def cer(hyp, ref):
    if not ref:
        return None
    d = np.zeros((len(hyp) + 1, len(ref) + 1), dtype=np.int32)
    d[:, 0] = np.arange(len(hyp) + 1)
    d[0, :] = np.arange(len(ref) + 1)
    for i in range(1, len(hyp) + 1):
        for j in range(1, len(ref) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1,
                          d[i - 1, j - 1] + (hyp[i - 1] != ref[j - 1]))
    return d[len(hyp), len(ref)] / len(ref)


def load_torch_model(ckpt_path):
    import torch
    import torch.nn as nn
    import torch.nn.functional as functional
    from torchaudio.models import Conformer

    class Net(nn.Module):
        def __init__(self, cfg, vocab_size):
            super().__init__()
            self.stem = nn.Sequential(
                nn.Conv1d(cfg["in_dim"], cfg["dim"], 3, stride=2, padding=1), nn.SiLU(),
                nn.Conv1d(cfg["dim"], cfg["dim"], 3, stride=1, padding=1), nn.SiLU(),
                nn.Dropout(cfg["dropout"]))
            self.encoder = Conformer(
                input_dim=cfg["dim"], num_heads=cfg["num_heads"],
                ffn_dim=cfg["dim"] * cfg["ff_expansion"], num_layers=cfg["num_blocks"],
                depthwise_conv_kernel_size=cfg["conv_kernel"], dropout=cfg["dropout"])
            self.head = nn.Linear(cfg["dim"], vocab_size)

        def forward(self, features, raw_lengths):
            x = self.stem(features.transpose(1, 2)).transpose(1, 2)
            lengths = (raw_lengths + 1) // 2
            x, lengths = self.encoder(x, lengths)
            return functional.log_softmax(self.head(x), dim=-1), lengths

    raw = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    model = Net(raw["hyper_parameters"]["model_cfg"], len(VOCAB))
    model.load_state_dict({k.removeprefix("model."): v for k, v in raw["state_dict"].items()
                           if k.startswith("model.")}, strict=True)
    model.eval()
    return model, torch


def coreml_chunked(mlmodel, feats):
    logits = []
    start = 0
    while start < feats.shape[0]:
        chunk = feats[start:start + WINDOW]
        valid = chunk.shape[0]
        if valid < WINDOW:
            chunk = np.pad(chunk, ((0, WINDOW - valid), (0, 0)))
        pred = mlmodel.predict({"features": chunk[None].astype(np.float32)})["logits"][0]
        logits.append(pred[: (valid + 1) // 2])
        start += WINDOW
    return np.concatenate(logits, axis=0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shard", required=True)
    parser.add_argument("--checkpoint")
    parser.add_argument("--mlpackage")
    parser.add_argument("--clips", type=int, default=200)
    args = parser.parse_args()
    if not args.checkpoint and not args.mlpackage:
        sys.exit("pass --checkpoint and/or --mlpackage")

    import tensorflow as tf
    model = torch = mlmodel = None
    if args.checkpoint:
        model, torch = load_torch_model(args.checkpoint)
    if args.mlpackage:
        import coremltools as ct
        mlmodel = ct.models.MLModel(args.mlpackage)

    table = pyarrow.feather.read_table(args.shard, columns=["serialized"])
    count = evaluated = 0
    torch_cers, coreml_cers, samples = [], [], []
    for chunk in table["serialized"].chunks:
        for serialized in chunk:
            if count >= args.clips:
                break
            count += 1
            prompt, right, left, pose = parse_clip(serialized.as_py(), tf)
            ref = norm_text(prompt or "")
            feats = build_features(right, left, pose)
            if feats is None or not ref:
                continue
            row = [ref]
            if model is not None:
                with torch.no_grad():
                    lp, _ = model(torch.from_numpy(feats)[None],
                                  torch.tensor([feats.shape[0]], dtype=torch.int32))
                hyp = norm_text(greedy_decode(lp[0].numpy()))
                torch_cers.append(cer(hyp, ref)); row.append(hyp)
            if mlmodel is not None:
                hyp = norm_text(greedy_decode(coreml_chunked(mlmodel, feats)))
                coreml_cers.append(cer(hyp, ref)); row.append(hyp)
            evaluated += 1
            if evaluated <= 8:
                samples.append(row)
            if evaluated % 25 == 0:
                bits = []
                if torch_cers:
                    bits.append(f"torch {np.mean(torch_cers)*100:.1f}%")
                if coreml_cers:
                    bits.append(f"coreml {np.mean(coreml_cers)*100:.1f}%")
                print(f"  {evaluated} clips: CER " + "  ".join(bits), flush=True)
        if count >= args.clips:
            break

    print(f"\nEvaluated {evaluated}/{count} clips")
    if torch_cers:
        print(f"PyTorch full-clip greedy CER : {np.mean(torch_cers)*100:.2f}% (median {np.median(torch_cers)*100:.1f}%)")
    if coreml_cers:
        print(f"Core ML {WINDOW}-chunked greedy CER: {np.mean(coreml_cers)*100:.2f}% (median {np.median(coreml_cers)*100:.1f}%)")
    print("\nSamples (ref | hyps…):")
    for row in samples:
        print("  " + " | ".join(repr(x) for x in row))


if __name__ == "__main__":
    main()
