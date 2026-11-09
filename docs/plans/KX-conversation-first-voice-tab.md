# Plan KX — The Conversation First (the Voice tab as one scrolling conversation, the mic beside the buttons button)

**Status:** 🚧 Built 2026-11-10 (one PR), tried on the owner's phone build by build; the iOS 26.0 fallback and
large-text layouts are checked in the simulator only. Catalog sync for the new and reworded strings is owed in
its own PR.
**Track:** Home (Voice tab).
**Builds on:** the dock panel and pager (`BottomControlBar`, `DockPagerPolicy`, `HomeGridPaging`), Plan
[KH](KH-from-capabilities-to-use.md) (things to try on the home screen), Plan EK (cited manual pages).

---

## Trigger

The owner, 2026-11-09, on the Voice tab: the buttons button on the right, the mic just left of it as an easy
target, no full-width Tap to Talk bar, the conversation panel infinite with manual pages in it, and the bottom
menu shrinking to the Avenkin mark on scroll as it does on Settings. Refined over the following builds on the
phone (below).

## As built

1. **The conversation is the tab's own scroll** (`ConversationFeed`). My Day, captions, notices and things to
   try lead in at the top; the conversation follows as long as it is. Short content stays at the top; a long
   conversation opens on its newest line and follows new lines with explicit scrolls (no size-change anchor,
   so the line being read never moves when the bars change size). The status card and the conversation's
   header ride a bar above it; the header's three targets are 56 pt.
2. **Manual pages open in place** (`InlineManualPage`): a cited page is a card under the answer on the Voice
   tab, not a sheet; in the expanded workspace it stays in the context pane. A page opened there stays put
   rather than turning into a sheet on the next tab.
3. **The mic and the buttons button** replace the capsule. The mic carries every state the capsule did
   (talk, cancel, stop, start or stop a live session, the mute badge and its long press) and wears a ring for
   what the session is doing — a pulse listening, a turning arc thinking, a breath speaking; still under
   Reduce Motion, spoken as the mic's value.
4. **Apple's bottom accessory carries them** (`VoiceDockAccessory`, iOS 26.1+). Full width above the tab bar
   its free width is a "Type a request" entry that opens the typed bar (the cog while the buttons are up;
   nothing in a live session, which has no typed turn); when the conversation scrolls
   up the bar shrinks to the mark with the system's own motion and the strip moves into its row, controls
   trailing. On iOS 26.0, where the accessory cannot be switched per tab, the two float over the feed instead.
   The typed bar takes the bottom for itself and switches the accessory off.
5. **The buttons take the conversation's place**, not a band under it: the buttons button swaps them, the
   conversation stays alive underneath so it comes back where it was left, a sideways swipe on the
   conversation brings the buttons, and the first page dot is the conversation, so swiping back from page one
   returns to it. A reply that arrives while the buttons are up puts a dot on the conversation button.
6. **Copy** that named the capsule ("tap Tap & Talk") now says "tap the mic".
7. **Shared state** (`VoiceDockModel`): the pager, the typed bar and the reply dot live above the tab view,
   because the accessory belongs to the tab view, not the tab. The pager's own flips moved into the Voice tab.

## What was tried and dropped

- **A grid risen under the conversation** — the owner: "we had that before", the pages were the fix.
- **Hiding the tab bar ourselves** and drawing the Avenkin button in our own row: in line with the mic, but
  the bar jumped instead of shrinking. The system's minimised state cannot be read by a view
  (`toolbarMinimizationSafeAreaAdjustment` is navigation-bar only), so the accessory is the supported way to
  sit beside the shrunk mark.

## Tests

`HomeGridTests` (the grid's page body in the conversation's place), `WakeListenerFailurePolicyTests` (the copy
names the mic, not the capsule), with `DockPagerTests` and `AdaptiveWorkspaceLayoutTests` unchanged and green.

## Owed

- Catalog sync for the new strings ("Listening", "Thinking", "Speaking", "New reply", "Type a request", the
  reworded mic lines)
  in its own PR.
- A context-aware strip for the other tabs (each tab's own actions beside the mark) — a follow-up plan.
