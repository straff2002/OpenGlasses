# Stock in a business's own system, draft v1

Where a business already keeps its stock in its own system (a workshop or trade system with jobs,
or a till or inventory system without them), the phone does not keep a second count. It reads the
system's figures into a snapshot and sends back the parts used on a job, once a person has
confirmed them. This contract lists what a phone-side connector may write, so that an
office-side connector, or anyone reading the system's audit trail, can recognise what a phone wrote.
The first adapter is Square's (below), pure and headless: nothing connects to it yet. The synthetic
fixtures are in [`fixtures/stock-systems/`](fixtures/stock-systems/) (one system with jobs, one
without, vendor-neutral) and [`fixtures/square-v2/`](fixtures/square-v2/) (Square's response shapes).

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
| `POST /v2/inventory/counts/batch-retrieve` | `INVENTORY_READ` | The chosen locations' `IN_STOCK` counts, paged |
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
   name) and every request built from them, with no host and no key.
2. **Decoding**: its responses read into the common types (locations, the raw rows the snapshot
   builder takes, a read-back), closed and bounded, with its paging as small pure plans.
3. **Units**: its table onto the phone's closed unit list, with its own tests.
4. **Capabilities**: jobs or not, whole numbers only or not, the reasons it keeps, a note field.
5. **Read-back**: recognising its own writes, by the step's key, and saying when one under the
   key is not the step.

It gets from the common layer, which names no vendor: the request value and its allowed-list check,
the driver that runs a plan, the failure categories with their sentences (which stop retrying and
which back off), the snapshot and its builder, the conversion into the phone's quantities, the join,
the answer sentences, the parts-used write plan and its idempotency keys, the batch key rule and the
write-time rule. Those exist today. Still to be built by the common layer, once, for every system:
the connection in Settings › Field Assist › Stock system and its Keychain storage, the network route
and its pinned-host transport, the snapshot store and the pull triggers, `van_stock` answering from
the system, the staging and the person's confirmation, and the queued sink with its read-back
before retry.

