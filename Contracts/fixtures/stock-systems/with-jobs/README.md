# Stock system fixtures: a system with jobs

Synthetic. Every id, name, part number and figure here is invented for the contract
([`Contracts/stock-systems.md`](../../../stock-systems.md)) and describes no real system, business,
product or person. The shape stands for a garage or trade system that has jobs: used parts go on
the system's own job as part lines.

| File | What it is |
|---|---|
| `input.json` | What a connector hands the phone: the source, the pull time, its unit map, its declared capabilities, the system's locations and the connector-normalised rows (all strings). One row has no item id and is dropped. |
| `expected-snapshot.json` | The snapshot built from it, as the phone stores it: `onHandScaled` under `quantityScale` 3, `known: false` with a reason where the figure cannot be held exactly (more decimal places than three, a unit the phone does not keep, no figure). Prices are off, so none is kept. |
| `batch.json` | A batch a person confirmed at job close, with the job's reference in this system. |
| `expected-write-plan.json` | The writes that batch becomes: two part lines on job `WO-77`, and one line the system does not carry, kept on the phone and not sent. |

Idempotency keys are SHA-256 hex over `jobID`, the staged line id and the step kind, each followed
by one zero byte.
