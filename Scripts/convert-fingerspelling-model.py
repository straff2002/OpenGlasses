#!/usr/bin/env python3
"""Convert the fingerspelling Conformer-CTC checkpoint to Core ML (Plan CK).

Input: a PyTorch Lightning checkpoint of the MIT-licensed reference fingerspelling model —
a torchaudio Conformer encoder (12 blocks, 384 dim, 6 heads, conv stem stride 2) over 63
hand-landmark features (21 joints x 3; wrist-origin, palm-scale, CMVN), linear head to the
FSboard charset with a CTC blank at index 0. Trained on FSboard (CC BY 4.0 — ship attribution
with the model card / About screen).

Output (upload these, unpacked, to the HuggingFace repo set in Settings):
  FingerspellingConformer.mlpackage   fp16 Core ML program
  vocab.txt                           one symbol per line, <blank> first
  cmvn.json                           {"mean": [63], "std": [63]}

Usage:
  pip install torch torchaudio coremltools numpy
  python3 Scripts/convert-fingerspelling-model.py --checkpoint best.ckpt --out ./artifacts \
      [--window 96]

Notes:
- The Lightning checkpoint stores weights under `state_dict` with a module prefix
  (`model.`/`net.`); the loader below strips common prefixes. If your checkpoint layout
  differs, adjust STRIP_PREFIXES.
- The exported model takes a fixed [1, WINDOW, 63] float input ("features") and returns
  [1, WINDOW/2, VOCAB] log-probabilities ("logits"). WINDOW defaults to 96 frames (~3.2 s at
  30 Hz); the app's LandmarkWindower slices to this length.
"""

import argparse
import json
import sys
from pathlib import Path

STRIP_PREFIXES = ("model.", "net.", "module.")

# The FSboard charset used by the reference checkpoint's head, blank first.
FSBOARD_CHARS = " !#$%&'()*+,-./0123456789:;=?@[_abcdefghijklmnopqrstuvwxyz~"
VOCAB = ["<blank>"] + list(FSBOARD_CHARS)

IN_DIM = 63
DIM = 384
NUM_BLOCKS = 12
NUM_HEADS = 6
FF_EXPANSION = 4
CONV_KERNEL = 31


def build_network(vocab_size: int):
    import torch
    from torch import nn
    from torchaudio.models import Conformer

    class FingerspellingNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.stem = nn.Conv1d(IN_DIM, DIM, kernel_size=3, stride=2, padding=1)
            self.encoder = Conformer(
                input_dim=DIM,
                num_heads=NUM_HEADS,
                ffn_dim=DIM * FF_EXPANSION,
                num_layers=NUM_BLOCKS,
                depthwise_conv_kernel_size=CONV_KERNEL,
            )
            self.head = nn.Linear(DIM, vocab_size)

        def forward(self, features):  # [1, T, 63]
            x = self.stem(features.transpose(1, 2)).transpose(1, 2)  # [1, T/2, DIM]
            lengths = torch.full((x.shape[0],), x.shape[1], dtype=torch.int32)
            x, _ = self.encoder(x, lengths)
            return torch.log_softmax(self.head(x), dim=-1)

    return FingerspellingNet()


def load_weights(net, checkpoint_path: Path):
    import torch

    raw = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state = raw.get("state_dict", raw)
    cleaned = {}
    for key, value in state.items():
        for prefix in STRIP_PREFIXES:
            if key.startswith(prefix):
                key = key[len(prefix):]
                break
        cleaned[key] = value
    missing, unexpected = net.load_state_dict(cleaned, strict=False)
    if missing:
        print(f"WARNING: missing keys ({len(missing)}): {missing[:5]}…", file=sys.stderr)
    if unexpected:
        print(f"WARNING: unexpected keys ({len(unexpected)}): {unexpected[:5]}…", file=sys.stderr)
    if len(missing) > len(cleaned) // 2:
        sys.exit("Checkpoint layout doesn't match the expected architecture — inspect the "
                 "state_dict keys and adjust STRIP_PREFIXES / build_network().")
    return raw


def export_coreml(net, window: int, out_dir: Path):
    import coremltools as ct
    import torch

    net.eval()
    example = torch.zeros(1, window, IN_DIM)
    traced = torch.jit.trace(net, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="features", shape=(1, window, IN_DIM))],
        outputs=[ct.TensorType(name="logits")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = ("Fingerspelling Conformer-CTC over hand landmarks. "
                                 "Trained on FSboard (CC BY 4.0, Google).")
    dest = out_dir / "FingerspellingConformer.mlpackage"
    mlmodel.save(str(dest))
    return dest


def write_sidecars(raw_checkpoint, out_dir: Path):
    (out_dir / "vocab.txt").write_text("\n".join(VOCAB) + "\n")
    # CMVN stats: the reference training pipeline stores them in the checkpoint (adjust the
    # key if yours differ); fall back to identity stats with a loud warning.
    mean = std = None
    for key in ("cmvn_mean", "feature_mean"):
        if isinstance(raw_checkpoint, dict) and key in raw_checkpoint:
            mean = list(map(float, raw_checkpoint[key]))
    for key in ("cmvn_std", "feature_std"):
        if isinstance(raw_checkpoint, dict) and key in raw_checkpoint:
            std = list(map(float, raw_checkpoint[key]))
    if mean is None or std is None:
        print("WARNING: no CMVN stats found in checkpoint — writing identity stats. "
              "Recompute them from the training data before publishing.", file=sys.stderr)
        mean, std = [0.0] * IN_DIM, [1.0] * IN_DIM
    (out_dir / "cmvn.json").write_text(json.dumps({"mean": mean, "std": std}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--window", type=int, default=96)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    net = build_network(len(VOCAB))
    raw = load_weights(net, args.checkpoint)
    dest = export_coreml(net, args.window, args.out)
    write_sidecars(raw, args.out)
    print(f"Exported {dest}")
    print(f"Upload the contents of {args.out} (unpacked) to a HuggingFace repo, then set that "
          f"repo in Settings (fingerspellingModelRepo).")


if __name__ == "__main__":
    main()
