# Plan DV — Reminders Tool

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review — a gap two independent implementations surfaced: we have
alarms, timers, geofences, and calendar, but no Reminders/EventKit integration at all (verified — no
`EKReminder`/EventKit reference anywhere in `Sources/`).
**Priority:** Small, self-contained, high daily utility ("remind me to take the bins out when I get
home" is a canonical glasses ask).

---

## Relevant seams

- `OpenGlasses/Sources/Services/NativeTools/` — new `RemindersTool.swift`, registered in
  `NativeToolRegistry.init()` (tool description feeds `SystemPromptBuilder` — no hand list)
- `OpenGlasses/Sources/Services/NativeTools/AlarmTool.swift`, `TimerTool.swift`,
  `CalendarTool.swift` (adjacent tools — descriptions must disambiguate so the router picks the
  right one; calendar = events with times and attendees, reminders = todos with optional due/location)
- `OpenGlasses/Sources/Services/NativeTools/GeofenceTool.swift` + `LocationService` (location-based
  reminders reuse saved/named geofence regions)
- Info.plist: `NSRemindersFullAccessUsageDescription`

## Decisions and invariants

1. **The LLM parses dates; the tool never does.** The tool schema takes an ISO-8601 `due` (optional)
   — natural-language time ("next Tuesday morning") is the model's job, where it's already reliable.
   No client-side NL date parsing, ever; the relative-time guard pattern from the timer/reminder
   tools survey applies (reject a `due` in the past with an honest message rather than silently
   scheduling "now").
2. **Location reminders ride EventKit, not our geofences.** For "when I arrive/leave X", create the
   `EKReminder` with a location alarm (system-owned, survives our app being killed) targeting either
   a named saved location (via `SaveLocationTool` data / `GeofenceTool` regions) or a one-shot
   geocode. Our own `GeofenceTool` remains for TTS-on-crossing behaviors; a reminder is the OS's job.
3. **Deterministic core, EventKit at the edge.** `ReminderRequest` normalization (title casing, list
   selection, due/location validation, past-due rejection) is a pure type with headless tests;
   `EKEventStore` calls live in a thin adapter conforming to a seam so tests never touch the real
   store (house rule: never exercise shared-service device state in unit tests).
4. **Read paths too.** `list_reminders` (today / overdue / by list) makes the tool useful for the
   daily-briefing and digest surfaces (`DailyBriefingTool` gains a reminders section behind its
   existing structure). Completion by voice ("mark the bins one done") matches on fuzzy title within
   an explicit list, asks on ambiguity, never bulk-completes.
5. **Permission is asked in context.** First use triggers the EventKit prompt via the existing
   consent-surface conventions (Plan BN); denial degrades to an honest "Reminders access is off —
   I can set a timer instead" with the alternative actually offered.

## Phases

**P1 — Core + create.** Pure request normalization/validation + `RemindersStoring` seam + tool with
`create` (title, notes, due, list, location) and past-due rejection. Registry + Info.plist key.

**P2 — Read/complete + briefing.** `list`/`complete` verbs, ambiguity handling, `DailyBriefingTool`
integration. Device/manual: location-alarm firing (system behavior, not unit-testable) — verify once
on hardware alongside a geofence run.
