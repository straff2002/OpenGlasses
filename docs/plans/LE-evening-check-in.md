# Plan LE — The Evening Check-in (what's still waiting on your reply, decision or approval)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) below are
recommendations and are still open.
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

Rules, applied in order:

1. Drop anything dismissed from the check-in today, unless its `fingerprint` changed since.
2. Drop anything that will be in tomorrow's morning briefing as a dated item for tomorrow (the evening
   check-in is about today; tomorrow is My Day's job).
3. Merge duplicates: a reminder that is also a goal step's action counts once, as the goal step.
4. Rank: approvals first (someone or something is blocked on them), then overdue items oldest first, then
   due-today items by due time, then undated items by `since`. Ties by source order in the table.

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

## Decisions for Greig (open)

Recommendations first.

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

## Phases (one PR each)

### P0 — the pure core (headless)

- `OpenLoop`, `OpenLoopSource`, `OpenLoopAction`, `OpenLoopCollector` (the rules in §2), `OpenLoopPhraser`,
  `OpenLoopDismissals`.
- `ActivityEntry.resolvedAt`/`resolution`, decoding old entries unchanged; `ActivityPhraser` and
  `ActivityTool.next` read only unresolved held entries.
- `MyDayDeliverySlot.checkIn` in `MyDayDeliveryPolicy`, with the merge rule.
- **Exit tests:** a held entry approved later is not listed; a dismissed reminder stays out tonight and
  returns only when its due date changes; a reminder that is also a goal step's action counts once;
  tomorrow-dated items are left to the morning; the empty scheduled check-in returns nothing to say; four
  spoken, "the rest are on your phone"; quiet hours defer; the evening and check-in merge inside 30 minutes
  and not at 31; the policy never delivers twice for one day key.

### P1 — wired (headless)

- Source adapters over `ActivityStore`, `EventKitDayStore`, `GoalStore`, `NotificationDigestService` and
  `AgentNotificationQueue`.
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
