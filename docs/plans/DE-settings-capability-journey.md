# Plan DE — Settings Capability Journey

**Status:** 📝 Drafted 2026-08-24 · build queued behind the CY–DC wave (touches the Settings hub, which Plan DC is editing)

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

## Non-goals

- Any gate, biometric or otherwise, on seeing settings (that's Simple Mode's job).
- Removing or relocating individual settings; visual redesign — DE owns structure and
  visibility, Plan DG owns the look (its settings phase lands with this plan's P2).
- New capabilities — this plan only sequences the existing surface.
- Coupling tiers to pricing.

## Open

- Rename Simple Mode (e.g. "Handoff Mode") so "simple" is free for the default experience —
  leaning yes; needs Greig's call, and it's a rendered-string change so it rides its own commit.
- Exact tier placement of HUD (drafted: Power) and translation (drafted: Everyday, with
  captions) — cheap to move; decide during P2 review.
