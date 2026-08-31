# Plan EA — Voice Home Grid & Quick Actions

**Status:** ✅ Shipped P1–P3, then revised on device (2026-08-31). The dock-fit criterion closed the
same day — the model tile dropped its model-name label for a provider glyph + constant caption (full
name stays in the accessibility label), and the dock's strip wraps into rows of four instead of
scrolling horizontally. A phone test of that build then rewrote decisions 1, 2, 5 and 6: see
**P4 — On-device revision** below.
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

1. ~~Dock = controls, grid = content actions.~~ **Superseded in P4.** Two grids of identical tiles
   stacked one above the other read on device as one thing split in half. There is one grid, in the
   dock panel, holding controls and content actions together.
2. One spacing scale: modules stack top-aligned at 16 pt with the existing 12 pt top / 8 pt bottom
   paddings; the single flexible spacer sits between the top modules and the captions/transcript
   block. There is now one layout at every text size rather than two that agree (P4).
3. The grid follows My Day's yielding rules exactly: hidden while the assistant thinks or speaks and
   while live captions are active; hidden (not compacted) while listening.
4. Actions are data, not view literals: a catalog type with stable ids, so entries are testable,
   editable, and extensible. Two kinds — `.prompt` (submit a canned user turn through the same path
   `ChatInputBar` uses) and `.photoPrompt` (capture via the existing glasses-camera/phone-fallback
   path, attach via Plan CN machinery, then submit). No parallel entry points.
5. VoiceOver parity per Plan DF: every tile a labelled button with a hint and honest ordering. The
   grid drops to two columns at accessibility type sizes, where a tile lays its glyph beside its
   label and four columns would shred every caption.
6. ~~The grid draws at most 8 tiles.~~ **Superseded in P4.** No ceiling: the grid wraps into rows of
   four and scrolls vertically inside a bounded panel height, so nothing is ever cut off.
7. Controls are always present; content tiles yield. A dock a user can strip of its own disconnect
   is a trap, so `hidden` is honoured for actions and ignored for controls — enforced in the
   resolver, not in one list's gesture configuration.

As built: `.prompt` submits through `AppState.sendTextMessage` — the `ChatInputBar` seam with turn
running, cancellation, and thread persistence — deliberately not `executeQuickAction`'s older
direct-`llmService` branch. Photo tiles reuse `capturePhotoAndSend` and its phone-camera fallback.
Persistence reuses the shipped `Config.quickActions` store for the actions; only the arrangement is
new (versioned codable, lossy decode that names what it dropped). The dead `showAllQuickActions`
preference and `DockItem.quickActions` were retired with salvage-tested stored-order decoding.

## P1 — Layout rhythm and dock relief ✅

1. Top-align the conversation zone: status card → 16 pt → My Day (full width) → 16 pt → quick-action
   grid → spacer → captions/transcript → dock. Converge `accessibleConversationZone` to the same
   order.
2. Move `QuickActionTiles` out of the dock's utility row into the home grid; the dock row keeps
   model chip, picker, camera, Type, push-to-talk, and Disconnect. Verify the slimmed row fits
   without scrolling on the smallest supported width at default type size.
3. Preserve yielding, recording badge, chat-input swap, and dock behaviour unchanged.

**Tests.** Visibility predicate truth table across voice states × captions; catalog ids stable;
accessibility labels/identifiers for migrated tiles (extend the session-surface pattern).

## P2 — Canned-prompt and photo actions ✅

1. Default catalog entries: Meetings today (prompt), Tasks today (prompt), Photo → Event
   (photoPrompt), Photo → Task (photoPrompt) — each resolving through shipped tools
   (`CalendarTool`, `AppleRemindersTool`) via the normal LLM turn, not direct tool calls.
2. `.photoPrompt` captures first, attaches, then submits; capture failure is a spoken/visible error,
   never a silent no-op.

**Tests.** Action kind marking; prompt text stability; photo actions require capture; a `.prompt`
action reaches the session through the same seam as typed input (fake session).

## P3 — Grid editor ✅

1. Edit surface (long-press or Settings entry) to add/remove/reorder tiles from the full catalog —
   built-ins plus whatever fed `QuickActionTiles`. Persisted per the existing quick-action store if
   one exists; otherwise a small versioned codable store with lossy decode (BB salvage semantics).
2. Reset-to-default; removing a tile never deletes any underlying user data.

**Tests.** Reorder/add/remove round-trip; lossy decode drops unknown entries by name, never
silently; reset restores defaults.

## P4 — On-device revision ✅

Tested on an iPhone Air against a Release build. Four changes:

1. **One grid, one editor.** `HomeActionGrid` as a separate home-surface card is gone; its tiles
   moved into the dock panel's wrapped grid as `DockSlot` values (`.control` | `.action`) resolved
   by `DockGridCatalog` from one arrangement. The Bar Layout and Home Grid editors merged into
   `DockLayoutEditorView`, so a tile can finally sit beside a control — the move neither list could
   express. Both stores are kept: `homeGridArrangement` is the arrangement, `dockItemOrder` is read
   as the fallback control ordering so a bar arranged before the merge keeps its order with no
   migration step. The grid has a bounded height and scrolls vertically past it.
2. **My Day collapses.** A chevron in the header plus a tap on the header's empty space, persisted
   in `@AppStorage("myDayCollapsed")`. Collapsed is the header row alone, carrying today's headline
   when the snapshot is loaded. It composes with the session's compact form and outranks it: the
   compact form is imposed while the mic is open, this is a choice.
3. **A functional regression, fixed.** With a reply on screen and a two-row dock, the conversation
   zone and the dock shared one fixed `VStack` whose intrinsic height exceeded the tab — and a
   `VStack` in that position neither clips nor scrolls, it overflows. The overflow pushed the bottom
   of the dock past the tab bar, so the capsule stayed visible while the tiles under it were outside
   the hittable area. The zone is now a `ScrollView` inside a `GeometryReader`, which accepts any
   height down to zero: the dock is laid out at its intrinsic height first and every tile stays
   on screen and tappable. `minHeight` keeps the top-aligned rhythm when the content is short.
4. **Provider marks are asset-first.** `DockLayout.providerMarkAsset(for:)` names
   `ProviderMark-<provider rawValue>`; the tile draws that asset template-rendered when the catalog
   carries one and falls back to the (now exhaustive) `modelTileGlyph` mapping otherwise. No mark is
   drawn from an approximation of somebody's trademark — sourcing official marks is separate work.

**Tests.** Dock-slot composition (controls then actions, interleaving, stored control order leads);
yielding removes actions and leaves every control; controls cannot be hidden; every provider has a
symbol fallback and the three major ones do not collide; asset names keyed to the raw value.

## Rollout and exit criteria

Pure UI/composition — no new permissions, no new network. Rollback is reverting the PR. Complete
when the gaps around My Day are deterministic at every state and device size, no dock tile is ever
off-screen or unhittable at default type size on the smallest supported width, every action fires
through the existing turn pipeline, the editor round-trips, and the full suite, accessibility
checks, and Release build are green. All met as of the P4 revision.
