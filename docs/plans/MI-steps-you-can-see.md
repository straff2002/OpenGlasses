# Plan MI — Steps You Can See (a picture and the parts on every procedure step, and steps drafted from a manual's own step pages)

**Status:** 📝 Drafted 2026-11-19 — nothing implemented.
**Track:** Field Assist procedures first; the same step format is what a later personal "guides"
lane would use (decision 5).
**Builds on:**
- Plan [F](F-field-assist.md): `Procedure` / `Procedure.Step`, `ProcedureRunner`, the `procedure`
  tool, and Plan [H](H-custom-vault-import.md)'s `VaultValidator`, which checks the graph at import.
- Plan [LC](LC-the-lens-made-ready.md) §6: `Step.videoURL` and `HUDVideo`, the first piece of media a step
  carries, and the rule that the lens is only handed what it can show.
- Plan [EK](EK-manual-structure-and-figures.md): `ManualFigure` (the staged figure, how a manual page
  is rendered, what the lens says, what the phone shows) and `ManualFigureSheet`.
- Plan [KV](KV-the-page-on-the-lens.md) and Plan [MG](MG-reading-the-conversation-on-the-lens.md):
  `HUDPicture`, `LensPageFrame` (what one lens frame holds), `LensPageRenderPlan` (the crop, its size,
  its tones turned for an additive lens) and the tile-grid zoom.
- Plan [EM](EM-work-record-and-parts.md): `PartsVerifier`, which turns a part number into one that
  can be ordered or marks it **unverified**.
- Plan [GX](GX-photo-checked-procedure-steps.md): the `reference_photo` amendment, whose
  vault-relative photo, file checks and size cap this plan reuses rather than inventing a second
  convention.
- Plan [LW](LW-vault-authoring.md): the proposal review screen, `PromptKit` and `PastedDraftParser`
  (bring your own model by copy and paste).

---

## Trigger

Surveying adjacent guide-on-glasses products shows one shape again and again: a manual turned into
a deck of picture-first pages the wearer steps through hands-free, with what each step needs (two
screws, a hex key) printed beside the picture. Ours is the opposite shape. A procedure is a
branching graph with safety notes, citations, calculations, confirmation and evidence, which none of
those products have, but **a step is words only**. On a Display the lens shows a title and an
instruction; on Ray-Ban Meta the technician hears it. "Fit the inducer gasket" is clear to the
author and ambiguous to the person holding three gaskets.

Everything needed to fix that is already in the tree. We render manual pages and crops for the lens
(KV), turn their tones for an additive display, zoom into them (MG), show a figure on the phone (EK),
and verify part numbers (EM). What is missing is a field on the step that points at a picture, a
field that lists what the step needs, and a way to draft both from the manual's own step pages
rather than typing JSON.

---

## What exists (verified 2026-11-19 on `origin/main` ee572aaaf)

- `Procedure.Step` (`Services/FieldAssist/Procedure.swift:63`): `id`, `title`, `instruction`,
  `expected_input`, `safety_note`, `calc_ref`, `citations`, `branches`, `default_next`, `terminal`,
  `outcome`, `requires_confirmation`, `video_url`. No picture and no parts. Optional fields are left
  out when encoding, which is the convention new fields follow.
- `ProcedureHUDTaskSource.current` builds a `HUDStep` (`Services/Display/HUDTaskSource.swift:7`)
  with `index: 0, total: nil` always, because a branching graph has no fixed length. A procedure
  that happens to be a straight chain still shows no position.
- `HUDPicture` (`Services/Display/HUDScreen.swift:103`) is a picture a screen draws, handed only to a
  backend whose `drawsPictures` is true (the Meta Display; not the teleprompter, not Even).
- `LensPageRenderPlan` draws a crop of a manual page for the lens, and `LensPageFrame.Content` already
  has `hasPicture`, so the budget for a picture plus a few lines of text is known.
- `PartsVerifier.verify(_:)` returns a `TaskPart` with `verified` true or false.
- `VaultValidator` reads `procedures/*.json` and checks the graph. It knows nothing of media beyond
  what `Procedure` decodes.
- The vault guide (`docs/field-assist-vault-guide.md`, Step 4) documents procedures as voice-first
  branching checklists, and says an export carries procedures but **never** the manuals.

---

## Design

### 1 · Two new optional fields on a step

```json
{
  "id": "fit_gasket",
  "title": "Fit the inducer gasket",
  "instruction": "Seat the new gasket on the inducer flange, tab towards the pressure switch.",
  "group": "Inducer",
  "figure": {
    "manual": "SLP99V_installation.pdf",
    "page": 41,
    "region": [0.08, 0.22, 0.52, 0.34],
    "alt": "Inducer flange from the front, gasket tab at the top right next to the pressure switch."
  },
  "needs": [
    { "name": "Inducer gasket", "count": 1, "kind": "part", "part_number": "103084-01" },
    { "name": "5/16 in nut driver", "kind": "tool" }
  ]
}
```

- **`figure`** is one of two sources, never both:
  - **A region of a manual the vault already holds**: `manual` (a document the manifest lists),
    `page` (1-based, as printed by the PDF's page index, not the book's folio), and `region`
    (`[x, y, width, height]` as fractions of the page *as displayed*, so a rotated page means what
    the author saw). The picture is rendered on the phone from the installed manual each time; no
    pixels from the manual are copied into the vault. This is what keeps an exported vault free of
    the manufacturer's artwork, as it is free of their text today.
  - **A photo the author took**: `photo`, a path relative to the vault (`figures/fit_gasket.jpg`),
    JPEG or PNG, under 2 MB, the same rules as GX's `reference_photo`. An author's own photos travel
    in an export, because they are the author's.
  - **`alt`** is a sentence saying what the picture shows. The phone's screen reader reads it, it is
    what a lens without pictures falls back to when the wearer asks "what does it look like?", and
    it is the only description of the figure the model is ever given by default (§4). Decision 2.
  - `caption` (optional) is a short label printed under the picture on the phone.
- **`needs`** lists what the step uses: `name` (required), `count` (optional, 1–99; absent means
  "some" and is never said as "1×"), `kind` (`part`, `tool` or `consumable`; default `part`), and
  `part_number` (optional). A part number is run through `PartsVerifier` at import and its result
  stored with the procedure; an unverified one is shown and said as unverified, the same rule the
  work record follows.
- **`group`** (optional) names the stage a step belongs to ("Inducer", "Bag 2"). It is printed as
  the step's meta line and lets the phone fold a long procedure into stages. It changes no
  navigation.

All three are optional, left out when encoding, and ignored by an older build (it skips unknown
keys today), so a vault that uses them still installs on a phone that has not updated; it simply
runs as words.

### 2 · Where the step is in a straight procedure

`ProcedureShape` (pure) reads the graph once at load. When every step has at most one way forward
and there is a single path from entry to the terminal step, the procedure is **linear**, and each
step knows its position: the lens and the phone show "Step 3 of 12", and "how many more?" has an
answer. A procedure with any branch stays as it is (`total: nil`). Groups give the position within
a stage as well ("Inducer · 2 of 4") when every step in the chain has one.

### 3 · What it needs, gathered and said once

`ProcedureNeeds.gather(_:)` (pure) unions `needs` across every step reachable from the entry, adds
counts for the same `name` + `part_number`, and orders parts, then consumables, then tools, each in
first-use order. For a branching procedure it takes the union over all paths and says so ("you may
need").

- **Before the first step** the assistant says it once: "You'll need the inducer gasket, a 5/16 nut
  driver and three more on the phone." At most five items are spoken (decision 4); the phone always
  lists all of them as a checklist the technician can tick, kept with the job.
- **At each step** the lens prints the step's own needs as one meta line ("Needs: 1× inducer
  gasket · 5/16 nut driver"), the phone lists them under the picture, and a speaking-only pair says
  them after the instruction only when the wearer asks "what do I need?".
- An unverified part number is never read out as a number to order. It is said as "a part the book
  doesn't confirm".

### 4 · How a figure is shown

`HUDStep` gains `picture: HUDStepPicture?`, an SDK-free description of the source (manual region or
vault photo, plus `alt`). `StepPictureResolver` turns it into a `HUDPicture`:

- A **manual region** goes through `LensPageRenderPlan` with the region as the crop, sized to
  `LensPageFrame.contentWidthPixels`, tones turned for the additive lens exactly as a page is. The
  `contentKey` is the manual, page, region and render settings, so the render queue skips a frame it
  has already drawn.
- A **photo** is downscaled to the same width and goes through the same tone rule.
- **Budget.** The frame is `LensPageFrame.Content(metaLines: 1, bodyLines: n, hasPicture: true)`.
  When the instruction does not fit under the picture, the lens shows the picture with the title and
  needs line and puts the instruction on a second page (**More**), rather than shrinking the picture
  into a stamp. The budget is computed, not tuned by eye, so it is a headless test.
- **No picture-drawing lens** (teleprompter, Even, Ray-Ban Meta without a display): nothing changes
  but the needs line, and "what does it look like?" reads `alt`.
- **Zoom.** "Zoom in" on a step's picture opens MG's tile grid on that crop; "Back" returns to the
  step. The step is the same step afterwards: zooming never advances.
- **Phone.** The procedure card shows the picture above the instruction; a tap opens
  `ManualFigureSheet` on the full page with the region outlined (a manual region) or the photo
  full-screen. When the manual is not on this phone (an export imported without its manuals), the
  card says "Picture is in *SLP99V installation*, not on this phone" and the step runs as words.
- **The model.** A step's figure is not attached to the turn automatically: the camera frame owns
  the image slot (`ManualFigureAttachment`), and an on-device model is never handed a page. The step
  context the model receives gains the `alt` sentence and the needs, which is what it needs to answer
  "which way does the tab go?". Asking "look at the picture" stages the figure through EK's existing
  path, under its existing rules.
- **Privacy.** A figure comes from the vault or an installed manual, never from the camera, so it
  needs no `OutboundFrameConsumer` roster entry and does not pass the privacy chokepoint; nothing in
  this plan reads a camera frame.

### 5 · Drafting steps from a manual's step pages

Most service and assembly manuals already are step decks: numbered pictures, a line of text each,
and parts callouts ("2×", "Qty 4"). `StepPageDraft` (pure) reads what our manual import already
knows about a page (its text blocks with positions, its picture regions and captions from EK and
the pictured-table work) and proposes steps:

- A **step** is a step number ("3", "Step 3", a circled numeral) with the nearest picture region and
  the text beside it. The proposal carries the region as a `figure` reference, the text as the
  instruction, and the number as its order.
- A **need** is a quantity marker next to a name or a small picture ("2×", "x2", "Qty 2") on the
  step or the page's parts box. A part number found beside it is run through `PartsVerifier`.
- Pages are picked by the author ("pages 38–44"), not guessed across the whole book.
- The proposals land in LW's **review screen**, one row per step, with the crop beside each so the
  author can drag the region, fix the words or drop a row. Nothing becomes a procedure until the
  author saves it; the validator (§6) runs on save. A drafted procedure is linear; the author adds
  branches as they do today.
- **Bring your own model.** LW's `PromptKit` gains a procedure kit: the author runs it in whatever
  model they use with their own copy of the manual, and the answer (steps with page numbers,
  regions as fractions, needs) is pasted back and read by `PastedDraftParser` into the same rows,
  checked the same way. The phone never sends the manual anywhere for this.

### 6 · What the validator checks

- `figure` has exactly one source; a manual region names a document in the manifest, a page within
  its page count (when the manual is present at import; a warning when it is not), and a region
  inside `0…1` at least 5 % of the page each way; a photo exists, is JPEG or PNG and is under 2 MB.
- `alt` is present and between 10 and 300 characters (decision 2).
- `needs`: `name` non-empty, `count` 1–99 when present, `kind` one of three, no duplicate
  `name` + `part_number` on one step.
- The import summary counts steps with pictures and lists unverified part numbers, so an author sees
  "12 steps, 9 with pictures, 1 part number unconfirmed" before installing.

---

## Phases

- **P0 — the format (headless).** `figure`, `needs`, `group` on `Procedure.Step` with round-trip
  tests (present, absent, older JSON, unknown keys); `ProcedureShape` (linear detection and
  position); `ProcedureNeeds.gather` (union, counts, order, the "may need" flag for branches);
  `VaultValidator` checks of §6 and the import summary line; the vault guide's Step 4 gains a
  "Pictures and parts" section. About 30 tests.
- **P1 — on the lens and the phone (headless + simulator).** `HUDStep.picture`,
  `StepPictureResolver`, the frame budget and the **More** page, "Step 3 of 12", the needs meta line,
  the phone card with picture and checklist, the missing-manual line, and the spoken "You'll need"
  opener (capped). Simulator screenshots on the simulated Display in both appearances and at the
  largest text size; accessibility audit of the phone card.
- **P2 — voice.** "What do I need?", "what does it look like?" (`alt` on a lens without pictures),
  "zoom in" on the step picture through MG's tiles, "show me the page", and the `procedure` tool's
  `status` result carrying needs and position so the model can answer from them.
- **P3 — drafting from step pages (headless core, then the screen).** `StepPageDraft` over the
  stored page layout, fixtures from two real assembly-style manuals already in the eval set (no new
  licensed text committed), and the review screen with draggable regions.
- **P4 — bring your own model.** The procedure prompt kit and the `PastedDraftParser` layer, sharing
  P3's rows and checks.
- **P5 — device pass (owed).** On the Meta Display: render time of a step picture, legibility of
  line art after tone turning, the **More** page with gloves. On Ray-Ban Meta without a display:
  the spoken opener and "what do I need?" in a noisy room.

P0–P2 are one PR per the house rhythm; P3–P4 another; P5 is a device report.

---

## Decisions for Greig

1. **Manual pictures by reference only** (recommended): a step points at a region of an installed
   manual and the phone renders it, so an export never carries the manufacturer's artwork. The
   alternative, copying crops into the vault, makes exports self-contained but puts licensed
   pictures into every shared vault.
2. **`alt` required on every figure** (recommended): it is the screen-reader text, the speaking-only
   fallback and the model's description. The drafting flow proposes one so it costs the author a
   glance, not a sentence. The alternative is optional with a warning.
3. **One picture per step now** (recommended), with a "what done looks like" second picture left for
   GX, whose reference photo already is that. The alternative is a before/after pair from the start.
4. **Spoken parts list at the start: once, at most five items, the rest on the phone** (recommended).
   Alternatives: never spoken (phone only), or every item.
5. **Personal guides** (recipes, flat-pack, a home appliance's own step pages for My Manuals
   subscribers) **in a later plan** (recommended). The format here is what it would use; the store,
   tier and screens are their own question.
6. **No outside agent writing procedures over a live connection** in this plan (recommended).
   Copy and paste (P4) keeps the author in the loop and the manual on the phone. If a live
   connection comes later, it starts with reading on and saving, publishing and deleting off until
   the owner turns each on, per agent.

---

## Not in scope

- **Free-form card layouts** (text and pictures at fixed positions on a canvas). Our lens lays
  itself out, follows text size and accessibility settings, and has to work on displays of
  different sizes and on none; a fixed canvas would fight all of that.
- **Importing step decks from other guide services.** Their formats carry positioned text and
  pictures with nothing that says what a step, a need or a branch is, so an import would give slides,
  not procedures, and the content's terms are theirs.
- **Server-side manual processing** to find steps or crop pictures. Manuals stay on the phone they
  were imported on.
- Identifying a part from the camera; GX covers checking a step against a photo.

---

## Risks

- **Render time on the Display.** A step picture is a page render plus a crop; MG's render-ahead
  draws the next step's picture while the current one is shown, for linear procedures. Measured in
  P5.
- **Line art after tone turning.** Thin black lines on white become thin light lines on clear glass;
  KV's legibility rule applies, and a region too small to read is a validator warning (§6), not a
  surprise on site.
- **Rotated and scanned pages.** Regions are in displayed orientation; a photographed manual
  (Plan IF) has a page image, not vector art, and its regions are checked against that image.
- **A vault that moves to a phone without its manuals** loses its pictures, by design (decision 1).
  The step says where the picture is, rather than showing nothing.
