# Plan JD — Apple Intelligence Gets the App's Tools

**Status:** 🚧 P0 built 2026-10-18 · window follow-up built 2026-10-20 · device pass owed · P1 planned

**Manual answers (2026-11-20).** The window follow-up below keeps manual questions off this model.
[Plan MP](MP-apple-intelligence-manual-answers.md) drafts the way back: the app retrieves the
passages and the model only reads them, on Apple's Private Cloud Compute model (iOS 27, a daily
per-user allowance) when online and on the device otherwise, with the answer checked against the
passage in code. MP P1 also takes P1's "measured budget" below, reading
`SystemLanguageModel.contextSize` at runtime instead of assuming 4,096.

**Window follow-up (2026-10-20).** A field report showed "open a new job" on the on-device model
overflow its window on a brand-new conversation, retry three times (re-running `field_session`
each time) and be reported as a max-tokens stop. Now: the on-device path has its own instructions
under 4,800 characters (`AppleOnDeviceInstructions`: the persona without its camera section,
condensed only when it does not fit; authored short app guide and safety policy; a compact job
summary instead of the vault and manual passages; memory clipped; date, time and location kept),
with its blocks recorded for the report; a Field Assist job turn (open, paused or starting) is
handed to the first usable cloud or local model with one spoken sentence per process
(`OnDeviceJobRoutePolicy`), staying on the device only when nothing else is configured or the
offline hand-off chose it; `manual_lookup` is no longer offered on this path; the carry starts at
what the history holds, so an empty conversation fails at once; a rebuilt session replays the
turn's tool results (`AppleToolResultCache`); the failure is `LLMError.contextOverflow`
(`contextOverflow` in the report, cascading like `outputTruncated` until a tool has run); and the
report's phone line reads "AI model set now:". Device pass for the routed and the compact turns
owed.

## Problem

A tester set Apple Intelligence as the model, tapped the Field Assist prompt "Open a new job", and
was told the assistant "can't directly open a job" and could help find jobs online instead. The
on-device path (`sendAppleOnDeviceImpl`) created `LanguageModelSession(instructions:)` with **no
tools**: the model had nothing to call, so it answered as a chatbot. Three smaller faults sat
beside it:

- The session was created once and kept for the life of the preset, so every later turn answered
  with the **first turn's instructions** — the date line, location and memory block never updated.
- The path never wrote to `conversationHistory`, so the on-device conversation existed only inside
  a session nothing else could see (the uncertainty re-ask's history block was always empty).
- A full context window (the system model has 4,096 tokens) surfaced as the generic error line;
  so did a guardrail refusal.

The MLX path solved tools with a `<tool_call>` markup protocol and a reduced set, because a 2B
model has no structured tool channel. Apple's model does: the framework's `Tool` protocol, with
constrained decoding against each tool's `GenerationSchema`, and the framework runs the calls —
several in one turn when needed — and folds their output back into the same `respond(to:)`.

## P0 — the bridge (built)

Deterministic core first, headless-tested; the device edge is the owed pass.

- **`AppleToolSchema`** (pure, no Foundation Models import): reads a `NativeTool.parametersSchema`
  JSON dictionary into a small typed tree (`object`/`string(choices:)`/`integer`/`number`/
  `boolean`/`array`), `required` → optionality, nested objects named by path, an `enum` above 24
  choices rendered as text with the choices in the description. **Condensing** keeps a tool's
  description to 360 characters and a property's to 150, cut on a sentence boundary when one is in
  reach (a decimal point is not one). `estimatedTokens` is the pessimistic size the budget uses.
- **`AppleOnDeviceToolSet`** (pure): the priority order — the Field Assist tools when the feature
  is on (`field_session` first; a job need not be open, opening one is the point), then the local
  safe set, then `web_search` — filtered to what the registry offers (enabled, HIPAA already
  applied), narrowed by `OfflineToolPolicy` on an offline-handoff turn, and `fit` to a
  1,500-token definition budget in priority order (a tool that does not fit is skipped, not the
  rest).
- **`AppleToolBridge`** (Foundation Models): `NativeToolAdapter: Tool` with `GeneratedContent`
  arguments and a `String` output; `DynamicGenerationSchema` built from the tree and validated
  into `GenerationSchema` once per tool; `transcript(instructions:tools:history:carry:)` shapes
  the per-turn session from the app's history. The adapter never throws: a failed or refused call
  is returned as text ("Error: …") for the model to relay, as the cloud wires do.
- **`LLMService.sendAppleOnDeviceImpl`**: builds the session **for the turn** — fresh instructions,
  this turn's adapters (cached while the chosen names are unchanged), the last 12 entries of
  `conversationHistory` as prompt/response pairs — and calls `respond(to:)`. Every tool call hops
  to `runAppleTool` on the main actor and through `NativeToolRouter.executeRoot`, so the policy
  ladder, the approval card and the feature gates see an Apple call as they see any other.
  `exceededContextWindowSize` retries with a carry of 4, then 0, then surfaces as "ran out of
  room"; `guardrailViolation`/`refusal` → `modelDeclined`; the other cases each name their way
  out. The turn is appended to `conversationHistory`. Stateless and structured completions pass
  `includeTools: false, carryHistory: false` and are unchanged in behaviour.
- **Plan BI's deferred item** is closed: `web_search` is a real tool on this backend; the
  uncertainty re-ask stays as the backstop (and is skipped on an offline-handoff turn).

### Tests

- `AppleToolSchemaTests` — every JSON type, optionality, sorted properties, nested naming, the
  enum cap and its text fallback, condensing (sentence / word / decimal-point cases), the size
  estimate's monotonicity, argument read-back dropping `null`, the carry policy.
- `AppleOnDeviceToolSetTests` — priority order with Field Assist on/off, registry filtering,
  offline narrowing matches `OfflineToolPolicy`, the everyday list *is* the local safe set, `fit`
  semantics, and the invariant that `field_session` condensed uses under half the budget.
- `AppleToolBridgeTests` — every registered tool (plus the field tools built directly) produces a
  `GenerationSchema`; a model call with `GeneratedContent` arguments reaches a real router and a
  recording tool with `null` stripped; an unknown tool comes back as text; the transcript carries
  instructions, tool definitions and the newest turns; the error mapping.

## Owed

- **Device pass.** The simulator has no system model, so no test here generates. On a phone with
  Apple Intelligence: "Open a new job" from the Field Assist prompt opens one; "what's the
  weather" calls `get_weather`; a twenty-turn conversation recovers from the full window without
  an error line; a refusal is spoken as a decline. Measure the real token cost of the chosen
  definitions against the 1,500 estimate.

## P1 — planned

- **Per-tool on-device descriptions.** Condensing is mechanical; the field tools would do better
  with a hand-written short form (an optional `onDeviceDescription` on `NativeTool`) that names the
  actions a technician says rather than the first 360 characters of the cloud text.
- **Measured budget.** Replace the character estimate with the framework's own count once the
  device pass has numbers, and let the budget follow the lean prompt's actual size.
- **Tool call status in the transcript view.** The adapter sets `toolCallStatus` around each call;
  the chat bubble could show the running tool as the cloud paths do.

## Non-goals

- Vision on the Apple path (the system model is text-only; the existing refusal stands).
- Carrying tool calls and outputs between sessions — the answer that followed them is carried.
- Offering every registered tool. The window is the constraint; the priority list is the design.
