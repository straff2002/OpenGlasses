# Developer and user feedback: local LLM tool calling on iPhone/iPad (MLX Swift, llama.cpp-based apps)

Research date: 2026-11-20. Source-quality key: **[M]** = maintainer-confirmed or fixed in a merged PR; **[R]** = reporter gives a controlled reproduction with numbers; **[A]** = anecdote, README or blog claim; **[S]** = taken from a search-engine summary of the page, not fetched and read in full here (check before relying on it).

Pages fetched and read directly: AnyLanguageModel #328, mlx-swift-examples #492, mlx-swift-lm #259 and PR #812, the mlx-swift-lm issue search listings ("tool"; "memory OR iPhone OR jetsam"), the mlx-swift-examples issue search ("tool call"), and the Hemeskyo/mlx-ios-toolcall README. ertyurk.com could not be fetched (the host is blocked by this session's network policy).

## Tool-calling reliability with small on-device models (malformed markup, narration, hallucinated tools, template mismatches, streaming parsers)

### Takeaway
Most reliability failures reported in 2026 are in the **harness**, not the model. Three causes recur: the parser does not match the model's tool-call markup; the assistant's own tool-call turn is never sent back into the history; and chat templates drop `tool` messages or choke on schema shapes. Once these were fixed, small models went from total failure to mostly correct in controlled runs. Examples: Gemma 4 E2B went from 0/6 to 6/6, and Qwen3-1.7B from 10/10 repeated calls to 0/10. The remaining model-side problems are Qwen omitting closing tags, Qwen3.x placing tool calls inside `<think>`, preamble text before `<tool_call>`, argument types returned as strings, and narrating instead of acting.

### Cited Findings

**Harness / history bugs (MLX Swift via AnyLanguageModel)**
- **AnyLanguageModel #328** (opened 2026-10-14; closed 2026-10-26; fixed in AnyLanguageModel **1.1.0** via PRs #329, #331, #343) **[M][R]**. Environment: AnyLanguageModel 1.0.0, mlx-swift-lm 3.32.3, 4-bit MLX models. Tested on an M3 Pro Mac, not an iPhone. `MLXLanguageModel` never put the assistant's tool-call message into the chat history, and it sent tool results without a call ID or name. Effects by family:
  - Gemma 4: the result was dropped and the model repeated the same call.
  - gpt-oss-20b: the template raised a missing-assistant-tool-call error.
  - Ministral 3: alternating-roles errors in 2 of 6 runs.
  - Qwen3, Qwen3.5, Llama 3.2 and LFM2: the result rendered without the call that produced it.

  Before vs after the fix:
  - Gemma 4 e2b calculator: 6/6 failed → 6/6 correct.
  - Gemma 4 E2B QAT: 6/6 failed → 5/6 correct.
  - Gemma 4 E4B QAT: 6/6 failed → 4/6 correct (1 empty).
  - Qwen3-1.7B search: 10/10 re-sent the identical call → 0/10.
  - Qwen3-8B: 6/6 → 0/6.
  - Qwen3-4B: 8/10 "announced another search" → 0/10.

  Also found:
  - Llama 3.x templates allow only one tool call per assistant message, so Llama-3.2-3B errored on every parallel-call round.
  - The repeated-call detector compared dictionaries stringified in Swift's per-process hash order, so it missed 286 of 603 identical rounds across 14 models. Qwen3-1.7B with a 3-argument tool missed 12 of 20 by default and 0 of 20 with `SWIFT_DETERMINISTIC_HASHING=1`.
  - An 8-round cap discarded all of the round's tool work (88/88 limit errors left only the prompt in the transcript).
  - In comparison, Apple Foundation Models had 30/30 runs with no errors and stopped after 3–5 empty searches.
  — [AnyLanguageModel #328](https://github.com/huggingface/AnyLanguageModel/issues/328)
- mlx-swift-lm PR #780 "fix: render null tool-call arguments in chat history" was merged 2026-11-16. Title only; not read. **[S]** — [mlx-swift-lm issue search "tool"](https://github.com/ml-explore/mlx-swift-lm/issues?q=tool)

**Parser / format mismatches (mlx-swift-lm)**
- **mlx-swift-lm #259** (opened 2026-05-01, mlx-swift-lm 3.31.3; closed 2026-09-14 by PR #548; core gap reportedly already fixed by PR #183, merged 2026-05-22) **[M]**. The report used gemma-4-26b-a4b-it-8bit on an M5 Pro. Two bugs:
  - `ToolCallFormat.infer` matched `"gemma"` exactly, but Gemma 4's `model_type` is `"gemma4"`, so the default JSON parser was used.
  - `GemmaFunctionParser` looked for `<start_function_call>`, but Gemma 4 emits `<|tool_call>`…`<tool_call|>`. The tool calls streamed out as plain text, with no `.toolCall` events and `stopReason == .stop`.

  The reporter also flagged that the Gemma 4 template drops `role:tool` messages. — [mlx-swift-lm #259](https://github.com/ml-explore/mlx-swift-lm/issues/259)
- **mlx-swift-lm PR #812** (merged 2026-11-18) **[M]** fixes two problems:
  - **Lost arguments.** Qwen sometimes omits `</parameter>` before the next `<parameter=`, so one value swallowed all later parameters. In the reported case the call went out without `url`, and the model repeated it 4 times until the tool budget ran out (seen on a `.qwen35` model). The fix: a `<parameter=` at the start of a line now closes an unclosed value.
  - **Undeclared tools mislabelled.** Calls to tools that were never declared (e.g. `tool_read` instead of `read_url`) were reported as `malformedSyntax` with no name. They are now `undeclaredTool` with the name, across the Qwen35, GLM4, Mistral and LFM2 paths.

  A test feeds the payload one character at a time to confirm streaming chunks don't change the parse. — [mlx-swift-lm PR #812](https://github.com/ml-explore/mlx-swift-lm/pull/812)
- Pythonic tool-call parsing (LFM2-style) keeps being hardened in mlx-swift-lm:
  - `PythonLiteralParser` triple-quoted strings: PR #786, merged 2026-11-10.
  - Surrogate pairs and Python escapes: PR #769, merged 2026-11-06.
  - r/u prefixes and adjacent string literals: PR #799, merged 2026-11-16.

  Titles only. **[S]** — [mlx-swift-lm issue search "tool"](https://github.com/ml-explore/mlx-swift-lm/issues?q=tool)
- Guided generation can now use the caller's sampler and logit processor (PR #733, merged 2026-11-17). An earlier talk said structured generation was not yet supported directly in mlx-swift-lm. **[S]** — [mlx-swift-lm issue search "tool"](https://github.com/ml-explore/mlx-swift-lm/issues?q=tool); [AI Engineer talk: Gemma 4 on-device 40 tok/s on iPhone with MLX](https://ai.engineer/talks/a2muGkT4WD4-running-gemma-4-on-device-40-tokens)
- A long-standing feature request for structured output for tool use in mlx-swift-examples, #221 (2025-03-04), is still open. Qwen3-VL tool calling landed 2025-10-27 (PR #421), and "Implement Structured Tool" landed 2025-06-24 (PR #311). **[M]** for the merges. — [mlx-swift-examples search "tool call"](https://github.com/ml-explore/mlx-swift-examples/issues?q=tool+call)

**Argument typing**
- In a SwiftLM fork, Gemma-4-E2B 4-bit returned integer and boolean tool arguments as strings, scoring 16/20 against a 20/20 reference. The author suspects general argument decoding in that Swift build rather than the model. **[S][A]** — [eejd/swift-lm #7](https://github.com/eejd/swift-lm/issues/7)
- A transformers issue says several templates (Llama, Gemma4, Qwen2.5, GptOSS) silently double-escape string arguments. **[S]** — [huggingface/transformers #45419](https://github.com/huggingface/transformers/issues/45419)

**Chat templates and swift-jinja**
- Gemma 4's chat template renders tool schemas with a recursive macro. swift-jinja recurses once per schema level, and prompts render on a Swift-concurrency cooperative thread with a 512 KiB stack, so deeply nested schemas can overflow the stack. The fix renders templates on a dedicated stack. **[S]** — [Layr-Labs/d-inference PR #2381](https://github.com/Layr-Labs/d-inference/pull/2381)
- The Gemma 4 template applies `upper` to the schema `type` unconditionally and crashes on schemas that omit `type`. **[S]** — [lmstudio-bug-tracker #2228](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2228)
- There are reported problems with multiple rounds of tool calling in Gemma 4's official template. **[S]** — [google/gemma-4-31B-it discussion #115](https://huggingface.co/google/gemma-4-31B-it/discussions/115)
- Gemma 3 templates have no `tool` role. **[S]** — [google/gemma-3-12b-it discussion #11](https://huggingface.co/google/gemma-3-12b-it/discussions/11)
- Gemma 2 templates raise "System role not supported". The system-role exception belongs to Gemma 2-era templates, not Gemma 4. **[S]** — [google/gemma-2-2b discussion #28](https://huggingface.co/google/gemma-2-2b/discussions/28)

**Qwen3 / Qwen3.x thinking vs tool calls (llama.cpp; affects llama.rn and PocketPal, which embed llama.cpp)**
- Qwen3.5 9B with thinking enabled often prints tool calls as XML **inside the thinking block** and stops, so the tool parser never sees them. The reported workaround is `--reasoning-format none`. **[S]** — [llama.cpp #20837](https://github.com/ggml-org/llama.cpp/issues/20837)
- The `peg-native` parser fails when a thinking model outputs text before `<tool_call>`, because the grammar root expects the tag first. **[S]** — [llama.cpp #20260](https://github.com/ggml-org/llama.cpp/issues/20260)
- Qwen3.5-27B tool-call parsing is reported still broken after PR #20424 (build 8576), with "Failed to parse input at pos N" even with thinking disabled. **[S]** — [llama.cpp #21158](https://github.com/ggml-org/llama.cpp/issues/21158)
- In the Qwen3 `TAG_WITH_TAGGED` format, an array-of-object parameter aborts the parse, and a partial tool call leaks to the client and "poisons multi-turn history". **[S]** — [llama.cpp #21771](https://github.com/ggml-org/llama.cpp/issues/21771)
- I found no llama.rn-specific report. The search summary notes that the impact depends on which llama.cpp commit the binding bundles. **[S]**

**Narrating instead of acting**
- A fine-tuned LFM2.5-2.6B iOS app reports that "skipping reasoning sometimes makes the model chat instead of act", so it added a fallback pass. **[A]** — [Hemeskyo/mlx-ios-toolcall](https://github.com/Hemeskyo/mlx-ios-toolcall)
- A developer write-up (per search summary) says small models wrap JSON in markdown fences or add chatter before it, so parsing must be lenient. **[S][A]** — [ertyurk.com on-device LLM tool calling](https://ertyurk.com/posts/on-device-llm-tool-calling/) (not fetchable from this session)

### Inferences
- Before blaming a small model for loops or "it ignored the tool result", check the history round-trip. The assistant tool-call turn must carry IDs and names, and the template must actually render `role:tool`. This was the dominant cause in the only controlled multi-model study found (#328).
- On mlx-swift-lm, Qwen and Gemma 4 tool parsing changed materially in 2026: #183 (May), #548 (September) and #812 (November). Any pin older than the November main may still hit the dropped-argument bug. Issue #797 notes the last tag was 3.32.3 (2026-09-30), with about 95 commits on main since, so #812 is probably **not yet in a tagged release** (see the Gaps entry on this).
- With Qwen3.x thinking models, disable thinking for tool turns, or strip and inspect `<think>` blocks for tool calls. Several runtimes mis-parse calls placed there.

### Gaps
- I found no iPhone-specific controlled tool-calling success-rate benchmark. #328 ran on macOS (M3 Pro); behaviour on an iPhone with the same MLX build should be the same in principle, but it is unverified.
- I could not confirm whether mlx-swift-lm PR #812 is in a tagged release yet. Only issue #797's title ("Tag cadence — 3.32.3 (2026-09-30), ~95 commits on main since") was seen.
- I did not find swift-jinja's own issue tracker entries. The template findings above come from adjacent projects.
- I found no Reddit or Apple Developer Forums thread text directly. The search did not surface the threads themselves.

## Memory and stability on iPhone (Jetsam, os_proc_available_memory, increased-memory-limit, KV cache, vision models, background GPU, thermal)

### Takeaway
The practical ceilings come from per-app limits, not physical RAM. The increased-memory-limit entitlement helps on some devices, but reports conflict on newer phones. MLX copies weights into the footprint, while llama.cpp mmaps them, so the two hit different limits. Long prompts plus KV cache on 8 GB phones can kill the process silently (not even a jetsam log). iOS refuses Metal GPU work in the background, so inference must stop before the app resigns active.

### Cited Findings
- **mlx-swift-examples #492** (opened 2026-08-17; **open**; no fix) **[R]**. Device and versions: iPhone 16 Pro (8 GB), iOS 26, mlx-swift-examples 2.29.1, mlx-swift 0.29.1. Test: 4,009-token prefill, `kvBits=8`.
  - Qwen3-1.7B-4bit completes with a supplied `KVCacheSimple` (713 MB) and with a supplied `QuantizedKVCache` (311 MB).
  - Qwen3-4B-Instruct-2507-4bit-DWQ **terminates** with either supplied cache, at about 1.1 GB `os_proc_available_memory()` free, with "no crash report, no NSException, and no jetsam event". With the MLX-managed cache (`cache: nil`) it completes (347 MB, 24.7 s).
  - macOS completes every case.
  - The reporter had to set `MLX.GPU.set(cacheLimit:)` to 32 MB, or even the managed cache failed.

  The maintainer (davidkoski) asked whether the app had the Increased Memory Limit entitlement. The workaround is `cache: nil`, which gives up cross-turn KV reuse; on macOS that reuse cut a 140-case suite from 522 s to 211 s. — [mlx-swift-examples #492](https://github.com/ml-explore/mlx-swift-examples/issues/492)
- **PocketPal AI #639**: an iOS memory limit blocked models larger than about 5 GB. PR #651 added the `increased-memory-limit` and `extended-virtual-addressing` entitlements, for about 1 GB more headroom, fixed in v1.13.1. **[S][M]** — [pocketpal-ai #639](https://github.com/a-ghorbani/pocketpal-ai/issues/639)
- PocketPal #594: models that used to load began crashing at load. The maintainer suggested turning off Memory Mapping. **[S]** — [pocketpal-ai #594](https://github.com/a-ghorbani/pocketpal-ai/issues/594)
- PocketPal #231: "recent models that crash the app" (tool-capable models suspected). On iOS they fail to load rather than crash. Closed. **[S][A]** — [pocketpal-ai #231](https://github.com/a-ghorbani/pocketpal-ai/issues/231)
- PocketPal #662: crash loop on load fixed in v1.13.3. **[S]** — [pocketpal-ai #662](https://github.com/a-ghorbani/pocketpal-ai/issues/662)
- PocketPal PR #955: fix for a crash when a model is released during a completion. **[S]** — [pocketpal-ai PR #955](https://github.com/a-ghorbani/pocketpal-ai/pull/955)
- **Entitlement effect, conflicting measurements** **[S][A]**:
  - Raises the limit: iPhone 13 Pro went from about 3.1 GB to about 4.2 GB `os_proc_available_memory()`; another device went from 3374 MiB to 6142 MiB at launch. — [zenn.dev: Two Entitlements to Boost Memory](https://zenn.dev/mtfum/articles/ios_memory_entitlements?locale=en); [Vocello entitlement doc](https://github.com/PowerBeef/Vocello/blob/main/docs/reference/ios-increased-memory-entitlement-request.md)
  - Ceiling did not move: on iPhone 17 Pro Max (12 GB), `phys_footprint + os_proc_available_memory` stayed at 8192 MiB with one, two or three entitlements. — [SceneWorks/inference PR #1272](https://github.com/SceneWorks/inference/pull/1272) or [cactus #793](https://github.com/cactus-compute/cactus/issues/793). The search summary did not say which of these two holds this measurement; verify before citing.
  - Physical RAM: the entitlement does not change the limit on iPhone 11 and earlier (4 GB), and it is "only available on some device models". — [besthub.dev](https://www.besthub.dev/articles/how-to-extend-ios-app-virtual-address-space-and-boost-memory-limits-c8d1ce1e247c)
- **MLX vs llama.cpp accounting**: MLX and Core ML copy weights into memory, so they count against the footprint allowance. llama.cpp and whisper.cpp map the file, so they count against the Metal working set. A separate report says the entitlement mainly raises a mapped-memory ceiling that is distinct from the roughly 2 GB jetsam cap. **[S][A]** — [Vocello doc](https://github.com/PowerBeef/Vocello/blob/main/docs/reference/ios-increased-memory-entitlement-request.md); [cactus #793](https://github.com/cactus-compute/cactus/issues/793)
- Another app fixed MLX models not fitting by adding the increased memory limit. **[S]** — [ByteRepair/entoli PR #523](https://github.com/ByteRepair/entoli/pull/523)
- **MLX buffer-cache growth**: "MLX can accumulate memory and cause the app to crash after just a couple of queries" (Gemma 3n on iOS). Fix: cap the GPU cache and use the entitlement. **[S][A]** — [Medium: Offline RAG on iOS with Gemma 3N](https://medium.com/google-cloud/building-offline-rag-on-ios-how-to-run-gemma-3n-locally-ffdfda6f7217)
- **Gemma on short-memory iPhones**: the private-mind app keeps Gemma from hanging or crashing when the iPhone runs short of memory (PR #457). It also stopped auto-reloading Gemma after it took the app down while starting (PR #460). It reports that on a phone where iOS holds about 3 GB it cannot hand back, Gemma 4 does not fit at all. **[S]** — [private-mind PR #457](https://github.com/software-mansion-labs/private-mind/pull/457); [private-mind PR #460](https://github.com/software-mansion-labs/private-mind/pull/460)
- Gemma 3n E2B through MediaPipe/LiteRT-LM: the roughly 3.14 GB model plus runtime exceeds per-process limits, and Jetsam kills it "even on 8GB devices". **[S][A]** — [HF google/gemma-3n-E2B-it-litert-lm discussion #9](https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/discussions/9)
- LFM2.5-2.6B: the 16-bit and 8-bit builds are killed by jetsam on a 6 GB iPhone 15 Plus. The 4-bit build (about 1.5 GB resident) works. **[A]** — [Hemeskyo/mlx-ios-toolcall](https://github.com/Hemeskyo/mlx-ios-toolcall)
- **Background GPU**: iOS rejects Metal command buffers submitted in the background (`MTLCommandBufferErrorNotPermitted` / `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`), whatever background-task assertions or audio modes the app holds.
  - The TTSMLX package cancels in-flight generation on resign-active, and ships a forked mlx-swift that swallows these errors in `check_error()`. — [fil-technology/TTSMLX](https://github.com/fil-technology/TTSMLX)
  - private-mind store crashes include an ExecuTorch Metal exception. — [private-mind #438](https://github.com/software-mansion-labs/private-mind/issues/438)
  - llama.cpp #16998: when the app is minimized during `llama_decode` from Swift, the GPU backend is unavailable and the process aborts. — [llama.cpp #16998](https://github.com/ggml-org/llama.cpp/issues/16998)

  **[S]**
- **Old devices**: Metal kernel compilation crashes on iPhone 11 (A13), even for a basic float32 matmul. **[S]** — [mlx-swift #526](https://github.com/ml-explore/mlx-swift/issues/526)
- mlx-swift-lm is adding memory tooling. "Report model used memory" (PR #746) merged 2026-10-30. "Estimate what generation will need before it runs" (PR #748) and "Let a ChatSession move its cache out and back" (PR #801) are open as of November 2026. **[S]** (titles) — [mlx-swift-lm search "memory OR iPhone OR jetsam"](https://github.com/ml-explore/mlx-swift-lm/issues?q=memory+OR+iPhone+OR+jetsam)

### Inferences
- On 8 GB iPhones, 3–4B 4-bit models fit with an MLX-managed cache and a small GPU cache limit. Supplying your own long-lived KV cache, or using long tool-schema prompts of about 4k tokens, is where reports show silent termination. Tool schemas should be kept short, and prefill length should be monitored with `os_proc_available_memory()`.
- Do not count on the increased-memory-limit entitlement for a specific number on newer devices. Measure `phys_footprint + os_proc_available_memory` on target hardware.
- Any inference path must cancel generation and stop GPU submission on `willResignActive`. Background modes do not make Metal available.

### Gaps
- I found no first-hand thermal-throttling measurements for sustained tool-calling sessions on iPhone.
- I found no vision-model (Gemma 3n/4 vision, SmolVLM, Qwen-VL) memory reports for specific iPhone RAM tiers in mlx-swift; the Gemma 3n reports found are text-only or MediaPipe.
- #492's root cause is unexplained, and the issue was still open as of 2026-08-17 with no reporter reply.

## Model-specific load and compatibility issues on iOS

### Takeaway
In 2026, Gemma 3n/4 caused the most runtime-specific trouble (shared-KV layers, template quirks, parser tags, memory). Qwen3/3.5 tool-call parsing has been repeatedly patched across runtimes. LFM2/LFM2.5/LFM3 support in mlx-swift-lm is current and has a dedicated Pythonic parser. Newer families (LFM3, Qwen3.8, DeepSeek-V4) are arriving as open PRs.

### Cited Findings
- Gemma 3n in Swift: the Layr-Labs fork lists RoPE-offset, sliding-mask, sanitize-key and batch-2 crash bugs in `Gemma3nText`. **[S]** — [Layr-Labs/mlx-swift-lm #195](https://github.com/Layr-Labs/mlx-swift-lm/issues/195)
- Gemma 3n in Python mlx-lm: shared-KV layers are incompatible with the batched cache, so the server returns garbage. **[S]** — [mlx-lm #1384](https://github.com/ml-explore/mlx-lm/issues/1384)
- The "Add Gemma 3n" PR in mlx-swift-examples (#340) was closed as a draft on 2026-04-13. **[S]** — [mlx-swift-examples search](https://github.com/ml-explore/mlx-swift-examples/issues?q=tool+call)
- Gemma 4 in mlx-swift-lm: wrong format inference (`gemma4`) and outdated parser tags, fixed by PR #183 / PR #548 (closed 2026-09-14). **[M]** — [mlx-swift-lm #259](https://github.com/ml-explore/mlx-swift-lm/issues/259)
- Python mlx-lm has a similar Gemma 4 report: native tool calls are not parsed and `tool_calls` stays empty. **[S]** — [mlx-lm #1096](https://github.com/ml-explore/mlx-lm/issues/1096)
- A Gemma 4 E2B fine-tune exported to LiteRT-LM loads, but its tool-call fidelity regresses against the MLX baseline. **[S]** — [litert-torch #1013](https://github.com/google-ai-edge/litert-torch/issues/1013)
- A Rapid-MLX maintainer could not reproduce empty tool calls with gemma-4-e2b-4bit and traced the reported failure to the client. **[S]** — [Rapid-MLX discussion #1062](https://github.com/raullenchai/Rapid-MLX/discussions/1062)
- LFM2 in mlx-swift-examples had a fix in Aug 2025 (PR #369). LFM3 text support merged in mlx-swift-lm 2026-11-06 (PR #750) and 2026-11-16 (PR #756). LFM3-VL and LFM3-Omni PRs (#781, #782) are open, and feature request #741 asks for LFM3-1.7B and LFM3-VL-2B. **[S]** (titles) — [mlx-swift-lm search "tool"](https://github.com/ml-explore/mlx-swift-lm/issues?q=tool); [mlx-swift-examples search](https://github.com/ml-explore/mlx-swift-examples/issues?q=tool+call)
- Other mlx-swift-lm items **[S]** (titles) — [mlx-swift-lm search "memory OR iPhone OR jetsam"](https://github.com/ml-explore/mlx-swift-lm/issues?q=memory+OR+iPhone+OR+jetsam):
  - Qwen3.5 MTP prompt chunked-prefill PR (#820, open 2026-11-20).
  - Qwen3.8-Flash-Next PR (#818, open).
  - NemotronH ran about 3x slower in decode because of a float32 weight (#751, closed 2026-11-04).
  - GPT-OSS dtype fix (#792, merged 2026-11-17).
- Qwen3 support was added to mlx-swift-examples on 2025-04-29 (PR #286). An older Chinese-text detokenizer garbling issue (#252) was closed 2025-04-09. **[M]** — [mlx-swift-examples search](https://github.com/ml-explore/mlx-swift-examples/issues?q=tool+call)
- Qwen3.6's XML tool-call format is not handled by one llama.cpp fork's `peg-native` parser (closed as not planned). **[S]** — [TheTom/llama-cpp-turboquant #199](https://github.com/TheTom/llama-cpp-turboquant/issues/199)

### Inferences
- Gemma 4 E2B/E4B on mlx-swift-lm needs a build after September 2026 for tool parsing, plus a harness that round-trips tool calls (AnyLanguageModel 1.1.0 or equivalent). Its template has known traps: recursive schemas, a missing `type`, and multi-turn tool rounds.
- Gemma 3n has accumulated more open runtime bugs (shared KV) than Gemma 4 in the sources found.

### Gaps
- I found no iOS-specific load or compat reports for SmolLM2/SmolLM3, Phi-4-mini, Granite or FunctionGemma in mlx-swift or llama.cpp iOS apps in this search pass.
- Llama 3.2's only finding is the one-tool-call-per-assistant-message template limit (#328).

## What developers report as working well, and what as unreliable, for on-device tool calling on iPhone

### Takeaway
The concrete iPhone evidence is thin and anecdotal. Qwen3 1.7B/4B and LFM2.5 (1.2B, or a 2.6B fine-tune) are the models most often reported as working. Gemma 4 E2B/E4B work only once the harness bugs are fixed, and the QAT variants are slightly less reliable. Speed claims run from about 18–28 tok/s decode for 1.7–2.6B 4-bit models on A17/A16-class phones up to "40 tok/s" for Gemma 4 in one talk.

### Cited Findings
- A test of 21 small models on tool-calling judgment (Feb 2026, Ollama on desktop, not iPhone) had four models tied at 0.880 Agent Score: lfm2.5:1.2b, qwen3:0.6b, qwen3:4b and phi4-mini:3.8b. LFM2.5 needs a bracket-notation parser. The recommended standard-format choice was qwen3:0.6b (0.880, 3.6 s), with qwen2.5:1.5b (0.840, 2.2 s) as the faster alternative. A commenter reported "very bad results" with LFM2.5. **[S][A]**; the source is a post by a Liquid AI employee citing an r/LocalLLaMA write-up (a potential conflict of interest). — [X post by @ramin_m_h](https://x.com/ramin_m_h/status/2022896926371311836)
- LFM2.5-2.6B QLoRA (trained on xlam-function-calling-60k), 4-bit MLX, on iPhone 15 Plus (6 GB): about 1.5 GB resident, about 120 tok/s prefill and about 28 tok/s decode, parsed by mlx-swift-lm `.lfm2`. No accuracy numbers are given. **[A]** — [Hemeskyo/mlx-ios-toolcall](https://github.com/Hemeskyo/mlx-ios-toolcall)
- Qwen3 1.7B is used for tool-use demos across iOS, macOS and visionOS with MLX Swift. **[S][A]** — [rudrankriyam/MLX-Outil](https://github.com/rudrankriyam/MLX-Outil)
- Qwen3-1.7B 4-bit runs at about 18–24 tok/s on A17 Pro (iPhone 15 Pro). Unverified blog figure. **[S][A]** — [DEV: Wiring MLX to a quantized on-device LLM for iOS](https://dev.to/software_mvp-factory/wiring-apples-mlx-framework-to-a-quantized-on-device-llm-for-ios-44eg)
- "Running Gemma 4 on-device: 40 tokens/s on iPhone with MLX" (talk title). **[S][A]** — [AI Engineer talk](https://ai.engineer/talks/a2muGkT4WD4-running-gemma-4-on-device-40-tokens)
- Gemma 4 E2B/E4B reached 6/6 correct on a calculator task after the history fix. The QAT variants reached 5/6 and 4/6 (one empty). Measured on macOS. **[R][M]** — [AnyLanguageModel #328](https://github.com/huggingface/AnyLanguageModel/issues/328)
- Device RAM, not chip generation, should drive model choice: iPhone 15 has 6 GB and iPhone 15 Pro 8 GB. **[S][A]** — [ertyurk.com](https://ertyurk.com/posts/on-device-llm-tool-calling/)
- Vendor sizing guide: Qwen3 1.5B or Phi-4 Mini for 6 GB iPhones; Llama 3.2 3B, Qwen3 4B or Gemma 3 for 8 GB Pro models. App-vendor content, not a benchmark. **[S][A]** — [DEV: run LLMs locally on iPhone 2026](https://dev.to/alichherawalla/how-to-run-llms-locally-on-your-iphone-in-2026-completely-offline-no-subscription-4b3a)
- Industry overview: on-device tool calling works but is less reliable than cloud, and cloud wins above 2–3 tools. **[S][A]** — [ztabs.co on-device LLMs 2026](https://ztabs.co/blog/on-device-llms-mobile-2026)
- Apple Foundation Models ran 30/30 tool runs without errors in the #328 comparison. This is a useful baseline when weighing an MLX model against the system model. **[R]** — [AnyLanguageModel #328](https://github.com/huggingface/AnyLanguageModel/issues/328)

### Inferences
- The best-supported shortlist for an iPhone tool-calling assistant in late 2026 is Qwen3-1.7B or 4B (4-bit, thinking off for tool turns), LFM2.5 (possibly fine-tuned), and Gemma 4 E2B (non-QAT) on a fixed harness. Keep the tool count small (2–3) and keep schemas flat.
- Reliability numbers depend heavily on the harness. Any internal evaluation should log rendered prompts per round, so the history and template bugs above can be ruled out before models are compared.

### Gaps
- I found no iPhone-measured tool-call success rates for any model. All controlled rates found are from macOS or desktop Ollama.
- I found no first-hand Reddit or Apple Developer Forums threads with numbers (the search did not surface them).
- I found no data on SmolLM3, Phi-4-mini, Granite or FunctionGemma tool-call reliability on iOS specifically.
