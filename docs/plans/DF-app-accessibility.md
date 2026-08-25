# Plan DF — App Accessibility: VoiceOver, Dynamic Type & Contrast

**Status:** 🚧 P1 shipped 2026-08-25 (with DG P1, one PR) · **P2's onboarding slice shipped
2026-08-25** with DG P2 (the screens converted, so the semantics landed with the look) ·
the rest of P2 (session surface, captions overlay, hub) and P3–P4 planned

## Why

The product's assistive features are free forever (Plan A) and growing (CV continuous narration);
a blind wearer is one of the app's most important users. But the *app itself* — the thing that
user must operate to reach those features — has never been audited for non-visual use. The UI is
built from custom OGDesign components and a fully hand-rolled onboarding, which is exactly the
construction that quietly loses VoiceOver semantics: hand-rolled rows that read as undifferentiated
text, toggles without traits or labels, decorative wavelines announced as images, a dark custom
onboarding whose contrast was never measured. If a blind user cannot complete onboarding and start
a session with VoiceOver alone, the accessibility tier is a promise the front door breaks.

Reference standard: **WCAG 2.2 AA**, mapped to iOS: complete VoiceOver semantics (labels, traits,
values, grouping, focus order, announcements), Dynamic Type without truncation, contrast ≥ 4.5:1
for text, touch targets ≥ 44 pt, Reduce Motion respected, no meaning carried by colour alone.

## P1 — Audit + component-level fixes ✅ shipped

- Fix at the **OGDesign component layer first** so it propagates: `OGRow` (label + value + trait
  composition, chevron/toggle semantics), toggles (`.accessibilityLabel` from the row title, not
  the empty `Toggle("")`), `OGHeroDeviceCard` (one summarised element, chips grouped), decorative
  elements (`waveline`/ambience) hidden from the accessibility tree, capsule and session controls
  given names, values, and hints.
- Produce a ranked screen checklist (in this doc, updated as audited): onboarding → main talk
  surface/capsule → settings hub → accessibility settings themselves → ambient captions overlay →
  everything else. The checklist is the audit artefact; each screen gets pass/fail per WCAG
  criterion.

### What P1 landed

- **`OGRow`** composes title and subtitle into one thought; a *value* row becomes one element
  carrying the button trait its chevron already promised, while a *control* row keeps its
  children focusable, because a switch has to stay reachable.
- **`OGRow(_:isOn:)` / `OGToggle`.** `Toggle("", isOn:)` plus `.labelsHidden()` reaches
  VoiceOver as an *unnamed* switch — the modifier only hides the label visually, so the row
  title was never attached to it. Every bare-`Toggle("")` site in the app is now named.
- **`OGHeroDeviceCard`** reads as one sentence — identity, state, power, then what the device
  can and can't do, chips grouped by availability instead of spilling as loose stops.
- **No meaning by colour alone**: an unavailable chip says "unavailable" rather than merely
  going grey. Pills turn their middot separator into a pause (VoiceOver reads it as "middle
  dot"); badges are read as written, not as displayed (short all-caps gets spelled out).
- **Decoration hidden**: icon tiles, chevrons, status dots, hairlines. The waveline and
  ambience were already hidden and stay so.
- **Touch targets**: the 52pt row floor now scales with Dynamic Type, so it clears 44pt at
  every size rather than only at default.
- **Reduce Motion**: the waveline holds a still frame (its *shape*, not its travel, is what
  distinguishes the four states), the ambience stops breathing, and the launch glow fades up
  once instead of pulsing for as long as the screen is up.
- The spoken strings are **pure functions**, so the wording is covered headlessly — traits,
  grouping and hidden decoration only exist in a running UI and belong to P4's audit target.

### Ranked screen checklist

Ranked by how much a blind user's first session depends on the screen. `—` means not yet
audited: P1 fixed the component layer and left the per-screen pass/fail to the phase that
converts each screen, since a screen's semantics change when its idiom does.

| Rank | Screen | Phase | State after P1 |
|---|---|---|---|
| 1 | Onboarding (`OnboardingView`, sign-in sheet) | ✅ P2 | Converted with DG P2: pages built from OGDesign rows and stock grouped lists, so P1's semantics apply; each page's title is a header and takes VoiceOver focus on page change; selection carries `.isSelected`; permission state is said in words; decoration hidden; Reduce Motion honoured; hero pages scroll at AX5. All text on contrast-asserted token pairs (`onAccentLabel`, `okLabel`/`errorLabel` added for this screen). Owed: the running-UI audit, which is P4's target. |
| 2 | Main session surface (`VoiceTab`, `BottomControlBar`, capsule) | P2 | Controls already carry labels, selected traits and hints; decorative waveline/ambience hidden. Outstanding: mode/state changes **announced**, not just re-rendered. |
| 3 | Status card (`StatusIndicator`) | P2 | Already grouped with a composed label. Re-audit when P4 restyles it. |
| 4 | Settings hub (`SettingsView`) | ✅ P1 | Built from OGDesign, so it inherits everything above: hero card summarised, rows composed, both switches named. Re-audited when DE rebuilt it (2026-08-26): the new `OGDiscoverCard` reads as one element with a spoken label covered headlessly, its dismiss control is named and clears 44pt, the Discover heading carries the header trait, unfolding posts an announcement (the change happens further up the page, where VoiceOver would otherwise miss it), and the unfold/show-all animations are skipped under Reduce Motion. |
| 5 | Accessibility settings (`AccessibilitySettingsView`) | P2 | — stock `Form`; stock controls are natively labelled, but never audited. Free forever per Plan A, so it must not be the weak screen. |
| 6 | Ambient captions overlay | P2 | — Dynamic Type and the live-region question are open (see below). |
| 7 | The other ~90 screens | P3/P5 | — see [the DG screen inventory](DG-screen-inventory.md) for which idiom each is in and which phase converts it. |

## P2 — Critical-path conformance

Onboarding (including DD's sign-in sheet — `SFSafariViewController` is natively accessible; the
custom pages around it are not), the main session surface (start/stop, mode state changes
*announced*, not just re-rendered), captions overlay (Dynamic Type, and consider
`UIAccessibility.post(notification:)` for live caption updates vs. VoiceOver chatter — likely an
opt-in "speak captions" is wrong, but focusable transcript history is right), Settings hub +
accessibility category.

## P3 — System-wide sweep

Dynamic Type across OGDesign (no fixed sizes; test at AX5), contrast pass over the theme tokens
(including the accent-on-dark pairs), Reduce Motion variants for the ambience/waveline animations,
touch-target audit.

Pulled forward into P1, because they were properties of the components rather than of the
screens: the OGDesign token contrast pass (now `OGTheme.contrastAudit`, asserted in both schemes
for every accent preset — the accent-on-dark pairs are exactly what forced `inkAccentLabel`),
the ambience/waveline Reduce Motion variants, and the OGDesign side of the Dynamic Type and
touch-target work. What P3 still owes is the **screens**: fixed point sizes outside OGDesign
(`LaunchScreen`'s `.system(size:)` among them), an AX5 truncation pass per screen, and the
accent painted straight onto a surface without going through the tinted-label path.

## P4 — Automated regression gate

Introduce the app's **first UI-test target** (unit tests can't do this — `Wearables` fatals
headless, and VoiceOver semantics only exist in a running UI) running
`XCUIApplication.performAccessibilityAudit()` per critical screen, with MockDeviceKit where a
paired device is needed. This is the deterministic gate that keeps P1–P3 from rotting; it also
retires the standing "onboarding has zero end-to-end coverage" gap for free.

Deferred, stated: a full manual VoiceOver pass on hardware, and — per CV P4's principle — a
session with a blind user whose judgement is the specification, covering both the app UI and how
it hands off to the in-ear assistive experience.

## Non-goals

- Web/marketing-site accessibility (separate surface).
- Visual redesign (DD owns onboarding's look; DE owns settings sequencing — DF constrains both:
  their builds must meet P1's component criteria rather than re-fixing after).
- Braille-display-specific work beyond what correct VoiceOver semantics provide.

## Open

- Whether the captions overlay should offer a VoiceOver-native live region or stay a visual-only
  surface with a focusable history (leaning the latter — a blind user already has the audio).
- Whether `performAccessibilityAudit` runs in CI per-PR or as a nightly (it needs a booted
  simulator; cost unknown until P4).
