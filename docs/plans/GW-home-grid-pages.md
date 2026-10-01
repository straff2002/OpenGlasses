# Plan GW — Home Grid Pages, Editor Behind the Cog, My Day Removable

**Status:** ✅ Shipped 2026-10-02 — P0 + P1 in one PR: `HomeGridPaging` (rows that fit, one order
across pages, page/slot mapping, dots, keep-first-visible-tile on reflow), `HomeGridTilePresence`
(gates applied before paging), the anchored `DockPagerState`, the editor as a sheet behind the cog
(and the long press), `MyDayHomePlacement` + `myDayOnHome` with the card's "Remove from Home",
Settings' "Show on Home Screen" and the editor's Cards section; plus the session card's
wake-word-off line (below). **Owed (P2, device):** swipe feel, rows at Large and AX sizes with My
Day open, collapsed and removed.

**As built — where the code differs from the draft below:**
- The first grid page records no anchor (`nil`), so it stays the first page whatever is put in
  front of its first tile; later pages record their first tile.
- The view's tile gates moved into a pure `HomeGridTilePresence`, and the on-device model key is
  its own `HomeGridTile.localModel` in front of Model — a paged grid has to know exactly which
  tiles each page holds.
- **Small extra — the wake word off, said on the card.** The master "Listen for Wake Phrase" switch
  (`listeningEnabled`) can be turned off from the Lock Screen Live Activity, Control Center, the
  widget, the Action Button or Siri, and the session card kept saying "Ready". The card now shows
  "Wake word off — tap to turn on" under its status row when the switch is off and push-to-talk
  (`silentMode`) is not the wearer's choice; tapping it calls `setListeningEnabled(true)`. The rule
  is `SessionCardWakeWordNotice` beside the card's other presentation types; there is no separate
  push-to-talk-only setting beyond `silentMode`.
- **Compressible tiles (review round).** The first cut counted rows in natural tiles, and with My
  Day open a page held one row over most of a row of empty glass. Rows are now counted in
  *minimum* tiles — the measured glyph and caption at the current text size with 6 pt of padding
  (`HomeGridPaging.minimumTileHeight`) — and every tile on the page then stretches to share it,
  capped at 1.25 × its natural height (`HomeGridPaging.fit`). The grid measures each tile's
  *content*, not the key, so the page's choice of height never feeds back into the measurement.
- Screenshots on the simulator (iPhone 17 Pro, default text size): seeded My Day open — two rows
  of three, four dots; My Day collapsed to its one-line header — four rows, three dots, filling the
  panel. (The first cut showed one row with My Day open and four with it removed; at XXXL the same
  shape, captions truncating as in #601; at AX-L one column.)
- **Small extra — the Lock Screen Live Activity fits its slot.** Its 2 × 2 grid of capsules lost
  its bottom row to the Lock Screen's height limit on a phone. It is one row now: up to four
  buttons, a glyph over a one-line caption (beside it for one or two), Connect taking a place in
  the row when disconnected, the status text one line, and the presentation's text size capped at
  xLarge. `LockScreenActivityLayout` (shared with the widget) holds the plan and the height
  budget, tested to leave at least 12 pt of the 160 pt slot at xLarge. Simulator Lock Screen:
  Connect (filled accent), Describe, Record, Translate Sign in one row under the header.
- **Small extra — the talk capsule is one VoiceOver element.** `ActionCapsule` uses an
  accessibility representation; the ignore-children wrapper had left the `Button` beneath it
  named by its drawn copy.

**Related:** PR #601 (three glass keys across, the cog on the dots row), `DockPagerPolicy` (the
auto-flip and its "a finger is never overruled" promise), `DockGridMetrics` (the panel's measured
height), Plan [GT](GT-weatherkit.md) (My Day's weather source), the My Day services under
`Sources/Services/MyDay/`.

---

## Trigger

Greig, after living with #601's home grid:

1. The layout editor is a page of the dock's pager, so a swipe onward from the grid lands in it by
   accident. The cog is the way in; a swipe should never be.
2. The grid scrolls vertically inside a panel that already pages horizontally — two scroll axes in
   one glass. It should page like a home screen: three across, a whole page per swipe, as many rows
   per page as the room under the cards allows.
3. My Day cannot be taken off the home screen. With it off in Settings the home still shows its
   set-up card, so "off" still costs the surface a card.

## What exists today (verified 2026-10-02, main at dde9b2bc)

- `BottomControlBar.panel` is a paging `TabView` over `DockPage` — `.conversation`, `.actions`,
  `.edit` — with the dots shown and a `cornerButton` (cog on the grid, ✓ on the editor) overlaid on
  the dots row. A long press on the grid's gaps also moves to `.edit`.
- The grid page is one vertical `ScrollView` + `LazyVGrid`; its viewport snaps to whole rows
  (`DockGridMetrics.viewportRows`) and the panel's remainder sits under it as empty glass.
- Some slots draw nothing in some states (Preview without glasses, Type without the chat binding,
  Assistive when the mode is off, Disconnect when not connected) and the Model slot can draw two
  tiles (the on-device model tile rides in front of it). The grid tolerated that because it simply
  flowed; a paged grid cannot — a page has to know exactly which tiles it holds.
- `DockPagerPolicy.advance` flips to `.conversation` on the turn starting and on the reply
  arriving, unless the user moved the pager during that turn.
- `VoiceTab` shows `MyDayHomeView` whenever `HomeSurfaceVisibility.showsMyDay(state:captions:)`;
  `MyDayHomeView` draws a set-up card when `myDayEnabled` is false.
- `myDayEnabled` gates more than the card: `MyDayDeliveryPolicy` (the scheduled morning and evening
  briefings, spoken or not), the `daily_briefing` tool, and `ProactiveAlertService`'s leave-by
  travel alerts.
- The panel's height is `availableHeight − heightAboveDock − dock chrome`, where `heightAboveDock`
  is the measured sum of everything above the dock. Removing a card shrinks that sum, and the panel
  grows on the same frame.

## Outcome

- **A1.** The editor opens only from the cog on the dots row (and the long press on the grid's
  gaps, which goes to the same place). No swipe reaches it. It is a sheet with its own Done, so it
  also gets the room it needs at every panel height — the panel can now be one row tall.
- **A3.** The grid is three keys across (one at accessibility text sizes, as today) and pages
  horizontally: conversation, grid page 1, grid page 2, … — one whole page per swipe, snapping.
  Rows per page are 1–4, as many as fit the room under the cards at the measured tile height, so
  larger text means fewer rows. Tiles flow in the one arranged order across the pages. The dots
  count the conversation and every grid page.
- **A2.** With My Day off, nothing of it is on the home screen. With it on, the card can be removed
  from the home screen from its own context menu and brought back from Settings or the editor.

## Design

### The paging maths — `HomeGridPaging` (pure, `Sources/Models/HomeGridPaging.swift`)

One value built from `tileCount`, `columns` and `rows`, plus the static fitting rule:

| API | Meaning |
|---|---|
| `static rowsThatFit(height:rowHeight:)` | `1...maxRows` (4): whole rows (tile + gap) in the page body; never 0 |
| `static naturalTileHeight(contentHeight:)`, `minimumTileHeight(contentHeight:)`, `fit(height:minimumTileHeight:naturalTileHeight:)` | the tile's padded and squeezed heights, and the rows + stretched tile height a page is drawn at |
| `tilesPerPage` | `rows × columns` |
| `pageCount` | `⌈tileCount / tilesPerPage⌉`, at least 1 (an empty grid still has its page) |
| `page(ofTile:)`, `position(ofTile:)` | page, row, column of tile *i* — order is row-major, no gaps |
| `tileRange(onPage:)` | the contiguous slice of the one order a page holds |
| `conversationIndex` (0), `panelIndex(forGridPage:)`, `gridPage(forPanelIndex:)` | the pager's indices: conversation first, then the grid pages |
| `dotCount` | `1 + pageCount` |
| `gridPage(anchoredAt:in:fallback:)` | the page holding the anchor tile; a vanished anchor falls back to the clamped page |
| `anchor(forGridPage:in:)`, `panelIndex(for:tileIDs:)` | the anchor a move to a page records (`nil` for page 1), and the pager index a state shows |

### Where the pager is — `DockPagerState`

`DockPage` loses `.edit` and keeps `.conversation` / `.actions`. The state gains `gridAnchor`: the id
of the **first tile on the grid page the user last chose**. The panel index is *derived* every
render — `0` on the conversation, otherwise `1 + page containing the anchor` under today's paging —
so a reflow needs no handler: when My Day expands and the rows drop from 4 to 2, the anchor's page
is recomputed and the panel lands on the page that still shows the tile that was first on screen.
The anchor is written only by a user's move (swipe, dots, named action), never by a reflow, so
toggling a card back and forth returns to the same page rather than drifting.

**Auto-flip and the grid pages (decision).** `advance` still only ever moves to the conversation
and keeps `gridAnchor`. Coming back:
- a **swipe** onward from the conversation lands on grid page 1 — the pages are a line and the
  conversation sits before page 1, so that is the only page one swipe can reach;
- the **"Show actions"** named action returns to the remembered page (the anchor's), so a VoiceOver
  user is not walked back through every page to find the tile they used.

### A1 — the editor behind the cog

- The editor is presented with `.sheet` from `BottomControlBar` (a `NavigationStack` titled "Edit
  Home Screen", Done in the toolbar, medium and large detents). It is no longer a `TabView` page, so
  no swipe can reach it.
- The cog stays on the dots row of every grid page (not the conversation, as today). The ✓ on the
  dots row goes; the sheet's Done is the way out.
- **Long press on the grid's gaps (decision): kept**, and it opens the same sheet. It never fires
  with a tile (it rides the page background) and it costs nothing; removing it would take a working
  shortcut away from people who found it.
- VoiceOver: the panel's named actions are "Show conversation", "Show actions", "Next page of
  actions" / "Previous page of actions" (when there is one), and "Edit home screen".

### A3 — a paged grid

- The view resolves the **visible tile list** before paging: a slot whose contextual gate is closed
  is dropped, and the on-device model tile is its own tile in front of Model. Paging then sees
  exactly the tiles it draws, so a page never has a hole and no tile is skipped or duplicated.
- Each grid page draws its slice as explicit rows of `columns` cells (empty cells in a short last
  row keep the column widths), inside one `GlassEffectContainer`, top-aligned, with the panel's
  remainder under it as calm glass — the whole-row rule now lives in `rowsThatFit`.
- **Row-fit rule (decision, revised in review).** `rows = clamp(⌊(bodyHeight + gap) / (minTile +
  gap)⌋, 1, 4)`, where `bodyHeight` is the page's height above the dots and `minTile` is the
  measured content with 6 pt of padding (at least 44 pt); the tiles then stretch to `(bodyHeight −
  (rows − 1) · gap) / rows`, capped at 1.25 × natural. Dynamic Type grows the content, so it fits
  fewer rows — squeezing only ever takes padding. Columns stay 3, or 1 at accessibility sizes (a three-across
  caption is cut to a letter there — #601's rule).
- The editor edits the single order (`homeGridArrangement`), so moving a tile never depends on the
  screen's height.

### A2 — My Day off the home screen

- **Flag (decision): a separate placement flag, `myDayOnHome` (default `true`).** `myDayEnabled`
  also drives the scheduled briefings, the `daily_briefing` tool and the leave-by alerts; removing
  a card from the home screen should not silently stop a morning briefing. The card shows only when
  `myDayEnabled && myDayOnHome` (`MyDayHomePlacement.isShown`).
- One source of truth per fact. Settings' "My Day" switch is `myDayEnabled`; a new "Show on Home
  Screen" switch under it is `myDayOnHome`; the card's "Remove from Home" writes `myDayOnHome =
  false`; the editor's "My Day" switch reads `isShown` and turning it on writes both (a fresh
  opt-in, recorded as before). All four read the same `UserDefaults` keys through `@AppStorage`, so
  they cannot disagree.
- The set-up card goes. With My Day off the home screen draws nothing for it; it is turned on from
  Settings or from the editor's Home Screen section.
- Removal animates with the surface's one settle curve, the measured height above the dock shrinks,
  the panel grows on the same frame, and the rows per page recompute from it.

## Phases

- **P0 — pure core.** `HomeGridPaging`, the anchored `DockPagerState`, `MyDayHomePlacement`, the
  widened `HomeSurfaceVisibility.showsMyDay`. Tests: row fit (heights, Dynamic Type sizes, floor
  and ceiling), one order across pages with nothing skipped or duplicated, page/slot mapping, dot
  count, reflow keeps the first visible tile, auto-flip keeps the anchor, a swipe overrules nothing,
  placement truth table.
- **P1 — views.** Editor sheet + cog + long press; paged grid; My Day context menu, Settings switch,
  editor section; UI tests updated for tiles that now live on page 2.
- **P2 — device (owed).** Swipe feel (one page per flick, spring-back on a short drag) on a phone,
  rows at Large and at AX sizes with My Day open, collapsed and removed.

## Risks

- A paging `TabView` whose page count changes under it: the selection is derived and always valid,
  and a write from the `TabView` equal to the derived page is ignored, so a reflow is never mistaken
  for a swipe.
- Tiles on grid page 2 are hidden from VoiceOver while page 1 is up (as off-screen pages already
  were). The dots, the named actions and the page value ("Actions, page 2 of 3") are the way across.

## Decisions

| Question | Decision |
|---|---|
| How is the editor presented? | A sheet from the cog. Not a page, so no swipe reaches it, and it has room at a one-row panel |
| Long press on the grid's gaps? | Kept — opens the same sheet as the cog |
| Return after the auto-flip | A swipe lands on grid page 1; "Show actions" returns to the remembered page (anchored by tile) |
| Rows per page | 1–4, counted in minimum tiles, then stretched to fill (cap 1.25 × natural); fewer at large text |
| Columns | 3; 1 at accessibility sizes (unchanged from #601) |
| My Day "remove from home" flag | Separate `myDayOnHome`; `myDayEnabled` keeps the briefings, tool and alerts |
| My Day off | Nothing on the home screen (the set-up card is removed) |
| Wake word off elsewhere | The session card says so and a tap turns it back on — unless push-to-talk is chosen |

## Out of scope

- Reordering tiles by dragging across pages on the home screen itself.
- Per-page arrangements (the order is one list by design).
- Widgets or cards other than My Day being removable from the home screen.
