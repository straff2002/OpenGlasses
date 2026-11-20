# Square fixtures (stock systems)

Synthetic. Every id, name, SKU, figure and key here is invented for the stock-systems contract
([`Contracts/stock-systems.md`](../../stock-systems.md)) and describes no real merchant, location,
product or person. The shapes follow the field names of Square's public API reference; no example
body is copied from it. The phone's Square adapter (`Services/FieldAssist/StockSystem/Square/`) reads
these in `SquareStockAdapterTests` and `SquareRequestGuardTests`.

The fixture pull is for `LOC-FIX-MAIN` and `LOC-FIX-VAN`, finished at 2026-11-20 10:00 UTC, with
prices off and the account label "Fixture Motors".

| File | What it is |
|---|---|
| `locations.json` | `GET /v2/locations`: two chosen locations (physical → `base`, mobile → `van`), one not chosen, one inactive (left out of "Which stock is here?"), one with no id (dropped). |
| `catalog-search-page-1.json`, `-page-2.json` | `POST /v2/catalog/search`, two pages joined by a cursor: measurement units, variations, and the parent items in `related_objects`. A variation with no measurement unit (whole, `each`), one by the litre at precision 2, one by the kilogram at precision 5, a custom "Tin" the phone doesn't keep, a custom "Box" (a pack), a metre at precision 1 tracked only at one location, millilitres (not kept), an untracked variation, a deleted one, one offered only at a location not chosen, an unknown member, and two unreadable variations. |
| `inventory-counts-page-1.json`, `-page-2.json` | `POST /v2/inventory/counts/batch-retrieve`, two pages: `IN_STOCK` counts, a count at a location not chosen, a `WASTE` count (ignored), a five-place figure (unknown, `too_many_decimals`), a count for an object the catalogue doesn't have, and one with a number where a string belongs (dropped). |
| `expected-snapshot.json` | The snapshot those six responses build. |
| `batch.json` | A batch a person confirmed by voice at `LOC-FIX-MAIN`. |
| `expected-write-plan.json` | Its plan with Square's capabilities (`waste`): three adjustments; 0.125 litres and 0.25 metres not sent (more decimal places than Square keeps for those items); grease not sent (Square keeps it in tins); one part Square doesn't carry. |
| `batch-create-success.json` | `POST /v2/inventory/changes/batch-create`, `200`: the three adjustments back with their `reference_id`s. |
| `inventory-changes-page-1.json`, `-page-2.json` | `POST /v2/inventory/changes/batch-retrieve` for the read-back: the first step applied, the second under its key with another amount (a mismatch for a person), the third absent (still to send), a sale, a physical count and an adjustment with no reference (all ignored). |
| `error-*.json` | Error bodies: 401 `ACCESS_TOKEN_EXPIRED`, `ACCESS_TOKEN_REVOKED` and `UNAUTHORIZED`; 403 `INSUFFICIENT_SCOPES`; 429 `RATE_LIMITED`; 400 `INVALID_VALUE` on a field; 500. |

Step keys are `PartsUsedWritePlan`'s: SHA-256 hex over the job id, the staged line id and
`adjustment`, each followed by one zero byte.

## Confirmed from Square's public reference (2026-11-20)

- `GET /v2/locations` (`MERCHANT_PROFILE_READ`); `POST /v2/catalog/search` (`ITEMS_READ`; nested
  types such as `ITEM_VARIATION` must be named in `object_types`; `limit` up to 1,000; with
  `include_related_objects` a variation's parent `ITEM` comes back in `related_objects`);
  `POST /v2/inventory/counts/batch-retrieve` and `POST /v2/inventory/changes/batch-retrieve`
  (`INVENTORY_READ`; `limit` 1–1,000; `cursor` unset on the last page; the changes read takes at
  most 500 `catalog_object_ids` and `types` without `TRANSFER`); `POST
  /v2/inventory/changes/batch-create` (`INVENTORY_WRITE`; `idempotency_key` 1–128 characters; at
  most 100 changes; the response's `changes` list is marked beta).
- Square-Version `2026-07-15` retired `InventoryAdjustment.location_id` and the `TRANSFER` change:
  an adjustment carries `from_location_id` and `to_location_id`, the same location when stock
  leaves in place. The adapter pins that version. The same release added adjustment reasons
  (`reason_id`, beta); the adapter does not use them.
- `InventoryAdjustment`: `reference_id` up to 255 characters; `quantity` a decimal string with up to
  five places; `occurred_at` RFC 3339 and, the reference says, not more than 24 hours old.
- `CatalogMeasurementUnit.precision`: 0–5, default 3 (0 is whole numbers). The standard unit enums
  include `METRIC_LITER`, `METRIC_METER`, `IMPERIAL_FOOT`, `METRIC_KILOGRAM`, `IMPERIAL_POUND`, and
  the generic `UNIT`.
- `ItemVariationLocationOverrides`: `track_inventory` overrides the variation's; with neither set,
  tracking is off. `inventory_alert_threshold` is an integer, with `inventory_alert_type`
  `LOW_QUANTITY`.
- Errors: `{"errors":[{"category","code","detail","field"}]}`; 401 for `UNAUTHORIZED`,
  `ACCESS_TOKEN_EXPIRED` and `ACCESS_TOKEN_REVOKED`; 403 for `INSUFFICIENT_SCOPES` (no scope named);
  429 for `RATE_LIMITED`, with exponential back-off advised.
- Hosts: `connect.squareup.com`, sandbox `connect.squareupsandbox.com`; a bearer token.

## Not yet confirmed against a live account (owed in qualification)

- Whether a 429 carries `Retry-After` (the reference doesn't say; the adapter reads whole seconds
  when present, else the common back-off).
- How `include_related_objects` behaves across pages: whether a parent `ITEM` always arrives on the
  same page as its variation, and whether measurement units also come as related objects (the
  adapter names `MEASUREMENT_UNIT` in `object_types` so it needs neither).
- The precision default when `precision` is absent, and how counts for a precision-0 unit are
  spelled (`"3"` or `"3.00000"`).
- `present_at_all_locations` treated as `true` when absent.
- A tracked variation that has never moved: whether it has an `IN_STOCK` count of `"0"` or none
  (none reads as unknown, never zero).
- `occurred_at`'s exact window (the adapter sends the confirmation time while it is under 23
  hours old, otherwise the send time).
- `updated_after` on the changes read: whether it compares `created_at` or `calculated_at`, and
  that a five-minute margin before the queued time finds every adjustment sent.
- Square-Version behaviour: that `2026-07-15` accepts `from_location_id`/`to_location_id` on
  `ADJUSTMENT` and returns them on the changes read, and that a request with a different body
  under a reused `idempotency_key` is refused (`IDEMPOTENCY_KEY_REUSED`), which the adapter maps to
  a terminal rejection.
- That the batch-create `200` always lists `changes` (beta); when it doesn't, the adapter treats
  the outcome as uncertain and the sink reads back first.
- A personal access token's scopes, and which scopes OAuth needs for a seller's own account.
