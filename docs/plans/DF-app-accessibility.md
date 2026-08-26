# Plan DF — App Accessibility: VoiceOver, Dynamic Type & Contrast

**Status:** 🚧 P1 shipped 2026-08-25 (with DG P1, one PR) · **P2 complete 2026-08-26** — the
critical path (onboarding + sign-in, session surface, captions overlay, settings hub +
accessibility category) is operable with VoiceOver alone, with session state **announced** from
the state machine and deduplicated against the app's own audio · **P3 complete 2026-08-26** —
the system-wide sweep: every remaining screen's type, colour, motion and touch targets, plus a
new audited token family for the surfaces that put chrome on video rather than on the canvas ·
**P4 complete 2026-08-26** — the app's first UI-test target, auditing the critical path on every
run, which immediately found that neither onboarding nor the launch screen hid the app behind
them from VoiceOver. **All four phases shipped.** Still deferred, and stated: a manual VoiceOver
pass on hardware, and a session with a blind user whose judgement is the specification

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
Everything below was **static** conformance until P4: traits, grouping and focus order only exist
in a running UI. **Rows marked "audited" are now asserted by `OpenGlassesUITests` on every run**;
the rest of the table remains a reading.

| Rank | Screen | Phase | Name/role/value | State announced | Dynamic Type | Contrast | Targets ≥44pt | Reduce Motion | Not colour alone |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Onboarding (`OnboardingView`) | ✅ P2 · P4 | **audited** (P4) | **pass** (P2) | **audited** (P4) | **audited, `.secondary` deferred** (P4) | **audited** (P4) | pass | pass |
| 1b | Sign-in flow (`SignInSheetModel`, OAuth/Google rows) | ✅ P2 | **pass** (P2) | **pass** (P2) | pass | pass | pass | n/a | pass |
| 2 | Session controls (`BottomControlBar`, capsule) | ✅ P2 · P4 | **audited** (P4) | **pass** (P2) | deferred to DG P4 | deferred to DG P4 | **audited** (P4) — the capsule's element was 18pt inside a 50pt control until P4 | pass | pass |
| 3 | Status card (`StatusIndicator`) | ✅ P2 · P4 | **audited** (P4) | **pass** (P2) | deferred to DG P4 | deferred to DG P4 | **pills ~33×25, deferred to DG P4** (P4) | pass | pass |
| 3b | Transcript cards (`TranscriptOverlay`) | ✅ P2 | **pass** (P2) | n/a | deferred to DG P4 | deferred to DG P4 | pass | pass | pass |
| 4 | Settings hub (`SettingsView`) | ✅ P2 · P4 | **audited, folded + show-all** (P4) | **pass** (P2) | **audited at AX5; hero chip row deferred** (P4) | **audited, `.secondary` deferred** (P4) | **audited** (P4) | pass | pass |
| 5 | Accessibility settings (`AccessibilitySettingsView`) | ✅ P2 · P4 | **audited, both states** (P4) | **pass** (P2) | **audited; system `Form` chrome deferred** (P4) | **audited; system `Form` chrome deferred** (P4) | **audited** (P4) | n/a | pass |
| 6 | Ambient captions overlay | ✅ P2 · P3 · P4 | **audited** (P4) | **by design: none** | **pass** (P2) | **pass on the scrimmed line** (P3; see P3's findings) | **partial** — speaker chip ~20pt, handed to DG P4 | **pass** (P3) | pass |
| 6b | Model editor (`ModelEditorView`) | ✅ P4 | **audited** (P4) | n/a | **audited** (P4) | **audited; system `Form` chrome deferred** (P4) | **audited** (P4) | n/a | pass |
| 7 | The long tail (see P3's table below) | ✅ P3 | P2/P4 | n/a | **pass** (P3) | **pass** (P3) | **pass** (P3) | **pass** (P3) | **pass** (P3) |

Rank 7's name/role/value column stays P2's and P4's business: P3 is a *property* sweep and did
not touch semantics, so nothing here claims the long tail has been read with VoiceOver.

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
That is P4's target and this phase does not claim it. **P4 shipped the audit half**; the hardware
VoiceOver pass is still owed, and still deferred.

## P3 — System-wide sweep ✅ shipped 2026-08-26

Dynamic Type across OGDesign (no fixed sizes; test at AX5), contrast pass over the theme tokens
(including the accent-on-dark pairs), Reduce Motion variants for the ambience/waveline animations,
touch-target audit.

Pulled forward into P1, because they were properties of the components rather than of the
screens: the OGDesign token contrast pass (now `OGTheme.contrastAudit`, asserted in both schemes
for every accent preset — the accent-on-dark pairs are exactly what forced `inkAccentLabel`),
the ambience/waveline Reduce Motion variants, and the OGDesign side of the Dynamic Type and
touch-target work. What P3 still owed was the **screens**: fixed point sizes outside OGDesign
(`LaunchScreen`'s `.system(size:)` among them), an AX5 truncation pass per screen, and the
accent painted straight onto a surface without going through the tinted-label path.

### What P3 landed

A property sweep, deliberately not a redesign — DG P5 owns how the long tail *looks*, and this
phase changed only what a screen's text scales with, what its colours are read from, what its
animations do under Reduce Motion, and how big its targets are. Layout and behaviour are frozen
throughout, which is what makes a change this wide reviewable at all.

**Colour: 107 call sites onto the audited tokens, across 39 screens.** The pattern the sweep kept finding is the one
`OGStatusLabel` was built for — a `.green` checkmark, an `.orange` warning line, a `.red`
validation failure, hand-painted at the call site. Those hues are chosen to read as a 7pt dot;
as text on a white card the green measures about 2.2:1. Every one of them now reads from
`OGTheme.okLabel` / `warnLabel` / `errorLabel`, while the ones that really are *fills* — a
status dot, a progress tint, a capsule wash — read from the uncorrected `ok` / `warn` / `error`.
Several screens had a single `color(for:)` helper feeding both roles at once; those split into a
wash and a label variant, because one function cannot be right for both. `SafetyControlColor`
became the shared version of that split, so the HECA report and the evidence overlay stop
carrying private copies.

**A new token family, because a camera preview is not a canvas.** The audit had no answer for
the surfaces that lay chrome over *video*: the live preview, the phone camera sheet, the HUD
mirror. They are black in both schemes, so the card/canvas correction is the wrong one — the
failure hue needs lightening to read on a dark card and needs nothing at all on black. `Token.media`
plus `onMedia`, two opacity roles and `mediaOkLabel`/`mediaWarnLabel`/`mediaErrorLabel` name that
ground, and six new pairs in `contrastAudit` measure it. The tests assert both halves: that the
media labels clear AA on black, and that the media and card corrections *disagree* — if they
ever agree, one of the two surfaces is being measured wrongly.

**Type: 26 fixed point sizes onto Dynamic Type**, with two categories left fixed on purpose and
said so in the code. A decorative hero glyph (the lock on the biometric gate, the paywall's
cross, the settings lock) keeps its proportions through `@ScaledMetric` rather than becoming a
text style. And `HUDPreviewView` keeps real fixed sizes, because it is a fidelity mirror of a
fixed-geometry lens display: text that grew with the phone's setting would make the preview
misreport what the wearer actually sees.

**Motion: twelve decorative animations across nine screens** now ask first. The interesting one is the chat typing
indicator — three dots pulsing off a repeating timer for as long as a reply is in flight. It is
not a `withAnimation` call, so it survived the earlier passes; under Reduce Motion the timer
stops advancing and the dots hold steady, which says the same thing without the flicker. The
consent card and the pinned-frame card drop their slide and scale to a plain fade — the card
still arrives, only the travel goes.

**Targets: 18 sub-44pt controls across ten screens**, every one fixed by growing the *hit area* and leaving
the drawn artwork alone: the chat composer's 36pt glass circles, the preview's close button
(whose `.padding()` sat outside the button's hit region and so was never part of the target at
all), a Lock Screen power button, and a scatter of icon-only buttons that were tappable at about
20pt. Where the fix moved a glyph — the attachment's remove badge — the offset was rewritten in
terms of the target so it still lands on the corner it was drawn on.

**One contrast failure the sweep found rather than tidied.** A count badge and the LIVE capsule
both drew white text on the system notification red — about 3.6:1, under AA at the size a badge
is drawn in. `Token.badge` deepens the red instead of dropping a convention people read
instantly, and the test asserts the gap it exists to close: if the system red ever clears AA
under white, the token is unnecessary and should go.

### The sweep, by area

`fixed` names the kinds changed; `fine` means the screen was read against all five criteria and
needed nothing.

| Area | Fixed | Verified fine |
|---|---|---|
| Settings & services | `AgentHarness`, `AgenticFeatures`, `FieldAssist`, `Fingerspelling`, `Gateway`, `HermesBridge`, `HIPAA`, `Language`, `Playbooks`, `SafetyRules`, `Services`, `SiriExposure`, `SkillPacks`, `Sync`, `Tools`, `Translation`, `WebHUDMirror` (colour) · `QuickActions` (colour, type, target) · `SettingsView` (colour, type, motion) · `SettingsScreens` (badge contrast) | the remaining category screens |
| Tools, skills & integrations | `ClawHubBrowser` (colour, type, target), `CustomTools`, `MCPServers`, `MCPServerTrust`, `RemoteInvokeAudit`, `SuggestedSkills`, `CaptureFlowAuthor` (colour) | `MCPCatalog`, `ScheduledTasks`, `RemoteActionConsent`, `VoiceSkillsManager` |
| Models & personas | `LocalModelManager` (colour, target), `Personas`, `PersonaPickerSheet` (colour, target) | `AddModel`, `ModelEditor`, `ModelForm`, `ModelPricingEditor`, `PromptPresets`, `PromptInspector` |
| Vaults, documents & records | `VaultManager` (colour), `Recordings` (colour, target) | `VaultFilesEditor`, `HealthVaultEditor`, `Documents`, `MeetingRecords`, `ProjectDetail` |
| Learning | `Flashcard` (colour), `Quiz` (colour, **colour-alone**) | `DeckList`, `ReadingStats`, `Insights` |
| Assessment & medical | `AssessmentCard` (colour, motion, target), `SafetyAssessmentReport` (colour, type, target), `SafetyAssessmentOverlay` (shared colour split), `MedicalCompliancePaywall` (colour, type) | — |
| Media & HUD | `LivePreview` (all four), `PhoneCamera` (colour), `HUDPreview` (colour; sizes fixed on purpose) | `HUDMirror` |
| Chat | `ChatComposer` (type, target, motion), `ChatThread` (motion) | `ChatList`, `MessageBubble`, `MessageContentView` |
| Panels & shell | `LaunchScreen` (type), `RootView` (motion), `DeveloperPanel` (accent-on-fill), `AssistiveModeToggle` (motion), `ShortcutTemplates` (motion), `BiometricLock` (colour, type, motion), `NetworkMonitor` (colour) | `TurnTimelineDebug`, `SiriContentDetail`, `OnboardingOverlay` |
| Widgets | `GlassesActivityWidget` (type, target) | `HomeScreenWidget` — the listening state is carried by a sentence in every family, so the dot beside it is reinforcement, not the signal |

### Deliberately out of scope, and why

- **The session surface** (`MainView`, `VoiceTab`, `StatusIndicator`, `BottomControlBar`,
  `VoiceWaveline`, `TranscriptOverlay`, `CircleButton`, `QuickActionsOverlay`) — DG P4 sets its
  type scale, colour pairs and metrics, and doing them here would be deciding that phase's
  answers early. P2's checklist already records this division.
- **The record/live red.** `.red` on a recording dot, a stop glyph or a LIVE badge is a platform
  convention rather than a status hue, and it is never the only carrier — a duration, a label or
  a changed glyph sits beside it every time. The rule the sweep followed: ok/warn/error go
  through tokens; the record red does not.
- **The Dynamic Island's compact slot** keeps its 9pt battery readout. That slot is a hard
  geometry; text that grows there is text the system truncates away entirely, and the expanded
  and Lock Screen presentations carry the same number at Dynamic Type.
- **Two findings on the captions overlay, handed to DG P4 with its layout.** P2 recorded that
  surface as passing contrast, and on the live line — the one with a scrim behind it — it does.
  The rest does not have a ground: the history rows and the two-way legs sit directly on whatever
  is behind the overlay, so their contrast is unmeasurable rather than merely thin. P3 did what
  it can without touching the layout — every white in that stack now reads from the media
  opacity roles, and the three values that measured under AA even against pure black (the
  original-language ribbon at 0.35, the leg label at 0.4, the empty-leg placeholder at 0.25) are
  lifted to roles that clear it, hierarchy intact. The scrim itself is a layout decision and
  belongs to the phase that owns this surface. Likewise the speaker chip: its tap area is about
  20pt, and a 44pt floor would push four caption rows apart by roughly 27pt each — a reflow of
  the session surface, which is exactly what this phase was told not to do. Its *contrast* is
  fixed here, though: the chip painted white on eight palette hues, which the pale slots lose
  outright, and the label now goes through `onAccentLabel` like every other label on a filled
  ground.
- **The watch target and the widget's own palette.** Widgets render on a system material, not on
  `Token.canvas`, so the audited pairs would not describe them; giving the extension targets the
  token module is a target-membership change with its own blast radius, and the watch app is a
  separate target whose layout DG explicitly leaves alone. The widget fixes that *were* made are
  the ones that stand on their own: a Lock Screen target bumped to 44pt and a fixed size turned
  into a text style.

## P4 — Automated regression gate ✅ shipped 2026-08-26

The app's **first UI-test target**, `OpenGlassesUITests`, running
`XCUIApplication.performAccessibilityAudit()` per critical screen. Unit tests cannot do this —
`Wearables` fatals headless, and traits, grouping, focus order and rendered contrast only exist in
a running UI. It also retires most of the standing "onboarding has zero end-to-end coverage" gap:
the audit has to walk the flow to measure it.

**Coverage.** Onboarding pages 1–5 (welcome, provider, access key, services, permissions), the
session surface, the captions overlay with a seeded history, the settings hub in both of its
shapes (folded with Discover cards, and showing everything), the accessibility category before and
after its master switch reveals three sections, the model editor, and the settings hub at AX5. The
walk stops before onboarding's page 6: that is where the flow starts talking to the glasses —
camera permission and registration with the companion app — and a simulator has nothing to
register with, so driving into it produced a page that sometimes never arrived. A gate that fails
for a reason unrelated to what it measures is a gate people switch off. Pages 6 and 7 are built
from components audited on the five pages before them, over the same `centeredScroll` the AX5 test
drives, so what is unaudited there is their composition, not their parts.

Two launch arguments seed state, both `#if DEBUG` and inert without `-OGUITest`: a fresh install
(onboarding first) and a configured one (past onboarding, journey folded, optionally showing
everything or with the captions overlay populated). They seed persisted state and nothing else —
no screen behaves differently under them, and a Release binary contains none of it.

### What the audit found that three phases of reading did not

**The app behind the overlay was never hidden.** Onboarding is drawn *over* the tab view, not
instead of it, and the launch screen the same. Sighted users see a full-screen cover; VoiceOver
saw both trees at once — thirteen of the sixteen findings on the welcome page were the session
surface underneath it, a status card reporting "Glasses: Disconnected" and a capsule offering
"Connect & Talk" for an app the user has not finished setting up. A blind user swiping through
the welcome page fell out of the flow into a UI they could not see and had no business reaching.
This is the finding that justifies the phase: it is invisible to every method the earlier phases
used, and obvious the moment something reads the tree instead of the screen.

**Two controls whose accessibility element was not the control.** Left to itself, SwiftUI gives a
`Button` the union of its label's children rather than the frame it draws. The session capsule —
the control the whole surface is built around — was an 18pt-tall element inside a 50pt capsule,
and the glasses connection pill was the 13pt logo inside it. VoiceOver's focus ring landed inside
the control rather than around it, and the target an audit measures was the text, not the button.
`children: .ignore` at both sites makes the element the drawn control; the capsule now clears
44pt honestly rather than by assertion.

**A 4pt page indicator in the accessibility tree.** Onboarding's dots carried "Page 1 of 7" as a
label on a 120×4 element — a stop VoiceOver had to pass through and a target no finger could hit.
The dots are now decoration, and the position rides on each page's title as its *value*, which is
the element focus is moved to on every page change. It is heard on arrival, at the moment the
question is asked, instead of being findable beside it.

**Text the hero device card truncated at accessibility sizes.** `lineLimit(1)` on the status line
dropped "Not connected" outright at AX5 — the state of the device, on the card that exists to
report it. There the cap simply went; the row has the space.

**Sub-44pt targets on the field that gets the app working.** `SecretInputField`'s Paste and Reveal
buttons were bare glyphs measuring about 26×17 — on the screen a user has to operate to enter an
API key at all. Both grew a 44pt hit area with the drawn glyph left where it was, which is the
same fix P3 made eighteen times elsewhere and missed here.

### The AX5 onboarding hero, measured

P3 recorded this row as *unconfirmed* because it could see the subtitle running under the pinned
button in a preview and could not drive the scroll. Driven, the picture is precise: at AX5 the
welcome page's hero block (a `@ScaledMetric` logo, a `largeTitle`, and a four-line subtitle) is
taller than the scroll viewport the pinned footer leaves it, so **at rest the subtitle's last
lines are clipped by the bottom of the scroll view**, with nothing to say so. It is not a layout
that has to be rebuilt: the content does scroll, and a position exists where the subtitle reads in
full. What could not find it was a stock `swipeUp()`, which travels most of the screen and jumps
straight past the one position that works — which is exactly why P3 could not drive it. The test
drags a fixed 100pt instead, and the assertion is the real question: *does the layout have a
readable position*, not *does a coarse gesture happen to land on one*.

### Deferrals, each named where it is filtered

The audit-issue handler never suppresses a category wholesale. Every deferral names its audit
types, the surface it covers, and where the work lives, and prints what it filtered so a
suppressed finding is still visible in the run:

- **Session-surface type, colour and metrics** — the plan's own division of labour, unchanged
  from P2 and P3: the design phase that restyles this screen sets its numbers.
- **Session-surface targets** — the status card's connection pills are drawn at about 33×25. Their
  accessibility element now covers the drawn pill; growing the *pill* pushes the card's footer row
  apart, which is a metric on that surface.
- **Captions overlay ground and speaker chip** — as P3 recorded: no scrim to measure against, and
  a 44pt chip reflows the caption stack.
- **System `Form` chrome** — section headers and footers rendered by the system in its own
  secondary grey, on the OGDesign canvas rather than the system grouped background. One measured
  *failure* and several near-misses. Correcting it means styling every section header in the app.
- **`.secondary` at small sizes** — `OGRow`'s subtitle and the quiet button style both use the
  system secondary label at footnote/subheadline size, which clears AA as *large* text and misses
  it as body text. An audited secondary-copy token would touch every screen.
- **The hero card's chip row** — drawn in `caption2`, the smallest text style, whose scaling the
  system caps below the top of the accessibility range; and at AX5 three chips cannot sit side by
  side, so each is squeezed into a narrow column. A larger style and a wrapping row, both design
  changes to a shipped component.
- **Single-line text entry and system picker values** — a one-line field scrolls its text rather
  than growing the row at accessibility sizes, which the audit reports as text that may clip. That
  is the platform's behaviour for text entry; a multi-line API-key field would be a worse field.
- **`OGRow`'s value width**, and this one was *tried*. A settings row is a title, a subtitle and a
  value sharing one width, and at larger sizes they cannot all have it: the audit caught the value
  being cut (`“Openglasses”`, `System`). Removing the value's line cap moved the clip to the
  subtitle; giving the title column priority moved it to the title. Three strings, one width, and
  no version of "just remove the cap" that doesn't take the space from something else — so the cap
  stays, the finding is recorded, and which of the three yields (or whether the value belongs
  under the title rather than beside it) is left to the phase that owns the component's layout.
  The failed attempts are worth writing down: they are the evidence that this is a design
  decision rather than an oversight.
- **Content scrolled under the translucent tab bar** — the audit samples composited pixels, so
  `.primary` label copy, which cannot fail against the canvas, is reported as failing contrast
  where it slides under the bar. Filtered *by frame* to the bottom strip, so a genuine contrast
  failure anywhere else on the same screen still fails the test.
- **The onboarding page dots and the app behind the overlay** — both are hidden from VoiceOver as
  of this phase, and the audit still sees them, because it walks the **render** tree rather than
  the VoiceOver tree. Worth recording as a property of the tool: `.accessibilityHidden` fixes the
  user-facing problem without silencing the finding, and the two trees disagreeing is exactly why
  the overlay bug survived three phases of reading the code.

Of these, the `.secondary` contrast, the system `Form` chrome and the hero card's chips are
**catalogued, not dismissed**: they are real, they are app-wide, and they are the natural first
item for whichever phase next opens OGDesign's type and colour. The rest are properties of the
platform or of the audit, and are named as such.

### Settings unfold: the focus handoff, decided

P2 deferred one question to a running UI — when a Discover card unfolds, should VoiceOver focus
follow the new row up the page? Two things are now measured, and they point the same way.

The **precondition holds**: the unfolded category is in the tree as a row immediately after the
tap, so there is something to hand focus to, and the test asserts it. What cannot be measured is
the thing the question is actually about — XCUITest reports the accessibility tree, not the screen
reader's cursor, so "focus landed sanely" is not machine-checkable here at all.

The decision is therefore made on what the handoff would *cost*, and it is not built:

- It would talk over its own explanation. P2's announcement says where the row went — "added to
  the Settings list above" — and a focus move in the same beat makes VoiceOver read the newly
  focused row instead, replacing the sentence that explains what just happened with the thing it
  was explaining.
- It would strand a user working *through* Discover. The cards are a list, and unfolding three of
  them is a normal thing to do. Yanking focus to the top of the page after each tap turns that
  into three journeys back down.

So the row stays where it is and the announcement keeps its job. The judge of whether that is
right is the blind-user session this plan defers to — which is the honest answer to a question
about whether something feels sane, and a better one than a `@AccessibilityFocusState` line
nobody has heard in use.

### Known flaky, and what was done about it

A UI test is the flakiest kind there is, and pretending otherwise is how a gate loses its
credibility. What was actually observed over six full runs, and the state it ships in:

- **The first case of a run, at any content size.** A run installs a large Debug build and starts
  it cold, and that first launch occasionally produced a process with no UI in it — the app
  "running" with an empty accessibility tree — while every later launch in the same run came up in
  a couple of seconds. Seen twice, passing on re-run both times. Mitigated rather than papered
  over: waits are 60s, and `launch()` gives a UI that never appears one clean restart before
  believing it (`relaunchIfTheUINeverCameUp`). Green in the runs since, but it is the first thing
  to suspect if this target ever fails on case one and nothing else.
- **The CoreSimulator runner.** One run died mid-suite with "Simulator device failed to launch
  …xctrunner" — the known simulator flake, unrelated to the app. Recovery is shutdown → erase →
  boot → retry, which is what the run before this one did.

Neither is an accessibility failure, and neither is silenced with a skip. If either starts
recurring, hardening the launch path is the work, not loosening the assertions.

### MockDeviceKit, and why it is not here

`MockDeviceKit` is the SDK's mock-device kit and this target is the first place in the repo that
*could* use it — but the half that pairs a device (`MockDeviceKit.shared`, `startTestServer`) runs
inside the **app** process, and `MockDeviceTestClient` in the test process talks to it over a
local socket. Using it means linking the mock framework into the shipping app and compiling a
listening test server into the production binary, gated only at runtime. Nothing on the critical
path needs it — the hero card reports "Not connected" and audits perfectly well in that state —
so the cost buys nothing this phase wants. Recorded here so the next phase that *does* need a
paired surface starts from the constraint rather than rediscovering it.

### Running it

`OpenGlassesUITests` is its own scheme, deliberately outside the per-PR unit scheme. **Measured on
an M-series Mac against an iOS 27 simulator: about 13 minutes of test time for the fifteen cases**
(≈16½ minutes wall including the incremental build), because a UI test launches the app into a
simulator once per case and the audit has to render each screen before it can measure contrast and
hit regions. The unit suite is seconds. `.github/workflows/accessibility.yml` runs it nightly, on manual dispatch, and on
any PR labelled `accessibility`. A label rather than a paths filter, for two reasons: this gate
covers most of the app's view layer, so a path list broad enough to be correct would fire on
nearly every PR — and `paths-ignore` negation re-*includes* rather than excludes, which is a
footgun in a filter nobody reads twice.

Deferred, stated: a full manual VoiceOver pass on hardware, and — per CV P4's principle — a
session with a blind user whose judgement is the specification, covering both the app UI and how
it hands off to the in-ear assistive experience. An automated audit cannot tell you whether a
label reads *well*; it can only tell you one is there.

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
- ~~Whether `performAccessibilityAudit` runs in CI per-PR or as a nightly (it needs a booted
  simulator; cost unknown until P4).~~ **Resolved 2026-08-26 (P4): its own workflow — nightly,
  manual dispatch, and per-PR behind an `accessibility` label.** Measured, the suite is minutes
  rather than seconds: each case launches the app into a simulator and walks it, and the audit
  renders every screen before it can measure contrast and hit regions. Folding that into the
  per-PR unit gate would multiply the cost of the tracked gate for a class of failure that moves
  far less often than app code does — and the label keeps it available on the PRs where it
  matters. See P4's "Running it" for why the trigger is a label and not a paths filter.
- Whether the announcement wording should be user-tunable (terse vs. full sentences). Not built:
  a preference nobody has asked for is a setting to maintain, and the right judge is the blind-user
  session P4 defers to.
