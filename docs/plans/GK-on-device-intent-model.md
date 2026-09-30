# Plan GK — On-Device Intent Model (hint, offline routing, addressee check)

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Serves:** Plan [GE](GE-automatic-offline-handoff.md) (its P2 keyword router is a placeholder for
this classifier), Plan S/DJ (`ToolAuthorizationPolicy` gains one more strengthen-only floor).
**Related:** Plan BC (`HighImpactToolPolicy`), W08.4 safety-eval gate (`.github/workflows/safety-eval.yml`,
the model for this plan's CI gate), Plan EC (UI localisation languages), Plan GD3 (`FieldToolProfile`,
the only tool narrowing that exists today).

---

## Trigger

Three jobs want the same small thing, a fast local guess at *what the wearer is asking for*:

1. **Tool choice.** About 120 native tools are declared every turn; the cloud model sometimes picks
   a near neighbour (`reminder` for `set_timer`, `web_search` for `get_news`). A cheap prior could
   steer it.
2. **Offline.** When GE moves the conversation onto the phone, and especially when the phone is
   locked (no MLX), requests that a native tool can serve without a model need routing by
   something that is not an LLM.
3. **Irreversible actions.** A message, a call or a deletion triggered by speech that was not meant
   for the assistant ("send it to him tomorrow", said to a colleague) is the worst failure a voice
   assistant has. Today messaging is always confirmed, but deletions are not, and the confirmation
   never says *why* it is unsure.

## Outcome

- A bundled on-device text classifier, a few MB, that labels one utterance with the **tool id** it
  most likely needs (or `no_tool` / `not_addressed`) in milliseconds, on the CPU, foreground or
  background, with no network.
- A published number: **correctly understood requests** on a frozen held-out set, cloud model
  **without** the hint vs **with** it. The hint ships only if it helps.
- Before an irreversible action, if the model thinks the wearer meant something else or was talking
  to someone else, the assistant holds and asks.

## What exists today (verified 2026-10-01)

- `Services/IntentClassifier.swift` is **not** an intent model: it is a cloud LLM call (prefers a
  saved gpt-4o-mini, then any OpenAI or Groq key) that answers `RESPOND`/`IGNORE` for bystander
  filtering in Direct mode, `Config.intentClassifierEnabled` default **off**, refused by
  `MedicalEgressGuard.check(.intentClassification)` in local-only mode (falls to `.uncertain`). Called
  once from `AppState` (`OpenGlassesApp.swift` ~5057).
- No intent model, no labelled utterance corpus. CoreML is used by `SignLanguage/FingerspellingInferenceEngine`
  (`MLModel(contentsOf:)`) and the privacy filter; `NaturalLanguage` by RAG, memory and translation.
- **Authorization:** `Services/NativeTools/ToolAuthorizationPolicy.swift` runs a ladder (composition
  floor → `HighImpactToolPolicy` when Agent Mode is off → `SafetySupervisor` when on) and then an
  effect-class floor that can only raise `.allow` to `.confirm(summary:)`.
  (`HighImpactToolPolicy` lives at `Services/HighImpactToolPolicy.swift`, not under `NativeTools/`.)
  `ToolEffectClassifier` (`Services/Security/ToolEffectClass.swift`) puts `send_message`, `send_via`,
  `phone_call`, `asian_messaging`, `chinese_app`, `escalate_to_expert`, `deliver_report`,
  `parts_request` in `.messaging`, which is **always** bound-approved. Native deletions
  (`delete`/`forget`/`remove`/`clear` actions on `contextual_note`, `geofence`, `object_memory`,
  `voice_skills`, `social_context`, `manage_schedule`) are `.write` on the native seam and run
  **unconfirmed**.
- **Declarations:** `ToolDeclarations.declarableNames` filters by enabled/HIPAA/`FieldToolProfile`;
  Anthropic requests put `cache_control` on the tool block, so anything per-turn must stay out of the
  tools and the system prompt or it breaks the cache.
- **Eval precedent:** `OpenGlassesTests/SafetyEval{Corpus,Harness,Report,GateTests}.swift` + fixtures
  in `OpenGlassesTests/Fixtures/SafetyEvalCorpus/` + `safety-eval.yml` (path-filtered, three test
  classes, Markdown summary to the job page). The harness is pure and deliberately produces no
  headline accuracy; this plan's gate differs in that it does.

## Design

### Label schema

`IntentLabel` = a registered `NativeTool.name` (the tool id) **or** one of four pseudo-labels:
`no_tool` (answerable by the model alone), `not_addressed` (bystander speech, filler, thinking
aloud), `cancel` (stop/never mind), `agent` (OpenClaw/gateway `execute`). Multi-action tools with an
irreversible action get a second level only where it matters: `geofence.delete`,
`contextual_note.delete`, `object_memory.forget` — the rest stay one level. A test walks
`NativeToolRegistry` and fails if a registered tool has no label entry (`IntentLabelCatalog`), or if
the catalog names a tool that no longer exists; a new tool therefore lands with corpus rows or an
explicit `unlabelled` marker that the report counts.

### Corpus (`Tools/IntentCorpus/`, not shipped in the app)

JSONL rows: `{id, text, lang, label, addressee, source, family, split}` where `addressee` ∈
`assistant`/`other_person`/`self_talk`, and `family` groups a seed sentence with all its paraphrases.

- **Synthetic (bulk).** A dev-time script generates seeds from each tool's `description` and
  `parametersSchema` (slot grammars: times, contacts from a fake-name list, places, amounts), then an
  LLM paraphrase pass (casual, clipped, disfluent, ASR-style lowercase without punctuation, with
  and without the wake word). Model id, prompt and seed are recorded in the corpus header so the set
  is reproducible. Target ~30–50k English rows, ≥ 150 per tool, more for the confusable clusters
  (timer/alarm/reminder, note/memory, search/news/weather, message/send_via/call).
- **Real phrasing (small, precious).** (a) the example phrases already in tool descriptions, App
  Shortcut phrases and prompt examples; (b) recorded read-and-rephrase sessions with the owner and
  testers ("ask for a timer the way you would"), transcribed by the app's own ASR so errors look
  real; (c) public intent datasets **after a licence check**: MASSIVE (multilingual, reported CC BY
  4.0), CLINC150 (out-of-scope class, reported CC BY 3.0); anything share-alike is excluded. Each is
  mapped to our labels by a checked-in mapping table; unmapped intents become `no_tool`.
- **Addressee rows.** Bystander and self-talk utterances that *look* like commands ("text her that
  I'm late" said across a table, "delete that, no wait") are the negative class for the check below.
- **Never** wearer transcripts from the field. There is no upload path, and GK adds none.

### Held-out discipline

- Splits are assigned **by family**, never by row, so no paraphrase of a test seed is ever trained on.
- `test` is frozen: its SHA-256 digest is checked in; `IntentCorpusIntegrityTests` fails if the file
  changes without a version bump and a changelog line. Tuning uses `dev` only.
- The report always shows two slices: **synthetic test** and **real-phrasing test** (human-authored
  sources only, never trained on). The real slice is the headline; synthetic accuracy flatters.

### Model and budget

Train with Create ML `MLTextClassifier` on a Mac (dev-time script `Scripts/train-intent-model.sh`),
two candidates benchmarked in P1: **maximum entropy** (self-contained, no OS assets, deterministic in
the simulator) and **transfer learning over the OS contextual embedding** (better on unseen
phrasing, multilingual, but depends on on-device embedding assets that the simulator may lack).
Ship the one that wins on the real slice within budget. Loaded through `NLModel` with
`MLModelConfiguration.computeUnits = .cpuOnly` so it runs while backgrounded (GE's locked-phone case).

| Budget | Limit |
|---|---|
| Bundled size | ≤ 5 MB per language model, ≤ 12 MB total |
| Latency | p95 ≤ 15 ms per utterance on the oldest supported iPhone, CPU only |
| Memory | ≤ 30 MB resident; loaded lazily, unloaded under memory warning |
| Output | top-3 labels with probabilities + addressee probabilities |

### Uses

1. **Hint (`IntentHint`).** When top-1 ≥ 0.6, one line is appended to the **user turn** (not the
   system prompt or tools, to keep prompt caching): `[likely tools: set_timer 0.82, reminder 0.11]`.
   Ignorable by design; no tool is removed. Narrowing the declared tools to top-k plus essentials
   (a GD3-style cost saving) is a later, separate decision.
2. **Offline routing.** `OfflineIntentRouter` replaces GE P2's keyword router: when GE is in `phone`
   state without a model (locked, MLX unavailable), a top-1 ≥ 0.8 on a tool GE's `OfflineToolPolicy`
   marks `local` runs that tool through a per-tool argument extractor (times, durations, labels);
   anything else takes GE's "hold until signal" path.
3. **Addressee check (`AddresseeCheck`, pure).** Inputs: the utterance(s) that led to the call, the
   classifier output, the resolved call and its `ToolEffectClass`. Scope: `.messaging`,
   `.physicalActuation`, `.sensitiveDisclosure`, `.financial`, and native destructive actions
   (`IrreversibleActionClassifier`: `delete`/`forget`/`remove`/`clear` on a `localMutation` tool).
   Verdict `.proceed` or `.ask(question)` when `P(not_addressed) ≥ 0.5`, **or** the called tool is
   outside the utterance's top-3 and not `agent`, **or** a vocative names someone other than the
   assistant ("Mike, send…"). It becomes a strengthen-only floor in `ToolAuthorizationPolicy.evaluate`,
   after the effect-class floor: an `.allow` becomes `.confirm(summary:)`, and an existing
   confirmation keeps its summary but gains the reason ("I wasn't sure you were talking to me.
   Send 'running late' to Maria?"). It never downgrades anything and never blocks. Under HIPAA and
   local-only mode it works unchanged (no egress), and it gives local-only mode the bystander filter
   `IntentClassifier` cannot.

### CI eval gate

`intent-eval.yml`, shaped like `safety-eval.yml`: path-filtered on the model, corpus, label catalog,
`NativeToolRegistry` and the router/policy files; runs `IntentEvalGateTests` (loads the bundled model,
scores `test` both slices, writes `.intent-eval/report.md` to the job summary). Fails when real-slice
top-1 drops > 2 points below the checked-in baseline, top-3 < 95 %, addressee miss rate on the
irreversible negative set > 5 %, or false-hold rate on ordinary irreversible requests > 3 %. The
thresholds start as **proposed**, like the safety gate's. If the embedding candidate wins and the
simulator lacks its assets, the gate runs on the macOS runner host instead of a simulator.

The **with-hint vs without** cloud comparison needs live keys and costs money, so it is not in PR CI:
`Scripts/intent-hint-ab.sh` (and a `workflow_dispatch` job using repository secrets) replays the real
slice through the real `SystemPromptBuilder` + declarations for one pinned model, records which tool
the model called, and writes `docs/evals/intent-hint-<date>.md`. That file is the published metric.

### Multilingual scope

English first (P1–P3). Next, the UI languages that SenseVoice also hears well (zh-Hans, ja), then the
rest of the Plan EC set (de, es, fr, pl, ru, uk) — each only when its real-phrasing slice has ≥ 300
human rows. A language without a model gets no hint and falls back to today's behaviour; the
addressee check then uses only the vocative and tool-mismatch rules and says so in its reason.

## Phases (one PR each)

**P0 — Label catalog and pure policies.** `IntentLabel`, `IntentLabelCatalog`, `IntentHint` (format,
threshold), `IrreversibleActionClassifier`, `AddresseeCheck`, `OfflineIntentRouter` (with a fake
classifier). Tests: `IntentLabelCatalogTests` (every registered tool labelled; no stale labels),
`IrreversibleActionClassifierTests`, `AddresseeCheckTests` (each rule; never downgrades; summary
wording), `IntentHintFormatTests` (user-turn only, threshold), `ToolAuthorizationPolicyTests` additions
(floor raises `.allow` on a delete; leaves refusals/blocks/holds untouched).

**P1 — Corpus, splits, training scripts, first model (English).** Generator, mapping tables, licence
notes (`Tools/IntentCorpus/LICENSES.md`), `Scripts/train-intent-model.sh`, both candidates benchmarked,
model bundled behind `Config.onDeviceIntentModelEnabled` (default off). Tests:
`IntentCorpusIntegrityTests` (digest, family-disjoint splits, label coverage), `IntentModelSmokeTests`.

**P2 — Eval gate + A/B script.** `intent-eval.yml`, `IntentEvalGateTests`, report writer, baseline
file, first published `docs/evals/intent-hint-*.md`.

**P3 — Wiring.** `IntentModelService` (lazy load, CPU only, memory-warning unload, injected into
`AppState` and the router), hint append in Direct mode, the floor live, GE's router swapped. Settings
→ Intelligence: "Understand requests on this phone" (copy never names the plan). Device checks owed:
latency on the oldest supported phone, backgrounded classification with the phone locked, false
holds over a week of real use.

**P4 — More languages; optional tool narrowing** (only with a measured win).

## Risks

- **Synthetic overfit.** Mitigated by family splits and the real-slice headline; the real slice is
  small, so report its confidence interval, not just the point.
- **Nagging.** A floor that asks too often trains reflexive "yes". The false-hold threshold is a gate
  metric for that reason.
- **Label drift.** Tools get added weekly; the catalog test and the eval gate's path filter on
  `NativeToolRegistry` keep the model from silently going stale.
- **Licensing** of public datasets must be verified per dataset before any row is committed.

## Decisions for Greig

1. **Ship the hint at all?** Only if the A/B shows a gain on the real slice. *Recommend yes, conditional.*
2. **Model family:** maxent vs embedding transfer — decide on the P1 numbers. *Recommend whichever wins
   on the real slice; tie → maxent (simpler CI).*
3. **Addressee floor on by default** once P2 passes its false-hold threshold? *Recommend yes; it never blocks.*
4. **Retire the cloud `IntentClassifier`** in favour of the local addressee probability? *Recommend
   after one release of side-by-side logging (verdicts only, no text).*
5. **Public datasets** (MASSIVE, CLINC150) vs synthetic + owned recordings only.
6. **Budget for the A/B runs** (live model calls) and which model is pinned for the published number.

## Out of scope

Replacing the cloud model's tool choice, slot filling beyond GE's small offline set, on-device
training or personalisation from the wearer's speech, and any upload of real transcripts.
