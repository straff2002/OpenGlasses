# First-Line Runbooks by Issue Class

Concise triage steps. Stop and escalate if a step is outside the technician's authorization or change-control window.

## Link down

1. Confirm port LED + `show interface` status (admin vs operational).
2. Reseat cable and transceiver at both ends; try a known-good cable/SFP.
3. Check speed/duplex and VLAN/trunk config vs the far end.
4. Move to a known-good port to isolate port vs device.

## Packet loss / intermittent

1. Baseline with continuous ping/`show interface` error counters (CRC, input errors, drops).
2. Rising CRC/input errors → cabling/optic/EMI; rising output drops → congestion.
3. Check duplex mismatch (classic late-collision/CRC signature).
4. Inspect for STP topology changes or a flapping link.

## Slow link / throughput

1. Confirm negotiated speed/duplex matches expectation.
2. Check interface utilization and QoS/policer config.
3. Test path MTU; look for fragmentation.
4. Rule out a single host/app before blaming the network.

## DHCP exhaustion / no IP

1. Confirm client VLAN and that the port is in the right VLAN.
2. Check scope utilization on the DHCP server; look for rogue DHCP.
3. Verify `ip helper-address`/relay on the SVI.

## DNS resolution failure

1. Confirm client DNS servers; test direct query to each.
2. Check forwarders and conditional forwarders on the resolver.
3. Rule out the record vs the resolver (query an authoritative server).
