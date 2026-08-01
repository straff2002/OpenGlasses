# Plan CA — Turn-by-Turn Walking Navigation (HUD)

**Status: ✅ Shipped (2026-08-01, P1–P3 in one PR; device-pending edges noted).** Pure core:
`RoutePoint`/`Maneuver` (keyword-parsed from MapKit's English instruction text — MapKit exposes
no maneuver field; non-English degrades to `.continueStraight` with text intact)/`RouteStep`
(maneuver point + inbound leg + inbound distance), `RouteGeometry` (haversine +
point-to-leg via local tangent projection), `DistanceFormatter` (banding: ≤15 → now, nearest
10 <100 m, nearest 50 <1 km, nearest 100 beyond; metric/imperial compact+spoken),
`ManeuverPhraser` ("← 40 m · King St" / "In 40 metres, turn left onto King Street."),
`NavigationCuePolicy` (approach once per step + imminent once), `RouteProgressTracker`
(accuracy-scaled advance/arrival radii, off-route needs K=4 consecutive fixes beyond
max(30 m, 1.5×accuracy) measured against inbound+next legs, 30 s reroute throttle; depart
passes immediately). Live edge: `WalkingRouteService` — `MKLocalSearch`
(confirm-top-candidate, open decision resolved for hands-free) → `MKDirections` walking →
step mapping (instruction applies at polyline head; synthetic arrive appended),
`LocationService.begin/endPrecisionGuidance` (Best/3 m/.fitness while guiding only),
HUD render via `showNavigation` + urgency-scaled TTS (imminent = high), throttled reroute
with spoken cue, arrival announcement, ETA/remaining in tool status. Surfaces: `navigate`
tool (start/stop/status), `NavigationSettingsView` (units override, voice cues, recents),
launcher "Navigate" branch over recent destinations. Power gate (BV): reserve = no continuous
countdown, cues only. Deferred/device-pending: real-walk GPS + reroute tuning, backgrounded
guidance, heading "face this way" cue, App Intent entry (the AppShortcut string-parameter
metadata constraint makes it a deliberate, separately-validated change), next-turn arrow
bitmap. Offline routing remains out of scope (MapKit needs network — stated in settings copy).

Hands-free pedestrian navigation: the phone plans a walking route, and each maneuver appears as
a terse HUD card and a spoken cue at the right moment — "turn left onto King Street in 40 m" —
with distance counting down, automatic step advancement, off-route rerouting, and an arrival
announcement. The user keeps their phone in their pocket and reads the next turn in-lens.

This is a genuine feature gap. What exists today is adjacent but different:

| Exists | What it is | Why it's not this |
|---|---|---|
| `NavigationAssistService` (Plan J) | Vision-based low-vision hazard/landmark aid (clock-position phrasing from the camera) | Reactive obstacle guidance, **no route, no destination, no maneuvers** |
| `LocationService` | Single `CLLocationManager` — `currentLocation`, region monitoring, `HundredMeters` accuracy | No routing, and accuracy is too coarse for step-level guidance |
| `GlassesDisplayService.showNavigation(_:icon:)` | HUD line with a navigation icon (used by offline/first-aid/assist producers) | The render surface — reusable as-is, but nothing drives it with real directions |
| CarPlay (shipped) | Driving context on the car screen | Driving is CarPlay's domain; **CA is pedestrian, glasses-first** |

No `MKDirections`/`MKRoute` code exists anywhere yet — this plan introduces routing.

## Design

### Deterministic core (the testable half — no MapKit, no GPS, no HUD)

- **`RouteStep`** (`Codable`): `instruction` (raw MapKit text), `maneuver` (`.turnLeft`,
  `.turnRight`, `.continue`, `.uTurn`, `.arrive`, `.depart`, `.roundabout`, …), `streetName?`,
  `coordinate` (maneuver point), `distanceFromPrevious` (m), `polyline` (the leg's coordinates).
- **`ManeuverPhraser`** (pure): `RouteStep` + remaining distance → a HUD line and a spoken
  phrase, banded and rounded ("← 40 m · King St" for the HUD; "In 40 metres, turn left onto
  King Street" spoken). Distance bands (e.g. now / 20 m / 50 m / 100 m / 200 m) so the line
  doesn't churn every GPS tick; maneuver → arrow icon mapping onto the existing `HUDIcon` set.
- **`RouteProgressTracker`** (pure — the heart): given the ordered steps and a stream of
  `(coordinate, horizontalAccuracy)` fixes, decide (a) the active step, (b) distance to the
  next maneuver, (c) when to **advance** to the next step (within an arrival radius scaled by
  accuracy), (d) **off-route** (perpendicular distance from the active leg's polyline exceeds a
  threshold for K consecutive fixes → emit a reroute request, throttled), and (e) **arrival**
  (within the destination radius). Pure state machine, fully unit-testable with synthetic
  coordinate sequences (straight leg, overshoot, GPS jitter, deliberate detour, arrival).
- **`DistanceFormatter`** (pure): metric/imperial by locale, HUD-compact vs spoken forms.

### Deferred edge

- **`WalkingRouteService`** (`@MainActor`): owns the `MKDirections` walking request, resolves
  the destination (`MKLocalSearch` over a spoken place name / a passed coordinate), feeds
  `LocationService` fixes through `RouteProgressTracker`, renders the active maneuver via
  `showNavigation`, and speaks cues through `TextToSpeechService` with **urgency scaling** (an
  imminent turn speaks at higher urgency, per the A2 urgency tiers). Reroute on off-route
  (throttled, with a spoken "rerouting…"). Announces arrival and, on request, ETA/remaining
  distance.
- **Location accuracy:** bump `LocationService.desiredAccuracy` to `kCLLocationAccuracyBest`
  (and `activityType = .fitness`) *while guiding only*, restoring the coarse default on stop —
  step-level guidance needs it, all-day tracking does not. Add optional heading updates
  (`startUpdatingHeading`) for a "face this way to start" cue; step advancement stays
  distance-based so heading is a nicety, not a dependency.
- **Entry points:** a `navigate` native tool (`"navigate to Blue Bottle Coffee"` — the LLM-facing
  description makes it the obvious pick for "take me / walk me / directions to …"), a HUD
  launcher item (Plan Y) for a saved/recent destination, and an App Intent (Plan BQ catalog) so
  Siri can start it.

## Honest constraints (called out, not glossed)

- **Walking only in v1.** Glasses are a pedestrian context and driving is already CarPlay's
  domain — a `.walking` transport type keeps scope tight and avoids duplicating vehicle work.
- **No live map tiles on the HUD.** The in-lens surface is a low-resolution additive display
  driven by a token DSL — text maneuver cards + a direction arrow icon only, never a rendered
  map. (A pre-rendered next-turn arrow via the bitmap escape hatch is a possible P3 polish.)
- **GPS reality.** Urban-canyon drift is real; the tracker scales its advance/off-route radii by
  reported `horizontalAccuracy` and requires K consecutive off-route fixes before rerouting, so
  a single bad fix can't thrash the route. Still, accuracy tuning is inherently device-pending.
- **Background guidance** needs the location background mode + Always/WhenInUse authorization
  already present for geofencing; guiding with the app backgrounded is a P2 on-device check, not
  assumed to work.

## Phases

### P1 / PR1 — Deterministic core 🟢
Pure, fully headless-testable.
- `RouteStep`/`Maneuver`, `ManeuverPhraser`, `RouteProgressTracker`, `DistanceFormatter`.
- Tests: phrasing/banding across maneuver types + distances, tracker advance on a straight leg,
  no false-advance under jitter, off-route detection + throttle (K-fix hysteresis), arrival
  radius scaled by accuracy, imperial/metric formatting.

### P2 / PR2 — Service + routing + entry + surface
- `WalkingRouteService`: `MKDirections` walking route, `MKLocalSearch` destination resolution,
  `LocationService` accuracy bump/restore, tracker wiring, `showNavigation` render + urgency TTS,
  throttled reroute.
- `navigate` native tool (+ stop-navigation), registered in `NativeToolRegistry`.
- Settings: units override, voice cues on/off, reroute sensitivity.
- Device-pending: real-walk GPS tracking quality, reroute tuning, background-mode guidance.

### P3 / PR3 — Polish & integration
- HUD launcher item + App Intent entry (Plan BQ catalog); heading "face this way to start" cue;
  arrival + ETA/remaining announcements; optional next-turn arrow bitmap.
- Power gate (Plan BV): under `reserve`, lengthen the location cadence / drop heading and speak
  turns without the continuous distance countdown.

## Open decisions
- Destination disambiguation when `MKLocalSearch` returns several hits — speak the top candidate
  and confirm, vs. a quick HUD pick-list (leaning: confirm-top-candidate for hands-free flow).
- Whether to co-run with Plan J's `NavigationAssistService` for low-vision users (directions +
  hazard calls together) or keep them mutually exclusive — needs a real audio-density read.
- Offline routing is out of scope (MapKit needs network); note the dependency, don't fake it.
