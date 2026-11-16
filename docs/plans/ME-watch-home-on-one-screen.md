# Plan ME — The Watch Home on One Screen (the phone's first tiles, glass keys, and More)

**Status:** ✅ P0 merged 2026-11-17 ([#1090](https://github.com/straff2002/OpenGlasses/pull/1090), build 699); its 15 new strings translated and synced to the watch catalog in the catalog-sync PR that follows it — device pass (P1) owed.
**Track:** Apple Watch app, every channel that ships it.
**Builds on:**
- The phone's home grid: `HomeGridCatalog`, `DockGridCatalog` and `HomeGridDispatcher`
  (`Models/HomeGridCatalog.swift`), the wearer's arrangement in `homeGridArrangement`.
- The watch's photo rule from Plan [LT](LT-ecosystem-review-fixes-2026-11.md) §3: a request from the wrist never
  opens the phone's camera, and a photo command replies with its own result.
- Plan [LU](LU-private-conversation.md)'s Private button and badge (`WatchPrivateWire`).

---

## Trigger

The owner, using the watch app on 2026-11-16: the header said the name but drew a typed capital A
rather than the Avenkin mark; there was a lot to scroll through when it opened (a dozen full-width
rows before anything else); and the quick actions did not match the first buttons on the phone.

What the code showed: the watch drew its wordmark from two `Text`s; it stacked Listen, Dictate,
Private, Transcribe, Photo and Video as rows, then quick actions, personas, Connect and recent
conversations; and it received `Config.quickActions.prefix(4)`, the speed dial in its stored order,
while the phone's first tiles are the home grid in the wearer's arrangement (built-ins such as
Meetings, Tasks and Brief first, hidden tiles left out). A text quick action run from the wrist also
took a glasses photo and asked its label, where the phone runs its prompt.

## What changes

1. **The mark, alone.** The header is the Avenkin mark, laid out by the glyph's own bounds and
   tinted with the accent. VoiceOver still reads "Avenkin".
2. **The phone's first tiles, three across.** The phone sends `gridTiles`: the home grid's action
   tiles in the order the dock draws them, at most twelve (four rows of three), hidden tiles and
   the edition's hidden tiles left out (`DockGridCatalog.storedSlots`, which the dock now uses too).
   The grid's controls stay on the phone; the watch has its own Listen, Photo, Video and Sleep. My
   Manuals stays on the phone, because it opens a picker there. Photo tiles are dimmed where the
   phone dims them.
3. **A tap runs what the tile runs** (`WatchGridTiles.route`): a built-in asks its own question as a
   typed turn; a photo tile captures with the glasses and asks; a speed-dial action runs through
   `executeQuickAction`, as the phone's tile does. A tile that would open the phone's camera first,
   My Manuals and a stale id are refused with a line saying so. Only a turn that answered sends an
   answer back, so a light or a shortcut never shows an earlier reply as its own.
4. **One screen.** Status; the Private badge while one is open; the map card, Today and the job;
   Listen (the one filled button) with Dictate beside it; the answer directly under them; the
   tiles; Photo, Video and Transcribe as one row; then More.
5. **More, and pins.** More holds Private, Connect or Sleep, personas and recent conversations.
   The pin beside an item keeps it on the main screen too, above More; it stays under More either
   way (`WatchMorePins`, stored on the watch only).
6. **Glass.** The tiles are Liquid Glass keys in one `GlassEffectContainer`, as each tile on the
   phone is its own glass key; Listen is `glassProminent` in the accent; the answer sits on a pane
   of glass signed with the mark; the ground is the accent falling to black, brighter while
   listening. Motion answers the wearer: a tile's glyph bounces on its tap and Listen's waveform
   moves while it listens; Reduce Motion stills both.

An older phone sends no `gridTiles`, and the watch draws its four speed-dial actions as tiles with
the old `quickAction` command, which the phone still answers.

## Phases

- **P0 (this PR):** all of the above, with `WatchHomeTests` (tile order, the cap, hidden and phone-only
  tiles, dimming, the wire round trip, every route, the command token, pins).
- **P1 (device, owed):** on a paired watch: the tiles match the phone's first rows after an edit on
  the phone (the push follows a change to the grid); a built-in tile answers on the wrist; a photo
  tile with and without glasses; a pinned persona and Connect on the main screen; Private from
  More; the layout at the smallest watch and at an accessibility text size (one column).

## Out of scope

Editing the watch's tiles on the watch (the phone's arrangement is the one arrangement); the phone
grid's controls on the wrist; syncing pins to the phone.
