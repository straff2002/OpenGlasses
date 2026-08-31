# Plan EA — Voice Home Grid & Quick Actions

**Status:** ✅ Shipped P1–P3, then revised on device (2026-08-31). The dock-fit criterion closed the
same day — the model tile dropped its model-name label for a provider glyph + constant caption (full
name stays in the accessibility label), and the dock's strip wraps into rows of four instead of
scrolling horizontally. Four phone rounds then rewrote most of the plan's decisions — the dock is a
three-page pager and My Day rows can be cleared. See **P4**–**P7** below. The pattern is the plan's
real lesson: every one of those rounds found something no amount of headless reasoning had.
**Origin:** On-device design review of the shipped My Day home surface (2026-08-31): inconsistent
vertical gaps around the My Day card, and a bottom-dock utility row that scrolls because it carries
both controls and the user's quick actions.
**Priority:** P1 for the layout rhythm and dock relief; P2 for the editor.

The Voice tab's home surface grows from a single centred card into a top-aligned module stack with a
quick-action grid, and the bottom dock returns to being a control bar. One PR.

---

## Problem and verified path

`VoiceTab.conversationZone(_:)` centres `MyDayHomeView` between two flexible `Spacer`s, so the gaps
above and below it are leftover space — they vary by device height and by My Day's compact/full
state, and rarely match the fixed 12 pt top / 8 pt bottom paddings of the status card and dock. The
accessibility layout (`accessibleConversationZone`) is already a top-aligned `VStack(spacing: 16)`,
so the two layouts disagree about the surface's shape.

`BottomControlBar`'s utility row carries the local-model chip, model picker, the user's
`QuickActionTiles()` band, camera connect, Type, push-to-talk, and Disconnect in one horizontally
scrolling row. Content actions and controls compete for the same strip, and the row outgrows the
width on every device.

Relevant seams:

- `OpenGlasses/Sources/App/Views/VoiceTab.swift` — both conversation zones, `shouldShowMyDay(for:)`
- `OpenGlasses/Sources/App/Views/BottomControlBar.swift` — utility row, `QuickActionTiles`
- whatever model/store feeds `QuickActionTiles` today (investigate before building; if it is the
  Plan Y quick-action catalog there may be an existing editor surface to extend)
- `ChatInputBar`'s typed-turn submission path (the prompt-injection seam actions must reuse)
- Plan CN vision attachment + the existing photo-capture path (for photo-first actions)
- `SessionSurfaceAccessibilityTests.swift` — the Plan DF VoiceOver bar to hold

## Decisions and invariants

1. ~~Dock = controls, grid = content actions.~~ **Superseded in P4.** Two grids of identical tiles
   stacked one above the other read on device as one thing split in half. There is one grid, in the
   dock panel, holding controls and content actions together.
2. One spacing scale: modules stack top-aligned at 16 pt with the existing 12 pt top / 8 pt bottom
   paddings; the single flexible spacer sits between the top modules and the captions/transcript
   block. There is now one layout at every text size rather than two that agree (P4).
3. The grid follows My Day's yielding rules exactly: hidden while the assistant thinks or speaks and
   while live captions are active; hidden (not compacted) while listening.
4. Actions are data, not view literals: a catalog type with stable ids, so entries are testable,
   editable, and extensible. Two kinds — `.prompt` (submit a canned user turn through the same path
   `ChatInputBar` uses) and `.photoPrompt` (capture via the existing glasses-camera/phone-fallback
   path, attach via Plan CN machinery, then submit). No parallel entry points.
5. VoiceOver parity per Plan DF: every tile a labelled button with a hint and honest ordering. The
   grid drops to two columns at accessibility type sizes, where a tile lays its glyph beside its
   label and four columns would shred every caption.
6. ~~The grid draws at most 8 tiles.~~ **Superseded in P4.** No ceiling: the grid wraps into rows of
   four and scrolls vertically inside a bounded panel height, so nothing is ever cut off.
7. Controls are always present; content tiles yield. A dock a user can strip of its own disconnect
   is a trap, so `hidden` is honoured for actions and ignored for controls — enforced in the
   resolver, not in one list's gesture configuration.
8. The capsule is the bottom-most element, on its own glass, and the grid sits above it (P5). The
   biggest and most-used target belongs nearest the thumb; the grid of small ones does not belong
   between it and the tab bar.
9. The panel's height is always a whole number of rows — three at rest, fewer when the grid is
   shorter, scrolling beyond (P5). A partial tile is not a smaller control, it is an unreachable
   one.

As built: `.prompt` submits through `AppState.sendTextMessage` — the `ChatInputBar` seam with turn
running, cancellation, and thread persistence — deliberately not `executeQuickAction`'s older
direct-`llmService` branch. Photo tiles reuse `capturePhotoAndSend` and its phone-camera fallback.
Persistence reuses the shipped `Config.quickActions` store for the actions; only the arrangement is
new (versioned codable, lossy decode that names what it dropped). The dead `showAllQuickActions`
preference and `DockItem.quickActions` were retired with salvage-tested stored-order decoding.

## P1 — Layout rhythm and dock relief ✅

1. Top-align the conversation zone: status card → 16 pt → My Day (full width) → 16 pt → quick-action
   grid → spacer → captions/transcript → dock. Converge `accessibleConversationZone` to the same
   order.
2. Move `QuickActionTiles` out of the dock's utility row into the home grid; the dock row keeps
   model chip, picker, camera, Type, push-to-talk, and Disconnect. Verify the slimmed row fits
   without scrolling on the smallest supported width at default type size.
3. Preserve yielding, recording badge, chat-input swap, and dock behaviour unchanged.

**Tests.** Visibility predicate truth table across voice states × captions; catalog ids stable;
accessibility labels/identifiers for migrated tiles (extend the session-surface pattern).

## P2 — Canned-prompt and photo actions ✅

1. Default catalog entries: Meetings today (prompt), Tasks today (prompt), Photo → Event
   (photoPrompt), Photo → Task (photoPrompt) — each resolving through shipped tools
   (`CalendarTool`, `AppleRemindersTool`) via the normal LLM turn, not direct tool calls.
2. `.photoPrompt` captures first, attaches, then submits; capture failure is a spoken/visible error,
   never a silent no-op.

**Tests.** Action kind marking; prompt text stability; photo actions require capture; a `.prompt`
action reaches the session through the same seam as typed input (fake session).

## P3 — Grid editor ✅

1. Edit surface (long-press or Settings entry) to add/remove/reorder tiles from the full catalog —
   built-ins plus whatever fed `QuickActionTiles`. Persisted per the existing quick-action store if
   one exists; otherwise a small versioned codable store with lossy decode (BB salvage semantics).
2. Reset-to-default; removing a tile never deletes any underlying user data.

**Tests.** Reorder/add/remove round-trip; lossy decode drops unknown entries by name, never
silently; reset restores defaults.

## P4 — On-device revision ✅

Tested on an iPhone Air against a Release build. Four changes:

1. **One grid, one editor.** `HomeActionGrid` as a separate home-surface card is gone; its tiles
   moved into the dock panel's wrapped grid as `DockSlot` values (`.control` | `.action`) resolved
   by `DockGridCatalog` from one arrangement. The Bar Layout and Home Grid editors merged into
   `DockLayoutEditorView`, so a tile can finally sit beside a control — the move neither list could
   express. Both stores are kept: `homeGridArrangement` is the arrangement, `dockItemOrder` is read
   as the fallback control ordering so a bar arranged before the merge keeps its order with no
   migration step. The grid has a bounded height and scrolls vertically past it.
2. **My Day collapses.** A chevron in the header plus a tap on the header's empty space, persisted
   in `@AppStorage("myDayCollapsed")`. Collapsed is the header row alone, carrying today's headline
   when the snapshot is loaded. It composes with the session's compact form and outranks it: the
   compact form is imposed while the mic is open, this is a choice.
3. **A functional regression, fixed.** With a reply on screen and a two-row dock, the conversation
   zone and the dock shared one fixed `VStack` whose intrinsic height exceeded the tab — and a
   `VStack` in that position neither clips nor scrolls, it overflows. The overflow pushed the bottom
   of the dock past the tab bar, so the capsule stayed visible while the tiles under it were outside
   the hittable area. The zone is now a `ScrollView` inside a `GeometryReader`, which accepts any
   height down to zero: the dock is laid out at its intrinsic height first and every tile stays
   on screen and tappable. `minHeight` keeps the top-aligned rhythm when the content is short.
4. **Provider marks are asset-first.** `DockLayout.providerMarkAsset(for:)` names
   `ProviderMark-<provider rawValue>`; the tile draws that asset template-rendered when the catalog
   carries one and falls back to the (now exhaustive) `modelTileGlyph` mapping otherwise. No mark is
   drawn from an approximation of somebody's trademark — sourcing official marks is separate work.

**Tests.** Dock-slot composition (controls then actions, interleaving, stored control order leads);
yielding removes actions and leaves every control; controls cannot be hidden; every provider has a
symbol fallback and the three major ones do not collide; asset names keyed to the raw value.

## P5 — Inverted stack, whole rows ✅

A second phone test, against the P4 build. Two changes and a re-check:

1. **The stack inverted.** The capsule was on top of the grid inside one glass rectangle — glass on
   glass, with the app's largest and most-used control furthest from the thumb. They are two
   surfaces now: the grid panel keeps the rounded-rectangle glass, the capsule keeps the
   capsule-shaped glass it always drew, and bottom-to-top the tab reads tab bar → capsule → grid
   panel → conversation zone.
2. **Whole rows, three of them.** The panel took a single scaled constant (~100 pt) as its maximum
   height, which landed mid-tile: on device that was one and three-quarter rows with the next row's
   tiles sliced across the panel edge — "definitely not accessible", and correctly so. The height is
   now `rows × tileHeight + (rows − 1) × spacing` from `DockGridMetrics`, with three complete rows
   at rest, fewer when the grid is shorter (yielding the content tiles gives the rows back to the
   conversation), and a scroll beyond. It is an exact `.frame(height:)` rather than a maximum,
   because any height the stack picks that is not a multiple of a row is a clipped tile. The row
   height is composed from the same scaled bases `BarButton` draws from — both now live in
   `DockGridMetrics` so they cannot drift — and the caption base is set a point above `.caption`'s
   real line height on purpose: over-estimating leaves a hairline of glass, under-estimating clips.
3. **Overflow re-checked.** The split into two surfaces keeps the P4 fix and sharpens it: the
   controls block now has an exact intrinsic height instead of a bounded one, so the `layoutPriority`
   split with the conversation zone's `ScrollView` is unambiguous. Nothing overlaps the tab bar or
   the capsule.

**Tests.** Three rows at rest and the rest scrolled; short grids shrink the panel; the accessibility
column drop changes the row count, not the snap; the panel height is a whole number of rows at every
plausible tile height; the row height never underestimates the drawn tile.

## P6 — The panel becomes a pager ✅

A third and fourth phone round, and the largest change to the surface's shape so far. The panel
stopped being one grid with a yielding rule and became three pages behind one frame.

1. **Four rows at rest**, same row-snapped arithmetic — `DockGridMetrics.defaultVisibleRows`.
2. **Pager: conversation ↔ grid ↔ edit.** The grid is the middle page and the home one, so each of
   the others is one gesture away. `DockPagerPolicy` is the whole decision, pure:

   | from | to | result |
   |---|---|---|
   | idle / listening | thinking | flip to conversation (the turn started) |
   | thinking | speaking | flip to conversation (the reply arrived) |
   | idle | listening | nothing — an open mic is not a turn |
   | speaking | idle | nothing, **and it does not flip back** |
   | any | any, after the user swiped this turn | nothing |
   | any | any, on a new turn | the override clears; it flips again |

   **Dwell: no timer.** The reply stays until the wearer swipes away or the next turn arrives. A
   panel that slides out from under someone still reading is the same failure as one that fights
   their swipe, only on a delay.
3. **The transcript moved to page 1; the error card did not.** `TranscriptOverlay` is now the
   conversation page, flat on the panel's glass. The error/notice card split out as
   `SessionNoticeOverlay` and stayed in the conversation zone — the panel pages, and a failure the
   wearer has to see must never be one swipe from invisible. The zone is now status card → My Day →
   captions → notices.
4. **The editor is page 2.** `DockLayoutEditPage` shares every mutation with the full-screen
   `DockLayoutEditorView` through `DockArrangementEditor`; only the driving differs. The page
   reorders with ▲▼ buttons rather than a drag, deliberately: a drag handle inside a horizontally
   paging panel is two gestures competing for one finger, and buttons are also the only reordering
   VoiceOver can drive. Settings → Quick Actions → Bar Layout keeps the drag. Long-press on the grid
   background now flips to this page instead of presenting a sheet.
5. **Provider marks are drawn at `DockGridMetrics.markGlyphBox`**, not the SF symbol's point size —
   a mark is flat artwork with its own viewBox margin and no stroke conventions, so at the symbol's
   number it read too small to recognise. Applies wherever `BarButton.assetIcon` renders.
6. **Nothing critical hides behind a page.** The capsule never pages, and during a turn it *is* the
   mid-turn control ("Cancel" / "Tap to stop"), so stopping is always one tap with no swipe.
   Disconnect and the model picker are one swipe away, which is the deliberate trade.

**Tests.** The flip table above; the override standing for its turn and clearing on the next; the
grid as the middle page; every page named for VoiceOver; drag and nudge agreeing; removal refusing
controls from either surface.

## P7 — My Day: clearing rows, all-day policy, freshness ✅

1. **Swipe a row left to clear it.** `.swipeActions` was unavailable — it is a `List` modifier and
   both My Day surfaces are `OGCard` → `VStack` rows — so `MyDaySwipeToClear` builds it: horizontal
   drag only, refusing any gesture whose vertical travel dominates, so it never claims the
   conversation zone's scroll. Partial swipe rests showing a Clear button; a full swipe clears on
   release. The gesture leaves no mark in the accessibility tree, so a named per-row action is the
   real control rather than a convenience beside it.
2. **`.dismiss` generalised, not duplicated.** One entry point, `MyDayService.dismiss(_:)`. A digest
   update still retires inside the digest — its own record, the shipped path. Everything else
   belongs to a source this app does not own, so the dismissal is recorded against the *card*:
   `MyDayDismissalStore`, day-scoped, filtered inside `compose` between ranking and the item cap
   (so a cleared row frees its slot rather than leaving a hole, and the headline stays consistent
   with the rows). **It never deletes or completes anything** — the event is still in the compose
   inputs, still counted, only un-ranked. A dismissal is pinned to the row's content as well as its
   id, so a rescheduled meeting is new news and comes back.
3. **Today's all-day events are a morning-only slot.** Briefing information, not a commitment:
   worth a row over breakfast, noise by lunchtime. The headline counts them on the same rule, so
   the sentence and the rows tell one story. Tomorrow's all-day events in the evening preview are
   untouched — that is forward-looking, a different question.
4. **The card refreshes across the day.** It did not before: `nextRefreshAt` only ever *labelled* a
   snapshot stale, and the sole automatic refresh was the first load. It now also refreshes on app
   foregrounding (when actually stale) and on `EKEventStoreChanged`, both as background refreshes
   that record no briefing metric. Frequent recompose is safe precisely because dismissals persist.

**Tests.** All-day present at 9:00, absent at 14:00 and 20:00, tomorrow's preview intact; a cleared
event absent from `items` but still in the inputs and the headline count; a cleared row freeing its
slot; a rescheduled event returning; dismissals surviving every refresh in a day and lapsing at the
rollover; keys namespaced by source.

## P8 — The clip the four-row panel caused ✅

Reported from the phone as "the My Day panel is cut off at the bottom", and **reproduced in the
simulator first** — which is the only reason the diagnosis is a mechanism rather than a guess. A
`-OGUITestSeedMyDay` launch flag now seeds a full card the way `.seedCaptions` seeds a caption
session, so this state is reachable without a calendar, a permission grant or a real morning.

**Mechanism (the second of the three proposed, with a cause the list did not name).** The zone was
*scrollable* — swiping revealed the rest of the card intact. So this was not a claimed gesture or a
stale height. It was arithmetic: the dock had grown by a row, a page indicator and a separated
capsule, the zone's content (status card + expanded My Day) no longer fitted what was left, and the
resting scroll position put the clip line exactly on the panel's top edge. Flush against the glass,
with no gap and no scroll indicator, a card with more below it is indistinguishable from a card that
has been cut in half. Two smaller clips rode along: the grid's last row was trimmed by a few points,
and the page dots overlapped its captions.

**Fixes, all structural:**

1. **The panel sizes itself from the screen.** `DockGridMetrics.restingRows` takes the tab's height
   and a share of it. Four rows and an expanded My Day do not both fit on a 6.9" phone — that is
   arithmetic, not preference — so the ceiling stays four and the phone rests at three. Collapsing
   My Day hands back its height and the panel takes the fourth row, which is the one state where a
   phone genuinely affords it. The tab height is read once at the top of `VoiceTab` and handed down:
   one-way, because the reverse is circular.
2. **The row height is measured, not predicted.** `DockTileHeightKey` reports a real tile's height
   and the panel snaps to that. Predicting a tile meant predicting a font's line height, and being a
   point short of it is precisely how a last row ends up sliced — the composed estimate is now only
   the first frame's answer.
3. **`pageIndicatorHeight` 28 → 40.** SwiftUI centres its page index view *inside* the tab view's
   bottom rather than below it, so reserving the capsule's own height still left it over the last
   row's captions. Measured against the dots as drawn.
4. **The zone never ends flush.** 16 pt of bottom padding plus visible scroll indicators, so "there
   is more here" is legible at rest instead of being discoverable only by trying.

**Verified on device-sized simulator across states:** expanded (3 rows, card whole, gap before the
panel), collapsed (4 rows, all captions intact, dots clear), and the grid page's own scroll.

## Rollout and exit criteria

Pure UI/composition — no new permissions, no new network. Rollback is reverting the PR. Complete
when the gaps around My Day are deterministic at every state and device size, no dock tile is ever
off-screen or unhittable at default type size on the smallest supported width, every action fires
through the existing turn pipeline, the editor round-trips, and the full suite, accessibility
checks, and Release build are green. All met as of the P4 revision.
