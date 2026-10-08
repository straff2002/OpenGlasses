# Plan HV — Site and System Vaults (how the units at one site work together)

**Status:** 📝 Drafted 2026-10-08 — nothing implemented. Mostly a vault-authoring feature: a new,
validated kind of vault content that describes how the units at one site are connected and
controlled, and a small phone side that recognises when a job is at that site and tells the model
how the units relate. Office-built vaults need office plan FX14 (vault archive conformance,
private) to accept the new section before they can carry it.
**Track:** Field Assist (B2B).
**Related:** Plan [F](F-field-assist.md) (vaults), Plan [ED](ED-vault-manual-retrieval.md) (the
reference tier), Plan [EG](EG-vault-packs.md) (packs), Plan
[FS](FS-subscriber-vaults-and-vault-links.md) (subscriber vaults and the archive), Plan
[FR](FR-fictional-example-vault.md) (the fictional example vault), Plan
[H](H-custom-vault-import.md) (the validator and importer), Plan
[Q](Q-vault-and-skills-library-management.md) (vault management), Plan
[EL](EL-equipment-identity.md) (equipment identity), Plan [GB](GB-field-test-round-3.md) (several
units on one job), Plan [HT](HT-external-job-references.md) (external equipment identifiers), Plan
[HU](HU-service-history-and-maintenance-flags.md) (history by unit), Plan
[HB](HB-field-assist-mode-and-job-day.md), Plan [FO](FO-guided-job-flow-and-job-tab.md) (the
brief before site), and office plan FX14.

---

## Trigger

The pilot conversation behind [HT](HT-external-job-references.md) and
[HU](HU-service-history-and-maintenance-flags.md) raised a third need. Vaults already hold several
models, and a job can already cover several units. What nothing captures is how the units at one
site **work together**: a furnace, a heat pump and a communicating thermostat that are one system,
where the fault the technician sees on one unit is caused by the link between two of them. An error
on the heat pump because the furnace board dropped off the communication bus is not a heat-pump
fault, and a technician who reads the heat pump's manual will replace the wrong board.

Each unit must keep its own identity and specifications. What is missing is an overlay that joins
them: which units are at the site, how they are connected, which controller commands which, how
they are configured, and which faults are known to come from the interaction.

**The relationships are the content.** A manual describes one unit on its own; nobody writes down
how the units at one site are wired, bussed, plumbed and configured to each other, or which outside
systems they talk to, and that is where the hard faults live. This is not an HVAC need. The same
overlay describes a plant line (PLC, drives, sensors, the fieldbus between them and the historian
above them), a comms room (switches, UPS, environmental monitoring, the management network), a
building (chiller, air handlers, the building management system that schedules them), a dairy
shed (vacuum pump, pulsation controller, milk cooling, the herd-management software) or a solar
installation (inverters, battery, meter, the portal). The vocabulary below is therefore generic,
with the trade-specific detail in free text, and the integrations with systems outside the site
are a first-class part of the document, not a note.

## Outcome

- **A vault may carry site documents**: one structured file per site system, naming its units by
  model (and serial where known), their connections, the control topology, the integrations with
  systems outside the site, the configured settings, and known interaction faults.
- **It works for any trade.** Connection and integration kinds are a generic vocabulary (power,
  control, communication, fluid, data, and so on) with the trade's detail in plain text, so the
  same document shape serves heating, process plant, network rooms, building services or
  agricultural equipment.
- **Each unit stays a distinct unit.** A site document is an overlay that refers to units; it is
  never a merged "unit", never a model section, and never changes how a unit is identified.
- **When a job is at a documented site,** the model is given that site's connections and controls,
  told to consider the link when a fault crosses units, and cites the site document.
- **The technician is told.** The brief and the equipment announcement say "part of the Hillside
  house system, with two other units".
- **Authoring is checked.** The validator refuses a site document whose units the vault does not
  know, whose serials repeat, or whose connections name undeclared units.

## What exists today (verified against main @ 447d35ec)

- **A vault has two tiers.** `VaultManifest.files` is core markdown that `VaultPromptBuilder.promptContext`
  loads whole into every turn. `VaultManifest.documents` (`VaultDocument`: `file`, `title`, `kind`,
  `source`, `sourceUrl`) are chunked into the document store and retrieved per turn by
  `VaultRetriever`. `VaultDocument.kind` is free text and "informational".
- **The core has a budget.** `VaultValidator.coreBudgetCharacters = 32_768`, a warning rather than
  an issue. `VaultPromptBuilder.referenceByteLimit` holds every API provider to that same 32,768
  (ChatGPT to `conservativeChatGPTLimit = 24_000` unless the request context is at least
  `fullCoreMinimumContext = 128_000`), ranking optional core files by the turn and keeping safety
  files whole; omitted files are named and left to `equipment_lookup`.
- **Models are read from headings.** `VaultModelIndex(vaultName:files:)` treats every `##`/`###`
  heading in the core with a model-like token as a model section, with its spellings.
  `EquipmentRecognition.resolve(stated:index:)` matches a stated model `exact`, `alias`, `near` or
  `unmatched`. `EquipmentIdentity` carries `modelToken`, `heading`, `file`, `source`,
  `statedModel`, `vaultMatch`, and `unitKey` (the stated model normalised); `nameplateText` is
  "audit only … never placed in a prompt". It has no serial.
- **Several units on one job are recorded.** `FieldSessionService.setEquipment` starts a new
  continuity scope for a different unit and appends a `VisitedUnit` (its `serial` is passed as nil
  there); `UnitLedger` groups tasks by unit for the record (GB P2). `JobHistoryIndex` reads serials
  from `visitedUnits` and from `identityFields` whose name contains "serial". Nameplate fields are
  EL P3, not started.
- **A job's equipment list stops at the job ahead.** `UpcomingJob.equipment` is `[KnownEquipment]`
  (model, serial); `applyJobAhead` copies site, fault report, brief, provenance and needs onto the
  session, not the equipment list. The brief's `knownEquipment` section resolves each model
  through `VaultModelIndex.match(text:)`.
- **The visit's context.** `FieldSessionContextSnapshot.render` puts protected job lines first
  (`jobFlowLines`, `JobBriefContract.lines` at 1,200 characters, identity fields, open tasks), then
  bounded records (`workingCharacterLimit = 8_000`). Live sessions get `LiveJobContract.block`,
  capped at 1,600 characters.
- **Install copies only what the manifest lists.** `VaultImporter` copies `manifest.files`, the
  `proceduresDir` folder and each document (and its original); `VaultExporter` copies the files and
  procedures. `VaultManifest.init(from:)` ignores keys it does not know, so a new manifest key is
  silently skipped by an older build. `VaultPackCatalogService.installPack` refuses a pack whose
  `documents` is not empty.
- **The example vault is still the real-product one.** `examples/vaults/lennox-slp99` is tracked;
  FR, which replaces it with an invented product line, is drafted and not built.

## Assessment

Three places a site description could live, and two are wrong.

- **A core markdown file** is loaded into every turn whatever the job, so a vault for a business
  with forty documented sites would spend its 32,768-character core on sites the technician is not
  at. Worse, a site file's own `##` headings naming its units would be read by `VaultModelIndex` as
  extra model sections, and the brief would start saying a model "could be any of 2 models".
- **A reference document** (`VaultDocument` with a `kind` of `site_system`) is retrieved by
  similarity, so the topology would reach the model only when the turn's words happened to match
  it, cited by a chunk. A pack cannot carry documents at all. The point of a site document is that
  it is there, whole, exactly when the job is at that site.
- **A dedicated, structured section**, chosen by the job rather than by the turn, is the right
  shape: a `sites` key in the manifest listing JSON files under `sites/`, each validated against the
  vault's own model index, and one rendered block injected only for the matched site. An older
  build ignores the key and installs the rest of the vault unchanged.

Matching must be honest about strength. A serial identifies a unit; a model does not, since the
same model is at many sites.

## Design

### 1 · The site document

`manifest.json` gains `"sites": ["sites/hillside-house.json", …]`. Each file:

```json
{
  "format": "avenkin.site-system", "version": 1,
  "id": "hillside-house", "name": "Hillside house, whole-home system",
  "location_label": "Hillside house", "external_location_ids": ["loc-88412"],
  "units": [
    { "id": "furnace", "model": "AF-80", "serial": "AF80-2201", "label": "basement furnace" },
    { "id": "heatpump", "model": "AH-36", "serial": "AH36-7713", "label": "side-yard heat pump" },
    { "id": "tstat", "model": "AT-9", "label": "hall thermostat", "covered": false } ],
  "connections": [
    { "from": "furnace", "to": "heatpump", "kind": "fluid", "medium": "refrigerant",
      "detail": "3/8 liquid, 3/4 suction line set, about 9 m" },
    { "from": "tstat", "to": "furnace", "kind": "communication", "protocol": "4-wire serial bus",
      "detail": "terminals 1-2-R-C" },
    { "from": "furnace", "to": "heatpump", "kind": "communication", "protocol": "4-wire serial bus",
      "detail": "daisy-chained from the furnace board" } ],
  "controls": [
    { "controller": "tstat", "commands": ["furnace", "heatpump"], "mode": "communicating",
      "detail": "Dual fuel; balance point set at the thermostat" } ],
  "integrations": [
    { "id": "portal", "name": "Manufacturer remote-monitoring portal", "kind": "cloud_portal",
      "units": ["tstat"], "direction": "outbound", "protocol": "Wi-Fi, vendor cloud",
      "detail": "Thermostat reports alerts to the portal; the dealer account sees them. No control from the portal." } ],
  "settings": [
    { "unit": "furnace", "name": "Blower profile", "value": "B", "note": "Set at install for the coil" } ],
  "interaction_faults": [
    { "seen_on": "heatpump", "code": "E77", "link": "communication_bus",
      "text": "Heat pump shows E77 when the furnace board drops off the bus; check the bus at the furnace before the heat pump board." } ],
  "notes": "Install 2024. Outdoor disconnect behind the side gate."
}
```

- **Relationships are typed generically; the trade lives in free text.** `connections[].kind` is
  one of `power`, `control`, `communication`, `data`, `fluid`, `air`, `mechanical`, `other`, with
  optional `medium` (refrigerant, water, steam, milk, compressed air), `protocol` (a fieldbus name,
  a serial bus, Ethernet, a wireless standard) and `direction` (`one_way` from → to, or `two_way`,
  default two-way). `controls[].mode`: `communicating`, `conventional`, `other`.
- **`integrations[]` are the systems outside the site that the units talk to**: a building
  management system, a PLC or SCADA layer, a manufacturer's cloud portal, a network management
  system, a herd- or fleet-management application, a utility meter. Each has `id`, `name`, `kind`
  (`bms`, `scada`, `cloud_portal`, `network_management`, `business_application`, `metering`,
  `other`), the `units` it touches, `direction` (`inbound`, `outbound`, `both`), `protocol` and
  `detail` (what it reads, what it may command, who has the login). An integration is not a unit:
  it has no model, is never the active unit, and never appears in the unit ledger. It is a
  declared endpoint so that `connections` and `interaction_faults` may name it.
- Plain text everywhere, under the job file's `checkText`-style rules (no markup, no control
  characters, length limits per field).
- **A unit is a reference, not a unit record.** Its `model` names a model the vault indexes; its
  specifications stay in that model's own section and manual. `label` is where it is at the site.
- `external_location_ids` and per-unit serials are what lets a job from an FSM (HT) find the site.
  A vault may describe a system type with no serials and no location ids; it then matches only by
  model (§3).

### 2 · Validation (`VaultValidator`, issues unless marked)

- `format`, `version`, `id` (unique in the vault, `safeIdentifier` rules), `name` present.
- Every unit's `model` resolves `exact` or `alias` through `EquipmentRecognition.resolve` against
  the vault's own `VaultModelIndex`, **or** the unit says `"covered": false`, which is how an honest
  out-of-vault component (a thermostat with no section) is told apart from a typo.
- Unit `id`s unique within the document; serials unique within the document **and** across the
  vault's site documents (one serial is one unit in one place).
- Every `connections[].from`/`to`, `controls[].controller`/`commands[]`, `settings[].unit` and
  `interaction_faults[].seen_on` names a declared unit, or (for a connection endpoint or a fault's
  `link`) a declared integration; `from` differs from `to`. `integrations[].units` name declared
  units; integration ids and unit ids share one namespace.
- `connections[].kind` and `integrations[].kind` are from their lists (unknown kinds are an issue,
  so that a typo is not quietly `other`); `medium`, `protocol` and `detail` are free text.
- Bounds: at most 12 units, 8 integrations, 30 connections, 30 settings and 20 interaction faults
  a document; each file at most 8 KiB; at most 100 site documents a vault. A rendered block over its bound (§4) is a
  **warning** naming what will be clipped.
- The file is listed in `sites`, present, and inside `sites/`.

### 3 · Matching a job to a site

`SiteSystemMatcher`, pure over the vault's site documents and what the job knows:

- **Confirmed:** a serial on the job (the job ahead's `equipment`, `identityFields` named serial,
  `visitedUnits`) equals a unit's serial, or HT's `external.location_id` is in a document's
  `external_location_ids`. One document can be confirmed; two confirmed documents is an authoring
  error the validator's serial rule already prevents, and the location id must be unique too.
- **Probable:** no confirmed match, and exactly one document lists every modelled unit the job names.
  Shown and injected with "matched by model only; the serial will confirm it".
- **None:** otherwise, including several probable documents. The brief says "N site systems in
  the vault use this model; the serial will say which", and nothing is injected.
- The match is computed when the brief is assembled, kept on the job ahead as `SiteSystemMatch`
  (site id, vault id, strength, matched unit ids), copied to the session by `applyJobAhead`, and
  recomputed when `setEquipment` or a serial identity field changes it. Every match and change is a
  session log event.
- **No serial from the nameplate text.** `nameplateText` stays audit-only. Matching from a read
  serial waits on EL P3's nameplate fields.

### 4 · What the model is told

- `SiteSystemContract.lines(match:document:)` renders one bounded block in
  `FieldSessionContextSnapshot.render`, beside `JobBriefContract.lines`, at most 1,600 characters:
  `SITE SYSTEM:` with the name and match strength, the units (label, model, serial, and which one
  is the active unit), connections, controls, integrations, settings, and interaction faults, in
  that order of priority when clipped. A connection is rendered as one line, "hall thermostat →
  basement furnace: communication, 4-wire serial bus, terminals 1-2-R-C", so the model reads the
  relationship, not a schema.
- The lede: these units are separate machines with their own manuals; when a symptom on one unit
  may come from a connection or a controller, say so and name the link; cite the site document as
  the vault's source (`sourceAttributionFormat`, with the document's `name` as the file), never as
  a manual page; a probable match is unconfirmed.
- **Outside the vault budget.** The block is not a core file, so it never counts against
  `coreBudgetCharacters` or `referenceByteLimit`, and only the matched site's block is ever sent.
- **Live sessions** get one line in `LiveJobContract.block` ("Site system: Hillside house, 3
  units; ask equipment_lookup for 'site system'"), since its 1,600 characters cannot hold the block,
  and `equipment_lookup` gains a `site system` query that returns the rendered block.
- **Each unit stays itself.** `setEquipment`, `EquipmentIdentity`, `UnitLedger` and the work record
  are unchanged. `EquipmentScopeCheck` still answers for the active unit; the site block is context,
  not a scope.

### 5 · The technician's side

- **Brief:** `knownEquipment` gains one line when a match exists: "Part of the Hillside house
  system, with 2 other units: hall thermostat, side-yard heat pump", cited "vault › site
  Hillside house" and marked unconfirmed when probable.
- **Recognition:** when `setEquipment` records a unit that a matched site lists,
  `EquipmentIdentity.announcement`'s caller in `EquipmentLookupTool` appends "Part of the Hillside
  house system with 2 other units." Once per unit per job.
- **The job's page** shows the site system's name and units under the equipment.

### 6 · Authoring

A new section in `docs/field-assist-vault-guide.md`, "Describing a site system":

- When to write one: units that share controls, a bus, a line set, a network or an outside system,
  in any trade, and reusable system types ("our standard dual-fuel install", "the standard
  three-rack comms room") as well as one customer's site.
- What to write: one file per system; units by the model spelling their section already uses;
  serials when the vault is for one customer's sites, none for a reusable system type; the
  connections a technician would trace, typed generically with the trade's words in the detail;
  the controller; the outside systems the units talk to and who holds their logins; the settings
  someone set on site; the faults the crew has seen come from the link, in plain words.
- What not to write: specifications (they belong to the model's section), customer contact details,
  or anything that is a diagnosis without having been seen.
- **The worked example** above, with invented models, goes into the example vault. FR is not built,
  so P0 adds it to FR's invented product line if FR has landed and otherwise as a test fixture
  vault under `OpenGlassesTests/Fixtures`, never into the real-product example folder.
- **The office.** An office-built archive carries `sites/` like any listed file; FX14's checker
  must accept the `sites` key, apply §2's rules, and list the files in `vault-archive.json`. Until
  it does, office-built vaults do not carry site documents. That is the gate for the office route.
- **Packs.** A sellable pack describes products, not customers' sites; `installPack` refuses a pack
  with `sites` in this plan (open question 2).

### 7 · Install and export

`VaultImporter` copies the listed `sites` files into staging and validates them with the rest;
`VaultExporter` carries them; `VaultStore` gains `siteDocuments()`; the vault manager (Q) shows a
count. Site documents are baseline content only: no phone editor, no overlay.

## Phases (one PR each)

- **P0 — Schema, validator, example, tests (headless).** `SiteSystemDocument`, the manifest key,
  `VaultValidator` rules, importer and exporter copying, `VaultStore.siteDocuments()`, the fixture
  vault, the guide section.
- **P1 — Matching, prompt and attribution.** `SiteSystemMatcher`, `SiteSystemMatch` on the job ahead
  and session, `SiteSystemContract` in the snapshot, the live line, `equipment_lookup`'s query.
- **P2 — Brief and recognition.** The `knownEquipment` line, the announcement, the job's page.
- **Gate for office-built vaults:** FX14 accepts and checks `sites`.
- **Device check owed:** a three-unit dual-fuel site, a job with serials from an office, the bus
  fault asked about at the heat pump, the answer naming the furnace board and citing the site.

## Tests

- `SiteSystemDocumentTests` — the example decodes; every field rule and bound; unknown connection
  kinds and control modes refuse.
- `SiteSystemValidatorTests` — a unit model not in the index refuses; `covered: false` admits it;
  duplicate unit ids, serials within a file and across files, and location ids refuse; dangling
  connection, control, setting and fault references refuse; an over-long render warns; a vault with
  no `sites` validates exactly as before.
- `VaultModelIndexSiteIsolationTests` — installing site documents leaves `VaultModelIndex`, the
  core prompt and `coreBudgetCharacters` accounting unchanged.
- `SiteSystemMatcherTests` — serial confirms; location id confirms; model-only with one candidate
  is probable; several candidates is none; a serial seen mid-job upgrades probable to confirmed and
  logs it.
- `SiteSystemContractTests` — the block's order, lede, clipping priority and 1,600 limit; nothing
  rendered without a match; the live line fits `LiveJobContract.characterLimit`.
- `JobBriefSiteSystemTests` and `EquipmentLookupSiteAnnouncementTests` — the brief line, the
  announcement once per unit, the unconfirmed wording.
- `VaultImporterSiteTests` and `ExampleVaultSiteTests` — listed files copied and exported; a pack
  with `sites` refused; an older-format manifest unchanged.

## Risks

- **A site document out of date.** A replaced board or a changed setting makes the overlay wrong.
  It is cited as the vault's, dated by the vault's version, and is the author's to maintain; HU's
  history is where recent change shows.
- **Model-only matches misleading.** Probable matches are worded as unconfirmed, and several
  candidates inject nothing.
- **Customer data in a vault.** Site documents can identify a customer's premises. Vault exports
  and links carry them; the guide says what not to write, and packs refuse them.

## Out of scope

- Discovering topology automatically, from the camera, the bus or anything else.
- Topology supplied by an FSM. A direction for later: HT's `equipment_ids` and `location_id` and
  HU's per-unit history already name the units at a location, and an office could one day generate
  a site document from the FSM, through FX14, rather than an author writing it.
- Editing site documents on the phone.

## Open questions

1. **One file per site, or a single `sites.json`?** The plan takes one per site for clean diffs
   and per-site bounds.
2. **Packs.** Refuse `sites` in a pack, or allow site *types* without serials or location ids?
3. **A site seen across vaults.** A furnace in a heating vault and a heat pump in another: should a
   site document be allowed to name a unit from another installed vault?
4. **The live route.** One line and a lookup, or a smaller live block when a match is confirmed?
