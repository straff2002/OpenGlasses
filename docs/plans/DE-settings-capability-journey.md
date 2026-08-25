# Plan DE — Settings Capability Journey

**Status:** ✅ **Shipped 2026-08-26** — P1 (pure core + invariants), P2 (hub + Discover) and P3
(four contextual moments) landed in one PR, carrying DG P3's settings remainder with them.

## Why

The mainline first-run is now: install from the App Store, sign in with the provider you already
pay for, talk. For that user the product is ready the moment sign-in completes — but the Settings
surface they can wander into is 26 screens and ~86 navigation links deep, built over eighteen
months of plans, and it presents everything at once. The existing hub (Plan CL) groups it into
seven categories, which is structure but not sequence: nothing tells a new user which three of
those categories are *for them today* and which ones are for the version of them that exists in a
month.

The instinct "default Simple Mode on" is the wrong vehicle, deliberately not taken: Simple Mode
(BM P10) is a **caretaker lock** — it hides the owner-config surface for handing the device to
someone else, and *exiting it requires Face ID*. Making it the newcomer default would put a
biometric gate between a curious user and their own settings, and would break the genuine handoff
case it exists for. Simple Mode stays exactly what it is, orthogonal to this plan.

What this plan builds instead is **progressive disclosure by intent, folded not locked**: the hub
opens showing the everyday surface, presents the rest as discoverable capabilities with one-line
pitches, and unfolds a category the moment the user shows interest — one tap, no gate, nothing
ever inaccessible.

## Decisions

- **Tiers are by user intent, not complexity:**
  - **Everyday** — voice & wake phrase, camera, captions/translation, **accessibility**,
    **Apple app integrations** (Home, Calendar, Reminders, Contacts, Music, Maps directions,
    Alarms), look & feel, glasses & privacy, diagnostics & support (Plan DC's surface).
  - **Creator** — streaming, recording, chat readback (the CY/CZ/DA surface).
  - **Power** — models & personas, tools & actions, automations, HUD.
  - **Pro & Org** — Field Assist, medical compliance, connections (MCP servers, gateways),
    agent mode.
- **Accessibility is Everyday, pinned — decided 2026-08-24.** Assistive features are free forever
  (Plan A) and a blind or low-vision user is a first-class day-one user, not a power user. The
  accessibility surface is always visible, never folded behind Discover, and — consistent with
  CT's rule that no org profile may withhold assistive features — no journey state may hide it
  either. This is enforced structurally: the catalog type marks the accessibility category
  un-foldable, with a test.
- **Apple-app integrations are Everyday — decided 2026-08-24.** "Turn off the lights",
  "what's on my calendar", "remind me to…" are day-one voice-assistant expectations, and the
  Apple set needs zero configuration — iOS's own permission prompts are the gate, and the
  high-impact-tool confirmation policy already covers the destructive cases. The Everyday hub
  gets a "Works with your iPhone" surface presenting these; third-party and self-hosted
  integrations (Home Assistant, MCP, gateways) stay in their later tiers. Note the tiers fold
  *settings visibility* only — voice capabilities themselves are unaffected by journey state.
- **Folded, not locked.** Non-Everyday categories render as **Discover cards** in the hub: icon,
  name, one-line pitch ("Stream what your glasses see, live"). Tapping unfolds the category into
  a permanent full row. No gate of any kind — the pitch *is* the journey. Agent mode keeps its
  existing separate `agentModeEnabled` consent gate on top; unfolding a card never flips a
  behavioural toggle, it only reveals surface.
- **Contextual unlock moments, few and quiet.** At the point of relevance the app may suggest the
  next capability *once*: first photo taken → recording card highlighted; display-capable glasses
  connect → HUD; a broadcast starts → chat readback. Phone-screen moments only — never TTS, never
  repeated, dismissal persists. Capped at a small fixed set (≤4) so this stays a journey, not a
  marketing channel.
- **"Show everything" toggle** in the hub for users who want the whole surface — one switch,
  unfolds all tiers permanently.
- **Existing users migrate fully unfolded.** Anyone with a completed onboarding from a prior
  version, or any non-default configuration inside a folded category, starts with everything
  visible. A visible setting disappearing on update is the one failure this plan is not allowed
  to have.
- **Tiers are not price tiers.** IAP/licence gating (Field Assist, Medical Compliance) stays
  exactly where it is; a Discover card may lead to a purchase page but the journey mechanism
  itself never sells.

## P1 — Pure core

`CapabilityTier` + `CapabilityCatalog` (category → tier, pitch line, un-foldable flag on
accessibility), `SettingsJourneyState` (persisted unfolded set + dismissed suggestions + show-all
flag), pure migration function (inputs: prior-install marker, per-category non-default detection →
initial unfolded set; fresh install → Everyday only), and `UnlockSuggestionPolicy` (event →
at-most-once suggestion, dismissal persists). All headless-tested, including the invariants:
accessibility never foldable, migration never hides a configured category, suggestions never
repeat.

## P2 — Hub rendering

The Settings hub renders Everyday categories as today, then a **Discover** section of cards for
folded tiers; unfold action; Show everything; Simple Mode section untouched. Category
content/screens are unchanged — this plan moves visibility, not settings.

## P3 — Contextual moments

Wire the ≤4 unlock events through `UnlockSuggestionPolicy` into a subtle hub-badge/highlight
(no interstitials, no TTS).

## What shipped

### The tier layout, as built

`CapabilityCatalog` is the whole layout as data. Twelve categories, in hub order:

| Category | Tier | Screen |
|---|---|---|
| Voice & Triggers | Everyday | existing |
| **Works with your iPhone** | Everyday | **new** — presents the existing Apple-tool switches |
| **Accessibility** | Everyday, **pinned** | existing screen, promoted to the hub |
| Glasses & Privacy | Everyday | existing |
| Look & Feel | Everyday | existing |
| Diagnostics & Support | Everyday | existing |
| **Capture & Streaming** | Creator | **new** — curated doors to recordings, meetings, streaming |
| **Display & HUD** | Power | **new** — the display switches and everything that draws on it |
| AI & Personality | Power | existing |
| Tools & Actions | Power | existing |
| Advanced | Power | existing |
| Connections | Pro & Org | existing |

The three new screens are *presentation*, not capability: every switch on them writes the same
`Config` value through the same setter, and "Works with your iPhone" asks iOS for permission
through the same code path the full tool list uses — `ToolPermissionGate`, lifted out of
`ToolsSettingsView` unchanged so two screens offering one switch cannot disagree about what it
means.

**The accessibility pin is structural, not a convention.** `FoldableTier` has no `everyday` case,
so `CategoryPlacement.discover(.everyday)` is not a representable state; and the assistive
category is built by `CapabilityCategory.pinnedAssistive`, which takes no placement parameter and
no Simple Mode parameter. A test walks every combination of show-all × unfolded-set × Simple Mode
and asserts the row is present in all of them. Accessibility also *moved up*: it used to be
reachable only through Tools & Actions — a category Simple Mode hides outright — so a wearer
handed the device in Simple Mode could not reach the assistive settings at all. It is now a hub
row, always visible, and the duplicate link inside Tools & Actions is gone.

### Migration

`SettingsJourneyMigration.initialState` is pure; `SettingsJourneySignals` is the `Config`-reading
measurement beside it. It runs once, in `OpenGlassesApp.init()` **before onboarding** — which is
the whole trick: a first-time user has not completed onboarding at launch, and after they finish
it they look exactly like an upgrader. A prior install unfolds everything; a fresh install gets
Everyday only; and anything configured is unfolded either way, which is the belt to that brace.

Two probes had to be written against what a fresh install actually *contains* rather than what it
sounds like it should: the model list is seeded (several models, on-device among them) and exactly
one persona is seeded, so "has models" and "has a persona" are both true on first launch. Verified
on a clean iOS 27 container: fresh install migrates to `unfolded: []`, and the same container with
`glassesDisplayEnabled` set and no journey state migrates to `unfolded: ["display"]` — the Display
& HUD row present with its "On" summary, everything else still a card.

### The four contextual moments

Capped at four, phone-screen only, at most once ever, dismissal persists, and suppressed entirely
once the target category is visible.

| Moment | Suggests | Where it is recorded |
|---|---|---|
| First photo saved | Capture & Streaming | `GlassesPhotoAlbum.saveImage` — every route into the album passes through it |
| Display-capable glasses connected | Display & HUD | the hub itself, from `glassesDisplay.hasDisplayCapability` — no service has to report it |
| A broadcast starts | Capture & Streaming (chat read-aloud) | `BroadcastService.startBroadcast` |
| The assistant asks before acting | Tools & Actions | `ToolConfirmationCoordinator.requestConfirmation` |

The fourth is this build's own choice: the confirmation prompt is the moment a user learns the
assistant *acts*, and the tool surface is where they decide what it may act on. The two Creator
moments deliberately share a card — they are independent routes to it, and whichever arrives first
spends the other.

The highlight is a sentence on the card with a dismiss control, not a dot: colour carries none of
the meaning and VoiceOver reads the same thing the eye does.

### Resolved open items

- **HUD → Power.** Drafted as Power and it stays Power, but it needed a home: the HUD switches
  live three levels down inside Hardware & Privacy, which is Everyday. Rather than relocate them
  (a non-goal), the new **Display & HUD** category presents them — same `Config` values, second
  door — which is also what makes the display-capable-glasses moment able to point somewhere.
- **Translation → Everyday**, as drafted, and no new category for it: live translation and
  captions are already reachable from Everyday surfaces (Look & Feel → Languages, and the
  Accessibility screen), and inventing a category to hold a setting that has not moved would have
  been structure for its own sake.

### Deliberate deviations

- Simple Mode's hidden set is unchanged in substance — it still hides the owner-configuration
  surface — but Accessibility is now always visible, and the three new categories are marked
  Simple-Mode-hidden so the caretaker view gains nothing it did not have.
- A Simple-Mode-hidden category is never pitched as a Discover card either: offering a card that
  leads nowhere is worse than saying nothing.

## Non-goals

- Any gate, biometric or otherwise, on seeing settings (that's Simple Mode's job).
- Removing or relocating individual settings; visual redesign — DE owns structure and
  visibility, Plan DG owns the look (its settings phase lands with this plan's P2).
- New capabilities — this plan only sequences the existing surface.
- Coupling tiers to pricing.

## Open

- Rename Simple Mode (e.g. "Handoff Mode") so "simple" is free for the default experience —
  leaning yes; needs Greig's call, and it's a rendered-string change so it rides its own commit.
  Deliberately **not** taken in this build.
- ~~Exact tier placement of HUD and translation~~ — **resolved above**: HUD is Power (with a
  Display & HUD category to hold it), translation is Everyday with captions and gains no category
  of its own.
- `advanced` is the one folded category with no configuration probe of its own — it is a set of
  inspectors, not settings — so an upgrader reaches it through the prior-install marker and a
  fresh install meets it as a card. Worth revisiting only if a developer surface ever grows a
  setting worth detecting.
