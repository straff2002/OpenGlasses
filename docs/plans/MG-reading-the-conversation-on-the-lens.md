# Plan MG — Reading the Conversation on the Lens (bigger pages now, then the answer and the ones before it in one view you scroll, and a page you zoom by pointing)

**Status:** 📝 Drafted 2026-11-18. Nothing is implemented. P0, bigger pages, is small and headless and can
ship on its own. P1 is a measurement on the simulated Display, and it decides how P2–P4 are built.
8 decisions are open.
**Track:** Display (Meta Ray-Ban Display through the stable `MWDATDisplay` 1.0.1). Every Direct-mode and
live answer on the lens, and the manual-page view. P0, P2 and P3 are headless. P1 and P4 run on the
iOS Simulator against Meta's simulated Display (Plan KV's P4 lane). P5 is TestFlight only, and P6 needs
the glasses.
**Source:** feedback from a Ray-Ban Display tester on TestFlight build 717 (2026-11-18). Meta's developer
docs, checked through Meta's docs server on 2026-11-18, and the pinned 1.0.1 `MWDATDisplay` interface.
**Related:** Plan [KP](KP-answers-you-can-act-on.md) (the answer card, the pager, the band check, the
60 s card lifetime), Plan [KV](KV-the-page-on-the-lens.md) (the page view, `LensPageFrame`, the
four-button rule, reading mode, the simulated-Display lane), Plan [LC](LC-the-lens-made-ready.md) (the
thumbnail on the first page, live answers on the card), Plan [BP](BP-web-hud-mirror.md) (the web
mirror), Plan [JV](JV-dat-experimental-testflight-lane.md) (Inputs, TestFlight only), Plan
[LU](LU-private-conversation.md) (private conversations), Plan [AG](teleprompter.md) (where the 4 × 32
geometry comes from).

---

## Why

The tester called the Display a selling point: technicians in gloves can follow the conversation
without taking the phone out. In their words, the answer is useful to see while working. They raised
four things:

1. **Answers arrive one or two lines at a time.** Each page is behind another Next gesture, and long
   answers are hard to follow.
2. **Nothing goes back.** There is no way to reread an earlier answer on the lens. They want to scroll
   the conversation up and down, the way Meta's own assistant does on the Display.
3. **Zoom and pan should be gestures.** Inspecting tables, diagrams and pictures needs quick zoom and
   pan.
4. **They haven't seen a manual page on the glasses yet.** The ask was "show me the page", and nobody
   has tried Plan KV on a real Display.

## What the tester sees, and why

**Pages are so short because of where their size comes from.** `HUDAnswerCard.activeGeometry()` gives
the pager `TeleprompterPaginator.Geometry.raybanDisplay`, which is 4 lines × 32 characters. That is the
teleprompter's own guess (Plan AG). `HUDAnswerPager` then spends lines on the frame:

| Page | Lines the geometry gives | Taken by | Lines of answer |
|---|---|---|---|
| a single-page answer | 4 | nothing | 4 |
| the first of several | 4 | the "1/3" footer and the "You: …" question (KV §7) | **2** |
| any later page | 4 | the footer | **3** |

A 600-character answer is about 20 display lines, so it comes out as 7 pages and 6 Next presses. Every
press is a fresh `send()` over Bluetooth. The lens has room for far more. `LensPageFrame` measured the
frame on the simulated Display in KV P4: a body line is 38 px, a meta line 30 px, the button row 88 px
and the gaps 6 px. On that budget, KV's reading mode already pages at 10 lines (9 of text and the
footer). Its own note says 4 × 32 "left a reading page two lines of text and the top of the lens
empty". The answer card never took the same budget.

**Going back.** KP P1 put ‹ Back on middle pages, so the wearer can go back *within* an answer. When a
new answer arrives, the old one is gone from the lens. `HUDAnswerCard` holds one answer and keeps no
history. The card also clears after 60 s without a press (`defaultIdleLifetime`).

## What Meta's platform allows (checked 2026-11-18)

Each claim below was checked against Meta's docs (DAT v1.0 and the Web Apps corpus) and against the
pinned SDK's interface. Two of the claims the plan started from were wrong, and the design follows
from the corrections.

| What we assumed | What the docs and the SDK say |
|---|---|
| The stable Display has no scroll container. | **Half right.** There is no scroll component (the views are `FlexBox`, `Text`, `Button`, `ButtonGroup`, `Image`, `Icon`, `VideoPlayer`). But the iOS guide says: *"Views are presented one at a time with vertical scrolling. Horizontal scrolling is not supported."* KV P4 saw it happen: a 750 px page-view frame scrolled on the simulated Display. A view taller than the lens scrolls vertically. The docs don't say what drives the scroll (focus moving from one control to the next, or a free swipe); **P1 measures it.** |
| Band input reaches the app only as button focus and press. | **Wider than that.** Stable 1.0.1 also has `FlexBox.onTap` (*"Make any component tappable"*), so a block of text can take focus and a press, not only a `Button`. The app is still told only about presses: focus moves are never reported. Only a `Button` can carry `.actionRole(.primary)`, the control focused when a view renders. |
| Back ends a Display session and is not delivered to the app. | **Confirmed.** Back is *"a two-finger tap on the … temple"* and *"ends the display session"*. The docs add: *"Always have a root view … Back from L0 ends the session."* Meta's issue tracker reports that `consumeBack` doesn't help in 1.0.x. |
| The lens dims at 20 s without input and sleeps at 25 s. | **Confirmed**, with one addition that matters: *"Display sleep does not end a … session. When the display wakes, your app can either show the previously displayed content or send a new view."* A view that sleeps comes back as it was. |
| Raw nav and drag input exists only in experimental `MWDATInputs` (Plan JV). | **Confirmed.** `Inputs` carries `nav(direction:)`, `select`, `back` and `drag` (`neuralBandDrag`, continuous, with x, y, dx and dy). The docs warn that the wearer's settings can invert swipe directions, so a forward swipe doesn't always arrive as the same direction. |
| The web app surface (`WebHUDRenderer`) gets directional input and can scroll. | **Confirmed, and it offers more:** Chromium spatial navigation, `ScrollView`/`VerticalList` with scroll-to-focus, system Back that follows browser history and that the page can claim, and continuous drag once the page sets `touch-action: none` on `body`. **But** *"Your Web App must be hosted on a publicly accessible HTTPS URL … HTTP-only URLs are not supported."* BP's phone listener is plain HTTP on the LAN, so the glasses can't load it, and BP's mirror has no path back into the app. |
| (not assumed) | *"Each call to `send()` replaces the entire display … no incremental updates."* So every redraw resets focus, and so where the view is scrolled to. Since focus moves aren't reported, the app never knows how far the wearer has scrolled. |

## Options

| | A · Bigger pages | B · "Earlier" on the paged card | C · One view you scroll, native | D · The web app | E · The experimental lane |
|---|---|---|---|---|---|
| What it is | The answer card takes `LensPageFrame`'s budget: 8 lines on page 1 and 9 after, instead of 2 and 3. | A **‹ Earlier** button and a list of past answers, each opening as today's pages. | The answer as a column of tappable rows, taller than the lens, with earlier answers under it. The band moves from row to row and the lens scrolls. | The conversation as a web app with `ScrollView`, Back and drag. | Inputs' `nav` and `drag` map to scroll and pan. |
| Store build | yes | yes | yes (stable 1.0.1 only) | yes, but it needs public hosting | **no**, TestFlight only |
| Rereading earlier answers | no | yes, behind a list | yes, by scrolling | yes | only together with B or C |
| Presses for a long answer | about a quarter of today's | as today | none: swipes | none | none |
| Unknowns | the real line width (KV P5) | none | what drives the scroll, where focus lands, send time for a tall view (P1) | public HTTPS relay, web view lifecycle, battery (BP P3/P4) | JV P3's probe; Meta's own use of the gestures |
| New egress | none | none | none | **the conversation leaves the phone** for a public host | none |
| Size | small | medium | medium | large | small on top of C |

**A** is clearly worth doing, and doing first: the tester gets it in the next build. **B** is safe but
doesn't answer the ask: the tester wants to scroll, not to open a list. **D** would scroll best, but it
needs a public HTTPS host, which means sending the conversation (and cited manual text) through a
relay. That is a new egress, needs a HIPAA exclusion and a licensed-content review, and still leaves
BP's reachability, lifecycle and battery questions open. **E** can never reach store users.

### Recommendation

**A now (P0), then C, measured before it is built (P1–P3), with B as C's fallback.** The docs say the
native lens already scrolls a tall view vertically, and `FlexBox.onTap` lets each row of text take the
band's focus. Together they give a scrolling conversation on the stable SDK, in the store build, with
nothing new leaving the phone. Because the docs leave open what drives the scroll, P1 measures it on
the simulated Display first. If a column of tappable rows does not scroll with focus, P2 builds B
instead, on the same history core. E adds drag on top in flagged TestFlight builds once JV's probe has
run (P5). D is left out (see [What MG leaves out](#what-mg-leaves-out)).

---

## Design

### 1 · Bigger pages (P0)

- **A frame budget for the answer card.** A pure `LensPageFrame.answerGeometry(question:picture:)` gives
  the pager `maxLines` from the same measured budget reading mode uses: 10 on the Meta Display, so a
  paged page holds 9 lines of text and the footer. Page 1 gives up one line to the question (8) and,
  when the turn has a thumbnail (LC §5), the lines its strip takes: at most 209 px drawn plus a gap,
  which is 5 body lines, so 3 or 4 remain. `firstPageReservedLines` already carries the question's line.
  P0 also gives it the picture's lines, and lays out the first page with the picture's reservation
  whenever a picture is staged, so `HUDAnswerThumbnail.fits` keeps passing and the page count stays
  what the wearer turns through.
- **32 characters a line stays.** The character advance is still KP's estimate until KV P5 measures a
  real lens. A wider line is a one-number change once it has been measured.
- **Who it changes.** The Meta Display and the web mirror (which uses the Meta geometry). The Even G2
  keeps 3 × 40. The teleprompter keeps its own 4 × 32. Prepared cards (`PreparedCardHUDBuilder`) keep
  4 × 32 in P0: their stack screens put titles and buttons on the same geometry, so they move only
  after their own budget has been checked against `LensPageFrame`.
- **What stays the same.** Pages are still prefix-stable while an answer streams, the footer, ‹ Back on
  middle pages, the eight-page cap and "… more on phone".
- **Effect.** The 600-character answer goes from 7 pages and 6 presses to 3 pages and 2 presses.

### 2 · The reading view (P2–P3, if P1 passes)

One view per answer on the Meta Display, built from rows the band can step through:

```
You: what size breaker for the condenser        (meta)
┌ For a 3-ton unit on 230 V, the nameplate ┐     row: one paragraph, or ≤ 4 lines of a long one
└ says MOCP 30 A, so a 30 A double-pole…   ┘
┌ Wire it with 10 AWG copper…              ┐     row
[ Page ] [ Actions ] [ Close ]                   the answer's buttons (≤ 4, KV's rule)
Earlier                                          (meta)
┌ You: refrigerant charge for the …        ┐     an earlier turn, collapsed: its question and
└ R-410A, 7 lb 4 oz factory charge…        ┘     its first two lines
┌ You: …                                   ┐
```

- **Rows.** Each paragraph of the answer is a row, a `FlexBox` with `.onTap`. A paragraph longer than
  `rowMaxLines` (4, P1 confirms the number) is split at a sentence, the same way the pager cuts pages
  (`HUDAnswerPager`'s wrap and sentence rule). So each swipe moves a few lines, never a whole screen.
- **Order.** The newest answer is at the top and earlier answers are below it, newest first (decision
  1). The view opens where the wearer starts reading without depending on where focus lands. Chat order
  (newest at the bottom, as in Meta's assistant) works only if P1 shows that the lens opens scrolled to
  a focused `Button` in the middle of a column. P1 measures that too, and decision 1 is taken with the
  result in hand.
- **A press on a text row** says that paragraph again, from there to the end of the answer (decision 3):
  in a noisy plant room, that is the part the wearer missed. On an earlier turn's row, a press opens
  that turn at the top of the view, whole, with **‹ Latest** in its buttons.
- **The buttons** are the answer's own: **Page** first when the turn staged a page (it moves out from
  behind Actions; see §5), up to two follow-ups, **Actions** (KP's Actions screen, unchanged) and
  **Close**. The row is capped at four by KV's rule.
- **Earlier** holds this conversation's last 10 answers (decision 2). Each is collapsed to its question
  and first two lines and opens whole on a press.
- **Streaming.** A redraw resets focus and the scroll position, and the app can't see where the wearer
  is. So a pure `ReadingRedrawPolicy` decides when to send: the first draw happens once a paragraph has
  settled (as the card waits for a settled page today), more draws happen as paragraphs settle while the
  answer is still streaming, and the final draw happens when the text is complete. After that, the view
  is redrawn only on a press, on a new answer, or when the lens comes back. Answer text usually
  finishes long before the speech does, so the wearer is still at the top when the last draw lands.
- **Lifetime.** The app can't see scrolling, so KP's 60 s without a press would clear a view the wearer
  is still reading. The reading view lasts 3 minutes without a press (decision 4). The lens itself still
  dims at 20 s and sleeps at 25 s, and the docs say the view comes back as it was on wake.
- **Size cap.** At most `maxRows` rows and `maxCharacters` characters in one send (P1 measures send time
  against size and sets both). Past the cap, the oldest earlier turns drop off the view first, then the
  answer ends in "… more on phone", as now.
- **Back.** It ends the session, and the app never hears it. **Close** stays on every view. "Show the
  conversation" (voice), the phone preview and the next answer bring it back.
- **Voice.** A strict whole-utterance parser, `HUDReadingCommand`, in the style of `HUDPageCommand`:
  "earlier" or "previous answer" opens the turn before the one at the top; "latest" goes back to the
  newest; "show the conversation" opens the view; "say that again" is Repeat. Longer sentences go to the
  model, as they do now.
- **Gloves.** Everything in the view works from the Neural Band (it reads the wrist, so gloves don't
  matter) and by voice. Nothing depends on the temple touchpad, whose two-finger tap is Back.
- **Pages or scroll.** The reading view becomes the Meta Display's default, with **Pages** as a choice
  in Display & HUD for wearers who prefer pages (decision 5). The Even G2 keeps pages and gets
  "previous answer" by voice. The web mirror draws the rows as a column; its page already scrolls.

**If P1 fails** (a tall column doesn't scroll with focus, or tappable rows don't take a visible focus),
P2 builds the same history as B: **‹ Earlier** on an answer's first page opens a list of the earlier
turns (four to a screen, KV's rule), and each opens as P0's bigger pages.

### 3 · The history core

`LensConversationLog` is pure and in memory only. It is a ring of finished turns: the question, the
answer text, the follow-ups, whether the turn staged a page, and when it was made. It takes in what the
card already receives (Direct-mode turns, live turns through LC's adapter, prepared cards), never
anything else.

- It is **never written to disk** and never goes to a model, to memory, to BrainStore or into the
  support report. The report gets counts only: rows, sends, bytes, send times.
- It is cleared when the conversation ends, when a private conversation ends (Plan LU), when the HUD is
  turned off, and when glasses or the Display disconnect for longer than the card's lifetime.
- It holds only what the lens already showed. So it adds no new place where conversation text lives
  after the conversation ends.

### 4 · Zoom and pan, quicker (P4)

Today, every view change is a press and a new picture. From the whole page, getting to the bottom
right of a table takes **Zoom in**, then focus to **Move** and a press, then focus to **→** and a
press, then focus to **↓** and a press: about seven band actions, with each frame rendered and sent.
On the stable lane, P4 makes it quicker in four ways, each kept or dropped by what P1 measured:

- **Point to zoom.** The whole page (and any view short of the cap) is drawn as a grid of tappable tiles
  (3 × 3 by default), each a `FlexBox` with `.onTap` holding its slice of the picture. A swipe moves
  focus across the tiles and the focused tile glows. A press zooms two rungs into that tile's centre.
  The bottom right of a table is then two swipes and a press. It needs DAT to move focus across a row
  as well as down a column, and the glow to show on an image. P1 checks both, and decision 7 takes the
  result.
- **Vertical pan with no send.** When zoomed, the view draws the crop's whole column of the page (the
  crop's width, the page's height at that zoom, up to `maxStripHeight`) as stacked tappable slices.
  Swiping scrolls down the page on the lens itself, and only left, right and zoom need a new frame. Then
  **Move**'s arrow row drops to ← · → · Done.
- **Frames ready before the press.** A pure `LensPageViewport.neighbours()` lists the views one press
  away (the next rung in and out, each move). The session renders them off the main actor while the
  wearer looks, so a press only sends. The report logs render time and send time per frame, to show
  which one dominates.
- **Words that combine.** "Zoom in on the bottom right", "zoom into the table", "closer at the top":
  a corner or area word with a zoom, in one utterance (`HUDPageCommand`, still whole utterances only).

Tables keep KV's behaviour of opening on the table's area. Holding a table's header row in place while
its body scrolls is left out (below).

### 5 · Finding "show me the page"

The tester hasn't seen it. **Page** sits on KP's Actions screen, one press deep, and only when the turn
staged a page. In the reading view, **Page** is the first button of an answer that has one (§2), and
P0's pages put it on the last page beside the follow-ups when the turn staged one (replacing the second
follow-up, which moves to Actions). P6's script starts with "show me the page".

### 6 · The experimental lane (P5, flagged TestFlight builds only)

Only after JV P3's probe shows which events reach the app without Meta also acting on them:

- `drag` pans the page view continuously, limited to about 4 frames a second, with the zoom kept;
- `nav(.left/.right)` steps the page view without the arrow row;
- nothing else is mapped. Back stays Meta's (`consumeBack: false`, JV's rule).

The code goes under `Sources/Glasses/Experimental/` inside `#if DAT_EXPERIMENTAL` and is listed in
`DATExperimentalGuardTests`' roster. A store build has the stable view and nothing more.

## What MG leaves out

- **The web app surface.** It would scroll and take drag, but the glasses load only public HTTPS URLs.
  Serving the conversation from a public host is a new egress for conversation text and cited manual
  pages, so it would need its own plan: hosting, a relay or push, its own consent, a HIPAA exclusion,
  and a licensed-content review. BP's P3/P4 questions come first.
- **Pinch and free pan in the store build.** The stable SDK delivers presses, and focus moves the app
  never sees. Continuous drag exists only in Inputs (P5).
- **Horizontal scrolling.** The lens doesn't do it (*"Horizontal scrolling is not supported"*). Wide
  tables pan by frames.
- **A table's header row held in place while its body scrolls.** It needs table structure on the lens,
  not a picture. That is a plan of its own once tables have been tried on the glasses.
- **Keeping the lens history after the conversation ends.** The phone's conversation view keeps it.

## Decisions (open)

1. **Order in the reading view.** *Recommended:* newest answer at the top, earlier ones under it. The
   alternative is chat order (newest at the bottom), and only if P1 shows the lens opens scrolled to a
   focused button in the middle of a column.
2. **How much history.** *Recommended:* the last 10 answers of this conversation, in memory only,
   cleared as in §3. The alternatives are the whole day, or kept across launches.
3. **What a press on a text row does.** *Recommended:* say it again from that paragraph. The
   alternatives are opening the answer's Actions, or nothing (the rows only scroll).
4. **The reading view's lifetime.** *Recommended:* 3 minutes without a press. The alternative is KP's
   60 s.
5. **Scroll or pages by default.** *Recommended:* scroll on the Meta Display, with **Pages** in Display
   & HUD. The alternative is pages by default and scroll as the choice.
6. **Delivery.** *Recommended:* P0 as its own PR now, so the tester's next build has bigger pages, then
   P2–P4 in one PR after P1. The alternative is everything in one PR after P1.
7. **Point to zoom.** *Recommended:* if P1 shows tiles take a visible focus, the tile grid replaces
   **Zoom in** on the whole page (one press on the focused tile does what Zoom in did, and more). The
   alternative is the grid as an extra **Point** button, with **Zoom in** kept.
8. **The web app surface.** *Recommended:* not now (above). The alternative is a plan of its own, drafted
   after BP P3.

## Phases

### P0 — bigger pages (headless)

`LensPageFrame.answerGeometry(question:picture:)`; `HUDAnswerCard.activeGeometry()` uses it on the Meta
Display and the web mirror. The first page's reservation covers the question and a
staged picture. **Page** moves to the last page when the turn staged one (§5). The LC thumbnail note and
`HUDAnswerThumbnail.fits` are updated for the new budget.

Tests: the page counts and line counts for single, paged, questioned and pictured answers at the new
geometry; Even unchanged; prefix stability while streaming kept; the fullest first page with a picture
still fits (`fits` passes); the 600-character fixture is 3 pages. Then the full suite and a Release
build. The new **Page** placement adds no strings.

### P1 — measure on the simulated Display (development only, iOS Simulator)

A **Tall views** set in Developer › Simulated Display (KV's P4 lane, `#if DAT_MOCK_DISPLAY`, never
archived). It measures:

1. a column of 30 tappable text rows (about 1,500 px tall): does a directional move step the focus from
   row to row, does the lens scroll with it, and does the focus show on a tappable `FlexBox`;
2. where focus and scroll land on a send: with no primary button, with a primary `Button` at the top,
   and with one in the middle of the column;
3. send time against size, at 10, 30 and 60 rows and 1, 3 and 6 thousand characters;
4. a 3 × 3 grid of tappable image tiles: does focus move across rows as well as down them, does the
   glow show on an image, and how does `.fill` size an image in a row;
5. a stack of image slices up to three lens heights: the drawn size and the send time.

The results are written into this plan as **Measured (P1)** and fix §2's and §4's numbers, decision 1's
premise and decision 7's premise. The simulator is not the glasses: P6 checks every result again.

### P2 — the reading view's core (headless)

`LensConversationLog` (§3); a `HUDBlock` (a tappable block of lines with an id) in the SDK-free DSL;
`HUDReadingRows` (paragraph rows, split by the pager's wrap and sentence rule); `HUDReadingViewBuilder`
(state to screen: the question, the rows, the buttons, Earlier, an opened earlier turn, the caps);
`ReadingRedrawPolicy`; `HUDReadingCommand`. Or, if P1 failed, B's **‹ Earlier** list on the same log.

Tests (about 30): row splitting and stability as the text streams; the order, the caps and the drop
order; collapsed and opened earlier turns; the four-button rule; redraws only at settle points, at the
end and on a press; clearing on every §3 event; the parser's whole-utterance rule; a private
conversation leaves nothing in the log.

### P3 — the reading view on the lens (headless, wired; simulated-Display walkthrough)

`MetaDisplayBackend` maps `HUDBlock` to a `FlexBox` with `.onTap`; Even draws its lines; the web mirror
draws a column. `HUDAnswerCard` uses the reading view on the Meta Display while **Pages** is off, with
the 3-minute lifetime; the phone preview shows the same view; Display & HUD › **Answers on the lens:
Scroll / Pages**. The support report gets counts and times only. The walkthrough is re-run on the
simulated Display and its screenshots are reviewed before the PR. The new strings get a catalog sync,
in this PR or right after it.

### P4 — zoom and pan quicker (headless; simulated-Display walkthrough)

§4, as far as P1's results allow: the tile grid, vertical pan by native scroll, frames rendered ahead,
and combined words. Tests cover the tile geometry (every tile maps to a crop inside the page, with
two-rung zoom clamped at the cap), the strip slices, the neighbour list, and the new words.

### P5 — drag and nav in flagged builds (TestFlight only; after JV P3)

§6. Owed to JV's probe results.

### P6 — device pass (the tester's Display; folded in with KP P6, KV P5 and LC)

Script: "show me the page" on a manual with a diagram and a table; a long answer read by scrolling; two
earlier answers reread; point to zoom into a table's corner; gloves on; daylight; the lens left to dim
and sleep mid-read, then woken; Back pressed mid-read, then the view brought back by voice; a private
conversation, checking its answers are gone from Earlier afterwards. The tester reports what Meta's
assistant does that this still doesn't.

**Gates for each PR:** the full suite and a Release build green; `SWIFT_EMIT_LOC_STRINGS=NO` for
throwaway builds; strings synced to the catalog; no plan letters or beta wording in the UI;
`DATExperimentalGuardTests` green (P5); the support report checked for counts only.

## Acceptance

- A 600-character answer reads in 3 pages with P0, and in one view with no Next after P3.
- Any of this conversation's last 10 answers can be reread from the lens with the band alone, in two
  moves or fewer from the newest.
- From the whole page, reaching the bottom right of a table takes at most three band actions.
- Nothing new leaves the phone, and the lens history is gone when the conversation ends.
- The store build calls no experimental API.

## Open

- What drives the native scroll, and where focus lands after a send (P1, then P6).
- The real character advance on the lens (KV P5), which could widen lines past 32.
- Whether a new `send()` wakes a sleeping lens (unconfirmed; dat-conventions). If it doesn't, a redraw
  after sleep waits for the wearer's next input.
- Whether the Display session survives the wake word holding the glasses mic (a known Meta field
  report). A reading view that ends while the mic is open is that, until shown otherwise.
