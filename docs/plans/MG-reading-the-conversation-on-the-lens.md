# Plan MG — Reading the Conversation on the Lens (bigger pages now, then the answer and the ones before it in one view you scroll, and a page you zoom by pointing)

**Status:** 🚧 P0 built 2026-11-18 (headless): the answer card takes the lens's measured budget, so a
600-character answer is 3 pages instead of 7, and **Page** sits on the last page. "Show that again"
brings the last answer back to the lens by voice after the glasses' Back gesture, Close or its lifetime
(§7). §8 records what a send does to a dimmed or sleeping lens as a device check, with no keep-awake
loop. P1, a measurement on
the simulated Display, is next, and it decides how P2–P4 are built.
All 8 decisions taken 2026-11-18 as recommended ("take all eight recommendations").
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

### 7 · Bringing the lens back hands-free (P0)

Reopening is the tester's top ask. Today the glasses' Back gesture (a two-finger temple tap) ends the
display session, and nothing brings the answer back but a new question or the HUD switch on the phone.
A gloved technician needs the way back to be by voice.

- **The words.** "Show that again", "show it again", "show me the answer", "back to the answer", "show
  the conversation", "bring it back", and a few close variants (`HUDReopenCommand`). They match the whole
  utterance only, with a leading filler ("ok", "hey") and a trailing "please" allowed, so a real
  question is never taken: "can you show that again on the phone" goes to the model. None of them is a
  page-view, paging or task word, and a test keeps it that way.
- **What comes back.** The last answer card, on the page the wearer was reading (not its Actions
  screen), with its question and follow-ups. It is a frame the wearer asked for, so it opens a lens they
  dismissed with Back. The card the Back gesture left held comes back as it is. A card that **Close** or
  its 60-second lifetime cleared is kept in memory for 10 minutes and comes back from there. A new
  answer replaces it.
- **When the words go on.** With no answer to bring back, the HUD off, or a task card or a menu on the
  lens, nothing is taken and the words reach the model as an ordinary request. With the page view open
  over the answer, "back to the answer" closes the view back to the card.
- **The private conversation (Plan LU).** When it ends, the kept card is forgotten, and a card on the
  lens is not kept when it closes, so these words never bring a private answer back.
- **Once the reading view exists (P3),** the same words open it at the wearer's last position instead of
  the paged card.
- **Spoken words only.** Text typed on the phone never reaches the lens's voice commands, so a typed
  "show that again" is a message to the assistant, as a typed "menu" is today. Bringing the lens back is
  a hands-free action. The phone already has the HUD switch.
- **Not changed.** The launcher's own words and the router are untouched, and the green mark at the top
  of an empty chat on the lens stays as it is.

### 8 · When the lens dims and sleeps

Meta's docs say the lens dims after 20 s without input and sleeps at 25 s. Sleep does not end the display
session, and on wake the app may show what was there or send something new. No API reports dimming or
sleep, or controls them. Two things are unknown and decide how §7 behaves after sleep:

1. Does a `send()` to a dimmed or sleeping lens wake it?
2. After the wearer wakes the lens by touch or pinch, is our last frame still on it?

Until P6 answers them, "show that again" draws the card again when it is already the frame on the lens.
That is harmless if the content survived sleep, and it is the only redraw that can wake a lens that
keeps nothing. If P6 shows the frame survives and a send does not wake the lens, the redraw stays: the
wearer's next input shows it. If a send does wake the lens, the redraw is the wake.

**No keep-awake loop.** Nothing sends to the lens on a timer to keep it from dimming or sleeping. A send
happens only when the wearer asks, an answer arrives, or a press changes the screen. Dimming is Meta's
power and privacy behaviour, and a timer that defeats it would also cost battery and heat.

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

## Decisions (taken 2026-11-18: every recommendation below, "take all eight recommendations")

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

**As built (P0).**

- **The geometry.** `LensPageFrame.answerGeometry` is a property, not `answerGeometry(question:picture:)`:
  the question and the picture stay first-page reservations, as the question already was. It shares
  reading mode's budget function (the two frames are the same shape: a meta line over page 1, body
  lines, a meta footer, the button row), so it is 10 × 32, derived and not written down: a paged page
  holds 9 lines of text and the footer, 8 under the question; a single page 10, 9 under the question
  (`HUDTextShaper.maxBodyLength`, 120 characters, keeps a real single page far shorter).
  `HUDAnswerCard.activeGeometry()` returns it on the Meta Display and in the phone-only build (the web
  mirror); Even keeps `.evenG2`. `TeleprompterPaginator.Geometry.raybanDisplay` is untouched.
- **Who stays on 4 × 32.** A new `HUDAnswerCard.activeTeleprompterGeometry()` is the old behaviour, and
  the three other callers of `activeGeometry()` now read it: `HUDRouter.cardGeometry` (the prepared-card
  stack), `PreparedCardGlances.geometry` (the glance) and `HUDTurnState.geometry` (the Thinking card,
  which reads only its 32 characters).
- **The picture's lines.** `LensPageFrame.pictureBodyLines(drawnHeight:)` is a picture's drawn height and
  its gap in body lines and their gaps, rounded up; `HUDAnswerThumbnail.firstPageLines(of:)` applies it,
  5 for the 552 × 200 strip (209 px drawn), 3 for a 552 × 100 panorama.
  `HUDAnswerCard.firstPageReservedLines(hasQuestion:picture:geometry:)` is the question's line plus the
  picture's lines beyond the room the geometry already leaves (10 less its `maxLines`): so 5 at the
  lens's 10 lines and none at the teleprompter's 4, which left the strip room of its own (every card
  test that injects 4 × 32 is unchanged). A picture so tall it would leave no line of text beside the
  question and the footer reserves nothing, because `fits` leaves it off. Even draws no pictures, so
  nothing is staged there.
- **When it reserves.** `update()` reads the first page's picture once per layout: before the card is
  first shown, the staged picture if it is still fresh and the backend draws pictures
  (`freshStagedPicture()`, which replaced `takeStagedPicture()`); once shown, the card's own `picture`.
  The card takes exactly the picture it laid out for, so the reservation is constant for the card's
  life and settled pages keep their lines as an answer streams. The fullest first page with the strip —
  the question, 3 lines and the footer; 4 lines and the footer; a single page of 4 or 5 lines — is at
  most 567 px of the 600.
- **One thing the plan didn't name.** A page the pager makes in its paged path that turns out to be the
  only one (no footer) can now hold up to 9 lines, past the 120 characters a backend keeps of one body
  line. `HUDAnswerCardBuilder.page` draws such a page line by line, as a paged page is, so nothing is
  cut; a page within 120 characters is still today's one line.
- **Page on the last page.** `HUDAnswerCardBuilder.page(…, hasPage:)` takes the same
  `hasPage && pageCanOpen()` the Actions screen gets. With a page: first follow-up (if any) · **Page** ·
  Actions · ‹ Back (paged only); the second follow-up moves to the Actions screen ahead of the third,
  and the Actions screen no longer offers Page. Without one, both are exactly as before. A page staged
  while the card is up redraws it on the last page as well as on Actions. The existing `ItemID.page`,
  `HUDAnswerAction.page` and the existing "Page" string and comment are reused: no new strings.
- **The simulated-Display walkthrough's** answer card, three pages at 4 × 32, would have been one page at
  10 × 32; its reply is now about 600 characters, three pages again.
- **Tests.** 20 new, in `LensPageFrameTests` (2), `HUDAnswerPagerTests` (4), `HUDAnswerCardBuilderTests`
  (5), `HUDAnswerFollowUpTests` (3), `LensLiveAndVisionTests` (3) and `LensLiveAndVisionDisplayTests` (3):
  the geometry from the budget, the 600-character fixture (`"word " × 120`, 20 lines: 7 pages at 4 × 32,
  3 at 10 × 32 as 9 · 9 · 2, and 8 · 9 · 3 under the question), every first page at every length fitting
  with the picture, the reservation by question, picture and geometry, prefix stability with the first
  page reserved, a streamed vision answer keeping its picture and its 3-line first page end to end, the
  active geometries by backend, and the last-page and Actions buttons with and without a page for 0–3
  follow-ups. One changed: `LensPageSessionTests.testTheAnswerCardOffersPageWhenItsTurnStagedOne` now
  finds Page on the card's page, not under Actions. The focused classes ran 316 tests and the full suite
  17,935 (16 skipped), all passing; the Release build succeeded.

**As built (P0, bringing the lens back, §7).** `HUDReopenCommand` (in `HUDVoiceCommand.swift`) is the
strict whole-utterance parse. `HUDAnswerCard.reopen()` puts the held card back on its page, or the last
closed one within `reopenLifetime` (10 minutes, in memory only). It calls
`GlassesDisplayService.wearerAskedForAnswerCard()` so a lens dismissed by Back opens again, presents the
card as wearer-led, and restarts its lifetime. `canReopen` says whether there is a card to bring back.
`forgetForReopen()` runs when the private conversation ends. A `hud-answer-reopen` handler in the voice
chain, after the launcher's, takes the words only when the card came back (or, with the page view
over it, closes the view back to the card), so otherwise they go on to the model. `HUDLauncher` and
`HUDRouter` are not changed. `HUDAnswerReopenTests` (15) covers the words and the sentences they must
not take; that none of them is a page, paging or task word; the card back after Back, Close, its
lifetime and from Actions, on its page with its question; the 10 minutes; nothing taken with no
answer, the HUD off or a task card up; a new answer replacing the kept one; a card on the lens drawn
again; and the private conversation's end forgetting a closed, dismissed or showing card while the next
answer is kept again.

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
5. a stack of image slices up to three lens heights: the drawn size and the send time;
6. dimming and sleep (§8) are not measured here: the 1.0.1 Mock Device Kit has no dim or sleep
   control (its glasses fold, unfold, don and doff, and take input and clicks), so what a `send()`
   does to a dimmed or sleeping lens, and what a wake keeps, is P6's.

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
conversation, checking its answers are gone from Earlier afterwards. For §7 and §8: "show that again"
after Back, after Close, after the card's lifetime, and while it is on the lens; the words said inside a
real question ("can you show that again on the phone"), which must reach the model; and, with the card
up, the lens left to dim (20 s) and to sleep (25 s), then (a) "show that again" said, noting whether the
send wakes the lens, and (b) the lens woken by touch and by pinch, noting whether the card is still
there. Those two answers settle §8. The tester reports what Meta's
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
- After Back, Close or the card's lifetime, "show that again" brings the last answer back to the lens
  on the page the wearer was reading, and inside a sentence the same words reach the model.
- Nothing sends to the lens on a timer to keep it awake.

## Open

- What drives the native scroll, and where focus lands after a send (P1, then P6).
- The real character advance on the lens (KV P5), which could widen lines past 32.
- Whether a new `send()` wakes a dimmed or sleeping lens, and whether our frame survives a wake by touch
  or pinch (unconfirmed; dat-conventions; §8; the simulator can't show it, so P6). If a send doesn't wake it, a redraw
  after sleep waits for the wearer's next input.
- Whether the Display session survives the wake word holding the glasses mic (a known Meta field
  report). A reading view that ends while the mic is open is that, until shown otherwise.
