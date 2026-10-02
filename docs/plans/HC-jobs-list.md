# Plan HC — The Jobs List (and the Model Tile's Provider Mark)

**Status:** ✅ Shipped 2026-10-02 — P0 (pure types) + P1 (views, routing) + the Model tile's mark
in one PR. **Owed (device):** the list with a real week of jobs (the badge scoping, the older
section's paging), VoiceOver through the list, the open-job question and Back, and the provider
mark on the home grid at the default size and at AX sizes.

**Related:** Plan [FO](FO-guided-job-flow-and-job-tab.md) (the Job tab, its pages, the guided job
flow, the send queue, sign-off, debriefs, jobs ahead), Plan [HB](HB-field-assist-mode-and-job-day.md)
(Field Assist mode, the job-day card and its `JobDayComposer` / `JobDayDestination`), Plan
[GW](GW-home-grid-pages.md) (the home grid's tiles).

---

## Trigger

Greig, 2026-10-02:

1. Under the Jobs tab, a **list of jobs** with an **Add new job** action. Selecting a job opens it,
   with a clear way back to the list. Add new job opens a new job exactly as the tab does today.
2. The **Model tile's provider logo** on the home grid is too small beside the other tiles' icons.

## What existed (verified 2026-10-02, main at 38d02f5f)

- The tab (`JobTab`) was **one job at a time**. With no job open it showed (`NoActiveJobView`): the
  staged-send card, the vault in use (→ Field Assist settings), a job-number field and **Start
  job**, the Upcoming section (jobs ahead → their page; "Add an upcoming job"), "Send today's
  conversations…", and every finished job newest first with a search by number/machine/vault and
  "Export a day…". With a job open it showed **only that job** (`ActiveJobView`): the send card,
  the two question cards, number, time, unit, work, photos and clips, Open conversation, Read back,
  Close job. Finished and upcoming jobs were reachable only once the job was closed. A finished job
  (`PastJobView`) and a job ahead (`UpcomingJobView`) were pushed on the tab's stack.
- One job is open at a time: `FieldSessionService.startSession` throws `alreadyActive`; a job ahead's
  Start is refused while one is open (`UpcomingJobsModel.startBlockedReason`); HB's scenarios run
  in the open job or are refused, never end it.
- Routes into the tab only **selected** it (`appState.requestedTab = .job`): the day view's open-job
  row, the Field Assist tab's Resume / Start a job and a scenario start, the staged-send
  notification (`JobSendNotificationRouter`), an accepted job file. The day view pushed finished and
  upcoming jobs on **its own** stack inside its full-screen cover. No URL or App Intent opens a job.
- The Model tile drew `ProviderMark-<provider>` into a 28 pt square (`DockGridMetrics.markGlyphBox`,
  a `@ScaledMetric` relative to `.title2`, so it already tracked Dynamic Type and GW's compressible
  tiles — compression takes padding, never the glyph box).

## Decisions

1. **Sections and order** (`JobListComposer`), top to bottom:
   - the **staged-send card** (unchanged, first, as on every Job tab screen since FO P3b);
   - **Open job** — the one open job, running or paused, with any to-do badges;
   - **Add new job** — prominent while nothing is open, a plain row beside an open job;
   - **Scheduled** — every job ahead, soonest first (`UpcomingJobStore.ordered`): an overdue one
     (scheduled on an earlier day, never started — HB's rule) is kept, flagged and naturally first;
     undated ones last. Detail reads "Today 2:30 PM", "Sat 3 Oct, 9:00 AM", "Was due …" or
     "No date set"; a job file's signature line is kept;
   - **Recent** — finished in the last **7 days** (today and the six before; the same span HB keeps
     a failed send owed), newest first, footer "N still have something to do";
   - **Older jobs (N)** — everything before that, **folded** by default and **paged 25 at a time**
     ("Show 25 more"); its header counts the ones with something still to do;
   - **Send today's conversations…** and **Export a day…**, moved from the old empty state.
   - **Search** (`.searchable`, "Search by job number, customer or machine") covers every job —
     open, scheduled and finished — by number, customer, site, machine and vault; results keep the
     sections' order. A technician doing five jobs a day has a thousand a year; the old past-job
     search was by number and machine only.
   - **Empty**: "No jobs yet" with the voice route, and Add new job.
2. **Badges reuse the job-day card's rules** — `JobDayComposer`'s to-do derivation is now one shared
   function, `JobDayComposer.owed(sessions:finishedInScope:queue:debrief:signOffRequired:now:)`, and
   each `JobDay.Todo` carries its `sessionId`. The card calls it with today's jobs; the list with
   every job, and the **recent** finished ones in scope for "report not sent" and "sign-off owed".
   Badges: Debrief not saved · Report didn't send (warning) · Report ready to send · Report not sent
   · Sign-off owed (only when the organisation requires it) · Parts request(s) waiting · Overdue
   (warning, jobs ahead). One badge per kind per job. **Older jobs never badge "report not sent"** —
   HB left them to this tab, but many organisations never send some jobs, and a history that grew
   into a to-do list would be noise; a failed send (seven-day window) and open parts requests still
   badge wherever the job sits. A cancelled visit owes no report.
3. **Selecting a job pushes its existing page** over the list — `ActiveJobView`, `PastJobView`,
   `UpcomingJobView`, unchanged — and standard Back returns to it. The open job's page and the
   start page are **one route** (`JobRoute.currentJob`): with no job open it is the start page
   (`NewJobView`: the vault in use, the number field, **Start job**, and "Schedule a job for later"
   with the voice and job-file hints the old Upcoming footer carried); Start turns it into the job in
   place, exactly as the tab always behaved; a job closed by voice while it is on screen turns it
   back. Closing a job **replaces** its page with the finished job's (record, Send report), so Back is
   the list; starting a job ahead lands on the job.
4. **Add new job with a job already open asks** (`JobListAdd`, `OpenJobPrompt`): "Job 1005 is still
   open — One job is open at a time. Finish it before starting another, or schedule the new job for
   later. Nothing is closed for you." Answers: **Resume Job 1005** (its page), **Finish Job 1005…**
   (its page, then the job's own Close job — the same confirmation, evidence review and sign-off;
   backing out of any of them leaves it open), **Schedule a job for later** (the add-a-job-ahead
   sheet, which needs nothing closed), Cancel. **Nothing ends a job from this button** — the defect
   HB fixed for scenarios. Pausing is not an answer: a paused job is still the open job (FO P1), so
   it would not let another start.
5. **Links into a job** (`JobListRequest`, `JobListRouting`, `AppState.openJobs(_:)`): every surface
   that sends the technician to a job sets a request and selects the tab; the tab resolves it
   against what is on the phone **at that moment** and **replaces** its stack, so Back is always the
   list:
   - `.list` — the staged-send notification (the card is on the list) and "Show upcoming jobs" after
     a job file is accepted;
   - `.currentJob` — Resume on the Field Assist tab, a scenario just started, the day's open-job row;
     with nothing open: the list, "No job is open right now.";
   - `.newJob` — "Start a job" on the Field Assist tab: the start page, or the open-job question;
   - `.session(id)` — the open job's page when it is the open one, a finished job's page otherwise,
     or the list with **"That job is no longer on this phone."**;
   - `.upcoming(id)` — its page, or "That job is no longer scheduled. It may have been started or
     removed." (A started job ahead leaves the store and carries no link to its session.)
   The notice sits at the top of the list with Dismiss, and clears on the next tap.
6. **The day view's rows now leave it** (HB's routes): a job opens in the Jobs tab over the list —
   one home for a job's page, so Send report, sign-off and debrief are in the same place however the
   job was reached, and Back shows every job with this day's admin flagged on it. A report row still
   opens its composer in place. (HB pushed finished and upcoming jobs inside the cover; that second
   stack is gone.)
7. **Unchanged:** `JobTabPresence` (when the tab exists), the edition's and lockdown's tab rules
   (HA/HB), the tab's title "Jobs", the job pages themselves, the close sequence, CarPlay's and the
   watch's read-only job lists.
8. **The Model tile's mark.** The cause was the **artwork**, not the frame: the OpenAI and ChatGPT
   marks carried the brand's clear space inside a 716-unit viewBox — the ink was half the square,
   so the mark drew at about 14 pt beside a 22 pt camera — and seven of the 24-unit marks
   (Gemini, Gemini Vertex, Groq, Minimax, OpenRouter, Qwen, xAI) wrote SVG arc flags run together
   (`a.503.503 0 00-.975 0`), which browsers accept and the system's renderer does not: **Gemini
   drew as a sliver**. Fixes: the OpenAI/ChatGPT viewBox is cropped to the artwork
   (`180 180 356 356`); every mark's path data is respaced (pixel-identical in a browser render
   before and after). The frame stays `DockGridMetrics.markGlyphBox` (a `.title2` scaled metric),
   which already tracks Dynamic Type and the compressible tiles; its doc now states the artwork's
   side of the contract, and `ProviderMarkArtworkTests` renders every bundled mark and measures its
   ink (draws at all, fills ≥ 80% of the square, centred). The Avenkin mark draws through
   `LogoIcon`, untouched.

## P0 — pure types

| Type | File | API |
|---|---|---|
| `JobRoute` | `Services/FieldAssist/Job/JobList.swift` (moved from `JobTab.swift`) | `.currentJob`, `.pastJob(sessionId:)`, `.transcript(threadId:)`, `.upcomingJob(id:)` |
| `JobListComposer` / `JobList` | same | `compose(JobListInputs) -> JobList` (`open`, `scheduled`, `recent`, `older`, `results`, `isEmpty`, `recentAttention`, `recentFooter`, `olderTitle`); `JobList.Item` (`route`, `title`, `detail`, `note`, `status`, `badges`, `spoken`); `JobList.Badge.Kind`; `page(_:pages:)`, `recentDays` = 7, `olderPageSize` = 25 |
| `JobListAdd` / `OpenJobPrompt` | same | `decide(openJobLabel:)` → `.startNew` / `.jobOpen(prompt)`; prompt copy; `step(_ answer:)` → `path`, `beginsClose`, `schedules` |
| `JobListRequest` / `JobListRouting` | same | `.list` / `.currentJob` / `.newJob` / `.session(id:)` / `.upcoming(id:)`, `init?(JobDayDestination)`; `resolve(_:_ Facts) -> Outcome(path, notice, prompt)` |
| `JobDayComposer.owed` | `Services/FieldAssist/Job/JobDay.swift` | the card's to-do rules over caller-scoped sessions; `JobDay.Todo.sessionId` |
| `JobListFeed` | `Services/FieldAssist/Job/JobListFeed.swift` | gathers the facts (report-sent read once per recent session, forgotten when a send moves), re-composes on change and on the minute; `query`; `routingFacts` |

## P1 — views and wiring

- `JobTab`: the stack's root is `JobListView`; `.currentJob` draws `NewJobView` or `ActiveJobView`;
  consumes `AppState.jobListRequest`; the open-job question; close lands on the finished page.
- `JobListView` (new), `NewJobView` (was `NoActiveJobView`, now only the start page).
  `UpcomingJobsSection` and `UpcomingJobsModel.rows` removed (the list draws jobs ahead).
- `AppState.openJobs(_:)` / `jobListRequest`; the staged-send notification router, the job-file
  sheet, `VoiceTab`'s day-view hand-off and `FieldAssistModeTab` route through it.
- `JobDayView`: every row leaves the cover.
- `BottomControlBar`/`HomeGridCatalog`: unchanged rendering, documented contract; the ten
  `ProviderMark-*.imageset/mark.svg` files fixed.
- UI-test launch value `-OGUITestModelProvider <provider>`: a keyless model of that provider, active,
  so the Model tile wears its mark in a screenshot.

## Tests

`JobListComposerTests` (sections and order, the recent boundary, statuses and details, each badge
and its scope, agreement with the card, search across sections, paging), `JobListRoutingTests`
(Add new job with and without an open job, each answer, each request incl. a vanished job, every
link one page deep, the day card's routes, the notification), `ProviderMarkArtworkTests`; the
refactored `JobDayComposerTests` unchanged and green. UI: `JobTabAccessibilityTests` updated (the
open job is pushed from its row; the empty list → the start page) plus the list with open,
scheduled and finished jobs and Back, and Add new job with a job open; `FieldAssistModeUITests` gains
a day-view row opening over the Jobs list; `JobSignOffScreenshotTests` reaches the open job from
the list.

## Tests (as run)

New: `JobListComposerTests` (20), `JobListRoutingTests` (11), `ProviderMarkArtworkTests` (3 — it
fails on main's artwork: OpenAI at 50% of its square, Gemini a sliver). Focused classes (the new
three plus `JobDayComposerTests`, `JobTabModelTests`, `JobTabPresenceTests`, `GuidedJobFlowTests`,
`JobFlowPolicyTests`, `FieldSessionServiceTests`, `FieldAssistModeTests`, `EditionPresentationTests`,
`MainTabTests`, `DockLayoutTests`, `DockPagerTests`, `HomeGridPagingTests`, `HomeGridTests`,
`JobAheadTests`, `JobAheadFlowTests`, `JobFileTests`) green, then the whole `OpenGlassesTests` suite:
8718 tests, 0 failures, 13 skipped. UI: `JobTabAccessibilityTests` (15, incl. the two new list
tests), `FieldAssistModeUITests` (4, incl. the day-view row), `JobSignOffScreenshotTests` (10),
`JobDebriefScreenshotTests` (7) — 36 green (three fixed and re-run: a navigation title now also
says "Job 1005", the empty-list assertion depended on what earlier runs left in the simulator's
session store, and the list's rows under a tall send card are not built until scrolled to).

**Simulator (iPhone 17 Pro, default text):** the list reads Open job (Job 1005 · In progress ·
"Started 4:19 PM · Refrigeration Service"), Add new job, Scheduled (Jobs 1006/1007 "Today …", 1008
"Sat, 3 Oct at 9:00 AM"), Recent (Job 1004 · Resolved · "Report not sent", footer "1 still has
something to do"), then Send today's conversations and Export a day. Add new job with 1005 open
raises "Job 1005 is still open" with Resume / Finish Job 1005… / Schedule a job for later; Resume
pushes the job's page (title "Job 1005") and Back returns to the list with the job still in
progress. A finished job's page opens from Recent with Back to the list. Fresh install: "No jobs
yet" with the voice hint and a prominent Add new job; Add opens "New job" (vault, number, Start
job, Schedule a job for later). From the day view, Job 1006 opens its page in the Jobs tab (tab
selected) and Back lands on the list. Model tile: before, OpenAI's mark drew at about half the
camera's size and Gemini's as a small sliver; after, OpenAI, Anthropic, Gemini and xAI all draw at
the camera and keyboard symbols' size.
