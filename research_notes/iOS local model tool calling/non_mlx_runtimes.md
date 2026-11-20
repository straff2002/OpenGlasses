# iOS on-device LLM tool calling on non-MLX runtimes (llama.cpp/GGUF, LiteRT-LM, Cactus, Foundation Models, MLC, ExecuTorch, ONNX GenAI)

Checked 2026-11-20. Star counts come from GitHub repo pages fetched that day and are approximate. Most claims come from README text, not code. Where a claim rests on code (llama.cpp `common/chat.h`), that is stated. All pages were read through a summarising fetch tool, so before acting on a detail, re-read the page itself. developers.googleblog.com could not be reached from this session (host not allowed), so the Google AI Edge Gallery function-calling post was not read directly.

## Which iOS-capable apps/libraries on non-MLX runtimes do on-device tool calling, and what models do they default to or recommend?

### Takeaway
Real on-device tool calling on iOS outside MLX is available today in:
- **llama.rn** (React Native; uses llama.cpp's own `common/chat.cpp` through minja).
- **PocketPal AI**, built on llama.rn ("Talents" with an `AgentRunner` tool loop).
- **LLM.swift** (Swift, native-format tool calls through llama.cpp `common/chat`).
- **LocalLLMClient** (Swift, `@Tool` macro, marked experimental).
- **Cactus's React Native/Flutter SDKs**, with default model `qwen3-0.6b` and cloud handoff. The cactus-react-native repo was archived 2026-07-23.
- **Google LiteRT-LM** (Swift API in "Early Preview"; FunctionGemma 270M; the AI Edge Gallery app is on iOS).
- **Apple Foundation Models** (`Tool` protocol).

Model recommendations cluster on very small Qwen models (Qwen3-0.6B Q4_K_M or INT8, Qwen2.5-1.5B-Instruct Q4_K_M), Gemma 3 4B QAT Q4_0 for general use, and FunctionGemma 270M as a specialist. SpeziLLM's local path is MLX, and the README describes function calling only for OpenAI. ExecuTorch, MLC LLM and ONNX Runtime GenAI showed no documented iOS tool calling.

### Cited Findings

**llama.rn (mybigday/llama.rn): React Native binding for llama.cpp**
- About 1.1k stars, 137 forks. v0.10+ requires React Native's New Architecture. No release date was visible on the page. — [llama.rn](https://github.com/mybigday/llama.rn)
- README: "universal tool call support by using minja", linked to llama.cpp `common/chat.cpp`. Models with native support follow `chat.cpp`; others fall back to a GENERIC format that always outputs a JSON object (`{"response": "..."}` when no tool is called). Tools go in `context.completion({ tools, tool_choice: 'auto' })`, and the result exposes `tool_calls`. — [llama.rn](https://github.com/mybigday/llama.rn)
- GBNF grammar support, plus a built-in JSON-Schema→GBNF converter used by `response_format: { type: 'json_schema' }`. — [llama.rn](https://github.com/mybigday/llama.rn)
- iOS requirements:
  - Metal needs an Apple7 GPU at minimum (A14 / iPhone 12 and later, by Apple's Metal feature tables).
  - Metal does not work in the iOS Simulator.
  - The README recommends enabling the **Extended Virtual Addressing** and **Increased Memory Limit** capabilities.
  - It ships a prebuilt `rnllama.xcframework`; `RNLLAMA_BUILD_FROM_SOURCE=1` builds from source.
  - Source: [llama.rn](https://github.com/mybigday/llama.rn)
- Also does multimodal (mmproj; images, audio, video frames tuned for Qwen3-VL), embeddings (nomic-embed-text-v1.5-GGUF) and rerankers. — [llama.rn](https://github.com/mybigday/llama.rn)

**PocketPal AI (a-ghorbani/pocketpal-ai): iOS/Android app**
- About 9.6k stars. Runtime stack listed as "`llama.rn` `0.13.0-rc.11` → llama.cpp b12292 · GGUF". — [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai)
- Tool calling through "Talents": Pals "call built-in tools" in "a tool-use loop".
  - Built-in talents: `calculate`, `datetime`, `render_html`, `web_search` (opt-in), `read_url` (opt-in).
  - An `AgentRunner` "drives each chat turn" and handles streaming, tool dispatch and feeding results back.
  - The README says nothing about MCP.
  - Source: [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai)
- Roadmap item: "Tool use expansion … deepen the agentic loop so Pals can do more, fully on-device". — [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai)
- The README names no exact default model ids, only families ("Gemma, Qwen, Phi, Llama, and more"). Uses Metal on iOS. It states no iPhone or RAM requirements. — [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai)

**LLM.swift (eastriverlee/LLM.swift): Swift wrapper over llama.cpp**
- About 883 stars. No release dates were visible. — [LLM.swift](https://github.com/eastriverlee/LLM.swift)
- Tool calling:
  - Tools conform to a `Tool` protocol, and their arguments use `@Generatable`.
  - Calls use "the model's native format, handled by llama.cpp's `common/chat` machinery".
  - Results land in `toolCalls`, with up to `maxToolTurns` rounds (default 4).
  - The README claims `@Generatable` gives "100% reliable" structured output. That is a README claim; the README does not say whether grammar enforces it.
  - Source: [LLM.swift](https://github.com/eastriverlee/LLM.swift)
- Example models: `unsloth/Qwen3-0.6B-GGUF` at `.Q4_K_M`, and a bundled `gemma-3-4b-it-q4_0.gguf`. Device anecdotes: a Mistral 7B model at Q5_K_M on an iPad Air 5, and at Q2_K on an iPhone 12 mini. The README recommends models of 3B parameters or fewer on mobile. — [LLM.swift](https://github.com/eastriverlee/LLM.swift)

**LocalLLMClient (tattn/LocalLLMClient): Swift; llama.cpp + MLX + Foundation Models**
- About 219 stars, 270 commits on main. — [LocalLLMClient](https://github.com/tattn/LocalLLMClient)
- "Tool calling (experimental)" through the `@Tool("get_weather")`, `@ToolArguments`, `@ToolArgument` and `@ToolArgumentEnum` macros. "Tool calling is only available with models that support this feature." The README does not say how calls are parsed (chat template vs `common/chat`). — [LocalLLMClient](https://github.com/tattn/LocalLLMClient)
- Models:
  - Tool-calling example: `Qwen/Qwen2.5-1.5B-Instruct-GGUF` / `qwen2.5-1.5b-instruct-q4_k_m.gguf`.
  - General: `lmstudio-community/gemma-3-4B-it-qat-GGUF` / `gemma-3-4B-it-QAT-Q4_0.gguf`.
  - Vision: `ggml-org/gemma-3-4b-it-GGUF` Q8_0 + `mmproj-model-f16.gguf`.
  - Overlaps with MLX via `mlx-community/Qwen3-1.7B-4bit`.
  - Source: [LocalLLMClient](https://github.com/tattn/LocalLLMClient)
- iOS 17.0+ (the Foundation Models backend needs iOS 26 and Apple Intelligence). Suggests the `com.apple.developer.kernel.increased-memory-limit` entitlement. Demoed on an iPhone 16 Pro. — [LocalLLMClient](https://github.com/tattn/LocalLLMClient)

**SpeziLLM (StanfordSpezi/SpeziLLM)**
- About 290 stars. The README says SpeziLLMLocal runs on `mlx-swift`, so it is MLX, not llama.cpp; this researcher could not confirm whether it ever used llama.cpp. Function calling ("declarative Domain Specific Language to utilize OpenAI function calling") is described only for the SpeziLLMOpenAI backend. SpeziLLMFog sends inference to LAN fog nodes found over mDNS. The README notes that some models need the Increase Memory Limit entitlement and that the local backend does not run in simulators. — [SpeziLLM](https://github.com/StanfordSpezi/SpeziLLM)

**Cactus (cactus-compute)**
- The core repo `cactus-compute/cactus` has about 14.9k stars. On 2026-11-20 its README documents a **Python** package with a "Needle 3" tool-calling model (`@cactus.tool`, `run()` / `complete()`), plus Whistle (speech) and Mirage (vision). It does not mention iOS, React Native or Flutter, and it does not name the engine. — [cactus](https://github.com/cactus-compute/cactus)
- **cactus-react-native was archived on 2026-07-23** (about 181 stars). README API:
  - `cactusLM.complete({ messages, tools })` returns `result.functionCalls`.
  - Options `forceTools` (default false) and `toolRagTopK` (default 2: "Number of tools to select via RAG when tool list is large").
  - Default LM `'qwen3-0.6b'`; examples `'lfm2-vl-450m'` and `'gemma-4-e2b-it'`; quantization `'int8'` by default, `'int4'` optional.
  - Source: [cactus-react-native](https://github.com/cactus-compute/cactus-react-native)
- Hybrid: `confidenceThreshold` (default 0.7) is the "Confidence threshold below which cloud handoff is triggered". STT has an entropy-based `cloudHandoffThreshold`. — [cactus-react-native](https://github.com/cactus-compute/cactus-react-native)
- A Flutter package exists (`cactus` 1.3.0 on pub.dev). Search snippets say the Flutter/RN SDKs support a `tools` option, Qwen3-0.6B is 394 MB, and "Qwen3 600m [excels] at tool calling". These are secondary snippets, not read in full. — [pub.dev cactus](https://pub.dev/packages/cactus); [HF blog](https://huggingface.co/blog/rshemet/cactus-on-device-inference)
- Self-reported speeds from search snippets: Gemma3 1B Q4 at about 54 tok/s and Qwen3 4B Q4 at about 18 tok/s on iPhone 16 Pro Max; about 49 and 16 on iPhone 16. — [HF blog](https://huggingface.co/blog/rshemet/cactus-on-device-inference); [InfoQ](https://www.infoq.com/news/2025/12/cactus-on-device-inference)

**Flutter llama.cpp wrappers**
- fllama (Telosnex/fllama): the README claims OpenAI-compatible chat including function calling, on iOS, macOS, Android, Windows, Linux and Web with Metal. The pub.dev docs do not document tool calling. — [fllama](https://github.com/Telosnex/fllama); [pub.dev fllama](https://pub.dev/documentation/fllama/latest/)
- llamadart (pub.dev): its docs describe tool definitions "advertised in the format the loaded model's family expects, calls parsed back out of the raw token stream", plus a `ChatSession.sendWithTools` loop. Source is a search snippet. — [llamadart](https://pub.dev/documentation/llamadart/0.19.11/)
- llamafu and llm_llamacpp also claim tool calling (llamafu with grammar-constrained generation; llm_llamacpp "via prompt convention"). Both are early (0.1.x). — [llamafu](https://www.pub.dev/packages/llamafu); [llm_llamacpp](https://pub.dev/documentation/llm_llamacpp/latest/)

**Google LiteRT-LM / AI Edge Gallery**
- LiteRT-LM: about 6.9k stars, v0.19.0. Platforms are "Android, iOS, Web, Desktop, and IoT". Swift is marked "Early Preview" for native iOS/macOS. "Tool Use: Function calling support for agentic workflows". v0.19.0 adds "Accelerated Logit Masking … faster constrained decoding on GPUs". Example ids: `litert-community/gemma-4-E4B-it-litert-lm` (with MTP speculative decoding) and `google/gemma-3n-E2B-it-litert-lm` (int4). The README does not say how tool use is implemented. — [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
- FunctionGemma is a function-calling fine-tune of Gemma 3 270M. Model card: BFCL Simple 61.6, BFCL Multiple 63.5 (0-shot). — [FunctionGemma model card](https://ai.google.dev/gemma/docs/functiongemma/model_card?hl=en)
- AI Edge Gallery shipped on iOS with "Mobile Actions" and "Tiny Garden" FunctionGemma demos (post dated 2026-02-26 in search results; not read directly). — [Google Developers Blog](https://developers.googleblog.com/on-device-function-calling-in-google-ai-edge-gallery/)
- Artifacts: `litert-community/functiongemma-270m-ft-mobile-actions` and a q8 / EKV1024 `.litertlm` build. — [HF](https://huggingface.co/litert-community/functiongemma-270m-ft-mobile-actions); [HF q8](https://huggingface.co/litert-community/functiongemma-mobile-actions_q8_ekv1024.litertlm)
- Fine-tuning guide for Mobile Actions. — [ai.google.dev](https://ai.google.dev/gemma/docs/mobile-actions)
- Field notes:
  - A community export says the LiteRT-LM Python runtime returns FunctionGemma calls as raw text that you parse yourself. — [soniqo export](https://huggingface.co/soniqo/FunctionGemma-270M-LiteRT-LM)
  - An HF discussion reports intermittent degenerate repeated-EOS output with the iOS Swift API and native tool calling. — [HF discussion](https://huggingface.co/litert-community/functiongemma-270m-ft-mobile-actions/discussions/2)
  - FunctionGemma expects the `developer` role, not `system`, to enter function-calling mode (search-result summary of the blogs above).
  - A December 2025 post said LiteRT-LM did not support iOS yet. That is now outdated. — [Medium](https://medium.com/google-developer-experts/on-device-function-calling-with-functiongemma-39f7407e5d83)

**ExecuTorch / MLC LLM / ONNX Runtime GenAI**
- The ExecuTorch iOS LLM guide covers text and multimodal runners (generate, load, stop, reset) and calls the runner APIs experimental. It has no tool-calling section. — [ExecuTorch run-on-ios](https://docs.pytorch.org/executorch/stable/llm/run-on-ios.html)
- An arXiv comparison (2511.05502) describes MLC-LLM's OpenAI-style server and iOS SDK but says nothing about function calling. — [arXiv 2511.05502](https://arxiv.org/pdf/2511.05502)
- No source was found for ONNX Runtime GenAI tool calling on iOS.

### Inferences
- The only non-MLX stacks that hand an iOS app a model-agnostic tool-call parser are those that compile llama.cpp's `common/` into their binary: llama.rn (and so PocketPal) and LLM.swift. Everyone else either writes per-model parsing (LiteRT-LM/FunctionGemma raw text, llamadart) or relies on a vendor-tuned model (Cactus Qwen3-0.6B, Needle; Apple's model).
- The consistent pick for small-model tool calling is Qwen-family at 0.6B–1.7B (Qwen3-0.6B Q4_K_M or INT8, Qwen2.5-1.5B Q4_K_M). Gemma 3 4B Q4_0/QAT is the "general chat" default rather than a tool-calling default.
- Cactus's move from mobile SDKs (RN archived) to a Python/"Needle" product makes it a risky dependency for a new iOS build. Treat its RN/Flutter SDKs as stale.

### Gaps
- No exact default model id was found for PocketPal Talents.
- Release dates and last-commit dates for llama.rn, LLM.swift, LocalLLMClient, SpeziLLM and fllama were not visible on the fetched pages.
- It was not confirmed in code whether LocalLLMClient's llama backend uses `common/chat.cpp` or its own parser.
- MLC LLM's iOS SDK docs were not fetched directly. Whether its OpenAI-style engine accepts `tools` on iOS is unconfirmed.
- No source was found for ONNX Runtime GenAI on iOS with tool calling.

## Which model families does llama.cpp's chat/tool-call handling natively support, and is that code path usable from an iOS app?

### Takeaway
Two sources disagree, and the code is newer. llama.cpp's `docs/function-calling.md` still lists the older native set:
- Llama 3.1/3.2/3.3
- Functionary v3.1/v3.2
- Hermes 2/3, Qwen 2.5 / 2.5 Coder
- Mistral Nemo
- FireFunction v2
- Command R7B
- DeepSeek R1 (WIP)
- GPT-OSS / LLM-jp (Harmony)

Everything else uses a "Generic" JSON fallback. The current `common/chat.h`, however, no longer has a per-model enum: formats are now `CONTENT_ONLY`, `PEG_SIMPLE`, `PEG_NATIVE`, `PEG_GEMMA4` and `PEG_MINIMAX_M3`, parsed by a PEG parser, with lazy grammars and grammar triggers.

All of this lives in `common/` and the Jinja engine, not in `libllama`. iOS wrappers that want it compile `common` (and minja) themselves: llama.rn does, and LLM.swift says it does.

### Cited Findings
- Native formats on the docs page:
  - Llama 3.1/3.3 (with builtin tools `wolfram_alpha`, `brave_search` / `web_search`, `code_interpreter`) and Llama 3.2
  - Functionary v3.1/v3.2
  - Hermes 2/3, Qwen 2.5, Qwen 2.5 Coder
  - Mistral Nemo
  - FireFunction v2
  - Command R7B
  - DeepSeek R1 ("WIP / seems reluctant to call any tools?")
  - GPT-OSS (Harmony) and LLM-jp-4.1
  - Source: [llama.cpp function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- Gemma and GLM templates map to Generic in that doc's table. Qwen3, LFM2, Kimi and Granite are not listed as native; Granite appears only in a usage example. — [function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- Generic fallback: "Generic tool call is supported when the template isn't recognized by native format handlers", and it "may consume more tokens and be less efficient than a model's native format". `--chat-template-file` overrides the template. — [function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- Server use needs `--jinja` and a tools-enabled template (check `chat_template` / `chat_template_tool_use` at `/props`). `parallel_tool_calls` is off by default. Extreme KV quantization (e.g. `-ctk q4_0`) "can substantially degrade" tool-calling performance. The original implementation was PR #9639. — [function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- Code (`common/chat.h`, master as of 2026-11-20):
  - The `common_chat_format` enum is now `CONTENT_ONLY`, `PEG_SIMPLE`, `PEG_NATIVE`, `PEG_GEMMA4`, `PEG_MINIMAX_M3`, with the comment "These are intended to be parsed by the PEG parser".
  - `common_chat_params` carries `bool grammar_lazy`, `std::vector<common_grammar_trigger> grammar_triggers` and a `common_peg_arena parser`.
  - Inputs carry `parallel_tool_calls` (default false), `tool_choice` (`AUTO` / `REQUIRED` / `NONE`) and `reasoning_format`.
  - Source: [common/chat.h](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/common/chat.h)
- Gemma 4 has its own dedicated PEG format (`COMMON_CHAT_FORMAT_PEG_GEMMA4`). — [common/chat.h](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/common/chat.h)
- llama.rn uses minja plus `common/chat.cpp` ("universal tool call support"), and falls back to GENERIC JSON for unrecognised templates. — [llama.rn](https://github.com/mybigday/llama.rn)
- PocketPal pins llama.rn 0.13.0-rc.11 → llama.cpp b12292, so it gets whatever `common/chat` is in that build. — [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai)
- LLM.swift: tool calls are "handled by llama.cpp's `common/chat` machinery". — [LLM.swift](https://github.com/eastriverlee/LLM.swift)

### Inferences
- `function-calling.md` lags the code. The per-family list it gives is historical, and the refactor to PEG-parsed formats (`PEG_NATIVE` driven by the template) suggests support is now derived from each model's Jinja template rather than hand-coded per family. A report writer should say this precisely and point readers to `chat.h` / `chat.cpp` at the pinned build, not to the doc.
- An iOS app linking only the plain llama.cpp core (for example via the XCFramework or SPM package) gets no tool parsing. It must vendor `common/chat*`, the PEG parser and the Jinja engine, as llama.rn and LLM.swift do, or parse model output itself. This is inferred from where the code lives; no source was found that states the official llama.cpp XCFramework excludes `common`.
- Because templates drive the parser, the GGUF must carry a tools-capable chat template. Quantisers' GGUFs sometimes ship an older template, and an override template may be needed (the docs give DeepSeek R1 as an example).

### Gaps
- `common/chat.cpp` was not read, so the exact list of templates that `PEG_NATIVE` recognises today (Qwen3, Qwen3-Coder XML, LFM2, Granite, GLM-4.5, Kimi K2 and others) could not be listed from code.
- The commit or date of the PEG refactor was not found.

## How do apps use grammar-constrained decoding to make small models emit valid tool calls, and what performance cost do they report on iPhone?

### Takeaway
In llama.cpp-based stacks, constrained decoding for tool calls is **lazy**. `common/chat` produces a grammar plus "grammar triggers", so free text is unconstrained and the grammar only engages once the model emits a tool-call opener. `tool_choice: required` forces it. Apps also expose plain GBNF and JSON-Schema→GBNF (llama.rn). Apple guarantees schema-valid tool arguments through guided generation, and LiteRT-LM added GPU logit masking for constrained decoding. No source reported a measured iPhone performance cost for grammar-constrained tool calls.

### Cited Findings
- `common_chat_params` exposes `grammar`, `grammar_lazy` and `grammar_triggers`, and `tool_choice` has a `REQUIRED` value. — [common/chat.h](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/common/chat.h)
- llama.rn: a GBNF `grammar` parameter and a JSON-Schema→GBNF converter used by `response_format` with `json_schema`. — [llama.rn](https://github.com/mybigday/llama.rn)
- LLM.swift `@Generatable`: README claims "100% reliable type-safe structured output". The README does not say how that is enforced. — [LLM.swift](https://github.com/eastriverlee/LLM.swift)
- llamafu advertises grammar-constrained generation alongside tool calling. — [llamafu](https://www.pub.dev/packages/llamafu)
- LiteRT-LM v0.19.0: "Accelerated Logit Masking … faster constrained decoding on GPUs". — [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
- Apple (Frameworks Engineer, Apple forums, June 2026): "Guided generation ensures that tool arguments will always follow the defined arguments schema", and "If a schema somehow cannot be satisfied, the framework will produce an error." — [Apple forum 833642](https://developer.apple.com/forums/thread/833642)
- Cactus avoids large tool lists with `toolRagTopK` (default 2), which retrieves the relevant tools before prompting. — [cactus-react-native](https://github.com/cactus-compute/cactus-react-native)

### Inferences
- With lazy grammars, a small model still chooses on its own whether to call a tool. The grammar only fixes the syntax of a call once one starts, so tool-selection errors (wrong tool, or no call when one is needed) remain. Apple's guarantee is similar: it covers the argument schema, not the decision.
- Shrinking the tool list (Cactus tool-RAG; Apple's "3–5 tools") is the main lever reported for small models, ahead of grammar.

### Gaps
- No measured tokens/s cost of GBNF or lazy-grammar sampling on an iPhone was found in any source. The llama.cpp docs, llama.rn and PocketPal give none.
- No published accuracy numbers were found for Qwen3-0.6B or 1.7B tool calling on device with versus without grammar.

## How does Apple's Foundation Models framework tool calling compare (what apps use it, context window limits, reported reliability)?

### Takeaway
Foundation Models (iOS 26+, Apple Intelligence devices) offers a `Tool` protocol with `Generable` arguments, called automatically by the session. Apple says arguments always match their schema. The hard limit is a **4096-token context per session** shared by instructions, tool schemas, tool inputs and outputs, and responses. Apple advises 3–5 tools with one-phrase descriptions, running deterministic tools before the model, and splitting work across sessions. Of the libraries researched, only LocalLLMClient wraps it alongside llama.cpp.

### Cited Findings
- TN3193 (first published 2025-10-06; updated 2026-03-31 for the iOS 26.4 APIs) on budget and token counting:
  - "Apple's on-device foundation model has a context window of 4096 tokens per language model session."
  - Everything counts against it: "instructions, all prompts, the information of tools (schemas, input, and output), `Generable` schemas, and all the model's responses."
  - `SystemLanguageModel.tokenCount(for:)` counts instructions, prompts, tools, schemas and transcript entries.
  - Source: [TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)
- TN3193 on tool use:
  - Tool definitions (name, description, parameters) go in the prompt, and tool output returned to the model "consumes additional tokens".
  - "Keep your tool description and `@Guide` descriptions to a short phrase each. Give the model a maximum of 3–5 tools to choose from."
  - Skip tool calling when information is always needed: run the tool first and inline its result. Alternatively, generate arguments in one session and process the output in a second.
  - Source: [TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)
- On overflow, the framework throws `LanguageModelSession.GenerationError.exceededContextWindowSize`. Recovery means a new session seeded from a condensed `transcript`. — [TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)
- Apple Frameworks Engineer, June 2026:
  - "The on-device model has a 4K context window."
  - Tool arguments always follow the schema.
  - "There is currently no pinning or model version retrieval API" (use the Evaluations framework to catch regressions).
  - "The OS limits the amount of concurrent requests to the model", and access may be limited in background tasks on iOS.
  - Source: [Apple forum 833642](https://developer.apple.com/forums/thread/833642)
- The accepted (non-Apple) answer in the same thread contradicts that: "Tool calling is not guaranteed deterministic — the model can produce arguments that don't validate". It also says PCC is 32K. Treat this as unverified. — [Apple forum 833642](https://developer.apple.com/forums/thread/833642)
- The context-size error count can read slightly above 4096 because it reports the count at the moment the limit tripped (Apple forums). — [Apple forum 806542](https://developer.apple.com/forums/thread/806542)
- LocalLLMClient exposes Foundation Models as a backend ("iOS 26.0+ / macOS 26.0+ and requires Apple Intelligence"). — [LocalLLMClient](https://github.com/tattn/LocalLLMClient)

### Inferences
- Compared with llama.cpp stacks, Foundation Models has no model download, no memory entitlement and grammar-enforced arguments. It is limited by a fixed 4K window, a model version the app cannot pin, OS-level throttling, and only Apple Intelligence-capable iPhones (iPhone 15 Pro and later; the device list was not verified in this research). A 3–5-tool budget suits a narrow voice-assistant tool set but not a large tool catalogue.

### Gaps
- The `Tool` protocol reference page did not render through the fetch tool, so the exact signatures (for example the `call(arguments:)` return type) and parallel tool-call behaviour are not verified here.
- No open-source iOS app was found and confirmed to ship Foundation Models tool calling in production. None was checked beyond LocalLLMClient.
- No published reliability or accuracy benchmark for Foundation Models tool selection was found.

## Any hybrid designs (on-device model for routing/tool selection, cloud for the rest)?

### Takeaway
Cactus is the clearest example: confidence-thresholded "cloud handoff" for completions (default 0.7) and entropy-thresholded handoff for speech-to-text, plus tool-RAG to pre-select tools. SpeziLLM offers runtime choice between local (MLX), LAN "fog" nodes and OpenAI, with function calling only on the OpenAI path. Apple's TN3193 recommends a split-session pattern (generate tool arguments, run the tool in code, process in a new session) that maps onto local routing with a separate executor.

### Cited Findings
- Cactus RN: `confidenceThreshold` (default 0.7) is the "Confidence threshold below which cloud handoff is triggered". STT has `cloudHandoffThreshold` ("Max entropy threshold above which cloud handoff is triggered"). `toolRagTopK` defaults to 2. The repo was archived 2026-07-23. — [cactus-react-native](https://github.com/cactus-compute/cactus-react-native)
- SpeziLLM: SpeziLLMLocal (mlx-swift), SpeziLLMFog (dispatches "to a random fog node" found over mDNS) and SpeziLLMOpenAI (function-calling DSL). — [SpeziLLM](https://github.com/StanfordSpezi/SpeziLLM)
- Apple: "generate those [tool arguments] in one session, then run your tool using normal programming, then have the model process the tool's output in a new, second session". — [TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)
- FunctionGemma is positioned as a tiny specialist that turns natural language into function calls on device (Mobile Actions). — [FunctionGemma model card](https://ai.google.dev/gemma/docs/functiongemma/model_card?hl=en); [Google blog](https://blog.google/technology/developers/functiongemma/)

### Inferences
- The pattern that recurs across these sources is a small model (270M–0.6B) or Apple's model doing intent/tool selection over a short, retrieved tool list. Escalation to a larger local model or the cloud happens on low confidence. No source here measured end-to-end accuracy of such a router on iPhone.

### Gaps
- Apart from Cactus's thresholds, no open-source iOS app was found that documents a local-router / cloud-executor design with measured results.
- Whether Cactus's current Python/"Needle" product keeps cloud handoff could not be determined from its README.
