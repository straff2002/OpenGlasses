# Plan KV — The Page on the Lens (the manual page or diagram in the glasses, zoomed by band or voice, and the question above the answer)

**Status:** 📝 Drafted 2026-11-08 from the partner's ask, made while ordering a Meta Ray-Ban Display for
pilot demos. Nothing built. The owner took all nine recommended decisions the same day ("take all
nine"), and the same day added P1b, finding the diagram on a page, and P4, a development-only simulated
Display ("add it to KV").
**Track:** Display (Meta Ray-Ban Display through `MWDATDisplay`). Field Assist and personal manuals:
every page "show me the page" or an answer opens. P0–P3 (with P1b) are headless; P4 runs on the iOS Simulator
against Meta's simulated Display; P5 needs a real one.
**Related:** Plan [KP](KP-answers-you-can-act-on.md) (the answer card, `frameRevision`, the band check,
the preview to scale, the Display-in-use rule), Plan [KR](KR-the-page-it-says.md) (one page per turn:
the page shown is the page said), Plan [EK](EK-manual-structure-and-figures.md) (the staged figure,
`ManualFigureCue`, `ManualFigurePresenter`), Plan [IN](IN-verifiable-code-lookup.md) P1–P2 (cited passages marked
on the page, `show_source`), Plan [JN](JN-pictured-tables.md) P2 (picture areas outlined), Plans
[X](X-interactive-hud-now-next-tasks.md)/[Y](Y-interactive-hud-launcher.md) (`HUDRouter`, the task card),
Plan [AH](even-display-backend.md) (the Even backend), Plan [BP](BP-web-hud-mirror.md) (the web mirror),
Plan [JV](JV-dat-experimental-testflight-lane.md) P2 (glasses gestures, TestFlight only).

---

## Why

The partner is getting a Display for pilot demos, because the people he demos to keep asking to see
information in the glasses. He asked for two things, in this order:

1. **The conversation on the lens.** On a job site you can't always hear the spoken reply, and reading
   it shouldn't mean taking the phone out. KP built most of this: each Direct-mode answer is a paged card
   with actions under it. What KP leaves out is the other half of the conversation, what the
   technician asked (and what the app heard).
2. **"Show me the page."** The manual page an answer came from, in the glasses, and where the hardware
   allows, the band zooming in on a detail or a diagram.

The second one goes against a sentence the code says today. `ManualFigureCue` says a lens "cannot make a
wiring diagram legible — the HUD screen model has no image type and would not help if it did", so the
lens gets one line, "Figure 12, page 30, on your phone". Both halves of that were reasonable when they
were written, and both are now only partly true:

- **DAT 1.0.0 can put a picture on the lens.** `MWDATDisplay.Image(image: UIImage, sizePreset: .fill)`
  sends any image the phone renders. The HUD model just never grew an image element.
- **A whole page at 600 × 600 is not legible, but a part of one is.** A letter page fitted to the lens
  draws 8 pt terminal labels about 8 lens pixels tall, well under the smallest text token KP's preview
  estimates (22 px). The same labels at three times that scale are about 24 px. A diagram's shape is
  readable whole, its labels once zoomed, and the cited passage or the marked table row is usually a
  region small enough to fit at a readable size from the start.

So the page goes on the lens as a picture the phone draws: opened on the part the answer is about, with
the whole page one press away, and zoom and pan by band press or voice.

## What exists, and what doesn't

- **The staged page.** `FieldSessionService.StagedFigure` names the document, the physical page, the
  printed caption, the cited passages (`citedPassages`) and, for pictured tables, the outlined
  `pictureAreas`. `ManualFigurePresenter` resolves it to the manufacturer's PDF and a page index, or to
  `.unavailable` when the document was imported as text. Personal manuals stage through
  `PersonalManualLibrary.takeStagedFigure()`.
- **Rendering a page.** `ManualFigureAttachment.render(source:page:)` already rasterises a PDF page
  through `PDFPageRasterizer` (150 dpi for the model). Nothing crops, inverts or draws marks into a
  picture; the phone's marks are drawn by the PDFKit viewer on screen.
- **Marks.** `PassageMarks` locates each cited passage as text ranges in the page's text. The phone turns
  those into highlights in the viewer. Turning them into rectangles needs only `PDFPage.selection(for:)`
  and its bounds, which work without a view.
- **Where a diagram is.** Nothing does. The importer records a page's caption ("Figure 12") but never
  where the drawing sits on the page; no figure bounds are stored anywhere. `LensPageFocus` has the slot
  for one and nothing fills it, so without P1b "show me the diagram on page 7" opens the whole page.
- **The lens.** `GlassesDisplayBackend` takes `showContent(title:body:icon:)` and `send(screen:)`.
  `HUDScreen` holds text lines, icons and buttons, with no image. `MetaDisplayBackend` builds
  `FlexBox`/`Text`/`Button`/`Icon` and never `Image`. The Even renderer draws text cells only. The web
  mirror (`WebHUDRenderer`) draws the same screens as HTML.
- **What happens today when a page opens.** The phone opens the sheet (while the app is in front;
  `ShowSourceCenter` holds a request made with the phone locked until it is), and the lens flashes the
  six-second cue. With the phone in a pocket, the technician hears the answer and is told to look at a
  phone.
- **The geometry.** `HUDCanvas.metaDisplay` is 600 × 600 at density 160; KP P4's preview draws a frame at
  the lens's shape, with token sizes marked as estimates.
- **The answer card.** KP's card shows the reply only. `HUDAnswerTurn` opens around each Direct-mode
  reply; the transcribed question is known at that point and not shown. The live modes (Gemini Live,
  OpenAI Realtime) get no card at all, as KP P1 found.
- **The band.** In a store build the band reaches the app only as a button's `onClick`. Swipes and
  pinches would come only through JV's Inputs lane, which is TestFlight-only. Whether the band can reach
  every button in a row is what KP's band check settles.
- **The order of things.** KR (PR 996, open) fixes the page on the phone being re-chosen after every tool
  round, so the page shown is the page the answer said. KV sends that same page to the lens. It builds on
  KR and must not land before it.

## Design

### 1 · The page view

A **page view** is a lens screen: one picture, at most two short text lines over it, and one row of
buttons under it. P4 measured the frame on the simulated Display: with the button row and the lines, the
picture gets a box about **576 × 382 px**, not the whole 600 × 600 (`LensPageFrame` computes it from what
is on the frame, so nothing scrolls). A cited **text passage** opens differently, as text (§1b).

The picture is a crop of the page, chosen by a viewport:

```swift
struct LensPageViewport: Equatable {
    let pageSize: CGSize          // the page in PDF points
    var center: CGPoint           // in page points
    var scale: CGFloat            // relative to the whole page fitted in the picture box
    var cropRect: CGRect { … }    // the picture box's shape, clamped inside the page
    mutating func zoomIn(); mutating func zoomOut()
    mutating func move(_ step: Step)   // .up, .down, .left, .right: half a crop at a time
    mutating func reset()              // back to the opening view
}
```

It opens on the **focus**, picked by a pure `LensPageFocus` in this order:

1. The cited passages' bounds on that page, united (IN's marks, turned into rectangles).
2. The pictured table's outlined area (JN's `pictureAreas`).
3. The diagram on the page, found by P1b's `PageFigureLocator` from the ink alone (no caption needed),
   chosen by a named caption, the request's words, a position word, or else the largest.
4. None: the whole page, fitted.

When the request asked for a drawing ("show me the diagram on page 7", "show me figure 12", or
`manual_figure`), the diagram moves to the top of that order, ahead of any cited passage. The diagram is
a focus at all only when a drawing was asked for, or when the app put the page up by itself for its
figure. A request for the page ("show me page 7") with nothing cited on it opens the whole page, with
**Next diagram ›** there to jump to a drawing.

The focus is padded by a margin and given the picture box's shape. The view opens at exactly the scale
that fits it, so a marked table row or a diagram fills the box's width, and a whole wiring diagram opens
whole. **Zoom in** and **Zoom out** move ×1.5 per press from there, up to a cap one press past the scale
at which 8 pt labels reach the readable floor. **Whole page** is scale 1. As built, the cap is 4.125 lens px per page point (8 pt labels at the 22 px floor
is 2.75, times one more press), so labels draw about 33 px at the deepest zoom. The picture box is 576
px wide and 462, 426, 418 or 382 px tall for no lines, the citation, the hint, or both; a frame with a
button row keeps 32 px under it for the focused button's glow. (First built as a square crop
with four fixed steps, fit/×2/×3/×4; P4's screenshots showed portrait pages and tables opening a third
of the box wide, and the owner had it changed on 2026-11-08.)

**Legibility.** A pure `LensLegibility` estimates how tall the page's text draws on the lens at a given
crop: the cited lines' height in page points (from their selection bounds, or a 8 pt default for a
drawing's labels) times lens pixels per page point. When the estimate is under the readable floor, the
view shows a one-word hint ("Zoom in for labels"). The floor starts at KP's smallest text token
estimate (22 px, `HUDCanvas.textSize(.meta)`) and is marked as an estimate until P5 measures it.

### 1b · Cited text opens as text

A picture of body text can't be read on this lens: a manual's line spans the column, so even fitted to
one line it draws about 9 px tall (P4's screenshots). So when the opening focus is a cited **text
passage** (not a marked table row, a pictured table or a drawing) and the page has a text layer, the
page view opens in **reading mode**: the passage's exact words, taken from the page text by the
passage's located ranges (never the model's words), set as lens text with the backend's geometry and
paged like KP's card ("1/2"), under the citation line. Several cited passages on a page follow one
another, numbered as the marks are. Its row: **Next ›** while pages remain · **Page** (the picture,
opened on the passage's mark) · **‹ Back** from page 2 · **Next page ›** on the last page when another
cited page follows · **Close**, four at most. The picture view of such a page gets **Read it**, back to the
text. Voice: "next" and "back" page the text while reading mode is up, "show the page" and "read it"
switch. Photographed and text-imported pages, and table rows, keep the picture. This is also the
owner's first aim for the Display: the exact manual content, readable, a card at a time.

### 2 · Drawing for an additive lens

The Display adds light: black is clear and white glows. A manual page is black ink on white paper, so
sent as-is it is a glowing square with dark lines, covering the very thing the technician is looking at.
The renderer (`LensPageRenderer`) draws:

- **The crop**, rasterised at the resolution the lens needs (600 px across the crop, not a whole-page
  render scaled down), so zoom gets sharper, not blurrier.
- **Inverted luminance:** light lines on black, so the paper disappears and the drawing floats.
  Photographed pages (Plan [IF](IF-photographed-manuals.md)) are inverted too, after a contrast stretch, since paper in a photo is grey
  and inverted grey is a dim haze.
- **The marks**, as outlines in the AI accent: each cited passage and each pictured area that lies in the
  crop, with its number when the page carries more than one (as the phone's marks do).
- **A position mark** when zoomed: a small frame in one corner showing where the crop sits on the page,
  so the technician knows what part of the sheet they are looking at.

The output is a `UIImage` at the canvas size. Rendering runs off the main actor; the overview and the
opening view are drawn as soon as a page is staged, so the press that opens the view doesn't wait for
PDFKit.

### 3 · Buttons and words

The row under the picture (a pure `HUDPageScreenBuilder`, from the viewport state):

| View | Buttons |
|---|---|
| Opening view, zoomed | **Zoom in** · **Whole page** · **Move** · **Close** |
| Whole page | **Zoom in** · **Back to part** (when there is a focus) · **Close** |
| At the deepest zoom | **Zoom out** · **Move** · **Close** |
| Move (pushed) | **↑** · **↓** · **←** · **→** · **Done** |
| Reading mode (§1b) | **Next ›** (while pages remain) · **Page** · **‹ Back** · **Next page ›** · **Close** (four at most) |

**Four buttons at most.** P4 found five-button rows clip on the lens ("Whole page" and "Next diagram ›"
were cut). When a view would have five, **Move** drops first, then **Next diagram ›**, then **Whole page**; both stay
reachable by voice, and **Move** comes back once the view is zoomed past its opening scale.

**Move** pushes an arrow row rather than cycling through tiles, so the technician never loses their
place and a press always does the same thing. Each arrow moves half a crop. With several pages ("show me
the relevant pages"), the opening view's row also gets **Next page ›**, and the first view of the next
page is its own focus.

Voice, through a new `HUDPageCommand` parsed the same strict way as KP's paging words (whole short
utterances, filler tolerated, only while a page view is on the glasses): "zoom in", "closer", "zoom out",
"whole page", "show the whole page", "up"/"down"/"left"/"right", "top left"/"bottom right" (the corners),
"next page", "back", "close the page". Anything longer is an ordinary request, as on the card.

When JV's Inputs lane is present (TestFlight only), its swipes pan the view and nothing else changes.
The store build needs no gesture the band doesn't send.

### 4 · When the page goes to the lens

- **When the technician asks for it:** "show me the page", "show me the diagram", "show it on the
  glasses" (`show_source`, or a figure staged with `origin == .requested`). With the HUD on and a backend
  that draws pictures, the page view opens on the lens **as well as** the phone sheet. The phone keeps
  the full page and PDFKit's own zoom; the lens gets what fits.
- **When the app put the page up by itself** (`origin == .automatic`, opened by `FigureAutoOpenPolicy`): the lens keeps today's
  cue, but the cue becomes a card with one button, **Show here**, instead of a six-second line. One
  press opens the view. The app never covers the technician's view with a diagram unasked.
- **With the phone locked:** the lens view opens anyway. That is the case it is most for. The phone sheet
  still waits for the app to come to the front, as today.
- **On the answer card:** a turn that staged a page gets a **Page** action under KP's Actions, so a
  technician reading the answer can open the page without saying anything.
- **Closing** returns to whatever was under it: the answer card, a task card or nothing.

The page view is a pushed `HUDRouter` screen, rendered through `frameRevision` like everything else, so
a notification that arrives between "zoom in" and the render still wins. KP §8 holds unchanged: while
another app has the Display, the lens is not taken back, and the hint says the page is on the phone.

### 5 · What says what

The lens, the phone and the spoken answer name the same page, because they read the same staged figure
(KR's rule, one page per turn). The view's first frame carries the citation in KP's meta style, one line
over the picture ("Figure 12 · p. 30"), and drops it once the technician zooms or moves. Every view the
lens opens, and every zoom, is written to the audit trail the phone sheet already keeps
(`ManualPageController`), as "shown on the glasses" with the page and the crop. The audit holds the page
reference, never the page's text or pixels.

### 6 · Backends

`GlassesDisplayBackend` gains `var drawsPictures: Bool`.

- **Meta Display:** true. `HUDScreen` gains an optional picture (`HUDPicture`: the image, its size, a
  content key so the service's de-duplication doesn't re-send an identical frame), and `MetaDisplayBackend`
  renders it as `Image(image:sizePreset: .fill)` above the button row.
- **Even G2:** false. Its panel is monochrome text cells, so it keeps the cue line
  and the page words of §3 do nothing there.
- **The web mirror:** false in KV. The picture would make the mirror's payload a different kind of thing
  (an image per frame instead of a few lines of text), which belongs with BP's own reachability work.
- **The phone preview (KP P4):** shows the exact frame that was sent, picture included, so the whole view
  can be seen and tested without a Display.

### 7 · The question above the answer

KP's card gets one line above the answer's first page: what the app heard, condensed to one line in the
meta style and prefixed "You:". It shows on the first page only, so a long answer loses no reading room
after it. Hearing the question back answers a question the technician had no way to ask: whether the
app misheard them. It isn't shown for a turn the app started (a proactive alert, a watcher) and is cut
like any other line (`HUDTextShaper.condense`). The live modes still get no card; mirroring their
transcript is a separate piece of work (see "What KV leaves out").

### 8 · Privacy and licensed pages

The page goes over the DAT link to the wearer's own glasses, the same path the answer text takes; DAT's
analytics opt-out and `MetaTelemetryBlock` are unchanged. Nothing is stored on the glasses. A licensed
vault's page is shown exactly as it is on the phone today, to the person the vault was opened for. A
photographed page is a reviewed, stored image, not a camera frame, so `OutboundFrameConsumer`'s roster is
not involved. The privacy-logging gate applies to every new log line: page references and timings only.

## What KV leaves out

- **Pinch, scroll and free pan.** A store build gets button presses only. KV's zoom is steps and its pan
  is half-crop moves.
- **Live-mode conversation on the lens** (Gemini Live, OpenAI Realtime). Their replies are model audio;
  putting their transcripts on a card means mirroring two different transcript streams with their own
  timing. A plan of its own, once the partner says which mode the demos run in.
- **Pictures on the Even G2 and the web mirror** (§6).
- **Pages in a task card.** A procedure or playbook step that cites a page could offer **Page** too. KV
  opens the view from the answer card and from requests; the task-card route waits until P5 shows the
  view reads well.
- **Speech-synced page views**, the lens following the answer from passage to passage as it is spoken.

## Decisions (taken 2026-11-08: every recommendation below, "take all nine")

1. **When the page opens on the lens:** only when asked, with **Show here** on an auto-opened page's cue
   (§4); or every staged page. *Recommended: only when asked. A diagram the technician didn't ask for
   covers what they are looking at.*
2. **Opening view:** the focus when one exists, else the whole page (§1); or always the whole page.
   *Recommended: the focus.*
3. **Zoom steps:** fit, ×2, ×3, ×4 of the whole page fitted. *Recommended. P5 says whether ×4 is ever
   used.* **Revised 2026-11-08 after P4:** the view opens at the exact scale that fits its focus, and
   zoom moves ×1.5 per press (§1); the owner chose the fix.
4. **Pan:** a pushed arrow row (§3); or one **Move** button cycling tiles in reading order.
   *Recommended: the arrow row.*
5. **Inversion:** always for line art, with a contrast stretch for photographed pages (§2); or a setting.
   *Recommended: always, no setting until P5 shows a page that reads worse inverted.*
6. **Marks:** outlines in the AI accent (§2). *Recommended.*
7. **The question line** (§7): on whenever the card is. *Recommended.*
8. **Even G2 and the web mirror:** the cue only (§6). *Recommended.*
9. **The phone sheet** when the lens opens: still opens as today (§4). *Recommended: yes, so the
   full-resolution page is there when the technician does take the phone out.*

## Phases

The whole plan is one PR, built after KR merges (P0–P4, with P1b), with P5 owed to the partner's Display.

### P0 — the pure core (headless)

- `LensPageViewport` (zoom steps, half-crop moves, corners, clamping, reset), `LensPageFocus` (the four
  sources in order, padding, the square), `LensLegibility` (the estimate and the floor, marked as an
  estimate), `HUDPageScreenBuilder` (the rows of §3, by state, with **Next page ›** for several pages)
  and `HUDPageCommand` (the words of §3, and what isn't one).
- Mark rectangles from `PassageMarks` through a seam (`PageTextGeometry`: range → bounds), with a fake
  in tests and PDFKit's selection bounds behind it.
- Tests: every move clamps at every edge and zoom; the focus wins in the stated order; a table row opens
  at a readable step and a whole drawing at fit; the hint shows exactly when the estimate is under the
  floor; the arrow row and the corners; "next" inside a sentence is not a command.

### P1 — the view on the glasses (headless, wired)

- `LensPageRenderer`: crop at the needed resolution, invert (with the photographed-page stretch), marks,
  the position frame, the citation line on the first frame; off the main actor, the overview and opening
  view pre-drawn on staging, cached by figure identity plus crop.
- `HUDPicture` on `HUDScreen`, `drawsPictures` on the backends, `Image(image:sizePreset: .fill)` in
  `MetaDisplayBackend`, the cue line on Even and the mirror.
- The routes of §4: requested pages open the view; auto-opened pages get the **Show here** cue card; the
  **Page** action on KP's card; locked-phone opening; close returns to what was under it; `frameRevision`
  and KP §8 respected.
- The audit lines of §5, and a **Page on the lens** section in the support report: views opened, zooms,
  moves, render milliseconds, bytes sent and send milliseconds, by backend.
- Tests through the existing seams (`testRenderSink`, `testInteractiveButtonActions`,
  `testCapabilityOverride`): the right page renders for a requested figure and only the cue for an auto
  one; a stale render is dropped; the phone preview shows the frame sent; the Even backend never gets a
  picture; the audit holds no page text.

### P1b — finding the diagram (headless)

- `PageFigureLocator` (pure core): from a coarse ink mask of the page (a grid of cells, each inked or
  not) and the page's text-line rectangles, blank out the text, join neighbouring inked cells into
  blocks (closing small gaps, so a diagram's thin lines hold together), and drop blocks too small or too
  thin to be a drawing (a rule line, a table border alone, a logo). What is left are the page's
  drawings, as rectangles in page points (P0's top-down convention).
- **Finding needs no caption.** The locator works from ink alone, so a drawing with no caption, no
  figure number and no title is found like any other. A caption only helps choose when a page holds
  more than one.
- **Choosing one**, in this order, each step used only when it decides:
  1. **A named caption.** The request named one ("figure 12") and it is found on the page: the drawing
     nearest it, above or below, as captions usually sit.
  2. **The request's words.** Each drawing keeps the text lines that fall inside it (its own labels,
     blanked out of the ink but not forgotten) and the heading or line just above it. The request's
     content words ("the blower wiring", "the control board") are matched against those, the same
     whole-word way `ManualFigureTool` matches today; a clear winner is chosen.
  3. **A position.** "The top diagram", "the one at the bottom", "the left one", "the second diagram":
     read by `HUDPageCommand`'s strict parse extended with position words, against the drawings in
     reading order.
  4. **Otherwise the largest**, with **Next diagram ›** after **Zoom in** on the opening view, cycling
     the page's drawings in reading order (voice "next diagram"), so a wrong first pick is one press
     from the right one.
- **The thin edge.** `PageInkMask` renders the page small (about 72 dpi) through `PDFPageRasterizer` and
  thresholds it into the mask; text lines come from `PDFPage.selection(for:)` line by line. Located
  drawings are cached by document, page and source revision, so a page is analysed once.
- **Where it doesn't apply.** Photographed pages and text-imported documents have no text layer to
  blank out: they open on the whole page as before. A page that is all drawing (a wiring sheet) finds
  one block the size of the page and opens fitted, which is right.
- Wiring: `LensPageFocus` takes the located drawing as its figure rect; the request's kind (a drawing
  asked for, or not) decides the order of §1.
- Tests: invented pages drawn with `UIGraphicsPDFRenderer`, with a block diagram and text, two drawings
  and two captions, two drawings with no captions told apart by their labels and by "the bottom one", a
  drawing with no caption at all, a page of text only, a page that is all drawing, a table with only its border, and a
  thin rule line. The right block is found and chosen, text never counts as ink, and the opening zoom
  holds the whole drawing.

### P2 — the question above the answer (headless)

- The "You:" line on the first page of KP's card (§7), condensed, not for app-started turns; the pager
  budgets the first page one line shorter.
- Tests: the line appears once, on page 1 only; a long question is condensed, never wrapped; a proactive
  turn has none; page counts stay right.

### P3 — the preview and the words on the phone (headless)

- KP P4's preview draws the page view at the lens's shape, picture included, with **Zoom in**/**Move**
  working on the phone so a reviewer without a Display can walk it.
- The help text for "show me the page" and the HUD settings row say the page can go to the glasses.
- The `ManualFigureCue` doc comment is rewritten to say what KV found (a whole page isn't legible, a part
  is).

### P4 — the simulated Display (development only, on the iOS Simulator)

Until now every Display phase (X, Y, KP and KV's P0–P3) has been checked only through test seams: a fake
render sink and button actions called directly. Nothing has drawn the real `MWDATDisplay` views. DAT
1.0.0's Mock Device Kit can: `MockDeviceKit.shared.enable()`, `pairGlasses(model: .metaRayBanDisplay)`,
`powerOn()` and `don()` give the app a simulated Display, which draws the 600 × 600 lens from the views
the app sends, either in a preview view inside the app (`services.display.createPreviewView()`) or in
Chrome through Meta's simulator extension (`startTestServer(port:)`, then `http://127.0.0.1:9000/`, iOS
Simulator only). Its direction pad and Select stand in for the band, and
`MockDisplayKit.sendClick(identifier:)` presses a button from code. Meta's guidance is that the preview
stays out of production builds.

- **A lane that cannot ship.** `project.mock-display.yml` links `MWDATMockDevice` and defines
  `DAT_MOCK_DISPLAY`. Only `AVENKIN_DAT_MOCK_DISPLAY=1 ./Scripts/generate-xcodeproj.sh` adds it, and the
  script refuses the flag under Xcode Cloud or CI. Code that calls the mock lives only in
  `Sources/Glasses/MockDisplay/`, wrapped in `#if DAT_MOCK_DISPLAY`. A guard test (in the style of
  `TelemetryOptOutGuardTests`) fails on any `MWDATMockDevice` import or mock call outside that folder or
  outside the `#if`, and on any committed spec other than `project.mock-display.yml` that names the mock
  product. A flagged build is never archived, sent to TestFlight or submitted.
- **A Developer switch.** Developer › **Simulated Display** (present only in a flagged build) enables the
  kit, pairs simulated Display glasses, powers them on, puts them on and starts the test server. It shows
  the in-app preview in a square floating panel the developer can hide, and it says the Chrome address.
  The HUD then drives the simulated lens through the real `MetaDisplayBackend`, so the frames are the
  ones a Display would get.
- **A scripted walkthrough.** A Developer action (and a UI test where the mock's process allows it) asks
  for a page of an invented test manual, then walks the view: opening view, **Zoom in** twice, **Move**
  and an arrow, **Whole page**, **Close**. It also walks a three-page KP answer card and its **Actions**,
  pressing each button through `sendClick(identifier:)`. **Found:** the mock addresses a button by the
  identifier the SDK gives it when a frame is sent, `c<position>_<token>` (the token is stable for a
  label); a label returns `true` but presses nothing. The identifiers are read from the test server's
  frame (`POST /display/content`) before each press.
- **Screenshots as evidence.** Each step's lens is captured (`simctl io screenshot`, the preview panel
  cropped) and kept with the PR's notes, not in the repo. The checks: the picture is inverted, the marks
  sit on the cited lines, labels read at the step `LensLegibility` predicts, the button row fits under
  the picture, and a stale frame never overwrites a newer notification.
- **First, a spike.** Whether the whole app runs in the Simulator with the mock enabled (the order
  against `Wearables.configure()`, the permission gate, `GlassesConnectionService` reading a mock link as
  `.connected`) is unknown. Thirty minutes decide it. If the app can't run, P4 falls back to a small host
  screen in the same flagged lane that drives `MetaDisplayBackend` alone.

**Built 2026-11-08.** The spike settled it: the full app runs on the mock. It configures the SDK as
usual (telemetry block, then `Wearables.configure()`); the lab then enables the kit registered with the
permission granted, pairs, powers on and dons, and the phase reads `.connected` with frames going
through the real `MetaDisplayBackend`. No store-build code changed. `project.mock-display.yml` also
carries a build phase that fails anything but a Debug Simulator build. Launch arguments
`-AvenkinSimulatedDisplay` (and `-AvenkinSimulatedDisplayWalkthrough`) switch it on at launch. The first
walkthrough found the lens scrolling (a square picture made the frame about 750 px tall), five-button
rows clipping, cited text unreadable, and portrait pages and tables filling a third of the picture box:
fixed by `LensPageFrame`, the four-button rule (§3), reading mode (§1b) and the fitted, continuous zoom
(§1).

The simulator doesn't replace P5: brightness, legibility against daylight, transfer time and the real
band need the glasses.

### P5 — device pass (owed; the partner's Display)

On a Meta Display: ask for three pages (a wiring diagram, a table with a marked row, a text page with a
cited passage), and one photographed page. For each: read the opening view, zoom in to the labels, move
around, go to the whole page and back. Report which zoom step made labels readable (calibrates the floor),
whether inversion helped or hurt, how long a press took to show (from the support report), and whether
the band reached every button in the arrow row. Then do the same with the phone locked, and with another
Display app open. Settle decisions 3 and 5.

**Gates for the PR:** the P4 walkthrough's screenshots reviewed, the full suite and a Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`, catalog
changes in their own commit, the security checks before opening it, the licensed-content leak check on
every added line (fixtures use invented pages and captions only), and this Status line and the index row
updated.

## Acceptance

- "Show me the page" with a Display on puts the page on the lens, opened on the part the answer is about,
  with the marks the phone shows.
- "Show me the diagram on page 7" opens on the diagram itself, zoomed to hold the whole drawing, and
  "figure 12" picks that figure when the page holds two. A drawing with no caption is found the same way,
  and two uncaptioned drawings are told apart by their labels, by "the bottom one", or by **Next
  diagram ›**.
- From the glasses alone the technician can zoom in until labels are readable, move around the page, see
  the whole page, go to the next cited page, and close it.
- The lens, the phone and the answer always name the same page.
- An auto-opened page never covers the lens without a press.
- With the phone locked, the page still reaches the lens.
- The card shows what the app heard above the answer.
- Nothing is stored on the glasses, no page text or pixels reach a log, and the phone preview shows the
  same frame the lens got.

## Open

- How long DAT takes to deliver a full-canvas image, and whether it compresses it (P5, from the support
  report's send timings).
- The real readable floor on the lens (P5), which replaces the 22 px estimate.
- Whether the Display's colour makes an accent outline readable over inverted line art, or white reads
  better (P5).
- Whether stable DAT sends the band's back gesture to the app (KP's open question, JV's probe); until then
  **Close** and **Done** are on-screen buttons.
