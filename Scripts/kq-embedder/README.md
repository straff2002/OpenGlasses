# Search-trained embedder: conversion and parity (Plan KQ P0)

These scripts turn EmbeddingGemma 2's **text encoder** into a Core ML package, then check that the package
gives the same vectors as the reference encoder. They also write the files the phone check reads. Weights,
packages and vectors live outside the repository and are never committed.

The phone decides (Plan KQ, constraint 0). The Mac only converts the model and screens what goes to the
phone.

## Environment

```bash
uv venv --python 3.12 <work>/venv
uv pip install --python <work>/venv/bin/python "torch==2.8.0" "transformers==5.22.2" \
    "sentence-transformers==6.2.0" "coremltools==9.0" numpy safetensors
hf download google/embeddinggemma-2 --local-dir <work>/hf/embeddinggemma-2
```

`torch` stays at 2.8: a newer torch than coremltools supports breaks the trace.

## Run

```bash
<work>/venv/bin/python Scripts/kq-embedder/convert.py <work>/hf/embeddinggemma-2 <work>/out
<work>/venv/bin/python Scripts/kq-embedder/parity.py  <work>/hf/embeddinggemma-2 <work>/out
```

`convert.py` writes three packages, each taking 1 to 512 tokens and returning one L2-normalised
768-dimensional vector (mean pooling over the tokens, prompt included, as the model's pooling config says):

| Package | Weights | Compute precision | Meant for |
|---|---|---|---|
| `eg2-text-fp32.mlpackage` | float32 | float32 | the reference on Core ML |
| `eg2-text-int8.mlpackage` | int8, per channel | float32 | the phone's CPU |
| `eg2-text-int8-fp16.mlpackage` | int8, per channel | float16 | testing the model card's fp16 warning on the Neural Engine |

Up to 512 tokens every sliding-attention layer sees the whole input (the window is 512), so one padding
mask serves both layer types. Longer text is split before embedding, as the contextual backend already
does at 256.

`parity.py` embeds a few hundred invented sentences, as questions (`task: search result | query: `) and
as passages (`title: none | text: `), with the reference SentenceTransformer in float32 and with each
package. It prints counts only: NaN vectors, and minimum and median cosine against the reference, at
768 and at 256 dimensions. It also writes `phone-check.json` (the sentences' token ids and reference
vectors) for the phone check. Every sentence is made up here; none comes from a manual.

## Phone check

Copy the int8 package, the tokenizer files and `phone-check.json` into the app's Documents, then open
Settings › Advanced › Developer › Search Model Check on the phone:

```bash
mkdir -p <work>/phone/search-model-check
cp -R <work>/out/eg2-text-int8.mlpackage <work>/out/phone-check.json <work>/phone/search-model-check/
cp <work>/hf/embeddinggemma-2/{tokenizer.json,tokenizer_config.json,config.json} <work>/phone/search-model-check/
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \
    --domain-identifier <bundle id> --source <work>/phone/search-model-check \
    --destination Documents/search-model-check
```

"Run the check" loads the model on the CPU only and embeds every text twice. "Embed one question in 15
seconds" warms it up, waits for you to lock the phone, then embeds five questions at two priorities. Each
run appends its counts and timings to `Documents/search-model-check/result.txt`, which can be read back
with `devicectl device copy from`.
