# Plan MK — Stock Where It Lives (van stock for a shop, a storeroom or a warehouse, in the words of the place)

**Status:** 📝 Drafted 2026-11-19 — nothing implemented. **All ten decisions taken 2026-11-19 as
recommended**, 7 in the form reworked the same day on the owner's point that a store may want its
numbers checked against a catalogue or a particular manual (§4). The build follows as its own PR,
after PR 1139 (the near-match fix), which adds van wording of its own to the same three files.
**Track:** Field Assist (B2B).
**Builds on:**
- Plan [IH](IH-van-stock.md): the movement log, `van_stock`, the Van Stock screen, the spreadsheet
  out and back, the close-of-job question and the shift handover. This plan changes none of how stock
  is counted. It changes what the place is called, who decides that, and which of IH's van-only
  steps a place offers.
- Plan [CT](CT-org-configuration-profiles.md): `SettingKey` and its `kind`s. `organizationAccentColor`
  (`profileOwned`, set and locked by the profile) is the pattern for the new key.
- Plan [EM](EM-work-record-and-parts.md): `PartsVerifier`, the source of the "checked against the
  manuals" mark that §4 narrows.

---

## Trigger

A pilot tester runs van stock in a shop, not a vehicle: cases of drinks, kept in bins such as the
main fridge. The owner asked whether the user, the company or a partner can set the "van", or
whether it should be generic. Today only the list's name can be changed: it becomes the screen's
title. Every answer the assistant gives still says "on the van", the tool tells the model it is
about "the technician's own van or truck", a load is offered a "top-up to standard load", the
handover goes "to base", and every line with a part number carries "Number not checked against the
manuals", which means nothing for a bottle of gin.

The answer given to the owner: van stays the default, because field technicians are who the
feature was built for. A **place** setting goes beside it. The organisation profile can set the
place and lock it. Otherwise the person keeping the list chooses it. The same feature then reads
naturally in a shop.

## What exists (verified 2026-11-19 on `origin/main` e129d36df)

- **One editable name.** `VanIdentity` (`VanStockHandover.swift`) is `id` and `name`. The name is
  the screen's title when set (`App/Views/Job/VanStockViews.swift:49`), entered through "Name this
  van…" with the placeholder "Truck 4". It is written to the workbook's hidden `Avenkin` sheet as
  `van_name`, beside `van_id` and `exported_at`. The reader looks up meta rows by key, so an older
  build ignores a key it does not know.
- **Model-facing text is English and hard-coded.** `VanStockTool.description` and its
  `parametersSchema` are `let`s ("The technician's own van or truck stock…"). The sentences come from
  `VanStockAnswerComposer` (about 23 literals that name the van, the van list or the manuals),
  `VanStockService` (about 37: "put on the van", "taken off the van", "the van log", "standard load",
  "returning it, or keeping it on the truck?"), `VanStockHandover` ("Van" as the fallback name, "No
  standard load is set for this van"), `JobCloseSequence` ("Ask the technician whether each came off
  the van") and `PartsRequestTool` (`on_van`, `for_van_stock`, "It is not a line on the van list").
  IH P0 decided that these are English on purpose: the model reads them and answers in the person's
  language. `NativeTool.description` and `parametersSchema` are `get` requirements, so both may
  become computed.
- **Screen text is localised.** About 31 string literals in `VanStockViews.swift` (14),
  `VanStockImportReviewSheet.swift` (12), `VanStockHandoverSheet.swift` (3) and `JobListView.swift`
  (the "Van stock" row, 2) name the van, the truck or base. 28 of the catalog's keys contain "van"
  or "truck", each translated into 18 languages besides English.
- **The workbook names the van as well.** The stock sheet is called "Van stock", the file
  "Van stock 2026-10-14.xlsx", and the Standard set by column says "This truck" or "Base".
- **The organisation can only switch it off.** `SettingKey.organizationForbidsVanStock` is a
  ceiling pinned on. It hides the Job-tab row and makes the tool refuse
  (`OrgProfileManager.swift:1110` "Van stock is off"). It is listed in
  `docs/deployer-information-sheet.md`.
- **"Not verified" means two things.** `VanStockItem.verified` is a `Bool`. A line loaded with no
  job open is looked up with no vault to look in and is stored as `false`, the same value as a number
  the manuals were searched for and did not contain. `VanStockRows.isUnverified` (`number != nil &&
  !verified`) puts the mark on both. The composer says "The part number is not verified against the
  manuals" for both, and the first-load read-back says the number "is not in the manuals".
- **Units are a closed list:** `each`, `m`, `ft`, `kg`, `lb`, `l`, `pack`. The unit picker on the
  line's page shows the raw values, not localised names.
- **There are no other trades to borrow from.** `FieldTrade` has `refrigerationHVAC` and `electrical`.
  A vault is a set of manuals, and a phone can hold several, so neither one says where stock is kept.

## Design

### 1 · A place is a kind and, optionally, a name

`StockPlace` (pure, `Codable`) is a **kind** from a closed list and the list's existing **name**:

| Kind | Family | Said as | Example name |
|---|---|---|---|
| `van` (default) | vehicle | on the van | Van 2 |
| `truck` | vehicle | on the truck | Truck 4 |
| `store` | premises | in the store | Main street store |
| `warehouse` | premises | in the warehouse | Warehouse A |
| `stock` (neutral) | premises | in stock | Factory 2 stores |

**`stock` is the catch-all** (Decision 10). It names no place: "22 in stock", "the stock list".
With no place noun it is safe in every language, so it covers a factory, a workshop, a storeroom, a
site container, a clinic's supply cupboard or a bar, with the list's name saying which. Named
kinds are kept for places where the noun really helps the sentence. A new named kind later costs one
enum case, its English phrases and four screen strings in 19 languages, so the list grows only when
a pilot asks for one.

A **custom name is a name on one of these kinds, not another kind.** A sentence needs a noun whose
grammar it knows: "on" a vehicle, "in" a building, and in the 18 translations, a gender, an article
and a case. A free word ("the cellar", "the fridge") cannot be put into a translated sentence
safely. So the name goes where a name works on its own: the screen's title, the Job-tab row, the
workbook, the handover message, and the model's results as a label ("Main street store: 22 packs in
the store"). The kind is what the sentences are built from. In English, `store` is said as "store",
which reads correctly in both American and New Zealand English.

The **family** decides which of IH's steps the place offers (§5). A kind this build does not know,
from a newer build's workbook or profile, reads as `van` in a workbook and is a named drop in a
profile (§2).

### 2 · Who sets it

The place is resolved in one place, `StockPlaceSetting.resolve` (pure), in this order:

1. **The organisation profile**: a new `SettingKey.organizationStockPlace`, `profileOwned(.string)`,
   so it is set and locked like `organizationAccentColor`, and cleared when the profile is removed.
   The content check denies by default: a kind this build does not know is a named drop ("not one of
   van, truck, store, warehouse or stock"), never a guess. The profile summary says "Stock is kept in the
   store". The deployer information sheet gains its row.
2. **The list's own place**, chosen by the person keeping the list, on the Stock screen: "Name this
   van…" becomes "Name and place…", a sheet with the kind as a picker and the name as a field. When
   the profile has set the place, the picker is shown read-only with "Set by your organisation", as
   the accent picker is.
3. **Van.** Nothing changes for anybody who does not choose.

The place is stored with the list, as an optional `place` on `VanIdentity`, and written to the
workbook's meta sheet as a `place` row. So a takeover carries it: the next shift's phone reads the
same words the last one did, and an older build ignores the row. A profile's place overrides a
workbook's on the phone that applies the profile, and is not written back into the list. Removing
the profile restores the list's own choice.

**Not from the vault or the trade.** A vault describes equipment, not the business, and a phone
holds several. `FieldTrade` has two trades, both of them van trades. A partner who ships a profile
to their customers sets the place through the profile, which is the partner channel CT already
provides.

### 3 · One source for every word about the place

`StockPlaceWording` (pure) is the only code that says anything about the place. It is English, for
the model:

| Phrase | van / truck | store / warehouse | stock |
|---|---|---|---|
| where | on the van | in the store | in stock |
| the list | the van list | the stock list | the stock list |
| put there | loaded, put on the van | put in the store | put into stock |
| taken | used, taken off the van | sold or used, taken from the store | used or sold, taken from stock |
| the usual figure | standard load | par level | par level |
| who set it | base / this truck | the office / this store | the office / this list |
| the handover | send the stock to base | send the stock list | send the stock list |

`VanStockAnswerComposer`, `VanStockService`, `VanStockHandover`, `JobCloseSequence`'s stock
question and `PartsRequestTool`'s result lines take a `StockPlaceWording` instead of literals.
`VanStockTool.description` and `parametersSchema` become computed from the resolved place, so a
place changed on the screen is in the next turn's tool definitions. Whether the definitions cache
(Plan IU's on-demand mode) holds an old description across that change is checked in P1 and pinned
by a test.

**The tool's name and action values stay**: `van_stock`, `send_to_base`, `not_from_van`, `on_van`,
`for_van_stock`. They are contract strings in `OfflineToolPolicy`, `ToolEffectClassification`,
`FieldToolProfile` and the tests, and the model reads the descriptions, not the identifiers. The
descriptions lead with the place: "The stock kept in the store, on the phone. Use it whenever they
ask what is in the store, or say they received, sold, used, returned or counted stock."

**The screen does not name the place in its sentences** (Decision 5). Its strings are rewritten to
read the same everywhere: "Nothing on the list matches that", "On hand", "The list on this phone
can't be read". The place shows only where a name works alone: the title and the Job-tab row
("Van stock", "Truck stock", "Store stock", "Warehouse stock", "Stock", or the list's name). Three places
genuinely need the kind, and get one string per kind: the takeover button ("Take over this van" /
"…this truck" / "Take over this list"), the empty-state hint ("I've loaded four flame sensors" /
"I've put in six cases of soda water"), and the name field's placeholder. The workbook's sheet,
file name and Standard set by column follow the kind too. Care is needed in that column: today's
reader takes only "base" as set by base and anything else as set by the list. A store's export
writes "Office", so the reader must learn "office" as the same marker, or a re-imported store sheet
would claim every office-set figure as its own. "This store" and "This truck" already read as set
by the list.

### 4 · Numbers checked against the book the list names, and marked only when that book was asked

**What a lookup is today.** `PartsVerifier` is pure over one vault's parts table
(`VaultPartsIndex`) and an exact-token search of that vault's manuals. `FieldSessionService` builds
it only for the open job's vault, so a line loaded with no job open is never looked up at all.
Nothing in the verifier is tied to a job: it can be built for any installed vault.

**The list names its book.** A list may name one installed vault to check numbers against:
"Check numbers against" on the Stock screen's Name and place sheet, beside the place. A vault is
the app's container for both a catalogue and a manual, so this covers a supplier's catalogue
written as a vault with a parts table, and a single manual added to a vault of its own. The
choice is stored on the list (`VanIdentity.checkVaultID`). It is **not** written into the
workbook, because a vault id means nothing on a phone that lacks that vault, and a takeover keeps
the receiving phone's own choice. The book used for a number is, in order:

1. the open job's vault, when a job is open (today's behaviour, unchanged);
2. otherwise the list's named vault, when it is installed and readable;
3. otherwise none, and nothing is searched.

There is no default. A store searches nothing until somebody names a book, and a van searches
the job's vault as it does now. A van may also name one, so a line loaded at the shop is checked
at once against the brand the technician mostly works on. A named vault that has been removed is
treated as none, and the sheet says it has gone.

**Three states, not two.** `VanStockItem.verified: Bool` becomes `verification`: `found`, `notFound`
or `notChecked`, plus the name of the vault that answered. A stored `true` decodes as `found` and a
stored `false` as `notChecked`, because today's `false` cannot say whether anything was searched.
A lookup is recorded as `notFound` only when it ran against a vault with a parts table or manuals.
With no book it is `notChecked`, and a later look that has a book still upgrades it, as today.

- The screen's mark names the book: "Not found in Supplier catalogue", on `notFound` lines only.
  A `found` line can show where it was found, as a task's part does.
- The composer's sentence names the book too ("not found in Supplier catalogue"), for `notFound`
  only. A store that has named no book never hears about manuals.
- The first-load spelling read-back stays for every place: a misheard stock code is as costly as a
  misheard part number. The reason given follows the facts: "has not been on this list before" for
  `notChecked`, and "is not in Supplier catalogue and has not been on this list" for `notFound`.
- **A found number is not proof of stock**, only that the number exists in that book, exactly as
  for a technician. The supersession lookup (a number replaced by a newer one) comes for free from
  the parts table.

### 5 · What each family keeps

| IH step | vehicle (van, truck) | premises (store, warehouse, stock) |
|---|---|---|
| `check`, `low`, `load`, `use`, `remove`, `count`, `undo` | as today | as today, in premises words: a use is "sold or used" |
| `use` tagged to the open job; `unrecorded`, `not_from_van`; the close-of-job question | as today | no longer in the schema the model is given. A premises list has no job to tag, and the close question is asked only when a job closes, so nothing is lost |
| standard load: `top_up`, `set_standard`, `load` with `to_standard`; base's baseline import | as today | kept, worded as the par level: "brought everything up to par except the soda water". The sheet already reads a Par column |
| `send_to_base` | as today | kept as "send the stock list": the levels, what to reorder and what needs counting, through the share sheet. It never says "base", and the day's-extras question is not asked |
| Take over this list (from a workbook) | as today | kept, as "Take over this list", for a shop where the closing person's phone hands over to the opening person's |
| Previous list, Import, Export, Undo | as today | as today |

The day's extras (`VanStockSurplus`) belong to a vehicle that is loaded for a route and comes back.
A shop's stock does not travel, so asking "returning it, or keeping it on the truck?" would only
confuse.

### 6 · What does not change

The movement log, its file and its fields, apart from the optional `place` and `verification`.
`organizationForbidsVanStock`, which keeps its name, because signed profiles already carry it.
`DataStoreRegistry` (`vanStock`), the backup rule, the HIPAA rule on the handover, the one-list-per-
phone rule (IH Decision 8), and the feature's licensing: it still needs Field Assist switched on.

### 7 · A warehouse, a factory, a team: what the words do not fix

`stock` makes the words right anywhere. Four limits stay, and they are not wording:

- **One list on one phone at a time** (IH Decision 8). A warehouse or a factory usually has several
  people taking from the same stock at once. That needs the company's stock in Avenkin Office
  (Plan [HF](HF-office-stock-and-capture-contracts.md)), not a setting. Until then, each person
  keeps their own list, or one phone keeps the list for the whole place.
- **Whole quantities only** (IH §1). Resin by the kilogram or cable cut to fractions of a metre hits
  the same limit as refrigerant by weight. Fractions change the quantity type through the ledger
  and HF.
- **Where the list is opened.** It is reached from the Job tab, and a factory or a shop runs no jobs
  (Open question 2).
- **Locations inside the building are already covered**: every line has a bin label ("Main fridge",
  "Rack C3"), searched like the description.

## Phases

- **P0 — the place (headless).** `StockPlace` (kinds, family, decoding an unknown kind),
  `StockPlaceWording`, `StockPlaceSetting.resolve` (profile over list over default),
  `VanIdentity.place` with older JSON decoding, the meta sheet's `place` row in and out, and
  `VanStockVerification` with the legacy decode. About 25 tests.
- **P1 — what the model sees and hears (headless).** The composer, service, handover, close question
  and `parts_request` lines through `StockPlaceWording`; `VanStockTool.description` and
  `parametersSchema` computed per place, with premises dropping `unrecorded` and `not_from_van`;
  §4's book order (job, then the list's named vault, then none) through a `PartsVerifier` built
  for a named vault outside a session, and `found`/`notFound`/`notChecked` naming the book; §5's
  premises `send_to_base` with no extras question. Tests pin the wording per place (below).
- **P2 — who sets it, and the screen (headless + simulator).** The `organizationStockPlace` key, its
  content check, the profile summary line and the deployer sheet row; "Name and place…" with the
  locked state and the "Check numbers against" vault picker (with its "has gone" state); the place-neutral rewrite of the screen strings; the per-kind title, row, takeover
  label, hint and placeholder; the workbook's sheet and file names; the "Not in the manuals" mark.
  Simulator screenshots of a van and a store in both appearances and at the largest text size, and
  the Van Stock screen's accessibility-audit entry IH P2 still owes.
- **P3 — the catalog sync (its own PR).** The build PR adds English only. About 50 keys are changed
  or added: about 31 rewritten to be place-neutral, 5 titles, about 12 per-kind strings, and the
  profile's summary and refusal, and the vault picker's few strings. All of them are then
  translated into the 18 other languages and the retired van keys removed, as PRs 1128, 1133 and
  1140 did for earlier features.
- **P4 — the pilot pass (owed).** A shop's own spreadsheet imported into a store list, a day of
  spoken checks, receipts and counts in the shop, and a read of every spoken answer for a stray
  "van", "truck", "base" or "manuals". The same day on a technician's phone with the place left at
  van, to confirm nothing changed for them.

P0–P2 are one PR, under the house rhythm. P3 is the catalog PR. P4 is a report.

## Tests

- `StockPlaceTests`: each kind's family; an unknown kind in a workbook reads as van; a list with no
  `place` decodes as van; the meta row round-trips and an older workbook without it imports.
- `StockPlaceSettingTests`: the profile wins over the list, the list over the default; removing the
  profile restores the list's own choice; the profile's place is never written into the list.
- `StockPlaceWordingGuardTests` (source scrape, like `DATExperimentalGuardTests`): no string
  literal under `Services/FieldAssist/VanStock/`, in `VanStockTool`, or in the stock lines of
  `JobCloseSequence` and `PartsRequestTool` contains "van", "truck", "base", "standard load" or
  "manuals" outside `StockPlaceWording`. The contract identifiers are listed as exceptions.
- `VanStockAnswerComposerTests`, `VanStockToolTests`, `VanStockHandoverTests` and
  `VanStockJobCloseTests`, run for every kind: each result and the tool's description contain the
  kind's own words and none of the other family's ("van", "truck", "base", "load" at a store; "store",
  "warehouse", "par" on a van; no place noun at all at `stock`). The van run's expected strings are
  today's, unchanged, so the default is pinned to what ships now.
- `VanStockToolTests` additions: a premises schema has no `unrecorded` or `not_from_van`;
  `send_to_base` at a store asks no extras question and stages the list; a store with no named
  vault makes no lookup (the injected `verify` is never called).
- `VanStockVerificationTests`: legacy `true` is `found` and `false` is `notChecked`; a lookup with
  no book records `notChecked`, never `notFound`; the book order is job, then named vault, then
  none; a named vault that has been removed is none; a later lookup with a book upgrades
  `notChecked`; the mark and the sentence name the book that answered and show on `notFound` only;
  the named vault is not written into the workbook and a takeover keeps the receiving phone's.
- `SettingKey` and `OrgProfileManager` tests: the new key's kind, a known kind applied and locked, an
  unknown kind dropped with its sentence, the summary line.
- `VanStockSheetTests` additions: the sheet and file names per kind; "This store" and "This truck"
  both read back as set by the list; "Office" and "Base" both read back as set by base, so a store's
  export imported straight back changes no standard's owner.

## Decisions for Greig

**All ten taken 2026-11-19 as recommended** (owner: "1. yes, 2, yes, 3, yes, 4, yes, 5, yes, 6,
yes", "8 and 9 yes"). 7 was reworked on the owner's question ("a store could want to search
through a catalogue or a specific manual for a part number?") and taken in that form ("Yes, take
7").

1. ✅ **Named kinds, and a custom name rides on one of them** (recommended): van, truck, store,
   warehouse, and the neutral `stock` of Decision 10, with the list's existing name as the custom
   part. The alternative is a free-text
   place word, which cannot go into translated sentences and would leave the screen half in the
   person's word and half in "van".
2. ✅ **The default stays van, with no guess from the region** (recommended), so no existing list
   changes its words without someone choosing. The alternative, truck for American English (IH's
   open question 2), changes the wording on phones that have used the feature since October.
3. ✅ **The organisation's profile sets and locks it, and otherwise the person keeping the list chooses
   it** (recommended). The vault and the trade do not set it. The alternative adds a second,
   unlocked profile key as a starting value, as the accent colour has. That can come later if a
   partner asks.
4. ✅ **The place travels with the list, in its workbook** (recommended), so a takeover keeps the
   words. The alternative is a per-phone setting, which a new phone would have to be told again.
5. ✅ **The screen's sentences are rewritten to be place-neutral, and the place appears in the title,
   the row and three per-kind strings** (recommended): about 50 keys, translated once. The
   alternative, per-kind variants of every sentence, roughly triples the keys and every future
   string.
6. ✅ **The tool and action names stay `van_stock`, `send_to_base`, `not_from_van`** (recommended),
   and only their descriptions follow the place. A store's schema leaves out the two job-only
   actions. The alternative renames the tool to `stock`, which touches the classification tables,
   the offline policy, the field tool profile and every stock test, for a word the model reads
   through the description anyway.
7. ✅ **Numbers are checked against the book the list names, and marked only when that book was
   asked** (recommended, reworked 2026-11-19). The order is the open job's vault, then a vault the
   list names under "Check numbers against" (a supplier's catalogue with a parts table, or one
   manual), then none. Nothing is searched until a book is named, and the mark ("Not found in
   Supplier catalogue") shows only for a number that book was searched for and did not hold. A van
   may name one too, so a line loaded with no job open is checked at once. The first version of
   this decision had a store never search. The alternative now is the job's vault only, as today,
   with the mark narrowed to `notFound`, which leaves a store with no way to check a number.
8. ✅ **"Par level" is the store's word for the standard load** (recommended): it is what retail and
   hospitality say, and the importer already reads a Par column. The alternatives are "usual level"
   or keeping "standard load" everywhere.
9. ✅ **A store keeps `send_to_base` as "send the stock list", with no extras question, and keeps the
   takeover as "Take over this list"** (recommended). The alternative hides both at premises, which
   loses the opening-and-closing handover a shop with two staff phones can use.
10. ✅ **A neutral `stock` kind is the catch-all for every other place** (owner, 2026-11-19: "stock,
   yes"). It is said as "in stock" and "the stock list", names no place, and takes the premises
   steps. It covers a factory, a workshop, a storeroom or a bar, with the list's name saying which
   one. Named kinds are added only when a pilot asks. Several people sharing one stock is HF's, not
   this plan's (§7).

## Open questions

1. **Cases and bottles.** A drinks shop counts in cases and bottles. `pack` covers a case today. Is
   a `case` unit wanted, and should one line be countable in two units (cases and loose bottles)?
   The first is one enum case and its sentences. The second is a quantity change through the whole
   ledger and HF, as fractional refrigerant was in IH's open question 1. Proposed: neither until the
   pilot asks. Localising the unit picker, which shows raw values today, is worth doing in P2
   either way.
2. **The entry point.** The list is reached from the Job tab. A shop does not run jobs. Proposed:
   keep it there for the pilot, with the row's label following the place, and make a Home tile its
   own plan if the shop finds it hard to reach.
3. **A phone with a shop and a van.** One list per phone stays (IH Decision 8). A business with both
   uses a phone for each until HF's company-wide stock exists.

## Not in scope

- More than one stock list on a phone, several people working one list at once, transfers between
  places, and company-wide stock (Plan HF).
- A point-of-sale feed, sales figures, prices or reordering from a supplier.
- Renaming `organizationForbidsVanStock` or any tool or action identifier.
- A free-text place word in sentences, and a named kind for every kind of business (`stock`
  covers the rest).
- The Home tile (Open question 2).

## Risks

- **The model may still say "van"** from the tool's name. The description and every result say the
  place's words, and P4 reads a day of spoken answers to check. If it persists, a line in the
  description ("Say 'the store', never 'the van'") is the next step before any rename.
- **The neutral rewrite changes text that technicians already know.** The van run of the wording
  tests keeps every model-facing sentence as it is today. Only screen sentences change, and only to
  drop the noun.
- **Translations.** About 50 keys across 18 languages is a catalog PR the size of PR 1133's. Until
  it lands, the new strings show in English.
