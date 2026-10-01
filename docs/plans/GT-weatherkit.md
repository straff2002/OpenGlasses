# Plan GT — Weather from WeatherKit

**Status:** ✅ Shipped 2026-10-01 — P0–P2 in one PR: the WeatherKit entitlement (spec, committed
and personal-example entitlements, setup-script patch, generate-time warning); the pure core
(`WeatherReport`, `WeatherUnits`, `WeatherConditionPhrase`, `RainOutlook`, `WeatherAlertDigest`,
`WeatherPhraser`, `WeatherLocationPrecision`); `WeatherKitProvider`; `get_weather` and My Day's
weather on the provider seam; the Apple Weather mark and legal link in My Day, chat and Settings →
Works with your iPhone → About Weather Data; Open-Meteo removed from the app, the privacy manifest
and the privacy page; 52 headless tests. Decisions taken as listed below. **Owed (P3, device):** a
signed build answers weather now the capability and App Service are live (expect refusals for a
while after activation); a minute-forecast region and one without; an active alert; US units and a
Fahrenheit override; the mark in light and dark mode and the Legal link; airplane mode.

**As built — where the code differs from the draft below:**
- The test classes are grouped: `WeatherUnitsTests`, `RainOutlookTests`, `WeatherAlertDigestTests`
  and `WeatherPhraserTests` (coarsening, intensity conversion and failure sentences included) live
  in `WeatherCoreTests.swift`; the "no Open-Meteo" checks and the route check are part of
  `WeatherKitEntitlementGuardTests` rather than a separate `NoOpenMeteoGuardTests`.
- A rain change must hold for 3 minutes; "about N minutes" is rounded to 5 from 10 minutes up.
- Today's line adds "N% chance of precipitation" from 30 %; the third day is named by weekday.
- `WeatherTool.lookUp(args:)` is My Day's entry point and does not record a chat thread;
  `execute` does, through `onAnswered`. My Day under Medical Local Only now shows "Weather is off
  while Medical Local Only is on." — before, the refusal sentence was displayed as the forecast.
- The attribution and the mark are not fetched under Medical Local Only; the fallback credit (the
  service name as text and Apple's legal page) is drawn instead.
- `privacy.html`'s effective date moves to 1 October 2026.
**Replaces:** the Open-Meteo client inside `get_weather` (`NativeTools/WeatherTool.swift`).
**Related:** Plan [GS](GS-spotify-control.md) (the rule that a system framework making its own
request gets no `NetworkRoute`), Plan [GI](GI-health-summaries.md) (how a new entitlement is added
to the spec, the committed and personal entitlements, and the setup script), My Day
(`Services/MyDay/`), Plan [GF](GF-recipe-add-ons.md) (flagged the Open-Meteo terms problem for
add-ons).

---

## Trigger

`get_weather` calls the free Open-Meteo API. Its terms say the free API may only be used for
non-commercial purposes and count apps that have subscriptions as commercial. Avenkin is a paid app
with subscription tiers, so the current weather source breaks those terms. WeatherKit is included
with the Apple Developer Program (500,000 calls a month), and the WeatherKit capability and App
Service were enabled on the App ID `com.openglasses.app` on 2026-10-01.

## Outcome

- Every weather answer comes from WeatherKit. Open-Meteo is gone from the app, the privacy
  manifest and the public privacy page. There is no fallback to it.
- The same answers as today — current conditions, today's high and low, a 3-day outlook — plus two
  new ones:
  - **Rain in the next hour**, from WeatherKit's minute forecast: "Rain starting in about 15
    minutes", "Rain stopping in about 20 minutes", "No rain expected in the next hour". Where the
    region has no minute forecast, nothing is said about it.
  - **Active severe-weather alerts**: the alert's summary and the agency that issued it.
- Units follow the phone's region and temperature setting.
- If WeatherKit fails (not activated yet, no network, a denied request), the answer is one sentence
  saying so.
- Apple's attribution — the Apple Weather mark and a link to the legal attribution page — is shown
  wherever weather data is displayed on a screen, and in Settings. Spoken answers carry no credit.

## What exists today (verified by grep, 2026-10-01)

- **`NativeTools/WeatherTool.swift`** (`get_weather`): parameters `latitude`, `longitude` and
  `location` (a label only — a named place is never looked up, so "weather in Paris" answers for
  the wearer's own position unless the model supplies coordinates). Guards
  `MedicalEgressGuard.allows(.weatherLookup)`, awaits a location fix (2 s), builds an
  `api.open-meteo.com` URL, parses JSON by hand, maps WMO codes, and picks °F/mph only when the
  region is exactly `US`. Reverse-geocodes the coordinates for "in Wellington".
- **My Day**: `NativeWeatherDaySource` (`MyDay/MyDaySources.swift`) runs `WeatherTool.execute` and
  string-matches the sentence twice — `looksUnavailable` (error phrases) and `isDecisionRelevant`
  (rain/snow/storm words). `MyDayComposer` turns it into a "Weather" item whose detail is the whole
  sentence, shown in `MyDayView` and in the home card (`MyDayHomeView`). Settings → Works with your
  iPhone → "Included in My Day" has a Weather toggle (`myDayWeatherIncluded`).
- **`Security/NetworkRouteRegistry.swift`**: `.weatherLookup` (`[.location]`, `.publicWeb`,
  blocked under Medical Local Only, owned by `WeatherTool` because it holds a `URLSession`).
  `NetworkRouteRegistryTests` scrapes the sources for `URLSession` owners.
- **Other consumers:** `ConversationClassifier` routes a bare "weather" question straight to
  `get_weather` and pre-fetches it for weather-decision turns on the on-device model
  (`OpenGlassesApp` → `LLMService.leanOnDevicePrompt(weatherContext:)`); `DailyBriefingTool` reads
  My Day; `FieldToolProfile`, `Config.internetRequiringTools`, `ToolsSettingsView` name the tool;
  `OpenAppTool` opens the system Weather app (`weather://`), unaffected.
- **Privacy:** `PrivacyInfo.xcprivacy` names open-meteo in its header note and in the Precise
  Location comment; `privacy.html` names Open-Meteo in the look-ups row and links its terms.
  No in-app Swift copy names Open-Meteo. Onboarding's Location row says "For weather, nearby
  places, and context".
- **Entitlements:** no `com.apple.developer.weatherkit` in `project.base.yml`, the committed
  `OpenGlasses/OpenGlasses.entitlements` or `Config/Entitlements/Personal/OpenGlasses.entitlements.example`.
  Plan GI's HealthKit pattern is the model: spec key, both entitlements files,
  `setup-local-dev.sh`'s `ensure_personal_capabilities`, a warning in `generate-xcodeproj.sh`, and
  `HealthEntitlementGuardTests`.
- **Tests that touch it:** `MedicalEgressCanaryTests` (WeatherTool refuses under Local Only),
  `MyDayP4Tests` (`looksUnavailable`), `MyDayServiceTests` / `MyDayComposerTests` (fake sources).

## Design

**Provider seam.** `WeatherProviding` (`report(for: CLLocation) async throws -> WeatherReport`).
The live `WeatherKitProvider` makes one `WeatherService.shared.weather(for:including: .current,
.daily, .minute, .alerts)` call and maps the result into `WeatherReport`, a plain value type
(WeatherKit's structs have no public initialisers, so tests could not build them). Shapes checked
against the iOS 27 SDK `.swiftinterface`: `minute` is `Forecast<MinuteWeather>?` (nil where the
region has no minute forecast), `alerts` is `[WeatherAlert]?`, `attribution` is `get async throws`,
`MinuteWeather.precipitationIntensity` is a `Measurement<UnitSpeed>`.

**Pure core.**
- `WeatherUnits.forLocale(_:)`: `UnitTemperature(forLocale:usage: .weather)` and
  `UnitSpeed(forLocale:usage: .wind)`, so the phone's region *and* its temperature setting decide.
- `WeatherConditionPhrase`: WeatherKit condition → short lowercase phrase, plus whether it is a
  decision-relevant condition (rain, snow, storms, fog, wind, extreme heat or cold).
- `RainOutlook.evaluate(minutes:now:)`: `.unknown` when there is no minute forecast; otherwise
  `.dryForTheHour`, `.starting(inMinutes:kind:)`, `.stopping(inMinutes:kind:)` or
  `.continuing(kind:)`. A minute is wet at ≥ 50 % chance and ≥ 0.1 mm/h; a change must hold for
  3 minutes so a single wet minute does not become "rain starting".
- `WeatherAlertDigest`: active alerts sorted by severity, at most two spoken ("… and 1 more"),
  each "summary, from source"; expired or duplicate alerts dropped.
- `WeatherPhraser`: the tool's sentence(s) — current, today's high/low, rain in the next hour,
  alerts, tomorrow and the day after; `isDecisionRelevant(report:)` for My Day, from the data
  rather than by searching words in a sentence.
- `WeatherLocationPrecision.coarsen`: coordinates rounded to 2 decimal places (about 1 km) before
  they leave the phone — enough for a minute forecast, less than a GPS fix.

**Tool.** `get_weather` keeps its name and parameters. A named `location` without coordinates is
now geocoded on the phone (`GeocodingHelper.geocodeAddress`, Apple's geocoder), so "weather in
Paris" means Paris. Failures map to one sentence each (`WeatherFetchFailure`): WeatherKit not
available to this build, no network, no location.

**My Day** reads `WeatherReport` through the provider directly (no more matching error strings in
a sentence), with the same sentence as the detail and decision relevance from the data.

**Attribution.** `WeatherAttributionStore` fetches `WeatherService.shared.attribution` once and
caches it; `WeatherAttributionMarkLoader` downloads the light and dark combined marks off the main
thread and keeps them in memory. `WeatherAttributionView` shows the mark (or the service name as
text until it loads) and a "Legal" link to `legalPageURL` (Apple's legal attribution page if the
attribution itself cannot be fetched). Shown:
- under the weather row in `MyDayView` and in the home card wherever the weather detail is drawn;
- at the foot of a chat thread in which `get_weather` answered (`WeatherAttributionThreads`
  records the thread ids, bounded);
- in Settings → Works with your iPhone → "About Weather Data".

**Privacy.**
- Coordinates (coarsened) go to Apple through WeatherKit instead of Open-Meteo. The request is the
  framework's own, so — following GS — there is no `NetworkRoute` for it; `.weatherLookup` is
  removed. The attribution-mark download is Avenkin's own `URLSession` request to Apple's asset
  host and gets its own route (`.weatherAttributionMark`, content-free).
- **Medical Local Only** blocks weather, as before: location leaving the phone is exactly what the
  mode forbids, and every other location look-up (aircraft, defibrillators) is blocked too. The
  check moves into `WeatherTool` / the My Day source as an injected closure over
  `MedicalEgressGuard.currentMode()`, the same shape GS used for MusicKit.
- `PrivacyInfo.xcprivacy`: header and Precise Location comment name WeatherKit; no data type
  changes (Precise Location is still declared, still app functionality, not linked).
- `privacy.html`: weather moves to the Apple row; Open-Meteo is removed from the look-ups row and
  the provider list.
- No new SDK (WeatherKit is a system framework), so no telemetry review.

## Phases

**P0 — Entitlement.** `com.apple.developer.weatherkit: true` in `project.base.yml`, the committed
entitlements and the personal example; `ensure_personal_capabilities` adds it to an existing
personal copy; `generate-xcodeproj.sh` warns when it is missing. Tests:
`WeatherKitEntitlementGuardTests`.

**P1 — Pure core.** Units, condition phrases, rain outlook, alert digest, phraser, coordinate
coarsening. Tests: `WeatherUnitsTests`, `RainOutlookTests`, `WeatherAlertDigestTests`,
`WeatherPhraserTests`, `WeatherLocationPrecisionTests`.

**P2 — Provider, tool, My Day, attribution, privacy.** `WeatherKitProvider`, `WeatherTool` on the
seam, `NativeWeatherDaySource` on the provider, attribution store/loader/view in My Day, chat and
Settings, the route change, manifest and privacy page. Open-Meteo removed. Tests:
`WeatherToolTests` (fake provider: each sentence, named place geocoded, provider failure is one
sentence, Local Only refuses before the provider is asked, thread recorded for attribution),
`WeatherAttributionThreadsTests`, `NativeWeatherDaySourceTests`, `NoOpenMeteoGuardTests`
(no source, manifest or privacy-page mention; no `open-meteo.com` host anywhere in the app).

**P3 — Device checks (owed).** A signed build answers weather (the capability and App Service are
live); the minute forecast in a region that has it (e.g. the US, UK, Ireland, Japan, Australia)
and silence in one that does not; an active alert; °F and mph on a US-region phone, °C with a
Fahrenheit temperature override; the mark in light and dark mode; the Legal link opens; airplane
mode gives the one-sentence failure.

## Risks

- **Activation lag.** WeatherKit can refuse requests for a while after the capability is enabled
  (`WeatherError.permissionDenied` / an authentication failure). The failure sentence covers it;
  the device check confirms it clears.
- **Minute-forecast coverage** is regional; the outlook is `.unknown` and silent elsewhere, never
  "no rain".
- **Attribution on the glasses display.** The display mirrors spoken sentences; there is no room
  for a mark. Treated like voice: spoken answers need no credit. If App Review disagrees, the
  mirror can drop weather sentences.
- **Quota.** 500,000 calls a month. My Day refreshes on foreground and calendar change; one call per
  refresh with weather on. Well inside the quota at current scale; no caching layer added.

## Decisions

1. **No Open-Meteo fallback** (brief): WeatherKit is the only source; a failure is said, not hidden.
2. **No `NetworkRoute` for WeatherKit itself** (GS rule); `.weatherLookup` removed. The mark
   download gets `.weatherAttributionMark` because Avenkin owns that transport.
3. **Medical Local Only blocks weather** (unchanged behaviour, same rule as the other location
   look-ups).
4. **Coordinates coarsened to ~1 km** before sending (new; no answer needs more).
5. **Named places are geocoded on the phone** (new; the old tool silently answered for the
   wearer's own position).
6. **Chat threads get the attribution footer** when weather answered in them; spoken answers and
   the glasses display do not.

## Out of scope

Hourly forecasts beyond what the sentence needs, historical statistics, weather notifications or
background alerts, a weather screen of its own, air quality / pollen (WeatherKit does not offer
them on iOS), and any other weather provider.
