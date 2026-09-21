# Plan FO — Guided Job Flow and the Job Tab

**Status:** 🚧 Drafted 2026-09-21; evidence-at-close addendum (§5, P2a/P2b) added 2026-09-21;
**P0 implemented 2026-09-21** (inventory below + the typed tab identifier). P1–P4 unbuilt.
The voice-turn reliability fixes
from the same field report (wake word re-arm, self-interrupted speech, `new_topic` misfire, short
wake phrases, and the narrow "keep the saved thread while a field session is active" rule) landed
alongside this draft in the same PR; they are a **prerequisite**, not part of this plan, and a
device run confirming them is still owed.
**Trigger:** A pilot technician on build 407 asked for three workflow changes: one continuous chat
per job, the assistant asking for the job number by itself when a job starts, and a confirmation
when the conversation moves to different equipment. The stated bar: *the workflow should guide the
technician automatically, without requiring familiarity with AI or chat apps.*

## Outcome

A technician with Field Assist enabled opens the app and sees a **Job** tab. One tap (or one spoken
phrase) starts a job; the assistant asks for the job number and records what it hears; everything
said, measured, photographed and cited until the job is closed lives in one thread, reviewable
later under that job number. If the technician starts talking about a different unit, the assistant
asks whether the previous job is finished before anything is re-scoped. Closing the job reads back
the record, lets the technician pick which photos and clips go with it, and offers delivery. None of
this requires knowing what a "chat", "thread" or "session id" is.

## Verified starting point (main @ build 408)

- `FieldSession.jobReference` exists, persists, and flows into `WorkRecord`, delivery file names
  and summaries. `FieldSessionTool` has `set_job_reference` (added in #521). `startSession(…,
  jobReference:)` accepts one, but the tool's `start` action never passes it and its reply
  ("Started … Session id: 1a2b3c4d.") neither asks for a job number nor tells the model to. Whether
  the technician is asked is left to the model's initiative.
- `FieldSession` has **no thread id field**, and `FieldSessionService` never mentions
  `ConversationStore`. The coupling runs the other way and is one line: `returnToWakeWord()` asks
  `ConversationThreadContinuityPolicy.shouldEndSavedThread(…, fieldSessionActive:)` — the
  accompanying fix's narrow rule, already shipped — before ending the thread. The other coupling is
  `FieldSessionService.recordConversationTurn`, an event-log dedup hook. This plan replaces the
  narrow rule with an explicit binding.
- **Correction to the draft:** a saved thread does *not* live "exactly as long as
  `AppState.inConversation`". The two are unrelated pieces of state. `inConversation` is a mic flag,
  never `@Published`, and has no reference to `ConversationStore` at all; the thread is
  `ConversationStore.activeThreadId`, created lazily on the first turn's text and restored at launch
  if under two hours old. A thread routinely outlives `inConversation` — see the inventory below.
- `FieldSessionService.setEquipment` **silently re-scopes** when the recognised heading changes:
  new `continuityScope`, procedure runner dropped (FM). Correct for continuity, but nobody is asked
  whether the previous job is finished, and a forgotten open job keeps accruing billable time.
- The tab bar (`MainView.swift`) is Voice / Modes / Chat / Settings, `Tab(value: Int)`. Field
  Assist today is reachable through a quick action, Settings → Field Assist, and tool calls. There
  is no surface that shows "the job I am on" as a first-class thing. `WorkRecordSurface`,
  `EquipmentSurface`, `ManualPageSheet` and the session history exist as components.
- `Config.fieldAssistActive` already gates the feature (licence + toggle).

## Decision: a Job tab, shown only when Field Assist is active

**Yes.** Reasons, on the merits:

1. The pilot audience is technicians, not chat-app users. The thing they think in is *the job*.
   Today the job is invisible unless you ask the assistant about it; the Chat tab shows a flat list
   of conversations titled by their first sentence, which is the wrong index for this user.
2. A fifth tab costs nothing for everyone else: it appears only when `fieldAssistActive`, so the
   consumer/accessibility experience is unchanged. Five is within the platform's comfortable limit.
3. It gives the guided flow a home. "Start job", "job number", "current unit", "close job" and
   "past jobs" need buttons somewhere for the moments voice fails (noisy plant room, customer
   present), and Settings is the wrong place for operational controls.
4. It gives review a home: past jobs listed by job number/date, each opening its single thread and
   its work record.

Constraints: the Voice tab stays the primary capture surface (the capsule stays primary — existing
UI decision); the Job tab is a *dashboard and review* surface plus explicit controls, not a second
chat UI. It must not appear, flash, or reorder tabs for users without Field Assist, and a licence
lapsing mid-job must not strand an open job (tab stays while a session is active).

## Scope and invariants

- Never end, switch, or start a job without the technician's say-so. One job may cover several
  units; equipment change is a *question*, never an automatic switch.
- A job number is recorded exactly as given — never invented, normalised or guessed from context.
  "I don't have one" is a valid answer and is recorded as such (no nagging loop).
- Guidance is deterministic app behaviour, not model goodwill: the prompts that must happen
  (ask for job number; confirm job change) are driven by app state and survive a model that
  ignores instructions, a provider switch, and a context compaction (FM).
- Job threads are ordinary saved conversations; deletion, export, privacy scopes and HIPAA
  restrictions keep their existing semantics. No second conversation store.
- Works in Direct mode first. Gemini Live / OpenAI Realtime get the same state machine through
  their setup/context snapshots in a later phase; they are not silently covered.

## Design

### 1. Job ↔ thread binding
`FieldSession` gains `conversationThreadId: String?` (decode-if-present, so old sessions load).
Starting a job binds the active thread, or starts one if none. While a job is active, every
Direct-mode turn — wake word, tap-to-talk, typed — resolves to the bound thread through one pure
function, `JobThreadPolicy.thread(for:)` (inputs: active session, bound id, whether that thread
still exists, explicit user "new chat"). Ending/returning to wake word no longer ends a bound
thread. An explicit "new chat" during a job asks first ("You're on job 1005 — keep this in the job,
or start a separate chat?"). A restored in-progress session re-binds on launch. The thread's title
becomes "Job 1005 — Lennox SLP99" once known, not the first sentence.

### 2. Job-number prompt
A small pure state machine, `JobIntakeState`: `needsReference → asked → recorded | declined`.
`FieldSessionTool.start` accepts `job_reference` (so "start job 1005" is one step) and, when it is
absent, returns a result that states the job number is outstanding. Independently of the model,
the app speaks the intake question after the start confirmation when state is `needsReference`,
and treats the next utterance as the answer candidate — confirmed by read-back ("Job 1005 —
right?") because speech-recognised digits are error-prone. `declined` is logged in the audit
record. The Job tab shows the same state with a text field, so it can be typed instead.

### 3. Possible change of job
Pure `JobChangeDetector`: compares a newly recognised `EquipmentIdentity` (or a spoken
model/serial that resolves through `VaultModelIndex`) with the session's current equipment and
returns `.same | .additionalUnit(candidate) | .unclear`. On a candidate, the app **holds** the
re-scope and asks: *"That sounds like a different unit. Is job 1005 finished, or is this another
unit on the same job?"* Answers: same job → re-scope exactly as `setEquipment` does today, and
record the unit on the job; finished → run the normal close flow, then start a new job (intake
asks for its number); not sure/no answer → nothing changes, ask again at most once per candidate.
A wrong nameplate read must not trigger a close: the question is only raised on a confident
identity (same threshold EL uses to set equipment at all).

### 4. Job tab
Shown when `fieldAssistActive || activeSession != nil`. Tabs move to a typed identifier instead of
bare `Int` values first, so inserting one cannot shift persisted selections or deep links.
- **No active job:** vault in use, a large *Start job* button (optional job-number field),
  past jobs by job number/date/outcome.
- **Active job:** job number (editable), elapsed/billable state with pause/resume, current unit(s),
  task list and readings from `WorkRecordSurface`, *Open conversation* (the bound thread),
  *Read back*, *Close job* (→ existing export/delivery flow).
- **Past job:** the work record, its thread (read-only), re-send delivery.
- A "Wake word" row is **not** duplicated here — the accompanying fix puts it in Field Assist settings.
VoiceOver order, Dynamic Type and the HUD-less case are acceptance criteria, not afterthoughts.

### 5. Evidence review at close (photos and clips in what gets sent)

Owner request, 2026-09-21: the technician wants to send evidence of the fault and of the fix. The
moment for that is the end of the job — *Close job* walks through choosing the pictures and clips
before anything is rendered or sent. Owner decisions the same day: video clips are **in scope**;
full-size originals are offered through the share sheet; Fault/Fix marking is **optional**.

**Verified starting point.** `photo_log` already saves a filtered still into the session's `photos/`
directory with a caption, records it on the current task's `Evidence.photos` (or the session's
`jobEvidence` when no task is open), and queues a `.photoUpload` for the offline sink. But nothing
the recipient gets contains a picture: `SessionExporter` prints each photo as a text bullet
(`"• \(photo.path)" + caption`), and its private `PDFLayout` has no image-drawing method at all;
`DeliveryRequest.Attachment.Kind` is `pdf | json` only. Photos taken any other way during a job (a
plain capture, a picture added in chat from the phone) are not attached to the job at all —
`attachPhoto` has exactly one caller, `PhotoLogTool`. There is no clip/video evidence on a session:
`Task.Evidence` is `readings`, `photos`, `citationsOpened`, `pagesVerified`.

**Design.**
- *During the job, capture stays cheap.* Every photo taken while a job is active — `photo_log`, a
  plain capture, a phone-camera or library picture added from the Job tab or the job's thread — lands
  in the job's evidence with its time, task and caption. No question is asked mid-job. Filtering is
  not inherited: `photo_log` goes through `CameraService.filteredStill(for: .toolPhotoCapture,
  source:)`, but `capturePhoto()` is deliberately exempt (the wearer's own framed shot), and the
  phone-camera path (`handlePhoneCapture`) is filtered by neither. So each newly attached route must
  ask for a filtered still explicitly — `filteredStill(for:source: .photoOnly)` for the shutter
  image, the same privacy filter applied to a phone-sourced picture before it is stored — or the job
  would carry unblurred bystanders while `photo_log` does not.
- *Close job → evidence review.* The close flow gains one step before the read-back and delivery:
  a grid of the job's photos and clips, grouped by task, newest last. Each item can be included or
  left out, captioned/re-captioned, and **optionally** marked **Fault** or **Fix** — never prompted,
  never required (pure `EvidenceSelection` model: item id, included, role?, caption, order).
  Default: everything captured through `photo_log` included, everything else offered but not
  pre-selected. Skipping the step is one tap and sends the text-only record exactly as today. By
  voice: "include all", "skip photos", and a per-item yes/no read-out for the hands-busy case; the
  HUD-less/VoiceOver path is an acceptance criterion.
- *The PDF carries the pictures.* `SessionExporter` renders selected photos inline under their task,
  Fault before Fix before unmarked, downscaled (long edge and JPEG quality fixed by a pure
  `EvidenceImageBudget` so a twenty-photo job still produces a mailable PDF), each with caption and
  timestamp. `PDFLayout` gains an image method — it has only `heading`/`section`/`body`/`spacer`
  today. Unselected photos stay in the on-device record and the JSON's `photos` list (marked
  `included: false`) but are not rendered and never leave the device through delivery.
- *Full-size originals by share sheet.* The review step and a past job's record both offer "Share
  full-size photos" for the selected items: the stored (already privacy-filtered) originals go to
  the system share sheet, so the technician picks the route (AirDrop, Files, Mail, a job system's
  share extension). The PDF keeps the downscaled copies; the composer-based delivery channels are
  not asked to carry originals.
- *Clips.* A PDF cannot carry video. A selected clip is sent as its own attachment where the channel
  can take it, bounded by a per-channel size budget; over budget, the flow says so and offers the
  share sheet for that clip instead of silently dropping it. `DeliveryRequest.Attachment.Kind` gains
  `video`; `DeliveryChannel.carriesAttachments` — today a plain `Bool` that zeroes attachments for
  channels that cannot carry files — grows a size-aware check. The PDF lists each included clip
  (caption, time, duration) under its task so the record is complete even when the clip travels
  separately. Clip *capture* during a job ("record a clip of this") subscribes to
  `outboundFrames.publisher` like every other camera-rate consumer (bystander blur shared via
  `OutboundFrameRelay`), registers in the `OutboundFrameConsumer` roster, is length-capped, and is
  stored under the session like photos.
- *Face blur follows the global setting, and says so.* `Config.privacyFilterEnabled` is one app-wide
  toggle with no per-call override, and the copy stored for a filtered route is the filtered one —
  raw pixels are never kept — so nothing can be un-blurred at review time. The Job tab and the
  close-job review show the current state in plain words ("Face blur: On/Off", linking to the
  setting), and an item captured while the filter was on is labelled as such in the review grid so
  the technician knows what the recipient will see. There is no per-job or per-photo override
  (owner decision 2026-09-21). The filter touches faces only; nameplates, gauges and fault sites are
  unaffected.
- *Invariants.* Nothing is sent without the technician's Send tap (EM) — enforced by the composer
  sheet on `AppState.deliveryComposerRequest`, with `completeDelivery` recording `.sent` only on a
  real send outcome; the share sheet is likewise only ever opened by a tap. The selection is part of
  the work record, so a re-send from a past job reproduces the same PDF. HIPAA/medical restrictions
  and the privacy-filter scope rules are unchanged; any new store registers with `DataStoreRegistry`.
  **Deletion is an open problem, not an invariant:** there is no way to delete a field session
  today, and `DataStoreRegistry` marks `.fieldSessionLogs` `deleteAll: .unavailable("a session log
  is the engineer's compliance record")`. Adding media does not change that posture, but it raises
  the stakes, so P2a records the media under the same store and the deletion question moves to the
  open list rather than being answered here.

## Phases (one PR each)

- **P0 — inventory and seams.** ✅ **Implemented 2026-09-21.** Every place a thread is
  started/resumed/ended and every entry point that starts, re-scopes or ends a field session,
  mapped in *P0 inventory* below — including six findings that change P1's scope. `MainTab`
  replaces the bare-`Int` tab identifier, with the legacy numbers frozen; no visible change.
- **P1 — deterministic core, headless.** `JobThreadPolicy`, `JobIntakeState`,
  `JobChangeDetector`, the `FieldSession` field + migration test, `FieldSessionTool.start`
  accepting `job_reference`. Wired into Direct mode. Tests are the gate: thread continuity across
  wake-word cycles and app restart; intake including declined and misheard-digits read-back;
  change detector corpus (same model different serial, accessory vs unit, low-confidence read);
  compaction does not lose intake/change state.
- **P2 — Job tab.** The three states above over existing components; thread titling; past-jobs
  list. Snapshot/UI tests with Field Assist off (tab absent) and on.
- **P2a — photo evidence at close.** Headless first: `EvidenceSelection`, `EvidenceImageBudget`,
  job-scoped attachment of photos from every capture route (each asking for a filtered still in its
  own right), `SessionExporter` inline rendering, the selection persisted in the work record
  (decode-if-present) and honoured on re-send. Then the close-flow review step in the Job tab with
  its voice path, and "Share full-size photos". Tests are the gate: PDF contains the selected images
  and none of the unselected; Fault → Fix → unmarked ordering with marking absent entirely also
  valid; size budget holds at 20+ photos; skip reproduces today's output; re-send determinism;
  every newly attached capture route stores a filtered copy; the share-sheet item list is exactly
  the selected originals.
- **P2b — clips.** Length-capped clip capture as a rostered `OutboundFrameConsumer` on the blurred
  relay, stored under the session; clips in the review grid; `video` attachment kind with the
  per-channel size budget and the share-sheet fallback; clip lines in the PDF. Tests: roster/guard
  suites stay green, over-budget never silently drops, re-send determinism.
- **P3 — live sessions and other surfaces.** Gemini Live / OpenAI Realtime parity via their
  context snapshots; HUD cue for the two questions; CarPlay/watch read-only job state.
- **P4 — device acceptance (owed to a pilot run).** One real job end-to-end by a technician who
  has not been coached: start by voice, number captured, two units on one job, a forgotten-close
  caught by the change question, close and deliver, review later by job number.

## Open questions

- Should a declined job number block delivery, or only flag the record? Leaning: flag, never block.
- Multi-unit jobs: is one `equipment` plus a list of visited units enough for the work record, or
  does each unit need its own task/evidence grouping in the export? (FM's scopes already partition
  tasks; the export does not show it yet.)
- Auto-suggest closing a job after long inactivity or a large location change — useful, but it is
  a nag risk and touches billing; out of scope until a pilot asks.
- Team tier: does the office need to push a job number/assignment to the phone (ops bridge)
  instead of the technician speaking it? Natural follow-on, not v1.
- Clip limits: maximum length per clip and total size per delivery channel (defaults proposed in
  P2b, confirmed on a pilot device).
- Should the office also receive full-resolution originals automatically through the sync sink, in
  addition to the share-sheet route?
- Deleting a job's media: sessions cannot be deleted at all today (`DataStoreRegistry` calls a
  session log a compliance record). Photos and clips make that harder to defend — does a job's media
  need its own retention rule, separate from the log it belongs to?

## P0 inventory (2026-09-21)

Read, not grepped, against main at build 410; symbols are the durable reference. All types
named are `@MainActor` unless the row says otherwise, so P1's hooks can be plain MainActor calls.

### 1. Where a conversation thread begins, resumes, switches or ends

The thread is `ConversationStore.activeThreadId` (a `UUID` string, persisted in `conversations.json`).
`AppState.inConversation` is a separate mic flag; nothing links them.

| Surface | Symbol | Thread effect | Modes |
|---|---|---|---|
| Wake word / tap-to-talk / Action Button | `AppState.handleWakeWordDetected(manual:)` → `ConversationStartSequence.run` | sets `inConversation = true`; the thread itself is created later, in `AppState.handleTranscription`, only once transcript text exists (`ConversationStore.startThread`) | Direct |
| Typed chat | `ChatThreadView.send` → `AppState.sendTextMessage` | `startThread` if none active | Direct/cloud/local |
| Return to wake word | `AppState.returnToWakeWord()` | `inConversation = false`, then `endThread()` **only if** `ConversationThreadContinuityPolicy.shouldEndSavedThread(persistenceEnabled:hasActiveThread:fieldSessionActive:)` says so | Direct |
| `new_topic` (spoken, Tier-0) | `ConversationClassifier` → `AppState.handleTranscription` → `ConversationResetCoordinator.requestReset(source: .voiceCommand)` | retires every live backend at a turn boundary, then `clearLocalHistory` + `startThread` | all |
| `new_topic` (model tool) | `NewTopicTool.execute` posts `.ogNewTopicRequested`; observer calls `requestReset(source: .modelToolCall)` | as above | Direct, Gemini Live |
| Chat tab → New chat | `ChatListView.startNewChat()` → `requestReset(source: .userInterface)` | as above | all |
| Chat tab → open a thread | `ChatThreadView.activateThread` → `AppState.activateConversationThread` → `ConversationContinuity.resume` | sets `activeThreadId` **and** replays history into `LLMService` | Direct |
| Chat tab → delete | `ChatListView` `.onDelete` → `ConversationStore.deleteThread` | destroys the thread, no confirmation (the switcher sheet has one; the list does not) | — |
| Conversation page header → New conversation | `ConversationPageHeader.newConversation()` → `ConversationContinuity.startFresh` | **bypasses `ConversationResetCoordinator`** — ends the thread and clears local history without retiring Gemini Live / Realtime / gateway context | all |
| Siri: ask / run action | `AskOpenGlassesIntent` (`startDirectTranscription`), `AskQuestionIntent` / `RunGlassesActionIntent` (`sendTextMessage`) | start or continue | Direct |
| Siri: persona | `AskPersonaIntent` → `ConversationStore.continueRecentOrStartThread(mode:within:)` | the only recency-based resume in the app (5 min) | Direct |
| CarPlay | `CarPlaySceneDelegate.startVoice/stopVoice/startNewConversation/resumeConversation` | `stopVoice` sets `inConversation = false` without `returnToWakeWord()`; `startNewConversation` calls `endThread()` **directly**, bypassing the coordinator; `resumeConversation` assigns `activeThreadId` **directly** — no `resumeThread()` log, no history replay | Direct |
| Watch | `WatchConnectivityManager` `"ask"` / `"persona"` / `"resumeThread"` | same direct-assignment resume gap as CarPlay | Direct |
| Notification reply | `AgentNotificationQueue.deliver` / `deliverSummary` | sets `inConversation = true` **directly**, bypassing `ConversationStartSequence`; never touches `ConversationStore`, so the reply is not in any thread | Direct |
| Deep links | `openglasses://persona/<id>`, `action/ask` → `connectAndListen`; `disconnect` → `disconnectGlasses()` which ends the thread | start / end | Direct |
| Widget quick action | `AppState.executeQuickAction` → `LLMService.sendMessage` | **none** — a quick-action reply is never saved to a thread | Direct |
| Launch | `ConversationStore.restoreActiveSession()` | restores `activeThreadId` if the thread is under 2 h old; no history replay, `inConversation` always starts false | — |
| Glasses disconnect (BT drop) | `AppState.isConnected` didSet | `inConversation = false`, thread left open | — |
| Background / foreground / termination | — | no handler touches the thread | — |

### 2. Where a field session begins, is re-scoped, or ends

`FieldSessionTool` actions: `start`, `set_job_reference`, `pause`, `resume`, `end`, `status`,
`list`, `recall`, `vaults`, `escalate`, `export`.

| Surface | Symbol | Session effect | Modes |
|---|---|---|---|
| Tool `start` | `FieldSessionTool.startSession(args:service:)` → `FieldSessionService.startSession(vaultId:assetId:mode:startLocation:jobReference:)` | reads `vault` / `asset_id` / `mode` only — **never passes `jobReference`**, though the service parameter exists | Direct, Gemini Live |
| Tool `set_job_reference` | `FieldSessionTool` → `FieldSessionService.setJobReference` | the only way a job number is recorded today | Direct, Gemini Live |
| Tool `pause` / `resume` / `end` | `FieldSessionService.pauseSession/resumeSession/endSession(outcome:)` | billable-time accumulation | Direct, Gemini Live |
| Quick action "Field Assist" | `QuickAction` `.prompt` — sends *text* asking the model to start a session | **indirect**: it is a prompt, not a call, so whether a session starts is the model's decision | whichever mode is live |
| Settings → Field Assist | `FieldAssistSettingsView` Pause / Resume / End / "Start Default Session" | calls the service directly, bypassing the tool (and so any tool-level guard) | UI only |
| Launch restore | `FieldSessionService.restoreInProgressSessionIfAny()` (from `init`) | rebuilds vault/parts index and `ProcedureRunner`, then **auto-pauses** unless already paused | — |
| Equipment set | `FieldSessionService.setEquipment` ← `EquipmentLookupTool` (spoken, spoken-correction, nameplate/OCR), `EquipmentSurface` (manual tap), `startSession` (work-order `asset_id` match) | on a changed `identity.heading`: new `continuityScope`, `runner = nil`, `activeProcedureId = nil` — **silently**, as drafted | Direct, Gemini Live / UI |
| Equipment clear | `FieldSessionService.clearEquipment()` | same reset, unconditional | Direct, Gemini Live |
| Offline queue | `OfflineQueue.recoverInFlight()` | re-arms stranded ops that *reference* a session id; never starts or ends a session | — |
| Licence lapse | `Config.fieldAssistActive` re-checked inside each tool's `execute` | refuses **new** tool actions; an already-open session is untouched — which is what "a lapse must not strand an open job" needs | — |
| Audit hook | `FieldSessionService.recordConversationTurn(_:sourceID:)` ← `LLMService` | appends a `.userMessage` event tagged with `continuityScope` and `activeTask?.id`, deduped by `sourceID`. Confirmed: an event-log hook, nothing more | Direct only |

Persistence: `Documents/FieldSessions/{id}/{session.json, log.jsonl, photos/}` via `SessionLogger`,
registered as `DataStoreRegistry.SensitiveStore.fieldSessionLogs`. `FieldSession` has a hand-written
`init(from:)` precisely so new fields can be added — `continuityScope = try
c.decodeIfPresent(String.self, forKey: .continuityScope) ?? "initial"` is the pattern P1's
`conversationThreadId` should copy.

### 3. What P1 has to hook, and what the draft got wrong

- **`JobThreadPolicy` hooks one place for the happy path and four for correctness.** The happy path
  is `returnToWakeWord()`, where `ConversationThreadContinuityPolicy` already stands — P1 replaces
  that call. The four that bypass it: `ConversationPageHeader.newConversation()` (no coordinator),
  `CarPlaySceneDelegate.startNewConversation/resumeConversation` (direct `endThread()` / direct
  `activeThreadId` assignment), `WatchConnectivityManager` `"resumeThread"` (same), and
  `AppState.disconnectGlasses()` (ends the thread with no field-session check). A binding that only
  covers `returnToWakeWord` is a binding a CarPlay tap breaks.
- **Thread *creation* is lazy and late.** `startThread` runs inside `handleTranscription` after ASR
  produces text, so "start a job" cannot bind a thread that does not exist yet. `JobThreadPolicy`
  must tolerate `boundThreadId == nil` until the first turn, or bind at `startThread` time.
- **Resume is two-step and three callers skip step two.** `ConversationContinuity.resume` sets
  `activeThreadId` *and* replays history into `LLMService`; CarPlay, Watch and launch-restore set
  the id only. A job thread rebound on launch through the id-only path would be an empty-context
  thread wearing a job number — P1's re-binding must go through `ConversationContinuity.resume`.
- **The quick action cannot start a job deterministically.** It sends prompt text; the plan's
  "guidance is deterministic app behaviour, not model goodwill" therefore does not hold for the one
  entry point a technician is most likely to tap. P1 or P2 should give the Job tab (and ideally the
  quick action) a direct `startSession` call.
- **OpenAI Realtime has no Field Assist at all.** Not "parity deferred": `OpenAIRealtimeSessionManager`
  has no `ToolCallRouter` / `ToolDeclarations` reference and its `buildSystemInstruction()` never
  calls `FieldSessionService.promptContext()`. P3's scope for that mode is *wiring tools at all*,
  not adding a state machine to existing ones.
- **Gemini Live does not write to the session audit log.** `recordConversationTurn` is called only
  from `LLMService`, so a job run in Gemini Live has no `.userMessage` events. P1 should decide
  whether the binding also closes that gap.
- **There is a second gate.** Besides `Config.fieldAssistActive` (licence + toggle),
  `FieldSessionTool` checks `AIFeatureGate.isEnabled(.fieldAssist)` (`Config.fieldAssistToolsEnabled`).
  The Job tab's visibility rule should say which gate it follows. HIPAA does **not** gate
  `field_session` — it is not in `Config.hipaaDisabledTools`.
- **No `UIApplicationShortcutItem` exists** anywhere in the app. "Quick action" always means the
  in-app `QuickAction` grid, and P0 found no home-screen shortcut to inventory.

### 4. Readers and writers of the tab selection

One writer, one reader, both in `MainView`: `@State private var selectedTab` and the
`.onChange(of:initial:)` that logs `PrivacyLog.app(.tabSelected, …)`. Nothing else in the app reads
or writes it — no `@AppStorage`, no `@SceneStorage`, no deep link (`onOpenURL` handles callbacks,
trust, personas, skill packs; never a tab), no App Intent, no quick action, no notification, no
launch argument. The UI tests address tabs by their button label through
`AccessibilityAudit.openTab(_:in:)`, never by index. So the typed identifier landed without a
compatibility shim being needed anywhere; `MainTab.legacy(_:)` exists because the numbers *were* the
API while the bare-`Int` bar shipped, and freezing the mapping is what lets P2 insert `.job` without
auditing this again.

Related: [F Field Assist](F-field-assist.md), [EL equipment identity](EL-equipment-identity.md),
[EM work record](EM-work-record-and-parts.md), [FM context and field continuity](FM-conversation-context-and-field-continuity.md),
[FE voice reliability](FE-agent-voice-reliability-and-feedback.md).
