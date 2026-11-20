# Stock system fixtures: a system without jobs

Synthetic. Every id, name, part number and figure here is invented for the contract
([`Contracts/stock-systems.md`](../../../stock-systems.md)) and describes no real system, business,
product or person. The shape stands for a till or an inventory system with no jobs, which keeps
whole numbers only: used parts go back as adjustments with the organisation's reason.

| File | What it is |
|---|---|
| `input.json` | What a connector hands the phone. The rows are dated, so the snapshot's `asOf` is the oldest date. Prices are enabled. Three rows are dropped: an item id listed twice, a date that is not ISO 8601, and a row with neither part number nor description. |
| `expected-snapshot.json` | The snapshot built from it. A fraction of an `each` and a figure below zero are `known: false` with their reasons, never rounded and never zero. An unreadable price is dropped. A location class the phone does not know reads as `other`. |
| `batch.json` | A day's list confirmed on the screen. It carries another system's job reference, which this system cannot use. |
| `expected-write-plan.json` | Two adjustments (`internal_use`), half a litre not sent because the system keeps whole numbers only, and one line not sent because the system keeps that item in another unit. |

Idempotency keys are SHA-256 hex over `jobID`, the staged line id and the step kind, each followed
by one zero byte.
