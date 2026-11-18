# Plan MJ — Personal Guides (step-by-step guides of your own, from a manual's pages, your photos or a recipe you share, followed hands-free)

**Status:** 📝 Drafted 2026-11-19 — nothing implemented.
**Track:** consumer. Phone first; the glasses, the watch and AirPods are surfaces, not requirements.
**Builds on:**
- Plan [MI](MI-steps-you-can-see.md): the step `figure`, `needs` and `group` format,
  `StepPictureResolver`, the lens step card, "Step 3 of 12", `StepPageDraft` (steps drafted from a
  manual's numbered step pages) and the review screen. This plan reuses all of it and adds no second
  step format.
- Plan [JK](JK-my-manuals.md): My Manuals, the `personalManuals` capability, the five-manual shelf
  and the new-manual allowance, and its rule that a cheaper tier is defined by what the code
  structurally lacks: no `fieldWork`, so no procedures and no `procedure` tool.
- Plan [F](F-field-assist.md): `Procedure` and `ProcedureRunner`, which this plan deliberately does
  not reuse for running a guide (§2).
- `TimerTool` and `TimerCompletionWatch`: timers that already ring on the phone and the watch.
- The share extension (`OpenGlassesShareExtension`), which already accepts text and web URLs.
- Plan [JD](JD-apple-intelligence-tools.md): the on-device model, for splitting text into steps
  without sending it anywhere.
- Plan [CP](CP-outbound-frame-privacy.md) / W04.1: `OutboundFrameConsumer` and the privacy
  chokepoint, for photos taken to make a guide (§5).

---

## Trigger

Plan MI gives a Field Assist procedure a picture and a parts list on every step. The same shape is
what a person at home wants: a recipe on the lens while their hands are in dough, the flat-pack
wardrobe's step pages one at a time, the coffee machine's descaling routine from its own manual, an
oil change from the car's handbook. Guide-on-glasses products sell exactly that.

We cannot hand that person procedures. Since Plan JK, procedures sit behind `fieldWork`, and the
personal tier is cheaper *because* the code cannot reach them. A received set's procedures are
dropped for a personal customer on purpose. Personal guides therefore have to be their own thing:
simple enough that nobody would buy them instead of Field Assist, built from the same step format so
nothing is written twice.

---

## What exists (verified 2026-11-19 on `origin/main` ee572aaaf)

- `FieldAssistCapability` (`Services/Entitlement/FieldAssistCapability.swift`): `fieldWork`,
  `ownVaults`, `personalManuals` and the rest. `procedure`, `ProcedureRunner` and the Field Assist
  procedure screens all ask for `fieldWork`.
- `PersonalManualLibrary`, `ManualQuota`, `ManualLibraryAdmission` and `MyManualsView`: the
  personal shelf, its quota and its screen. The personal vault (`my-manuals`) has no trades,
  procedures or scenarios.
- `TimerTool` sets, lists and cancels named timers; `TimerCompletionWatch` rings them on the watch.
- The share extension activates on text, attachments and web URLs.
- Nothing called a guide exists. There is no linear step list outside `Procedure`.

---

## Design

### 1 · Who gets guides

**Recommended (decision 1):** guides are part of the app itself, for anyone who has bought it.
A guide made from your own photos and words, or from a recipe you share, needs no subscription. A
step whose picture is a region of a manual needs that manual on your shelf, which means My Manuals
(`personalManuals`) or Field Assist (`ownVaults`). So drafting a guide from a manual's step pages
lives in My Manuals, and that is the reason to subscribe, not the guides themselves.

Guides never count toward the five manuals or the new-manual allowance; they hold no manual text.

### 2 · A guide is not a procedure

`Guide` is its own type, in its own files, with its own runner and tool:

```json
{
  "kind": "guide",
  "format": 1,
  "id": "sourdough-loaf",
  "title": "Sourdough loaf",
  "needs": [
    { "name": "Strong white flour", "amount": "500 g" },
    { "name": "Dutch oven", "kind": "tool" }
  ],
  "steps": [
    {
      "id": "s1",
      "title": "Mix",
      "instruction": "Mix the flour, water and starter until no dry flour is left.",
      "figure": { "photo": "photos/s1.jpg", "alt": "A shaggy dough in a glass bowl." },
      "timer": { "seconds": 1800, "label": "Rest" }
    }
  ]
}
```

- **Linear only.** A list of steps, in order. No branches, no `expected_input`, no `calc_ref`, no
  `requires_confirmation`, no outcome, no evidence, no work record, no citations. The step fields it
  has are MI's: `title`, `instruction`, `figure`, `needs`, `group`. A guide adds only `timer`.
- **Separate decoder, separate kind.** A procedure file never decodes as a guide and a guide never
  runs through `ProcedureRunner`: `GuideCodec` refuses anything without `"kind": "guide"`, and a
  guard test fails if `Guide`, `GuideRunner` or the `guide` tool names `Procedure`, `fieldWork` or
  the procedure runner. This keeps JK's line structural: a personal subscriber who imported a
  procedure file would get a refusal, not a procedure with its branches removed.
- **`amount` on a need.** Recipes measure ("500 g", "2 tbsp"), they do not count. MI's need gains an
  optional free-text `amount` beside `count` (one or the other, never both), shared by both formats
  and accepted by MI's validator.
- **`needs` at the top as well as on steps.** A recipe's ingredient list is a whole-guide list; MI's
  `ProcedureNeeds.gather` becomes `StepNeeds.gather` and merges the guide's list with its steps'.

### 3 · Following a guide

- **Start it by voice or a tap.** "Start my sourdough guide" or the guide's row. The `guide` tool's
  actions are `list`, `start`, `next`, `back`, `repeat`, `needs`, `status` and `stop`. The model
  sees only the titles of the person's guides, never their contents, until one is started.
- **Before the first step** it says what is needed once, at most five items, as MI does, and the
  phone shows the full list to tick.
- **Each step** shows MI's step card: the picture, "Step 3 of 9", the step's needs and, when the step
  has one, a timer chip. Without a picture-drawing lens the step is spoken, and "what does it look
  like?" reads its `alt`.
- **The phone is a first-class place to follow it.** A guide screen in large type, one step at a
  time, readable from a worktop at arm's length, that stays awake while the guide runs, with
  **Back**, **Repeat** and **Next** buttons big enough for a floury knuckle. Voice works with the
  phone alone, so this needs no glasses.
- **The watch** shows the step's title and position and has Back, Next and the timer.
- **Timers are offered, not started** (decision 6). A step with a `timer` ends its instruction with
  "Say 'start the timer' for 30 minutes." The timer is an ordinary `TimerTool` timer named for the
  step ("Sourdough · Rest"), so it rings on the phone and the watch like any other and outlives the
  guide screen. "How long left?" answers from it.
- **Resume where you stopped.** The step you were on is kept per guide and offered next time ("Carry
  on from step 4, Shape?"); finishing or "start again" clears it.

### 4 · Making a guide

Three ways in, one review screen (MI's, with a guide's simpler rows):

1. **From a manual's step pages** (needs the manual on the shelf). "Make a guide from pages 12 to 18
   of the wardrobe instructions." MI's `StepPageDraft` proposes the steps with their picture regions
   and parts callouts; the person fixes and saves. The pictures stay references to the manual, as in
   MI decision 1, so a guide never carries the manufacturer's artwork.
2. **Card by card, with your own photos.** Add a step, take or pick a photo, say or type the
   instruction. On the phone camera or, hands-free, on the glasses: **"record as I go"** takes a
   photo with the glasses on each "next step", transcribes what the person says as that step's
   instruction, and ends on "that's it". The result is a draft for review, never a finished guide.
3. **From text you share or paste.** A recipe page shared from Safari, a list pasted from Notes.
   - A page that publishes structured recipe or how-to data (schema.org `Recipe` with
     `recipeIngredient` and `recipeInstructions`, or `HowTo` with its steps) is read
     deterministically by `StructuredHowToReader`: ingredients become needs with amounts,
     instructions become steps, and nothing is guessed.
   - Otherwise `NumberedStepSplitter` (pure) splits numbered or bulleted text into steps and a
     leading "Ingredients" or "You will need" list into needs.
   - Only when neither finds steps is a model asked, the on-device one first. A cloud provider is
     used only if it is the person's chosen provider and the sheet says the text will go to it.
   - **Words only from a web page** (decision 5): the page's own pictures are not kept, so a guide
     never carries someone else's photos. The source URL is kept with the guide.

Timers are proposed from the text ("rest for 30 minutes", "bake 40–45 min"; a range takes its
lower end and says so) and shown in the review for the person to keep or drop.

### 5 · Photos and privacy

- A photo taken to make a guide is a new camera-pixel consumer: `OutboundFrameConsumer` gains
  `personalGuideCapture`, with its scope, tap and mechanism, so `OutboundFrameConsumerTests` keeps
  covering it.
- **Recommended (decision 3):** the photo is taken through
  `CameraService.filteredStill(for:source: .photoOnly)`, so a bystander's face in someone's kitchen
  is blurred before it is stored. It differs from the wearer's framed shutter photo, which stays
  unfiltered, because a guide is something made to be followed and, later, maybe shared. The
  alternative is to treat it as the wearer's own photo and keep it unfiltered.
- Guides and their photos live in the app's container on this device, are included in the device's
  own backup, and are not synced (decision 7). The store registers with the data-store registry so
  "erase my data" and the data export cover guides, and the guard tests that enforce that pass.
- A guide's photos are never sent to a model by default. "Look at the picture" sends one through the
  existing staged-figure path under its rules, the same as MI.

### 6 · Limits

50 guides, 80 steps a guide, photos downscaled to 1,600 px on the long side and kept under 2 MB
(decision 7 asks to confirm the figures). A full library is refused with the counts, never by
dropping old guides.

### 7 · What stays out

- Sharing a guide with someone else, or receiving one (decision 4). The format is ready for it: an
  export would carry the author's own (filtered) photos and drop manual pictures to references.
- Branches, checks against the camera, and evidence; those are Field Assist's.
- Guides inside a job. A Field Assist subscriber can make personal guides, but the job tool set
  never offers them, and a guide never becomes a procedure.
- Fixed-position card layouts and importing decks from other guide services, for MI's reasons.
- Downloading pictures from web pages.

---

## Phases

- **P0 — the format and the runner (headless).** `Guide`, `GuideCodec` (the `kind` refusal),
  `GuideValidator` (MI's figure and need checks, plus timers 5 s–24 h and the limits of §6),
  `amount` on the shared need type, `StepNeeds.gather`, `GuideRunner` (position, resume, timer
  offers), `GuideStore` and its erasure registration, `NumberedStepSplitter`,
  `StructuredHowToReader` (fixtures: recipe and how-to pages written for the tests, no copied site
  content), the timer proposals, and the guard test of §2. About 40 tests. Needs MI P0's shared
  figure and need types first.
- **P1 — following a guide (headless + simulator).** The `guide` tool, the phone guide screen, MI's
  lens card for guide steps (needs MI P1), the watch keys, named timers, the spoken opener and
  resume. Simulator screenshots at the default and largest text sizes in both appearances, with an
  accessibility audit of the guide screen.
- **P2 — making a guide on the phone.** The guide list and editor, card by card with phone photos,
  share and paste with the review screen, and the from-manual-pages route in My Manuals (needs MI
  P3).
- **P3 — record as I go on the glasses.** `personalGuideCapture` on the roster, the glasses photo per
  step, the spoken instruction, the draft for review.
- **P4 — device pass (owed).** A real kitchen: the guide screen at arm's length, voice over a running
  tap and an extractor fan, timers ringing on the watch, a step picture on the Meta Display, and
  record as I go on Ray-Ban Meta.

P0–P1 are one PR, P2–P3 another, P4 a device report.

---

## Decisions for Greig

1. **Guides come with the app; a picture from a manual needs the manual on your shelf**
   (recommended). Photo and text guides then cost nothing on top of the app, and drafting from a
   manual's pages is a reason to take My Manuals. The alternative is guides for My Manuals
   subscribers only.
2. **A guide is its own linear type, never a procedure** (recommended), so the personal tier still
   cannot reach procedures, as Plan JK requires. The alternative, letting the personal tier run
   procedures with their branches removed, blurs the line between the two subscriptions.
3. **Photos taken for a guide go through the bystander blur** (recommended). The alternative is to
   keep them unfiltered, like the shutter photo.
4. **Sharing guides in a later plan** (recommended). The format is ready; the questions of what a
   shared guide may carry and how it is received are their own.
5. **Words only from a web page; its pictures are not kept** (recommended). The alternative is to
   keep the page's step pictures for the person's own use, never exported.
6. **Timers offered and started on the person's word** (recommended). The alternative starts them
   when the step is reached, which surprises anyone who reads ahead.
7. **This device only, no sync, and limits of 50 guides × 80 steps with photos under 2 MB**
   (recommended). The alternative syncs through iCloud, which would carry photos between devices but
   not the manuals a manual-picture step points at.

---

## Risks

- **A guide that looks like a free Field Assist.** Mitigated by §2: linear, no checks, no evidence,
  no record, its own runner, and a guard test that keeps it that way.
- **Splitting text badly.** Structured data first, a deterministic splitter second and a model
  last, always into a review screen, so a bad split is a moment's fix, not a wrong step at the oven.
- **Voice in a kitchen.** Running water and fans are hard on the wake word; the phone's buttons and
  the watch are first-class for that reason, and P4 measures it.
- **Record as I go and the camera LED.** Each photo is taken in view, on the wearer's word, with
  the capture light showing, as Meta's policy requires; nothing records between steps.
