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

PENDING-RESEARCH

## Decisions

1. **Explicit above `none` moves; Automatic does not.** The selector sends a turn to Responses only
   when the saved model's effort is explicit and above `none` *and* tools are attached *and* the
   model is a reasoning family on the OpenAI API host. Automatic keeps GB's behaviour (Chat
   Completions, `none` with tools) because the tester's default is cheap and fast, and reasoning is
   opted into per model.
2. **No tools → no move.** Chat Completions accepts `reasoning_effort` without tools, so a
   tools-off turn (side calls, summarisation, the lean prompt) stays where it is. The one exception is
   a model the docs list as Responses-only, which moves regardless.
3. **Custom and Azure hosts opt in through the base URL, not a new toggle.** A model whose base URL
   path ends in `/responses` is sent Responses requests; any other custom host stays on Chat
   Completions (the existing behaviour, `/chat/completions` appended). This adds no user-facing
   string and matches how the base URL already selects the request shape.
4. **Reasoning items live in the turn, not the transcript.** The encrypted reasoning item that
   precedes a `function_call` is kept on the assistant history message (a non-chat key) for the
   tool loop of the current turn and stripped when the turn finalises. It is opaque ciphertext of
   several kilobytes; carrying it across turns would inflate the persisted history and the cache
   prefix for no documented benefit. `PromptLayout.chatMessages` and the Chat Completions body never
   see the key — a fallback mid-turn strips it before the retried request.
5. **Usage parsing detects the shape.** For the OpenAI-shaped providers, a usage block carrying
   `input_tokens` (and no `prompt_tokens`) is parsed as Responses usage; cached tokens are subtracted
   from input exactly as GB does for the chat shape, so nothing is counted twice.
6. **The fallback is a route decision, not a cascade hop.** A 4xx from Responses that is not
   401/403/429 retries the same turn once on Chat Completions at `none`, with the history rewound to
   the turn's start so the user message is not appended twice, logs `routeFallback`, and remembers
   the model for the run. The retried request's own 400 stays terminal (`ModelFallbackChain`).
7. **Context for the API host comes from a table, provenance-stamped**, like the ChatGPT catalog:
   the model page's context window for every family the app knows, and a conservative default for an
   unknown model on `api.openai.com` — never the 32k that fits the subscription backend.

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
