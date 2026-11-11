# Plan LD — Home Cameras Through Home Assistant (is the garage shut, is there a parcel, is anything left on the lawn, frost on the car)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) are
recommendations and are still open.
**Track:** Everyday assistant (home). No Field Assist dependency.
**Builds on:** `HomeAssistantTool` and `HomeAssistantRESTClient` (the configured URL and token, `EndpointPolicy`
on the `homeAssistantCommand` route, Medical Local Only first), `HomeAssistantEntityCache`, the privacy
chokepoint (`PrivacyFilterService.filtered(_:for:)` / `filteredOrUnavailable(_:for:)`, the
`OutboundFrameConsumer` roster and its test), `StructuredVisionService.assess(kind:imageData:note:)` and the
`AssessmentSchemaRegistry`, `PerceptualHash` and `FrameGate`, `CallBudget`, the weather core of Plan
[GT](GT-weatherkit.md) (`WeatherProviding`, `WeatherReport`, `RainOutlook`), Plan [JO](JO-watchers.md)
(`Watcher`, `WatchRunner`, `WatchDeliveryPolicy`), `MyDayDeliveryPolicy`, `HighImpactToolPolicy` (Plan
[BC](BC-unconditional-safety-gate.md)).
**Sits beside:** Plan [KU](KU-watch-it-for-me.md) (a camera the wearer is holding or wearing, waiting for one
thing and ending; LD reads fixed cameras the house already has, on a standing schedule). Plan
[LH](LH-car-routines-with-home-assistant.md) (asks LD whether the car is frosted, or in the garage). Plan
[KT](KT-cards-ready-to-act.md) (the drafted message LD offers when a parcel sits too long). Plan
[LL](LL-always-on-home-agent.md) (the always-on host that can run LD's checks on time).

---

## Trigger

The owner shared, on 2026-11-11, an example list of routines a cloud personal agent runs. Several of the most
useful are a camera the house already has, looked at on a schedule, with a plain answer:

- an hourly look at the front door for a delivered parcel, with a photo, and a nudge if it sits for hours;
- a nightly look that the garage and shed are shut and nothing was left on the lawn, silent unless something
  is wrong;
- a rain watch that only speaks when rain is coming **and** something is actually left outside;
- a frost check on the parked car from the driveway camera, with the forecast as backup, skipped when another
  camera shows the car in the garage.

Avenkin can already reach the wearer's Home Assistant, and Home Assistant already holds those cameras. What is
missing is the picture: nothing in the app asks Home Assistant for a camera still, and nothing reads one.

## Outcome

- **Asked, answered.** "Is the garage door shut?" → "Yes, the garage door is shut." (from the door's own
  sensor when Home Assistant has one; from the garage camera when it hasn't). "Is there a parcel at the front
  door?" → "Yes, one box on the step, since about two o'clock." "Anything left on the lawn?" → "A bike and a
  ball, near the fence." The phone shows the still the answer came from; the lens shows one line.
- **Checked for you, and quiet.** "Check the garage and the shed every night" → at the time the wearer chose,
  one look. Nothing is said when all is well. When something is wrong, one sentence and a notification: "The
  shed door looks open."
- **Parcel left out.** "Tell me if a parcel's been sitting there a while" → once a parcel has been seen for four
  hours (the wearer's figure), one sentence, and an offer: "Want me to text someone who's home?" The draft
  is handed over for the wearer to send (Plan KT's shape); nothing is sent on its own.
- **Rain, only when it matters.** "Warn me if it's going to rain and something's left out" → when the forecast
  says rain within the hour (or the next few hours, decision 6) **and** the lawn camera shows something left
  out, one sentence. Rain and an empty lawn: silence.
- **Frost on the car.** "Is the car frosted?" → from the driveway camera first; when the picture can't say
  (dark, fogged lens), from the overnight low and current temperature, said as the forecast's answer, not the
  camera's. If another camera shows the car in the garage, "the car's in the garage" and no frost answer.
- **Readable and removable.** "What are you watching at home?" lists the home checks; "stop checking the
  shed" removes one. Each check shows on the phone with its last result and still (if kept).
- **Honest about timing.** The confirmation says what the phone can promise: "I'll check at ten when the
  app's running; if it isn't, I'll check the next time it is and tell you if it was missed."

## What exists (verified 2026-11-11 at main 2d936d2)

**Home Assistant:**
- `HomeAssistantTool` (`home_assistant`): `call_service`, `get_state`, `list_entities`, `run_automation`,
  `toggle`, `converse`. Requests go through `EndpointPolicy.requireOpenable(_, for: .homeAssistantCommand)`
  with the long-lived token as a Bearer header, 15 s timeout; failures log the status class only
  (`PrivacyLog.requestFailed(.homeAssistant, …)`). `MedicalEgressGuard.allows(.homeAssistantCommand)` is
  checked first.
- `HomeAssistantRESTClient` (`HomeAssistantServiceCalling`): the same rules behind a seam, used by music
  control. It reads `/api/states` and calls services. **No call to `/api/camera_proxy/…`, and no image is
  read from Home Assistant anywhere in the app.**
- `HomeAssistantEntityCache`: `CachedEntity` (`entityId`, `friendlyName`, `domain`, `state`), five-minute
  staleness, `fuzzyMatch(_:preferDomain:)`, `deviceSummaryForPrompt()`. Camera entities appear in it like any
  other (`domain == "camera"`), with no image.
- `NetworkRouteRegistry` declares `homeAssistantCommand` ("read or change device state") and
  `homeAssistantEntityCache`. Neither says it carries images of the home.
- **A read can ask for confirmation by accident.** `HighImpactToolPolicy.evaluate(tool: "home_assistant",
  …)` matches substrings ("garage", "cover.", "open", "lock.") of the call's text; for a `get_state` call with no
  `service` that text is the joined arguments, so `get_state cover.garage_door` asks "Home Assistant: …" before
  reading the door. LD needs reads not to ask (P1).

**Pictures and privacy:**
- `PrivacyFilterScope` and `PrivacyFilterService.filtered(_:for:)` / `filteredOrUnavailable(_:for:)`: the
  bystander blur for a scope. `Config.privacyFilterEnabled` defaults to **off**. When it is on, the filter is
  unavailable while the app is backgrounded, transitioning or locked (`PrivacyFilterAvailability`), and a
  filtered still reader gets `.unavailable(.filterUnavailable)` rather than raw pixels.
- `OutboundFrameConsumer` lists every place that receives camera pixels; `OutboundFrameConsumerTests`
  scrape the sources for `filtered(_:for:)`, `filteredStill(for:)` and raw frame reads and fail on an owner
  that is not listed. There is precedent for a still that does not come from `CameraService`:
  `expertHandoverPhotos` reads stored job photos and filters them under `.expertHandover`.
- `CameraService.filteredStill(for:source:)` serves the wearer's camera only. A Home Assistant camera is
  a different source and cannot use it.

**Reading a picture:**
- `StructuredVisionService.assess(kind:imageData:note:)`: forced structured output against a registered
  `AssessmentSchema`, the `sensitive_items` category-only reporting (`AssessmentPrivacy`), view limits,
  `ImageQualityProbe` qualification. It **publishes** the card (`latest`, HUD mirror): right for an answer the
  wearer asked for, wrong for a silent background check. Schemas today: instrument reading, safety assessment,
  first-aid triage.
- `PerceptualHash`, `FrameGate` (Plan KU uses the same pair as its anchor gate), `CallBudget`.

**Weather:** `WeatherKitProvider` asks for `.current, .daily, .minute, .alerts`. `WeatherReport` has current
temperature, days (`highC`, `lowC`, `precipitationChance`) and minutes where the region has them.
`RainOutlook.evaluate(minutes:now:)` covers the next hour only. **There is no hourly forecast.**

**Running later:** Plan JO is drafted, nothing built: no `Watcher`, no `WatchRunner`. `AgentScheduler` runs
while the process is alive. No `BGTaskScheduler` task, no push (`UIBackgroundModes` is `audio`,
`bluetooth-central`, `external-accessory`). `MyDayDeliveryPolicy` decides quiet hours and protected data for
My Day.

## Design

### 1 · Fetching a still (`HomeCameraClient`)

- `GET /api/camera_proxy/<camera entity>` on the wearer's Home Assistant, with the same token, the same
  Medical Local Only check and the same `EndpointPolicy` rules. A new route, `homeAssistantCamera`, is declared
  in `NetworkRouteRegistry` so Network Activity says "a camera still from your Home Assistant", separate from
  device commands.
- A size cap (2 MB) and a 10 s timeout; the answer must be an image type, or it is refused. Downscaled on
  the phone to the size the vision call needs before anything else touches it.
- **Only cameras the wearer allowed.** A per-entity allowlist, empty by default (decision 1). An entity not
  on it is never fetched, whatever the model asks. Each allowed camera has the wearer's own name for it
  ("front door", "lawn", "driveway") and what it may be asked about (parcel, closed-up, lawn, car).

### 2 · Privacy: a new scope and roster entry

- A new `PrivacyFilterScope.homeCamera`, filtered when the blur is on (`isFiltered` true), not mandatory. A
  front-door camera sees delivery drivers and passers-by, who are exactly the bystanders the blur is for.
- A new roster entry `homeCameraStill`, owned by `HomeCameraClient`, tap "fetched still", protected by
  `filteredOrUnavailable(_:for: .homeCamera)`. A still the filter cannot process is never sent: the check
  says "I couldn't check the front door just now".
- **What that means in the background.** With the blur on, the filter is unavailable while the phone is
  locked or the app is backgrounded, so an unattended cloud check cannot run then. LD does not work round
  this. It offers two honest routes: the on-device change check (§4) still runs, and a cloud look waits for
  the next time the app is in front, or runs on the always-on host (Plan LL). The check's screen says which.
- **Stills are not kept by default** (decision 3). An answer the wearer asked for shows its still on the
  phone until the conversation moves on. A background check keeps only the result. "Keep the photo" per check
  keeps the latest still (filtered) in the app's own store, never the Photos library.
- Cameras inside the house are allowed only by name and only for the kinds the wearer ticks. The app never
  describes people in a home-camera still: the schemas have no field for them, and the prompt says so.

### 3 · Reading a still (`home_check` schemas)

A pure `HomeCheckKind` with one small schema each, registered in `AssessmentSchemaRegistry`:

| Kind | Answers | Fields |
|---|---|---|
| `closedUp` | Is the named door, gate or shed shut? | `target_visible`, `closed` (yes/no/unsure), `seen` |
| `parcel` | Is there a parcel at the door? | `target_visible`, `parcel_present`, `count`, `seen` |
| `leftOutside` | Is anything left on the lawn or deck? | `target_visible`, `items` (short nouns, max 5), `seen` |
| `carFrost` | Is the parked car frosted or snow-covered? | `car_visible`, `frost` (none/light/heavy/unsure), `seen` |
| `carPresent` | Is the car in this space? | `car_visible`, `present` |

- A sensor beats a picture. When the allowlisted target has a Home Assistant entity (a `cover`, a door
  `binary_sensor`), `closedUp` reads its state and never fetches a still. The camera is for things that have
  no sensor.
- A silent background check calls a new non-publishing `StructuredVisionService.evaluate(kind:imageData:note:)`
  that runs the same chokepoint augmentations and returns the card without setting `latest` or mirroring to
  the HUD. `assess` keeps its behaviour for answers the wearer asked for.
- `unsure`, a target not visible, or a poor `ImageQualityProbe` reading is **no answer**, said as such when
  asked ("the lawn camera's too dark to tell") and silent in a background check, which then records
  "couldn't tell" on its screen.
- Night: many cameras switch to infrared. A `carFrost` answer at night is treated as `unsure` unless the
  schema's quality fields say the view is clear (decision 7).

### 4 · Cheap first: a reference still and a change gate

- Each allowed camera can be given a **reference still** ("this is what all clear looks like"), taken by the
  wearer from the camera's own still. `PerceptualHash` compares each new still with it on the phone, which
  sends nothing.
- Close to the reference → the result is "as usual" with no model call (`closedUp`, `leftOutside`, `parcel`).
  Far from it → a cloud check, within the check's `CallBudget`. A gate result is labelled as such
  ("looks the same as usual") so a wearer can tell a looked-at answer from an unchanged one.
- The gate is what makes an hourly parcel check affordable, and what lets something useful happen while the
  blur blocks a cloud call: "the front door view has changed since this morning" is said as a change, never as
  "there's a parcel".

### 5 · Standing checks (a JO watcher kind)

- `WatcherKind.homeCheck(camera, kind, schedule, condition)`, stored and listed with the other watchers (Plan
  JO's store, screen and "what are you watching?"). The schedule is a time ("10 pm"), an interval ("every hour
  from 9 to 6") or "when the forecast says rain".
- **Silent unless wrong** is the default for every home check (decision 4): a check that finds everything as
  it should be records it and says nothing.
- **Parcel left out:** a `parcel` check remembers when it first saw a parcel (by the change gate going "far"
  and the schema saying yes). At the wearer's threshold (default 4 h) it says so once and offers a draft
  message to a contact the wearer picked when setting it up. The draft goes through the ordinary
  `send_message`/`send_via` read-back and confirmation; nothing about LD can send. When Plan KT lands, the offer
  is a `PreparedCard`.
- **Rain and left outside:** a pure `RainExposureRule` joins `RainOutlook` (or the hourly forecast, decision
  6) with a `leftOutside` result. Both must hold; the forecast is asked first because it costs no picture.
- **Frost:** `carFrost` from the allowed driveway camera; if `unsure`, a pure `FrostFromForecast` rule
  (current temperature and the day's `lowC` against a figure, default 1 °C) answers, and the answer names its
  source. If a `carPresent` check on the garage camera says the car is inside, the frost check is skipped.
  Plan LH calls this before deciding on defrost.
- **Delivery:** `WatchDeliveryPolicy`, with one change (decision 5): a home check the wearer set up to report a
  problem is outside JO's three-a-day cap, like KU's requested result. Quiet hours still apply: a finding during
  them becomes a notification only, not speech.

### 6 · When it runs

The runner is JO's `WatchRunner.runDue(now:budget:)`, called while the app is alive, on becoming active and
after a wake word, and (when JO P2 lands) from background refresh, which iOS times. So:

- **Alive** (the always-on wake word holds the process, or the app is in front): checks run at their time.
- **Not alive:** a check runs late, the next time the app is, and says it was late ("At 10 pm I couldn't look;
  now the shed's shut"). A check that is more than its own window late (a nightly check by 7 am) is recorded
  missed, never reported as if it were on time.
- **On time, every time** needs a host that is always running: Plan LL runs the same `home_check` kinds next to
  Home Assistant and tells the phone. LD's checks are written so that host can run them unchanged (pure kinds,
  typed results).

## Decisions for Greig (open)

Recommendations first.

1. **No camera by default.** Each camera is allowed by the wearer, with its name and what it may be asked
   about. The model cannot fetch an entity that isn't on the list.
2. **Cameras inside the house:** allowed, but only by explicit name and kind, and never described for people.
   (Alternative: outdoor cameras only in v1.)
3. **Stills are not kept** unless the wearer turns on "keep the photo" for a check; then only the latest,
   filtered, in the app's own store.
4. **Silent unless wrong** for every standing home check; "tell me either way" is an option per check.
5. **A home check's problem finding is outside JO's daily cap** and still respects quiet hours (notification,
   no speech).
6. **Rain horizon:** add WeatherKit's hourly forecast to `WeatherReport` and warn up to three hours ahead
   (minutes only cover an hour, and many regions have none). Alternative: the hour only.
7. **Frost at night:** an infrared or dark picture is `unsure` and the forecast answers, said as the forecast.
8. **Call budget:** 30 cloud checks a day across all home checks, on top of the change gate.

## Phases (one PR each)

### P0 — the pure core (headless)

- `HomeCheckKind` and the five schemas; the allowlist model (`AllowedHomeCamera`: entity, name, kinds,
  reference hash, keep-photo flag) and its validation (an entity not of domain `camera` refused).
- The change gate (`HomeCameraChangeGate` over `PerceptualHash`), `RainExposureRule`, `FrostFromForecast`,
  the parcel age tracker, the "sensor beats picture" resolver, the late/missed rule, and the wording for each
  result.
- **Exit tests:** an entity off the list is never fetched; a sensor present means no still; gate near/far over
  fixture hashes; rain with an empty lawn is silent; rain with an item speaks; `unsure` frost at night falls to
  the forecast and says so; car in garage skips frost; a parcel seen at 1 pm and again at 5 pm fires once; a
  nightly check run at 8 am is recorded missed.

### P1 — asking (wired)

- `HomeCameraClient` (`camera_proxy`, cap, type check, downscale), the `homeAssistantCamera` route, the
  `homeCamera` scope and `homeCameraStill` roster entry, `StructuredVisionService.evaluate` (non-publishing).
- A `home_camera` action on `home_assistant` (or its own `home_check` tool, decided in review) for "is the
  garage shut?", answering from a sensor or a still, the still shown on the phone, one line on the lens.
- `HighImpactToolPolicy`: `get_state`, `list_entities` and the new camera read never ask, whatever the entity
  is called; actuation keeps its floor. A test pins `get_state cover.garage_door` as `.proceed`.
- Settings › Home Assistant › Cameras: the allowlist, names, kinds, reference still, keep-photo.

### P2 — standing checks (wired, needs JO P0–P1)

- `WatcherKind.homeCheck`, the runner hook, silent-unless-wrong delivery, the parcel offer through
  `send_message`'s ordinary confirmation, the rain and frost rules, late and missed wording, the checks in
  JO's Watching screen.
- If JO P0 has not landed, LD P2 waits for it rather than building a second scheduler.

### P3 — the hourly forecast (headless, small)

- `WeatherReport.hours` from WeatherKit's `.hourly`, and `RainOutlook` over hours (decision 6). My Day and
  `get_weather` may use it; neither is changed by this plan.

### P4 — device pass (owed)

- A real Home Assistant with three cameras (door, lawn, driveway) in daylight and at night; a parcel placed
  and left; a nightly check with the app alive on the wake word, and with it not running; the blur on and the
  phone locked (the check must wait, not send); the cost of a day of hourly parcel checks.

## Acceptance

- No still is fetched from a camera the wearer didn't allow, and none leaves the phone unfiltered while the
  blur is on.
- A door with a sensor is answered from the sensor.
- A background check that finds nothing wrong says nothing; one that finds a problem says it once.
- A late check says it was late; a missed one is recorded missed.
- Nothing is sent to anyone without the wearer's own "send".

## Risks

- **Cameras lie at night.** Infrared, glare and rain on the lens give confident wrong answers. Mitigated by
  `unsure` as a first-class answer, the quality probe, and the forecast backup for frost; measured in P4.
- **A wrong "all clear".** Silence is the default, so a missed open shed is invisible. Each check's screen
  shows its last result and still; "tell me either way" exists for a wearer who wants the reassurance.
- **Cost creep** from hourly checks. The change gate and the day budget bound it; P4 measures it.
- **Camera proxies vary.** Some integrations return a slow or stale still. The 10 s timeout and the
  late/unsure wording cover it; a still older than a few minutes (when Home Assistant says so) is unsure.

## Out of scope

- Live video, motion events or recording from Home Assistant cameras.
- Recognising or describing people, faces, number plates or animals on a home camera.
- Acting on what a check found (shutting the garage, locking up). That is an ordinary `home_assistant` call,
  asked for by the wearer, under the existing confirmation floor.
- Cameras not in Home Assistant (vendor clouds with no Home Assistant integration).
- Running checks on time with the phone asleep: Plan [LL](LL-always-on-home-agent.md).
