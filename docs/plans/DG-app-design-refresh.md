# Plan DG — App-Wide Design Language Refresh

**Status:** 🚧 P1 shipped 2026-08-25 (with DF P1, one PR) · P2–P5 planned — they ride with DD/DE and then sweep the rest

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

## P2 — Onboarding

Executes DD's design-refresh phase on P1's foundation (DD's sign-in mechanics are unchanged;
this is the visual half). Lands with or immediately after the DD build.

## P3 — Settings

The hub and category screens, landing with DE's reorg — DE decides what's visible and in what
order; DG decides what it looks like. Discover cards are the first natively-DG component.

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
