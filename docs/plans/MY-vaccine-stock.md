# Plan MY — Vaccine Stock (each dose given, by lot and expiry, waste kept apart, a weekly count, and a daily check against the clinic's own records)

**Status:** 🚧 **P0–P3 built 2026-11-22 (headless).** Lots, waste and expiry; GS1 parsing; the scan
sheet and the clinical `van_stock` actions; the lot-by-lot weekly count, `StockPeriodReport` (screen,
spreadsheet, spoken sentence) and the weekly count reminder; and the check against the EMR
(`ImmunisationListReader`, `CSVReader`, the line aliases, `ImmunisationReconciliation`, the
medical-mode gate). All 12 decisions are built on the plan's recommendations
(`VaccineStockPolicy`) and remain the owner's to change. The 9 new test classes and every existing
stock, org-profile, settings-visibility, catalog and brand guard class pass on the simulator (815
tests, 60 classes); the full suite (19,508 tests) and the Release build pass. `check-privacy-logging.sh`
passes. **2026-11-25:** the clinic's own vaccine list imports as it is (§8, P3b): a list with a
code and a description and no quantities comes in as new lines, a tariff code is the line's number,
and short forms and brand names become the line's codes, which the EMR check matches as well as the
number. **2026-11-27, P4:** the catalog sync is done: 118 keys in the 13 complete languages,
add-only, the EMR named by each language's usual short term. Owed: a simulator check of the scan sheet, the count sheet, the report and the EMR check sheet; the device
pass (a real carton scanned, and the reminder seen on a phone); P5 the pilot; a
takeover workbook still drops lots (it carries lines and figures only). **2026-11-27, the clinic's brief (P3c):** the clinic set
out the table it has in mind (immunization number, category, description, tariff, brand names,
quantity on hand) and how it expects stock to move: a tariff billed in the EMR uses one bottle. The
table imports as it is: `Category` is kept on the line, and `Immunization #` joins its codes (§8).
Stock lowered by billing is not built and is set out as Decision 13 (§8a), with the question of
whether a tariff is a dose or a bottle (§2). One new screen string (*Category*) is owed to a
catalog sync. **2026-11-28, after the build-799 notes:** the spreadsheet export writes a
`Category` column (last, after the hidden Item ID, and only when some line has one), so an export
read back, or taken over on another phone, keeps each line's group; a tap on the count reminder opens Jobs › Stock with the count
sheet up, from a cold launch too (routed by the reminder's identifier, `userInfo` still empty); and
a carton whose code no line carries offers "Which line is this?" (§5): the chosen line keeps the
GTIN-14 in its codes in the same entry as the movement, so one Undo takes both back and the next
scan finds it; a code already on another line is refused. Owed: the new screen strings to a
catalog sync; a simulator look at the link and the reminder tap; a takeover workbook drops a line's
codes as well as its lots, so a linked carton is linked again on the new phone. **2026-11-29:** what
the EMR check, the billing check and the scan sheet say is screen text in the phone's language, with
its plurals and dates. A scan that records nothing now gives the sheet a reason of its own
(`StockScanFlow.Problem`, worded by `StockScanText.problem`); before, it showed the assistant's
English answer, instructions to the model included. That answer is unchanged. The new
strings are translated in a catalog PR of their own.
**Track:** Field Assist stock, for a medical clinic. The phone, not the glasses (Decision 10).
**Builds on:**
- Plan [IH](IH-van-stock.md): the phone's own stock list. That means the append-only movement log
  (`VanStockMovement`: `loaded`, `used`, `removed`, `counted`, `reversed`…), the fold
  (`VanStockLedger` → `VanStockLevel`), the count check (`VanStockCountCheck`: matches / short by /
  over by), the matcher that tries a scanned code first (`VanStockMatcher`), the `van_stock` tool,
  the Stock screen, the spreadsheet import (`XLSXReader`, `VanStockSheet`) and the export
  (`XLSXWriter`).
- Plan [MK](MK-stock-where-it-lives.md): the place (`StockPlace`, here the neutral `stock` kind
  with the clinic's own name for the list) and its wording (`StockPlaceWording`).
- Plan [ML](ML-measured-quantities.md): `StockQuantity`. Doses are whole numbers of `each`.
- Plan [MM](MM-stock-in-the-business-system.md): the rule that where a business's own system
  already counts the stock, the phone keeps no second count. If the clinic's records system has a
  vaccine stock module, MM's pattern applies instead of this plan's count (Decision 9).
- The medical compliance mode (`HIPAAComplianceService`, `Config.hipaaMode`, Plan
  [DL](DL-medical-secret-and-export-lifecycle.md)): file protection, the audit log, no cloud
  memory sync, and no web search or messaging tools.

---

## Trigger

A partner talked with the owner and manager of a medical clinic on 2026-11-22. The clinic records
each vaccination by hand: the patient's record in its records system (the EMR), a spreadsheet of
doses, and a count of the fridge every so often. Entries get missed. Three things go wrong when
they do:

1. The stock figure is wrong.
2. Doses given and doses wasted can't be told apart.
3. A dose that never reached the EMR is never claimed, so the clinic is not paid for it.

The clinic will pilot with us. The flow the partner proposed is ours to shape:

- staff say or scan which vaccine was given, with its lot;
- the app takes it off the stock and keeps waste separate;
- daily and weekly reports;
- a weekly count, with differences flagged.

The partner's caution is the design constraint: **this must not become another separate log** of
who was vaccinated.

The clinic's second ask, an EMR help vault, needs no build. It is set out under
[The other ask](#the-other-ask-an-emr-help-vault-no-build) at the end.

## The point, said once

**The EMR is the record of who was given what. The app is the record of the fridge.** The app
never stores who a dose was given to. It keeps:

1. **Every dose that left the fridge, and why:** given or wasted (with the reason), by vaccine,
   lot and day.
2. **What is in the fridge:** by vaccine and lot, with expiry dates, from deliveries in and counts.
3. **The difference between the two records.** Each day, the app compares its doses given per
   vaccine, lot and day with the EMR's own list of immunisations. A dose the app saw and the EMR
   lacks is an entry someone missed, and so a claim nobody made. A dose the EMR has and the app
   lacks is a stock entry someone missed. Staff then fix the EMR in the EMR. The app writes nothing
   to it.

That third job is what gets the clinic its money back, and it needs no patient data on the phone.

## What exists today (verified 2026-11-22 on `origin/main` c96a18fa9)

- **The ledger already has most of the verbs.** `VanStockMovement.Kind` has `loaded` (a delivery),
  `used` (a dose given), `removed` with `RemovalReason` `returned` / `damaged` / `lent` / `other`,
  `counted` (a stocktake sets the level) and `reversed` (a mistake is taken back, never deleted).
  Movements carry no free text, and their own comment says the log holds *"nothing about a
  person"*. That is the property this plan depends on.
- **The count check exists.** `VanStockCountCheck` compares a count with the expected figure and
  words the difference (*"2 short of the 18 expected"*), or says the old figure couldn't be
  trusted.
- **A line has no lot and no expiry.** `VanStockItem` has a number, description, unit, minimum,
  standard, bin and scanned `codes`. `VanStockLevel` is one figure per line. Nothing in
  `Services/FieldAssist/VanStock/` knows a lot, a batch or an expiry date.
- **No clinical waste reasons.** Wastage would be filed as `removed · damaged` or `other`, which a
  report can't break down.
- **Scanning.**
  - `NativeTools/BarcodeScannerTool.swift` reads a still from the camera chokepoint. Its `barcode`
    filter leaves out `.dataMatrix`, and its default "any" mode detects every type.
  - Nothing parses a GS1 element string, so a code's lot and expiry are thrown away.
  - The phone-camera scanner the app already uses (`DataScannerViewController` in
    `VaultLinkViews.swift` and `OrgCodeScannerView.swift`) is set to QR only.
  - A line's `codes` are matched first, so a scanned product number already finds its line.
- **Reports.** The Stock screen exports the list as a spreadsheet. There is no report by date
  range: nothing reports doses given, waste, expiries and count differences for a day or a week.
- **The spreadsheet reader reads `.xlsx` only.** There is no CSV reader in the stock code.
- **Medical mode already shapes stock.** `van_stock`'s `send_to_base` refuses while
  `Config.hipaaMode` is on, because a handover carries dictated descriptions. The person exports it
  themselves instead.

## Design

### 1 · A lot on a line

A line stays one product, as now (*"the flu vaccine, 10-dose carton"*, its product number in
`codes`). A **lot** belongs to a line and has:

- the lot code as printed;
- the expiry date;
- when it was first received.

The level is folded **per lot** and summed for the line. A movement gains an optional `lotID`.
Older movements have none and fold into the line as today. A line with no lots behaves exactly as
an IH line does, so nothing changes for a van.

Lot codes are kept exactly as read (case and leading zeros kept). A spoken lot is matched against
the lots this line holds and never creates a new one by itself; a lot comes in on a delivery (a
scan or the screen) or on a count.

### 2 · Doses, and the carton they come in

The unit is `each`, and each is a dose. A delivery is often counted in cartons, so a line
remembers **doses per carton** once, the first time it is received. *"Two boxes in"* is then 20
doses on a 10-dose line. A multi-dose vial is one carton of N doses, and the doses left in an
opened vial that must be thrown out are wasted doses (§3).

**A tariff is a dose, not a bottle (2026-11-27).** The clinic's brief says a billed tariff "would
use 1 bottle". That holds for a single-dose vial or a prefilled syringe, where a dose and a bottle
are the same thing. For a multi-dose vial it doesn't: ten claims come from one vial, and the doses
left when it is thrown out are waste. The app keeps counting doses. A single-dose product has
`dosesPerCarton` set to its pack size, and a bottle is then one dose. Which products the fridge
holds as multi-dose vials is still open (question 4).

### 3 · Given, wasted, and the rest

A new movement kind, **`wasted`**, with its own reasons:

- expired;
- cold chain (the fridge went out of range);
- drawn up and not given;
- broken or dropped;
- opened vial discarded (doses left over);
- other.

`used` stays "given". `removed` stays for returns to the supplier and transfers. Three kinds make
three columns in a report, and a count difference makes a fourth. Staff can't hide a waste as an
ordinary removal, and a report never has to guess (Decision 3).

### 4 · Expiry, checked when the dose is given

- **Given from an expired lot:** not recorded as given. The answer offers to record it as
  `wasted · expired` instead: *"Lot ABC123 expired on 3 November. I haven't recorded it as given.
  Shall I record it as expired?"* (Decision 4).
- **Given from a lot while an older one is in the fridge:** recorded. The read-back adds the older
  lot and its date, once a day per line, so the fridge is used oldest first.
- **Expiring soon:** a list of lots expiring within the clinic's chosen number of days (30 by
  default), on the Stock screen and in every report.
- **A GS1 day of `00`:** the expiry is the last day of that month.

### 5 · Scanning a carton

Most vaccine cartons carry a 2D GS1 code (Data Matrix) holding the product number (AI `01`, a
GTIN-14), the expiry (AI `17`, YYMMDD) and the lot (AI `10`). Some also carry a serial number (AI
`21`).

- **`GS1ElementString` (pure).** It parses the code's text: the FNC1/GS separators, fixed-length and
  variable-length fields, and the GTIN check digit. It refuses rather than guesses on a bad check
  digit, an impossible date or a truncated field. The test fixtures are invented GTINs with valid
  check digits.
- **The scan sheet on the Stock screen.** It uses the phone-camera scanner already in the app, set
  to `.dataMatrix` and GS1-128. A scan resolves to line + lot + expiry, then asks *Given · Wasted ·
  Received · Count*.
  - Given is the default.
  - A product number not on the list starts a new line: its name, and doses per carton.
  - A new lot on a known line is added on Received or Count, never on Given (§1).
- **No double counts by accident.** The same code scanned again within 10 seconds asks *"Another
  one?"* rather than recording it twice.
- **Voice still works.** *"One flu dose given."* When the line has one lot in stock, that lot is
  used. When it has more than one, the app asks which, oldest expiry first. A spoken lot is matched
  only against the line's own lots (§1).

### 6 · The weekly count

A count goes lot by lot, oldest expiry first, on screen or by voice. Each count is a `counted`
movement on the lot. It reuses `VanStockCountCheck` per lot, and the differences go into the
week's report. An empty lot that is still listed is counted at zero and stays listed until the
clinic hides it. A reminder on the clinic's chosen day is a local notification (Decision 11).

### 7 · Reports

A pure **`StockPeriodReport`** for any range, with today and this week one tap away. It lists:

- doses given;
- doses wasted, by reason;
- received;
- on hand, by line and lot with expiry;
- lots expiring soon;
- count differences;
- the latest check against the EMR, if one was run (§8).

It appears on screen and as a spreadsheet through the share sheet, and its spoken summary is one
sentence. Nothing is sent by itself; under medical mode the person exports it, as with the
handover today.

### 8 · The check against the EMR

The clinic exports its immunisation list for a date range from the EMR, as a spreadsheet or CSV.
The app reads it and forgets it:

- **Read only three columns:** date given, vaccine (or product code) and lot. The column mapping is
  chosen once and remembered; it holds column names, never values.
- **Every other column is dropped as the file is read.** The patient's name and number never reach
  a model, a log, the support report or the disk. The file itself is not copied into the app
  (`ImmunisationListReader`, pure over the reader's rows). A CSV reader is added beside
  `XLSXReader` if the EMR exports only CSV.
- **The EMR's vaccine names are mapped to lines once.** The mapping is kept as the line's aliases
  in `codes` (an EMR product code) or as a named alias.
- **The clinic's own list sets most of that mapping up front (P3b, 2026-11-25).** The clinic sent
  the province's publicly funded list: abbreviation, description, tariff code and brand names, with
  no quantities. `VanStockSheet` reads a sheet that names a code and a description as a catalogue
  (lines with no figures; the first count sets the levels). `Tariff`, `Tariff code`, `Billing code`
  and `Code` headings are the line's number, so the check lines up with the code a dose is claimed
  under. `Abbreviation` and `Brand names` columns (a note in brackets after a heading is ignored) are
  split at commas and semicolons, with trademark signs dropped, and kept as the line's `codes`: at
  most 12 a row, 60 characters each, only ever added on a later import. `ImmunisationLineAliases`
  matches a line's number as well as its codes, so an EMR column holding the tariff code, the short
  form or a brand finds the line with no mapping step. Where one tariff code covers brands with
  different carton sizes, the clinic splits that row into one line per brand (`dosesPerCarton` is
  per line).
- **The clinic's own table (P3c, 2026-11-27).** The clinic's brief names six fields: Immunization #
  (5 letters and digits), Category (40), Description (75), Tariff (4 digits), Brand Names (50) and
  Quantity on Hand (4 digits). The widths are its database design, not limits the app enforces.
  `Quantity on Hand` (and `Qty on hand`, `Stock on hand`) now reads as on hand, so a row's figure
  is its count; before, only the bare words *quantity* and *on hand* did. A `Category` heading (or `Group`, `Vaccine category`) is kept on the line as
  `VanStockItem.category`: shown under the line's name on the Stock screen and editable on the
  line, but read in only, as the other names are. An empty cell on a later import leaves the line's
  own, a changed one is an edit an undo takes back, and a cell over 60 characters is not a category.
  An `Immunization #` heading (also `No.`, `Number`, `Code`, `ID`, and the same for `Vaccine`) joins
  the line's codes ahead of its brands, so the EMR check also finds a line by it. A bare
  `Immunization` heading is not one, as it may hold the vaccine's name.
- **Compare per day × line × lot (`ImmunisationReconciliation`, pure):**
  - **Given here, not in the EMR:** *"3 flu doses on 24 November, lot ABC123, are not in the
    EMR."* These are the likely missed claims.
  - **In the EMR, not given here:** a stock entry missed, so the stock figure is high.
  - **Same day, different lot:** listed on its own. It is usually a typo in one record.
  - **A record one day either side:** shown as "nearby", not as missing, because an entry made
    after midnight is common.
- **What it gives back:** a list for staff to work through in the EMR. The app says which counts
  differ, never which patient. Finding the patient is done in the EMR, by the people allowed to.

### 8a · What the clinic asked for: stock lowered by billing

The brief has the app interface with the EMR so that billing a tariff lowers the stock: tariff 8161
billed is one COVID-19 Moderna dose gone. That is not built, for two reasons.

- **It needs an EMR connector**, which needs the EMR's name, its vendor's documentation and its
  permission (Decision 9). The EMR is still unknown (question 1).
- **It hides the missed claims, the clinic's own third problem.** When billing drives the stock, a
  dose nobody billed never leaves the stock either. The weekly count then comes out over, with no
  day and no lot to start from. When staff record the dose in the app as they give it, the check
  against the EMR (§8) names the day, the vaccine and the lot of each dose that was given and
  never claimed.

A smaller step needs no connector: the check reads the EMR's **billing export** (date and tariff
per claim) in place of its immunisation list. `ImmunisationLineAliases` already matches the tariff,
because it is the line's number. A billing export carries no lot, so the comparison would be by day
and line only, and `ImmunisationListReader` today requires a lot column. Decision 13.

### 8b · One fridge, several staff (2026-11-27)

Several staff take vaccines from the same fridge, so a list kept on each phone, as a technician
keeps a van's, does not work: the count must be one shared record, and the check against the EMR
needs that same record. Staff record what they take ("gave 2 flu doses"), never a new total, so
entries from two people at once or from a phone that was offline add up without conflict; only a
count states a total, and it is ordered by when it was taken.

Where that shared record lives:

- **Not on a server of ours.** A central record we host holds clinic data, even with no patient
  names: a dose's time and who gave it can be matched to an EMR appointment. That could bring
  data residency and health-privacy obligations and a host other than the portal's current one,
  at a cost out of proportion to a pilot.
- **Not on one shared device at the fridge.** It needs no sync, but it doesn't fit how the
  clinic works.
- **In the clinic's own software, preferred.** If the EMR holds inventory, the phone keeps no count
  for that place and works through it on MM's pattern (Decision 9): it answers from the EMR's
  figure and sends doses given and wasted back through the offline queue, once each. The data
  stays in a system the clinic already controls. That needs the EMR's name, an API that can write
  stock, and the vendor's permission.
- **Else the clinic's own shared spreadsheet,** if its stock is tracked in one on Microsoft 365 or
  Google today: each dose is a row added to it, and the totals are read back. A new connector, no
  vendor agreement beyond the clinic's own sign-in. Not built.

Which of the last two depends on open questions 1 and 10. Separate places within a company
(clinics, buildings, fridges) follow MK's places once the record is chosen.

*2026-11-27:* research on Canadian health-privacy law found stock with no patient linked is not
personal health information in any province. Its caveat is that a dose's time and the staff member
on it, a rare product or a patient-linked tariff can tip a record over. Plan
[NJ](NJ-canada-inventory-only-clinic-stock.md) makes what leaves the phone inventory-only by
construction (per day, line and lot; no staff, time or free text). Plan
[NK](NK-clinic-stock-in-the-clinics-own-workbook.md) puts the shared count in the clinic's own
Microsoft 365 workbook, which a tenant provisioned in Canada keeps in Canada. Plan
[NL](NL-canada-patient-linked-clinical-data.md) is parked, in case patient linkage is ever wanted.
The spreadsheet sketch above ("each dose is a row") becomes one row per day, line and lot.

This check runs only while medical mode is on, because the file in the person's hand carries
patient data even though the app keeps none of it (Decision 8).

### 9 · Wording

A list marked as clinical says *given*, *doses*, *wasted*, *the fridge* (or the list's own name)
and *lot*, through `StockPlaceWording`, in place of *used*, *parts* and *the van*. It is set by an
organisation profile key, `organizationStockClinical` (locked), or on the list. No plan letters,
vendor names or "beta" wording in the copy. The copy says plainly that this is a stock record, not
the patient's immunisation record.

### 10 · Privacy

- **No patient identity, anywhere in this plan.** `van_stock` takes no patient argument.
  Movements carry no free text. The read-back never repeats a name the person said.
- **The spoken sentence still goes to the model** (*"gave Mrs Smith her flu shot"*). Under medical
  mode a local model is preferred and memory sync is off. Scanning needs no model at all. The pilot
  setup tells staff to say the vaccine, not the patient.
- **The EMR file** is read once in memory, under medical mode, three columns only (§8).
- **The stock store stays `SensitiveStore .vanStock`.** It holds no PHI, but it is a clinic's
  operational record, so its protection is unchanged.
- **No glasses camera in consult rooms for the pilot** (Decision 10). The Meta Acceptable Use Policy
  forbids covert capture of anyone, and a patient's consent to a camera in the room is the clinic's
  to manage, not ours to assume.

## Phases

The house rhythm puts P0–P3 in one PR, with the device-only edges named as owed.

- **P0 — lots, waste and expiry (headless).** ✅ Built 2026-11-22.
  - `StockLot` and the optional `lotID` on `VanStockMovement`, decoding older logs unchanged.
  - The fold per lot, and the line total.
  - The `wasted` kind and `WasteReason`.
  - Doses per carton on the line.
  - The expiry rules (expired, expiring within N days, oldest first, day `00`).
  - `GS1ElementString`.
  - `VanStockCountCheck` per lot.
  - Every existing IH, MK, ML and MM test stays green, which shows nothing changed for a van.
  - About 40 tests.
- **P1 — scan and speak (headless + simulator).** ✅ Built 2026-11-22, headless. Owed: the
  simulator check of the scan sheet, and the device pass with a real carton.
  - The Stock screen's scan sheet (Data Matrix and GS1-128) and the Given / Wasted / Received /
    Count choice.
  - The new-line and new-lot flows, and the 10-second repeat guard.
  - `van_stock` actions for give, waste, receive and count with an optional lot, and the
    which-lot question.
  - The expired refusal and the oldest-first line.
  - The clinical wording and its profile key.
  - `BarcodeScannerTool`'s `barcode` filter gains `.dataMatrix` and returns a parsed GS1 code when
    it reads one.
- **P2 — the count and the reports (headless + simulator).** ✅ Built 2026-11-22, headless.
  The count is a sheet on the Stock screen (every lot, oldest expiry first within its line; one
  entry, so one Undo takes it back; an empty lot is hidden by a swipe). The report is a sheet
  (Today, This week, or dates) shared as a spreadsheet, and `van_stock`'s `report` action speaks
  its one sentence. The reminder is one repeating local notification that names nothing. Owed:
  the simulator check of the three sheets, the reminder seen on a device, and opening the count
  from the reminder.
  - The lot-by-lot count flow.
  - `StockPeriodReport`, on screen, as a spreadsheet and as a spoken summary.
  - The weekly reminder.
- **P3 — the check against the EMR (headless).** ✅ Built 2026-11-22. A sheet on the Stock
  screen picks the file in place (never copied), maps the columns once and lists the findings; a
  vaccine the EMR names is matched to a line once and kept in the line's codes. Only the counts of
  the last check are kept, for the report. Owed: a run against the clinic's real export (P5).
  - `ImmunisationListReader` with its column mapping, the drop of every other column at read time,
    and a CSV reader if needed.
  - The line aliases.
  - `ImmunisationReconciliation`.
  - The medical-mode gate.
  - A guard test that the reader's output type has no field for anything but date, vaccine and lot.
  - Fixtures are invented rows with invented names in the dropped columns, and the test asserts
    those names appear nowhere in the output.
- **P3b — the clinic's own list (headless).** ✅ Built 2026-11-25, after the clinic sent its
  vaccine list (§8): catalogue import with no quantities, tariff headings as the number, short forms
  and brand names as codes, the EMR check matching the number. One reworded refusal (*"A list with no
  quantities yet needs both Part number and Description."*) joins P4's keys. Owed: importing the
  clinic's real list on a phone (P5).
- **P3c — the clinic's own table (headless).** ✅ Built 2026-11-27, after the clinic's brief:
  `VanStockItem.category` (stored, logged as an edit, undone with its batch, read by an older line
  as none), the `Category` and `Immunization #` headings on import, and the category on the Stock
  screen's row and the line's details. Owed: the *Category* key in a catalog sync; a sheet export
  does not write the category (read in only, like the other names).
- **P4 — the catalog sync (its own PR).** ✅ Done 2026-11-27: 118 keys from the clinic screens,
  harvested from a build's `.stringsdata`, translated into the 13 complete languages, add-only
  (+9,731/−0), the stock-system keys in the same files left for their own sync.
- **P5 — the pilot (owed, a report).** Owed. A real delivery received by scanning, a week of doses given
  and wasted, a weekly count, and two checks against the clinic's own EMR export. Read every spoken
  answer for a stray "van", "part" or "used". Count how many missing EMR entries the check found,
  and whether staff found them correct.

## Tests

- **Older logs.** An IH log with no lots folds exactly as before (golden file).
- **Lots.**
  - Two lots on a line: a dose given from each folds to the right lot and the right total.
  - A reversal of a given dose restores that lot.
  - A spoken lot not held by the line is refused, and no lot is created.
- **Waste and expiry.**
  - `wasted` subtracts, is reported apart from given, and each reason is counted.
  - An expired lot on Given is refused, and the offer creates `wasted · expired`.
  - An expiry with day `00` is the month's last day.
- **GS1.**
  - Fixed and variable fields, with and without a GS separator.
  - A bad check digit, a 13th month and a truncated lot are each refused.
  - AI order doesn't matter.
- **Counts and reports.**
  - A count per lot gives matches / short / over.
  - `StockPeriodReport` for a fixed log and range is a golden value.
- **The EMR check.**
  - The mapped columns only.
  - A patient-name column's values never appear in any output, log line or error text.
  - Day, nearby-day and wrong-lot cases.
  - Refused with medical mode off.
- **Wording.** No "van", "part" or "used" in any clinical sentence; the stock wording tests run per
  place, as MK's do.
- **Guards.**
  - `van_stock`'s schema has no patient-like parameter.
  - `check-privacy-logging.sh` passes.

## Decisions for Greig

1. **Patient identity.** *Recommend:* none in the app. The check against the EMR is by vaccine, lot
   and day (§8). *Alternative:* an opaque encounter or appointment number from the EMR on each dose,
   which matches dose by dose but puts an EMR identifier in the log and needs staff to read it out
   or scan it.
2. **Lots.** *Recommend:* a lot belongs to a line (§1). *Alternative:* a line per lot, which needs
   no new model but makes every list and report repeat the product once per lot.
3. **Waste.** *Recommend:* a new `wasted` kind with clinical reasons (§3). *Alternative:* more
   `RemovalReason` cases, which is a smaller change but lets a report mix returns with waste.
4. **An expired lot given.** *Recommend:* not recorded as given, with the offer to record it as
   expired. *Alternative:* recorded with a warning. That keeps the stock right but hides a clinical
   event inside an ordinary entry.
5. **Doses.** *Recommend:* `each` is a dose, with doses per carton kept on the line (§2).
6. **Funded and private stock.** Many clinics keep government-funded and privately bought stock of
   the same vaccine apart. *Recommend:* two lines that share a product code, and a scan asks once
   which, when both hold that lot. *Alternative:* leave this out until the clinic says it matters.
7. **The place.** *Recommend:* MK's neutral `stock` kind with the clinic's own name for the list
   ("Vaccine fridge"), with no new place kind. *Alternative:* a `fridge` kind, which earns its keep
   only if a clinic has several fridges and wants them told apart by kind.
8. **The EMR check's gate.** *Recommend:* allowed only while medical mode is on, three columns read,
   the file never copied (§8). *Alternative:* allowed in any mode, since nothing is kept. Weaker,
   because the model and logs are less constrained outside medical mode.
9. **When the EMR already counts the stock.** *Recommend:* MM's pattern. The phone keeps no count
   for that place, answers from the EMR and sends doses given and wasted back. That is an EMR
   connector, a later plan, and only with the EMR vendor's documentation and permission. P0–P3 here
   are for an EMR without a stock module, or one the clinic doesn't use. *2026-11-27:* the clinic's
   brief asks for the EMR's billing to lower the stock. That is this connector, not built (§8a).
10. **Phone or glasses.** *Recommend:* the phone (and a shared iPad at the fridge, if they have
    one) for the pilot. The glasses stay out of consult rooms. *Later:* scanning a carton by
    looking at it, from a pair worn at the fridge only.
11. **The weekly count reminder.** *Recommend:* a local notification on the day and time the clinic
    chooses, off until chosen. *Alternative:* none, with the report only showing the last count's
    date.
12. **Clinical wording.** *Recommend:* a list-level clinical flag with a locked profile key
    `organizationStockClinical` (§9). *Alternative:* follow the place kind alone, which can't tell
    a clinic's storeroom from a shop's.
13. **Stock lowered by billing (2026-11-27, §8a).** *Recommend:* staff record each dose in the app
    as now, and the check also accepts the EMR's billing export (date and tariff, the lot column
    optional), comparing by day and line where there is no lot. *Alternative:* the billing export
    is where doses come from: its claims lower the stock, the oldest lot first, and only the weekly
    count catches what was given and never billed, as a total. That suits a clinic whose staff
    won't record doses twice, but it gives up naming the missed claim, and the lot is a guess.
    *Later:* a live EMR connector (Decision 9).

## Open questions (for the clinic, the week of 2026-11-23)

*2026-11-27, from the clinic's brief:* the field list and the tariff-to-stock rule are answered
(§8, §8a). New: is a billed tariff one dose or one bottle, product by product (§2)? Is the
Immunization # the short form (MMR, Tdap) or a number of the clinic's own? Do privately paid
vaccines have a billing code in the EMR? Can the EMR export billed tariffs for a date range?

1. Which EMR, which version, cloud or installed? Does it have a vaccine stock module, and does the
   clinic use it? (Decision 9.)
2. Can it export the immunisations given for a date range, and in what format? A sample with the
   patient columns emptied would settle §8's mapping.
3. Who gives the doses, and who records them? Where in the day does an entry get missed?
4. Which vaccines, carton sizes and multi-dose vials? Is funded stock kept apart from private
   stock? (Decision 6.) *Partly answered 2026-11-24: the clinic sent the province's publicly funded
   list (39 rows, one suspended). Still owed: which of them the fridge holds, and the carton size of
   each brand where one tariff code covers several.*
5. Photos of a few cartons' labels, to confirm the 2D code is there and what it holds.
6. How are doses claimed, and which waste or cold-chain events must be reported, to whom?
7. A copy of the current spreadsheet with patient details removed, to import as the opening stock.
8. What devices are at the fridge and in the treatment rooms? Who at the clinic approves a new app
   handling clinic data?
9. How many days ahead counts as "expiring soon" for them?
10. *2026-11-27:* several staff share one fridge (§8b). Does the EMR store inventory? How is stock
    monitored today, and if in a spreadsheet, where does it live (Microsoft 365, Google, a file on
    one PC)?

## Not in scope

- Any patient data: names, numbers, dates of birth, or a link from a dose to a person.
- Writing to the EMR, the national immunisation register or a funder's claim system.
- An EMR connector: appointments due against stock and expiry, or the EMR's own stock. That is a
  later plan through MM's seam, once the EMR is known and its vendor's documentation and
  permission are in hand.
- Ordering vaccines from a supplier or a funder.
- Fridge temperature logging and cold-chain alarms. A cold-chain *event* is recorded only as
  waste.
- Clinical advice: schedules, eligibility, contraindications or doses per patient.

## Risks

- **A second patient log by the back door.** Defended by construction: no patient parameter, no
  free text on movements, three columns from the EMR file, and the guard tests above.
- **A missed claim reported wrongly.** A late EMR entry looks missing on the day. The nearby-day
  bucket and wording that says *"not in the EMR on that day"* keep it a prompt to check, not a
  verdict.
- **A misread code.** GS1's check digit and date checks, the read-back of vaccine, lot and expiry,
  and the 10-second repeat guard.
- **Being taken for the immunisation record.** The copy says it is the fridge's record, the export
  is titled as stock, and the app never claims a patient was vaccinated.
- **Licensed EMR manuals in a vault** (the other ask). They stay in the clinic's private company
  vault, never in a published vault or the repository.

UI copy never names plan letters. The person-facing words are "stock", "dose", "lot", "given",
"wasted", the list's own name and "the EMR" (or its own name, once the clinic tells us).

## The other ask: an EMR help vault (no build)

The clinic also wants staff to ask *"How do I do this in the EMR?"* and *"Where is this screen?"*
and be answered from the vendor's manuals, its web FAQs and the clinic's own instructions. That is
a company vault, and it needs setup, not a build:

- **Company vault from the portal** (Plan [LR](LR-company-vaults-from-the-portal.md)) or built on
  the phone (Plan [LW](LW-vault-authoring.md)), with the vendor's user manuals as PDFs.
- **Web FAQs** are saved as PDFs today. The app has no import from a web address.
- **The clinic's own instructions** become guides (Plan [MJ](MJ-personal-guides.md)) or procedures
  (Plan [MS](MS-editing-a-procedure-on-the-phone.md)).
- **Software manuals are mostly screenshots,** so answers that show the figure matter (Plan
  [MU](MU-the-lens-read-at-work.md) on the lens, and the phone's page view).
- **Licensed material.** The vendor's manuals are licensed to the clinic. They live only in the
  clinic's private company vault, never in a published vault (Plan
  [LV](LV-published-vaults.md)) without the vendor's permission, and never in the repository or a
  test fixture.
- **No camera on the EMR screen.** The screen shows patient records, and the privacy filter blurs
  faces, not text. Questions are asked in words.

If the pilot shows a gap here (a screen-name vocabulary, or answers that point at a menu path), it
gets its own plan then.
