# Plan DG — App-Wide Design Language Refresh

**Status:** 📝 Drafted 2026-08-24 · P1 launchable now (pairs with DF P1 — same component files, one PR); later phases ride with DD/DE and then sweep the rest

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

## P1 — Foundation: tokens + components (launchable now)

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

## Open

- Whether P5 batches by navigation area or by component usage (decide from P1's inventory).
- How far the watch and CarPlay surfaces participate (leaning: tokens yes, layout untouched).
