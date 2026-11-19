# Plan MM — Stock Kept in the Business's Own System (a garage's workshop system or a shop's till holds the count; the phone reads it and sends back what was used)

**Status:** 📝 Drafted 2026-11-19 — nothing implemented. Decisions 1–12 are owed. Which system comes
first is the owner's choice, made for a pilot (Decision 1).
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
  `onHand` or `known: false`, provenance, as-of time, replace-whole) and its rule that the phone
  sends proposals, never ledger writes. This plan reuses the snapshot's body shape with a connector
  as its source in place of Avenkin Office.
- Plan [JR](JR-workiz-from-the-phone.md): the precedent for the phone talking straight to a
  business's own system. It covers the device-only key, the "who are you there?" choice, the
  route-per-system registration, a write plan with read-back before retry, and the office route
  ceiling (`organizationFieldServiceRoute`) that stops every direct connector once a firm's office
  connects the system itself.
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
  over FX's transport, and none of it exists in code. Its `onHand` is an integer.
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
(`part`, `description`, `unit`, `levels` per location with `onHand` **or** `known: false`,
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

**Quantities are decimal** (§8). HF P0 is unbuilt, so its `onHand` can take the same form before
anything ships. That is a note for HF's build, not a change this PR makes to HF's contract.

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

- **The connector's quantities are decimal strings**, kept as `Decimal`, never `Double`, each with
  its unit and the unit's precision (Square's measurement unit carries one; others default to the
  unit's own: three places for `l` and `kg`, none for `each`). A spoken *"half a litre"* becomes
  `0.5 l`; a quantity finer than the unit's precision is refused with its reason, never rounded in
  silence.
- **Plan ML** (measured quantities, being drafted in parallel) may define the app's quantity form.
  If it does, this plan uses ML's type and its spoken forms, and `StockQuantity` here is only an
  adapter to the systems' wire formats. If ML lands later, P0 builds `StockQuantity` the way the
  table above says and ML adopts or replaces it. Either way there is one quantity type in the app
  (Decision 8).
- **The phone's own ledger stays whole-number** in this plan. Moving IH's `Int` to decimals is ML's
  question, not this plan's.
- **A system with whole numbers only** (Shopify) refuses a fractional line before it is staged,
  with the reason.

## Phases (one PR each)

**P0 — The seam, the snapshot and the sentences (pure, headless).** `StockAuthority` and its
`resolve`; `StockSystemSnapshot` (HF's body plus `source` and the `system` provenance) with its
closed decoding; `StockQuantity` (or ML's type) with the spoken and wire forms; `StockSystemJoin`
over a snapshot and the vault MK resolves; `StockSystemAnswerComposer`; `StagedStockUse` and
`PartsUsedWritePlan`; the `StockSystemConnector` protocol (pull a snapshot, list locations, write a
plan, read back), with a fake. Two fixture sets in `Contracts/fixtures/stock-systems/`, invented and
built from each vendor's published example shapes: one system with jobs and one without. A short
`Contracts/stock-systems.md` lists the only writes each connector may make and the idempotency and
read-back rules, so an office-side connector can recognise what a phone wrote. Tests below. No
network, no UI, no store.
*Owed:* nothing.

**P1 — The first connector (pure decode and request building) and its qualification.** The system
from Decision 1: closed, bounded types for its responses, the request builder (reads, plus only the
writes `Contracts/stock-systems.md` allows), the error sentences, and the key kept out of every
description. *Gate before the build:* the vendor's reference (and, for a system without a public
one, the vendor's written permission) and a test account. A short qualification against that
account confirms the facts the table marks as to-confirm, and the results are recorded in this
plan.

**P2 — The connection, the store and the routes.** Settings › Stock system (§3), the Keychain
storage, the `NetworkRoute` and its transport, `MedicalEgressGuard`, the manifest, inventory and
privacy copy, `StockSystemSnapshotStore` in `SensitiveStore`, the pull triggers, the office-route
erase (§4), and the profile keys that switch the connector on and set what goes back.
*Owed (device):* Test connection and a pull on 4G and on Wi-Fi; aeroplane mode afterwards.

**P3 — `van_stock` answers from the system.** `StockAuthority` in `VanStockService` and the tool;
the per-action table in §5; the computed description per authority; the Stock screen showing the
system's figures read-only with *"From Square at 9:10"* and the previous list kept; check-now with
its budget.
*Owed (device):* a day of spoken checks against a real account, including the stale and unknown
cases.

**P4 — Parts used, out per job.** Staging, the close-of-job confirmation by voice and on screen,
the premises day list, `PartsUsedWritePlan` through the connector's sink, read-back reconcile, the
job row's states, and the `van_stock` block's new fields.
*Owed (device):* ten jobs closed with parts sent, one with the phone offline until the next morning,
one with the key's write permission removed, and one resend after a forced kill mid-send. In the
system: each line appears once, on the right job or as the right adjustment.

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
- `StockQuantityTests`: decimal strings to `Decimal` and back without loss; spoken fractions; the
  unit's precision refuses a finer quantity; a whole-number system refuses a fraction.
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
- `StockSystemSinkTests` (P4): read-back before retry; `401`/`403` stop; back-off; survives a
  relaunch; an office-route ceiling ends a queued batch with its sentence and leaves it on the
  record.
- `NetworkRouteRegistryTests`, `PrivacyManifestReconciliationTests`, `DataStoreRegistryTests` and
  the profile secret-disjointness test updated for the new route, store and key.

## Decisions for Greig

1. **Which system first.** *Recommend:* the one the first committed pilot runs, chosen when a pilot
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
8. **Quantities.** *Recommend:* decimal strings kept as `Decimal`, with the unit's precision, in one
   type shared with Plan ML; the phone's own ledger stays whole-number until ML changes it.
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
