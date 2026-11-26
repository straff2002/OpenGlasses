# Plan IH — Van Stock (what is on the technician's own truck, kept by voice)

**Status:** 🚧 Every phase has its core built, 2026-10-14: the ledger, the store, the `van_stock`
tool, the Van Stock screen, the spreadsheet out and back, the question at the close of a job, and
the shift handover. Three things in the design are not built — P4's Job-tab to-do and day-view
line, and P5's delivery by the organisation's report channel (the handover is sent through the
share sheet) — and every device and hand check is owed. Nothing here has run on a phone. A
technician tells the assistant what
they loaded at the shop and what they used on a job; the phone keeps the count, answers "have I
got one?" with no signal, says when the last one has gone, and offers to ask the office for a
replacement. The count lives on the phone and nowhere else. A spreadsheet goes out and comes back
in for bulk loading and hand corrections. At the end of a shift the levels and a top-up list go
to base, and the next technician to take the vehicle picks the list up on their own phone.
Company-wide stock is not in this plan.
**Note (2026-11-19, a tester's build-728 report):** a line's brand was heard as the everyday word
it sounds like and a number in its size heard in two pieces, so `check` matched nothing and said "none on the van" over
22 packs. `VanStockMatcher` now tries a number broken at a space rejoined (an exact match), and,
when nothing matches word for word, returns `.near` for lines that match every said word but one,
at least two of them, the odd one sounding like an unsaid word of the line (a small phonetic key or
one to two letters' edit; never a number). `check` gives the near line's figure to be confirmed;
every write changes nothing and asks, and `load`/`count` start a new line only with `new_line`.
**Note (2026-11-26, owner's ask):** a line can be deleted from its page ("Delete this line", with a
confirmation). An import of corrections still never deletes; only a takeover replaces the list.
`VanStockLog.deleteItem` takes the line and its lots off the list as its own batch, noted as an
`edited` movement that changes nothing, so an older build reads the file as a list without the
line. The line is kept in `deleted_lines` until the next deletion, and Undo puts it back where it
stood while the deletion is still the last entry. The line's movements stay as history, which
the fold already passes over, and the exported History sheet still names it. Not offered while
a business's own system holds the count; on a clinic's list, a line with a dose given or wasted
is not deleted, so the stock report keeps it (owner confirmed 2026-11-27). Not by voice:
`van_stock` has no delete. Built in PR 1243; its six screen strings were translated into the 13
complete languages on 2026-11-27.
**Track:** Field Assist (B2B).
**Depends on:** Plan [EM](EM-work-record-and-parts.md) P1 (shipped: `PartsVerifier`,
`VaultPartsIndex`, `parts_request`, the work record). Nothing here waits on the office connection.
**See also (2026-11-19):** Plan [MM](MM-stock-in-the-business-system.md): where the business keeps
stock in its own system, that system answers and this ledger stops counting that place.
**Related:** Plan [HF](HF-office-stock-and-capture-contracts.md) (the firm's stock in Avenkin
Office; this plan is the van end of it, built so HF can take it over), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (the Job tab and its to-dos), Plan
[GE](GE-automatic-offline-handoff.md) (offline tool classification), Plan
[CT](CT-org-configuration-profiles.md) (an organisation can pin the feature off), Plan
[IA](IA-agent-choice-questions.md) (answering "which one?" from the glasses), Plan
[BT](BT-reading-companion.md) (the read-only ZIP reader this plan reuses).
**Origin:** A partner's field experience, 2026-10-13: a technician uses a part, forgets to record
it, and arrives at the next job without one. The ask was the smallest thing that fixes that — the
technician's own truck, by voice, in a file they can open and correct — tested alone before
anything company-wide.

---

## Decisions proposed (owner to confirm)

1. **The store is a movement log; the spreadsheet is a view of it.** The phone keeps an
   append-only list of movements and derives every level from it. The spreadsheet is exported
   from the log and an edited one comes back as corrections. A file that is the store cannot be
   undone, cannot say when a figure was last true, and is corrupted by being open in another app
   while the phone writes it.
2. **A real `.xlsx`, never CSV.** A spreadsheet program opening a CSV drops leading zeros and
   turns a number such as `14E65` into scientific notation. Part numbers are written as text
   cells in a text-formatted column.
3. **Stock is not tied to a job.** Loading happens at the shop with no job open. The tool needs
   Field Assist switched on and nothing else; a use is tagged to the open job when there is one.
4. **Most van stock is in no manual.** Capacitors, contactors, fuses and fittings are universal.
   The vault check (`PartsVerifier`) still runs and its result is recorded, but an unverified
   number is never refused, and an item may have a description and no number at all.
5. **Write, read back, and let the technician undo.** A load or a use is recorded at once and
   read back in the same breath. "Undo that" reverses the whole spoken batch. A confirm-before-
   write step would double every turn while somebody's hands are full of boxes.
6. **Ordered and on the van are different facts.** Asking the office for a replacement opens an
   order; only the technician saying they loaded it adds stock. Until then the answer is "none on
   the van, one asked for on Tuesday".
7. **Nothing is ordered unattended.** A low count is spoken and a request is offered. The
   technician says yes. Anything that would act without them is gated behind `agentModeEnabled`
   and is out of this plan.
8. **One van on a phone at a time, and a van can change hands.** The log belongs to the van,
   not to the technician: it has a name and an identifier, it is sent to base at the end of a
   shift, and the next technician takes it over on their phone. Two phones working the same van
   in the same shift, and stock moving between vans, belong to HF.
9. **A handover is sent by a person.** It is staged and shown, like a job report, and leaves by
   the organisation's own channel when the technician sends it.

### Decided by the owner, 2026-10-14

- **The standard load starts as base's baseline and grows per truck.** Base holds one baseline.
  Each vehicle adds to it over time, and a later baseline from base must not undo what a truck
  has added (§6, §8).
- **The technician tops up, at the start of the shift, before leaving base.** Nobody restocks the
  vehicle overnight. With the day's jobs in mind the technician also loads parts beyond the
  standard load, and may return what was not used at the end of the shift (§8).
- **One phone per technician.** The phone goes home with its owner and the vehicle stays, so the
  takeover in §8 is needed and stays in P5.

## Product promise

- *"Check my truck for a 45/5 capacitor."* — *"Two on the van, counted on Monday."*
- *"Record that I used one, and ask the office for a replacement."* — *"One left. I've asked the
  office for one; it goes with the job report."*
- At the shop: *"I've loaded four flame sensors, part 62-23543-01, and six 45/5 capacitors."* —
  the assistant reads both lines back, and spells out any number it has not met before.
- At the end of a job: *"The igniter on this job has no stock entry. Did it come off the van?"*
- At the start of a shift: the technician opens what the last shift sent and hears *"You've
  taken over Truck 4, as it was left at ten past five. Nine lines are short; two need
  counting."* They fill the shelves and say *"Topped up everything except the flame sensors, and
  I've put an inducer motor on for the Hill Street job."*
- At the end of the shift: *"Send the truck stock to base."* — *"The inducer motor wasn't used.
  Are you returning it or keeping it on the truck?"* — then *"Truck 4: four lines to top up.
  Ready to send to the office."*
- An unknown is spoken as unknown. A count the log cannot stand behind is said to be unreliable
  until somebody counts; an invented figure is never spoken.
- It all works in a basement. Nothing in this plan touches the network.

## Verified starting point (`9a613d51`, 2026-10-13)

- **Part numbers are already checked.** `Services/FieldAssist/PartsVerifier.swift` turns a spoken
  number into a `TaskPart` (`number`, `partDescription`, `verified`, `page`): the vault's parts
  table first (`VaultPartsIndex.part(number:)`, which also resolves a superseded number to its
  replacement), then the manuals as an exact token. `VaultPartsIndex.normalise` strips the
  punctuation a transcribed number picks up.
- **Requests to base exist.** `NativeTools/PartsRequestTool.swift` (`parts_request`) records a
  `PartsRequest` (`quantity`, `urgency`, `onVan`, `status` `requested`/`sent`/`answered`,
  `baseAnswer`) on the active session. It refuses without one. `on_van` already means "the
  technician has one and this is a replacement for stock". The request leaves with the job report
  by the organisation's channel (`DeliverySettings`: email, messages, WhatsApp, Telegram or an
  endpoint) or through the office connection.
- **Things already leave by a person's hand.** `DeliveryRequest.Payload` has two kinds, a job
  report and a team-learning bundle; `deliver_report` only stages one and the composer sends it.
  `DeliveryChannel` is email, messages, WhatsApp, Telegram, the share sheet, or an unattended
  endpoint. The signed office report contract (`Contracts/office-reports.md`) carries three record
  kinds — `workRecord`, `partsRequest`, `addendum` — and no other.
- **"Used" has no quantity.** `WorkRecord.partsUsed` is the parts on tasks that ended `done`,
  de-duplicated by number. `TaskPart` carries no quantity, and a part on a task did not
  necessarily come off the van. `propose_task` is what attaches parts to a task.
- **Codes can be scanned.** `BarcodeScannerTool` (`scan_code`) decodes QR and the common retail
  and industrial symbologies on device from a filtered still, and returns the text.
- **Archives can be read, not written.** `ZipArchiveReader` (`Services/Reading/
  BookFileExtractor.swift`) is a strict read-only ZIP parser with stored and deflate decoding,
  already reused by `OfficeManualImport`. There is no ZIP writer and no spreadsheet code. No
  package would need adding: `XMLParser` and the system zlib cover the rest.
- **The app's files are not in Files.** `Info.plist` declares three document types the app
  receives as a copy (`LSSupportsOpeningDocumentsInPlace` is `NO`); `UIFileSharingEnabled` is
  not set. `ShareSheet` and file importers are used across the app.
- **Enforced registers a new tool and a new store must join.** `OfflineToolPolicy` (every tool
  is `local`, `degraded` or `needsNetwork`), `ToolEffectClassification` (checked against the live
  registry by `ToolEffectClassificationTests`), and `SensitiveStore` in `DataStoreRegistry`
  (checked by a source scrape in `DataStoreRegistryTests`).
- **The Job tab has to-dos.** `JobDay.Todo.Kind` lists `debrief`, the report states, `signOff`,
  `parts`, and the recording kinds; `JobNeedsSection` shows them.
- **HF is drafted and unbuilt.** Its stock snapshot already has a location class `van` and a flag
  for the phone's own van, movement kinds as a closed list, and provenance on every figure.

## Design

### 1 · Items and movements

An **item** is one line of stock: a stable `itemID`, an optional part `number` (normalised with
`VaultPartsIndex.normalise`), a `description`, a `unit`, an optional `minimum` (warn at or below
this), an optional `standard` (what the van should carry; top-ups fill to it) with who set it, `base`
or `van`, an optional `bin`
(a short label such as "left shelf 2"), zero or more scanned `codes`, and whether the number was
`verified` against the vault when it was last checked. The identifier is separate from the part
number, as HF requires, because a number can be corrected and an item can have none.

A **van** is a name ("Truck 4") and an identifier, set once and carried in every export, so a
list can be told apart from another vehicle's and followed from one phone to the next.

A **movement** is one dated fact about one item. The kinds are a closed list:

| Kind | Effect on the level | Carries |
|---|---|---|
| `loaded` | + quantity | the job it was loaded for, when the technician names one |
| `used` | − quantity | the job session and job reference, when a job is open |
| `removed` | − quantity | a reason from a closed list: `returned`, `damaged`, `lent`, `other` |
| `counted` | sets the level | — |
| `ordered` | none | the `PartsRequest` id, when this phone made the request; closed by later loads, oldest first |
| `edited` | none | which attribute changed (number, description, unit, minimum, standard, bin) |
| `reversed` | undoes one earlier movement | that movement's id |
| `opening` | sets the level | what a folded history left: the figure, whether it was counted, whether it was unreliable |

Every movement has an id, a time, a `batch` id (one spoken sentence or one imported sheet is one
batch), and a `source`: `spoken`, `typed`, `scanned`, `sheet` or `handover`. Movements carry no free text, so
the log holds part data and job references and nothing about a person.

**Levels are a fold.** `VanStockLedger` (pure) reduces the movements to, per item: `onHand`,
`onOrder`, `provenance` — `counted` when nothing has moved since the last count, `inferred`
otherwise — and `asOf`, the time of the last movement that changed the level. These are HF's
words for the same things.

**A use the log cannot cover.** The technician is holding the part, so the use is always
recorded. If the log said none, the level stays at zero, the item is marked **unreliable**, and
every answer about it says so until a count clears it: *"I've recorded it. The log said you had
none, so I can't tell you how many are left — count them when you can."*

**Units.** A closed list, whole quantities only: `each`, `m`, `ft`, `kg`, `lb`, `l`, `pack`.
Refrigerant weighed to a fraction is out of scope (Open question 1).

### 2 · Finding the item somebody means

`VanStockMatcher` (pure) takes what was said and the current items and returns one item, several
candidates, or none. In order:

1. a scanned code already attached to an item;
2. the normalised part number, exactly;
3. the vault's supersession, both ways, so the number printed on the old component finds the
   stock of its replacement;
4. description tokens — "45/5 capacitor" against "Capacitor, dual run, 45/5 µF 440 V".

Several candidates go back to the model as a short list to ask about; it never picks one. **Only
a load or a count may create an item.** A use, a removal or a check that matches nothing says so
and changes nothing, which is what stops a misheard number quietly becoming a new line with
minus one in it.

Deducting is the easy direction: the reference only has to match one of the lines on this van.
Loading is the hard one, because any number can be said. So a number that is neither verified
against the vault nor already on the van is read back character by character
(`SpokenPartNumber`: "six two, dash, two three five four three, dash, zero one") with the
invitation to undo.

**Scanning.** The model may call `scan_code` and pass the result as the reference with source
`scanned`. A printed barcode is usually a retail code, not the part number, so the first time a
code matches nothing the technician is asked what it is, and the code is remembered against that
item. The second box scans straight in.

### 3 · The `van_stock` tool

One native tool, registered with the other Field Assist tools when `Config.fieldAssistActive`.
It does not require an active session. Its description names both "van" and "truck".

| `action` | What it does |
|---|---|
| `check` | One item's level, on-order figure, provenance and age; or candidates; or "not on the van" |
| `low` | Items at or below their minimum, and items at zero with no minimum set |
| `top_up` | What it takes to bring the van back to its standard load: each short line and by how much |
| `load` | One or more lines of `part`/`description`, `quantity`, `unit` |
| `use` | The same shape; tagged to the active job when there is one |
| `remove` | The same shape, with a reason |
| `count` | Sets one or more levels: a stocktake. The read-back compares the count with the figure the log expected ("2 short", "1 over", "matches"), except for a line's first figure or one the log could not trust (added 2026-11-17) |
| `undo` | Reverses the most recent batch, once |
| `send_to_base` | Stages the end-of-shift handover (§8). It sends nothing by itself |

Rules, each a test:

- **Every answer about a level states how it is known**: counted or worked out, and as of when.
  An unreliable item is said to be unreliable before any figure.
- **A write returns the read-back the model must speak**: what was recorded, the level now, and
  for a use whether the item has reached its minimum or zero.
- **At zero or at minimum the result offers a request and stops.** It does not call
  `parts_request`; the model asks the technician.
- **No store, no guess.** With nothing ever loaded the tool says the van list is empty and how to
  start one. It gives the model no route to answer from memory.
- **A repeated identical write inside a few seconds is one write.** Models retry; a retry must
  not load four sensors twice.

`load` also takes `to_standard`, with optional exceptions: *"topped up everything except the
flame sensors"* brings every short line but those to its standard load in one batch. The
read-back gives the number of lines and names the exceptions, and one undo takes the batch back.

Classification: `OfflineToolPolicy` `local`; `ToolEffectClassification` `.local()`, since the
strongest action writes on-device state. The existing `parts_request` gains one seam: a request
made with `on_van` set, or made on the back of a `van_stock` offer, writes an `ordered` movement
so the van knows something is coming. A request for a part that will be fitted rather than
stocked does not.

### 4 · The store

`VanStockStore` keeps the movements and the items in the app's Application Support directory,
written atomically, with complete file protection. It joins `SensitiveStore` as `vanStock`:
business data, the technician's own working record, **left in the device backup** so a new phone
still knows what is on the truck, and outside the subject-erasure walk because it holds no
personal data — which the no-free-text rule in §1 is there to keep true.

Movements older than a retention window (proposed 400 days; Open question 5) are folded into
one opening balance per item, so levels stay exact while the history stays short.

### 5 · The Van Stock screen

Reached from the Job tab. A searchable list — description, number, on hand, on order, a mark for
low, unreliable and unverified — with a detail view per item: a number field and stepper to set
the count (a `counted` movement), the editable attributes, and the item's history. A toolbar
carries Export, Import and Undo.

This screen, not the spreadsheet, is the ordinary way to fix one wrong figure on the phone.
Every state it shows is also spoken by the tool; it passes the accessibility audit at the largest
text size, and none of it is a paid extra beyond the organisation's Field Assist licence.

An organisation may pin the feature off with one CT ceiling key. Like every ceiling it only
subtracts.

### 6 · The spreadsheet, out and back

**Why it earns its place.** A working truck already holds a couple of hundred lines. Nobody will
dictate them. The first thing a pilot needs is to load the list the shop already has, and the
second is a way to fix twenty figures at a desk.

**Out.** `VanStockSheetExport` builds a workbook with two sheets through `XLSXWriter` (pure; a
stored, uncompressed ZIP with CRC-32 from the system zlib, and the handful of XML parts a
workbook needs):

- **Van stock** — Part number, Description, Unit, On hand, Standard, Standard set by, To top
  up, Minimum, On order, Needs a count, Bin, Last changed, and a hidden Item ID column. Part number and Bin are
  text-formatted columns, so a number typed into a new row stays as typed. Standard
  set by, To top up, On order and Needs a count are worked out by the phone and ignored on the
  way back in.
- **History** — the movements, newest first. Read-only in spirit: import ignores it.

The workbook records the van's name and identifier, when it was exported and the last movement
it includes. It leaves through
the share sheet, to wherever the technician sends it.

**Back.** The app registers as a viewer for `.xlsx` and takes the file as a copy, exactly as it
takes a job file, or through a file importer on the screen. `XLSXReader` (pure, over
`ZipArchiveReader` and `XMLParser`) reads shared, inline and formula-string cells and cached
numeric values. `VanStockSheetImport` (pure) turns the sheet into a **proposal**:

- a changed On hand becomes a `counted` movement;
- a new row becomes a new item and a `counted` movement;
- changed attributes, a standard load among them, become `edited` movements;
- **a missing row changes nothing** and is listed as missing — sorting, filtering and an
  accidental delete must not zero the van; zero is typed as zero;
- a line that also moved on the phone after the export is shown with both figures, and the
  technician chooses; the sheet's figure is the default.

Nothing is applied until the technician has seen the summary ("7 counts changed, 2 new items,
1 needs a choice") and tapped once. The whole import is one batch, so one undo takes it back.

**A sheet we did not write.** A first import has no Item ID column. Columns are found by header,
from a short list of synonyms (part / part number / item; description; qty / quantity / on
hand; unit; standard / par / stock to; min / minimum; bin / location).

**Base's baseline.** The same reader takes base's baseline sheet through a third import,
**Apply base's standard load**. It touches standards and nothing else — no level changes. A line
the baseline names gets that standard, marked as set by base, and is created at zero if the van
has never carried it. A line whose standard this truck set itself is shown with both figures and
kept unless the technician chooses otherwise. A line the baseline does not name is left alone.
So base can reissue the baseline as often as it likes and a truck keeps what it has grown. A sheet with no recognisable header is refused with a
sentence naming the headers it needs.

**Refused outright:** a macro workbook, an encrypted workbook, more than 5,000 rows, a file over
2 MiB or one that inflates past 16 MiB, and — per line, with the reason — a quantity that is
negative, fractional or not a number.

### 7 · The end of the job, and the record

This is the part that fixes the complaint the plan started from.

`VanStockReconciler` (pure) compares the parts on the job's finished tasks (`partsUsed`) with the
`used` movements tagged to that job, and returns the parts that have no stock entry. They become
one Job-tab to-do, and one question when the job is being closed: *"Two parts on this job have no
stock entry: the igniter and the pressure switch. Did they come off the van?"* Yes records the
use, asking the quantity; "no, it was ordered in" or "the customer's" dismisses that part for
this job. It never deducts by itself, because a part on a task is not proof of where it came
from.

The work record gains an optional `van_stock` block: what came off the van on this job, with
quantities, units and whether each number was verified. Nil, and absent from the JSON, on a job
that used nothing — the pattern `usage` and `teamLearnings` already follow. This is the quantity
HF's mapping from the record to "issued to job" is missing today.

### 8 · The end of the shift, and the next one

A vehicle that is driven by one technician today and another tomorrow needs two things: base has
to know what state it came back in, and the next technician's phone has to know what is on it,
because that technician is the one who tops it up before driving off.

**Out, at the end of the shift.** *"Send the truck stock to base"* (`send_to_base`) does four
things in order. It runs the reconciler of §7 over the shift's jobs and asks about any part still
without a stock entry, because a handover that repeats a forgotten use passes the mistake on. It
asks about the day's extras (below). It composes the handover: the workbook of §6 and a short text of what matters — the top-up list
(each line below its standard load and by how much), what is on order, and what needs counting.
Then it stages a delivery for the technician to look at and send.

The delivery is a third `DeliveryRequest.Payload` beside the job report and the team-learning
bundle, so it goes by the channel the organisation already chose for reports, to the recipients
it already named, through the same composer and the same audit trail. It is unsigned, like the
learning bundle: a spreadsheet is meant to be edited. Where the organisation's reports go to an
unattended endpoint, the handover rides the queue as its own kind. The signed office connection
cannot carry it — its report contract knows a work record, an addendum and a parts request and
nothing else — so until HF's capture message exists a phone enrolled with an office sends the
handover by a person-operated channel or the share sheet, and says so.

**The day's extras.** A technician who has read the job list loads more than the standard load:
the part a job is expected to need, and the one it might. Nothing has to be said to mark these.
`VanStockSurplus` (pure) finds them at the end of the shift: every line loaded since the takeover
that now stands above its standard load, or has none. Each is asked about once — *returning it,
or keeping it on the truck?*

- **Returning** records a `removed` movement with the reason `returned`.
- **Keeping** leaves the level as it is, and offers to make it part of this truck's standard
  load. Saying yes sets the standard, marked as set by the van.

That offer is how a truck's standard load grows: from what a technician chose to carry and
chose to keep, one line at a time, never by inference. The handover's Standard set by column
shows base which lines a truck has added, so the baseline can follow if base wants it to.

A line with no standard load cannot be short of it. With none set anywhere, the top-up list is
the lines at zero and the lines below their minimum, and the message says the van has no
standard load to measure against.

**In, at the start of the next.** The next technician opens the workbook — forwarded by base,
or sent straight from the last shift — and the app, seeing a van identifier, offers **Take over
this van** beside the ordinary import. Taking over differs from correcting in one way that
matters: the sheet is the whole truth. Every line in it becomes a `counted` movement with source
`handover`; a line on the phone that is missing from the sheet is set to zero; lines on order
come across as orders with no request attached; lines marked as needing a count stay unreliable.
The summary is shown first, and the technician taps once.

- **A different van.** A phone that holds Truck 2 and is handed Truck 4 keeps Truck 2's log,
  archived and exportable, and switches. It never merges two vehicles.
- **A stale handover.** One older than the phone's own latest movement for the same van is named
  as older and is not the default.
- **The technician tops up and says so.** Straight after the takeover the phone reads the
  top-up list. The technician fills the shelves and reports it — line by line, or *"topped up
  everything except…"* (§3) — and adds the day's extras the same way, naming the job when there
  is one. Nothing is assumed to have been put back; a line nobody mentions stays short.
- **The phone does not predict the extras.** Which parts today's jobs might need is the
  technician's judgement. A readiness note from the office is HF's, later.

Answers after a takeover carry it: *"Two on the van, as handed over yesterday at ten past
five."* The technician's name travels in the message, where base needs it, and never in the log.

**Medical modes.** Descriptions in the workbook may have been dictated. With HIPAA mode on, the
handover is not staged and the action is not offered to the model, the rule HF sets for its
capture messages; the share sheet on the Van Stock screen remains the technician's own act.

### 9 · When the office keeps stock too

When HF is built, the office's snapshot may also carry a figure for this phone's own van. The
phone's ledger is the fresher of the two for its own van and answers for it; the snapshot answers
for base and for everybody else. The ledger's movements are already in HF's vocabulary, so a
van's history can go to the office as capture proposals without being reshaped. Neither is built
here. A firm that collects each vehicle's handover has, in a folder of spreadsheets, a first
company-wide picture with no further software; HF is what replaces the folder.

### 10 · Honest limits

- The count is only as good as what the technician says. The plan makes saying it cheap, makes a
  mistake cheap to undo, and asks at the end of the job; it cannot see the shelf.
- A spoken part number in a noisy shop is the weakest link. Read-back, the van's own list as the
  vocabulary, and the barcode are the three mitigations; how well they hold is a device check.
- The spreadsheet round trip depends on the technician's spreadsheet app saving a workbook the
  reader accepts. Which apps do, on which devices, is a check owed before the pilot.
- The spoken number reaches whichever model the conversation uses. Under the medical local-only
  mode that model is on device; nothing in this plan adds an egress of its own.
- A handover is as current as the moment it was sent. Stock used after it, or put back by
  somebody who did not say so, is not in it.
- Two phones cannot work one van at the same time. A technician who changes phones without a
  backup takes the van over from its last handover.

## Build order (one PR each)

**P0 — Ledger, matcher and sentences (pure).** ✅ **Built 2026-10-14.** `VanStockItem` and
`VanStockUnit`, `VanStockMovement`, `VanStockLog` and `VanStockLevel` (`VanStockLedger.swift`: the
fold, the changes, undo, and folding an old history), `VanStockMatcher`, `VanStockAnswerComposer`
(injected clock and calendar), `SpokenPartNumber`, under `Services/FieldAssist/VanStock/`. No
store, no tool, no UI. As built: the composer returns English, as every tool result does, because
its reader is the model and the model answers in the technician's language; the item carries
`standard` and who set it, and a movement may carry the `handover` source, so P5 needs no change
of format.
*Owed:* nothing.

**P1 — Store and `van_stock`.** ✅ **Built 2026-10-14; device checks owed.** `VanStockStore`
(one protected JSON file, left in the backup, refused when unreadable, old history folded on
load), the `vanStock` case in `SensitiveStore`, `VanStockService` (the one place a spoken line is
matched, recorded and answered), `VanStockTool`, its `OfflineToolPolicy`, `ToolEffectClassification`
and `FieldToolProfile` rows, registration, the `parts_request` seam, scanned-code aliases.
As built, beyond the design above:
- **`new_line`.** A vaguer description joins the line it fits — "capacitor" goes on the 45/5
  line — and the read-back names that line. Saying it is a different part (`new_line`) starts
  a new one, matched only by its number or its code.
- **`for_van_stock` on `parts_request`.** After the last one is used the technician no longer
  "has one on the van", so `on_van` alone could not mark a restock. Either flag writes the
  `ordered` movement; a request for a part the van has never carried says so and adds no line.
- **A part number has no spaces and at least one digit.** Words given where a number goes are
  the description.
- **Outside a job there is no vault to check a number against**, so a line loaded at the shop is
  unverified until it is next touched with a job open, when it is checked again.
*Owed (device):* ten parts loaded by voice in a noisy room, through the glasses and through the
phone; a check and a use in aeroplane mode; the same in a live session.
**The three-line voice workflow is testable with a partner after this phase**, on an empty van.

**P2 — The Van Stock screen.** ✅ **Built 2026-10-14; device checks owed.** `VanStockView` and
`VanStockItemView` (`App/Views/Job/VanStockViews.swift`), reached from a Van stock row on the Job
tab's list through two new `JobRoute` cases; `VanStockRows` (pure: the rows, their marks, the
search, a line's history); the screen's operations on `VanStockService` (a typed count, edits as
one batch, undo); and `organizationForbidsVanStock`, a ceiling pinned on, which makes the tool
refuse and hides the row. A part number corrected on the screen is looked up again, so the old
number's verification does not carry over.
*Not built:* the accessibility audit entry. The audit runs in the UI-test target on a simulator,
and none was available when this was built; it is owed with the device pass below. Import, Export
and the review sheet arrive with P3.
*Owed (device):* VoiceOver and largest text size on the list and the detail; the audit entry.

**P3 — Spreadsheet out and back.** ✅ **Built 2026-10-14; hand checks owed.** `XLSXWriter`
(stored ZIP, inline-string cells, a text-formatted part number column), `XLSXReader` (over
`ZipArchiveReader` and `XMLParser`; shared, inline and formula-string cells, cached numbers; the
size, row and macro refusals), `VanStockSheet` (the workbook out, the proposal back, and applying
it as one batch), `VanStockImportService` and `VanStockImportReviewSheet` (the review, raised by
the app whichever way the file arrived), Import and Export on the Van Stock screen, and the
workbook document type at alternate rank. As built:
- The stock sheet already carries Standard, Standard set by, To top up, On order and Needs a
  count, so P5 adds no columns.
- A line is matched by its Item ID, then its part number, then its exact description.
- The export's time, in a hidden sheet, is what marks a line as moved since the export. It is
  to the second.
- A figure that matches the phone's is not offered as a count unless the line is unreliable, so
  an export imported straight back says there is nothing to change.
- An export is a temporary file, removed when the share sheet finishes.
- In a sheet this app wrote, an emptied Minimum, Standard or Bin clears it. In anybody else's,
  an empty cell changes nothing. An empty description or part number never clears either.
*Owed (hand):* a file saved by each spreadsheet app a pilot technician actually uses, on the
phone and on a desktop, added to the fixtures; "Open in Avenkin" from Mail and from Files on a
device. Every workbook the tests read today was written by this app or built by hand in the
tests. **A real truck can be loaded after this phase.**

**P4 — Job close and the record.** 🚧 **Core built 2026-10-14; two surfaces not built.**
`VanStockUse` and `VanStockReconciler` (pure); the session's own account of what came off the van
(`vanStockUses`, `vanStockNotFromVan` on `FieldSession`, and their methods on
`FieldSessionService`); the question in `JobCloseSequence`; `van_stock` actions `unrecorded` and
`not_from_van`; and the `van_stock` block on the work record. As built:
- **The use is kept on the job as well as in the van's log**, because the two outlive each other
  differently: the log changes hands with the vehicle and the record stays the job's. The record
  is still assembled from the session alone. An undo in the van's log takes the use off the job.
- **The question is one more step of the one close sequence.** By voice a part with no stock
  entry holds the close and names both answers — record a use, or say it did not come off the
  van. The screen's close is not held for it.
- **A technician who keeps no van stock is never asked.** The close only looks when the van list
  is not empty and the organisation has not switched van stock off.
- **A part is matched by its number.** A use recorded by description alone does not account for
  a numbered part on a task, so that part is still asked about.
- The block sits in the record's JSON and its internal summary lines ("Off the van:"). It is not
  added to the customer summary.
*Not built:* the Job-tab to-do row for unrecorded parts, and the low-stock line in the day view.
Both are surfaces in the Job tab's feed, which could not be exercised without a simulator.
*Owed:* the office accepting a report whose record carries the new block; one uncoached job.

**P5 — Shift handover.** 🚧 **Core built 2026-10-14; the organisation's channel not built.**
`VanIdentity` and `VanStockHandover` (pure: the top-up list, the day's extras, what was returned,
the message, a workbook read as a van to take over, and base's baseline); the van's name and a
one-generation previous list in `VanStockStore`; `van_stock` actions `top_up`, `set_standard` and
`send_to_base`, and `load` with `to_standard`; `VanStockHandoverService` and
`VanStockHandoverSheet`; the three ways of applying a workbook in the import review; and Name this
van, Send stock to base and Previous list on the Van Stock screen. As built:
- **The handover is sent through the system share sheet, not the organisation's report channel.**
  It is staged and shown as §8 describes, with the workbook and the short text, and the
  technician chooses who it goes to. `DeliveryRequest.Payload` is unchanged, so no recipient is
  filled in, nothing rides the unattended endpoint, and it is not in the delivery audit trail.
  That is the part of Decision 9 still to build.
- **A takeover replaces the phone's list; it does not merge.** The list that was there is kept
  once, as `van-stock-previous.json`, and can be gone back to from the screen. A second takeover
  overwrites it.
- **What a takeover does not carry:** scanned-code aliases, and whether a number was verified.
  A number is looked up again the next time its line is touched with a job open.
- **The shift begins at the takeover**, or at the start of the day when there was none. That is
  what "loaded this shift" means for the day's extras and for what was returned.
- **`send_to_base` asks first, once.** A part on the open job with no stock entry, and extras
  still on board, come back as questions; the second call, with `answered`, stages. Jobs already
  closed were asked at their own close.
- **`set_standard`** is how a kept extra joins the truck's standard load, and how a technician
  sets one by voice. Zero clears it.
- **The baseline import** takes a standard from a Standard column. Only a sheet from somebody
  else that has no Standard column has its quantities read as the standard, so an export of a
  van's own stock is never mistaken for a baseline. A figure the truck already has is no change,
  whoever set it.
- **Returned extras are listed in the message** ("Returned this shift"), which answers Open
  question 9 in base's favour until somebody says otherwise.
- **Under Medical Compliance mode** `send_to_base` is refused and the screen's Send is disabled.
  The tool is still declared; only the action is refused.
*Owed (device):* one vehicle handed between two phones through a real mailbox, both ways, with a
top-up, one extra returned and one extra kept.
**Needs only P3**; the question about unrecorded parts joins it once P4 is in.

## Tests

- `VanStockLedgerTests` — every kind's effect; a reversal undoes exactly one movement and cannot
  be reversed twice; provenance flips to inferred on the first movement after a count; a use past
  zero marks the item unreliable and a count clears it; orders close oldest first; folding old
  movements leaves every level unchanged.
- `VanStockMatcherTests` — exact number; supersession both ways; code alias; description tokens;
  several candidates are returned, never chosen; only load and count create.
- `VanStockAnswerComposerTests` — the age is always present; unreliable is said before a figure;
  an unknown is never a number; on-order wording; minimum and zero wording.
- `SpokenPartNumberTests` — digits, letters, dashes and slashes.
- `VanStockStoreTests` — atomic write, protection class, survival of a relaunch, a torn file
  refused rather than half-read.
- `VanStockToolTests` — no active session is fine; Field Assist off is refused; empty van; the
  read-back; the duplicate-write guard; undo; an offer at zero that orders nothing.
- `PartsRequestToolTests` update — the `ordered` movement is written for a stock replacement and
  not for a part to be fitted.
- `OfflineToolPolicyTests`, `ToolEffectClassificationTests`, `DataStoreRegistryTests` updates.
- `XLSXWriterTests` and `XLSXReaderTests` — round trip; a part number with leading zeros and one
  shaped like an exponent survive; shared, inline and formula-string cells; each refusal.
- `VanStockSheetImportTests` — each proposal kind; a missing row changes nothing; the conflict
  case; a foreign sheet matched by header; an unrecognised header refused.
- `VanStockReconcilerTests` — a part on a finished task with no movement is listed; one with a
  movement is not; a dismissed part stays dismissed for that job only.
- `VanStockHandoverTests` — the top-up list is standard minus on hand, never negative; with no
  standard anywhere it falls back to zero and below-minimum lines and says so; unrecorded parts
  are asked about before anything is staged; staging sends nothing; a takeover sets a missing
  line to zero where a correction leaves it alone; orders and unreliable marks come across; a
  different van archives rather than merges; a stale handover is not the default; nothing is
  staged under HIPAA mode; the log never holds a name.
- `VanStockSurplusTests` — a line loaded this shift above its standard is found; one loaded and
  used is not; one with no standard is; stock above standard from an earlier shift is not asked
  about again; returning removes exactly the surplus named; keeping changes no level; accepting
  the offer sets the standard as set by the van.
- `VanStockBaselineImportTests` — levels never change; a named line takes base's figure; a new
  line is created at zero; a van-set standard is kept by default and shown with both figures; an
  unnamed line is untouched; a second, different baseline leaves the truck's additions alone.
- `VanStockToolTests` update — `to_standard` fills only short lines, honours exceptions, is one
  batch and one undo.
- `WorkRecordTests` update — the block is absent when empty, so an older record encodes as it did.

## Non-goals

- The firm's stock, base stock, transfers between vans, and two phones on one van at once (HF).
- Ordering from a supplier, prices, and anything that spends money.
- Requests sent without the technician saying so.
- Fractional quantities and unit conversion.
- Exposing the app's documents folder in Files, or editing a workbook in place.
- A column-mapping screen for arbitrary spreadsheets.
- Counting stock from a photo of a shelf.

## Open questions

1. **Units.** Is whole-number `each`/length/weight enough for the pilot, or is refrigerant by
   weight needed from the first day? Fractions change the quantity type everywhere, HF included.
2. **The word.** "Truck" in North America, "van" here. Proposed: the tool understands both and
   the screen title follows the region's English. *Taken up by Plan [MK](MK-stock-where-it-lives.md)
   (2026-11-19): a place setting (van, truck, store or warehouse) that the organisation can lock,
   proposed with no region default.*
3. **Where corrections happen.** If pilot technicians correct on the phone, P2 is enough for them
   and P3 is only for the first load. If they correct at a desk, P3 moves ahead of P2.
4. **Barcodes.** Do the shop's parts carry them? If not, the alias work in P1 can wait.
5. **How long the history is kept** before it is folded into an opening balance.
6. **When to ask about an unrecorded part:** only when the job is closed (proposed), or as soon
   as its task is finished.
7. **The baseline's form.** Base holds a baseline (decided). Is it already a spreadsheet with
   part numbers and quantities, or does somebody have to write it down first?
8. **The office.** Whether its report intake already tolerates an unknown block on the work
   record, or needs a change before P4 ships.
9. **Returned extras.** Does base want to be told what came back at the end of a shift, as a
   line in the handover message, or is the level enough?
