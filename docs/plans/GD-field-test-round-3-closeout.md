# Plan GD — Field Test Round 3 Close-out: Job Cost, Earlier Work, Field Tool Profile

**Status:** 📋 Planned 2026-09-30 — the three buildable items Plan [GB](GB-field-test-round-3.md)
left behind from the field tester's round-3 feedback, in one PR, so that everything he asked for is
built before the next TestFlight build. Owner decisions taken 2026-09-30: build the field-mode tool
profile (on by default during a job); pages shown automatically stay out of the customer PDF (JSON
only, as shipped); the glasses stream is **not** resumed after a relaunch (`record_clip` claims it on
demand, GB P4). **Owed after merge:** the device pass GB lists, plus this plan's rows: the Job tab's
cost against the provider's dashboard for one job, and one field job with the profile on.

**Trigger:** GB's Status names three deferrals that are code, not device checks: per-job cost on the
Job tab (the usage store carries the job id, nothing reads it — `UsageTracker.jobUsage` has no
caller outside `Services/Usage/`), the unit split on first identification, and a field-mode tool
profile (GB's cost table, rank 4: about 10k tokens of unused tool schemas on every request, an
estimated 10–20% of his bill). His three priorities were usage tracking, spending caps and reliable
answers; the first and third of these items serve the first, the second serves the record he reads.

Paths are under `OpenGlasses/Sources/` unless noted. Line numbers are `main` @ `20ddf33d`.

## Verified starting point

- `JobUsageSummary` (`Services/Usage/UsageModels.swift:51-77`) and `UsageTracker.jobUsage(fieldSessionId:)`
  (`Services/Usage/UsageTracker.swift:56`) exist; `UsageRecord.fieldSessionId` is written per request
  (`LLMService.recordUsage`, `:1833-1846`). Nothing consumes the summary: `WorkRecord`
  (`Services/FieldAssist/WorkRecord.swift`) has no usage field, `ActiveJobView.timeSection`
  (`App/Views/Job/ActiveJobView.swift:178`) and `PastJobView` show billable time only.
- `FieldSessionService.setEquipment` (`Services/FieldAssist/FieldSessionService.swift:253-291`)
  attaches the first identification to the current scope (`"initial"` until a new unit opens) and
  only opens a new scope when a *different* unit follows an existing one; `startNextUnit` (`:322`) is
  the explicit split. `UnitLedger` (`Services/FieldAssist/UnitLedger.swift`) already prints a scope
  with tasks and no identity as "Unidentified unit". So work recorded before the first nameplate is
  read is attributed to whatever machine is identified next — right when it is the same machine,
  silently wrong when the technician has moved on.
- `ToolDeclarations.nativeToolDeclarations` (`Models/ToolCallModels.swift:145-163`) declares every
  registry tool that is enabled and not HIPAA-disabled, sorted, for OpenAI, Anthropic and Gemini
  shapes; the prompt lists `registry.toolNames` (`LLMService.swift:809`, `:487`) and, when schemas are
  not attached, their descriptions (`:862`); `runAgentPlan` (`:1105`) plans over the same names. There
  is no profile mechanism. About 120 native tools exist.

## Decisions (2026-09-30)

1. **Per-job cost is shown where the technician looks and kept off the customer's page.** The work
   record gains `usage` (decode-if-present, encoded only when non-empty); the Job tab's time section
   and the past-job view show one line; the customer summary and PDF never do.
2. **No silent unit split.** GB's deferred wording ("opens a new scope and back-fills the unidentified
   unit") would guess whether earlier work belongs to the machine just identified — the inference GB
   decision 1 rejected for evidence. Instead: when the first identification arrives after work is
   already recorded, the tool's reply says the earlier work is now on this unit and invites the
   correction; a new `field_session` action, `separate_earlier_work`, moves that earlier work to an
   unidentified unit of its own. Deterministic, logged, reversible in the sense that nothing was
   guessed.
3. **The field-mode tool profile is on by default during a Field Assist job**, with a Developer-panel
   switch to turn it off. It is one fixed, sorted allowlist plus the general essentials; the declared
   list is logged as a count and a digest, never as prompt text. The profile is applied at the one
   filter every provider's declaration passes through and to the prompt's tool list, so a tool is
   either declared and listed or neither. HIPAA filtering still applies on top.
4. **Shown-automatically pages stay out of the PDF** (owner, 2026-09-30). No change.
5. **No stream resume after relaunch** (owner, 2026-09-30). No change.

## Phases (one PR)

### GD1 — Per-job cost on the Job tab and in the job JSON
- `WorkRecord.usage: JobUsageSummary?` with key `usage`, nil when the summary is empty or absent;
  `WorkRecord(session:vaultName:…, usage:)` takes it as a parameter (the struct stays pure), and the
  record builders in `FieldSessionService` (`:206`, `:903`, `:913`, `:2273`), `JobTabModel` (`:699`,
  `:837`), `GuidedJobFlow+Debrief` (`:332`) and the app (`OpenGlassesApp.swift:979`) pass
  `UsageTracker.shared.jobUsage(fieldSessionId: session.id)`.
- Pure `JobTabModel.usageLine(_ summary: JobUsageSummary?) -> String?`: "Model usage: $0.42 · 12
  requests", "Model usage: 12 requests (3 unpriced)", "Model usage: 5 requests, not priced", nil when
  empty. Shown in `ActiveJobView.timeSection` and in `PastJobView`'s summary. `summaryLines` (the
  internal text) gets the same line; `CustomerSummary` is untouched and a test proves it.
- Tests: encode/decode with and without usage, a legacy record decodes with nil; each phrase; the
  customer summary never mentions usage; the Job tab line for an active job with two requests.

### GD2 — Earlier work and the first identification
- `FieldSession` gains `earlierWorkAttachedAt: Date?` (decode-if-present): set by `setEquipment` when
  it is the first identification (`session.equipment == nil`) and the current scope already has
  tasks, readings or photos; cleared by `separate_earlier_work` or `next_unit`.
- `FieldSessionService.separateEarlierWork() -> Bool`: when set, opens a fresh scope for the
  identified machine (the `VisitedUnit` moves to the new scope; `equipment` stays), leaves the
  earlier tasks under the old scope (which `UnitLedger` then prints as "Unidentified unit"), logs
  `unitSplit` with both scopes, clears the marker. Returns false when nothing was attached.
- `FieldSessionTool`: the identification reply appends one sentence when the marker is set ("Earlier
  work on this job is now recorded on this unit; say if it was a different machine."); the new
  action `separate_earlier_work` with its description in the tool schema; the system-prompt rule
  that maps "that was a different unit" / "the earlier work was on the other furnace" to it (in the
  same place GB P2 documents `next_unit`).
- Tests: job 1011's shape — two tasks, then a first identification → marker set and the reply carries
  the sentence; `separate_earlier_work` → the ledger prints Unit 1 "Unidentified unit" with the two
  tasks and Unit 2 the identified machine; a first identification with no prior work sets nothing;
  `next_unit` clears the marker; a legacy session decodes.

### GD3 — Field-mode tool profile
- Pure `FieldToolProfile` (`Services/FieldAssist/FieldToolProfile.swift`): `static let names:
  Set<String>` (the field list below plus essentials), `static func declaredNames(all: [String],
  fieldJobActive: Bool, enabled: Bool) -> [String]` returning `all` unchanged unless both flags are
  true, otherwise the sorted intersection. Field list: `field_session, manual_lookup, manual_figure,
  equipment_lookup, procedure_runner, reading, evidence, parts_request, deliver_report,
  escalate_to_expert, capture_photo, record_clip, photo_log, pin_frame, smart_capture, vision_assess,
  look_closely, scan_document, scan_code, scan_badge, qr_context, domain_calc, convert_units,
  calculate, capture_flow, safety_assessment, first_aid, emergency_info, task, propose_task, reminder,
  set_timer, save_note, list_notes, session_search, summarize_conversation, new_topic,
  yield_to_human, discover_capabilities, get_datetime, get_weather, where_am_i, navigate,
  get_directions, find_nearby, phone_call, lookup_contact, send_message, web_search, flashlight,
  device_info, teleprompter, playbook`. A scrape test asserts every name exists in the registry.
- `Config.fieldToolProfileEnabled` (default true) with a Developer panel toggle "Field-mode tool
  profile" and a footnote ("During a Field Assist job, only field tools are offered to the model,
  which cuts cost per request. Turn off to offer every tool."). This is the one new user-facing
  string pair.
- Applied in `ToolDeclarations.declarableNames` (so OpenAI, Anthropic, Gemini and the Responses
  hoist all see the same list) and at `LLMService.swift:809` for the prompt's `nativeToolNames`,
  with `fieldJobActive = FieldSessionService.shared.activeSession != nil`. `PrivacyLog.model(
  .toolProfileApplied, count: declared, total: all)` once per turn when it trims anything.
- Tests: no job → all; job + enabled → the intersection, sorted; job + disabled → all; HIPAA-disabled
  names still removed; every profile name exists; the prompt's tool list and the declared schemas
  agree (a request with the profile on lists exactly the declared names).

## Deferred and follow-ups
- Per-vault or per-job-type tool profiles (a vault naming the tools it needs).
- The PDF heading for shown-automatically pages, if the owner ever wants it.
- GB's device pass, extended by this plan's two rows, stays owed to the field tester.
