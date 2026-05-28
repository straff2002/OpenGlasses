# Plan D — Small Utilities Bundle

**Source repo:** [SkyRadar](https://github.com/Trickdog/SkyRadar) (D1, D2) + [shopping list](https://github.com/kendy92/Meta-Rayban-Glass-Shopping-List) (D3, deferred)

**Strategic fit:** Three small, independently-useful additions. Low risk, fast to ship. Good warmup PR.

**Effort:** D1 + D2 in ~1 day total. D3 deferred.

---

## D1. `OneEuroFilter` Swift utility

**Files:**
- New: `Sources/Utils/OneEuroFilter.swift`

**API:**
```swift
struct OneEuroFilter {
    init(mincutoff: Double = 0.3, beta: Double = 0.5, dcutoff: Double = 1.0)
    mutating func filter(_ x: Double, t: TimeInterval) -> Double
    mutating func filterAngle(_ x: Double, t: TimeInterval) -> Double  // 0-360 wrap-safe
    mutating func reset()
}
```

**Algorithm (from SkyRadar):**
- Adaptive low-pass filter: `cutoff = mincutoff + beta * |velocity|`
- Reduces jitter when signal is stable, stays responsive when changing fast
- `filterAngle` handles 359°→1° wrap correctly via modular difference
- Maintains internal state: `x_prev`, `dx_prev`, `t_prev`

**Use sites (now and future):**
- CarPlay compass/heading smoothing
- Future AR overlays needing device orientation
- Any sensor stream with both noise and rapid motion

**Test:**
- Feed noisy sine wave + impulse step; verify smoothing curve
- Test angle wraparound (358 → 2)

---

## D2. `aircraft_overhead` NativeTool

**Files:**
- New: `Sources/Services/NativeTools/AircraftOverheadTool.swift`
- Touch: `NativeToolRegistry.init()` — register with `LocationService`
- Touch: `Sources/Services/LLMService.swift` system prompt — add tool description
- Touch: `Sources/Services/GeminiLive/GeminiLiveSessionManager.swift` system prompt — add tool description
- Touch: `project.pbxproj` — standard four-entry pattern

**API used:** `https://opendata.adsb.fi/api/v2/lat/{lat}/lon/{lon}/dist/{nm}` — free, no key, public ADS-B feed

**Tool spec:**
```
aircraft_overhead:
  args:
    radius_miles?: 1-200  // default 25
  returns: human-readable summary of N nearest planes
```

**Response format (returned to LLM):**
```
3 aircraft within 25 miles:
- DAL2417 (Boeing 737-800) — 12 mi NE, FL340, 450 kts, heading 273°, descending
- UAL891 (Airbus A321) — 18 mi SW, FL280, 480 kts, heading 095°, level
- N12345 (Cessna 172) — 8 mi N, 4500 ft, 110 kts, heading 180°, level
```

**Voice triggers:** "what's flying overhead?", "any planes nearby?", "what aircraft is above me?"

**Touches LocationService** to get current lat/lon. Uses imperial units by default (matches your other traveler tools).

---

## D3. `DPadNavigable` SwiftUI modifier — DEFERRED

**Source:** [shopping list useDpadNavigation.js](https://github.com/kendy92/Meta-Rayban-Glass-Shopping-List/blob/main/src/hooks/useDpadNavigation.js)

**Reason for deferral:** Only useful when targeting the Meta Display glasses 600×600 surface. Not relevant until Display-glasses hardware support is in scope.

**Bookmark:** When ready, port their hook to a SwiftUI `.dpadNavigable()` ViewModifier:
- Arrow keys cycle through `data-focusable="true"` equivalents (probably `.focusable()` + `.focused()`)
- Modulo wrap-around at list boundaries
- Enter/Space activates
- Escape callback
- Smooth scroll-into-view on focus change
- Skip handling when text field is focused

---

## Build order

1. **D1** — `OneEuroFilter.swift` + unit test (no dependencies, can land alone)
2. **D2** — `AircraftOverheadTool.swift` + LLMService/GeminiLive prompt updates + pbxproj entries

Both can ship in a single PR.

---

## Open questions

- **D2 retry/timeout:** ADSB.fi can occasionally lag. Default 5s timeout, retry once? Or fail fast and surface the error to the LLM?
- **D2 caching:** Cache results for ~10s to avoid spamming API if user asks twice quickly?
- **D2 unit display:** Always imperial, or honor a locale setting? *Recommendation: imperial — aviation is universally feet/knots/nm.*
- **D1 angle units:** Radians or degrees for `filterAngle`? *Recommendation: degrees, since iOS sensors deliver degrees.*

---

## Dependencies / prereqs

- D1: none
- D2: existing `LocationService` (already a NativeToolRegistry init param)
- D3: deferred — Display-glasses hardware target
