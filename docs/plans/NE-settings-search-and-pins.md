# Plan NE — Settings Search and Pins (find any screen or setting by typing, and keep the ones you use most at the top)

**Status:** 🚧 P0–P2 being built 2026-11-25 in one PR, on the recommended answers below (still the
owner's to change). P3 (the catalog sync and translation of the new words) follows as its own PR, as
every string sync does. P4 (bring a found setting into view on its screen, with a brief highlight) is
deferred.

## Why

A tester wrote on 2026-11-25: the app is great, and they wish Settings had a search and a way to pin
the settings they use most.

Settings has 9 hub rows over 15 categories, roughly 110 screens behind them, and many more switches
on those screens. Plan HA chose not to have a settings-wide search. The concern was managed phones:
a search must never show a technician a setting their organisation hides, and a Simple Mode phone
must not show what Simple Mode hides. This plan keeps that guarantee. Search and pins draw only from
what the person in front of the phone may see, so they cannot reach anything the hub could not.

Today the only search near Settings is the tool list's (`ToolsSettingsView`, a substring match on one
screen). There is no index of screens or settings, and `SettingKey` (the organisation's allow-list)
carries no display names, so the index has to be written down.

## What the person sees

- **A search field at the top of Settings** ("Search Settings"). Typing replaces the hub with
  results. Each result shows its name, an icon for its category and where it lives ("Assistant ›
  Voice & Triggers"). Tapping a result opens that screen. For a setting, it opens the screen the
  setting is on.
- **Results cover screens and individual settings.** "memory" finds What Avenkin Remembers, User
  Memory and Memory Suggestions. "hipaa" finds Medical Compliance. A few plain keywords per entry
  catch the words people use ("blur", "faces", "wake word", "hey", "dark").
- **A pin on every result.** The button at the end of each result pins it, and pressing it again
  unpins it. Pinned entries appear in a **Pinned** section on the hub, between the Organisation
  section and the category rows. A pinned row's context menu (also offered to VoiceOver as actions)
  has Unpin, Move Up and Move Down. Up to 8 pins. The section is not drawn while nothing is pinned.
- **Nothing hidden ever shows.** A setting hidden from a technician, a category Simple Mode hides, a
  glasses screen on a phone-only build or on a phone without glasses support, Agent Mode screens
  while Agent Mode is off: none of these appear in results or pins. A pin that becomes hidden (a
  profile arrives, Simple Mode goes on) is not drawn, and it is kept, so it comes back when the
  screen does.
- **Lock Settings still locks.** While the owner gate's cover is up there is no search field and no
  pinned section.

## Design

### P0 — the index, the filter, the ranking and the pins (pure, headless)

All of this lives in `OpenGlasses/Sources/Services/SettingsHub/`, beside `SettingsCatalog` and
`SettingsGroupCatalog`, and follows their rules: pure data and pure functions, with no `Config`, no
`UserDefaults` and no views.

- **`SettingsIndexEntry`** has these fields:
  - `id`: stable, a short kebab-case string. Pins store it, so **never change one**.
  - `title`: `String(localized:)`, reusing the exact English the screen draws, so the existing
    translations apply.
  - `keywords`: `String(localized:)`, comma-separated.
  - `kind`: `.screen` or `.setting`.
  - `category`: `SettingsCategoryID`.
  - `destination`: `SettingsDestination`.
  - `gate`: `SettingsIndexGate`.
- **`SettingsDestination`** has one case per openable screen, plus `.category(SettingsCategoryID)`
  for a setting drawn on a category's own screen. The view mapping is an exhaustive switch in a view
  file, so a new case cannot compile without a screen.
- **`SettingsIndexGate`** says what besides the category decides visibility. It is a list of
  conditions, all of which must hold:
  - `.managed(ManagedSetting)`: the existing `.key`, `.area`, `.row(in:)` or `.tool`.
  - `.glassesBuild`: not the phone-only build.
  - `.glassesSupported`.
  - `.agentMode`.
  - `.fieldAssistUnlocked`.
  - `.watchInstalled`.
  - `.notSimpleMode`.
  - `.myDayOn`.
- **`SettingsIndex.entries`** is the whole index, written down. Dynamic rows (one per vault, per
  handover or per add-on) are not indexed; their parent screen is.
- **`SettingsSearchConditions`** is a plain value. It holds Simple Mode, the
  `ManagedSettingsContext`, the `SettingsHubPhone`, whether the build is phone-only, whether
  Assisting is present, and the runtime switches the gates read. The view builds it from `Config`,
  `AdminGate` and the services.
- **`SettingsIndex.visible(in:)`** keeps an entry only when all of these hold:
  1. Its category is in `SettingsHub.visibleCategories(simpleMode:in:on:assistingPresent:)`.
  2. `SettingsVisibilityPolicy.presentation(.category(c), in:)` is shown.
  3. Every `.managed` condition's presentation is shown.
  4. Every other condition holds.

  `.readOnly` counts as shown, which matches what the screens draw: the `alwaysShown` protections
  are visible and locked.
- **`SettingsSearch.results(for:in:)`** matches case- and diacritic-insensitively, in the current
  locale. Every word of the query must appear in the title, the keywords or the breadcrumb. Matches
  rank in this order:
  1. title starts with the query;
  2. a title word starts with a query word;
  3. title contains it;
  4. a keyword matches;
  5. only the breadcrumb matches.

  On a tie, screens come before settings, then index order. A blank query has no results.
- **`SettingsPins`** is a value type: an ordered list of ids, capped at 8. It has `pin`, `unpin`,
  `toggle`, `move(up:)` and `move(down:)`, and drops duplicates and unknown ids on read.
  `SettingsPins.visible(in:)` resolves the ids through `SettingsIndex.visible`.
- **`SettingsPinStore`** reads and writes `[String]` at `settingsPinnedEntries` in a `UserDefaults`
  it is given (defaulting to `.standard`), so tests use their own suite.

### P1 — the hub

- `SettingsView` gets `.searchable(text:placement:prompt:)`. It is attached only while the owner
  gate is not covering the hub. With a non-blank query, the page's body becomes the results list.
  With no results, it says *No settings match “⟨query⟩”*.
- The **Pinned** `OGSection` goes between the Organisation section and the category rows.
- Opening a result or a pin sets `@State openedEntry`. It is pushed by its own
  `.navigationDestination(item:)` into **`SettingsIndexDestinationScreen`**, which re-reads
  visibility on every draw, as `SettingsHubRowScreen` does. A hidden entry draws `ManagedHiddenScreen`
  rather than the screen. This way a pushed sub-screen never skips the category's lock.
- The existing call expressions that `SettingsHubTests` reads from `SettingsView`'s source stay
  verbatim.

### P2 — guards

- **Nothing hidden leaks.** The test sweeps every entry across the unmanaged, technician (standard,
  all-locked, partly open), administrator and ceilings-only contexts, Simple Mode on and off, glasses
  and no glasses, and the phone-only build. It asserts that no visible entry belongs to a hidden
  category or carries a hidden `ManagedSetting`. It also asserts that search results and visible pins
  are always a subset of `visible(in:)`.
- **The index stays complete.** Every screen in `SettingsHubTests.inventory`, and every switch title
  `SettingsGroupCatalog` draws, has an index entry, or an exemption with a written reason.
  `InfoToggle("…")` titles in the settings screen files are checked the same way. A new screen or
  switch without an entry fails the suite.
- **Ids are stable and unique.** There is a pinned list of ids, and every `SettingsDestination` has
  at least one entry.

### P3 — the words (own PR)

Sync the new strings into the catalog (search prompt, Pinned, Pin/Unpin, Move Up/Down, the
no-results line and the keywords), and translate them into the complete languages. Titles reuse
existing keys, so they are already translated. Until P3, keywords match in English only.

### P4 — deferred

Opening a found setting scrolls its screen to it and briefly highlights it. That means giving each
indexed row an id inside its `Form`, which is a change to many screens. It waits until people have
used P1.

## Decisions (recommendation first; built on the recommendation)

1. **Index screens and individual settings, not screens alone.** Recommended, and what the owner
   asked for on 2026-11-25. Most searches are for a switch ("blur faces"), not a page.
2. **The index is written down, not scraped from the views at runtime.** Recommended. SwiftUI cannot
   enumerate a `Form`'s rows, and the screens' titles are `LocalizedStringKey` literals that can't be
   read back. The completeness guard (P2) stops the list from drifting.
3. **Read-only settings appear; hidden ones never do.** Recommended. This is what the screens draw.
4. **Pins are per phone and not set by an organisation profile.** Recommended for now. A profile key
   for starting pins can follow if an organisation asks.
5. **At most 8 pins.** Recommended. More than that and the hub stops being the hub.
6. **A pin that becomes hidden is kept, not dropped.** Recommended. It reappears when the screen
   does, and a technician never sees it in the meantime.
7. **Pins appear above the category rows, below the Organisation section.** Recommended. The status
   card stays on top.

## Out of scope

Searching content (manuals, memories, notes); voice search of settings ("open blur faces settings"
is a later tool); syncing pins across devices.
