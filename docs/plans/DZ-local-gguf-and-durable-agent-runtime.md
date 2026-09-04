# Plan DZ — Local GGUF Runtime and Durable Agent Loops

**Status:** 🚧 In progress — **P0 / PR1 ✅ complete**, **P1 / PR2 ✅ complete** (all flags off);
PR3 onward not started.
**Priority:** P1 for the text-only GGUF runtime and model acquisition path; P1 reliability work for
scheduled tasks; P2 for memory curation; vision and skill-pack storage remain gated follow-ups.

### P0 / PR1 — what actually landed, and its caveats

Landed: `LocalInferenceTypes` (runtime/model identity, descriptor validation, relative-path
containment, generation shapes), `LocalInferenceBackend`, `LocalInferenceCoordinator` (single
residency, cancel-then-unload ordering, reentrancy refusal, foreground-only probe),
`MLXLocalInferenceBackend` + `MLXPromptAdapter`, `LocalModelCatalog` (versioned bundled catalog,
with `LocalLLMService.recommendedModels` / `visionModelIds` / `expectedDownloadBytes` as
compatibility projections), `LocalModelRepository` (installation manifest + `.complete` marker +
read-back-verified, forward-only legacy migration), backend-aware admission in `LocalModelBudget`,
and the four feature flags — all default off.

Honest caveats on the exit criteria:

- **"Existing MLX models load and generate through the compatibility façade" is proved
  structurally, not on a device.** `MLXPromptAdapter.decompose` is pinned as the exact inverse of
  the `compose` that `sendLocal` calls, and the backend is driven against a recording fake to show
  the MLX runtime receives byte-identical arguments. No MLX weights were loaded: the simulator
  cannot, and the device evidence in the test plan is still outstanding.
- **The coordinator route is flag-gated and off.** `Config.localRuntimeCoordinatorEnabled` defaults
  false, so every shipped turn still takes the direct `LocalLLMService` call. The seam is proven,
  not yet exercised in production.
- **The catalog is Swift, not `Resources/LocalModelCatalog.json`.** A JSON entry's value is its
  size/digest/revision triple, and no MLX entry has one — these are hub snapshots fetched whole,
  with no pinned revision and no recorded digests. Writing them to JSON would be writing empty
  fields more expensively. `installationFaults()` reports `.unpinnedRevision` for every current
  entry precisely so this cannot become the standard for a *new* download. The JSON catalog lands
  with PR4, which can populate it.
- **Licence metadata is `.unverified` for every entry.** No acceptance gate existed before DZ and
  inventing licence names for models that install today would be asserting something unchecked.
  Curated licence text is PR4 work.
- **Admission is additive, not rewired.** `LocalModelBudget.admit` supplies the
  `allow` / `allowConstrained` / typed-refusal vocabulary the second runtime needs, and is pinned to
  refuse exactly when the shipping `MemoryHeadroom.canLoad` gate does. The MLX load path still calls
  `canLoad`; swapping it for a differently-tuned gate would have been a behaviour change wearing a
  refactor's clothes.
- **Legacy MLX files are discovered, never moved.** A migrated record is
  `.legacyHubSnapshot` and points at the existing `models--org--name` directory. Relocating
  multi-gigabyte directories is how an interrupted migration costs someone their model.
- **The migration is the one part of PR1 that runs on every device with the flags off.** It is
  wired into launch beside the other one-time migrations, writes only into a new `installed/`
  subdirectory, and after its first success costs a single integer read per launch. Nothing yet
  *consumes* the records — PR4/PR5 do — so a device that defers or fails it is in no worse a state
  than before DZ.
- **`LocalModelDownloadManager` / `LocalModelDownloadPlan` are not in this PR** — they belong to the
  acquisition work in PR4 and would have no consumer here.

### P1 / PR2 — what actually landed, and its caveats

Landed: `Vendor/LlamaCpp` as a local SPM package (`Package.swift`, the `LlamaCppWrapper`
Objective-C++ target behind a minimal C ABI, a static `llama.xcframework` built from a pinned
revision, plus `REVISION`, `SHA256SUMS`, `BUILD-INFO`, `NOTICES.md` and a `README.md`);
`Scripts/build-llamacpp-framework.sh` and `Scripts/fetch-llamacpp-framework.sh`; the package wired
into `project.base.yml` and the CI post-clone; `LlamaRuntimeAvailability` as the app's only contact
with the engine; and `LlamaRuntimePackageTests` guarding the pin, the digests, and the
"linked is not enabled" property.

`BUILD-INFO` is an addition to the layout the plan prescribed, not a substitution — see the
reproducibility caveat below for what it is for.

The engine is pinned at `c1d0e7a004015f23bc0233470b747b596f29b264` (release `v0.3.0`), chosen
because it is upstream's newest *non-prerelease* release — every `bNNNNN` tag is published as a
prerelease nightly, so pinning one would be pinning a nightly.

Honest caveats on the exit criteria:

- **"Metal execution works" is not among the claims.** The device slice builds with Metal
  compiled in and links; nothing has run a Metal graph on hardware, because nothing loads a model
  until PR3. `LlamaRuntimeAvailability.supportsGPUOffload` says the backend is present, not that it
  runs. A successful simulator build is explicitly not evidence here.
- **The wrapper ABI is written but unexercised.** Tokenization, template application, batched
  decode, sampling and detokenization compile and are shaped for PR3's flow; not one of them has
  processed a real GGUF file. The tests in this slice cover the *packaging* promise, not the
  engine's behaviour.
- **Byte-level reproducibility is not claimed, only source-level.** The revision is pinned by
  commit and cross-checked against its tag before compiling, but a static archive carries DWARF
  with absolute paths, so a different Xcode or a different checkout directory produces different
  digests from identical sources. `BUILD-INFO` records revision, options fingerprint, toolchain and
  checkout path; the build script fails hard on a digest change that *none* of those explain, and
  records the new digests loudly when one of them does. `--strict` makes any difference fatal.
- **There is no published artefact mirror yet, so "a clean clone deterministically obtains the
  exact binary" is only half true.** `Scripts/fetch-llamacpp-framework.sh` verifies a downloaded
  archive against both its own digest and `SHA256SUMS` — but with no URL configured it falls
  through to building from the pinned sources, which is deterministic in sources and not in bytes.
  Mirroring the xcframework as a release asset (and setting `LLAMACPP_FRAMEWORK_URL` /
  `_SHA256`) closes this; the fetch path is already written and waiting for it.
- **CI now builds the engine on a cold run.** Xcode Cloud has no Homebrew, so
  `ci_post_clone.sh` sets `OG_ALLOW_TOOL_BOOTSTRAP=1` and the fetch script unpacks a pinned,
  checksum-verified cmake into `.ci-tools/` the way the same script already does for XcodeGen. This
  adds several minutes per cold archive. A mirror removes it. On a developer's Mac the bootstrap is
  off and a missing cmake is a clear error, never a silent install.
- **The simulator slice runs generic CPU kernels.** Building it for `arm64` and `x86_64` together
  defeats ggml's architecture detection ("Unknown CPU architecture. Falling back to generic
  implementations"). The device slice is unaffected. Simulator inference is correct and slow, which
  is acceptable because the simulator is not a supported place to run local models — MLX cannot run
  there at all. `--sim-archs arm64` trades Intel Mac support for NEON.
- **`LLAMA_BUILD_MTMD=OFF`.** The multimodal projector is not built, matching the text-only
  invariant. The vision phase flips the option and re-pins; it is not a silent capability sitting
  in the binary.
- **No module map ships inside the xcframework.** Xcode copies a static xcframework's headers into
  `$BUILT_PRODUCTS_DIR/include`, so a second vendored xcframework carrying one collides with
  sherpa-onnx's ("Multiple commands produce …/include/module.modulemap"). The wrapper only needs
  the headers on the search path, and Swift is meant to see `LlamaCppWrapper.h`, never `llama.h`.
- **`Package.resolved` is unchanged, correctly.** Local path packages are not pinned in the
  SwiftPM lockfile — sherpa-onnx and MediaPipe are absent from it for the same reason.

---

## Product promise

OpenGlasses can run a broader range of user-selected local models without weakening the existing
MLX path, can acquire those models safely, and can keep scheduled work and long-term memory honest
when the app is suspended, a model is unavailable, or a write fails.

The implementation is deliberately split into independently reversible tracks:

1. a common local-inference seam and a text-only GGUF backend;
2. a revision-pinned model catalog, importer, and resumable installer;
3. durable scheduled-task outcomes and retry state;
4. transactional, reviewable memory curation;
5. a later multimodal GGUF adapter after text inference is proven on devices; and
6. an optional host-managed storage binding for signed, data-only skill packs.

No phase depends on copying another application's UI, lifecycle, or agent architecture. This plan is
the complete implementation contract.

## Existing system to preserve

- `LocalLLMService` is the current local-inference façade. It owns MLX download, load, generation,
  cancellation, and published UI state. Existing callers should continue to use it during migration.
- `LLMService` owns provider routing, conversation assembly, the tool loop, and local-output parsing.
  A local backend returns streamed assistant text; it does not execute tools itself.
- `LocalModelBudget` and `MemoryHeadroom` already make context and turn-time admission decisions.
  GGUF models must use these policies instead of creating a second, optimistic memory heuristic.
- `LocalModelManagerView` is the single user-facing place to discover, download, load, unload, and
  remove local models.
- `AgentScheduler` currently stores task definitions in `UserDefaults`, runs opportunistically, and
  treats most execution errors as completed runs. That completion behavior must be replaced.
- `AgentNotificationQueue` is the durable delivery path for results that should be spoken after the
  device reconnects.
- `SemanticMemoryStore`, `ConversationIndex`, `BrainStore`, and `AgentDocumentStore` remain the
  authoritative memory stores. Curation adds coordination and provenance; it does not create a new
  universal memory database.
- `MemoryLoopService` handles immediate per-turn detection. Batch curation complements it and must
  not duplicate facts or autonomously rewrite safety/personality documents.
- `SkillPackManifest` describes signed data-only capability packs. Packs remain non-executable.
- The Xcode project is generated from the YAML specifications. Package changes go through
  `project.base.yml` and the package manifests, never direct project-file edits.

## Decisions and invariants

1. **GGUF is a second runtime, not an MLX replacement.** Existing downloaded MLX models, first-run
   offers, model IDs, and saved configurations continue to work without redownload or user action.
2. **One coordinator owns local model residency.** Only one large local model backend may be loaded
   at a time. Switching runtime always awaits generation cancellation, backend unload, accelerator
   synchronization, and memory release before loading the next model.
3. **Text-only first.** The first shipping GGUF slice accepts text conversation history and streams
   text tokens. Image projection and multimodal prompt construction are a later phase.
4. **Full-history generation is the safe initial cache policy.** Each GGUF generation clears the KV
   cache and renders the complete supplied conversation. Prefix-cache reuse is out until a tested
   prefix-diff can prove there is no duplicated or stale history.
5. **The model's embedded chat template is authoritative.** The runtime applies a usable template
   found in the GGUF metadata. Arbitrary imports without a supported template are installable only
   as inactive files and cannot be selected for chat. Curated entries must pass a template smoke
   test before inclusion.
6. **Context admission happens before decode.** Prompt tokens plus a reserved output allowance must
   fit the selected context window. The user receives a typed, actionable error; input is never
   silently truncated in the backend.
7. **Prompt decode is batched.** Token input is partitioned into chunks no larger than the runtime's
   configured batch size. Long prompts must not be submitted as one oversized batch.
8. **Runtime pointers are actor-owned.** Model, context, vocabulary, sampler, multimodal projector,
   and batch allocations never cross the owning actor unsafely. Cancellation is checked between
   prompt batches and generated tokens.
9. **Downloads are immutable and integrity-checked.** A model is selected at an exact repository
   revision. Every file has an expected size and digest. Installation becomes visible only after all
   files validate and the staged directory is moved atomically into place.
10. **No remote executable catalog.** The first catalog ships in the app bundle. A future remotely
    updated catalog requires signed metadata, expiry, rollback protection, and the same validation
    as signed content packs.
11. **Public model acquisition first.** The first importer supports anonymous public repositories.
    Gated/private repository credentials are a separate opt-in design and must use Keychain storage.
12. **Local inference is foreground-best-effort.** Metal-backed model execution is not presented as
    reliable background work. A scheduled task using an unloaded or unavailable local model defers;
    it never auto-loads a multi-gigabyte model at launch or in the background.
13. **Attempts and successes are separate facts.** A failed, cancelled, or uncheckable scheduled run
    does not advance `lastSuccessAt` or consume the recurrence.
14. **Curation commits atomically.** Its cursor advances only after all planned writes have either
    committed or been recorded as explicit no-ops. Retries use stable idempotency keys.
15. **Curation cannot change authority.** It may create/update memory records and propose learned
    skills. It may not rewrite `SOUL`, grant tools, change safety policy, enable automation, or turn a
    skill proposal into an active skill without the existing review path.
16. **Prompt content stays out of diagnostics.** Performance records contain model/runtime IDs,
    token counts, durations, memory readings, and thermal state; never prompt, response, filename,
    or user-memory text.
17. **Every track is feature-flagged and fail-closed.** Disabling GGUF leaves MLX available;
    disabling the new scheduler pauses scheduled execution instead of restoring the known
    success-on-error path; disabling curation stops new batches. None of these actions deletes data.

## Target architecture

```text
LLMService / tool loop
        │
        ▼
LocalLLMService compatibility façade
        │
        ▼
LocalInferenceCoordinator (actor; one resident model)
        │
        ├── MLXLocalInferenceBackend
        └── LlamaCppLocalInferenceBackend
                 │
                 └── optional GGUFMultimodalAdapter (later)

LocalModelCatalog ── LocalModelRepository ── LocalModelDownloadManager
        │                     │                         │
 bundled descriptors      installed manifest      staged/validated files

AgentScheduleStore ── SchedulePolicy ── AgentScheduler ── AgentNotificationQueue

MemoryCurationStore ── MemoryCurationPlanner ── MemoryCurationCommitter
        │                                            ├── SemanticMemoryStore
 completed batches/cursor                            ├── AgentDocumentStore snapshots
                                                     └── EvolvedSkillStore proposals
```

## Core data contracts

### Runtime and model identity

Add a stable descriptor that separates a model's identity from its runtime-specific files:

```swift
enum LocalModelRuntime: String, Codable, Sendable {
    case mlx
    case llamaCpp
}

struct LocalModelID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

struct LocalModelDescriptor: Codable, Hashable, Sendable {
    let id: LocalModelID
    let displayName: String
    let runtime: LocalModelRuntime
    let repositoryID: String
    let revision: String
    let files: [LocalModelFile]
    let quantization: String?
    let capabilities: Set<LocalModelCapability>
    let contextLength: Int
    let estimatedWeightsBytes: Int64
    let estimatedWorkingBytes: Int64
    let minimumHeadroomBytes: Int64
    let license: LocalModelLicenseSummary
}

struct LocalModelFile: Codable, Hashable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String
    let role: Role       // weights, projector, tokenizer, config, auxiliary
}
```

Rules:

- `id` is app-owned and stable across display-name or URL changes.
- `repositoryID + revision + relativePath` identifies a remote artifact; floating branches are not
  valid installed-model metadata.
- Relative paths must be normalized, non-empty, and contained beneath the model's staging root.
- Capabilities are factual: `.text`, `.vision`, `.toolFriendly`. A model is never inferred to be
  vision-capable from its name.
- Model license metadata includes the displayed name, a bundled summary, whether explicit acceptance
  is required, and the accepted license revision. Installation records that acceptance locally.
- Existing MLX model strings map to bundled descriptors. Unknown legacy MLX strings receive a
  generated compatibility descriptor with `runtime = .mlx`; no saved configuration becomes invalid.

### Backend protocol

```swift
protocol LocalInferenceBackend: Sendable {
    var runtime: LocalModelRuntime { get }
    func load(_ installation: InstalledLocalModel,
              configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel
    func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error>
    func cancelGeneration() async
    func unload() async
}

struct LocalGenerationRequest: Sendable {
    let messages: [LocalChatMessage]
    let images: [LocalImageInput]
    let maxOutputTokens: Int
    let sampling: LocalSamplingConfiguration
    let stopSequences: [String]
}
```

The protocol is intentionally narrow. Downloading, catalog metadata, conversation storage, tool
execution, and UI state do not belong in a backend. The coordinator translates backend state into
the existing `LocalLLMService` published properties while the migration is in progress.

### Installed-model manifest

Each installed model directory contains `installation.json` and a `.complete` marker. The manifest
records descriptor version, exact revision, validated files, installation date, license acceptance,
and the framework build identifier used for the latest successful load. Directory layout:

```text
Application Support/LocalModels/
├── installed/<percent-encoded stable model ID>/
│   ├── installation.json
│   ├── *.gguf or MLX model files
│   └── .complete
├── staging/<download UUID>/
│   ├── download-plan.json
│   └── partial files
└── quarantine/<download UUID>/
    └── validation-failure.json
```

All directories are excluded from backup and use the app's protected-file policy. A directory
without both a valid manifest and `.complete` is never presented as installed. Quarantine is bounded
by age and total size and contains no credentials.

### Scheduled-run state

Keep task definition separate from mutable execution state:

```swift
enum ScheduledTaskRunStatus: Codable, Equatable {
    case succeeded(reported: Bool)
    case deferred(reason: ScheduleDeferralReason)
    case couldNotCheck(reason: ScheduleCheckFailure)
    case failed(SanitizedTaskFailure)
    case cancelled
}

struct ScheduledTaskState: Codable, Equatable {
    let taskID: String
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextEligibleAt: Date?
    var consecutiveFailures: Int
    var firstFailureAt: Date?
    var lastFailure: SanitizedTaskFailure?
    var lastWarningAt: Date?
    var recentRuns: [ScheduledTaskRunRecord]
}
```

`[NOTHING]` remains an output adapter and maps to `succeeded(reported: false)`. It is not a failure.
The store retains a bounded run history per task (default 20 records) and no response text.

### Memory curation records

```swift
struct MemoryCurationBatch: Codable, Sendable {
    let id: UUID
    let cursorBefore: MemoryCurationCursor
    let inputReferences: [MemoryInputReference]
    let createdAt: Date
    var state: MemoryCurationBatchState
    var proposedMutations: [MemoryMutationProposal]
    var appliedMutationIDs: Set<String>
}

enum MemoryMutationProposal: Codable, Sendable {
    case upsertMemory(idempotencyKey: String, record: CuratedMemoryRecord)
    case supersedeMemory(idempotencyKey: String, oldID: String, replacementID: String)
    case proposeSkill(idempotencyKey: String, proposal: CuratedSkillProposal)
    case noOp(idempotencyKey: String, reason: MemoryNoOpReason)
}
```

Every proposal names the input records that justify it and a confidence. The committer validates
scope, size, and allowed mutation type again; it does not trust model-produced operation names.

## Work packages and pull-request sequence

### P0 / PR1 — Runtime seam, model records, and migration

Build the deterministic core before linking another inference engine.

1. Add `LocalModelRuntime`, `LocalModelDescriptor`, `InstalledLocalModel`, `LocalModelRepository`,
   `LocalInferenceBackend`, and `LocalInferenceCoordinator`.
2. Wrap the existing MLX implementation in `MLXLocalInferenceBackend`. This should initially be a
   thin adapter around the current load/generate/unload code, not a behavior rewrite.
3. Keep `LocalLLMService` as the UI-compatible façade. Route one feature-flagged MLX generation
   through the coordinator and assert byte-for-byte-equivalent prompt assembly and equivalent
   streamed-output semantics.
4. Move the recommended model list into a versioned bundled catalog while preserving the current
   static accessors as compatibility projections.
5. Add a legacy migration:
   - known saved MLX IDs resolve to their bundled descriptor;
   - unknown IDs resolve to a compatibility MLX descriptor;
   - already downloaded MLX directories are discovered without moving files in this PR;
   - migration is idempotent and writes a version only after successful validation.
6. Implement backend-aware admission in `LocalModelBudget`. Inputs include runtime, declared weights,
   configured context, live app footprint, available process memory, image working set, and a safety
   reserve. The output is `allow`, `allowConstrained`, or a typed refusal.
7. Add feature flags `localRuntimeCoordinatorEnabled`, `ggufModelsEnabled`,
   `durableSchedulerStateEnabled`, and `memoryCurationEnabled`, all default off.

PR1 exit criteria:

- every current local-model test remains green;
- existing MLX models load and generate through the compatibility façade;
- no model redownload occurs;
- the coordinator refuses a second resident model and unloads cleanly; and
- decoding any pre-DZ saved model/task configuration succeeds.

### P1 / PR2 — Reproducible llama runtime package

Add the native runtime as a local package named `LlamaCpp`.

Expected package layout:

```text
Vendor/LlamaCpp/
├── Package.swift
├── Sources/LlamaCppWrapper/
│   ├── include/LlamaCppWrapper.h
│   └── LlamaCppWrapper.mm
├── Frameworks/llama.xcframework        # fetched/generated, not hand-edited
├── REVISION
├── SHA256SUMS
└── NOTICES.md
Scripts/build-llamacpp-framework.sh
Scripts/fetch-llamacpp-framework.sh     # if CI consumes a prebuilt artifact
```

Requirements:

- Pin an exact engine revision in `REVISION`; never build a moving branch.
- Produce device and simulator slices for the current iOS deployment target and merge them into one
  XCFramework. Enable Metal and Accelerate; omit command-line tools, examples, tests, and server code.
- The build script validates the expected revision, build options, architectures, and final digest.
- Prefer a small Objective-C++/C wrapper with an intentionally minimal C ABI over exposing unstable
  C++ types to Swift. The wrapper exposes model/context lifecycle, metadata lookup, tokenization,
  chat-template application, batched decode, sampling, detokenization, cancellation checks, and
  accelerator synchronization.
- Add the local package to `project.base.yml` and the root Swift package if both build surfaces need
  the application services. Do not edit a generated Xcode project.
- Update post-clone CI to fetch or build the framework and validate its checksum before resolving the
  app. Keep large generated binaries out of ordinary source commits unless repository policy is
  explicitly changed.
- Record third-party notices and compile settings in the vendored package.
- Add a compile-only smoke test that imports the wrapper in Debug, Release, device, and simulator
  configurations. A successful simulator build is not evidence that Metal device execution works.

PR2 exit criteria:

- a clean clone can deterministically obtain the exact binary;
- checksum or revision drift fails with a clear error;
- Debug and Release compile for simulator and device; and
- removing `ggufModelsEnabled` from the active build leaves all MLX behavior unchanged.

### P1 / PR3 — Text-only GGUF load and generation

Implement `LlamaCppLocalInferenceBackend` as an actor.

Load flow:

1. Resolve a completed installation by stable ID and validate the manifest again.
2. Ask the coordinator for exclusive residency and run the memory-admission policy.
3. Load model metadata without guessing architecture or chat format from the filename.
4. Read and validate the embedded chat template. If it cannot render a minimal system/user/assistant
   exchange, return `unsupportedChatTemplate` and unload.
5. Clamp context length to the smaller of model capability, descriptor policy, and memory budget.
6. Create the context and sampler; publish loaded state only after all resources succeed.
7. On any failure, destroy partially created resources in reverse order and report a typed error.

Generation flow:

1. Reject images in the text-only phase with `visionNotAvailable`.
2. Convert `LocalChatMessage` values into the runtime's chat-message representation.
3. Apply the embedded template, tokenize with special-token handling appropriate to the template,
   and calculate the output reserve.
4. If `promptTokens + outputReserve > nContext`, fail before decode with counts in the diagnostic
   metadata but not the prompt text.
5. Clear the KV cache for every request.
6. Decode prompt tokens in chunks `<= nBatch`, checking cancellation between chunks.
7. Sample one token at a time, stop on EOS, configured stop sequences, cancellation, or output cap,
   and emit only valid Swift strings.
8. Use a byte accumulator for token pieces so split UTF-8 sequences are not emitted as replacement
   characters or dropped.
9. Record load time, prompt-decode time, first-token latency, generated-token count, tokens/second,
   context usage, memory-headroom deltas, and thermal state.
10. Synchronize outstanding accelerator work during cancellation and before resource destruction.

Sampling starts with conservative app-owned defaults: temperature, top-p, top-k, repeat penalty,
and deterministic seed injection for tests. Per-model overrides live in the bundled descriptor, not
in filename heuristics.

Tool behavior remains in `LLMService`. The backend streams assistant text in the same shape as MLX,
including any textual tool-call envelope expected by the current parser. Curated models marked
`toolFriendly` must pass a tool-call conformance fixture before receiving that capability.

PR3 exit criteria:

- a curated small GGUF loads, answers a one-turn prompt, and unloads on a physical device;
- a second turn contains exactly one copy of each prior message;
- a prompt longer than `nBatch` succeeds through multiple decode calls;
- an over-context prompt fails before native decode;
- cancellation stops token delivery and releases the coordinator lease; and
- switching GGUF → MLX → GGUF does not leave two model allocations resident.

### P2 / PR4 — Safe catalog, repository importer, and downloader

Add one acquisition pipeline used by curated entries and custom public-repository imports.

#### Import parsing

- Accept `owner/repository` or a full repository URL.
- Reject schemes other than HTTPS, embedded credentials, query-based token material, malformed
  repository names, non-allowlisted hosts, and paths outside the repository form.
- Resolve repository metadata to an exact immutable revision before creating a download plan.
- Enumerate eligible `.gguf` files and optional projector files. Never execute repository scripts or
  consume arbitrary HTML.
- Parse quantization labels as display metadata, not as trust evidence. Prefer a curated default only
  when the exact file is present; otherwise require user selection.

#### Fit and consent

Before download, show:

- model name, runtime, quantization, capabilities, exact download size, and available storage;
- a conservative load verdict based on declared weights plus working reserve;
- the license summary and acceptance control when required; and
- a warning that an import may install successfully but remain unloadable if its architecture or
  chat template is unsupported.

Unknown size, missing digest, or unresolved revision prevents installation. An unreadable free-space
reading is a visible inability to check, not permission to proceed optimistically.

#### Download state machine

```text
planned → awaitingConsent → queued → downloading → validating → installing → installed
                          ↘ cancelled
downloading/validating/installing → failed(retryable | terminal)
```

- Use a background `URLSession` with a stable task identifier and persisted `download-plan.json`.
- Limit acquisition to one model plan at a time and download a plan's files sequentially to bound
  disk and memory pressure.
- Restore task-to-plan mapping after relaunch; progress comes from persisted expected/completed bytes,
  not only in-memory callbacks.
- Stream to staging files. Do not buffer model files into memory.
- Revalidate the final redirect host and HTTPS policy for every response.
- Verify normalized destination containment, HTTP status, expected bytes, and SHA-256 before install.
- Move the completed staging directory atomically, write `.complete` last, and then publish installed
  state. Power loss at every prior step must leave either the previous installation or a recoverable
  staging plan, never a half-installed model.
- Cancellation removes the session tasks and moves incomplete state to bounded quarantine or deletes
  only the exact validated staging directory.
- Deleting a model first cancels its downloads, then unloads it if resident, then removes the exact
  installed directory after checking it is beneath the model root.

#### Catalog policy

Ship a small bundled GGUF catalog, initially text-only and tool-capable where verified. Each entry has
an exact revision, exact files, digests, context policy, memory estimate, and license metadata. Do not
add a model based only on a successful load; it must complete the conversation, long-prompt,
cancellation, tool-call, and device-memory fixtures relevant to its capability badges.

PR4 exit criteria:

- curated and custom imports use the same state machine;
- pause/relaunch/resume preserves progress;
- size, digest, redirect, traversal, and revision mismatches cannot produce `.complete`;
- cancellation and deletion affect only the selected model plan; and
- the app recovers cleanly from termination during each transition.

### P2 / PR5 — Local model manager and diagnostics

Extend `LocalModelManagerView` instead of creating a second model screen.

Required UI:

- filter or group by MLX/GGUF and text/vision capability;
- runtime and quantization badges;
- installed, staged, incompatible, loaded, and update-available states;
- download size, on-disk size, estimated working memory, and current fit verdict;
- per-file/background progress with cancel and retry;
- load, unload, remove, and “show incompatibility reason” actions;
- a custom import sheet with repository parser, file/quant selection, license acceptance, and final
  download confirmation; and
- a diagnostic card showing framework revision, model revision, context, first-token latency,
  tokens/second, memory delta, and thermal state.

Accessibility requirements:

- progress changes are announced at bounded intervals, plus completion/failure immediately;
- badges have full VoiceOver labels rather than relying on color;
- destructive removal requires confirmation and names whether staged and installed files are removed;
- unsupported models explain what metadata or runtime capability is missing; and
- leaving the screen during a background download explicitly says the download continues.

The selected local model stored in app configuration becomes a stable `LocalModelID`; the runtime is
resolved from the descriptor. For one compatibility release, retain the legacy string field and keep
it synchronized. Downgrading to a build without DZ must still leave an MLX selection usable.

### P1 / PR6 — Durable scheduler semantics

This work can begin after P0 contracts and does not wait for the GGUF UI.

1. Extract pure `SchedulePolicy` functions for due calculation, recurrence, retry delay, catch-up,
   warning thresholds, and next wake suggestion.
2. Add an actor-backed `AgentScheduleStore` using an atomically replaced JSON file in Application
   Support. Store task definitions and execution state separately. Migrate the existing
   `agentScheduledTasks` blob once; retain it as a rollback copy for one release.
3. Replace `TaskRunOutcome.completed` with the typed statuses above. Every error path must classify
   itself; an absent `appState` is `couldNotCheck`, never success.
4. Update state as follows:
   - every dispatched run records `lastAttemptAt`;
   - only `succeeded` records `lastSuccessAt` and advances normal recurrence;
   - `deferred` sets a short eligibility delay without incrementing failure count;
   - `couldNotCheck` and `failed` increment consecutive failures and apply bounded exponential
     backoff with deterministic jitter injection for tests;
   - `cancelled` records the attempt but neither success nor failure streak; and
   - the first subsequent success resets failure state and warning suppression.
5. Prevent catch-up storms. On activation, a periodic task may run at most once even if several
   periods were missed, then schedules from the successful current run. A once-daily task may catch
   up once within its configured day window. Only one task runs per scheduler cycle.
6. Preserve the current foreground timer as an opportunistic trigger. Add a background-refresh
   adapter only as another chance to call the same policy; never claim exact timing.
7. Apply backend-aware execution policy:
   - loaded local model + foreground: eligible;
   - unloaded local model: deferred without auto-load;
   - background local model: deferred;
   - cloud model: eligible only if its existing credentials, privacy mode, network policy, and task
     configuration permit cloud use; and
   - no silent runtime fallback for a task pinned to a specific model.
8. Warn through `AgentNotificationQueue` after three consecutive failed/could-not-check attempts or
   six hours without a successful check, whichever is later. Suppress repeats for 24 hours unless
   the failure reason materially changes. Recovery clears the warning episode.
9. Add a bounded task history and status details to `ScheduledTasksView`: last success, last attempt,
   next eligibility, failure streak, sanitized reason, and “Run now”. Manual runs use the same
   outcome and persistence path.

Suggested initial retry delays are 5, 15, 30, 60, and 120 minutes, capped at two hours. The policy
owns these values so tests do not sleep and product tuning does not alter execution code.

PR6 exit criteria:

- thrown errors never update `lastSuccessAt`;
- deferred local work retries only when eligible and does not increase the failure streak;
- relaunch preserves attempts, backoff, and warning suppression;
- a week of missed intervals produces one catch-up run, not a replay storm;
- recovery resets the episode and produces no stale warning; and
- existing task creation/edit/delete flows operate through the new store.

### P2 / PR7 — Two-stage memory curation

Replace the current scheduled “memory reflection” prompt with a dedicated, opt-in pipeline. The old
task remains disabled during migration and is removed only after this phase is proven.

#### Stage A — Freeze an immutable input batch

1. Read completed conversation-turn references after the durable cursor, bounded by turn count,
   character count, age, and active memory/privacy policy.
2. Record stable input references and the cursor-before value in `MemoryCurationStore` before invoking
   a model. Do not copy attachments, images, or full chat history into the curation database.
3. Ask an injected analyzer for a strictly structured set of candidate facts, preferences,
   procedures, corrections, and explicit no-ops. Local-only is the default. In a privacy mode that
   forbids cloud processing, the analyzer must be an already loaded local model or the batch defers.
4. Validate the analyzer output against app-owned enums, size limits, scopes, and provenance. Unknown
   operations, autonomous instructions, tool grants, and personality/safety edits are rejected.
5. Persist the validated proposals with deterministic idempotency keys derived from input IDs,
   mutation kind, scope, and normalized content.

#### Stage B — Curate and commit

1. Resolve candidate duplicates against `SemanticMemoryStore` and pending/applied curation batches.
2. Classify each proposal as insert, update, supersede, skill proposal, or no-op. Conflicting facts do
   not overwrite silently: keep the previous record, add a correction linked to it, and expose the
   conflict for later user review.
3. Before any bounded rewrite of `AgentDocumentStore.memory`, create a versioned snapshot containing
   the prior bytes, digest, date, and batch ID. Keep the most recent 10 snapshots and any snapshot
   newer than 30 days; never prune the only known-good snapshot.
4. Apply memory mutations through authoritative store APIs. Supersession uses tombstones/links rather
   than hard deletion. Skill-shaped knowledge goes only to `EvolvedSkillStore` as a pending proposal.
5. Record each committed idempotency key immediately. A retry skips already committed mutations and
   resumes the remaining plan.
6. Advance the global cursor only after every proposal is committed or recorded as an explicit no-op.
   A failed write leaves the batch retryable with the prior cursor.
7. Enforce a `MemoryCurationBudget` for injected memory, individual records, proposal counts, and
   document size. Prefer relevance and recency while preserving explicit user memories. Exact defaults
   live in one tested policy type.

#### Trigger and controls

- Trigger after a configurable number of completed turns or from a two-hour scheduler opportunity,
  whichever comes first. Only one curation batch may run at a time.
- Default off for existing users. The control explains what content is analyzed, whether cloud is
  allowed, and that learned skills still require review.
- Add a phone status surface under Memory: enabled state, analyzer policy, pending batch, last success,
  last error, proposed-skill count, snapshot list, and restore action.
- Restoring a snapshot requires confirmation, creates a snapshot of the current bytes first, performs
  an atomic replacement, and records an audit event. It does not rewind unrelated semantic memories.
- Disabling curation stops future batches without deleting existing memory. “Erase curation history”
  removes batch metadata only after no batch is running and does not imply erasing authoritative
  memories.

PR7 exit criteria:

- a failed mutation cannot advance the cursor;
- process termination between mutations resumes without duplicate records;
- identical input is idempotent across retries and relaunch;
- `SOUL`, active `SKILLS`, tool grants, schedules, and safety settings cannot be mutation targets;
- cloud analysis is impossible when the active privacy policy forbids it;
- every destructive document rewrite has a verified, restorable snapshot; and
- the current immediate memory loop still works without double-saving curated facts.

### P3 / PR8 — GGUF multimodal adapter, gated on text evidence

Do not start this phase until PR3–PR5 have passed the device matrix and switching between runtimes no
longer shows unexplained memory growth.

Add an optional multimodal adapter around the runtime's supported projector path:

- model descriptors name the exact projector file and compatible model revision;
- load validates model/projector compatibility before publishing vision capability;
- `LocalGenerationRequest.images` accepts bounded, normalized images and text messages;
- image preprocessing runs off the main actor, preserves aspect ratio, and uses
  `LocalModelBudget.multimodalTurnPlan` plus live `MemoryHeadroom` at turn time;
- below the safe headroom floor, the request fails before allocating image tensors;
- image tokens and text tokens share one context-budget calculation;
- projector/context allocations stay within the GGUF backend actor and unload with it; and
- vision routes advertise capability only after a real image fixture succeeds on that installation.

The initial consumer is an explicit photo question. Continuous scene narration remains gated until
its latency, thermal duty cycle, and Metal contention with local TTS are measured. No camera-frame
retention is added.

PR8 exit criteria:

- a curated model answers a fixed image fixture on supported physical devices;
- incompatible or missing projector files fail before generation;
- the measured low-headroom scenario returns an error rather than process termination;
- repeated image turns have bounded footprint growth; and
- text-only models never appear vision-capable.

### P4 / PR9 — Optional skill-pack storage binding

This phase is independent and must not delay the inference, scheduler, or memory tracks. Implement it
only when a real data-only pack needs durable structured state.

Extend `SkillPackBinding` with a declarative storage operation:

```swift
case storage(StorageBinding)

struct StorageBinding: Codable, Equatable {
    let collection: String
    let operation: Operation       // append, set, update, delete, query
    let schema: Data               // bounded JSON Schema subset
    let argumentMap: [String: String]
    let query: StorageQuery?
}
```

Host requirements:

- one SQLite namespace per installed pack ID; pack IDs and collection names never become unchecked
  filesystem paths;
- JSON values only, validated against a bounded schema subset with maximum nesting, field count,
  string length, row count, query limit, and per-pack byte quota;
- no SQL, JavaScript, HTML, expressions, network calls, dynamic imports, or file access supplied by
  the pack;
- all actions flow through the same composed-tool authority and audit path as other bindings;
- delete and bulk update require the existing destructive-action confirmation policy;
- pack uninstall asks whether to retain or erase namespaced data and reports the exact choice; and
- schema upgrades are explicit versioned migrations that can be validated without executing pack
  code.

PR9 exit criteria:

- two packs cannot read or mutate each other's namespace;
- malformed schemas and quota overruns fail without partial writes;
- CRUD and bounded query behavior are deterministic and headless-testable;
- destructive confirmation cannot be bypassed through a composed action; and
- unknown storage operations are surfaced in the existing lossy-decode report.

## Expected file changes

New runtime/model files:

```text
OpenGlasses/Sources/Services/LocalInference/
├── LocalInferenceBackend.swift
├── LocalInferenceCoordinator.swift
├── LocalInferenceTypes.swift
├── LocalModelCatalog.swift
├── LocalModelRepository.swift
├── LocalModelDownloadManager.swift
├── LocalModelDownloadPlan.swift
├── MLXLocalInferenceBackend.swift
└── LlamaCpp/
    ├── LlamaCppLocalInferenceBackend.swift
    ├── LlamaCppChatTemplate.swift
    ├── LlamaCppTokenDecoder.swift
    └── GGUFMetadataValidator.swift
Vendor/LlamaCpp/**
Scripts/build-llamacpp-framework.sh
Scripts/fetch-llamacpp-framework.sh
OpenGlasses/Sources/Resources/LocalModelCatalog.json
```

New durability files:

```text
OpenGlasses/Sources/Services/Scheduling/
├── AgentScheduleStore.swift
├── SchedulePolicy.swift
└── ScheduledTaskRunState.swift
OpenGlasses/Sources/Services/Memory/Curation/
├── MemoryCurationStore.swift
├── MemoryCurationPlanner.swift
├── MemoryCurationCommitter.swift
├── MemoryCurationBudget.swift
└── MemoryDocumentSnapshotStore.swift
OpenGlasses/Sources/Services/SkillPacks/
└── SkillPackStorage.swift                     # optional P4 only
```

Existing files expected to change:

- `OpenGlasses/Sources/Services/LocalLLMService.swift` — compatibility façade and state projection.
- `OpenGlasses/Sources/Services/LLMService.swift` — backend-neutral local routing only; tool loop stays.
- `OpenGlasses/Sources/Services/LocalModelBudget.swift` and `MemoryHeadroom.swift` — backend-aware
  admission and metrics inputs.
- `OpenGlasses/Sources/App/Views/LocalModelManagerView.swift` — unified manager and import sheet.
- `OpenGlasses/Sources/App/Views/ModelFormView.swift` and configuration migration — stable model IDs.
- `OpenGlasses/Sources/Services/AgentScheduler.swift` and
  `OpenGlasses/Sources/App/Views/ScheduledTasksView.swift` — typed outcomes/store/status.
- `OpenGlasses/Sources/Services/Memory/MemoryLoopService.swift` — deduplication handoff and trigger.
- `OpenGlasses/Sources/Services/AgentDocumentStore.swift` — snapshot-safe atomic memory replacement.
- `OpenGlasses/Sources/Models/SkillPackManifest.swift` and binding executor — optional storage case.
- `project.base.yml`, root `Package.swift`, post-clone CI, privacy metadata, and localized strings.

File placement may be adjusted to match the codebase at implementation time, but ownership boundaries
and actor isolation should remain as specified.

## Test plan

### Pure unit tests

- legacy model-ID migration defaults to MLX and is idempotent;
- descriptor/revision/file validation and stable-ID encoding;
- repository URL parser and host/scheme rejection;
- relative-path normalization rejects absolute paths, `..`, encoded traversal, and symlink escape;
- GGUF filename/quantization display parsing without capability inference;
- model fit verdicts across runtime, context, footprint, headroom, and thermal inputs;
- context/output-reserve calculation and over-context refusal;
- prompt partitioning produces only batches `<= nBatch`;
- full-history rendering plus KV reset on every generation using a fake backend;
- split UTF-8 token pieces produce the intended string exactly once;
- stop-sequence matching across token-piece boundaries;
- download-plan transitions, relaunch restoration, cancellation, digest mismatch, size mismatch,
  redirect rejection, atomic install, and power-loss recovery;
- schedule due calculation, daily windows, single catch-up, retry ladder, warning suppression, recovery,
  and deterministic jitter;
- every scheduler error classification leaves `lastSuccessAt` unchanged;
- curation cursor persistence, validation, idempotency, partial-commit retry, conflict handling, size
  budget, snapshot pruning, and restore;
- curation mutation validator refuses authority/safety/personality targets;
- privacy policy refuses cloud analysis when prohibited; and
- optional skill storage schema, namespace isolation, quota, CRUD, bounded query, confirmation, and
  lossy-decode reporting.

### Integration tests with fakes

- coordinator load/cancel/unload ordering across MLX and GGUF fake backends;
- only one resident backend lease at a time;
- `LLMService` receives equivalent streamed text from both local runtimes and keeps tool execution in
  the existing authority path;
- task execution persists an attempt before dispatch and a status after completion;
- queued notifications survive reconnection without duplicating a successful run;
- curation termination after each mutation boundary resumes exactly once; and
- snapshot write failure prevents destructive document replacement.

### Physical-device evidence

For each supported phone tier, record Debug and Release separately:

- cold load duration and peak footprint;
- first-token latency and decode tokens/second for short and long prompts;
- 20-turn conversation correctness and footprint trend;
- prompt larger than one batch;
- cancellation during prompt decode and during token generation;
- GGUF ↔ MLX switching and post-unload memory recovery;
- 15-minute generation session thermal state and battery delta;
- background/foreground transition during download;
- low-storage download refusal and relaunch recovery;
- scheduler activation with loaded local, unloaded local, and permitted cloud models; and
- multimodal long-edge tiers, headroom refusal, repeated photo turns, and local-TTS contention when P3
  begins.

Record device model, OS build, app build, runtime/framework revision, model revision/quantization,
context size, and whether increased-memory entitlement is active. Never record prompts or responses.

## Rollout and rollback

1. Land P0 with all flags off and exercise MLX through internal tests only.
2. Enable GGUF framework/runtime for developer builds, then an internal cohort with one curated small
   text model.
3. Enable public-repository import only after the curated path survives relaunch and corruption tests.
4. Enable durable scheduler state independently. Keep the legacy task blob for one release and offer
   a one-way repair command that can rebuild state from task definitions without inventing success.
   Before cutover the flag selects the legacy implementation; after the migrated scheduler ships,
   turning its kill switch off pauses scheduling and must never reactivate the legacy executor.
5. Enable memory curation for internal users, local-analyzer-only, with snapshot UI visible before any
   document compaction. Expand analyzer policy only after privacy review.
6. Add multimodal capability per exact model/device tier, never globally by runtime.
7. Keep skill storage off until a signed pack and product flow justify it.

Rollback behavior:

- disabling GGUF prevents load/import but leaves validated installations for re-enable or explicit
  removal; MLX remains available;
- a native-runtime crash kill switch refuses new GGUF loads without touching model files;
- disabling durable scheduler state pauses scheduler execution rather than falling back to the old
  success-on-error path;
- disabling curation stops new batches and retains snapshots/pending work for review; and
- disabling skill storage makes those actions unavailable without deleting pack data.

## Risk register and mitigations

| Risk | Required mitigation |
|---|---|
| Native ABI or build drift | Exact revision, reproducible script, checksums, compile matrix, narrow wrapper |
| Jetsam while switching models | Single coordinator lease, awaited unload/sync, live headroom gate, device matrix |
| Incorrect multi-turn answers | Clear KV per call, full-history template fixture, 20-turn device test |
| Oversized prompt crashes decode | Preflight context budget and `nBatch` partitioning |
| Invalid UTF-8 streaming | Byte accumulator with boundary tests |
| Malicious or corrupt model path | HTTPS allowlist, exact revision, size/digest validation, containment checks, atomic install |
| Background task claims exceed iOS behavior | Opportunistic semantics, typed deferral, no local auto-load, visible last-success state |
| Retry or catch-up notification storm | One task per cycle, bounded backoff, one catch-up, episode warning suppression |
| Memory corruption or silent loss | Immutable batch, snapshot-before-rewrite, idempotent commits, cursor-last transaction |
| Curation changes assistant authority | App-owned mutation enum, denylist by construction, skill proposal review only |
| Diagnostics leak private content | Typed metadata fields, no free-form prompt/response/path logging |
| Skill pack becomes executable app platform | Declarative JSON-only operations, host schema/quota/authority enforcement |

## Exit criteria

The core plan is complete when P0–P2 and PR6–PR7 satisfy all of the following:

- existing MLX models and configurations work without migration loss or redownload;
- at least one curated text GGUF can be installed, loaded, used across 20 turns, cancelled, unloaded,
  and switched with MLX on every supported device tier that advertises it;
- install state is revision-pinned, resumable, integrity-checked, and crash-consistent;
- custom public imports cannot bypass host, path, size, digest, template, or architecture validation;
- local tool-capable output enters the existing tool authority path and cannot execute directly;
- scheduled failures are never recorded as successes, retry state survives relaunch, and missed work
  cannot create a catch-up storm;
- curation retries cannot duplicate memories or advance past a failed write;
- users can see curation status and restore every document rewrite from a verified snapshot;
- privacy modes prevent prohibited cloud analysis and diagnostics contain no user content; and
- feature flags can independently disable GGUF, scheduler execution, curation, and optional pack
  storage without deleting user data or breaking MLX.

Multimodal GGUF and skill-pack storage have their own PR exit criteria and do not block declaring the
core text/runtime/durability plan shipped.

## Explicit non-goals

- Replacing MLX, Apple Intelligence, or cloud providers.
- Running local Metal inference as a reliable background service.
- Shipping arbitrary binaries, scripts, JavaScript, HTML/WebView agents, or repository-provided code.
- Letting a native runtime own conversation history, tool execution, memory policy, or UI.
- Guessing chat templates, architecture, capability, context, or projector compatibility from names.
- Automatically downloading a large model during onboarding, launch, or a scheduled task.
- Supporting gated/private repositories in the first importer.
- Remotely mutating the bundled catalog without signed, rollback-safe metadata.
- Autonomously editing `SOUL`, activating learned skills, changing safety policy, or granting tools.
- Replacing authoritative memory stores with a copied universal memory database.
- Promising exact-time scheduling or replaying every interval missed while iOS suspended the app.
- Enabling continuous GGUF vision before explicit photo turns pass memory, thermal, and contention
  evidence on physical devices.
