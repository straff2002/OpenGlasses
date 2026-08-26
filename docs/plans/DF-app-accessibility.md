# Plan DF — App Accessibility: VoiceOver, Dynamic Type & Contrast

**Status:** 🚧 P1 shipped 2026-08-25 (with DG P1, one PR) · **P2 complete 2026-08-26** — the
critical path (onboarding + sign-in, session surface, captions overlay, settings hub +
accessibility category) is operable with VoiceOver alone, with session state **announced** from
the state machine and deduplicated against the app's own audio · P3–P4 planned

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

Ranked by how much a blind user's first session depends on the screen. The criteria are the
WCAG 2.2 AA mapping from the top of this doc; `n/a` means the screen has nothing of that kind.
Everything below is **static** conformance — traits, grouping and focus order only exist in a
running UI, and asserting them is P4's job, not a claim this table makes.

| Rank | Screen | Phase | Name/role/value | State announced | Dynamic Type | Contrast | Targets ≥44pt | Reduce Motion | Not colour alone |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Onboarding (`OnboardingView`) | ✅ P2 | pass | **pass** (P2) | pass | pass | pass | pass | pass |
| 1b | Sign-in flow (`SignInSheetModel`, OAuth/Google rows) | ✅ P2 | **pass** (P2) | **pass** (P2) | pass | pass | pass | n/a | pass |
| 2 | Session controls (`BottomControlBar`, capsule) | ✅ P2 | **pass** (P2) | **pass** (P2) | deferred to DG P4 | deferred to DG P4 | deferred to DG P4 | pass | pass |
| 3 | Status card (`StatusIndicator`) | ✅ P2 | **pass** (P2) | **pass** (P2) | deferred to DG P4 | deferred to DG P4 | n/a | pass | pass |
| 3b | Transcript cards (`TranscriptOverlay`) | ✅ P2 | **pass** (P2) | n/a | deferred to DG P4 | deferred to DG P4 | pass | pass | pass |
| 4 | Settings hub (`SettingsView`) | ✅ P2 | **pass** (P2) | **pass** (P2) | pass | pass | pass | pass | pass |
| 5 | Accessibility settings (`AccessibilitySettingsView`) | ✅ P2 | **pass** (P2) | **pass** (P2) | pass (stock `Form`) | pass | pass | n/a | pass |
| 6 | Ambient captions overlay | ✅ P2 | **pass** (P2) | **by design: none** | **pass** (P2) | pass | pass | pass | pass |
| 7 | The other ~90 screens | P3/P5 | — | — | — | — | — | — | — |

"deferred to DG P4" is the plan's own division of labour, not an unaudited gap: DG P4 owns the
session surface's *look*, so its type scale, colour pairs and metrics are decided there. P2 took
the half that is independent of the restyle — what the controls are called and what they announce —
and left the visual criteria to the phase that sets them.

## P2 — Critical-path conformance ✅ shipped 2026-08-26

Onboarding (including DD's sign-in sheet — `SFSafariViewController` is natively accessible; the
custom pages around it are not), the main session surface (start/stop, mode state changes
*announced*, not just re-rendered), captions overlay, Settings hub + accessibility category.

### What P2 landed

**Announcement, and the subtraction that makes it bearable.** The session's state now reaches
VoiceOver as speech, wired at the state machine (`AppState.configureAccessibilityAnnouncements`)
rather than in the views — a view announces only while it is on screen, and this session runs
hands-free with the phone in a pocket, so the moment worth reporting is usually the moment
nothing is rendering it. Every surface inherits the same narration, and there is one list to
read when asking what a blind user is told.

The harder half is what is *not* said. This app talks: an ascending cue when the glasses attach,
a chime opening every turn, an end tone closing it, a descending cue on disconnect, an ambient
pad while a turn runs, and its own voice for the answer. Announcing those again puts two voices
in one ear a half-second apart — worse, for the user this phase exists for, than saying nothing.
So `SessionAnnouncementPolicy` is a subtraction: a transition earns a line only when the app is
otherwise silent about it, and every announcement is withheld outright while the assistant has
the floor. What that leaves is exactly the state a blind user had no access to at all — a live
session starting or ending, the camera starting or stopping, a reconnect, the mic muting, and an
error. "Thinking" is the interesting case: covered by the pad *while the pad plays*, and spoken
when something stopped it, because the cue's presence decides rather than the event's name.
`SessionAnnouncer` adds the other guard — said once — since a `@Published` flip can arrive more
than once for one real transition, and a screen reader that repeats itself is one the user turns
off. Both halves are pure enough to be covered headlessly.

**The session surface**, semantics only (DG P4 owns its look, untouched here): the status row
became one sentence instead of three stops that had to be assembled by swiping ("Listening…",
"Voice middle dot Claude", "Camera streaming"), with the middot as the pause it was drawn to be;
the card's own label stopped restating what the row now says properly. The capsule's visible copy
is written as an instruction to a finger — "Tap to talk", "Tap to stop" — which is the wrong
gesture and the wrong grammar for VoiceOver, so it carries a spoken name instead, with the mute
badge as a *value* so it is re-read when it changes. **Mute was unreachable**: it lives only on a
long press, and VoiceOver swallows that gesture for its own use — it is now a named custom action
as well as a hint. Dimmed controls say why they are dimmed. And the transcript card announced who
was talking and never what they said: `children: .combine` followed by `.accessibilityLabel`
*replaces* what was combined, so the words — the only thing on that card worth reading — were
unreachable.

**Onboarding and sign-in.** DG P2's conversion had already landed the page semantics; what it
left was the *async* half. The permission rows, the key validation, the Meta AI registration and
both OAuth flows all resolved in silence: a grant swaps a button for a checkmark somewhere down
the list, a refusal changes nothing at all, and the sign-in sheet **dismisses itself** on success
and drops the user on a screen where a button has quietly become a spinner. Every one of those
endings is now spoken, and refusal is spoken too, because it is the answer that stalls the flow.
The sign-in wording lives on `SignInFlowState` — both the loopback and paste paths land on that
one state, so neither surface can be the one that forgets.

**Settings.** DE's rebuild had already announced *unfolding* a Discover card; it had never
announced the unlock moment **arriving**, which is the one thing the whole mechanism exists for —
a card further down the page grows a border and a sentence while the user is reading elsewhere.
That now announces once per moment (the store's `deliveredMoments` guard makes re-entry
impossible) and names the dismiss control. The unfold line says *where* the row went, because the
card the user was standing on disappears in the same beat. On the accessibility screen itself,
the master switch reveals three sections below it and now says so.

### Open questions this phase closed

- **Captions overlay: readable history, not a live region — decided.** Captions are speech that
  already happened in the room. A blind user heard it; pushing every line back at them through
  VoiceOver would narrate the conversation a beat late and bury the app's own state
  announcements. The people this surface serves — deaf and hard-of-hearing users — read it with
  their eyes. So: no `.announcement` posts, per-row focusable history so the last few lines can
  be swiped back through, `.updatesFrequently` on the live line so it re-reads only for someone
  who chose to hold focus there, and Dynamic Type throughout (the fixed 16pt caption did not
  grow with the system text size — which failed exactly the reader it was drawn for).

### Still owed

The running-UI audit — traits, focus order, grouping, and a real VoiceOver pass on hardware.
That is P4's target and this phase does not claim it.

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

- ~~Whether the captions overlay should offer a VoiceOver-native live region or stay a visual-only
  surface with a focusable history.~~ **Resolved 2026-08-26 (P2): focusable history, no live
  region.** The lean was right and the reason sharpened in the building — a blind user already
  heard the room, and forced announcements would both narrate the conversation back at them a
  beat late and crowd out the session-state announcements that carry information they *don't*
  have. See "Open questions this phase closed" above for the shape that shipped.
- Whether `performAccessibilityAudit` runs in CI per-PR or as a nightly (it needs a booted
  simulator; cost unknown until P4).
- Whether the announcement wording should be user-tunable (terse vs. full sentences). Not built:
  a preference nobody has asked for is a setting to maintain, and the right judge is the blind-user
  session P4 defers to.
