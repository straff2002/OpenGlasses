# Plan GM — Apple Watch: Map Cards, Live Route, Lists, Images, Workout-Backed Guidance

**Status:** 📝 Drafted (not scheduled), 2026-10-01; **revised 2026-10-02** (map first, place / where-am-I /
nearby cards added, surface model shared with the phone map) — nothing built.

**Suggested build order (2026-10-02, across Plans GM, GL and HH):** shared surface model (GM P0) →
watch map cards and the live route (GM P1a, P1b) → travel modes by voice, cycling then driving
(GL P0–P2) → the map in the phone conversation (HH) → lists, images and workout-backed guidance on
the watch (GM P2, P3) → road alerts and speed cameras (GL P3, P4).

**Relation to Plan [CS](CS-standalone-watch-client.md):** CS (drafted 2026-08-09, unstarted) is about
the watch **asking** without the phone: `WatchCommandRoute`, a watch transcript, a direct HTTPS path.
It covers none of what GM does. GM is the opposite direction: the phone **shows** something on the
wrist when seeing beats hearing. It needs no CS piece and can ship first; where both touch the same
screen, GM adopts CS's rule that every unavailable state carries a stated reason.
**Relation to Plan [GA](GA-watch-phone-camera-vision.md):** GA (planned, nothing built as of
2026-10-02) fixes the watch's camera commands and the stale status push. GM depends on one GA P0 fix
(the phone's context push must not require `isReachable`); GA has not landed, so GM P1a makes that one
change itself unless GA P0 merges first.
**Related:** Plans [CA](CA-walking-navigation.md) / [GL](GL-cycling-driving-navigation-and-road-alerts.md)
(the route being shown and its travel mode), [HH](HH-conversation-map-surface.md) (the phone
conversation map, drawn from the same payloads), [GF](GF-recipe-add-ons.md) (its `display` step names
the watch as a target), [GH](GH-parking-memory.md) (the parked car is a `place`), FO P3a
(`JobWatchPayload`, the precedent for a keyed payload).

---

## Trigger

Some answers are bad as speech: "how far is that tower?", "where am I?", five nearby cafés, a route
("left in 80 m, then the second right, then…"), a shopping list. The watch is on the wrist and
glanceable, but today it shows only status and a 200-character `lastResponse`.

## Outcome

- **"How far is that tower?"** — the watch shows a small map with two dots (you and the place), the
  name as a header and the distance large underneath, labelled "in a straight line" when it is not a
  route distance.
- **"Where am I?"** — the watch shows your position with the street and suburb.
- **"Find a pharmacy"** — the watch lists the results with distances; a tap opens that place's map
  card; **Go** on the card starts guidance in the current or default travel mode.
- While guiding on foot or by bike, the watch shows a **live map**: the route line, your position,
  the next-maneuver card, and a tap on the wrist before each turn.
- Later phases, unchanged in substance: a **list** answer can be ticked off on the wrist, an **image
  card** can be sent, and guidance can ride a **workout session** so the map stays live for a whole
  walk or ride.
- Phone-only and glasses-free use is unchanged; the watch is an extra surface, never required.

## What exists today (verified against `origin/main`, 2026-10-02)

- **Watch target** (`OpenGlassesWatch/`): `OpenGlassesWatchApp.swift`, `WatchMainView.swift`,
  `WatchConnectivityService.swift`. Imports are Foundation, SwiftUI, WatchConnectivity, WidgetKit —
  **no MapKit, no CoreLocation, no HealthKit**. `Info.plist` has `WKRunsIndependentlyOfCompanionApp`
  true and no usage strings or background modes; the entitlement file holds the App Group only.
  `project.watch.yml` compiles `OpenGlassesWatch/` plus one shared file,
  `GlassesActivityWidget/AccentColors.swift`. Deployment target watchOS 26.0 (`project.base.yml`).
  `OpenGlassesWatch/PrivacyInfo.xcprivacy` states in its header that the watch app makes **no direct
  network access** — a `Map` view ends that, so P1a rewrites the header.
- **Watch receive path:** `session(_:didReceiveApplicationContext:)` reads flat keys (`isConnected`,
  `status`, `lastResponse`, `personas`, `recentThreads`, `quickActions`, `job`); an absent `job` key
  clears the job. `sendCommand` returns "iPhone not reachable" unless `WCSession.default.isReachable`.
- **Phone send path:** `Services/WatchConnectivityManager.swift` `sendStatusUpdate()` builds one
  dictionary and calls `updateApplicationContext` — but still returns early unless
  `session.isReachable` (line 47), and is called only after a watch command or a job change. The
  command vocabulary is the fixed set in `commandToken(_:)`; anything else is logged as unknown.
  `FieldAssist/Job/JobWatchPayload.swift` adds one keyed sub-dictionary; GM follows that pattern.
- **Spatial tools speak text only.** `NativeTools/WhereAmITool.swift` (`where_am_i`) returns an
  address string and coordinates; `NativeTools/LocationSearchTool.swift` (`find_nearby`) returns one
  sentence of names, distances and addresses and discards the `MKMapItem`s; `NavigateTool` returns a
  confirmation. None publishes a structured result, and there is no tool that answers "how far is
  X" without starting guidance — `place` needs one (P1a, below).
- **Route data:** `Services/Navigation/RouteModel.swift` (`RoutePoint`, `Maneuver` with a text arrow
  glyph, `RouteStep` with `maneuverPoint`, `inboundLeg`, `inboundDistance`), `RouteProgressTracker`
  (`activeStepIndex`, `distanceToManeuver`, `remainingDistance`), `WalkingRouteService`
  (`@Published state`, `currentHUDLine`; the tracker, steps and destination are private). Nothing is
  sent to the watch.
- **Corrections to the 2026-10-01 draft:** the phone app **has** the HealthKit entitlement now (Plan
  GI shipped it; `OpenGlasses.entitlements`), so only the watch target lacks it. The draft's
  "`HUDIcon` name" for the maneuver was wrong: `HUDIcon` (`Display/HUDScreen.swift`) has no arrows;
  the maneuver class is `Maneuver`'s raw value. A shared-source folder already exists
  (`OpenGlasses/Sources/Shared/`, compiled into the widget), which is where the model goes.

### watchOS facts (checked in the watchOS 27.0 SDK and Apple's documentation)

- **SwiftUI `Map` on the watch** (`_MapKit_SwiftUI.swiftinterface`, watchOS slice): `Map` with
  `MapCameraPosition`, `Marker`, `Annotation`, `MapPolyline`, `MapCircle`, `UserAnnotation`,
  `MapStyle` (standard / imagery / hybrid, `showsTraffic`), `MapCompass`, `MapUserLocationButton`,
  `onMapCameraChange` are all `watchOS 10.0+`, well under the 26.0 target. **Not on watchOS:**
  `MapPitchToggle`, `MapScaleView`, `LookAroundPreview`, map-feature selection, `MKMapView`.
  `MKDirections`, `MKLocalSearch` and `MKMapSnapshotter` exist on watchOS but GM does not call them:
  the phone resolves and routes, the watch draws.
- **No entitlement** is needed for MapKit. A `Map` that draws markers and a line from payload
  coordinates does not touch CoreLocation, so no usage string should be needed until the watch asks
  for its own location (P3). The phone's `ParkingSettingsView` already does exactly this on iOS (a
  `Map` with a `Marker`, no location request). **Not verified on a watch** — owed device check.
- **`updateApplicationContext`** (Apple's reference): may be called when the counterpart is not
  reachable; delivered "when the opportunity arises"; property-list values only; latest wins.
  **`sendMessage`** from iOS **does not wake the watch app** and fails when unreachable; from the
  watch it wakes the iOS app in the background. Apple documents **no byte limit** for either, so
  GM's budgets are self-imposed and conservative, and the real ceiling is an owed measurement.
- **Wrist down:** the app stays frontmost and dimmed for about two minutes by default (up to an hour
  by the wearer's Return to Clock setting), updating at a reduced cadence, then goes to the
  background — where it receives no `sendMessage` and plays no haptics. A workout session keeps it
  on screen. So without P3, **turn haptics and the moving dot work only while the app is on screen**.
- **Tiles with phone-only connectivity:** a watch in Bluetooth range uses the phone's connection for
  ordinary requests; whether map tiles load promptly that way, and what the map shows with no
  connection at all, is unverified — owed device check, and every card is laid out to be useful with
  a blank map (name, distance, bearing arrow are payload text, never tiles).

## Design

### The shared surface model (pure; one file, two targets, two renderers)

`OpenGlasses/Sources/Shared/GlanceSurface.swift` (**new**, Foundation only, added to
`project.watch.yml` sources the way `AccentColors.swift` is). It is not watch-specific: the phone's
conversation map (Plan HH) renders the same values.

- **`GlanceSurface`** (**new**, `Codable`, `Equatable`): `id`, `createdAt`, `expiresAt`, `mapAllowed`
  (false under Medical Local Only — see Policy) and a `kind`:
  - `.place(PlaceCard)` — `name`, `subtitle?` (street / suburb), `coordinate`, `wearer?`
    (`WearerFix`), `straightLineMeters`, `bearingDegrees`, `routeMeters?`, `etas` (zero or more
    `{mode, seconds}` for walking / cycling / driving). Distance shown is the route distance when
    present, else the straight line with the label "in a straight line".
  - `.whereAmI(WhereCard)` — `wearer`, `street?`, `locality?`.
  - `.places(PlacesCard)` — `query`, up to **8** `PlaceRow`s (`id`, `name`, `category?`, `meters`,
    `coordinate`), `wearer?`.
  - `.route(RouteSnapshot)` — simplified polyline (≤ 300 points), destination name and coordinate,
    `mode` (Plan GL's `TravelProfile` raw value; `walking` until GL lands), active step index, next
    maneuver (`Maneuver` raw value, street, banded metres), the maneuver after it ("then …"),
    `remainingMeters`, `arrivalAt?`, `wearer?`.
  - `.list(ListCard)` — ≤ 30 items `{id, text, checked}`, `origin`.
  - `.image(ImageCard)` — caption, source, and a file reference (the JPEG travels by
    `transferFile`, not inside the context — a change from the first draft, because no documented
    size limit exists to budget a 60 KB blob against).
- **`GlancePoint`** (**new**): latitude/longitude stored as `Int32` microdegrees ×10 (about 1 cm),
  so a 300-point line is 2.4 KB of `Data`. The file does not import the phone's `RoutePoint`; the
  phone-only `GlanceSurfaceBuilder` (**new**) converts.
- **`WearerFix`** (**new**): coordinate, `fixAt`, horizontal accuracy. Always the **phone's** fix.
- **`GlanceGeometry`** (**new**, pure): straight-line distance and initial bearing between two
  points, and the map region that frames a set of points with padding for the card overlay.
- **`GlanceSurfaceCodec`** (**new**): property-list encoding with a hard byte budget per consumer.
  The watch budget: **48 KB** for the whole `surfaces` value, **8 KB** for a delta. Over budget is
  refused with a reason, never truncated silently; `places` drops trailing rows to fit and says how
  many it dropped.
- **`PolylineSimplifier`** (**new**): Douglas–Peucker to the point cap; endpoints and maneuver points
  always kept.
- **`RouteDelta`** (**new**): `surfaceId`, wearer fix, active step index, banded metres to the
  maneuver, remaining metres, `cue?` (`approach` / `imminent` / `arrived` / `rerouting`). The full
  route is re-sent only on start, reroute and mode switch.

### Where the wearer's dot comes from

**The phone sends it** (decision 1). Reasons: the phone already holds a fix for every one of these
answers (`LocationService.awaitFix`), so static cards need **no watch location permission, no usage
string and no new prompt**, and P1a can ship without touching the watch's privacy posture beyond the
map tiles; and one source of truth means the distance on the wrist is the distance that was spoken.
The watch's own location is used only in P3, where the workout session already requires the
permission and the phone may be in a bag.

**Staleness (`WearerDotFreshness`, new, pure, tested):**

| Surface | Fresh | Aged | Stale |
|---|---|---|---|
| place / where-am-I / places | < 60 s: solid dot | 60 s – 5 min: solid dot + "2 min ago" | > 5 min: grey hollow dot, distance greyed with "as of 10:42" |
| live route | < 10 s since the last delta | 10 – 30 s: dot + "updating…" | > 30 s: grey dot, countdown replaced by "Phone not nearby — the map will catch up" |

The dot never moves by dead reckoning; a stale dot says it is stale.

### When a map goes to the wrist (`GlanceSurfacePolicy`, new, pure)

- **Route:** automatically while guiding, when the watch app is installed
  (`WCSession.isWatchAppInstalled`).
- **Place / where-am-I / nearby:** two candidate rules — *always when the watch app is installed and
  the answer is spatial*, or *only when asked* ("show me on my watch"). **Recommended: always**
  (decision 2). The context push is latest-wins and costs one small dictionary; the wearer who does
  not look loses nothing; and "only when asked" makes the feature invisible to the people it is for.
  Automatic cards arrive **silently** (no haptic); an explicit "show me on my watch" plays one tap.
  Setting: Settings → Devices & Privacy → Apple Watch → "Maps on your watch": *Automatically* /
  *Only when I ask* / *Never*. Copy names no plan letters. This is not a glasses setting.
- **Lists and images:** unchanged — a list only when asked, or when it has more than 4 items and
  "Send long lists to watch" is on; images only when asked.
- **Medical Compliance.** Map cards carry location and place names, no health data. With Medical
  Compliance on, **route / place / where-am-I / places are allowed; lists and images are not**
  (unchanged rule, decision 6). With **Medical Local Only** on, the card is sent with
  `mapAllowed: false`: the watch draws the text card (name, distance, bearing arrow, maneuver) and
  **no `Map` view**, because map tiles are fetched from Apple around the wearer's position and that
  is location leaving the devices — the same reasoning the shipped weather plan applied to WeatherKit
  (a framework-owned request gets no `NetworkRoute`; the mode is checked by an injected closure over
  `MedicalEgressGuard.currentMode()`).
- **Expiry:** place / places 15 min, where-am-I 5 min, route until guidance ends. An expired card is
  removed from the context (absent key clears, as `job` does).

### Transport

- Latest state rides `updateApplicationContext` under one key, `surfaces` (current card + the live
  route if any). Needs no reachability; the early `isReachable` return in `sendStatusUpdate()` goes.
- `RouteDelta`s use `sendMessage` when reachable and are dropped when not; the next one supersedes
  them. Rate: on a banded-distance change, a step change or a cue, and at most once every 2 s.
- Watch → phone commands (added to `commandToken`'s set): `startGuidance` (`surfaceId`, `placeId`),
  `stopGuidance`, `listToggle`. `startGuidance` carries **no mode**: the phone resolves it with Plan
  GL's `TravelModeResolver` (walking until GL lands). Replies are honest in GA's four kinds: started,
  refused with a reason, or "Open Avenkin on your iPhone to start" when the phone cannot begin
  location updates from the background.
- List ticks: unchanged from the first draft (`listToggle`, echo, `transferUserInfo` queue when
  unreachable, shown as pending).

### Watch UI

- **Place card:** header = name (2 lines, Dynamic Type), a small non-interactive `Map` framing both
  dots (`GlanceGeometry` region; coral marker for the place, the standard blue for the wearer),
  distance large beneath, "in a straight line" in the caption style when applicable, then ETA chips
  per mode when present, then **Go**. With `mapAllowed` false or no tiles: a bearing arrow in place
  of the map.
- **Where-am-I card:** street large, locality beneath, the map centred on the dot, accuracy ring
  when accuracy is worse than 50 m.
- **Places list:** rows of name, category, distance; tap → that row's place card (built on the watch
  from the row and the shared wearer fix; no round trip).
- **Live route:** `Map` with `MapPolyline` (coral, the app accent `#E77F47`), the wearer's dot as an
  `Annotation` from deltas, north-up, camera following the dot; a maneuver card over the bottom
  (arrow from `Maneuver`, banded distance, street, "then …"). The mode shows as a small symbol on
  the card (walk / bike / car). Crown zooms.
- **Haptics** at the cues (`WKInterfaceDevice.play`): `.directionUp` / `.directionDown` for
  right / left, `.notification` for arrival, `.retry` for rerouting. Cue timing comes from the
  phone's `NavigationCuePolicy` in the delta, so the wrist and the voice agree; cycling and driving
  timing is GL's `GuidanceParameters`.
- **Always-On:** when the scene is not active the countdown shows banded distance only (no sub-second
  change) and the map stops camera animation.
- `WatchMainView` gains a "Now showing" row when a surface is active. Complications unchanged.
- Unavailable states say why: "Ask on your phone or glasses to see it here", "Phone not nearby — the
  map will catch up", "Maps are off while Medical Local Only is on".
- **Accessibility:** each card has one VoiceOver summary ("Sky Tower, 1.2 kilometres north-east in a
  straight line, as of 2 minutes ago"); the map itself is hidden from VoiceOver.

### Workout-backed guidance (P3, unchanged in substance)

- When guidance starts in a walking or cycling mode and "Use a workout on my watch" is on, the phone
  asks the watch to start an `HKWorkoutSession` (outdoor walk / outdoor cycle) via
  `HKHealthStore.startWatchApp(toHandle:)`. The session keeps the app on screen and allows watch
  GPS, so the map follows the **watch's own location** when deltas stop (the watch dot is then
  `UserAnnotation`, labelled as the watch's fix).
- Ends when guidance ends or after 10 min of no movement. Saved to Health or discarded: decision 4.
- Needs on the watch: HealthKit entitlement, `WKBackgroundModes` `workout-processing`,
  `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`,
  `NSLocationWhenInUseUsageDescription`. The phone already has the HealthKit entitlement.
- Driving never starts a workout; in a car the watch shows no map (GL's `DrivingSurfacePolicy`).

### Sources that feed the watch

| Surface | Producer |
|---|---|
| place | a new `distance_to` action — on `find_nearby` (`query` + `nearest: true`) rather than a new tool, so the model has one place tool; also the parked car (`ParkingTool`), and a tapped `places` row |
| whereAmI | `WhereAmITool` |
| places | `LocationSearchTool` (keeps its `MKMapItem` coordinates instead of discarding them) |
| route | `WalkingRouteService` today, `RouteGuidanceService` after GL |
| list | `show_on_watch` on an answer; GF add-ons' `display` step `kind: list` |
| image | a GF `display` step once GF adds an `image` kind (decision 5), or a destination snapshot |

Tools do not talk to WatchConnectivity. Each returns its sentence as today **and** hands a
`GlanceSurface` to `GlanceSurfaceBus` (**new**, a small `@MainActor` publisher owned by `AppState`,
injected into the tools); the watch publisher and the phone map (Plan HH) both subscribe. Camera
frames from the glasses are not a source: that would be a new camera-pixel consumer and would have to
go through `CameraService.filteredStill(for:source:)` and the `OutboundFrameConsumer` roster.

## Phases (one PR each)

**P0 — Shared surface model (pure).** `GlanceSurface` and its cards, `GlancePoint`, `WearerFix`,
`GlanceGeometry`, `GlanceSurfaceCodec`, `PolylineSimplifier`, `RouteDelta`, `WearerDotFreshness`,
`GlanceSurfacePolicy`; the file added to both targets (watch builds, draws nothing yet). Tests (iOS
test target): `GlanceSurfaceCodecTests` (round trip per kind, budget, `places` row drop, oversize
refused), `GlanceGeometryTests` (distance, bearing, framing region incl. the antimeridian),
`PolylineSimplifierTests` (cap, maneuver points kept), `WearerDotFreshnessTests` (every table row),
`GlanceSurfacePolicyTests` (three setting values, asked vs automatic, Medical Compliance, Local Only
→ `mapAllowed` false, watch app not installed), `RouteDeltaTests`.

**P1a — Static map cards on the wrist.** Phone: `GlanceSurfaceBus`, `GlanceSurfaceBuilder`,
`WatchSurfacePublisher` (**new**, over an injected `WatchSessioning` seam — never `WCSession.default`
in a test), `where_am_i` / `find_nearby` / parking publish cards, the `distance_to` action, context
push without the reachability guard, the setting. Watch: decode, place / where-am-I / places views,
**Go** → `startGuidance` (walking). Watch `PrivacyInfo.xcprivacy` header and the privacy page updated
for map tiles in the same PR. Tests: `WatchSurfacePublisherTests` (fake session: pushed when
unreachable, expiry clears the key, Never sends nothing), `GlanceSurfaceBuilderTests` (from stub map
items and fixes — no MapKit request), `WatchStartGuidanceCommandTests` (reply kinds),
`LocationSearchSurfaceTests` (tool with injected search seam publishes rows in spoken order).

**P1b — Live route on the wrist.** `WalkingRouteService` exposes a read-only guidance snapshot (steps,
active index, remaining) for the builder; route surface on start / reroute; deltas; watch route map,
maneuver card, haptics, Always-On behaviour. Tests: `RouteSurfaceFeedTests` (fresh service instance
with the existing `originFix` / `localSearch` / `directions` seams: snapshot on start, new snapshot
on reroute, deltas rate-limited, cue carried once), `WatchHapticMappingTests` (pure cue → haptic).
*Why split:* P1a touches three tools and the transport and is verifiable in a simulator pair; P1b
changes the guidance service and can only be judged on a real walk. Separate PRs keep the first
reviewable and shippable while the second waits for a device pass. If the owner prefers one PR, the
order inside it is the same.

**P2 — Lists and images.** `show_on_watch`, `listToggle` round trip, reminders completion, image by
`transferFile`. Tests: `WatchListToggleTests` (queued tick, echo, conflict when the item vanished),
`ImageCardTransferTests`.

**P3 — Workout-backed guidance.** Watch HealthKit entitlement, plist keys, background mode,
`WatchWorkoutController` (**new**, pure state: idle / starting / running / ending, 10-minute
stationary end), watch-location dot. Tests: `WatchWorkoutStateTests`.

### Owed device checks (nothing below is verified)

1. `Map` on a real watch with no location usage string: draws, no prompt, no crash.
2. Tile loading with the watch on Bluetooth only, on its own Wi-Fi, and with no connection.
3. The largest `surfaces` context and delta that deliver reliably (to replace the 48 KB / 8 KB guesses).
4. Context delivery latency from a spoken answer to the card appearing, watch app closed and open.
5. Wrist-down: what the route map shows dimmed; how long before the app leaves the screen.
6. **Go** from the wrist with the phone locked in a pocket: does guidance start, or does it need the
   phone opened (when-in-use location from a background launch).
7. A real walk: dot lag, haptic timing against the spoken cue, battery over 30 minutes.
8. P3: `startWatchApp(toHandle:)` with the phone locked; a 45-minute ride's battery; phone ↔ watch
   location handover.

## Risks

- **Haptics need the app on screen** until P3. P1b says so in its setting footer rather than
  promising a tap that will not come.
- **Watch battery** under a live map; the workout session is opt-in and ends itself.
- **WCSession delivery is best effort**; the design is latest-wins and never depends on a delta.
- **A wrong "nearest" match** for "that tower": the card shows the name it resolved, so a wrong match
  is visible, and the spoken answer names it too.
- **HealthKit review** for a navigation app starting workouts: the setting states the reason, and
  nothing is read from Health.

## Decisions for Greig

1. **Wearer's dot:** phone-supplied for all cards, watch location only inside the workout phase
   (*recommended*) — or ask for watch location in P1.
2. **Automatic vs asked** for place / where-am-I / nearby cards. *Recommend automatic and silent,
   with the three-way setting.*
3. **P1 as two PRs** (static cards, then live route — *recommended*) or one.
4. **Pull the workout phase forward?** Without it, turn taps stop when the watch returns to the
   clock. The stated build order leaves it after the phone map; *recommend keeping that order but
   deciding after the first real walk with P1b.*
5. **Save guided workouts to Health** or discard. *Recommend ask once; default save for cycling,
   discard for walking.*
6. **Traffic-camera images:** extend GF's `display` step with an `image` kind — or native sources
   only. *Recommend the GF extension, allowlist rules unchanged.*
7. **Medical Compliance:** map cards allowed, lists and images not; **Local Only** shows text cards
   with no map (*recommended*).
8. **`distance_to`** as an action on `find_nearby` (*recommended*) or a separate tool.
9. Setting placement: Devices & Privacy → Apple Watch (a new screen beside Glasses).

## Out of scope

Everything in CS (asking from the watch, direct transport, watch transcript), routing computed on
the watch, offline maps, glasses camera frames on the watch, a map on the wrist while driving,
satellite / 3D styles on the watch.
