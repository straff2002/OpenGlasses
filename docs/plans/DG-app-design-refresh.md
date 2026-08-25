# Plan DG — App-Wide Design Language Refresh

**Status:** 🚧 P1 shipped 2026-08-25 (with DF P1, one PR) · P2 (onboarding) shipped 2026-08-25 ·
**P3's model-selection slice shipped 2026-08-26** · the rest of P3 rides with DE; P4–P5 planned

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
  `OGSelectionCheck` when that file is next opened.

## P4 — The session surface

Main screen, capsule, status card, live-session controls. Highest-traffic surface, done after
the language is proven on P2/P3. The approved signatures (capsule, status card, waveline) are
polished within the language, not replaced.

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
