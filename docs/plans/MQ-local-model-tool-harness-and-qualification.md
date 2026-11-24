# Plan MQ — Local Model Tool Harness and Device Qualification

**Status:** 🚧 P0 built 2026-11-21 (headless core) · P1 built 2026-11-22 behind `Config.localNativeToolCallsEnabled`, off by default, Gemma 4 E2B only (see [P1 as built](#p1-as-built-2026-11-22)) · P3 part 1 built 2026-11-22: per-model sampling, the kill-limit memory budget, the run gate, the grader additions and the device qualification app (see [P3 part 1 as built](#p3-part-1-as-built-2026-11-22)); first phone run 2026-11-22 found every tool turn overflowing (`promptTooLong`, 4,317–4,326 of 3,456): the runtime now fits the definitions (compact, then drop, then none) before trimming history, the native selection's estimate is calibrated on the phone, and a native turn on Gemma 4 E2B gets 6,144 tokens on phones with 8 GB and the memory (see [Found on the phone](#found-on-the-phone-2026-11-22)); phone runs 2026-11-22 to 23 (see [Phone runs](#phone-runs-2026-11-22-to-2026-11-23)): the tool cases went from 6 of 94 to 303 of 326 through the fixes below and `LocalTurnRouter`, which runs error-code, model-number and procedure-step calls before the model; two-step 7–9 of 12, restraint and clean output 100%; P3 part 2 (2026-11-24): the full corpus on main 582/618 with every hard floor clear, and job commands, evidence choices, reading follow-ups and a reading logged in one breath routed too: tool cases 323/326 · **P2 built 2026-11-24** behind the same flag (and `Config.ggufModelsEnabled`): GGUF models call tools through llama.cpp's own `common/chat` at the kept v0.3.0 pin (Gemma 4 and Qwen 3.x handlers, lazy call grammars), feeding the same `LocalToolLoop`; the KV cache keeps its shared prefix and GGUF history is trimmed in batches; Gemma 4 E2B, Gemma 4 E4B and Qwen 3.5 4B added as GGUF catalog entries (text only, no badge) and allowlisted; device app `--gguf`; nothing run on a phone (see [P2 as built](#p2-as-built-2026-11-24)) · 2026-11-25: llama.cpp v1.0.0, Qwen 3.5 4B's card sampling, a prefix state snapshot for hybrid caches and a screen for model calls the turn did not ask for; phone tool cases 326/326 on Qwen 3.5 4B GGUF, Gemma 4 E2B GGUF and Gemma 4 E2B MLX (see [Calls the turn did not ask for](#calls-the-turn-did-not-ask-for-and-the-phone-runs-2026-11-25)) · the rest of P3 not built · P4 device pass owed · all 8 decisions taken 2026-11-21; owner 2026-11-22: phone results first, the Mac screener is a compile check · mlx-swift-lm moved to `4c21c84` (mlx-swift 0.33.0) in P1

Offline Field Assist depends on the downloaded models (MLX and GGUF) when Apple Intelligence is
missing or can't hold the turn. The research of 2026-11-20
([report](../../reports/iOS%20local%20model%20tool%20calling.md), notes in
`research_notes/iOS local model tool calling/`) found that small on-device models fail tool calls
mostly because of the **harness around them**: a parser that doesn't match the model's own format,
the model's tool-call turn never written back into the history, and chat-template traps. In the one
controlled study, fixing those took Gemma 4 E2B from 0/6 to 6/6, and Qwen3-1.7B's repeated calls
from 10/10 to 0/10 (AnyLanguageModel #328, on a Mac). Our local path has each of those faults.
This plan fixes the harness first, then qualifies a short list of models on real phones and lets
only measured evidence put a tool badge on a model.

The Apple Intelligence path is out of scope. It already uses the framework's own `Tool` protocol
with schema-constrained calls; its manual-answer gap is [Plan MP](MP-apple-intelligence-manual-answers.md).

## P0 as built (2026-11-21)

Everything below is pure and headless, and nothing calls it from a live turn yet: P1 wires it in
behind `Config.localNativeToolCallsEnabled`.

- **`LocalToolLoop`** (`Services/LLM/LocalToolLoop.swift`) drives a turn over injected `generate`
  and `execute` closures. Each round appends the assistant's call (id `call_N`, name, canonical
  arguments) and a `tool` message with the result, the tool's name and the same id. The cap is 3
  rounds (decision 2); after the third, one last generation runs with tools withheld over the
  results gathered. A call repeated by name and `AttemptToolLedger.canonicalArguments` ends the
  loop: prose beside it stands, otherwise one tools-withheld answer runs. A call inside `<think>`
  is taken. Round 0 keeps `sendLocal`'s "I'll check" correction, with the same words (now
  `LLMService.localIntentCorrection` / `localLocationCorrection`, shared). Cancellation is checked
  around every generation and tool and propagates unwrapped.
- **`OnDeviceToolSchema`** (`Services/LLM/OnDeviceToolSchema.swift`) is `AppleToolSchema` moved, not
  copied: the Apple path reads it through a `typealias`, so its conversion is byte-for-byte what it
  was. Added for the local path: `localParameters` / `localToolSpec` (a `type` on every node,
  containers past depth 2 rendered as text holding JSON) and `OnDeviceArgumentCoercion`, which
  reads `"42"` as 42, `108` as `"108"`, `"true"` as true, a choice in the wrong case as the choice,
  JSON text as its object, and refuses `"45 psi"`, `"about forty"`, `1` for a boolean or an
  unlisted choice with a message naming the field and type only.
- **`FieldAssistLocalToolSet`** (`Services/LLM/FieldAssistLocalToolSet.swift`): the eight-tool
  priority list, narrowed by `OfflineToolPolicy`, ordered by `OfflineKeywordRouter.fieldToolHints`
  (new: whole-word cues per tool), at most 5 (decision 3), then cut to
  `LocalModelBudget.toolDefinitionBudget(for:)` — a quarter of the prompt budget, 864 tokens on a
  4,096 window. Empty unless Field Assist is on **and** the model qualifies.
- **`ManualReadingCheck`** (`Services/FieldAssist/ManualReadingCheck.swift`), MP's check, built here
  so the graders use it: `found`, a known passage, a non-empty quote contained in that passage, and
  every number-with-a-unit in the answer present in it (4.5 ≠ 45, 4.50 = 4.5; `in. w.c.` = `inWC` =
  `inches of water`; a unit in a table heading counts; one-letter units only after a number).
- **Badges follow evidence.** MLX entries carry `evidence` (all `fileMetadataOnly`) and
  `pendingClaims`; `.vision` and `.toolFriendly` reach a descriptor only on `deviceVerified`, and
  `validationError(for: Entry)` states the rule as the GGUF catalog does. `toolCapableModelIDs` is
  gone; `toolCandidateModelIDs` lists what would be claimed, without Qwen2.5-0.5B. Rows read
  `currentClaims`, so an installation record written with the old badges stops showing them.
  `qualifiesForFieldAssistTools` is false for every model. **Decision 6:** nothing offered tools by
  badge — `localToolNames` never read `.toolFriendly` — so every shipped model keeps exactly the
  everyday set. **Vision:** the photo path, the vision factory and the picker's Vision filter read
  the architectural `visionCapableModelIDs`, unchanged; only the badge went.
- **Corpus, graders, CI runner.** `Scripts/local-tool-eval/corpus/local-tool-corpus.v2.jsonl`,
  **generated** by `Scripts/local-tool-eval/generate-corpus.py` from the Lennox SLP99 example vault
  (`python3 -I …` to write, `--check` to compare), so it regenerates when the vault changes. Its
  header records the SHA-256 of every input (the generator included) and of the case lines, and
  `LocalToolEvalCorpusTests` recomputes both: a vault edit without a regeneration, or a hand edit,
  fails CI. It is mostly Field Assist, because that is the point (cost): every service value,
  diagnostic code, part, model and size code and safety rule that can carry a question yields an
  answered reading checked by `ManualReadingCheck`, most with a near-miss twin (the same unit with a
  value the vault doesn't state, a code it doesn't list, a part for a model it doesn't fit) that must
  be declined; service values become readings logged in and out of range and voltage readings
  carried into `domain_calc`; codes become `table_lookup` turns with follow-ups; the three
  procedures become start, next, repeat and answer turns; each model spelling an `equipment_lookup`.
  The vault's `eval/calibration.jsonl` is the retrieval eval's answer key (pages per question); its
  phrasings are reused here as reading cases — its in-scope questions answered from the vault's
  passage, its out-of-scope ones as abstentions — without its page scoring. `LocalToolEvalCore.swift`
  holds the format, ten graders (tool name, argument presence, types after coercion, values,
  repeats, clean text, `ManualReadingCheck`, carry, cancellation, context fit) and a counts-only
  report that puts **Field Assist first, as its own group** with its categories and graders, then the
  everyday group, each with a bootstrap interval. `LocalToolEvalCorpusTests` plays every case's
  `reference` output three times through the shipped loop against a scripted fake model, and shows
  each grader failing a bad script.

  | Group | Category | Cases |
  |---|---|---:|
  | Field Assist | toolChoice | 143 |
  | Field Assist | manualAnswer | 229 |
  | Field Assist | notInManual | 161 |
  | Field Assist | multiTurn | 119 |
  | Field Assist | twoStep | 12 |
  | Field Assist | longPrompt | 4 |
  | Field Assist | cleanOutput | 3 |
  | Field Assist | cancellation | 2 |
  | Field Assist | restraint (added in P3, 2026-11-22) | 36 |
  | Everyday | restraint | 7 |
  | Everyday | toolChoice | 2 |
  | Everyday | cancellation | 1 |
  | | **Total** (Field Assist 709, 98%) | **719** |

  | Source | Cases |
  |---|---:|
  | `error_codes.md` | 204 |
  | `service_values.md` | 198 |
  | `models.md` | 81 |
  | `parts.md` | 55 |
  | `safety.md` | 26 |
  | `procedures/slp99_no_ignition.json` | 24 |
  | `procedures/slp99_pressure_switch_lockout.json` | 21 |
  | `procedures/slp99_unit_size_code.json` | 16 |
  | `eval/calibration.jsonl` (phrasings) | 24 |
  | written in the generator (job flow, protocol, Field Assist restraint, everyday) | 70 |

  Writing the cases found two gaps in the check, fixed before it shipped: a timing table's bare `s`
  wasn't read as seconds, and the manifold table states its unit only as the nameplate note's
  `in. w.g.`, which is now read as inches of water. A part number such as `65W77` is no longer
  mistaken for "65 W".
- **The pin is unchanged.** The first revision with PR #812 (`4c21c84`, 2026-11-18) builds against
  the installed SDK on paper: its `MLXFoundationModels` changes since `14414441` use only API in
  the Xcode 27.2 SDK's `FoundationModels` interface and `.tbd` (attachments, `ContextOptions`,
  `UnsupportedTranscriptContent`), and its switch over the now non-exhaustive `Attachment` has an
  `@unknown default`. But it also carries the reasoning-event change: thinking now streams as
  `Generation.reasoning`, not inside `.chunk`, and LFM2.5 resolves as always-thinking.
  `LocalLLMService` reads `.chunk` alone and strips `<think>` assuming the template opened it, so
  every LFM2.5 answer would come back empty. It also moves mlx-swift from 0.31.6 to 0.33.0. The
  bump goes with P1, which rewrites that stream loop anyway. The root `Package.swift` and
  `Package.resolved`, which still named `d6614025`, now name `14414441`.
- **Found while building, for P1.** The pinned library already parses tool calls out of the text
  stream when no tools are declared: its decoder accepts any tool name when `tools` is nil and
  defaults to the Hermes (`json`) format. So for a model whose format resolves to `json` (Qwen 2.5,
  whose template frames `<tool_call>`, and any model with no format), the `<tool_call>` the app asks
  for arrives as a `.toolCall` event that `LocalLLMService` skips, and `LocalOutputPolicy` never
  sees it. Read from the library's source, not seen on a phone; P1's first job is to take those
  events.

### `<field_assist_context>` size audit

Measured by `FieldAssistContextAuditTests` on 2026-11-21: the Lennox SLP99 example vault's core
files and procedures, a text manual made of its own service values and codes (the manufacturer's
PDFs are not committed), job 1005 open, the nameplate read, four readings, the no-ignition
procedure running and 30 conversation turns. Tokens are the local path's own estimate (four
characters a token, `HandoffTranscriptBridge.estimatedTokens`), for the `<field_assist_context>`
block alone. The lean on-device prompt includes that block whenever a job is open
(`leanOnDevicePrompt` → `buildSystemPrompt`), so this is what a downloaded model is handed today
before the persona, memory, tools and history.

| State of the job | Tokens | Share of a 4,096 window's prompt budget (3,456) | LFM2.5 (2,944) | 8,192 window (7,552) |
|---|---:|---:|---:|---:|
| Job open | 7,792 | 225% | 265% | 103% |
| + unit and 4 readings | 7,830 | 227% | 266% | 104% |
| + a manual question (passages) | 8,690 | 251% | 295% | 115% |
| + a running procedure | 8,959 | 259% | 304% | 119% |
| + 30 conversation turns | 10,049 | 291% | 341% | 133% |

The prompt budgets are `LocalModelBudget.promptBudget`: 3,456 for Gemma 4 E2B/E4B, SmolVLM2 2.2B
and Qwen 2.5 3B; 2,944 for LFM2.5 (its larger thinking reserve); 7,552 for Qwen 2.5 0.5B and
SmolVLM2 500M. **No catalog model can hold the job context of this vault**, before anything else
is added: on a 4K model it is more than twice the whole budget. `sendLocal` trims history first and
then refuses a prompt that still overflows, so with this vault open a downloaded model's turn
cannot run at all. The vault's core tier (about 9k tokens of markdown) is most of it; the bound
`VaultPromptBuilder.referenceByteLimit` gives every provider but ChatGPT, `.local` included, is the
validator's whole core budget (`VaultValidator.coreBudgetCharacters`).
P1 needs a local tier for this block — the Apple path's compact `JobSummary` is the model — before
the loop is wired in, or the Field Assist tools have no room to be offered. (Recorded as a finding;
not changed in P0.)

## P1 as built (2026-11-22)

Everything new runs only with `Config.localNativeToolCallsEnabled` on (Developer panel, "Native
tool calls", default off) and only for models on `LocalNativeToolPolicy.allowlist`, which holds
Gemma 4 E2B alone (decision 1). With the flag off, a local turn is the single shot it was, except
for the compact job tier and the shorter prompt head below, which every local turn gets. Routing is
unchanged: a turn reaches a downloaded model exactly when it did before.

- **Compact job tier.** `LocalJobContext` writes `<field_assist_context>` for a downloaded model
  on the pattern of the Apple path's `JobSummary`. It carries:
  - the vault's own rules;
  - the job, the unit and its nameplate line;
  - the latest readings;
  - the running procedure step;
  - a manuals line. It sends manual questions to the Field Assist tools when the turn offers them,
    and otherwise says that manual answers need a cloud model, as the Apple path does.

  It is fitted to `LocalModelBudget.jobContextBudget(for:)`: readings go first, then the nameplate
  line, then the procedure is condensed. The cloud prompt is untouched. Before P1, `sendLocal`
  refused every turn with this vault open.
- **Shorter prompt head on local turns.** `buildSystemPrompt(compactHead:)` uses
  `Config.onDeviceDefaultSystemPrompt`, `SystemPromptBuilder.onDeviceCameraLine`,
  `PromptInjectionPolicy.onDeviceSystemPromptPolicy` and a short app guide. The prompt without a
  job dropped from about 2,250 tokens to 1,045. `LocalPromptCompactHeadTests` checks the cloud
  head is byte-for-byte what it was.
- **Calls the library already parsed.** The `.toolCall` events mlx-swift-lm emits are now taken
  (`LocalToolCallEvent`, `LocalGenerationEvent`, `generateEvents`/`generateTurn`) instead of
  dropped. Even the single shot runs one, so a Hermes-format model's call no longer vanishes.
- **Native loop.** `sendLocalNative` passes the turn's tools as `ToolSpec`s for the model's own
  template, runs `LocalToolLoop` (3 rounds, at most 5 tools), coerces arguments
  (`OnDeviceArgumentCoercion`) and dispatches through the router, so approval and safety rules
  hold. A photo turn keeps the single shot.
- **Field Assist tools under qualification.** With the flag on, an allowlisted model is offered the
  Field Assist tools so the owner can try it on a job. `qualifiesForFieldAssistTools` stays false
  for every model, and no badge shows (decision 6).
- **Floors in code.** `LocalToolEval.Floors` holds decision 5's hard floors (not in the manual
  ≥ 95%, clean output 100%, restraint ≥ 90%). Tool choice and two-step stay unset until the first
  phone run (owner, 2026-11-22; it was the Mac screener).
- **The pin.** mlx-swift-lm `14414441` → `4c21c84` (upstream PR #812), and mlx-swift 0.31.6 →
  0.33.0. The library now streams reasoning as its own `Generation.reasoning` event:
  - `LocalStreamRouter` keeps it out of the spoken, previewed and returned text.
  - A reasoning-only turn falls to the existing empty-answer guard.
  - Stop and backgrounding are still checked between reasoning tokens.
  - Time to first token is stamped at the first answer word.

  `loadContainer`'s progress callback moved to `progress: .download { }`, and the new `tools:`
  argument is left unset. A call written inside a model's reasoning is no longer picked up for
  library-parsed models, since the library reads calls from answer text only.
  `LocalReasoningStreamTests` covers these cases. A fresh resolve also moved about ten unrelated
  packages within their ranges; `ci_scripts/Package.resolved` keeps only the MLX change, and that
  drift is left to its own change.
- **Prompt-cache reuse (finding for H3).** mlx-swift-lm reuses the cache across turns only inside
  its own `ChatSession`. Our hand-tokenized path would keep the `[KVCache]` and a token ledger
  itself, trim to the shared prefix (`trimPromptCache`) and prefill only the rest. LFM2's
  convolution state can't be trimmed, so it reuses only when the new prompt extends the old one
  exactly, which batch trimming makes common.

Context audit after P1, the same scenario as above (`FieldAssistContextAuditTests`, which fails
under 400 tokens left on any model, or 600 on Gemma 4 E2B native). **Corrected 2026-11-22 from the
first phone run** (see [Found on the phone](#found-on-the-phone-2026-11-22)): the Gemma rows count
the definitions at Gemma's real template rate calibrated on the phone
(`OnDeviceToolSchema.localEstimatedTokens`, 3.4 bytes of spec JSON a token plus 8 a tool, not four
characters a token), selected and fitted as the app now does it (`LocalToolFit`, with the 600-token history reserve a job
turn has). On 6,144 the larger definition budget (1,376) selects five bigger tools; full detail
would leave only 376 for the conversation, so they go compact. P1's figure was 1,146 tokens of
tools and 617 left.

| Model | Budget | Compact tier (of its cap) | Prompt without the job | Tools | Left for history and the turn |
|---|---:|---:|---:|---:|---:|
| Gemma 4 E2B, native, 6 GB phone (4,096 window): 5 tools, compact | 3,456 | 648 of 864 | 1,045 | 940 | 823 |
| Gemma 4 E2B, native, 8 GB and up (6,144 window): 5 tools, compact | 5,504 | 648 of 864 | 1,045 | 1,394 | 2,417 |
| Gemma 4 E4B, Qwen 2.5 3B, SmolVLM2 2.2B (single shot) | 3,456 | 643 of 864 | 1,045 | 213 | 1,555 |
| LFM2.5 2.6B (single shot) | 2,944 | 643 of 736 | 1,045 | 213 | 1,043 |
| Qwen 2.5 0.5B, SmolVLM2 500M (8K) | 7,552 | 643 of 1,888 | 1,045 | 213 | 5,651 |

The compact tier is 349 tokens with only the job open and 648 at most, against 7,792–10,049 for
the full block. Verified headless: 716 tests, 0 failures, plus the Release build. Not verified: any
real model on a phone. That is P3 and P4.

## P3 part 1 as built (2026-11-22)

The owner decided on 2026-11-22 that phone results come first: the Mac's memory limit, GPU and
thermals don't represent a phone, so the Mac screener shrinks to a compile check and the device app
is the runner that qualifies. This part builds the device app and what it stands on. Nothing in it
grants a badge, adds a catalog model or touches the GGUF tool path (P2).

- **Per-model sampling (H1).** `LocalModelSampling` (`Services/LocalInference/`): an optional
  `sampling` object on MLX and GGUF catalog entries — temperature, top-p, top-k, min-p, repetition
  and presence penalty, each decoded only when present — with a `source` note and an optional
  `toolTurn` set applied over it on a native tool turn. Only the members set replace the global
  0.7 / 0.9. `LocalLLMService.generateParameters(for:toolTurn:)` reads it on every MLX turn, and
  `sendLocal` passes the same set to the GGUF backend through `LocalGenerationRequest.sampling`, so
  the app and the device app sample alike. Sets are added only where the publisher states one:
  - Gemma 4 E2B and E4B: temperature 1.0, top-p 0.95, top-k 64 (their model cards, "Best
    Practices", one configuration for all uses);
  - LFM2.5 2.6B: temperature 0.1, top-k 50, repetition penalty 1.1 (its card's "Generation
    parameters"). These are the values `generateParameters` hard-coded before; the card names no
    top-p, so it now takes the global 0.9 rather than the library's 1.0.

  Qwen 2.5 and the GGUF entries carry none. No entry has a tool-turn set: no publisher we ship
  states one. A GGUF set may not use presence penalty (the wrapper's sampler has none) and is
  refused if it does; GGUF min-p now comes from the request when set.
- **Memory budget from the kill limit (H2).** `LocalMemoryBudget` (pure): the kill limit is
  `os_proc_available_memory()` plus the footprint held, measured once; copied weights (MLX) are
  judged against it with the footprint held, mapped weights (GGUF) against Metal's
  `recommendedMaxWorkingSetSize` with their working set against the kill limit; 1 GB is kept back
  on a 6 GB phone, 512 MB above. `LocalMemoryReadings` is the live adapter, with the kill limit
  fixed at first use. **The shipping gates are unchanged**: loads still go through
  `MemoryHeadroom.canLoad` and the RAM floors. Switching a gate that decides which models a
  customer may load waits for the phone records this feeds.
- **The run gate (H4).** `QualificationRunGate` (pure, in `OpenGlassesTests/LocalToolEval/`):
  thermal state, Low Power Mode, battery level and charging into `proceed`, `wait(reasons)`,
  `flag(reasons)` or `stop(reasons)`. **Heat changes the speed, not the answers (owner,
  2026-11-22):** a run measures through `nominal`, `fair` and `serious` and counts every answer
  towards the floors; the record's time to first token and decode rate come only from cases that
  started `nominal` or `fair`, and the hot cases' count and decode rate are kept beside them. It
  pauses only at `critical`, settles for 120 s at the start and after a `critical` spell, refuses
  Low Power Mode and a battery off the charger, flags when `critical` outlasts the cap (20
  minutes), and stops when power is still bad at the cap. The plan gives no numbers; these are
  the device app's defaults and its arguments. Found on the phone: the first build waited for
  `nominal`, and a cool iPhone Air on its charger reported `fair` between cases; the second waited
  out `serious`, which the phone reached within a minute of generating after an hour of runs.
- **Grader additions.** A generation's runtime report (`LocalGenerationStats`: tokens, timings,
  the cap and the stop reason, from mlx-swift-lm's completion info) now rides out of
  `LocalLLMService` on `MLXTurnOutput` and `LocalToolLoop.Generation`. A reply of zero tokens fails
  `cleanText` as a template fault; a blank reply with tokens behind it does not. A reply that
  stops at the cap is marked cut and counted, not failed.
- **One grading core, two runners.** `LocalToolEvalCore.swift` is compiled unchanged by the test
  target and the device app. Its `Environment` takes the loop's generation (text, parsed calls and
  report), a reader for reading cases, and optionally a model that runs its own tool loop (Apple's).
  A reading case now asks the model for a reading (`Reader`: passages by id and the question in,
  one JSON object out), which `ManualReadingCheck` accepts or declines; CI's scripted model replies
  with the case's scripted reading in that format, and an unreadable reply is declined, as the app
  would decline it, and counted. The 98 near-miss twins test the check, not a model (each is an
  answered case's question and passages with a made-up value in its scripted reading), so a live
  run skips them (`Case.isCheckOnly`) and the record says how many. The dispatcher's unoffered-tool
  message (`LocalToolLoop.unofferedToolMessage`) and the tool-result framing
  (`PromptInjectionPolicy.resultForModel`) are the shipped ones, shared.
- **The device app** (`Scripts/local-model-qualification/`, bundle id
  `com.openglasses.localmodelqualification`, the app's increased-memory-limit entitlement). It
  compiles the production `LocalLLMService` and its MLX runtime, the loop, parser, coercion, output
  policy, schema conversion, catalog and sampling by path; `Stubs.swift` adapts only telemetry, the
  turn recorder, two type names and a photo-only helper. To make that possible, four pure pieces
  moved out of large files unchanged: the local turn's wording (`LLMService+LocalTurnText.swift`),
  canonical arguments (`AttemptToolLedger+CanonicalArguments.swift`), tool-output framing
  (`PromptInjectionPolicy+ToolOutput.swift`), and the staging-summary bridge (into
  `LocalModelRowState.swift`); `LocalToolTurn.forLoopPass` builds each pass for `sendLocalNative`
  and the app alike. What it can't build without the app is in `Fixture/qualification-fixture.json`:
  each offered tool's registry declaration and the lean on-device prompt with the Lennox job open,
  fitted to each tool-candidate model; `LocalModelQualificationFixtureTests` rebuilds it from the
  app and fails when it is stale. The app takes `--model` (default Gemma 4 E2B), `--apple`,
  `--repeats` (3), `--groups` (default Field Assist with the restraint and not-in-the-manual
  categories), `--limit`, `--settle`, `--cap`, `--allow-battery`, `--cancel-probes` and `--fresh`;
  downloads the model through the production downloader; gates every case; keeps the screen awake;
  cancels generation when it resigns active; and writes `Documents/results.json` after every case,
  resuming a matching unfinished record. The record (`LocalModelQualificationRecord`) is counts and
  hashes only: per group and category pass counts with bootstrap intervals over cases, decision 5's
  floors, cut and zero-token replies, time to first token and decode rate, the fit before load and
  the peak footprint against the kill limit, the thermal trace, gate waits and flags, cancel latency
  from timed probes, the sampling set, and the device, OS build, app commit, runtime revision, model
  revision and quantisation.
- **Apple's baseline.** `--apple` runs the same cases on Apple's on-device model: the tools are
  the shipped `AppleToolBridge` adapters built from `OnDeviceToolSchema`, each calling the same
  dispatcher the loop uses (scripted results, the same coercion), and the outcome is graded by the
  same graders. Two differences, recorded here: its instructions are Gemma 4 E2B's fixture prompt,
  not the shipped Apple path's `AppleOnDeviceInstructions` (which needs the running app's job
  service), and Apple reports no token counts, so the zero-token and cut checks don't apply to it.
- **Decision 8's test.** An entry with `deviceVerified` evidence must name its record
  (`evidenceRecord`, a JSON file under `reports/`; MLX and GGUF), and
  `LocalModelQualificationRecordTests` fails when a named record is not in git, read from the git
  index itself since the simulator can't run `git`. No entry names one yet.
- **Compile check.** `Scripts/local-model-qualification/check-compiles.sh` builds the app for the
  simulator. It is not in `Scripts/check-eval-harnesses.sh`: that job compiles plain-swiftc Mac
  harnesses in a 10-minute budget, and a cold mlx-swift-lm build alone takes longer.
- **Field Assist restraint cases.** Found while building: the corpus had no Field Assist restraint
  case (its seven were everyday chatter), so the restraint floor could not be judged on the group
  decision 5 names and no run could clear every floor. `generate-corpus.py` now writes 36 job turns
  that need no tool while the job tools are offered (owner, 2026-11-22): chatter and asides, turns
  that name the unit, a code or a procedure without asking for anything, and requests none of the
  offered tools can do. None states a reading. They are written by hand, with no facts from the
  vault beyond names the corpus already used. The corpus is 719 cases (Field Assist 709); the
  format is unchanged, so it stays version 2.

### Found on the phone (2026-11-22)

The first phone run (iPhone Air, 12 GB, `mlx-community/gemma-4-e2b-it-4bit`, mlx-swift-lm
`4c21c84`): reading turns ran at about 40 tokens a second, first token in 0.1–0.6 s (6.2 s cold),
peak footprint 3.16 GB against a 6.44 GB kill limit. **Every tool turn failed before generating**
with `promptTooLong(tokens: 4,317–4,326, limit: 3,456)`. Three faults together:

- **Nothing cut the tools.** `historyFittingBudget` drops history, and these turns had none; the
  overflow was the definitions, and the turn threw.
- **The device app bypassed the app's selection.** It sent each case's offered tools as they were;
  the first tool cases offer `reading`, `field_session`, `table_lookup` and `domain_calc`, whose
  standard definitions are about 2,750 tokens (`domain_calc` alone about 1,400). The app's own
  selection would have cut them to its 864-token definition budget.
- **The app's selection estimate was low.** It used the Apple path's `estimatedTokens`, which counts
  no JSON keys, types or punctuation: 2,155 for those four tools, about 22% under the render.

Calibration, from that case (`FieldAssistContextAuditTests.testTheCalibratedToolEstimateAgainstThePhone`):
the job prompt with the tool guide is 6,234 characters (about 1,560 tokens at four characters a
token), the turn 52–75 characters, the four specs 10,034 bytes of JSON; 4,317–4,326 measured leaves
about 2,750 tokens for the definitions, 3.65 bytes a token. The native selection now budgets with
`OnDeviceToolSchema.localEstimatedTokens` (3.4 bytes a token plus 8 per tool), which puts that
prompt at 4,556–4,561, 5–6% over the phone; the test fails if it ever comes in under. P1's audit was
not a chars/4 undercount by half, as first read: its five tools were selected under the 864-token
budget, the phone's four were not, and four characters a token of the same spec JSON is about 8% low.
The split assumes the system prompt reads at four characters a token; the record now keeps every
generation's prompt token count, which settles it on the next run.

What was built:

- **The fit (`LocalToolFit`, pure).** At the one chokepoint every local tool turn goes through
  (`LocalLLMService.generateTurn`, both the Gemma 4 VLM path and the generic tokenizer path), the
  system prompt, the turn and the tools are measured with the model's own tokenizer and template,
  no history, in this order: every tool at full detail (only when that also leaves 600 tokens,
  `LocalToolFit.historyReserve`, for a turn with history, so a roomier window doesn't spend its room
  on longer descriptions); every tool with compact definitions (`OnDeviceToolSchema.Limits.compact`:
  a 160-character tool description, required properties' descriptions cut to 100, optional ones
  dropped; every node keeps its `type` and choices, nesting still at most two); compact, dropping one
  tool at a time from the lowest-priority end; no tools. Only then is the history trimmed into what
  is left. A tool turn now throws `promptTooLong` only when the system prompt and the turn alone
  don't fit. A turn whose model inferred no tool format (Hermes instruction, nothing rendered) is
  not fitted.
- **Priority order is explicit.** `LocalToolTurn.tools` and `compactTools` are in priority order
  (`LocalNativeToolPolicy.nativeToolNames`, which now builds on a pure `ordered(field:everyday:utterance:)`);
  `FieldAssistLocalToolSet.ordered` is the Field Assist half.
- **The dispatcher refuses a dropped tool.** `MLXTurnOutput.toolFit` and `LocalToolLoop.Generation.toolFit`
  carry offered, kept, compact and the window (a `.toolFit` event on the coordinator path).
  `sendLocalNative` and the eval core narrow the offer after each generation
  (`LocalToolFit.dispatchable`), so a call to a dropped tool gets `unofferedToolMessage` and runs
  nothing; the `toolName` grader fails a call the dispatcher refused as not offered.
- **The selection is honest.** A native turn's `estimate` is `localEstimatedTokens` of the compact
  spec (the least the runtime can send), so the selection rarely leaves the fit a tool to drop; the
  audit asserts it leaves none. The single shot and the Apple path keep `estimatedTokens`.
- **The device app orders like the app.** `LiveEnvironments.appOrder` orders each case's tools with
  the same two functions, sends standard and compact specs, and the record keeps, per run (counts
  only): tools offered and kept on the first tool generation, generations that dropped a tool or
  went compact, whether a tool the case expected was dropped, the window and every generation's
  prompt tokens; per group: runs where the fit dropped an expected tool (so "the fit dropped it" is
  told from "the model missed it"), runs that dropped any and runs that went compact. Record schema
  `/2`, so a `/1` record is not resumed.
- **A larger window for Gemma on bigger phones (behind the flag).** A native tool turn (the flag on,
  an allowlisted MLX model) on Gemma 4 E2B gets a 6,144-token window, prompt budget 5,504, definition
  budget 1,376, when the phone has at least 8 GB and `LocalMemoryBudget.fit` against the kill limit
  still keeps the reserve after the model, its 768 MB working set and the KV cache for 6,144 tokens
  (`LocalModelBudget.toolTurnContextWindow`). 6 GB phones, the flag off, other models and non-tool
  turns keep 4,096. The cache is read from the model's config as mlx-swift-lm builds it: of 35
  layers the last 20 share earlier layers' K and V and hold none, and of the 15 that do, 3 are full
  attention (one KV head, 512 wide) and 12 slide over 512 tokens (one head, 256): 6 KB a token
  plus 12 MB, 48 MB at 6,144. The gate charges a conservative 180 MiB (all 15 layers full width, no
  window) in case the checkpoint's config differs from the library's defaults. The record names the
  window (`window`: ordinary, chosen, reason, budget). The app decides it once per turn in
  `sendLocal` and hands it to the runtime on `LocalToolTurn.contextWindow`.
- **The fixture no longer carries the clock.** Found while regenerating it: the job tier stamps the
  equipment with the time it was identified, so `qualification-fixture.json` differed on every run;
  `LocalModelQualificationFixtureTests` pins that time, and the file is now the same every build.
- **Time to first token (owed, phone).** The larger window lets a turn carry up to about 2,000 more
  prompt tokens. Reading turns prefilled in 0.1–0.6 s warm; the extra prompt will add to that on a
  long job, and the next phone run measures it (the record's per-generation prompt seconds and
  tokens). Not measured here.

### Phone runs (2026-11-22 to 2026-11-23)

Gemma 4 E2B (MLX, `mlx-community/gemma-4-e2b-it-4bit`) on the iPhone Air, one repeat a case, the
device app's counts-and-hashes record. Fifteen runs: a 94-case slice, the full corpus once, then the
326 tool cases (every tool category plus restraint) after each change. Run to run, the same build
moves about four cases either way.

| Run | Cases | Passed | Notes |
|---|---|---|---|
| 94-case slice, P1's guide | 94 | 6 | |
| 94-case slice, after the fixes below up to table rows | 94 | 83 | |
| Full corpus (before the router) | 618 | 375 | not-in-manual 63/63, restraint 43/43, manual answers 218/229, clean output 311/317; tool choice 44/143, multi-turn 1/119, two-step 0/12 |
| Tool cases, Gemma's own call syntax read | 326 | 113 | |
| Tool cases, with the router | 326 | 294 | every routed turn passed |
| Tool cases, the last two builds | 326 | 302, 303 | tool choice 132–133/143, multi-turn 112/119, two-step 7–9/12, restraint 43/43, clean output 324/324 |

Decode ran at about 19 tokens a second with the phone hot (its usual state in a long run), 26–28
warm; peak footprint 3.5 GB. **The full corpus was last run before the router; a full run on the
final build is owed**, so the reading categories' numbers are from that earlier build.

**What the runs found, and what was built for each:**

- **Results lost when the phone locked.** The runner resumes in the same process when the app
  returns to the foreground.
- **An empty reply after a successful call.** Gemma often ended its turn right after `reading`;
  the loop now speaks the tool's own result when it is a short single line of prose
  (`LocalToolLoop` end reason `.toolResult`), and a miss otherwise.
- **Readings declined on a formality.** `ManualReadingCheck` reads a passage id written `[p1]` or
  `passage p1`, and accepts a quote made of one table row's cells with that table's headers.
- **Gemma's own call syntax.** `LocalOutputPolicy` reads `call:name{key:<|"|>value<|"|>}` and its
  `<tool_call:…>` hybrids, and a Python-style `name(key="value")` call standing on its own line, as
  further grammars (never as repairs: a body that doesn't parse is never a call, and is not spoken).
- **The assistant's name at the front of a reply** ("Avenkin here…") is taken off; "Avenkin will
  log…" is kept.
- **Lookups and procedure steps answered from memory.** Gemma rarely called `equipment_lookup` for
  an error code or a model number, or `procedure_runner` for "next", "say that again" or a step's
  answer, and sometimes made up advice. Guide lines asking it to did not help, and nor did fewer
  tools. `LocalTurnRouter` (pure) now recognises those turns and runs the call before the model:
  an error code, a model number given to identify the unit, a running procedure's next / repeat /
  answer, and a procedure start matched to exactly one title in the vault's catalogue. A lookup's
  result goes to the model to phrase; a step's result is spoken as the runner wrote it, minus the
  lines meant for the model. Over the corpus it routes every code, model and next/repeat case and
  11 of 12 answers, never a case that expects no call, never a wrong one. Its score is the router's
  as much as the model's: the record counts routed calls per run.
- **Two calls in one generation.** Every call a generation makes now runs, in order, each through
  the dispatcher and counted against the round cap.
- **Claims and promises nothing kept.** A reply that says a reading was logged or a drop worked out
  when no such call ran gets the turn's one correction, then the miss text (`unbackedClaim`); a
  final promise to act ("I will calculate it now") with nothing behind it ends the same way
  (`unbackedPromise`). The intent check also hears the assistant's own name as "I".
- **Numbers nobody said.** Gemma filled voltage-drop calls with invented conductor figures (a
  resistance of 16 Ω/ft for 14 AWG copper). `LocalArgumentGrounding` drops a numeric argument that
  appears nowhere in the turn, the history, this turn's tool results or the job block of the
  prompt, and tells the model which; over the corpus's reference calls it drops none.
- **The wire, the supply and the operation from the technician's words.** `LocalArgumentCompletion`
  fills a voltage drop's `wire_awg` or `area_mm2`, `material` and `supply_v` from what the
  technician said (the technician's stated wire wins over a figure the model supplied), and sets
  `operation` on a call shaped like a voltage drop that named none. Coercion moves a missing
  required choice from a key that holds one of its values (Gemma's `application: voltage_drop`).
- **Voltage drop by wire size.** `domain_calc` takes `wire_awg` (18 to 4/0) or `area_mm2`, with the
  metal; the figures ship as electrical trade reference data (`Resources/Electrical/conductors.json`,
  credited in Attributions), the one exception to Plan JJ's "no shipped tables"
  ([JJ decision 8](JJ-table-lookup-and-rule-chains.md)). The metal is never assumed.
- **A location ask on a turn about something else** ("It's filthy in this cupboard" → "tell me
  where you are?" → `where_am_i`). The location correction now fires only on a turn that depends on
  where the wearer is.

**P3 part 2 (2026-11-24).** The full corpus on `main` after part 1 (4d6c64dbd): **582 of 618, and
every hard floor clears** — not-in-manual 62/63, clean output 324/324, restraint 43/43, manual
answers 217/229, tool choice 131/143, multi-turn 112/119, two-step 8/12, cancellation 2/2; decode
about 28 tokens a second hot, first token 1.4 s median, peak footprint well inside the kill limit.
Then `LocalTurnRouter` took three more shapes the model kept answering instead of calling: job
commands (`field_session` start, work order, pause, resume, end, next unit, status — imperative or a
fixed status question only, never a deferred, conditional, negated or past-tense turn, and not
start or next unit while a procedure runs), evidence choices (`evidence` keep / exclude / include
all), and a reading's follow-up ("and the other one?" after a turn that stated two values and logged
one: the other value, the same quantity and unit). `LocalArgumentCompletion` fills `show_source`'s
`which` from the words. Over the corpus the router routes 8/8 job, 4/4 evidence and 6/6 follow-up
cases, never a case that expects no call. The tool cases on the phone: **317 of 326** (was 303) —
tool choice 138/143, multi-turn 118/119, two-step 11/12, restraint 43/43.

An evidence choice is routed with no photo named, so the tool takes its default, the latest photo:
"Exclude the blurry photo of the inducer" excludes the latest one. The model couldn't do better
(photo ids aren't in its prompt), and a choice can be undone ("put it back").

**Still failing:** an explicit "Log <quantity> … at <value> <unit>" turn answered with "which
model?" or a promise (6 of the 9 tool failures; it passes most runs, so a route for it is next), one
procedure answer to a step that asks nothing, one two-step, a show-source argument. The badge waits
on P4's device pass.

**A reading logged in one breath (2026-11-24).** `LocalTurnRouter` now records "Log <what> at
<value> [unit]" and "<what> reads <value>, log it" itself: one number in the turn, what was measured
said before it (or, with nothing before, a short qualifier after it: "Log 0.6 on low fire"), and
nothing deferred, denied, conditioned, asked as a question or asked of another tool. Two values, a
correction ("135, not 140") and a log followed by a calculation go to the model. Over the corpus it
routes 38/38 logged-reading cases and no case that expects no call; the decode-cancel case became a
question ("Can you log 0.6 on low fire?") so the model still decodes that call, and the grader tests
that score the model's own calls run without the router. The tool cases on the phone: **323 of
326** (was 317) — logged readings 38/38 (was 34), long prompts 3/3 (was 1). Still failing: one
procedure answer to a step that asks nothing, one two-step (a different case from the last run: the
model varies), the show-source argument.

**A step that asks nothing still takes its answer (2026-11-24).** That remaining procedure answer
was a step whose instruction ends "…The control stores it and resets.": no question, so the router
left "The code stopped blinking and the control reset" to Gemma, which said "Understood" and
recorded nothing. The router's context now carries the running step's `expected_input` and branch
conditions while nothing is recorded for it, and a short reply that shares at least two content
words with one of them (and those are at least half of its own) is the step's answer. Over the
corpus: procedure answers 12/12 routed (was 11; its floor is now 1.0), still no case that expects no
call.

**Log it, then work out the voltage drop (2026-11-24).** The two-step turn ("Line voltage at the
control is 115. Log it, then work out the voltage drop at 15 amps over 50 feet of 14 gauge copper")
passed on most phone runs and failed on a different case each time: prose with no call, a call in
a form nothing reads (`<tool_call:domain_calc{…}}`), a resistance Gemma made up. `LocalTurnRouter`
now routes both calls in order when the part before "then" is a reading logged in one breath and
the part after it asks for a voltage drop with one current and one length, every other number being
the wire's size: the reading, then `domain_calc` with the operation, current and length as said.
`LocalToolLoop` runs every routed call and completes each from the technician's words as it does a
model's, so the wire, metal and supply are `LocalArgumentCompletion`'s, never the router's; the
model says the result. Over the corpus: two-step 12/12 routed, no case wrongly routed. The tool
cases on the phone: **325 of 326** (was 323) — two-step 12/12, procedure answers 12/12, logged
readings 38/38, restraint and clean output 100%. The one left: the `show_source` table argument.

**The source the technician named (2026-11-24).** That last case was "Show me the page that table
came from", sent as `show_source` with `which: "first"`, which opens the first cited page rather
than the table. `LocalArgumentCompletion`'s source rule only filled a missing `which`; it now reads
the one source the turn names (an ordinal, the cited table, a table number or every source) and
replaces a different `which` from the model, as the conductor and supply rules do. A turn that names
none leaves the model's alone, and two different sources give none. The tool cases on the phone
with both changes: **326 of 326**, restraint and clean output 100%.

**Not checked on the phone:** what the router and the argument steps say in the real app (the
qualification run scores scripted tool results, so a reply after a refused call can still quote
the script); the preview stream can show a Gemma or Python-style call line briefly before it is
classified (the spoken and stored text never carries it).

## P2 as built (2026-11-24)

GGUF models now take their tools natively, through llama.cpp's own `common/chat` (decision 4),
behind the same flag as MLX (`Config.localNativeToolCallsEnabled`, and `Config.ggufModelsEnabled`
for GGUF at all). Nothing changes with either flag off.

- **The pin is kept.** v0.3.0 (`c1d0e7a0`, 2026-08-25) already has `common/chat` with what P2
  needs: a dedicated Gemma 4 handler (`peg-gemma4`: Gemma's `<|tool_call>call:name{…}<tool_call|>`
  syntax and its `<|"|>` strings, written back as Gemma writes them), the Qwen 3.5 / Qwen3-Coder XML
  handler (`<function=…><parameter=…>`), an automatic parser for Hermes-style templates (Qwen 3,
  Qwen 2.5), lazy grammars with their triggers, `tool_choice`, and llama.cpp's own Jinja engine.
  Newer non-prerelease releases exist (v1.0.0, 2026-11-13, about 50 commits to the chat code,
  including a Gemma 4 grammar refactor); moving there means a new engine API to adopt and is left
  to its own change.
- **What is built, and what is not.** Not upstream's `llama-common` target: it also carries the
  model downloader, the Hugging Face cache, the argument parser and cpp-httplib. A separate
  configure, `Vendor/LlamaCpp/chat/CMakeLists.txt`, compiles chat's link closure from the same
  pinned checkout (worked out from the objects' undefined symbols: chat, its PEG parser, the Jinja
  engine, JSON (nlohmann, MIT), `common.cpp` and what it pulls in), and leaves out `arg`, `console`,
  `debug`, `download`, `hf-cache`, `http`, `imatrix-loader`, `llguidance`, `preset` and `subproc` by
  name. The build script merges it into `libllama.a`, ships its headers under
  `Headers/llama-common/`, fingerprints its source list in BUILD-INFO's options digest, and now
  fails the build when the device archive references a socket, resolver, URL-loading or TLS symbol
  (none does). `common/`'s own logger, which would write template text and model output to stderr,
  is switched off by the bridge.
- **Size.** The device slice went from 10,322,800 bytes (v0.3.0 without chat, Xcode 26.6) to
  15,621,800 (with it, Xcode 26.6); the chat library alone is a 5.3 MB archive. Linked and
  dead-stripped into a minimal arm64 executable, chat adds 1,522,744 bytes (stripped: 5.53 → 7.05 MB).
- **Reproducibility.** The bytes were re-recorded because the options changed. A first record on
  the Mac (Xcode 27.2) could not be reproduced: no GitHub macOS runner has 27.2, so the strict
  rebuild failed on the toolchain. The committed engine is instead the CI runner's own build
  (Xcode 26.6, the toolchain `main`'s engine was recorded with), made by a hand-started run of the
  Engine Reproducibility workflow with its new `record` input, which builds with `--update-sums` and
  uploads the engine, SHA256SUMS and BUILD-INFO for a person to commit; the ordinary strict run then
  checks those bytes against the same toolchain. The workflow now also runs when
  `chat/CMakeLists.txt` changes, and selects the Xcode BUILD-INFO names when the runner has it.
- **The bridge.** `LlamaCppChat.mm` in the wrapper, behind C functions in `LlamaCppWrapper.h`, JSON
  text in and out: templates from the model (or from Jinja source, for the tests), a render
  (OpenAI-style messages, tools, `tool_choice`, thinking, a fixed clock → prompt, format, lazy grammar
  and triggers, the control tokens the parser needs as text, extra stops, the serialized parser), a
  parser handle and a parse (full, or partial for the preview). The lazy grammar sits on the sampler
  beside its chain, applied as llama.cpp's own sampler does: the chain draws, and only a token that
  would break a started call is redrawn under the grammar. No status carries a message, so no
  prompt or reply can reach a log through an error. `LlamaToolChat` (Swift, pure) builds the
  request and reads the parse; a call whose name is empty or whose arguments are not a whole JSON
  object (a call cut off by the cap) is counted and never run.
- **How GGUF reaches `LocalToolLoop`.** `LlamaCppLocalInferenceBackend.generateEvents` renders a
  tool turn through `common/chat`: the system prompt, the earlier turns, this turn's calls and
  results in `tool` roles, and the tools, fitted by `LocalToolFit.fit` (moved out of
  `LocalLLMService`, so both runtimes run the same fit) with no history, then the history trimmed
  into the room left. The completion is read by the family's parser: the reply without its calls as
  `.text`, each call as `.toolCall`, the fit as `.toolFit`, and the runtime's counts and timings as
  a new `.stats` event (MLX's backend yields it too). `sendLocal` and `sendLocalNative` are
  unchanged apart from reading `.stats`: the router, grounding, completion, claim and promise
  guards, the round cap and the dispatcher's refusal of dropped tools all apply as on MLX. A model
  whose templates `common/chat` cannot read falls back to the Hermes instruction, as MLX does with
  no format. Ordinary (non-tool) turns keep the fixed-list template path Plan DZ shipped, except on
  a model only `common/chat` can render — Gemma 4's template is not on llama.cpp's fixed list, so
  before P2 a Gemma 4 GGUF could not load at all.
- **Prefix reuse (H3).** The backend keeps the tokens its KV cache holds and, before each prompt,
  keeps their longest shared prefix (less one token, for the logits) instead of clearing the cache
  (`og_llama_context_keep_prefix`). A sliding-window cache that has dropped early cells, or a
  recurrent or hybrid model's state (Qwen 3.5 is hybrid), cannot be cut back: the cache is then
  cleared and the prompt read from the start, as llama.cpp's server does. A cancel, an error or an
  unload forgets the cache. GGUF history is trimmed in batches of a quarter of the room, rounded up
  to whole exchanges (`LocalModelBudget.historyFittingBudgetInBatches`), so the same exchanges stay
  dropped until the conversation has grown another batch; the system prompt, the job tier and the
  turn never go. A GGUF native turn hands the runtime the last 24 messages for that trim, not the
  six-message window that moves the start every turn. MLX keeps its one-at-a-time trim (its cache
  is not reused). Time to first token is in every generation's `.stats` (render, tokenize and the
  prefill the cache did not save), which the device app records as it records MLX's.
- **The targets.** `LocalNativeToolPolicy.ggufAllowlist` holds Gemma 4 E2B, Gemma 4 E4B and
  Qwen 3.5 4B as GGUF, under qualification like the MLX entry (no badge, decision 6). All three are
  new catalog entries from llama.cpp's own GGUF repositories, at pinned revisions with their files'
  sizes and SHA-256 digests, text only, `fileMetadataOnly`, Apache 2.0 (the base models' licence;
  decision 7): Gemma 4 E2B and E4B at Q4_0 (the only 4-bit quantisation published there), Qwen 3.5
  4B at Q4_K_M. The Gemma entries carry the same sampling as the MLX entries. Qwen 3.5's card asks
  for a presence penalty the GGUF sampler did not take yet, so its entry carried none (it does since
  2026-11-25: see [Qwen 3.5 sampling](#qwen-35-sampling-2026-11-25)).
- **The device app.** `--gguf <catalog id>` runs a GGUF entry on the production GGUF backend
  through the same loop and graders (`LiveEnvironments.backend`, over any backend behind the seam),
  with Gemma 4 E2B's fixture prompt, the record naming llama.cpp's revision and the mapped backing.
  It has no GGUF downloader: the weights file is copied into its `Documents/gguf/` (README). Not
  yet for GGUF: the cancel-latency probes, and a run with the phone locked.

- **Found while building: C++ exceptions in the app image.** Inside the app (and the test host,
  which is the app), `catch (const std::exception &)` does not catch a libc++ `std::runtime_error`:
  the MediaPipe graph archive's `regex_split.o` and `wordpiece_tokenizer.o` define their own
  `std::exception` typeinfo (device and simulator archives alike), and every catch clause in the
  image binds to that copy, while libc++'s exceptions derive from libc++abi's. The same code on the
  Mac catches them. `common/chat` relies on such catches when it probes a template for its automatic
  parser, so a template without a dedicated handler (Qwen 3, Qwen 2.5, SmolLM2) fails to render
  there: the backend then gives the turn the Hermes instruction over the fixed-list path, and logs
  `gguf-exceptions-unreliable` once per load. Gemma 4 and Qwen 3.5 have their own handlers and are
  unaffected; the two Qwen 3 bridge tests skip while the probe
  (`og_llama_runtime_catches_standard_exceptions`) says so. The same hazard sits under any C++ in
  the image that catches `std::exception` from libc++ — llama.cpp's own model loader among it — so
  it is an owner decision to fix at the MediaPipe archive rather than here.

Verified headless on main at `727ce7e56`: 604 tests across the GGUF, local-model, loop, eval,
privacy and guard suites, 0 failures, 2 skipped (the Qwen 3 bridge tests above), slowest 23 s; the
device app's compile check passes; `Scripts/check-privacy-logging.sh` passes.

**Not checked on a phone:** any of it. Owed: that each target loads at v0.3.0 (the GGUF files were
re-uploaded 2026-11-12, after the pin), Gemma 4 E2B GGUF against its MLX run on the same corpus,
time to first token on turn 1 and turn 8 of a long job with the cache kept, and the grammar's cost
per token inside a call. The GGUF runtime still offloads every layer to Metal by default, so the
locked-phone case the plan names needs a CPU-only load before it can be measured.

## llama.cpp v1.0.0 (2026-11-25)

The GGUF engine moved from v0.3.0 to **v1.0.0** (tag `v1.0.0`, commit `b1b770d9`, build b12359,
published 2026-11-13, 1,738 commits on), for Qwen 3.5's gated delta-net fixes (#28068, #32078),
the on-device state copy sizes for quantized KV caches (#30541) and the newer `common/chat`.
Server-side context checkpoints are in `tools/server`, which is not linked.

- **Build.** `chat/CMakeLists.txt` adds `chat-tts-norm`, `json-schema` and the per-family handlers
  v1 moved to `common/parsers/` (upstream's own `parsers/sources.cmake`); `file-lock` joins the
  excluded downloader code; `json-schema.h` ships with the chat headers. The no-network check
  passes. No new third-party code is compiled (nlohmann/json stays 3.12.0, now with llama.cpp's
  deep-nesting patch).
- **API.** `common_chat_params.prompt` is now parts (template text and user input); the bridge
  joins them, as before. The family's parser became an in-memory PEG arena with no text form, so
  `og_llama_chat_parser_create` now takes the templates and the request and renders it again
  (one extra render a generation), and the render's JSON lost its `parser` key. The parse input is a
  `common_chat_input`. The core `llama.h` calls the wrapper uses are unchanged. The
  `catch (std::exception)` probe still reads false in the app image, so Qwen 3-style templates still
  fall back to Hermes.
- **Size.** Device slice 15,621,800 → 21,778,656 bytes (a local Xcode 27.2 build; the committed
  engine bytes are the CI runner's, recorded by hand through the Engine Reproducibility workflow).
  Linked and dead-stripped into a minimal arm64 executable with the wrapper: 8.44 → 13.09 MB, 6.94 →
  11.41 MB stripped. 3.54 MB of that is the embedded Metal kernel source (`__ggml_metallib`, 1.78 →
  5.32 MB: v1 keeps one source per kernel kind, each with the shared headers copied in), about
  0.73 MB code.
- **Verified** headless: the GGUF suites (LlamaCppToolTurnTests, LlamaToolChatTests,
  LlamaCppRuntimeTests, LlamaCppBackendTests, LlamaRuntimePackageTests) 102 tests, 0 failures,
  2 skipped (the Qwen 3 bridge tests, as before). Not run on a phone.

## Qwen 3.5 sampling (2026-11-25)

The first Qwen 3.5 4B GGUF phone run (v0.3.0) sampled with the GGUF defaults (min-p 0.05,
repetition penalty 1.1, no presence penalty) and missed the restraint floor (31/36 Field Assist):
it called tools on turns that ask for none. The entry now carries its card's set for instruct
(non-thinking) mode, which a tool turn runs: temperature 0.7, top-p 0.8, top-k 20, min-p 0, presence
penalty 1.5, repetition penalty 1.0 ("Qwen3.5-4B model card, Best Practices", read 2026-11-24). The
GGUF sampler takes a presence penalty now (`LlamaSamplerOptions.penaltyPresence` → llama.cpp's
`penalty_present`, applied over the penalties sampler's 64-token window rather than the whole
reply), so the GGUF catalog no longer refuses one; min-p and the repetition penalty already went
through. An entry that names none keeps today's GGUF defaults, so Gemma GGUF is unchanged; MLX is
unchanged. The device app's `--gguf` run reads the entry's set by id and records it.

## Qwen prefix snapshot (2026-11-25)

The first Qwen 3.5 4B GGUF phone run read a median 3,147-token prompt in 17.2 s (181 tok/s), 76% of
a 22 s case, because Qwen 3.5 is hybrid (gated delta-net layers beside full attention) and its cache
cannot be cut back: P2's prefix reuse cleared it and re-read the whole prompt every generation.
Gemma 4 E2B's 2,871 tokens took 0.78 s through the same reuse. Built, headless:

- **A prefix state snapshot**, only for a cache that cannot be cut back
  (`og_llama_model_memory_can_trim`: not recurrent, not hybrid). Once the prefill reaches the
  prompt's **stable start** the backend copies sequence 0's whole state (`llama_state_seq_get_data`,
  host memory, in the wrapper); a later prompt that begins with exactly those tokens restores it
  (`llama_state_seq_set_data`) and prefills only the rest. The stable start is where the render of
  the same system prompt and tools over a one-character probe message (U+E000) parts from the real
  prompt: the template's system/tools section, up to the first message's own words. One snapshot,
  keyed by its exact tokens (`LlamaPromptCache.snapshotStep`): restored when the prompt begins with
  it, saved afresh at the stable start when it does not (or when the start runs past it), the old
  one freed before the new is taken, none under 64 tokens or over 512 MiB, and forgotten on a
  cancel, an error, an unload or another model, as the trimmed prefix is. Gemma's trim path is
  untouched. The size is logged as kilobytes (`promptSnapshot`) and recorded in bytes; from Qwen
  3.5 4B's published configuration (8 full-attention layers, 4 KV heads of 256, f16; 24 delta-net
  layers) it should be about 32 KB a token of KV plus about 50 MB of recurrent state, so roughly
  130–150 MB for a 2,500–3,000-token start.
- **One render order for a turn's tools** (`FieldAssistLocalToolSet.renderOrder`: the Field Assist
  tools by priority, then the rest by name), in `LocalToolTurn.specs(kept:detail:)`, so MLX and GGUF
  both render it. Which tools a turn offers, and which the fit drops first, still follow the turn's
  words. The fixture is unchanged (it holds no tool order).
- **Where each prompt was read from**: `LocalGenerationStats` carries `promptSource` (`fromStart`,
  `trimmedPrefix`, `restoredSnapshot`), the tokens that saved and a saved snapshot's bytes; the
  qualification record keeps them per generation and counts and times them per source
  (`timing.promptSources`, `firstTokenSecondsBySource`, `largestSnapshotBytes`).
- **`--gguf-batch <n>`** in the device app sets a GGUF run's logical and physical prefill batch
  (`n_batch`, `n_ubatch`; the app's own default, 512, is unchanged), named in the record's window.
- **Found while testing:** the backend finished a generation's stream before it recorded the
  result, so a round started the moment the last ended could be refused as "already generating".
  The stream now ends after the backend's state does, and a generation id stops a cancelled one that
  finishes late from clearing a newer one's slot.

What sits at the start of a job tool turn (the qualification app's job prompt and five Field Assist
tools, character offsets in the render): **Qwen 3.5** renders the tools first — the tools block to
7,928 (3,285 compact), its call instructions to 8,755, then the system prompt: its head, the
`<field_assist_context>` job tier (11,626–13,317), the rules, the `CURRENT DATE & TIME` line at
14,422, its last line and the native tool guide, ending at about 15,330, where the user turn begins.
**Gemma 4** renders the system prompt first (job tier 2,890–4,581, date line 5,686, tool guide
5,885) and the tools after it (6,587–14,524). Neither puts per-turn content before its tools except
inside the system prompt itself: the job tier and the minute-precise date line sit inside the stable
start on Qwen (the date about 900 characters before its end) and before the tools on Gemma. Not
moved: moving the date line would reorder what the model is told on both runtimes, so it is left to
the owner (see the lead's report).

## Calls the turn did not ask for, and the phone runs (2026-11-25)

With v1.0.0, the card's sampling and the snapshot, Qwen 3.5 4B GGUF reached 321/326 tool cases. Its
misses were calls the turn never asked for: a reading logged for a question that only stated
values, a job changed on a turn about something else, a lookup or a second call beside one the
router had already made, a source shown nobody asked to see. `LocalToolLoop.screened(_:turn:routed:)`
now leaves such a model-made call unrun, counted as `callsScreened` (not `callsNotRun`, and not a
repeat), and the turn goes on as if the model had not made it. Routed calls are never screened. It
leaves unrun:

- a `reading` whose value is present but holds no digit or number word (a blank or missing value
  still goes to the tool, which asks for it, as before);
- any call to a tool the router already ran this turn, or a lookup (`equipment_lookup`,
  `table_lookup`, `manual_lookup`, `manual_figure`, `show_source`) beside a routed call;
- a `reading` on a question that states values and has no logging word;
- a `field_session` change (anything but `status`, `query`, `next_unit`) on a turn with no job word;
- a `show_source` on a turn that neither asks to see something nor names a source.

The rules read only the turn's words and the call; they live in `LocalToolLoop` itself so the
qualification app compiles them unchanged. The corpus test that scripts a restraint call now
scripts one the screen leaves alone (an `evidence` keep), so the grader is still exercised.

**Phone runs, iPhone Air, the tool cases (326), all at `f67ddb36f`, llama.cpp `b1b770d9`:**

| Model | Runtime | Tool cases | Clean output | Restraint | Median case | Run | Peak | Screened |
|---|---|---|---|---|---|---|---|---|
| Qwen 3.5 4B Q4_K_M | GGUF | 326/326 | 317/317 | 36/36 | 7.2 s | 47.5 min | 0.52 GB | 3 |
| Gemma 4 E2B Q4_0 | GGUF | 326/326 | 317/317 | 36/36 | 2.3 s | 11 min | 0.30 GB | 1 |
| Gemma 4 E2B 4-bit | MLX | 326/326 | 317/317 | 36/36 | 2.9 s | 14 min | 3.65 GB | 0 |

Qwen's snapshot was restored for 157 of 267 generations and read from the start for 110; first token
1.3 s median restored against 13.5 s from the start; the largest snapshot 163.5 MB; decode about
9.4 tok/s. Gemma GGUF trimmed its prefix on 264 of 265 (first token 0.2 s). The first Qwen run, on
v0.3.0 with the GGUF defaults, took 22 s a case and missed the restraint floor. `clearsFloorsUnflagged`
stays false on these records only because a tool-case run leaves the corpus's other floors
unjudged.

Still open for the owner: the minute-precise date line sits inside Qwen's stable start, so a
snapshot taken one minute is not reused the next once the app carries the date (the qualification
runs carry none); the snapshot's host memory (163.5 MB here) is not counted by `LocalMemoryBudget`;
v1's prompt parts for tokenizing user text apart from the template are not used yet; Gemma 4 E4B is
not run.

## What the local path does today (read from the code, 2026-11-20)

1. **The prompt lists tool names, not schemas.** `LLMService.localToolInstructions` appends
   "Output exactly: `<tool_call>{"name": …, "arguments": …}</tool_call>`" and the names. Only
   `calendar` gets a hand-written argument line. Every model is told to use Hermes JSON, the format
   Qwen2.5 was trained on. Gemma 4 (`<|tool_call>`), Qwen3.5 (XML parameters) and LFM2 (Pythonic)
   were trained on others.
2. **The library's own parsing is thrown away.** `LocalLLMService` skips mlx-swift-lm's `.toolCall`
   generation events (the stream loop near "Non-text generations (`.toolCall`/unknown) are skipped"),
   and no `ToolSpec`s are passed, so the chat template never renders the tools.
   `LocalOutputPolicy` parses only the Hermes frame and bare JSON objects.
3. **One call per turn, and the call isn't written back.** `sendLocal` runs at most one tool. The
   history then gets the model's prose, or "Let me check that for you." when there was none, in
   place of the call. The result goes in as a **user** message ("Tool 'x' returned: … Please respond
   naturally"). The 2026 failures in the research came from exactly this gap. A stalled "I'll check"
   gets one corrective re-generation.
4. **No Field Assist job tools.** `LLMService.localToolNames` offers `localSafeTools` (weather,
   time, timers, calendar and the like). It adds `manual_lookup`, `table_lookup`, `manual_figure`
   and `show_source` only when the *personal* manual library has manuals. `field_session`,
   `reading`, `evidence`, `equipment_lookup`, `domain_calc`, `procedure_runner` and `rule_chain` are
   never offered on a downloaded model, though `OfflineToolPolicy` marks every one of them as
   working offline. So a technician on a downloaded model, offline, can't open a job by voice.
5. **The GGUF runtime has no tool parsing at all.** The vendored `llama.xcframework` ships only
   llama.cpp's core headers. Prompts go through `llama_chat_apply_template`, which `llama.h` says
   "does not use a jinja parser" and supports a fixed list of templates. llama.cpp's tool parsers
   and tool templates live in `common/chat`, which isn't built. GBNF
   (`llama_sampler_init_grammar`) is available.
6. **Tool badges without evidence.** `LocalModelCatalog.toolCapableModelIDs` gives `.toolFriendly`
   to Gemma 4 E2B/E4B and Qwen2.5 3B/0.5B by a hard-coded list. The GGUF catalog refuses that
   badge unless an entry's evidence is `deviceVerified` (`LocalModelCatalog.validationError`).
7. **The pin predates the latest parser fixes.** mlx-swift-lm is pinned to revision `14414441`
   (`project.base.yml`; `ci_scripts/Package.resolved` agrees, the root `Package.resolved` still
   shows `d6614025`). PR #812 (Qwen's missing `</parameter>`, calls to undeclared tools reported as
   such) merged on 2026-11-18 and is in no tag.

## Design

### A. Use each model's own tool format (MLX)

Pass the turn's tools as `ToolSpec`s through `UserInput(chat:tools:)`, so the model's chat
template renders them in the form it was trained on. Then take the calls from the `.toolCall`
events mlx-swift-lm's parsers emit (`gemma4`, `qwen35`, `lfm2`, `json` and others). At load,
log the `ToolCallFormat` the library inferred (as a token). When it infers none, which happens
with a re-quantisation whose template was edited, fall back to today's Hermes instruction and
`LocalOutputPolicy`, and say so in the report. Keep `LocalOutputPolicy` as the last guard on
everything spoken: no markup reaches the voice, whichever parser ran.

### B. Short, flat schemas

Reuse the compact schema `AppleToolSchema` already builds for the Apple path. Make that one
`OnDeviceToolSchema`, so both on-device paths describe a tool the same way. Plan JD's per-tool
`onDeviceDescription` serves both. Every node carries a `type` (Gemma 4's template crashes
without one), nesting is at most two levels (its recursive macro can overflow swift-jinja's
stack), and arguments are coerced to the declared types before dispatch (Gemma 4 E2B 4-bit has
been seen returning numbers as strings).

### C. A bounded tool loop that writes the call back

A pure `LocalToolLoop` driver over injected `generate` and `execute` closures, run inside the
existing turn scope and cancellation.

- **History:** each round appends the assistant's tool-call message (with its id) and a `tool`
  message carrying the result, its name and the call id, in the roles the chat template expects.
  The "Let me check that for you." substitute and the user-role result go away.
- **Cap and repeats:** a round cap (decision 2). Repeat detection uses
  `AttemptToolLedger.canonicalArguments`, which is order-independent; the study missed 286 of 603
  repeats because Swift's dictionary order varies by process. A repeat ends the loop.
- **At the cap:** the last round answers with tools withheld and keeps the results already
  gathered. It doesn't throw them away.
- **Reasoning models:** thinking is off on tool turns (Qwen3 and Qwen3.5 put calls inside
  `<think>` and stop). If a call still arrives inside `<think>`, it is taken rather than dropped.
- **The corrective re-generation** for "I'll check" stays as round 0's recovery.

### D. Field Assist tools, few per turn

When Field Assist is active, a priority list like `AppleOnDeviceToolSet.fieldAssistPriority`,
offline-filtered by `OfflineToolPolicy`: `field_session`, `reading`, `evidence`,
`equipment_lookup`, `domain_calc`, `procedure_runner`, `table_lookup`, `show_source`. Offer
**3–5 per turn**, chosen by the turn's own words: the GK intent classifier once it lands, a
keyword router until then (`OfflineKeywordRouter` already exists). Cut the list to the model's
budget (`LocalModelBudget`), not to a fixed count.

**Manual questions don't go through a tool at all.** They take Plan MP's path: the app searches
first, then the model reads, then the answer is checked. MP's `ManualPassageFitter` and
`ManualReadingCheck` are shared, so a downloaded model gets the same "that isn't in the manual"
rule in code. That matters because the research found abstention weak in every small model.
P0 also measures what `<field_assist_context>` (`FieldSessionService.promptContext`) puts in a
local turn's prompt today, against each catalog model's window.

### E. GGUF: link llama.cpp's own tool parsing

Build `common/chat` and its Jinja engine into the vendored framework
(`Scripts/build-llamacpp-framework.sh`, checked by the engine-reproducibility workflow). That gives
the GGUF path llama.cpp's maintained per-family parsers (`PEG_NATIVE`, `PEG_GEMMA4` and others),
tool-rendering templates, lazy grammars that constrain a call once it starts, and `tool_choice`.
The alternative is in decision 4.

### F. The pin

Move mlx-swift-lm to the first revision that has PR #812 and still builds against the Xcode 27
SDK, through `Scripts/update-package-resolved.sh`. Make the root `Package.resolved` agree with
`ci_scripts/Package.resolved`. Keep the `revision:` pin and its comment's rule: go back to a
`version:` as soon as a tag carries the fixes.

### G. Badges follow evidence

Give the MLX entries the GGUF catalog's `Evidence` field and its rule: an entry may not claim
`.toolFriendly` or `.vision` unless the evidence is `deviceVerified`. Then a badge is earned on a
phone and cannot be granted by a list. Whether the tools stay *offered* to an unbadged model is
decision 6.

### H. Running a small model well on a phone (added 2026-11-21)

Added after reviewing another offline on-device chat app and its field data. That app has no tool
calling, so none of this changes A–G. All four decide whether a qualification run measures the
model or the conditions around it. Where code is adapted rather than rewritten, its MIT notice
goes with it.

1. **Each model's own sampling (P3, before the first phone run; built 2026-11-22).** Every local turn today uses one set of
   settings, temperature 0.7 and top-p 0.9 (`LocalLLMService`). Model publishers recommend very
   different ones: top-k and min-p values differ by family, and some advise against a repetition
   penalty. A model screened on settings its publisher doesn't recommend can fail a floor for
   that reason alone. MLX and GGUF catalog entries get an optional `sampling` object (temperature,
   top-p, top-k, min-p, repetition and presence penalty; every member optional, decoded only if
   present, with the source noted beside it). Only the members that are set replace the global
   value. A separate tool-turn set is allowed, because a call wants less randomness than a
   sentence. The qualification record names the set it ran with.
2. **A memory budget from the real kill limit (P3).** The RAM gates use physical memory rounded
   up to the number on the box (`LocalLLMService.marketingRAMGB`). The point where iOS kills the
   app is lower, and it is fixed per process: `os_proc_available_memory()` plus the footprint
   already held, measured once. Copied-weight backends (MLX) are judged against that limit;
   memory-mapped GGUF against Metal's `recommendedMaxWorkingSetSize`. A 6 GB phone keeps about
   1 GB in reserve, because a Field Assist turn's KV cache keeps growing over a job and is what
   tips a model that only just fits. A pure `LocalMemoryBudget` takes the readings as inputs. The
   device app records peak footprint against the same limit, so the fit rule and the evidence
   use one number.
3. **Keep the prompt's start where it was (P2).** The GGUF backend clears its KV cache every turn,
   and `LocalModelBudget.historyFittingBudget` drops one exchange at a time, so the start of the
   prompt moves on every turn. On a long job that means re-reading the whole window before each
   answer; the other app's field data reported 23 s to the first word by turn eight before its fix.
   The fix has two parts:
   - The engine rewinds the cache to the longest token prefix it shares with the new prompt,
     instead of clearing it.
   - The trim drops old exchanges in batches of about a quarter of the room, rounded up, so the
     same exchanges stay dropped until the conversation has grown another batch. The system
     prompt, the compact job tier and the turn being answered never go.

   A Field Assist job is the best case for this: the same system prompt and job tier for many
   turns. The time to first token on turn 1 and turn 8 goes in the record. Whether mlx-swift-lm's
   prompt cache gives MLX the same reuse is checked in P1's pin bump; if not, it joins P3.
4. **A thermal and power check before measuring (P3, device app).** In the other app's overnight
   runs, every model fell to 5–11 tokens a second once the phone reached `serious`, which took
   two to five long answers. A cool-down wait that gave up after a few minutes measured hot
   twice a night. A pure `QualificationRunGate` turns a reading (thermal state, Low Power Mode,
   battery level and charging) into one of four decisions:
   - `proceed`;
   - `wait`, with the reasons, for the log;
   - `flag`: the wait ran out, so it measures anyway and the issue goes on the record;
   - `stop`: the power is still bad at the cap, so no later model is measured.

   As built (owner, 2026-11-22): heat changes the speed, not the answers, so answers count
   through `serious` and only the timing is taken from cool cases; the run pauses only at
   `critical`, and refuses a draining battery and Low Power Mode. A flagged result can't grant a badge. The 10-minute sustained run keeps
   its thermal trace either way.

Smaller items go in with P3's graders:
- A reply of zero tokens is told apart from a blank one. Zero tokens almost always means the prompt
  format is wrong, so it counts against clean output as a template fault, not as a model answer.
- A reply that stops at exactly the token cap is marked cut.
- While the phone is `serious` or hotter, the local path may say once that replies are slower, and
  offer a lighter downloaded model. It never switches models by itself.

## Qualification

The primary purpose is Field Assist on a downloaded model, because that is what saves the cloud
cost, so the badge thresholds (decision 5) and each model's default-on decision are judged on the
Field Assist group first, while restraint and not-in-the-manual keep their own floors.

### Corpus

JSONL, versioned, committed. The cases are synthetic plus the Lennox example vault; private
manuals are local only, as for `Scripts/retrieval-eval`. Each case gives the turn, the tools
offered, and what should happen:

| Category | What passes |
|---|---|
| Tool choice | the expected tool is called, with the required arguments of the declared types |
| Restraint | no tool when none applies (small talk, a question already answered in the turn) |
| Not in the manual | "isn't in the manual" or a held question, never a made-up value |
| Two steps | e.g. a reading, then `domain_calc` on it, with the first result carried into the second |
| Long prompt | the job context near the model's budget, and the above still holds |
| Multi-turn | a follow-up ("and the low side?") that needs the previous turn |
| Clean output | nothing `LocalOutputPolicy.classify` flags as carrying protocol reaches the voice |
| Cancellation | a barge-in during prompt decode and during generation stops within a set time |

### Graders

Deterministic, no model judging a model. They run the **shipped** parser and loop over the raw
output: tool name, argument presence and types, a value checked against its passage with
`ManualReadingCheck`, repeated calls, leftover markup. A run prints counts and bootstrap intervals
only, never a question, a passage or an answer, as `RetrievalEvalCore` does. Each case is run
several times at fixed sampling settings: the model's own from its catalog entry (H1), or the global
set when it has none, and the record says which.

### Runners

1. **CI, headless:** the loop, the schema adapter, the graders and the corpus format against a
   scripted fake model. This is where regressions are caught.
2. **Device qualification app, first** (owner, 2026-11-22): `Scripts/local-model-qualification/`,
   a separate bundle id on the pattern of `Scripts/manual-library-benchmark`, running the
   production `LocalLLMService` and its MLX runtime with the CI runner's grading core compiled
   unchanged (built in P3 part 1). It records the corpus results and, per run:
   - time to first token and decode rate;
   - peak footprint against `os_proc_available_memory`;
   - thermal state over a 10-minute sustained run;
   - cancel latency;
   - that generation stops when the app resigns active.

   It runs on each RAM tier we offer (6, 8 and 12 GB, per `minimumRAMGB`). Results go into the
   catalog's `evidence` and a dated qualification record. The record holds counts and hashes only,
   plus the device, OS build, app build, runtime revision, model revision and quantisation.
3. **Mac screener, a compile check only.** The Mac's memory limit, GPU and thermals don't
   represent a phone, so a Mac run neither qualifies nor ranks models. What is left of it is
   keeping the device app building: `Scripts/local-model-qualification/check-compiles.sh` builds it
   for the simulator.

Apple's on-device model, and Private Cloud Compute once MP P2 lands, run the same corpus as the
baseline.

### Shortlist

In order, from the research (MLX unless noted):

1. **Gemma 4 E2B**, uniform 4-bit (not QAT, not MXFP4), native `gemma4` format. Already in the
   catalog.
2. **Qwen3.5-2B, then 4B**, with thinking off on tool turns; vision-capable, Apache 2.0. New
   catalog entries.
3. **Qwen3-1.7B**, MLX and GGUF; the most common default across the projects surveyed. New
   entries.
4. **LFM3-1.7B**, after its licence's revenue terms are checked and our pin parses LFM3. Its BFCL
   figure is the vendor's own.
5. **Qwen2.5-1.5B GGUF** as the control. Already in the catalog.

Out until evidence: the tool badge on **Qwen2.5-0.5B** (4-bit tool calling collapses at 1B and
below). **SmolLM2-360M** is already text-only. **xLAM-2** and **Hammer2.1** wait until their
licences are confirmed.

## Phases (one PR each)

- **P0 — headless core.** `LocalToolLoop` with history roles, round cap, canonical repeat
  detection and cap-keeps-work; `OnDeviceToolSchema` shared with the Apple path; the Field Assist
  local tool list and per-turn cut; argument coercion; the corpus format, graders and the CI runner
  against a fake model; `Evidence` on MLX entries with the validation rule; the
  `<field_assist_context>` size audit; the pin bump and `Package.resolved` agreement.
- **P1 — MLX native tool calls** (✅ built 2026-11-22), behind `Config.localNativeToolCallsEnabled` (default off):
  `ToolSpec`s in, `.toolCall` events out, the inferred format logged, thinking off on tool turns,
  and the loop wired into `sendLocal` in place of the single shot. Added from P0's findings: the
  `.toolCall` events the pinned library already emits for Hermes-format models are taken first; a
  compact local tier for `<field_assist_context>` (on the model of the Apple path's `JobSummary`)
  comes before the loop, since the audit found no catalog model can hold today's block; and the
  mlx-swift-lm pin moves past PR #812 with the stream loop's `Generation.reasoning` handling.
  What the vault's core files become in that tier, and what `table_lookup` and a manual question
  hand a small model, is [Plan MV](MV-manuals-a-small-model-can-use.md)'s: typed facts the app
  scopes to the unit and speaks itself, and cards of at most 200 tokens for the reader.
- **P2 — GGUF tool parsing** (✅ built 2026-11-24, [as built](#p2-as-built-2026-11-24)), behind
  the same flag: `common/chat` in the framework build (or the alternative from decision 4), with
  the engine-reproducibility check updated, and the GGUF cache keeping its shared prefix with batch
  trimming (H3). Owed on a phone: each target loading at the pin, Gemma 4 E2B GGUF against its MLX
  run, and time to first token with the cache kept.
- **P3 — qualification:** part 1 (🚧 built 2026-11-22, [as built](#p3-part-1-as-built-2026-11-22)):
  per-model sampling in the catalog (H1), the kill-limit memory budget (H2), the device app with
  its run gate (H4), the grader additions, Apple's baseline, and the test that fails if a catalog
  entry's evidence names a record that is not in git (decision 8). Owed: the first phone run, then
  tool choice's and two-step's floors set from it, the
  shortlist run on each RAM tier, new catalog entries for the models that pass, badges set from the
  records (dated JSON in `reports/`), and the flag's default decided per model from the results.
  The Mac screener is a compile check (owner, 2026-11-22).
- **P4 — device pass (owed, not automatable):** a field day on each RAM tier in airplane mode:
  open a job by voice, log readings, a calculation, a manual question answered and one declined,
  barge-ins, a locked phone (Plan GE's background ladder).

## Decisions

All eight decided by the owner on 2026-11-21.

1. **Ship P1 on all models at once, or per model?** **Decided 2026-11-21: one model at a time,
   starting with Gemma 4 E2B**, since its format had the most parser fixes. This is
   `LocalNativeToolPolicy.allowlist` (P1). With the flag on, an allowlisted model is *under
   qualification*: it is offered the Field Assist tools so the owner can try it on a job, while its
   catalog badges stay evidence-only (`qualifiesForFieldAssistTools` is unchanged and still false
   for every model).
2. **Round cap.** **Decided 2026-11-21: 3, as built**: enough for look-up-then-calculate; the
   research's projects use 4 to 8, and every round costs a phone seconds.
3. **Tools per turn.** **Decided 2026-11-21: at most 5, as built**, matching Apple's advice for its
   own 4K model and the tool-retrieval designs in the survey.
4. **GGUF: link `common/chat`, or keep our parser with an app-rendered template and a GBNF grammar
   for the call?** **Decided 2026-11-21: link llama.cpp's `common/chat` (P2)**, after checking the
   binary size and the engine-reproducibility workflow. It is the maintained per-family code.
   Why GGUF matters for the cost goal: MLX needs Metal, which iOS denies in the background, so a
   CPU GGUF model is the only local path that could keep a job going with the phone locked in a
   pocket.
5. **Thresholds for `.toolFriendly`.** **Decided 2026-11-21**, judged on the Field Assist group, as
   hard floors per category, never an average. Fixed now, before any model is run:
   - not-in-the-manual declined ≥ 95%;
   - no protocol markup reaching the voice: 100%;
   - restraint (no tool when none applies) ≥ 90%.

   Set after the first phone run (owner, 2026-11-22, in place of the Mac screener run): tool
   choice (around 85%) and two-step (around 70%). The hard floors above are unchanged.
6. **Does an unbadged model still get tools?** **Decided 2026-11-21: yes, the everyday set only,
   as built**, with no Field Assist tools until it is qualified (or, with the P1 flag on, while an
   allowlisted model is under qualification), and the badge hidden.
7. **Which licences are acceptable for a model we recommend to a paying Field Assist customer?**
   **Decided 2026-11-21:** Apache 2.0 and MIT outright; the Gemma terms reviewed first (Gemma 4
   E2B is the first candidate); LFM's revenue terms reviewed before LFM3 is shortlisted; no
   non-commercial weights.
8. **Where the qualification records live.** **Decided 2026-11-21:** dated JSON in `reports/`,
   beside `reports/my-manuals-benchmark-2026-10-25.json`, with the catalog's evidence naming the
   record. Added to P3's scope: a test fails if a catalog entry names a record that is not in git.

## Non-goals

- The Apple Intelligence path (Plan MP and Plan JD).
- Fine-tuning a model for our tools: the research found narrow fine-tunes don't carry over to new
  tools.
- Vision tool calls. Photo turns keep their own cascade; vision badges are qualified separately
  under Plan DZ P3.
- A cloud judge for qualification. Grading stays deterministic and on our own data.
