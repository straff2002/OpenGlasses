# Plan GL — Cycling & Driving Guidance, Road Alerts, Speed Cameras (country-gated)

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Continues:** Plan [CA](CA-walking-navigation.md) (walking turn-by-turn, shipped). CA kept v1 to
walking and left driving to CarPlay and the maps apps; GL adds the bike and car profiles to the same
pure core and adds road alerts.
**Related:** Plan FO P3c (`MapsHandoff` / preferred maps app, the car-screen hand-off), Plan
[GM](GM-watch-map-and-list-surfaces.md) (the watch map), Plan BV (power posture), Plan W (presence).

---

## Trigger

Guidance exists on foot only. On a bike the wearer has to stop and look at a phone; in a car the
app can hand directions to a maps app but says nothing itself about the crash, the queue or the
roadworks two kilometres ahead. Drivers ask for exactly those warnings, and for speed-camera
warnings where that is lawful.

## Outcome

- "Cycle to the harbour" and "drive to Mum's" get street-by-street spoken guidance, with the same
  cue timing discipline as walking, scaled for speed.
- While driving (guided or not), live **road alerts** ahead on the route: accidents, jams with the
  delay, roadworks and closures, spoken once at a useful distance.
- **Speed-camera warnings only where the current country allows them**, decided by a deterministic,
  tested table that fails closed. Off by default everywhere.
- Audio-first in the car. The glasses display and phone stay quiet while moving in a vehicle.

## What exists today (verified 2026-10-01)

- `Services/Navigation/`: `RouteModel.swift` (`RoutePoint`, `Maneuver`, `RouteStep`,
  `RouteGeometry`), `ManeuverPhraser.swift`, `RouteProgressTracker.swift`, `WalkingRouteService.swift`
  (`MKDirections.Request.transportType = .walking`, `LocationService.begin/endPrecisionGuidance`,
  throttled reroute). `Maneuver` is keyword-parsed from MapKit's English instruction text.
  `NavigateTool` (`navigate`) says "Walking only; driving belongs to CarPlay."
- `NativeTools/DirectionsTool.swift` (`get_directions`) + `MapsHandoff.swift` (`MapsApp` apple/google/
  waze, `TravelMode` driving/walking/transit — **no cycling**) open a maps app. `CarPlaySceneDelegate`
  opens that hand-off on the car screen through the scene.
- **CarPlay entitlement is `com.apple.developer.carplay-voice-based-conversation` only**
  (`OpenGlasses.entitlements`). That category does not get `CPMapTemplate`; the app cannot draw a
  map or turn cards on the car screen, and GL does not pretend otherwise.
- **MapKit, iOS 27.0 SDK (Xcode 27.0, checked in `MKDirectionsTypes.h`):** `MKDirectionsTransportType`
  = `automobile`, `walking`, `transit` (**ETA only**), `cycling` (iOS 14+), `any`. Requests have
  `tollPreference`/`highwayPreference` (iOS 16+) and `departureDate`; routes have
  `expectedTravelTime` (traffic-aware for automobile), `advisoryNotices`, `hasTolls`, `hasHighways`;
  steps have `notice`. **No traffic incidents, speed limits or speed cameras are exposed.**
- **No traffic or camera code** anywhere. `Presence/MotionActivityProvider` reads CoreMotion
  `automotive`/`cycling`; `AppState.carPlayConnected` flips on the CarPlay scene.
- **Background location is not configured**, contrary to CA's note: `UIBackgroundModes` is `audio`,
  `bluetooth-central`, `external-accessory` (no `location`), and nothing sets
  `allowsBackgroundLocationUpdates`. Guidance with the phone locked currently survives only while the
  audio mode keeps the process alive. Driving makes this unavoidable, so GL adds it (P2).

## Design

### Profiles on one core

`TravelProfile` (`walking`, `cycling`, `driving`) and a pure `GuidanceParameters.for(profile:speed:)`:

| | Walking (today) | Cycling | Driving |
|---|---|---|---|
| Cue lead | distance bands (CA) | 200 m / 50 m / now | **time-based**: ~30 s and ~8 s before the maneuver at current speed, plus 2 km on roads above 80 km/h |
| Off-route | K=4, max(30 m, 1.5×acc) | K=3, max(25 m, 1.5×acc) | K=3, max(50 m, 1.5×acc) |
| Reroute throttle | 30 s | 20 s | 15 s |
| `CLActivityType` | `.fitness` | `.fitness` | `.automotiveNavigation` |

`WalkingRouteService` becomes `RouteGuidanceService(profile:)` (walking behaviour unchanged, pinned
by CA's tests). `Maneuver` parsing gains driving phrases (merge, exit, keep left/right, roundabout
exits, ramps). Cycling directions are not available in every region; an `MKError` falls back to
"I can't get cycling directions here — walking route instead, or open your maps app?" — never a
silent walking route. `navigate` gains `mode` (walk/cycle/drive); `TravelMode` gains `.cycling` for
hand-off parity (Google Maps and Apple Maps URL flags).

### Who gives the turns in a car

The maps apps already do turn-by-turn well, and on CarPlay only they can show a map. Default:
**"drive to X" hands the route to the wearer's maps app (FO P3c) and GL runs road alerts alongside**
without duplicating turn cues. GL's own spoken driving turns are for phone-only drivers who choose
them ("Guide me in the car with my glasses" setting) — decision 2.

### Road alerts

- **`RoadAlert`** (pure model): `kind` (`accident`, `jam`, `roadworks`, `closure`, `hazard`,
  `speedCamera(fixed|mobile|average|redLight)`), coordinate or polyline, optional bearing, road name,
  delay seconds, severity, `validUntil`, `source`.
- **`RoadAlertProvider`** protocol; first adapter **TomTom Traffic Incidents API** (incident details by
  bounding box, categories map to `kind`, delay/magnitude to severity). Speed-camera data is a
  separate source (candidates: a commercial camera dataset, or OpenStreetMap `highway=speed_camera`
  nodes, whose ODbL terms need review) — decision 1. Community driver reports are a later source
  and need a backend; out of scope here.
- **`RouteCorridor`** (pure): splits the remaining route into ≤ N bounding boxes within the provider's
  area limit; unguided driving uses a heading cone ahead of the car. Requests carry only box corners
  (rounded to ~100 m) and the API key: no route id, no device id, no destination.
- **`RoadAlertMatcher`** (pure): keeps alerts within 40 m of the remaining polyline (and matching
  bearing when given), computes distance-along-route, merges adjacent jam segments, drops expired.
- **`RoadAlertAnnouncer`** (pure): one announcement per alert at the profile's lead (driving: 2 km for
  accidents/closures/jams with delay ≥ 2 min, 1 km for roadworks, cameras per the gate below), a
  short reminder at 300 m only for closures and cameras, ≤ 1 alert per 20 s, jams worded with the
  delay ("Queue in 2 kilometres, about 6 minutes' delay"). Refresh every 2 min or on reroute;
  `expectedTravelTime` from MapKit stays the ETA source.
- New `NetworkRoute.trafficIncidents` (data class `location`, `publicWeb`), refused by
  `MedicalEgressGuard` in local-only mode; the privacy manifest's location entry and the in-app
  privacy copy name the provider in the same PR.

### Speed-camera country gate (`SpeedCameraLegality`, pure, table-driven)

- Input: ISO 3166-1 alpha-2 of the **current** position (not home country), confidence of that
  country fix, and camera kind. Output: `.allowed`, `.zoneOnly` (announce a generic "danger zone"
  without saying it is a camera or where exactly), or `.prohibited`.
- Rows are data (`SpeedCameraLegality.table`), each with `verdict`, `note` and `reviewedOn`. **Any
  country without a reviewed row is `.prohibited`** (fail closed); an unknown or low-confidence
  country fix is `.prohibited`. Initial rows: `DE` prohibited, `CH` prohibited, `FR` zone-only;
  `allowed` rows are added only after a per-country review (decision 3).
- Country from a cached `CLGeocoder` reverse geocode, refreshed every 10 km or 10 min of driving and
  when the last known country is near a border. On a change to anything not `.allowed`, camera
  warnings stop at once, queued camera alerts are dropped, and **camera data is not fetched at all**
  while there.
- Tests are the contract: `SpeedCameraLegalityTests` pins every row, the fail-closed default, the
  low-confidence rule, and the border transition (allowed → prohibited drops pending camera alerts).

### Surfaces while moving

- `DrivingSurfacePolicy` (pure): in a vehicle (CarPlay connected, or CoreMotion `automotive` with
  speed > 25 km/h for 30 s) the glasses display shows nothing but an optional single maneuver arrow
  (off by default), phone cards are suppressed, alerts are spoken at `.high` urgency with ducking.
  Cycling keeps CA's HUD cards; the watch map comes from GM.
- CarPlay: the voice template's status line shows "Road alerts on"; a "Road alerts" list tab (list
  templates are allowed for this category) shows the current alerts read-only.
- Settings → Navigation (not the glasses section; everything works phone-only): mode default,
  "Road alerts while driving", "Speed-camera warnings where legal" (off; the row explains it is
  unavailable in some countries). Copy never names plan letters.
- **Power (BV):** under `reserve`, alerts refresh every 5 min and cameras still announce.
- **HIPAA:** no health data involved; the provider call is location to a third party, so it follows
  `MedicalEgressGuard` (blocked in local-only mode).

## Phases (one PR each)

**P0 — Pure core.** `TravelProfile`, `GuidanceParameters`, driving `Maneuver` phrases, `RoadAlert`,
`RouteCorridor`, `RoadAlertMatcher`, `RoadAlertAnnouncer`, `SpeedCameraLegality`, `DrivingSurfacePolicy`.
Tests: `GuidanceParametersTests` (time-based lead at 50/100 km/h), `ManeuverParsingDrivingTests`,
`RouteCorridorTests` (box count/area, rounding), `RoadAlertMatcherTests` (on-route vs parallel road,
bearing, expiry, merge), `RoadAlertAnnouncerTests` (once, spacing, reminder only for closures/cameras),
`SpeedCameraLegalityTests` (above), `DrivingSurfacePolicyTests`. CA's tracker tests unchanged.

**P1 — Cycling.** `RouteGuidanceService(profile:)` refactor with walking pinned, `.cycling` routes,
region fallback copy, `navigate mode:`, `TravelMode.cycling`. Device: a real ride (cue timing, wind
noise, HUD glance).

**P2 — Driving guidance and background location.** `location` background mode +
`allowsBackgroundLocationUpdates` only while guiding (App Review note: turn-by-turn navigation),
driving profile, maps-app-first default, surface policy live. Tests: `RouteGuidanceServiceTests`
with injected directions and location seams.

**P3 — Road alerts.** Provider adapter behind `RoadAlertProvider`, key in the Keychain (build-time or
user-entered, decision 1), `NetworkRoute.trafficIncidents` + privacy manifest + copy, CarPlay list
tab. Tests: `TomTomIncidentDecodingTests` (recorded fixtures), `RoadAlertRefreshTests` (fake clock).
Device: a drive with a known incident; flapping signal.

**P4 — Speed cameras** (only after decision 3's reviewed rows exist). Camera source adapter, gate
live, fetch suppression outside `.allowed`. Device: a border crossing is not feasible to test live;
simulated location routes cover it.

## Risks

- **Legal.** Camera-warning law changes and has nuance (e.g. zone-only regimes); the table is data
  with review dates, the default is prohibited, and the feature ships off.
- **Distraction.** Any visual while driving is a liability; the policy defaults to audio only.
- **Provider cost and terms** scale with drivers and refresh rate; attribution rules apply.
- **Background location** raises App Review questions and battery cost; it is on only while guiding
  or while road alerts are explicitly running in a detected vehicle.

## Decisions for Greig

1. **Data provider(s) and keys:** TomTom Traffic Incidents (or another) for incidents; which source
   for cameras; a shipped app key (cost scales with users) vs wearer-supplied key. *Open — needs
   quotes and terms review; no default recommended.*
2. **Car turns:** maps-app-first with GL alerts alongside (recommended) vs GL's own driving voice by default.
3. **Which countries to review** for `allowed`/`zoneOnly` rows before P4 (the rest stay prohibited).
4. **Unguided road alerts** (driving without a route, by heading) in P3, or only on a route?
   *Recommend route-only first.*
5. **Glasses arrow while driving:** allow an opt-in single arrow, or never? *Recommend never in v1.*

## Out of scope

Drawing maps on CarPlay (needs a different entitlement category), offline routing, lane guidance,
speed-limit warnings (not in MapKit), community reporting and its backend, transit guidance
(MapKit transit is ETA only).
