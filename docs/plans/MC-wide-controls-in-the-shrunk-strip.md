# Plan MC — Wide Controls in the Shrunk Strip (the pill's width goes to the buttons, with even borders)

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

The owner's answer: **if the pill keeps its width, give that width to the buttons.** Make them wide touch
targets that share the pill, with even borders.

## Today

`BottomControlBar.accessoryRow(_:)` and `tabStripRow(_:)` (in `Sources/App/Views/BottomControlBar.swift`),
inline placement:

- The controls keep to the pill's trailing end (`.frame(maxWidth: .infinity, alignment: .trailing)`) with
  6 pt horizontal padding. Everything to their left is dead glass.
- The mic is a 34 pt solid circle (`DockGridMetrics.accessoryMicSize`) in a 44 pt target. The buttons
  button is a 44 pt glyph target with no surface (`accessoryButtonSize`, `onSystemGlass: true`).
- The gap on the right (6 pt plus the target's slack around the glyph) doesn't match the gap above and
  below, which the system sets. That is the "unequal borders" the owner sees.

On a 6.1″ phone the inline pill is about 280 pt wide. The two targets use 98 pt of it.

## Proposal

### 1. The pill is split into equal segments

In the inline placement, each control becomes one **segment**: an equal share of the pill's width, the
pill's full inner height, and the whole segment as the tap target. One inset value separates the segments
from the pill's edge on all four sides, and the same value separates them from each other. That is where
the even borders come from.

- **Avenkin tab:** two segments, mic then buttons button. This keeps the order the owner chose in KX
  (mic on the left).
- **Other tabs (KY):** two segments, the tab's action (its symbol) then the mic. With no action (Settings,
  or a job's own page) the mic is **one segment the width of the pill**.
- **The expanded placement is unchanged.** It keeps the typing field, the cog, and the tab action's words.

### 2. What a segment looks like

- **The glyph stays centred and the size it is now.** The mic keeps its 34 pt tinted circle and its
  activity ring, which carry its state. The ring stays a circle and is not stretched across the segment.
- **A segment shows its edges only when pressed or active:** a capsule highlight on press, and the accent
  tint on the buttons button while the grid is up (as `isActive` tints it today). At rest the pill reads as
  it does now, two glyphs on glass, with the space between them now live.
- **A segment's shape follows the pill:** a capsule with the pill's own corner radius less the inset, so
  the highlight is concentric with the pill's edge.

### 3. Behaviour that stays exactly as it is

- The mic's long press still mutes, the VoiceOver custom action still mutes, and the spoken value
  (Listening, Thinking, Speaking, Microphone muted) is unchanged.
- The buttons button's badge dot sits at its glyph's corner, not the segment's, so it stays next to what
  it marks.
- Same accessibility elements, labels and hints, only with larger frames. **No new strings**, so no
  catalog sync is owed.
- Haptics are unchanged: medium on the mic, light on the others.

### 4. A pure layout core

**`InlineStripLayout`** (pure, `Sources/Models/`) takes the pill's size, the inset and the number of
controls, and returns each segment's frame. The views place segments from it, and the tests read it:

- equal widths
- the same inset at the pill's edges and between segments
- one control fills the pill
- no segment narrower or shorter than the 44 pt floor, even at the narrowest pill (iPhone SE size, the
  largest Dynamic Type)
- right-to-left mirrors the order without changing the widths

The inset is one named constant in `DockGridMetrics` beside `accessoryMicSize`.

## Decisions owed (the owner)

1. **Glyph only, or glyph and a word?** At about 135 pt a segment has room for "Talk" or "Buttons".
   *Recommended: glyph only.* KY decided the shrunk strip shows symbols alone, and words would compete
   with the conversation you are scrolling.
2. **Mic alone: the whole pill, or one segment's width?** *Recommended: the whole pill.* With nothing
   else in it, the pill is the mic, and it is the easiest target on the screen.
3. **Show the segment's surface at rest?** *Recommended: no, only on press or when active.* At rest that
   avoids glass on glass, and it matches KX's note that the accessory is already glass.
4. **The inset value.** *Recommended: match whatever gap the system leaves above and below the controls,
   measured from a screenshot on the phone.* That is the only way the borders read as even, because iOS
   sets the pill's height.

## Phases

- **P0 — layout and segments** (one PR). `InlineStripLayout` with its tests, then `accessoryRow` and
  `tabStripRow` in the inline placement built from it. A Release build and the full suite pass.
- **P1 — device check** (the owner's phone). On the Avenkin tab, History, Jobs, Field Assist and Settings:
  - scroll to shrink the tab bar
  - tap across each whole segment
  - long-press the mic to mute
  - check the borders look even
  - VoiceOver and the largest text size
  - the mark beside the pill still brings the full tab bar back, and taps near the gap don't land in the
    wrong segment

## Not in this plan

- A pill that shrinks to fit its controls. That needs a hand-drawn accessory and loses Apple's shared
  motion with the tab bar (see Trigger).
- Any change to the expanded strip, or to which control each tab gets (KY's decisions stand).
