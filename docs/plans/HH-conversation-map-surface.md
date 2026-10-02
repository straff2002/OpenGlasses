# Plan HH — The Map in the Phone Conversation

**Status:** 📝 Drafted (not scheduled), 2026-10-02 — nothing built.

**Suggested build order (2026-10-02, across Plans GM, GL and HH):** shared surface model (GM P0) →
watch map cards and the live route (GM P1a, P1b) → travel modes by voice, cycling then driving
(GL P0–P2) → the map in the phone conversation (HH) → lists, images and workout-backed guidance on
the watch (GM P2, P3) → road alerts and speed cameras (GL P3, P4).

**Depends on:** Plan [GM](GM-watch-map-and-list-surfaces.md) P0 (the shared `GlanceSurface` model and
`GlanceGeometry`) and P1a (`GlanceSurfaceBus`, the tools publishing surfaces). HH adds a second
renderer for the same payloads; it defines no payload of its own.
**Related:** Plans [CA](CA-walking-navigation.md) / [GL](GL-cycling-driving-navigation-and-road-alerts.md)
(the route and its travel mode), [EA](EA-voice-home-grid.md) / [GW](GW-home-grid-pages.md) (the home
dock this presents over), [GT](GT-weatherkit.md) (the rule for Apple-framework requests under Medical
Local Only), [GH](GH-parking-memory.md) (the one map already in the app).

---

## Trigger

"Where am I?", "how far is the tower?", "find a pharmacy" and "take me to the harbour" are answered
in words on a screen that could show them. The phone has the largest display the wearer owns and
today draws no map in the conversation at all.

## Outcome

- A spatial answer puts a **map card** in the conversation; a tap (or "show me the map") opens it
  **full-bleed**, with the voice status collapsed into a bottom bar — state, camera, stop — and a
  back control to the transcript. The conversation carries on by voice the whole time.
- While guiding, a **guidance layout**: the maneuver card on top (arrow, distance, "then …"),
  arrival time, time and distance to go and speed along the bottom.
- Later, each its own phase: satellite / hybrid by voice, a visual traffic layer, and a slow camera
  orbit around a place.
- Same payloads as the watch, so the phone and the wrist never disagree about a name or a distance.

## What exists today (verified against `origin/main`, 2026-10-02)

- **The home / conversation screen** is `App/Views/VoiceTab.swift`: a `ZStack` of `VoiceAmbience`
  under a `VStack` of the *conversation zone* (`StatusIndicator` — the status card with pills and the
  coral waveline from `VoiceWaveline.swift` — then the day card, captions and
  `SessionNoticeOverlay`) and the dock, `BottomControlBar`. The dock is a pager (`Models/DockPager.swift`:
  `DockPage.conversation` / `.actions`, `DockPagerPolicy`) whose conversation page is
  `ConversationPageHeader` + `ConversationPageBody` (`TranscriptOverlay` for the live turn); the
  capsule (`ActionCapsule`) sits below the panel and never pages, so stop is always one tap. Grid
  paging is `Models/HomeGridPaging.swift`. `VoiceVisualState` is derived once (`VoiceStateProvider`)
  and drives both ambience and waveline. Full-screen covers on this tab today: `LivePreviewView`,
  `JobDayView`.
- **One map in the app:** `ParkingSettingsView` draws a SwiftUI `Map` with a `Marker` (no user
  location). `import MapKit` otherwise appears only in `WalkingRouteService`, `LocationSearchTool`,
  `GeocodingHelper`, `TravelTimeDaySource`.
- **Tool results are text.** There is no structured tool-result card in the transcript; sheets driven
  by a tool go through `AppState` request properties presented in `MainView` (`manualFigureRequest`,
  `phoneCameraRequest`, …).
- **Guidance numbers the shipped tracker produces:** active step and its maneuver / street,
  `distanceToManeuver`, `remainingDistance`, the next step (by index), and the route's
  `expectedTravelTime` and `distance` **at start only**. **Not produced today:** live time
  remaining, arrival time, current speed (`CLLocation.speed` is on every fix in
  `LocationService.currentLocation` but nothing reads it), and a "then …" phrase. HH adds a pure
  estimator for these (below); none needs a new data source.
- **MapKit, iOS 27.0 SDK (`_MapKit_SwiftUI.swiftinterface`, headers):** `MapCamera(centerCoordinate:
  distance:heading:pitch:)`, `mapCameraKeyframeAnimator`, `onMapCameraChange`,
  `MapStyle.standard / imagery / hybrid` with `elevation: .realistic` and `showsTraffic:` are iOS 17+
  (target is iOS 26.0). **No API reports whether realistic 3D imagery covers a place** — the headers
  have the elevation enum and nothing else; `MKLookAroundSceneRequest` reports street-level imagery,
  which is a different feature.
- **Medical Local Only:** MapKit requests are the framework's own, so they have no `NetworkRoute`
  (`Security/NetworkRouteRegistry.swift` says so in a comment: "the same rule as MusicKit and MapKit
  search"). WeatherKit and MusicKit are nonetheless refused under Local Only by an injected closure
  over `MedicalEgressGuard.currentMode()`; MapKit search, directions and the parking map have **no**
  such check today.
- Accent: `\.appAccent`, coral `#E77F47`.

## Design

### Presentation (`MapSurfacePresenter`, new, pure)

A state machine with no SwiftUI in it: `hidden` → `card(surface)` → `fullBleed(surface)` →
`guidance(route)`. Inputs: a surface arrived on `GlanceSurfaceBus`, tap, back, "show / hide the map"
by voice, guidance started / ended / rerouted, in-a-vehicle (GL's `DrivingSurfacePolicy`), Medical
Local Only, surface expiry, app mode.

- **Card.** A spatial tool result adds one compact card at the foot of the conversation page — inside
  `ConversationPageBody`, under the live turn: a 16:9 non-interactive map, the name, the distance
  (with "in a straight line" when it is not a route distance), an expand control. One card at a
  time; a newer surface replaces it. The card is not a transcript message and is not stored in
  `ConversationStore` (the spoken sentence already is).
- **Full-bleed.** A layer in `VoiceTab`'s `ZStack`, above `VoiceAmbience`, replacing the conversation
  zone and the dock **panel** — not a `fullScreenCover`, so the tab bar, `SessionNoticeOverlay` and
  the turn spine stay alive and an error is never hidden behind a map. The map ignores the top safe
  area. Over it:
  - **top-left:** a back control ("Conversation") returning to the dock's conversation page;
  - **bottom:** `MapVoiceBar` (**new**) — the voice state (a short waveline and the state word from
    the same `VoiceVisualState`), the camera button (the capsule's existing preview / photo action),
    and stop / hang-up (the capsule's existing action, same size and place, so "stop is one tap"
    survives). The capsule itself is hidden while the bar shows; the bar is its compact form.
  - a `places` surface shows numbered markers and a bottom sheet list at the small detent; a row tap
    frames that place and offers **Go**.
- **Automatic full-bleed only for guidance**, and only when the app is in the foreground and the
  wearer is not in a vehicle. Everything else stays a card until tapped or asked for (decision 1).
  Setting, on the Navigation settings screen: "Open the map when directions start" (on). Not a
  glasses setting; copy names no plan letters.
- **Back** returns to the card; the route keeps running. Leaving the Voice tab keeps the state.

### Rendering (`MapSurfaceView`, new)

SwiftUI `Map` driven by `GlanceSurface`: coral `Marker`s for places, `MapPolyline` in the accent for
the route, the wearer's position from the payload's `WearerFix` for static cards (so the dot, its
age and its greying follow GM's `WearerDotFreshness` exactly) and `UserAnnotation` while guiding
(the phone has the permission and the fix). Framing comes from `GlanceGeometry`'s region with insets
for the top card and bottom bar. Marker tint, polyline and the bar's waveline use `\.appAccent`;
nothing is cyan or violet.

### Guidance layout (`GuidanceLayoutModel` + `RouteProgressEstimator`, new, pure)

- **Top card:** the maneuver arrow (`Maneuver`), banded distance (`DistanceFormatter`), street, and
  "then turn right onto Queen Street" from the following step; the travel-mode symbol (GL).
- **Bottom strip:** arrival time · time to go · distance to go · speed.
- `RouteProgressEstimator`: time to go = the route's `expectedTravelTime` scaled by remaining over
  total distance, blended toward observed speed once two minutes of moving fixes exist; arrival =
  now + time to go, rounded to the minute and updated at most every 15 s so it does not flicker;
  speed from `CLLocation.speed` when its accuracy is valid, hidden when not and always hidden on
  foot (walking speed is noise). All inputs are plain values: a test feeds fixes and a clock.
- The camera follows the wearer, heading-up while moving, north-up when stationary; a pan pauses
  following and shows a "Re-centre" control.
- Under BV's `reserve` posture the map holds its last frame and the strip updates on cues only.

### Later extras (each its own phase, each optional)

- **Style by voice** — "show satellite", "back to the normal map": `MapStyle.imagery` / `.hybrid` /
  `.standard`. Driven by a small new native tool, **`map_view`** (actions `show`, `hide`, `style`,
  `traffic`, `look_around`), so all three LLM modes can reach it; its description is self-contained
  and it is classified in `OfflineToolPolicy` (`.degraded`: cached tiles only).
- **Traffic layer** — `MapStyle.standard(showsTraffic: true)`: **visual only**, a toggle and "show
  traffic". The assistant does not describe it; spoken traffic is GL's provider phase, and the tool
  result says "Traffic is on the map" and nothing about conditions.
- **A look around a place** — "fly around the tower": `OrbitPlan` (**new**, pure: centre, distance
  from the place's size, pitch 60°, one 360° turn in 24 s as keyframes) played with
  `mapCameraKeyframeAnimator` over `.hybrid(elevation: .realistic)`. Realistic 3D exists only in
  some cities and there is no API to ask. So: the orbit always runs (a pitched turn over flat
  imagery is still a useful look), the assistant says "Here's a look around it" and **never
  promises 3D**; after the first second the view reads back the camera pitch through
  `onMapCameraChange`, and if it was clamped flat the caption under the map reads "3D view isn't
  available here." Whether that read-back actually distinguishes coverage is unverified (owed
  device check); if it does not, the caption is dropped and the wording stays neutral.

### Medical Local Only

Map tiles are requests to Apple centred on the wearer — location leaving the phone. Following the
weather plan's rule: **no `NetworkRoute`** (the request is the framework's, not ours), and an
**injected mode check** decides presentation. Under Local Only the presenter never shows a `Map`:
the card is text (name, distance, a bearing arrow, the maneuver), full-bleed is unavailable with
"Maps are off while Medical Local Only is on.", and `GlanceSurface.mapAllowed` is false for the watch
too. Medical Compliance without Local Only changes nothing (location, no health data). The existing
parking map gets the same check in the same PR. Whether `navigate` / `find_nearby` themselves are
refused under Local Only is GL's decision 8, not settled here.

### Accessibility

- The map is one VoiceOver element with a summary built from the payload ("Map. Sky Tower,
  1.2 kilometres north-east of you in a straight line."; guiding: "Map. In 80 metres turn left onto
  King Street. 12 minutes to go."), updated on cue changes, not on every fix. Markers are not
  individually focusable; the `places` list is.
- Cards and the strip use Dynamic Type; at accessibility sizes the strip wraps to two rows and the
  top card drops "then …" before it truncates the maneuver.
- **Reduce Motion** replaces the orbit with a single cut to the pitched view and turns off camera
  animation between surfaces.
- Bar controls keep the capsule's hit sizes and labels; the screen joins the CI accessibility audit.

## Phases (one PR each)

**P0 — Pure cores.** `MapSurfacePresenter`, `GuidanceLayoutModel`, `RouteProgressEstimator`,
`OrbitPlan`, the VoiceOver summary builder. Tests: `MapSurfacePresenterTests` (every transition;
guidance auto-opens only in the foreground and out of a vehicle; Local Only never reaches a map
state; expiry returns to hidden; a newer surface replaces the card), `GuidanceLayoutModelTests`
(snapshots of the model per maneuver, with and without a following step, at an accessibility size
flag), `RouteProgressEstimatorTests` (scaling, speed blend, no flicker inside 15 s, speed hidden on
foot and on invalid accuracy), `MapSurfaceSummaryTests`, `OrbitPlanTests`.

**P1 — Card and full-bleed map** for place, where-am-I and places: `MapSurfaceView`, the card in
`ConversationPageBody`, the layer and `MapVoiceBar` in `VoiceTab`, the Local Only check (and on the
parking map). Tests: `MapVoiceBarModelTests` (state word and actions per `VoiceVisualState`),
`MapSurfaceLocalOnlyTests` (injected mode closure; no shared service).

**P2 — Guidance layout.** Route surface, follow camera, top card and strip, auto-open and its
setting. Tests: `GuidanceMapFeedTests` (a fresh guidance service with its injected seams feeding the
presenter and estimator — never `AppState` or a `.shared` service).

**P3 — Style and traffic by voice.** `map_view` tool (registered; description; `OfflineToolPolicy`
row), the toggles. Tests: `MapViewToolTests`, `OfflineToolPolicyTests` updated.

**P4 — Look around a place.** Orbit, reduce-motion cut, the neutral wording, the pitch read-back if
the device check supports it.

### Owed device checks

1. Layer vs dock: swipe feel, the bar at Large and accessibility sizes, small phones.
2. Card → full-bleed → back while a live session (Gemini Live, OpenAI Realtime) is talking.
3. A real walk with the guidance layout: arrival-time stability, heading-up behaviour, battery.
4. Pitch read-back in a city with 3D imagery and one without; orbit smoothness on an older phone.
5. Tile memory alongside an on-device model (the app holds the increased-memory entitlement).
6. VoiceOver through all four states.

## Risks

- **Screen-on battery** during guidance; `reserve` posture freezes the map, and the wearer can stay
  on the transcript — voice guidance never depends on the map.
- **A third thing in the dock area**: the presenter is pure so the "stop is one tap" and "errors are
  never hidden" promises are tests, not intentions.
- **Memory** with a local model loaded; the card uses a non-interactive map and full-bleed releases
  it on back.
- **Promising 3D** where there is none; the wording never does.

## Decisions for Greig

1. **How the map opens:** card always, full-bleed on tap or by voice, automatic only when guidance
   starts (*recommended*) — or full-bleed for every spatial answer.
2. **Layer in the Voice tab** keeping the tab bar and error card (*recommended*) vs a full-screen cover.
3. **Medical Local Only:** text card, no map, and the parking map gains the same check (*recommended*).
4. **Speed** on the strip for cycling and driving only (*recommended*), or never.
5. **Extras:** build P3 (style, traffic) and P4 (orbit) at all, and in which order. *Recommend P3
   when convenient, P4 only after device check 4.*
6. **A `map_view` tool** for the voice controls (*recommended*) vs more actions on `navigate`.

## Out of scope

A map on the glasses display (CA: text cards only), CarPlay maps (entitlement category), offline
tiles, spoken traffic (GL), street-level imagery, editing or saving places from the map, a map on
the Lock Screen Live Activity, storing map cards in the conversation history.
