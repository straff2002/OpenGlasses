# Plan X — Interactive HUD: Now / Next Tasks (Display Phase 3)

**Source pattern:** Continues the Ray-Ban **Display** HUD line — Phase 1 (PR #42: AI responses + ambient captions) and Phase 2 (notifications + Navigation Assist, branch `display/hud-phase2`). Phases 1–2 are **read-only** mirrors. Phase 3 is the first time the user *acts through the lens* with the **Neural Band** instead of just reading it.

**Strategic fit:** The app already has two step-based execution engines — **Playbooks** ([PlaybookStore.swift](../../OpenGlasses/Sources/Services/PlaybookStore.swift)) and Field Assist **Procedures** ([ProcedureRunner.swift](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureRunner.swift)). Both already track a current step and a next step. Phase 3 is therefore ~90% a thin **interactive HUD layer** over models that exist, not new task infrastructure: render the active step as a *Now / Next* card and wire four band buttons (`Done / Skip / Next / Back`) to the engine's existing transitions. This is the foundation [Plan Y](Y-interactive-hud-launcher.md) (the launcher) builds on.

**Effort:** ~3–4 days.

---

## SDK reality — what input we actually get

`MWDATDisplay` is **one-way render + callbacks**, confirmed against the 0.7.0 `.swiftinterface`:

- `Display.send(some DisplayableView) async throws` pushes a `FlexBox` tree (the only producer call).
- Interactivity is **declarative**: `Button(label:style:iconName:onClick:)`, plus `FlexBox.onClick` and `.onTap(handler:)`.
- There is **no raw band/gesture/focus stream**. The glasses + Neural Band firmware own focus traversal and selection; they invoke our `onClick` closure when the user pinch-selects an element.

So an interactive screen is just *a `FlexBox` of `Button`s with closures*. Selecting one runs the closure; we then `send` the next screen. We manage the nav stack app-side; the band drives focus + select on whatever we last sent.

> ⚠️ **One unverifiable assumption:** whether the Neural Band can *free-navigate* an arbitrary list of our `Button`s (multi-item focus traversal) versus only activating a single primary action. Not visible in the SDK, and **no Ray-Ban Display hardware is available to confirm it** — so this is a documented risk, not a checked fact. The interaction logic is instead validated entirely by **headless tests** that simulate the band by invoking each rendered button's `onClick` (`GlassesDisplayService.testInteractiveButtonActions(for:)`). If a device ever becomes available, run the spike below; if the band turns out to be single-action only, the fallback is a **paged** card (one primary action, band cycles which action is armed) — the rest of the design is unaffected.

---

## Concept

When a Playbook or Procedure is running, the HUD shows a compact card:

```
┌──────────────────────────────┐
│ ◔ Step 3 of 7                 │   ← progress (meta)
│ Torque the manifold bolts     │   ← NOW: step title (heading)
│ 45 Nm, crosswise, 2 passes    │   ← NOW: instruction (body)
│ ⚠ De-energize before contact  │   ← safety note (if any)
│ ─────────────────────────     │
│ Next: Reconnect the sensor    │   ← NEXT (secondary/dim)
│ [✓ Done] [↷ Skip] [← Back]    │   ← band-selectable actions
└──────────────────────────────┘
```

The band selects an action → we call the task source → re-render with the new now/next. Phase 1/2 ambient producers (AI replies, captions, notifications) are **suppressed or flashed** while a card is held so the task stays on screen (see Open questions).

---

## Files

```
Sources/Services/Display/
├── HUDRouter.swift            // interactive screen owner over GlassesDisplayService; ambient⇄interactive mode
├── HUDScreen.swift            // HUDScreen + HUDItem models + render to FlexBox/Button tree
├── HUDTaskSource.swift        // protocol: current/next step + complete/skip/advance/back
├── PlaybookHUDTaskSource.swift   // adapts PlaybookStore / PlaybookSession
└── ProcedureHUDTaskSource.swift  // adapts FieldAssist ProcedureRunner
```

Touch:
- [GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift) — add an **interactive-mode gate**: while `HUDRouter` holds a screen, ambient `showText`/caption producers are suppressed (queued) and notifications become brief flashes that restore the screen. Reuse the existing latest-wins render queue and session.
- [PlaybookStore.swift](../../OpenGlasses/Sources/Services/PlaybookStore.swift) / [PlaybookTool.swift](../../OpenGlasses/Sources/Services/NativeTools/PlaybookTool.swift) — expose `current`/`next` step + the existing `next/back/skip/add_result` transitions to the adapter (logic already exists; just surface it).
- [ProcedureRunner.swift](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureRunner.swift) — same: surface `currentStepId`/`nextStepId` + advance/branch for the adapter.
- [OpenGlassesApp.swift](../../OpenGlasses/Sources/App/OpenGlassesApp.swift) — construct `HUDRouter`, inject `glassesDisplay`, register task sources; auto-present the card when a Playbook/Procedure session starts.
- [SettingsView.swift](../../OpenGlasses/Sources/App/Views/SettingsView.swift) — interactive HUD is part of the existing **Glasses Display (HUD)** feature; no new top-level toggle needed (gate stays `Config.glassesDisplayEnabled`).
- Voice bridge: hook the existing wake-word/transcription path so "next / done / skip / back" map to the active source (the **voice** half of the Band+voice+phone input model).

---

## Model

```swift
struct HUDStep: Equatable {
    let index: Int          // 0-based
    let total: Int?         // nil for branching procedures with no fixed length
    let title: String
    let instruction: String?
    let safetyNote: String?
    let icon: GlassesDisplayService.HUDIcon
}

/// Source-agnostic adapter so the Now/Next card doesn't care whether it's a
/// Playbook (linear) or a Field Assist Procedure (branching).
@MainActor protocol HUDTaskSource: AnyObject {
    var title: String { get }            // workflow/procedure name
    var current: HUDStep? { get }        // the NOW step (nil ⇒ finished)
    var next: HUDStep? { get }           // the NEXT step (nil ⇒ last)
    var changes: AnyPublisher<Void, Never> { get }  // re-render trigger

    func complete() async   // mark current done → advance
    func skip() async       // skip current → advance
    func advance() async    // next without marking (peek-ahead workflows)
    func back() async       // previous step
}

struct HUDItem {
    enum Kind { case action(() async -> Void); case submenu(HUDScreen); case back }
    let label: String
    let icon: GlassesDisplayService.HUDIcon
    let kind: Kind
}

struct HUDScreen {
    let title: String?
    let body: [HUDLine]      // non-interactive content (now/next text, safety)
    let items: [HUDItem]     // band-selectable buttons
    let showsBack: Bool
}
```

`HUDRouter` owns a `[HUDScreen]` stack, renders the top screen to a `FlexBox` via the existing SDK builders (`Text` heading/body/meta, `Icon`, `Button(onClick:)`, `Background.card`), and routes each button's `onClick` to its `HUDItem.Kind`. For Phase 3 there's effectively **one screen** (the task card); the stack matters for [Plan Y](Y-interactive-hud-launcher.md).

---

## Flow

```
Playbook/Procedure session starts (phone, voice, or quick action)
   ▼
HUDRouter.present(taskCard(for: source))   → HUD enters interactive mode
   ▼
band focuses a button, pinch-selects ──► onClick fires
   │
   ├─ [✓ Done]  → source.complete()  ┐
   ├─ [↷ Skip]  → source.skip()      ├─► source.changes emits → re-render card
   ├─ [← Back]  → source.back()      ┘
   │  (voice "next/done/skip/back" → same calls)
   ▼
source.current == nil  → render "✓ Workflow complete" flash → exit interactive mode
```

---

## Build order

0. **(Deferred — no hardware.)** The on-device band-navigation spike can't run without a Display device. Until one exists, the band is simulated in tests (fire each rendered button's `onClick`) and free-navigation is a documented assumption (see *SDK reality*). Every other step proceeds test-first.
1. `HUDScreen` + render-to-`FlexBox`, and the `HUDRouter` interactive-mode gate in `GlassesDisplayService` (ambient suppressed while a screen is held). Unit-test the render mapping (screen → component tree) headlessly.
2. `HUDTaskSource` + `PlaybookHUDTaskSource` (linear is simplest). Auto-present the card on Playbook start; wire `Done/Skip/Back`.
3. Voice bridge: "next/done/skip/back" → active source.
4. `ProcedureHUDTaskSource` (branching: `Done` follows `defaultNext`; a branch step renders its `branches[]` as selectable buttons instead of Done/Skip).
5. Agent-response coexistence (flash-over-card, then restore) + completion flash.
6. Settings copy + debug events; Release-config build check.

---

## Tests

- **Render mapping** (pure): `HUDScreen` → expected `FlexBox`/`Button` tree (labels, icons, button count, Back presence). No device.
- **PlaybookHUDTaskSource**: start → current/next correct; `complete` advances + marks status; `back` returns; last step → `current == nil`.
- **ProcedureHUDTaskSource**: linear `defaultNext`; a branch step exposes `branches[]` as items; terminal step ends.
- **Interactive gate**: ambient `showText` is suppressed while a screen is held and flushes the latest on exit; a notification flashes then restores the card.
- **Voice bridge**: "done"/"skip"/"back"/"next" map to the right source call; ignored when no active source.

---

## Open questions / decisions needed

- **Agent responses vs an active card.** Flash the reply for ~4 s then restore the card, or split the lens into a persistent task region + transient reply line? *Recommendation: flash-and-restore for Phase 3 (simplest, keeps the task authoritative); revisit a two-region layout only if it feels cramped on-device.*
- **Completion behavior.** On the last `Done`, auto-exit interactive mode after a "✓ Complete" flash, or hold a summary screen? *Recommendation: flash then exit to ambient; a summary screen is a Plan Y launcher concern.*
- **Voice vocabulary collisions.** "next/done/skip/back" are common words — gate them to only fire while a card is active and the user is in a command window. *Recommendation: only active during an interactive session; require the existing push-to-talk / wake context, not always-listening.*
- **What presents the card.** Auto-present on Playbook/Procedure start is the default. Also reachable from the [Plan Y](Y-interactive-hud-launcher.md) launcher ("Resume task"). *Recommendation: auto-present on start now; launcher entry lands with Y.*

---

## Dependencies / prereqs

- **Phase 1 + 2 HUD** ([GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift)) — the session, render queue, and `HUDIcon` mapping are reused as-is; Phase 3 adds the interactive layer beside the ambient producers. Phase 2 must be merged first.
- [PlaybookStore.swift](../../OpenGlasses/Sources/Services/PlaybookStore.swift) + [PlaybookTool.swift](../../OpenGlasses/Sources/Services/NativeTools/PlaybookTool.swift) — primary task source (now/next already modeled via `currentStepIndex`).
- [FieldAssist/ProcedureRunner.swift](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureRunner.swift) + [Procedure.swift](../../OpenGlasses/Sources/Services/FieldAssist/Procedure.swift) — branching SOP source (see [Plan F](F-field-assist.md)).
- Wake-word / transcription pipeline (existing) — the voice-command channel.
- **[Plan Y](Y-interactive-hud-launcher.md)** — consumes `HUDRouter`/`HUDScreen` for the full launcher; X ships standalone value (run a workflow hands-free) before Y exists.

---

## Why this matters

Phases 1–2 made the glasses a second screen you *read*. Phase 3 makes them a surface you *operate* — and it does so over task engines you already shipped, so the new code is a small, well-bounded interaction layer rather than a new subsystem. A field tech (or anyone running a checklist) can keep both hands on the work and tick through a procedure with a pinch. It also de-risks the bigger [launcher](Y-interactive-hud-launcher.md): the band-navigation model, the screen→`FlexBox` renderer, and the ambient⇄interactive arbitration all get proven on one focused card first.
