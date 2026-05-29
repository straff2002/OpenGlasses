# Safety — Racks, IDFs & Server Rooms

## Electrical

- Treat PDUs and power feeds as live. LOTO before servicing a PDU or hardwired circuit.
- Servers often have **dual power feeds** — pulling one PSU does not de-energize the chassis.
- Never daisy-chain power strips; respect circuit/PDU load limits.

## ESD

- Wear a grounded wrist strap when handling DIMMs, cards, or drives.
- Keep components in anti-static bags until install.

## Physical / environmental

- Rack stability: extend only one heavy device at a time; use the anti-tip foot.
- Mind hot-aisle temperatures and sharp rails.
- Fiber: never look into an active fiber or laser port.

## Change control (operational safety)

- Confirm an approved maintenance window before any disruptive action: reboot, failover, firmware update, cable removal on a live trunk.
- Have a rollback plan and console/out-of-band access before changing remote-reachability config.
- If an action risks an outage outside the window, **stop and escalate**.
