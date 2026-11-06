#!/usr/bin/env python3
"""Parity of the converted packages against the reference encoder (Plan KQ P0). Mac side.

Usage: python parity.py <model-dir> <out-dir>

Prints counts only, and writes <out-dir>/phone-check.json: for every invented sentence, its kind,
the exact text embedded (prefix included), its token ids from the reference tokenizer, and the
reference float32 vector. The phone check reads that file and compares its own tokenizer and vectors.
"""

import json
import sys
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from sentence_transformers import SentenceTransformer

sys.path.insert(0, str(Path(__file__).parent))
from sentences import PREFIX, sentences  # noqa: E402

MAX_TOKENS = 512


def cosine(a, b):
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def truncated(v, dim):
    v = v[:dim]
    return v / np.linalg.norm(v)


def summarise(label, reference, vectors, seconds):
    nan = sum(1 for v in vectors if not np.all(np.isfinite(v)))
    finite = [(r, v) for r, v in zip(reference, vectors) if np.all(np.isfinite(v))]
    for dim in (768, 256):
        sims = sorted(cosine(truncated(r, dim), truncated(v, dim)) for r, v in finite)
        if sims:
            print(f"[KQ] {label:<22} dim {dim}: NaN {nan}/{len(vectors)}  min {sims[0]:.5f}  "
                  f"median {sims[len(sims) // 2]:.5f}  below 0.999 {sum(s < 0.999 for s in sims)}")
        else:
            print(f"[KQ] {label:<22} dim {dim}: NaN {nan}/{len(vectors)}  no finite vector")
    print(f"[KQ] {label:<22} {1000 * seconds / len(vectors):.1f} ms per text on this Mac")


def main():
    model_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
    st = SentenceTransformer(str(model_dir), device="cpu", model_kwargs={"dtype": torch.float32})
    tokenizer = st.tokenizer

    items = []
    for kind, sentence in sentences():
        text = PREFIX[kind] + sentence
        ids = tokenizer(text, add_special_tokens=True)["input_ids"][:MAX_TOKENS]
        items.append({"kind": kind, "text": text, "ids": ids})
    lengths = sorted(len(item["ids"]) for item in items)
    print(f"[KQ] {len(items)} texts, tokens min {lengths[0]} median {lengths[len(lengths) // 2]} max {lengths[-1]}")

    start = time.time()
    reference = []
    for item in items:
        batch = {"input_ids": torch.tensor([item["ids"]]), "attention_mask": torch.ones(1, len(item["ids"]), dtype=torch.long)}
        with torch.no_grad():
            features = st.forward(batch)
        vector = torch.nn.functional.normalize(features["sentence_embedding"], dim=-1)[0].numpy()
        reference.append(vector)
    print(f"[KQ] reference float32: {1000 * (time.time() - start) / len(items):.1f} ms per text")

    # The reference on ids must equal the library's own encode of the text.
    check = st.encode([items[0]["text"]], convert_to_numpy=True, normalize_embeddings=True)[0]
    print(f"[KQ] reference on ids vs encode(text): {cosine(check, reference[0]):.6f}")

    variants = [
        ("eg2-text-fp32", ct.ComputeUnit.CPU_ONLY, "fp32 CPU"),
        ("eg2-text-int8", ct.ComputeUnit.CPU_ONLY, "int8 CPU"),
        ("eg2-text-int8-fp16", ct.ComputeUnit.CPU_ONLY, "int8 fp16 CPU"),
        ("eg2-text-int8-fp16", ct.ComputeUnit.CPU_AND_NE, "int8 fp16 Neural Engine"),
    ]
    for name, units, label in variants:
        model = ct.models.MLModel(str(out / f"{name}.mlpackage"), compute_units=units)
        start = time.time()
        vectors = []
        for item in items:
            ids = np.array([item["ids"]], dtype=np.int32)
            result = model.predict({"input_ids": ids, "attention_mask": np.ones(ids.shape, dtype=np.float32)})
            vectors.append(np.array(result["embedding"][0], dtype=np.float32))
        summarise(label, reference, vectors, time.time() - start)
        del model

    payload = {
        "model": "google/embeddinggemma-2 text encoder",
        "dimension": 768,
        "items": [{"kind": item["kind"], "text": item["text"], "ids": item["ids"],
                   "reference": [round(float(x), 7) for x in vector]} for item, vector in zip(items, reference)],
    }
    (out / "phone-check.json").write_text(json.dumps(payload))
    print(f"[KQ] wrote phone-check.json ({len(items)} texts)")


if __name__ == "__main__":
    main()
