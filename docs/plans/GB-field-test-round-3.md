# Plan GB — Field Test Round 3: Job Record Fidelity, Manual Pages, Reasoning and Cost

**Status:** 📋 Planned 2026-09-30. Nothing implemented. Root causes verified against code on
`main` @ `641bb8ca`; the five decisions below were confirmed by the owner on 2026-09-30.
**Trigger:** The field tester ran build 2026.9 (421) with the Lennox SLP99 vault on two test jobs,
1010 and 1011, using OpenAI models over the OpenAI API (job 1010's record names `gpt-5.6-sol`, job
1011's names `gpt-5.5`). He sent both jobs' JSON and PDF, a diagnostics export covering both, 14
screenshots and an API bill. His summary: *the core diagnostic interaction is usable, but equipment
identity, pending verification, photo selection, and corrected results need to carry reliably into
the saved job and report.* He also asked us to confirm that the next build applies the correct
reasoning-effort setting for the selected model and API, including when function calling is used,
and where he can see or change the effective setting. He wants reasoning set **per model**, saved
and reused across jobs, not per job. On cost his priorities are usage tracking, spending caps and
reliable answers. His bill for about 2 h 20 min: **121 requests, $13.38 (about $5.73/h), 97% of it
input, about 30.7k input tokens per request, 33% cached.**

Paths are under `OpenGlasses/Sources/` unless noted. Line numbers are `main` @ `641bb8ca`.

## Outcome

A technician who works a job with two furnaces, corrects a model number and a reading, opens two
manual pages on purpose, excludes a blurry photo and closes the job by voice gets a saved record
and a report that say what happened:

- both units, under the model numbers he said (with the vault section each matched, if any);
- the corrected reading, shown as a correction, not as two finished tasks;
- only the pages he opened, marked verified only when he confirmed them;
- only the photos he kept;
- a fault that needs a heat-cycle retest left open as "Verify: …", not reported as resolved;
- the full conversation, both sides, without the app's own kickoff instruction;
- the time he actually worked, even when the app died mid-job;
- what the job cost in model usage.

The model editor shows the reasoning setting each saved model will actually use, with and without
tools, and why. Spend caps warn before a budget runs out and ask before going over it.

## Evidence (what the saved records show)

| Defect | Where it shows |
|---|---|
| Pages recorded as verified that nobody opened | Job 1011 `job_evidence.citationsOpened: []` (0 opened) while the report lists 6 pages as verified. Every one was logged by the sheet opening itself. |
| Count and list disagree | Job 1011 PDF: "Against the job itself: 1 photo, **5** pages verified", then a list of **6** pages (task-level page 30 is counted in the list but not the number). |
| Wrong pages popped up | Screenshots `01_1010_Wrong_Page_*`, `01_1011_Wrong_Page_*`: venting and CO₂ tables opened after spoken readings such as "0.28" and "135 not 140". |
| First furnace never recorded | Job 1011 transcript: the first unit (`SLP99UH070XB36B`, not in the vault) appears nowhere in `equipment`, `identity_fields: []`. |
| Stated model replaced by the vault's spelling | Job 1011 `equipment.model = SLP99UH090XV48CK`, `source: "spoken"`, though the technician said `…48C`. `recognised_at 22:42:28Z` is the time of the correction, not of first identification. |
| Two units, one scope | Job 1011: all five tasks under one equipment; no unit grouping in JSON or PDF, although the Job tab says work is kept apart per machine. |
| Readings not recorded | `job_evidence.readings: []` in **both** jobs. The 140 °F reading and its correction to 135 °F were saved as two `done` tasks. |
| "Resolved" before the retest | Job 1011 `outcome: resolved`, `procedures_run[0].outcome: resolved` after 4 steps; the vault's terminal step says to run a full heat cycle only after the retest passes. The tester's screenshot `07_1011_Verification_Not_Tracked`. |
| Photo excluded, still sent | Screenshot `05_1011_Photo_Still_Selected`; job 1011 `media` still carries the photo. |
| Transcript one-sided, kickoff as technician | Job 1011 `transcript[0]` is the app's own prompt ("A Field Assist session has just been started… do not call field_session start…") attributed to the technician; no assistant lines; `citations: []`. |
| Time lost after the app died | Screenshots `04_1011_Timer_Before/After`: about 20 minutes dropped on relaunch; final `billable_seconds 4157.95`. |
| Report could not be sent after close | Diagnostics 18:21:02 `field_session end`, 18:21:04 `deliver_report`, 18:21:10 "No active Field Assist session…". |
| Double full stops | Job 1011 PDF: "airflow.. Note:", "range.. Cited". |
| Assistant went silent | Diagnostics, earlier run: 5 `tts speaking engine=system`, 0 finished or cancelled; a held utterance stale-dropped 17:11:16 → 17:12:12. After relaunch 9 of 9 finished. |
| Clip refused, video not saved | Screenshots `06_1011_Camera_Stream_Error`, `06_1011_Video_Save_Error`; no `frameReceived` after the relaunch. |
| HTTP 400 on a reasoning model | Screenshot `API_GPT6_HTTP400`: "Function tools with reasoning_effort are not supported for gpt-6-sol in /v1/chat/completions… use /v1/responses or set reasoning_effort to 'none'", shown under an **AI-generated** badge. |
| Cost | Diagnostics: every request `detail=withImage`, bodies of about 1 MB, message count growing 39 → 159 across both jobs. |

## Verified starting point (main @ 641bb8ca)

### Manual pages
- **Auto-open is not a model decision.** Every utterance runs retrieval (`Services/LLMService.swift:596`
  → `FieldSessionService.promptContext(turn:)`). `FieldSessionService.bestFigure` (`FieldSessionService.swift:1162-1165`)
  picks the first diagram, **or any captioned passage** ("Table 35"), and `stageFigure` (`:1169`) stages
  it. `App/OpenGlassesApp.swift:2620-2624` subscribes to `$stagedFigure` and presents it on the phone.
  `LLMService.swift:815-827` also sends that page as the turn's image when there is no camera frame.
- **Numbers become page matches.** `CodeTokenizer.candidateTokens` (`Services/Vault/CodeTokenizer.swift:10-23`)
  splits on every non-alphanumeric, so "0.28" becomes "28"; `isCodeLike` (`:27-29`) treats any 2+
  character token with a digit as a code. An exact token hit ranks first (`VaultRetriever.swift:214-216`)
  and always counts as evidence (`:412`). Checked against the manuals: "135 not 140" matched Install
  p64 (CO₂ table, input size 135); "0.28" matched Install p17 Table 8; "0.35" matched the "TABLE 35"
  caption on p64. On device (`nl-sentence.en`) `RetrievalEvidencePolicy.default` (`VaultRetriever.swift:399`)
  applies its lexical check only for `nl-word`, so only the 0.30 floor applies. Simulators run
  `nl-word`, which is why tests miss this.
- **"Correct the job number to 1011" is not recognised as job bookkeeping.** `ManualTurnScope.isJobManagement`
  has no "correct" verb and no "to" qualifier, so the turn retrieves pages.
- **Opening a page is logged as verifying it.** `ManualFigureSheet.swift:43` runs `.task { await controller.open() }`;
  `ManualPageSheet` `open()` (`:268-274`) and `openOriginal()` (`:283-289`) call `recordVerification()`
  (`:310-314`) → `logPageVerified`. Only chip taps (`OpenGlassesApp.swift:3856`) and `manual_figure`
  (`ManualFigureTool.swift:123`) log `citationOpened`. Labels differ ("page 65, Figure 65" vs "page 65",
  `FieldSessionService.swift:1362`). This contradicts EK §5, whose verification is the technician's
  check, not the sheet's appearance.
- **Count vs list.** `WorkRecord.swift:270-271` counts job-level evidence only; `:277-280` lists the
  deduplicated union of job and task evidence (`:220`).
- **Per-task evidence is empty in practice.** `attachEvidence` (`FieldSessionService.swift:692`) attaches
  to the in-progress task, else the job (EM §2). Procedures started by `procedure_runner` create no
  task, technician tasks lived 3–5 s, and retrieval runs before the task tool call.

### Equipment identity
- Only `equipment_lookup` records equipment (`EquipmentLookupTool.swift:147`). Zero vault matches
  return `(nil, nil)` and record nothing (`:128-131`). `EquipmentScopeCheck` (`EquipmentIdentity.swift:125-129`,
  via `FieldSessionService.swift:991-995`) then injects "not one of them", and `set_equipment` refuses
  too (`:169-171`). `recordIdentityField` (`FieldSessionService.swift:471`) still has no production
  caller (EM's 2026-09-25 finding), so `identity_fields` is always empty.
- The identity token is the **vault heading's** name, not what was said (`EquipmentLookupTool.swift:138,175`,
  `JobChangeDetector.swift:61`, `FieldSessionService.swift:138`). That contradicts EL §2 ("modelToken,
  as matched"). A correction through `set_equipment` substring-matches back to the same heading
  (`VaultModelIndex.swift:172-178`) and rewrites it with a fresh timestamp (`FieldSessionService.swift:243-262`).
- `visitedUnits` (`FieldSession.swift:46`) and `taskEquipmentScopes` (`:83`) exist, but `setEquipment`
  re-scopes only when a previous identity exists (`FieldSessionService.swift:245`), so every job-1011
  task landed in the "initial" scope. `WorkRecord` has no units (`WorkRecord.swift:34,109-112,256-261,310-320`);
  neither does the exporter (`SessionExporter.swift:619`, PDF `:333-339`). `App/Views/Job/ActiveJobView.swift:230`
  states "Work is kept apart per machine in the record", which the export does not do.

### Job record
- **Timer.** `lastResumeAt` is in memory only (`FieldSessionService.swift:30`); billable seconds are
  written only on pause or end (`:150`, `:185`, `accumulateBillableTime` `:2027-2032`). On relaunch
  `restoreInProgressSessionIfAny` (`:1974-1995`) calls `pauseSession()` (`:1991`) with `lastResumeAt`
  nil, so it adds nothing and sets `pausedAt = now`. `field_session status` reports wall-clock time,
  not billable time (`FieldSessionTool.swift:335`).
- **Photo exclusion.** The thumbnail is display-only (`JobEvidenceViews.swift:307-333`) and
  `JobPhotosSection.selection` is a `let` (`:204`). The setter `liveSelection` → `applyEvidenceSelection`
  (`JobTab.swift:256-259`, `JobTabModel.swift:521-524`) exists but is never wired, because
  `ActiveJobView.swift:58` passes the wrapped value. The exporter honours a selection only once it is
  reviewed (`SessionExporter.swift:206,375-397`; `WorkRecord.swift:182`), and voice close skips review.
- **Premature "resolved".** `ProcedureRunner.advance` completes on *entering* a terminal step
  (`ProcedureRunner.swift:95`); `ProcedureRunnerTool.swift:93-94` returns "Procedure complete. Outcome:
  resolved." The terminal step's instruction is never shown. `WorkTask` has no verification concept
  and `closeTask` (`FieldSessionService.swift:651-676`) is unconditional.
- **Transcript.** `logAssistantMessage` (`FieldSessionService.swift:1425`) is called only by the
  health-safety advisor, so the transcript is technician-only and `citations` (derived from assistant
  turns, `SessionExporter.swift:145-150`) is empty. The Field Assist quick action's prompt
  (`QuickAction.swift:90`) goes through `llmService.sendMessage` (`OpenGlassesApp.swift:4159-4163`),
  is logged as a user message and exported as the technician's line (`SessionExporter.swift:135-137`).
- **Readings.** The only writer is `logCaptureRecord` (`FieldSessionService.swift:1431-1441`); there
  is no spoken-reading path.
- **Double full stops.** `WorkRecord.line` joins with `". "` (`WorkRecord.swift:378`); `terminated`
  guards only the last piece, so a punctuated inner piece prints "..".
- **Close then send.** `deliver_report` needs an active session (`DeliverReportTool.swift:74-75`,
  `workRecord()` `FieldSessionService.swift:765`), although `reportDelivery(for:canSendAttachments:sessionId:)`
  (`:816-827`) already renders an ended one. Voice close (`FieldSessionTool.swift:320`) calls
  `GuidedJobFlow.closeJob` directly, bypassing `JobTabModel.closeJob` (`JobTabModel.swift:492-506`),
  whose comment says every close route comes through it: sign-off policy, evidence selection and the
  record snapshot are skipped.

### Voice and video
- **Silent assistant.** One `AVSpeechSynthesizer` (`TextToSpeechService.swift:17`, a `let`, never
  rebuilt). `speakWithiOS` awaits a continuation (`:915`) that only `didFinish`/`didCancel` resume
  (`:996`, `:1010`); there is no watchdog and nothing handles `mediaServicesWereResetNotification`.
  The turn runner awaits speech before finishing (`OpenGlassesApp.swift:5702`), so the next utterance
  is held (`:3008`) and later stale-dropped (`:1351-1354`). The FE P4 `SpeechDeliveryLedger` has no
  "never started" outcome.
- **Clip refusal.** `record_clip` gates on `readinessNow.hasFreshVisualEvidence`
  (`JobClipRecorder.swift:192-200`, `OpenGlassesApp.swift:1064-1066`) and refuses; the preview,
  `video_recording` and `toggleRecording` (`OpenGlassesApp.swift:4410`) all start the stream on demand.
  After the relaunch the glasses stream was never resumed.
- **Recording save.** The writer's `startWriting()` result is ignored (`VideoRecordingService.swift:274`)
  and frames are appended from `.receive(on: DispatchQueue.global(qos: .userInitiated))` (`:306`),
  which is concurrent. The failure path (`:412`, likely `AVError` −11800) still has `RecordingFiler`
  move the broken file (`RecordingFiler.swift:106,:434`) and offer it to Photos (`:554`), with copy
  that says nothing was lost. Recordings live in `Documents/Recordings`, which the Files app cannot
  see (`RecordingFiler.swift:142-144`); `RecordingsView` lists audio only. `pendingShareItem`
  (`OpenGlassesApp.swift:4402`) presents on `VoiceTab` (`VoiceTab.swift:132`) while the record button
  is inside `LivePreviewView`'s full-screen cover (`:121`). The error is shown under an
  "AI-generated" badge (`TranscriptOverlay.swift:306`). `WebRTCStreamingService.swift:81` has the same
  concurrent-append pattern.
- The diagnostics buffer spent 222 of 500 slots on `frameReceived`.

### Reasoning and cost
- **Reasoning is never sent to OpenAI.** Chat Completions (`LLMService.swift:77`, body `:2067-2104`)
  sends nothing except `applyQwenReasoning` (`:3798-3804`) for Groq/Qwen. Tools are always attached
  (`:2081-2089`), so the model's server default applies, and on `gpt-6-sol` that default is rejected
  with tools (the 400). A 400 is terminal in the fallback cascade (`ModelFallbackChain.swift:111`).
  The ChatGPT subscription path (`LLM/ResponsesTranslator.swift`) sends none either; Anthropic
  (`:1791-1814`) sends no thinking; Gemini REST uses 512 on tool turns (`GeminiBudgetPolicy.swift:52-70`,
  CO Item 2); Gemini Live uses 0; side calls (`:1255-1610`) send nothing. Tool turns cap output at
  1024 via `max_completion_tokens` (`:2069`, `:3811-3814`); reasoning tokens count against it.
  `ModelConfig` (`Models/ModelConfig.swift:4-18`) has no reasoning field.
- **Cost drivers.** About 10k tokens of tool schemas per request, every tool sent
  (`Models/ToolCallModels.swift:140-149,198`), and the same descriptions again in the system prompt
  (`SystemPromptBuilder.toolLines`, `LLMService.swift:473`, about 8k at `:754`). The vault core is
  bounded (24k bytes) only for ChatGPT (`FieldSessionService.swift:958`, `VaultPromptBuilder.swift:51`).
  API history is never budgeted: FM's `RequestContextBudget` applies to ChatGPT only (`:735`, `:2321`),
  legacy compaction starts at an 80k estimate (`:302`, `:1102`), and `HistoryHygiene.estimatedTokens`
  (`LLM/HistoryHygiene.swift:131-150`) counts an OpenAI `image_url` block at the default of 1 token.
  One old image (about 880 KB base64 at the 2576 px `.full` size, `Config.swift:2864`) is resent on
  every request and every tool round-trip (`pruneImages(keepLast: 1)`, `LLMService.swift:862`, `:2064`).
- **Cache hit rate 33%.** Volatile content sits in the middle of the system prompt (image block `:544`,
  memory, date and time to the minute `:565`/`:3096`, location, voice skills, manual passages); tool
  order follows dictionary iteration; `JSONSerialization` runs without `.sortedKeys`; no
  `prompt_cache_key`. Anthropic's breakpoint covers a timestamped system block (`:1794-1798`).
- **Usage tracking (AU).** No gpt-5.x or gpt-6 rows in `Services/Usage/ModelPricing.swift:28-61`.
  OpenAI's `prompt_tokens` already includes cached tokens, but `UsageTracker.swift:91-99` records the
  cached count separately and `ModelPricing.cost` (`:104-111`) prices it again, so cost is overstated
  by 10% of cached tokens (Gemini too). The ChatGPT path ignores `cached_tokens`. `UsageRecord.sessionId`
  is the tracker's own app-session id (`UsageTracker.swift:18,30`), not the field session, so no cost
  can be attributed to a job. There is no spend cap anywhere.
- **HIPAA.** `nativeToolDeclarations` (`ToolCallModels.swift:140-149`) filters only `Config.isToolEnabled`;
  the HIPAA filter lives in the registry (`NativeToolRegistry.swift:330-331,341-345`), so HIPAA-disabled
  tools are *declared* to the model although `tool(named:)` still refuses to execute them.

## Decisions (decided 2026-09-30)

1. **Evidence attribution: a procedure opens its task (option a).** Starting a procedure opens, or
   attaches to, a task scoped to the current unit, so evidence has a home when it is gathered.
   Retroactive inheritance (option b: a task added and closed in the same turn inherits job-level
   evidence since the previous task ended) is rejected: it guesses, and it could attach exactly the
   unrelated auto-shown pages the tester complained about. Evidence gathered outside any task stays
   job-level. This supersedes EM §2's "in-progress task, else job" only in that procedures now
   create the task.
2. **"Verified" requires an explicit technician confirmation** on a page the technician opened: a
   tap on **Checked against manual**, or a spoken confirmation classified deterministically. No
   dwell-time inference. Three recorded states: **shown** (automatic; never in the verified list, and
   listed separately as "shown automatically" or omitted), **opened** (the technician asked), and
   **verified** (confirmed). Readings and tasks cite verified pages only.
3. **Reasoning is set per saved model.** The default is Automatic, which on Chat Completions with
   tools resolves to `none`. The effective value and its reason are always visible.
4. **Recordings are reachable in the app** (a video list in Recordings), not by exposing Documents to
   the Files app, which would also expose transcripts.
5. **At 100% of a spend cap the app warns and asks** for a spoken or tapped confirmation to continue.
   It does not silently drop to a cheaper model, because an unannounced model change undermines
   "reliable answers". Falling back to a cheaper tier is an opt-in setting.

## Scope and invariants

- **Deterministic, headless-testable core first.** Every rule below is a pure type with table tests;
  views, services and tools call it. The live, device and provider edges are named per phase and
  deferred to the device pass.
- **Codable back-compat.** Every persisted-type change is optional and decoded with
  `decodeIfPresent`. A legacy session, work record, model config or usage row decodes unchanged, and
  a legacy record renders byte-identically wherever an earlier plan requires it: FO's single-unit
  report (a job with at most one unit prints exactly as today), and the customer sign-off digest
  (`CustomerSummary.lines`, `CustomerSignOff.swift:159-200`, is an allow-list of done-task titles,
  parts and time; a signed record keeps its frozen `summaryLines`, and nothing in this plan adds to
  that allow-list).
- **Speech stays the technician's report (FM).** A spoken reading or correction is recorded as
  reported, never as observed or verified.
- **Nothing here puts cost, reasoning or internal evidence on the customer's page.** The per-job cost
  appears on the Job tab and in the internal JSON only.

Prior-plan invariants each phase must respect:

| Plan | Invariant | Phases |
|---|---|---|
| EJ / FQ | Retrieval ranking, query variants and the passage budget are unchanged. GB decides what is *presented* and *recorded*, not what ranks. `ManualTurnScope` keeps bare numbers in retrieval. | P1 |
| EK | Diagrams still reach the model as pictures (§4); a turn with nothing staged clears the previous figure (P2); every citation stays a door to its page (§5). | P1 |
| EL | Equipment identity stays session-scoped; the vault match is evidence about the stated model, not a replacement for it. | P2 |
| EM | Declines and deferrals are kept; parts keep their verified flag and page. §2's attachment rule changes only as Decision 1 says. | P1, P3 |
| FO | A paused job is still the job; the job clock keeps minute grain; close, check and send are one movement; the single-unit report is byte-identical; the sign-off digest is untouched. | P0, P2, P3 |
| FM | Corrections reach durable state; compaction never removes saved messages or ends a job; the ChatGPT budget stays as shipped. | P0, P3, P5 |
| FW | Live modes (Gemini Live, OpenAI Realtime) keep nothing unless FW's setting says so; P0's assistant-line logging is Direct mode only. | P0 |
| FD | Camera gates read `readinessNow`; the cold-start window is FD's; the stream intent is deliberately not persisted across launches (FD, CV). | P4 |
| FE P4 | The speech ledger's first terminal outcome wins; a rebuilt synthesizer cannot record a second outcome for the same utterance. | P4 |
| AS (audio-session lease) | Rebuilding the synthesizer does not acquire or hold the lease. | P4 |
| AU | Usage stays local-only; an unpriced model records tokens with `costUSD == nil`. | P0, P5 |
| CO Item 2 | A thinking or reasoning budget always comes with an output cap that leaves room for the answer. Gemini REST tool turns keep a bounded budget; Gemini Live stays at 0. | P0 |
| CO / CP | Every camera still, clip and frame that leaves the device passes the privacy chokepoint; `record_clip` claiming the stream keeps it a rostered `OutboundFrameConsumer` on the relay. | P4, P5 |
| FV | Turn traces stay content-free; the effective reasoning setting is a token, not text. | P0 |

## Phases (one PR each; P0 is the next build)

### P0 — Next-build quick fixes (small, low risk)

**Reasoning effort, per model.**
- `ModelConfig.reasoningEffort: String?` (optional, so older configs decode as nil = **Automatic**).
- Pure `ReasoningPolicy.resolve(provider:model:route:toolsAttached:requested:) -> Resolution`, where
  `Resolution` is `{ wireFragment, effective, reason }`:
  - **OpenAI Chat Completions, reasoning family, tools attached** → clamp to `none`, reason "Chat
    Completions does not accept function tools with reasoning for this model". This fixes the
    `gpt-6-sol` 400. Automatic resolves here to `none` too.
  - Chat Completions, no tools → the requested value; Automatic sends nothing (provider default).
  - Responses routes (the ChatGPT subscription path) → `reasoning.effort`.
  - Gemini REST → `thinkingBudget` mapped from the effort, never unbounded (CO Item 2); Gemini Live
    stays 0.
  - Anthropic → "not supported yet", nothing sent.
  - Custom, OpenRouter, Mistral, xAI → only an explicit value is sent; Automatic sends nothing.
  - A 400 in the known shape (function tools with reasoning) is classified by a pure
    `ReasoningRejectionClassifier`, and the turn retries **once** with `none`, logged, so a model
    missing from the policy table does not dead-end in the terminal cascade
    (`ModelFallbackChain.swift:111`).
- When `effective > none`, raise the tool-turn output cap (`max_completion_tokens`, `LLMService.swift:2069`,
  `:3811`) to at least 4096. Otherwise reasoning consumes the 1024 and the completion is empty.
- **Where to see and change it:** Settings → Models → edit a model → **Reasoning** (a picker in
  `ModelEditorView`/`ModelFormView`), with two read-only lines under it: "Effective with tools: none
  — Chat Completions doesn't allow reasoning with tools for this model" and "Effective without
  tools: medium". The editor notes that reasoning tokens are billed as output. Each turn notes its
  effective value in `TurnRecorder` (visible in Turn details), in the FV trace, and as a `PrivacyLog`
  token.

**Record and report.**
- `deliver_report` after close: pure `ReportTargetResolver.resolve(active:recentEnded:threadId:now:)`
  returns `.active`, `.ended(sessionId)` (the job ended in this thread within N minutes and has not
  been sent), or `.refuse(reason)`. `DeliverReportTool` hands the ended session to the existing
  `reportDelivery(for:canSendAttachments:sessionId:)`. It never reopens a job.
- The app's kickoff prompt is sent as `sendMessage(origin: .appInstruction)`, logged as an app event
  and kept out of the transcript. Pure `TranscriptOriginClassifier` exact-matches the known app
  prompts so already-saved records export without them. The sign-off digest is unaffected because
  the transcript is not in `CustomerSummary`.
- Assistant replies are logged to the field session at the Direct-mode turn sites
  (`LLMService.swift:731`, `:2316`), with `Source:` lines as citations, so the transcript has both
  sides and `citations` is populated. Live modes are FW's.
- Pure `EvidenceRollup`: one deduplicated set feeds both the count and the list (`WorkRecord.swift:270-280`).
  Test with job 1011's data (5 vs 6).
- `WorkRecord.line`: terminate each piece before joining (`:378`), so "airflow.. Note:" becomes
  "airflow. Note:".

**Usage and safety.**
- Price rows for the gpt-5.x and gpt-6 families in `ModelPricing.defaults`, verified against the
  provider's published prices at implementation time.
- Fix cached-token double counting: for OpenAI-shaped and Gemini usage, uncached input =
  `prompt_tokens − cached_tokens`; parse `cached_tokens` on the ChatGPT path as well.
- `nativeToolDeclarations` applies the registry's HIPAA filter, so a disabled tool is not declared.

Tests: the policy table for every provider and route, with and without tools, including the clamp,
Automatic and the output-cap rule; the 400 classifier plus the single retry; `ReportTargetResolver`
(active, ended recently in the same thread, ended long ago, already sent, other thread);
origin-tagged kickoff absent from a fresh and a legacy export; assistant lines present;
`EvidenceRollup` against 1011; the join; cost for a 1,000-token prompt with 400 cached equals
600 × rate + 400 × rate × 0.1; the HIPAA declaration list. Device edge: one tool turn per saved
OpenAI model on the API, confirming no 400 and a non-empty completion.

### P1 — Manual pages

- Pure `FigureAutoOpenPolicy.decide(turnKind:passageKind:tokenHits:) -> .present | .attachToModelOnly | .none`:
  - Only question and show-me turns present anything. Corrections, readings and job bookkeeping never do.
  - Diagrams may auto-present, as EK §4 intends. Tables are presented only when asked for.
  - A turn whose only hits are numbers or decimal fragments never auto-presents.
- `CodeTokenizer`: keep decimals whole ("0.28" stays "0.28" and never yields "28"), so a spoken
  reading cannot exact-match a table number or a caption. Model numbers longer than 14 characters
  are no longer dropped.
- `ManualTurnScope`: "correct", "change" and "set" join the job verbs, and "to <number>" joins the
  qualifiers, so "correct the job number to 1011" is bookkeeping. Bare numbers stay in retrieval.
- Pure `PageEvidencePolicy.classify(origin:confirmed:) -> .shown | .opened | .verified`, per
  Decision 2. The sheet's `open()` no longer logs verification. **Checked against manual** on the
  sheet, or a spoken confirmation ("checked", "that matches the manual") classified while that sheet
  is the one the technician opened, logs `pageVerified`. A voice-originated open cannot tell a
  technician's request from a model-initiated one, so it records `.opened` only when a
  technician-turn classifier says the turn asked for a page.
- `FieldSession.Evidence` gains `pagesShown` (decode-if-present). The report never lists shown pages
  as verified. It either omits them or prints them under "Shown automatically", as the owner prefers
  (default: omit from the PDF, keep them in the JSON). Labels are normalised to one form (title,
  page, optional figure).
- Log figure presentation (`figurePresented`, with the policy's reason), so the diagnostics can say
  which turn put which page on screen.
- Decision 1's rule lives here: `procedure_runner start` opens (or attaches to) a task scoped to the
  current unit.

Invariants: EJ/FQ ranking unchanged (the calibration harness must report identical `recall@4`, MRR
and nDCG@4 before and after, except for the decimal-token change, whose effect is recorded); EK P2
clearing. Tests: the three screenshot cases ("0.28", "135 not 140", "0.35") present nothing and
record nothing; "show me the wiring diagram" presents; a table is presented only when asked; job
1011's six pages classify as shown, not verified; a confirmed page reaches a reading's citation. The
device edge (`nl-sentence` on device) is named in the device pass because simulators run `nl-word`.

### P2 — Equipment identity and several units on one job

- Pure `EquipmentRecognition.resolve(stated:index:) -> .exact | .alias | .near(candidate, distance ≤ 2) | .unmatched`.
- `EquipmentIdentity.statedModel` (what the technician said, always recorded) and `vaultMatch`
  (heading and kind of match), both decode-if-present. Legacy identities read `statedModel` from the
  current `model`. `unitKey` derives from `statedModel`.
- `.near` asks "did you mean SLP99UH090XV48CK?" and records the answer. `.unmatched` but asserted by
  the technician is a real unit and counts as in scope: `EquipmentScopeCheck` stops injecting "not
  one of them" for a unit the technician named. The manual answers carry the existing
  out-of-vault caveat.
- The correction path (`set_equipment` or "the model is …") replaces `statedModel`, keeps the original
  `recognisedAt`, and logs `equipmentCorrected` (from, to). The report prints
  "SLP99UH090XV48C (vault section SLP99UH090XV48CK)".
- Pure `UnitLedger` from `visitedUnits` and `taskEquipmentScopes`. The first identification after
  work already sits in "initial" opens a new scope and back-fills the unidentified unit. An explicit
  `field_session next_unit [label]` starts the next unit with or without a vault match.
- `WorkRecord.units` is encoded only when there are two or more units. With one unit or none, the JSON
  and `summaryLines` are byte-identical to today (FO) and the customer summary is unchanged. Report
  sections per unit appear only with two or more units; `SessionExporter` and the PDF follow the same
  rule. The Job tab (`ActiveJobView`, `JobTabModel`, `PastJobView`) reads the ledger.
- Until the ledger ships, the footer "Work is kept apart per machine in the record." is changed to a
  true sentence ("One job can cover several machines."), in P0 if P2 slips.
- Serial and nameplate fields reach `recordIdentityField` through the same tool action, closing EM's
  2026-09-25 unwired finding for spoken values.

Tests: job 1011's sequence (unmatched `…070XB36B`, then `…090XV48C` near `…48CK`, then the
correction) gives two units, the stated spellings, the vault section, and tasks grouped correctly; a
single-unit legacy record is byte-identical; a legacy identity decodes; the digest is unchanged.

### P3 — Job record fidelity

- **Timer.** Pure `BillableClock.recover(session:lastEvidenceOfLife:now:)`. The anchor is
  `resumedAt ?? startedAt` (both persisted, `FieldSessionService.swift:169,175`); the heartbeat is the
  last `log.jsonl` event's timestamp. It credits anchor → heartbeat, clamped when the heartbeat is
  before the anchor, and sets `pausedAt = heartbeat`. It is optionally backed by a decode-if-present
  `billableCheckpointAt` written on backgrounding. The Job tab says "Paused when the app closed at
  5:18 PM; 2 minutes not counted". `field_session status` reports billable time. Cases: never paused,
  paused before the app died, resumed then died, heartbeat before anchor, legacy session with no
  `resumedAt`.
- **Photo include/exclude.** `EvidenceSelection.Entry.decided` (decode-if-present) marks a
  technician's explicit choice. Pure `EvidenceSelectionPolicy.effective(selection:)` honours decided
  entries **without** requiring the close review. The thumbnail toggle is bound to the existing
  setter (`liveSelection` → `applyEvidenceSelection`), and a new `evidence` tool handles
  `exclude|include latest|<id>` by voice. The exporter and `evidencePlan` read the effective
  selection.
- **Verification.**
  - `Transition.arrivedAtTerminal(step)`, and `requires_confirmation` on terminal steps
    (decode-if-present in the procedure schema). The runner shows the terminal instruction and
    completes only on an explicit `complete` after the technician confirms.
  - `Task.verification: VerificationRequirement?` (decode-if-present).
  - Pure `TaskClosePolicy.decide -> .close | .closeSpawningVerification(title) | .refuse(reason)`.
    Closing a fix that needs a retest leaves an open "Verify: …" task.
  - Tool results say "Not yet verified. Do not say resolved."
  - The job's outcome cannot be `resolved` while a verification task is open.
- **Spoken readings.** Pure `SpokenReading { id, quantity, value, unit, unitScope, taskId, at, supersedes? }`
  with `record_reading` / `correct_reading` actions. Readings attach per Decision 1. A correction
  supersedes; it never adds a second finished task. The report prints "Supply air 140 °F (corrected
  to 135 °F at 5:28 PM)". Speech is recorded as the technician's report (FM), and a reading cites a
  page only when that page is verified (Decision 2).
- **One close.** Pure `JobCloseSequence`: open work and verifications → evidence decision →
  `SignOffPolicy` → record snapshot → end → stage delivery. It runs inside `GuidedJobFlow.closeJob` as
  the single chokepoint, so voice close (`FieldSessionTool.endSession`) and the Job tab take the same
  steps. By voice, open verifications and an undecided evidence selection become spoken questions,
  never silent skips.

Invariants: FO (paused job is still the job, minute grain, one close movement, sign-off digest), EM
(declines and deferrals kept), FM (corrections reach durable state). Tests: each `BillableClock`
case; job 1011's timeline credits the lost 20 minutes; a toggle-excluded photo is absent from the
PDF, the JSON and the share list without any review; `clear_and_retest` stops at its terminal
instruction; the 140 → 135 correction renders as one reading; voice close and tab close produce
identical records for identical sessions; a signed legacy record's digest still verifies.

### P4 — Voice and video reliability

- Pure `SynthesizerHealthPolicy.assess(speakAt:didStartAt:lastBoundaryAt:characters:rate:now:) -> .healthy | .neverStarted | .stalled`,
  where expected duration = characters ÷ rate + slack. On failure: rebuild the synthesizer (a `var`
  behind a factory seam), record `.failed("engine unresponsive")` in the ledger, resume the pending
  continuation, and retry the utterance once. Also rebuild on `mediaServicesWereResetNotification`,
  and log `tts started`. The ledger gains a never-started outcome. A held utterance is replayed after
  the failed turn completes, not stale-dropped. Test with a fake synthesizer that never calls back:
  the turn completes and the held utterance runs. FE P4 first-terminal-wins holds, and the rebuild
  never takes the audio-session lease (AS).
- `record_clip` claims the stream (`CameraService.claimStream(for: .jobClip)`, `CameraService.swift:428`)
  and waits for fresh visual evidence within FD's cold-start window (about 20 s), then releases on
  stop, cap or job close. An async `ensureStream` seam goes in `RecordClipTool.Seams` and
  `JobClipRecorder.Seams`. Tests: stopped → connecting → ready, timeout, claim failure. The clip stays
  a rostered consumer on the blurred relay (CO/CP).
- `VideoRecordingService`: a serial append queue, `startWriting()` checked, the writer's underlying
  error code logged. The same fix applies in `WebRTCStreamingService`, and a source-scrape guard
  test forbids `receive(on: DispatchQueue.global` in recorders.
- `RecordingFiler` honest outcomes: `Outcome.encodeFailed` with honest copy, and no offer to Photos
  when encoding failed. "Nothing was lost" is shown only when the file is playable (an `AVURLAsset`
  seam).
- Recordings reachable in the app (Decision 4): a video list in `RecordingsView`. The share sheet
  presents from `LivePreviewView` itself.
- System errors (HTTP failures, recorder errors) render without the "AI-generated" badge.
- The diagnostics buffer rate-limits `frameReceived` (or gives it its own budget) so capture noise
  cannot push out model and speech events.

Device edge: the synthesizer wedge's trigger and the −11800 root cause are confirmed on a device;
the headless tests prove recovery, not cause.

### P5 — Cost and caps

- **Stable, cacheable prefix.** The system prompt splits into a stable prefix (persona, rules, vault
  core, tool guidance) and a volatile tail (image block, memory, date and time, location, voice
  skills, manual passages) placed **after** history. Tools are sorted by name; request JSON uses
  `.sortedKeys`; `prompt_cache_key` is derived from the model and the stable-prefix digest. Anthropic's
  cache breakpoint moves to the untimestamped prefix. A pure `PromptPrefixDigest` test proves two
  consecutive turns share the prefix byte-for-byte.
- **Budgeted API history.** Reuse FM's `RequestContextBudget` for API providers with a cost allowance
  (12–16k history tokens, a setting). History starts fresh per job (verify what the job boundary does
  today, `GuidedJobFlow.swift:468,507`), and the `image_url` estimate is fixed in `HistoryHygiene`.
  FM's ChatGPT behaviour is unchanged.
- **Drop stale images.** An image rides only on the turn that asked about it (`keepLast: 0` after the
  turn), and it is not resent on tool round-trips.
- **Vault byte cap** of 24k on every provider, not just ChatGPT.
- **Dedupe tool guidance.** Tool descriptions appear once, in the schemas. A field-mode tool profile
  (`NativeToolRegistry.contextualToolNames`, which exists and is unused) sends the tools a job
  actually uses.
- Pure `SpendCapPolicy.decide(spentToday:spentMonth:caps:priced:) -> .ok | .warn(80%) | .confirmToContinue | .fallBackToTier(opt-in) | .notEnforceable`.
  Daily and monthly USD caps. Warn at 80%. At 100% the next turn asks for a spoken or tapped
  confirmation (Decision 5); falling back to a cheaper tier only when that setting is on. An unpriced
  model reports "cap not enforceable" rather than pretending to be under the cap. Depends on P0's
  price rows and the cached-token fix.
- **Per-job cost.** `UsageRecord` gains an optional field-session id (a nullable column), and the
  work record gains a decode-if-present usage summary (requests, input, cached, output, estimated
  USD, unpriced flag). It is shown on the Job tab and in the internal JSON, never in the customer
  summary. The tester's provider export cannot split cost by job; this can.

Ranked savings, estimated against the tester's bill ($13.38 for 121 requests; about 3.7M input
tokens, 1.23M of them cached; about $12.43 uncached input, $0.61 cached input, $0.34 output). Each
figure is independent. The savings overlap and do not add up.

| Rank | Change | Mechanism | Estimated saving on this bill |
|---|---|---|---|
| 1 | Stable prefix, volatile tail after history, sorted tools, `.sortedKeys`, `prompt_cache_key` | Cached share from 33% to about 75–85% | about $6–8 (45–60%) |
| 2 | Budgeted API history (FM budget, fresh per job, image estimate fixed) | History held to 12–16k instead of growing 39 → 159 messages across both jobs | about $2–4 (15–30%) |
| 3 | Drop stale images | About 1–1.5k image tokens and about 0.9 MB of upload per request | about $0.5–1 (4–8%); large latency gain |
| 4 | Dedupe tool guidance and a field-mode tool profile | About 8k duplicated tokens, plus unused schemas | about $1.5–3 (10–20%) |
| 5 | 24k vault cap on every provider | Bounds the vault core | depends on the vault; zero if already under 24k |

Enabling reasoning moves the other way: reasoning tokens bill as output ($30/M on this bill), which
is why the editor says so and why Automatic resolves to `none` with tools.

Tests: prefix stability across turns, tool order, sorted keys; the budget holds at 159 messages; no
image on a turn that did not ask; the declared tool list in field mode; each `SpendCapPolicy` state,
including unpriced; the per-job usage split across two jobs in one app session; a legacy work record
and usage row decode. Device edge: a real two-job run with the provider's reported cached tokens
compared with the tracker's figures.

## Deferred and follow-ups

- **OpenAI API via `/v1/responses`**, so reasoning can run *with* tools on the API. `ResponsesTranslator`
  is mostly provider-neutral. The subscription-specific parts need separating: auth, the
  `RequestContextBudget` host check (`LLM/RequestContextBudget.swift:36-49`, 32k fallback),
  `ChatGPTVisionGate`, `refreshedFieldInstructions`, `cached_tokens` parsing, and replaying
  reasoning items with `store: false`. Once it lands, `ReasoningPolicy` stops clamping for that route.
- **Per-job-type reasoning.** The tester declined it for now; per-model settings cover his need.
- **Resuming the glasses stream after a relaunch mid-job.** Stream intent is deliberately not
  persisted (FD, CV); P4 only makes `record_clip` claim the stream on demand. Open question below.
- **Live modes.** Assistant-line logging, reasoning and spend caps for Gemini Live and OpenAI
  Realtime follow FW.
- **Device pass (owed, one run by the field tester):** two units on one job with a correction; a
  spoken reading and its correction; one page opened and confirmed, one auto-shown; a photo excluded
  by tap; a retest left open; the app force-quit mid-job and relaunched; a clip after relaunch; a
  video saved and found in Recordings; voice close then "send the report"; a reasoning model on the
  API with tools; a spend-cap warning; and the tracker's cost compared with the provider's bill.

## Open questions

1. **Where the 540 s came from.** Job 1011 had 540 billable seconds persisted before the relaunch.
   Billable time is written only on pause or end, and nothing in the export says which one wrote
   it. The on-device `log.jsonl` would say.
2. **What wedged the synthesizer.** One candidate is the wake-word session reconfiguring on becoming
   active; unproven.
3. **The writer's underlying error behind −11800.** P4 logs it; the concurrent-append hypothesis is
   untested on a device.
4. **Default reasoning effort of `gpt-5.5` and the `-sol` family, and which efforts each accepts.**
   Verify against OpenAI's documentation at implementation time. If a model's default is already
   `none`, Automatic sends nothing for it rather than an explicit `none`.
5. **Whether the job boundary clears model history today** (`GuidedJobFlow.swift:468,507`). P5
   depends on the answer.
6. **Which turn opened which page in the tester's run.** There was no presentation event (P1 adds
   one), and the embedder in use was not logged.
7. **Resume the stream on relaunch mid-job?** Doing so would reverse a deliberate FD/CV choice; it
   needs an owner decision.
8. **Shown-automatically pages in the PDF:** omitted (the default above) or listed under their own
   heading?
