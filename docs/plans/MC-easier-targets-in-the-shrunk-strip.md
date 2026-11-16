# Plan MC — Easier Targets in the Shrunk Strip (bigger tap areas for the mic and the buttons button, with even borders)

**Status:** 📝 Drafted 2026-11-16. Nothing is implemented yet.
**Track:** Home / navigation.
**Builds on:** Plan [KX](KX-conversation-first-voice-tab.md), which put the mic and the buttons button in
Apple's bottom accessory, and Plan [KY](KY-context-aware-bottom-strip.md), which gave every tab a strip.

---

## Trigger

The owner, 2026-11-16, while scrolling a conversation. The tab bar shrinks to the Avenkin mark and the strip
becomes a pill beside it. Could that pill shrink to fit its two controls (the mic and the buttons button)
with even borders?

It can't while it stays Apple's accessory. In the inline placement, iOS draws the pill and sizes it to fill
the row beside the shrunk tab bar. SwiftUI's only hook is `tabViewBottomAccessoryPlacement`, which changes
what goes inside the pill and not its width. A pill that hugs its controls would mean dropping the accessory
for one we draw ourselves, and that loses the system's shared motion with the tab bar. KX chose that motion
over a hand-made imitation, so that route is closed.

The owner's answer: **not full-width buttons, just easier touch targets.** The two controls stay where they
are, at the pill's trailing end. They become easier to hit, and the borders around them become even.

## Today

`BottomControlBar.accessoryRow(_:)` and `tabStripRow(_:)` (in `Sources/App/Views/BottomControlBar.swift`),
inline placement:

- The controls keep to the pill's trailing end (`.frame(maxWidth: .infinity, alignment: .trailing)`) with
  6 pt horizontal padding and 10 pt between them.
- The mic is a 34 pt solid circle (`DockGridMetrics.accessoryMicSize`) in a 44 pt square target. The buttons
  button is a 44 pt glyph target with no surface (`accessoryButtonSize`, `onSystemGlass: true`).
- So each target is the 44 pt minimum and no more. The 10 pt between them is dead, and so is the strip of
  pill above and below each target.
- The gap on the right (6 pt plus the target's slack around the glyph) doesn't match the gap above and
  below, which the system sets. That is the "unequal borders" the owner sees.

## Proposal

### 1. Bigger targets, same look

In the inline placement only:

- **Each target fills the pill's inner height**, not a 44 pt square, so a tap a little high or low still
  lands.
- **Each target is wider than it is tall:** a fixed width (recommended 60 pt, decision 1) with the glyph
  centred. A thumb coming in from the side has more to hit.
- **No dead gap between the two targets.** They sit edge to edge, so a tap between them goes to whichever is
  nearer instead of to nothing. The glyphs keep the same visual spacing as today.
- **The look doesn't change at rest.** The mic keeps its 34 pt tinted circle and activity ring, and the
  buttons button keeps its bare glyph. The larger area appears only as a capsule highlight on press.
- **The controls stay at the trailing end, two of them, in today's order.** The rest of the pill stays as it
  is. With the mic alone (Settings, a job's page), it is one target of the same size, not the whole pill.

### 2. Even borders

The gap from the outer target's edge to the pill's trailing edge is set to the same value as the gap the
system leaves above and below. That value is one named constant in `DockGridMetrics`, beside
`accessoryMicSize`, measured from a screenshot on the phone (decision 2).

### 3. Behaviour that stays exactly as it is

- The mic's long press still mutes, the VoiceOver custom action still mutes, and the spoken value
  (Listening, Thinking, Speaking, Microphone muted) is unchanged.
- The buttons button's badge dot sits at its glyph's corner, not the target's.
- Same accessibility elements, labels and hints, only with larger frames. **No new strings**, so no
  catalog sync is owed.
- Haptics are unchanged. The expanded placement (the typing field, the cog, a tab action's words) is
  unchanged.

### 4. A small pure core

**`InlineStripLayout`** (pure, `Sources/Models/`) takes the pill's inner size, the number of controls, the
target width and the border, and returns each target's frame, aligned to the trailing end. Tests check:

- every target is at least 44 pt each way
- the targets touch with no gap between them
- the trailing border equals the vertical one
- the controls never cross the pill's leading edge on the narrowest pill (iPhone SE size, the largest
  Dynamic Type), and if they would, the target width is reduced first, down to 44 pt
- right to left mirrors the order and the alignment

## Decisions owed (the owner)

1. **Target width.** *Recommended: 60 pt* (44 pt is today's). That is enough to help a thumb without the
   controls reaching far into the pill.
2. **The border value.** *Recommended: match the gap the system leaves above and below, measured on the
   phone.* iOS sets the pill's height, so this is the only way the borders read as even.
3. **Highlight on press.** *Recommended: yes, a capsule the size of the target,* so the larger area shows
   when it is used.

## Phases

- **P0 — layout and targets** (one PR). `InlineStripLayout` with its tests, then `accessoryRow` and
  `tabStripRow` in the inline placement built from it. A Release build and the full suite pass.
- **P1 — device check** (the owner's phone). On the Avenkin tab, History, Jobs, Field Assist and Settings:
  - scroll to shrink the tab bar
  - tap near each target's edges and between the two targets
  - long-press the mic to mute
  - check the borders look even
  - VoiceOver and the largest text size
  - the mark beside the pill still brings the full tab bar back

## Not in this plan

- A pill that shrinks to fit its controls. That needs a hand-drawn accessory and loses Apple's shared
  motion with the tab bar (see Trigger).
- Full-width controls that share the pill (the owner, 2026-11-16: not wanted).
- Any change to the expanded strip, or to which control each tab gets (KY's decisions stand).
