# Plan EB — Action Reach & Conversation Continuity

**Status:** 📋 Planned (2026-09-01)
**Origin:** On-device use of the shipped Plan EA home surface (2026-09-01): the grid's actions stop
at the app's edge, creating a new action means a trip through a Settings screen that is not up to
the job, and the pager's conversation page is read-only — a reply can be read but the conversation
cannot be restarted, resumed, or managed.
**Priority:** P1 exposure, P2 creation, P3 continuity — one PR.

The Plan EA grid made actions first-class data. This plan gives that data reach (Action Button,
Siri) and gives the conversation page the other half of its job (continue, switch, manage).

---

## Problem and verified path

1. **Action Button / Siri reach.** Plan BQ's `SiriActionCatalog` + entity-parameterized
   `RunGlassesActionIntent` already make catalog actions bindable to the iPhone Action Button
   (Settings → Action Button → Shortcut → pick the intent). But the catalog harvests capture flows,
   procedures, playbooks, and custom tools — it predates Plan EA and knows nothing about
   `HomeGridAction` built-ins (Meetings, Tasks, Photo → Event, Photo → Task) or the user's
   speed-dial quick actions. The grid's one-tap actions are exactly what a hardware button wants.
2. **Creating actions.** The grid's edit page (pager page 3) arranges and hides, but *adding* a new
   action routes through `QuickActionsSettingsView` — a form that predates the grid and reads as an
   afterthought. Creation belongs where the actions live.
3. **Conversation continuity.** The pager's conversation page shows the current transcript and
   nothing else: no way to restart a conversation, no way to resume a *specific* earlier thread
   (the Chat tab's `ConversationThread` store has them; the voice surface cannot reach them), and
   no way to delete a thread — individually or wholesale.

Relevant seams:

- `OpenGlasses/Sources/Services/SiriActionCatalog.swift` + `RunGlassesActionIntent` /
  `SiriActionEntity` (Plan BQ P1) and `SiriExposureView` — the harvest pattern to extend
- `OpenGlasses/Sources/Models/HomeGridCatalog.swift` — `HomeGridAction` / `HomeGridEntry` /
  `DockGridCatalog` (stable ids, the currency of this plan)
- `OpenGlasses/Sources/App/Views/DockLayoutEditPage.swift` + `DockLayoutEditorView` — the edit
  surface creation joins
- `QuickActionsSettingsView` + `Config.quickActions` — the store creation writes (and the screen
  this plan demotes)
- `OpenGlasses/Sources/App/Views/BottomControlBar.swift` — conversation page (pager page 1)
- `ConversationStore` / `ConversationThread` + the Plan AK Chat surfaces — threads to resume;
  `AppState.sendTextMessage` — the turn seam that must receive a "continue thread X" turn
- `MyDayDismissalStore` (Plan EA P6) — the confirm-modal idiom for destructive actions lives with
  the design system, not per-feature

## Decisions and invariants

1. One catalog of actions, many surfaces. A grid tile, a Siri phrase, and an Action Button press
   run the *same* `HomeGridAction` by id through the *same* turn seam (`AppState.sendTextMessage` /
   `capturePhotoAndSend`). No surface gets its own execution path.
2. App Intents constraints are load-bearing: `AppShortcut` parameters stay `AppEntity`/`AppEnum` —
   a free-form `String` parameter silently halts `appintentsmetadataprocessor` and wipes ALL intent
   metadata, and only a Release/SDK build catches it. The Release gate is part of this plan's
   definition of done.
3. Creation is data entry, not code: a new action is a name, an icon, a kind (`.prompt` /
   `.photoPrompt`), and a prompt string, written to the existing `Config.quickActions` store.
   Nothing this plan adds can execute anything the grid could not already execute.
4. Destructive actions confirm. Deleting a conversation — one or all — presents a confirmation
   modal stating what is about to be deleted; delete-all states the count. Deletion is real
   deletion from `ConversationStore` (and its encrypted form), not a view-level hide — the
   My-Day-clear precedent is the opposite contract and the UI copy must not blur them.
5. Resuming a thread is explicit: the conversation page names the active thread; switching threads
   is a user act, never an inference. A resumed thread continues with full prior context via the
   same history the Chat tab uses.

## P1 — Grid actions reach Siri and the Action Button 🔴

1. Harvest `HomeGridAction` built-ins and the user's `Config.quickActions` speed-dial entries into
   `SiriActionCatalog` as toggleable candidates (same pattern as the capture-flow harvest), curated
   in the existing `SiriExposureView` under the 10-App-Shortcut cap.
2. Execution routes by id through the grid's own dispatch (`HomeGridSession` seam) — background
   where the intent context allows, foregrounding only when capture requires it.
3. A "Use with the Action Button" hint row (Settings → Siri Exposure): one line + the system path,
   since discoverability is the actual barrier. No new intent kinds; no free-form parameters.

**Tests.** Harvested entities carry stable ids and honest display names; toggling exposure
round-trips; the intent resolves an id to the same action the grid resolves; cap arithmetic with
mixed sources; a Release build (metadata processor) is the gate for the entity shape.

## P2 — Create actions where they live 🔴

1. The pager's edit page grows an **Add** affordance: name, SF Symbol picker (curated set), kind,
   prompt text — writing to `Config.quickActions`. The same sheet serves editing an existing
   speed-dial action. Built-ins are not editable; their tiles say so.
2. `QuickActionsSettingsView` demotes to a thin entry point: the grid editor link and the Siri
   exposure link. The old form's residual capabilities (Field Assist injection etc.) move or retire
   explicitly — audit what it still owns before deleting anything.
3. Deleting a speed-dial action from the editor removes it from the store (it is user-authored
   data, so this one *is* real deletion) — with the standard confirm modal, and Siri exposure for
   that id revoked atomically.

**Tests.** Create/edit/delete round-trip through the store; created action executes through the
existing seam (fake session); deletion revokes exposure; built-ins immune to edit/delete; lossy
decode still names drops.

## P3 — Conversation continuity on the pager 🔴

1. The conversation page names the active thread and gains a compact header: **New conversation**
   (ends the current thread cleanly, next turn starts fresh) and a **thread switcher** (recent
   threads from `ConversationStore`, newest first, titles as the Chat tab shows them; selecting one
   makes it the active voice thread — the next capsule turn continues it with full context).
2. Restart = resume the *current* thread after the session went idle: the capsule already sends the
   next turn into the active thread — verify that contract end-to-end from the pager and fix
   whatever breaks it today (the reported symptom: after a reply, the conversation could not be
   restarted from the page).
3. **Delete, with confirmation**: swipe-left on a thread row in the switcher deletes that thread
   (confirm modal); a Delete All control (confirm modal stating the count) empties the store. Both
   delete from `ConversationStore` including the encrypted store, mirror to the Chat tab instantly,
   and never touch Brain/memory stores (state that boundary in the modal copy).
4. VoiceOver: thread switcher rows labelled with title + relative date; delete as a named row
   action; the confirm modal is a proper alert.

**Tests.** Thread switch changes the active thread the turn runner appends to; new-conversation
produces a fresh thread id; delete removes one/all from the store (and encrypted form) and the
switcher; confirm-required is enforced at the store seam (no unconfirmed deletion path); Chat tab
and pager agree on the thread list after every operation.

## Rollout and exit criteria

Pure app-surface work over shipped stores and seams; no new permissions or network. Rollback is
reverting the PR. Complete when: a grid action fires from the Action Button via a curated App
Shortcut; a new action can be created, edited, and deleted entirely from the grid's edit page with
Settings demoted to links; the conversation page can start fresh, resume the current thread, switch
to any recent thread, and delete one or all with confirmation; the App Intents metadata processor
emits all entities in a Release build; and the full suite plus Release gate are green.
