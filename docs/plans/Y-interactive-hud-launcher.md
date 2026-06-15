# Plan Y — Interactive HUD Launcher (Display Phase 4)

**Source pattern:** Builds directly on [Plan X](X-interactive-hud-now-next-tasks.md) (Display Phase 3), which introduces the `HUDRouter` / `HUDScreen` nav stack and proves band navigation on a single Now/Next card. Phase 4 turns that one card into a **navigable launcher**: a hands-free home on the lens for starting and switching everything the app can do.

**Strategic fit:** Every surface the launcher exposes already exists and is already enumerable at runtime — Quick Actions ([Config.swift](../../OpenGlasses/Sources/Utils/Config.swift) `quickActions`), Playbooks ([PlaybookStore.swift](../../OpenGlasses/Sources/Services/PlaybookStore.swift)), Field Assist Procedures ([ProcedureLibrary.swift](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureLibrary.swift)), and Modes/Personas ([Config.swift](../../OpenGlasses/Sources/Utils/Config.swift) `AppMode` / `Persona`). Y is the menu/router glue that makes them reachable from the band without touching the phone.

**Scope decision (agreed):** ship **all four surfaces in one release** — Quick Actions · Workflows · SOPs · Mode/Persona. (Native-tool browse is a natural later add via [NativeToolRegistry.contextualToolNames()](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift) but is **out of scope** for this release to keep the menu shallow.)

**Input model (agreed):** **Band + voice + phone.** Band navigates/selects inside a screen; voice gives parallel commands ("menu", "quick actions", "start <name>", "back"); the phone mirrors the same menu for fallback/setup.

**Effort:** ~4–6 days (on top of X).

**Status:** ✅ Feature-complete (headless-validated; no Display hardware yet). Shipped: the navigation **stack** in `HUDRouter` (open/push/pop/dismiss + `resumeTask`), `HUDMenuBuilder` + `HUDLauncher` with **all four branches** — Quick Actions · **Workflows** · **SOPs (Field Assist)** · Mode/Persona — plus a dynamic **Resume task** root item; Workflows and SOPs hand off to the Plan X Now/Next card (`startTask` supersedes the open menu and re-presents it on resume/close). Also shipped: **in-menu voice navigation** (`HUDLauncher.handleVoiceSelection` — say an item's label, or "back"/"close"), **pagination** (>6 items → a `More…` pager, shared `listScreen` helper), a voice "menu" open trigger, and the live on-phone mirror (`HUDPreviewView`/`HUDMirrorView`) walking the same `FlexBox` tree `makeScreenView` builds. 38 HUD tests pass; Debug + Release verified. Remaining (optional): Settings to choose branch visibility/order; a band "home" open-gesture if the device exposes one.

---

## What we enable (the four launcher branches)

```
HUD ROOT  (opened by band gesture / voice "menu" / phone)
│
├─ ▶ Resume task            → only when a Playbook/Procedure is active → Plan X card
├─ ⚡ Quick Actions         → list Config.quickActions → select runs it
│      • photo / prompt / photo+prompt / Home Assistant / Siri shortcut / open app
├─ 📋 Workflows             → list Playbooks → start → Plan X Now/Next card
├─ 🛠 SOPs (Field Assist)   → vault → procedure → start → Plan X card (branching)
└─ 🎛 Mode / Persona        → switch AppMode / activate a Persona → confirm flash
```

Each leaf either (a) drops into the [Plan X](X-interactive-hud-now-next-tasks.md) task card (workflows/SOPs), or (b) runs an action and shows a **confirmation flash** then returns to its list. Quick Actions reuse the exact dispatch already behind [QuickActionTool.swift](../../OpenGlasses/Sources/Services/NativeTools/QuickActionTool.swift) / [QuickActionsOverlay.swift](../../OpenGlasses/Sources/App/Views/QuickActionsOverlay.swift); mode/persona switching reuses `AppState.currentMode` / `activePersona`.

---

## How the user interacts

**Inside a screen** — the band traverses focus over the screen's `Button`s and pinch-selects; the SDK fires that button's `onClick` (per [Plan X](X-interactive-hud-now-next-tasks.md) SDK notes). Selecting a category **pushes** a child screen; **Back** (a button on every non-root screen) **pops**.

**Navigation rules (legibility-driven):**
- **≤ 6 items per screen.** Long lists (many playbooks/quick actions) **paginate** with a "More…" item rather than scroll forever.
- **≤ 3 levels deep:** root → category → action (SOPs are root → vault → procedure → card = the one 3-deep path).
- **Short labels** — the HUD condenses to ~120 chars; launcher labels target ≤ ~24 chars (truncated with the existing `condense`).
- **Always escapable** — Back on every non-root screen; a root "Close" exits to ambient.

**Three input channels (agreed):**
| Channel | Role |
|---|---|
| **Neural Band** | Primary: focus + select within the current screen; Back. |
| **Voice** | Parallel shortcuts — "menu", "quick actions", "start morning checklist", "switch to <persona>", "back", "close". Resolves against the *current* screen's items + global verbs. |
| **Phone** | Mirror/fallback — the same `HUDScreen` tree rendered in-app ([QuickActionsOverlay](../../OpenGlasses/Sources/App/Views/QuickActionsOverlay.swift)-style) for setup, or when the band is unpaired. |

---

## Files

```
Sources/Services/Display/
├── HUDLauncher.swift          // builds the root + category HUDScreens from live app state
├── HUDMenuBuilder.swift       // each surface → [HUDItem] (quickActions, playbooks, procedures, personas)
├── HUDVoiceCommandRouter.swift// transcription → current-screen item match + global verbs
└── HUDPhoneMirrorView.swift   // SwiftUI mirror of the active HUDScreen stack (fallback/setup)
```

Reuses from [Plan X](X-interactive-hud-now-next-tasks.md): `HUDRouter` (stack + render), `HUDScreen`/`HUDItem`, the interactive-mode gate in [GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift), and `HUDTaskSource` (workflows/SOPs hand off to the card).

Touch:
- [OpenGlassesApp.swift](../../OpenGlasses/Sources/App/OpenGlassesApp.swift) — construct `HUDLauncher`; wire open-triggers (band gesture if exposed, voice "menu", a phone Quick Action, lock-screen button).
- [NativeToolRegistry.swift](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift) — read-only enumeration for any future Tools branch (not wired this release).
- [SettingsView.swift](../../OpenGlasses/Sources/App/Views/SettingsView.swift) — optional: choose which root branches appear + their order (default: all four).

---

## Model

```swift
@MainActor final class HUDLauncher {
    // Live builders — re-evaluated each time a screen is presented so the menu
    // reflects current state (active session, enabled personas, saved quick actions).
    func rootScreen() -> HUDScreen
    func quickActionsScreen(page: Int = 0) -> HUDScreen
    func workflowsScreen(page: Int = 0) -> HUDScreen
    func sopVaultsScreen() -> HUDScreen
    func proceduresScreen(vaultId: String, page: Int = 0) -> HUDScreen
    func modePersonaScreen() -> HUDScreen
}
```

- **Root** is dynamic: "Resume task" only appears when a [Plan X](X-interactive-hud-now-next-tasks.md) `HUDTaskSource` is active; branches with no content (e.g. no vaults installed) are hidden.
- Each builder maps live model → `[HUDItem]` with the right `HUDIcon` (`.message` prompt, `.location` HA, `.calendar`, etc.) and a handler that runs the action or pushes the next screen.
- Pagination: when items > 6, append a `More…` submenu item carrying `page + 1`.

---

## Flow

```
trigger (band gesture | voice "menu" | phone) 
   ▼
HUDRouter.present(launcher.rootScreen())     → interactive mode (Plan X gate)
   ▼
select "Quick Actions"  → push launcher.quickActionsScreen()
select "Take photo"     → run QuickActionTool dispatch → "✓ Captured" flash → pop to list
   … or …
select "Workflows" → pick "Site walkthrough" → start Playbook
   → HUDRouter swaps to Plan X Now/Next card (launcher stack retained underneath)
   ▼
voice in parallel: "switch to Scout" → HUDVoiceCommandRouter matches modePersona item → activate → flash
   ▼
"close" / root Close → exit interactive mode → ambient producers resume
```

---

## Build order

1. `HUDMenuBuilder` for **Quick Actions** (flattest, instant payoff) + `HUDLauncher.rootScreen`/`quickActionsScreen`; open via a phone Quick Action first (no band-trigger dependency).
2. Open-trigger matrix: voice "menu"; band gesture **if** the on-device spike ([Plan X](X-interactive-hud-now-next-tasks.md) step 0) shows one is available; keep the phone trigger as guaranteed fallback.
3. **Workflows** branch → hand off to the [Plan X](X-interactive-hud-now-next-tasks.md) card; "Resume task" root item.
4. **Mode / Persona** branch (switch + confirm flash).
5. **SOPs** branch (vault → procedure → card), reusing the branching `ProcedureHUDTaskSource`.
6. `HUDVoiceCommandRouter` (current-screen item match + global verbs) across all branches.
7. `HUDPhoneMirrorView` fallback + Settings (branch visibility/order).
8. Pagination polish; Release-config build check.

---

## Tests

- **Menu builders** (pure): given fixtures (N quick actions, M playbooks, K personas) → expected `HUDScreen` items, icons, pagination (`More…` past 6), and hidden empty branches.
- **Root dynamism**: "Resume task" present iff a task source is active; vault branch hidden with no vaults.
- **Routing**: selecting a category pushes the right child; Back pops; leaf action invokes the correct dispatch (mock `QuickActionTool` / persona switch) exactly once.
- **Voice router**: utterance → correct item on the *current* screen; global verbs ("back/close/menu") always resolve; ambiguous match asks or no-ops (never wrong-fires).
- **Hand-off**: starting a workflow/SOP from the launcher presents the [Plan X](X-interactive-hud-now-next-tasks.md) card and preserves the launcher stack for return.

---

## Open questions / decisions needed

- **Band open-gesture availability.** Can our app claim a band "home" gesture, or does the system own it (so we open only via voice/phone)? Resolved by the [Plan X](X-interactive-hud-now-next-tasks.md) on-device spike. *Recommendation: design for voice + phone triggers as guaranteed; treat a band gesture as a bonus if exposed.*
- **List length in the field.** Power users may have many quick actions/playbooks. *Recommendation: paginate at 6 with `More…`; later add a "Favorites" subset pinned to the root for the field.*
- **Mode switch safety.** Switching to Gemini/OpenAI Realtime from the lens starts a live session (mic/network). *Recommendation: require a second confirm item for mode switches that open a realtime session; persona swaps (same mode) are one-tap.*
- **Notification interruptions mid-menu.** A geofence/proactive alert arriving while a menu is open. *Recommendation: brief flash badge, never steal focus from an open launcher screen (reuse the [Plan X](X-interactive-hud-now-next-tasks.md) flash-and-restore).*
- **Agent-mode gating.** Anything that can *act* autonomously stays behind agentModeEnabled; the launcher itself is user-initiated, so it isn't gated, but agentic quick actions inside it inherit that gate.

---

## Dependencies / prereqs

- **[Plan X](X-interactive-hud-now-next-tasks.md) must land first** — Y reuses its `HUDRouter`, `HUDScreen`/`HUDItem`, the interactive-mode gate, and `HUDTaskSource`. (Agreed sequencing: Phase 3 → Phase 4.)
- [Config.swift](../../OpenGlasses/Sources/Utils/Config.swift) — `quickActions`, `AppMode`, `Persona` enumeration.
- [QuickActionTool.swift](../../OpenGlasses/Sources/Services/NativeTools/QuickActionTool.swift) / [QuickActionsOverlay.swift](../../OpenGlasses/Sources/App/Views/QuickActionsOverlay.swift) — existing action dispatch + a phone-mirror reference.
- [PlaybookStore.swift](../../OpenGlasses/Sources/Services/PlaybookStore.swift) + [ProcedureLibrary.swift](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureLibrary.swift) — workflow/SOP listings.
- Wake-word / transcription pipeline — the voice channel.

---

## Why this matters

The launcher is what makes the Display glasses a *control surface*, not just a notification screen — start a workflow, fire a quick action, switch persona, all without reaching for the phone. Because every branch maps to a capability the app already ships and enumerates, Phase 4 is mostly menu-building over [Plan X](X-interactive-hud-now-next-tasks.md)'s proven router. The shallow ≤6-item / ≤3-level discipline keeps it glanceable in the field, and the three-channel input (band + voice + phone) means it degrades gracefully when the band is unavailable instead of stranding the user.
