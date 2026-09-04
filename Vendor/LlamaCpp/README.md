# LlamaCpp (vendored, built)

The [llama.cpp](https://github.com/ggml-org/llama.cpp) inference engine (MIT), used by the GGUF
local-model runtime (Plan DZ). See [`NOTICES.md`](NOTICES.md) for licences, the verified
no-network posture, and the full table of compile settings.

Like `Vendor/MediaPipeTasks`, the binary is **not committed**. Unlike it, there is nothing
upstream to download — llama.cpp publishes no iOS xcframework — so it is *built* from the exact
revision pinned in [`REVISION`](REVISION):

```bash
Scripts/fetch-llamacpp-framework.sh     # fetch-or-build; verifies before use (CI runs this)
Scripts/build-llamacpp-framework.sh     # the build itself; --help for options
```

Needs `cmake` (`brew install cmake`); it will say so rather than installing anything. The first
run takes several minutes and produces `Frameworks/llama.xcframework` (~50 MB, gitignored);
re-runs are a no-op.

Tracked, and the reason any of this is checkable:

| File | What it promises |
|---|---|
| `REVISION` | which sources — repository, release tag, and the exact commit. Cross-checked against the tag upstream before every build. |
| `SHA256SUMS` | which bytes — every file in the built xcframework, in `shasum -c` format. |
| `BUILD-INFO` | what produced them — revision, options fingerprint, toolchain, checkout path. A digest change that none of these explains fails the build. |

`OpenGlassesTests/LlamaRuntimePackageTests` enforces the shape of all three and their agreement
with each other, and verifies the digests against the artefact when it is present (skipping with
a message when it is not, so a clean clone still passes the suite).

## The wrapper

`Sources/LlamaCppWrapper` is a single Objective-C++ file behind a deliberately small C ABI
(`include/LlamaCppWrapper.h`): model and context lifecycle, GGUF metadata lookup, tokenization,
chat-template application, batched decode, sampling, detokenization, cancellation, and accelerator
synchronization. Nothing from llama.cpp's own headers reaches Swift — the engine is C++ whose
types move between releases, so an engine bump should be a rebuild here rather than a source break
across the app.
