# Third-party notices — `LlamaCpp`

This package vendors the [llama.cpp](https://github.com/ggml-org/llama.cpp) inference engine for
the on-device GGUF runtime (Plan DZ). The pinned revision lives in [`REVISION`](REVISION); the
digests of the built artefact live in [`SHA256SUMS`](SHA256SUMS) and what produced them in
[`BUILD-INFO`](BUILD-INFO).

## llama.cpp (and ggml)

- **Upstream:** https://github.com/ggml-org/llama.cpp
- **Revision:** `b1b770d90d94cad9e9ea5b993bdbc383a522fb28` (release `v1.0.0`, build b12359)
- **Licence:** MIT — Copyright (c) 2023-2026 The ggml authors

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

The full text is at `LICENSE` in the upstream repository at the pinned revision.

### Code vendored *inside* llama.cpp that this build links

The build links `vendor/hash`, and the chat library (below) compiles `vendor/nlohmann`, so their
upstream sources ship in the binary:

| Component | Licence | Attribution |
|---|---|---|
| xxHash | BSD 2-Clause | Copyright (c) 2012-2021 Yann Collet |
| SHA-256 | Public domain | 2010-06-11, Igor Pavlov |
| SHA-1 | Public domain | Steve Reid |
| rotate-bits | MIT | Copyright (c) 2021 William Casarin |
| JSON for Modern C++ (nlohmann/json) 3.12.0, with llama.cpp's deep-nesting patch | MIT | Copyright (c) 2013-2025 Niels Lohmann |

Nothing else under llama.cpp's `vendor/` is compiled: cpp-httplib, miniaudio, sheredom and stb
belong to the server, the downloader, tools and multimodal targets, all of which are off.

### The chat library (Plan MQ P2)

The GGUF tool path links llama.cpp's own `common/chat`: each model family's chat template, tool
grammar and tool-call parser, with llama.cpp's own Jinja engine (`common/jinja`, MIT, part of
llama.cpp) and the PEG parser it uses. It is built by [`chat/CMakeLists.txt`](chat/CMakeLists.txt)
from the same pinned checkout, as the smallest set of `common/` sources that links — **not**
upstream's `llama-common` target, which also carries the model downloader, the Hugging Face cache,
the argument parser and cpp-httplib. Left out by name: `arg`, `console`, `debug`, `download`,
`file-lock`, `hf-cache`, `http`, `imatrix-loader`, `llguidance`, `preset`, `subproc`. Since v1.0.0 it
also compiles `chat-tts-norm`, `json-schema` and the per-family handlers in `common/parsers/` (taken
from upstream's own `parsers/sources.cmake`), all llama.cpp's own MIT code. Its headers ship under
`Headers/llama-common/` for the wrapper's chat bridge (`Sources/LlamaCppWrapper/LlamaCppChat.mm`);
Swift sees only the bridge's C functions. Its logger, which writes template text and model output
to stderr from its own thread, is switched off by the bridge (`common_log_set_verbosity_thold(-1)`).

Size, device slice (`ios-arm64/libllama.a`): 10,322,800 bytes at v0.3.0 without it (Xcode 26.6),
15,621,800 bytes with it (Xcode 26.6, recorded on the CI runner); the chat library alone is about
a 5.3 MB archive. At v1.0.0, 21,778,656 bytes (a local build, Xcode 27.2; the committed bytes come
from the CI runner). Linked and dead-stripped into a minimal arm64 executable with the wrapper,
v1.0.0 is 4.47 MB larger stripped than v0.3.0 (6.94 → 11.41 MB): 3.54 MB of it is the embedded
Metal kernel source (`__ggml_metallib`, 1.78 → 5.32 MB, now one source per kernel kind with the
shared headers copied into each), about 0.73 MB code.

## Telemetry posture

**The engine phones nowhere, and this is checked rather than assumed.** Per the repository's
telemetry rule — off by default, disclosed by exception, never silent — a newly linked SDK gets
reviewed for what it sends home before it ships.

llama.cpp's inference core has no analytics, crash-reporting or update-check path; the networking
that exists upstream lives in the server, the model downloader and the CLI tools, none of which
are built here (`LLAMA_BUILD_SERVER`, `LLAMA_BUILD_TOOLS`, `LLAMA_BUILD_COMMON`, `LLAMA_OPENSSL`
are all `OFF`; the chat library above is a list that excludes the downloader by name). The
evidence, not just the claim: the built device slice has **no undefined network symbols at all** — no BSD sockets (`socket`, `connect`, `getaddrinfo`, …), no
`NSURLSession`, no `CFNetwork`, no `nw_connection`, no OpenSSL. Its only Foundation class
reference is `NSURL`, which the Metal backend uses to name a local file.

So there is nothing to disclose in `PrivacyInfo.xcprivacy` for this dependency, and the
manifest's "no analytics, crash-reporting, or advertising SDK" claim stays true. The build script
now runs this check on every build and fails on a hit (`assert_no_network`); by hand:

```sh
nm -u -arch arm64 Vendor/LlamaCpp/Frameworks/llama.xcframework/ios-arm64/libllama.a \
  | sort -u | grep -E '^_(socket|connect|getaddrinfo|curl_|SSL_|CF(URL|HTTP|Stream|Socket))'
```

One related default *was* changed rather than accepted: the engine logs model paths and tensor
names to stderr. That is device-log egress nobody asked for, so `og_llama_runtime_init` installs
a log callback that drops everything unless a developer calls
`og_llama_set_logging_enabled(true)`.

## Compile settings

Built by [`Scripts/build-llamacpp-framework.sh`](../../Scripts/build-llamacpp-framework.sh),
which asserts each of these back out of the CMake cache after configuring — a renamed upstream
option or a stale cache fails the build instead of silently shipping a differently-built engine.

| Setting | Value | Why |
|---|---|---|
| `BUILD_SHARED_LIBS` | `OFF` | Static archive; nothing to embed or sign. |
| `GGML_METAL` | `ON` | GPU inference on device. |
| `GGML_METAL_EMBED_LIBRARY` | `ON` | Kernel source embedded in a `__ggml_metallib` section — no `default.metallib` resource to ship or fail to find. |
| `GGML_BLAS` / `GGML_BLAS_VENDOR` | `ON` / `Apple` | Accelerate for prompt-batch GEMM. |
| `GGML_ACCELERATE` | `ON` | Accelerate vDSP/vecLib paths in the CPU backend. |
| `GGML_OPENMP` | `OFF` | No OpenMP runtime on iOS. |
| `GGML_NATIVE` | `OFF` | Never tune for the build machine when cross-compiling. |
| `LLAMA_BUILD_COMMON`, `_EXAMPLES`, `_TOOLS`, `_TESTS`, `_SERVER`, `_APP`, `_UI`, `_MTMD` | `OFF` | Inference library only. `MTMD` (the multimodal projector) turns on with the later vision phase, not before. The chat part of `common/` is built separately, without the rest (above). |
| `LLAMA_USE_PREBUILT_UI` | `OFF` | Would fetch a web bundle over the network at build time. |
| `LLAMA_OPENSSL` | `OFF` | No TLS stack in an offline inference engine. |
| `CMAKE_OSX_DEPLOYMENT_TARGET` | from `project.base.yml` | Read from the spec, never a second copy. |

Slices: `ios-arm64` (device) and `ios-arm64_x86_64-simulator`.

**Known limitation, recorded rather than papered over:** building the simulator slice for two
architectures at once defeats ggml's CPU architecture detection, which reports *"Unknown CPU
architecture. Falling back to generic implementations"* and compiles scalar kernels for that
slice. The device slice detects `arm64` and is unaffected. Simulator inference is therefore
correct but slow, which is acceptable because the simulator is not a supported place to run local
models (MLX cannot run there at all). Pass `--sim-archs arm64` to the build script to trade Intel
Mac support for NEON kernels in the simulator.
