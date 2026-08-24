# Plan DF — App Accessibility: VoiceOver, Dynamic Type & Contrast

**Status:** 📝 Drafted 2026-08-24 · P1 can start any time; P2's onboarding slice lands with/after Plan DD (same screens)

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

## P1 — Audit + component-level fixes

- Fix at the **OGDesign component layer first** so it propagates: `OGRow` (label + value + trait
  composition, chevron/toggle semantics), toggles (`.accessibilityLabel` from the row title, not
  the empty `Toggle("")`), `OGHeroDeviceCard` (one summarised element, chips grouped), decorative
  elements (`waveline`/ambience) hidden from the accessibility tree, capsule and session controls
  given names, values, and hints.
- Produce a ranked screen checklist (in this doc, updated as audited): onboarding → main talk
  surface/capsule → settings hub → accessibility settings themselves → ambient captions overlay →
  everything else. The checklist is the audit artefact; each screen gets pass/fail per WCAG
  criterion.

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
