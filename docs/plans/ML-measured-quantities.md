# Plan ML — Measured Quantities (4.25 litres of oil, kept exactly, on the phone and to the office)

**Status:** 📝 Drafted 2026-11-19 — nothing implemented. **All nine decisions taken 2026-11-19 as
recommended** (owner: "1-9 yes, build it"). Decision 9's refusal ships first, as its own PR. The build follows Plan [MK](MK-stock-where-it-lives.md)'s build PR (branch
`feat/mk-stock-place`), which is changing the same VanStock files now. This docs PR also amends
Plan [HF](HF-office-stock-and-capture-contracts.md)'s four contracts so that the phone and the
office agree on one quantity form before either side is built.
**Track:** Field Assist (B2B).
**Builds on:**
- Plan [IH](IH-van-stock.md): the movement log, `van_stock`, the Van Stock screen, the spreadsheet
  out and back, and the record's `van_stock` block. IH §1 limits it to "whole quantities only",
  and its Open question 1 asked about refrigerant by weight. This plan answers that question.
- Plan [MK](MK-stock-where-it-lives.md): the place setting and `StockPlaceWording`. MK §7 names
  whole quantities as one of the limits the wording does not fix.
- Plan [HF](HF-office-stock-and-capture-contracts.md): the office stock contracts. They are drafted
  and not built, so their quantity form can still be fixed here.
- [`Contracts/office-reports.md`](../../Contracts/office-reports.md): the report that carries the
  work record to the office.

---

## Trigger

A mechanic tops up an engine with 4.25 L of oil. A precision workshop measures fluids to the
millilitre. Van stock cannot record either. Every quantity is an `Int` in the line's unit, so
4.25 litres can only be written as 4. MK's store and warehouse examples hit the same limit: resin
by the kilogram, and cable cut to part of a metre. IH named this from the start, for refrigerant
weighed to a fraction.

A fraction changes the quantity's type in six places: the ledger, its file, the spreadsheet, the
work record that goes to the office, Plan HF's contracts and the words the assistant says. HF is
drafted and unbuilt. If its contracts keep `onHand` as a whole number, the office and the phone
will each be built around a form one of them must later break. The time to decide is now.

## What exists (verified 2026-11-19 on `origin/main` 965de65b0)

- **Units** (`VanStockItem.swift`): `VanStockUnit` is a closed list. `each`, `m`, `ft`, `kg`, `lb`,
  `l`, `pack`. `phrase(_:of:)` writes "2 × Flame sensor", "10 m of Thermostat cable" and
  "1 pack of Wire nuts". `init?(spoken:)` refuses any unit not on the list.
- **Every quantity is `Int`.** `VanStockMovement.quantity`, `VanStockItem.minimum` and `.standard`,
  `VanStockLevel.onHand` and `.onOrder`, `VanStockLog.record(…quantity:)`, `appendOpening`,
  `VanStockCountCheck` (`expected`, `by`), `VanStockUnit.amount(_:)`, `VanStockHandover.topUp`
  (`standard - onHand`), and the sheet's To top up column (`max(standard - onHand, 0)`).
- **Edits keep figures as text.** An `edited` movement keeps `minimum` in `oldValue`/`newValue` as
  `"4"`, and `standard` as `"4:base"` (`encodeStandard`/`decodeStandard`). Undo reads them back
  with `Int(_:)`. A migration has to rescale these strings as well as the quantity fields.
- **The store has a format number and refuses a format it does not know.** `VanStockStore.File`
  is `version`, `log`, `van`, with `formatVersion = 1`. `read` returns `.unreadable` for any other
  version, and an unreadable file is never overwritten. An older build given a newer file
  therefore refuses it. It cannot misread it. `van-stock-previous.json` (the takeover archive) is
  the same format.
- **The tool's quantity is an integer, and a decimal is cut, not refused.** `VanStockTool`'s
  `quantity` is `"type": "integer"`. `PartsRequestTool.integer(_:)`, which both tools use, maps a
  `Double` through `Int(value)`. So today: "used 4.25 litres" records **4** without saying so;
  "used half a kilo" becomes 0 and is refused as "has to be at least 1"; "counted 3.5" records 3;
  `set_standard` at 0.5 becomes 0 and **clears the standard**. None of these says that it cut a
  figure (Decision 9).
- **The spreadsheet refuses fractions line by line.** `VanStockSheet.wholeNumber` reads "4" and
  "4.0" as 4 and anything negative, fractional, non-numeric or ≥ 1,000,000 as invalid, which
  becomes the line's `notAWholeNumber` refusal (On order is ignored instead). `XLSXWriter` writes
  numbers as `.number(Int)`, `<v>4</v>`. OOXML always stores a number with a `.` decimal, whatever
  the locale.
- **The screen counts whole numbers.** The line's page has a `Stepper` over `0...9_999` and a
  Minimum field with `.numberPad`. The list row shows `"\(onHand) \(unit.rawValue)"`.
- **The record's block.** `VanStockUse` (`id`, `number`, `description`, `quantity: Int`, `unit`,
  `verified`, `at`) uses synthesised `Codable` keys. It is stored on the open session
  (`FieldSession.vanStockUses`, a file with no format number). It is written into the work record
  as `van_stock` (`WorkRecord.swift:190`), and the record goes to the office inside the signed
  report.
- **The office reads the record as opaque bytes with no version.** `Contracts/office-reports.md`
  §4 says the record is opaque to the report contract. Open point 4 says the record "carry[s] no
  schema version" and the office "must read [it] tolerantly". The JQ extension says readers
  "ignore unknown additive fields". No office reads a report yet. The `van_stock` block is not
  described in any contract.
- **Parts requests and job updates are counts of a part.** `PartsRequest.quantity` is an `Int`
  with no unit (`WorkTask.swift:233`). `parts_request`'s `for_van_stock` turns it into an
  `ordered` movement in the line's unit (`VanStockService.noteOrdered`, at least 1).
  `Contracts/job-updates.md`'s `quantity` is "how many, `0` when not stated, at most 1 000 000".
  It is built (`OfficeJobUpdate.swift`, `Int64`), and the payload is closed.
- **HF's contracts are integers only.** They are closed flat JSON. "Fractional or exponent integer
  spellings [are] refused". `onHand` is an integer per location. `unit` is "`each`, `m`, `kg`,
  `l`, … (closed list)". Capture `count` lines and readiness `needed` are quantities with the same
  limit.

## Design

### 1 · A quantity is a whole number of thousandths

`StockQuantity` (pure, `Codable`, `Comparable`, `Sendable`) wraps one `Int`, the amount in
**thousandths of the line's unit**. 4.25 L is `4250`, 2 flame sensors are `2000` and 12 m is
`12000`. Sums, differences, comparisons and top-ups are integer arithmetic, so they are exact.
There is no float anywhere: 0.1 + 0.2 is 300 thousandths, and 1,000 additions of 0.001 L make
exactly 1 L.

**One scale for every unit, and the unit decides which steps are allowed** (Decision 2).
`VanStockUnit.step` is 1 thousandth for `m`, `ft`, `kg`, `lb` and `l` (a millimetre, a gram, a
millilitre, about a third of a millimetre, about half a gram). It is 1,000 thousandths, a whole
one, for `each` and `pack`. A quantity that is not a multiple of its unit's step is refused, never
rounded. "2.5 packs" is refused with a sentence: packs are counted whole, so the loose ones go on a
line of their own.

Why one scale and not a scale per unit: a line's unit can be edited (`Attribute.unit`), and a
movement does not record the unit it was made in. With a scale per unit, a line changed from
`each` to `l` would hold movements at two scales, and the migration would need each line's unit
at every point in its history. With one scale, the stored number never depends on the unit. The
migration multiplies everything by 1,000 without looking at units.

- **Changing a line's unit** keeps the stored figure, as today: 4 each becomes 4 l. A change to
  `each` or `pack` is refused while the on-hand, minimum or standard is not whole, with the
  sentence "4.25 l on hand is not a whole number of packs; count it first." That is the one new
  refusal on an edit.
- **Bounds.** At most 1,000,000 of a unit, so 1,000,000,000 thousandths. That is the sheet's limit
  today and job-updates' limit. Far below `Int` and below the contracts' 2^53 − 1.
- **Parsing is exact.** `StockQuantity(decimal:unit:)` reads a decimal string ("4.25", "4",
  "0.001", "4.250") digit by digit into thousandths. It never goes through `Double`. More than
  three decimal places is refused ("litres are kept to 3 decimal places"), and so is a fraction
  on `each`/`pack`. A `Double` from the model's JSON is first turned into its shortest round-trip
  spelling (`4.25`, `0.1`) and then read the same way.
- **Formatting has one source.** `StockQuantity.decimalString` gives "4.25", "4", "0.001": `.`
  as the separator, no trailing zeros, no exponent. That is the spelling for the model, the
  sheet and the log's edit strings. `formatted(locale:)` gives the screen's form ("4,25" in
  German and French, "4.25" in English) with up to three decimal places.

### 2 · The ledger file, format 2

`VanStockStore.formatVersion` becomes **2**. In format 2 every quantity is in thousandths: the
movement's `quantity`, the item's `minimum` and `standard`, and the `edited` strings for minimum
and standard (`"4250"`, `"5000:base"`).

**Loading a format 1 file migrates it exactly.** `VanStockLogMigration.fromFormat1` (pure)
multiplies every movement quantity, minimum and standard by 1,000 and rewrites the minimum and
standard edit strings the same way. A movement kind that has no quantity (`edited`, `reversed`)
keeps its zero. The result is saved straight away as format 2, and the archive file is migrated
when it is first read. Every level, top-up, low mark, open order and undo works out the same as
before, times 1,000. P1's tests check that on a recorded log.

**An older build given a format 2 file refuses it** with its existing check. It stays empty, says
the list can't be read, and writes nothing. It cannot read 4,250 mL as 4,250 litres. Nothing new
is needed for that, and a test pins it so a later change to `read` cannot loosen it. A newer
format (3 or higher) is refused by format 2 in the same way.

**The open session's uses** (`FieldSession.vanStockUses`) have no file format number. So
`VanStockUse` changes its **key name** (§5): it reads a legacy `quantity` as whole units and
multiplies by 1,000, and reads `quantityScaled` as it stands. The key name says which form it is.

### 3 · What the model is given and what it says

- **The tool's schema.** `quantity` becomes `"type": "number"` with the description "How much, in
  the line's unit. Up to 3 decimal places for m, ft, kg, lb and l (4.25 litres is 4.25); whole
  numbers for each and pack." `set_standard`'s figure and `count`'s figure follow the same rule.
  `parts_request`'s `quantity` stays an integer (§6).
- **Refusals are sentences, never silent cuts.** The tool says "Nothing recorded for Engine oil:
  litres are kept to 3 decimal places" or "Nothing loaded for Wire nuts: packs are counted whole."
  A zero after parsing is refused as today. The cuts listed above can no longer happen.
- **The composer writes measured amounts in words** (Decision 7): "4.25 litres of Engine oil",
  "1 litre", "0.5 kilograms", "12 metres", "0.75 pounds", "3 feet". `each` and `pack` read as
  they do now ("2 × Flame sensor", "1 pack of Wire nuts"). Today's results write "10 m"; the model
  turns that into speech, and "l" in particular is easily read as "one". The words go through
  `VanStockUnit.spoken(_:)`, the one place that names a unit in English. The count check reads
  "0.25 litres short of the 4.5 litres expected", and top-up reads "0.75 litres of Engine oil to
  bring it to standard". MK's wording tables gain no rows: the unit words do not depend on the
  place.
- **Spoken fractions are the model's job.** "Four and a quarter litres" or "four point two five"
  reach the tool as 4.25 because the model converts them, as it converts "a dozen" today. The
  device pass (P5) listens for that.

### 4 · The screen and the spreadsheet

- **The line's page.** For a measured unit, the count is a decimal field
  (`.decimalPad`) beside a stepper that moves one whole unit. It is read with the phone's locale,
  so "4,25" works in German, and then exactly as in §1. For `each`/`pack` the stepper and number
  pad stay as they are. Minimum and standard follow the same rule. The list row shows
  `formatted(locale:)` and the unit symbol ("4,25 l"), never a converted unit.
- **Out.** `XLSXWriter` gains a decimal number cell. It writes `decimalString` as `<v>4.25</v>`,
  which a spreadsheet shows in its own locale. On hand, Standard, To top up, Minimum and On order
  are written that way. Each/pack figures are whole numbers, as today.
- **Back.** The unit cell is read before the numbers, because the unit decides the allowed steps.
  `wholeNumber` becomes `quantity(_:unit:)`. It takes up to 3 decimal places for a measured unit,
  a whole number for `each`/`pack`, and, from spreadsheet storage only, an exponent spelling
  (`4.25E-1`). A cell that holds binary float noise from a formula (`4.2499999999999991`) is read
  as the nearest thousandth when it is within one millionth of a unit of it. Any other cell with
  more than 3 places, or a fractional each/pack figure, refuses the line with the reason "Engine
  oil: On hand 4.2513 has more than 3 decimal places" or "Wire nuts: On hand 2.5 is not a whole
  number of packs". The refusal case is renamed `notAQuantity(column:value:unit:)`.
- **Old and new builds and the workbook.** The workbook holds human figures ("4.25"), not
  thousandths, so it needs no scale marker. An older build importing a newer workbook refuses the
  fractional lines one by one and takes the whole ones. A newer build reads an older workbook's
  "4" as 4 units. Neither can misread the other.

### 5 · The work record's `van_stock` block

The block is the one quantity that leaves the phone today, and its reader is the hardest to
protect: the office reads the record tolerantly, with no version, and ignores unknown fields.
A line that kept the key `quantity` with the value 4250 would be read by such a reader as 4,250
litres. So the key changes (Decision 6):

```json
{"id":"…","number":"OIL-5W30","description":"Engine oil","unit":"l",
 "quantityScaled":4250,"quantityScale":3,"verified":true,"at":"2026-11-19T10:40:00Z"}
```

- `quantityScaled` is the amount in units of 10^−`quantityScale` of `unit`. `quantityScale` is
  `3` in every line this plan writes. It is on each line so that a line copied out of the record
  still says what it is.
- **No `quantity` key is written.** A reader that only knows `quantity` finds none, so it shows
  nothing or refuses the line. It cannot show a wrong figure. No office reads reports yet, so
  nobody loses a working figure. A reader that sees a `quantityScale` other than 3 must refuse the
  line rather than guess.
- **Reading back.** A record or session written before this plan has `quantity` in whole units,
  and it decodes to `quantityScaled = quantity × 1000`.
- **Written down.** P3 adds the block to `Contracts/office-reports.md` as an additive extension,
  in the way the JQ attribution extension was added, with a fictional fixture
  (`office-report-record-van-stock-v1.json`) holding an each line and a litre line. The report's
  signed format and domain do not change: the record digest covers the block like any other byte.
- The record's printed summary (`WorkRecord.swift:469`) uses the same words as the composer
  ("4.25 litres of Engine oil").

The block and the ledger change in **one PR**. Once the ledger holds thousandths, a `VanStockUse`
still writing `quantity` would carry 4250 under the old key. The record's form cannot lag the
ledger by a single build.

### 6 · What stays a whole count

- **`PartsRequest.quantity`, `parts_request`'s `quantity`, and job updates' `quantity`** count a
  part, and have no unit. They stay whole (Decision 8). An order for a measured line
  (`for_van_stock` on Engine oil) is a whole number of that line's unit, "5 litres asked for", and
  `noteOrdered` scales it into the ledger (5 → 5000). Ordering 4.25 litres is not a thing a
  supplier does. If a pilot needs it, `PartsRequest` gains a unit and a scale in a plan of its own,
  because the request is also a record kind the office receives.
- **Price.** HF's optional `price` is already in minor units of a currency, an integer. Nothing
  changes.

### 7 · Plan HF's contracts (amended in this PR)

HF is unbuilt, so no reader of its contracts exists, and its closed JSON already refuses unknown
keys and fractional spellings. The amendment keeps HF's integers-only rule and makes the scale
part of the signed bytes:

- Every payload whose body carries a quantity (stock snapshot, capture message, job readiness
  note, stock answer) gains a **`quantityScale`** member. It is exactly `3` in v1, and any other
  value is refused. A later finer scale is then a value a v1 verifier refuses, never one it
  misreads.
- Quantity members are renamed so their form is in their name: `onHand` → **`onHandScaled`**,
  `quantity` → **`quantityScaled`**, `needed` → **`neededScaled`**. Each is a non-negative integer
  in units of 10^−`quantityScale` of the line's `unit`, at most 1,000,000,000 (a million units). A
  value that is not a whole multiple of its unit's step (1,000 for `each`/`pack`) is refused.
- `unit` is **the phone's closed list exactly**: `each`, `m`, `ft`, `kg`, `lb`, `l`, `pack`. Not
  "… (closed list)". A unit added later is added to both at once.
- The rule "unknown is not zero" is unchanged. `known: false` with no `onHandScaled` is still the
  only way to say a figure is not known.
- HF P0's `WorkRecordStockMapping` reads `van_stock`'s `quantityScaled` and `quantityScale`, and
  refuses a line with no scale, rather than reading a legacy `quantity` as a ledger proposal.

### 8 · What this plan does not change

The movement kinds, their fields other than the scale of `quantity`, the item identifiers, the
match rules, the retention fold, `DataStoreRegistry` (`vanStock`), the backup rule, one list per
phone, and the feature's licensing. One unit per line (Decision 5). No unit conversion: a line in
litres is always shown and spoken in litres.

## Phases

- **P0 — the quantity (pure, headless).** `StockQuantity`: the exact decimal parse, the
  `Double`-from-JSON path, the per-unit step, bounds, `decimalString`, `formatted(locale:)`,
  arithmetic and comparison. `VanStockUnit.step` and `spoken(_:)`. About 30 tests.
- **P1 — the ledger, format 2 (pure + store).** Every `Int` quantity in `VanStockMovement`,
  `VanStockItem`, `VanStockLevel`, `VanStockLog`, `VanStockCountCheck` and
  `VanStockHandover.topUp` becomes `StockQuantity`. `VanStockLogMigration.fromFormat1` covers the
  edit strings, the opening figures and the archive. `formatVersion = 2`. The unit-change refusal.
- **P2 — what the model, the screen and the sheet see.** The tool schema and the exact parse that
  replaces `PartsRequestTool.integer` for stock quantities. The refusal sentences. The composer,
  service, handover and count-check wording through `spoken(_:)`. The line's page (decimal field,
  locale parse, the stepper per unit). `XLSXWriter`'s decimal cell, the sheet's
  `quantity(_:unit:)`, the float-noise rule and `notAQuantity`. `noteOrdered` scaling a whole
  order.
- **P3 — the record and the contract.** `VanStockUse.quantityScaled`/`quantityScale` with the
  legacy decode. The record's summary. The `van_stock` extension and its fixture in
  `Contracts/office-reports.md`. The portable contract check (`Contracts/tests/`) gains the
  fixture's shape: no `quantity` key, and a scale of 3.
- **P4 — the catalog sync (its own PR).** The build PR adds English only: the decimal field's
  label and the few refusal sentences on the screen and in the import review. It then translates
  them into the 18 other languages, as PRs 1128, 1133 and 1140 did.
- **P5 — the device pass (owed).** "I used four and a quarter litres of oil", "counted 3.5 kilos
  of refrigerant", and "used 300 mL" (the model has to convert to 0.3 l). A sheet with decimals
  round-tripped through Numbers and Excel on the phone, in English and German locales. A format 1
  log from a phone that has used the feature since October, opened by the new build, with its
  levels compared by hand.

**P0–P3 are one PR** (§5 says why the record cannot follow later). Under the house rhythm that is
the build PR, after MK's. P4 is the catalog PR. P5 is a report.

## Tests

- `StockQuantityTests`: "4.25" l is 4250, and "4.250" and "4.2500" are 4250 too (a trailing zero
  is not a fourth decimal place). "4.2501" l is refused. "0.001" l is 1, and "0.0005" is refused.
  "2" each is 2000, "2.5" each and "1.5" pack are refused, "2.0" each is 2000. A negative number,
  an empty string, "4,25", "1e3", NaN and over a million are each refused. A `Double` of 4.25,
  0.1 and 1e-3 from JSON parses exactly. Sums: 0.1 + 0.2 l is exactly 0.3. A thousand additions
  of 0.001 make exactly 1.000. A standard of 5 minus 4.25 on hand is 0.75. `decimalString` has no
  trailing zeros and no exponent. `formatted` gives "4,25" in de_DE and fr_FR and "4.25" in en_NZ
  and en_US.
- `VanStockLogMigrationTests`: a recorded format 1 log (loads, uses, a removal, a count, an open
  order, a minimum and standard edit with origin, an undo, an opening figure) migrates so every
  level, low mark, open order, top-up line and undo is exactly 1,000 times the format 1 result.
  Migrating twice is impossible because the version is checked first. The archive file migrates.
  A format 1 line whose unit was edited from `each` to `l` keeps its figures.
- `VanStockStoreTests` additions: a format 2 file is written after a format 1 load. A file whose
  format is not the reader's own (a format 3 file now, as a format 2 file is to today's build) is
  refused as unreadable and never overwritten. That is the "an old reader cannot misread" test for the log.
- `VanStockToolTests` additions: `use` with 4.25 on a litre line records 4250; with 4.25 on an
  each line it records nothing and says why; `count` 3.5 kg records 3500; `set_standard` 0.5 on a
  litre line sets 500 and does not clear the standard; `parts_request` `for_van_stock` 5 on a
  litre line puts 5000 on order. The schema's `quantity` is a number for `van_stock` and an
  integer for `parts_request`.
- `VanStockAnswerComposerTests` and `VanStockHandoverTests` additions: "4.25 litres of Engine
  oil", "1 litre", "0.5 kilograms", "12 metres", "3 feet"; each and pack read exactly as today.
  The count check gives "0.25 litres short of the 4.5 litres expected". No result contains "4250",
  "4.250" or a bare " l " symbol.
- `VanStockSheetTests` additions: an export writes `<v>4.25</v>` and `<v>4</v>`, and the export
  imported back changes nothing. "4.25" on a litre row is taken, "4.2513" refuses the line with
  its reason, "2.5" on a pack row refuses the line, and `4.2499999999999991` reads as 4.25. A row
  whose unit cell is `l` and whose quantity has decimals is taken even when the line was `each`
  on the phone, because the row's unit is read first. An older-format workbook's "4" is 4 units.
- `VanStockUseTests` / `WorkRecordTests` additions: the encoded `van_stock` line has
  `quantityScaled` and `quantityScale: 3` and **no `quantity` key**. A legacy `{"quantity": 2}`
  line decodes as 2000. An open session saved before the build decodes its uses at the new scale.
  The record summary says "4.25 litres of Engine oil".
- Contract check (`Contracts/tests/`): the `van_stock` fixture has no `quantity` member, every
  line's `quantityScale` is 3, and each `each`/`pack` line's `quantityScaled` is a multiple of
  1,000.

## Decisions for Greig

**All nine taken 2026-11-19 as recommended** (owner: "1-9 yes, build it").

1. ✅ **Fixed-point integers, not `Decimal`** (recommended). Every quantity is a whole number of
   thousandths, so the maths is exact and every contract keeps its integers-only rule. The
   alternative is `Decimal` everywhere, which is weighed here honestly. It is exact in base ten
   and reads naturally in code, but it has three costs. Foundation's `JSONDecoder` has been known to
   decode `Decimal` through `Double`, which brings back the float error it is meant to
   remove. Every contract in `Contracts/` refuses fractional spellings, and the Go side has no
   decimal type in its standard library, so the office would read the numbers as `float64`. And
   rounding becomes a choice at every operation instead of an impossibility. `Double` is not a
   candidate.
2. ✅ **One scale (thousandths) for every unit, with `each` and `pack` held to whole thousands**
   (recommended). The alternative is a scale per unit (×1,000 for measured units, ×1 for
   each/pack). Because a line's unit can be edited and movements do not record their unit, that
   puts two scales in one line's history and makes the migration depend on the unit at each point
   in time. Both give the same contracts, since the scale is stated either way.
3. ✅ **Three decimal places, no finer for now** (recommended): a millilitre, a gram or a millimetre.
   That covers the mechanic's 4.25 L, fluids to the millilitre and refrigerant to the gram. The
   scale is written into the record line and HF's payloads, so a finer scale later is a new value
   that older readers refuse, not a silent change. Alternative: four places now, for a trade
   that weighs grease or additive below a gram. No pilot has asked for that.
4. ✅ **Imperial units take thousandths like the metric ones, and no new units come in this plan**
   (recommended). `ft` and `lb` get thousandths (about a third of a millimetre and about half a
   gram). Quarts, gallons, fluid ounces, ounces and inches are not on the list today. A North
   American mechanic adds oil in quarts, so `qt` is likely to be the first one asked for. Each is
   one enum case, its spoken word and its screen string, and HF's unit list gains it at the same
   time. Alternative: add `qt`, `gal`, `fl oz`, `oz` and `in` now.
5. ✅ **One unit per line; cases and loose bottles are two lines** (recommended). A line counted in
   two units (a case of 12 and 5 loose) needs a conversion factor on the line, a two-part amount
   in every movement and every contract, and a rule for what "low" means. Two lines ("Soda water,
   case" and "Soda water, bottle") already work, and MK's Open question 1 proposes waiting for the
   pilot to ask. Alternative: a per-line `per` factor (12 bottles to a case) with the ledger in the
   smaller unit.
6. ✅ **In contracts, the scale is stated and the field name says the figure is scaled**
   (recommended): `quantityScaled` plus `quantityScale: 3` on each `van_stock` line, and in HF a
   signed `quantityScale` (exactly 3 in v1) with `onHandScaled`, `quantityScaled` and
   `neededScaled`. The new name protects against a reader that ignores fields it does not know.
   The scale protects against a reader that knows the name and assumes the scale. Alternatives:
   the name only (`quantityThousandths`, which would have to be renamed for a finer scale), or the
   scale only (keeps `quantity`, which a tolerant old reader of the record would misread).
7. ✅ **Measured amounts are written in words in what the model is given** (recommended): "4.25
   litres", "0.5 kilograms", "12 metres". This changes today's model-facing "10 m" for measured
   units only, and MK's wording tests are updated for those lines on purpose. Each and pack are
   untouched. The screen shows the symbol in the locale's form ("4,25 l"). Alternative: keep the
   symbols and leave the expansion to the model, which risks "l" being read as "one".
8. ✅ **Parts requests and job updates stay whole counts** (recommended). `PartsRequest.quantity`,
   `parts_request` and `Contracts/job-updates.md`'s `quantity` count parts and carry no unit. An
   order for a measured line is whole units of it. Alternative: give `PartsRequest` a unit and a
   scale, which changes a record kind the office receives and the built job-update contract, for
   orders no supplier takes.
9. ✅ **Stop the silent cut now, ahead of this plan** (recommended). Today a decimal from the model is
   cut to an integer with no warning: 4.25 litres is recorded as 4, a count of 3.5 as 3, and a
   standard of 0.5 clears the standard. A small fix of its own, in `PartsRequestTool.integer`'s
   stock callers, refuses a quantity that is not whole with a sentence ("whole numbers only for
   now") until ML's build lands. It touches the tool, not the VanStock files, so it does not
   collide with MK. Alternative: leave it until ML's build.

## Open questions

1. **Refrigerant.** Plan [IS](IS-refrigerant-toolkit.md) (the refrigerant toolkit) weighs a charge on a scale. Should a charge
   weighed in a refrigerant flow also record a `used` movement on the cylinder's line? Proposed:
   not in ML. Once quantities are exact the two can be joined in IS, with the technician
   confirming.
2. **Rounding a shortfall to what can be bought.** "0.75 litres of Engine oil to top up" is exact.
   Oil is bought by the litre or by the 5 L can, though. Proposed: the top-up states the exact
   shortfall, and a pack size per line is its own idea, if the pilot asks.
3. **Office display.** How the office shows 4250 thousandths is the office's choice. The contract
   only fixes that it is 4.25 of the line's unit. Office copy is out of this repository.

## Not in scope

- Unit conversion of any kind (litres to quarts, metres to feet, cases to bottles).
- Two units on one line, pack sizes, and a per-line conversion factor (Decision 5).
- New units (Decision 4).
- Fractional parts requests or job-update quantities (Decision 8).
- Changing HF's other rules (sequence, body files, receipts, expiry) or building any part of HF.

## Risks

- **Downgrading the app.** An older build refuses the format 2 log, which is safe but empty until
  the newer build is reinstalled. The older build's session decode meets a `van_stock` use with
  no `quantity` key and fails the open session's decode. Downgrades happen only through
  TestFlight, and the release note for the build says not to go back. Mitigation if wanted: an
  older-build decode that skips a malformed use. That would be a change to an older build, so it
  is not possible after the fact.
- **The model's arithmetic.** A spoken "three hundred mils" has to reach the tool as 0.3 litres.
  The schema says so, and P5 listens for it. The refusal path means a wrong scale (300 litres)
  is at least visible in the read-back, since the composer says the amount it recorded.
- **Spreadsheet apps.** Numbers, Excel and Sheets each store decimals in their own way. The
  float-noise rule covers formula results, and P5's round trip in two locales checks the rest.
- **MK in flight.** MK's build changes the composer, service, handover and sheet now. ML is built
  on top of MK's merged PR. ML's wording changes are limited to the amount (`spoken(_:)`) and do
  not touch `StockPlaceWording`.
