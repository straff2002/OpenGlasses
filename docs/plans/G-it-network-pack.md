# Plan G — IT / Network Field Assist Pack

**Builds on:** [Plan F](F-field-assist.md) Phase 4. The Field Assist engine (VaultStore, ProcedureRunner, DomainCalcTool, EquipmentLookupTool, SessionExporter, EscalationCoordinator) already ships — this is a **content + one domain-calc** addition, no new infrastructure.

**Strategic fit:** Second B2B vertical. Proves the multi-pack thesis. IT MSPs are a large, well-funded buyer with recurring field/onsite work.

**Effort:** ~1 week (mostly vault content authoring + one domain calc + procedures).

---

## What already exists (reused as-is)

- `VaultStore` / `VaultRegistry` / `VaultManifest` — register a new `it_network` manifest in `VaultRegistry.builtInManifests`.
- `ProcedureRunner` / `ProcedureLibrary` — drop `procedures/*.json` into the pack; the branching schema (`Procedure.swift`) is unchanged.
- `EquipmentLookupTool` — already searches the *active* session's vault, so it works for IT error codes/model lookups with zero changes (voice + camera OCR).
- `SessionExporter`, `EscalateToExpertTool`, `PhotoLogTool` — domain-agnostic, work immediately.

## New work

**Vault** `Sources/Resources/Vaults/it_network/`:
- `manifest.json` equivalent entry in `VaultRegistry` (id `it_network`, gating `field_assist_it`, prompt rules mirroring refrigeration's "never fabricate / cite sources / escalate when unsure").
- `error_codes.md` — Cisco IOS, Aruba, Dell iDRAC, HPE iLO, common switch/router/server fault codes.
- `topology.md` — network topology templates, VLAN conventions, cabling/label color standards.
- `runbooks.md` — per-issue-class first-line checks (link down, packet loss, slow link, DNS, DHCP exhaustion).
- `inventory_schema.md` — server/switch inventory fields the tech should capture.
- `safety.md` — electrical safety in racks/IDFs, ESD, LOTO for PDUs.

**Procedures** `it_network/procedures/`:
- `server_cold_swap.json`, `server_hot_swap.json`
- `network_troubleshoot.json` (branching: link down vs packet loss vs slow)
- `cable_trace.json`
- `firmware_update.json`

**Domain calc** — extend `DomainCalcTool` *or* add `NetworkCalcTool` (cleaner: a sibling tool, registered only when an IT session is active is hard, so make it always-available math):
- `subnet`: CIDR → network/broadcast/usable-host range/count
- `vlan_lookup`: VLAN id ↔ purpose from the vault
- `cable_length`: run-length estimate

*Recommendation:* a new `NetworkCalcTool` (pure math, no vault dependency for subnet/CIDR) rather than overloading `DomainCalcTool`, which is refrigeration-specific.

## Gating

Add an `it_network` case to `VaultRegistry.isUnlocked` (new IAP `field_assist_it`, dev-unlock via `fieldAssistDeveloperUnlocked` like refrigeration until the product is live).

## Build order

1. Register `it_network` manifest + author the 5 markdown files.
2. Author 5 procedures (reuse the refrigeration JSON as a template).
3. `NetworkCalcTool` (subnet/CIDR math) + tests.
4. Add tool descriptions to LLMService + GeminiLive prompts.
5. Settings: the existing `FieldAssistSettingsView` vault picker lists it automatically once registered.

## Open questions

- Subnet math only, or also IPv6? *Recommendation: IPv4 + IPv6 CIDR — both are pure functions, cheap to add.*
- Is the error-code DB defensible to ship, or licensing-sensitive? *Action: use publicly-documented codes only; cite vendor docs.*

## Dependencies

- Plan F engine (shipped). No new infrastructure.
