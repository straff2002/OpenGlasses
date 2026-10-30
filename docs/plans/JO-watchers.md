# Plan JO — Watchers ("tell me the score", "tell me when they announce a show near here", "I'm waiting on a letter")

**Status:** 📝 Drafted (not scheduled), 2026-10-21 — nothing built. Owner decisions taken the same day,
see [Decisions](#decisions-for-greig-taken-2026-10-21). Errands and the leaving-home offer added
2026-10-31 as P4; their decisions are still [open](#errand-decisions-open).
**Builds on:** `AgentScheduler` (typed tasks, as Plan [IW](IW-goals-and-activity-trail.md) P2's goal
check-ins), `AgentNotificationQueue`, Plan [BZ](BZ-notification-digest.md) (digest, `NotificationPriority`),
Plan [DY](DY-my-day-everyday-briefing.md) (`MyDayDeliveryPolicy`, quiet hours), Plan IW (activity
trail, goals), `PresenceMonitor`, `NetworkRouteRegistry`, `LocationService`, `MediaPlayerLibrary`.
**Sits beside:** Plan [GN](GN-agent-notebook.md) (the assistant's notes about *your* data — a watcher
is a standing question about the *outside world*; both need the same background runner, see P2),
Plan [IZ](IZ-product-lookup-and-price-alerts.md) (a price watch becomes one watcher kind rather than
its own scheduler), Plan [IX](IX-scoped-grants-and-read-only-integrations.md) (a mail source, if one is ever added,
is an IX read-only integration — not in this plan, decision 5), Plan [GG](GG-readable-memory.md) (suggestions read memory; every watcher is
readable and removable the same way a fact is).

---

## Trigger

Two things a good personal assistant does that this one cannot.

**It volunteers.** "Your team kicks off at 7:35, here's the line-up", "full time, 24–17",
"that band you play every week just announced a show in town", "there's a road closure on your way
home". Today the assistant knows none of this unless asked. The pieces that look proactive are all
about the wearer's own data — calendar alerts (`ProactiveAlertService`), My Day, goal check-ins,
geofences — and the one scheduler that could ask the outside world (`AgentScheduler`) runs a
free-text model prompt on a `Timer`, which means it only runs while something else keeps the process
alive, costs a model call every time, and can't say "only tell me if it changed".

**It connects what you're waiting for with what arrives.** "I'm waiting on a letter from the
council" should make the assistant watch for it — in calendar entries, reminders, the gateway's
events — and say so when it shows up, the way it would if
it had been told the parcel's tracking number. Nothing holds an expectation today; IW goals hold
steps, not things the wearer is waiting to *receive*.

The honest constraint underneath both: **an iOS app is not a server.** A watcher that must fire at
half-time needs the process alive at half-time. This plan builds the watcher once, runs it wherever
the app can run — alive, foreground, iOS background refresh, location wakes — and says plainly what
each of those can and can't promise. An always-on tier is named and left for later (see
[Later](#later-always-on)).

## Outcome

- **Ask once, hear it when it matters.** "Tell me the Blues scores" → a watcher: before the game (if
  the app is awake), at the end, and the half-time score when the app is listening at the time.
  "Tell me if Fat Freddy's announce a show near here" → checked a few times a day; one sentence when
  a new date within the wearer's radius appears, never again for the same date.
- **Local, coarse, and sourced.** "Tell me about anything happening around here" → local news for the
  suburb (never precise coordinates sent anywhere), and official emergency alerts where a region
  publishes them. Every finding names where it came from.
- **Noticed, then offered — never silently set up.** "You've asked about the Blues three times this
  fortnight. Want me to tell you their scores?" One offer, at a free moment; "no" means it isn't
  asked again for 90 days. The assistant never creates a watcher the wearer didn't say yes to.
- **Waiting on something.** "I'm waiting on a letter from the council" → an expectation watcher;
  when a matching item appears in a source the app can read (calendar, reminders, the gateway's
  events), "the council letter you were waiting on — there's a reminder from the council for
  Thursday". "What am I waiting on?" lists them.
- **Errands, when you're passing.** "Remind me to buy milk" → near a supermarket, one sentence:
  "There's a supermarket just here. You wanted milk." Leaving home: "Heading out? Want the lights off?"
  Both are offers the wearer said yes to, not a phone watching where they go by default.
- **Bounded.** At most three unprompted spoken findings a day across all watchers (the rest wait in
  the digest), never in quiet hours, a meeting or a live session, and a finding that has gone stale
  (a half-time score after full time) is dropped, not delivered late.
- **Readable.** "What are you watching?" lists them; "stop watching the Blues"; "why did you tell me
  that?" names the watcher and the source. Phone: Settings › AI & Personality › Watching, each
  watcher with its last check, last finding and a pause/remove control.
- **Honest about timing.** The watcher screen and the first confirmation say which promises hold:
  "I'll tell you the final score. If I'm listening at half-time you'll hear that too." Never a
  promise the platform can't keep.

## What exists today (verified 2026-10-21)

- `AgentScheduler` (`Services/AgentScheduler.swift`): a `Foundation.Timer`, re-armed after each
  cycle at `Config.agentConnectedInterval`/`agentDisconnectedInterval`. It runs while the process is
  alive, which in practice means while the `audio` background mode holds it (the listener, a live
  session) or the app is in the foreground. Prompt tasks go to the model; **typed** tasks (IW P2 goal
  check-ins) never reach it and have their own due policy — the shape a watcher check should take.
  Once-daily tasks are due by calendar day (`ScheduleDuePolicy`, fixed in Plan JC).
- **No background execution of its own.** `UIBackgroundModes` is `audio`, `bluetooth-central`,
  `external-accessory`; nothing registers a `BGTaskScheduler` task and there is no
  `BGTaskSchedulerPermittedIdentifiers`. The only background-time request is
  `beginBackgroundTask` in `VaultIndexingMonitor` (finishing work already started).
- **Location wakes half exist.** `LocationService` requests Always authorization and monitors
  `CLCircularRegion`s for `GeofenceTool` — region events relaunch a suspended app. No
  significant-location-change monitoring.
- **No push.** No `registerForRemoteNotifications`, no `aps-environment` entitlement, no sender.
  `OpenClawEventClient` receives the gateway's heartbeat/cron events over a WebSocket and speaks them —
  only while the app is alive and connected.
- **Places and errands (checked 2026-10-31).** `GeofenceTool` needs a named place and shares iOS's
  20-region cap (`Armability.atCapacity`). `SaveLocationTool` keeps the wearer's named places.
  `SafetyRule` holds a `HomeRegion` for its "block actuation away from home" rule, which is off until
  a home is set. `MKLocalSearch` is already in use (`WalkingRouteService`, `LocationSearchTool`).
  `AppleRemindersTool` reads Reminders. Nothing connects an unfinished errand to where the wearer is.
- **Delivery is solved.** `AgentNotificationQueue` (priority, reconnect delivery, "told you" log),
  `NotificationDigestService` + `NotificationPriority` (staleness: low 30 min, medium 2 h, high never),
  `MyDayDeliveryPolicy` (quiet hours, protected data), `PresenceMonitor`, `HeldRecommendationStore`.
- **Activity trail** (IW): `ActivityRecorder`/`ActivityStore` record what the assistant did; a
  finding becomes an entry.
- **Sources today:** `NewsTool` reads a news RSS search with a fixed US locale (`hl=en&gl=US`);
  `WebSearchTool` returns free text only (and is `hipaaDisabled`, untrusted-output). No sports,
  events or local-alerts source. `NetworkRouteRegistry` is where a new egress is declared.
- **Taste on the device:** `MediaPlayerLibrary` queries the on-device library (albums, playlists,
  songs) for playback; play counts and last-played dates are available on the items but not read.
- **Mail:** compose only (`send_via channel:email`); IX records that there is no mail-reading tool.
- **Drafted neighbours:** GN plans a `BGAppRefreshTask` pass as its P2; IZ's price watch needs
  "checked once or twice a day" and names DZ PR6 (durable scheduler, unbuilt) as a dependency.

## Design

### The watcher

```swift
struct Watcher: Codable, Identifiable {
    let id: UUID
    var kind: WatcherKind          // .fixture(team) .artistShows(artist, radiusKm) .localNews(area)
                                   // .topic(query) .price(productRef) .expectation(Expectation)
    var label: String              // "Blues scores" — what the wearer hears and sees
    var origin: Origin             // .asked(utteranceAt) | .acceptedSuggestion(because)
    var state: State               // .active | .paused | .ended(reason)
    var lastChecked: Date?
    var seen: [String]             // fingerprints already told (bounded, oldest dropped)
    var endsAt: Date?              // a fixture watcher can end with the season; an expectation after 30 days asks "still waiting?"
}
```

Stored in one `JSONStore` file, registered in `DataStoreRegistry` (erasure, export). Not memory: a
watcher is not ingested into `BrainStore`; a fact the wearer says while making one ("I support the
Blues") goes through the normal memory path.

### Sources — typed, pure parsers, one route each

`protocol WatchSource { func observations(for: WatcherKind, area: CoarseArea?) async throws -> [Observation] }`
where `Observation` is typed (`.fixture(kickoff, teams, score?, status)`, `.event(artist, venue, city,
date)`, `.headline(title, publisher, published, link)`, `.price(...)` from IZ, `.item(source, text,
date)` for expectations). Each source is a `NetworkRoute` (declared, egress-classified, `.publicWeb`,
`blockedWhenLocalOnly`) using `BoundedHTTPClient`; its parser is pure and tested from recorded
fixtures. Output is untrusted (never instructions; phrased from typed fields, not passed raw).

**Sources follow the wearer's region (decision 2).** There is no single worldwide list of sports,
event or local-news providers, so the app ships a versioned, bundled `WatchSourceCatalog`: for each
watcher kind, an ordered list of providers keyed by country (ISO region from the device locale, or the
watcher's `CoarseArea` when it names another country), each with its coverage (sports codes and
leagues, cities), terms note and route. A kind with no regional provider falls back to the
generic one — news search for the country, then web search phrased into typed fields with "I think"
— and the watcher screen says which source a watcher uses. Starting points known at drafting: a
regional event-listing provider for New Zealand (and possibly Australia) with a free developer API
and location filtering; a worldwide sports-data provider whose rugby, league and cricket coverage
appears to sit on a paid tier (verify against its own pricing at P1); the news feed with the device's
country instead of a fixed US locale. **Official alerts do have a list:** the WMO Register of
Alerting Authorities names each country's alerting authorities and, for many, a Common Alerting
Protocol feed — the catalogue's alert entries are seeded from it and checked by hand, since entries
can be missing or stale. Adding a country is a catalogue entry plus a parser fixture, not new code
when the provider's format is already supported.

**Location is coarse by construction.** `CoarseArea` is a suburb/city name from reverse geocoding (on
the device) or coordinates rounded to ~1 km; precise coordinates never leave the phone for a watcher.

### Matching (`WatchMatcher`, pure, deterministic)

Observation + watcher + `seen` → `Finding?` with a fingerprint and a `because`. New-since-seen
semantics (a show date, a final score, a headline id are each told once). Thresholds are rules, not
model judgement: inside the radius, after the watcher was made, not older than the source's staleness
bound. An expectation matches by the wearer's own words plus the sender/subject tokens they gave,
and reports *where* it matched; a weak match is said as "this might be the letter you meant".

### Cadence (`WatchCadence`, pure)

Each kind proposes its next check: a fixture watcher schedules around kickoff (before, half-time,
expected end + margin, then a final-score retry); show and news watchers a few times a day; an
expectation when its sources change (digest refresh, calendar/reminder change, gateway event) plus
daily. Cadence is a wish; the runner checks what is due whenever it gets the chance.

### Delivery (`WatchDeliveryPolicy`, pure)

Reuses `MyDayDeliveryPolicy`'s context (quiet hours, presence, busy, protected data) and GN's
rules: no speech in a meeting or live session; **≤ 3 unprompted spoken findings a day across all
watchers, ≥ 60 min apart** (decision 6); each finding carries a time-to-live (half-time score: until
full time; a show announcement: a day; a news item: 2 h) and is dropped when it lapses. Allowed →
`agentNotificationQueue.enqueue` at a mapped `NotificationPriority`; otherwise a digest entry. Phone-
only wearers (no glasses) get a local notification in place of speech.

### Wording

A deterministic `WatchPhraser` floor from typed fields ("Full time: Blues 24, Chiefs 17.") is the
default and costs nothing. A model rewrite is optional and off by default — a watcher check never
needs a model call.

### The runner and when it runs

`WatchRunner.runDue(now:budget:)` — one entry point, called from:

1. **Alive:** an `AgentScheduler` typed task (like goal check-ins) — never a model prompt.
2. **Foreground and wake-word catch-up:** on becoming active, and right after a wake word, run what
   is overdue (cheap; bounded to a few seconds).
3. **iOS background refresh** (P2): one `BGAppRefreshTask` identifier shared with GN's pass through
   a single `BackgroundRefreshCoordinator` — whichever plan lands first builds it, the other plugs in.
   Hard ~25 s budget, cancellation honoured, cloud-free (watchers need no model). iOS decides when.
4. **Location wakes** (P2): significant-location-change (or region exit around home) re-evaluates
   `.localNews` watchers for the new area.

What each can promise is written into the watcher's confirmation and screen (see Outcome): the
final score and "a show was announced today" are realistic in the background; half-time and
minute-level news are only realistic while the app is alive.

### Suggestions — notice, then offer (`WatchSuggester`, pure)

Inputs, all on the device: repeated asks in recent conversations (the same team/artist/topic ≥ 3
times in 14 days, from the tool-call trail, not transcripts), GG memory facts in preferences/places,
and on-device library play counts (top artists over 30 days). Output: at most one suggestion a day,
with a `because`, delivered through `WatchDeliveryPolicy` as a question. Yes → a watcher with
`origin: .acceptedSuggestion`; no → that subject is not offered again for 90 days; "stop suggesting
these" turns suggestions off. No part of this plan needs Agent Mode (decision 1): suggestions have their own
"suggest things to watch" switch in the Watching screen.

### Expectations and digging

`Expectation { text, senderHints, subjectHints, sources, expiresAt }`. "I'm waiting on…" and IW goal
steps phrased as waiting ("wait for the quote from the plumber") create one. Sources in order of
availability: calendar, reminders, the gateway's events (P3). Mail is not a source (decision 5). Digging is the same matcher
run on demand: "is there anything about reference 48-2211?" searches the readable sources for the
token and reports matches with where they were found — never a guess at what the reference is.

### Errands and the leaving-home offer

Both are watchers, so they get the matcher, delivery caps, screen and removal above; only the trigger
is new. They belong here because the hard part is restraint, which this plan already has rules for.

**What counts as an errand.** `WatcherKind.errand(item, placeKind)` holds a thing and the kind of
place that has it (`supermarket`, `pharmacy`, `hardware`…). It comes from the wearer saying so, or
from one Reminders list the wearer picks, and from nowhere else. Scanning notes for words like "get"
or "pick up" is out: "pick up the kids" and "get the invoice to the office" aren't shopping. Saying "remind me
to buy milk" can be followed by one offer: "Want me to tell you when you're near a shop?"

**When it runs.** `WatchRunner` needs a wake, and the app can't track position all day. So:

1. Significant-location-change (P2 of this plan) wakes the app after a real move.
2. On that wake, with errands pending, search a ~1 km tile with `MKLocalSearch` filtered to the
   errands' place kinds. Only the tile's rounded centre leaves the phone, in keeping with
   `CoarseArea`. Results are cached per tile for a day; the precise position is compared on the phone.
3. The nearest few shops become `CLCircularRegion`s (at most 5, ~150 m). Entering one is the trigger.
   Errand regions are reserved last and released first, so the wearer's own geofences always win
   the 20-region cap.

**`ErrandPolicy` (pure)** turns a wake into a `Finding` or nothing: the fix is good enough (accuracy
under 100 m), the wearer isn't within 400 m of home, where a nearby shop tells them nothing, the same shop
hasn't been mentioned in 3 hours, the same item not in 12 hours. Findings use `WatchDeliveryPolicy`
as they stand (daily cap, quiet hours, no speech in a meeting or live session) with a 10-minute
time-to-live: past the shop, the moment has gone. A finished reminder ends its errand.

**Leaving home.** Exiting the wearer's home region is the trigger, and it only offers. It's an opt-in
watcher naming one Home Assistant or HomeKit scene ("Want me to run Away?"). Three things to note:

- The offer has to leave the app listening for the answer, and `AgentNotificationQueue.enqueue` has
  no way to ask that. P4 adds it.
- A yes goes through the normal tool path and confirmation; the watcher runs nothing itself.
- The "block actuation away from home" safety rule fires at exactly this moment, because the wearer
  has just left the region. The rule stays as it is, and the offer isn't made while that rule is on
  unless the wearer has explicitly allowed this one scene.

**Gates.** Location Always is required, and without it the watcher says it can't work rather than
half-working. HIPAA mode: errands off, because a place search is egress. Local-only: blocked.
Field Assist: errands don't run during a job, so a van's day of stops can't set them off.

### Gates and modes

- **HIPAA mode:** watchers off (every source is public-web egress, as `WebSearchTool`); expectations
  over calendar/reminders still work.
- **Local-only mode:** sources blocked (`blockedWhenLocalOnly`); expectations over local sources only.
- **Organisation profile** can pin watchers and suggestions off.
- **Power:** no background checks under `reserve`; `conserve` halves cadence.
- **Privacy copy and `PrivacyInfo.xcprivacy`:** each new route is disclosed in the same PR — the
  source learns the team/artist/area being watched, nothing else.

## Phases (one PR each)

**P0 — Watcher core (headless).** `Watcher`/`WatcherKind`/`Observation`/`Finding`, `WatcherStore`
(+ `DataStoreRegistry`), `WatchMatcher`, `WatchCadence`, `WatchDeliveryPolicy`, `WatchPhraser`,
`WatchRunner` with an injected clock and fake sources; the `watch` tool (add / list / pause / remove /
"why did you tell me"); the alive-only typed scheduler task; activity-trail entries. First real
source: `.topic` over the existing news RSS (locale taken from the device, not fixed US). Tests:
matcher dedupe and staleness, cadence around a kickoff, delivery caps/quiet hours/TTL drop, phraser
floor, store round-trip and erasure.

**P1 — Sources.** Fixtures/scores, artist shows, local news by `CoarseArea`, official alerts where a
region publishes a feed; each a declared route + pure parser + recorded fixtures; the Watching screen
in Settings with honest timing copy. `WatchSourceCatalog` with the New Zealand entries first, the
generic fallback for every other country, and the alert entries seeded from the WMO register;
providers chosen per decisions 2–4; privacy copy + manifest.

**P2 — Background.** `BackgroundRefreshCoordinator` (`BGAppRefreshTask`, `fetch` mode,
`BGTaskSchedulerPermittedIdentifiers`), significant-location-change wakes, foreground/wake-word
catch-up. Pure budget/cancellation logic tested headless; **device pass owed** (a fixture's final
score heard after a locked evening; a show watcher firing on a morning unlock).

**P3 — Suggestions and expectations.** `WatchSuggester` (repeated asks, memory facts, library play
counts), the 90-day decline memory, `Expectation` over calendar, reminders and gateway events, IW
"waiting" steps, and on-demand digging over those sources.

**P4 — Errands and the leaving-home offer** (after P2, which provides the location wakes).
`WatcherKind.errand`, `ErrandPolicy`, the tile search with its route and privacy copy, dynamic shop
regions with the cap rule, the Reminders-list picker, the offer after "remind me to buy…", the
leaving-home watcher and an expects-a-reply delivery. Tests: every policy rule, region reservation
at the cap, the safety-rule interaction, a finished reminder, the 10-minute drop. **Device pass
owed:** a real walk past a shop with the phone locked, a week of battery readings, and how soon a
region exit actually wakes the app, because a late wake makes both features useless.

## Later: always-on

A watcher that must fire at a given minute regardless of the phone needs a process that is always
running and a way to wake the phone: the gateway or Avenkin Office running the same watcher kinds,
and a push sender (APNs entitlement + a server-held key). That is its own plan, an **addition** to the
phone tier, never a prerequisite for it — every watcher in this plan works phone-only.

## Risks

- **Over-promising timing.** iOS background refresh is opportunistic and often silent overnight. The
  defence is the per-kind promise in the copy, and P2's device pass measuring what actually arrives.
- **Nagging.** Global daily cap, spacing, TTL drop, one suggestion a day, 90-day decline memory.
- **Source terms and rate limits.** Choose providers whose terms allow alerting use; cache; back off;
  a source failing quietly degrades to "I couldn't check the Blues score" on request, never a wrong one.
- **Interest leakage.** Queries reveal interests to the source; disclose per route, send coarse
  area only, and keep the watcher list on the device.
- **Expectation false positives.** A weak match is said as "might be"; a match always names where.

## Decisions for Greig (taken 2026-10-21)

1. **Agent Mode gate — none.** Watchers, suggestions and expectations all work without Agent Mode.
   Suggestions keep their own switch ("suggest things to watch") so they can be turned off alone.
2. **Sports data — follow the wearer's region.** A bundled per-country `WatchSourceCatalog` with a
   generic fallback, not one fixed provider; the provider per country is picked at P1 from a
   terms-and-coverage check (see [Sources](#sources--typed-pure-parsers-one-route-each)).
3. **Concert/show data — the same:** regional providers in the catalogue, default radius 50 km.
4. **Hyper-local — the same, regional:** local news for the suburb from the country's news feed plus
   the official alert feeds the catalogue lists (seeded from the WMO register); no police-scanner or
   crime-report aggregators.
5. **Mail — not in this plan.** No mail source and no mail phase; expectations and digging use
   calendar, reminders and the gateway's events.
6. **Daily cap — 3** spoken findings a day, ≥ 60 min apart, the rest in the digest.
7. **Always-on tier — its own plan later**, after P2's device pass shows what the phone tier delivers.

### Errand decisions (open)

1. **Where errands come from.** Recommended: the wearer's words plus one chosen Reminders list.
2. **Do errands share the daily cap of 3?** Recommended: yes. A separate allowance is how a phone
   becomes a nag.
3. **Leaving-home offer.** Recommended: keep it, opt-in, naming one scene, offered and never run
   unasked.

## Out of scope

Inferring watchers without asking; reading other apps' notifications (iOS does not allow it);
live play-by-play; ticket purchase; scanner/crime feeds; any model call on a routine check; reading mail;
the always-on tier (see above).
