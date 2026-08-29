# Plan DY — My Day: Everyday Briefing and Preparation

**Status:** 📝 Drafted (2026-08-29)
**Origin:** The opportunity assessment names Everyday Briefing as the P1 daily-retention loop and
places it before differentiated intelligence such as the private-memory timeline.
**Priority:** P1 everyday product, immediately after the DK privacy close-out.
**Surfaces:** Phone and spoken audio first. No waveguide, HUD, or Neural Band dependency.

---

## Product promise

“Tell me what matters next, when I need to leave, and what I should prepare.”

My Day is one dependable daily view and spoken briefing, not another autonomous agent mode. It
combines information OpenGlasses can read authoritatively, ranks a small number of useful items with
deterministic rules, and offers direct actions such as opening an event, completing a reminder, or
starting directions. An LLM may make the wording natural; it never decides which commitments exist,
changes their times, or invents urgency.

## Verified starting point

Most primitives exist, but they are disconnected:

- `DailyBriefingTool` runs date/time, weather, and news in parallel and returns three labelled text
  blocks. It has no calendar, reminders, travel time, prioritization, preparation, or shared model.
- `CalendarTool` can list/create events, while `ProactiveAlertService` separately queries EventKit
  for 10-minute and imminent alerts. Neither exposes a reusable typed day snapshot.
- `AppleRemindersTool` is already registered and can create/list/complete reminders, despite Plan
  DV still saying the integration is absent. It owns a concrete `EKEventStore`, parses natural date
  strings locally, and completes the first substring match; those behaviors need the DV seam and
  ambiguity rules before My Day relies on it.
- `NotificationDigestService` already ranks and deduplicates OpenGlasses-owned calendar, geofence,
  proactive, and agent items. It is a “what changed?” queue, not a plan for the day.
- `AgentScheduler` can run a morning-briefing prompt, but only in Agent Mode and without a typed,
  authoritative input contract. It must become a trigger for My Day, not remain a second composer.
- Weather and location services exist. There is walking navigation, but no shared point-to-point
  travel-time estimator for leave-by decisions.

The gap is orchestration, prioritization, one configuration surface, and honest degraded states—not
more tools.

## Decisions and invariants

1. **One deterministic composition core.** `MyDayComposer` receives typed source snapshots and
   produces the same ordered `MyDaySnapshot` for phone, speech, Siri, and scheduled delivery.
2. **Authoritative sources only.** V1 uses EventKit calendar/reminders, Weather, MapKit routing, and
   OpenGlasses' own digest. It never claims access to arbitrary iPhone notifications or messages.
3. **No content database.** My Day is an ephemeral read model. Events and reminders remain in
   EventKit; digest items remain in their existing store. At most, content-free delivery state such
   as “morning briefing shown on 2026-08-29” is persisted.
4. **LLM wording is optional.** Selection, urgency, time math, leave-by, caps, and fallback copy are
   pure. Offline and power-reserve modes still produce the complete deterministic briefing.
5. **Actions return to the owner.** Complete reminder calls the reminder adapter; directions calls
   the navigation owner; event edits open or call EventKit. My Day never mutates a copied row.
6. **Permission denial is partial availability.** A denied calendar does not erase weather; the UI
   labels the unavailable section and offers the relevant Settings route.
7. **Quiet by default.** On-demand briefing ships first. Scheduled speech is opt-in, presence-aware,
   respects quiet hours, and never speaks private details while the wearer is away.
8. **Phone/audio first.** The phone is the configuration and review surface; audio is the eyes-free
   path. Existing digest HUD rendering may display the same bounded lines later, but no My Day phase
   depends on a display.
9. **Memory is not a prerequisite.** DX may later add one explicit “something you asked me to
   remember” preparation item through its access policy. My Day ships without reading private memory.

## Common read model

```swift
struct MyDaySnapshot: Equatable, Sendable {
    let generatedAt: Date
    let period: MyDayPeriod              // morning, daytime, evening
    let headline: String
    let items: [MyDayItem]               // bounded, deterministically ordered
    let sourceStates: [MyDaySourceState]
    let nextRefreshAt: Date?
}

struct MyDayItem: Identifiable, Equatable, Sendable {
    let id: MyDayItemID                  // source + source-owned stable ID
    let kind: MyDayKind                  // event, leaveBy, reminder, weather, update, preparation
    let title: String
    let detail: String?
    let dueAt: Date?
    let urgency: MyDayUrgency
    let source: MyDaySourceRef
    let actions: Set<MyDayAction>        // open, complete, directions, dismiss
}
```

Stable source identity prevents a calendar event and similarly named reminder from being silently
deduplicated. The snapshot contains bounded display/speech text, never raw EventKit notes, attendee
lists, full notification bodies, or hidden prompt payloads.

## Sources and ownership

| Source adapter | Authoritative owner | V1 contribution | Mutation |
|---|---|---|---|
| `CalendarDaySource` | EventKit events | Today + tomorrow preview; next timed commitment | Open/edit through Calendar owner |
| `RemindersDaySource` | EventKit reminders | Overdue, due today, and up to two priority todos | Complete exact stable reminder ID |
| `WeatherDaySource` | Existing Weather service | Current conditions and only decision-relevant forecast | Read-only |
| `TravelTimeDaySource` | MapKit + current location | Route duration and leave-by for the next locatable event | Start directions |
| `DigestDaySource` | `NotificationDigestService` | At most two still-actionable first-party updates | Dismiss/acknowledge through digest |

`CalendarTool`, `AppleRemindersTool`, `ProactiveAlertService`, and My Day must share injected
EventKit-facing adapters rather than constructing competing stores and parsing the same records four
ways. Plan DV is corrected as part of that extraction: the model supplies an absolute ISO date;
completion by text asks on ambiguity; My Day completion uses the stable reminder ID directly.

## Deterministic priority policy

`MyDayComposer` chooses at most six primary items:

1. An in-progress or imminent commitment.
2. A leave-by warning when travel time plus configurable buffer reaches the threshold.
3. Overdue reminders, then reminders due before the next event.
4. A weather condition that changes a plan: precipitation, hazardous temperature, or high wind.
5. The next later commitment.
6. Up to two actionable first-party digest updates when capacity remains.

Ties use due time and then stable ID. Routine weather, news, and informational updates never displace
an imminent event or overdue task. News is an optional “More” section, off by default; it is not part
of the retention loop promised by My Day.

### Period behavior

- **Morning:** today overview, first commitment, first leave-by, overdue/today reminders, relevant
  weather.
- **Daytime:** what is next, whether to leave, and the most actionable outstanding task.
- **Evening:** unfinished due-today reminders, first commitment tomorrow, and one preparation cue.

## Phone and spoken experience

Add a **My Day** destination to the everyday home surface:

- A plain-language headline: “Two commitments; leave for the dentist at 2:20.”
- A short ordered list with source-owned actions.
- Visible partial-source states such as “Calendar access is off.”
- Pull to refresh and a timestamp; no silent stale snapshot.
- Settings for included sources, morning/evening schedule, speech, quiet hours, travel mode/buffer,
  home/work defaults, news opt-in, and reset of content-free delivery history.

The spoken form targets roughly 20–35 seconds and stops after the primary items. “Anything else?”
reads the optional section. A deterministic formatter is always available; optional rewriting must
preserve item count, source facts, times, and action labels or be rejected wholesale.

## Phases

### P0 — Contracts and source seams 🔴

1. Add `MyDaySnapshot`, item/source/action types, `MyDayComposer`, deterministic spoken formatter,
   fake adapters, and exhaustive priority/cap/partial-availability tests.
2. Extract injected EventKit calendar and reminder read seams shared by tools, proactive alerts, and
   My Day. No unit test touches the real shared `EKEventStore`.
3. Reconcile Plan DV with shipped `AppleRemindersTool`: absolute-date input, past-date rejection,
   stable IDs, exact completion, ambiguity, and honest permission state.
4. Add `Config.myDayEnabled`, default off during construction. The flag hides surfaces/triggers and
   never deletes source data.

### P1 — On-demand My Day MVP 🟠

1. Compose calendar, reminders, and weather into the phone view and spoken command.
2. Replace `DailyBriefingTool`'s independent text assembly with the shared snapshot/composer; keep a
   compatibility tool name so prompts, Siri exposure, and user phrases do not break.
3. Route the existing AgentScheduler morning task to My Day; it no longer asks an agent to discover
   and rank the day from a free-form prompt.
4. Ship deterministic empty, loading, denied, partial, offline, and stale states with VoiceOver and
   large Dynamic Type coverage.

### P2 — Travel time and leave-by 🟠

1. Add MapKit travel-time estimation for the next event with a usable location, using current
   location or an explicit home/work origin and the configured transport mode.
2. Compute leave-by as event start minus route duration minus user buffer. Cache only route metadata
   briefly; invalidate on material location/time/route change.
3. Feed leave-by into `ProactiveAlertService` and the digest as one stable item so the same warning is
   not spoken, notified, and displayed three times.

### P3 — Evening preparation, digest, and controls 🟡

1. Add evening/tomorrow composition and one deterministic preparation cue.
2. Add at most two still-actionable digest items; never mirror arbitrary notifications.
3. Add the complete phone settings surface and opt-in scheduled delivery with presence, quiet-hour,
   offline, and power gates.

### P4 — Release and learning 🟡

1. Device tests for permission denial/regrant, timezone and daylight-saving changes, all-day and
   overlapping events, no-location events, route failure, offline weather, and locked phone.
2. Measure snapshot latency and speech duration on the oldest supported phone; no source content in
   telemetry.
3. Track opt-in, briefings requested, actions taken, dismissals, and seven-day return without
   recording titles, locations, reminder text, or generated speech.

## Rollout and exit criteria

Roll P1 out behind `myDayEnabled`; scheduled speech remains separately opt-in. A rollback hides My
Day and disables its triggers without changing Calendar, Reminders, Weather, Digest, or their data.

Complete when one shared deterministic snapshot powers phone, voice, Siri, and scheduled delivery;
calendar/reminder/weather partial failure is honest; the next commitment and leave-by agree across
surfaces; reminder completion targets a stable ID; no display hardware is required; and the full
unit, accessibility, Release, and oldest-device matrix is green.

