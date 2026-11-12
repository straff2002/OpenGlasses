# Plan LM — The Background and Notification Foundation (one background wake for every plan, buttons on a notification, and a record of what really ran)

**Status:** 🚧 P0–P2 built 2026-11-12: written 2026-11-11 in a container with no Swift toolchain, then compiled and tested on a Mac the next day (rebased onto main, one compile fix, Debug tests and a Release simulator build green). P3 is Plan DZ PR6, not started; the P4 device pass is owed. The four new UI strings were synced into the catalog with translations the same day. Drafted the same day
after the owner asked what plans and intentions exist for background refresh and said "sure, then
build it".
**Track:** App-wide infrastructure. Nothing here is a feature a wearer asks for by name.
**Builds on:** `AgentScheduler` and its goal check-ins (Plan [IW](IW-goals-and-activity-trail.md) P2),
`JobSendNotificationRouter` (the app's one `UNUserNotificationCenterDelegate`, Plan FO P3b),
`JSONStore` (Plan [BB](BB-store-integrity.md)), `PrivacyLog` (Plan [DM](DM-privacy-safe-production-logging.md)),
the Developer panel (Plan CL P2).
**Unblocks:** Plan [JO](JO-watchers.md) P2 (its `BackgroundRefreshCoordinator` is this plan), Plan
[GN](GN-agent-notebook.md) P2, Plan [IZ](IZ-product-lookup-and-price-alerts.md)'s background checks,
and the background and notification parts of Plans [KT](KT-cards-ready-to-act.md),
[LD](LD-home-cameras-through-home-assistant.md), [LE](LE-evening-check-in.md),
[LG](LG-reminders-on-a-rhythm.md), [LH](LH-car-routines-with-home-assistant.md) and
[LJ](LJ-tell-me-when-its-for-sale.md).
**Sits beside:** Plan [DZ](DZ-local-gguf-and-durable-agent-runtime.md) PR6 (durable scheduler state —
this plan's P3 is that work, specified there and not repeated here), Plan
[LL](LL-always-on-home-agent.md) (the always-on tier: what must happen at a set minute goes there,
not here).

---

## Why

Nine plans need the app to do a little work while it is not open, and two need a notification the
wearer can answer with a button. Every one of them says the same thing about it:

- JO P2: "one `BGAppRefreshTask` identifier shared with GN's pass through a single
  `BackgroundRefreshCoordinator` — whichever plan lands first builds it, the other plugs in."
- GN P2: the same identifier, a cloud model only, a 25-second budget.
- IZ: "a `BGAppRefreshTask` path is not in v1 (GN decides background refresh for the app as a whole)."
- KT, LD, LE, LG, LH, LJ, LL: there is no `BGTaskScheduler` and no notification action anywhere.

So the foundation sat inside an unscheduled phase of a drafted plan, and every plan that needed it
waited for another to go first. The owner, 2026-11-11, on the question of what we intend: "sure,
then build it."

The honest constraint stays in front: **iOS background refresh is a chance, not a schedule.** iOS
decides when, often runs nothing overnight, and runs less for an app the wearer seldom opens. This
plan builds the one door every plan uses and a record of what actually came through it, so the
device pass can say what the phone tier delivers instead of each plan guessing.

## Outcomes

1. One background wake identifier, registered once, shared by every plan that needs background
   time. A plan joins by adding a participant; it never registers its own task.
2. A participant gets the time it asks for or does not start; nothing runs past iOS's limit, and
   an expired wake stops cleanly.
3. The app asks to be woken only when some participant wants it, never sooner than iOS allows.
4. Every wake is written down — when it came, how long after it was asked for, what ran, how it
   ended — and readable in the Developer panel. That record is the device pass's evidence.
5. Notifications can carry buttons. A plan registers what a button does; the app's one delegate
   routes the press; a tap on a notification still behaves exactly as it does today.

## What exists (verified 2026-11-11 at main 2d936d2)

- **No background execution of its own.** `UIBackgroundModes` in `OpenGlasses/Info.plist` is
  `audio`, `bluetooth-central`, `external-accessory`. There is no `BGTaskScheduler` call, no
  `BGTaskSchedulerPermittedIdentifiers`, no `fetch` mode. The only background-time request is
  `beginBackgroundTask` in `VaultIndexingMonitor` (finishing work already begun) and the turn
  background time of Plan KR P5.
- **Timed work runs only while the process is alive.** `AgentScheduler` uses a `Timer`
  (`agentConnectedInterval` / `agentDisconnectedInterval`); `MyDayScheduledDeliveryService` a
  60-second `Timer`; `ProactiveAlertService` its own timer. The process stays alive in the
  background only while audio keeps it so — the always-on wake word, a live session.
- **Goal check-ins make no model call.** `AgentScheduler.runGoalCheckIns(now:wearerPresent:)` runs
  `GoalCheckInPolicy.run`, files each output in the digest and queues a spoken line only when the
  wearer is present. That makes it the one existing piece of scheduled work that is safe to run in
  a background wake as it stands.
- **One notification delegate.** `JobSendNotificationRouter` is set as
  `UNUserNotificationCenter.current().delegate` in `AppState`; it answers `willPresent` (office
  updates only) and routes a tap's `og_open_tab` to a tab. No `UNNotificationCategory`, no
  `UNNotificationAction`, no `setNotificationCategories` anywhere.
- **The app delegate** (`OpenGlassesAppDelegate`, a `UIApplicationDelegateAdaptor`) has no
  `didFinishLaunchingWithOptions`. `AppState` is a `@StateObject`, so it exists only once SwiftUI
  builds the scene — which a background launch may not do (see P4's first question).
- **The phone-only build** derives its plist from the authored one
  (`Scripts/prepare-phone-only-build.py`), dropping only accessory and Bluetooth modes; `fetch`
  passes through unchanged.
- **Durable scheduler state is Plan DZ PR6, not started.** Scheduled tasks are a `UserDefaults`
  blob (`agentScheduledTasks`); a run's outcome is `completed / deferred / yielded`.

## Design

### The one identifier

`BackgroundRefreshPolicy.taskIdentifier` = `com.openglasses.app.refresh`, listed in
`BGTaskSchedulerPermittedIdentifiers`, with `fetch` added to `UIBackgroundModes`. A guard test
reads the authored plist and fails if either drifts from the constant. No `BGProcessingTask` in
this plan: nothing yet needs minutes of work while charging, and asking for it invites review
questions with no feature to answer them.

### Participants

A participant is a value, not a subclass:

- `id` — a fixed literal (`goal-check-ins`), logged as a token, never wearer content;
- `minimumSeconds` — how much of the wake it needs to start at all;
- `nextWake(now)` — when it next wants a wake, or nil for never (switched off, nothing to do);
- `run(deadline)` — does its work and returns a `BackgroundWorkOutcome`
  (`didWork`, `nothingToDo`, `deferred`, `failed`, `cancelled`).

Rules every participant keeps, stated here so each later plan inherits them:

1. **No model call unless its own plan says so and names the budget.** GN's pass is the only one
   planned with a model; it stays in GN.
2. **Nothing spoken.** A background participant files (digest, queue, trail) or posts a
   notification; it never starts speech, the microphone or the camera.
3. **Cancellation honoured.** A participant checks `Task.isCancelled`; an expired wake cancels it.
4. **Nothing high-impact.** A background wake never runs an action that would ask for confirmation
   in the foreground; it can only prepare it.

### One wake

`BackgroundWorkRunner.run` takes the participants in registration order. For each: skip it
(`notDue`) if `nextWake` is nil or later than now; skip it (`skippedNoTime`) if less than its
`minimumSeconds` remains of the budget; otherwise run it with the overall deadline. The budget is
25 seconds of the roughly 30 iOS gives an app-refresh task, leaving room to write the record and
submit the next request. A cancelled wake marks the remaining participants `cancelled` and stops.

Before running anything the coordinator **submits the next request**, so a wake that iOS kills
still leaves the next one asked for. `BackgroundRefreshPolicy.earliestBeginDate` asks for the
soonest any participant wants, never sooner than 15 minutes from now, and returns nil — no request
at all — when no participant wants a wake.

The request is also submitted whenever the app goes to the background. `BGTaskScheduler.submit`
throws on the Simulator and when the wearer has switched Background App Refresh off; the failure is
recorded, not retried in a loop.

### The record

`BackgroundRunLedger` keeps the last 40 wakes and the last request, in `UserDefaults` through
`JSONStore.decodeArray` (slot `background_runs`). A wake record holds when it started, which
trigger (`systemRefresh` or `manual` from the Developer panel), the earliest-begin date that had
been asked for, each participant's outcome and seconds, the total seconds, and whether it expired.
No wearer content: participant ids are fixed literals and outcomes are an enum. The Developer
panel's **Background Refresh** section lists the lines, the last request, and a **Run now** button
that runs the same pass in the foreground (trigger `manual`) — the only way to exercise it on the
Simulator.

### Notification buttons

`NotificationActionCatalog` declares the categories as values and registers them once at launch
(`setNotificationCategories` replaces the set, so there is exactly one place that calls it). The
first category is `avenkin.ask-until-done` with **Done** and **Stop for today**, which Plan LG's
keep-asking reminders and Plan LE's fallback notification need. A plan that needs a different
button set adds a category here.

A notification that wants a button carries its category and, in `userInfo`, `og_subject` — an
opaque identifier the posting plan owns (a reminder's id, never its text). `NotificationActionHub`
maps a category to a handler. The router's `didReceive` parses the response
(`NotificationActionResponse.parse`): a custom button press goes to the hub; a plain tap
(`UNNotificationDefaultActionIdentifier`) and a dismissal keep today's routing, so every existing
notification behaves exactly as before. A press with no registered handler is dropped quietly —
the hub never guesses.

### Gates

- Background wakes run participants only; with none wanting a wake, the app never asks for one.
- Goal check-ins, the first participant, run only while Agent Mode is on (their own policy checks
  it again) and file into the digest with `wearerPresent: false`, so nothing is said until the
  wearer is back.
- Simple Mode and organisation profiles change nothing here: the participants they would switch
  off are switched off at the participant.

## Phases (one PR)

**P0 — Pure core.** `BackgroundRefreshPolicy` (identifier, budget, minimum interval,
`earliestBeginDate`, `isDue`, `mayStart`), `BackgroundWorkOutcome`, `BackgroundRunRecord`,
`BackgroundRunSummary.line`, `NotificationActionCatalog` and `NotificationActionResponse.parse`.
Headless tests: earliest-begin floor and nil; due and time-left rules; record round-trip and the
40-entry bound; summary lines; catalog ids unique and stable; parse of a button, a tap, a dismissal
and a foreign category. **Written, not yet compiled.**

**P1 — The wake.** `BackgroundWorkRunner` (testable with fake participants and a fake clock),
`BackgroundRefreshCoordinator` (`BGTaskScheduler` registration from
`application(_:didFinishLaunchingWithOptions:)`, the handler, expiration, submit on background and
after each wake), the ledger store, `Info.plist` keys, goal check-ins as the first participant, the
Developer panel section, `PrivacyLog.agent(.background, …)` events. Tests: runner order, skip and
cancel; a participant that overruns cannot hold the record; the plist guard. **Written, not yet compiled.**

**P2 — Notification buttons.** Category registration at launch, `NotificationActionHub`, routing in
`JobSendNotificationRouter.didReceive`. Tests: a press reaches its handler with its subject; a tap
still opens its tab; an unhandled press is dropped. **Written, not yet compiled** — no notification
posts the category yet; LG and LE are its first users.

**P3 — Durable scheduler state.** Plan DZ PR6 as specified there: `SchedulePolicy`,
`AgentScheduleStore`, typed run outcomes, backoff, one catch-up run instead of a storm, run history
in `ScheduledTasksView`. With it, prompt tasks may become a participant — cloud model only,
deferred for a local one, never past the budget. **Not started.**

**P4 — Device pass.** On a real phone, release build, Background App Refresh on:
1. Does a background launch build `AppState` (and so register participants), or does a wake arrive
   with none? The ledger records a wake with no participants as exactly that.
2. After an evening locked on the bedside table: how many wakes overnight, and how long after the
   asked-for time?
3. After a morning unlock: does a wake follow within the hour?
4. With Background App Refresh switched off: the submit failure is recorded and nothing else breaks.
5. The Done / Stop for today buttons from a test notification reach the hub with the app killed.
The answers go into JO's and LE's promise copy. On the Simulator, Xcode's
`_simulateLaunchForTaskWithIdentifier:` debugger command and the panel's **Run now** cover the code
paths, not the timing.

## Decisions for Greig (open)

1. **Ask for a wake only when a participant wants one** (no request at all otherwise)?
   *Recommend yes:* a wake with nothing to do costs battery and earns nothing.
2. **Budget 25 seconds of the ~30 iOS gives.** *Recommend yes;* revisit after P4.
3. **No `BGProcessingTask` until a feature needs minutes of work.** *Recommend yes.*
4. **Goal check-ins as the first participant** (no model, Agent Mode only, digest only in the
   background). *Recommend yes;* it is the only existing scheduled work that is safe as it stands.
5. **The record lives in the Developer panel only**, not the Activity screen. *Recommend yes:* it
   is evidence for us, not a story for the wearer; the participants' own results already reach the
   trail and digest.
6. **One button category now (Done / Stop for today), others added by the plan that needs them.**
   *Recommend yes.*

## Risks

- **Reading the record as a promise.** A good night on one phone says little about another. P4 is
  measured across several nights, and the copy in JO and LE says "usually", never "at".
- **A background launch without the app set up.** If a wake arrives before `AppState` exists, it
  finds no participants and records that. If P4 shows this is common, the fix is to build the
  participants without `AppState` (they need only the goal and task stores), not to force the UI up.
- **One delegate, two jobs.** The router now also routes buttons. Taps keep their old path, pinned
  by the existing tab-routing test and a new one.
- **App Review.** `fetch` with no visible feature can draw a question. The first participant is a
  real feature (goal check-ins reaching the digest), and every later one is.

## Out of scope

Anything that must happen at a given minute (Plan LL, or a system reminder or alarm); push
notifications and APNs; `BGProcessingTask`; background location beyond what Plan JO P2 adds itself;
running a local model in the background (MLX cannot); speaking, listening or using the camera from
a background wake; a wearer-facing settings switch (iOS's own Background App Refresh switch is the
control).
