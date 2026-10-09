# Plan IB: Paged HUD Answers (a long reply turns pages instead of stopping at 120 characters)

**Status:** 📝 Drafted 2026-10-10. Nothing built. P0 is the pure pager and the stale-frame rule; P1
wires it into `GlassesDisplayService` and the input paths; P2 is a device pass on both display
backends.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 3 row "HUD
answers cut at 120 characters", section 4 row "Paged HUD answers"; Appendix B claim 7).
**Priority:** Every long answer shown on a display is silently cut today, on the Meta Display and on
Even G2 alike. The wearer sees a fragment with no sign there was more.
**Surfaces:** `HUDTextShaper`, `GlassesDisplayService`'s present path and render queue, the HUD
input routing (band, temple taps, voice, the web mirror's keys). No new dependency; both backends
keep receiving ordinary `HUDContent`.

Evidence under `OpenGlasses/Sources/`; line numbers as recorded by the review at `7a0cc0e0`,
re-read on `main` at `48bcae0c`.

---

## Why

- `HUDTextShaper.maxBodyLength` is 120 (`Services/Display/HUDScreen.swift:24`), and
  `GlassesDisplayService.present` condenses every body to it (`Services/GlassesDisplayService.swift:231`),
  collapsing newlines first. `condense` truncates; nothing records that text was dropped.
- `TeleprompterPaginator` (`Services/Teleprompter/TeleprompterPaginator.swift:16`) already windows
  text into HUD-sized pages with per-backend geometry (`raybanDisplay` 4 lines × 32 characters,
  `evenG2` 3 × 40), "paginate, don't scroll", and is used only by the teleprompter.
- The render queue has no notion of which frame is current. A delayed page turn, arriving after a
  notification or a new answer has been shown, would overwrite the newer frame.

## Scope

**In:** answers (the assistant's reply mirrored to the HUD) and long notifications split into pages
with a "1/3" footer; page turns by band, temple tap, voice and the mirror's arrow keys; a revision
token that makes a stale page turn a no-op; spoken answers unchanged.

**Non-goals:**
- Interactive screens (Plan X/Y). They own their own layouts and keep them.
- Navigation and hazard lines. They are short by construction and must never page: a hazard that
  needs a second page is a hazard rewritten, not paged. `showNavigation` keeps the cap.
- Auto-advancing pages in time with speech. Possible later with HZ's sentence boundaries; not here.
- A scroll gesture. The HUD model is paged, as the teleprompter's is.

## Design

### 1 · `HUDAnswerPager` (pure)

```swift
struct HUDAnswerPage: Equatable { let body: String; let index: Int; let count: Int }
enum HUDAnswerPager {
    static func pages(for text: String, geometry: TeleprompterPaginator.Geometry,
                      maxPages: Int = 8) -> [HUDAnswerPage]
}
```

Builds a `TeleprompterScript` from the answer and walks `TeleprompterPaginator.window` across it,
one window per page, so line wrapping and blank-line handling are the teleprompter's. Rules:
- a page break never splits a word, and prefers a sentence end in the last line of a page;
- one footer line is reserved on each page of a multi-page answer ("1/3"); a single page has no
  footer and looks exactly as today;
- past `maxPages` the last page ends "… more on phone" and the phone transcript holds the rest;
- geometry comes from the active backend (`raybanDisplay` or `evenG2`), so Even G2 pages are
  shaped for its own panel; P4 of Plan [DS](DS-even-g2-link-hardening.md) (measured text fit) can
  later replace the character budget without changing this type.

`HUDTextShaper.condense` keeps the cap for titles and for callers that are not answers.

### 2 · `frameRevision` and stale page turns

`GlassesDisplayService` gains `frameRevision: UInt64`, bumped by **every** render it enqueues (an
ambient op, a screen, a clear, a page). The paged answer it is showing records the revision of its
current page. A page turn carries the revision it was issued against; on the render queue, a turn
whose revision is not the current one is dropped and logged (`hudPageTurnStale`). So a notification
that arrives between "next" and the page render wins, and the answer's pages are abandoned rather
than resurrected over it. A pure `PageTurnGate.accept(turnRevision:currentRevision:)` holds the
rule.

### 3 · Input mapping

Page turns reuse existing input, only while a paged answer is the current frame:

| Input | Next | Previous | Leave |
|---|---|---|---|
| Neural Band (Meta Display, via `HUDRouter`) | swipe forward | swipe back | pinch-hold |
| Temple tap (configured in `TempleTapSettingsView`) | single tap, when bound to "page" | double tap | none |
| Voice (`HUDVoiceCommand`) | "next", "next page" | "back", "previous" | "close", "clear" |
| Web mirror (Plan BP) | right arrow | left arrow | Escape |
| Even G2 temple gesture (when AH's gesture mapping is confirmed) | forward | back | none |

The voice words are taken only while a paged answer is showing and only as whole short
utterances, as `HUDVoiceCommand` does for its other commands, so "next" in an ordinary sentence is
never swallowed. `HUDVoiceCommand` already maps "next" to `.complete` for a Now/Next task card;
the paging words are a separate parse that `HUDRouter` consults only when the current frame is a
paged answer, so "next" keeps meaning "step done" on a task card.

### 4 · Lifetime

A paged answer stays until the wearer leaves it, a new answer replaces it, or 60 s pass without a
page turn (then it clears like any persistent frame). Paging state is in memory only.

## Phases

- **P0 (one PR):** `HUDAnswerPager`, `HUDAnswerPage`, `PageTurnGate`. **Tests:**
  `HUDAnswerPagerTests` (one-page answer has no footer and equals today's text; a 400-character
  answer pages for both geometries; no split words; sentence-end preference; the eight-page cap and
  its "more on phone" line; blank lines), `PageTurnGateTests`.
- **P1 (one PR):** `frameRevision` in `GlassesDisplayService`; answers routed through the pager;
  the input table wired; the 60 s clear. **Tests:** `HUDInteractionTests` additions (next and
  previous move pages; a notification between issue and render makes the turn stale; navigation
  lines never page; an interactive screen is unaffected), `WebHUDMirrorTests` (the mirror shows the
  footer and arrow keys turn pages), `HUDPreviewSnapshotTests` for one paged frame per backend.
- **P2 (owed):** read three long answers on a Meta Display and on Even G2 hardware; turn pages by
  band, voice and temple tap; confirm a stale turn never overwrites a newer notification.

**Gates:** full suite and Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`; index row and this
Status line updated in each PR.

## Open questions

1. Footer wording: "1/3" (recommended, language-neutral) or "Page 1 of 3"?
2. Should a paged answer start on page 1 even when the reply is still being spoken? Recommended:
   yes; speech-synced paging waits for Plan [HZ](HZ-direct-mode-sentence-streamed-speech.md).
3. Eight pages as the cap, or fewer? Glanceable text argues for fewer; P2 decides.

## Dependencies

- **AG** (✅ teleprompter): `TeleprompterPaginator`.
- **AH** (✅ steps 1 to 4, BLE dark) and **DS**: the Even backend and its future text fit.
- **X** / **Y** (✅): `HUDRouter` and the band input.
- **BP** (✅ P1 and P2): the mirror input row.
- **IA**: long choice lists page here once this lands.
