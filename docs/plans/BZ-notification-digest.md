# Plan BZ — Proactive Notification Digest & HUD Glance

**Status: ✅ Shipped (2026-08-01, P1–P3 in one PR).** Pure core: `NotificationPriority`
lifted out of `AgentNotificationQueue` (typealias adoption, same raw values + staleness
numbers, existing queue tests unchanged), `DigestItem`/`DigestRanker` (explicit ladder:
urgent > time-sensitive [imminent ≤15 min or geofence] > actionable > informational >
routine, ties by recency)/`DigestDeduper` (threadKey → latest; near-dup same source +
normalized body within 10 min)/`DigestStaleness` (shared age rule + seen-cap + event lapsed
>5 min)/`DigestComposer` (top-N + overflow)/`DigestLineBuilder` (fallback
`[Calendar] Standup in 8 min`, structured rewrite prompt+schema, clamp: empty/control/
over-length → template; wrong line count → all templates). Live edge:
`NotificationDigestService` (JSONStore BB semantics incl. unreadable→never-write; sources:
proactive/calendar + geofence via the existing onAlert wiring, agent queue via new `onQueued`
hook; rewrite through `completeStructured` — one-shot, never the conversation path).
Surfaces: `HUDVoiceCommand.briefing` ("what's new"/"catch me up", strict whole-phrase, global
handler in the voice chain), launcher "What's new" branch (content-gated), glance screen
(lines + "+N more" + Dismiss), spoken digest (tags stripped, overflow appended),
auto-surface-on-reconnect (urgent-only, 5 s after the queue's spoken window), `DigestSettingsView`
(enable/lines/delivery/auto-surface/clear). P3 gates: presence `.away` and power `.reserve`
suppress auto-surface; `.reserve`/offline skip the rewrite (fallback floor); dismissal marks
shown agent items delivered (`AgentNotificationQueue.markDelivered`). Device-pending:
on-glasses legibility/line-count tuning, rewrite latency. Open decision unchanged: the
morning-briefing nudge stays a spoken reminder for now; reminders/sync sources are wired
types without producers yet.

Compose OpenGlasses' *own* event streams into one ranked, deduplicated, LLM-rewritten
**digest** — a terse "here's what matters right now" glance the user can pull up on the HUD
(or hear), instead of the current one-alert-at-a-time spoken interruptions. Each item is
reduced to a single legible line with a priority policy; the digest is surfaced on demand and
kept fresh as items go stale.

## What's new vs. what exists

Today three services each fire in isolation:

| Service | Behaviour today | Gap |
|---|---|---|
| `ProactiveAlertService` | Timer-driven calendar checks → single spoken alert (10-min / 1-min / morning-briefing nudge) | No composition, no ranking, no visual glance — each alert interrupts on its own |
| `AgentNotificationQueue` | Priority (`low`/`medium`/`high`) + `isStale` + disconnected-delivery queue for agent results | Already has the ranking/staleness *model*, but it's private to the reconnect path |
| Geofence / gateway alerts | One-shot TTS on enter/exit / agent event | Never aggregated with the rest |

BZ is the missing **aggregation + ranking + rewrite + on-demand surface** over all of them.
It reuses `AgentNotificationQueue`'s `Priority`/`isStale` semantics (lifted into a shared type),
`ProactiveAlertService`'s calendar plumbing as a source, and the `GlassesDisplayService` /
`HUDRouter` interactive-screen path (Plan X/Y) as the render surface.

**Scope guard — our own sources only.** iOS does not let the app read other apps' notifications,
and Meta's closed firmware gives no on-glasses ANCS hook, so there is deliberately **no
third-party notification mirroring** here. Sources are all first-party: calendar events,
geofence enter/exit, proactive alerts, agent/gateway notifications, reminders, and (opt-in)
sync/field-queue status. This is an honest, permanent constraint — the plan does not pretend
otherwise.

## The trigger — why not "look up"

The research pattern this borrows from uses a head-up gesture ("look up = dashboard"). **DAT
0.8 exposes no head-position / IMU / glance signal** (only `thermalLevel` + registration/device
state — verified against the `.swiftinterface`), so that trigger is unavailable on Meta
hardware. The digest is instead pulled up by the input we *do* have:

- **Voice:** a new strict `HUDVoiceCommand` case (`briefing` — "what's new", "catch me up",
  "briefing", "anything for me") — matched with the same tight whole-phrase discipline as the
  existing `complete`/`skip`/`back` cases (`HUDVoiceCommand.swift`).
- **Launcher:** a "What's new" item in the Plan Y HUD launcher menu.
- **Optional auto-surface:** on glasses (re)connect, if ≥1 `high` item is pending, flash the
  digest once (respecting Plan W presence — never when the user is away).

Repeated Neural-Band tap advances through digest lines; a final "dismiss" clears them and marks
them seen. The digest can also be *spoken* (composed into one short TTS utterance) for
audio-only glasses via the existing `onAlert` path.

## Pure core (the testable half)

- **`DigestItem`** (`Codable`): `id`, `source` (`.calendar`/`.geofence`/`.proactive`/`.agent`/
  `.reminder`/`.sync`), `title`, `rawBody`, `createdAt`, `priority` (the shared
  `NotificationPriority` lifted out of `AgentNotificationQueue`), `threadKey?` (for dedup),
  `seenCount`.
- **`DigestRanker`** (pure): orders by an explicit policy — user-directed/`high` > time-sensitive
  (imminent calendar, geofence) > actionable (agent result awaiting a reply) > informational >
  routine. Ties broken by recency. Mirrors the priority ladder the source design encodes, made
  explicit and unit-tested.
- **`DigestDeduper`** (pure): collapses items sharing a `threadKey` to the latest, and drops
  near-duplicate bodies (same source + normalized body within a window).
- **`DigestStaleness`** (pure): reuses the `isStale` age-by-priority rule (`low` 30 min,
  `medium` 2 h, `high` never) and a `seenCount` cap (an item viewed ≥ N times is retired).
- **`DigestComposer`** (pure): dedupe → drop stale/seen → rank → take top-N (default 3 for the
  600-px panel, per the HUD line budget) → `Digest` (ordered lines + overflow count).
- **`DigestLineBuilder`** (pure): builds the LLM rewrite *prompt* (terse ≤ ~40-char lines,
  the priority/style rules — "state the thing, don't narrate", "no 'You have…'", keep the
  actionable verb) AND the **deterministic fallback line** (`[Calendar] Standup in 8 min`)
  used verbatim when the LLM is unavailable/offline or suppressed by power policy. The rewrite
  is validated/clamped on the way back (length cap, strip control chars) — a bad rewrite falls
  back to the template, never blanks the line.

All of the above is headless-testable with no LLM, no HUD, no device.

## Deferred edge

- **`NotificationDigestService`** (`@MainActor`): subscribes to the real sources, maintains the
  live item set, runs the composer, calls the LLM for the rewrite (with the fallback line as the
  guaranteed floor), and drives the `HUDRouter` screen + optional TTS. Owns `seenCount`
  persistence (`JSONStore`, BB salvage semantics) and dismissal.
- **Voice + launcher wiring**, auto-surface-on-connect, presence/power gates.

## Phases

### P1 / PR1 — Deterministic core 🟢
Pure, fully headless-testable.
- Lift `NotificationPriority` (+ `isStale`) out of `AgentNotificationQueue` into a shared type;
  `AgentNotificationQueue` adopts it (no behaviour change — covered by its existing tests).
- `DigestItem`, `DigestRanker`, `DigestDeduper`, `DigestStaleness`, `DigestComposer`,
  `DigestLineBuilder` (prompt + deterministic fallback + rewrite clamp).
- Tests: rank ordering across the policy ladder, thread/near-dup collapse, staleness &
  seen-cap retirement, top-N + overflow, fallback-line formatting, rewrite clamp (over-length /
  control-char / empty → template).

### P2 / PR2 — Sources + rewrite + surface
- `NotificationDigestService`: real source subscriptions (calendar via the existing EventKit
  path, geofence, proactive, `AgentNotificationQueue`, reminders), LLM rewrite with the
  fallback floor, `seenCount` persistence.
- `HUDVoiceCommand.briefing` + `HUDRouter` glance screen (one line per item, Neural-Band advance,
  dismiss = mark seen); Plan Y launcher "What's new" item; spoken-digest TTS path.
- Settings: enable, max items, voice-vs-visual-vs-both, auto-surface-on-connect toggle.
- Device-pending: on-glasses legibility/line-count tuning, rewrite latency.

### P3 / PR3 — Integration polish
- Presence gate (Plan W): suppress auto-surface + downgrade cadence when the user is away.
- Power gate (Plan BV): under `reserve`, skip the LLM rewrite (fallback lines only) and drop
  auto-surface — the digest stays available on explicit request.
- Dismissal → source acknowledgement where the source supports it (e.g. mark the agent
  notification delivered).

## Open decisions
- Whether the morning-briefing nudge in `ProactiveAlertService` should *become* an auto-surfaced
  digest (leaning yes — same content, better surface) or stay a separate spoken reminder.
- Reminders as a source: EventKit reminders vs. only calendar for v1 (calendar-first is cheaper;
  reminders can be a P2 rider).
- Top-N default and per-line character cap want a real-hardware read before locking (3 / ~40
  is the starting point from the panel budget).
