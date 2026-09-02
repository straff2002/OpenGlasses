# Plan EA — Voice Home Grid & Quick Actions

**Status:** ✅ Shipped P1–P3, then revised on device (2026-08-31). The dock-fit criterion closed the
same day — the model tile dropped its model-name label for a provider glyph + constant caption (full
name stays in the accessibility label), and the dock's strip wraps into rows of four instead of
scrolling horizontally. Five phone rounds then rewrote most of the plan's decisions — the dock is a
three-page pager, My Day rows can be cleared, the panel's height is measured rather than apportioned,
and My Day expands in place instead of into a modal. See **P4**–**P8d** below. The pattern is the
plan's real lesson: every one of those rounds found something no amount of headless reasoning had.
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

### P7a — Reminders are a *day's* reminders (device round 2, 2026-09-02)

Phone use of the shipped card found three faults in how it treated reminders, and all three are one
policy question: what belongs on a card called My Day.

1. **Only overdue and due-today reminders enter the ranking.** The card took every incomplete
   reminder and ranked the undated ones last, which on a real account is most of them — a "someday"
   pile with no date attached is not a day's work, and it crowded out the things that were. Undated
   reminders now stay in Reminders, which is the app for them; future-dated ones (previously also in
   that last rank) are excluded outright so tomorrow's task cannot displace today's. This is the
   morning-only all-day rule again, in the other source: **the card curates, the source app keeps
   everything.** Nothing is completed, deleted or hidden anywhere but on the card.
2. **A row says which list it came from.** `MyDayReminder` carries `listName`
   (`EKReminder.calendar.title`) and the detail reads "Overdue · Work" / "Due 3:00 pm · Shopping".
   Without it the day's reminders arrive from every list at once as a pile of bare titles with no
   way to tell which part of your life each belongs to. A list name is the wearer's own words: it
   belongs on the row and in what VoiceOver reads, and **in no log line** — the same rule the store
   and home categories already follow. The compact card draws no detail, so its rows carry an
   explicit accessibility label rather than relying on what happens to be rendered.
3. **The cap stopped being invisible.** `items` is still ranked-then-capped, because the spoken
   briefing, the digest and the HUD all budget against it — but what the cap left out now travels
   with the snapshot as `overflowItems`, and the full-day screen shows `allItems`. "See all N items"
   counts the whole day. Clearing a row promoting the next one was always the intent; it read as
   items materialising only because nothing on screen could say the list was longer than the card.

**Tests.** Undated absent, due-tomorrow absent (including the date-only boundary case), due-today
and overdue present; the detail carries the list name and grows no stray separator without one; the
overflow is the same ranking's tail and `items` stays bounded; clearing a row promotes the next and
drops the reported total by exactly one.

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

### P8a — One tall frame, and the four-row ceiling retired (device round 3, 2026-09-02)

Reported from the phone once the conversation page could finally show a conversation: *"you get a
very small space… by having full height, the conversation can be properly reviewed."* The panel was
sized as a **grid** — at most four rows, and fewer when the grid held fewer tiles — and the
conversation page shares that frame, so a transcript was being read through a two-line window.

The first design considered was a per-page reading height: expand on the conversation page, return
to the row-snapped height on the others. It was **rejected before it was built**, and the reason is
the report it would have produced next — *"it keeps growing and shrinking."* A frame that depends on
the selected page moves under every swipe, and no amount of animating it on settle makes a surface
that changes size three times a gesture feel still.

**What shipped instead: the panel is as tall as the screen affords it, at all times, on every page.**

1. **`DockGridMetrics.restingRows(availableHeight:rowHeight:surfaceAboveIsCompact:)`** — the page is
   not a parameter and neither is the slot count. Rows are `floor(share × available ÷ rowHeight)`:
   the four-row ceiling is gone, and so is the "never more rows than the content needs" clamp that
   used to shrink the panel for a wearer with a short speed dial. Whole rows by construction, so P8's
   no-sliced-tile guarantee is untouched — the truncation *is* the snap.
2. **Two shares, because My Day is the one thing above the panel whose height the wearer controls.**
   0.24 with the card expanded (was 0.20 under a four-row ceiling), 0.52 collapsed (was 0.30) —
   what is left once the status card, My Day in its current state, the page control and the capsule
   have had theirs. Both are bounded by P8's rule rather than by taste: the surface above is never
   clipped at the panel's edge. A greedier pair was tried **in the simulator first** and cut the
   collapsed card by a few points, which is P8's exact failure shape, so the shares came down until
   the card was whole with a gap under it, and the expanded number follows the same arithmetic
   against a ~280 pt open card. The asymmetry is deliberate and is the honest one: a phone cannot
   hold an open My Day *and* a tall panel, and the collapse control is how a wearer says which they
   want. With My Day off — the shipped default — the compact branch applies, so the tall panel is
   what a new install gets. This is also the answer to the separate report that a collapsed card
   left dead space: the freed height now returns as whole rows rather than as a gap under the last.
3. **The invariant is restored, not revised.** Round 4 promised *"the panel never resizes under a
   swipe."* It now holds absolutely: **the frame is not a function of the page, so a swipe cannot
   change it.** The two things that do change it — collapsing My Day, and the first real tile
   measurement replacing the opening guess — both originate outside the pager and settle with a
   0.25 s animation keyed on the height itself.
4. **The grid page's consequence is accepted deliberately.** More visible rows and less scrolling;
   a wearer with few tiles gets empty glass below them rather than a short panel. That trade is the
   whole point — the frame belongs to all three pages, and the one that needs height most is the
   one that cannot ask for it.

**Tests.** The height as a truth table (My Day state × screen × row height → whole rows) at two
phone sizes and an accessibility row height; collapsing My Day never costs rows and never exceeds
its share, swept across screen sizes; a short grid keeps the tall frame; the unmeasured first frame
falls back to a guess; a very short screen still gets one row; and — stated as arithmetic — the
height function has no page input, with the pager's own test showing a page change carries a page
and nothing else.

> **Superseded by P8b and P8c.** The two shares below are gone, and so is the row-snapped frame.
> Everything else in P8a — the tall frame,
> the retired ceiling, whole rows, the page-is-not-an-input invariant — stands.

### P8b — The shares became a measurement (device round 4, 2026-09-02)

Reported from the phone with the tall panel approved: **with My Day expanded there is a visible gap
between the card's bottom and the panel's top.** Reproduced in the simulator first, on a screen the
size of the one it was reported from — an open My Day whose day happened to be a light one, and
~190 pt of empty glass under it.

**Mechanism, and it is the shares' own margin.** P8a chose 0.24 and 0.52 by measuring a *plausible*
surface — a ~116 pt status card, a ~50 pt collapsed My Day, a ~280 pt open one — and then rounded
down so the tallest of those was never clipped at the panel's edge (P8's rule). A margin against
clipping is dead space whenever the real card comes in shorter than the estimate, and a My Day card
is exactly the module whose height nobody can predict: it is as tall as the day is busy. The same
arithmetic produced the opposite failure at the other end, also reproduced: with My Day *off* the
compact share applied, but the setup card it draws instead is far taller than the ~50 pt collapsed
card the number was fitted to, and it was clipped flush against the panel.

**What shipped instead: the panel subtracts a measurement, not a share.**

1. **`DockGridMetrics.restingRows(availableHeight:reservedHeight:rowHeight:)`** — `reservedHeight`
   is the height everything that is not a grid row actually drew. `heightShare` and
   `heightShareWhenSurfaceAboveIsCompact` are deleted, and with them the dock's reads of
   `myDayEnabled` / `myDayCollapsed`: My Day's state reaches the panel by changing the measurement,
   which is also how a caption arriving reaches it, and how anything added to that surface later
   will. **Both failure shapes close at once.** Clipping is impossible by construction, because the
   number subtracted *is* the height the surface drew. The residual gap can only be the sub-row
   remainder — under one row, which is breathing room rather than a hole.
2. **Two measured groups, summed by a preference key.** `ConversationSurfaceHeightKey` reduces by
   addition, and the zone's modules report in two groups — the status card and My Day above the
   flexible spacer, the captions and notices held below it — because the panel needs the whole of
   what they drew and a group left out is a group the panel would grow over. The stack's own 16 pt
   spacing became the spacer's `minLength`, so the two gaps around it are a constant rather than
   something else to estimate: the zone's height is two measurements plus 32.
3. **The capsule is measured too**, on the tile's terms and for the tile's reason (`DockCapsuleHeightKey`).
   It was the last predicted number in the reservation, and predicting it is predicting a font's
   line height at text sizes nobody sweeps by hand. Its touch-target floor is what keeps the
   measurement from feeding back into the panel above it.
4. **The row arithmetic now pays for its gaps.** Rows are `floor((budget + rowSpacing) ÷ (rowHeight
   + rowSpacing))`, not `floor(budget ÷ rowHeight)`: `n` rows also cost the `n − 1` gaps between
   them, and those points were exactly what the last row used to overrun by.
5. **Everything else is untouched by design.** Whole-row snapping, the one-row floor, the
   first-frame fallback before any measurement arrives, the 0.25 s settle keyed on the height
   itself, and the page-is-not-an-input invariant.

**Tests.** The truth table's inputs become measured ones (reserved height × screen × row height →
whole rows) at two phone sizes and an accessibility row height. Two sweeps replace the share bound:
the panel never takes height the surface above drew, *and* never leaves a whole further row behind
as a gap — the two failure shapes as one property. The collapse pin is restated in measurement
terms: walking the surface above down in height never costs the panel a row. Page-independence, the
short-grid frame, the one-row floor (including a surface taller than the tab, which measuring makes
reachable) and the unmeasured first frame all stand, the last now including "the surface has not
reported yet".

### P8c — One rhythm, and the remainder moves inside the glass (device round 5, 2026-09-02)

P8b's arithmetic was right and its *placement* was wrong. Screenshots from the phone, both My Day
states: the leftover — the spacer floor plus the sub-row remainder, ~70–80 pt together — rendered
**between** My Day and the panel, while every other gap on the surface is 16 pt. The rule the report
states is the right one: *"The gap between should be similar as the other vertical gaps. This should
be consistent across all panels for good UI design."*

Measuring fixed how much was reserved. It did not stop the frame from *rounding*, and a frame that
snaps to whole rows has to put the rounding somewhere.

1. **Every inter-module gap is `DockGridMetrics.moduleGap` (16).** Status card ↕ My Day ↕ panel ↕
   capsule, one number, no second one. The zone's flexible spacer is gone — with the glass absorbing
   the remainder there is nothing left for a spacer to hold — and the captions/notices block joins
   the flow rather than being pinned to the bottom, because with no leftover those are the same
   place. Below the capsule stays 8: the next thing there is the tab bar, not a module.
2. **The glass absorbs everything left.** `panelPagesHeight(availableHeight:reservedHeight:rowHeight:)`
   is pure subtraction with a floor of one row plus the dots — no row term in the frame at all. The
   sum is now *exact*: surface + panel + the dock's rhythm = the screen, which is what the test
   asserts instead of "within a row".
3. **The whole-row rule moved to where it bites.** `viewportRows` snaps the grid's **scroll
   viewport** inside the glass. The edge that can slice a tile is its scroll view's, so that is the
   edge that lands on a row boundary; the remainder sits below it as calm empty glass, which the
   wearer has seen and accepts. Conversation and edit pages simply fill the glass.
4. **One settle curve, and only one animation.** `DockGridMetrics.heightSettle` is shared, and the
   panel's frame is now **deliberately not animated** — it tracks the measurement. A second
   animation there was the mushy part: while My Day animates its own height the reader reports a new
   value every frame, and `.animation(value:)` restarts an ease toward each one, so the panel
   arrived late behind a card that had already stopped. Tracking means card and panel sum to the
   screen on *every frame* — an exact height exchange. The changes with no motion of their own to
   ride (the opening guess giving way to the first measurement, a caption arriving, the tile and
   capsule measurements landing) carry the settle at their source instead.

### P8d — My Day expands in place; ↗ was a modal (device round 5)

Reported alongside the rhythm: *"should be a nice transition when my day opens and closes, maybe the
my day summary opens up taller rather than in a modal."*

**What ↗ was.** `arrow.up.right` presented `MyDayView` as a **sheet** — a full `NavigationStack`
screen with the whole list, per-item actions, an Availability section and pull-to-refresh. The row
tap and "See all N items" opened the same sheet.

**What it became.** A third card state, `isExpanded`, drawn in the flow:

- **Chevron** = collapsed ↔ summary, as before, and a collapse resets the expansion — expansion is a
  glance, not a setting, so it is `@State` rather than `@AppStorage`.
- **↗ became ⤢** (`arrow.up.left.and.arrow.down.right` / its inverse): grows the card in place to
  today's whole list. The arrows point the way the card is about to move, which the old ↗ — the
  universal "open elsewhere" — actively contradicted. "See all N items" and a row tap do the same.
- **The row actions came with it.** Complete, directions, dismiss and open-in-Calendar are ported
  into the expanded rows, so moving the list into the card is not a quieter version of it.
- **The card grows to whatever the day needs** and the zone — already a scroll view — scrolls when
  the day is longer than the screen. Deliberately *not* a nested scroll view inside the card: it
  would fight the zone's gesture and make the card's measured height ambiguous, which is the number
  the panel is sized from. The panel floors at one row plus the dots, as its own test pins.

**The modal survives for one named reason.** Repairing a source needs per-source messages and a
Settings deep link, which is a genuinely different screen from a list of today's items. It is now
reached from the availability line — the thing it repairs — instead of from the expand control, and
that line became a button. VoiceOver labels follow the new behaviour throughout.

## Rollout and exit criteria

Pure UI/composition — no new permissions, no new network. Rollback is reverting the PR. Complete
when the gaps around My Day are deterministic at every state and device size, no dock tile is ever
off-screen or unhittable at default type size on the smallest supported width, every action fires
through the existing turn pipeline, the editor round-trips, and the full suite, accessibility
checks, and Release build are green. All met as of the P4 revision.
