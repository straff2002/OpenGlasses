# Plan MM — Stock Kept in the Business's Own System (a garage's workshop system or a shop's till holds the count; the phone reads it and sends back what was used)

**Status:** 🚧 P0 built 2026-11-20 (headless): the pure seam in
`Services/FieldAssist/StockSystem/` (who holds the count, the snapshot and its builder, the
conversion into Plan ML's `StockQuantity`, the join, the sentences, the parts-used write plan, the
connector protocol), two invented fixture sets and `Contracts/stock-systems.md`; 47 tests. Built on
the recommendations for decisions 2–9 and 11, each kept in one place (`StockSystemPolicy`), which
remain the owner's to change. **Decision 1 taken 2026-11-20: Square and Simpro**, one system without
jobs and one with, built against fixtures from each vendor's public reference and checked against a
live account later, as Workiz was. **P1 built 2026-11-20 (headless): Square only**, by the owner's
direction: the vendor-neutral adapter seam in the same folder (requests from a closed endpoint
list, paged pull plans, the driver, common failure categories and their sentences), an item's
`decimalPlaces` in the snapshot, and Square's thin adapter in `StockSystem/Square/` over synthetic
fixtures; 57 new tests. Simpro is not built (no public reference). Square's live qualification
is owed. **P2 built 2026-11-20 (headless): the common connection** (Settings › Field Assist › Stock
system, the device-only Keychain item, the pinned-host transport and `squareStockAPI` route, the
snapshot store and the pull triggers, the office-route erase, the profile keys); device checks owed.
**P3 built 2026-11-20 (headless): `van_stock` answers from the system** (who holds the count in the
service and the tool, the §5 table, the description per authority, check-now within 3 seconds,
uses staged per job or premises day, the Stock screen's read-only figures and the previous list);
a day of spoken checks against a real account owed. **P4 built 2026-11-21 (headless): parts used,
out per job** (one yes per batch by voice or on screen, the premises day list, the common queued
sink with read-back before retry, the job's states, the record's members); ten closed jobs and the
offline, revoked-permission and killed-mid-send cases owed on a device against a real account. P5
(the pilot) owed; the plan stays 🚧 for those device checks and Square's live qualification.
Quantities are Plan [ML](ML-measured-quantities.md)'s.
**Track:** Field Assist (B2B).
**Builds on:**
- Plan [IH](IH-van-stock.md): the phone's own movement log, the `van_stock` tool, the Stock screen,
  the close-of-job question (`VanStockReconciler`) and the work record's `van_stock` block. This
  plan keeps all of that for a business with no stock system. Where a system holds the count, it
  changes who answers.
- Plan [MK](MK-stock-where-it-lives.md): the place (`StockPlace`: van, truck, store, warehouse,
  `stock`) and its wording, and the vault a list names to check numbers against. This plan adds
  where the count is kept to the place. It does not change MK.
- Plan [HF](HF-office-stock-and-capture-contracts.md): the office stock snapshot (locations, lines,
  `onHandScaled` or `known: false`, provenance, as-of time, replace-whole) and its rule that the phone
  sends proposals, never ledger writes. This plan reuses the snapshot's body shape with a connector
  as its source in place of Avenkin Office.
- Plan [JR](JR-workiz-from-the-phone.md): the precedent for the phone talking straight to a
  business's own system. It covers the device-only key, the "who are you there?" choice, the
  route-per-system registration, a write plan with read-back before retry, and the office route
  ceiling (`organizationFieldServiceRoute`) that stops every direct connector once a firm's office
  connects the system itself.
- Plan [ML](ML-measured-quantities.md): `StockQuantity`, a whole number of thousandths of the line's
  unit, and HF's quantity members as amended there (`onHandScaled`, `quantityScaled` under a signed
  `quantityScale` of `3`, with `each` and `pack` whole). Every quantity in this plan is that type.
- Plans [HT](HT-external-job-references.md) and [HU](HU-service-history-and-maintenance-flags.md):
  a job's identity in another system (`ExternalJobReference`), which lets parts used go onto
  the system's own job.

---

## Trigger

The owner, on Plan MK: a garage will probably already run a workshop management system with parts
inventory, and a shop a point-of-sale system. Avenkin's van stock is the phone's own count (IH). For
those businesses a second count on the phone would compete with the one they already pay for.
Nobody would keep both up to date, so both would drift. The figure the business trusts is the one
in its system, which is the figure that should be answered.

## The point, said once

**Where a business already has a system of record for stock, the phone does not keep a second
count.** It does three jobs there:

1. **Answer "have we got one?" from the system's figure.** The answer is read-only and says where
   the figure came from and how old it is: *"Three in stock in Square, as of 9:10."* It works with
   no signal from the last snapshot.
2. **Capture what was used on each job and hand it to the system.** The used parts are staged on
   the phone and confirmed by a person before anything is sent. They go as a part line on the
   system's own job where the system has jobs, or as a stock adjustment where it has none. Nothing
   is written unattended. The phone never sets a level.
3. **Stay out of the way where there is no system.** IH and MK keep the phone's own list for a
   business with none. When both exist, the system answers for the stock it holds and the phone's
   list stops counting that stock (Decision 3).

## What exists today (verified 2026-11-19 on `origin/main` 965de65b0)

- **The phone's own stock.** `Services/FieldAssist/VanStock/`: `VanStockLedger` (the fold),
  `VanStockMatcher`, `VanStockAnswerComposer`, `VanStockService`, `VanStockStore` (`SensitiveStore`
  `.vanStock`), `VanStockReconciler` and `VanStockUse` (the close-of-job question and the record's
  block), `VanStockHandover`. **Quantities are `Int`** (`VanStockMovement.quantity`,
  `VanStockUse.quantity`). The tool is `NativeTools/VanStockTool.swift`.
- **One direct connector exists:** Workiz (`Services/FieldAssist/Workiz/`, Plan JR). Its
  pieces are the patterns this plan follows: `WorkizConnection` (key in the Keychain
  `…ThisDeviceOnly`, the stored external user id, the office-route check
  `PolicyEnvelope.string(.organizationFieldServiceRoute, …) == "office"`), a transport seam with a
  URLSession implementation that refuses redirects and foreign hosts and caps response bytes, a
  pure request builder that permits only the writes its contract names, and a durable `SyncSink`
  with read-back before retry. `UpcomingJob.Origin.connector` marks a job from another system.
- **Egress is registered and checked.** `Services/Security/NetworkRouteRegistry.swift`: every route
  is a `NetworkRoute` case with a purpose sentence, the `NetworkDataClass`es it may carry, a medical
  policy (`.workizAPI` is `blockedWhenLocalOnly`) and the one transport type allowed to use it.
  `MedicalEgressGuard.check(_:)` runs before every request. `PrivacyManifestReconciliationTests`
  walks the registry against `PrivacyInfo.xcprivacy`, and `NetworkRouteRegistryTests` fails on an
  unregistered transport.
- **Secrets never ride a profile.** `SettingKey`'s rule is that a secret must be structurally
  impossible to put in a photograph, and a test asserts it is disjoint from `Config`'s secret
  inventories. `organizationFieldServiceRoute` is a string ceiling pinned to `office`.
- **The office snapshot is drafted and unbuilt.** HF's snapshot is signed by Office and delivered
  over FX's transport, and none of it exists in code. Plan ML amends its quantities to whole
  thousandths under a signed `quantityScale`.
- **No stock system is connected.** Nothing reads or writes any garage, trade or retail system's
  inventory today. The Workiz v2 reference read for JR has job line items but no stock calls.

## Which systems, and what they offer

Read from each vendor's public developer reference or product help, 2026-11-19. Where a vendor
publishes no reference, the row says so. Every API fact here is to be confirmed in P1 against a
real account before any build depends on it.

| System | Kind | Read stock | Send back what was used | Access | Notes |
|---|---|---|---|---|---|
| **Square** | Retail POS | Counts per catalogue item and location; quantities are decimal strings, up to five places | `BatchChangeInventory` with `ADJUSTMENT` between states (`IN_STOCK` → `WASTE`, and so on) or `PHYSICAL_COUNT`; a batch succeeds or fails whole; a client idempotency key | Public reference, sandbox; OAuth with scopes, or a personal access token for the seller's own account | Square's guide says not to submit computed levels as physical counts, which matches Decision 6. Measurement units carry their own precision. Sales recorded by the till already take stock out |
| **Lightspeed Retail (X-Series)** | Retail POS | Inventory per product and outlet | `stock_adjustments` (API version 2026-01): per outlet and product, a closed reason list (`INTERNAL_USE`, `DAMAGE`, `EXPIRY`, `THEFT`, `DONATION`, `STOCK_FOUND`, …), needs `inventory:write` | Public reference | Common in New Zealand and Australian retail. `INTERNAL_USE` is the right reason for a part used and not sold |
| **Shopify (POS)** | Retail POS | Inventory levels per location (Admin GraphQL) | `inventoryAdjustQuantities` with a named quantity (`available`, `on_hand`), a reason from a closed list, and an idempotency key | Public reference; a custom app per store with `read_inventory` / `write_inventory` | Whole-number quantities, so fluids by the litre do not fit |
| **Simpro** | Trade job management with stock | Stock per **storage device** (a van, a warehouse, a shed) from a catalogue | Stock allocated to a job as materials; transfers between storage devices | REST API on the customer's own build host; vendor reference | The closest fit to IH: it already models a van as a storage device. Common with trades in New Zealand, Australia and the UK |
| **Shopmonkey** | Garage management | Parts inventory (list, search) | Parts on a work order's services | Self-serve: an admin makes an API key in Settings › Integration › API Keys; bearer token; no sandbox reported | The key carries the admin's permissions, so it is company-wide (JR's risk). US-centred |
| **Tekmetric** | Garage management | Parts inventory | Parts lines on a repair order's jobs | Partner programme only: apply, then OAuth client credentials with a sandbox | No public reference. US-centred |
| **MechanicDesk, Workshop Software** | Garage management (NZ, AU, UK) | Stock levels and supplier invoices, per product pages | Parts on a job card, per product pages | An API is advertised (Workshop Software on its top tier). **No public reference found** | Most likely to be what a New Zealand garage runs. Needs the vendor's documentation and permission before a plan can depend on it |
| **Unleashed** (inventory system) | Inventory behind a shop or workshop | Stock on hand | `StockAdjustments` (list, view, create; cannot be back-dated) | Vendor reference; an API id and key per account | For a business whose POS or workshop system defers to a separate inventory system |
| **ServiceTitan** | Field service | Inventory module: trucks and warehouses, on hand / available / on hold, adjustments | Materials on a job | Office-side only (FX21). The phone never talks to ServiceTitan | Out of this plan. A firm on ServiceTitan gets its stock through Avenkin Office into HF's snapshot |

**What the table says.** Two shapes recur, and the seam has to take both:

- **A system with jobs** (garage and trade systems: Simpro, Shopmonkey, Tekmetric, MechanicDesk,
  Workshop Software). Used parts go onto **the system's job**, and the system takes them out of
  stock by its own rules: when the line is added, when the job is invoiced, or when a person
  approves it. Writing a stock adjustment as well would take the part out twice.
- **A system without jobs** (a POS, or an inventory system). The till records sales, and a sale
  takes the item out of stock. Parts used and not sold, such as a workshop's consumables or a
  shop's breakage, go as **an adjustment with a reason** (`INTERNAL_USE`, `WASTE`, `DAMAGE`). The
  phone never records a sale (Decision 7).

**Recommendation for Decision 1.** Build first for the system the first committed pilot runs, and
not before one commits. A garage pilot will most likely be on MechanicDesk or Workshop Software,
which first needs the vendor's documentation (P1's gate). If the seam must be proved before a pilot
names a system, prove it on **Square**: it has a public reference, a sandbox, decimal quantities
and self-serve access. P0's fixtures cover one system with jobs and one without, so the first
connector does not set the seam's shape alone.

## Design

### 1 · Who holds the count: `StockAuthority`

A list's place (MK) gains **where its count is kept**:

- `phone`: the phone's own movement log (IH), as today, and the default.
- `system(connectorID, locationIDs)`: a connected system, and which of the system's locations are
  this place, chosen on the phone (§3). A van in Simpro is one storage device; a shop in Square
  is one location; a garage is usually one location with several bins.

`StockAuthority.resolve` (pure) decides it in this order: the organisation profile's route ceiling
(§4) first, then the connection on this phone, then `phone`. It is the one place `van_stock` asks
who answers. **When a system holds the count, the phone's own list for that place stops counting.**
It is kept read-only as a previous list, the way IH P5 keeps one across a takeover, so nothing is
lost and switching the connection off restores it (Decision 3). There is no merge and no partial
split: a phone that counted some lines itself and read others from a system would answer two ways
for the same shelf.

### 2 · The snapshot: HF's shape, fed by a connector

`StockSystemSnapshot` is HF's snapshot **body**: `locations` (`id`, `name`, `class`) and `lines`
(`part`, `description`, `unit`, `levels` per location with `onHandScaled` **or** `known: false`,
`provenance`, optional `lineAsOf`, optional `price`). Two things differ, because no office signs
it:

- **The source is stated, not signed.** The snapshot carries `source` (`connector`, the system's
  id and display name, the account label the person sees) and `asOf`: the time the phone finished
  the pull, unless the system dates its own figures, in which case it is the oldest of those dates.
  Integrity comes from the pinned host and TLS, as for Workiz. There is no signature to check
  because no Avenkin party produced the figures.
- **A new provenance word, `system`** (Decision 11): the system's own figure, however the system
  arrived at it. HF's `counted`, `inferred` and `declared` describe Office's ledger. The phone
  cannot know which of those a POS figure is, and saying "counted" would claim too much.

**Quantities are Plan ML's** (§8): `onHandScaled` in thousandths under `quantityScale` `3`, and
`unit` from the phone's closed list. The connector converts the system's figures into that form
before a line enters the snapshot. This plan adds nothing to HF's quantity members.

`StockSystemSnapshotStore` keeps the last good snapshot per connector, outside vault content,
protected, replaced atomically, with the previous one kept until the new one is committed (HF P1's
rule). It joins `SensitiveStore` as `stockSystemSnapshot`. It is business data, so it is **excluded
from backup** like Workiz's cached jobs, because a restored phone should pull fresh figures rather
than trust old ones. The snapshot holds only what `van_stock` needs: the chosen locations' tracked
items, up to 20,000 lines (HF's cap). `price` is dropped while it is decoded unless the
organisation has enabled prices (Decision 9).

**When it pulls.** When the app comes to the foreground, when the Stock screen opens (at most every
10 minutes) and on pull-to-refresh, like JR's jobs. There is no background fetch. A `check` with a
connection and a snapshot older than 10 minutes may also ask the system for just those lines, with
a 3-second budget. If the reply is late, the answer comes from the snapshot with its age, and the
late reply only refreshes the store (HF P4's rule; Decision 10).

### 3 · The connection, in Settings

**Settings → Field Assist → Stock system.** The section is shown when Field Assist is licensed and
the profile does not route outside systems through the office (§4). For each system it has the
same five steps as JR:

1. **Sign in or paste a key.** Use OAuth with PKCE where the vendor offers it to a mobile app.
   Otherwise paste a key, with a short *How to make a key* list that names the smallest scopes the
   phone needs. Read: inventory, catalogue and locations. Write: inventory adjustments, or job
   parts, but only when sending back is switched on.
2. **Test connection.** Read calls only, then one line saying what works: *"Connected to Square.
   Stock ✓ Items ✓ — sending back is off."* A missing scope names the scope. Write access is
   confirmed on the first send, as JR does it.
3. **Which stock is here?** A list of the system's locations (outlets, storage devices, warehouses),
   with the one that matches the list's name preselected when exactly one matches. The choice is
   stored with the connection, not in the workbook, for the same reason MK keeps the named vault
   off it.
4. **Who are you there?** Only for a system with jobs, so that parts land on the right person's job
   (JR step 3).
5. **What goes back** (off by default): parts used as job lines, or as adjustments with which
   reason, and **Remove connection**.

**Credentials.** The token or key is kept only in the Keychain (`…ThisDeviceOnly`). It is never in
a backup, a log, a support report, a diagnostics export or a profile, and `DiagnosticsRedactor`
treats it as a known secret. It is erased by *Remove connection*, when the phone leaves its
organisation, and when the office route ceiling arrives. A profile may switch the connector on,
choose the system, set what goes back and lock those choices. It can never carry the key (the
`SettingKey` rule). On a managed phone the key is pasted behind the admin passcode (JR Decision 2).
A system whose keys are company-wide carries JR's risk, accepted per system in Decision 12.

### 4 · A firm with Avenkin Office

The office rule from JR holds: **a firm that runs Avenkin Office connects outside systems in the
office, and the phone reads HF's snapshot.** The existing `organizationFieldServiceRoute = office`
ceiling stops every direct stock connector as well (Decision 2). It erases the key, retires the
system snapshot, and leaves any staged parts-used batch to go with the work record by the usual
route, so the office can post it. One rule covers jobs and stock, and two routes never write the
same system.

### 5 · What `van_stock` says when the system holds the count

The tool, its name and its action values stay (MK Decision 6). Its description and its results
follow the authority:

| Action | Phone holds the count (today) | System holds the count |
|---|---|---|
| `check` | IH's answer | *"Three in stock in Square, as of 9:10."* With the snapshot older than the staleness threshold (HF Decision 3's 24 hours), the age comes first: *"As of yesterday at 16:10, Square had three."* An unknown figure: *"Square lists it but has no count for it."* A line in the vault but not in the system: *"Square doesn't carry that number."* Other locations, when the snapshot has them: *"None here; two at the Main Street store."* |
| `low` | IH's answer | Lines at or below the system's own reorder point, when the system has one; otherwise the lines at zero. Said as the system's figures |
| `use` | Records a movement | **Stages** a used line on the open job (§6) and says so: *"I've noted one 45/5 capacitor used on this job. It goes to Square when you confirm the job's parts."* Square's count does not change until then. With no job open, the line is staged on the day's list for the place (premises) or refused with the reason (vehicle, where every use belongs to a job) |
| `load`, `count`, `remove`, `set_standard`, `top_up`, `undo` of a load | IH's | Refused with one sentence: *"Stock is kept in Square, so receiving and counting are done there."* `remove` with a reason the system has (damaged, internal use) is staged like a use. A count is never written (Decision 6) |
| `send_to_base` | IH's handover | Not offered. The system is the handover |
| a sale, at a POS | MK's "sold or used" | Not offered: *"Sales come off Square's count at the till."* (Decision 7) |

`StockSystemAnswerComposer` (pure, injected clock and calendar) writes these sentences in English,
as IH P0 decided, through MK's `StockPlaceWording` for the place words, with the system's display
name as a label. Each rule is a test: the as-of time is always present, an unknown is never a
number, provenance is said as "in Square" and never "counted", and the answer names the system.

The **join to the vault** is HF's, three ways: in both; in the vault and not in the system ("doesn't
carry that number"); in the system and not in the vault ("stocked, but I can't check that number").
The vault is the one MK resolves: the open job's, else the list's named vault, else none.
Supersession resolves in both directions before the system's lines are searched, so the number on
the old part finds its replacement's stock.

### 6 · Parts used, out per job

This is the half that makes the connection worth having. It reuses IH P4's close-of-job flow and
changes only where the result goes.

**Staged.** A `use` on a system-held place adds a `StagedStockUse` to the open job's session:
item reference (the system's id, from the snapshot), part number and description, quantity and
unit, verification against the vault, and the source (`spoken`, `typed`, `scanned`). The job's
existing parts on finished tasks still feed `VanStockReconciler`, so a part fitted and never spoken
of is asked about at close, exactly as today.

**Confirmed by a person.** At job close, the parts step reads the staged lines back and asks once:
*"Two parts used on this job: one 45/5 capacitor, half a litre of coolant. Send them to Square?"*
The screen shows the same list with a quantity stepper per line and a Send button. Yes queues the
batch; no keeps it on the job, unsent, with a Job-tab line until somebody sends or discards it.
**Nothing is sent without that yes.** With Agent Mode on, nothing changes: no agent path may send a
staged batch (Decision 5). On premises with no jobs, the day's list is confirmed the same way from
the Stock screen.

**The write plan.** `PartsUsedWritePlan` (pure) turns a confirmed batch into the system's calls,
and it can produce only these:

- **A system with jobs**, and a job that carries an `ExternalJobReference` for that system: one part
  line per staged use on that job, linked to the inventory item. The system deducts stock by its
  own rules.
- **A system without jobs**, or a job with no reference in that system: one adjustment per line,
  from in-stock to the reason the organisation chose (`INTERNAL_USE`, `WASTE`, `DAMAGE`), at the
  chosen location, carrying the job number in the system's note or reference field where it has
  one.
- **Never both for one line.** Never a physical count, a set level, a new catalogue item, a price,
  a sale, an order or a change to the job's status. A used part the system does not carry stays on
  the phone's record and in the work report, and is named as *"not in Square's catalogue, so not
  sent"*.

**Delivered once.** The batch rides the offline queue as a new `SyncSink` per connector. Each write
carries an idempotency key derived from the job and the line, and the sink reads back before any
retry: it lists the job's parts, or the adjustments since the batch was queued, the way JR and
FX21 reconcile. A `401` or `403` stops retrying and says what to fix. A `429` or `5xx` backs off.
The job's row shows *Sent to Square*, *Waiting for a connection* or *Needs attention — …*. After a
successful send the next pull refreshes the figures, and until then the answer says the batch is on
its way: *"Two in stock in Square as of 9:10, and one used on this job is still being sent."*

**On the record.** The work record's `van_stock` block gains, for a system-held place, the system's
id and display name, and each line's item id and delivery state, so the report and the office can
see what went where. The block stays absent on a job that used nothing.

### 7 · Privacy and egress

A new outbound connection is reviewed the way JR's was, in the same PR as the code:

- **One `NetworkRoute` per system** (`squareStockAPI`, and so on), each with its purpose sentence,
  pinned hosts, and the one transport allowed to use it. Its data classes: `credential`; part
  numbers, quantities, location and job references, which are business data under `promptText`
  because a description may have been dictated; and `contactData` only if the system's job read
  returns customer details, which the decoder then drops. **Blocked under Medical Local Only**, like
  `.workizAPI`. `MedicalEgressGuard.check` runs before every request, including retries.
- **No vendor SDK.** Each connector is plain HTTPS through its own `URLSession` transport behind the
  seam. If a vendor SDK were ever linked, the repo's telemetry posture applies before it ships: what
  it sends home by default is reviewed, then switched off or disclosed in `PrivacyInfo.xcprivacy`
  and the in-app privacy copy in the same PR, under `TelemetryOptOutGuardTests`.
- **The manifest and the inventory.** `PrivacyManifestReconciliationTests` covers the new routes.
  The generated privacy inventory table gains a row per system. The in-app privacy copy says, in
  one sentence per system, what goes to it ("part numbers and quantities used on a job") and that
  it is the business's own account.
- **What never goes.** The transcript, photos, the customer summary, prices and anything about the
  person, beyond the external user id step 4 stores.
- **HIPAA mode.** The pull sends nothing user-derived, but it rides the same route, so it is
  blocked under local-only as above. The answer then comes from the last snapshot, with its age.
  Sending back is not offered.

### 8 · Quantities with decimals

Fluids, cable, refrigerant and loose fasteners by weight do not come in whole numbers. Square
already counts in decimal strings, and a garage sells oil by the litre.

**Plan ML owns the quantity.** Every quantity here is ML's `StockQuantity`: a whole number of
thousandths of the line's unit (4.25 l is `4250`), parsed digit by digit and never through a float,
with `each` and `pack` whole. In the snapshot it is HF's `onHandScaled` under `quantityScale` `3`,
as ML amends HF. This plan defines no quantity type and no HF member. **The conversion is the
connector's job, at the seam**, in both directions:

- **In.** A system's decimal string goes through `StockQuantity(decimal:unit:)`. A figure with more
  decimal places than the scale allows (Square keeps up to five) is **refused, never rounded**: the
  line stays in the snapshot with `known: false` and the reason, so the answer is *"Square holds
  that to more decimal places than I keep, so I can't give you its figure."* A system unit that
  maps onto none of the phone's closed list (`each`, `m`, `ft`, `kg`, `lb`, `l`, `pack`) is treated
  the same way. Each connector's unit map is a pure table with its own tests.
- **Out.** A staged use is a `StockQuantity`, written to the system with
  `StockQuantity.decimalString`. A system that keeps whole numbers only (Shopify) refuses a
  fractional line before it is staged, with the reason. A unit the system does not keep for that
  item is refused the same way.
- **Spoken.** ML's spoken forms, unchanged: *"half a litre"* is `500` thousandths of `l`.

## Phases (one PR each)

**P0 — The seam, the snapshot and the sentences (pure, headless).** `StockAuthority` and its
`resolve`; `StockSystemSnapshot` (HF's body plus `source` and the `system` provenance) with its
closed decoding; each connector's conversion into ML's `StockQuantity` (the unit map and the
refusals of §8); `StockSystemJoin`
over a snapshot and the vault MK resolves; `StockSystemAnswerComposer`; `StagedStockUse` and
`PartsUsedWritePlan`; the `StockSystemConnector` protocol (pull a snapshot, list locations, write a
plan, read back), with a fake. Two fixture sets in `Contracts/fixtures/stock-systems/`, invented and
built from each vendor's published example shapes: one system with jobs and one without. A short
`Contracts/stock-systems.md` lists the only writes each connector may make and the idempotency and
read-back rules, so an office-side connector can recognise what a phone wrote. Tests below. No
network, no UI, no store.
✅ **Built 2026-11-20.** As built: the fixtures are vendor-neutral, connector-normalised rows (the
vendor-shaped ones come with P1, once Decision 1 named the systems). A line whose system unit maps
to none of the phone's units keeps the system's unit string and has no `unit`. A connection with no
location chosen resolves to the phone. A job reference is used only when its system matches the
connector. A price is kept as the system's decimal text and currency code, and only when enabled.
The idempotency key is SHA-256 over the job id, the staged line id and the step kind, each followed
by a zero byte. The load refusal says "each receipt and count is done there", so it never says
"counted". Times follow the app's 24-hour style ("as of 09:10").
*Owed:* nothing.

**P1 — The first connector (pure decode and request building) and its qualification.** The system
from Decision 1: closed, bounded types for its responses, the request builder (reads, plus only the
writes `Contracts/stock-systems.md` allows), the error sentences, and the key kept out of every
description. *Gate before the build:* the vendor's reference (and, for a system without a public
one, the vendor's written permission) and a test account. A short qualification against that
account confirms the facts the table marks as to-confirm, and the results are recorded in this
plan.
✅ **Built 2026-11-20 for Square** (headless). The owner chose to build from Square's public
reference and synthetic fixtures and qualify against a live account later, as Workiz was, rather
than wait for a test account; Simpro is not built, because its reference is not public and nothing
is built from anyone's client code. As built, **as much as possible is common**, so the
organisation's own choice of system plugs in without reshaping: `StockSystemAdapter` and
`StockSystemRequest` (a request only for an endpoint on the adapter's closed list, with no host,
no key, and descriptions that never show a header value or the body), `StockSystemPullPlan` (each
paged read a small pure state machine) and `StockSystemPlanDriver` (the one loop, with a request
budget), `StockSystemFailure` (unauthorized expired/revoked/invalid, missing scope, rate limited
with `Retry-After`, server, rejected with only a short plain code, not found, malformed, too large,
unreachable; `isTerminal`/`isRetryable`; one sentence each, naming the system and Settings › Field
Assist › Stock system), and `StockSystemIdempotency` (the batch key: SHA-256 over the sorted step
keys; the write-time clamp). A guard test fails if any file directly in the common folder names a
vendor. The Square adapter is only its five endpoints, decoding, unit table, capabilities (no jobs,
`waste` only, no note, per-item decimals) and read-back matcher; the one write is an `ADJUSTMENT`
from `IN_STOCK` to `WASTE` with the same from and to location, `reference_id` the step's key, at
most 100 per request, `occurred_at` the confirmation time unless it is over 23 hours old.
Decided in the build: an untracked variation is left out of the snapshot, not kept unknown (the
snapshot holds tracked items); Square's `calculated_at` is when a count last changed, so it does
not date a line and `asOf` is the pull; a variation not offered at a chosen location is left out;
the reorder point is kept only when every chosen location's `LOW_QUANTITY` threshold agrees; a
write under a step's key that is not that step (or the key twice) is a mismatch, neither applied
nor resent (`StockSystemReadBack.mismatched`, `PartsUsedWritePlan.needsAttention(after:)`); a
quantity finer than the item's `decimalPlaces` is `too_many_decimals`, never rounded. Prices, when
enabled, are read only in a currency whose minor unit the adapter knows. Square's adjustment
reasons (`reason_id`, beta in `2026-07-15`) are not used.
*Owed (live account):* a Square sandbox account and a seller's own account with a personal access
token, confirming each fact `Contracts/fixtures/square-v2/README.md` lists as not yet confirmed
(`Retry-After`, related objects across pages, the precision default, count spelling, presence
default, never-moved counts, the `occurred_at` window, `updated_after`'s field and margin, the
pinned version and a reused idempotency key, the batch-create response's `changes`, the scopes).
Open question 1 for Square: a sale is taken out at the till; a `WASTE` adjustment is taken out
when Square accepts it. *Owed (device):* nothing yet (nothing is connected until P2).

**P2 — The connection, the store and the routes.** Settings › Stock system (§3), the Keychain
storage, the `NetworkRoute` and its transport, `MedicalEgressGuard`, the manifest, inventory and
privacy copy, `StockSystemSnapshotStore` in `SensitiveStore`, the pull triggers, the office-route
erase (§4), and the profile keys that switch the connector on and set what goes back.
✅ **Built 2026-11-20 for Square** (headless; 53 new tests). As built, everything but the adapter is
common and reads the system's name, hosts, endpoints, permissions, reasons and reply cap from it:
`StockSystemConnectionStore` (one device-only Keychain item per system,
`stockSystemConnection.<connector>`, holding the key and every choice: the business's account or a
sandbox, the chosen locations with their names, sending back, the reason, and an unused external
user id for a system with jobs; the key pasted behind the administrator's passcode on a managed
phone; an erase the locked phone refuses is kept pending and the item never read again),
`URLSessionStockSystemTransport` (the one transport for every stock route: ephemeral, no cookies,
cache or stored credentials, redirects refused, only the adapter's pinned host for the environment
over HTTPS, the endpoint checked again, the bearer added only on the wire, the reply capped at the
adapter's size, `Retry-After` passed back, any connection failure `unreachable`, and
`MedicalEgressGuard.check` before every request), `StockSystemHTTPConnector` (any adapter through
`StockSystemPlanDriver`; the write and read-back wired for P4 and called by nothing),
`StockSystemSnapshotStore` (`SensitiveStore.stockSystemSnapshot`: one file per system in
`Application Support/FieldAssist/stock-system/`, first-unlock protection, file and folder excluded
from backup, a new snapshot written and read back before it replaces the current one, which is kept
as the previous one and read when the current one cannot be) and `StockSystemService` (the
triggers, Test connection, the locations). The adapters are listed by connector id in
`StockSystem/Registry/StockSystemAdapterRegistry.swift` (adapter, route, what the system calls its
key and where it is made); the guard test now scans every common file, the settings view included.
The seam gained `maximumResponseBytes` and `probeRequests()` on the adapter (Square: one `IN_STOCK`
count and one item variation, a page of one each) and `probe()` on the connector, whose `apply` and
`readBack` now take the confirmation and queue times. `NetworkRoute.squareStockAPI` carries
`promptText` and `credential` only. Profile keys (all profile-owned, each locking its control, none a
key): `stockSystemEnabled`, `stockSystemConnector` (a connector this build offers),
`stockSystemSendBack`, `stockSystemAdjustmentReason`. Erased on Remove connection, on leaving the
organisation (beside Workiz's) and when the office route arrives (`enforceWorkizRoute` now enforces
both); a new key, or another choice of locations, retires the snapshot. Settings › Field Assist ›
Stock system is hidden under the office route; the Stock screen shows "From Square at 09:10" and
why the last pull failed, pulls on opening and on pull-to-refresh. Decided in the build: the
foreground pull keeps the same 10-minute interval as the Stock screen (JR's rule), measured from the
last attempt; only pull-to-refresh, a good Test connection and a new choice of locations pull at
once. One pull at a time: a second caller waits for the one under way. Test connection chooses the
location whose name matches the list's when exactly one does. Square's personal access token is not
scoped, so "How to make a key" lists the permissions the phone uses rather than ones to tick. OAuth
with PKCE is not built: it needs an Avenkin application registered with each vendor.
*Owed (device):* Test connection and a pull on 4G and on Wi-Fi; aeroplane mode afterwards (the last
figures stay, with the unreachable sentence). *Owed (live account):* P1's Square qualification, now
through Settings. *Owed (build):* OAuth with PKCE per vendor; a catalog sync of the new Settings and
Stock screen strings (separate PR).

**P3 — `van_stock` answers from the system.** `StockAuthority` in `VanStockService` and the tool;
the per-action table in §5; the computed description per authority; the Stock screen showing the
system's figures read-only with *"From Square at 9:10"* and the previous list kept; check-now with
its budget.
✅ **Built 2026-11-20** (headless; 49 new tests). As built, all of it common, reading the system's
name, capabilities and reasons from the adapter: `VanStockService` asks `StockSystemService.authority`
(`StockAuthority.resolve` over the office route and the running connection) before every action, and
while a system holds the count hands the action to `StockSystemVanStock`, which answers from the
snapshot through `StockSystemJoin` (a number joined across the book, supersession both ways; words
matched against the system's descriptions with IH's matcher) and `StockSystemAnswerComposer` (new:
`low`, `list`, no figures yet, the notes and their undo). **The phone's list is kept where it is**,
not moved aside: every write to it (spoken, typed on the screen, a workbook import or takeover, a
baseline, an order noted from a parts request) is refused while the system holds the count, so it is
the previous list read-only, and removing the connection gives it back unchanged; IH P5's archive is
for a takeover and was not reused. A `use`, or a `remove` with `damaged` when the system keeps
damage or waste, is staged in `StagedStockUseStore` (`SensitiveStore.stagedStockUse`: one file
beside the delivery queue, first-unlock, out of backup, kept when a snapshot is retired, cleared on
leaving the organisation) with its scope (`job:<session>`, or at premises with no job `day:<date>`),
the system's location, the item, quantity, unit, verification, source, the write-off reason and the
call; a vehicle with no job open is refused. A quantity the item cannot take is refused before it is
staged (`StockSystemQuantityConversion.outgoing` with the item's `decimalPlaces`), and so is a unit
other than the item's. The same use said twice within ten seconds is noted once; `undo` takes back
the last call's notes. No phone movement is written and no `VanStockUse` reaches the job, so the work
record is unchanged. The tool's description and schema are computed per authority: under a system
they offer `check`, `list`, `low`, `use`, `remove` (damaged), `undo` and the two job actions, say
receiving, stocktakes, par levels and reordering are done in the system, and never offer a sale;
`load`, `count`, `set_standard` and `top_up` are refused before any figure is read, `send_to_base`
says the system already has it, and `sell`/`sale`/`sold` get the till's sentence. **Check-now**: a
new pure adapter operation, `linesPlan(itemIDs:locationIDs:)` (Square: the same counts
batch-retrieve with `catalog_object_ids`, at most 100, so the five endpoints are unchanged), and
`pullLines` on the connector (a fallback whole pull for one without it); `StockSystemService.checkNow`
asks only when the figures for the asked lines are over ten minutes old, there is signal
(`Reachability`) and Medical Local Only does not hold the route, races the read against the
3-second budget (injected), merges a reply in time into the store (only those lines' levels and
`lineAsOf`; an older reading never wins, a missing figure keeps the reason it had), and lets a late
reply refresh the store without being waited for. The Stock screen, while a system holds the count,
shows "From <system> at 09:10", the figures read-only (unknowns with the reason, never 0; stale
said plainly), what is noted for the open job or today, and the phone's list as "Previous list",
collapsed; pull-to-refresh and the open-screen pull stay; only Name and place remains in the menu.
Decided in the build: a premises day's note says "used today", never "sold or used"; a removal for
returned, lent or other is refused (only a write-off is the system's to record); the work record's
new fields wait for P4, and so does the close-of-job question over staged lines (`unrecorded` still
reads the job's phone uses).
*Owed (device):* a day of spoken checks against a real account, including the stale and unknown
cases, and the Stock screen's read-only figures and previous list on a phone. *Owed (build):* a
catalog sync of the new Stock screen strings (separate PR).

**P4 — Parts used, out per job.** Staging, the close-of-job confirmation by voice and on screen,
the premises day list, `PartsUsedWritePlan` through the connector's sink, read-back reconcile, the
job row's states, and the `van_stock` block's new fields.
✅ **Built 2026-11-21** (headless). As built, all of it common, driving any adapter through
`StockSystemConnector` and naming the system by its display name (the vendor guard now scans the
new files and the close, the flow, the Job tab and the parts step). **Confirmation**
(`StockSystemPartsUsed`): `confirm(scope, by: StockUseConfirmation)` reads the noted lines in a job
or a premises day, groups them by location and reason, builds each `ConfirmedStockUseBatch` and
`PartsUsedWritePlan`, marks a line the plan cannot send `not_sent` with its sentence, and queues
the rest. It is called from two places only: by voice, `JobCloseSequence` holds a voice close
(after IH's question for parts on finished tasks, which now counts a noted part as accounted for)
with a line telling the model to stand back; `GuidedJobFlow` puts the question itself at the end of
the turn (*"Two parts used on this job: one Run capacitor 45/5, half a litre of Coolant. Send them
to Square?"*), takes the person's plain yes or no (`RemoteActionVoiceConsent`) before the model
hears anything, and finishes the close; on the screen the Job tab's close opens the parts step
first (a stepper per line moving by the item's unit and `decimalPlaces`, never to nothing; swipe to
discard; Send, or Not now). A question put and not answered keeps the parts unsent; a no keeps them
on the job with *"N parts not sent to Square"* until sent from the job's page or discarded. No tool
or agent surface can confirm or send (`StockSystemConfirmationGuardTests` scans every source file
for a confirmation outside those two places, and the tool, agent, Apple Intelligence, gateway and
intent folders for any path to the confirmation, the sink or the queue kind). Sending is offered
only while the connection runs, sending back is on, Medical Local Only does not hold the route and
the office does not post stock; otherwise, at close, the job's noted lines go on its record as
`not_sent` with that reason. **The premises day list**: the Stock screen, at premises with no job
open, shows today's states and *Review and send*, confirmed on the screen only. **The sink**
(`StockSystemSyncSink`, one for every system, ahead of Workiz's on the queue): the queue item
(`OpKind.stockSystemParts`, `StockSystemQueuedBatch`) holds the plan, the connector id, the
system's name, the confirmed-at and queued-at times and the delivery's progress, never the key;
a write is marked uncertain before it is sent, and the next attempt after a timeout, a dropped
connection, a `5xx`, an unreadable reply or a kill reads back first and sends only what is
missing; a mismatched key is `needs_attention` and never resent; `401`/`403` stop with the failure's
sentence until a new key's generation; `429` honours `Retry-After`, else 30 s doubling to an hour;
no signal waits without counting an attempt; running out of attempts needs attention and can be
tried again. The office route arriving, or Remove connection, ends a queued batch and leaves its
lines on the record as `not_sent` (`office_route`, `disconnected`) — the decision recommended in the
brief. A send asks for a fresh pull (one at a time), and until a newer figure a `check` says
*"…and 1 used on this job is still being sent."* **States**: each staged line now carries where it
stands (`staged`, `queued`, `sent`, `not_sent` with a reason code, `needs_attention`), shown as
*Sent to Square*, *Waiting for a connection*, *Needs attention — …*, *N parts not sent to Square*
and *N not sent: …* on the job's row, its page and the parts step; settled lines are kept 30 days.
**The record**: the job's lines are kept on the session (`stockSystemUses`, for the open job or a
finished one), so `van_stock` gains, per system line, `itemID`, `delivery` and `deliveryReason`, and
the record names the system in `van_stock_system`; phone-held lines and a job that used nothing are
unchanged (`Contracts/office-reports.md`, `Contracts/tests/test_van_stock_record.py` and a second
fixture). **P3's gap closed**: a workbook opened while the system holds the count is refused with
*"Stock is kept in Square, so this list was kept as the previous list and not loaded."* Decided in
the build: the record carries each line's state when the record is taken, and a record taken later
(the report sent from the job's page) carries the later state; a batch is one location and one
reason; a line noted for another system than the one connected is `not_sent` (`disconnected`); a
reason not chosen never settles a line: the reason sent is the one chosen when the system keeps
it, else the system's only reason (Square keeps only `waste`, so it needs no choice), else none, and
a profile-locked reason is never replaced; turning sending back on stores the reason Settings
shows. With none (several kept and none chosen, or a profile locked to one the system doesn't
keep), sending is not offered (`no_reason`) and the lines stay noted on the job, waiting to send,
rather than closing as `not_sent`. A plan built with no reason still marks its lines `no_reason`, as
P0's does, and a line's own reason (written off as damaged) is kept as said.
*Owed (device):* ten jobs closed with parts sent, one with the phone offline until the next morning,
one with the key's write permission removed, and one resend after a forced kill mid-send. In the
system: each line appears once, on the right job or as the right adjustment. *Owed (build):* a
catalog sync of the parts step's and the Job tab's new strings (separate PR).

**P5 — The pilot pass (owed).** A week in the pilot business. Measure answers given from the system
against the shelf, parts sent against parts fitted, every *Needs attention*, and every answer that
said "van", "counted" or a number for an unknown.

## Tests

- `StockAuthorityTests`: the profile's office route beats the phone's connection, which beats
  `phone`; the phone's list becomes the previous list and comes back when the connection is
  removed; no list is ever both.
- `StockSystemSnapshotTests`: closed decoding (unknown members ignored, strings capped, a malformed
  line dropped and counted); `known: false` round-trips as unknown and never zero; price dropped
  unless enabled; the line cap; `asOf` is the oldest system date when the system dates its
  figures.
- `StockSystemQuantityTests` (the seam, over ML's `StockQuantity`): a system's decimal string to
  thousandths and back without loss; more than three decimal places gives `known: false` with its
  reason, never a rounded figure; an unmapped unit likewise; a whole-number system refuses a
  fractional staged use.
- `StockSystemJoinTests`: the three join outcomes; supersession both ways; MK's book order.
- `StockSystemAnswerComposerTests`: as-of always present; stale wording first; unknown never a
  number; "in Square", never "counted"; other locations; the place's words from
  `StockPlaceWording` and none of the other family's.
- `PartsUsedWritePlanTests`: a job with a reference gives job lines only; no reference or no jobs
  gives adjustments only; never both for one line; never a count, set, sale, price, new item or
  status; an uncarried part is named and not sent; idempotency keys stable across a rebuild of the
  same batch.
- `VanStockToolTests` additions, per authority: `load`/`count` refused with the sentence; `use`
  stages and says so; no sale at a POS; the description per authority.
- `StockSystemSinkTests` (P4): read-back before retry; only the remaining steps resent;
  `401`/`403` stop; `429` with and without `Retry-After`; back-off; survives a relaunch with no key;
  an office-route ceiling ends a queued batch with its sentence and leaves it on the record; a
  mismatch needs attention and is never resent; end to end over Square's fixtures. With
  `StockSystemPartsUsedTests`, `StockSystemPartsVoiceCloseTests` and
  `StockSystemConfirmationGuardTests` (no agent path confirms or sends).
- `NetworkRouteRegistryTests`, `PrivacyManifestReconciliationTests`, `DataStoreRegistryTests` and
  the profile secret-disjointness test updated for the new route, store and key.

## Decisions for Greig

1. ✅ **Taken 2026-11-20 (owner): Square and Simpro**, built against fixtures from each vendor's
   public reference and qualified against a live account later, as Workiz was. *Recommended had
   been:* the one the first committed pilot runs, chosen when a pilot
   commits. A New Zealand garage is most likely on MechanicDesk or Workshop Software, which first
   needs the vendor's documentation and permission. If the seam must be proved first, prove it on
   Square (public reference, sandbox, decimals, self-serve). P0 is built over one system with jobs
   and one without either way. **The choice is yours.**
2. **A firm with Avenkin Office.** *Recommend:* the existing `organizationFieldServiceRoute = office`
   ceiling stops direct stock connectors too, so the office connects every outside system and the
   phone reads HF's snapshot. *Alternative:* a separate stock route key, for a firm whose office
   connects its field-service system but not its till.
3. **When the phone's list and a system both exist.** *Recommend:* the system answers for the place
   it holds; the phone's list for that place is kept read-only as the previous list and stops
   counting; removing the connection restores it. *Alternative:* the phone keeps counting the lines
   the system doesn't carry, which means one place answered two ways.
4. **How used parts go back.** *Recommend:* as part lines on the system's job where the system has
   jobs and the job has a reference there; otherwise as adjustments with the organisation's chosen
   reason; never both for one line.
5. **Who confirms.** *Recommend:* the technician at job close (or the person keeping a premises list,
   from the Stock screen), one yes per batch, by voice or on screen. No agent path may send a
   batch, Agent Mode included. *Alternative:* a second person (the office) approves each batch,
   which needs a place to approve it that this plan does not build.
6. **Counts from the phone.** *Recommend:* none in v1. A count is done in the system, as Square's
   own guidance says (a computed level must not be sent as a physical count). *Later:* a physical
   count sent only after the person reads it back and confirms it, if a pilot wants stocktakes from
   the phone.
7. **Sales at a POS.** *Recommend:* the phone never records a sale. The till does that.
8. **Quantities.** *Recommend:* Plan ML's `StockQuantity` and its amendment of HF, with no quantity
   form of this plan's own. The connector converts at the seam and refuses a figure finer than the
   scale or in a unit the phone does not keep, rather than rounding it.
9. **Prices.** *Recommend:* dropped at decode and never spoken unless the organisation enables them
   (the one organisation key HF Decision 4 proposes, shared by both plans).
10. **Live check.** *Recommend:* snapshot answers, plus a check-now for the asked-about lines when
    the snapshot is over 10 minutes old and there is signal, within 3 seconds, falling back to the
    snapshot with its age.
11. **Provenance word.** *Recommend:* a new `system` provenance, said as "in Square", so a POS
    figure is never called counted.
12. **Company-wide keys.** *Recommend:* accept JR's risk per system, with its mitigations (smallest
    scopes, device-only Keychain, only this place's locations shown, rotation is one paste), and
    use OAuth with PKCE and per-user tokens wherever the vendor offers them.

## Open questions

1. **Where the system takes stock out.** Some garage systems deduct a part when it is added to the
   job, some at invoice, some on approval. P1 records which, per system, so the answer after a send
   can say when Square's (or the garage's) figure will change.
2. **A van in a system without vans.** A POS has no vans. A mobile mechanic whose till is Square
   either makes the van a Square location or keeps the van on the phone (IH) and the shop in Square,
   which needs two places on one phone (MK Open question 3, still one list per phone).
3. **Bins.** A system's bin or shelf field, where it has one, could fill IH's bin label for "where is
   it?". Proposed: read it if present, never write it.
4. **Kits and assemblies.** A system that sells a kit and deducts its parts. Proposed: send the kit
   as the system knows it and let the system explode it.

## Not in scope

- Ordering, purchase orders, reordering suggestions sent to a supplier, and receiving stock into the
  system.
- Prices, costs, margins and invoicing, unless the organisation enables prices to be read.
- Two-way sync of the system's catalogue: creating, renaming or editing items, units, bins or
  reorder points in the system.
- Transfers between the system's locations.
- Sales from the phone.
- Webhooks and background refresh (no server to receive them; no background run).
- Connectors that run in Avenkin Office (the office's own plans), and ServiceTitan stock, which
  reaches the phone only through Office and HF.
- Any change to Plan MK's place, wording or named vault.

## Risks

- **Double deduction.** A part on the system's job and an adjustment for the same part take it out
  twice. `PartsUsedWritePlan` makes both for one line impossible by construction, and that is a test.
- **A stale figure said confidently.** The as-of rule, the stale-first wording and the
  unknown-as-unknown rule are tests, not prompt text (HF's defence, unchanged).
- **Undocumented systems.** The garage systems most likely in a New Zealand pilot publish no
  reference. P1 is gated on the vendor's documentation and permission, and nothing is reverse
  engineered.
- **Company-wide keys on technicians' phones.** As in JR: reduced by scope, storage and rotation,
  not removed (Decision 12).
- **Part numbers differ between the book and the shelf.** The join says so rather than guessing.
  Aliasing is the system's data, never the phone's.
- **The model may still say "counted" or "on the van".** The wording tests run per authority, and
  P5 reads a week of spoken answers.

UI copy never names plan letters. The person-facing words are "stock", the system's own name, and
"send to <system>".
