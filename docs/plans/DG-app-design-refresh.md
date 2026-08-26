# Plan DG — App-Wide Design Language Refresh

**Status:** 🚧 P1 shipped 2026-08-25 (with DF P1, one PR) · P2 (onboarding) shipped 2026-08-25 ·
**P3 shipped 2026-08-26** — its model-selection slice first, then the hub + category screens with
the DE build · **P4 shipped 2026-08-27** — the session surface, and with it every accessibility
row DF had deferred to this phase · P5 planned

## Why

Eighteen months of plans built surfaces in whichever idiom the moment produced: OGDesign
(Plan CL) in the settings hub, a hand-rolled white-on-black onboarding, and a long tail of
screens — tools, vaults, browsers, panels — each styled locally. Individually fine; together
they read as several apps sharing an icon. With the App Store as the mainline channel and the
settings reorg (DE) deliberately courting **the curious user** — someone who signed in with one
tap and is now poking around to see what this thing can do — the whole app should speak one
design language, and it should be the *system's*: current-iOS materials and idioms, so the app
feels like it belongs on the phone from the first screen to the deepest panel, with the app's
own identity carried in a small number of deliberate signatures rather than in per-screen
invention.

Standing design decisions this plan inherits rather than reopens: the **capsule stays the
primary interaction**; the status card with merged pills and the coral waveline/ambience
treatment are approved signatures; the AI accent stays in the approved coral family (never
violet/cyan). DE owns settings *structure*; DF owns accessibility *criteria* — DG owns the
look, and every DG phase must meet DF's component criteria as it lands, not retrofitted.

## P1 — Foundation: tokens + components ✅ shipped

One PR over the OGDesign layer, shared with DF P1 since it touches the same files once:

- **Token pass**: semantic colour tokens with measured light/dark contrast (DF P3's ≥ 4.5:1
  becomes a property of the palette, not of each screen), type scale expressed in Dynamic Type
  text styles (no fixed sizes), spacing/radius scale, motion standards with Reduce Motion
  variants for the ambience/waveline animations.
- **Component pass**: OGDesign components adopt system materials where hand-rolled fills stand
  in for them today; every component gets its VoiceOver semantics (DF P1) in the same change.
- **Inventory**: the artefact that scopes the rest — every screen listed with its current idiom
  (OGDesign / custom / stock) and its target phase below.

## P2 — Onboarding ✅ shipped

Executes DD's design-refresh phase on P1's foundation (DD's sign-in mechanics are unchanged;
this is the visual half). Landed immediately after the DD build.

### What P2 landed

- **The flow stopped forcing dark.** `preferredColorScheme(.dark)` and a `Color.black` ground
  were the root of the old look; the pages now paint `OGTheme.canvas` and follow the user's
  appearance setting, which is why every page needed measuring in both schemes rather than one.
- **Every list-shaped page is a list.** Provider selection, credentials, optional services,
  permissions and the glasses hookup are grouped `List`s with `.ogFormStyle()` — system row
  materials, standard separators, a real `Section` header/footer for the labels and captions the
  old layout hand-placed. The two hero pages (welcome, ready) stay centred compositions, but
  their content moved into `OGCard` + `OGRow`, so they inherit P1's semantics and metrics
  instead of restating them.
- **The model picker** is a grouped selection list with a trailing check, the same shape the
  Settings model editor offers, replacing a 200pt nested `ScrollView` of custom pills.
- **Two token additions, both forced by measurement rather than taste.** `onAccentLabel` — a
  filled accent button treats the accent as *ground*, and the shipped coral needs white text in
  light and near-black in dark; picking one and hoping is how a filled button loses its
  contrast. And `okLabel`/`warnLabel`/`errorLabel` — the status hues are picked to read as a 7pt
  dot; the green measures ~2.2:1 as text on a white card, so "Key valid" and "Granted" go
  through the same `readable(_:on:)` correction the accent does. Both are in
  `OGTheme.contrastAudit`, asserted in both schemes; `onAccentLabel` is asserted across every
  accent preset.
- **`OGProminentButtonStyle` / `OGQuietButtonStyle`** replace the hand-rolled white slab and the
  0.4-opacity text link: accent-tinted, scaled-metric heights that clear 44pt at every Dynamic
  Type size, and a disabled state that drops to the system's inactive fill rather than a washed
  accent that still looks tappable.
- **Accessibility (DF P1 criteria) as part of the change, not after it:** the page title is a
  header and takes VoiceOver focus on every page change; selection rows carry `.isSelected`
  rather than relying on a coral tick; permission state says "Granted" in words; every icon tile,
  logo and tick is hidden from the tree; the "Grant" buttons name their permission; page
  transitions and the indicator animate only when Reduce Motion is off; the hero pages scroll so
  AX5 doesn't truncate them.
- Behaviour is untouched: seven pages in the same order, the Back chevron, the keyless
  "Start without an API key" card, the sign-in flows and their paste fallbacks, and every
  validation and save path. The one deletion is a duplicate "get your API key" row that rendered
  twice, with the same destination, whenever the field was empty.

## P3 — Settings

The hub and category screens, landing with DE's reorg — DE decides what's visible and in what
order; DG decides what it looks like. Discover cards are the first natively-DG component.

### Model selection ✅ shipped (2026-08-26)

Taken ahead of the rest of P3 because it is the one settings surface with a *twin*: onboarding
already rebuilt the same job — pick a provider, prove a credential, choose a model — in P2's
language, and two screens doing the same thing in two idioms is the exact complaint this plan
opens with. The Settings side now matches by construction rather than by resemblance.

- **The shared pieces are components, not copies.** `OGSelectionRow` (title, supporting line,
  trailing check, whole row as the target, `.isSelected` on the row) and `OGSelectionCheck` are
  the selection-list treatment P2 arrived at, lifted into `Components/` so the model editor and
  the model switcher render the same row type. `OGStatusLabel` does the same for the one-line
  outcome beside a control — "Key valid · 12 models", a validation failure, "Reachable — 40 ms" —
  which is where the raw `.green`/`.red`/`.orange` survived longest.
- **The model list is a grouped selection list.** The editor offered a `.menu` picker *and* a
  free-text model-ID field, which read as two different answers to one question; the list is now
  the same post-validation section onboarding shows, with the ID field kept below it for the
  models a fetch doesn't return.
- **Colour is token-driven and no longer load-bearing.** Every status hue in these screens goes
  through the corrected `okLabel`/`warnLabel`/`errorLabel` family; the three kinds also differ in
  glyph, so the state survives a monochrome reading. The model switcher's `eye` glyph became the
  word "Vision" in both the visible subtitle and the spoken label.
- **The sheets stop flashing cool grey.** `Add Model` and `Edit Model` adopt `.ogFormStyle()`, so
  a sheet raised from the warm canvas lands on it too.
- **DF P1 criteria in the same change**: 44pt-clearing scaled row heights on every field, button
  and menu row; decorative glyphs hidden; the validate row, sign-in rows and the deep link named
  rather than left to be read as their glyph plus text; spoken model-row wording extracted to a
  pure function so it is covered headlessly.
- Behaviour is frozen: model CRUD, fetch/validation, the loopback sign-in machinery and its paste
  fallbacks, and active-model switching all take the same paths as before.
- Owed to the DE build: `AIPersonalitySettingsScreen`'s own model rows (the entry point into the
  editor) and onboarding's private twins of `selectionCheck`, which should collapse into
  `OGSelectionCheck` when that file is next opened. — **both paid, see below.**

### Hub + category screens ✅ shipped (2026-08-26, with DE)

DE decided what is visible and in what order; this is what it looks like.

- **`OGDiscoverCard` is the first component designed for this language rather than adapted into
  it.** A card, not a row, because the two mean different things: a row is a destination, a card
  is an offer, and tapping it doesn't navigate — it turns itself into the row. It carries the
  icon tile, the pitch, and (when one is raised) the contextual note as a *sentence* with its own
  dismiss control, so the highlight survives a monochrome reading and reaches VoiceOver as the
  same thing the eye gets. Its spoken label is a pure function, covered headlessly.
- **The hub stopped hard-coding its own contents.** Rows and cards are both rendered from
  `CapabilityCatalog`, with the value summaries (wake phrase, active model, appearance, HUD
  state) resolved per category — so a layout change is a data change, and there is one place that
  decides what a hub row looks like.
- **Raw status colour left the category screens.** `AIPersonalitySettingsScreen`'s model rows
  (the `.green` tick / `.orange` warning pair) are now `OGStatusLabel`, with "Vision" as a word
  rather than an `eye` glyph and the spoken row extracted to a pure function; the medical
  compliance row's stacked `.green`/coral glyph pair became one `OGStatusLabel` plus the word
  "Subscription"; the recording indicator and the Simple-Mode auth failure moved onto the audited
  `errorLabel` family.
- **The accent swatches were the one place a selection was invisible.** The ring was white drawn
  *on top of* the swatch, which vanished on the pale presets in light mode; it is now drawn
  outside the swatch in the label colour, the swatch scales with Dynamic Type, and the target is
  a full 44pt square carrying `.isSelected`.
- **Onboarding's private `selectionCheck` is gone**, collapsed onto `OGSelectionCheck` at both
  call sites — the smallest possible diff in that file, and the last copy of that treatment.
- The three new DE screens are built in the same idiom as the existing category screens: stock
  `Form` under `.ogFormStyle()`, so they land on the warm canvas rather than flashing cool grey.
- Rider, decided 2026-08-26: **the appearance default is now `system`** in all three
  `@AppStorage("appAppearance")` declarations, and the Theme picker leads with System. An app
  that arrives following the phone's own appearance is the one that feels like it belongs on it.

## P4 — The session surface ✅ shipped (2026-08-27)

Main screen, capsule, status card, live-session controls. Highest-traffic surface, done after
the language is proven on P2/P3. The approved signatures (capsule, status card, waveline) are
polished within the language, not replaced.

### What P4 landed

**The signatures are the same shapes with measured numbers under them.** The status card still
opens with a tinted tile and a status line beside it, still merges the connection pills into its
footer, and the capsule is still the one large control on the screen. What changed is that none of it is
drawn in literals any more: eighteen fixed point sizes became text styles, the geometry that sits
*beside* type (the status tile, the pill glyph, the dock tile's glyph box, every status dot)
became `@ScaledMetric`, and every colour reads from the palette. The one place the drawn shape
moved at all is the status card's footer, and only because of the target work below.

**A hue on a wash of itself is one problem, and it now has one answer.** The status tile, the hero
capsule and the dock tiles all paint a colour on a faint tint of that same colour — the accent when
a session is live, the attention hue while it connects, the failure hue when it breaks, a grey when
nothing is happening. That is exactly the case `tintedAccentLabel` was built for in P1 and had only
ever been asked to solve for the accent presets; all four hues now go through it, and the suite
asserts the guarantee for the status hues as well. It also forced the one genuinely new token:
`Token.inactive`, a measured warm grey, because `.gray` is a value the palette cannot correct or
assert against and this surface tints a wash from whatever it is handed.

**The surface did not survive its own Dynamic Type, and that is the finding of the phase.** The
shipped layout is a fixed `VStack` — status card, waveline on two `Spacer`s, captions, transcript,
dock — and it fitted only because almost nothing in it grew: the status line, the mode line and the
dock captions were fixed point sizes, so at AX5 they rendered at exactly the size they do at
the default. Putting them on
Dynamic Type is the job of this phase, and doing it made the screen overflow at both ends at once:
the status card ran off the top, the dock off the bottom, and neither could be reached, because
`Spacer`s cannot absorb an overflow — they are already at zero. Measured on the simulator rather
than reasoned about; the before-and-after screenshots are what settled it.

Two layout adaptations, both scoped to accessibility sizes and neither touching the shipped
composition below that threshold:

- **The conversation zone scrolls and the dock stays pinned** — the same trade onboarding's hero
  pages make. The waveline does not come with it: it is decoration, it is already hidden from the
  accessibility tree, the status card is the source of truth for everything it expresses, and a
  reader who has asked for larger text has asked for more of the *content*, not for 76 points of
  ribbon to scroll past on the way to it. The signature is untouched everywhere it is visible.
- **A dock tile lays its glyph beside its label instead of above it.** Stacked, a tile at AX5 is
  around 130pt tall, and a row of them above the capsule leaves no screen for the conversation.
  Side by side the same tile is about one line high, and the row already scrolls horizontally — so
  the space it needs is the axis it has. Nothing is dropped or renamed; the parts change places.

**A 44pt target is a fingertip, not a type size.** The first cut of the pill and chip targets used
`@ScaledMetric`, following the row-height convention P1 established — which is right for a floor
under text that grows and wrong for a floor under a thumb: scaled by the body ratio, 44 reaches
about 130pt at AX5, a third of the screen for a control that draws at 25. `OGMetrics.minTouchTarget`
is a plain constant for that reason, and the same correction applies to the hero capsule, whose
fixed 50pt height became fixed *padding* around content that sets its own height — 22pt of glyph
plus 28pt of padding is the same 50pt at the default size, and grows only as far as the label does
rather than to the 155pt a scaled height would have produced.

**A disabled dock tile was rendering at about a quarter of its ink.** `.opacity(0.4)` sat on the
whole button, so it multiplied the label's own secondary weight — on a control whose entire job in
that state is to explain why it can't be used ("Start the live session first"). The blanket opacity
is gone and the dimming lives in the foreground colour, which is an audited value. This is the
find that most justifies doing the surface rather than only its checklist rows: nothing was
deferred about it, it simply had never been measured.

**Two touch targets that three phases declined to grow.** Both were deferred for the same honest
reason — the fix reflows a surface nobody was authorised to reflow — and both are made here, the
same way: the *target* grows, the drawn artwork does not.

- **The status card's connection pills** were drawn at about 33×25. They now carry a full scaled
  44pt target around a capsule that still looks the size it always did, and the card's footer row
  gave up its bottom padding to pay for most of it, so the card grows by single digits rather than
  by twenty points. A pill that *looked* 44pt would have been a different status card; this is the
  same card with a control a finger can land on.
- **The captions overlay's speaker chip** was about 20pt, and the reason it stayed there was that
  a 44pt floor pushes the caption rows apart. It does, and the cost is now paid — but only by the
  rows that cause it. A row grows to fit the chip only when it *has* a chip, so a single-speaker
  stack (the default, with diarization off) keeps exactly the density it ships with today. Two
  alternatives were considered and rejected: an overhanging target that takes no layout space puts
  44pt of tappable area on rows sitting 20pt apart, so three chips overlap and a tap near a
  boundary names the wrong speaker; and making the whole caption row the rename control gives the
  target for free but turns reading text into a rename gesture, which is new behaviour.

**The captions overlay got a ground, which is what made it measurable at all.** Only the live line
had a backing; the history rows and the two-way translation legs sat directly on whatever the
session surface was drawing, so their contrast was not *thin* — DF P3 was precise about this — it
was undefined. One opaque panel now sits behind the whole stack, and the roles each stepped up one
notch (full → secondary → tertiary) so the stack keeps a three-step hierarchy without reaching for
the quiet floor. Visually it also fixes something that was never quite right: one block behind the
whole stack reads as a caption panel, where before it was three floating lines with the fourth one
boxed.

**Opaque, and that was the second answer rather than the first.** The panel began as a 0.8 scrim,
with a `captionScrimToken` measuring the worst case (the scrim over the palest backdrop the app can
produce) and three new `contrastAudit` pairs against it. The arithmetic was fine and so were the
pixels — sampled on the simulator, the stack measured **8.8:1** on the history rows, **11.5:1** on
the live line and **6.0–6.4:1** on the speaker chips, over a ground at luminance 0.032, within
rounding of the token's prediction. The audit reported it as failing contrast anyway, and stopped
when the panel became opaque, which is what identified the mechanism (see below). So the scrim
token, its opacity role and its three pairs are gone: an opaque panel is the **media** ground the
palette already measures, the caption roles are covered by the `media …` pairs P3 established, and
at this darkness the two grounds differ by about 0.03 in luminance — nothing was traded for the
simplification.

**`OGRow`'s three-way width contest, decided by rejecting the premise — and it needed both halves.**
A settings row is a title, a subtitle and a value sharing one width, and DF P4's audit caught the
value being clipped. Capping it clips it; uncapping it takes the second line out of the subtitle;
giving the title priority takes it out of the title — all three were tried in that phase and all
three moved the clipping rather than removed it. They move it because three strings do not fit on
one line at AX5.

So the fix is two changes that only work together. Above the accessibility threshold the value
sits **under** the title with the row's full width, where it is no longer *beside* anything and has
no line to steal; and with that true, the line cap comes off **at every size**. The earlier attempt
failed precisely because it was the second change without the first. At everyday sizes there was
room all along — the cap was truncating values that would have fitted on a second line of a row
that grows anyway. Only *value* rows stack: a control row's trailing view is a switch, and a switch
under the title is a different control rather than a wrapped one.

The settings hub audits are the evidence, at AX5 and at the default size, with the filter gone.

**Behaviour is frozen.** Every control does what it did — the capsule's five states and their
actions, the long-press mute and its custom action, the pills' connect/disconnect, the dock's
ordering and contextual gating, the caption rename alert, the transcript sheet. The one deliberate
non-visual change is in the UI-test seed, not the app: two of the three seeded captions now carry
a diarized speaker, because without one the speaker chip never renders and the target this phase
spent its argument on was gated by nothing.

**DF P2's announcement wiring is untouched** — `SessionAnnouncer`, the policy, the capsule and
pill accessibility elements from P4's audit target all survive the restyle, and the audit suite is
what proves it.

### The audit deferrals this phase deleted

Not relaxed — deleted, with the underlying issue fixed. `SessionSurfaceAccessibilityTests` now
runs the audit's Dynamic Type, clipping, hit-region, trait and description checks **unfiltered** on
the highest-traffic screen in the app, and a new AX5 case audits the same surface at the top of the
accessibility range. Its contrast check is the exception, and it has its own section below.

| Deferral | How it closed |
|---|---|
| `sessionSurfaceVisuals` (contrast, Dynamic Type, clipping) | The surface's type scale and colour pairs are set: text styles throughout, every hue from the palette. Dynamic Type and clipping now run unfiltered here; contrast has its own, narrower filter for a reason about the tool (below). |
| `sessionSurfaceTargets` (the ~33×25 pills) | A 44pt target around the drawn capsule; the footer row's padding pays for it. |
| `captionsOverlayGround` (no ground, ~20pt chip) | An opaque media panel under the stack; a 44pt chip target, paid for only by rows that have a chip. |
| `rowValueWidth` (`OGRow`'s three strings) | The value stacks under the title at accessibility sizes, and the line cap comes off at every size. |

**Two deferrals were added**, and neither is about the surface's quality. The first is
`contrastThroughGlass`, which has its own section below. The second:
`focusableCaptionHistory` excuses the 44pt *target* check on a caption-history line: DF P2 made
each past line its own accessibility element so a VoiceOver user can swipe back through what was
said, and the audit sees an element and asks whether a finger could hit it — but the line has no
action, and the 44pt floor is a pointer-target criterion. Growing every caption row to 44pt would
push the stack apart to satisfy a check on something that is not a target. It is scoped to
**non-button** elements, which is a real scope rather than a formality: the speaker chip beside
those lines *is* a button, it is the control this phase grew, and it still fails the audit if it
ever shrinks back.

### The audit cannot measure contrast through translucency, and this is how that was established

The audit reported the hero capsule's label ("Connect & Talk", `Color(.label)` on the capsule's
glass) as failing contrast. Sampled from the simulator's own screenshot, that text measures
**20.5:1** — black on near-white. Two measurements disagreeing is not a conclusion, so the
mechanism was pinned down rather than assumed:

- The caption panel tripped the same check while it was a **0.8 wash**, on a stack whose pixels
  measure 8.8-11.5:1, and stopped tripping it when the panel became **opaque**. The panel is not
  glass, so "glass" was never the common factor.
- What the two share is a *translucent* ground. The check reads the declared background rather
  than the composite, so any partly-transparent ground looks to it like no ground at all. That is
  the same property DF P4 recorded for content scrolled under the translucent tab bar - and the
  reason that deferral exists too.

The caption panel is fixed rather than filtered, because opaque was the better answer anyway. The
capsule, the dock and the status card cannot be: Liquid Glass chrome *is* this surface. So
`contrastThroughGlass` defers `.contrast` here and nothing else - Dynamic Type, clipping, hit
regions, traits and descriptions stay live on this screen, which is where a real regression shows
up, and the colour work is asserted twice over without it: every pair the palette paints is walked
by `OGDesignContrastTests` in both schemes, and after this phase nothing on this surface is
hand-painted, so there is no colour here the headless suite does not already measure.

It is worth being plain that this is the one deferral in the change that covers a criterion the
phase was asked to close. The criterion is met - measured, twice - by a method the audit cannot
reproduce.

`appBehindTheOverlay` **stays**, with its reason rewritten. It survives for a reason that has
nothing to do with this surface's quality: contrast measured *through* a full-screen cover is
contrast against the wrong ground, and the audit walks the render tree rather than the VoiceOver
tree. Those same elements are now audited properly, and unfiltered, on the Voice tab — which is
the argument for keeping the deferral scoped to the cover rather than widening it.

### What P4 took from DF P4's app-wide catalogue, and what it left

Three of the five catalogued findings were app-wide rather than session-surface, and the phase took
the part it was already standing in:

- **`.secondary` at small sizes** — *partly paid.* `OGTheme.secondaryLabel` is the audited
  expression of that grey (the palette already measures it as "row subtitle on card"), and the
  session surface plus `OGRow`'s subtitle and value now read from it instead of from the system's
  semantic colour, which is a value the suite cannot inspect. `OGQuietButtonStyle` and the long
  tail of screens still use `.secondary`, so the deferral stays in the settings and onboarding
  audits. Genuinely partial, and recorded as such rather than claimed.
- **System `Form` chrome** — left. No `Form` on the session surface; nothing here to fix.
- **The hero card's chip row** — left. It is a settings-hub component, and DG P5 owns it.
- **Single-line text entry** and **content under the translucent tab bar** — left. Both are
  properties of the platform and of the audit rather than of the app, as P4 recorded.

### The scope call, recorded

P1's inventory lists fifteen files under P4, and this PR restyles nine of them: `MainView`,
`VoiceTab`, `StatusIndicator`, `BottomControlBar`, `TranscriptOverlay`, `AmbientCaptionOverlay`,
`VoiceWaveline` (which needed nothing — it is a `Canvas`, hidden from the accessibility tree, and
was already Reduce-Motion-aware as of P1), `QuickActionsOverlay` and `CircleButton`.

The six that moved to P5 are the **sheets and full-screen surfaces reached *from* the session
surface** rather than the surface itself — `LivePreviewView`, `PhoneCameraView`,
`SafetyAssessmentOverlay`, `AssistiveModeToggleView`, `ModelPickerSheet` and `PersonaPickerSheet`
(~800 lines on its own). The plan's P4 prose has always said "main screen, capsule, status card,
live-session controls"; each of these is a screen of its own with its own composition, four of
them were already property-swept by DF P3, and none of them is on the tab the audit gate stands in
front of. Batching them with the long tail keeps this PR reviewable and puts them with the other
sheet-shaped work.

`QuickActionsOverlay` and `CircleButton` are both **currently unreferenced** — the control dock
absorbed their call sites into its one tile idiom. They are restyled rather than deleted because
Plan Y cites the former as its phone-mirror reference and the inventory assigned the latter to
this phase; leaving an un-audited idiom in the tree for someone to reach for is the failure mode
worth avoiding. Whether they survive at all is a P5 question.

## P5 — The long tail

Everything in P1's inventory not yet covered (tools screens, vault managers, browsers, panels,
developer surfaces), batched into a small number of PRs by area, each mechanical once P1's
components exist.

## Non-goals

- Rebranding, renaming, or icon work.
- Information-architecture changes beyond what DE specifies.
- Reopening approved signatures (capsule primacy, status card, coral accent family).
- Accessibility criteria themselves — DF defines them; DG conforms.

## What P1 actually landed

- The palette moved out of `OGDesign.swift` into `OGDesignTokens.swift` as **explicit
  light/dark values** rather than system semantic colours — a semantic colour can't be
  inspected headlessly, so a measured palette has to carry its own numbers.
- `ContrastRatio` (pure: WCAG 2.2 relative luminance, alpha compositing, and a
  `readable(_:on:)` correction that blends toward black or white by the least amount that
  clears a threshold, so the hue family survives). `OGTheme.contrastAudit` names every
  text-on-surface pair the components paint, wash included, and the suite walks it in both
  schemes. Opacity roles are named for the same reason — a bare `0.4` in a component is a
  number nothing can assert against.
- Two derived accents fell out of the measurement rather than being designed up front:
  **`tintedAccentLabel`** (the accent as small text on its own faint tint — the raw accent
  is picked to read on a plain surface, and a wash of itself behind it eats the margin;
  the White preset vanishes outright), and **`inkAccentLabel`/`inkAccent`** (the hero card
  is ink in both schemes, so an adaptive accent's light-mode value — chosen to sit on white
  — measures well under AA there; both resolve against *dark* traits whatever the screen is
  doing, so the hero's tint and its label can't drift apart in light mode).
- The shipped Coral is barely moved by the correction (nil in dark), asserted, so the
  approved signature can't be repainted by a future token edit.
- Dynamic Type: the metrics that sit *beside* type scale with it — row height, icon tile,
  divider inset, status dot. `OGMetrics` derives the divider's inset from the row's own
  geometry so the hairline keeps meeting the text edge at AX5.
- Materials: hand-rolled neutral washes became `quaternarySystemFill`. This is the one
  visible delta — in dark mode the system fill is more present than the 0.072-white it
  replaced, which is the point (it is what the rest of iOS paints an inactive chip with).
  The accent family, the capsule and the status card are untouched.

## Open

- ~~Whether P5 batches by navigation area or by component usage~~ — **decided from the
  inventory**: the navigation areas are also component-usage clusters, so P5 batches by area.
- How far the watch and CarPlay surfaces participate (leaning: tokens yes, layout untouched).
  The inventory found no view files to convert — CarPlay renders through templates and the
  watch app is its own target — so this reduces to whether the tokens travel.
- The accent used as *text on a plain surface* is only guaranteed for the tinted-label path;
  a screen painting `accent` straight onto a card without going through OGDesign is not
  covered. Fold into P3.
