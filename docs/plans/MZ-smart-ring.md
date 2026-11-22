# Plan MZ — Smart Ring (heart rate, oxygen, steps, sleep and battery from a cheap ring, straight into Apple Health, with no vendor app or cloud)

**Status:** 📝 Drafted 2026-11-22; nothing built. 10 decisions with recommendations. The owner has
one ring in hand, so the device pass (P5) can be run for real as soon as P0–P4 are built.
**Track:** Health and wearables. The phone talks to the ring; the glasses are not involved, except
as the camera a ring trigger can fire (P4).
**Builds on:**
- Plan [GI](GI-health-summaries.md): `health_summary` and its pure core in
  `Services/HealthSummary/` — the `HealthSampleReading` seam, `HealthKitSampleReader`,
  `SleepNightAggregator` (sources merged, not added), `HeartRateSummary`, `StepBaseline` and
  `HealthSummaryDeliveryPolicy` (who hears a health number).
- `FitnessCoachingTool` (`fitness_coach`): workouts saved through `HKWorkoutBuilder`, the step goal
  in `fitnessStepGoal`. Plan [C](C-live-coach-tool.md): `LiveCoachService`.
- Plan [AH](even-display-backend.md): the precedent. A vendor BLE protocol behind a headless codec,
  a transport seam (`EvenTransporting`) with a mock in `EvenDisplayBackendTests`, and
  `EvenBLETransport` shipped dark.
- Plan [GJ](GJ-remappable-temple-gestures.md): `TempleAction`, `TempleActionResolver`,
  `TempleActionPerforming` (`AppState+TempleTaps.swift`). The alternative triggers' `TriggerGate`.
- Plan [BV](BV-power-policy.md) (`PowerPolicyService`, `PowerPosture`), Plan
  [DL](DL-medical-secret-and-export-lifecycle.md) (`HIPAAComplianceService`, `Config.hipaaMode`),
  Plan [DM](DM-privacy-safe-production-logging.md) (`PrivacyLog`, `Scripts/check-privacy-logging.sh`),
  Plan [ET](ET-iso27701-privacy.md) (`DataStoreRegistry`), Plan
  [IK](IK-store-build-without-glasses-sdk.md) (the phone-only store build).

---

## Trigger

The owner bought a cheap generic smart ring. It advertises as `SMART_RING`, speaks a vendor protocol
on service `0x56FF`, and is meant to be used with the vendor's phone app, which sends the readings to
the vendor's cloud. He wants the ring's heart rate, oxygen, steps, sleep and battery in Avenkin
without the vendor's app, account or cloud. He has the ring now.

## The point, said once

**Avenkin is the ring's app.** It talks to the ring itself over Bluetooth, writes what the ring
measured to Apple Health, and reads it back through the health code it already has. Nothing goes to
the vendor, nothing new is stored by Avenkin except which ring is paired and how far it has synced,
and no health number is logged.

## What exists today (verified 2026-11-22 on `origin/main` 09a7bb77e)

- **Health is read-only for summaries.** `HealthKitSampleReader` asks to read heart rate, resting
  heart rate, sleep and steps (`HealthSummaryReadType`) and shares nothing
  (`requestAuthorization(toShare: [], …)`). Each `SleepSample` carries `sourceID`, the writing app's
  bundle identifier.
- **The app writes only workouts.** `FitnessCoachingTool.healthKitShareTypes` is the workout type and
  active energy; `ToolPermissionGate` requests exactly that set. `NSHealthUpdateUsageDescription`
  says Avenkin saves workout data from coaching sessions. The HealthKit entitlement is present.
- **Sources are already merged.** `SleepNightAggregator` takes the asleep timeline from staged
  sources only and unions it, and takes stage totals from the one staged source with the most staged
  time, so a ring beside a watch is not added to it. `cumulativeSteps` is a HealthKit statistics sum,
  de-duplicated across sources by Health's own source order. `latestHeartRate` takes the newest
  sample from any source.
- **One owned BLE stack.** `EvenBLETransport` is the only CoreBluetooth code; it is compiled out of
  the store build (`#if !AVENKIN_PHONE_ONLY`) and is foreground-only by its own decision.
- **Bluetooth in the build.** `Info.plist` declares `bluetooth-central` in `UIBackgroundModes` (with
  `audio`, `external-accessory`, `fetch`). Both Bluetooth usage strings name the glasses only.
  `Scripts/prepare-phone-only-build.py` strips the Bluetooth keys and background modes from the
  store build, and `Scripts/check-phone-only-artifact.py` fails an archive that has them.
- **Triggers.** `TriggerGate` (debounce, suppression) and `TempleActionResolver.resolve(action:context:)`
  turn an input into a `TempleEffect` that `AppState` performs; `.startTalking`, `.photoDescribe` and
  `.photoToCameraRoll` are already actions. Glasses photos go through `CameraService.capturePhoto`
  and its `PhotoCaptureLedger`.
- **Settings.** Devices & Privacy has its own rows for Glasses, Apple Watch and Hardware & Privacy
  (`SettingsScreens.swift`). A device's settings live under its own row.

## The ring's protocol, as far as it is known

Taken from a reverse-engineered description of this ring and checked against a second, independent
working implementation for the same ring. Our code is written fresh in our own Swift from these
facts; nothing is ported. Status markers are the protocol notes' own: CONFIRMED (seen working),
PARTIAL (packet known, fields not all decoded), UNCONFIRMED, UNKNOWN.

**Identity and GATT (CONFIRMED).** Advertised name `SMART_RING`; advertising service `0xFEF5`;
manufacturer id `0x594A`, whose data begins with the ring's own Bluetooth address. The app service is
`000056ff-…`: write `000033f3-…` (property *write*, so write-with-response), notify `000033f4-…`.
Battery Service `0x180F` / `0x2A19` (uint8 percent). The ring also carries Device Information, an
unexplored vendor service `0xFF12`, and HID `0x1812`, which iOS keeps from apps. Some attributes need
pairing; expect the iOS pairing prompt on first connect.

**Packets (CONFIRMED).** Fixed 20 bytes: byte 0 is the command or response id, the rest fields and
zero padding. No length header and **no checksum**. Integers are little-endian. Most commands are
echoed back unchanged as their acknowledgement. Ring timestamps are **local wall-clock seconds**
(UTC plus the offset sent at the last time sync), not UTC.

| Id | What | Status | Used |
|---|---|---|---|
| `01` | Time sync: u32 time at 1–4, signed whole-hour offset at 5; echoed | CONFIRMED | Every connect and on a time zone change |
| `21` | Locale, ASCII `en-US` at 1–5; echoed | CONFIRMED | Sent as observed |
| `0c` | Status; reply carries the ring's address at 3–8, rest undecoded | CONFIRMED / PARTIAL | Liveness only; the address is never kept |
| `02` → `03` + `13` | "Activity query" `0299b85a…`, answered by `03` and `13` | CONFIRMED (bytes) | Not sent (risk 1) |
| `03` | Current activity: time 1–4, steps 5–8, distance-like 9–12, calories 13–16 | CONFIRMED; distance ≈ metres UNCONFIRMED | Steps; distance after P5 |
| `13` | Activity summary: time, two unknown fields, a step-like field at 13–16 | PARTIAL | Decoded, not used |
| `1a` | Step goal, u32 at 1–4; echoed | CONFIRMED | From `fitnessStepGoal` |
| `0b` | Battery percent at byte 1 (matches `0x2A19`) | CONFIRMED | Battery |
| `14 b4` / `14` / `15` / `27` | Live heart rate start; result with BPM at byte 5; stop; completion | CONFIRMED | Live heart rate |
| `23 01` / `24` / `23 00` / `28` | Oxygen start; progress (`24 00…`) then result with SpO₂ at byte 4; stop; completion | CONFIRMED (risk 2) | Spot oxygen |
| `10` → `10` + `11` | Sleep and history query; `11` = time 1–4 then 15 one-minute stages, `28` light, `63` deep | CONFIRMED (night totals matched the vendor app to the minute) | Sleep |
| `16` → `16 f0/aa/a0/ff` | Stored measurements: header, metadata, chunks of stored automatic heart rate, end | PARTIAL | Decoded; written only after P5 |
| `19` | Automatic heart rate: window 1–4 (`00 00 17 3b` = all day), on/off at 5, minutes at 6 (`1e`, `0a` seen), byte 7 `02` seen | CONFIRMED (risk 3) | The schedule setting |
| `07 01` / `06 02` / `07 00` | Selfie mode on; the ring's clench event; off | CONFIRMED | The ring trigger (P4) |
| `04 0a` | Find ring (byte 1 likely duration; `01`, `05`, `0a`, `14` all echoed) | CONFIRMED | Find ring |
| `0e fe dc ba 98 76 54 32 10` | Factory reset, no acknowledgement, link drops | CONFIRMED | Not offered |
| `52`, `1b` variant | Air control / HID mode | UNCONFIRMED | Out of scope |
| `20`, `f6`, `44`, `48` | Startup and config notifications | PARTIAL / UNKNOWN | Counted, not decoded |

## Design

### 1 · Where the readings go: Apple Health (P1)

The ring's driver writes to Apple Health, and everything that reads health reads it back from there:
`health_summary`, last night's sleep, the prepared cards' short-night line and `fitness_coach`'s
history all pick the ring up through `HealthSampleReading` with no change and no second health store
(Decision 1). The only thing held outside Health is a small in-memory channel for the live heart
rate during a workout (§5).

What is written, each sample with Avenkin as its source, an `HKDevice` named "Smart ring" (model
`SMART_RING`, no vendor name), and `HKMetadataKeySyncIdentifier` + `HKMetadataKeySyncVersion` so a
re-sync replaces rather than duplicates:

| Reading | Health type | How |
|---|---|---|
| Live and spot heart rate | `heartRate` | One sample per reading, throttled to one per 5 s; 30–220 bpm only |
| Stored automatic heart rate (`16`) | `heartRate` | After P5 confirms the format against readings taken the same night |
| Spot oxygen | `oxygenSaturation` | The final result only, as a fraction; 70–100 % only |
| Sleep (`11`) | `sleepAnalysis` | Runs of the same stage merged into one sample: light → `asleepCore`, deep → `asleepDeep`. `00` and unknown values are not written (a gap) |
| Steps (`03`) | `stepCount` | The difference between two readings of the ring's day counter, as an interval sample from the last reading to this one; a counter that falls is a new day or a reset and starts again from zero |
| Distance (`03`) | `distanceWalkingRunning` | Only once P5 confirms the unit (Decision 2) |
| Calories (`03`) | — | Not written: how the ring estimates them is unknown |

The sync identifier is `ring.<pairing id>.<kind>.<start>`, where the pairing id is a random value
made when the ring is paired, never the ring's address or the CoreBluetooth identifier. The ring is
the buffer: a sync cursor per kind (a date, no values) moves forward only after Health accepted the
batch. When the phone is locked, Health refuses writes; the batch is dropped from memory, the cursor
stays, and the next sync reads the same span from the ring again. Nothing health-related is written
to Avenkin's own storage.

**Overlap with other sources.** Sleep from a ring and a watch on the same night is unioned for time
asleep and never added; stage totals come from whichever recorded more staged time
(`SleepNightAggregator`, unchanged). A ring with no REM stage and an Apple Watch together will report
the watch's stages whenever the watch recorded more. Steps are de-duplicated by Health's source order,
which the wearer sets in the Health app; the ring settings say so in one line. Resting heart rate is
Apple's own figure from a watch, so the ring adds none.

**Permissions.** New share types: `heartRate`, `oxygenSaturation`, `sleepAnalysis`, `stepCount` (and
`distanceWalkingRunning` after P5), declared once as `RingHealthWriter.shareTypes` and requested from
the ring's settings at pairing, as `FitnessCoachingTool` does. No new read types. The
`NSHealthUpdateUsageDescription` is reworded to cover the ring. Forgetting the ring leaves its
readings in Health (they are the wearer's); the ring settings offer to delete them, which deletes only
samples from Avenkin's source with a ring sync identifier (Decision 7).

### 2 · A seam for rings, built for one ring (P0)

`RingDriver` is the device-agnostic seam: how a family is recognised (advertised name, service,
manufacturer id), its GATT roles, its `RingCapability` set (`liveHeartRate`, `storedHeartRate`,
`spotOxygen`, `steps`, `sleepStages`, `battery`, `findRing`, `clenchEvent`, `heartRateSchedule`,
`stepGoal`), `encode(_ command: RingCommand) -> [UInt8]` and `decode(_ packet: [UInt8]) -> [RingEvent]`.
`RingEvent` and `RingCommand` are the app's own vocabulary; nothing above the driver sees an opcode.
Only `SmartRingDriver` (this ring) is built. A second family later is a new driver and its tests.

### 3 · Time

`RingClock` latches the offset it sends in `01` and converts every ring timestamp back
(`ring seconds − offset`). The latched offset is kept per ring with the cursors, because a night
recorded before a time zone change was stamped with the old offset. The app re-syncs the ring's clock
on every connect and on `NSSystemTimeZoneDidChange`. Half-hour zones: byte 5 truncates, but bytes 1–4
carry the full offset, so decoding uses the latched seconds, not byte 5.

### 4 · The sync

`RingSyncMachine` is a pure state machine: it takes events and clock ticks and returns commands to
write and timers to set. Writes are serialised, one outstanding write-with-response at a time. An
echoed command is its acknowledgement; no echo in 3 s is one retry, then the step is skipped and the
sync carries on.

`connect → subscribe → status (0c) → time (01) → locale (21) → schedule (19) → goal (1a) →
battery (2A19) → activity (03, from the startup burst or the next notification) → sleep (10,
ended by 2 s without an 11) → stored heart rate (16, ended by 16 ff or a 10 s watchdog) → idle`.

From idle: a **live heart-rate session** (`14 b4`, readings, stop with `15` on request, on `27`
restart while a workout wants it, cap 60 s for a spot reading) or a **spot oxygen reading**
(`23 01`, wait up to 45 s for a `24` with a plausible value at byte 4, then `23 00`; a run that ends
with progress only is "no reading", said plainly). One measurement at a time; a request during a sync
waits for the current step, then runs, and the sync resumes after it. A disconnect resets the machine;
the next connect starts again from the top.

### 5 · Live heart rate (P3)

`RingLiveReadings` is an in-memory `@MainActor` value holder: the newest heart rate and its time,
nil after 15 s without a new one. Nothing persists it. `fitness_coach start_workout` asks the ring
service for a live session for as long as the workout runs; `status` includes the heart rate when
fresh; the workout's heart-rate samples are already in Health by its end, and the builder adds them to
the workout. `LiveCoachService` adds one "heart rate now" line to its context only when
`HealthSummaryDeliveryPolicy` would return a health number to the model. Otherwise a number is spoken
by the app, never handed over, exactly as `health_summary` does.

### 6 · The `ring` tool (P3)

`RingTool` (`ring`), registered in `NativeToolRegistry` beside `HealthSummaryTool`. Actions:
`heart_rate` (measure now), `oxygen` (measure now, "keep your hand still for about 40 seconds"),
`battery`, `find` (the ring's light), `last_sync`, `sync`. Measurements go through
`HealthSummaryDeliveryPolicy` and its receipts; battery and last sync are not health data and are
returned. Its `executionSemantics` declares a 60 s timeout for `oxygen`. With no ring paired it says
so and names the setting. The description is written to read well in the generated tool list.

### 7 · Bluetooth (P2)

`RingTransporting` is the seam (connect, disconnect, write, `onNotification`, `onDisconnect`, battery
read), with `MockRingTransport` in the tests replaying invented packets. `RingBLETransport` is the
CoreBluetooth half, its own `CBCentralManager`, never shared with the display's:

- **Find.** Scan for service `0xFEF5` and keep results named `SMART_RING` or carrying manufacturer id
  `0x594A`. Never match on an address. Also ask `retrieveConnectedPeripherals(withServices:)` for
  `0x56FF`: a ring the vendor app already holds on this phone does not advertise but can be found
  this way (Decision 9).
- **Pair.** The wearer picks the ring; its CoreBluetooth identifier is kept as the paired ring.
  Discover `0x56FF` and `0x180F`, subscribe to `33f4`, then run the sync.
- **Stay.** While the app runs the link is held, and a drop reconnects with a pending `connect` (iOS
  completes it when the ring is back in range) after a short backoff (Decision 3). Whether the ring
  drops an idle link, and after how long, is measured in P5; a keepalive is added only if it does.
- **Forget.** Disconnects, clears the pairing id, cursors and latched offset, and tells the wearer to
  also forget the ring in iOS Settings › Bluetooth, which an app cannot do.

**Settings.** Devices & Privacy › **Smart Ring**, its own row beside Apple Watch, shown only when
`Config.ringSupportEnabled` is on (off, no UI, until P5 passes). The screen: Pair a Ring, then the
ring's status (connected, battery, last sync), Apple Health access, what is written, automatic heart
rate (Off / every 30 min / every 10 min), the ring trigger (P4), Find Ring, Sync Now, Delete Ring
Readings from Apple Health, Forget Ring. One line under it: readings are estimates from a consumer
ring, not medical measurements. Nothing ring-related goes in general settings.

**Power.** At `PowerPosture.conserve` the periodic sync interval doubles and the automatic schedule is
left as the wearer set it; at `.reserve` no live session starts without being asked for. The ring's
own battery at 10 % is said once per charge.

### 8 · The ring as a trigger (P4)

In selfie mode the ring sends `06 02` when the wearer clenches or flicks the hand. It is coarse: the
event carries no strength or direction, and an ordinary hand movement can fire it. So:

- **Opt-in, off by default,** chosen in the ring settings from the same `TempleAction` list temple
  taps use (start talking, describe a photo, a photo to the camera roll, save Instant Replay, a Quick
  Action, and the rest). Selfie mode is turned on only while an action is chosen and off when it is
  cleared or the ring is forgotten.
- `RingClenchClassifier` (pure) reads two events within 1.2 s as a double clench. A photo action
  needs a double clench; start talking takes one.
- `TriggerGate` (2 s debounce) and suppression while the assistant is listening, speaking or in a live
  session; then `TempleActionResolver.resolve(action:context:)` and `AppState`'s existing performer.
  A photo goes through `CameraService.capturePhoto`, so the capture light and the ledger apply as for
  any other photo.
- The earcon for a fired trigger is the temple tap's (`TempleEarcon`), so a misfire is heard.

The vendor's "air control" mode (`52`, the `1b` variant) is unconfirmed, and its output is HID, which
iOS does not hand to apps. It is out of scope.

## Phases

The house rhythm: P0–P4 in one PR, everything device-facing behind `Config.ringSupportEnabled`
(off) until the device pass; the catalog sync is its own PR.

- **P0 — the pure core (headless).** `Services/Ring/`: `RingDriver`, `RingCapability`, `RingCommand`,
  `RingEvent`; `SmartRingPacket` (20-byte frame, padding, little-endian fields), `SmartRingDriver`
  (encoder and a decoder per CONFIRMED notification, PARTIAL ones decoded into typed but unused
  events, everything else `.unknown(opcode:)` with no payload kept); `RingClock`;
  `RingSleepTimeline` (packets → merged runs in the app's `SleepStage`); `RingSyncMachine`.
  Tests: `SmartRingPacketTests` (every command's bytes against the protocol's own examples; a 19- or
  21-byte packet refused), `SmartRingDecoderTests` (activity, battery, heart rate, oxygen with
  progress and result, sleep, clench, echoes; unknown opcodes), `RingClockTests` (offset round trip,
  half-hour zone, a night recorded under an older offset), `RingSleepTimelineTests` (a five-hour
  night of 18 light and 2 deep packets gives 4 h 30 light and 30 min deep; a gap from `00`; packets
  out of order), `RingSyncMachineTests` (the full sequence over `MockRingTransport`, a missing echo
  retried then skipped, the sleep quiet window, the stored-history watchdog, a live session's stop
  and cap, oxygen with no result, a measurement during a sync, a disconnect mid-sync). Fixture
  packets are taken from the protocol's published examples or invented; status and identity fixtures
  use an invented address, never a real one.
- **P1 — the Health writer (headless).** `RingHealthWriter` over a `RingHealthStoring` seam (the live
  `HealthKitRingStore`, a fake in tests), `RingHealthBatch`, `RingSyncCursor` (dates only).
  `RingHealthWriterTests`: the mapping table above; the same night synced twice gives one set of
  samples (same sync identifiers); a refused write leaves the cursor; the step counter's
  differences, a fall, and a new day; out-of-range values dropped; delete removes only ring samples.
  `SleepNightAggregatorTests` gains a ring-shaped source beside a watch-shaped one: not added, the
  busier staged source's stages. `RingHealthWriter.shareTypes` matches what `ToolPermissionGate`
  requests.
- **P2 — Bluetooth and settings (dark).** `RingBLETransport`, `RingService` (owns the transport, the
  machine, the writer, the clock), `RingSettingsView`, `Config.ringSupportEnabled`,
  `Config.ringPairing`, the Devices & Privacy row, reworded Bluetooth and Health usage strings, a
  `DataStoreRegistry` entry for the pairing record (pairing id, CoreBluetooth identifier, cursors,
  latched offset; no readings). The Developer panel shows unknown opcodes and their counts, and the
  last twenty packets on screen only, never saved or put in a report. Device-pending: all of it.
- **P3 — live heart rate and the tool (headless + device).** `RingLiveReadings`, the
  `fitness_coach` and `LiveCoachService` hooks, `RingTool`. Tests: `RingToolTests` (each action, the
  delivery policy's receipts in medical mode and without consent, no ring paired),
  `RingLiveReadingsTests` (freshness), the workout asking for and ending a live session.
- **P4 — the trigger (headless + device).** `RingClenchClassifier`, `RingTriggerSetting`, the
  selfie-mode switch in the sync, the settings picker. `RingTriggerTests`: single and double, the
  debounce, suppression, a photo action refusing a single clench, selfie mode off when cleared.
- **P5 — the device pass, on the owner's ring.** Below. Its results decide distance, stored heart
  rate, the idle link and the flag.
- **P6 — catalog sync (its own PR).** The new keys into the 13 complete languages, add-only.

### P5 · What to check on the ring

1. **Pair from clean.** With the vendor app deleted and the ring forgotten in iOS: the ring is found,
   the iOS pairing prompt appears once, the sync runs through, battery matches `0x2A19`. Note whether
   the ring now shows in iOS Settings › Bluetooth as a keyboard or media device (HID).
2. **The vendor app still installed.** Open it, then pair in Avenkin: is the ring found through
   `retrieveConnectedPeripherals`, do both apps get notifications, and does the vendor app overwrite
   the clock or the schedule?
3. **A night.** Wear it overnight, sync in the morning. Sleep in Health matches what the ring reports
   to the minute (compare with the vendor app once, then delete it again); "how did I sleep?" answers
   from it. Repeat with an Apple Watch worn too: no double counting. Look for an awake value.
4. **A walk.** 1 km measured on a map: steps land once in Health beside the iPhone's (Health's source
   order), and the distance field is compared with the 1 km (Decision 2).
5. **Spot readings.** `heart_rate` and `oxygen` from the tool, each against a clip-on oximeter. Also
   try oxygen with `23 02` and compare the `24` packet (risk 2). A short oxygen run says "no reading".
6. **Stored heart rate.** With the 30-minute schedule on overnight, decode `16` and compare against
   spot readings taken during the evening; look at the cadence and at any outlier.
7. **A workout.** `fitness_coach` start, 20 minutes, stop: the heart rate keeps coming (note how long
   one live run lasts before `27`), the saved workout has it, and the ring's battery cost per hour.
8. **The link.** Leave the phone idle in a pocket for an hour, app in the background: does the link
   hold, does it drop when idle and after how long, does it come back on its own. The same with the
   phone locked overnight: the morning sync fills the night once the phone is unlocked.
9. **Time zones.** Change the phone's time zone and sync; a later night lands at the right hours.
10. **The trigger.** Selfie mode on: how readily does an ordinary hand movement fire `06 02`, can a
    double clench be made reliably, and does the clench also send a volume or camera key to iOS
    through HID (risk 4)? A photo by double clench, start talking by single.
11. **Find ring and the goal.** `04 0a` lights it; the goal from `fitnessStepGoal` is echoed.
12. **Logs.** `check-privacy-logging.sh` passes and a support report has no reading, address or
    peripheral identifier in it.

## Decisions for Greig

1. **Where readings live.** *Recommend:* Apple Health, read back through the existing seam (§1).
   *Alternative:* Avenkin's own store, which works without Health permission but makes a second
   health store, a registry entry with health values, and every reader a second path.
2. **Steps, distance, calories.** *Recommend:* steps now; distance after P5 confirms the unit; never
   calories. *Alternative:* steps only, leaving distance to the phone and watch.
3. **Background.** *Recommend:* hold the link while the app runs, using the `bluetooth-central` mode
   the glasses build already declares, with a pending reconnect; no state restoration in v1.
   *Alternative:* foreground-only like the display (simplest, but a night syncs only when the app is
   opened), or state restoration now (the app relaunched by the ring, more to test).
4. **Automatic heart rate.** *Recommend:* on at every 30 minutes, the setting offering Off / 30 / 10
   (only those two cadences have been seen working). *Alternative:* off until the wearer turns it on.
5. **The store build.** *Recommend:* TestFlight (the glasses build) only until P5 passes; the store
   build then as a decision of its own, since it means putting a Bluetooth usage string and the
   background mode back into `prepare-phone-only-build.py` and `check-phone-only-artifact.py`.
   *Alternative:* both builds from the start, with the transport outside `#if !AVENKIN_PHONE_ONLY`.
6. **Medical mode.** *Recommend:* the ring syncs to Health as usual (the wearer's own data, on their
   own phone); every number is spoken by the app and never given to a model, as `health_summary`
   already does under `HealthSummaryDeliveryPolicy`. *Alternative:* the ring stops in medical mode.
7. **Forgetting the ring.** *Recommend:* readings stay in Health; a separate Delete Ring Readings
   button removes them. *Alternative:* forgetting also deletes them, after a confirmation.
8. **The trigger's default.** *Recommend:* off, with Start Talking first in the picker, and photo
   actions needing a double clench. *Alternative:* no photo actions on the ring at all.
9. **The vendor app still on the phone.** *Recommend:* when the ring is found already connected
   through another app, say once that the ring's own app is still talking to it and may change its
   clock and schedule, and suggest removing that app. *Alternative:* refuse to pair until it is gone.
10. **The body profile (`02`).** *Recommend:* not sent (risk 1). If P5 shows activity stops without
    it, send the wearer's own height, weight, age and sex, entered in the ring settings, never
    defaults. *Alternative:* read them from Health, which needs four new read permissions.

## Privacy and safety

- **No vendor cloud, no account, no new SDK.** CoreBluetooth and HealthKit only. Nothing from the ring
  leaves the phone except what the wearer's own Health sync and their own consent to share health
  data with an AI already allow. There is no telemetry.
- **Logs.** `PrivacyLog` `.device` events name what happened (connected, synced, write refused,
  unknown opcode) with no reading, no address, no CoreBluetooth identifier and no packet bytes. A scrape
  test holds that nothing in `Services/Ring/` passes a reading or an identifier to `PrivacyLog`.
- **The address the ring broadcasts** is read only to recognise the ring family, never kept, logged or
  used as a sync identifier.
- **Not medical.** The settings, the tool's description and spoken answers call the readings
  estimates from a consumer ring. The ring is never used to tell anyone a reading is safe or unsafe;
  blood pressure, which the ring's oxygen packet may carry, is not decoded or written.
- **Medical mode** per Decision 6.

## Risks and open questions

1. **The "activity query" is probably a body profile.** `0299b85a…` reads as age 25, male, 184 cm,
   90 kg under the second implementation's encoding of `02`. Sending it would set a stranger's body on
   the wearer's ring and skew its calorie and distance estimates. Activity packets also arrive in the
   burst after subscribing, so P0 does not send it (Decision 10).
2. **Oxygen's mode byte.** The notes confirm `23 01` and a SpO₂ at byte 4 of `24`; the second
   implementation reads `23 01` as a blood-pressure run and `23 02` as oxygen, with `24` carrying
   several values at once. Byte 4 is oxygen either way. P5 compares the two.
3. **The schedule's byte 7** was observed as `02`; the second implementation sends `01`. Send the
   observed `02`; P5 checks the echo and that readings are stored.
4. **HID.** The ring carries HID `0x1812`. If iOS bonds it as a keyboard or media device, the clench
   or air-control mode may send keys to iOS (volume, the camera shutter) beside our event.
5. **Activity summary `13`** field meanings; **distance** units and rounding; **calories** versus the
   vendor app.
6. **The awake value** in the sleep timeline has never been seen; `00` is treated as no data.
7. **Stored history `16`** is PARTIAL: cadence, repeated bytes, a 149 bpm outlier in a night of 70s.
   Nothing from it is written before P5.
8. **Older days.** Whether byte 1 of `10` and `16` selects a day (0 = today), so a phone away for
   several days can catch up, is unconfirmed. Until it is, a missed night is a missed night.
9. **Undecoded notifications** `20`, `44`, `48`, `f6`, and the second implementation's claim and bind
   commands (`48`, `4b`), which may matter if the ring stops answering after its own app held it.
10. **Health accuracy.** Apple asks that apps not write inaccurate data to Health. Range checks, the
    `HKDevice`, and writing nothing unconfirmed are the defence.
11. **A reverse-engineered protocol.** Firmware updates through the vendor app could change it. The
    driver refuses what it cannot decode rather than guessing.

## Not in scope

- The vendor's cloud, account, firmware updates or its other apps.
- Factory reset from Avenkin; air control and HID; the `FF12` service.
- Blood pressure, stress, blood sugar or any value the notes do not confirm.
- A resting heart rate or sleep score of our own.
- Showing ring readings on the glasses' lens (a later, small change once P5 passes).
- Other ring families (a new `RingDriver` each, later).

UI copy never names plan letters or the vendor. The words are "ring", "smart ring", "heart rate",
"oxygen", "sleep", "steps" and "Apple Health".
