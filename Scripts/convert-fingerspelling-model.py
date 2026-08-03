#!/usr/bin/env python3
"""Convert the fingerspelling Conformer-CTC checkpoint to Core ML (Plan CK).

This is the exact script that produced the published artefact (verified 2026-08-03:
state dict loads strictly; mask-free/functional-attention forward parity < 2e-5 vs the
reference forward; Core ML fp16 output 100% argmax agreement vs torch fp32).

Checkpoint contract (read from the Lightning ckpt's hyper_parameters):
  in_dim 162 = 54 landmarks x 3 (21 dominant-hand + 33 pose, MediaPipe ordering),
  wrist-origin centred, palm-size scaled, NaN->0, per-utterance CMVN (no fixed stats).
  Stem = Conv1d(stride 2) -> SiLU -> Conv1d -> SiLU -> Dropout; torchaudio Conformer
  (12 blocks / 384 dim / 6 heads / conv kernel 17); linear head to 60 classes
  (<blank> + the FSboard charset). Trained on FSboard (CC BY 4.0 - ship attribution).

Environment (torch newer than coremltools supports breaks the trace):
  uv venv --python 3.12 venv && uv pip install --python venv/bin/python \
      "torch==2.8.0" "torchaudio==2.8.0" "coremltools==9.0" numpy

Usage:
  python3 Scripts/convert-fingerspelling-model.py <checkpoint.ckpt> <out-dir> [window=96]

Upload the out-dir contents (unpacked) to a HuggingFace model repo; the app downloads them
via `Config.fingerspellingModelRepo` (see `FingerspellingModelBundle.requiredFiles`).
"""

import json
import sys
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as functional
from torchaudio.models import Conformer

CKPT = Path(sys.argv[1])
OUT = Path(sys.argv[2])
WINDOW = int(sys.argv[3]) if len(sys.argv) > 3 else 96
OUT.mkdir(parents=True, exist_ok=True)

FSBOARD_CHARS = " !#$%&'()*+,-./0123456789:;=?@[_abcdefghijklmnopqrstuvwxyz~"
VOCAB = ["<blank>"] + list(FSBOARD_CHARS)

raw = torch.load(CKPT, map_location="cpu", weights_only=False)
cfg = raw["hyper_parameters"]["model_cfg"]
print("model_cfg:", cfg)


class FingerspellingNet(nn.Module):
    """The reference network, attribute names matching the checkpoint's state dict."""

    def __init__(self, cfg, vocab_size):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv1d(cfg["in_dim"], cfg["dim"], kernel_size=3, stride=2, padding=1),
            nn.SiLU(),
            nn.Conv1d(cfg["dim"], cfg["dim"], kernel_size=3, stride=1, padding=1),
            nn.SiLU(),
            nn.Dropout(cfg["dropout"]),
        )
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


model = FingerspellingNet(cfg, vocab_size=len(VOCAB))
state = {k.removeprefix("model."): v for k, v in raw["state_dict"].items() if k.startswith("model.")}
model.load_state_dict(state, strict=True)
model.eval()
print("state dict loaded strictly: OK")


class TraceableMHA(nn.Module):
    """nn.MultiheadAttention re-expressed functionally with compile-time-constant shapes —
    the stock module's internal dynamic shape casts don't convert to Core ML. Eval-mode only
    (attention dropout skipped)."""

    def __init__(self, mha, seq_len, batch=1):
        super().__init__()
        self.num_heads = mha.num_heads
        self.head_dim = mha.head_dim
        self.embed_dim = mha.embed_dim
        self.seq_len = seq_len
        self.batch = batch
        self.in_proj_weight = mha.in_proj_weight
        self.in_proj_bias = mha.in_proj_bias
        self.out_proj = mha.out_proj

    def forward(self, query, key=None, value=None, key_padding_mask=None, need_weights=False, **_):
        T, B, E = self.seq_len, self.batch, self.embed_dim
        qkv = functional.linear(query, self.in_proj_weight, self.in_proj_bias)
        q, k, v = qkv.chunk(3, dim=-1)

        def split(t):
            return t.contiguous().view(T, B * self.num_heads, self.head_dim).transpose(0, 1)

        q, k, v = split(q), split(k), split(v)
        attn = torch.softmax((q @ k.transpose(1, 2)) / (self.head_dim ** 0.5), dim=-1)
        out = (attn @ v).transpose(0, 1).contiguous().view(T, B, E)
        return self.out_proj(out), None


class ExportWrapper(nn.Module):
    """Mask-free forward for a full fixed window: identical to the reference forward when
    nothing is padded (an all-false mask ≡ None), and free of the dynamic length arithmetic
    that doesn't trace for Core ML."""

    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, features):
        x = self.inner.stem(features.transpose(1, 2)).transpose(1, 2)
        x = x.transpose(0, 1)
        for layer in self.inner.encoder.conformer_layers:
            x = layer(x, None)
        x = x.transpose(0, 1)
        return functional.log_softmax(self.inner.head(x), dim=-1)


wrapped = ExportWrapper(model).eval()
example = torch.randn(1, WINDOW, cfg["in_dim"])
with torch.no_grad():
    ref_out, _ = model(example, torch.tensor([WINDOW], dtype=torch.int32))
    wrapped_out = wrapped(example)
parity = float((wrapped_out - ref_out).abs().max())
print(f"mask-free forward parity vs reference: max |diff| = {parity:.2e}")
assert parity < 1e-4, "mask-free forward diverges from the reference forward"

for layer in model.encoder.conformer_layers:
    layer.self_attn = TraceableMHA(layer.self_attn, seq_len=(WINDOW + 1) // 2)
with torch.no_grad():
    swapped_out = wrapped(example)
mha_parity = float((swapped_out - wrapped_out).abs().max())
print(f"traceable-MHA parity: max |diff| = {mha_parity:.2e}")
assert mha_parity < 1e-4, "functional attention diverges from nn.MultiheadAttention"
ref_out = swapped_out

traced = torch.jit.trace(wrapped, example)

import coremltools as ct  # noqa: E402

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="features", shape=(1, WINDOW, cfg["in_dim"]), dtype=float)],
    outputs=[ct.TensorType(name="logits")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
mlmodel.short_description = ("Fingerspelling Conformer-CTC over MediaPipe-style landmarks "
                             "(21 dominant hand + 33 pose, wrist/palm normalised, per-utterance "
                             "CMVN). Trained on FSboard (CC BY 4.0, Google).")
dest = OUT / "FingerspellingConformer.mlpackage"
mlmodel.save(str(dest))

# Parity check: Core ML fp16 vs torch fp32 on the same input.
import numpy as np  # noqa: E402

pred = mlmodel.predict({"features": example.numpy().astype(np.float32)})
cm = np.asarray(pred["logits"], dtype=np.float32)
print(f"coreml output: {cm.shape}, max |diff| vs torch fp32: {float(np.abs(cm - ref_out.numpy()).max()):.4f}")
agreement = float((cm.argmax(-1) == ref_out.numpy().argmax(-1)).mean())
print(f"argmax agreement: {agreement * 100:.2f}%")
assert agreement > 0.99, "fp16 conversion changed decoded letters"

(OUT / "vocab.txt").write_text("\n".join(VOCAB) + "\n")
(OUT / "cmvn.json").write_text(json.dumps({
    "mode": "per_utterance",
    "note": "CMVN is computed from the utterance's own valid frames (clip-level), not fixed stats.",
}))
print("done ->", dest)
