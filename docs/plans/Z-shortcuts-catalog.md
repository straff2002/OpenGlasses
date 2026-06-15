# Plan Z — Shortcuts Catalog: auto-surface Siri Shortcuts to the agent

**Source pattern:** The agent can already *run* Apple Shortcuts — generically by name ([SiriShortcutsTool.swift](../../OpenGlasses/Sources/Services/NativeTools/SiriShortcutsTool.swift) `run_shortcut`, fire-and-forget) and as first-class result-returning tools ([CustomToolWrapper.swift](../../OpenGlasses/Sources/Services/NativeTools/CustomToolWrapper.swift) via `shortcuts://x-callback-url` + [ShortcutCallbackManager](../../OpenGlasses/Sources/Services/ShortcutCallbackManager.swift)). What it lacks is a **live menu of what exists** — and iOS exposes **no API to enumerate all Shortcuts**. The closest is `INVoiceShortcutCenter`, which returns only the shortcuts the user has *"Added to Siri"*. [DiscoverCapabilitiesTool](../../OpenGlasses/Sources/Services/NativeTools/DiscoverCapabilitiesTool.swift) already pulls that subset on demand; this plan folds it into the system prompt automatically so the agent has a current menu without the user naming shortcuts.

**Effort:** ~half a day.

---

## Concept

A small `ShortcutsCatalog` caches the user's Siri-added shortcuts and feeds a compact block into the prompt builders, refreshed when the app foregrounds. The agent then knows which shortcut names are real (and can call `run_shortcut` confidently), without us pretending we can see the full Shortcuts library — the block states the limit plainly.

---

## Files

```
Sources/Services/ShortcutsCatalog.swift   // wraps INVoiceShortcutCenter; caches [(phrase, title)]; refresh()
```

Touch:
- [LLMService.swift](../../OpenGlasses/Sources/Services/LLMService.swift) + [GeminiLiveSessionManager.swift](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift) — inject an `Available Siri Shortcuts:` block (the two prompt builders, same spot the custom-tool list is assembled).
- [OpenGlassesApp.swift](../../OpenGlasses/Sources/App/OpenGlassesApp.swift) (`AppState`) — `refresh()` on `scenePhase`/`didBecomeActive`, and after a Custom Tool is saved.
- Prompt Inspector (transparency) — show the block, since it's data going to the model.

---

## Model

```swift
@MainActor final class ShortcutsCatalog: ObservableObject {
    struct Entry: Equatable { let phrase: String; let title: String }
    @Published private(set) var entries: [Entry] = []   // cached, persisted to UserDefaults

    func refresh() async        // INVoiceShortcutCenter.getAllVoiceShortcuts → entries
    func promptBlock(max: Int = 25) -> String?  // nil when empty; capped + truncated
}
```

`promptBlock` example:

```
Available Siri Shortcuts (ones the user added to Siri — call run_shortcut by name):
- "log water" → Log Water
- "start focus" → Start Focus
(There may be more Shortcuts not listed here; iOS only exposes Siri-added ones.)
```

---

## Build order

1. `ShortcutsCatalog.refresh()` + `promptBlock` (pure formatter) + UserDefaults cache.
2. Inject `promptBlock` into `LLMService` and `GeminiLiveSessionManager` prompt assembly (only when non-empty).
3. Refresh triggers: app foreground + after Custom Tool save.
4. Surface the block in the Prompt Inspector.

---

## Tests
- `promptBlock` (pure): N entries → expected formatting, cap/truncation at `max`, `nil` when empty, the iOS-limit caveat line present.
- Catalog: synthetic entries → dedup/sort stable; cache round-trips through UserDefaults.
- Prompt assembly: block present when entries exist, absent when empty (no dangling header).

---

## Open questions / decisions
- **Cap size.** 25 shortcuts is plenty for a HUD-era prompt; more just burns tokens. *Recommendation: cap 25, newest/most-recently-used first if that ordering is available, else alphabetical.*
- **Privacy.** Shortcut names can be personal. *Recommendation: it's local-only and only the Siri-added subset; still, gate it behind the existing Tools/transparency surface and show it in the Prompt Inspector.*

---

## Dependencies / prereqs
- `INVoiceShortcutCenter` (Intents framework) — already used by [DiscoverCapabilitiesTool](../../OpenGlasses/Sources/Services/NativeTools/DiscoverCapabilitiesTool.swift) and [QuickActionTool](../../OpenGlasses/Sources/Services/NativeTools/QuickActionTool.swift).
- The two prompt builders (`LLMService`, `GeminiLiveSessionManager`) — the injection points (they already assemble the custom-tool list).

---

## Why this matters
Today the agent runs shortcuts "blind" — it guesses a name or relies on the user to say it. Folding the Siri-added catalog into the prompt gives it a real, current menu so `run_shortcut` lands on names that exist, while being honest (in the prompt itself) that iOS hides the rest — for which **Custom Tools** remain the reliable, result-returning path.
