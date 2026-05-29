# IT / Network Error & Fault Reference

Common fault indicators across enterprise network and server gear. Always confirm against the device's own service manual and current vendor documentation.

## Cisco IOS / IOS-XE (switches, routers)

| Indicator | Meaning | First-line check |
|-----------|---------|-----------------|
| `%LINK-3-UPDOWN` interface down | Physical/link-layer down | Cable, SFP seating, port config, far-end status |
| `%LINEPROTO-5-UPDOWN` line proto down (link up) | L1 up, L2 down | Duplex/speed mismatch, encapsulation, keepalives |
| `%PLATFORM_THERMAL` over-temp | Thermal alarm | Airflow, fan trays, intake temp, dust |
| `%SYS-2-MALLOCFAIL` | Memory exhaustion | Process leak, oversized tables, reload window |
| STP `BLK`/loop guard | Spanning-tree block / loop | Topology change, redundant link, BPDU guard |

## Aruba (ArubaOS-CX / controllers)

| Indicator | Meaning | First-line check |
|-----------|---------|-----------------|
| Port `down/down` | Link down | Cable/transceiver, `interface` admin state |
| PoE `denied`/`fault` | PoE budget or fault | Power budget, class, faulty PD/cable |
| AP `down` on controller | AP unreachable | Switch port/PoE, VLAN, controller reachability |

## Dell iDRAC (servers)

| Indicator | Meaning | First-line check |
|-----------|---------|-----------------|
| Amber system health | Hardware fault present | iDRAC → System → check faulted component |
| `PSU` redundancy lost | PSU failure/unplugged | Both feeds, PSU LEDs, reseat |
| `DIMM` correctable/uncorrectable ECC | Memory errors | Identify DIMM slot, reseat/replace |
| Drive `Failed`/`Foreign` | Disk/RAID issue | RAID controller, drive LED, import/clear foreign config |

## HPE iLO (servers)

| Indicator | Meaning | First-line check |
|-----------|---------|-----------------|
| Health LED amber/red | Degraded/critical | iLO → Information → System Health |
| Fan `Failed` | Fan fault | Reseat fan, check zone, intake temp |
| Smart Storage Battery fault | Cache battery | Replace; write cache may be disabled meanwhile |

## General response protocol

1. Have the technician read the exact code/LED state and the device model.
2. Identify the layer: physical (cable/optic/power), link (speed/duplex/VLAN), network (routing/IP), or platform (thermal/memory/disk).
3. Cross-reference `runbooks.md` for the matching issue class.
4. Confirm change-control approval before any disruptive remediation (see `safety.md`).
