# Plan GC — OpenAI API reasoning with tools via `/v1/responses`

**Status:** 📋 Planned 2026-09-30 — follows Plan [GB](GB-field-test-round-3.md) P0, which clamps
reasoning to `none` whenever function tools ride on `/v1/chat/completions` for the OpenAI API
provider. This plan routes those turns through `/v1/responses` so the technician's chosen effort
actually applies during tool-calling turns. One PR. **Owed after merge (device, live key):** one
real reasoning tool turn on `gpt-6-sol` and one on `gpt-5.5` over the API, with latency and cost per
turn read from the tracker and compared with the provider's bill.

**Trigger:** GB's field-test run: `gpt-6-sol` returned HTTP 400 *"Function tools with
reasoning_effort are not supported … use /v1/responses or set reasoning_effort to 'none'"* on every
Direct-mode turn (tools are always attached). GB fixed the dead-end by clamping to `none` on Chat
Completions and showing the clamp in the model editor's "Effective with tools" line; it deferred the
real fix — this plan — because it needs the Responses request shape on the API-key route.

Paths are under `OpenGlasses/Sources/` unless noted. Line numbers are `main` @ `2bab2c11`.

## Outcome

- A saved OpenAI API model with an explicit reasoning level above `none` runs its tool turns on
  `POST https://api.openai.com/v1/responses` at that level; reasoning is carried across the tool
  round-trips of a turn so the model does not re-think from scratch after every tool result.
- **Automatic** (the default, and the tester's per-model preference is "default cheap") stays on Chat
  Completions at `none`: no cost or latency change for anyone who did not ask for reasoning.
- Non-reasoning models (`gpt-4o`, `gpt-4.1`, `gpt-5-chat-latest`) never move. Custom and Azure hosts
  stay on Chat Completions unless the model's base URL itself names a Responses endpoint.
- The model editor's "Effective with tools" line names the endpoint and why; every turn records the
  route in the turn trace and the privacy log; the usage tracker prices Responses usage with cached
  tokens counted once.
- If Responses refuses a model (4xx), the turn retries **once** on Chat Completions at `none` with a
  distinct log marker; the model is remembered for the rest of the run so later turns route straight
  to Chat Completions. The retried request keeps GB's rule that a 400 is terminal in the cascade.

## How the field tester uses it (end to end)

**Setting it, once per model.** Settings → Models → edit the OpenAI API model (for example `gpt-6-sol`
or `gpt-5.5`) → **Reasoning**. The picker is unchanged from GB: Automatic, None, Minimal, Low,
Medium, High, Extra high. The setting is saved with the model and reused on every job; nothing is
set per job. Two saved models can carry different levels (a cheap Automatic `gpt-5.5` for routine
jobs and a Medium `gpt-6-sol` for hard diagnostics), and switching between them is the normal model
switch.

**What the two read-only lines now say.**
- Automatic → "Effective with tools: None · Chat Completions — Automatic keeps tool turns on Chat
  Completions without reasoning, to stay quick and cheap." This is GB's behaviour, unchanged, and
  it is the default for every saved model that never touched the picker.
- Medium (or any level above None) → "Effective with tools: Medium · Responses API — this level
  needs the Responses API when tools are attached." and "Effective without tools: Medium · Chat
  Completions — as set for this model."
- None → "Effective with tools: None · Chat Completions — as set for this model."
- A non-reasoning model (`gpt-4.1`, `gpt-4o`) → "Not applicable — this model has no reasoning
  setting." on both lines; the picker still shows but changes nothing.
- A custom or Azure host → "… · Chat Completions — custom hosts stay on Chat Completions unless the
  base URL names a Responses endpoint." When the base URL ends in `/responses` the line reads
  "… · Responses API — the base URL names a Responses endpoint."
The footer still says reasoning tokens are billed as output.

**What happens on a turn, with a level above None set.**
1. He speaks; the wake word, transcription and prompt build are unchanged.
2. The route selector sees OpenAI API + reasoning family + explicit level + tools attached and picks
   Responses at his level. The request goes to `api.openai.com/v1/responses` with the same system
   prompt (stable head as `instructions`, the volatile tail last), the same tools, `store: false`,
   `include: ["reasoning.encrypted_content"]`, `prompt_cache_key`, and an output cap of at least
   4096 so reasoning cannot starve the answer.
3. If the model calls a tool (`field_session`, `manual_lookup`, `vision_assess`…), the tool runs as
   today. The next request in the same turn replays the model's encrypted reasoning item ahead of
   the tool result, so the model continues from where it was instead of re-thinking the whole
   problem after every tool. Reasoning is never shown or stored in the transcript.
4. The final answer is spoken and shown exactly as before. Turn details (long-press a turn, or the
   Developer panel's turn timeline) shows `reasoning: medium` and `route: responses`.
5. The usage tracker records the request's input, cached and output tokens from the Responses usage
   block, priced at the model's row; the cost per job on the Job tab and the spend caps (GB P5)
   include these turns. Reasoning tokens are inside the output count, which is why a Medium turn
   costs more than a None turn on the same model.

**What he should expect in cost and latency.** Reasoning tokens bill as output, and output is the
expensive side of every OpenAI price row; a Medium tool turn will typically emit several hundred to
a few thousand reasoning tokens before its answer, so per-turn cost and time-to-first-word both
rise. The GB spend-cap warning and the per-job cost line are the way to watch it. Automatic is the
way back to GB's cheap behaviour for a model; None keeps Chat Completions and sends an explicit
`none`.

**When something refuses.** If Responses answers a 4xx that is not authentication or rate limiting
(a model the API does not accept on that endpoint, a rejected shape), the same turn is retried once
on Chat Completions at `none`: he hears an answer, later turns on that model go straight to Chat
Completions for the rest of the run, and the turn's details show `route: chatCompletions` with a
`routeFallback` marker in the diagnostics export. The editor line does not change, because the
refusal is per run; a relaunch tries Responses again. Authentication, rate-limit and 5xx failures
behave exactly as today (cascade rules, retry rules).

**Photos.** A photo turn on a model with `Supports vision` on (the default for OpenAI API models)
goes to Responses as an `input_image`, the same picture pipeline as today. With vision switched off
for the model, the photo is dropped with the existing note, as on Chat Completions.

**What he does not have to do.** Nothing per job; no new toggle; no change to the base URL for
api.openai.com; no re-entry of the API key. The ChatGPT subscription model is untouched.

**What we ask him to confirm on the device (owed):** one tool turn on `gpt-6-sol` at Medium and
one on `gpt-5.5` at Medium, each with at least one tool call; the Turn details route and reasoning
tokens; the tracker's cost for those turns against the provider's dashboard; and time-to-first-word
compared with the same models at Automatic.

## Coverage across features (where the route must apply)

Every OpenAI API request in the app funnels through `LLMService.sendOpenAICompatible`
(`Services/LLMService.swift:2130`), so the route selector is consulted **inside that function**,
before the URL is built — not at the voice dispatch — and the Responses path is entered from there.
That one seam covers all of the following; the table records what each surface gets and the tests
that pin it.

| Surface | Entry | Tools | Route with an explicit level above None | Notes |
|---|---|---|---|---|
| Voice turn (wake word, glasses, CarPlay, Siri/App Intents, watch relays) | `sendMessage` → `.openai` case (`:940`) | yes | Responses | The field tester's main path. Cascade (`sendMessageCascading`) wraps it; a Responses 4xx is handled by the route fallback first, a 5xx/429 by the cascade as today |
| Chat tab, typed or dictated, streaming | `sendTextMessage` → `sendMessageCascading(onToken:)` | yes | Responses, streamed | `streamResponsesTurn` already delivers deltas; `onStreamReset` clears the bubble before the fallback's retry |
| Photo turns (`capturePhotoAndSend`, `sendPhotoToLLM`, `captureAndAnalyzePhoto`) | `sendMessage(imageData:)` | yes | Responses with `input_image` when `visionEnabled` | Same picture pipeline; with vision off the image is dropped with the existing note |
| Quick actions and HUD launcher actions | `executeQuickAction` → `sendMessage` | yes | Responses | |
| Field Assist guided job turns (`field_session`, `manual_lookup`, `vision_assess` tool calls) | the voice/chat turn above | yes | Responses, reasoning replayed across each tool round-trip | GB's job history floor and `APIHistoryBudget` (`:3878`) still select the request history; `RequestContextBudget` adds the capacity guard |
| Agentic fast tier, cloud agent | `sendCloud(includeTools: hasNativeTools)` (`:1787`, `:3822`) | yes | Responses | Would be silently left on Chat Completions if the hook sat at the voice dispatch — the reason the hook is inside `sendOpenAICompatible` |
| OpenClaw notification triage and clarification | `sendMessage` | yes | Responses | |
| Agent notification queue (background) | `sendMessage` | yes | Responses | 120 s request timeout as on the subscription path |
| Stateless completions (recall summaries, study, memory loop) | `completeStateless` (`:1120`) | no | Chat Completions (Decision 2) | `reasoning_effort` rides there when set |
| Side calls: `analyzeFrame`, `analyzeFrameStructured`, `completeStructured`, summarisation | their own builders (`:1455-1764`) | no | Chat Completions | Unchanged |
| Small-context (lean) models | `smallContext` in `sendOpenAICompatible` | as configured | Same selector | The lean prompt is the `instructions`; nothing else differs |
| HIPAA / medical local-only | `enforceMedicalRemoteBoundary` (`:2131`) | — | Refused before any route | The Responses path keeps the same first line |
| ChatGPT subscription | `sendChatGPT` | yes | Untouched | Shared translator additions default to today's behaviour |
| Gemini, Anthropic, Groq, Mistral, xAI, OpenRouter, custom without `/responses` | their paths / `sendOpenAICompatible` | — | Unchanged | Selector returns `otherProvider` / `customHostChat` |

The fake-transport tests exercise three of these through the real `sendOpenAICompatible`: a
streamed Chat-tab-style turn, a non-streamed voice-style turn with one tool call and reasoning
replay, and the cloud-agent entry.

## Verified starting point (`main` @ `2bab2c11`)

- `LLMService.sendOpenAICompatible` (`Services/LLMService.swift:2130`) is the only API-key path for
  `.openai`; it appends `/chat/completions` to the base URL (`:2136-2142`), resolves
  `ReasoningPolicy` with `toolsAttached` (`:2223`), raises the tool-turn cap through
  `Resolution.outputCap` (`:2230`), sets `prompt_cache_key` for `.openai` (`:2249`), lays the prompt
  out as `PromptLayout.chatMessages(stable:history:volatile:)` (`:2213`) and has GB's one retry at
  `none` on the classified 400 (`:2352-2366`).
- `sendChatGPT` (`:2462`) is the only Responses-shape path: `ChatGPTAuth` headers, the chatgpt.com
  endpoint, `RequestContextBudget.resolve` (`LLM/RequestContextBudget.swift:36-49`) which recognises
  only that host and gives every other endpoint 32k, `budgetedResponsesTurn` (`:2603`) with the one
  overflow recovery, `streamResponsesTurn` (`:2660`) over `streamingSession` (stubbable), and
  `refreshedFieldInstructions` (`:2581`) rebuilt every iteration.
- `ResponsesTranslator` (`LLM/ResponsesTranslator.swift`) is provider-neutral except that
  `requestBody` hard-codes `store: false` and `stream: true`, `inputItems` knows only chat-shape
  messages (no reasoning items), and `parseOutput` drops `reasoning` items ("not ours to consume",
  `:113`). `StreamAccumulator` already collects `response.output_item.done` items and prefers the
  envelope's `output` when it carries items (`:145-152`).
- `ReasoningPolicy` (`LLM/ReasoningPolicy.swift`): `ReasoningRoute.route(for:)` maps `.openai` to
  `.chatCompletions` unconditionally (`:52-60`); the `.responses` branch (`:301-310`) sends
  `reasoning.effort` and knows no tools clamp; `openAIFamily` (`:95-119`) marks only `gpt-6*` as
  `rejectsReasoningWithToolsOnChat`.
- `ChatGPTVisionGate` (`LLM/ChatGPTVisionGate.swift`) declines images for `.chatgpt` only; the API
  path attaches images when `ModelConfig.visionEnabled` says so (`LLMService.swift:2151-2182`).
- `UsageTracker.parseUsage` (`Services/Usage/UsageTracker.swift:88-134`) parses the Responses usage
  shape (`input_tokens` + `input_tokens_details.cached_tokens`) only under `.chatgpt`; `.openai`
  expects `prompt_tokens`, so a Responses reply on the API route would count as an unrecognised
  shape and its cost would be lost.
- `ModelFallbackChain.classify` (`Services/ModelFallbackChain.swift:111`) makes 400/422 terminal for
  the turn.
- `ModelReasoningSection` (`App/Views/ModelReasoningSection.swift`) shows "Effective with tools" /
  "Effective without tools" from `ModelConfig.reasoningResolution(toolsAttached:)`.
- `TurnRecorder.noteReasoning` (`Services/Diagnostics/TurnRecorder.swift:320`) and
  `PrivacyLog.ModelEvent.reasoningResolved/.reasoningRetried` (`Utils/PrivacyLog.swift:1435`) are
  the trace and log seams GB added.

## What the provider documents (verified 2026-09-30)

Read on 2026-09-30 from the provider's developer documentation (reasoning, function-calling,
prompt-caching, migrate-to-responses, conversation-state, images-vision guides; the Responses
create and streaming-events reference; the per-model pages and the pricing page; the reasoning-items
cookbook) and the provider's Python SDK type files. Items marked *inferred* or *community* are not
stated by the provider's docs.

- **Effort vocabulary:** `none | minimal | low | medium | high | xhigh | max`, per model. `gpt-6-astra`
  and `gpt-6.1-sol` accept `low`…`max` only (`none` is a 400); `gpt-6.1-sol` defaults to `medium`,
  `gpt-6-astra`'s default is not stated. `gpt-6-sol`, `gpt-6-luna` and every `gpt-5.6-*` accept
  `none` plus `low`…`max`, default `medium`. `gpt-5.5` accepts `none`…`xhigh`, default `medium`.
  `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2`, `gpt-5.1` **default to `none`**. `gpt-5` accepts
  `minimal`…`high`, default `medium`. o3 / o4-mini accept `low|medium|high` (default not stated).
  The app keeps `max` out of the picker (GB). There is no bare `gpt-6` id; `gpt-5.6` aliases
  `gpt-5.6-sol`.
- **Chat Completions and tools:** the migration guide states that from GPT-5.4 onwards Chat
  Completions has no tool calling unless `reasoning_effort` is `none`. `gpt-6-sol`, `gpt-6-luna`
  and `gpt-5.6-*` take tools on Chat Completions only at `none`; **`gpt-6-astra` and `gpt-6.1-sol`
  take no tools on Chat Completions at all.** The exact 400 text the tester saw is published by a
  cloud reseller's docs and the community forum, which also note that sending `tools` alone trips
  it because the default effort is `medium`. No current model is Responses-only for tool-free use.
  GB's `openAIFamily` table (only `gpt-6*` rejecting) is therefore wrong for 5.4, 5.5 and 5.6.
- **Reasoning replay, `store: false`:** reasoning items carry `encrypted_content` by default now;
  `include: ["reasoning.encrypted_content"]` is still accepted. Item shape:
  `{type: "reasoning", id: "rs_…", summary: [{type: "summary_text", text}], encrypted_content?,
  content?, status?}`. Read it from `response.output_item.done` (the `.added` copy may be partial).
  **The reasoning item precedes its `function_call`**; replay the whole `output` array in order,
  then the `function_call_output` items, and never split a chain since the last user message.
  Reasoning from earlier turns may be sent (irrelevant items are ignored; `reasoning.context`
  defaults to `all_turns` on 5.6+, `current_turn` before). Omitting reasoning is described as a
  quality loss, not an error. The known 400 *"Item 'rs_…' of type 'reasoning' was provided without
  its required following item"* (community) is the opposite mistake: a reasoning item without the
  item that followed it. GPT-5.5/5.4 assistant messages carry a `phase` field that should be
  replayed as received. Manual replay is the documented stateless path; `previous_response_id` is
  shown only with stored responses (*inferred*: it cannot serve `store: false`).
- **Caching:** `prompt_cache_key` is a top-level Responses field. `prompt_cache_retention` is
  deprecated; 5.6+ uses `prompt_cache_options.ttl` (`30m` only). 5.6+ bills cache writes at 1.25×
  input and reports `usage.input_tokens_details.cache_write_tokens`. `cached_tokens` is a subset of
  `input_tokens` (ordinary input = input − cached − cache-write). Reasoning tokens are
  `usage.output_tokens_details.reasoning_tokens`, inside `output_tokens`. Changing
  `reasoning.effort` between requests breaks the cached prefix (per model here, so stable).
- **Output cap:** `max_output_tokens` includes reasoning tokens; exceeding it returns
  `status: "incomplete"` with `incomplete_details.reason: "max_output_tokens"`, possibly with no
  visible text. The provider suggests generous headroom (25k); no hard minimum is documented.
- **Streaming:** `response.created`, `response.output_item.added/done`, `response.output_text.
  delta/done`, `response.function_call_arguments.delta/done`, `response.reasoning_summary_*`,
  `response.reasoning_text.*`, `response.completed`, `response.incomplete`, `response.failed`,
  `error`. `response.completed` carries a full `Response` (the example has `output`); no page
  guarantees it, so the `.done`-based accumulator stays authoritative.
- **Tools:** `{type: "function", name, description?, parameters, strict?}`; with `strict` omitted the
  API strictens where it can. `tool_choice`: `none | auto | required | {type: "function", name} |
  allowed_tools`; default `auto`. `parallel_tool_calls` default not stated (*inferred* true).
- **Context / max output:** GPT-6, 5.6, 5.5, 5.4 → 1,050,000 context, 128k output (6 and 5.6 cap
  input at 922k). 5.2, 5.1, 5 → 400k / 128k. `gpt-4.1` → 1,047,576 / 32,768. `gpt-4o` → 128k /
  16,384. o3, o4-mini → 200k / 100k. Requests above 272k input bill at 2× input / 1.5× output
  (irrelevant under GB's 14k history budget).
- **Prices per 1M (input / cached / cache write / output):** `gpt-6-astra` 10 / 1 / 12.50 / 50;
  `gpt-6.1-sol` 2 / 0.10 / 2.50 / 10; `gpt-6-sol` 2 / 0.20 / 2.50 / 10; `gpt-6-luna` 0.10 / 0.01 /
  0.125 / 0.50; `gpt-5.6-sol` 4 / 0.40 / 5 / 20 (promotional); `gpt-5.5` 5 / 0.50 / – / 30;
  `gpt-5.2` 1.75 / 0.175 / – / 14; `gpt-5.1` 1.25 / 0.125 / – / 10. GB's `ModelPricing` rows agree
  on input/cached/output; cache-write is new.
- **Prompt placement:** both top-level `instructions` and `developer` input messages are accepted.
- **Azure:** Responses exists at `https://<resource>.openai.azure.com/openai/v1/responses` (no
  `api-version`), `api-key` header or Entra bearer, `model` = deployment name; encrypted reasoning
  with `store: false` is documented there. URL opt-in (Decision 3) is viable.
- **Images:** every model above takes `{type: "input_image", image_url, detail}`; `detail` is
  `low | high | auto | original` (default `auto`; `original` from 5.4 up).
- **Not verified:** `gpt-6-astra`'s default effort, o3/o4-mini defaults, a `max_output_tokens`
  minimum, whether 6.x rejects the deprecated retention field, the `parallel_tool_calls` default.

## Decisions (1 and 3 confirmed by the owner 2026-09-30; the rest are house-style calls)

1. **Explicit above `none` moves; Automatic does not.** The selector sends a turn to Responses only
   when the saved model's effort is explicit and above `none` *and* tools are attached *and* the
   model is a reasoning family on the OpenAI API host. Automatic keeps GB's behaviour (Chat
   Completions, `none` with tools) because the tester's default is cheap and fast, and reasoning is
   opted into per model. **Amendment from the docs (2026-09-30):** a model that takes no tools on
   Chat Completions at all (`gpt-6-astra`, `gpt-6.1-sol`, which also refuse `none`) goes to
   Responses with tools even at Automatic, at its lowest accepted level (`low`) — the cheapest
   setting that can answer at all. The family table gains `chatToolsRequireNone` (5.4, 5.5, 5.6,
   6-sol, 6-luna) and `chatToolsUnavailable` (6-astra, 6.1-sol) in place of GB's single flag.
2. **No tools → no move.** Chat Completions accepts `reasoning_effort` without tools, so a
   tools-off turn (side calls, summarisation, the lean prompt) stays where it is. The one exception is
   a model the docs list as Responses-only, which moves regardless.
3. **Custom and Azure hosts opt in through the base URL, not a new toggle.** A model whose base URL
   path ends in `/responses` is sent Responses requests; any other custom host stays on Chat
   Completions (the existing behaviour, `/chat/completions` appended). This adds no user-facing
   string and matches how the base URL already selects the request shape.
4. **Reasoning items live in the turn, not the transcript.** The assistant history message for a
   Responses turn keeps the response's raw `output` items (reasoning, message, function_call — in
   the order received, `phase` and all) under one non-chat key, and `inputItems` replays them
   verbatim ahead of the `function_call_output` items, so a reasoning item is never sent without the
   item that followed it. The key is stripped when the turn finalises: the items are opaque
   ciphertext of several kilobytes and cross-turn carry is a documented nicety, not a requirement.
   `PromptLayout.chatMessages` and the Chat Completions body never see the key — a fallback mid-turn
   strips it before the retried request.
5. **Usage parsing detects the shape.** For the OpenAI-shaped providers, a usage block carrying
   `input_tokens` (and no `prompt_tokens`) is parsed as Responses usage; cached tokens are subtracted
   from input exactly as GB does for the chat shape, so nothing is counted twice.
6. **The fallback is a route decision, not a cascade hop.** A 4xx from Responses that is not
   401/403/429 retries the same turn once on Chat Completions at `none`, with the history rewound to
   the turn's start so the user message is not appended twice, logs `routeFallback`, and remembers
   the model for the run. The retried request's own 400 stays terminal (`ModelFallbackChain`).
7. **Context for the API host comes from a table, provenance-stamped**, like the ChatGPT catalog:
   the model page's context window for every family the app knows (table above), and 128k for an
   unknown model on `api.openai.com` — never the 32k that fits the subscription backend. GB's 14k
   history budget still decides what is sent; the context limit is the capacity guard.
8. **Caching fields stay minimal.** `prompt_cache_key` only; no retention or TTL field (one is
   deprecated, the other model-gated). `cache_write_tokens` is parsed and priced at 1.25× input
   when a row has no explicit cache-write rate, subtracted from input so nothing is counted twice.
9. **An incomplete response is named, not swallowed.** `status: "incomplete"` with
   `max_output_tokens` and no text or tool call logs a distinct marker and surfaces as the existing
   empty-completion path; the 4096 floor stays (GB) because the cap is a ceiling, not a spend.

## Scope and invariants

- **In:** `.openai` provider only (plus custom hosts opting in by URL). The ChatGPT subscription
  path is untouched except for shared translator additions that default to today's behaviour.
- **Out:** Anthropic thinking, Gemini, live modes, per-job reasoning, reasoning summaries in the
  UI, `previous_response_id` / server-side state (`store` stays `false`).
- The privacy log and turn trace carry tokens only: route name, effort, reason case, status,
  counts. Never prompt text, never the reasoning content.
- Codable back-compat: no new `ModelConfig` field is required; if one is added it is optional with
  a nil default.
- Sorted-key JSON bodies and the GB stable-head / volatile-tail ordering are preserved so the
  cache prefix stays byte-identical turn to turn.

## Phases (one PR)

### P0 — Pure route selection
`LLM/OpenAIRouteSelector.swift`: `select(provider:model:baseURL:toolsAttached:requested:
learnedToolRejection:learnedResponsesRejection:) -> Selection` where `Selection` is
`{ endpoint: .chatCompletions | .responses, reasoning: ReasoningPolicy.Resolution, reason }` and
`reason` is a case with an editor explanation (`reasoningWithTools`, `automaticStaysCheap`,
`noToolsAttached`, `notReasoningModel`, `otherProvider`, `customHostChat`, `customHostResponsesURL`,
`responsesRefusedEarlier`, `responsesOnlyModel`). `ReasoningRoute` gains nothing: the selector picks
the route and calls `ReasoningPolicy.resolve` with it. `ModelConfig.routeSelection(toolsAttached:)`
wraps it for the editor and the request builder.

### P1 — Translator and budget generalisation
- `ResponsesTranslator.requestBody` gains `includeEncryptedReasoning:` (adds `include:
  ["reasoning.encrypted_content"]`), `maxOutputTokens:` and `promptCacheKey:`; `inputItems` replays
  a reasoning item stored on an assistant message before its `function_call` items;
  `parseOutput` returns `reasoningItems` as a third element; `assistantHistoryMessage` carries them;
  `HistoryHygiene.stripReasoningItems` removes them.
- `RequestContextBudget.resolve` recognises `api.openai.com` and returns the table context with
  provenance `openaiModelPages20260930`; unknown models on that host get the conservative API default.
- `UsageTracker.parseUsage` shape detection (Decision 5).
- `ReasoningPolicy.openAIFamily` gains `responsesOnly` if the docs name any such model.

### P2 — The API route in `LLMService`
`sendOpenAIResponses` mirrors `sendChatGPT`: Bearer key via `openAICompatibleAuthorization`, endpoint
`<base>/v1/responses` (or the custom URL as given), `budgetedResponsesTurn` with the API limit,
`instructions` = GB's stable head, the volatile tail as the last input item, `prompt_cache_key` from
`PromptPrefixDigest`, `max_output_tokens` from `Resolution.outputCap`, images as `input_image` when
`visionEnabled`, reasoning replay inside the tool loop, usage recorded per request. The `.openai`
dispatch consults the selector; the fallback wrapper (Decision 6) sits around it.

### P3 — Surfaces
`ModelReasoningSection` shows "Effective with tools: Medium · Responses API" and the selector's
explanation; `TurnRecorder.noteRoute`, `PrivacyLog.ModelEvent.routeSelected/.routeFallback`.

### Tests
`OpenAIRouteSelectorTests` (the table, `gpt-6-sol` in both directions, Automatic, no tools, custom
host by URL, learned rejection, non-reasoning model); `ResponsesTranslatorTests` golden body for a
tool turn with reasoning replay (item order, `include`, `store`, `max_output_tokens`,
`prompt_cache_key`, `reasoning.effort`) and strip-on-finalise; `RequestContextBudgetTests` for the
API host table and the unknown-model default; `UsageTrackerTests` for the Responses shape under
`.openai` with cached tokens; `LLMStreamingTests`-style fake transport: Responses 400 → one Chat
Completions retry at `none`, history not duplicated, marker logged; a Responses 401 is not retried.

## Deferred and follow-ups

- Reasoning summaries (`reasoning.summary`) shown in Turn details.
- A per-model endpoint toggle in the editor, if URL opt-in proves too hidden for Azure users.
- Carrying reasoning items across turns once a documented benefit exists.
- The device pass named in Status.
