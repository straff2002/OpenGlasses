# Plan GP — Nearby Search with Opening Hours ("open now")

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Extends:** `find_nearby` (`NativeTools/LocationSearchTool.swift`).
**Related:** the First-Aid AED lookup (`Services/FirstAid/AEDFinder.swift`, the app's existing
Overpass client), `NetworkRouteRegistry` / `MedicalEgressGuard` (every new route is declared there),
Plan [GF](GF-recipe-add-ons.md) (not the route for this — see Decisions).

---

## Trigger

"Pharmacies near me that are open now" is a question an assistant is asked constantly, and the
useful answer is not a list of names but *which one is open, until when, and how far*. Today
`find_nearby` returns names, distances and addresses and says nothing about hours, so the model
either guesses or tells the wearer to check a map.

## Outcome

- "Is there a pharmacy open near me?" → "Two are open: the one on Queen Street, 300 m, open until
  9 pm, and one on Victoria Street, 700 m, open until 6. The closest, 150 m away, is closed until
  8 tomorrow."
- "When does the supermarket on Ponsonby Road close?" → hours for one named place.
- Honest when the data is thin: "I don't have hours for that one", and "hours may differ on public
  holidays" when the listed hours depend on holidays the app cannot know.
- The phone shows the same list with an Open / Closed / Unknown badge and the raw hours string.

## What exists today (verified 2026-10-01)

- `LocationSearchTool` (`find_nearby`): `MKLocalSearch` with a natural-language query in a 5 km
  region around `LocationService.currentLocation`; formats name, distance, address via
  `GeocodingHelper.locationAndAddress(from:)`. No hours, no open-now filter, no category.
- `AEDFinder` already queries **Overpass** (`https://overpass-api.de/api/interpreter?data=…`,
  `[out:json][timeout:10]`) through an injected `Fetcher`, with pure URL building and parsing, and
  calls `MedicalEgressGuard.check(.aedDirectory)` first. It sends no identifying `User-Agent`
  beyond URLSession's default. Its route `aedDirectory` is `.location` / `.publicWeb`.
- No `opening_hours` parsing anywhere in `OpenGlasses/Sources`.

### What MapKit exposes (checked against the iPhoneOS27.0 SDK in Xcode.app)

`MapKit.framework` headers and `MapKit.swiftmodule/arm64e-apple-ios.swiftinterface` were searched
for hours, open, operating and business terms. Findings:
- `MKMapItem`'s public properties are `identifier`, `alternateIdentifiers`, `location`, `address`,
  `addressRepresentations`, `name`, `phoneNumber`, `url`, **`timeZone`**, `pointOfInterestCategory`
  (plus the deprecated `placemark`). **There is no opening-hours or is-open property.**
- `MKLocalSearch.Request` has `naturalLanguageQuery`, `region`, `regionPriority`, `resultTypes`,
  `pointOfInterestFilter`, `addressFilter` — no open-now filter. `MKMapItemRequest` (with the iOS 26
  `GeoToolbox.PlaceDescriptor` initialiser) returns the same `MKMapItem`.
- `MKMapItemDetailViewController` / `MKSelectionAccessory` render Apple's place card (which shows
  hours on screen) but expose no data to the app.
- The only "operating hours" symbol in the SDK is in **AppIntents** (iOS 27): the `AppSchema`
  maps domain declares `operatingHours` / `operatingTimeRange` entity schemas. Those let an app
  *describe its own* entities to the system; they do not read Apple Maps data.
- The iOS 27 MapKit additions are new `MKPointOfInterestCategory` constants only.

Conclusion: MapKit gives us the places, the category and the place's time zone; hours must come
from elsewhere. OpenStreetMap's `opening_hours` tag is the open, well-specified source.

## Design

**Flow.** `find_nearby` keeps MapKit as the list of places (best names, addresses, relevance).
When the question is about hours (`open_now: true`, or a new `hours` action for one place), the tool
makes **one** Overpass request for the same area and category, matches OSM elements to MapKit items,
and evaluates each match's `opening_hours` at "now" in the place's time zone.

**`OSMCategoryMap`** (pure): `MKPointOfInterestCategory` → OSM tag filters (`.pharmacy` →
`amenity=pharmacy`; `.cafe` → `amenity=cafe`; `.foodMarket` → `shop=supermarket|convenience`;
`.gasStation` → `amenity=fuel`; `.bank`/`.atm`; `.bakery`; `.library`; `.postOffice`; …, ~30
rows). When MapKit gives no category, the query phrase is mapped by a small synonym table; when that
fails too, the Overpass query asks for named elements with an `opening_hours` tag and matching
relies on names.

**`OverpassHoursQuery`** (pure): builds `[out:json][timeout:10];nwr[<filters>]["opening_hours"]
(around:R,lat,lon);out tags center 60;` where R is the farthest MapKit result plus 150 m, capped at
3 km. **`OverpassHoursParser`** (pure) decodes elements (`tags.name`, `opening_hours`,
`check_date:opening_hours`, `center`/`lat`/`lon`).

**`PlaceMatcher`** (pure): pairs a MapKit item with an OSM element when distance ≤ 75 m and the
normalised names match (case, diacritics, punctuation, common suffixes like "Ltd", token-set
similarity ≥ 0.7), or distance ≤ 25 m with same category and one candidate. Unmatched items get
`unknown`, never a neighbour's hours.

**`OpeningHoursParser`** (pure) parses a supported subset of the OSM `opening_hours` grammar
(specification 0.7.x) into rules:
- Rule separators `;` (normal: replaces earlier rules for the days it covers) and `,` (additional:
  adds to them). `||` (fallback) is parsed in P1 only if cheap; otherwise the whole value is
  `unsupported`.
- Selectors in spec order: month and month-day (`Jan-Mar`, `Dec 24`, `Dec 24-26`), weekday ranges
  and lists (`Mo-Fr`, `Sa,Su`, `Mo-We,Fr`), `PH` and `SH`, time spans (`08:00-18:00`, several per day,
  over-midnight `22:00-02:00` and extended `18:00-26:00`), open end `18:00+`.
- `24/7`; modifiers `open`, `closed`/`off`, `unknown`; quoted comments kept as text.
- **Not supported in v1** (value becomes `unsupported`, raw string kept): `sunrise`/`sunset`/`dawn`/
  `dusk`, week numbers, `Su[1]`-style nth weekday, year ranges, `easter`, periods like `/2`.

**`OpeningHoursEvaluator`** (pure): `status(rules, at: Date, timeZone: TimeZone, holiday:
HolidayKnowledge) -> OpeningStatus` with `.open(until: Date?)`, `.closed(opensAt: Date?)`,
`.unknown(reason)` and `.unsupported`. The time zone is `MKMapItem.timeZone`, else the device's.
Yesterday's over-midnight span counts toward today. "Next change" searches up to 8 days ahead.
`HolidayKnowledge` is `.unknown` in v1: `PH`/`SH` rules are evaluated as "not a holiday" and the
status carries `holidayCaveat = true` whenever the value mentions `PH` or `SH`. Open end (`+`) gives
`.open(until: nil)` and "open from 6 pm, closing time not listed".

**Freshness.** A `check_date:opening_hours` older than two years adds "(hours last checked in
2022)". No `check_date` says nothing — most data has none.

**`OpeningHoursPhraser`** (pure): spoken one-liners in the wearer's locale and 12/24-hour setting —
"open until 9 pm", "open 24 hours", "closed, opens 8 am tomorrow", "closed today", "I don't have
hours for it", plus the single holiday hedge "hours may differ on public holidays" appended once per
answer, not per place. Ordering for open-now questions: open places first by distance, then closed
places that open soonest. The model receives the phrased lines plus a compact status per place, as
data. Copy never names a plan letter.

**Network.** New `NetworkRoute.openingHoursDirectory` (`.location`, `.publicWeb`,
`blockedWhenLocalOnly` like `aedDirectory`), owning type `OverpassHoursClient`, so
`NetworkRouteRegistryTests` and `PrivacyManifestReconciliationTests` stay green and Medical Local
Only refuses it with the standard message (MapKit results still come back, without hours).
`OverpassHoursClient`: injected fetcher, configurable endpoint `Config.overpassEndpoint` (https only,
validated), an identifying `User-Agent` (app name + version + contact URL), a 10 s timeout, one
request in flight, on HTTP 429/504 a 30 s back-off and a spoken "hours aren't available right
now". Responses cached per rounded area + category for 24 h (hours change rarely), a per-device daily
budget (default 50 requests) after which answers come without hours. `AEDFinder` adopts the same
endpoint setting and `User-Agent` in P2 (its emergency use stays exempt from the budget).

**Attribution.** Hours from OpenStreetMap are ODbL data: the phone list shows "Hours ©
OpenStreetMap contributors"; the About/Acknowledgements screen gains the line. Spoken answers do not
carry attribution.

**Modes.** Phone-only works identically (the answer is spoken on the phone; glasses optional).
HUD: the top three places with badges on `GlassesDisplayService` when a display is connected.
HIPAA: no special case beyond Medical Local Only above. Not agentic — no Agent Mode gate. CarPlay:
the spoken answer only.

## Phases (one PR each)

**P0 — Grammar and evaluator (pure).** `OpeningHoursParser`, `OpeningHoursEvaluator`,
`OpeningHoursPhraser`. Tests: `OpeningHoursParserTests`, `OpeningHoursEvaluatorTests`,
`OpeningHoursPhraserTests`. Test vectors (each evaluated at fixed instants in `Pacific/Auckland`,
`Europe/Berlin` and `America/New_York`, including a DST-change day):

| Value | At | Expect |
|---|---|---|
| `Mo-Fr 08:00-18:00; Sa 09:00-13:00` | Tue 17:30 | open until 18:00 |
| same | Sat 13:05 | closed, opens Mon 08:00 |
| `24/7` | any | open 24 h |
| `Mo-Su 22:00-02:00` | Wed 01:00 | open until 02:00 (Tuesday's span) |
| `Fr 18:00-26:00` | Sat 01:30 | open until 02:00 |
| `Mo-Fr 09:00-12:00,13:00-17:30` | Mon 12:30 | closed, opens 13:00 |
| `Mo-Sa 08:00-20:00; PH off` | Mon 10:00 | open until 20:00 + holiday caveat |
| `Mo-Fr 09:00-17:00; Dec 25 off` | Dec 25 (Wed) | closed today |
| `Mo-Fr 10:00-18:00, Sa 10:00-14:00` | Sat 11:00 | open until 14:00 |
| `Mo-Fr 09:00-17:00; We off` | Wed 10:00 | closed (normal rule replaces) |
| `Mo-Fr 18:00+` | Mon 19:00 | open, closing time not listed |
| `Mo-Fr 08:00-17:00 "by appointment"` | Mon 09:00 | open + comment kept |
| `sunrise-sunset` | any | unsupported |
| `Mo-Fr 08:00-` / garbage | any | unsupported, raw kept |

**P1 — Overpass enrichment.** `OSMCategoryMap`, `OverpassHoursQuery`, `OverpassHoursParser`,
`PlaceMatcher`, `OverpassHoursClient`, the route, `find_nearby` gains `open_now` and an `hours`
action (description rewritten so the model uses it for hours questions). Tests:
`OSMCategoryMapTests`, `OverpassHoursQueryTests` (exact query text, radius cap),
`OverpassHoursParserTests` (fixture JSON incl. ways with `center`), `PlaceMatcherTests` (neighbour
with different name never matched; chain branches 60 m apart), `OverpassHoursClientTests` (fake
fetcher: cache hit, 429 back-off, budget exhausted, Medical Local Only refusal),
`LocationSearchToolHoursTests` (MapKit seam faked), `NetworkRouteRegistryTests` update.

**P2 — Surfaces and settings.** Phone result card with badges and attribution; HUD list; endpoint
setting under Services (advanced) with a "test" button; `AEDFinder` on the shared endpoint and
`User-Agent`. Device checks (owed): real queries in a city centre and a small town, a late-night
over-midnight venue, a phone-locked question in a pocket (location and network from background).

## Risks

- **Coverage.** OSM hours are good for chains and city centres and patchy elsewhere; "I don't have
  hours" will be common in some regions. The answer must never imply closed when it means unknown.
- **Staleness.** Hours in OSM can be years old; the `check_date` note helps only where mappers set it.
- **Holidays.** The biggest source of wrong answers; hedged, not solved (see Decisions).
- **Public-instance policy** (next section) — the main operational risk.

## Decisions for Greig

1. **Overpass endpoint for a paid App Store app.** The OSM wiki's Overpass page asks commercial use
   to go to self-hosted or paid servers, asks apps to identify themselves with a `User-Agent` or
   `Referer`, and for regular application use suggests staying under roughly 100 queries and 10 MB
   a day (it is not explicit whether that is per client or per app); on 429/406, wait 30 s. Options:
   (a) public `overpass-api.de` with the budget, cache and `User-Agent` above; (b) a paid or
   self-hosted instance (possibly beside the FU base server) as the default, with the setting to
   override; (c) off by default until the wearer enters an endpoint. *Recommend (b) for release,
   (a) acceptable for TestFlight.* AED lookups already use (a) today.
2. **Holiday hedge scope.** Only when the value mentions `PH`/`SH` (recommended), or on every
   answer.
3. **Holiday calendars later?** A bundled public-holiday table per country would let `PH` evaluate
   properly; it is a maintenance burden. *Recommend not in this plan.*
4. **Not a GF recipe.** A recipe add-on could call Overpass, but the grammar evaluator is the whole
   value and must be native, tested code; recipes have no evaluation step. Keep it native.
5. **`sunrise`/`sunset` support** (a solar calculation) in P1 or later. *Recommend later.*

## Out of scope

Holiday calendars, busy-times/popularity, reservations, editing OSM data, OSM-only place lists when
MapKit finds nothing (possible follow-up), and hours for places saved in `save_location`.
