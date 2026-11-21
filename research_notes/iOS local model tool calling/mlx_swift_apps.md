# iOS/iPadOS apps and Swift libraries doing on-device tool calling through Apple MLX (mlx-swift / mlx-swift-lm)

Checked 2026-11-20. GitHub star counts are as WebFetch showed them on that date. Commit dates are given only where a page showed them. "README says" means the README or project description claims it; "code shows" means a source file was read.

## Which iOS apps/libraries using MLX Swift do on-device tool calling, and which models do they default to or recommend?

### Takeaway
Few open-source iOS projects really run tool calls on device through MLX Swift. They are small demos and SDKs, and none is a large app. The verifiable ones are MLX-Outil (Qwen3 1.7B), mlx-ios-toolcall (a fine-tuned LFM2.5-2.6B at 4-bit, using mlx-swift-lm's `.lfm2` parser), LocalLLMClient (experimental tools; MLX example `mlx-community/Qwen3-1.7B-4bit`), AnyLanguageModel (MLX backend with tools; example `mlx-community/Qwen3.5-4B-MLX-4bit`) and SwiftAgent (Qwen3 only; `mlx-community/Qwen3-4B-Instruct-4bit`). The best-known open iOS MLX chat app, fullmoon, has no tool calling and has been stale since May 2025. The defaults cluster on **Qwen3 / Qwen3.5 at 1.7B–4B, 4-bit**, with **LFM2.5** as the small, fast alternative.

### Cited Findings

**Inventory**

| Project | Type / platform | Stars (2026-11-20) | Activity | Tool calling | Models named |
|---|---|---|---|---|---|
| rudrankriyam/MLX-Outil | Demo app + `MLXTools` package; iOS 17+, macOS 14+, visionOS 1+ | 125 | GitHub topic page shows "updated Jan 15, 2026" | Yes: MLXLMCommon tool definitions via `UserInput(chat:tools:)` | "Qwen 3 1.7B" (no exact HF id in README) |
| Hemeskyo/mlx-ios-toolcall | iPhone SwiftUI demo | 1 | 4 commits; date not shown | Yes: mlx-swift-lm `toolCallFormat: .lfm2`, app-side dispatch to real system actions | `Hskyto/lfm2.5-2.6b-toolcall-mlx-q4` (QLoRA-tuned LFM2.5-2.6B, 4-bit, ~1.5 GB) |
| tattn/LocalLLMClient | Swift package (llama.cpp / MLX / FoundationModels backends); iOS 17+ | 219 | release list empty on page | Experimental `@Tool` macro + `LLMSession(model:tools:)` | MLX: `mlx-community/Qwen3-1.7B-4bit`; llama.cpp tool example `Qwen/Qwen2.5-1.5B-Instruct-GGUF` (q4_k_m) |
| mattt/AnyLanguageModel | Swift package mirroring the Foundation Models API; MLX trait depends on mlx-swift-lm; iOS 17+ | 990 | install snippet `from: "1.4.1"`; Swift 6.3+/Xcode 26.4+ | Yes for MLX (all providers except Core ML) | MLX example `mlx-community/Qwen3.5-4B-MLX-4bit` |
| mzbac/SwiftAgent | Agent framework, MLX provider + MCP; README says iOS 16+, macOS 14+ | 15 | 3 commits; date not shown | "Native support for Qwen3 tool calling", "XML-style formatting" | `mlx-community/Qwen3-4B-Instruct-4bit` (most examples); `mlx-community/Qwen3-0.6B-Instruct-4bit` (perf section) |
| Tom-Ryder/AgentRunKit | Swift 6 agent SDK; `AgentRunKitMLX` links mlx-swift-lm; iOS 18+ | 38 | `from: "6.1.0"` | Typed tools (the README does not say how MLX tool calls are parsed) | No local model ids given (Quick Start uses a cloud model) |
| SharpAI/SwiftLM (+ SwiftBuddy iOS app) | MLX Swift OpenAI-compatible server (macOS) + iPhone/iPad app | 802 | 918 commits; release b782 | Not documented: only the OpenAI `/v1/chat/completions` surface; the README warns 2-bit quantization "heavily destabilizes JSON grammars" | iOS catalog by family only (Qwen3, Phi-3.5, Mistral, Llama); server examples such as `mlx-community/Qwen2.5-3B-Instruct-4bit` |
| mainframecomputer/fullmoon-ios | iOS/iPadOS/macOS chat app | ~2.3k | **Stale**: latest commits May 5, 2025 | **None** (not mentioned) | `mlx-community/Llama-3.2-1B-Instruct-4bit`, `Llama-3.2-3B-Instruct-4bit`, `DeepSeek-R1-Distill-Qwen-1.5B-4bit` |
| abra-code/mlx-agent | **macOS**: Swift agent on mlx-swift-lm with an MCP tool loop | not fetched | not fetched | Yes (README: MCP tool loop with a permission gate before mutating tools) | not fetched |
| ml-explore/mlx-swift-examples (LLMEval, llm-tool) | Reference apps / CLI | 2.7k | libraries moved to mlx-swift-lm | llm-tool CLI: `--tool-time` demo tool | CLI default `LLMRegistry.mistral7B4bit` |

Sources and details per project:
- MLX-Outil: "show tool usage with Qwen 3 1.7B model using MLX Swift across iOS, macOS, and visionOS"; it ships an `MLXTools` package (Weather via WeatherKit/OpenMeteo, HealthKit workouts, DuckDuckGo web search, Calendar, Contacts, Location, Apple Music, Reminders); tools are passed as `[any ToolProtocol]` through `UserInput(chat:tools:)`; MIT; iOS 17.0+ (README claim) — [MLX-Outil](https://github.com/rudrankriyam/MLX-Outil). The last update "Jan 15, 2026" comes from the search snippet of the mlx-swift topic listing — [GitHub topic mlx-swift](https://github.com/topics/mlx-swift) (the activity page could not be read, so this is unverified).
- mlx-ios-toolcall: the model `Hskyto/lfm2.5-2.6b-toolcall-mlx-q4` is a 4-bit MLX build of LiquidAI/LFM2.5-2.6B, ~1.5 GB, downloaded on first launch. It carries a QLoRA adapter trained on `Salesforce/xlam-function-calling-60k` (training repo Hemeskyo/lfm-qlora, hyperparameters not given). Parsing uses mlx-swift-lm `toolCallFormat: .lfm2`, and the app adds a tool registry plus a name→handler `dispatch` router to EventKit (reminders/calendar), Maps URLs, UNUserNotifications timers and `sms:` — [mlx-ios-toolcall](https://github.com/Hemeskyo/mlx-ios-toolcall)
- LocalLLMClient: tool calling is marked experimental. The README shows a `@Tool("get_weather")` struct with `@ToolArguments`/`@ToolArgument`/`@ToolArgumentEnum` and `call(arguments:)`, registered via `LLMSession(model:tools:)`, and warns that only models that explicitly support tool calling work, with backend-dependent compatibility. Its demo video captioned "iPhone 16 Pro" includes an MLX clip (`mlx-qwen2.5.mov`) — [LocalLLMClient](https://github.com/tattn/LocalLLMClient)
- AnyLanguageModel: "Tool calling is supported by all providers except Core ML". For MLX, `required` tool choice is "Not supported: tools offered as usual", so MLX cannot force a tool call, and the MLX runtime runs `onToolCall`/`onToolOutput`. The README does not say whether mlx-swift-lm's parser does the parsing (the MLX trait "depends on `ml-explore/mlx-swift-lm`", so that is likely but unconfirmed) — [AnyLanguageModel](https://github.com/mattt/AnyLanguageModel)
- SwiftAgent: "Native support for Qwen3 tool calling" with "XML-style formatting"; tools are discovered from connected MCP servers — [SwiftAgent](https://github.com/mzbac/SwiftAgent)
- AgentRunKit: iOS 18.0+/macOS 15.0+, Swift 6.1+; `AgentRunKitFoundationModels` needs iOS 26+. The README does not describe MLX tool-call parsing — [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit)
- SwiftLM/SwiftBuddy: an iPhone/iPad app that downloads `mlx-community` models and shows RAM-fit indicators. The author says it runs on an iPhone 13 Pro (6 GB). The README has no tool-calling section beyond the OpenAI-compatible API and recommends 4-bit as the production standard for MoE — [SwiftLM](https://github.com/sharpai/swiftlm)
- fullmoon: the README has no tool calling and lists models as above — [fullmoon-ios](https://github.com/mainframecomputer/fullmoon-ios). Last commits May 5, 2025 ("add-qwen3", "add-memory-threshold" PRs) — [fullmoon commits](https://github.com/mainframecomputer/fullmoon-ios/commits/main)
- mlx-agent (macOS): native Swift local-LLM agent on mlx-swift-lm; MLX, OpenAI-compatible or Apple Foundation Models backend; MCP tool loop — [mlx-agent](https://github.com/abra-code/mlx-agent) (search-result summary only, not fetched)
- mlx-swift-examples `llm-tool` (code shows): `--tool-time` appends `timeTool.schema` to `toolSpecs`; `generate` switches on `case .toolCall(let toolCall):` and dispatches with `toolCall.execute(with: timeTool).toolResult`. The `EvaluateCommand`/ChatSession path passes `tools:` but ignores tool calls (`default: break`). The text default model is `LLMRegistry.mistral7B4bit` — [LLMTool.swift](https://github.com/ml-explore/mlx-swift-examples/blob/main/Tools/llm-tool/LLMTool.swift). The LLMEval README mentions "tool integration", and the libraries moved to mlx-swift-lm — [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples)
- mlx-swift-lm's own README example loads `LLMRegistry.gemma3_1B_qat_4bit`, and the MLXFoundationModels example uses `LLMRegistry.qwen3_0_6b_4bit`. Neither is presented as a tool-calling recommendation — [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm); [MLXFoundationModels](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels)

### Inferences
- Across projects the de facto on-device tool-calling default is a Qwen3-family model at 1.7B–4B in 4-bit (`mlx-community/Qwen3-1.7B-4bit`, `Qwen3-4B(-Instruct)-4bit`, `Qwen3.5-4B-MLX-4bit`). LFM2.5 (1.2B/2.6B) is the speed-oriented alternative and needs the Pythonic `.lfm2` parser.
- Every working on-device example keeps tool execution in app code (a name→handler dispatcher), whether through mlx-swift-lm `ToolCall` or a wrapper SDK. None hands execution to the model runtime.
- I found no widely used, maintained **open-source iOS app** (as opposed to a demo or SDK) that does MLX tool calling. Closed apps such as Locally AI were out of scope and not verified.

### Gaps
- Commit dates for MLX-Outil, mlx-ios-toolcall, LocalLLMClient, AnyLanguageModel, SwiftAgent and AgentRunKit were not visible on the fetched pages, so I could not confirm any of them as active or stale.
- MLX-Outil's exact HF model id was not visible in its README (likely an `LLMRegistry` Qwen3 1.7B 4-bit entry, but unverified).
- PocketMind, "MLX Chat" clones, Swift-Transformers-based apps and preternatural-explore/mlx-swift-chat were not verified for tool calling. They did not come up as tool-calling projects in searches.

## How does mlx-swift-lm expose tool calling (APIs, supported model families, known gaps)?

### Takeaway
mlx-swift-lm (877 stars) has first-class tool calling. You pass `[ToolSpec]` into `UserInput` or `ChatSession(tools:toolDispatch:)`, and the library injects them into the chat template, parses model output through a per-family `ToolCallFormat` parser (14 formats as of 3.33.0) and emits `.toolCall` / `.rejectedToolCall` generation events. Dispatch is fail-closed: only declared tools reach the callback. Configurable multi-format parsing arrived in **2.30.6 (Feb 2026)**, and most per-family fixes came in 2.31.3 → 3.32.3 (Apr–Sep 2026). There is also an Apple Foundation Models adapter (`.toolCalling` capability, `@Generable` guided generation) that needs the iOS 27 SDK.

### Cited Findings

**API surface (code shows)**
- `ChatSession` initializers take `tools: [ToolSpec]? = nil, toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil`. `toolDispatch` is "required for toolcalls if streaming strings rather than details". "Automatic dispatch is fail-closed: only calls naming a function declared in `tools`" reach it; with no tools "every tool-call-shaped model output is rejected". Rejected calls surface as `Generation.rejectedToolCall(_:)` in `streamDetails`, or as a thrown `RejectedToolCallError` under automatic dispatch. Tool results go back via `respond(to messages:)`/`streamResponse(to messages:)`, and an internal `restart: while !pendingMessages.isEmpty` loop restarts on tool calls. No round cap was visible in the part of the file I read — [ChatSession.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/ChatSession.swift)
- `Libraries/MLXLMCommon/Tool/` contains `Tool.swift`, `ToolCall.swift`, `ToolCallFormat.swift`, `ToolCallFormatInference.swift`, `ToolCallProcessor.swift`, `ToolCallPolicy.swift`, `ToolCallRecoveryPolicy.swift`, `TextToolCallRecoveryScanner.swift`, `ToolSchemaValidator.swift`, `ToolArgumentNormalization.swift`, `RejectedToolCall.swift`, `TokenStreamDecoder.swift`, `ToolParameter.swift`, `Value.swift` — [Tool dir](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXLMCommon/Tool)
- `Tool/Parsers/` holds 26 files, including `JSONToolCallParser`, `Llama3ToolCallParser`, `MistralToolCallParser`, `GemmaFunctionParser`, `GLM4ToolCallParser`, `PythonicToolCallParser` (LFM2), `Qwen35ToolCallParser`, `QwenXMLPayloadScanner`, `XMLFunctionParser`, `KimiK2ToolCallParser`, `MiniMaxM2ToolCallParser`, `MiniCPM5ToolCallParser`, `ATEMToolCallParser`, Harmony* (GPT-OSS) and Onyx* files — [Parsers dir](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXLMCommon/Tool/Parsers)

**`ToolCallFormat` cases (code shows, main @ 2026-11-20)** — [ToolCallFormat.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/Tool/ToolCallFormat.swift)
| Case | Families (doc comment) | Wire syntax |
|---|---|---|
| `json` | "Default JSON format used by Llama, Qwen, and most models" (Qwen/Hermes) | `<tool_call>{"name":…,"arguments":{…}}</tool_call>` |
| `lfm2` | LFM2 / LFM2.5 | `<|tool_call_start|>[func(arg='value')]<|tool_call_end|>` (Pythonic) |
| `xmlFunction` | Nemotron, Qwen3 Coder, Qwen3 Next | `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>` |
| `qwen35` | Qwen 3.5 | `<tool_call>` frame accepting XML or Hermes-JSON payload |
| `glm4` | GLM4 (+ GLM-4-0414 markerless dialect) | `<tool_call>func<arg_key>k</arg_key><arg_value>v</arg_value></tool_call>` |
| `gemma` | Gemma (FunctionGemma) | `<start_function_call>call:name{key:value,…}<end_function_call>` |
| `gemma4` | Gemma 4 | `<|tool_call>call:name{key:<|"|>value<|"|>}<tool_call|>` |
| `kimiK2` | Kimi K2 | `functions.name:0<|tool_call_argument_begin|>{…}` |
| `minimaxM2` | MiniMax M2 | `<invoke name="f"><parameter name="k">v</parameter></invoke>` |
| `miniCPM5` | MiniCPM5 (new in 3.33.0) | `<function name="f"><param name="k">v</param></function>` |
| `atem` | doc comment reads "Muse Glimmer's Onyx ATEM invoke/parameter format" (unfamiliar family; reported verbatim) | `<atem:function_calls><atem:invoke …>` |
| `mistral` | Mistral V11+ | `[TOOL_CALLS]get_weather [ARGS]{…}` |
| `llama3` | Llama 3 | `<|python_tag|>{"name":…,"parameters":{…}}` |
| `gptOSS` | GPT-OSS Harmony | `<|channel|>commentary to=functions.name<|message|>{…}<|call|>` |

**Format selection (code shows)** — [ToolCallFormatInference.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/Tool/ToolCallFormatInference.swift)
- Precedence: explicit `tool_parser_type` → format inferred from chat-template markers (e.g. `<|tool_list_start|>`→lfm2, `<arg_key>`→glm4, `[TOOL_CALLS]`→mistral, `<|tool_call>`→gemma4, `<start_function_call>`→gemma, `<tool_call>`+`<function=`→xmlFunction, `<tool_call>`+`tool_call.name`→json) → the model's own `modelFormat`. If nothing matches it returns `nil`, and no parser is selected. Harmony and Onyx are never inferred from template text.
- `tool_parser_type` aliases include `function_gemma`, `glm47`, `pythonic`, `qwen3_coder`, `qwen3_xml`, `json_tools`.

**Release history for tool calling** — [Releases](https://github.com/ml-explore/mlx-swift-lm/releases). The page showed day and month only. Years are inferred as 2026 from the order (2.29.x Jan → 3.33.0 Nov).
- 2.30.6 (18 Feb): "Add configurable tool call parsing with support for multiple model formats" (#78); LFM2.5 Pythonic syntax (#91); "Add tools parameter to ChatSession" (#107).
- 2.31.3 (01 Apr, last 2.x): optional toolCall dispatch + tool output injection (#114); multiple tool calls in ChatSession (#162); fixes for Mistral 3 (#132), Qwen3.5 (#133), LFM2.5 VL (#139), LFM2 nested parens (#152).
- 3.31.3 (15 Apr): "Fix tool calling for Llama 3" (#145); qwen3_next format inference (#166); Gemma 4 models (#180, #185).
- 3.31.4 (30 Jun): tools schema passed to ToolCallProcessor for type-aware parsing (#167); stringified JSON arguments (#172); GemmaFunctionParser for Gemma 4 (#183); JSON detection hardening (#205).
- 3.32.3 (30 Sep): assistant tool_calls recorded before tool results (#409); Gemma params converted by schema type (#388); `$defs` hoisting (#434); tool input prepared through the model's processor (#435); **multi-round tool calling in MLXFoundationModels** (#456); "Fix lfm2 toolcall parser and glm4 gate GLM-4-0414" (#481).
- 3.33.0 (17 Nov): `ToolCallFormat.miniCPM5` (#637), a breaking change because exhaustive switches need a new arm; new models Qwen 3.8, LFM2.5, LFM3, Nemotron.
- Hermes and Kimi do not appear by name in the release notes. Kimi is a code-level format (`kimiK2`).

**Foundation Models adapter** — [MLXFoundationModels README](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels); [mlx-swift-lm README](https://github.com/ml-explore/mlx-swift-lm)
- `MLXLanguageModel` conforms to Apple's `FoundationModels.LanguageModel` and works with `LanguageModelSession`. Capabilities are declared up front (default `[.guidedGeneration]`; also `.toolCalling` "Expose Swift `Tool`s to the model", `.reasoning`, `.vision`), and exceeding them "fails with a typed error". It requires the **macOS/iOS/visionOS 27.0 SDK**, behind the `FoundationModelsIntegration` trait.
- Guided generation through `respond(to:generating:)` with `@Generable`: the README says output "always matches the schema"; the schema is injected into the system prompt by default (`includeSchemaInPrompt: false` turns that off).

### Inferences
- A wearer-facing iOS app can rely on mlx-swift-lm's parsers for Qwen3/Qwen3.5, LFM2/2.5, Gemma 3/4, Llama 3, Mistral 3 and GLM4. Pin a 3.32+ release, since many family fixes landed between April and September 2026.
- Format choice is driven by the model's tokenizer/chat template, so a re-quantized community build with a modified template could silently pick the wrong parser or none (`nil`). That is worth a startup check.
- The "always matches the schema" claim for `@Generable` implies constrained decoding in the adapter. I did not read the code to confirm whether it uses grammar masking or validate-and-retry.

### Gaps
- I did not see a cap on tool-call rounds in `ChatSession` (the file was truncated at 100k chars).
- What `atem`/"Muse Glimmer's Onyx" refers to is unclear from the source.
- There is no official tool-calling guide in the mlx-swift-lm docs that I could find. Searches returned only third-party skill pages — [search results e.g. skills.lc](https://skills.lc/PicoMLX/mlx-swift-lm-skill/picomlx-mlx-swift-lm-skill-mlx-swift-lm-skill-md).

## What device / memory constraints do these projects state?

### Takeaway
The stated constraints are thin. Most projects give only OS minimums (iOS 16/17/18; iOS 26/27 for Foundation Models paths). Concrete numbers: 6 GB iPhones handle a 4-bit 2.6B model (~1.5 GB resident) but crash on 8/16-bit builds, and SwiftBuddy runs on a 6 GB iPhone 13 Pro. Apple's own LLMEval sample and LocalLLMClient use or recommend `com.apple.developer.kernel.increased-memory-limit`. MLX does not run on the iOS Simulator.

### Cited Findings
- mlx-ios-toolcall measured on an **iPhone 15 Plus (6 GB)**: ~120 tok/s prefill, ~28 tok/s decode, ~1.5 GB resident, ~4 s for a reminder request. "16-bit and 8-bit builds reportedly crash on 6 GB iPhones". MLX does not run on the Simulator (use a device or "My Mac (Designed for iPad)"). The increased-memory-limit entitlement is not mentioned — [mlx-ios-toolcall](https://github.com/Hemeskyo/mlx-ios-toolcall)
- Apple's LLMEval sample entitlements set `com.apple.developer.kernel.increased-memory-limit` = true (plus app-sandbox, user-selected read-only files, network client) — [LLMEval.entitlements](https://raw.githubusercontent.com/ml-explore/mlx-swift-examples/main/Applications/LLMEval/LLMEval.entitlements)
- LocalLLMClient recommends adding `com.apple.developer.kernel.increased-memory-limit` "for running larger models more reliably". It needs iOS 17.0+/macOS 14.0+ and Xcode 16+; its FoundationModels backend needs iOS 26+ with Apple Intelligence — [LocalLLMClient](https://github.com/tattn/LocalLLMClient)
- SwiftBuddy: the author says it runs on an iPhone 13 Pro (6 GB), the model catalog shows RAM-fit indicators, and the app has "a 30-second grace period on app switches". No minimum iOS or RAM is stated — [SwiftLM](https://github.com/sharpai/swiftlm)
- AnyLanguageModel: iOS 17.0+; Apple Foundation Models needs iOS 26; Private Cloud Compute needs iOS 27 plus an entitlement; Swift 6.3+/Xcode 26.4+; MLX tests must run via `xcodebuild` — [AnyLanguageModel](https://github.com/mattt/AnyLanguageModel)
- AgentRunKit iOS 18.0+ — [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit). SwiftAgent iOS 16+ (README claim) — [SwiftAgent](https://github.com/mzbac/SwiftAgent). MLX-Outil iOS 17.0+ with HealthKit/WeatherKit/EventKit/Contacts/MusicKit/Location permissions, no RAM figure — [MLX-Outil](https://github.com/rudrankriyam/MLX-Outil)
- The mlx-swift-lm FoundationModels path requires the iOS 27.0 SDK (iOS 26 `@available` on `@Generable` types, an iOS 27 runtime check on the model) — [mlx-swift-lm README](https://github.com/ml-explore/mlx-swift-lm)
- The iOS Simulator lacks the Metal features mlx-swift needs, so a physical device is required — [search summary citing MLX sample-app write-up](https://antran.app/2024/mlx_swift_examples/)
- fullmoon merged a PR titled "add-memory-threshold" (May 2025), but the README states no spec — [fullmoon commits](https://github.com/mainframecomputer/fullmoon-ios/commits/main)

### Inferences
- For a 6 GB iPhone, a 4-bit model of up to ~2–3B parameters (~1.5–2 GB weights) is the demonstrated ceiling for tool calling. 4B 4-bit models (~2.5 GB) probably need the increased-memory-limit entitlement and an 8 GB device (iPhone 15 Pro and later). That last point is an inference; no project states it.
- None of the projects states a context-length cap for on-device tool calling. Tool schemas inflate the prompt, so the KV cache adds to the resident memory figures above.

### Gaps
- No project states a minimum iPhone model or RAM tier for its recommended tool-calling model, other than mlx-ios-toolcall's 6 GB observation.
- No project documents a context-length cap.

## Do any compare models for tool-calling quality on device, or publish their own evals?

### Takeaway
No project publishes an **on-iPhone, MLX** tool-calling accuracy comparison. The closest is the macOS project Fae, which runs tool-calling evals through mlx-swift-lm. In Feb 2026 it found Qwen3.5 scoring 20% because mlx-swift-lm did not parse its XML-parameter tool calls; a Qwen3.5 parser fix shipped in mlx-swift-lm 2.31.3 (Apr 2026). By April 2026 it showed Qwen3.5-2B/4B and Gemma 4 E2B/E4B (4-bit) at 90–100%. Desktop CPU benchmarks rank Qwen3-1.7B first and LFM2.5-1.2B as the best speed/quality option. iPhone-only measurements cover speed and memory, not accuracy.

### Cited Findings
- **Fae (macOS, mlx-swift-lm; M4 Max and M2 Ultra, 96 GB)**: in the Swift MLX section (Feb 2026), `mlx-community/Qwen3-8B-4bit` scored 10/10 on tool calling, while `NexVeridian/Qwen3.5-35B-A3B-4bit` and `Qwen3.5-27B-4bit` scored 2/10. The page attributes this to Qwen3.5 emitting `<function=…><parameter=…>` XML "rather than the JSON that mlx-swift-lm parses", with tool selection itself correct. Current results (2026-04-02, Tool column): Qwen3.5-2B OptiQ 90%, Gemma 4 E2B 4-bit 100% / 8-bit 90%, Qwen3.5-4B 4-bit 100%, Gemma 4 E4B 4-bit 100% / 8-bit 70% / bf16 70% / mxfp4 40%, Qwen3.5-9B 100%, Qwen3.5-35B-A3B 100%. It concludes that "4-bit is the best quantization for Gemma tool calling" and that MXFP4 is worse than uniform 4-bit. RAM-tier recommendations (Swift section): under 32 GB → Qwen3-1.7B, 32–47 GB → Qwen3-4B. It also reports mlx-swift-lm decode slower than Python mlx-lm (Qwen3-8B 52.8 vs 70.2 tok/s; Qwen3.5-35B-A3B 11.7 vs 85.1 tok/s), attributed to per-token GPU→CPU sync — [Fae llm-benchmarks.md](https://github.com/saorsa-labs/fae/blob/main/docs/benchmarks/llm-benchmarks.md)
- The mlx-swift-lm releases include "Fixed tool calling for qwen3.5" (#133, 2.31.3, 01 Apr) and a dedicated `qwen35` format accepting XML or Hermes-JSON, which matches the Fae failure mode — [Releases](https://github.com/ml-explore/mlx-swift-lm/releases); [ToolCallFormat.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/Tool/ToolCallFormat.swift)
- **lintware/tool-calling-benchmark (not MLX, not iOS)**: despite the repo blurb mentioning M3 Ultra and MLX, the README results come from a Framework 13 (Ryzen AI 7 350, CPU-only) on Ollama/llama.cpp. It uses 12 prompts × 20 runs and an Agent Score = 0.4·Action + 0.3·Restraint + 0.3·Wrong-tool-avoidance. Scores: qwen3:1.7b 0.960 (10.7 s), lfm2.5:1.2b 0.920 (1.6 s, needs a bracket-notation parser), qwen3:0.6b 0.880, qwen2.5:1.5b and ministral-3:3b 0.800, phi4-mini 0.780, gemma3:1b 0.690, llama3.2:3b 0.660 (restraint 0.0), functiongemma 0.640, llama3.2:1b 0.430. The author notes "parameter count is a weak predictor" and that even the best model misses ~10% — [lintware/tool-calling-benchmark](https://github.com/lintware/tool-calling-benchmark)
- Callstack PR #349 benchmarks Qwen3 0.6B on an iPhone 17 Pro across runtimes including MLX, for speed and memory only (search-snippet summary, not fetched) — [callstackincubator/ai#349](https://github.com/callstackincubator/ai/pull/349)
- Liquid AI (vendor-reported): LFM2.5-2.6B beats Qwen3.5-9B on ToolSandbox, 77.83 vs 76.44 — [AlphaSignal](https://alphasignal.ai/news/liquid-ai-s-lfm2-5-2-6b-beats-9b-models-running-entirely-on-your-phone) (secondary source; the vendor's own post was not fetched)
- mlx-ios-toolcall, SwiftAgent, AgentRunKit, MLX-Outil and LocalLLMClient report no tool-calling accuracy evals — [mlx-ios-toolcall](https://github.com/Hemeskyo/mlx-ios-toolcall); [SwiftAgent](https://github.com/mzbac/SwiftAgent); [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit). SwiftLM reports speed, memory and needle tests only — [SwiftLM](https://github.com/sharpai/swiftlm)

### Inferences
- On-device tool-calling quality in Swift depends on parser coverage as much as on the model. The Fae 20% result came from a parser gap, not from the model. Any eval should be run through the same mlx-swift-lm version that ships, not through Python mlx-lm.
- For phone-sized budgets, the evidence (desktop and Mac, not iPhone) points to Qwen3-1.7B / Qwen3.5-2B–4B / Gemma 4 E2B–E4B at uniform 4-bit as the accuracy picks and LFM2.5-1.2B as the latency pick. Avoid 2-bit (SwiftLM warning) and MXFP4 (Fae).

### Gaps
- I found no published head-to-head tool-calling accuracy eval run on an iPhone with MLX Swift.
- The Liquid AI ToolSandbox figure is vendor-reported and was seen only through a secondary outlet.
