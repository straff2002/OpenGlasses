# Plan LI — Where Things Are Kept (a household inventory you speak to: location codes, rooms, and a photo of each shelf)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) are
recommendations and are still open.
**Track:** Everyday assistant. Free. No Field Assist dependency: the van-stock code it borrows from stays
Field Assist's.
**Origin:** an example list of routines a cloud personal agent runs, which the owner shared on 2026-11-11.
One of them is a household inventory: a master spreadsheet with per-room views, spoken location codes, and
photo-linked storage maps.
**Builds on:** `ObjectMemoryTool` and `ObjectMemoryStore` ("remember where I put my keys"), Plan
[GG](GG-readable-memory.md) (readable memory: `MemoryFact`, `MemoryFactSources`, Forget and Correct), Plan
[IH](IH-van-stock.md) (`VanStockMatcher`'s matching order, `SpokenPartNumber`'s spelled read-back,
`VanStockSheet` and `VanStockImportService`'s workbook out and back, `XLSXReader` and `XLSXWriter`),
`ParkingPhotoFlow` (a filtered still kept with a record), `RememberSceneTool`, `DataStoreRegistry`, the
privacy chokepoint (Plan [CP](CP-outbound-frame-privacy.md)).
**Sits beside:** `object_memory` (where *I just put* something; one entry per name, with GPS). LI is where
something is *kept*: a place in the house with a code, holding many things. `save_location` and `parking`
are places outdoors. Plan [LF](LF-coupon-wallet.md) uses the same photo-with-a-record pattern.

---

## Trigger

"Where's the stud finder?" is a question people ask about their own home all the time. The answer is
usually "the second shelf in the garage, in the blue tub". People who keep that in a spreadsheet give their
shelves short codes, such as G3 for garage shelf 3, because a code is quicker to say and to write on a label
than "the second shelf on the left in the garage".

Avenkin can remember where one thing is (`object_memory`), but only one place per name, with no notion of a
shelf, a room or a code. Each new "save" for the same name replaces the last, and "what's in the garage?"
has nothing to answer from.

## Outcome

- **Defining places, once:** "G3 is the garage, shelf three, the blue tubs." → "G3: garage, shelf three,
  blue tubs. Saved." The code is read back spelled ("G for garage, three"). Codes are the wearer's own
  (decision 2).
- **Filing:** "Put the stud finder in G3." / "The camping stove and the gas are in G3." → "Stud finder in
  G3, garage shelf three." Several items in one sentence are one batch, and one undo takes the batch back.
- **Finding:** "Where's the stud finder?" → "G3: garage, shelf three, blue tubs. You put it there on
  12 October." When several items match ("the drill" with a drill and a drill-bit set), the assistant asks.
  A name that matches nothing in the inventory falls back to `object_memory`, then says it doesn't know.
- **Reading a place:** "What's in G3?" → the list. "What's in the garage?" → places, then counts ("G1 has 4
  things, G3 has 9; want G3 read out?").
- **Moving and removing:** "Move the stove to S1." "The old router's gone." "Undo that."
- **A photo of each place:** "Take a picture of G3." (glasses or phone) → the photo is kept with the place,
  filtered first, and shown with the place on the phone. "Show me G3" opens it.
- **Filing from a photo, offered and never automatic** (decision 6): "What's on this shelf? File it as
  G3." → the selected vision model lists what it sees. The wearer hears the list, corrects it, and
  confirms, and only then is it filed.
- **The spreadsheet:** export the inventory as a workbook (Items and Places sheets, one row per item with
  code, room and place). Import an existing one, by headers, as a reviewed proposal applied in one batch.
- **On the phone:** a Home Inventory screen grouped by room, then place, with search, each place's photo,
  and a printable list of codes for labels.
- Everything is readable and forgettable from the Memory screen, as GG's facts are.

## What exists, and what doesn't

**Exists (verified 2026-11-11 at `main` 2d936d2):**
- `ObjectMemoryTool` (`object_memory`, `Services/NativeTools/ObjectMemoryTool.swift`): actions `save`,
  `find`, `list` and `forget`. An `ObjectMemoryEntry` is `objectName`, `locationDescription` (free text),
  optional latitude and longitude, and `savedAt`. `ObjectMemoryStore` keeps a JSON array in the preferences
  key `objectMemory`. **`save` replaces any entry with the same lowercased name**, and `find` is an exact
  lowercased name match. There are no rooms, codes, photos, batches, undo or partial matching.
  It is registered in `DataStoreRegistry` as `objectMemory` (personal memory, backed up). It surfaces in
  readable memory as `MemoryFactKind.object` (`MemoryFactSources`, `MemoryFactMutations`).
- `SaveLocationTool` (`save_location`): labelled GPS points (at most 50), outdoors by intent. Parking has
  its own tool (`parking`, Plan [GH](GH-parking-memory.md)).
- `RememberSceneTool` (`remember_scene`): a filtered still described by the selected cloud vision model plus
  on-device OCR, kept as **text** in saved memory and found later by `memory_search`. It keeps no photo.
- `ParkingPhotoFlow` (`Services/Parking/`): a glasses still from the chokepoint, or a phone photo through
  `StillImageFiltering.filteredOrUnavailable`, scope `.toolPhotoCapture`, roster entries
  `parkingSignCapture` and `parkingPhonePhoto`. It fails closed, and the record is saved without the photo.
- Van stock (Plan IH, Field Assist only, `Services/FieldAssist/VanStock/`): `VanStockMatcher` (scanned code,
  exact number, supersession, description tokens; several candidates go back as a list and it never
  picks), `SpokenPartNumber` (spelled read-back), `VanStockLedger` (levels as a fold over movements, undo by
  batch), `VanStockStore` (one JSON file in Application Support; an unreadable file is refused and never
  overwritten), `VanStockSheet` with `VanStockImportService` (workbook out, workbook back as a reviewed
  proposal, one batch), and `XLSXReader` and `XLSXWriter`. **The reader and writer take XLSX only. There is
  no CSV path.** `VanStockTool` returns early unless `Config.fieldAssistActive`.
- `DataStoreRegistry` and `DataStoreRegistryTests` (every store registered). `OutboundFrameConsumerTests`
  (every pixel consumer on the roster).

**Doesn't exist:**
- Any notion of a place inside a home, a room, a code, or several things in one place.
- A photo kept with an indoor place.
- CSV in or out anywhere in the app.

## Design

### 1 · Memory or its own store? Its own store, shown in memory (decision 1)

An inventory is a list of records the wearer maintains, with codes, batches and a spreadsheet round trip.
Readable memory is facts the assistant learned, one at a time. Putting 300 items into `ObjectMemoryStore`
would need a migration of its keying (one place per name) and would bury every other fact on the Memory
screen.

So LI is its own store, `HomeInventoryStore`. It appears in readable memory as one new kind,
`MemoryFactKind.storedItem`: one fact per item ("stud finder — G3, garage shelf three"), so Forget and
Correct work as they do for every other fact. The Memory screen groups them under one collapsed heading.

`object_memory` stays for "I just put my keys on the hall table". `find` in either tool checks both (§4).

### 2 · The model (pure, `Codable`)

```
struct StoragePlace: Codable, Identifiable { let id: UUID; var code: PlaceCode; var room: String
                                             var label: String; var photo: String?; var createdAt: Date }
struct PlaceCode: Codable, Hashable { let raw: String }   // normalised: "G3", "LOFT-2", "K12"
struct StoredItem: Codable, Identifiable { let id: UUID; var name: String; var aliases: [String]
                                           var placeID: UUID; var note: String?; var quantity: Int?
                                           var filedAt: Date; var batch: UUID; var source: Source }
enum Source: String, Codable { case spoken, typed, sheet, photo }
```

The store keeps the current state plus a short **change log** (create, move, remove, each with its batch).
Undo reverses the last batch. The log is kept 90 days. This is IH's "levels are a fold" idea made smaller:
there are no counts to fold, only where each item is.

`quantity` is optional and only ever what the wearer said. LI is not a pantry or a stock ledger (decision 4).

### 3 · Codes (`PlaceCodeParser`, pure)

- A code is 1–4 letters plus 1–3 digits, optionally with a dash ("G3", "SH1", "LOFT-2"), defined by the
  wearer. The parser accepts what speech recognition writes: "G three", "gee 3", "G. 3", "golf three".
- **Homophones:** B/D/E/G/P/T/V, M/N and F/S are confusable when spoken. Defining a code that sounds like an
  existing one ("D3" when "G3" exists) is allowed, but the wearer is told once ("that sounds like G3; I'll
  spell them when I say them"). Every code is then read back spelled with the room ("G for garage, three"),
  with `SpokenPartNumber`'s rules adapted. The room name is said with the code because it removes most
  ambiguity on its own.
- A code that has not been defined, used in "put X in Q7", is never created silently. "Q7 isn't a place
  yet; what is it?" This is IH's rule that only a load or a count may create an item, applied to places.

### 4 · Finding (`InventoryMatcher`, pure)

The order borrows from `VanStockMatcher`:

1. exact name or alias;
2. singular and plural, and the name without a leading article ("the drill" → "drill");
3. all of the query's words in the name ("stud finder" finds "Bosch stud finder");
4. a token overlap above a threshold.

One match gives the answer. Several give a short list for the model to ask about, and it never picks. None
falls back to `ObjectMemoryStore.find`, then "I don't have the X on file." The answer always comes from the
store's words. The tool's description says the model must not name a place the tool did not return.

### 5 · The tool (`home_inventory`)

`home_inventory` has these actions:

- `define_place` (code, room, label);
- `file`, which takes `items` for several at once;
- `find`, `whats_in` (code or room), `move`, `remove` and `undo`;
- `rename_place`, `remove_place` (refused while items are in it unless `move_to` is given);
- `photo_place`;
- `file_from_photo` (decision 6).

The writes are `localMutation`. **Filing and moving do not ask for confirmation.** Undo is one word away,
and the read-back says what was filed. `remove_place`, an import, and `file_from_photo` ask before they
change anything. Plan [LA](LA-quiet-after-actions.md)'s quiet ending may opt `file` and `move` in once they
report `ActionCompletion`.

### 6 · Photos

`photo_place` uses `ParkingPhotoFlow`'s shape: a glasses still from `filteredStill(for: .toolPhotoCapture,
source: .cachedFrameThenPhoto)`, or a phone photo or library pick through
`StillImageFiltering.filteredOrUnavailable`. There is one current photo per place, and retaking replaces it.
It is stored as JPEG beside the store's file. The new roster entries are `inventoryPlacePhoto` and
`inventoryPlacePhonePhoto`. With no filter, nothing is kept and the place is unchanged.

`file_from_photo` sends that filtered still to the **selected** vision model with a schema (a list of short
item names), through the structured-vision path. A separate roster entry `inventoryShelfReading` records
that this one is egress. With a local-only setup or Offline Mode, it says it can't read the shelf and offers
dictation. The list it returns is read back and is **never filed until the wearer confirms it**.

### 7 · The spreadsheet

- **Out:** a workbook through `XLSXWriter` with sheets `Items` (name, code, room, place label, note,
  quantity, filed) and `Places` (code, room, label, item count), plus a hidden sheet holding the export time,
  as `VanStockSheet` does. A CSV of the Items sheet is offered too (decision 5), through a new small pure
  `CSVCodec` (RFC 4180 quoting; UTF-8 with BOM so spreadsheet apps open it correctly).
- **Back in:** a workbook or CSV read by its headers (`name`/`item`, `code`/`location`/`place`, `room`,
  `note`, `qty`/`quantity`). It becomes a **proposal**: items to add, items that moved, new places, and
  rows refused with the reason (no code; a code missing from the Places sheet and from the store). The
  wearer sees it and applies it with one tap as one batch, so one undo takes the whole import back. This is
  `VanStockImportService`'s flow without the Field Assist gate. The workbook code moves out of
  `FieldAssist/VanStock/` into a shared folder, or LI takes a dependency on it in place (decision 7).
- Files arrive through the Home Inventory screen's **Import** (Files picker). Mail and the Share extension
  are not ways in for v1.

### 8 · The store (`HomeInventoryStore`)

One JSON file and a `photos/` folder in Application Support, under a format number. An unreadable file is
refused and never overwritten (`VanStockStore`'s rule). File protection is
`completeUntilFirstUserAuthentication`, so a spoken "put it in G3" with the phone locked in a pocket can
still write, for `VanStockStore`'s stated reason. It is registered in `DataStoreRegistry` as `homeInventory`:
personal memory, wearer-linked, delete-all supported, **backed up** (decision 3). The Forget and Correct
mutations are wired through `MemoryFactMutations`.

### 9 · Surfaces

- **Phone:** Home Inventory (rooms → places → items), search, place photo, import and export, and a "codes
  for labels" sheet to print or share (codes large, with room and label).
- **Display glasses:** an answer card for `find` and `whats_in` through the existing answer card (Plan
  [KP](KP-answers-you-can-act-on.md)): code, room, label, and the photo's existence ("photo on your phone").
- **Watch:** nothing new in v1. Asking by voice works from the watch's existing ask path.

## What LI leaves out

Sharing one inventory between household members' phones (the export is the share for now; a shared store
is its own decision). Stock counts, reorder points and barcodes on household items (that is van stock's
job). Valuations and insurance inventories. Automatic filing from passive camera frames: nothing is filed
from what the camera happens to see. Room maps or floor plans drawn by the app; a place's photo is the map.

## Decisions for Greig (open)

Recommendations first.

1. **Its own store, shown in readable memory** as `storedItem` facts (§1). `object_memory` stays as it is,
   and `find` checks both.
2. **Codes are the wearer's own**, 1–4 letters plus 1–3 digits, always read back spelled with the room. No
   imposed scheme.
3. **Backed up**, like notes and saved places. It is the wearer's own record, and a new phone should
   still know where the drill is.
4. **No stock keeping.** An optional quantity the wearer says, never decremented by the app.
5. **XLSX and CSV both**, out and in. CSV is the common format for existing household spreadsheets.
6. **Filing from a shelf photo: offered, confirmed every time**, and only with a cloud vision model the
   wearer already selected. Off in Offline Mode.
7. **Move the workbook code to a shared folder** (`XLSXReader`, `XLSXWriter`, and a header-mapping helper
   lifted out of `VanStockSheet`) rather than have an everyday feature import from `FieldAssist/`. Van stock
   keeps its behaviour, with its tests unchanged.

## Phases (one PR each)

### P0 — the pure core (headless)

- `StoragePlace`, `PlaceCode`, `StoredItem`, the change log with batch undo, `PlaceCodeParser` (spoken forms
  and homophone detection), the spelled read-back, `InventoryMatcher`, `CSVCodec`, the import proposal
  builder over header rows, and the wording.
- **Exit tests:** "G three", "gee 3" and "golf three" → G3; D3 against G3 is flagged; an undefined code
  is never created; a batch of three is undone in one; "the drill" with two candidates → a list; an
  unknown name → the `object_memory` fallback; CSV quoting round trips (commas, quotes, newlines, a BOM);
  an import with a missing code is refused per row, not whole.

### P1 — the tool and the store (headless, wired)

- `home_inventory` (all actions except photos), `HomeInventoryStore` and its registry entry,
  `MemoryFactKind.storedItem` with Forget and Correct, `object_memory`'s `find` checking the inventory, and
  the tool description in the prompt builders.

### P2 — the phone screen and the spreadsheet (headless, wired)

- Home Inventory screen, search, codes-for-labels sheet; the workbook code moved to a shared folder (with
  van stock's tests unchanged); export in XLSX and CSV; import as a reviewed proposal.

### P3 — photos (headless, wired)

- `photo_place` on glasses and phone with its two roster entries; `file_from_photo` with its schema, roster
  entry and confirmation; the Display answer card.

### P4 — device pass (owed)

- A real garage: ten places defined by voice on the glasses, forty items filed in sentences, found again a
  week later; confusable codes said in a noisy garage; a place photo from the glasses in poor light; an
  existing spreadsheet imported; VoiceOver over the screen.

## Acceptance

- Every answer to "where's X?" names a place the store holds, or says it doesn't know.
- No code is created by a misheard word; every write can be undone as the batch it was.
- Forgetting an item on the Memory screen removes it from the inventory.
- An import changes nothing until it is applied, and one undo takes it all back.

## Risks

- **Misheard codes.** The spelled read-back, the room said with the code, and the homophone warning are the
  defence. The device pass in a noisy garage is where this is measured.
- **The inventory goes stale.** Things move without anyone saying so. The answer always carries when the
  item was filed ("you put it there on 12 October") so the wearer can judge it.
- **A shelf photo reads wrong.** It is only ever a proposal, confirmed item by item.
