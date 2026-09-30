# Plan GN — Agent Notebook ("What have you been thinking about?")

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Builds on:** `AgentScheduler` (Agent-Mode timer tasks), `AgentNotificationQueue`, Plan
[W](W-presence-aware-agent-throttle.md) (presence), the My Day delivery gate (`MyDayDeliveryPolicy`,
`isBusy`), Plan BZ (notification digest).
**Sits beside:** Plan [GG](GG-readable-memory.md) (readable memory). Memory is what the assistant
knows about the wearer; the notebook is what it is *thinking about* on the wearer's behalf. They are
separate stores with one link: forgetting a fact closes notebook entries that cite it.
**Related:** Plan [AW](skill-self-evolution.md) (the other Agent-Mode background loop, human-reviewed),
[llm-cost-usage-tracker](llm-cost-usage-tracker.md).

---

## Trigger

Between conversations the assistant forgets it had anything in mind. The wearer said on Monday
they would call the plumber "after the quote comes in"; a meeting ended with two actions; a
reminder has slipped three days running. Nothing notices, and when something does (the existing
scheduled "Context Check"), it speaks immediately or not at all, and leaves no record the wearer can
read.

## Outcome

- Between conversations, with Agent Mode on and the setting enabled, the assistant writes **brief
  notes**: open loops, upcoming things that need preparation, and patterns ("third day the gym
  reminder was snoozed").
- Each note is **scored** for whether it is worth telling. Worth-telling notes wait until the wearer
  is free, then are said once, briefly. The rest stay in the notebook.
- The notebook is **readable** ("What have you been thinking about?"), **editable** and **clearable**,
  by voice and on the phone. Nothing in it is hidden reasoning.

## What exists today (verified 2026-10-01)

- `Services/AgentScheduler.swift`: Agent-Mode-gated (`Config.agentModeEnabled`) timer tasks while the
  process is alive (`agentConnectedInterval`/`agentDisconnectedInterval`), defaults include
  "Upcoming Events" (on), "Context Check", "Memory Reflection" (`[REMEMBER]` writes), "Suggest
  Improvements" (off). Each run wraps the prompt with a `[NOTHING]` convention, defers when the
  on-device model is not loaded or `LocalLLMError.backgrounded`, runs off-turn
  (`TurnRecorder.offTurn`), and speaks through `agentNotificationQueue.enqueue`. **No record of a run
  is kept** beyond `lastRun`; a `[NOTHING]` run leaves no trace.
- `Services/AgentNotificationQueue.swift`: speaks immediately if glasses are connected, otherwise
  queues with staleness, reviews on reconnect, summarises many; feeds the BZ digest (`onQueued`).
- `NativeTools/AgentDiaryTool.swift` (`agent_diary`) over `SemanticMemoryStore`'s `diary` table: the
  agent's private append-only journal (write/read/search). No state, no score, no UI; the wearer
  cannot see it.
- `Services/MyDay/MyDayDelivery.swift`: `MyDayDeliveryPolicy.decide` (quiet hours, protected data,
  presence `active`/`present`, power not `reserve`, online, `!isBusy`); `isBusy` is wired in
  `AppState` as `isProcessing || isListening || speechService.isSpeaking`. `MyDaySources.swift`
  protocols (`CalendarDaySource`, `RemindersDaySource`, `DigestDaySource`, …) are injectable.
- `Services/Presence/ThrottlePolicy.swift` (`EngagementMode` active/present/idle/away); `Brain/BrainStore`
  `needs(for:openOnly:)` (open loops per person); `ProactiveAlertService` (calendar alerts).
- **No `BGTaskScheduler` anywhere**; `UIBackgroundModes` is `audio`, `bluetooth-central`,
  `external-accessory` (no `fetch`/`processing`). Today "between conversations" means "while the app
  happens to be alive".

## Design

### Model

`NotebookEntry`: `id`, `kind` (`openLoop`, `upcoming`, `pattern`, `followUp`), `text` (≤ 280 chars,
second person, plain), `because` (≤ 140 chars, why it was noted), `evidence` (refs into the inputs
below: `reminder:<id>`, `event:<id>`, `need:<id>`, `thread:<id>`, `fact:<store/id>`), `createdAt`,
`updatedAt`, `score` + `scoreReasons`, `state` (`noted`, `waiting`, `told`, `dismissed`, `done`,
`expired`), `tellAfter?`, `expiresAt` (default 14 days, `upcoming` expires at the event).

### Thinking pass

- **`NotebookInputs`** (built deterministically, injected sources): reminders due/overdue, calendar
  next 36 h, open brain `needs`, thread titles + summaries from the last 72 h (summaries only, never
  full transcripts), meeting action items, and the current notebook. Capped at ~4k input tokens by a
  pure `NotebookInputBudget` (oldest threads dropped first).
- **One model call** (`completeStateless`) with a fixed instruction and a JSON schema: up to 5
  operations `add` / `update(id)` / `close(id, reason)`. **`NotebookProposalParser`** (pure) validates
  lengths and kinds, and **rejects any evidence ref not present in the inputs** so the notebook cannot
  cite things that do not exist. Invalid output → no change, logged by count only.
- Cadence: at most every 3 h and ≤ 6 passes a day; skipped when nothing in the inputs changed since
  the last pass (input digest), which is most of the time and costs nothing.

### Worth telling (`WorthTellingScorer`, pure, deterministic)

Score 0–100 from: time sensitivity (due/overdue or event within 3 h: high), kind weight, novelty
(not already told, not already in today's My Day briefing, not a near-duplicate of a told entry —
token Jaccard), evidence count, the wearer's history for that kind (dismiss rate lowers future
scores), and the model's own `importance` clamped to ±10 so the model cannot force delivery.
≥ 70 → `waiting`; below stays `noted`. Pinned by table tests.

### Delivery (`NotebookDeliveryPolicy`, pure)

Reuses My Day's context shape (`presence`, `power`, `isBusy`, quiet hours from the My Day settings,
protected data) plus: no delivery during a meeting (`MeetingAssistantService` active) or a live
session, ≤ 3 unprompted notes a day, ≥ 90 min apart, oldest-most-urgent first. When allowed, one
sentence goes through `agentNotificationQueue.enqueue` (so the glasses-disconnected queue, staleness
and the digest still apply); phone-only wearers get the digest entry / notification instead of
speech. **If the wearer is busy it waits**; a `waiting` note past its `tellAfter` window turns back to
`noted` rather than arriving late.

### Readable and editable

- Tool **`agent_notebook`**: `list` ("What have you been thinking about?" reads the top 3 by score,
  then offers the rest), `dismiss(id)`, `done(id)`, `edit(id, text)`, `mute(kind)`, `clear`. Replies
  name why each note exists (`because`).
- Phone: Settings → Assistant → **Notebook**: entries grouped by kind with because/evidence, state,
  Dismiss / Done / Edit / Clear all, "Think between conversations" toggle, and a line showing the
  last pass time and today's pass count. Copy never names plan letters.
- **Not memory.** Entries are not ingested into `BrainStore` or recalled as facts: they are derived
  from memory and would loop back into it. What the wearer *says* in reply goes through the normal
  memory paths. `agent_diary` stays the agent's internal log; the notebook reads the diary as an
  optional input, never the reverse.
- **GG link:** GG's `MemoryFactForgetter` adds a step that closes (`expired`, reason "forgotten")
  every notebook entry whose evidence cites the forgotten fact, and a person erasure closes entries
  citing that person.

### Where the thinking runs

1. **While the app is alive** (listening, audio mode, foreground): a built-in `AgentScheduler` task
   `notebook` replaces the default-off "Context Check" and "Memory Reflection" prompts for wearers
   who enable the notebook (they stay available as custom tasks).
2. **Background, opportunistic:** `BGAppRefreshTask` (`BGTaskSchedulerPermittedIdentifiers`,
   `UIBackgroundModes` `fetch`), one pass per wake, cloud model only, hard 25 s budget; iOS decides
   when (often after the phone is unlocked, rarely overnight). No `BGProcessingTask` in v1.
3. **On-device model:** foreground only (MLX cannot run backgrounded); if the active model is
   local-only, background passes are skipped, not queued.

### Gates and modes

- **Agent Mode required** (autonomous background work), plus its own toggle, default off. Turning
  Agent Mode off stops passes and delivery; the notebook stays readable and clearable.
- **HIPAA mode:** passes run only when `MedicalEgressGuard` allows the active provider for transcript
  content; local-only mode runs foreground on-device passes only. Entries honour
  `Config.hipaaRetentionDays`.
- **Power:** no passes under `reserve`; `conserve` halves the cadence.
- **Cost:** each pass is recorded off-turn under its own label in the cost tracker; the setting shows
  "about N passes a day".

## Phases (one PR each)

**P0 — Pure core.** `NotebookEntry`, `NotebookInputs` + `NotebookInputBudget`, `NotebookProposalParser`,
`WorthTellingScorer`, `NotebookDeliveryPolicy`, `NotebookCadence` (digest skip, daily cap). Tests:
`NotebookProposalParserTests` (invented evidence rejected, caps, malformed), `WorthTellingScorerTests`,
`NotebookDeliveryPolicyTests` (busy waits, quiet hours, meeting, daily cap, spacing, late → noted),
`NotebookCadenceTests`, `NotebookInputBudgetTests`.

**P1 — Store, tool, screen, foreground passes.** `AgentNotebookStore` (SQLite, file protection
`completeUntilFirstUserAuthentication`, 200-entry cap), `agent_notebook` tool registered, Notebook
screen, `AgentScheduler` `notebook` task with fake-LLM tests (`AgentNotebookServiceTests`), delivery
through the queue.

**P2 — Background refresh.** BGTask registration, Info.plist keys, 25 s budget and cancellation,
local-model skip. Tests: `NotebookBackgroundPassTests` (expiry handler cancels cleanly; no MLX path).
Device (owed): how often iOS actually grants refresh for this app over a week.

**P3 — Feedback and GG link.** Dismiss-rate learning per kind, `mute(kind)`, the GG forget hook
(lands with or after GG P1, which builds `MemoryFactForgetter`). Tests: `NotebookForgetPropagationTests`.

## Risks

- **Nagging.** The scorer, daily cap and spacing are the defence; the dismiss-rate feedback lowers
  future scores; the default is off.
- **Confabulated notes.** Evidence must cite real inputs; notes without evidence are rejected.
- **Background reality.** App refresh is rare and unpredictable; the notebook must be useful from
  foreground passes alone.
- **Privacy.** Summaries of recent threads go to the cloud model in each pass; the setting says so.

## Decisions for Greig

1. **Agent-Mode gate** plus a default-off toggle (recommended, per house rule) — or allow a
   read-only "notice but never speak" notebook without Agent Mode?
2. **Background refresh (`fetch` mode)** in v1, or foreground/alive-only first? *Recommend alive-only
   in P1, BGTask in P2.*
3. **Speaking threshold and cap:** 70 / 3 a day / 90 min apart as starting values?
4. **Which model** runs passes: the active model, or a pinned cheaper one? *Recommend the active
   provider's small model.*
5. **Replace** the default-off "Context Check" and "Memory Reflection" tasks for notebook users, or
   keep all three?

## Out of scope

Acting on notes (the notebook suggests; any action goes through normal tool authorization when the
wearer asks), syncing the notebook to the gateway or other devices, long-horizon planning, and
reading full transcripts in passes.
