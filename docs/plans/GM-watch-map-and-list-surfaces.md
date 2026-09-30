# Plan GM — Apple Watch: Live Map, Lists, Camera Images, Workout-Backed Guidance

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Relation to Plan [CS](CS-standalone-watch-client.md):** CS (drafted 2026-08-09, unstarted) is about
the watch **asking** without the phone: `WatchCommandRoute`, a watch transcript, a direct HTTPS path.
It covers **none** of what GM does. GM is the opposite direction: the phone **shows** something on the
wrist when seeing beats hearing. It needs no CS piece and can ship first; where both touch the same
screen, GM adopts CS's rule that every unavailable state carries a stated reason.
**Relation to Plan [GA](GA-watch-phone-camera-vision.md):** GA fixes the watch's camera commands and
the stale status push. GM depends on one GA P0 fix (the phone's context push must not require
`isReachable`); if GA P0 has not landed, GM P1 makes that one change itself.
**Related:** Plans [CA](CA-walking-navigation.md) / [GL](GL-cycling-driving-navigation-and-road-alerts.md)
(the route being shown), [GF](GF-recipe-add-ons.md) (its `display` step names the watch as a target),
[GI](GI-health-summaries.md) (adds the HealthKit entitlement on the phone), FO P3a (`JobWatchPayload`,
the precedent for a keyed payload).

---

## Trigger

Some answers are bad as speech: a route ("left in 80 m, then the second right, then…"), a shopping
list, five nearby results, a picture of the traffic at the motorway junction. The watch is on the
wrist and glanceable, but today it shows only status and a 200-character `lastResponse`.

## Outcome

- While walking or cycling with guidance, the watch shows a **live map**: the route line, your
  position, the next maneuver card, and it taps the wrist before each turn.
- A **list** answer (reminders list, search results, an add-on's list) can be sent to the watch and
  ticked off there.
- An **image card** (a traffic camera frame, a map snapshot) can be sent to the watch.
- Guidance on the watch rides a **workout session**, so the screen stays live for the whole walk or
  ride instead of dropping to the watch face.
- Phone-only and glasses-free use is unchanged; the watch is an extra surface, never required.

## What exists today (verified 2026-10-01)

- `OpenGlassesWatch/`: `OpenGlassesWatchApp.swift`, `WatchMainView.swift` (status, listen/record/
  video/photo, quick actions, personas, threads, job block), `WatchConnectivityService.swift`
  (reads application context keys `isConnected`, `status`, `lastResponse`, `personas`,
  `recentThreads`, `quickActions`, job payload; `sendCommand` guarded by `isReachable`). Imports:
  SwiftUI, WatchConnectivity, WidgetKit only. `WKRunsIndependentlyOfCompanionApp` is true. The
  watch target has the App Group entitlement only: **no HealthKit, no location usage string, no
  background modes**. watchOS deployment target 26.0 (`project.base.yml`).
- Phone: `Services/WatchConnectivityManager.swift` `sendStatusUpdate()` builds one context dictionary
  and `updateApplicationContext` — but returns early unless `session.isReachable` (line 47).
  `FieldAssist/Job/JobWatchPayload.swift` adds one keyed sub-dictionary; that is the pattern GM follows.
- Route data lives in `Services/Navigation/` (`RouteStep` with polyline and maneuver, the tracker's
  active step); nothing is sent to the watch.
- The phone app itself has no HealthKit entitlement yet (Plan GI P0 adds it).

## Design

### Surfaces (pure, shared by phone and watch)

A small shared source file (compiled into both targets like `AccentColors.swift`):

- **`WatchSurface`** — `.route(RouteSnapshot)`, `.list(ListCard)`, `.image(ImageCard)`, each with
  `id`, `title`, `createdAt`, `expiresAt`.
  - `RouteSnapshot`: simplified polyline (≤ 300 points), destination, active step index, next
    maneuver text + `HUDIcon` name, distance to it, ETA, profile.
  - `ListCard`: ≤ 30 items, each `{id, text, checked}`, and `origin` (reminders, results, add-on).
  - `ImageCard`: JPEG ≤ 60 KB (phone-side downscale to watch width), caption, source.
- **`WatchSurfaceCodec`** — encode/decode with a hard byte budget; `PolylineSimplifier`
  (Douglas–Peucker to fit the point cap, endpoints and maneuver points always kept).
- **`WatchSurfacePolicy`** — decides *whether* to send: route while guiding and the watch app is
  installed; a list only when asked ("put it on my watch") or when a list answer has > 4 items and
  the wearer has turned on "Send long lists to watch"; images only when asked. Never while HIPAA mode
  is on for list/image content (route only) — decision 4.
- **`RouteDelta`** — position/step updates are small messages (`sendMessage` when reachable); the
  full route is re-sent only on start and reroute.

### Transport

- Latest surface state rides `updateApplicationContext` under key `surfaces` (latest-wins, delivered
  when the watch next wakes, no reachability needed). Live position/step deltas use `sendMessage`
  when reachable and are simply dropped when not (the next delta supersedes them).
- Images over 60 KB are refused at the codec, not truncated.
- List ticks from the watch go back as a `listToggle` command; the phone applies them to the source
  (`AppleRemindersTool`'s completion path for reminders) and echoes the new state. A tick while the
  phone is unreachable is queued on the watch with `transferUserInfo` and shown as pending.

### Watch UI

- **Map view** (SwiftUI `Map` with `MapPolyline` + user annotation): north-up by default, follow
  mode, next-maneuver card overlaid at the bottom, distance counting down in CA's bands. Haptic
  (`WKInterfaceDevice.play(.directionUp/.directionDown)` for right/left, `.notification` for arrive)
  at the approach and imminent cues, so eyes are optional.
- **List view**: checkable rows, large targets, "sent 2 min ago".
- **Image view**: full-width, caption, age ("taken 40 s ago"); stale after `expiresAt`.
- `WatchMainView` shows a "Now showing" row when a surface is active; complications are unchanged.
- Unavailable states say why: "Open the route on your phone to see it here", "Phone not nearby — the
  map will update when it's back".

### Workout-backed guidance

- When guidance starts in a walking or cycling profile and "Use a workout on my watch" is on, the
  phone asks the watch to start an `HKWorkoutSession` (outdoor walk / outdoor cycle) via
  `HKHealthStore.startWatchApp(toHandle:)`, which launches the watch app with the configuration.
  The session keeps the app frontmost-eligible with the screen live and allows watch GPS, so the
  map keeps updating from the **watch's own location** if the phone lags or is in a bag.
- Ends when guidance ends (arrival or stop) or after 10 min of no movement. Whether the workout is
  **saved to Health** or discarded is decision 2; either way the choice is stated in the setting.
- Needs on the watch: HealthKit entitlement, `WKBackgroundModes` `workout-processing`,
  `NSHealthShareUsageDescription`/`NSHealthUpdateUsageDescription`,
  `NSLocationWhenInUseUsageDescription`. Device-unverified: whether `startWatchApp(toHandle:)`
  launches reliably with the phone locked, and the battery cost of a 45-minute guided ride.
- Driving never starts a workout; the watch shows the list of road alerts (GL) at most.

### Sources that feed the watch

| Surface | Producer |
|---|---|
| Route | `WalkingRouteService` today, `RouteGuidanceService` after GL |
| List | a `show_on_watch` action on the answer (reminders lists, `find_nearby` results, notes lists); GF add-ons' `display` step `kind: list` |
| Image | a GF add-on `display` step once GF adds an `image` kind (decision 3), or a map snapshot of the destination |

Images of camera **frames from the glasses** are not a GM source: any such path would be a new
camera-pixel consumer and would have to go through `CameraService.filteredStill(for:source:)` and the
`OutboundFrameConsumer` roster. GM does not add one.

## Phases (one PR each)

**P0 — Shared surface model (pure).** `WatchSurface`, `WatchSurfaceCodec`, `PolylineSimplifier`,
`WatchSurfacePolicy`, `RouteDelta`. Tests (iOS test target; the shared file is also compiled into the
watch): `WatchSurfaceCodecTests` (budget, oversize image refused, round-trip),
`PolylineSimplifierTests` (point cap, maneuver points kept), `WatchSurfacePolicyTests` (HIPAA,
opt-ins, "asked" vs automatic), `RouteDeltaTests`.

**P1 — Route on the wrist.** Phone: `WatchSurfacePublisher` (injected session seam) fed by the route
service; context push no longer requires reachability. Watch: map view, deltas, haptics. Tests:
`WatchSurfacePublisherTests` with a fake session. Device: a real walk with the phone in a pocket.

**P2 — Lists and images.** `show_on_watch`, `listToggle` round trip, reminders completion, image
card. Tests: `WatchListToggleTests` (queued tick, echo, conflict when the item vanished).

**P3 — Workout-backed guidance.** Watch HealthKit entitlement + plist keys + background mode,
`WatchWorkoutController` (pure state: idle/starting/running/ending, 10-minute stationary end),
watch-location fallback. Tests: `WatchWorkoutStateTests`. Device (owed): locked-phone launch,
45-minute ride battery, GPS handover between phone and watch.

## Risks

- **Watch battery** under a live map; the workout session is opt-in and ends itself.
- **WCSession delivery is best effort**; the design is latest-wins and never depends on a delta arriving.
- **HealthKit review** for a navigation app starting workouts: the setting states the reason, and
  nothing is read from Health.

## Decisions for Greig

1. **Scope order:** route first (recommended), then lists, then images.
2. **Save guided workouts to Health** (visible in Fitness) or discard them after guidance?
   *Recommend ask once, default save for cycling, discard for walking.*
3. **Traffic-camera images:** extend GF's `display` step with an `image` kind (URL fetched on the
   phone, ≤ 60 KB after downscale) — or leave images to native sources only? *Recommend the GF
   extension, allowlist rules unchanged.*
4. **HIPAA:** lists and images never to the watch under HIPAA mode (recommended), route allowed.
5. Setting placement: Settings → Watch (a new section beside Glasses), not under glasses. Copy never
   names plan letters.

## Out of scope

Everything in CS (asking from the watch, direct transport, watch transcript), watch-originated
routing, offline maps, glasses camera frames on the watch, driving maps on the wrist.
