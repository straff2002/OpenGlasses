# Plan MU — The Lens Read at Work (a page you get around in one move, fuller tiles, sources on their own, fewer buttons, and an answer that stays until you put it away)

**Status:** 🚧 P0–P4 built headless and merged (PR 1189, 2026-11-22); P7 catalog sync built 2026-11-22
(branch `chore/mu-catalog-sync`: 22 new keys in the 13 complete languages, add-only, with Plan MQ
P1's three Developer panel keys). P0 and P1 2026-11-21: one picture
a row (MG's tile grid dropped from the page view, decision 5), `LensPictureScale` and the fit check
(Display & HUD and the Developer panel, default factor 1), the page opening whole with the answer
highlighted and the rest dimmed, its words under the picture, one press for the close-up (both
halves in one strip) or fit width, **Back**, **Rows**, the voice words, three buttons at most. P2–P4
2026-11-22: `HUDReadingRows` at 8 lines joined up to 9 with no orphan tile and the stride cut gone;
`LensSourceTile` and the reading view's source tile; "Earlier — press to open" with three lines;
`LensButtonRowBudget` (provisional constants: 15 px a character, 1.8× for a full-width character,
32 px of padding a button, 8 px gaps, against the 576 px column) on the reading view, the paged card
(Meta Display only), Actions, the page view and reading mode, with the 13-language test; the reading
view's three-button row with follow-ups on Actions; Keep answers up (Until closed by default, or 3
minutes), "show that again" for the conversation's life, "hide that" and "put it away" as Close.
Not done: P5 (the budget's constants are estimates until measured), P6 and P8's device checks (and the fit check's one reading in P0). **All 10 decisions
taken 2026-11-21:** 1–8 and 10 as recommended (7 is the owner's own suggestion); 9 declined, so §8's
request to Meta is not filed.
**Track:** Display (Meta Ray-Ban Display through the stable `MWDATDisplay`; DAT 1.1.0, adopted on
`chore/dat-1-1-0`, adds nothing to the Display). Every picture sent to the lens, the reading view
(Plan MG §2), the answer card's lifetime (Plan KP §3, MG decision 4) and the page view (Plan KV,
MG §4). P0 is headless with one reading from the glasses. P1–P4 are headless. P5 runs on the iOS
Simulator against Meta's simulated Display. P6 is TestFlight only, P7 is the catalog sync, and P8
needs the glasses.
**Source:** a Ray-Ban Display tester's notes and photos taken through the lens, 2026-11-21, on a build
with Plan MG P2–P4 and PRs 1137–1139. The pinned `MWDATDisplay` and the 1.1.0 `MWDATInputs`
interfaces, read 2026-11-21. Plan JV's first probe run on a Ray-Ban Display (PR 1155).
**Related:** Plan [MG](MG-reading-the-conversation-on-the-lens.md) (the reading view, the tile grid,
the strip, "show that again", P5 and P6, which this plan's P6 and P8 take over), Plan
[KV](KV-the-page-on-the-lens.md) (the page view, `LensPageFrame`, the four-button rule), Plan
[KP](KP-answers-you-can-act-on.md) (the card's lifetime, follow-ups, Actions), Plan
[EK](EK-manual-structure-and-figures.md) (`Source:` lines and `CitationLineParser`, EK P3), Plan
[JV](JV-dat-experimental-testflight-lane.md) (Inputs, TestFlight only).

---

## Why

The tester confirmed two things work on the glasses: an answer wakes the lens, even after the wearer
turned the display off with Meta's gesture, and the conversation scrolls as one view. They raised five
things:

1. **The answer goes away while it is still being used.** It clears after about five minutes without
   a press, and a technician may still be working through that instruction. They want it to stay
   until it is dismissed, with a double tap to hide it and another to bring the last one back.
2. **Scrolling seems to stop after about six sentences.**
3. **Tiles are short and split badly** (owner, from the photos): a sentence that runs one word past a
   tile leaves a tile holding only "20.". The owner asks whether every source line should be its own
   tile, and whether a tile can hold more than four lines.
4. **The button row is cut off** when it holds more than about three buttons or their labels are long.
   The tester asks whether the buttons are needed at all when voice does the same.
5. **Reading a page is too slow.** Stepping between zoom buttons and pressing them again and again
   takes too long for real work. They hope for Meta's own pinch-to-zoom and drag-to-pan. A photo of
   "show me the page" shows one corner of the page, cut off on the right, under **Next diagram ›** and
   **Close**, not the whole page. Two more photos follow the scroll up: first the page's top-left
   corner under "p.19" and "Zoom in for labels", then a larger part of a table under **Zoom in**,
   **Whole page**, **Move** and **Close**, still cut off on the right. Then, with more photos: the zoom
   works through the buttons and fine detail is readable, so picture quality is enough. The problem is
   getting around the page, which is still too slow to use during real work.

## What the tester sees, and why

**The answer clears at 3 minutes, not 5.** The reading view's `HUDAnswerCard.readingIdleLifetime` is
180 s without a press (MG decision 4); the paged card's is 60 s. The lens dims at 20 s and sleeps at
25 s, so the wearer looks up again some minutes later and finds nothing. "Show that again" brings a
closed answer back, but only for `reopenLifetime` (10 minutes), and only by voice.

**The double tap the tester describes is Meta's own.** The display-off gesture they used is Meta's
system toggle for the Display, and apps never receive it. Their report shows that turning the display
off does not end our session: the next answer woke the lens with our view. So if the answer simply
stayed up, Meta's own gesture would already hide it and bring it back. Nothing new would be needed
except a device check that the view returns as it was left.

**Scrolling doesn't stop; the earlier answers are folded.** Under the answer's buttons, **Earlier**
lists this conversation's previous answers folded to their question and first two lines
(`HUDReadingViewBuilder.collapsedLines`). Pressing one opens it in full, but nothing on the lens says
so. The photos show this: about six sentences of the answer, the buttons, then folded snippets.

**The "20." tile is a cutting bug, not a choice.** `HUDReadingRows.split` cuts a paragraph with
`HUDAnswerPager`, whose single-page case may hold one line more than `rowMaxLines`. The function then
cuts that page every four lines, and the fifth line becomes a tile of its own. Tiles are four lines
because MG P1 measured that a box taller than the lens loses its top, and four lines (about 160 px) was
the safe choice. The lens is 600 px: a body line is 38 px (`LensPageFrame.bodyLinePixels`) and a card
pads 8 px each side, so a tile of 8 lines is about 320 px. That still leaves the question line and the
start of the next tile on screen.

**Sources share a tile with prose only when the model puts them there.** `VaultRetriever` attaches a
`Source:` line on its own line, and in the first photo it got its own tile. In the second, the model
ran "Source: … page 20." onto the end of its sentence, so it shared the paragraph's tile and got split.
`CitationLineParser.sourceBodies(of:)` already finds a `Source:` marker inside a line.

**The button row overflows because it counts buttons, not width.** The reading view allows four:
**Page** when there is one, follow-ups (two, or one beside **Page**), **Actions** and **Close**. The
Display cannot scroll sideways (Meta's docs), so a row wider than the 576 px column is centred and
cut off at both ends. In the first photo, two follow-up questions pushed the first label off the left
and **Close** off the right.

**Pictures in a row don't fit on the glasses.** The page photos are explained by two things:

- **The first photo is the tile grid.** The only page view whose buttons are exactly **Next diagram ›**
  and **Close** is the whole page as a 3 × 3 tile grid (`HUDPageScreenBuilder.items` with
  `showsTiles`, MG decision 7). A send opens scrolled to the button row at the bottom, so the wearer
  first sees the bottom row's first tile: the "bottom-left corner" they described. The simulated
  Display draws three 186 px tiles across. The glasses draw one tile across the whole view, cut off
  on the right, so each row shows only its first tile. Scrolling up passes the middle row's first
  tile and reaches the top-left one under the citation ("p.19") and the hint (the second photo).
- **The zoomed photos are working as designed.** **Zoom in**, **Whole page** and **Move**, or
  **←**, **→** and **Done** while moving, belong to a zoomed view. On the Meta Display a zoomed view's
  strip is drawn after the button row (`LensPageSession` puts the slices in `trailingFlow`), which is
  why the buttons sit above the picture. The strip is the crop's column of the page, so the table's
  right-hand column is outside it until the wearer moves right. The tester confirmed the zoom works
  and fine detail is readable: picture quality is enough.

`MWDATDisplay`'s `Image` offers only `.icon` and `.fill`; the app can't give a picture a size. On the
simulated Display `.fill` draws one image pixel per lens pixel (MG P1 built the tile and strip sizes on
that). A single full-width picture looks the same on the glasses. Three pictures in one row do not:
on the glasses one of them takes the whole width. Photos taken through a lens can't tell whether the
glasses scale the picture up or fill the row with it. MG P6 already lists tile size as a device check,
and the page report doesn't record what was drawn.

**Getting around a page takes too many steps.** To reach one cell in the table's right-hand column
today, the wearer must: zoom in (one press, or a tile), step the band's focus to **Move**, press it,
step to **→**, press it once or twice, then step to **Done**. Each press is a band pinch after one or
more swipes to reach the button, and the view redraws after each. Scrolling up and down is the only
thing that is quick, because the lens does it itself.

**What Meta gives apps for pinch, drag and double tap.** In the stable SDK (1.0.1, and 1.1.0 from
2026-11-20): nothing. `MWDATDisplay` has `FlexBox`, `Text`, `Image`, `Button`, `ButtonGroup`, `Icon`
and `VideoPlayer`, with `onTap` and button clicks. It has no zoom, scale, pan or gesture handler, and
the lens scrolls only vertically, by moving focus. The experimental `MWDATInputs` reports `nav`
(four directions), `select`, `back`, `button`, `capture` (short, hold or double press of the capture
button) and `drag`. It has no pinch-zoom and no double tap. JV's probe run on a Ray-Ban Display found
band swipes arrive as clean `nav` events and pinches as `select`, but a drag arrives only as short
bursts, and each pinch sends one. Meta says experimental APIs "cannot be published yet", which reads as
not yet rather than never. So swipes and pinches are worth mapping in the TestFlight lane now, ready to
move into the store build when Meta makes Inputs stable. Even then, pinch-to-zoom and free dragging
aren't in what Inputs reports today.

## Scope

0. **One picture a row, checked on the glasses (§0).** Nothing sent to the Meta Display puts two
   pictures side by side. The tile grid is off by default (decision 5), and any other row of pictures
   becomes one picture. **Fit check** in Display & HUD (and the Developer panel) sends one screen with
   one picture exactly 576 px wide, numbered 1 to 12 across (one number every 48 px), and under it a
   row of three numbered 186 px tiles. The wearer says, or picks on the phone, the highest number they
   can read whole and how many tiles they see. Twelve and three means the glasses match the simulator.
   Fewer numbers means the glasses scale pictures up: `LensPictureScale` (pure) then shrinks every
   picture by that factor before it is sent, kept per glasses model. Twelve and one tile means a row is
   filled by its first picture. The reading goes in the support report, and `LensPageReport` records
   each sent picture's pixel size. The default factor is 1, which matches the tester's single pictures
   (decision 10).
1. **Fuller tiles (§1).** A paragraph is one tile when it fits in `rowMaxLines` = **8** lines (from
   4). A longer one is cut at a sentence end at or before 8 lines, then at a word. A last piece of one
   line, or under about 20 characters, is joined to the tile before it when that tile then stays within
   **9** lines (the lens-safe ceiling), and otherwise the cut moves back a sentence. The fix also
   removes the stride cut that made the "20." tile. The streaming rule is unchanged: tiles stay stable
   as the text grows (`settledRowCount`). The question line keeps its place over the first tile.
2. **Sources on their own (§2).** Every `Source:` marker in the answer, on its own line or inside a
   sentence, is moved out of the prose into one **source tile** at the end of the answer, before the
   buttons. A sentence that ends in "Source: …" keeps its words up to the marker. The source tile is
   a card (so focus can rest on it), with the meta style and at most 3 lines. Several sources are
   joined with "; ", as the photo's tile already does, and the rest are cut with "…". Pressing the
   source tile opens its page on the lens (the citation's door, Plan EK), the same as **Page**. The
   spoken answer and the phone's chat are unchanged: this changes only how the lens lays the text out.
3. **A button row that fits (§3).** The reading view keeps at most **3** buttons: **Page** when the
   answer staged one, then **Actions**, then **Close**. When there is no page, the row has one
   follow-up before **Actions**. All follow-ups move to the Actions screen, which already lists them,
   and to voice: "ask the first one" or the question itself, as now. Every button row on the lens
   (the reading view, the paged card, Actions, the page view, reading mode) is checked against a
   **width budget** (`LensButtonRowBudget`, pure), not only a count. Each label's width is estimated
   from its characters with an advance measured in P5, plus the button's padding and the row's gaps,
   and must fit the 576 px column. When a row would be too wide, a label is cut to a short form (for
   example "Next diagram ›" → "Next ›"), and if it still doesn't fit the least important button moves
   to Actions. Close is never dropped: Meta's Back gesture isn't passed to apps (ios #349), so Close
   is the only way to put the lens away from the lens itself.
4. **The answer stays until it is put away (§4).** On the Meta Display the reading view has **no idle
   lifetime**. It stays until **Close**, a new answer, the end of a private conversation (Plan [LU](LU-private-conversation.md)), the
   HUD turning off, or a disconnect longer than `LensConversationLog`'s window. The lens still dims
   and sleeps on Meta's own timer, and Meta's display gesture hides and shows it (device check, §7).
   A closed answer can be brought back ("show that again", "bring it back") for as long as the
   conversation lasts, not 10 minutes. "Hide that" and "put it away" are added to the voice words as
   Close. The paged card (Pages, and Even's lens) keeps its 60 s. The phone's Display & HUD gains **Keep answers up: Until closed / 3 minutes**, defaulting to Until
   closed (decision 2).
5. **Say what Earlier is (§5).** The **Earlier** heading becomes "Earlier — press to open" (one meta
   line). A folded earlier answer shows its question and first **3** lines (from 2), ending in "…".
6. **A page you get around in one or two moves (§6).** The aim is to remove the steps, not to make
   them quicker: up and down are the lens's own scroll, and the only other move is one press.
   - **It opens whole, with the answer highlighted** (owner, 2026-11-21). "Show me the page" opens on
     one picture of the whole page fitted to the lens, the view the tester asked for. The part the
     answer came from (the passage's mark, the table row or the figure: `PassageMarks`,
     `LensPageFocus`, `PageFigureLocator`) is outlined in the highlight colour, as the page view
     already does (`LensPageRenderPlan`, `LensHighlightColour`). The rest of the page is drawn at
     about half brightness so the highlight stands out on an additive lens. The wearer sees at once
     where on the page the answer is.
   - **Its words are under it, so no press is needed to read it.** At whole-page size the page's text
     is too small to read (the tester needed to zoom for labels). So the line under the picture, which
     today says "Zoom in for labels", carries the highlighted part's own words, one or two lines: the
     table row from `TableLookup` ("E7 · Low supply voltage · Check the supply"), or the cited passage's
     first sentence. The picture shows where; the line says what.
   - **One pinch reads it closely.** Focus opens on the picture, so a pinch opens a **close-up** of
     the highlighted part at a readable zoom (about 2×), not of whatever happens to be in view. A part
     wider than the lens is cut into a left half and a right half, both stacked in one strip: the left
     half's rows, then a "Right half" marker, then the right half's rows. Both are reached by
     scrolling, with no **Move** and no arrows. The band scrolls on past the part, down the page at
     the same zoom. **Back** (a button at the top, where focus opens) returns to the whole page.
   - **A page with nothing to highlight** (asked for by number) opens whole with no highlight. A pinch
     opens it at **fit width**, as wide as the lens and scrolled from the top, and the band scrolls it
     down.
   - **A table can be read as text.** When the vault holds the page's table (`TableLookup`), the
     button **Rows** shows the table one row per card: "E7 · Low supply voltage · Check the supply …",
     with the column names on each card. The band scrolls the rows, and a row can be pressed to say
     it aloud, opened at the highlighted row. Nothing is lost to the lens's width. It is one press
     from the whole page (decision 6).
   - **Voice gets there directly:** "show E7", "go to the bottom", "close-up", "whole page", "right
     half", "back". MG's combined zoom words stay.
   - **The buttons are at most three:** the whole page has **Rows** (for a table) and **Close**; a
     close-up or fit width has **Back** and **Close**; **Read it** and **Next page ›** are added only where they
     apply, within §3's budget. **Zoom in**, **Zoom out**, **Move**, the arrows, **Done** and **Next
     diagram ›** leave the lens's buttons (the zoom and diagram words stay by voice and on Actions).
   - The page report records each view's drawn picture sizes, what it highlighted and why (cited mark,
     figure, table row, none), and every press, so a support report shows how many moves a page took.
7. **Swipe and pinch in the TestFlight lane (§7, P6).** Under `DAT_EXPERIMENTAL` only, in
   `Sources/Glasses/Experimental/`: band `nav` **left/right** jump between a close-up's halves and, at
   fit width, to the previous or next page (one send each), so no button is needed for either. Up and down stay the lens's own scroll, and `back` is never consumed. This lane is
   ready to move into the store build if Meta makes `MWDATInputs` stable. Until then the store build
   keeps §6's voice and buttons. Free drag and pinch-to-zoom are not attempted: Inputs doesn't report
   them (decision 8).
8. **Ask Meta (§8).** Not done (decision 9, declined 2026-11-21): Meta will add zoom, pan, an image
   size, horizontal scroll and an app-visible double tap when it decides to. Each DAT
   bump's interface diff looks for them.

**Out of scope:** keeping the lens awake (MG §8 decided against a keep-awake loop; this plan only
stops clearing the view), the phone's own page viewer, Even's lens (its paged card and 60 s are
unchanged), live-mode answer cards beyond what the reading view already shows.

## Phases

- **P0 — One picture a row, and the fit check (§0).** Small and first. Headless: the tile grid off by
  default, any row of pictures sent as one, `LensPictureScale` (the reading → factor table, per-model
  storage, default 1), the fit-check screen and its phone and voice answers, the report fields. Tests:
  no screen sent to the Meta Display has two pictures in a row, every picture is sent at its lens
  size divided by the factor, at 1 nothing changes. One fit check on the tester's glasses afterwards.
- **P1 — A page you get around in one or two moves (§6).** The tester's main complaint, so it comes
  next. Headless: the whole page opening with the answer highlighted and the rest dimmed; the
  highlighted part's words in the line under the picture (table row or first sentence, cut to two
  lines); focus on the picture so a pinch opens the highlight's close-up, with both halves stacked in
  one strip and the marker; fit width for a page with no highlight; **Back** to the whole page;
  **Rows** from `TableLookup` as cards, opened at the row; the voice words; the page view's buttons at
  most three; the report's highlight reason and press count. Tests: a cited row is outlined and its
  words are under the picture with no press; the close-up is of the highlight wherever the lens is
  scrolled; any cell is reachable by scrolling plus at most one press; no **Move**, arrows or **Done**
  on any lens screen; the rows of an invented table; pages with no table, no mark and no figure.
- **P2 — Fuller tiles, sources on their own, and Earlier (§1, §2, §5).** Headless:
  `HUDReadingRows` (the 8-line rule, the join, the stride cut removed), a pure `LensSourceTile` that
  takes the `Source:` markers out of the answer's text for the lens with `CitationLineParser`, the
  builder's source tile and Earlier heading. Tests: the photo's two answers as fixtures (with invented
  model and page names), streaming stability, a sentence that runs one word over, an answer with two
  sources, a source in mid-sentence, a source with no page, the caps (`maxRows`, `maxCharacters`) with
  taller tiles.
- **P3 — A button row that fits (§3).** Headless: `LensButtonRowBudget` with a provisional advance (from
  the simulated Display's 576 px column and the photos), the reading view's three-button rule, follow-ups
  only on Actions and by voice, the short-label table, the rule that Close is never dropped, and a test
  that runs every lens button row (reading view, card, Actions, page view, reading mode) through the
  budget in every one of the 13 complete languages, longest labels first.
- **P4 — The answer stays (§4).** Headless: no idle timer for the reading view (the setting, default
  Until closed), "show that again" for the conversation's life, the hide words, the clearing rules
  unchanged (`LensConversationLog`), and a test that the paged card's 60 s is untouched.
- **P5 — Measure on the simulated Display.** Through MG P1's lane: the advance per character of a
  button label and the button's padding (to fix the P3 budget), an 8- and 9-line tile with the question
  line, the source tile, a 3-button row in the longest language, the whole page fitted, fit width and a close-up with both
  halves of a wide table, the rows view, and the fit-check screen (the simulator must read 12 and three tiles side by side). Evidence into the worktree's gitignored folder as before.
- **P6 — Swipe and pinch (§7).** TestFlight only, `DAT_EXPERIMENTAL`, added to
  `DATExperimentalGuardTests`' roster. Takes over MG P5.
- **P7 — Catalog sync.** The new strings ("Earlier — press to open", the source tile's label if any,
  Keep answers up and its two choices, the short labels) in the 13 complete languages, add-only.
- **P8 — Device pass.** Takes over MG P6. On a Ray-Ban Display, with the tester at a real unit:
  the fit check; a cited table opens whole with its row highlighted and readable in words, and one pinch reads the row closely; any cell is reached by scrolling plus at
  most one press, counted from the page report, against today's count; **Rows** read at arm's length;
  a close-up's right half by scrolling; an 8- and 9-line tile reads whole; the source tile; the row of
  three buttons in the longest language; the answer still there after 10 and 30 minutes with the lens
  asleep; Meta's display gesture hides it and brings it back as left; "show that again" after Close;
  the glasses' battery over an hour with an answer held up.

## Decisions

1. **Tile height.** *Taken 2026-11-21: 8 lines, joined up to 9.* Recommend 8 lines, joined up to 9. (Alternatives: 6, which keeps more of the next
   tile in view; or no limit below the lens, which risks a tile losing its top.)
2. **Default for keeping answers up.** *Taken 2026-11-21: Until closed, 3 minutes the other choice.* Recommend Until closed on the Meta Display, with 3 minutes as the
   other choice in Display & HUD. (Alternative: a long fixed lifetime, such as 30 minutes, with no
   setting.)
3. **Reopen window.** *Taken 2026-11-21: the whole conversation.* Recommend the whole conversation (cleared by the same rules as
   `LensConversationLog`). (Alternative: keep 10 minutes.)
4. **Follow-ups on the lens.** *Taken 2026-11-21: none in the row; one before Actions when there is no page.* Recommend none in the row: on the Actions screen and by voice. With no
   page, one may sit before Actions. (Alternative: keep two and rely on the width budget alone.)
5. **The tile grid.** *Taken 2026-11-21: off from P0, dropped once P1's close-up lands.* Recommend off by default from P0 and dropped from the lens's page view once P1's
   close-up replaces pointing at a ninth of the page. (Alternative: keep it behind a setting until P8
   shows how it draws.)
6. **How a cited table is read.** *Taken 2026-11-21: whole page with the row highlighted and its words under it; **Rows** one press away.* Recommend the whole page with the row highlighted and its words
   under the picture, and **Rows** (the table as text cards, at that row) one press away when the
   vault holds the table. (Alternative: open straight on **Rows** and skip the picture.)
7. **How "show me the page" opens.** *Taken 2026-11-21 (the owner's approach): the whole page, the answer highlighted, the rest dimmed, its words under it, one pinch for the close-up.* Recommend the whole page with the answer highlighted, the rest
   dimmed, its words under the picture, and one pinch for a readable close-up of the highlight
   (owner's suggestion). (Alternative: open at fit width already scrolled to the part. That gives
   readable text with no press, but the wearer loses the overview and has asked for the whole page.)
8. **The TestFlight lane.** *Taken 2026-11-21: build P6 now.* Recommend building P6 now so the mapping is ready when Inputs becomes
   stable: left and right for the halves and the next page, and `back` never consumed. (Alternative:
   wait for Meta.)
9. **Ask Meta.** *Declined 2026-11-21: no request; Meta will provide these when it decides to.* Recommend filing §8's request once P1 is built, from the owner's account.
10. **The picture factor until a fit check.** *Taken 2026-11-21: 1.* Recommend 1: single pictures already look right on the
   tester's glasses, and only rows of pictures misbehave, which P0 removes. The fit check then confirms
   it or sets a factor. (Alternative: guess a factor from the photos; not worth it, since a wrong one
   would make every picture smaller than it needs to be.)

## Tests and checks

Every phase headless except P0's one reading, P5, P6 and P8. Release build before each PR. No tester names, real
customers' products or source repositories in fixtures, PRs or commits. Plan status and this index row
updated in the PR that builds each phase.
