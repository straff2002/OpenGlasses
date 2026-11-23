# Plan NB — Twist to Zoom, Swipe to Pan (the Neural Band moves a manual page on the lens the way Meta's own Gallery and Maps do)

**Status:** 📋 Planned 2026-11-23; P0–P2 to be built in one PR, P3 (the device pass) owed. Everything
that touches Meta's SDK is in the TestFlight-only lane (Plan [JV](JV-dat-experimental-testflight-lane.md)):
Motion and Inputs are both beta in DAT 1.1 and an app that uses them cannot be published. The pure
core compiles and is tested in every build, so the store build gets it the day Meta makes them stable.

## Why

On a Ray-Ban Display, Meta's own Capture, Gallery and Maps apps zoom with one gesture: hold the index
finger to the thumb and turn the wrist, clockwise to zoom in and anticlockwise to zoom out, like a
dial. The same hold, with the arm moved, scrolls. The volume uses the same twist everywhere else. A
wearer who has used the glasses for a day already knows it.

Our lens page view (Plans KV, MG, MU) zooms by voice ("zoom in", "zoom in on the bottom right") and by
its own buttons, and the band's swipes move between a close-up's halves and between pages at fit width
(MU §7, P6). In the zoomed view a swipe does nothing, and nothing zooms without speaking or pressing.

What other people have built (GitHub, 2026-11-23): one glasses web app steps the zoom with a pinch
(fit, fill, 1.5×) and pans by one step a swipe, kept inside the picture; one Android presenter tried
pinch-and-move and dropped it because the move never arrived and quick repeated pinches lost the
third; one iOS app spins a 3D model with the band's drag. Nobody zooms with the twist outside a web app.
Meta's web app runtime hands the page the band's wrist orientation as a sensor reading, with a worked
example of deriving the twist from it. Native DAT 1.1 has a Motion capability whose samples say
whether they came from the glasses or the Neural Band, each with a fused orientation and the
gyroscope. That is the path this plan takes.

## What we know, and what only the glasses can tell us

| | |
|---|---|
| Swipes and the pinch reach us as `nav` and `select` from the band. | **Confirmed** on a Ray-Ban Display (JV probe, build 737). |
| A drag arrives only as bursts of 40–140 ms, and every pinch sends one about 300 ms before its `select`. | **Confirmed** (same run). Drag-to-pan is out (MG §6). |
| `MotionSample` carries `source` (`glasses` / `neuralBand`), a nullable `orientation` quaternion and a nullable `gyroscope`, at 5–60 Hz. | **From the SDK's interface.** Whether band samples actually stream to a native app is **unknown**. |
| A held pinch gives the app something that says "held" (the drag burst at its start, the `select` at its end, or neither). | **Unknown.** It decides the clutch (§3). |
| Meta's system takes the pinch-and-twist for the volume while our view is up. | **Unknown.** If it does, the twist moves the volume as well as our zoom. |
| Which way "clockwise" turns the quaternion, and whether the band's frame is mirrored for the left wrist as the web runtime's is. | **Unknown.** The web runtime mirrors; nothing says DAT does. |

So the plan builds the whole thing headless, ships a probe that answers those five questions on one
pair, and keeps the twist off until the probe has answered them. Swipe-to-pan needs none of them.

## Scope

### §1 Swipe to pan in the zoomed view (Inputs only)

The zoomed view (a spoken zoom, drawn as a strip) has one button, Back, so Meta's focus does not need
left and right there. `LensBandNavMap` gains a row:

| View | Left | Right |
|---|---|---|
| zoomed | the crop half a crop to the left (`LensPageViewport.move(.left)`), nothing at the edge | half a crop to the right, nothing at the edge |

Up and down stay the lens's own scroll of the strip, which already pans down the column. The new
actions are `LensBandPageAction.panLeft` / `.panRight`, one send each through `LensBandNavGate`, drawn
as a `.moved` event so the report counts them as moves. The moves are among `neighbours()`, so their
pictures are drawn ahead and a swipe only sends. It rides the existing switch ("Swipe through manual
pages"), whose caption says so.

### §2 The twist, in the app's own words (pure, every build)

`Services/Display/LensPage/LensTwist.swift`:

- **`WristTwist.angle(of:)`** — the signed twist about the forearm axis (band-local +Y), in radians,
  from a unit quaternion `(x, y, z, w)`: `2·atan2(q·axis, w)`, wrapped to [−π, π). `WristTwist.wrap`
  does the wrapping, so +179° to −179° is a 2° step. No Euler angles.
- **`WristTwist.confidence(of:)`** — how far gravity can resolve the twist: 1 with the forearm level,
  falling to 0 as it points straight up or down (|forearm·up| in the world frame, up = +Z). Below 0.35
  a sample is not used.
- **`TwistTracker`** — one clutch's twist from its samples. It prefers the orientation; a sample with
  none but a gyroscope adds `gyro.y · dt` (the forearm axis) to the running angle, with `dt` from
  `timestampNs` and capped at 100 ms so a gap never jumps. The reference is taken from the first
  stable sample after a 150 ms settle, never the very first. A sign flip of more than 120° between two
  samples in the first 500 ms is treated as the frame settling: the reference is taken again.
- **`TwistZoomDetent`** — turns the tracker's angle into rungs: every `detent` (20°) past the last
  rung emits one rung, in or out by sign, and the next rung needs `detent` more from there, with a
  `hysteresis` (5°) back-off before the direction can reverse. The sign is `TwistDirection`
  (`.clockwiseZoomsIn` by default, the probe's reading decides; §5). At most `maxRungsPerClutch` (6)
  per clutch. Pure: samples in, rungs out.
- **`ArmPan`** (its own switch, off by default; decision 7) — while clutched, the forearm's pointing
  direction (the forearm axis rotated into the world) against the reference; past 12° of yaw or pitch
  it emits a move step that way and re-anchors. The steps go to `LensPageSession.handleArmPan(_:)`
  through the same one-send gate as the swipes and the twist: in the zoomed view (and a close-up,
  carried on at its zoom as a spoken move is) `viewport.move(step)`, nothing at an edge; nothing on the
  whole page, the rows or reading. Drawn as a move, counted apart (`armPanSteps`, `armPanDropped`).
- **Twist and pan never fight** (`LensWristGestures`): with both switched on, one clutch can do
  either, and whichever first passes its threshold owns that clutch; the other is ignored until it
  closes.

### §3 The clutch: when a twist counts

A wrist turns all the time, so a twist counts only inside a clutch. `TwistClutch` (pure) opens on the
band's drag burst (`drag(.down)`, source `neuralBandDrag`, the start of a pinch) and closes at the
first of: that pinch's `select`, a `drag(.down)` that starts a new pinch, or `TwistClutch.cap` (3 s).
Without a burst nothing opens. If the probe shows a held pinch gives no burst, or gives its `select`
the moment it starts, the twist stays off and decision 4 is taken again with the probe's numbers.

A held pinch ends in a `select`, and Meta presses the focused button with it (in the zoomed view, Back).
**`ClutchPressGuard`** (pure): a press within 800 ms of a clutch that sent at least one rung or pan step is
dropped by `LensPageSession.press(itemID:)` and counted, so twisting to zoom never closes the view.

### §4 What a rung does to the page view

`LensPageSession.handleTwist(_ rung: TwistRung) -> LensTwistOutcome`, through the same gate as the
swipes (one send in flight, the rest of a burst dropped, never queued):

| View | Rung in | Rung out |
|---|---|---|
| whole page | one rung in, around the highlight's centre if there is one, else the page's centre | – |
| close-up | as "zoom in" by voice (`leavingCloseUp`, then `zoomIn`) | as "zoom out" |
| zoomed | `zoomIn`; nothing at the cap | `zoomOut`; at the whole page, the whole view |
| rows, reading | – | – |

Drawn as `.zoomed`, counted apart (`twistRungs`, `twistDropped`, `twistPressesSwallowed`).

### §5 Motion from Meta's SDK (flagged)

`Sources/Glasses/Experimental/`, under `#if DAT_EXPERIMENTAL`:

- `project.experimental.yml` links `MWDATMotion` beside `MWDATInputs`.
- `MotionChannel` / `MotionSource` protocols (as `InputsSource`) and `MetaMotionSource`: adds the
  `.motion` capability on the shared `DeviceSessionCoordinator` session (a new `Capability` case),
  `MotionConfiguration(samplingRate: .hz30)`, reads `samples`, passes on only `source == .neuralBand`
  samples mapped to the app's `WristSample` (timestamp, orientation?, gyroscope?) and counts the
  rest. `stop()` stops it, removes it and hands the session back. Never written down.
- **`MotionProbe`** in the Developer panel beside the Inputs probe, with its ledger
  (`MotionProbeLedger`) compiled in every build like `InputsProbeLedger` and printed in the full
  support report: 60 s, the band's Inputs at the same time, and four prompts on the phone: pinch and
  hold for two seconds; pinch, hold and turn the wrist clockwise; the same anticlockwise; pinch, hold
  and move the arm left. It records per prompt: samples by source, rate, how many carried an
  orientation and a gyroscope, the twist's net and peak (degrees, with the sign), the drag and
  `select` events with their times, and whether the phone's output volume changed (Meta taking the
  twist). Aggregates only.

### §6 Wiring (flagged)

`LensWristGestureService` (as `LensBandNavService`; one service for both gestures): opens Motion only
while the page view is on the lens in a view a switched-on gesture can change (the whole page, a
close-up or a zoom for the twist; a close-up or a zoom for the pan), a pair is connected, no probe
runs and either switch is on; closes it otherwise; a failed channel is not asked for again while the
page view stays up. The band channel's configuration gains the drag stream while either gesture is on
(`LensBandNavConfiguration.withDrag`, pinned by `DATExperimentalGuardTests` like the other two), and is
asked for again when a switch changes. New switches in the flagged settings section, **"Twist to zoom
manual pages"**, off by default, with "Reverse the twist" under it, and **"Pinch and move your arm to
pan"**, off by default, its own switch (owner, 2026-11-23).

## Phases

- **P0** — §1 map row and actions, §2 core, §3 clutch and press guard, §4 `handleTwist`, all pure or
  ordinary code, with tests (`LensBandNavTests` rows, `LensTwistTests`, `TwistClutchTests`,
  `LensPageSessionTwistTests`).
- **P1** — §5: Motion linked in the lane, `MetaMotionSource`, the Motion probe and its ledger and
  report section, the guard test's roster.
- **P2** — §6: the service, the switches, the swallowed press, the report counters.
- **P3** — device pass on a Ray-Ban Display with a Neural Band: run the Motion probe and answer the
  five questions above; then swipe in the zoomed view; then, if the clutch holds, the twist.

## Decisions (each built as recommended unless the owner says otherwise)

1. **Swipe-to-pan rides the existing swipe switch.** Recommended: yes; it is the same channel.
2. **The twist is off by default until P3.** Recommended: yes.
3. **Detent 20°, hysteresis 5°, at most 6 rungs a clutch.** Recommended: yes; the ladder has about
   five rungs from the whole page to the cap, so one comfortable turn covers it.
4. **The clutch is the pinch's window** (drag burst to `select`, 3 s cap). Recommended: yes, revisit
   with the probe.
5. **Swallow the press that ends a twist.** Recommended: yes, 800 ms.
6. **Orientation first, the gyroscope as fallback.** Recommended: yes.
7. **Arm-move pan is its own switch, off by default (owner, 2026-11-23).** It shares the twist's
   clutch, Motion channel and press guard; within one clutch the first gesture past its threshold
   owns it.
8. **30 Hz, only while a zoomable view is up.** Recommended: yes; 60 Hz buys nothing at one send at
   a time.
9. **The twist's sign is a constant plus a "Reverse" switch.** Recommended: yes; P3 sets the constant.

## Tests and checks

The ordinary suite: every P0 test, `DATExperimentalGuardTests` (the new module, call sites and the
pinned configuration line), `LensBandNavTests`. The flagged build (`AVENKIN_DAT_EXPERIMENTAL=1`)
compiles and runs the Experimental tests (`MetaMotionSource` mapping, the service, the probe). A
Release build. `Scripts/check-privacy-logging.sh`: the probe logs counts and angles only.
