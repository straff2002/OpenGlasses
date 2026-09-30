# Plan GH — Parking Memory ("Where did I park?")

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Continues:** Plan [CA](CA-walking-navigation.md) (walking guidance back to the car).
**Related:** Plan W (`MotionActivityProvider`), Plan [GG](GG-readable-memory.md) (the spot shows under
Places and can be forgotten), Plan [GM](GM-watch-map-and-list-surfaces.md) (watch pin), CarPlay
(first-class surface).

---

## Trigger

"Where did I park?" is one of the most common things people ask an assistant, and the answer that
helps is specific: *level 2, space 41, about 300 m that way*, with directions. Today the app can
store a labelled coordinate, but it knows nothing about levels or bays, never saves one on its own,
and cannot walk you back to a coordinate.

## Outcome

- **Save by voice:** "I parked on level 2, space 41" → spot saved with the current location.
- **Save by photo:** "Remember this" while looking at a pillar or bay sign → level/space read from
  the sign on the phone, photo kept with the spot.
- **Save automatically:** when a drive ends (CarPlay disconnects, or the phone's motion goes from
  driving to walking) the spot is saved quietly.
- **Recall:** "Where did I park?" → spoken level/space, distance and direction, and "want
  directions?" → walking guidance. A pin on the glasses display and, later, the watch.
- One active spot; history optional and off by default. Everything stays on the phone.

## What exists today (verified 2026-10-01)

The brief's "parking: none" is only partly true:
- `NativeTools/SaveLocationTool.swift` (`save_location`, `list_saved_locations`) already describes
  itself as "great for remembering where they parked": a label + coordinate + address in
  UserDefaults (`saved_locations`, max 50). No level, bay, photo or automatic capture.
- `NativeTools/ObjectMemoryTool.swift` (`object_memory`, `ObjectMemoryStore`) lists "car" as an
  example object with a free-text place.
- `Services/Navigation/WalkingRouteService.swift` (Plan CA) starts only from a **query string**
  (`start(destination:)` → `MKLocalSearch`); `RouteProgressTracker` itself is coordinate-based.
- `Services/Presence/MotionActivityProvider.swift` publishes one boolean (`isActive`, any of
  walking/running/cycling/automotive); no transitions, no history query.
- `App/CarPlaySceneDelegate.swift` sets `AppState.carPlayConnected` on connect/disconnect.
- `Services/Accessibility/OCRService.swift` (`recognizeText(in:)`, Vision) runs on the phone.
- Location: `LocationService` (When-In-Use by default; `requestAlwaysAuthorization()` exists for
  geofences). `UIBackgroundModes` is `audio`, `bluetooth-central`, `external-accessory` — **no
  `location`**, so a backgrounded app does not receive fresh fixes.

## Design

**`ParkingSpot`** (Codable): `coordinate`, `horizontalAccuracy`, `level?`, `space?`, `zone?`, `note?`,
`photoFile?`, `savedAt`, `capture` (`.voice`, `.photo`, `.carPlayDisconnect`, `.motion`),
`confidence` (`.certain` for voice/photo/CarPlay, `.probable` for motion only).

**`ParkingStore`**: one active spot plus optional history (last 10 when enabled). Protected file
(`completeUntilFirstUserAuthentication`), excluded from backup, registered in `DataStoreRegistry`
so retention and erasure reach it; a replaced spot deletes its photo.

**`ParkingUtteranceParser`** (pure): "level 2 space 41", "P3 bay B12", "floor minus one", "B2",
"row G", "green zone", spelled numbers → `level`/`space`/`zone`. Unparsed text becomes `note`.

**`ParkingSignParser`** (pure): OCR lines from a sign → the same fields, preferring tokens next to
LEVEL/FLOOR/P/BAY/SPACE and large isolated numbers; returns candidates with a score so the
assistant can say "I read level 2, space 41 — right?" when unsure.

**`DriveEndDetector`** (pure state machine, injected clock). Inputs: CarPlay connect/disconnect,
`CMMotionActivity` samples (automotive/walking/stationary with confidence), location fixes.
- **CarPlay disconnect** after ≥ 3 min connected → spot at the **last fix received while
  connected** (≤ 60 s old), `certain`. This is the strong signal and needs no background location.
- **Motion:** automotive (medium/high confidence) ≥ 3 min, then walking ≥ 30 s within 3 min →
  spot at the last fix at the automotive→stationary edge, `probable`. Passengers produce the
  same pattern, so motion-only capture is off unless the wearer turns on "I drive" in settings.
- A new drive start clears nothing; the next end replaces the spot (a manual spot saved in the
  last 10 min is never overwritten by a `probable` one).
- Retrospective: on app wake, `CMMotionActivityManager.queryActivityStarting` replays the recent
  activity history, so a transition that happened while the app was suspended is still found; the
  coordinate then comes from the last fix the app had, and the spot is `probable`.

**Location honesty.** Without Always authorisation and without a `location` background mode, a
locked phone gets no fresh fix at the moment of parking. P3 decides on device between: (a) asking
for Always (already declared for geofences) and a one-shot `requestLocation()`, or (b) using the
last CarPlay/foreground fix only. The recall says how old the fix is when it is more than a few
minutes stale.

**Recall.** A native `parking` tool (`save`, `where`, `clear`, `history`):
"You parked on level 2, space 41, about 300 metres north-east, 2 hours ago. Want directions?"
Directions call a new `WalkingRouteService.start(to:label:)` that takes a coordinate (skipping
`MKLocalSearch`); indoors, where GPS is poor, the spoken level/space and the photo carry the answer.
The glasses display shows a one-line pin via `GlassesDisplayService.showNavigation` ("Car · L2 ·
41 · 300 m NE"); the phone shows a card with map and photo. `save_location`'s description stops
claiming parking, so the model routes parking to `parking`.

**Photo path.** The sign photo comes through `CameraService.filteredStill(for:source:)` with a new
`PrivacyFilterScope` case and an `OutboundFrameConsumer` roster entry (`parkingSign`), so
`OutboundFrameConsumerTests` stays green; OCR runs on the filtered still. No pixels leave the
phone. Phone-only users can take the photo with the phone camera from the card.

**Modes.** Glasses optional throughout (phone speaker, CarPlay and the phone card are enough).
Not agentic, so no Agent Mode gate. HIPAA mode: no change (no clinical content, nothing leaves).
Settings live in a general "Parking" row, not the glasses section: automatic capture (CarPlay on
by default once the feature is enabled; motion off until "I drive"), keep history (off).

## Phases (one PR each)

**P0 — Pure core.** `ParkingSpot`, `ParkingUtteranceParser`, `ParkingSignParser`,
`DriveEndDetector`, `ParkingRecallPhraser` (distance/direction/age, reusing CA's
`DistanceFormatter`). Tests: `ParkingUtteranceParserTests`, `ParkingSignParserTests` (sign fixtures),
`DriveEndDetectorTests` (CarPlay short hop ignored; drive→walk; bus-passenger pattern ignored
without "I drive"; manual spot not overwritten; stale fix labelled), `ParkingRecallPhraserTests`.

**P1 — Store, tool, voice save and recall.** `ParkingStore`, `ParkingTool`, registry entry,
`WalkingRouteService.start(to:label:)`, HUD pin, phone card, `DataStoreRegistry`/erasure wiring.
Tests: `ParkingStoreTests` (one active spot, history cap, photo deleted on replace, protection
attribute), `ParkingToolTests`, `WalkingRouteServiceCoordinateStartTests` (no local search call).

**P2 — Photo capture.** Filtered-still path, OCR, confirm-when-unsure, roster entry.
Tests: `OutboundFrameConsumerTests` update, `ParkingPhotoFlowTests` with a fake still provider.

**P3 — Automatic capture and device checks.** CarPlay hook, motion provider transitions and
history query, location strategy decision. Device checks (owed): a real drive with CarPlay; a drive
without CarPlay and "I drive" on; a multi-storey car park (GPS drift, level readout); a bus ride
(no false spot); phone locked in a pocket throughout.

## Risks

- **False spots** from passengers; mitigated by CarPlay-first and the "I drive" opt-in.
- **Indoor GPS** is poor in car parks; the level/space and photo matter more than the pin.
- **Always location** is a big ask for one feature; the CarPlay path works without it.

## Decisions for Greig

1. Location strategy for locked-phone capture: request Always (a) or last-known fix only (b).
   *Recommend (b) first, (a) as an opt-in if P3 shows (b) is too stale.*
2. Motion-only capture behind an "I drive" switch (recommended) or on for everyone.
3. Speak a confirmation on automatic save ("Saved where you parked") or stay silent with a
   notification. *Recommend silent + notification; spoken only after CarPlay disconnect.*
4. History off by default (recommended), last 10 when on.

## Out of scope

Paid-parking timers and payments, finding free spaces, sharing the spot with someone, barometric
level estimation, and CarPlay-screen UI beyond what already exists.
