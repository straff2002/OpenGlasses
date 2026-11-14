# Plan LE — The Evening Check-in (what's still waiting on your reply, decision or approval)

**Status:** 🚧 P0 and P1 built 2026-11-14 (headless). P0: `OpenLoop` and its fourteen sources (the five
§10 job sources among them), `OpenLoopCollector`, `OpenLoopPhraser`, `OpenLoopDismissals`, held trail
entries that resolve, and `.checkIn` as a third `MyDayDeliveryPolicy` slot. P1: a reader over every store
that has a producer (the trail, Reminders, goals, the digest, the agent queue and the five job rows), held
entries matched to their later answer by a hold key, the dismissal and said-today store, the check-in
delivered at its time (merged with the evening, silent when empty, shown not spoken while driving), its
settings rows, `activity waiting`, and My Day's **Waiting on you** section. See [As built](#as-built). P2
(the content-free notification, the Display card, the watch line, the KH scenario) is next; the spoken
"Want to deal with the first one now?" is held for it. Drafted 2026-11-11. All eight
[decisions](#decisions-for-greig-taken-2026-11-12) taken as recommended on 2026-11-12. Whether the
"check-in is ready" notification carries Plan [LM](LM-background-and-notification-foundation.md)'s buttons
(drafted before LM existed) waits for LM's device pass. **Amended 2026-11-14:** the owner asked whether it
would help a Field Assist technician at the end of the day; it would, with the job's own loose ends as
sources. [§10](#10--field-assist-the-end-of-the-shift) and decisions 9–11 add them, in the same phases.
**Track:** Everyday assistant. Phone and spoken audio first; the Display and the watch follow.
**Builds on:** Plan [DY](DY-my-day-everyday-briefing.md) (`MyDayDeliveryPolicy`, `MyDayScheduledDeliveryService`,
quiet hours, `MyDaySpeechPolicy`), Plan [IW](IW-goals-and-activity-trail.md) (`ActivityStore`, `ActivityPhraser`,
`ActivityOutcome.waitingOnYou`, `GoalStore`, the `activity` tool), Plan [BZ](BZ-notification-digest.md)
(`NotificationDigestService`, `NotificationPriority`), `AgentNotificationQueue`, `EventKitDayStore`.
**Sits beside:** Plan [KT](KT-cards-ready-to-act.md) (prepared cards and drafts not yet sent), Plan
[KI](KI-tasks-that-wait.md) (tasks waiting on someone else), Plan [JO](JO-watchers.md) (watcher findings), Plan
[LG](LG-reminders-on-a-rhythm.md) (reminders that keep asking). None of those is built; each becomes a source
here when it lands. Sibling plans drafted the same day: [LD](LD-home-cameras-through-home-assistant.md),
[LF](LF-coupon-wallet.md), [LH](LH-car-routines-with-home-assistant.md), [LI](LI-where-things-are-kept.md),
[LJ](LJ-tell-me-when-its-for-sale.md), [LK](LK-reading-mail-the-decision.md),
[LL](LL-always-on-home-agent.md).

---

## Trigger

On 2026-11-11 the owner shared an example list of routines a cloud personal agent runs. One of them is
a nightly check at 9 PM that lists anything from the day still waiting on the person's reply, decision or
approval. It is a small routine and probably the one people would keep: the day's loose ends, said once,
at a time when they can still be dealt with.

Avenkin has most of the pieces and never puts them together:

- My Day already has an **evening slot**, but it looks forward: "Here is what matters before tomorrow."
  It names tomorrow's first event and what to prepare. It does not list today's loose ends.
- The activity trail can already say "One thing is waiting on you", but only inside an answer to "what
  have you done today?" or "what's next?". Nothing says it unprompted.
- Goal steps, reminders and the digest each know what is overdue or unread. Each is read on its own
  screen.

## Outcome

- With **Evening check-in** on (off by default), at the chosen time (default 21:00):
  - "Three things are still waiting on you: your OK to send the message to the plumber, the 'renew the
    registration' reminder, and the next step of 'clear the garage'. The rest are on your phone."
  - When nothing is open: silence. The check-in is not a ritual; it speaks only when there is something to
    say (decision 4).
- "What's waiting on me?" asked at any time gives the same list, and says "Nothing is waiting on you" when
  it is empty.
- The My Day screen shows the same list as a **Waiting on you** section, with each row's own action:
  approve or decline, complete the reminder, mark the step done, dismiss.
- Each item is said once a day. An item dismissed tonight does not come back tomorrow unless it changes.
- The timing is honest. If the app is not running at 21:00, a plain notification says "Your evening
  check-in is ready" (decision 3); the list is read when the wearer opens it or next talks to the
  assistant within the delivery window.

## What exists, and what doesn't

**Exists (verified 2026-11-11 at main `2d936d2`):**

- `MyDayDeliveryPolicy.decide(now:calendar:settings:context:lastMorningDayKey:lastEveningDayKey:)`
  (`Services/MyDay/MyDayDelivery.swift`) picks a `MyDayDeliverySlot` (`.morning`, `.evening`) once per
  day key, within `deliveryWindowMinutes` (120) of the set time. It defers for protected data, quiet
  hours and source access, and speaks only when the wearer is present, power is not `.reserve`, the
  phone is online and the wearer is not busy. Quiet hours default 22:00–07:00 (`MyDayConfig`).
- `MyDayScheduledDeliveryService` runs that policy from a 60-second `Timer`, so **only while the process
  is alive**. It calls `MyDayService.spokenBriefing(now:channel:)` and hands the text to `onDelivery`.
  It does not use `AgentScheduler` and does not need Agent Mode.
- The evening slot is off by default at 19:00 (`myDayEveningDeliveryEnabled`,
  `myDayEveningDeliveryMinutes`). `MyDayComposer` treats 18:00 onwards as `MyDayPeriod.evening` and adds
  tomorrow's first event and a preparation item; its headline is "Your evening is clear." or "Here is
  what matters before tomorrow."
- My Day sources (`Services/MyDay/MyDaySources.swift`): `CalendarDaySource`, `RemindersDaySource`
  (`loadReminders`, `completeReminder`), `WeatherDaySource`, `TravelTimeDaySource`, `DigestDaySource`,
  `GoalsDaySource` (`GoalStoreDaySource`, `nextSteps`, `completeGoalStep`). `MyDayGoalStep` carries a
  `dueAt`.
- The activity trail (`Services/Activity/`): `ActivityEntry` with `ActivityOutcome` (`done`, `failed`,
  `uncertain`, `waitingOnYou`). `ActivityRecorder` writes a `.held` entry titled "Your OK to use the …
  tool" with `outcome: .waitingOnYou` when a tool call is held for the wearer. `ActivityPhraser` has
  `waitingSentence(_:)` ("Nothing is waiting on you." / "One thing is waiting on you: …") and
  `whatsNext(goals:scheduled:entries:)`. Retention is 14 days (`ActivityRetention`).
- `ActivityTool` (`activity`): `today`, `this_morning`, `since`, `next`. `next` includes entries waiting
  on the wearer from the last 24 hours.
- `NotificationDigestService` (`Services/Digest/`): `items: [DigestItem]` with `seenCount`, `topLine`,
  `presentGlance`, `dismissItem(id:)`; ranking by `DigestRanker` and `NotificationPriority`.
- `AgentNotificationQueue`: queued agent results with `delivered` and `pendingCount`, delivered on
  reconnect.
- `HeldRecommendationStore` (Plan W): in memory, cap 10, drained into one sentence when the wearer
  re-engages (`drainSummary`).
- `EventKitDayStore.incompleteReminders()` and `completeReminder(id:)`; `AppleRemindersTool` (`reminder`)
  creates, lists and completes.
- `ScenarioCatalog` (Plan KH) for "things to try".

**Doesn't exist:**

- **A held entry never resolves.** Once written, a `.held` trail entry stays `waitingOnYou` whether or
  not the wearer later approved or declined; `ActivityTool`'s `next` simply stops showing it after 24
  hours. A check-in that read it as is would nag about things already answered.
- Any list of open loops across sources, any third delivery time, or any on-demand "what's waiting on
  me?" outside the `activity` answers.
- Background delivery. There is no `BGAppRefreshTask` in the app; JO P2 names a
  `BackgroundRefreshCoordinator` that is not built.
- Producers for KT drafts, KI waiting steps, JO findings and LG asks. All four plans are unbuilt.
- Notification actions. The app registers no `UNNotificationCategory`.

## Design

### 1 · An open loop (`OpenLoop`, pure)

```
struct OpenLoop: Identifiable, Equatable, Sendable {
    let id: String              // source-prefixed and stable: "held:<entry id>", "reminder:<EK id>"
    let source: OpenLoopSource  // .approval, .reminder, .goalStep, .digest, .agentResult,
                                // .draft (KT), .waitingOnOthers (KI), .watcherFinding (JO), .askAgain (LG)
    let title: String           // already in the wearer's words where the source has them
    let since: Date             // when it started waiting
    let dueAt: Date?            // when it is due, if it has a date
    let action: OpenLoopAction  // .approve(ref), .complete(ref), .stepDone(ref), .open(ref), .dismiss
    let fingerprint: String     // what "it changed" means for the once-a-day rule
}
```

Each source adapts its own records into `OpenLoop` behind a small protocol, `OpenLoopSourceReading`,
in the same shape as the My Day sources. A source that cannot be read reports itself unavailable and the
check-in says so on the phone, never by inventing an empty list.

### 2 · What counts (`OpenLoopCollector`, pure)

Only things waiting on the **wearer**, plus one narrow exception.

| Source | Counts when | Today |
|---|---|---|
| Approval | a trail `.held` entry with no resolution, from today or yesterday | built, needs §3 |
| Reminder | incomplete, due today or overdue | built |
| Goal step | next step of an active goal, due today or overdue | built |
| Digest | `actionable` or higher, never seen, not dismissed | built |
| Agent result | queued and not delivered | built |
| Draft (KT) | a prepared card with a draft the wearer opened and did not send | when KT lands |
| Waiting on others (KI) | a task step waiting on someone for longer than the threshold (decision 5) | when KI lands |
| Watcher finding (JO) | filed to the digest and never heard | when JO lands |
| Ask again (LG) | a keep-asking reminder still not confirmed | when LG lands |
| Job report (Field Assist, §10) | a staged report in the delivery queue that was never sent, or whose send failed | built |
| Job close held (§10) | a job whose close is held, such as for the customer's sign-off | built |
| Parts request (§10) | a parts request on today's work that was never sent | built |
| Deferred task (§10) | a work task the technician deferred and did not finish | built |
| Expert or escalation (§10) | a hand-off or escalation still waiting on its answer | built |

Rules, applied in order:

1. Drop anything dismissed from the check-in today, unless its `fingerprint` changed since.
2. Drop anything that will be in tomorrow's morning briefing as a dated item for tomorrow (the evening
   check-in is about today; tomorrow is My Day's job).
3. Merge duplicates: a reminder that is also a goal step's action counts once, as the goal step.
4. Rank: approvals first (someone or something is blocked on them), then the job's loose ends (§10: an
   unsent report, a held close, an unsent parts request, a deferred task, an unanswered hand-off, in that
   order), then overdue items oldest first, then due-today items by due time, then undated items by
   `since`. Ties by source order in the table.

### 3 · Held approvals resolve (`ActivityResolution`)

`ActivityEntry` gains an optional `resolvedAt` and `resolution` (`approved`, `declined`, `expired`). The
recorder sets it when the held operation later reaches the authorization boundary again (approved or
declined through `ToolConfirmationCoordinator`), and an entry older than its operation's own expiry is
`expired`. `ActivityPhraser` and `ActivityTool` then read only unresolved entries as waiting. P0 also checks
whether a Plan W ceiling hold writes a `.held` trail entry; if it does not, it should, so that a suggestion
held while the wearer was away is still visible after `drainSummary` has spoken and cleared it.

### 4 · When it is said (`MyDayDeliveryPolicy` gains a third slot)

`MyDayDeliverySlot` gains `.checkIn`. The policy already loops over candidate slots; the check-in is one more
candidate with its own enabled flag, time (default 21:00) and last-delivered day key. Everything else is
the same policy: once a day, the 120-minute window, quiet hours, presence, power, online and busy. It does
not go through `AgentScheduler` and does not need Agent Mode, because nothing in it calls a model and it
reads only the wearer's own data.

If the evening slot and the check-in fall within 30 minutes of each other, they are delivered as one: the
check-in list first, then "Tomorrow starts with …".

### 5 · When the app isn't running (`CheckInNotification`)

The timer only runs while the process is alive. When the check-in is turned on, the app schedules one
repeating local notification at the check-in time with fixed, content-free text: "Your evening check-in is
ready." (decision 3). Opening it, or the first wake word or foreground within the delivery window, runs the
check-in. If the check-in already ran tonight while the app was alive, the evening's notification is
removed. It never contains the list itself: it is scheduled in advance, so its content would be stale,
and the list can name other people.

### 6 · What is said (`OpenLoopPhraser`, pure)

- Templates only, in the style of `ActivityPhraser` and `GoalPhraser`. No model call in v1 (decision 8).
- At most four items spoken (decision 6), within `MyDaySpeechPolicy`'s ceiling; the rest "are on your
  phone".
- The count is always said first and is exact.
- Empty: the scheduled check-in says nothing; the on-demand question says "Nothing is waiting on you."
- After the list, a single question if the first item is an approval: "Want to deal with the first one
  now?" A yes runs that item's own confirmation as it would have run when it was held. Nothing is approved
  by the check-in itself.

### 7 · Asked for ("what's waiting on me?")

`ActivityTool` gains an action `waiting` that reads the collector and phrases it the same way. The tool
description lists the phrasing ("what's waiting on me?", "what do I still need to do today?", "anything I
haven't answered?"). Asked before the check-in time, it lists the same sources; asked after, it also marks
the day's items said.

### 8 · Surfaces

- **Phone:** a **Waiting on you** section in My Day, visible in the evening period and whenever the list is
  non-empty after the check-in time, with each row's action and a swipe to dismiss for tonight.
- **Display (P2):** one card, the count and the first item, with KP's page turn for the rest.
- **Watch (P2):** a line in the Today payload (Plan KS) when the check-in has items.

### 9 · Privacy and cost

Everything is read from stores on the phone. No network, no model, no new data kept beyond a per-day set of
dismissed fingerprints (`OpenLoopDismissals`, in the style of `MyDayDismissals`). With Medical Compliance or
local-only modes on, nothing changes, because nothing leaves the phone. The notification text names nothing.

### 10 · Field Assist: the end of the shift

For a technician the day's loose ends are the job's, and they cost money when they wait: a report the office
never received is a job nobody invoiced, and a part nobody ordered is a second visit. Field Assist already
keeps each of them on the phone; the check-in reads them as five more sources behind the same
`OpenLoopSourceReading` protocol, with the same once-a-day rule, dismissals and four-item limit.

- **Sources** (the rows marked §10 in the table in §2): the delivery queue's staged or failed job reports
  (`DeliveryRequest`, `DeliveryQueue`), a held job close (`jobCloseHeld`, `customerSignOffRequired`), a
  `PartsRequest` not `sent`, a `WorkTask` still `deferred`, and an expert hand-off or escalation with no
  answer. Each names the job the way the job's record already names it (its reference or customer as the
  technician entered it), so "the report for the Smith job isn't sent". P0 verifies each store's real
  shape before the adapter is written in P1; a source the record cannot answer is left out and said so here.
- **When.** With Field Assist on, the check-in's default time is **17:00** (decision 9), set in the same row.
  A trigger on the last job's close is not in v1: the app cannot know a close is the day's last.
- **Driving.** When the motion reading is `automotive` at the check-in time (`MotionActivityProvider`), the
  check-in is not spoken: it shows on the phone (and the content-free notification if the app is not in
  front), and is spoken only when asked (decision 10). The same rule holds for the everyday check-in.
- **Words.** "Two things before you finish: the report for the Smith job isn't sent, and the filter for
  Jones is still not ordered." The opener is "before you finish" with Field Assist on and "still waiting on
  you" otherwise.
- **Action.** Each row opens its own place (the report composer, the job, the parts request); nothing is
  sent or closed by the check-in itself (§6's rule).
- **Privacy.** Job titles and customer names stay on the phone and in speech, never in the notification,
  which stays content-free. A Medical Local Only profile changes nothing, as nothing leaves the phone.

## Decisions for Greig (taken 2026-11-12)

All eight taken as recommended.

1. **A separate check-in time, not a change to the evening briefing.** The evening slot looks at tomorrow;
   the check-in looks at today. Merge them only when they fall within 30 minutes. (Alternative: replace
   the evening slot's content.)
2. **Off by default**, offered from My Day's settings and as a Plan KH scenario ("Hear what's still waiting
   on you each evening").
3. **A content-free notification at the time** when the app isn't running, scheduled with the setting and
   removed when the check-in already ran. (Alternative: no notification, and accept a missed evening.)
4. **Silent when empty.** On demand still says "Nothing is waiting on you."
5. **Waiting on others counts only after 5 days** with no reply, and is worded as "No reply yet from …".
6. **Four items spoken**, the rest on the phone.
7. **No Agent Mode requirement.** It reads the wearer's own data and calls no model.
8. **Templates only in v1.** A digest-style rewrite (`DigestLineBuilder`) can follow if the templates read
   badly on the device.

Added 2026-11-14 with §10, taken as proposed when the owner asked for the Field Assist sources:

9. **With Field Assist on, the default time is 17:00**, the end of a working day, changeable in the same row.
   (Alternative: a trigger on the last job's close, which the app cannot tell apart from any other close.)
10. **Not spoken while driving.** An `automotive` reading at the time shows it on the phone and waits to be
    asked. (Alternative: speak it anyway, as the glasses are hands-free.)
11. **The five job sources rank straight after approvals**, report first. (Alternative: rank them with the
    rest by date.)

## Phases (one PR each)

### P0 — the pure core (headless)

- `OpenLoop`, `OpenLoopSource`, `OpenLoopAction`, `OpenLoopCollector` (the rules in §2), `OpenLoopPhraser`,
  `OpenLoopDismissals`.
- `ActivityEntry.resolvedAt`/`resolution`, decoding old entries unchanged; `ActivityPhraser` and
  `ActivityTool.next` read only unresolved held entries.
- `MyDayDeliverySlot.checkIn` in `MyDayDeliveryPolicy`, with the merge rule.
- §10: the five job sources in `OpenLoopSource` and the collector's ranking; the 17:00 default with Field
  Assist on; the driving rule as a policy outcome (show, don't speak); the "before you finish" wording. Each
  job store's shape checked, and the As built notes say which records answer which row.
- **Exit tests:** a held entry approved later is not listed; a dismissed reminder stays out tonight and
  returns only when its due date changes; a reminder that is also a goal step's action counts once;
  tomorrow-dated items are left to the morning; the empty scheduled check-in returns nothing to say; four
  spoken, "the rest are on your phone"; quiet hours defer; the evening and check-in merge inside 30 minutes
  and not at 31; the policy never delivers twice for one day key; an unsent report ranks after an approval
  and before an overdue reminder; with Field Assist on the default time is 17:00; an `automotive` reading
  shows the list and speaks nothing.

### P1 — wired (headless)

- Source adapters over `ActivityStore`, `EventKitDayStore`, `GoalStore`, `NotificationDigestService` and
  `AgentNotificationQueue`, and the §10 job stores.
- The recorder resolves held entries at the confirmation boundary; a Plan W hold writes a trail entry if it
  does not already.
- `MyDayScheduledDeliveryService` delivers the third slot; settings rows (on/off, time) under My Day.
- `activity` action `waiting`; the My Day **Waiting on you** section with row actions.

### P2 — the notification and the other surfaces (headless)

- `CheckInNotification` scheduling and removal; opening it runs the check-in.
- The Display card and the watch Today line.
- The KH scenario.

### P3 — device pass (owed)

- A real evening: two held approvals (one answered later), one overdue reminder and one goal step; the
  check-in at 21:00 with the app alive, and again with the app killed (the notification, then the list on
  open).
- Quiet hours at 21:30 defer it; "what's waiting on me?" at 16:00 gives the list.

## Risks

- **It turns into a nag.** Silent when empty, once a day, four items, dismissals that stick. The same
  item every night for a week is a sign the source's rule is wrong, not that the wearer needs telling
  again; the device pass checks a week of it.
- **Stale or wrong items.** The resolution fix in §3 is the guard for approvals; every other source is read
  fresh at delivery time, never from a cache filled earlier in the day.
- **Phone timing.** The notification is the honest floor. A minute-exact spoken check-in with the app
  killed needs the always-on tier in [LL](LL-always-on-home-agent.md).

## Out of scope

- Mail. Unanswered email is not a source; see [LK](LK-reading-mail-the-decision.md).
- Other apps' notifications or messages (iOS does not allow reading them).
- Approving, sending or completing anything from the check-in without the item's own confirmation.
- Inferring open loops from conversation ("you said you'd call the plumber"). That is Plan
  [GN](GN-agent-notebook.md)'s notebook, which can become a source when it lands.

## As built

### P0 — 2026-11-14 (headless)

**Files.** New, under `OpenGlasses/Sources/Services/MyDay/CheckIn/`:

- `OpenLoop.swift` — `OpenLoopSource` (the table's fourteen rows in table order, which is the last
  tie-break; `jobOrder` for the five §10 rows; `hasProducer` false for KT/KI/JO/LG), `OpenLoopPlace`
  (reuses the job day's `JobDayDestination` for the report composer, the job and the parts order),
  `OpenLoopAction` (`approve`, `complete`, `stepDone`, `open`, `dismiss`), `OpenLoopJobName`
  (`customer` / `reference`, as the record has it), `OpenLoop`, `OpenLoopReading` (`read` /
  `unavailable`) and the `@MainActor` `OpenLoopSourceReading` protocol. A reader names the sources it
  answers for, and an unreadable reader reports all of them.
- `OpenLoopCollector.swift` — `OpenLoopCollection` (ranked loops plus the unreadable sources),
  `collect(_:unavailable:dismissed:now:calendar:)`, `collect(readings:…)` and an async `gather(_:…)`
  that reads every reader fresh.
- `OpenLoopPhraser.swift` — `OpenLoopPhrase` (`text`, `spokenCount`, `offersFirst`) and the templates.
- `OpenLoopDismissals.swift` — the per-day `loop id → fingerprint` record (`active`, `adding`,
  `isDismissed`), using `MyDayDismissalPolicy.dayKey`.
- `OpenLoopApprovals.swift` — the approval row as a pure mapping from trail entries: `.held`, unresolved,
  from yesterday's start to now. P1's `ActivityStore` reader hands its entries here.

Changed: `ActivityEntry.swift` (`ActivityResolution`, `resolvedAt`, `resolution`, `isAwaitingWearer`,
`resolved(_:at:)`), `ActivityPhraser.swift` and `ActivityTool.swift` (`next`) read only
`isAwaitingWearer`, `MyDayDelivery.swift` (the slot, `MyDayCheckInDefaults`, the settings and context
fields, the merge and the driving rule) and `MyDayConfig.swift` (`myDayCheckInEnabled`, `myDayCheckInMinutes`,
`myDayLastCheckInDeliveryDay`, cleared by `resetMyDayDeliveryHistory()`). Tests: `OpenLoopCollectorTests`,
`OpenLoopPhraserTests`, `OpenLoopDismissalsTests`, `ActivityResolutionTests`, `MyDayCheckInDeliveryTests`.

**Decided while building.**

- **`OpenLoop` carries more than §1 sketched:** `subject` (the goal for a step, the person for KI,
  the expert for a hand-off), `job` (`OpenLoopJobName`), `failed` (a send that failed ranks first in its
  source and is said as "didn't send"), and `covers` (rule 3: a goal step lists the reminder loop its
  action set). The default fingerprint is title, due time and the failed flag.
- **Rule 3's pairs are found before rule 1 drops anything,** so clearing a goal step tonight keeps its
  reminder out too instead of letting the reminder come back on its own. Literal rule order would
  have brought it back.
- **Rule 2** drops anything due at or after the start of tomorrow; undated loops stay.
- **Rule 4's bands:** approvals (by `since`), the job's loose ends (report, held close, parts,
  deferred task, hand-off; a failed report before a staged one), overdue (due before now, oldest due
  first), due later today (by due time), undated (by `since`); then table order, then id.
- **An unreadable source:** the scheduled check-in stays silent; asked for, an empty list says "I
  couldn't check everything, and nothing I could check is waiting on you." rather than "Nothing is
  waiting on you."
- **Speech:** the count is a word and exact; at most four clauses, fewer when `MyDaySpeechPolicy`'s
  ceiling needs it, then "The rest are on your phone."; "Want to deal with the first one now?" only
  when the first loop is an approval. Two items are joined "a and b" (`SpokenPhrasing.joined`), so the
  §10 example reads without the comma: "Two things before you finish: the report for the Smith job
  isn't sent and the filter for Jones is still not ordered." Templates are `String(localized:)`; the
  catalog sync of the new strings is owed (they were built with `SWIFT_EMIT_LOC_STRINGS=NO`).
- **The delivery decision** keeps `.deliver(slot:dayKey:speak:)` and gains a defaulted
  `alsoDelivers: MyDayDeliverySlot?`. When the evening slot and the check-in are both enabled, both
  still owed today, within 30 minutes of each other (30 merges, 31 does not), and neither is past its
  own 120-minute window, whichever comes due first delivers `.checkIn` with `alsoDelivers: .evening`
  (the list first). Each keeps its own day key.
- **Decision 9** is `MyDayDeliverySettings.checkInMinutes: Int?` (nil until the wearer picks a time)
  plus `fieldAssistOn`, resolved by `MyDayCheckInDefaults.minutes(fieldAssistOn:)` inside the pure
  policy; `.current` reads `Config.fieldAssistActive` (entitled and switched on), so a lapsed licence
  goes back to 21:00. A chosen time is kept either way.
- **Decision 10** is `MyDayDeliveryContext.motion: MotionSample.Kind?` (the existing pure kind from
  `DriveEndDetector.swift`, which `MotionActivityProvider.sample(from:)` produces). `automotive` makes a
  check-in delivery (merged or not) `speak: false`: it shows, and is spoken when asked. The morning and
  evening briefings are unchanged. P1 must feed the reading in; nothing does yet.
- **`MyDayScheduledDeliveryService` never delivers `.checkIn` in P0** and never consumes its day key:
  it has no content until P1, and it cannot be switched on without a settings row. P1 removes the
  guard and handles `alsoDelivers` (the evening's day key with it).
- **No dismissal store yet.** A `UserDefaults` + JSON owner has to be registered with
  `DataStoreRegistry` (its structured-preference guard), so the store comes with its P1 caller.
- **Resolution on disk** is written only when set, so an unresolved entry still encodes in the old
  shape; an unknown resolution string from a later version decodes as nil while `resolvedAt` still
  marks the entry answered. `outcome` keeps `waitingOnYou`: it is what was true when written. The
  activity summary says an answered entry as "…: you said yes." / "…: you said no." / "…: it lapsed."

**Plan W check (§3).** A ceiling hold **does** write a `.held` trail entry. `NativeToolRouter`'s
`.hold` branch calls `onActionHeld` (which feeds `HeldRecommendationStore`) and sets the gate to
`.held`; `recordActivity` then writes one `ActivityFeed.toolCall` entry, kind `.held`, authorisation
`held_for_you`, outcome `waiting_on_you`, titled "Your OK to use the … tool"
(`ActivityFeederTests.testAHeldActionIsWaitingOnTheWearer` pins it). So an entry survives
`drainSummary`. Two things P1 needs to know: the ceiling hold is the **only** writer of `.held` entries
(the confirmation path records `ran` or `declined`, never `held`), and a held entry carries no
`.operation` ref, only the job thread and goal refs, so the recorder cannot match a later approval to
it by operation id. It has to match on the tool and the scope, or the hold has to carry an id.

**§10 store shapes (checked 2026-11-14 at `8524978e8`).** All five rows can be answered; no row is
left out. The job's name is `FieldSession.jobReference` (said "job 1005") or `FieldSession.site?.customer`
(said "the Smith job"); the job day already carries both as `JobDaySession.jobReference` /
`.customer`, and `JobDaySession.label` gives "Job 1005" / "No job number".

| Row | Record that answers it | Title / job name it can give | Notes |
|---|---|---|---|
| Job report | `DeliveryQueue.entries` (`QueuedSend`, persisted): `state` `.staged`/`.immediate`/`.sending` (`isWaiting`) or `.failed` (with `failureReason`); `documentKind` `.report`/`.addendum`. For a report that never reached the queue: `JobDaySession.reportSent == false` on a finished session (`JobDayFeed`, the same test KT's `jobReportOwed` uses with `queuedReportSessionIDs`). | `QueuedSend.jobNumber` ("Job 1005", held so it survives the session); the customer only through `sessionId` → the session. Open place: `JobDayDestination.send(queuedId:)` or `.pastJob(sessionId:)`. | `DeliveryRequest` itself is the in-memory staged envelope, not a store; the queue is the record. The job day already splits these as `reportFailed` / `reportStaged` / `reportNotSent`. |
| Job close held | **No persisted "held" flag.** `FieldSessionError.jobCloseHeld(question)` and `.customerSignOffRequired(reason)` are thrown by `GuidedJobFlow.closeJob` (`JobCloseSequence.decide`) and nothing records them. What a record can answer: a session still open (`endedAt == nil`) whose close inputs would hold — `openVerifications` non-empty, or `customerSignOffRequired` (`Config.organizationRequiresCustomerSignOff`) with `signOff == nil`; and a finished session without the required sign-off and with its report not sent (`JobDaySession.signedOff`, `reportSent`; KT's `jobSignOffOwed`). | The question text is not kept; the adapter names the reason from the inputs ("the customer's sign-off", the open check's task title). Open place: `.openJob` or `.pastJob(sessionId:)`. | Answerable by re-running the close inputs, not by reading a held state. A session closed as `Outcome.deferred` (a check still owed on the screen route) is a different thing and is not this row. |
| Parts request | `FieldSession.partsRequests` (`PartsRequest`, persisted on the session): `status == .requested` (not `.sent`/`.answered`). Counted already as `JobDaySession.unsentPartsRequests`. | `part.partDescription` (else `part.number`), `quantity`; the job from the session. Open place: `JobDayDestination.partsOrder(sessionId:)`. | "On today's work": scope by the session's day, as `jobPartsOwed` does. |
| Deferred task | `FieldSession.tasks` (`FieldSession.Task`): `status == .deferred` (not `isOpen`; `completedAt` nil). | `Task.title` (the technician's or the recommendation's words); the job from the session. Open place: `.pastJob(sessionId:)` / `.openJob`. | `Task.Status.deferred` is a task state; the session `Outcome.deferred` is separate. |
| Expert or escalation | `FieldSession.escalations` with `resolvedAt == nil` (`resolveLastEscalation` sets it); and `FieldSession.expertHandovers` (`ExpertHandoverSent`, current per expert via `ExpertHandoverLedger.current`) with no `FieldSession.expertReplies` entry (`ExpertReplyReceived`) for the same `handoverId`. | `Escalation.expert?.name` or `ExpertHandoverSent.expert` (an `ExpertSnapshot`, never a rate); `Escalation.reason`. | `EscalationCoordinator.state` and `ExpertBridge` are live, in-memory state, not records. An `ExpertReplyReceived` is the expert's time reply, the nearest thing to "answered" the record keeps. |

Every row is per session, so the P1 adapter reads `FieldSessionService`'s history and the delivery queue
together, as `JobDayFeed` already does. KT's three job cards (`jobReportOwed`, `jobPartsOwed`,
`jobSignOffOwed`) read the same facts: P1 should not list a KT job card and the §10 row for the same
job twice.

**What has gone stale in "What exists, and what doesn't".**

- **Background delivery exists now.** Plan LM P1 built `BackgroundRefreshCoordinator`
  (`Services/Background/`), the app's one `BGTaskScheduler` wake with participants and a run ledger;
  JO's coordinator is that one. P2's notification can join it as a participant rather than building
  anything.
- **Notification actions exist now.** LM P2's `NotificationActionCatalog`
  (`Services/Notifications/NotificationActions.swift`) registers `UNNotificationCategory`s
  (`askUntilDone` and the Developer panel's button test) through `NotificationActionHub`.
- **KT is built** (P0–P4, P5 device pass owed). Its draft row has a record: a card whose
  `PreparedCardMemory.state` is `.handedOff(result: .cancelled or .unknown)` — the composer was opened
  and the card did not close. KT's producer exists, so the draft source can get a reader in P1 or later;
  `hasProducer` stays false until it does. KI, JO and LG are still unbuilt.
- **"`ActivityRecorder` writes a `.held` entry"** is loose: the entry is built by `ActivityFeed.toolCall`
  (in `ActivityRecorder.swift`) and written from `NativeToolRouter`, only for a Plan W ceiling hold.

### P1 — 2026-11-14 (headless)

**Files.** New, under `OpenGlasses/Sources/Services/MyDay/CheckIn/`:

- `OpenLoopSources.swift` — the everyday rows as pure mappings: `OpenLoopReminders` (incomplete, due today
  or overdue; a date-only reminder is due at the end of its day), `OpenLoopGoalSteps` (an active goal's
  next step, due today or overdue, `covers` the reminder its `.reminder` action made, matched by the
  reminder's text), `OpenLoopDigest` (`actionable` or higher, `seenCount == 0`, through
  `DigestComposer.compose` so retired and stale items are gone; calendar, reminder and goal items have
  their own rows, a location transition only mattered at the time; an agent item `covers` its queued
  result) and `OpenLoopAgentResults` (queued, not delivered, not stale by its own priority).
- `OpenLoopJobLoops.swift` — the five §10 rows, pure, over `OpenLoopJobFacts` (sessions with whether each
  report went, the queue entries, the sign-off rule). Today's work is the open job plus jobs finished
  today, cancelled ones excluded. **Report:** owed failures (`JobDayComposer.owedFailures`, said "didn't
  send"), staged entries, and a job finished today with `reportSent == false` and nothing waiting or
  failed in the queue. **Held close:** re-run from the close inputs — an open job with an open
  verification ("the check '<task>'", without the `Verify:` prefix) or with the organisation's sign-off
  missing, and a finished job with the sign-off missing whose report has not gone; one row a job.
  **Parts:** `PartsOrder.waiting` (`status == .requested`), one row a request, by its description else its
  number. **Deferred task:** `status == .deferred` and not completed. **Hand-off / escalation:** the
  current generation of each hand-off with no `ExpertReplyReceived` for its id, and each escalation with
  `resolvedAt == nil`; an escalation to an expert who also has a hand-off waiting is that hand-off's row.
  The job is named `.customer` from `site.customer`, else `.reference` from `jobReference`, else nothing.
- `OpenLoopReaders.swift` — `ApprovalLoopReader` (the trail; unavailable while the file is unopened),
  `ReminderLoopReader` (My Day's own `RemindersDaySource`, so the same `EventKitDayStore` path; denied or
  failed is unavailable, switched off in My Day's sources is an empty list), `GoalStepLoopReader`
  (`GoalStore`; reads reminders only when a next step's action is a reminder), `DigestLoopReader`,
  `AgentResultLoopReader` (`AgentNotificationQueue.pendingNotifications`, new) and `JobLoopReader`
  (empty with Field Assist off; its production facts read `FieldSessionService`'s history and open job,
  each of today's finished jobs' `reportWasSent`, and the send queue — what `JobDayFeed` reads, read when
  the check-in asks). Every store is reached through a closure, so the tests use fakes.
- `OpenLoopDismissalStore.swift` — two `OpenLoopDismissals` records in `UserDefaults` + JSON, the
  dismissed-tonight one (`checkInDismissedLoops`) and the said-today one (`checkInSaidLoops`). Registered
  in `DataStoreRegistry` as `checkInDismissals` (a preference, not subject-linked, `deleteAll()`), and the
  ET data-lifecycle matrix regenerated. To make that true, `OpenLoop`'s default fingerprint is now a
  one-way digest of title, due time and failed flag: the store holds loop ids and digests, never a title
  or a name.
- `EveningCheckInService.swift` — the readers (the registry makes the trail, reminders and goals readers;
  AppState installs the digest, agent and job readers, `install` replacing any reader for the same
  sources), `collect` (less tonight's dismissals: My Day and the asked answer), `scheduledText` (less
  what was said today too; marks every delivered loop said) and `askedText` (marks the list said only
  when asked at or after the check-in time). Every call reads every reader fresh.
- `WaitingOnYouModel.swift` — the section's rules and rows (`WaitingOnYouSection.isVisible`,
  `WaitingOnYouRow`, `WaitingOnYouAction`, `WaitingOnYouText`) and `WaitingOnYouScreenModel`, whose
  handlers are AppState's services in the app and fakes in the tests.

Also new: `App/EveningCheckInWiring.swift` (the readers over AppState's services, the delivery's content
and motion reading, the row handlers, and `openJobDayDestination`, which the job day's own rows in
`VoiceTab` now use too) and `App/Views/MyDayWaitingOnYouView.swift` (the thin section view). Changed:
`ActivityEntry.swift` (`holdKey`, `ActivityHoldPolicy`, `isAwaitingWearer(at:)`,
`effectiveResolution(at:)`), `ActivityRecorder.swift` (`ActivityHoldKey`, `resolveHold` on the recorder
seam, `holdKey` on held entries), `ActivityStore.swift` (`resolveHold`, `resolve(entryID:as:at:)`,
`isUnreadable`; `titleOnly` keeps the resolution and key), `ActivityPhraser.swift` (a lapsed hold is said
as lapsed), `NativeToolRouter.swift` (the hold key, the answer at the boundary, the in-memory held calls
and `replayHeld`), `OpenLoopApprovals.swift`, `OpenLoopCollector.swift` (`said`), `OpenLoopPhraser.swift`
(`offerFirst`), `MyDayDelivery.swift` (delivery, `MyDayCheckInDefaults.shown`, `MyDayDeliveryMotion`),
`MyDaySettingsViews.swift`, `MyDayView.swift`, `ActivityTool.swift`, `NativeToolRegistry.swift`,
`MyDayService.swift` (`reminders`), `MotionActivityProvider.swift` (`latestSample`),
`AgentNotificationQueue.swift` and `DataStoreRegistry.swift`. Tests: `HeldEntryResolutionTests`,
`OpenLoopReadersTests`, `OpenLoopJobLoopsTests`, `OpenLoopDismissalStoreTests`, `EveningCheckInTests`.

**How a held entry now finds its answer.** Matching by operation id is impossible: a held call is turned
away, never dispatched, and when the wearer is back the model asks again under a fresh invocation id. What
comes back is the same call, so the hold is filed under `ActivityHoldKey` — a digest of the dispatch seam,
the tool, the definition digest and `CanonicalArgumentDigest` of the arguments (the fields an
`ApprovalBinding` is bound to, less its rotating session id). `NativeToolRouter` computes it for every
call it authorizes; the `.hold` branch writes it on the `.held` entry (`ActivityEntry.holdKey`, written only
when set, so old entries and every other entry keep their shape). The answer is recorded where the ladder
decides: a confirmation approved (or a plan grant spent) → `approved`, denied → `declined`, and the same
call allowed to run by itself → `approved` (what it was waiting on has happened). In practice the last
does not arise today: every tool the presence ceiling can hold is classed messaging or actuation by
name, so the effect-class floor asks for a bound approval whenever it comes back. `ActivityStore.resolveHold`
answers **every** waiting held entry under the key, so a scheduled task held every 15 minutes is one
question, answered once; and `OpenLoopApprovals` lists only the newest hold of a key. A call with any other
argument — another recipient, a reworded body — is another question and leaves the hold alone; matching on
the tool alone was rejected because a later, unrelated message would silently clear the one held.
**Expiry** has no writer moment, so it is derived: `ActivityHoldPolicy.lifetime` is 48 hours (the oldest
hold §2 lists, from the start of yesterday, is at most two days old), past which `effectiveResolution(at:)`
is `expired`, `isAwaitingWearer(at:)` is false and an answer can no longer reach it.

**Approve from the row.** "Never approve directly" needs the call itself, and the trail never holds
arguments. So the router keeps each held call (name and arguments) **in memory only**, by its key, for
the hold's lifetime, capped at 10 like `HeldRecommendationStore`, and dropped once the call is answered.
The row's **Review** runs `replayHeld(key:)`: the call goes back through the whole ladder as the wearer's
own request inside `HeldCallReplay.asksFirst`, which turns an `.allow` into a `.confirm` — the call's own
approval card and spoken prompt ask, and its answer resolves the entry as above. The flag only ever adds a
question, and today it is belt and braces: the effect-class floor already asks for every holdable call. After a relaunch the call is gone, so the row offers **Decline** only (`resolve(entryID:as:)`,
nothing runs); a declined row is answered, a dismissed one is not. Review and Open step out of the My Day
sheet first and act once it has gone, because the approval card and the job's pages are drawn over the
app's root.

**"Want to deal with the first one now?"** Left out of the spoken text in P1 (`offerFirst: false` at every
call site; the phraser and its P0 tests keep the offer). The scheduled check-in is spoken outside any
conversation turn, so a "yes" would reach the model with no idea what it answers, and routing that yes to
`replayHeld` means intercepting the next utterance — the conversation-turn plumbing the brief called risky.
The row's Review is the P1 way to deal with the first one. **For P2:** a pending-offer record the next
wake-word turn can consume (or an `activity` action the model calls), feeding `replayHeld`.

**KT draft source: no reader.** `PreparedCardStore` keeps only each card's id and state — the card's
words, recipient and kind of job live in the feed `MyDayService` composes, which is a cache filled at
compose time, not a store. A reader would have to rebuild the card feed or read that cache, against the
Risks rule, and KT's three job cards (`jobReportOwed`, `jobPartsOwed`, `jobSignOffOwed`) say the same job
facts as the §10 rows, which would need de-duplicating by session. So `draft.hasProducer` stays false, no
reader answers for it, and no KT card can double a §10 row (`OpenLoopReadersTests` pins it). KI, JO and LG
stay without readers.

**Decided while building.**

- **Delivery.** `MyDayScheduledDeliveryService` delivers `.checkIn`: the check-in's text (`scheduledText`),
  then, with `alsoDelivers: .evening`, the evening briefing's own text, as one delivery handed to
  `onDelivery` as `.checkIn`. Both day keys are consumed whether or not either had words: an empty
  check-in says nothing and is not said later in the window; an empty check-in merged with the evening
  leaves the evening to speak alone. `motion` is fed from `MotionActivityProvider.latestSample` while it is
  under 10 minutes old (`MyDayDeliveryMotion`); `automotive` makes it `speak: false`, which shows it the
  way an unspoken briefing already shows (`lastResponse` and the delivery notification). That
  notification's body for the check-in is the content-free "Your evening check-in is ready."
- **Said today.** "Each item is said once a day" is the said-today record: the scheduled check-in leaves
  out what was said, and "what's waiting on me?" asked at or after the check-in time marks what it said.
  The asked answer and My Day always show everything still waiting.
- **Settings.** "Evening check-in" (off by default) and "Check-in time" under My Day's Scheduled Delivery,
  beside the evening row; the picker shows `MyDayCheckInDefaults.shown` (17:00 with Field Assist active,
  else 21:00) and stores nothing until the wearer moves it. "Speak scheduled briefings" now also enables
  with only the check-in on.
- **The section shows only while the check-in is on** — all evening (from My Day's own 18:00 evening),
  and after the check-in time whenever it has something in it. Off by default means no new section for
  anyone who has not asked for the check-in. Rows: Review and Decline on an approval, Complete on a
  reminder, Done on a goal step, Open on a job row (`openJobDayDestination`), and Mark as heard on a
  digest update or an agent result (retired in its own store, as My Day's digest rows are); swipe to clear
  writes the dismissal store only.
- **The trail summary** says a hold past its lifetime as "it lapsed", not as waiting.

