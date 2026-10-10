# Plan FV — Support Reports Without a Backend

**Status:** 🚧 Implemented 2026-09-26, headless. Not compiled or run on a device in the session that
wrote it: the first build is CI's. Live voice modes are not traced yet (see *Not covered*).
**Origin:** pilot support (Max, 2026-09-26): *"we need to see what the technician said, how it was
transcribed, what was actually sent to the AI, and what response or error came back … asking them to
manually export and send logs each time would be cumbersome. Could we have a support dashboard with
automatic session and diagnostic log syncing?"*
**Decided the same day (owner):** automatic syncing means hosting — the firm's or the vendor's — and
neither is wanted before the base server (Plan [FU](FU-base-server.md)) has a host. So: record
everything support needs on the phone, and make sending it one tap, with the person reading it first.

## What it answers, and how

| Support needs | Where it comes from |
|---|---|
| What the technician said, as transcribed | the conversation thread (jobs and outside jobs); the job log's `user_message` when a thread is gone |
| Which recogniser transcribed it | `TurnTimeline.transcriber`, claimed from `TranscriptionService` with the speech-end stamp |
| What was sent to the AI | the words are the transcript line; with them, the system prompt **by block name and size** (`LLMService.buildSystemPrompt`), the manual passages **by citation** (`FieldSessionService.manualPassagesContext`), whether a photo went, the tools called by name and result class |
| What came back | the assistant's reply in the thread; the model that answered; timings (first output, reply complete, tools, heard) |
| What went wrong | `SafeErrorSummary` category on the turn (`ConversationTurnRunner` and the two photo spines), plus the app's event log (`DiagnosticRing`) for the period, plus the job's own log |

**The trace is content-free.** `TurnTrace` (from the sealed `TurnTimeline`) holds names, sizes,
citations, categories and times — never words — and the thread and job it belongs to, so an export
can line it up with the transcript. `TurnTraceStore` keeps 14 days, at most 2,000 turns, in
`Application Support/Diagnostics/turn-traces.json` (protected until first unlock, backup-excluded),
registered as `SensitiveStore.turnTraces`. Deletable in Settings → Diagnostics & Support, and erased
when a phone leaves its organisation.

## How a report is sent

- **After a failure:** a banner on every tab — *"That didn't work — 10:42, the AI service was busy.
  Send to support?"* — opens the review sheet on the conversation the failed turn was part of, with
  **The whole day** one switch away on the sheet (everything included, which is what the banner
  opened on until 2026-10-10). A turn recorded against no conversation opens the day. Dismissed,
  the banner stays quiet for ten minutes.
- **Settings → Diagnostics & Support → Send Last Conversation** (2026-10-10): only the most recent
  conversation. See *One conversation* below.
- **Settings → Diagnostics & Support → Send Today's Activity.**
- **Job tab:** a past job's *Export transcript…* offers *Transcript* or *Support report*; *Export a
  day…* offers the same per day.

The sheet shows the counts, what was masked, and the file; **Email to Support** opens Mail to
`DiagnosticsReportBuilder.supportEmail` with the file attached, and **Share the File…** uses the
share sheet (a `StagedExportCoordinator.fieldSession` lease, released when the share ends). A day's
report can include conversations outside jobs (on by default, a toggle on the sheet). Keys and
tokens are masked across the whole file by `DiagnosticsRedactor`, configured secrets included.
Nothing leaves the phone until the person sends it.

## One conversation

Added 2026-10-10, after a tester with one slow exchange to show was pointed at *Send Today's
Activity* and had to send the whole day to show it.

`JobTranscriptExport.Scope.conversation(threadId:)` is one thread and nothing else from the day:

- **Lines:** that thread's only.
- **AI turns:** the traces recorded against that thread id, whenever they happened. A turn recorded
  against a job but another thread is not claimed.
- **App events and debug log:** from the first thing said or asked to the last, five minutes either
  side — the margin a job's report uses (`JobTranscriptExport.windowMargin`). The debug log is cut
  to the period for this scope only; its lines carry a time of day and no date, so a line is placed
  on the period's first and last day and kept when either lands inside, and a line with no stamp is
  left out. A job's and a day's report keep the newest lines, as before.
- **The last conversation** is the thread with the newest transcript line
  (`JobTranscriptExport.lastConversation(in:)`): a thread holding only the app's own instructions is
  passed over. With conversations locked, Face ID is asked for first, because which thread is the
  last one cannot be known until they open.
- **A job's own thread is still reported as a conversation**, headed *Conversation on Job 1005* with
  a line saying the job's log is not in the file. Widening to the job's report would add the job
  log, tasks and readings to a file whose point is to carry one conversation; the job's report is
  on the Job tab when support needs it.
- **Title and file name** carry the minute the conversation began (*Conversation support report —
  2026-10-10 14:32*), never the thread's own title: that is made from the first words said, and a
  subject line is read by more people than the file.
- A thread whose words were never saved but whose turns were recorded is still sent, as its turns
  alone, and says so.

The selection, the period and the debug-log cut are pure functions over values
(`selection(threadId:threads:sessions:traces:now:)`, `window(around:now:)`,
`debugLines(_:within:calendar:)`), as is which scope each entry point opens
(`SupportReportRequest.named`, `.afterFailedTurn`, `.lastConversation`).

## Where reports go

**Settings → Diagnostics & Support → Support email** (`Config.supportReportEmail`), resolved by
`SupportReportRecipient.resolve`:

- a set address shaped like one wins;
- **an organisation's phone never falls back to the developer** (owner, 2026-09-26: technicians
  would take the button for their own work support, and the developer would receive customer data
  and a flood of mail). "Organisation phone" is `OrgProfileManager.isManaged` or an active
  organisation licence. It falls back to the office that receives its job reports
  (`organizationReportRecipients`), and with neither there is no address: the sheet hides *Email to
  Support*, says to ask a manager, and offers the share sheet;
- a personal phone falls back to `DiagnosticsReportBuilder.supportEmail`, so a typo never sends a
  report nowhere. An organisation profile
can set it as a starting value (`SettingKey.supportReportEmail`, checked for shape, shown on the
enrolment review as "Support reports are emailed to …"); the person can still change it. *Report a
Problem* (Plan DC) still goes to the developer: it reports the app, not a job.

## Not covered

- **Live voice modes** (Gemini Live, OpenAI Realtime). They keep no conversation at all (Plan FF
  keeps live turns in memory only): in a job only the wearer's words reach the job log, outside a job
  nothing is kept, and the assistant's replies are kept nowhere. `TurnRecorder` has no turn
  boundaries there either, so there are no traces and no banner. Planned as Plan
  [FW](FW-live-conversation-keeping.md): an option to keep live conversations, live-turn traces, and
  the learning loops fed from live turns.
- **Audio.** Never kept; the transcript is what the recogniser produced.
- **The full text of the instructions.** Block names and sizes only: the instructions can carry the
  wearer's memories and other context from outside the job.
- **Turn recording switched off** in the Developer panel: no traces.
- **Automatic delivery.** Deliberately none. When the base server exists, the same file can be one
  more upload kind on the job's channel (FU1's file shape), still with the person's consent.

## Tests

`JobTranscriptExportTests` (the transcript and the support report: turns under the lines they
answered, prompt blocks, manual pages, tools, timings, failures, job-log events, outside-job
conversations, unclaimed turns, masking, the no-AI turn; and for one conversation: which thread is
the last, whose lines and turns it holds, its period, the debug-log cut, the job-owned thread, the
unsaved thread, the file's wording, and which scope each entry point opens), `TurnTraceTests` (outcome mapping, dating,
model naming, retention, persistence and erase, the recorder hooks, off-turn isolation, the
banner's words), `DataStoreRegistryTests.testTurnTraceAttributesMatchTheRegistry`.
