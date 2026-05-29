# Inventory Capture Schema

Fields to record when documenting a device during a visit. Use `photo_log` to capture nameplates/serials and `field_session` to attach them to the audit log.

## Per device

- Hostname
- Make / model
- Serial number / service tag
- Rack location (IDF, rack, U-position)
- Management IP (and VLAN)
- Firmware / OS version
- Uplink(s): local port ↔ far-end device/port
- Power: PDU + outlet, redundant feed?
- Warranty / support contract reference

## Per cable run (when tracing)

- A-end label / device / port
- B-end label / device / port
- Color / type (Cat6, OM4, etc.)
- Length (see cable-length calc)
