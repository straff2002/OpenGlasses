# Stock in a business's own system, draft v1

Where a business already keeps its stock in its own system (a workshop or trade system with jobs,
or a till or inventory system without them), the phone does not keep a second count. It reads the
system's figures into a snapshot and sends back the parts used on a job, once a person has
confirmed them. This contract lists what a phone-side connector may write, so that an
office-side connector, or anyone reading the system's audit trail, can recognise what a phone wrote.
The first adapter is Square's (below); since Plan MM P2 a phone can connect to it from Settings and
read its stock, since P3 `van_stock` answers from it and notes parts used on the phone, and since
P4 the noted parts go to it once a person confirms them, through the offline queue (below). The synthetic fixtures are in
[`fixtures/stock-systems/`](fixtures/stock-systems/) (one system with jobs, one without,
vendor-neutral) and [`fixtures/square-v2/`](fixtures/square-v2/) (Square's response shapes).

## The snapshot

The body of Plan HF's office stock snapshot (`locations`: `id`, `name`, `class`; `lines`: `itemID`,
`part`, `description`, `unit`, `levels`, `provenance`, optional `lineAsOf`, `price`,
`reorderPointScaled`, `decimalPlaces`), with a stated `source` (`connector`, `name`, `account`) in place of a
signature and one provenance word, `system`. A level is `onHandScaled`, a non-negative integer in
thousandths of the line's `unit`, under a top-level `quantityScale` that is exactly `3`. Otherwise
the level is `known: false` with a `reason`: `no_count`, `unmapped_unit` (with the `systemUnit`),
`too_many_decimals`, `not_whole`, `negative`, `too_large` or `not_a_number`. A figure the phone
cannot hold exactly is never rounded, and an unknown is never zero. `asOf` (Unix UTC seconds) is
the oldest date the system put on its figures, or the time the pull finished when it dates none.
A snapshot holds at most 20,000 lines. Prices are dropped unless the organisation enables them.
`decimalPlaces`, when present, is the most decimal places the system keeps for that item (an integer
0–9; anything else is dropped on decode, never trusted). Absent, or three or more, is no limit beyond
the phone's own scale of three.

## The only writes

A confirmed batch becomes one entry per staged line, and each entry is exactly one of these:

| Kind | When | What it says |
|---|---|---|
| `job_part_line` | The system has jobs, and the job carries that system's reference | A part line on that job (`externalJobID`), linked to the inventory item (`itemID`), with `quantity` and `unit`. The system takes it out of stock by its own rules. |
| `adjustment` | Any other case | An adjustment out of stock at `locationID` for `itemID`, with `quantity`, `unit`, the organisation's `reason` (`internal_use`, `waste` or `damage`) and, where the system has a note field, the job's number in `note`. |
| `not_sent` | The system does not carry the item (`not_carried`), keeps it in another unit (`unit_not_kept`), keeps whole numbers only and the quantity is part of one (`fractional`), keeps the item to fewer decimal places than the quantity has (`too_many_decimals`), the amount is out of range (`out_of_range`), or no reason is chosen (`no_reason`) | Nothing is written. The line stays on the phone's record with the `reason` and a sentence. A quantity is never rounded to fit. |

A line is never both a part line and an adjustment. `quantity` is the decimal text of the amount
(`"0.5"`, `"2"`): `.` as the separator, no exponent, no grouping, no trailing zeros.

**A connector never writes** a physical count, a set level, a sale, a price or cost, a new or
edited catalogue item, unit, bin or reorder point, a transfer, an order, or a change to a job's
status. The phone has no way to express any of them.

## Delivered once

Every write carries an **idempotency key**: lower-case SHA-256 hex over the UTF-8 bytes of the
phone's job id, the staged line id and the step kind (`job_part_line` or `adjustment`), each
followed by one zero byte. The same batch always gives the same keys. A connector sends the key
in the system's own idempotency or reference field where the system has one.

**Read back before retry.** After an uncertain outcome (a timeout, a dropped connection, a server
error) the connector reads the job's part lines, or the adjustments since the batch was queued,
and sends only the steps whose keys it does not find. It never resends a whole batch blindly. A
`401` or `403` stops retrying and says what to fix; a `429` or `5xx` backs off.

A write under a step's key that is not that step (another item, location, amount or kind of
movement, or the key twice) is neither trusted as applied nor sent again: it waits for a person.

A verified `organizationFieldServiceRoute=office` ceiling stops every direct stock connector, as it
stops the direct field-service connector: the office connects the system, and the phone reads the
office's stock snapshot.

## Square

A system without jobs. Square-Version `2026-07-15` is pinned on every request; hosts
`connect.squareup.com` and, for a test account, `connect.squareupsandbox.com`; a bearer token. What
is confirmed from Square's public reference and what is still to confirm against a live account is
in [`fixtures/square-v2/README.md`](fixtures/square-v2/README.md).

| Endpoint | Permission | Used for |
|---|---|---|
| `GET /v2/locations` | `MERCHANT_PROFILE_READ` | "Which stock is here?" (active locations), and naming the chosen ones in a pull |
| `POST /v2/catalog/search` | `ITEMS_READ` | `ITEM_VARIATION` and `MEASUREMENT_UNIT` objects with related objects (the parent `ITEM`), paged |
| `POST /v2/inventory/counts/batch-retrieve` | `INVENTORY_READ` | The chosen locations' `IN_STOCK` counts, paged; and a check's few lines: the same read with `catalog_object_ids` (at most 100), paged |
| `POST /v2/inventory/changes/batch-retrieve` | `INVENTORY_READ` | The read-back: `ADJUSTMENT`s at the location, for at most 500 items at a time, since five minutes before the batch was queued, paged |
| `POST /v2/inventory/changes/batch-create` | `INVENTORY_WRITE` | The one write |

A line is one item variation tracked at a chosen location: `itemID` is the variation's id, `part`
its `sku`, `description` the item's name and the variation's when it adds something. A variation
with no measurement unit is `each` with `decimalPlaces` 0; a measurement unit's `precision` is its
`decimalPlaces` (3 when unset). Units map only onto the phone's own (litre, metre, foot, kilogram,
pound, and Square's generic unit as `each`), and a custom unit only by an exact each or pack word;
nothing is converted. Deleted, untracked and not-offered-here variations are left out. The reorder
point is the `LOW_QUANTITY` alert threshold when every chosen location says the same.

**The write.** Each `adjustment` step is one change, at most 100 per request:
`{"type":"ADJUSTMENT","adjustment":{"reference_id","catalog_object_id","from_state":"IN_STOCK",
"to_state":"WASTE","from_location_id","to_location_id","quantity","occurred_at"}}`, with the same
location on both sides. `reference_id` is the step's idempotency key above. The request's
`idempotency_key` is lower-case SHA-256 hex over the request's step keys, sorted, each followed by one
zero byte, so a rebuilt request for the same steps carries the same key. `occurred_at` is when the
person confirmed the batch, or the time of sending once that is more than 23 hours old (Square
refuses one older than 24 hours). The only reason Square takes is `waste`; it has no note field
(`reference_id` carries the key). A `200` must list every change back under its `reference_id`;
anything less is uncertain and is read back before any retry.

## Adding a stock system

A new system is a thin adapter in its own folder under `Services/FieldAssist/StockSystem/`,
conforming to `StockSystemAdapter`. It supplies five things, and only these:

1. **Requests**: its endpoints as a closed list (method, path, purpose, the system's permission
   name) and every request built from them, with no host and no key; its hosts (production and,
   where it has one, a sandbox); the most bytes a reply may be; and Test connection's smallest
   reads (a page of one of each kind the snapshot needs besides the locations).
2. **Decoding**: its responses read into the common types (locations, the raw rows the snapshot
   builder takes, a read-back), closed and bounded, with its paging as small pure plans.
3. **Units**: its table onto the phone's closed unit list, with its own tests.
4. **Capabilities**: jobs or not, whole numbers only or not, the reasons it keeps, a note field.
5. **Read-back**: recognising its own writes, by the step's key, and saying when one under the
   key is not the step.

Among its reads is **a check's few lines** (`linesPlan(itemIDs:locationIDs:)`, Plan MM P3): the
current figures for just the asked-about items at the chosen locations, on its stock endpoint, as
the system's own decimal text by item and location. A `check` asks for it when the snapshot's
figures for those items are older than ten minutes and there is signal, and waits at most three
seconds; the common layer merges the reply into the stored snapshot (only those lines' figures and
their `lineAsOf`; the snapshot's `asOf` stays the pull's), and a reply after the budget only
refreshes the store. A connector without one falls back to a whole pull.

It gets from the common layer, which names no vendor: the request value and its allowed-list check,
the driver that runs a plan, the failure categories with their sentences (which stop retrying and
which back off), the snapshot and its builder, the conversion into the phone's quantities, the join,
the answer sentences, the parts-used write plan and its idempotency keys, the batch key rule and the
write-time rule, and (since P2) the connection in Settings › Field Assist › Stock system with its
device-only Keychain item, the pinned-host transport, the connector that drives any adapter, the
snapshot store and the pull triggers, and (since P3) `van_stock` answering from the system with
the check-now merge, and the parts noted on the phone per job or premises day, and (since P4) the
person's confirmation, the queued sink with its read-back before retry, the job's states and the
record's members.

Beside its folder, a new system needs only: one `NetworkRoute` case (its purpose, `credential` and
`promptText`, blocked under Medical Local Only, owned by `URLSessionStockSystemTransport`), one entry
in `StockSystem/Registry/StockSystemAdapterRegistry.swift` (the adapter, the route, what the system
calls its key and where it is made), and its row in the privacy copy. Nothing else in the common
layer changes.

## The connection on the phone

One device-only Keychain item per system (`stockSystemConnection.<connector>`,
`…AfterFirstUnlockThisDeviceOnly`) holds the key and every choice: the environment (the business's
account or a sandbox), the locations that are this place, sending back on or off, the reason, and
an optional external user id for a system with jobs. A profile may switch the connection off
(`stockSystemEnabled`), choose the system (`stockSystemConnector`), and set sending back
(`stockSystemSendBack`) and the reason (`stockSystemAdjustmentReason`), each locking its control. It
never carries a key. Every request goes to the adapter's pinned host for the chosen environment over
HTTPS, for an endpoint on the adapter's list, with the key added as a bearer header by the
transport alone; redirects are refused and the reply is capped at the adapter's size. The last good
snapshot per system is kept outside vault content and out of backup, and a new one replaces it
only once written. Test connection reads only.

## Parts noted, not yet sent (Plan MM P3)

While a system holds the place's count, a `use` (or a `remove` for a reason the system keeps) is
noted on the phone as a staged line and nothing is written anywhere: the system's figure does not
change, and the phone's own list is kept read-only as the previous list. Each staged line carries
its scope (`job:<session id>`, or at premises with no job open `day:<yyyy-MM-dd>` in the phone's
calendar), the job's number, the connector, the system's location it came from, the staged use
(its id, the system's `itemID`, `part`, `description`, quantity in thousandths and `unit`,
verification against the book, `source`), the write-off reason where there is one, when it was
noted and the call that noted it. A quantity the item cannot take is refused before it is noted, by
the same rules as `not_sent` above. One file on the phone, out of backup; kept when a snapshot is
retired and cleared when the phone leaves its organisation. Confirming and sending them is P4's
(below).



## Confirmed and sent (Plan MM P4)

**A person confirms, one yes per batch.** At a job's close the parts noted on it are read back
once: *"Two parts used on this job: one Run capacitor 45/5, half a litre of Coolant. Send them to
<system>?"* By voice the app puts that question itself at the end of the turn and reads the
person's own plain yes or no before the model hears anything; the close waits for it and then
finishes. On the screen the parts step shows the same lines, each with a stepper that moves only by
what the item takes (its unit, and the system's `decimalPlaces`; never to nothing), and one Send.
At premises with no job open, the day's list is confirmed the same way from the Stock screen. No
is kept: the lines stay on the job, noted and unsent, until someone sends or discards them. No
tool and no agent path can confirm or send (`StockSystemConfirmationGuardTests`). Sending is not
offered while sending back is off, Medical Local Only holds the route, the office posts stock, or
the system is not connected: the job's noted lines then go on its record as `not_sent` with that
reason when it closes. **The reason sent** is the one chosen when the system keeps it; otherwise,
when the system keeps exactly one reason, that one; otherwise none. A reason the profile locked is
never replaced. Turning sending back on in Settings stores the reason Settings shows. With no reason
(the system keeps several and none is chosen, or the profile locked one it does not keep), sending
is not offered for lines that need one — part lines on the system's own job do not — and the lines
are **not** settled at the close: they stay noted on the job, waiting to send, until a reason is
chosen.

**The queued batch.** One offline-queue item (`stockSystemParts`) per batch — one location and one
reason — holding the write plan (`PartsUsedWritePlan`, Codable), the connector id, the system's
name, the scope, when the person confirmed it and when it was queued, and how far delivery has
got: the keys applied, the keys found on a different write, whether the last write's outcome is
uncertain, the key generation a `401`/`403` came back for, the next try's time, and a terminal
failure or ending. **Never the key**: the connection is read from the Keychain at delivery. It
survives a relaunch, and one sink delivers every system's batches through the connector the
registry names.

**Delivery.** A write is marked uncertain before it is sent. After an uncertain outcome (a
timeout, a dropped connection, a `5xx`, a reply the phone cannot read, or a kill mid-send) the
next attempt reads back first and sends only the steps whose keys the system does not show; a
step under a key on a different write is `needs_attention` and never resent. `401`/`403` stop
with the failure's sentence until a new key is saved. `429` waits for `Retry-After` when given,
else the back-off (30 s doubling, at most an hour); a `5xx` backs off; no signal waits without
counting an attempt. `MedicalEgressGuard` runs before every request, retries included.
`occurred_at` is the confirmation time, clamped as above. The office route arriving, or the
connection being removed, ends a queued batch with its sentence and leaves its lines on the
record as `not_sent` (`office_route`, `disconnected`) for the office to post. After a send the
figures are pulled again (one pull at a time); until a newer figure arrives, a `check` says the
use is still being sent.

**The job's states.** *Sent to <system>*, *Waiting for a connection*, *Needs attention — <the
sentence>*, *N parts not sent to <system>* (noted, not confirmed), and *N not sent: <reason>*,
on the job's row, its page and the parts step.

**On the record.** Each line is a `van_stock` line with `itemID`, `delivery` (`staged`,
`queued`, `sent`, `not_sent`, `needs_attention`) and, for the last two, `deliveryReason`; the
record names the system in `van_stock_system` (`connector`, `name`). See
[`office-reports.md`](office-reports.md), "Parts for a business's own stock system". A line that
was sent, or kept on the phone for good, stays on the phone for 30 days after it settled.
