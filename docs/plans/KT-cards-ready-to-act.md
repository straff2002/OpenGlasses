# Plan KT — Cards Ready to Act (two or three things the app already knows, joined into one thing to do, with the message drafted and handed to you to send — on the phone, the Display, the watch and by voice)

**Status:** 🚧 P0 built 2026-11-11 (headless): the shared card model, the rules for every P0 kind, the joiner and `TodayFeed`, the draft templates and validator, EventKit attendees, `GoogleCalendarPresence`, contact by email and the sub-locality. Nothing is wired into a surface yet; P1–P5 to do. Drafted 2026-11-07 from the owner's ask. The owner took all the
recommended [decisions](#decisions-taken-2026-11-07) the same day ("Take them all"). Gmail and an in-app
Google sign-in were in the first draft (the owner asked for them that morning) and were **dropped the same
day** once Google's verification was on the table ("let's not worry about gmail / calendar unless the
calendar is easy"). The calendar is easy without a sign-in: iOS Calendar already syncs Google calendars and
My Day already reads every calendar iOS Calendar shows, so §9 adds a helper, not a connection. The October
email report's "not yet" therefore stands, and so does Plan [JO](JO-watchers.md)'s decision 5. The owner
also asked for the cards to work on the Meta Display ("I see them being useful on the meta display screen
as well"), so §6 designs each card once for four surfaces.
**Track:** Everyday (My Day), with Display, Watch and Field Assist parts. Phone first: everything a card
offers on the lens, the wrist or by voice is also on the phone.
**Builds on:** Plan [DY](DY-my-day-everyday-briefing.md) (My Day: `MyDayComposer`, `MyDayService`,
`MyDayItem`, leave-by, `MyDayMetricsStore`, `MyDayDelivery`), Plan [HB](HB-field-assist-mode-and-job-day.md) (the job day:
`JobDay`, `JobDayFeed`, `UpcomingJob`), Plan [GI](GI-health-summaries.md) (`SleepNightAggregator`), Plan
[KP](KP-answers-you-can-act-on.md) (the Display answer card: `HUDAnswerPager`, `frameRevision`,
`DisplayAvailability`, the lifetime and voice rules), Plans [X](X-interactive-hud-now-next-tasks.md) and
[Y](Y-interactive-hud-launcher.md) (`HUDScreen`, `HUDRouter`, the launcher), Plan
[BZ](BZ-notification-digest.md) (`NotificationDigestService`), the
Field Assist composers (`ReportMailComposer`, `ReportMessageComposer`, `DeliveryChannel`).
**Sits beside:** Plan KS (watch Today screens; in progress in another worktree, not yet on `main`) —
KT's watch phase extends KS's payload rather than adding a second one. Plan [JO](JO-watchers.md)
(watchers: a watcher is a standing question about the outside world; a KT card is a one-off joining of
what is already on the phone). Plan [GN](GN-agent-notebook.md) (the agent's notes; KT needs no Agent
Mode). Plan [KK](KK-conversation-timeline.md)
(turns and meeting text).

---

## Trigger

The owner looked at a consumer assistant whose whole home screen is a feed of cards, and asked whether
Avenkin could do the same. Each of those cards does three things:

1. **It joins signals.** "Slept 5h 10m" and "free from 10" sit as two chips above one suggestion: ask to
   move tomorrow's 8 am review to 11. A ticket found in the inbox, the wearer's location, the transit
   route, a ride estimate and rain at the venue become one "Leave by 18:15" card.
2. **It has already written the message.** The reply is drafted in the user's voice, addressed to the
   right person, and shown in full on the card.
3. **It waits for the user to send.** Nothing is sent without a deliberate press ("hold to send").

Avenkin already has most of the signals. My Day reads calendar, reminders, weather and travel time and
works out leave-by. Health summaries read sleep. The job day knows the next job, the customer and the
admin still owed. Meeting summaries pull out action items. What it lacks is the card itself. A My Day
row can only **open**, **complete**, give **directions** or be **dismissed** (`MyDayAction`). Nothing
joins two rows into one suggestion, nothing drafts a message from a row, and nothing reaches the glasses'
display except answers, notifications and task steps.

The owner's further ask shapes the plan:

- **On the Display.** A card is short, glanceable and has one obvious action. That fits a lens with four
  32-character lines and buttons better than it fits anything else the app has.

Mail was asked for and then set aside the same day (see Status). Without it, the cards are about the
wearer's own day, their meetings and their customers; they don't answer other people's messages.

## What we don't copy

That product holds every connected account's credentials on its own servers and runs there around the
clock. That is how it reads WhatsApp and pushes cards to a locked phone. Avenkin keeps the opposite
promise: no server of ours holds anyone's tokens or messages. So KT:

- **reads on the phone, when the app runs.** Opening My Day, the home card's refresh, a scheduled My Day
  slot and the existing foreground timers.
- **never sends.** Every send goes through the platform's own composer, or another app the wearer
  confirms in. KT holds no credential that can send anything (§7.2).
- **does not read iMessage.** iOS gives no app access to Messages. Cards can *start* a message in
  Messages, never read one.
- **does not read WhatsApp or mail.** In-app WhatsApp is paused on the licence question (2026-10-02), and
  mail was set aside (see Status). If either comes back, it plugs into the same card rules ([Open](#open)).

---

## What exists, and what doesn't

Read from `main` at build 651 (`a401277b2`).

**My Day.** `MyDayComposer.compose(inputs:now:)` turns `MyDayInputs` (calendar events, reminders,
weather, travel estimate, up to two digest updates, goals) into a `MyDaySnapshot` of ranked `MyDayItem`s,
`maxItems` 6 plus `overflowItems`. An item has `id` (`MyDayItemID`: source + raw value), `kind`
(`event`, `leaveBy`, `preparation`, `reminder`, `update`, `weather`), `title`, `detail`, `dueAt`,
`urgency` (`routine` < `upcoming` < `important` < `immediate`) and `actions: Set<MyDayAction>`
(`open`, `complete`, `directions`, `dismiss`). `MyDayView` is the full page; `MyDayHomeView` is the
compact card on the Voice home screen, placed by `MyDayHomePlacement`. `MyDayRowDismissal` and
`MyDayDismissals` handle dismissal. `MyDayMetricsStore` records closed-enum local metrics
(`MyDayMetricEvent`). Weather comes from WeatherKit through `NativeWeatherDaySource` (off under Medical
Local Only). Leave-by is `MyDayLeaveByAlertPolicy`, shared with `ProactiveAlertService`.

**The job day.** With Field Assist on, `JobDayFeed` gathers `JobDaySession`s (open, past, cancelled,
`reportSent`, `signedOff`, `openPartsRequests`, `unsentPartsRequests`), upcoming jobs and — when My Day is
on and placed — the personal `MyDayItem`s, and `JobDay` orders them. `UpcomingJob` has `jobReference`,
`site` (`JobSite`: `customer`, `address`, `contact`, all free text), `faultReport`, `equipment`,
`scheduledFor: Date?` (one time, no window end), `notes`, `origin`, `officeReference`. The only live
office connector in code is Workiz (`WorkizJob`: `number`, `status`, `scheduled`, `client`; `WorkizClient`:
`name`, `address`, `phone`), mapped by `WorkizMyJobs.map`. Nothing texts a customer an arrival time today.

**Sleep.** `SleepNightAggregator` produces a `SleepNight` with `asleep: TimeInterval?` for the main
session, merging staged sources (watch, ring) over a phone's coarse block. Read through
`HealthKitSampleReader`.

**Meetings.** `MeetingSummaryTool` extracts action items, decisions and topics as `[String]` from
`AmbientCaptionService.captionHistory` by heuristics, saves a note and ingests to `BrainStore`. It has no
attendees. Plan KK's `TimelineEntry` lives on the conversation thread.

**Sending.** Every send today is a prefilled hand-off. `send_message` resolves a contact with
`ContactLookupHelper.resolve(name:)` and opens `sms:<number>&body=…`. `send_via` opens `mailto:`,
`whatsapp://send?phone=&text=` or Telegram. Field Assist has the only real composer sheets:
`ReportMailComposer` (`MFMailComposeViewController`) and `ReportMessageComposer`
(`MFMessageComposeViewController`) in `ReportComposer.swift`, chosen by `DeliveryChannel`
(`email`, `messages`, `whatsapp`, `telegram`, `shareSheet`, `endpoint`). There is no general composer for
an arbitrary draft. `ContactLookupHelper` resolves names to numbers and emails; nothing resolves an email
address (a calendar attendee) to a contact.

**Approval.** `ToolEffectClassifier` classes `send_message`, `send_via` and `phone_call` as `.messaging`,
which always needs a bound approval (`ToolConfirmationCoordinator.requestApproval`, single-use
`ApprovalGrant`). KT's hand-offs are not tool calls: the wearer presses a button on a card they can
read, and the platform composer is the send. §8 keeps that distinction explicit.

**One-shot model calls.** `LLMService.completeStateless(_:system:)` runs the active provider without
tools. For Apple's on-device model it also drops history. For other providers it saves and restores the
history around the call. Nothing forces an on-device model regardless of the active provider.
Apple's model is reached through `sendAppleOnDevice`; MLX through `LocalLLMService`.

**Untrusted text.** `PromptInjectionPolicy.wrap(toolName:content:)` frames tool output in
`<untrusted_tool_output>`; `untrustedOutputTools` lists the native tools treated that way. No session
taint or tool lockout exists. `meeting_summary` is in `untrustedOutputTools`: caption text can carry other
people's words.

**Google Calendar.** No Google API is called for it. DY reads every calendar exposed through EventKit,
and iOS Calendar syncs a Google account added in Settings › Apps › Calendar › Calendar Accounts, so a
Google calendar added there already reaches My Day. Nothing in the app tells the wearer that, or notices
when no Google calendar is present. (The app's only Google sign-in is the Vertex AI provider's, with a
user-typed client ID; KT doesn't touch it.)

**The Display.** `HUDScreen` (title ≤ 40 characters, `HUDLine`s with icon and emphasis, `HUDItem`
buttons with stable ids) is rendered by `GlassesDisplayService` through `MetaDisplayBackend` or the Even
backend. `HUDRouter` keeps a screen stack and parses `HUDVoiceCommand` (including `briefing`: "what's
new", "catch me up"). KP added `HUDAnswerPager` (pages from `TeleprompterPaginator` geometry: Ray-Ban
Display 4 lines × 32 characters, Even G2 3 × 40), `PageTurnGate` and `frameRevision`, a 60-second card
lifetime, `DisplayAvailability` (`.ours`, `.inUse`, `.off`), the held card and the busy hint.
`HUDIcon` has `calendar`, `location`, `reminder`, `message`, `navigation`, `warning`. Stable DAT gives
button presses, not gestures; the Display moves focus between buttons. The web mirror (`WebHUDRenderer`)
draws the live HUD on the LAN.

**The watch.** `GlanceSurface` (`place`, `whereAmI`, `places`, `route`, `list`, `image`) goes to the
watch in the application context under `GlanceWire.contextKey`. Watch → phone commands arrive as
`WCSession` messages with a `"command"` key in `WatchConnectivityManager` (`ask`, `quickAction`,
`startGuidance`, …). Plan KS, in progress elsewhere, adds a read-only `WatchTodayPayload` (day, events,
weather) under the key `today`; it sends no actions back.

**Background.** No `BGTaskScheduler`, no `fetch` mode, no push. `ProactiveAlertService` runs on a timer
while the app is active. Plan JO's `BackgroundRefreshCoordinator` is unbuilt.

**Location.** `LocationService.currentLocation` and `geocodedPlace`; `GeocodingHelper.reverseGeocode`
returns a `PlaceInfo` without a neighbourhood.

---

## Design

### 1 · The card

A **prepared card** is a `MyDayItem`'s bigger sibling: one suggestion, the reasons for it, and the one
thing to do about it, ready to go. It is pure data, Foundation-only, in `Shared/` so the watch target
compiles it too.

```swift
struct PreparedCard: Codable, Equatable, Identifiable, Sendable {
    let id: PreparedCardID            // kind + occurrence key; stable across refreshes
    let kind: PreparedCardKind
    let headline: String              // "Leave by 18:15", ≤ 40 characters
    let subject: String?              // "Gig at the Town Hall", ≤ 60
    let signals: [CardSignal]         // the chips: why this card exists, 1–3
    let facts: [CardFact]             // label/value rows, 0–4: "Doors" "19:00"
    let primary: PreparedAction       // the one obvious thing
    let secondary: [PreparedAction]   // 0–2 more
    let draft: PreparedDraft?         // present when an action sends something
    let urgency: MyDayUrgency         // DY's ladder, unchanged
    let dueAt: Date?                  // when it matters
    let validUntil: Date              // after this it is gone, not stale
    let sensitivity: CardSensitivity  // decides where it may show and be spoken (§6.6)
    let absorbs: [MyDayItemID]        // the rows it replaces on the page (§3.3)
}

struct CardSignal: Codable, Equatable, Sendable {
    let source: CardSource            // calendar, reminders, travel, weather, sleep, location,
                                      // meeting, job
    let text: String                  // "Slept 5h 10m", ≤ 24 characters
    let sensitivity: CardSensitivity
}

struct CardFact: Codable, Equatable, Sendable { let label: String; let value: String }

enum PreparedAction: Codable, Equatable, Sendable {
    case handOff(PreparedDraftRef)    // open the composer with the draft (§7)
    case directions(destination: String, mode: TravelMode)
    case openEvent(id: String)
    case openJob(id: String)
    case openReport(sessionId: String)   // Field Assist's composer, as JobDayDestination.send
    case openPartsOrder(sessionId: String)
    case addToCalendar(ProposedEvent)    // shown, confirmed, written through EventKit
    case call(ContactRef)
    case complete(reminderId: String)
    case later                           // §3.5
    case dismiss
}

struct PreparedDraft: Codable, Equatable, Sendable {
    let channel: DraftChannel         // messages, email, whatsapp
    let recipient: DraftRecipient     // name + address, and where the address came from
    let subject: String?              // email only
    var text: String                  // editable on the phone; the edit is kept (§5.4)
    let origin: DraftOrigin           // .template, .onDevice, .cloud(provider)
    let language: String              // BCP 47: the wearer's, or the contact's when known
}
```

Four rules make the model safe to fill from untrusted sources:

1. **The rule picks the recipient, never a model.** `DraftRecipient.source` is one of `calendarOrganiser`,
   `calendarAttendee`, `jobCustomer`, `meetingAttendees`. A draft whose recipient was not
   set by a rule cannot be built.
2. **The rule picks the action, never a model.** A model only writes `PreparedDraft.text` (§4).
3. **A card's numbers come from data.** Times, durations, prices and counts in `headline`, `facts` and
   chips come from the source rows, formatted by the rule. None is taken from a model's output.
4. **Everything has an end.** `validUntil` is set by the rule (the event's start, the end of the day, a
   job's start plus its window). An expired card is removed, never shown greyed.

`PreparedCardID` is `kind` plus an occurrence key built from the source ids (`leaveBy:<eventId>:<date>`,
`jobOnMyWay:<jobRef>:<date>`). A refresh that rebuilds the same card keeps its state, its
edited draft and its place.

### 2 · The kinds

Every kind is a pure rule over `CardInputs` (the facts My Day and the job day already gather). It returns zero or one card per occurrence. The table is the catalogue. The P column says which
phase builds it.

#### Personal (P0)

| Kind | When it appears | Chips | Facts | Primary · secondary | Draft |
|---|---|---|---|---|---|
| **Leave by** (`leaveBy`) | DY's leave-by for an event with a place, from 90 min before leave-by until the event starts | 📅 event time · 📍 "You're in {area}" · ☔ rain at the place, when there is any | Leave by · travel time and mode · arrive by | **Directions** · *Tell {name} you're on the way* · Later | When one other person at the event resolves to a phone or email: "On my way — there about {arrival}." |
| **Running late** (`runningLate`) | Now + travel time > the event's start − 2 min, and the wearer is not at the place (more than 300 m away) | 📅 starts {time} · 🚗 {n} min away | Starts · arrive about · late by | **Text {name}** · Directions · Dismiss | "Running about {n} minutes late, sorry — there about {arrival}." n rounded up to 5 |
| **Short night** (`shortNight`) | Opt-in (decision 4). Last night's `asleep` < the wearer's threshold (default 6 h), *and* before the threshold time (default 09:30) there is a meeting the wearer didn't organise, with 1–3 others, *and* a free slot of the same length later that day | 😴 "Slept 5h 10m" · 📅 "Free from 10" | Meeting · proposed time | **Ask to move it** · Open event · Dismiss | To the organiser: "Could we move {meeting} to {slot}? It would suit me better today." Never mentions sleep |
| **Meeting follow-up** (`meetingFollowUp`) | A meeting summary with at least one action item was saved within 2 hours of a calendar event that overlaps it and has other people with email addresses | 🎙 "3 things agreed" · 📅 event | Up to three action items | **Email recap** · Open note · Dismiss | To the attendees: one line of thanks, the action items as a list, a sign-off |
| **Fit it in** (`fitItIn`) | A reminder due today, no time set, and a free gap of 30 min or more starting within the next hour | ✅ reminder · 📅 "Free till {time}" | Reminder · gap | **Done** · Open · Later | None |

Weather never makes a card on its own (except severe alerts, which keep their existing path). It joins
as a chip and a fact: "Rain from 18:00 · take a coat" on a leave-by or running-late card when the hourly
forecast at the destination during the event has precipitation ≥ 40 % or a temperature below 5 °C.
Location joins only as a chip ("You're in Te Aro"), from `GeocodingHelper` with the sub-locality
added (§P0); it never makes a card.

#### Field Assist (P0)

| Kind | When it appears | Chips | Facts | Primary · secondary | Draft |
|---|---|---|---|---|---|
| **On my way** (`jobOnMyWay`) | The next `UpcomingJob` has a time and an address, and leave-by for it is within 30 min | 🔧 Job {ref} · 📍 address · 🚗 {n} min | Customer · scheduled · arrive about | **Directions** · *Text {customer}* · Later | "Hi {first name}, it's {wearer} from {company}. On my way, there about {arrival}." |
| **Running late to a job** (`jobRunningLate`) | As running late, for the next job | 🔧 Job {ref} · 🚗 {n} min away | Scheduled · arrive about | **Text {customer}** · Directions | "Hi {first name}, running about {n} minutes behind — there about {arrival}. Sorry for the wait." |
| **Report not sent** (`jobReportOwed`) | A job ended today, `reportSent` false, more than 15 min ago | 🔧 Job {ref} · ✉️ "Report not sent" | Customer · ended | **Send report** (opens the existing composer) · Open job | None: the composer already has its own |
| **Parts not ordered** (`jobPartsOwed`) | `unsentPartsRequests` > 0 | 🔧 Job {ref} · 📦 "{n} parts" | Parts | **Send parts order** (existing composer) · Open job | None |
| **Sign-off owed** (`jobSignOffOwed`) | A job ended today without sign-off, and the job needs one | 🔧 Job {ref} | Customer | **Get sign-off** · Open job | None |

The job kinds replace today's job-day rows for the same thing (the row is absorbed, §3.3), so a
technician sees one "Report not sent" card, not a card and a row. The customer's phone comes from the
office connector (`WorkizClient.phone`) or from `JobSite.contact` when it parses as a number
(`ContactLookupHelper.isPhoneNumber`). With neither, the card has no draft and its primary is
**Directions**. Company name comes from the organisation profile (Plan [CT](CT-org-configuration-profiles.md)) when there is one, otherwise
the wearer's own name only.

#### Google calendars

Google calendars add no kind of their own. When the wearer has added their Google account to iOS
Calendar, its events arrive through EventKit like any other, so every rule above sees them, attendees
included (§9).

### 3 · Joining, ranking, caps

#### 3.1 The pipeline

```
MyDayInputs + JobDayFacts + SleepNight? + MeetingFacts   (gathered as today)
        │
        ▼
PreparedCardRules.cards(from: CardInputs, now:, settings:) -> [PreparedCard]   (pure, one rule per kind)
        │
        ▼
PreparedCardJoiner.join(cards, items: snapshot.allItems) -> TodayFeed        (pure)
        │   absorbs rows, attaches weather and location chips,
        │   applies state (dismissed, later, done, handed off), drops expired
        ▼
TodayFeed { cards: [PreparedCard], rows: [MyDayItem], overflow: [MyDayItem] }
```

`TodayFeed` is what the phone page, the home card, the Display, the watch and speech all read. Nothing
re-ranks downstream.

#### 3.2 Ranking

Cards rank on DY's ladder first (`urgency`), then `dueAt`, then kind order (job kinds before personal
on a Field Assist day), then id. Each rule sets urgency from
time to `dueAt`:

| Time to `dueAt` | Urgency |
|---|---|
| ≤ 10 min, or running late | `immediate` |
| ≤ 60 min | `important` |
| today | `upcoming` |
| otherwise | `routine` |

#### 3.3 Absorbing rows

A card lists the `MyDayItemID`s it replaces (`absorbs`). The joiner removes those rows from `rows`. A
leave-by card absorbs the event's row, its leave-by row and the weather row it took a chip from. A job
card absorbs the job-day row for the same session. So the page never says the same thing twice, and
DY's cap still counts only rows.

#### 3.4 Caps

| What | Cap |
|---|---|
| Cards on the home card | 1 (the top card), with "N more ready" |
| Cards on the My Day page | 6, then DY's rows |
| Short night | 1 a day |
| Cards pushed unasked to the Display, a notification or speech | §6.2 |

#### 3.5 State

`PreparedCardStore` keeps, per card id, only: `state` (`fresh`, `seen`, `later(until)`, `handedOff(at,
result)`, `done`, `dismissed`, `notUseful`), the edited draft text if the wearer changed it, and the
time of the last change. No chips, no facts. Entries are dropped 24 h after the card's
`validUntil`. Registered with `DataStoreRegistry` as `preparedCards` so subject erasure reaches it.

- **Later** offers "In an hour", "This evening" and "Tomorrow morning" (only when `validUntil` allows).
- **Not useful** asks nothing further. Three "not useful" on one kind in 14 days turns that kind off
  and says so once on the page, with **Undo**. The kind's switch is in settings (§5.6).
- **Handed off** records the composer's result where the platform gives one
  (`MFMessageComposeResult`, `MFMailComposeResult`): `sent` closes the card, `cancelled` leaves it fresh.
  For a hand-off with no result (WhatsApp, `mailto:`), the card shows "Opened in {app}"
  with **Done** and **Not sent**, and closes itself at `validUntil`.

### 4 · Drafts

#### 4.1 Templates first

Every kind with a draft has a deterministic template (the table's quoted text), localised in the
catalogue, filled from the card's facts. P0 and P1 ship with templates only. A template is always the
fallback: when no model is allowed, when the model fails, or when its output fails validation.

#### 4.2 A model, when allowed

`DraftWriter` asks a model to rewrite the template in the wearer's voice, and for replies, to answer
the message. One call per card, made when the card is first shown on the phone, not when it is built
(so a card nobody looks at costs nothing). The call goes through a new isolated route,
`DraftModelCall`, which unlike `completeStateless` guarantees for every provider: no tools, no history,
no memory, no persona, no Brain or timeline text, nothing persisted, and no logging of the prompt or the
reply.

Model order (decision 5):

1. **Apple's on-device model**, when available.
2. **The local MLX model**, when one is loaded and the app is in the foreground.
3. **The wearer's cloud model**, only after a one-time consent ("Use {provider} to write drafts") that
   names what is sent. Never under Medical Local Only or HIPAA mode. A meeting follow-up's draft (which
   carries caption text) is never sent to a route on the blocked list (unpaid Gemini keys,
   sign-in-with-a-subscription routes).

The prompt carries: the template, the card's facts (trusted), the wearer's style note (§4.3), and for a
meeting follow-up the action items, framed as untrusted. The reply is the draft text only.

#### 4.3 "In your voice"

`WritingStyle` is small, local and readable:

- **A style note** the wearer can edit in settings: greeting ("Hi {name}", none), sign-off ("Cheers,
  Sam"), length (short / as needed), formality, emoji yes/no, and a free line ("I never use
  exclamation marks").
- **Learned from edits.** When the wearer edits a draft before handing it off, a pure `StyleEditLearner`
  compares the before and after: shorter or longer, greeting changed, sign-off changed, emoji removed.
  After three consistent edits it proposes a change to the style note ("You often cut the greeting. Stop
  adding one?"), which the wearer accepts or ignores. It never stores the messages, only the counts.
- **Not learned from the wearer's messages or mail.** KT can't read either, and wouldn't put the
  wearer's correspondence through a model to learn a style.

#### 4.4 Validation

`DraftValidator` (pure) checks every model draft before it is shown, and every template after filling:

| Check | On failure |
|---|---|
| Length within the channel's budget (Messages 320, WhatsApp 500, email 1,200 characters) | Template |
| No URL, no email address, no phone number, unless it appears in the card's trusted facts | Template |
| No money amount, unless it appears in the trusted facts | Template |
| No time or date not in the facts (a model must not invent a meeting time) | Template |
| Same language as the template's target language | Template |
| Not empty, no Markdown, no placeholder left (`{name}`) | Template |
| For meeting follow-ups: no text beyond the action items copied in more than 12 consecutive words | Template |

A draft that fell back says so in small text under it ("Simple draft"), so the wearer knows why it reads
plainly.

### 5 · On the phone

#### 5.1 The My Day page

The page becomes **cards, then rows**. The headline and source states stay as they are. Each card:

```
┌──────────────────────────────────────────────┐
│ [😴 Slept 5h 10m]  [📅 Free from 10]         │  chips: source icon + text, the "why"
│                                              │
│ Ask to move the review                       │  headline (large)
│ Review with Tom · tomorrow 08:00             │  subject (secondary)
│                                              │
│ Proposed      11:00                          │  facts
│                                              │
│ ┌ To Tom Reid · Email ──────────────────┐    │  draft box, coral edge = written by the
│ │ Hi Tom,                               │    │  assistant (the AI accent, #E77F47)
│ │ Could we move the review to 11?       │    │
│ │ It would suit me better today.        │    │
│ │ Sam                                   │    │
│ └──────────── Drafted on this iPhone ───┘    │
│                                              │
│ (  Email Tom  )    Open event    ···         │  primary capsule; secondary; menu: Later,
└──────────────────────────────────────────────┘  Not useful, Dismiss
```

- The **primary** is a capsule button whose label names the effect and the person: "Text Ana",
  "Email Tom", "Directions", "Send report". Never "Send" alone.
- The **draft box** is editable in place. Its footer says where it was written: "Drafted on this iPhone",
  "Drafted by {provider}", or "Simple draft".
- **Swipe** to dismiss (DY's `MyDayRowDismissal`), with Undo.
- Cards that need no draft (Report not sent, Booking) show facts and buttons only.
- **Empty and partial states** stay DY's. A source that is off or denied makes no cards, and the page says
  so in DY's source-state line, never as an error card.

#### 5.2 The home card

`MyDayHomeView` shows the top card in compact form: the chips, the headline and the primary button,
plus "N more ready" when there are more. With no cards, it is today's My Day card. On a Field Assist day
the job day's card shows the top job card the same way.

#### 5.3 Notifications

A card may post one local notification when it reaches `immediate` (leave-by within 10 min, running
late, on my way to a job). The lock-screen text is generic by default — "Something's ready in My Day" —
as DY's scheduled notifications are, with a setting to show the headline. The notification's action
opens the card. It never carries the draft text. Quiet hours (DY) hold them back.

#### 5.4 Edits

An edited draft is kept in `PreparedCardStore` until the card ends, so leaving the page loses nothing.
A rebuild that changes the facts (a later arrival time) does not overwrite an edit. It shows "Times
changed — update draft?" with **Update** and **Keep mine**.

#### 5.5 Accessibility

VoiceOver reads a card as: headline, then "because: slept five hours ten minutes; free from ten", then
the facts, then the draft with its recipient, then the actions. Chips are one combined element. Dynamic
Type wraps chips onto two lines rather than truncating. Every action is a named button, and the swipe
has a VoiceOver custom action.

#### 5.6 Settings

Under **My Day** in Works with your iPhone:

- **Ready-to-send cards** (on when My Day is on). Off returns My Day to rows only.
- Per kind: on/off. **Short night** starts off and needs Health first.
- **Add your Google calendar** (shown only when no Google calendar is present, §9).
- **Write drafts with**: On this iPhone only / {provider} (with the consent sheet).
- **Your style**: the style note.
- **Show card text on the lock screen**: off.
- **Sleep threshold** and **early meeting before**, under Short night.

With Field Assist on, the job kinds sit under Field Assist › Job day, and an organisation profile can pin
**Text customers from cards** off (Plan [CT](CT-org-configuration-profiles.md)'s policy, decision 8).

### 6 · On the Display (and the other surfaces)

#### 6.1 One card, four renderings

| Surface | Renderer | What it shows | What a press does |
|---|---|---|---|
| Phone | SwiftUI (§5) | Everything | Hands off through the composer |
| Meta Display / Even G2 | `PreparedCardHUDBuilder` → `HUDScreen` | Headline, one chip line, one or two facts, the draft in pages | Directions and opens run; a send is **staged on the phone** (§6.4) |
| Watch | KS's Today payload, extended (§6.7) | Chips, headline, facts, the draft | The same as the Display |
| Speech | `PreparedCardPhraser` | Headline, the reason, the offer | Voice stages a send, like the Display |

#### 6.2 How a card reaches the lens

**Pulled** (any card, any time):

- The launcher (Plan Y) gains **Today** as its first Quick Action when cards exist.
- "What's next", "what's ready", "catch me up" (`HUDVoiceCommand.briefing`, which today opens the
  digest glance) open the card stack when there are cards, and the digest when there are none.
- A temple tap can be bound to **Today** (`TempleAction.today`).

**Pushed** (shown unasked, only when the Display is `.ours` and the wearer is wearing the glasses):

| Kind | Pushed when | How |
|---|---|---|
| Leave by | Leave-by is 10 min away, once | A glance: headline + one fact, buttons **Open** · **Close**, 20 s |
| Running late, job running late | Once, when it first becomes true | The same |
| On my way (job) | Leave-by for the job is 10 min away, once | The same |
| Everything else | Never | Pulled only |

A pushed glance never covers a task card (Plan X) or an answer card (KP): it waits until they close, and
is dropped if the card is no longer `immediate` by then. While the Display is `.inUse` (another app has
it), nothing is pushed and nothing queues (KP §8 rule 3); the spoken line (§6.5) still plays.

#### 6.3 The screens

Ray-Ban Display: the title is ≤ 40 characters, a page is 4 lines × 32 characters, and a screen holds at
most three buttons so focus moves in one short sweep. Even G2: 3 lines × 40, the same buttons as its
backend draws them.

**The stack (card *i* of *n*):**

```
Leave by 18:15                         ← title: headline
📅 19:00 · 34 min · rain               ← meta line: chips, condensed, icons from HUDIcon
Bus 2, then a 4 min walk               ← primary line: the most useful fact
2/4                                    ← footer when n > 1
[ Directions ]  [ Text Ana ]  [ Next › ]
```

Buttons, left to right: the primary, the draft action when there is one (or the first secondary), then
**Next ›** (or **Close** on the last card). "Later" and "Dismiss" are reachable by voice and from the
draft screen, not on the first screen, so the three slots go to doing things.

**The draft (pushed when the draft action is pressed):**

```
To Ana · Messages
Leaving at quarter past,
see you inside
[ Send on phone ]  [ Read it ]  [ ‹ Back ]
```

The draft is paged with `HUDAnswerPager` and KP's geometry. Multi-page drafts show **Next ›** in place
of **Send on phone** until the last page, so the wearer has seen the whole message before they can stage
it. **Read it** speaks the draft.

**Staged (a flash, 3 s):** "Ready on your phone — tap the notification to send." Then the stack returns
on the next card.

Every press carries the `frameRevision` it was issued against, through `PageTurnGate`, as KP does. A
press on a card that has since expired or been rebuilt is dropped and the stack redraws.

#### 6.4 Why the Display stages instead of sending

iOS has no way for an app to send a text or an email without the user tapping Send on the phone. The
platform composers need the phone unlocked and in front of the user, and `sms:` and `mailto:` open the
other app. So from the lens, the wrist or the voice, **Send on phone** does three things:

1. marks the card `staged` with its current draft,
2. posts a time-sensitive local notification "Message to Ana ready — tap to send" (this one names the
   recipient, because the wearer just asked for it; the draft text is not in it),
3. opens the composer straight away if the phone is already unlocked and the app is in front.

Tapping the notification opens the composer with the draft. The staged state lasts until the card's
`validUntil`. This is less than a one-press send, and it is the honest limit of the platform. [Open](#open)
notes what would change it.

**Directions** from the lens starts walking or driving guidance on the phone exactly as the existing
directions action does. **Open** opens the card on the phone the next time it is unlocked.

#### 6.5 Speech

`PreparedCardPhraser` (pure) says a card in at most two sentences, and offers the action as a question:

- "Leave by quarter past six for the gig — it's raining there, so take a coat. Want me to get a message
  to Ana ready?"
- "Job 1005 is twelve minutes away. Shall I get an on-my-way text ready for Mrs Hale?"
- "Your 9 o'clock with Tom ended with three things agreed. I've drafted a recap — it's on your phone."

Rules:

- **Sleep is never said** unless the wearer asked about their sleep. A short-night card is said as "Your
  8 o'clock with Tom — want to ask to move it?".
- **A "yes" only stages.** Because a spoken yes cannot send anything, the existing short-utterance
  approval (`RemoteActionVoiceConsent`) is safe here: the worst a stray "yes" from a podcast can do is
  put a draft on the phone.
- Pushed cards (§6.2) are spoken when the glasses have no display or the Display is `.inUse` or `.off`,
  once, and never during a call or while captions run.
- "What's ready?" reads the stack one card at a time: "Three things. First: …". "Next", "skip", "later"
  and "not useful" work while the stack is being read.

#### 6.6 What may show where

`CardSensitivity` decides placement:

| Sensitivity | Phone page | Lock screen | Lens | Web mirror (Plan BP) | Watch | Spoken |
|---|---|---|---|---|---|---|
| `ordinary` (calendar, travel, weather, jobs) | Yes | Generic text by default | Yes | Yes | Yes | Yes |
| `personal` (meeting follow-up, a draft's text) | Yes | No | Yes | Draft text hidden | Yes | Headline only |
| `health` (sleep chips) | Yes | No | The chip shows as "Short night" | Hidden | No | No, unless asked |

The web mirror is a LAN page that someone else could open, so it gets the strictest column.

#### 6.7 The watch

KS sends `WatchTodayPayload` (events and weather, read-only) under `today`. KT adds a `cards` field (at
most 3 `WatchPreparedCard`s: headline, chips, up to 2 facts, primary label, draft text when its
sensitivity allows, the card id) and bumps the payload version. Three commands come back through
`WatchConnectivityManager`: `preparedCardAction` with `card_id` and `action` (`stage`, `directions`,
`later`, `dismiss`). `stage` does exactly §6.4. The watch app shows cards above KS's event list. KT's
watch phase waits for KS to land on `main`.

### 7 · Handing off

#### 7.1 One composer for any draft

`DraftComposer` generalises `ReportMailComposer` and `ReportMessageComposer` from Field Assist into a
presenter for any `PreparedDraft`. It picks the route by channel:

| Channel | Route, in order | Result known? |
|---|---|---|
| Messages | `MFMessageComposeViewController` when `canSendText()`, else `sms:` | Yes (composer) |
| Email | `MFMailComposeViewController` when `canSendMail()` (decision 2); else `mailto:`, which opens the wearer's default mail app (Gmail when they chose it); else copy and say so | Only through the composer |
| WhatsApp | `whatsapp://send?phone=&text=` when installed, else Messages | No |

Field Assist's report and parts flows keep their own
model (`ReportComposerModel`) and move onto the shared presenter without changing behaviour.

#### 7.2 Nothing here can send by itself

KT adds no tool and no credential that can send. Hand-offs are not routed through `send_message` or
`send_via` and so need no bound approval: the press is on a card that shows the whole draft and its
recipient, and the platform's own Send is the commitment. If the model ever asks to "send that" in
conversation while a card is showing, that remains an ordinary `send_via` call under
`ToolAuthorizationPolicy`, as today.

### 8 · Safety of the drafts

- The model never sees a card's recipient address, only a first name, so it cannot put an address in the
  text that the validator would then wave through.
- Meeting follow-ups are the one kind whose draft input isn't the wearer's own data: caption text can
  carry anyone's words. The action items are framed as untrusted (`meeting_summary` is already in
  `untrustedOutputTools`), the call is isolated (§4.2) and the draft is validated (§4.4) and shown in
  full before anything goes.
- No draft, chip or fact goes into memory, Brain, notes, Memory Rewind, the timeline, goals, watchers,
  Agent Mode, skill packs, MCP or the gateway. The card store keeps state and edits only (§3.5).

### 9 · Google calendars, through iOS Calendar

No Google sign-in, no Google API, no verification. iOS Calendar already syncs Google accounts, and My Day
already reads every calendar EventKit shows.

1. **Notice.** A pure `GoogleCalendarPresence` reads EventKit's sources: a CalDAV source whose title or
   account looks like Google (`Gmail`, `Google`, or an `@gmail.com` / Workspace address) counts as
   present. It is a hint, not a gate: a Google calendar subscribed another way still works.
2. **Say how, once.** When My Day is on and no Google calendar is present, the My Day page shows one
   dismissible line — "Use Google Calendar? Add your Google account to iPhone's Calendar and it shows up
   here." — with **Show me how**, a short sheet: Settings › Apps › Calendar › Calendar Accounts › Add
   Account › Google, turn on Calendars. iOS gives apps no link into those settings, so the sheet explains
   rather than opens. The same row sits in My Day settings until a Google calendar appears.
3. **Attendees.** EventKit attendees (`EKParticipant`: name, `url` as `mailto:`, role, status, `isCurrentUser`)
   map to a new `attendees` field on `MyDayCalendarEvent` (`[CalendarPerson]`: name, email, organiser,
   self, response). This works the same for Google, iCloud and Exchange calendars.
4. **People.** `ContactLookupHelper.resolve(email:)` (new) finds a contact by email address
   (`CNContact.predicateForContacts(matchingEmailAddress:)`) for a phone number and a display name, so
   leave-by's "Tell {name}" and running late's "Text {name}" can reach a person from any calendar.

### 10 · Learning what's useful

`PreparedCardMetricsStore` (local, closed enum, like `MyDayMetricsStore`): per kind, counts of built,
shown, opened, draft edited, handed off, sent (where known), later, dismissed, not useful; draft origin
(template, on-device, cloud) and validator fallbacks by reason; Display presses by button. No titles,
names, addresses, text or times. It feeds §3.5's "turn a kind off" rule and the support report's
**Cards** section (counts only).

---

## What KT leaves out

- **Sending by itself**, from anywhere. §6.4 says why, and [Open](#open) what would change it.
- **Gmail, Outlook and an in-app Google sign-in.** Set aside 2026-11-07: reading mail needs Google's
  restricted-scope verification (likely a paid security assessment, renewed yearly; a 100-user cap until
  then). `reports/Email access routes for Avenkin.md` holds the routes and the safety rules if mail comes
  back; the card model is written so mail kinds could join it.
- **iMessage reading.** No API.
- **WhatsApp, Telegram, Instagram, Signal and other inboxes.** WhatsApp waits on the licence advice; the
  rest have no supported read access on iOS.
- **Background fetch and server push.** No server; JO's coordinator may add a refresh later.
- **Tickets and bookings.** Without mail, a booking reaches the cards only as a calendar event the wearer
  (or the sender's own "add to calendar") put there; leave-by then covers it.
- **Ride booking.** A ride estimate needs a partner API; KT shows travel time from MapKit only.
- **Sleep from third-party wearables directly.** Only what reaches Apple Health.

## Decisions (taken 2026-11-07)

The owner took every recommendation ("Take them all"). Four first-draft decisions about Gmail (hand-off
through the Gmail app, no `gmail.compose`, no learning from sent mail, Google verification) and one about
Outlook fell away when mail was set aside; the rest are renumbered here.

1. **The Display, the watch and voice stage a send on the phone rather than sending** (§6.4). It is the
   only route iOS allows without the wearer tapping Send.
2. **Email hand-off:** Apple's Mail composer, else `mailto:` (the wearer's default mail app), else copy.
3. **Google calendars through iOS Calendar, with a helper, and no Google sign-in** (§9). (Replaces the
   first draft's `calendar.readonly` sign-in.)
4. **Short night is opt-in, and sleep is never said aloud unasked.**
5. **Drafts on this iPhone first; the cloud only with consent; never under Medical Local Only or HIPAA;
   meeting follow-ups never on blocked routes.**
6. **What may be pushed to the lens unasked:** only leave-by within 10 min, running late and on my way
   (§6.2).
7. **No Agent Mode gate.** Cards have their own switch under My Day, as DY's briefing does.
8. **Field Assist cards text customers from the technician's own Messages**, and an organisation profile
   (Plan [CT](CT-org-configuration-profiles.md)) can pin "Text customers from cards" off.
9. **No new name in the app.** The page stays **My Day**; cards carry a small "Ready" label and the home
   card says "N more ready".

## Phases (one PR each)

### P0 — the pure core (headless)

- `Shared/PreparedCard.swift`: the model of §1 (`PreparedCard`, `PreparedCardID`, `PreparedCardKind`,
  `CardSignal`, `CardFact`, `PreparedAction`, `PreparedDraft`, `DraftRecipient`, `CardSensitivity`),
  Codable, Foundation-only, compiled into the phone and the watch.
- `PreparedCardRules`: the personal and Field Assist kinds of §2, one function each, over a new
  `CardInputs` gathered from `MyDayInputs`, `JobDay` facts, `SleepNight?` and the latest meeting summary.
  `MeetingSummaryTool` returns its action items as a value as well as text, so the rule doesn't parse
  prose.
- `PreparedCardJoiner` and `TodayFeed` (§3): absorbing, weather and location chips, ranking, caps,
  expiry, state.
- `DraftTemplates` (catalogue strings) and `DraftValidator` (§4.4).
- `ContactLookupHelper.resolve(email:)` and attendee mapping for EventKit (`EKParticipant`), adding
  `attendees` to `MyDayCalendarEvent` (§9.3–9.4); `GoogleCalendarPresence` (§9.1).
- `GeocodingHelper` returns the sub-locality for the location chip.
- **Tests:** a table per rule (appear / not appear at each boundary: 300 m, 2 min, 90 min, 6 h, 09:30),
  joiner absorbing and caps, ID stability across rebuilds, every validator row, template
  filling in three languages.

### P1 — on the phone (headless, wired)

- `MyDayService` publishes `TodayFeed`; `MyDayView` draws cards then rows (§5.1); `MyDayHomeView` and the
  job day's home card show the top card (§5.2).
- `PreparedCardStore` (§3.5), registered as `preparedCards`; later, not useful, handed off, edits kept.
- `DraftComposer` (§7.1): the shared presenter, Field Assist moved onto it unchanged.
- The Google calendar line and its "Show me how" sheet (§9.2).
- Notifications for `immediate` cards (§5.3); settings (§5.6); VoiceOver (§5.5);
  `PreparedCardMetricsStore` (§10) and the support report's **Cards** section.
- **Tests:** view-model tests for the page and home card; composer route choice per channel and
  availability; store round-trip and erasure; notification content is generic by default; UI test of
  "edit, hand off, cancel, still there".

### P2 — drafts by a model, in the wearer's voice (headless)

- `DraftModelCall` (§4.2): isolated for every provider, on-device first, consent for the cloud, the
  blocked-route list, Medical Local Only and HIPAA respected.
- `DraftWriter` with the prompt of §4.2 and the validator; fallback to templates with the reason shown.
- `WritingStyle` and its settings page; `StyleEditLearner` and its suggestion (§4.3).
- **Tests:** a fake model returning drafts that break each validator row; no history or tools reach the
  call (asserted on the request); a cloud call is impossible without consent; the edit learner's
  thresholds.

### P3 — on the Display (headless, wired)

- `PreparedCardHUDBuilder` (pure): the stack, draft and staged screens of §6.3 from a `TodayFeed`, for
  both geometries, with `CardSensitivity` applied (§6.6).
- `HUDRouter`: a `today` stack (Next, Back, draft, Send on phone, Read it, Later, Dismiss, Close);
  launcher Quick Action; `briefing` opens the stack when cards exist; `TempleAction.today`; voice words
  "next card", "later", "not useful", "send it on my phone".
- Pushed glances (§6.2) behind `DisplayAvailability`, `frameRevision`, the X and KP precedence rules and
  quiet hours.
- Staging (§6.4): the `staged` state, the time-sensitive notification, opening the composer from it.
- The web mirror's redaction column (§6.6).
- **Tests:** builder snapshots by `renderKey` for every kind on both geometries; 3-button budget; page
  turns through `PageTurnGate`; a push never covers a task or answer card; nothing pushed while
  `.inUse`; staging posts the right notification and opens the composer; mirror redaction per row of
  §6.6.

### P4 — speech and the watch (headless)

- `PreparedCardPhraser` (§6.5) and the "what's ready" stack reading; pushed cards spoken when the
  Display can't show them.
- After KS lands: `WatchTodayPayload.cards` and the version bump; the watch's card view;
  `preparedCardAction` commands (§6.7).
- **Tests:** phrasing per kind and sensitivity (no sleep, no caption quotes); a spoken
  yes only stages; payload encoding within the application-context budget; each watch command.

### P5 — device pass (owed)

On a phone with Messages and Mail set up, a Google account added to iOS Calendar, glasses with a Display,
glasses without, and a watch: every kind appears and disappears on time; every hand-off route opens with
the right recipient and text; staging from the lens, the watch and the voice; pushed glances and their
precedence; spoken lines; VoiceOver; the Google calendar line appears without a Google calendar and goes
once one is added; attendees from a Google, an iCloud and an Exchange calendar resolve to contacts.

## Acceptance

- A leave-by, running-late and on-my-way card appears with a draft addressed to the right person, and
  the platform composer opens with that text; nothing is sent until the wearer taps Send there.
- No card shows a time, number, address or link that isn't in its source data.
- On the Display, any card is reachable from the launcher, "what's ready" and a temple tap, with at most
  three buttons per screen; a send from the lens stages on the phone and says so.
- Pushed glances obey §6.2 and never cover a task or answer card or appear while another app has the
  Display.
- Health content follows §6.6 on every surface.
- A Google calendar added to iOS Calendar feeds the cards with no sign-in in the app.
- Every new store is registered for erasure.

## Open

- **Neighbourhood names.** How often `MKReverseGeocodingRequest` gives a useful sub-locality outside
  big cities; the chip falls back to the street.
- **Running late without location permission "Always".** With "While using" only, the rule runs only
  while the app is in front; P5 measures how often that misses.
- **Detecting a Google calendar.** EventKit's source titles vary by iOS version and language; P5 checks
  the hint on a device and the line stays dismissible either way.
- **What would allow a true one-press send.** A WhatsApp or Telegram connection that can send (if the
  licence advice clears), or an organisation's own messaging endpoint (Field Assist's `endpoint`
  channel) for customer texts. Either would be its own plan.
- **Mail, later.** If the owner revisits mail, the first-draft design (reply owed, asked to meet,
  booking from reservation markup, invite waiting, on-device reading with the October report's rules)
  is in this file's history on PR 988's first commit.
