# Plan LH — Car Routines with Home Assistant (office day or school run, the car warm on time, switched off if you didn't leave)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) are
recommendations and are still open.
**Track:** Everyday assistant (home and car). No Field Assist dependency.
**Builds on:** `VehicleTool` (`vehicle_status`) and its planned entity-override follow-up
([vehicle-ev-status](vehicle-ev-status.md)), `HomeAssistantServiceCalling` / `HomeAssistantRESTClient`,
`HomeAssistantServiceData` (the service-data allowlist), `HomeAssistantEntityCache`, `QuickAction`
(`.homeAssistant`, `haService`, `haEntityId`) and the lens Home list of Plan [LC](LC-the-lens-made-ready.md),
`HighImpactToolPolicy` and `ToolAuthorizationPolicy` (Plan [BC](BC-unconditional-safety-gate.md)),
`ToolEffectClassifier`, My Day's morning slot (`MyDayDeliverySlot`, `MyDayDeliveryPolicy`, Plan
[DY](DY-my-day-everyday-briefing.md)), the local-notification scheduling in `AlarmScheduling`.
**Sits beside:** Plan [LD](LD-home-cameras-through-home-assistant.md) (answers "is the car frosted?" and "is it
in the garage?"), Plan [LG](LG-reminders-on-a-rhythm.md) (the reminder that keeps coming back until you say
it's done), Plan [LL](LL-always-on-home-agent.md) (the always-on host; LH does not need it, because Home
Assistant keeps the time).

---

## Why

The owner shared, on 2026-11-11, an example list of routines a cloud personal agent runs. One of the most
used is a weekday car routine:

- each weekday morning it asks whether today is an office day;
- on an office day it warms the car (charging held on so the battery isn't used for heat, climate on, started
  earlier when it's colder) for a fixed departure time;
- on other days it warms the car for an earlier school run instead, and keeps reminding the wearer to do a
  related task until they say they have;
- a failsafe turns the climate off if the car is still parked at home well after departure time;
- defrost is decided from a driveway camera, with the forecast as backup, and skipped when the car is seen in
  the garage.

Avenkin can read the car through Home Assistant today and nothing more. The obvious build, "the app warms the
car at 7:05", would fail on the morning it matters: an iPhone app cannot promise to run at a given minute. Home
Assistant can. So this plan splits the job along that line.

**Avenkin asks and records the answer. Home Assistant keeps the time and does the work.**

## Outcome

- **The question.** On a weekday morning, at the time the wearer chose: "Office day today, or the school run?"
  - With the glasses on and the app listening, it is asked aloud (as part of My Day's morning briefing when
    that is on). "Office" → "Okay, the car will be warm for 7:30." "School run" → "Okay, warm for 8:10. I'll
    keep reminding you about your school-run task until you say it's done." "Neither" or "not today" →
    "Okay, I'll leave the car."
  - Otherwise a notification with three buttons: **Office**, **School run**, **Not today**. Pressing one is
    the answer; the app doesn't need to open.
  - No answer by the cut-off: nothing warms (decision 2), and the next time the app is in front it says so once.
- **The car.** Home Assistant warms it on time, starting earlier in the cold, with defrost when LD or the
  forecast said so, and turns it off if the car hasn't left 20 minutes after departure. None of this needs the
  phone awake.
- **Asking about it.** "Is the car warming?", "what did you set the car for?", "did the failsafe turn it off?"
  are read from Home Assistant and answered.
- **Changing your mind.** "Actually it's an office day" before departure flips the answer; "don't warm the
  car" clears it.
- **The reminder.** On a school-run day, a reminder that repeats (at the wearer's interval) until they say
  "done" (Plan LG).
- **Set up once, in Home Assistant.** Settings › Home Assistant › Car routine names the helpers the app
  writes and shows a copyable example automation (see the [appendix](#appendix--example-home-assistant-setup)).
  The app never writes Home Assistant automations itself.

## What exists (verified 2026-11-11 at main 2d936d2)

- **`VehicleTool` (`vehicle_status`) only reads.** No parameters. It force-refreshes `HomeAssistantEntityCache`
  and fuzzy-matches four metrics (battery, range, charging, plugged in) from fixed query lists, then a pure
  `summary(battery:range:charging:plugged:)` makes one sentence. **No climate, location or "is it home"
  reading, and no entity overrides** (the follow-up its plan names). It declares no `executionSemantics`, so it
  takes `ToolExecutionSemantics.conservativeDefault` (`externalMutation`) although it never writes.
- **`HomeAssistantTool` (`home_assistant`)** can call any service on any entity the model names, but
  `HomeAssistantServiceData` allowlists only `media_content_id`, `media_content_type`, `volume_level` and
  `source`. So `climate.set_temperature` with a `temperature`, or `input_select.select_option` with an
  `option`, is refused; `input_boolean.turn_on`, `script.turn_on` and `climate.turn_off` with no data pass.
  When a service call fails, `callServiceWithFallback` retries through Home Assistant's Conversation API in
  natural language, which is not what a car routine should do.
- `HomeAssistantTool.runFavourite(domain:service:entityId:data:)` (Plan LC) makes a single call with the same
  guards and **no** Conversation fallback, answering yes or no. `QuickAction` of type `.homeAssistant` holds a
  service, entity and optional data; the lens Home list runs them through `HomeFavouriteRunner`, asking first
  when the floor says so.
- **The confirmation floor.** `HighImpactToolPolicy` asks before a `home_assistant` call whose text contains
  "unlock", "lock.", "open", "cover.", "garage", "alarm", "disarm" or "arm_". Car climate and a charge switch
  match none of these, so they run without asking today. `ToolEffectClassifier` raises an **external** tool
  that mentions "vehicle" to `physicalActuation`; it does not look at native calls that way.
- **My Day** has a morning and an evening delivery slot (`MyDayDeliverySettings`: times, scheduled speech,
  quiet hours). It runs only while the process is alive (`AgentScheduler`, the always-on wake word, or the
  app in front).
- **Notifications:** local notifications are scheduled by `AlarmScheduling` (`UNCalendarNotificationTrigger`),
  `TimerTool` and `PomodoroTool`. **No notification category or action exists**: nothing in the app
  answers a button on a notification.
- **No background execution of its own** and no push (`UIBackgroundModes` is `audio`, `bluetooth-central`,
  `external-accessory`; no `BGTaskScheduler`).
- `CalendarTool` and `EventKitDayStore` can read today's events.

## Design

### 1 · What the app writes: helpers, not the car

The routine's only writes are Home Assistant **helpers** the wearer created, with no service data:

| Helper | Meaning | Written by |
|---|---|---|
| `input_boolean.<prefix>_office_day` | today is an office day | the answer |
| `input_boolean.<prefix>_school_run` | today is a school-run day | the answer |
| `input_boolean.<prefix>_car_defrost` | defrost wanted this morning | LD's frost answer, or the forecast rule |

The departure times live in Home Assistant (`input_datetime` helpers), set there or from the app's settings
screen through the same no-data rule (decision 4 keeps time-setting in Home Assistant for v1). Home
Assistant's automations read the helpers and do everything that touches the car.

This keeps the allowlist as it is: no temperature or arbitrary data ever comes from the model. It also means a
wrong answer from the app can do at most what the wearer's own automation does.

The helper entity ids are configured once in settings (a prefix, then checked against the entity cache: each
must exist and be an `input_boolean`). They are never fuzzy-matched.

### 2 · The routine (`CarRoutine`, pure)

```swift
struct CarRoutine: Codable, Equatable {
    var enabled: Bool
    var days: Set<Weekday>             // default Monday–Friday
    var askAt: Minutes                 // default 6:40
    var cutoff: Minutes                // default 7:00; after it, the question is withdrawn
    var helpers: CarRoutineHelpers     // the three entity ids
    var schoolRunReminder: ReminderLink?   // an LG reminder started on a school-run answer
}
enum CarDayAnswer: Equatable { case office, schoolRun, notToday }
```

- `CarRoutineQuestion` (pure): the wording, and `parse(_:)` for spoken answers ("office", "work", "in the office"
  → `.office`; "school", "school run", "drop-off" → `.schoolRun`; "neither", "no", "not today", "working from
  home" → `.notToday`; anything else asks once more, then leaves it).
- `CarRoutinePlan` (pure): an answer → the ordered helper calls (`office`: office on, school off; `schoolRun`:
  school on, office off; `notToday`: both off) → `[HelperCall]`. Pure so the mapping is tested without a
  server.
- **A calendar hint, not a decision** (decision 1): if today has an all-day event whose title the wearer
  chose ("Office", "WFH"), the question leads with it: "Your calendar says office. Still right?" The calendar
  never answers on its own.

### 3 · Asking

- **Aloud**, when My Day's morning slot or the routine's own `askAt` falls while the app is alive and the
  glasses are connected, through `MyDayDeliveryPolicy`'s quiet-hours and busy rules. The answer goes through
  `CarRoutineQuestion.parse`.
- **A notification** otherwise: a daily `UNCalendarNotificationTrigger` on the chosen days at `askAt`, in a new
  category `carRoutine` with three actions that do **not** open the app. iOS gives the app a short background
  window to handle the response; the handler runs `CarRoutineRunner` and replaces the notification with the
  result ("Car set for 7:30", or "Couldn't reach Home Assistant: open Avenkin to retry"). This is the first
  notification category in the app; its handler is small and only ever writes the routine's own helpers.
- If the wearer answered aloud, the pending notification for today is removed.
- **After the cut-off** no answer is taken for today, so a late "office" can't warm the car after the wearer has
  left. Changing your mind before the cut-off is fine.

### 4 · Writing (`CarRoutineRunner`)

- Uses `HomeAssistantServiceCalling.callService` (the seam `HomeAssistantRESTClient` conforms to), never the
  Conversation fallback. Each call's result is checked by reading the helper back; a mismatch is "I couldn't
  set the car". Each is a write to one of the wearer's own helpers, declared `externalMutation`, and the answer
  to the routine's question is the consent for it (decision 3).
- **Medical Local Only** and the `homeAssistantCommand` route apply as for every Home Assistant call.

### 5 · Reading the car (`vehicle_status`, widened)

- **Entity overrides** (the follow-up in `vehicle-ev-status.md`): Settings › Home Assistant › Car names the
  battery, range, charging, plug, climate, location (`device_tracker`) and charge-override entities.
  `resolve` tries the configured id first, then today's fuzzy match.
- New readings: climate on/off and target, whether the car is home, whether the routine is set today
  (`office_day`/`school_run`), and whether the failsafe fired (an optional helper the example automation turns
  on). The pure `summary` grows to say them.
- `vehicle_status` declares `ToolExecutionSemantics` read-only, removing it from the conservative-default debt.

### 6 · Car commands by voice (`vehicle_control`)

"Warm the car now", "turn the car off", "hold the charge on" are reasonable to want outside the routine. A
small native tool, separate from `vehicle_status` so the read stays read-only:

- Actions: `climate_on`, `climate_off`, `charge_hold_on`, `charge_hold_off`. Each maps to a configured entity
  and a no-data service (`climate.turn_on`/`turn_off`, `switch.turn_on`/`turn_off`). **No configured entity, no
  action**: never fuzzy-matched for a write (decision 6).
- Declared `physicalActuation`. Climate and charge-hold ask once per command on the glasses ("Turn the car's
  climate on?") the first time each day, then not again that day (decision 3).
- **The floor grows for cars.** `HighImpactToolPolicy` adds car-security words (`trunk`, `frunk`,
  `charge_port`, `window`, `sentry`, `door`) so that a `home_assistant` call naming one always asks, as a lock
  does. `vehicle_control` offers none of them.

### 7 · Joining LD and LG

- **Defrost.** At `askAt`, if LD is set up with an allowed driveway camera, LH asks LD's `carFrost` (skipped when
  LD's `carPresent` says the car is in the garage) and writes `car_defrost`. With no camera, or an `unsure`
  answer, LD's `FrostFromForecast` rule decides. The example automation also has its own forecast fallback, so
  defrost still works on a morning the phone said nothing.
- **The school-run reminder.** A `.schoolRun` answer starts the linked LG reminder (the task the wearer
  named when setting it up), which repeats at its interval until the wearer says done. The routine stores only the link, never the
  reminder's text.

## Decisions for Greig (open)

Recommendations first.

1. **Ask, don't infer.** The calendar may suggest the answer; it never answers.
2. **No answer by the cut-off: nothing warms.** Alternative: a default mode per weekday.
3. **The routine's answer is the consent** for that morning's helper writes. A free-form car command asks once a
   day per action; car-security actions always ask.
4. **The app writes only `input_boolean` helpers** in v1. Temperatures, lead times and departure times live in
   Home Assistant. (Alternative later: a narrow allowlist entry for `input_datetime.set_datetime`'s `time`.)
5. **A notification with buttons** when the app isn't listening, handled in the background without opening.
6. **No fuzzy matching for writes.** `vehicle_control` and the routine act only on configured entities.
7. **Days are the wearer's** (default weekdays). Public holidays are Home Assistant's job (its workday
   integration), and the example automation checks it.

## Phases (one PR each)

### P0 — the pure core (headless)

- `CarRoutine`, `CarDayAnswer`, `CarRoutineQuestion` (wording and parser), `CarRoutinePlan`, the calendar-hint
  rule, the cut-off rule, `VehicleEntityOverrides` resolution (configured first), the widened `summary`, and the
  car-security additions to `HighImpactToolPolicy`.
- **Exit tests:** each answer's helper calls in order; "working from home" is not-today; an unclear answer asks
  once; an answer after the cut-off is refused and said; a calendar "Office" event leads the question but sets
  nothing; a configured entity beats a fuzzy match; `home_assistant` with `lock.car_doors` or "open the trunk"
  asks; `climate.turn_on` does not.

### P1 — reading and commands (wired)

- Settings › Home Assistant › Car (overrides, checked against the cache). `vehicle_status` new readings and
  read-only semantics. `vehicle_control` with its once-a-day confirmation, through
  `HomeAssistantServiceCalling` without the Conversation fallback.

### P2 — the morning question (wired)

- Settings › Home Assistant › Car routine (days, ask time, cut-off, helpers, the copyable example). The spoken
  question inside My Day's morning slot or on its own; the `carRoutine` notification category, its background
  handler and the replacement notification; `CarRoutineRunner` with read-back.

### P3 — defrost and the reminder (wired, needs LD P1 and LG P1)

- The frost answer written to `car_defrost`; the linked LG reminder on a school-run answer; the morning recap
  line when the failsafe fired ("The car's climate was switched off at 7:50 because it hadn't left").

### P4 — device pass (owed)

- A real Home Assistant with a car integration: the spoken question on the glasses; the notification answered
  from the lock screen with the app not running; Home Assistant unreachable at answer time; a change of mind
  before the cut-off; the failsafe on a morning the car didn't move; defrost from the camera and from the
  forecast.

## Acceptance

- The car is never warmed because the app guessed. It is warmed only on an answer, before the cut-off, and only
  by the wearer's own automation.
- A notification answer works with the app not running, and says so when Home Assistant can't be reached.
- No car action runs on an entity the wearer didn't configure.
- Car-security actions always ask.

## Risks

- **The background window is short and not promised.** A slow Home Assistant can miss it. The handler reports
  failure in the replaced notification; the example automation's fallback (nothing warms) is safe.
- **Integrations differ.** Climate modes, defrost and charge override are exposed differently by each car
  integration. The app writes helpers only, so the differences stay in the wearer's automation.
- **A wrong answer warms the car for nothing.** The failsafe bounds it; "don't warm the car" clears it.
- **Remote access.** Answering from outside the house needs Home Assistant reachable from there. The settings
  screen says so; LH adds no relay.

## Out of scope

- The app writing or editing Home Assistant automations, scripts or helpers.
- Talking to a car maker's own service directly (a vendor-direct path is the vehicle plan's later follow-up).
- Unlocking, opening or any car-security action by voice from this plan.
- Inferring office days from location history.
- The same routine without Home Assistant. (Home Assistant's own companion app can ask a question with
  notification buttons too; a wearer who wants only that needs nothing from Avenkin.)

## Appendix — example Home Assistant setup

Shown in the app for the wearer to copy into their Home Assistant and adapt. Every entity id below except the
`input_boolean`s is a placeholder for the wearer's own; climate modes and the defrost switch depend on the car's
integration. Uses the current automation syntax (`triggers:` / `actions:`).

```yaml
input_boolean:
  avenkin_office_day:
    name: Office day today
  avenkin_school_run:
    name: School run today
  avenkin_car_defrost:
    name: Defrost the car this morning
  avenkin_car_failsafe_fired:
    name: Car failsafe fired today

input_datetime:
  avenkin_office_departure:
    name: Office departure
    has_date: false
    has_time: true
  avenkin_school_departure:
    name: School-run departure
    has_date: false
    has_time: true

template:
  - sensor:
      - name: Car departure today
        unique_id: avenkin_car_departure_today
        state: >
          {% if is_state('input_boolean.avenkin_office_day', 'on') %}
            {{ states('input_datetime.avenkin_office_departure') }}
          {% elif is_state('input_boolean.avenkin_school_run', 'on') %}
            {{ states('input_datetime.avenkin_school_departure') }}
          {% else %}none{% endif %}
      - name: Car warm-up lead
        unique_id: avenkin_car_warm_up_lead
        unit_of_measurement: min
        state: >
          {% set t = states('sensor.outside_temperature') | float(10) %}
          {% if t < -5 %}35{% elif t < 0 %}25{% elif t < 5 %}15{% else %}10{% endif %}

automation:
  - alias: Avenkin – warm the car before leaving
    triggers:
      - trigger: template
        value_template: >
          {% set dep = states('sensor.car_departure_today') %}
          {{ dep != 'none' and now() >= today_at(dep)
             - timedelta(minutes=states('sensor.car_warm_up_lead') | int(15)) }}
    conditions:
      - condition: state
        entity_id: binary_sensor.workday_sensor
        state: "on"
      - condition: state
        entity_id: device_tracker.my_car
        state: home
    actions:
      - action: switch.turn_on            # the integration's "keep charging" / charge override
        target:
          entity_id: switch.my_car_charge_override
      - action: climate.turn_on
        target:
          entity_id: climate.my_car
      - if:
          - condition: or
            conditions:
              - condition: state
                entity_id: input_boolean.avenkin_car_defrost
                state: "on"
              - condition: numeric_state      # the forecast fallback when the phone said nothing
                entity_id: sensor.outside_temperature
                below: 1
        then:
          - action: switch.turn_on
            target:
              entity_id: switch.my_car_defrost

  - alias: Avenkin – car climate off if it didn't leave
    triggers:
      - trigger: template
        value_template: >
          {% set dep = states('sensor.car_departure_today') %}
          {{ dep != 'none' and now() >= today_at(dep) + timedelta(minutes=20) }}
    conditions:
      - condition: state
        entity_id: device_tracker.my_car
        state: home
      - condition: not
        conditions:
          - condition: state
            entity_id: climate.my_car
            state: "off"
    actions:
      - action: climate.turn_off
        target:
          entity_id: climate.my_car
      - action: input_boolean.turn_on
        target:
          entity_id: input_boolean.avenkin_car_failsafe_fired

  - alias: Avenkin – reset the car routine overnight
    triggers:
      - trigger: time
        at: "02:00:00"
    actions:
      - action: input_boolean.turn_off
        target:
          entity_id:
            - input_boolean.avenkin_office_day
            - input_boolean.avenkin_school_run
            - input_boolean.avenkin_car_defrost
            - input_boolean.avenkin_car_failsafe_fired
```
