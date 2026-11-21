# Plan MU — The Lens Read at Work (fuller tiles, sources on their own, fewer buttons, an answer that stays until you put it away, and a page that opens whole)

**Status:** 📝 Drafted 2026-11-21; nothing built; 9 decisions with recommendations.
**Track:** Display (Meta Ray-Ban Display through the stable `MWDATDisplay`; DAT 1.1.0, adopted on
`chore/dat-1-1-0`, adds nothing to the Display). The reading view (Plan MG §2), the answer card's
lifetime (Plan KP §3, MG decision 4) and the page view (Plan KV, MG §4). P0–P3 are headless. P4 runs
on the iOS Simulator against Meta's simulated Display. P5 is TestFlight only, P6 is the catalog sync,
and P7 needs the glasses.
**Source:** a Ray-Ban Display tester's notes and photos taken through the lens, 2026-11-21, on a build
with Plan MG P2–P4 and PRs 1137–1139. The pinned `MWDATDisplay` and the 1.1.0 `MWDATInputs`
interfaces, read 2026-11-21. Plan JV's first probe run on a Ray-Ban Display (PR 1155).
**Related:** Plan [MG](MG-reading-the-conversation-on-the-lens.md) (the reading view, the tile grid,
the strip, "show that again", P5 and P6, which this plan's P5 and P7 take over), Plan
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
   **Close**, not the whole page.

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
because P1 measured that a box taller than the lens loses its top, and four lines (about 160 px) was
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

**"Show me the page" drew one tile, not the grid.** The only page view whose buttons are exactly
**Next diagram ›** and **Close** is the whole page as a 3 × 3 tile grid (`HUDPageScreenBuilder.items`
with `showsTiles`, MG decision 7). On the simulated Display the grid is three 186 px tiles across. The
photo shows one tile's ninth of the page filling the view, cut off on the right, with empty card space
under it. On the glasses, then, tiles are drawn or laid out differently from the simulator (MG P6
already lists tile size as a device check). The page report doesn't record the drawn tile sizes, so we
can't tell yet whether the row is wider than the lens, the images are scaled up, or the row wraps into
one column.

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
   from its characters with an advance measured in P4, plus the button's padding and the row's gaps,
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
6. **The page opens whole (§6).** "Show me the page" opens on **one picture of the whole page**,
   fitted to the picture box, as Pages mode always has, instead of the tile grid. The grid is off by
   default until P7 shows it works on the glasses (decision 5). From the whole page:
   - **When the answer cites a figure or table**, the first button is that part's name or **Part**,
     which opens it as a **strip at a readable zoom** (`LensPageTiles` strip, the right column of the
     page for its rows). The band's up and down swipes scroll the strip with no send (MG P1: about
     one slice per move). The strip's width is the part's width, so a table is never cut on the right
     unless it is wider than the lens can read. Then the strip is the part's left half and **→**
     shows the right half (one send).
   - **Read it** stays where the page has the cited passage (reading mode).
   - The zoom rungs (**Zoom in**, **Zoom out**, **Move** and the arrows) leave the lens's button row
     and stay by voice: "zoom in", "zoom in on the bottom right", "zoom out", "whole page", "move
     left". The voice words are MG's combined zoom words, unchanged.
   - The row is then at most **Part**, **Read it** or **Next page ›**, and **Close**, held to §3's
     budget. **Next diagram ›** moves to voice and Actions.
   - The page report (`LensPageReport`) records each view's drawn picture and tile sizes, the row's
     estimated width, and what the lens scrolled to, so the next support report says what the glasses
     drew.
7. **Swipe and pinch in the TestFlight lane (§7, P5).** Under `DAT_EXPERIMENTAL` only, in
   `Sources/Glasses/Experimental/`: on a strip, band `nav` **left/right** move the strip half a column
   (one send). `select` with no focused button toggles between the whole page and the cited part at
   readable zoom. Up and down stay the lens's own scroll, and `back` is never consumed. This lane is
   ready to move into the store build if Meta makes `MWDATInputs` stable. Until then the store build
   keeps §6's voice and buttons. Free drag and pinch-to-zoom are not attempted: Inputs doesn't report
   them (decision 8).
8. **Ask Meta (§8).** File one request in Meta's DAT repository's discussions for: an image view
   the wearer can zoom and pan with Meta's own gestures, horizontal scroll, and app-visible double tap.
   This is a request, not a dependency. No source repositories are named in it, and nothing is
   assumed about when Meta will answer.

**Out of scope:** keeping the lens awake (MG §8 decided against a keep-awake loop; this plan only
stops clearing the view), the phone's own page viewer, Even's lens (its paged card and 60 s are
unchanged), live-mode answer cards beyond what the reading view already shows.

## Phases

- **P0 — Fuller tiles, sources on their own, and Earlier (§1, §2, §5).** Headless:
  `HUDReadingRows` (the 8-line rule, the join, the stride cut removed), a pure `LensSourceTile` that
  takes the `Source:` markers out of the answer's text for the lens with `CitationLineParser`, the
  builder's source tile and Earlier heading. Tests: the photo's two answers as fixtures (with invented
  model and page names), streaming stability, a sentence that runs one word over, an answer with two
  sources, a source in mid-sentence, a source with no page, the caps (`maxRows`, `maxCharacters`) with
  taller tiles.
- **P1 — A button row that fits (§3).** Headless: `LensButtonRowBudget` with a provisional advance (from
  the simulated Display's 576 px column and the photos), the reading view's three-button rule, follow-ups
  only on Actions and by voice, the short-label table, the rule that Close is never dropped, and a test
  that runs every lens button row (reading view, card, Actions, page view, reading mode) through the
  budget in every one of the 13 complete languages, longest labels first.
- **P2 — The answer stays (§4).** Headless: no idle timer for the reading view (the setting, default
  Until closed), "show that again" for the conversation's life, the hide words, the clearing rules
  unchanged (`LensConversationLog`), and a test that the paged card's 60 s is untouched.
- **P3 — The page opens whole (§6).** Headless: whole-page opening without tiles (tiles behind the
  setting, off), the cited part's button and strip at readable zoom, the strip's width from the part,
  the right half for a wide table, the zoom rungs off the row and kept by voice, and the page report's
  new fields.
- **P4 — Measure on the simulated Display.** Through MG P1's lane: the advance per character of a
  button label and the button's padding (to fix the P1 budget), an 8- and 9-line tile with the question
  line, the source tile, a 3-button row in the longest language, the whole page fitted, the strip of a
  wide table. Evidence into the worktree's gitignored folder as before.
- **P5 — Swipe and pinch (§7).** TestFlight only, `DAT_EXPERIMENTAL`, added to
  `DATExperimentalGuardTests`' roster. Takes over MG P5.
- **P6 — Catalog sync.** The new strings ("Earlier — press to open", the source tile's label if any,
  Keep answers up and its two choices, the short labels) in the 13 complete languages, add-only.
- **P7 — Device pass.** Takes over MG P6. On a Ray-Ban Display: an 8- and 9-line tile reads whole; the
  source tile; the row of three in the longest language; the answer still there after 10 and 30
  minutes with the lens asleep; Meta's display gesture hides it and brings it back as left; "show that
  again" after Close; the whole page fitted; a strip scrolls with swipes; the tile grid as it really
  draws (from the new report fields), to decide decision 5 for good; the glasses' battery over an hour
  with an answer held up.

## Decisions

1. **Tile height.** Recommend 8 lines, joined up to 9. (Alternatives: 6, which keeps more of the next
   tile in view; or no limit below the lens, which risks a tile losing its top.)
2. **Default for keeping answers up.** Recommend Until closed on the Meta Display, with 3 minutes as the
   other choice in Display & HUD. (Alternative: a long fixed lifetime, such as 30 minutes, with no
   setting.)
3. **Reopen window.** Recommend the whole conversation (cleared by the same rules as
   `LensConversationLog`). (Alternative: keep 10 minutes.)
4. **Follow-ups on the lens.** Recommend none in the row: on the Actions screen and by voice. With no
   page, one may sit before Actions. (Alternative: keep two and rely on the width budget alone.)
5. **The tile grid.** Recommend off by default from P3, behind the page view's own setting, until P7
   shows how it draws on the glasses. (Alternative: remove it.)
6. **Where "show me the page" opens when the answer cites a part.** Recommend the whole page, with the
   part one press away. This matches PR 1138's "opens whole". (Alternative: open straight on the part
   as a readable strip, with **Whole page** one press away. That is quicker for a table, but it is
   what the tester's photo looked like, and what they called a corner.)
7. **The zoom rungs.** Recommend voice only, off the lens's buttons. (Alternative: keep **Zoom in** on
   the whole page as the third button when there is no cited part.)
8. **The TestFlight lane.** Recommend building P5 now so the mapping is ready when Inputs becomes
   stable. Left and right pan, `select` toggles whole page ↔ part, and `back` is never consumed.
   (Alternative: wait for Meta.)
9. **Ask Meta.** Recommend filing §8's request once P3 is built, from the owner's account.

## Tests and checks

Every phase headless except P4, P5 and P7. Release build before each PR. No tester names, real
customers' products or source repositories in fixtures, PRs or commits. Plan status and this index row
updated in the PR that builds each phase.
