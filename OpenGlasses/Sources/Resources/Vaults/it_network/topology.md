# Topology, VLAN & Cabling Conventions

Templates and conventions for documenting and reasoning about a site's network. Confirm the customer's actual standards on arrival — these are common defaults, not universal truths.

## Three-tier reference

- **Core** — high-speed L3 backbone; redundant, rarely touched.
- **Distribution/Aggregation** — L3 boundary, inter-VLAN routing, policy.
- **Access** — edge ports for endpoints, APs, phones, PoE.

## Common VLAN scheme (verify per site)

| VLAN | Purpose |
|------|---------|
| 1 | Default — avoid using for production |
| 10 | Data / workstations |
| 20 | Voice (VoIP phones) |
| 30 | Wireless clients |
| 40 | Servers |
| 99 | Management |
| 666 | Quarantine / NAC remediation |

## Cable color conventions (common)

| Color | Typical use |
|-------|-------------|
| Blue | Data / general |
| Red | Secure / firewalled / DMZ |
| Yellow | Management / out-of-band |
| Green | VoIP |
| White/Grey | Uplinks / trunks |
| Orange | Crossover / legacy |

## Labeling

- Patch labels: `{IDF}-{rack}-{panel}-{port}` ↔ `{switch}-{port}`.
- Always label both ends; record in `inventory_schema.md`.
