# Plan KY — The Strip on Every Tab (the mic and each tab's own action in the bottom strip)

**Status:** 🚧 Built 2026-11-10 (one PR). Catalog sync for the new strings is owed in its own PR, together
with Plan KX's.
**Track:** Home / navigation.
**Builds on:** Plan [KX](KX-conversation-first-voice-tab.md) (the mic and the buttons button in Apple's bottom
accessory on the Avenkin tab).

---

## Trigger

The owner, 2026-11-10, while trying KX: should the bottom bar be context aware, so it reflects each tab? Taken
as a follow-up to KX.

## Decisions (the owner, 2026-11-10)

1. **The mic is on every tab.** You can talk from History, Jobs, Modes or Settings without going home; the
   reply is spoken, and its text lands in the Avenkin conversation as always.
2. **One action per tab**, beside the mic:
   - History: **New conversation**. It goes through the same leave-the-job question as the list's New chat
     button.
   - Jobs: **New job**, or **Open job** while one is open. Shown on the list only; on a job's page the mic
     stands alone.
   - Field Assist: **Ask a manual** while a manual can be asked (only the open job's vault can be). It goes
     straight to that manual, or offers a choice when there are several. Otherwise the job's action
     (New job / Open job), which is the tab's own first row.
   - Modes: the **active mode by name**, opening its details.
   - Settings: the mic alone.
3. **Tapping the shrunk tab bar keeps Apple's behaviour:** the full bar comes back and you stay on the tab you
   were on.

## As built

1. **`TabStripPolicy`** (pure, `Sources/Models/TabStripPolicy.swift`) decides each tab's action
   (`lead(for:facts:)`) and whether the strip is up at all (`showsStrip`). The strip is never up during
   onboarding. On Avenkin it is not up while the typed bar is open. On History it is not up over an open
   conversation, which has its own composer.
2. **`TabStripModel`** (shared from `MainView`) holds the `TabStripFacts` each tab reports as they change
   (History's lock and stack, the Jobs list's stack, Field Assist's askable manuals). `MainView` adds the facts
   it already holds: which Modes slot is up, the active mode, whether a job is open. The model also holds the
   strip's last tap. Jobs open through `AppState.openJobs`; the other actions post a request that only their
   tab takes, because they need state only that tab holds.
3. **`TabStripAccessoryModifier`** replaces `VoiceDockAccessoryModifier`. One `tabViewBottomAccessory` on the
   tab view switches content by the selected tab: Avenkin keeps KX's strip, and every other tab gets
   `TabStripAccessory`. It renders `BottomControlBar` in a new `tabStripRow`: the action as words and symbol
   while the strip is full width, the symbol alone beside the shrunk bar, then the mic.
4. iOS 26.0 keeps KX's fallback: no accessory, so the other tabs show nothing new.

## Review follow-up (2026-11-10)

The strip's mic works on every tab, but "Check what I said before sending" (Plan JM P1) drew its review —
the transcript, the countdown and Cancel — only in the Avenkin tab's typed bar, so on any other tab the
countdown sent the transcript without it ever being shown. **`SendReviewTabPolicy`** (pure, beside
`TabStripPolicy`) now brings the wearer to Avenkin when a review begins on another tab (decision 1 already
lands the reply's text there). It leaves the tab alone during onboarding, under a sheet presented from the
root (asked again once the sheet closes, so a manual page shown as a sheet is not re-homed inline), and
with CarPlay watching; it is asked when a review begins, not when the wearer moves off Avenkin
themselves. `MainView` wires it. No new strings. Status unchanged: the device check is still owed, now
including a spoken review started from History and Settings, with VoiceOver on.

## Tests

`TabStripPolicyTests`: every tab's action under each fact, the Field Assist fallback, and when the strip stands
aside.

## Owed

- Catalog sync for "New conversation", "New job", "Open job", "Ask a manual" (with KX's strings).
- Device check of every tab's strip, the shrunk placement and large text.
