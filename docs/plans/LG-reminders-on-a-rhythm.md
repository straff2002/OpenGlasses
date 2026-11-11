# Plan LG — Reminders on a Rhythm (every four to five weeks, quiet while one is booked; and keep asking until I say it's done)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) below are
recommendations and are still open.
**Track:** Everyday assistant. Phone, lock screen and spoken audio.
**Builds on:** Plan [DV](DV-reminders-tool.md) and Plan [DY](DY-my-day-everyday-briefing.md) P0 (`EventKitDayStore`,
`AppleRemindersTool`), Plan [JH](JH-alarmkit-alarms.md) (`AlarmScheduling`, and why an alarm is not a nag), Plan
[IW](IW-goals-and-activity-trail.md) (the activity trail), Plan [BZ](BZ-notification-digest.md) / DY (quiet hours,
presence, `AgentNotificationQueue`).
**Sits beside:** Plan [JO](JO-watchers.md) (a watcher waits on the outside world; a rhythm waits on the wearer's
own calendar), Plan [KI](KI-tasks-that-wait.md) (asking a business for a slot is KI's; LG only says it is time to
book), Plan [LE](LE-evening-check-in.md) (an unconfirmed keep-asking reminder is one of its open loops), Plan
[LH](LH-car-routines-with-home-assistant.md) (its school-run case is the first keep-asking user). Sibling plans
drafted the same day: [LD](LD-home-cameras-through-home-assistant.md), [LF](LF-coupon-wallet.md),
[LI](LI-where-things-are-kept.md), [LJ](LJ-tell-me-when-its-for-sale.md),
[LK](LK-reading-mail-the-decision.md), [LL](LL-always-on-home-agent.md).

---

## Trigger

On 2026-11-11 the owner shared an example list of routines a cloud personal agent runs. Two of them are
reminders that a fixed repeat cannot express:

- **A rhythm.** "Book a haircut every four to five weeks, and stay quiet while one is booked." The next
  reminder depends on when the last one actually happened, not on a calendar repeat, and it should vanish
  the moment an appointment is in the calendar.
- **Keep asking.** "Remind me to send the message, and keep reminding me until I say I've sent it." One
  reminder that does not go away after it fires once, and that stops the moment the wearer confirms.

Apple Reminders does neither. It repeats on a fixed rule from the due date, and a fired reminder is quiet
until it is opened. The `reminder` tool cannot set a repeat at all.

## Outcome

**A rhythm**

- "Remind me to book a haircut every four to five weeks." → "Okay. Your last one in the calendar was on 14
  October, so I'll remind you from 11 November. I'll stay quiet while one is booked." (When nothing matches
  in the calendar: "When was the last one?")
- At four weeks, a reminder "Book a haircut" appears in Apple Reminders, due that day at the wearer's usual
  time. It alerts on the lock screen like any reminder, and My Day lists it.
- When an event matching "haircut" appears in the calendar, the reminder completes itself and nothing more
  is said until four weeks after that appointment.
- "I had my hair cut today" (or completing the reminder) restarts the rhythm from today.
- Past five weeks with nothing booked: one more nudge, then weekly, at most three times (decision 3); then
  "Want me to keep reminding you about haircuts?"
- "What rhythms do I have?" lists them with when each is next due; "stop the haircut reminder" ends one.

**Keep asking**

- "Remind me at 7:15 to text the after-school programme, and keep asking until I've done it." → "Okay. I'll
  ask at 7:15 and every 10 minutes until you say it's done, up to 8:15."
- At 7:15 the glasses say it if the wearer has them on and is free; otherwise a notification with a **Done**
  button. Every 10 minutes it asks again.
- "Done", "I've sent it", tapping Done, or completing the reminder stops it and says "Got it." "Stop asking"
  or "not today" stops it for today without marking it done.
- At the deadline it stops and leaves one line in the evening check-in (LE): "You didn't confirm: text the
  after-school programme."
- "Every school day" works: weekdays, skipping days the wearer marks as holidays (decision 5).

## What exists, and what doesn't

**Exists (verified 2026-11-11 at main `2d936d2`):**

- `AppleRemindersTool` (`reminder`): actions `create`, `list`, `complete`; `title`, absolute ISO-8601
  `due_at`, `id`, `search`, `offset`. Completion resolves an exact ID or an unambiguous title and asks when
  several match. No repeat, no notes, no list choice.
- `EventKitDayStore` (`Services/MyDay/EventKitDayStore.swift`): `requestCalendarAccess`,
  `requestRemindersAccess`, `calendarEvents(from:to:)`, `saveCalendarEvent`, `incompleteReminders()`,
  `saveReminder(title:dueDate:hasTime:)`, `completeReminder(id:)`. No `EKRecurrenceRule` anywhere in the app.
- `MyDayView` already observes `.EKEventStoreChanged`.
- `AlarmScheduling` (Plan JH): `set_alarm` schedules an AlarmKit alarm (rings through silent mode and Focus,
  full screen on the lock screen) and falls back to a local notification only when the alarm permission is
  refused.
- Local notifications are scheduled with `UNUserNotificationCenter` by timers, Pomodoro, alarms' fallback,
  geofences, parking, `ProactiveAlertService` and Field Assist job notices. **No `UNNotificationCategory`
  or notification action is registered anywhere**, so no notification today has a button.
- `AgentNotificationQueue` speaks agent results when the wearer can hear them (`canDeliverImmediately`) and
  holds them otherwise. My Day's `MyDayDeliveryPolicy` holds the quiet-hours and presence rules.
- The activity trail (`ActivityStore`, `ActivityRecorder`) records the assistant's own actions.
- `TaskTool` (`task`) is the Field Assist job's task verbs (`accept`, `decline`, `defer`, `start`, `done`,
  `abandon`, `add`). It owns "done" while a job is open. It is not a personal to-do list.

**Doesn't exist:**

- Any reminder whose next date depends on the last occurrence, or that watches the calendar to stand down.
- Any reminder that asks more than once, or a notification with a Done button.
- JO's `Expectation` and its runner (drafted, not built).

## Design

### 1 · Two kinds, one store (`RhythmStore`)

```
struct RhythmReminder: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String                 // "Book a haircut"
    var matchWords: [String]          // ["haircut", "barber"], shown and editable
    var minDays: Int                  // 28
    var maxDays: Int                  // 35
    var lastDoneAt: Date?             // from the calendar or the wearer
    var lastDoneSource: LastDoneSource // .calendar(eventID) / .wearerSaid / .reminderCompleted
    var nudgeMinutes: Int             // time of day for the reminder, default 09:00
    var overdueNudges: Int            // how many sent past maxDays
    var ownedReminderID: String?      // the Apple reminder LG created and may complete
    var state: RhythmState            // .active / .paused / .ended
}

struct KeepAskingReminder: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String                 // "Text the after-school programme"
    var firstAskMinutes: Int          // 07:15
    var intervalMinutes: Int          // 10
    var deadlineMinutes: Int          // 08:15
    var days: KeepAskingDays          // .once(date) / .weekdays(exceptions) / .daysOfWeek([..])
    var occurrence: KeepAskingOccurrence? // today's: asks sent, confirmedAt, stoppedAt
    var createdBy: KeepAskingOrigin   // .wearer / .routine(planRef) e.g. LH
}
```

One JSON store with the strict-decode and unreadable-means-never-write rules the digest store uses. Every
item is listed in Settings › Reminders on a Rhythm, editable and removable, and readable by voice.

### 2 · The rhythm (`RhythmJudge`, pure)

Inputs: the rhythm, the clock, matching calendar events (past 120 days, next 120 days), and whether the owned
reminder is still incomplete. Output: one state and at most one action.

1. **Booked.** A future event matches → `.booked(date)`. Action: complete the owned reminder if one is open.
   Silent.
2. **Last occurrence.** The latest of: the most recent past matching event, the wearer's "I did it", the
   owned reminder being completed. That is `lastDoneAt`. A matching event that was later deleted does not
   count.
3. **Not yet.** `now < lastDoneAt + minDays` → `.notYet(opensOn:)`. Silent.
4. **Window open.** Between `minDays` and `maxDays` with nothing booked → `.due`. Action: create the owned
   reminder (once) due on the opening day at `nudgeMinutes`.
5. **Overdue.** Past `maxDays` with nothing booked → `.overdue`. Action: move the owned reminder's due date to
   the next nudge (the day after `maxDays`, then weekly), up to the cap (decision 3); after the cap,
   `.askToContinue`.
6. **No history.** No last occurrence at all → `.needsStart`. Action: ask once, "When was the last one?"

**Matching is deterministic.** An event matches when its title contains one of `matchWords` as a whole word,
case and diacritics folded. No model decides whether "Trim with Sam" is a haircut; at setup the assistant
shows the past events it matched and the wearer can add a word. A match is never inferred from location.

**Why Apple Reminders carries the nudge.** A reminder LG creates alerts on time from the system, whether or
not Avenkin is running, appears in the Reminders app and in My Day, and can be completed anywhere. LG only
has to re-evaluate when the app is alive: on launch, on foreground, on `.EKEventStoreChanged`, and once an
hour while running. A missed re-evaluation delays standing down, never the nudge.

**What LG may touch.** Only the reminder it created, identified by `ownedReminderID` plus a marker in the
reminder's notes ("Added by Avenkin: rhythm"). It never completes, moves or deletes a reminder the wearer made.
`EventKitDayStore.saveReminder` gains `notes` and returns the new identifier; a small `updateReminderDue(id:)`
is added for step 5.

### 3 · Keep asking (`KeepAskingPlanner`, pure)

Inputs: the reminder, today's date, the clock, the occurrence so far. Output: the ask times left today, and
whether today is a day at all.

- Ask times are `firstAsk, firstAsk + interval, …` up to `deadline`, at most 12 (decision 4).
- On setup and each morning, the app schedules today's remaining asks as **local notifications** with the
  identifier `keepasking.<id>.<day>.<n>`, in a new notification category `KEEP_ASKING` with two actions,
  **Done** and **Stop for today**. iOS allows 64 pending notifications; LG reserves at most 24 and refuses a
  new keep-asking reminder that would exceed that, saying why.
- **When the app is alive and the wearer can hear** (`AgentNotificationQueue.canDeliverImmediately`, glasses
  on, not busy, not in quiet hours), the ask is spoken instead and that slot's notification is removed. When
  the wearer cannot hear, the notification does the work.
- **Confirmation** ends it: the Done action, completing a mirrored reminder (decision 6), or a spoken "done",
  "I've done it", "I've sent it", "sent", "yes, done". **Stop words** end today only: "stop asking", "not
  today", "skip it today", and the Stop for today action. Either removes all of today's pending asks.
- **"Done" is ambiguous.** A spoken "done" counts for keep-asking only within 10 minutes after an ask was
  heard or shown, and never while a Field Assist job is open (`TaskTool` owns "done" there). Outside that
  window the assistant asks "Do you mean the text to the after-school programme?"
- **At the deadline** with no confirmation: stop, write `KeepAskingOccurrence.missed`, and hand LE an open
  loop. Nothing carries over to the next day except through LE.

**Not an alarm.** AlarmKit rings through silent mode and Focus with a full-screen alert. Repeating that every
10 minutes is a siren, not a reminder. Keep-asking uses ordinary notifications that follow the wearer's
Focus and notification settings (decision 7).

### 4 · The tool

A new native tool, `rhythm_reminder`, rather than more parameters on `reminder`, so that the plain reminder
stays simple and its description stays short:

- `add_rhythm` (`title`, `match_words`, `min_days`, `max_days`, `time`, `last_done`)
- `add_keep_asking` (`title`, `first_ask`, `interval_minutes`, `deadline`, `days`)
- `list`, `done` (`id` or `title`), `booked` (records a booking the calendar doesn't show), `stop_today`,
  `pause`, `resume`, `remove`

Every write is a `localMutation`. A routine from another plan (LH) creates keep-asking reminders through the
same `KeepAskingStore` API, never by calling the model, and is listed as their creator.

### 5 · Records and surfaces

- **Activity trail:** "Added the rhythm reminder 'Book a haircut'", "Asked you 3 times; you said done at
  7:42", "Stood down: haircut booked for 9 December".
- **My Day:** the owned reminder appears as any reminder does. A keep-asking reminder pending today appears
  as one row with its next ask time.
- **LE:** a missed keep-asking occurrence is an `OpenLoop` of source `.askAgain`.
- **Display and watch:** the spoken ask is mirrored as a one-line card with Done; the watch gets the
  notification as iOS forwards it. No new watch code in v1.

### 6 · Privacy and cost

Everything is on the phone: EventKit reads, a local store, local notifications. No network and no model call
on any check. Notification text is the wearer's own title, and follows iOS's preview setting (decision 8).

## Decisions for Greig (open)

Recommendations first.

1. **A rhythm's nudge is an Apple reminder LG owns**, not an Avenkin-only notification. It fires on time
   without the app and shows wherever the wearer already looks.
2. **Match calendar events by the wearer's words only**, shown at setup and editable; no model matching.
3. **Overdue nudges:** the day after the window closes, then weekly, three at most, then ask whether to keep
   the rhythm.
4. **Keep-asking defaults:** every 10 minutes, at most 12 asks, a deadline required (default one hour after
   the first ask).
5. **"Every school day" means weekdays with exception dates the wearer adds** ("no school on Friday"). No
   school-calendar source in v1.
6. **No mirrored Apple reminder for keep-asking.** Its own notifications and spoken asks are enough; a mirror
   would double every alert.
7. **No AlarmKit** for either kind. "Make it loud" can be added later as a per-reminder choice.
8. **Notification text shows the title**, with iOS's own preview setting deciding the lock screen.

## Phases (one PR each)

### P0 — the pure core (headless)

- `RhythmReminder`, `KeepAskingReminder`, the store and its codecs.
- `RhythmJudge` (the six rules), the word matcher, `KeepAskingPlanner`, the confirmation and stop-word
  matcher with its 10-minute window and job exclusion, and every spoken line.
- **Exit tests:** a rhythm with a past event 30 days ago is `.due`; booking an event makes it `.booked` and
  completes only the owned reminder; a deleted event no longer counts as the last occurrence; overdue nudges
  stop at three; no history asks once; "Trim" does not match "haircut" unless added; keep-asking produces
  7:15, 7:25 … 8:15 and never more than 12; "done" at 7:30 after an ask confirms, "done" during an open job
  does not; "not today" stops today and tomorrow still asks; a weekday exception skips that day; the 24-slot
  budget refuses the next reminder.

### P1 — the rhythm, wired (headless)

- `EventKitDayStore` gains reminder notes, the returned identifier and a due-date update.
- `rhythm_reminder` with the rhythm actions; re-evaluation on launch, foreground, `.EKEventStoreChanged`
  and hourly while alive; the activity trail entries; Settings › Reminders on a Rhythm.

### P2 — keep asking, wired (headless)

- The `KEEP_ASKING` notification category with Done and Stop for today, registered at launch; scheduling and
  removal; spoken asks through the notification queue when the wearer can hear; the keep-asking actions on
  the tool; the API LH calls; the LE source; the Display card.

### P3 — device pass (owed)

- A rhythm seeded from a real past event, booked mid-window, standing down within a minute of the calendar
  change with the app in the foreground, and on next launch with it killed.
- A keep-asking morning with the phone locked in a pocket (notifications with Done), then with glasses on
  (spoken), confirming by voice and by the button; Focus on; the deadline passing and the line in LE.

## Risks

- **Matching the wrong event.** A meeting called "Haircut budget review" stands the rhythm down. Whole-word
  matching, shown matches at setup and the "Stood down: …" trail line make it visible; the wearer can remove a
  word.
- **Touching the wearer's reminders.** Only the owned reminder, by ID and notes marker. A test fails if any
  code path completes or edits a reminder without both.
- **Nagging.** A deadline is required, there is a hard cap, and stop words always work. A keep-asking
  reminder never carries over to the next day by itself.
- **iOS's notification limit.** The 24-slot budget is enforced and said, not discovered when notifications
  silently stop.

## Out of scope

- Booking the appointment. Asking a business for a time is Plan [KI](KI-tasks-that-wait.md); signing into a
  booking portal is not something the phone does (see [LL](LL-always-on-home-agent.md)).
- Reading a confirmation email to learn that something was booked; see [LK](LK-reading-mail-the-decision.md).
- Learning a rhythm without being asked ("you seem to get a haircut every five weeks"). JO's suggestion
  pattern could offer it later.
- Fixed repeats ("every Monday"). Apple Reminders' own repeat already does that; adding `EKRecurrenceRule`
  to the `reminder` tool is a small separate change under Plan DV.
