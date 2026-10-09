# Plan IE: A Rejected Turn Names Its Reason, and the Current Claude Request Contract

**Status:** 📝 Drafted 2026-10-10. Nothing built. P0 and P1 are pure cores with fixture tests; P2 and
P3 change what the Anthropic paths send and keep; P4 is a live check that needs real credentials.
**Origin:** A tester's support report from build 480 (`7a0cc0e0`), 2026-10-09. The first question
asked after choosing a model failed: Anthropic, `claude-sonnet-5-5`, HTTP 400. The report could not
say why, and reading the code for the cause turned up five defects against the current Claude
models that no report has caught yet.
**Why a new plan:** checked first — [BF](BF-llm-turn-hygiene.md) repairs history so a turn does
not 400 but does not record why one did; [GC](GC-openai-responses-reasoning.md) puts Anthropic
thinking out of scope by name (its `anthropicNotYet` reason is this plan's P3);
[AD](structured-vision-assessment.md) shipped the forced tool call P1 has to replace;
[BK](BK-adversarial-review-remediation.md)'s fallback chain ends the turn on any 400 as "malformed,
fails everywhere" (`Services/ModelFallbackChain.swift:111`), which stopped being true once a
request one model accepts is one its successor refuses. Nothing drafted in Round 38 touches a
provider's rejection.
**Priority:** P0 first and on its own — every later report of this kind is unreadable until it
ships. P1 next: it is a silent total loss of structured vision on the newest models.
**Surfaces:** `SafeErrorSummary`, `TurnRecorder`, the support report's turn line and banner, the
five `/v1/messages` call sites in `LLMService`, `ReasoningPolicy`. No new dependency, no new egress.

Evidence under `OpenGlasses/Sources/`; line numbers read on `main` at `16558e71`.

---

## What the report establishes

- One model turn, the first of the launch: system prompt 10,405 characters, native tools, a single
  user message of 15 characters, no image, no prior history (the app had launched 40 seconds
  earlier and the thread was new).
- The model picker was opened and closed 14 seconds before the turn, so this was very likely the
  first request ever sent with that configuration.
- The request left through the **non-streaming** branch: `model event=apiError provider=anthropic
  status=400` is logged only at `Services/LLMService.swift:2046`, and only when the body parsed as
  Anthropic's error envelope with a `message`. So the provider said exactly what was wrong, and the
  app read it, put it in `LLMError.apiError(message:)`, and kept none of it.
- The turn's failure line reads `unknown(apiError)#3`. `3` is the enum case's ordinal, not a status:
  `TurnRecorder` (`Services/Diagnostics/TurnRecorder.swift:355`) summarises with the generic
  `SafeErrorSummary(error)` ladder, which has no rung for `LLMError`.
- The banner said "the AI didn't answer" (`App/SupportReporting.swift:154`, the `default` arm).

## What it cannot establish, and the candidates

A 400 is `invalid_request_error`; an unknown or unavailable model is a 404, so the model id was
accepted. The request carried `model`, `max_tokens`, `system` (two text blocks, one cache
breakpoint), `messages` and `tools` (one cache breakpoint) — nothing the current Claude models are
documented to reject. That leaves the parts of the request that vary by installation:

1. **The credential.** `AnthropicAuth.resolveCredential` (`Utils/ClaudeOAuth.swift:149`) falls back
   to a Claude account sign-in token when the configuration has no key, sent as a bearer token with
   the `oauth-2025-04-20` beta header. A token the service will not accept for this app's requests,
   or a beta value it does not recognise, is a 400 on the very first request, instantly — the shape
   seen here. The report does not record which kind of credential was used.
2. **A tool definition.** The only other per-installation part of the body is the tool list; a tool
   added from an MCP server carries that server's own schema.
3. **A model-specific rejection not covered by the public migration notes.**

Ruled out for this turn: forced tool choice (not on this path), sampling parameters and a thinking
configuration (none sent), thinking-block replay (no history).

**Two checks settle it before any code:** ask the tester whether they pasted a key or signed in
with their Claude account; and select `claude-sonnet-5-5` on a phone with a known-good key and ask
one question. If the second works, it is the credential or the tool list.

**2026-10-10 — the second check is done.** Sonnet answers normally on the developer's own phone, so
the model and the body the app builds are accepted. That removes candidate 3 and leaves the
credential and the tool list; the first check (key or account sign-in) is still owed from the
tester, and P0 makes the next such report answer it by itself.

## What reading the code found

A to C return a 400 on a current Claude model; D and E lose the answer without one. None is this
report's turn; all are live.

| # | Defect | Where | Fails on |
|---|---|---|---|
| A | Forced `tool_choice: {type: "tool"}` | `LLMService.swift:1671`, `:1778` (structured vision and its text sibling) | Sonnet 5.5, Opus 5.5, Fable 5.1. Both sites return `nil` on any non-200 without logging, so `vision_assess`, `instrument_reading` and first-aid triage simply produce nothing. |
| B | Streamed thinking blocks are stored half-built | `streamAnthropicContent`, `LLMService.swift:3281-3299`: `content_block_start` stores the block, only `text_delta` and `input_json_delta` are applied, so a thinking block keeps an empty `signature` | Any model that thinks by default, on a streamed turn that calls a tool: the block is replayed in the next iteration (`:2082`). |
| C | Thinking blocks outlive the turn while the prefix under them changes | `:2082` stores the full content of a tool-calling turn; the next turn sends a new volatile system tail (date and time), and `pruneImages`, `repairDanglingToolUse`, `APIHistoryBudget` and compaction rewrite earlier messages | Sonnet 5.5, Opus 5.5, Fable 5.1 on accounts created on or after 2026-08-31, where a replayed block over an edited prefix is refused. |
| D | Thinking is on by default and uncontrolled | `ReasoningPolicy.swift:338` omits every Anthropic control (`anthropicNotYet`); tool turns cap output at 1,024 tokens (`:2000`) and thinking counts toward it | Not a 400: a truncated turn with no text surfaces as `invalidResponse`, and at the default effort the model thinks before almost every spoken reply. |
| E | The reply is read by position, not by type | `LLMService.swift:1465`, `:1565` (summarise, one-shot vision) take `content.first?["text"]` | Not a 400: on a model that thinks by default the first block can be a thinking block, so the call returns `nil` with a good answer in the second block. |

Smaller, same area: `ModelPricing` (`Services/Usage/ModelPricing.swift:35-43`) has no rows for the
5.5 ids; `ModelFetcher.fetchAnthropic` returns an empty list on any failure, so a refused
credential looks like "no models" during setup.

## Scope

**In:** a pure classifier for provider rejections; an `LLMError` rung in `SafeErrorSummary`; the
turn line, banner and spoken line for a rejected request; logging at the Anthropic sites that are
silent today; a per-model request contract for Anthropic applied at all five call sites; correct
handling of thinking blocks within and across turns; an effort control and output cap for
Anthropic; a live check.

**Out:** the OpenAI-compatible and Gemini request shapes (their rejections get P0's classifier and
nothing else); showing reasoning summaries anywhere; server-side fallback between models; any
change to which credential kinds the app offers — P4 reports, a decision follows.

## Phases

### P0 — The rejection names itself

Deterministic, headless.

- **`ProviderRejection`** (new, `Services/LLM/`): given a status, a response body and the
  provider, return the provider's machine-readable error type (Anthropic `error.type`, an
  OpenAI-compatible `error.code` or `error.type`, Gemini `error.status`), the request id, and a
  **reason from a closed vocabulary** matched against the message: `toolChoiceUnsupported`,
  `thinkingConfigUnsupported`, `samplingUnsupported`, `betaHeaderUnknown`, `credentialNotAccepted`,
  `toolDefinitionInvalid`, `thinkingBlockInvalid`, `historyPrefixChanged`, `messageShape`,
  `contextTooLong` (the test `RequestContextBudget.swift:158` already makes), `other`. The message
  itself is never logged or exported — the same rule `SafeErrorSummary` already applies to a
  peer's free-form text.
- **`SafeErrorSummary`** gains an `LLMError` rung: `.apiError` maps through `http(status:)` with
  the provider's error type as the detail, so the line reads
  `clientError(invalid_request_error)#400`.
- **`LLMError.apiError`** carries the classified rejection alongside the message it has today.
- **The turn line** in the support report adds the reason, the credential kind (`key` or `account
  sign-in`, never the value) and the request id.
- **The banner and the spoken line** get a `clientError` arm: "the AI service rejected the
  request", and by reason — a model that does not accept what the app sent says to pick another
  model; a credential that was not accepted says to check the key or sign in again.
- **The fallback chain reads the reason.** A rejection that belongs to one model's contract or one
  credential ends that candidate, not the turn; `messageShape` and `contextTooLong` stay terminal
  for the turn.
- **Every Anthropic site logs a non-200**: the bodiless branch at `:2050`, the streamed path at
  `:3263`, and the four one-shot sites that return `nil` (`:1449`, `:1546`, `:1661`, `:1768`).

Tests: fixture bodies for each reason and each provider; the summary rung; the report line; the
chain's class per reason; no message text in any event (extend the privacy-logging gate's fixtures).

### P1 — One Anthropic request contract

- **`AnthropicModelContract`** (new, pure): from a model id, what the request may carry — forced
  tool choice, a thinking configuration and which, sampling parameters, effort levels. An id the
  table does not know gets the strictest contract, so a model released after a build fails closed
  to the shape every current model accepts.
- **Defect A:** on a model without forced tool choice the two structured sites send `tool_choice:
  auto`, `strict: true` on the tool, and an instruction naming it; a reply without the call is
  retried once. `StructuredVisionParser` already accepts prose JSON as a fallback.
- **Defect E:** the two one-shot sites take the text blocks by type, as the tool loop already does
  (`:2075`).
- All five sites build their body through one function that applies the contract.
- `ModelPricing` rows for the 5.5 ids ride along.

Tests: the contract table; body snapshots per model family for all five sites; a structured-vision
fixture with a call and without one.

### P2 — Thinking blocks: whole within a turn, gone after it

- **Defect B:** `streamAnthropicContent` applies `thinking_delta` and `signature_delta`, so a
  streamed block is replayed exactly as received.
- **Defect C:** when a turn finishes, thinking blocks are removed from the assistant messages that
  turn stored. Within a turn's tool loop the system parts, tools and earlier messages do not
  change, so replay there is valid; across turns nothing is replayed, so the volatile tail and the
  history edits BF and GB rely on stay legal. No beta header.

Tests: a streamed tool-loop fixture asserting the replayed block is byte-identical; a two-turn
fixture asserting the second request carries no thinking block; the existing hygiene suites
unchanged.

### P3 — Effort and output room for Anthropic

Retires `anthropicNotYet`.

- `ReasoningPolicy` resolves an Anthropic wire shape from the contract: `output_config.effort`
  from the app's existing reasoning setting.
- Tool turns stop capping at 1,024 tokens on models that think by default; `stop_reason`
  `max_tokens` and `refusal` become distinct outcomes rather than `invalidResponse`.

Tests: `ReasoningPolicyTests` rows per model family; a truncated-turn fixture; a refusal fixture.

### P4 — Live check (needs credentials; deferred)

One request per current model id, with a key and with an account sign-in, through the voice path,
the Chat tab and structured vision. Record what is accepted. If an account sign-in is refused for
this app's requests, setup must find that out when the account is connected, not at the first
question.

## Decisions wanted

1. **Request id in the support report.** It identifies one request to the provider and nothing
   else, and is what their support asks for. Recommended: include it.
2. **Default effort for a spoken turn** on models that think by default. Recommended: `low`, with
   the existing reasoning setting able to raise it; to be confirmed on a device through Plan
   [CU](CU-voice-turn-latency.md)'s timeline.
3. **Structured replies** on models without forced tool choice: `auto` with a strict tool and one
   retry (recommended — smallest change, one parser), or the provider's structured-output format.
4. **If P4 shows account sign-in is refused:** keep it and explain at connect time, or remove it
   from setup. Not decided here.

## Order and size

P0 one PR, small. P1 one PR, small to medium. P2 one PR, small. P3 one PR, medium, and the only
phase with a behaviour change a wearer could hear. P4 is a checklist, not a PR.
