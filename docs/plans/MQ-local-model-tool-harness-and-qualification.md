# Plan MQ — Local Model Tool Harness and Device Qualification

**Status:** 🚧 P0 built 2026-11-21 (headless core) · P1 built 2026-11-22 behind `Config.localNativeToolCallsEnabled`, off by default, Gemma 4 E2B only (see [P1 as built](#p1-as-built-2026-11-22)) · P3 part 1 built 2026-11-22: per-model sampling, the kill-limit memory budget, the run gate, the grader additions and the device qualification app (see [P3 part 1 as built](#p3-part-1-as-built-2026-11-22)); the first phone run owed · P2 and the rest of P3 not built · P4 device pass owed · all 8 decisions taken 2026-11-21; owner 2026-11-22: phone results first, the Mac screener is a compile check · mlx-swift-lm moved to `4c21c84` (mlx-swift 0.33.0) in P1

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
  | Everyday | restraint | 7 |
  | Everyday | toolChoice | 2 |
  | Everyday | cancellation | 1 |
  | | **Total** (Field Assist 673, 98%) | **683** |

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
  | written in the generator (job flow, protocol, everyday) | 34 |

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

Context audit after P1, the same scenario as above (`FieldAssistContextAuditTests`, which now
measures the real tool JSON and fails under 400 tokens left on any model, or 600 on Gemma 4 E2B
native):

| Model | Budget | Compact tier (of its cap) | Prompt without the job | Tools | Left for history and the turn |
|---|---:|---:|---:|---:|---:|
| Gemma 4 E2B, native, 5 tools | 3,456 | 648 of 864 | 1,045 | 1,146 | 617 |
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
  `flag(reasons)` or `stop(reasons)`. It waits for `nominal` plus a settle period (120 s), refuses
  Low Power Mode and a battery off the charger, flags when heat outlasts the cap (20 minutes) and
  then flags later cases at once until a settled `nominal`, and stops when power is still bad at
  the cap. The plan gives no numbers; these are the device app's defaults and its arguments.
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
- **Found while building.** Corpus v2 has no Field Assist restraint case (its seven are everyday
  chatter), so the restraint floor stays unjudged on the judged group and no run on v2 can clear
  every floor; the corpus needs Field Assist restraint cases before a badge can be granted.

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

   Unattended runs wait for `nominal` plus a settle period, refuse a draining battery and refuse
   Low Power Mode. A flagged result can't grant a badge. The 10-minute sustained run keeps
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
- **P2 — GGUF tool parsing**, behind the same flag: `common/chat` in the framework build (or the
  alternative from decision 4), with the engine-reproducibility check updated, and the GGUF cache
  keeping its shared prefix with batch trimming (H3).
- **P3 — qualification:** part 1 (🚧 built 2026-11-22, [as built](#p3-part-1-as-built-2026-11-22)):
  per-model sampling in the catalog (H1), the kill-limit memory budget (H2), the device app with
  its run gate (H4), the grader additions, Apple's baseline, and the test that fails if a catalog
  entry's evidence names a record that is not in git (decision 8). Owed: the first phone run, then
  tool choice's and two-step's floors set from it, Field Assist restraint cases in the corpus, the
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
