# Plan GL — Travel Modes by Voice (Walk / Cycle / Drive), Road Alerts, Speed Cameras (country-gated)

**Status:** 📝 Drafted (not scheduled), 2026-10-01; **revised 2026-10-02** (travel mode chosen by voice,
mode switch and comparison, re-phased so P0–P2 need no traffic provider) — nothing built.

**Suggested build order (2026-10-02, across Plans GM, GL and HH):** shared surface model (GM P0) →
watch map cards and the live route (GM P1a, P1b) → travel modes by voice, cycling then driving
(GL P0–P2) → the map in the phone conversation (HH) → lists, images and workout-backed guidance on
the watch (GM P2, P3) → road alerts and speed cameras (GL P3, P4).

**Continues:** Plan [CA](CA-walking-navigation.md) (walking turn-by-turn, shipped). CA kept v1 to
walking and left driving to CarPlay and the maps apps; GL adds the bike and car modes to the same
pure core, lets the wearer choose and change the mode by voice, and later adds road alerts.
**Related:** Plan FO P3c (`MapsHandoff` / preferred maps app), Plan
[GM](GM-watch-map-and-list-surfaces.md) (the watch map), Plan [HH](HH-conversation-map-surface.md)
(the phone map), Plan [GE](GE-automatic-offline-handoff.md) (what works without signal), Plan
[GH](GH-parking-memory.md) (walks back to the car; drive detection), Plan BV (power), Plan W (presence).

---

## Trigger

Guidance exists on foot only, and the tool says so. On a bike the wearer has to stop and look at a
phone; in a car the app can hand directions to a maps app but cannot say how long the drive is
compared with the walk, and says nothing about the crash or the queue two kilometres ahead.

## Outcome

- "Walk / cycle / drive to the harbour" starts guidance in that mode. With no mode stated the app
  picks sensibly (what you are already doing, then your default) and **asks once** when walking is
  implausible: "That's 12 kilometres — walk, cycle or drive?"
- **Mid-route:** "switch to cycling", "I'm driving now" reroutes in the new mode and speaks the new
  distance and time.
- **Without starting:** "how long by bike versus walking?" answers with a time per mode in one
  sentence.
- Later, with a traffic provider: live **road alerts** while driving, and **speed-camera warnings
  only where the current country allows them**, off by default, gated by a fail-closed table.
- Audio-first in the car. The glasses display and phone stay quiet while moving in a vehicle.

## What exists today (verified against `origin/main`, 2026-10-02)

- `Services/Navigation/`: `RouteModel.swift` (`RoutePoint`, `Maneuver`, `RouteStep`,
  `RouteGeometry`), `ManeuverPhraser.swift` (also `DistanceFormatter`, `NavigationCuePolicy`),
  `RouteProgressTracker.swift`, `WalkingRouteService.swift` (`transportType = .walking`,
  `LocationService.begin/endPrecisionGuidance`, throttled reroute). `Maneuver` is keyword-parsed from
  MapKit's **English** instruction text; spoken phrases are English literals in `ManeuverPhraser`.
- **New since the first draft (Plan GH, shipped 2026-10-01):** `WalkingRouteService` has injected
  seams — `originFix`, `localSearch`, `directions` — and `start(to:label:)` for a known coordinate.
  A headless test can now drive a start with no MapKit request; GL's service tests use them.
- **`NavigateTool`** (`navigate`): actions `start` / `stop` / `status`, one `destination` parameter,
  **no mode**. Its description reads "Start turn-by-turn WALKING directions… Walking only; driving
  belongs to CarPlay." `NavigationSettingsView` repeats "Walking routes only; driving stays with
  CarPlay." Both change in P1.
- **Three mode vocabularies already exist and disagree:** `TravelMode` in `MapsHandoff.swift`
  (driving / walking / transit, **no cycling**, unknown words default to driving),
  `MyDayTransportMode` in `MyDay/TravelTimeDaySource.swift` (walking / driving / transit, which
  already requests `.automobile` and `.transit` routes for travel-time rows), and the walking-only
  guidance. `DirectionsTool` (`get_directions`) opens a maps app and defaults to driving.
- **Activity signals:** `AppState.carPlayConnected` (set by `CarPlaySceneDelegate`),
  `Presence/MotionActivityProvider` (CoreMotion kind + confidence: automotive, cycling, walking,
  running, stationary), and `Parking/DriveEndDetector`, which already combines the two.
- **CarPlay entitlement is `com.apple.developer.carplay-voice-based-conversation` only**
  (`OpenGlasses.entitlements`, re-checked). That category gets no `CPMapTemplate`: the app cannot
  draw a map or turn cards on the car screen, and GL does not pretend otherwise.
- **MapKit, iOS 27.0 SDK (Xcode 27.0; `MKDirectionsTypes.h`, `MKDirectionsRequest.h`,
  `MKDirectionsResponse.h`, re-checked):** `MKDirectionsTransportType` = `automobile`, `walking`,
  `transit` ("only supported for ETA calculations"), `cycling` (iOS 14+), `any`.
  `MKDirections.calculateETA()` returns an `MKETAResponse` with `expectedTravelTime`, `distance`,
  `expectedArrivalDate`, `transportType` — the comparison answer needs nothing more. Requests have
  `tollPreference` / `highwayPreference` (iOS 16+), `departureDate`, `arrivalDate`; routes have
  `expectedTravelTime`, `advisoryNotices`, `hasTolls`, `hasHighways`; steps have `notice`.
  **No traffic incidents, speed limits or speed cameras are exposed.**
- **Background location is still not configured:** `UIBackgroundModes` is `audio`,
  `bluetooth-central`, `external-accessory`; nothing sets `allowsBackgroundLocationUpdates`.
  Guidance with the phone locked survives only while the audio mode keeps the process alive.
- **Offline (Plan GE):** `OfflineToolPolicy.table` classes `navigate`, `get_directions` and
  `find_nearby` as `.needsNetwork`, so on the phone-only path the model is **not offered `navigate`
  at all** — including `stop` and `status`, which need no network.
- **Medical Local Only:** MapKit search and directions are framework-owned requests with no
  `NetworkRoute`, and today `navigate` / `find_nearby` have **no** mode check (unlike WeatherKit,
  which Plan GT guarded with an injected closure). See decision 8.

## Design

### Modes on one core

`TravelProfile` (**new**: `walking`, `cycling`, `driving`) and a pure
`GuidanceParameters.for(profile:speed:)` (**new**):

| | Walking (today) | Cycling | Driving |
|---|---|---|---|
| Cue lead | distance bands (CA) | 200 m / 50 m / now | **time-based**: ~30 s and ~8 s before the maneuver at current speed, plus 2 km on roads above 80 km/h |
| Off-route | K=4, max(30 m, 1.5×acc) | K=3, max(25 m, 1.5×acc) | K=3, max(50 m, 1.5×acc) |
| Reroute throttle | 30 s | 20 s | 15 s |
| `CLActivityType` | `.fitness` | `.fitness` | `.automotiveNavigation` |

`WalkingRouteService` becomes `RouteGuidanceService` (profile per route; walking behaviour pinned by
CA's and GH's tests). `Maneuver` parsing gains driving phrases (merge, exit, keep left/right,
roundabout exits, ramps). `TravelProfile` is the one guidance vocabulary; `TravelMode` gains
`.cycling` for hand-off parity and stops defaulting unknown words to driving, and both it and
`MyDayTransportMode` get a tested mapping to and from `TravelProfile` rather than a fourth enum
growing beside them. Cycling directions are not available everywhere; an `MKError` gives "I can't
get cycling directions here — walk instead, or open your maps app?" — never a silent walking route.

### Choosing the mode (`TravelModeResolver`, new, pure, tested)

Input is a plain struct, so every row is a test: `stated`, `argument`, `activeRouteMode`, `activity`
(CarPlay connected; motion kind, confidence, seconds sustained), `defaultMode` (Settings), `recent`
(a remembered answer and its age), `straightLineMeters`. Output: `.use(profile, because:)` or
`.ask(question, options)`.

**Precedence, first match wins:**

1. **Stated in the request** — a mode word found by the deterministic `TravelModeLexicon` (below) in
   the wearer's utterance where the pipeline has it (Direct mode, the offline keyword router, the
   watch, App Intents) or inside the `destination` argument ("cycle to the harbour" passed whole).
   The wearer's own words outrank everything, including a model that filled `mode` with a guess.
2. **The tool's `mode` argument** — what the model understood. Second, not first, because models
   fill optional enums by habit; the description tells it to omit `mode` unless a mode was said.
3. **The mode of a route in progress** — "actually take me to the library instead" keeps cycling.
4. **Detected activity** — CarPlay connected → driving; CoreMotion automotive at medium/high
   confidence sustained 60 s → driving; cycling at high confidence sustained 60 s → cycling. Walking
   and stationary decide nothing (a driver at a red light is stationary).
5. **A remembered answer** from the last 30 minutes (below).
6. **The wearer's default**: "Usual way to travel" on the Navigation settings screen (*Ask me* /
   Walk / Cycle / Drive; default *Ask me*).
7. **Walking** — subject to the plausibility check.

**Asking once.** When the result came from step 6 or 7 (never from 1–5) and the straight-line
distance makes it implausible, the resolver returns `.ask`. Thresholds are data
(`TravelModePlausibility.table`, tested): walking beyond **4 km**, cycling beyond **40 km**; driving
never asks. *Ask me* as the default asks beyond **1.5 km** and walks below it. The question names the
distance and only the modes MapKit can route here: "That's 12 kilometres — walk, cycle or drive?"
The tool returns the question as its result and holds a `PendingRouteRequest` (**new**: resolved
destination, 90 s expiry); the answer arrives as `navigate(mode: …)` with no destination and
completes it. An unanswered question expires silently; nothing starts.

**Remembering (recommended).** An answer to the question is kept for **30 minutes** and used at step
5, so "and then to the supermarket" does not ask again. It never changes the Settings default by
itself. After the same answer three times running, the app offers once: "Want me to use cycling
whenever you don't say?" — yes sets the default; no is remembered and the offer is not repeated.

**Saying which mode was chosen.** Every start names the mode ("Starting cycling directions to…"),
so an inferred mode is always correctable with "no, walking".

**Words, synonyms and other languages.** `TravelModeLexicon` (**new**, data): English walk / on
foot / walking; cycle / cycling / bike / biking / ride / by bicycle; drive / driving / by car / in
the car. "Ride" alone is ambiguous with a lift and resolves to cycling only with "bike" or "cycle"
nearby or when the default or activity is cycling. The app is being localised into eleven languages
(Plan [EC](EC-ui-localization.md), UI strings; Russian complete first). Two paths, two rules:

- **Model-supplied `mode`** is language-independent: the schema is a closed English enum
  (`walk` / `cycle` / `drive`) and the description says to map the user's words from any language.
  This is the path all three LLM modes use.
- **The deterministic lexicon** is per language and only as wide as it is verified: English and
  Russian first, each other language added with its EC catalog. A language without a table yields
  **no stated mode** and falls through to step 2 — never a wrong guess.

Note the existing limits GL inherits rather than fixes: `Maneuver.parse` reads English instruction
text (non-English degrades to "continue" with the text intact) and the spoken cue templates are
English; localising spoken guidance is its own piece of work, named under Out of scope.

### Changing mode mid-route, and comparing without starting

Two new **actions** on `navigate` (the tool name stays), because each has a different outcome from
`start` and a parameter would overload it:

- **`switch`** (`mode` required): reroute from the current position to the same destination in the
  new profile, swap `GuidanceParameters`, keep the destination and the recents entry, speak
  "Switched to cycling — 3.4 kilometres, about 14 minutes." If the new mode has no route, guidance
  **continues in the old mode** and says so. "I'm driving now" in a car follows the driving rule
  below (hand-off or own voice). A `start` with a `mode` and no destination while guiding is treated
  as `switch`, so a model that picks the wrong action still does the right thing.
- **`compare`** (`destination` optional — defaults to the active or pending destination; `modes`
  optional — defaults to walk, cycle, drive, plus transit where it answers): one
  `MKDirections.calculateETA()` per mode, concurrently, each behind the existing `directions`-style
  seam. Answer in one sentence, fastest first: "To the harbour: 9 minutes by car, 14 by bike, 41 on
  foot." Transit is ETA-only in MapKit, so it can appear here and **cannot** be a guidance mode; a
  mode that fails is left out and named ("no cycling route here"). Starting nothing, it leaves a
  `PendingRouteRequest` so "OK, cycle" starts it.

`status` gains the mode and the time: "Cycling to the harbour — 2.1 kilometres, about 9 minutes."

### The tool text all three LLM modes see

`description` (replaces the walking-only text; `SystemPromptBuilder` feeds it to Direct, Gemini Live
and OpenAI Realtime alike):

> Turn-by-turn directions on foot, by bike or by car, spoken at the right moment and shown on the
> glasses display, watch and phone when present. Use for "navigate to / take me to / walk, cycle or
> drive to <place>". Actions: 'start' (needs destination), 'switch' (change travel mode during a
> route: "switch to cycling", "I'm driving now"), 'compare' (travel times by each mode without
> starting: "how long by bike versus walking?"), 'status' (distance and time left), 'stop'. Set
> 'mode' only when the user says how they are travelling, in any language; otherwise leave it out
> and the app chooses or asks. If the result is a question, ask the user and call again with their
> answer as 'mode'.

Schema: `action` — "'start' (default), 'switch', 'compare', 'status' or 'stop'."; `destination` —
"Place name or address. Needed for 'start'; optional for 'compare'."; `mode` — enum `walk`, `cycle`,
`drive`: "How the user said they are travelling. Omit if they did not say."; `modes` — array of
`walk` / `cycle` / `drive` / `transit`: "For 'compare' only. Omit for all." `get_directions` keeps its
job (open a maps app) and gains `cycling`.

### Who gives the turns in a car

Unchanged decision: **"drive to X" hands the route to the wearer's maps app (FO P3c)**, which is the
only thing that can show a map on CarPlay; GL's own spoken driving turns are for phone-only drivers
who choose them ("Guide me in the car myself" setting) — decision 2. Either way the mode resolver,
`switch`, `compare` and (later) road alerts apply.

### The mode on the watch and phone maps

The route payload (`GlanceSurface.route`, Plan GM) carries `mode` as `TravelProfile`'s raw value. The
watch and the phone map show a walk / bike / car symbol on the maneuver card and re-frame on a
`switch` (a new snapshot is sent, like a reroute). Cue timing travels in the delta from the phone's
`NavigationCuePolicy` using `GuidanceParameters`, so wrist taps follow the mode: walking at CA's
bands, cycling at 200 m / 50 m / now. In a car `DrivingSurfacePolicy` sends no map to the wrist and
the phone map does not auto-present.

### Without signal

Routing and ETAs need the network; the pure tracker does not. GL P1 reclassifies `navigate` from
`.needsNetwork` to `.degraded` in `OfflineToolPolicy.table` and makes the split explicit per action
(`NavigateOfflineBehaviour`, **new**, pure):

| Action offline | What the wearer hears |
|---|---|
| guidance already running | cues continue from GPS; nothing is said about the signal |
| off-route while offline | "You're off the route and I can't get a new one without signal." once; cues resume if they rejoin |
| `status`, `stop` | work as normal (today they are unreachable offline) |
| `start` | "I can't get directions without signal. I'll try again when it's back if you ask." |
| `switch` | "I can't change the route without signal — carrying on with the walking route." |
| `compare` | "I can't check travel times without signal." |

### Road alerts (later phase, unchanged in substance)

- **`RoadAlert`** (pure model): `kind` (`accident`, `jam`, `roadworks`, `closure`, `hazard`,
  `speedCamera(fixed|mobile|average|redLight)`), coordinate or polyline, optional bearing, road name,
  delay seconds, severity, `validUntil`, `source`.
- **`RoadAlertProvider`** protocol; first adapter **TomTom Traffic Incidents API**. Speed-camera data
  is a separate source (a commercial dataset, or OpenStreetMap `highway=speed_camera` nodes, whose
  ODbL terms need review) — decision 1. Community reports need a backend; out of scope.
- **`RouteCorridor`** (pure): the remaining route as ≤ N bounding boxes within the provider's area
  limit. Requests carry only box corners (rounded to ~100 m) and the key: no route id, no device id,
  no destination.
- **`RoadAlertMatcher`** (pure): alerts within 40 m of the remaining polyline (and matching bearing),
  distance-along-route, adjacent jam segments merged, expired dropped.
- **`RoadAlertAnnouncer`** (pure): one announcement per alert at the profile's lead (2 km for
  accidents / closures / jams with delay ≥ 2 min, 1 km for roadworks), a 300 m reminder only for
  closures and cameras, ≤ 1 alert per 20 s. Refresh every 2 min or on reroute.
- New `NetworkRoute.trafficIncidents` (data class `location`, `publicWeb`), refused by
  `MedicalEgressGuard` in local-only mode; privacy manifest and in-app copy name the provider in the
  same PR. The map's built-in traffic **layer** is a visual-only toggle in Plan HH; spoken traffic
  belongs here.

### Speed-camera country gate (`SpeedCameraLegality`, pure, table-driven; unchanged)

- Input: ISO 3166-1 alpha-2 of the **current** position, confidence of that fix, camera kind.
  Output: `.allowed`, `.zoneOnly` (a generic "danger zone"), or `.prohibited`.
- Rows are data with `verdict`, `note`, `reviewedOn`. **No reviewed row → `.prohibited`**; an unknown
  or low-confidence country → `.prohibited`. Initial rows: `DE` prohibited, `CH` prohibited, `FR`
  zone-only; `allowed` rows only after per-country review (decision 3).
- Country from a cached reverse geocode, refreshed every 10 km or 10 min and near a border. On a
  change to anything not `.allowed`, warnings stop, queued camera alerts drop, and camera data is
  **not fetched** while there.

### Surfaces while moving

- `DrivingSurfacePolicy` (pure): in a vehicle (CarPlay connected, or automotive with speed
  > 25 km/h for 30 s) the glasses display shows nothing but an optional single arrow (off by
  default), phone cards and the phone map do not auto-present, the watch gets no map, cues are spoken
  at `.high` urgency with ducking. Cycling keeps CA's HUD cards.
- Settings: `NavigationSettingsView`, reached today from `ServicesSettingsView`'s "Walking
  Navigation" row (renamed "Navigation"; not the glasses section — everything works phone-only):
  "Usual way to travel", "Guide me in the car myself", and later "Road alerts while driving",
  "Speed-camera warnings where legal" (off). The footer drops "Walking routes only". Copy names no
  plan letters.
- **Power (BV):** under `reserve`, cues only (as CA); later, alerts refresh every 5 min.

## Phases (one PR each)

**P0 — Pure core for modes** (no provider, no MapKit call). `TravelProfile`, `GuidanceParameters`,
driving `Maneuver` phrases, `TravelModeLexicon`, `TravelModePlausibility`, `TravelModeResolver`,
`PendingRouteRequest`, `NavigateOfflineBehaviour`, `DrivingSurfacePolicy`, the `TravelMode` /
`MyDayTransportMode` mappings. Tests: `TravelModeResolverTests` (one test per precedence row; stated
beats argument; activity needs sustained confidence; stationary decides nothing; remembered answer
expiry), `TravelModePlausibilityTests` (each threshold either side; driving never asks; question
lists only routable modes), `TravelModeLexiconTests` (synonyms, bare "ride", mode word inside a
destination, a language with no table yields nothing), `PendingRouteRequestTests` (answer completes,
expiry, a new destination replaces it), `GuidanceParametersTests` (time-based lead at 50 and
100 km/h), `ManeuverParsingDrivingTests`, `NavigateOfflineBehaviourTests`, `DrivingSurfacePolicyTests`,
`TravelProfileMappingTests`. CA's tracker tests unchanged.

**P1 — Cycling and voice mode selection.** `RouteGuidanceService` refactor with walking pinned;
`.cycling` routes and the region fallback; `navigate` gets `mode`, `switch`, `compare`, the new
description and schema; the ask-once flow; the setting; `TravelMode.cycling`; `OfflineToolPolicy`
reclassification; `mode` in the route surface. Tests: `RouteGuidanceServiceTests` (fresh instance,
injected `originFix` / `localSearch` / `directions` / ETA seams, never `AppState` or a `.shared`
service: start per mode, switch keeps the destination, switch failure keeps the old route, compare
orders by time and names a failed mode), `NavigateToolModeTests` (argument parsing, question result,
answer completes), `NavigateToolDescriptionTests` (no "walking only"; names all five actions),
`OfflineToolPolicyTests` updated. Device (owed): a real ride — cue timing, wind noise, HUD glance; the
question asked and answered through Direct, Gemini Live and OpenAI Realtime; CoreMotion cycling
detection latency.

**P2 — Driving guidance and background location.** `location` background mode and
`allowsBackgroundLocationUpdates` only while guiding (App Review note: turn-by-turn navigation),
driving profile, maps-app-first default with the own-voice setting, surface policy live, CarPlay /
automotive detection feeding the resolver. Tests: `RouteGuidanceServiceDrivingTests`,
`BackgroundLocationLifecycleTests` (on at start, off at stop / arrival, via an injected location
seam). Device (owed): a drive with CarPlay and one without; phone locked for a whole route; "I'm
driving now" mid-walk.

**P3 — Road alerts.** Needs decision 1. `RoadAlert`, `RouteCorridor`, `RoadAlertMatcher`,
`RoadAlertAnnouncer` (pure, with `RouteCorridorTests`, `RoadAlertMatcherTests`,
`RoadAlertAnnouncerTests`), the provider adapter, key in the Keychain, `NetworkRoute.trafficIncidents`
+ manifest + copy, CarPlay "Road alerts" list tab. Tests: `TomTomIncidentDecodingTests` (recorded
fixtures), `RoadAlertRefreshTests` (fake clock). Device: a drive with a known incident.

**P4 — Speed cameras** (only after decision 3's reviewed rows exist). `SpeedCameraLegality` with
`SpeedCameraLegalityTests` (every row, fail-closed default, low confidence, border transition drops
pending alerts), camera source adapter, fetch suppression outside `.allowed`. Device: simulated
location routes cover the border case.

## Risks

- **A wrong inferred mode** starts the wrong kind of route; every start names its mode and "no,
  walking" is one `switch`.
- **Model habits:** a model may always send `mode: "walk"`. Precedence 1 covers the stated case; the
  description covers the rest; `NavigateToolModeTests` pins both, and the three-mode device pass is
  where this is actually found.
- **MapKit throttling** on `compare` (three or four ETA requests at once); a throttled mode is left
  out and named, never retried in a loop.
- **Legal** (cameras): the table is data with review dates, default prohibited, feature ships off.
- **Distraction:** any visual while driving is a liability; the policy defaults to audio only.
- **Provider cost and terms** scale with drivers and refresh rate.
- **Background location** raises App Review questions and battery cost; on only while guiding.

## Decisions for Greig

1. **Data provider(s) and keys** (P3/P4 only — no longer blocks P0–P2): TomTom or another for
   incidents; the camera source; a shipped key vs a wearer-supplied one. *Open — needs quotes and
   terms review.*
2. **Car turns:** maps-app-first (*recommended*) vs GL's own driving voice by default.
3. **Which countries to review** for `allowed` / `zoneOnly` before P4.
4. **Default for "Usual way to travel":** *Ask me* (*recommended* — asks only beyond 1.5 km) or Walk.
5. **Remember the answer** for 30 minutes and offer to make it the default after three in a row
   (*recommended*), or always ask.
6. **Thresholds:** walking 4 km, cycling 40 km, *Ask me* 1.5 km. *Recommend as stated; they are data.*
7. **`navigate` offline as `.degraded`** so `status` / `stop` work without signal (*recommended*).
8. **Medical Local Only and MapKit:** `navigate` and `find_nearby` are unguarded today, unlike
   weather. *Recommend the same injected mode check in P1 — Local Only refuses new routes and
   searches with the standard sentence — as a deliberate behaviour change for Medical users.*
9. **Unguided road alerts** in P3, or only on a route? *Recommend route-only first.*
10. **Glasses arrow while driving:** opt-in single arrow, or never? *Recommend never in v1.*

## Out of scope

Drawing maps on CarPlay (needs a different entitlement category), offline routing, lane guidance,
speed-limit warnings (not in MapKit), community reporting, transit **guidance** (MapKit transit is
ETA only — it appears in `compare` and nowhere else), localised spoken guidance and non-English
maneuver parsing, e-scooter or wheelchair profiles.
