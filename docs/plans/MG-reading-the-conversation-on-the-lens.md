# Plan MG — Reading the Conversation on the Lens (bigger pages now, then the answer and the ones before it in one view you scroll, and a page you zoom by pointing)

**Status:** 🚧 P0 built 2026-11-18 (headless): the answer card takes the lens's measured budget, so a
600-character answer is 3 pages instead of 7, and **Page** sits on the last page. "Show that again"
brings the last answer back to the lens by voice after the glasses' Back gesture, Close or its lifetime
(§7). §8 records what a send does to a dimmed or sleeping lens as a device check, with no keep-awake
loop. **P1 measured 2026-11-18 on the simulated Display:** a tall column of tappable rows scrolls with
focus one row per move, and a press reaches the focused row, so the reading view (C) is buildable. Rows
and tiles must be `.background(.card)` (the only way focus shows), and a row must stay inside the lens.
A send opens scrolled to a primary button anywhere in the column. Focus moves across a tile grid as well
as down it. The mock's input kit moves nothing, and send times over the radio, dimming and sleep stay
P6's. **P2–P4 built 2026-11-18** (headless, with the simulated-Display walkthrough): on the Meta
Display an answer is one view the band scrolls — its rows, its buttons, and this conversation's last
10 answers under them, in memory only — with **Pages** in Display & HUD; a press on a row says it
again from there, a press on an earlier answer opens it with **‹ Latest**, and "earlier", "latest"
and "say that again" work by voice. The page view draws the whole page as nine tiles to point at,
a zoomed view as a strip the lens scrolls, the next views ahead, and takes "zoom in on the bottom
right". P5 waits on JV's probe; P6 is the device pass.
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

**Measured (P1), 2026-11-18.** iOS Simulator (iPhone 17 Pro, iOS 26), the 1.0.1 Mock Device Kit's
simulated Ray-Ban Display, a Debug build of the mock lane. Developer › Simulated Display › **Measure tall
views**, or the launch argument `-AvenkinSimulatedDisplayTallViews`, runs `SimulatedDisplayTallViews`
unattended. It sends `MWDATDisplay` views the HUD's DSL can't express through the HUD's own lens session
(`MetaDisplayBackend.sendMeasurementView`, compiled only under `DAT_MOCK_DISPLAY`, so no second
`DeviceSession`), reads the preview's web view after every move (scroll offsets, the focused element,
what changed, each image's drawn and natural size), and presses the focused element to see whose
handler fires. Results go to the app's Documents/tall-views/ (`results.json`, `tall-views.log`, 53 PNG
snapshots of the preview) and the debug event log.

*The input path.* The Mock Device Kit's input kit moved nothing. Three band and three touchpad
`navDown`s and seven band `select`s left focus, scroll and every handler as they were. The preview's
focus engine listens for the arrow keys and Enter, so every move below is an arrow key sent to the
preview's focused element, and every press is Enter. Enter on a focused box reached the app's `.onTap`
handler through the SDK. So did `sendClick(identifier:)`: the frame gives every tappable `FlexBox` an
identifier (`c<n>_…`, type `flexBox`), as it gives buttons. Whether the band's swipes move focus the way
the preview's arrow keys do is a question only the glasses answer (P6).

1. **A column of 30 tappable rows** (1,560 px; rows 44 px tall at a 50 px pitch).
   - **Focus steps row by row.** Each down move focused the next row: 29 moves reached row 30, and
     further moves stayed there. Up moves stepped back. After every move, Enter fired exactly the
     focused row's handler.
   - **The lens scrolls with focus.** It doesn't scroll for the first 8 moves. From the 9th it scrolls
     one row (50 px) per move and holds the focused row with its bottom 64 px above the lens's bottom
     edge, so the top of the next row shows below it. It stops at the end of the content
     (960 = 1,560 − 600). Going up, it holds until focus nears the top, then scrolls a row per move.
   - **Focus shows only on a card.** A plain tappable `FlexBox` is drawn as an unstyled focusable box:
     in every snapshot the focused row looks like the others. With `.background(.card)` (stable 1.0.1)
     each row is drawn as a rounded dark card, and the focused one is lifted with a light rim, plainly
     visible in every snapshot.
   - **A row taller than the lens loses its top.** With four rows of about 900 characters (728 px
     each), focus jumped a whole row per move, and the lens settled with the focused row's bottom on its
     bottom edge. The row's first 128 px, about three lines, were never on the lens. The view opened
     scrolled to 174. This happened with plain rows and with cards.
2. **Focus and scroll on a send.** Every send replaced focus and scroll with:
   - no primary button: the first tappable row is focused, scroll 0;
   - a primary `Button` at the top: the button is focused, scroll 0; one down move goes to row 1;
   - a primary `Button` in the middle (after row 15 of 30): **the lens opens scrolled to 340** with the
     button in view and focused (rows 7–16 showing); Enter presses it; one down move goes to row 16;
   - a primary `Button` at the bottom: the lens opens scrolled to the end (1,066 of 1,666), with the
     button focused.
3. **Send time against size.** The median of three sends, timed around the `send` await; "frame" is the
   size of the JSON the test server serves to the preview.

   | View | Characters | `send` | Frame |
   |---|---|---|---|
   | 10 one-line rows | 311 | 2.0 ms | 3.4 KB |
   | 30 one-line rows | 951 | 4.0 ms | 9.8 KB |
   | 60 one-line rows | 1,911 | 7.8 ms | 19.3 KB |
   | 10 rows of 100 characters | 1,000 | 2.1 ms | 4.1 KB |
   | 10 rows of 300 characters | 3,000 | 2.2 ms | 6.1 KB |
   | 10 rows of 600 characters | 6,000 | 2.4 ms | 9.1 KB |

   The test server served each new frame 5–43 ms after the call (polled every 20 ms), and the preview
   drew it 22–29 ms after the call. The session's first send, which starts the session and the
   display, took 354 ms. **On the simulator a send is an in-process hand-off with no radio, so these
   times say nothing about the glasses.** What carries over is the frame size: about 300 bytes per
   row on top of the text, so the number of boxes costs more than the characters (60 short rows are
   19 KB, and 6,000 characters in 10 rows are 9 KB).
4. **A 3 × 3 grid of tappable image tiles.**
   - **Focus moves across as well as down.** The moves right, right, down, down, left, left, up, right,
     down focused G12, G13, G23, G33, G32, G31, G21, G22 and G32. Enter fired that tile's handler each
     time.
   - **The glow on an image shows only on a card.** A plain tappable tile shows no focus. On
     `.background(.card)` the focused tile is drawn full size with a light rim and rounded corners, and
     the others shrink to 91% (a 180 × 140 tile drew at 164 × 128).
   - **How `.fill` sizes an image.** It draws the image at its own pixel size, one image pixel to one
     lens pixel. It never scales up (100 × 60 stayed 100 × 60), and it doesn't shrink images to share a
     row: three 400 × 300 tiles made a row 1,228 px wide, clipped at the lens's right edge, with no
     horizontal scroll. Alone in a row, a 900 × 200 image drew at 600 × 133, scaled to the lens's width,
     with its right 12 px past the edge. Tiles must therefore be rendered at their drawn size: three
     across with 8 px gaps is 186 px each.
5. **A stack of image slices** (576 × 200 each, plain tappable boxes).

   | Lens heights | Slices | Drawn height | Frame | `send` (median) |
   |---|---|---|---|---|
   | 1 | 3 | 678 px | 55.7 KB | 6.7 ms |
   | 2 | 6 | 1,296 px | 112.6 KB | 9.0 ms |
   | 3 | 9 | 1,914 px | 166.5 KB | 13.3 ms |

   Every slice drew at 576 × 200. Down moves stepped slice to slice and scrolled about 206 px per move
   (a slice and its gap), with no send. Nine slices reached the bottom in 8 moves. Plain slices show no
   focus mark, as in item 1.
6. **Dimming and sleep: not measured.** The mock has no control for either (§8, P6).

**Not measurable on the simulator:** send times over the glasses' radio, so the size caps; whether the
band moves focus the way the preview's arrow keys do; whether the card's lift and rim read on the real
waveguide in daylight; and whether the wearer's swipe-direction setting reverses the moves.

**What it means.**

- **§2: the reading view (option C) is buildable, with two conditions; B stays the fallback.** A column
  of tappable rows taller than the lens scrolls with focus, one row per move, and a press reaches the
  focused row's handler. First condition: each row is a `FlexBox` with `.background(.card)` and
  `.onTap`. That is the only way the focus shows, so `HUDBlock` (P2) maps to a card on the Meta Display.
  Second condition: a row stays well inside the lens's height. A row taller than the lens loses its top
  lines, so `rowMaxLines` stays at 4 (about 160 px). The first 10 rows read without scrolling,
  and after that each move brings in one row. B's **‹ Earlier** list is built only if P6 shows the band
  doesn't move focus this way on the glasses.
- **§2's size cap: P1 can't set it.** The simulator's send times don't carry over. Until P6 measures the
  radio, P2 starts with a provisional cap of 40 rows and 4,000 characters, about 13 KB a frame, below the
  60-row test's 19 KB. Rows are the costlier dimension, so the oldest earlier turns drop first, as
  planned.
- **Decision 1's premise: met on the simulator.** The view opens scrolled to a primary `Button` in the
  middle or at the bottom of a column, with that button focused. So chat order (newest at the bottom,
  opening on the newest answer's buttons) is possible. The decision taken (newest at the top) doesn't
  depend on it and stands. Switching is now a real option to weigh after P6, not a guess.
- **Decision 7's premise: met, if the tiles are cards.** Focus moves across a row as well as down a
  column, and a focused tile shows its glow, but only on `.background(.card)`. On a card the unfocused
  tiles shrink to 91% with rounded corners, so the grid reads as nine cards and not one seamless page.
  The grid replaces **Zoom in** on the whole page as decided, with each tile rendered at its drawn size.
- **§4's vertical pan: works without a send.** A stack of slices scrolls about one slice per move.
  Plain slices keep the strip seamless and show no focus mark; the scroll itself shows where the wearer
  is. A three-lens strip is 166 KB a frame. `maxStripHeight` starts at two lens heights (about 113 KB)
  until P6 times a send on the glasses.

### P2 — the reading view's core (headless)

`LensConversationLog` (§3); a `HUDBlock` (a tappable block of lines with an id) in the SDK-free DSL;
`HUDReadingRows` (paragraph rows, split by the pager's wrap and sentence rule); `HUDReadingViewBuilder`
(state to screen: the question, the rows, the buttons, Earlier, an opened earlier turn, the caps);
`ReadingRedrawPolicy`; `HUDReadingCommand`. Or, if P1 failed, B's **‹ Earlier** list on the same log.

Tests (about 30): row splitting and stability as the text streams; the order, the caps and the drop
order; collapsed and opened earlier turns; the four-button rule; redraws only at settle points, at the
end and on a press; clearing on every §3 event; the parser's whole-utterance rule; a private
conversation leaves nothing in the log.

**As built (P2).** In `Services/Display/ReadingView/`, all pure:

- **`LensConversationLog`** is a ring of the last 10 finished turns (`LensConversationTurn`: the
  card's turn id, the question line as drawn, the answer, its follow-ups, whether it staged a page,
  when it was made), oldest first; `record` replaces a turn it already holds in place (its
  follow-ups arriving), `earlier(than:)` lists the older turns newest first. The answer card holds
  it, in memory only; the report reads `count`.
- **`HUDBlock`** (in `HUDScreen.swift`) is a tappable block with an id, lines and an optional
  picture, drawn on a card (`.card`) or plain (`.plain`), with an action as `HUDItem` has. A screen
  carries blocks in two new columns: `flow` (after its lines, before its picture and buttons) and
  `trailingFlow` (after its buttons), each a list of lines and rows of blocks
  (`HUDFlowElement`). `focusesFirstBlock` marks no button as the focused one, so the first
  tappable block takes focus and the lens opens at the top (P1 item 2). All three are in
  `renderKey`; `hasPictures` and `withoutPictures()` replace the single-picture checks in the
  render queue, so a picture-less backend and the text retry handle block pictures too.
- **`HUDReadingRows`** cuts each paragraph into rows through `HUDAnswerPager` itself (a page of
  `rowMaxLines` + 1 lines, footer line unused), so the wrap and sentence rule are the pager's and
  rows are prefix-stable as it is; a single page that wraps to five lines is cut on its lines.
  A row's line is 31 characters, not 32: the card's 8 px padding either side
  (`LensPageFrame.cardPaddingPixels`) at the card's 18 px advance.
- **`HUDReadingViewBuilder`** builds the view: the question (meta), the rows (cards), the buttons
  (**Page** first when staged, then follow-ups — two, or one beside **Page**, only once the answer is
  final — **Actions**, **Close**; for an opened earlier turn **‹ Latest** and **Close**), then
  **Earlier** and the earlier turns collapsed to their question and first two lines, newest first.
  Caps: 40 blocks and 4,000 characters; the oldest earlier turns go first, then the answer is cut
  and ends in "… more on phone". A press on a row reports `HUDAnswerAction.repeatFrom` with the
  answer from that row to its end; on an earlier turn, `.openTurn`; **‹ Latest**, `.latest`.
- **`ReadingRedrawPolicy`**: the first draw at the first settled row (or a whole answer), more while
  streaming only when a paragraph settles, the final draw at completion, then never for the text.
  One deviation in what counts as a settle point: a streamed answer reaches the card as sentences
  joined by spaces (`HUDAnswerTurn`), so it has no paragraphs until the reply is final. A streamed
  reply is therefore drawn twice: once its first row settles, and when it is complete.
- **`HUDReadingCommand`** (in `HUDVoiceCommand.swift`): "earlier", "previous answer" and close
  variants; "latest", "back to the latest"; "say that again", "say it again". Whole utterances, a
  leading filler and a trailing "please". "Show the conversation" stays `HUDReopenCommand`'s. A test
  holds that none of the phrases is a reopen, page, paging, task or launcher word, and the reopen
  words aren't reading words.
- **Tests.** `LensReadingViewTests` (19): the ring, re-recording, earlier; rows by paragraph and
  sentence, rows inside the card, settled rows stable through 24 streamed sentences, settled
  paragraphs, what a row says again; the view's order, collapsed and opened turns, the buttons and
  the four-button rule, the presses, both caps and their drop order, the render key; the redraw
  rule; the words and their overlap with every other lens command.

**As built (P3).**

- **The backends.** `MetaDisplayBackend` draws a text block as a `FlexBox` with 8 px padding,
  `.alignSelf(.stretch)`, `.background(.card)` and `.onTap`, and a picture block (a tile, a slice)
  with no padding at its picture's size; a row of blocks is a `FlexBox` row 8 px apart. A press
  routes by the block's id through `onItemSelected`, as a button's does (and the preview's
  `onSelect`). `pictureBytes` counts every image in the tree. Even draws a screen's lines, its block
  lines, its numbered buttons, then what follows them. The web mirror's payload carries the whole
  column as lines (its buttons stay under it, so **Earlier** comes before them there: the mirror is
  read-only). The phone preview draws the same tree (cards and taps it already drew).
- **The card.** `HUDAnswerCard.usesReadingView` (AppState wires `activeUsesReadingView`: the Meta
  Display with **Scroll**) is read when a card goes up and when it is brought back. The paged card
  stays as it was underneath: the pages are still laid out (the Actions screen's first line, a switch
  to Pages), and a card left unwired keeps its pages, so every existing card test is unchanged. The
  reading view lasts `readingIdleLifetime` (180 s, decision 4); the paged card keeps 60 s. A finished
  turn is recorded in the log at its completion and again when its follow-ups or a page arrive.
  After the final draw, only a change to the answer's own buttons (follow-ups, **Page**) redraws it;
  an earlier turn open at the top is never redrawn for the newest. A press on a row speaks through
  `speakAgain` (the card's Repeat path, live modes included); a press on an earlier turn opens it,
  press-gated like a page turn. "Back" on the reading view leaves an opened earlier turn or the
  Actions screen; "next" does nothing there, so the router's paging words go on to the model.
- **Forgetting.** `forgetForReopen()` (the private conversation's end) also clears the log, and a
  card still on the lens is not recorded again. `conversationEnded()` (wired into the conversation
  reset's local-history step) does the same. `GlassesDisplayService` gained `onHUDTurnedOff`
  (from `shutdown()` with the HUD off) and `onGlassesLinkChanged`; the card clears the log (and the
  card kept for reopening) when the link stays down for its lifetime.
- **Bringing it back.** `reopen()` ("show that again", "show the conversation") brings the reading
  view back, with an earlier answer that was open at its top still there.
- **Voice.** Two handlers in AppState's voice chain, after the reopen handler: `hud-answer-reading`
  takes "earlier" and "latest" (nothing to do: the words go on), and `hud-answer-say-again` takes
  "say that again" only while the reading view is on the lens, after the quiet turn's replay, which
  owns those words for its 30 seconds. Typed text never reaches the chain. `HUDLauncher` and
  `HUDRouter` are not changed. On pages (Even, or **Pages**), "previous answer" puts an earlier answer
  up as the paged card and "latest" the newest, when no turn is answering.
- **The setting.** Display & HUD › In-Lens Display › **Answers on the lens: Scroll / Pages**
  (`Config.lensAnswerStyle`, `LensAnswerStyle`, Scroll by default), shown only with the Meta Display
  chosen.
- **The report.** `HUDAnswerCard.reportLines` (`LensReadingReport`) after the page view's lines: the
  style, how many earlier answers the lens holds now, reading views drawn, row presses, earlier
  answers opened, and rows and characters per view. Counts and sizes only. Send times stay in the
  display's own send record; a per-view send time needs the delivery callback the page view owns
  (one subscriber), so it is left for P6's timings.
- **Not done.** Prepared cards don't enter the log (they don't pass through the answer card).
- **Tests.** `HUDReadingCardTests` (17): the reading view goes up, Pages keeps the paged card, the
  setting by backend and its default, draws only at settle points while streaming, a row press says
  the answer again from that row (through the real tree), an earlier answer opened and ‹ Latest
  back, the words, previous answer on the paged card, the 3-minute lifetime, forgetting on
  conversation end, HUD off and a long disconnect but not a short one, a private conversation
  leaving nothing, show that again, the Meta tree (cards with taps, no focused button, earlier after
  the row), Even and the web mirror, and the report's counts.

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

**As built (P4).**

- **The tiles.** With `LensPageSession.tilesAndStrips` on (AppState turns it on), the whole page is
  drawn as nine card tiles in three rows (`LensPageTileGrid`): each a ninth of the page, a crop
  inside it, drawn at a size three across with 8 px gaps (186 px at most) and three down fit the
  picture box, keeping the ninth's shape. The tiles are cut from the whole page's picture
  (`LensPageSlicer`, off the main actor), so the grid costs no more PDF rendering than the picture.
  A press on a tile zooms `pointZoomRungs` (2) rungs into its centre
  (`LensPageViewport.zoom(rungs:around:)`, stopped at the cap). The grid replaces **Zoom in** on the
  whole page (decision 7). A button still takes the opening focus there; whether the band's first
  move up from it lands on a tile beside the bottom right, which the three-action acceptance needs,
  is P6's.
- **The strip.** A zoomed view is drawn as `LensPageStrip`: the crop's column of the page from the
  crop's top down at the view's zoom, up to two lens heights (1,200 px), cut into slices of about
  200 px, plain tappable boxes after the button row. One deviation: the strip goes *after* the
  buttons. A primary button takes the opening focus, and the lens opens scrolled to it (P1), so with
  the buttons first the lens opens at the top with the crop the wearer zoomed into just under them,
  and each down move brings in more of the page. **Move** keeps ← · → · Done; "up" and "down" by
  voice still move the crop (a new frame). A press on a slice zooms one rung in there. The strip
  draws no position frame (it would sit at the strip's bottom).
- **Ahead of the press.** `LensPageViewport.neighbours()` lists the views one press away, most
  likely first (in, left, right, down, up, out, the whole page, the opening), each once. After each
  frame the session draws the first four into the render cache (`renderAheadLimit`), off the main
  actor; their render times go into the report's render line, as every picture's do.
- **The words.** `HUDPageCommand.zoomInto(Area)` for "zoom in on / zoom into / closer at / get
  closer to" + a ninth ("the bottom right", "the top", "the middle", "the left side"; "corner"
  allowed), two rungs from the whole page and one more from a zoomed view; `.zoomIntoTable` (the
  page's table area, `LensPageLayout.viewportOnTable()`) and `.zoomIntoDiagram` (its drawing).
  Whole utterances only: "zoom in on the wiring" is still a request.
- **Not done.** The grid is drawn on the whole page only, not "any view short of the cap". The
  tiles and the strip are off where `tilesAndStrips` is (every existing page-view test).
- **Tests.** `LensPageQuickZoomTests` (13): every tile a ninth inside the page, tile sizes for three
  page shapes, a tile press two rungs into its corner, two rungs stopped at the cap, areas and cells,
  the strip's column and seamless slices, a strip stopping at the page's bottom, the neighbours, the
  combined words, the builder's rows, and the session: tiles on the whole page and a band press on
  one zooming into a strip, Move on a strip, neighbours drawn ahead, and "zoom in on the bottom
  right" by voice.

**Left for P6.** Everything here is measured on the simulator only: whether the band's swipes move
focus row to row and tile to tile as the preview's arrow keys did; send times over the radio (and so
the 40-row, 4,000-character and two-lens-height caps); the card's rim in daylight; where focus goes
from the button row into the grid; the 31-character row line on a real lens.

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
