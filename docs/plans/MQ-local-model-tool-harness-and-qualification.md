# Plan MQ — Local Model Tool Harness and Device Qualification

**Status:** 📝 Drafted 2026-11-20 · nothing built · 8 decisions below, each with a recommendation

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

## Qualification

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
several times at fixed sampling settings.

### Runners

1. **CI, headless:** the loop, the schema adapter, the graders and the corpus format against a
   scripted fake model. This is where regressions are caught.
2. **Mac screener:** `Scripts/local-tool-eval/run.sh` compiles the app's loop, parser and graders
   against mlx-swift-lm on macOS (MLX runs on Apple silicon). It honours `EVAL_COMPILE_ONLY` so
   `Scripts/check-eval-harnesses.sh` keeps it building. It compares models; it doesn't qualify
   them. The research found Swift and Python results differ, so it must run the Swift path.
3. **Device qualification app:** `Scripts/local-model-qualification/`, a separate bundle id on the
   pattern of `Scripts/manual-library-benchmark`, running the production `LocalInferenceCoordinator`
   and backends. It records the corpus results and, per run:
   - time to first token and decode rate;
   - peak footprint against `os_proc_available_memory`;
   - thermal state over a 10-minute sustained run;
   - cancel latency;
   - that generation stops when the app resigns active.

   It runs on each RAM tier we offer (6, 8 and 12 GB, per `minimumRAMGB`). Results go into the
   catalog's `evidence` and a dated qualification record. The record holds counts and hashes only,
   plus the device, OS build, app build, runtime revision, model revision and quantisation.

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
- **P1 — MLX native tool calls**, behind `Config.localNativeToolCallsEnabled` (default off):
  `ToolSpec`s in, `.toolCall` events out, the inferred format logged, thinking off on tool turns,
  and the loop wired into `sendLocal` in place of the single shot.
- **P2 — GGUF tool parsing**, behind the same flag: `common/chat` in the framework build (or the
  alternative from decision 4), with the engine-reproducibility check updated.
- **P3 — qualification:** the Mac screener and the device app, the shortlist run, new catalog
  entries for the models that pass, badges set from the records, and the flag's default decided
  per model from the results.
- **P4 — device pass (owed, not automatable):** a field day on each RAM tier in airplane mode:
  open a job by voice, log readings, a calculation, a manual question answered and one declined,
  barge-ins, a locked phone (Plan GE's background ladder).

## Decisions

1. **Ship P1 on all models at once, or per model?** *Recommend per model*, starting with Gemma 4
   E2B, since its format had the most parser fixes.
2. **Round cap.** *Recommend 3*: enough for look-up-then-calculate; the research's projects use 4
   to 8, and every round costs a phone seconds.
3. **Tools per turn.** *Recommend at most 5*, matching Apple's advice for its own 4K model and the
   tool-retrieval designs in the survey.
4. **GGUF: link `common/chat`, or keep our parser with an app-rendered template and a GBNF grammar
   for the call?** *Recommend linking `common/chat`*: it is the maintained per-family code, and
   writing grammars per family is what it already does. Check the binary size and the
   reproducibility workflow first.
5. **Thresholds for `.toolFriendly`.** *Recommend proposing them after the first Mac screener run*
   and fixing them before P3's device runs, so no model is judged by a bar set after seeing its
   score. Restraint and not-in-the-manual get their own floors, not an average.
6. **Does an unbadged model still get tools?** *Recommend yes, the everyday set only, with no Field
   Assist tools until it is qualified*, and the badge hidden. Removing tools from shipped Gemma 4
   and Qwen2.5-3B users without evidence would be a regression of its own.
7. **Which licences are acceptable for a model we recommend to a paying Field Assist customer?**
   *Recommend Apache 2.0 or MIT outright; Gemma terms and LFM's licence after review; no
   non-commercial weights.*
8. **Where the qualification records live.** *Recommend `reports/` as dated JSON beside the
   existing benchmark results*, with the catalog's evidence naming the record.

## Non-goals

- The Apple Intelligence path (Plan MP and Plan JD).
- Fine-tuning a model for our tools: the research found narrow fine-tunes don't carry over to new
  tools.
- Vision tool calls. Photo turns keep their own cascade; vision badges are qualified separately
  under Plan DZ P3.
- A cloud judge for qualification. Grading stays deterministic and on our own data.
