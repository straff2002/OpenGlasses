# Stock in a business's own system, draft v1

Where a business already keeps its stock in its own system (a workshop or trade system with jobs,
or a till or inventory system without them), the phone does not keep a second count. It reads the
system's figures into a snapshot and sends back the parts used on a job, once a person has
confirmed them. This contract lists what a phone-side connector may write, so that an
office-side connector, or anyone reading the system's audit trail, can recognise what a phone wrote.
No connector exists yet: the first is built for the first committed pilot. The synthetic fixtures
are in [`fixtures/stock-systems/`](fixtures/stock-systems/): one system with jobs, one without.

## The snapshot

The body of Plan HF's office stock snapshot (`locations`: `id`, `name`, `class`; `lines`: `itemID`,
`part`, `description`, `unit`, `levels`, `provenance`, optional `lineAsOf`, `price`,
`reorderPointScaled`), with a stated `source` (`connector`, `name`, `account`) in place of a
signature and one provenance word, `system`. A level is `onHandScaled`, a non-negative integer in
thousandths of the line's `unit`, under a top-level `quantityScale` that is exactly `3`. Otherwise
the level is `known: false` with a `reason`: `no_count`, `unmapped_unit` (with the `systemUnit`),
`too_many_decimals`, `not_whole`, `negative`, `too_large` or `not_a_number`. A figure the phone
cannot hold exactly is never rounded, and an unknown is never zero. `asOf` (Unix UTC seconds) is
the oldest date the system put on its figures, or the time the pull finished when it dates none.
A snapshot holds at most 20,000 lines. Prices are dropped unless the organisation enables them.

## The only writes

A confirmed batch becomes one entry per staged line, and each entry is exactly one of these:

| Kind | When | What it says |
|---|---|---|
| `job_part_line` | The system has jobs, and the job carries that system's reference | A part line on that job (`externalJobID`), linked to the inventory item (`itemID`), with `quantity` and `unit`. The system takes it out of stock by its own rules. |
| `adjustment` | Any other case | An adjustment out of stock at `locationID` for `itemID`, with `quantity`, `unit`, the organisation's `reason` (`internal_use`, `waste` or `damage`) and, where the system has a note field, the job's number in `note`. |
| `not_sent` | The system does not carry the item, keeps it in another unit, keeps whole numbers only and the quantity is part of one, or no reason is chosen | Nothing is written. The line stays on the phone's record with the `reason` and a sentence. |

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

A verified `organizationFieldServiceRoute=office` ceiling stops every direct stock connector, as it
stops the direct field-service connector: the office connects the system, and the phone reads the
office's stock snapshot.
