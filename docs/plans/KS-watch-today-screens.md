# Plan KS — Today on the Apple Watch (Now Playing, today's calendar, today's weather)

**Status:** 🚧 P0 + P1 built 2026-11-07 (one PR, headless): the shared `today` payload, its codec and
budget, the is-it-today and which-is-now rules and the midnight schedule, compiled into the phone and
the watch; the phone builds the value from what My Day gathered and folds it into every
application-context push beside `surfaces` and `job`; the watch draws three vertical pages — the
system Now Playing view, the calendar, the weather with its credit — behind a **Today** row; "Today on
Your Watch" in Settings › Devices & Privacy › Apple Watch, on by default. The device checks below are
owed: nothing here has run on a real watch. All decisions taken as recommended; the owner can change
any.

**Related:** Plan [GM](GM-watch-map-and-list-surfaces.md) (the phone → watch surface path this rides
on, and the one-dictionary rule), My Day (the plan that built `MyDayService` and its sources; the
watch reads what it gathers), FO P3a (`JobWatchPayload`, the first keyed context value).

---

## Trigger

Glanceable today screens on the wrist: what is playing, what is next on the calendar, and what the
weather is doing, without taking the phone out. The phone already composes all of it for My Day; the
watch showed none of it.

## Outcome

Raise the wrist, tap **Today**, and swipe through:

1. **Now Playing** — the system's own controls for whatever is playing, on the iPhone or the watch.
2. **Calendar** — today's next items still to come (at most six), all-day first, the current one marked
   **Now** in coral and the first one to start marked **Next**; "N more today on your iPhone" past the
   cap. Under Medical Compliance, times only.
3. **Weather** — the condition symbol, the temperature now, today's high and low, the chance of rain,
   the condition in words, and the weather credit.

Every page that has nothing to show says why: open the app on the iPhone, unlock the iPhone, calendar
off in My Day, no calendar access, weather off under Medical Local Only, the setting off.

## What exists (verified against `origin/main` at 1e9d45754, 2026-11-07)

- **The surface path (Plan GM).** `WatchSurfacePublisher.push()` is the one place every
  application-context push goes through: the phone's status dictionary (`statusContext()`, with `job`
  while a job is open) plus the `surfaces` value. The context is one dictionary and latest wins, so a
  key a push leaves out is cleared on the watch. `WatchConnectivityService.apply(_:)` on the watch reads
  each key; an absent `job` or `surfaces` clears it.
- **My Day.** `MyDayService.refresh` gathers calendar (today and tomorrow), reminders, weather, travel,
  the digest and goals, then `MyDayComposer` ranks and caps them into card rows. The rows keep a title,
  a detail and a due time — not an end time, an all-day flag or a place — and the weather reached My
  Day only as a spoken sentence (`MyDayWeather.summary`). A refresh with protected data unavailable
  reads nothing and says "Unlock iPhone to refresh My Day".
- **Weather.** `WeatherReport` (plain values copied from WeatherKit) had no symbol name. The phone
  draws `WeatherAttributionView` (Apple's mark and the legal link) wherever weather is shown, from
  `WeatherAttributionStore`, which falls back to the text "Apple Weather" and Apple's legal page.
- **Settings › Devices & Privacy › Apple Watch** held "Maps on Your Watch" only.
- **Scheduled My Day** already avoids permission sheets: `myDayDelivery.sourceAccessReady` refreshes
  only when every included source's permission has been answered.

### watchOS facts (checked in the watchOS 27.2 SDK in Xcode)

- **`NowPlayingView`** is declared in `_WatchKit_SwiftUI.swiftinterface` as
  `@available(watchOS 7.0, *) public struct NowPlayingView: View` with a plain `init()`, reached by
  `import WatchKit` beside SwiftUI. The deployment target is watchOS 26.0, so it is available with no
  check and no fallback. It is the system's now-playing interface and follows whatever is playing
  (the paired iPhone or the watch), so the phone needs no code for it.
- **WeatherKit attribution.** Apple requires the Apple Weather trademark and a link to the legal
  attribution page wherever WeatherKit data is displayed (`WeatherAttribution`: `serviceName`,
  `legalPageURL`, the combined marks). Apple's documentation states no watchOS-specific placement
  rule. SwiftUI `Link` exists on watchOS; whether a real watch opens that page is unverified.

## Design

### The phone resolves, the watch draws (decision 1)

No EventKit, WeatherKit or CoreLocation on the watch. The phone sends a compact `today` value:

- `WatchTodayPayload` (`OpenGlasses/Sources/Shared/WatchToday.swift`, Foundation only, listed in
  `project.watch.yml`): a version, the **day** it applies to (year, month, day in the phone's
  calendar), when it was gathered, the calendar's status and its items (`WatchTodayEvent`: id, start,
  end, all-day, optional title, optional short place), the count past the cap, whether titles were
  withheld, the weather's status and `WatchTodayWeather` (SF Symbol name, temperature, high, low,
  chance of rain, condition text, unit — whole degrees in the wearer's unit), and the weather credit
  (`WatchTodayAttribution`: service name and legal page URL), present whenever weather is.
- Each section's status is a stated reason: `shown`, `notIncluded`, `noAccess`, `locked`,
  `medicalOff`, `unavailable`, `settingOff`.
- `WatchTodayCodec`: binary property list, an **8 KB budget** (six full items and the weather come to
  well under 2 KB); over budget drops trailing items into the count, never silently; a version this
  build does not know decodes to nothing.
- `WatchTodayBuilder` (phone, pure) builds it from `MyDayGathered`, a new record `MyDayService`
  publishes on every refresh: the calendar as gathered (before the composer's ranking), the weather
  with its `WeatherReport`, each source's state, and whether the phone was locked. Items are today's
  (overlapping the gathered day), not yet ended, all-day first then by start; titles cut to 60
  characters, places to their first line and 40. `MyDayWeather` gained an optional `report`, and
  `WeatherReport.Current`/`.Day` an optional `symbolName` copied from WeatherKit (a fixed fallback
  table covers a report built without one).

### One dictionary (Plan GM's rule, extended)

`WatchApplicationContext.fold(base, surfaces:, today:)` is the rule every push follows: a nil value
**removes** its key, so `today`, `surfaces` and `job` always travel together and none clears another.
`WatchSurfacePublisher.push()` calls it with `WatchTodayPublisher.contextValue()`. The value is built
at push time from the held gathering, so a change of Medical Compliance mode or of the setting applies
to the very next push, whoever sends it.

### Refresh (decision 3)

`WatchTodayPublisher` (phone) holds the last gathering and asks for a push only when the encoded value
changes. It sees every My Day refresh, whoever asks for one (the card, a briefing, a scheduled
delivery). It asks for one itself — `refresh(channel: nil)`, no briefing — on app foreground (at most
every 15 minutes, `WatchTodaySchedule.foregroundInterval`), just after local midnight
(`WatchTodaySchedule.nextMidnight`), and when the watch app is installed. It never asks while the
setting is off or there is no watch, and only when every included source's permission has been
answered (`AppState.myDaySourceAccessReady`, now shared with scheduled My Day), so it cannot put a
permission sheet up. A defaults change (Medical Compliance, an organisation profile, the setting)
rebuilds the value, debounced by a second.

A look taken while the phone is locked reads nothing; it never replaces a good gathering of the same
day (`WatchTodayHoldPolicy`). A new day always replaces, so after midnight with the phone locked the
watch says "Unlock your iPhone to update today".

On the watch, `WatchTodayFreshness.evaluate` decides against the watch's own clock: no value → "Open
Avenkin on your iPhone to update today"; another day → the same; the setting off → its own sentence;
today → the pages. `WatchTodayTimeline.rows` drops ended items and marks **Now** / **Next**; the pages
re-evaluate every minute (`TimelineView(.everyMinute)`), so the marks move and the day turns at
midnight without the phone.

### Privacy (decision 4)

- **"Today on Your Watch"**, on by default, under "Maps on Your Watch". Off sends a small `settingOff`
  value (no calendar, no weather), so the watch can say where to turn it on rather than to open the app.
- **Any Medical Compliance mode** (Local Only or not): times and counts, never titles or places. The
  test checks the encoded bytes carry neither. Under **Local Only** the weather is `medicalOff`, as the
  weather tool already refuses it there.
- Calendar data travels only over WatchConnectivity, to the wearer's own watch. The watch makes no
  request for any of it. The watch's privacy manifest header ("the app's own code transmits nothing
  off the device… talks to the paired iPhone over WatchConnectivity") stays true and is unchanged; the
  phone's WeatherKit and EventKit use is unchanged, so its manifest is too.
- Logs: a refused value logs `todayRefused` with the codec's reason and the byte count — nothing of
  the day.

### Watch layout (decision 5)

A **Today** row under the status and the map card row, with the first item still to come as its
subtitle ("Now: Site visit", "10:30 Site visit", or the time alone under Medical Compliance). It opens
a vertical page `TabView`: Now Playing, Calendar, Weather. Coral (`AccentColors.aiCoral`) for the Today
mark and the **Now**/**Next** marks; no violet or cyan; no plan letters in any rendered string. Every
string is localised (`LocalizedStringKey` / `String(localized:)`).

### Weather credit (decision 6)

The phone sends WeatherKit's service name and legal page URL (`WeatherAttributionStore`, or its
fallback — "Apple Weather" and Apple's legal page). The weather page draws the service name, a **Legal
attribution** link, and the sentence "Weather data sources are listed there and under My Day in
Avenkin on your iPhone", so the credit and where to find the sources are on the wrist even if the watch
cannot open the page. The watch does not draw the Apple Weather mark image: it fetches nothing, and
sending the image would be most of the budget. Owed: check the link on a real watch, and confirm with
App Review that the text credit is acceptable on watchOS (Apple's documentation is silent there).

## Decisions (taken as recommended; the owner can change any)

1. **The phone resolves, the watch draws.** No calendar, weather or location framework on the watch.
2. **Now Playing is the system's `NowPlayingView`.** Available from watchOS 7, so no deep-link
   fallback is needed.
3. **Refresh on every My Day change, on foreground (at most every 15 minutes) and just after midnight**,
   never in a way that can show a permission sheet; the watch shows a stated reason when the value is
   absent or for another day.
4. **"Today on Your Watch" on by default; times and counts only under any Medical Compliance mode;
   weather off under Local Only; WatchConnectivity only.**
5. **Three vertical pages behind a Today row**, Now Playing first.
6. **A text credit and the legal link on the weather page**, not the mark image.
7. **The watch follows My Day's source choices.** Calendar or weather off in My Day is off on the
   watch too, with that reason; it works whether or not the My Day card is placed on the phone's
   home screen.
8. **Cleared rows still show.** A row cleared from the My Day card is a card decision; the watch's
   calendar is a calendar and shows the item. (The card's dismissals never reach the sources either.)
9. **At most six items**, the rest counted; titles to 60 characters, places to the first line and 40.

## Phases

**P0 — Shared core (pure). ✅ Built 2026-11-07.** `WatchToday.swift` (payload, codec, freshness,
timeline, schedule) in both targets; `WatchTodayBuilder` and `WatchTodayHoldPolicy`;
`WatchApplicationContext.fold`. Tests: `WatchTodayPayloadTests` (round trip and size, over-budget drop
and count, refusal, unknown version, today / yesterday / the watch's own midnight, setting off, Now /
Next / ended, next midnight across a daylight-saving change, refresh due), `WatchTodayBuilderTests`
(order, today only, cap and count, both Medical Compliance modes with the bytes checked, shortening,
every calendar and weather status, units and rounding, symbol fallback, the credit only with weather,
the hold rule), two `MyDayServiceTests` cases (what a refresh gathered; a locked refresh gathers
nothing).

**P1 — Wiring, setting, watch pages. ✅ Built 2026-11-07.** `MyDayService.gathered`;
`WatchTodayPublisher` owned by `WatchConnectivityManager`; the fold in `WatchSurfacePublisher.push()`;
the setting; the watch's decode and `WatchTodayViews.swift`. Tests: `WatchTodayPublisherTests` (held
and pushed once per change, a locked look keeps the good one, Medical Compliance takes titles off at
the next build, the setting off, when it looks again, the fold, and `today` / `surfaces` / `job`
surviving each other's pushes over a fake session). The watch views have no test bundle; they compile
in the watch target.

**P2 — Device pass (owed).** The checks below, on a real watch paired to the owner's iPhone.

### Owed device checks (nothing below is verified)

1. **Now Playing** on the wrist controls music and podcasts playing on the iPhone (play, pause, skip,
   volume with the crown), and audio playing on the watch.
2. The **Legal attribution** link opens on a real watch; if it does not, the sentence beside it is the
   credit's only route, and App Review's view on that is owed.
3. The value arrives with the watch app closed (application context) and is current when it opens;
   time from a calendar change on the phone (foreground) to the wrist.
4. Just after midnight with the phone locked: the watch says to unlock; after unlocking and opening the
   app, today's value arrives.
5. Medical Compliance turned on with titles on the wrist: they leave within a couple of seconds.
6. A long day (more than six items, long titles and addresses) reads well on the smallest watch; Dynamic
   Type at the largest size.
7. Foreground refresh cost: one My Day refresh at most every 15 minutes (WeatherKit, travel time) does
   not show in battery or data use.

## Risks

- **A day that changes while the app is in the background** reaches the watch only at the next
  foreground or My Day refresh; the watch drops ended items itself, so the cost is a missed new item,
  not a wrong one.
- **The six-item cap is fixed at gathering.** After several items end, the watch shows fewer than six
  and the count until the phone looks again.
- **Foreground refreshes call My Day's sources**, including travel time; throttled to 15 minutes and
  only with a watch app installed and the setting on.

## Out of scope

Ticking lists, the live route, images (Plan GM P1b/P2), complications for Today, the watch fetching
anything itself (Plan CS), reminders on the wrist.
