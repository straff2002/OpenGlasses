# Plan EA — Voice Home Grid & Quick Actions

**Status:** 📋 Planned (2026-08-31)
**Origin:** On-device design review of the shipped My Day home surface (2026-08-31): inconsistent
vertical gaps around the My Day card, and a bottom-dock utility row that scrolls because it carries
both controls and the user's quick actions.
**Priority:** P1 for the layout rhythm and dock relief; P2 for the editor.

The Voice tab's home surface grows from a single centred card into a top-aligned module stack with a
quick-action grid, and the bottom dock returns to being a control bar. One PR.

---

## Problem and verified path

`VoiceTab.conversationZone(_:)` centres `MyDayHomeView` between two flexible `Spacer`s, so the gaps
above and below it are leftover space — they vary by device height and by My Day's compact/full
state, and rarely match the fixed 12 pt top / 8 pt bottom paddings of the status card and dock. The
accessibility layout (`accessibleConversationZone`) is already a top-aligned `VStack(spacing: 16)`,
so the two layouts disagree about the surface's shape.

`BottomControlBar`'s utility row carries the local-model chip, model picker, the user's
`QuickActionTiles()` band, camera connect, Type, push-to-talk, and Disconnect in one horizontally
scrolling row. Content actions and controls compete for the same strip, and the row outgrows the
width on every device.

Relevant seams:

- `OpenGlasses/Sources/App/Views/VoiceTab.swift` — both conversation zones, `shouldShowMyDay(for:)`
- `OpenGlasses/Sources/App/Views/BottomControlBar.swift` — utility row, `QuickActionTiles`
- whatever model/store feeds `QuickActionTiles` today (investigate before building; if it is the
  Plan Y quick-action catalog there may be an existing editor surface to extend)
- `ChatInputBar`'s typed-turn submission path (the prompt-injection seam actions must reuse)
- Plan CN vision attachment + the existing photo-capture path (for photo-first actions)
- `SessionSurfaceAccessibilityTests.swift` — the Plan DF VoiceOver bar to hold

## Decisions and invariants

1. Dock = controls, grid = content actions. The dock keeps model administration (local-model chip,
   picker) and core controls; every canned-prompt tile lives in the home grid.
2. One spacing scale: modules stack top-aligned at 16 pt with the existing 12 pt top / 8 pt bottom
   paddings; the single flexible spacer sits between the grid and the captions/transcript block.
   The normal and accessibility layouts share ordering and scale.
3. The grid follows My Day's yielding rules exactly: hidden while the assistant thinks or speaks and
   while live captions are active; hidden (not compacted) while listening.
4. Actions are data, not view literals: a catalog type with stable ids, so entries are testable,
   editable, and extensible. Two kinds — `.prompt` (submit a canned user turn through the same path
   `ChatInputBar` uses) and `.photoPrompt` (capture via the existing glasses-camera/phone-fallback
   path, attach via Plan CN machinery, then submit). No parallel entry points.
5. VoiceOver parity per Plan DF: every tile a labelled button with a hint, honest ordering, and a
   single-column row list instead of a grid at accessibility type sizes.

## P1 — Layout rhythm and dock relief 🔴

1. Top-align the conversation zone: status card → 16 pt → My Day (full width) → 16 pt → quick-action
   grid → spacer → captions/transcript → dock. Converge `accessibleConversationZone` to the same
   order.
2. Move `QuickActionTiles` out of the dock's utility row into the home grid; the dock row keeps
   model chip, picker, camera, Type, push-to-talk, and Disconnect. Verify the slimmed row fits
   without scrolling on the smallest supported width at default type size.
3. Preserve yielding, recording badge, chat-input swap, and dock behaviour unchanged.

**Tests.** Visibility predicate truth table across voice states × captions; catalog ids stable;
accessibility labels/identifiers for migrated tiles (extend the session-surface pattern).

## P2 — Canned-prompt and photo actions 🔴

1. Default catalog entries: Meetings today (prompt), Tasks today (prompt), Photo → Event
   (photoPrompt), Photo → Task (photoPrompt) — each resolving through shipped tools
   (`CalendarTool`, `AppleRemindersTool`) via the normal LLM turn, not direct tool calls.
2. `.photoPrompt` captures first, attaches, then submits; capture failure is a spoken/visible error,
   never a silent no-op.

**Tests.** Action kind marking; prompt text stability; photo actions require capture; a `.prompt`
action reaches the session through the same seam as typed input (fake session).

## P3 — Grid editor 🟠

1. Edit surface (long-press or Settings entry) to add/remove/reorder tiles from the full catalog —
   built-ins plus whatever fed `QuickActionTiles`. Persisted per the existing quick-action store if
   one exists; otherwise a small versioned codable store with lossy decode (BB salvage semantics).
2. Reset-to-default; removing a tile never deletes any underlying user data.

**Tests.** Reorder/add/remove round-trip; lossy decode drops unknown entries by name, never
silently; reset restores defaults.

## Rollout and exit criteria

Pure UI/composition — no new permissions, no new network. Rollback is reverting the PR. Complete
when the gaps around My Day are deterministic at every state and device size, the dock's utility
row no longer scrolls at default type size on the smallest supported width, every action fires
through the existing turn pipeline, the editor round-trips, and the full suite, accessibility
checks, and Release build are green.
