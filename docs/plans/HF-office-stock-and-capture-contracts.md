# Plan HF — Office Stock and Capture Contracts (parts stock between the phone and Avenkin Office)

**Status:** 📝 Drafted (not scheduled), 2026-10-02 — nothing built.
**Depends on:** Plan [FX](FX-desktop-office-and-device-sync.md)'s next milestone (a physical
main-app pairing, then one signed job and one signed manual with an exact receipt — **no production
managed folder is enabled today**, so nothing in this plan can be delivered until that lands);
Plan [EM](EM-work-record-and-parts.md) P1 (shipped: `VaultPartsIndex`, `PartsRequest`, the work
record); Plan [T](T-offline-field-queue-and-sync.md) (the offline queue, for capture messages).
**Related:** [`Contracts/README.md`](../../Contracts/README.md) (the signed-contract style this
plan follows), Plan [GF](GF-recipe-add-ons.md) (add-ons, which this is deliberately *not*),
Plan [GE](GE-automatic-offline-handoff.md) (offline tool classification),
Plan [CT](CT-org-configuration-profiles.md) (organisation profile and office authority),
Plan [BL](BL-ops-platform-agent-bridge.md) (the bridge to the external operations platform),
Plan [HG](HG-add-on-catalogue-and-premium-gating.md) (connectors for systems outside Office).

---

## Trigger

EM's own risk section says it: "a parts index cannot know stock … Stock is base's answer." Today
that answer is a message somebody types back. A technician who asks "have we got a 14T65?" gets
the part verified against the book and nothing about whether one is on the shelf or on the van.

GF's revision (2026-10-02) rules out the obvious shortcut. Add-ons do not reach private or LAN
addresses, and Avenkin Office exposes no HTTP surface to the phone: FX replaced HTTP delivery with
signed messages over the embedded sync transport. So stock from the firm's own Office is a wire
contract between two paired devices, not an add-on.

## Outcome

- The technician asks and hears an answer that is local, works with no signal, and always says
  how old it is: *"Two at base, as of 10:40. None recorded on your van."*
- An unknown is spoken as unknown. *"Some at base, quantity not counted"* and *"that part number
  isn't verified against the manuals"* are valid answers; an invented count never is.
- The phone is a **source as well as a reader**. What was used and requested on a job goes back
  with the work record, and a technician can send what they see — a photo of a shelf, a delivery
  docket, a dictated count — to Office's inbox as a proposal for a person to accept.
- A managed job can arrive with a readiness note: which likely-needed parts are on hand, where,
  and which are short.
- No vendor server is involved at any point. Everything is local first.

## Product boundary (settled)

**Avenkin Office is the system of record for one firm's parts inventory.** It keeps an
append-only **movements ledger** — received, issued to a job, moved between locations such as base
and vans, returned, adjusted — and derives levels from it. Every row carries provenance: its
source, an as-of time, and whether the figure was counted or inferred.

Around the ledger Office has two things this plan relies on but does not specify:

- an **intake inbox**: anything in — a photo of a handwritten note, a spreadsheet, an invoice, a
  delivery docket, a voice note, a shelf seen through the glasses — becomes a *proposal* that a
  person accepts. Nothing writes the ledger directly;
- an **agentic review**: job readiness, reorder, supersession, dead stock, repeat failures and data
  quality, producing findings for a person to approve. It never orders anything.

The ledger, the inbox, the review, and all Office UI and persistence belong to the private Office
repository and are specified there. This plan states them only as context and as what the contract
assumes. It owns the phone behaviour and the shared wire contract.

Office covers one firm's jobs, manuals and stock, with rough-input intake, and is the step into
the external operations platform. Cross-domain, multi-site and live enterprise connectors belong
to that platform, not to Office and not to this plan.

## What exists today (verified 2026-10-02)

- **Office sync foundations** in `Services/OfficeSync/`: `OfficePeerBinding`
  (`Avenkin.OfficePeerBinding.v1`), `OfficeManualAssignment` (`Avenkin.ManualAssignment.v1`),
  `OfficeManagedJob` (`Avenkin.ManagedJob.v1`; envelope cap 131,072 bytes, job cap 65,536 bytes,
  integers ≤ 2^53 − 1), `OfficePhoneIdentity` (`Avenkin.PhonePossession.v1`),
  `OfficePairingService`, `OfficeApprovedPeerStore`, `OfficePeerHighWaterStore` (an actor that
  retains the accepted generation and refuses rollback or a same-generation conflict),
  `OfficeTransportIdentity`, `OfficeSetupPackage`, `OfficeInlineEntitlement`, `OfficeManualImport`,
  `OfficeManualVaultHandoff`. The closed flat-JSON check (`OfficeManualAssignment.flatObject`)
  and identifier rule (`safeIdentifier`) are already shared by the binding and job verifiers.
- **These are verification contracts, not a delivery flow.** `Contracts/README.md` is explicit: no
  managed folder, durable job high-water or commit, **receipt**, office job-signing key or phone UI
  caller is enabled. There is no receipt type in `Services/OfficeSync/` yet; FX specifies one.
- **Parts on the phone:** `Services/Vault/VaultPartsIndex.swift` (pure over core files; `Part`
  has `number`, `partDescription`, `fits`, `supersedes`, `file`, `heading`; `part(number:)`,
  `knownPartNumbers`, `normalise`). `Services/FieldAssist/WorkTask.swift` has `TaskPart` (`number`,
  `partDescription`, `verified`, `page`), `PartsRequest` (`quantity`, `taskId`, `modelToken`,
  `urgency`, `onVan`, `status` `requested`/`sent`/`answered`, `baseAnswer`) and
  `DeviceIdentityField`. `Services/FieldAssist/WorkRecord.swift` carries `tasks`, `partsRequests`,
  `equipment`, `identityFields`. `NativeTools/PartsRequestTool.swift` is the `parts_request` tool.
- **Parts used are not a separate list.** The record has parts on tasks (`TaskPart`) and parts
  requested (`PartsRequest`); "used" is a part on a task that finished `done`. HF P0 pins that
  mapping rather than assuming a field.
- **Offline queue:** `Services/Offline/` — `OfflineQueue`, `QueuedOp` with `OpKind`
  (`logEntry`, `photoUpload`, `clipUpload`, `llmGrounding`, `auditExport`, `captureRecord`,
  `workRecord`, `partsRequest`, `subjectErasure`), `SyncSink`, `EndpointSyncSink`. Plan T's header
  notes the office sink FX plans is not yet supplied by this queue.
- **Offline classification:** `Services/Offline/Handoff/OfflineToolPolicy.swift` —
  `Availability` is `local` / `degraded` / `needsNetwork`; `parts_request` is `degraded`,
  `equipment_lookup` is `local`.
- **Stills:** `CameraService.filteredStill(for:source:)` (`Services/Vision/FilteredStill.swift`)
  returns a filtered still or `.unavailable`, never source pixels. `PrivacyFilterScope` has
  `liveSession`, `directModelTurn`, `pinnedFrame`, `agentAttachment`, `faceRecognition`; there is
  no scope for an Office capture. `OutboundFrameConsumer` is the enforced roster.
- **Medical modes:** `MedicalEgressGuard` (`Services/Security/`) with `hipaaMode` and `localOnly`.
- **Organisation policy:** `Services/OrgProfile/SettingKey.swift` has no stock or capture key.
- **Real-time channel:** the app links WebRTC (`project.base.yml`); nothing uses it with Office.

## The contracts

Four message kinds, each in the style `Contracts/README.md` already fixes: a JSON envelope with
base64 `payload` and `signature`; Ed25519 over the domain string, one zero byte, then the exact
decoded payload bytes; closed, flat JSON (duplicate or unknown keys, nested values and
fractional or exponent integer spellings refused); identifiers and integer bounds as in the
existing contracts; the verifier's key supplied by the caller from the freshly rechecked
vendor-rooted binding, never by the message. Every payload carries `version`, `kind`,
`messageID`, `organizationID`, `enrolmentID`, `officeID`, `generation`, both transport identities,
`sequence`, `issuedAt` and `expiresAt`, exactly as `OfficeManagedJob.Payload` does.

Because payloads are flat, anything with rows (stock lines, readiness lines, attachments) is a
separate **body file** named by digest and byte count in the signed payload, the way a managed job
names its `.ogjob`. The body has its own closed schema and is checked for exact length and SHA-256
before it is parsed.

| # | Kind | Direction | Domain string | Signed by |
|---|---|---|---|---|
| 1 | Stock snapshot | Office → phone | `Avenkin.StockSnapshot.v1` | office application key |
| 2 | Capture message | phone → Office | `Avenkin.StockCapture.v1` | phone application key |
| 3 | Job readiness note | Office → phone | `Avenkin.JobReadiness.v1` | office application key |
| 4 | Stock query / answer | phone → Office → phone | `Avenkin.StockQuery.v1`, `Avenkin.StockAnswer.v1` | phone key / office key |

Each domain is separate from profiles, bindings, assignments, jobs and receipts, so a signature
for one kind can never be replayed as another.

### 1 · Stock snapshot

Payload adds `snapshotID`, `asOf` (Unix UTC seconds: when Office derived the levels),
`bodySHA256`, `bodyBytes`, `lineCount`, `locationCount`. Envelope ≤ 32 KiB; body ≤ 4 MiB and
≤ 20,000 lines (proposed; Decision 2).

Body: a `locations` array (`id`, `name`, `class` — `base` / `van` / `site` / `other`, and whether
it is this phone's own van) and a `lines` array. Each line:

| Field | Meaning |
|---|---|
| `part` | Part number as Office holds it |
| `description` | Short text |
| `unit` | `each`, `m`, `kg`, `l`, … (closed list) |
| `levels` | Per location: `onHand` as an integer, **or absent with `known: false`** |
| `provenance` | `counted`, `inferred` (derived from movements since the last count) or `declared` (entered from a document, never counted) |
| `lineAsOf` | Optional; when this line's figure was last established, if older than the snapshot |
| `supersededBy` | Optional; Office's view, kept apart from the vault's |
| `price` | **Optional**, and optional to honour: amount in minor units plus ISO 4217 code. Never required, never spoken unless the organisation enables it (Decision 4) |

**Replaces by sequence.** A snapshot is whole, not a delta: the highest accepted sequence within
the current generation is the stock the phone knows. Lower sequences are refused; the same
sequence with different bytes is a conflict; an exact replay is harmless. High-water state is
scoped to organisation, enrolment and kind, held outside any vault, and survives an authorised
office replacement, following the rule in *Replay and installation boundary*.

**Expiry does not delete.** `expiresAt` bounds when a message may be *accepted*. An accepted
snapshot stays usable after that and is simply reported with its age; a technician in a basement
is better served by "as of yesterday, 16:10" than by nothing.

**Join to the vault.** The phone joins lines to `VaultPartsIndex` on the normalised part number.
The vault contributes *fits* and *supersedes* (what the book says); Office contributes on-hand,
location and provenance (what the shelf says). Three outcomes are distinct and spoken
differently: in both; in the vault but not in Office's stock list ("not in the stock list");
in Office's list but not in the vault ("stocked, but I can't verify that number against the
manuals").

### 2 · Capture message

A technician's stock observation or source document, delivered as an inbox item. It is a
**proposal source, never a ledger write**; the contract has no field that states a level as fact.

Payload adds `captureID`, `capturedAt`, `captureKind` (`photo`, `scan`, `note`, `count`),
`jobReference` (optional), `locationID` (optional, from the snapshot's locations),
`bodySHA256`, `bodyBytes`, `attachmentCount`, `attachmentsSHA256` (a digest over the sorted
attachment digests) and `attachmentsBytes`.

Body: for `count`, structured lines (`part`, `quantity`, `unit`, `locationID`, `verified` — whether
the number resolved in the vault — and `source` `spoken` / `typed`); for `note`, the dictated text;
for every kind, an attachment table (name, media type from a closed list, bytes, SHA-256).
Caps proposed: ≤ 8 attachments, ≤ 5 MiB each, ≤ 20 MiB per message.

**Receipted like a job.** The message leaves through the offline queue and is delivered only when
Office returns a signed application receipt for the exact `messageID`, sequence and digest, after
it has committed the bytes durably. Transport completion is not delivery. The receipt contract is
FX's; HF reuses it rather than defining a second one, and P2 cannot start before it exists.

### 3 · Job readiness note

Attached to, or following, a managed job. Payload adds `jobMessageID` (the managed job it refers
to), `jobSHA256`, `asOf`, `bodySHA256`, `bodyBytes`. Body: lines of `part`, `description`,
`needed` (quantity, or unknown), `likelihood` (`listed` on the job / `likely` from Office's
review), `onHand` per location as in the snapshot, and `short: true|false|unknown`.

A note for a job the phone does not hold is kept pending until the job arrives or the note
expires; a note whose `jobSHA256` does not match the held job is refused. The note is information
on the job surface. It never changes a task or a recommendation, the same rule EM applies to
base's answers.

### 4 · Stock query and answer (later phase)

A small signed question (`queryID`, up to 10 part numbers, optional `locationID`) and a signed
answer (`queryID`, `asOf`, the same line shape as the snapshot, ≤ 32 KiB inline — no body file).
On the LAN or a direct route this is seconds. When Office is unreachable the tool answers from the
snapshot and says so; a query is never left hanging in front of the technician, and an answer that
arrives after the tool has replied is stored and reported only if asked again.

Until a real-time channel exists the query rides the same transport as every other message. When
one exists (the app already links WebRTC) truly live queries should ride its data channel. An
Office HTTP listener is not built for this now or later.

### What the contract requires of Office

Stated as requirements, not as an implementation:

- Derive every snapshot from the ledger at a stated `asOf`, with provenance per line; never send a
  level it cannot attribute.
- Represent "not known" as not known. A zero means counted zero.
- Treat every capture message as an inbox proposal that a person accepts or rejects.
- Retain pending messages until it verifies the phone's exact receipt, and receipt the phone's
  captures only after durable commit.
- Keep sequences increasing per organisation, enrolment and kind within a generation.
- Turn the parts used and requested on a returned work record into ledger *proposals* through the
  same inbox, attributed to the job.

## Phone behaviour

### `parts_stock` (native tool)

Reads the snapshot; never touches the network. Parameters: `part` (a number or a description
fragment), optional `location`. `OfflineToolPolicy` classifies it `local`.

Rules, each a test:

- Every answer states the as-of time. A snapshot older than a threshold (proposed 24 hours;
  Decision 3) is called out as old before the figures.
- A quantity that is not known is spoken as not known. `inferred` and `declared` provenance are
  said ("worked out from movements, not counted").
- A part number is resolved through `VaultPartsIndex` first, including `supersedes` in both
  directions, so the number printed on the old component finds the stock of its replacement.
- An unverified number is named as unverified, as `parts_request` already does.
- With no snapshot the tool says there is no stock list from the office yet. It does not guess,
  and it does not offer the model a way to answer from memory.
- The result is returned to the model as data, and the stock answer is reported to the
  technician; it never changes a recommendation (EM's decision, unchanged).

### The phone as a source

The work record already goes back with the job. HF adds nothing to that path except a pinned
mapping (P0) from the record to the movements Office will propose: a `TaskPart` on a task that
ended `done` is "issued to job"; a `PartsRequest` is a request, with its `onVan` flag; `verified`
and `page` travel with each; model and serial come from `equipment` and `identityFields`, each with
its source (`nameplate` / `spoken` / `display`).

Capture is by voice and by the phone: *"three of these in van two"* (a `count`, with the part
resolved from the active task or read back for confirmation), *"send this docket to the office"*
(a `scan`), *"note for stock: the last flame sensor went on the Hill Street job"* (a `note`).
The technician hears what will be sent before it is queued.

### Privacy, HIPAA and policy

- **Any photo that leaves the phone is filtered.** A capture still comes from
  `CameraService.filteredStill(for:source:)` and nowhere else; `.unavailable` means no attachment
  is sent and the technician is told why. P2 adds a `PrivacyFilterScope` case for Office capture
  and the matching `OutboundFrameConsumer` roster entry, so the existing scrape test covers it. A
  document scanned with the phone's own camera is not a glasses frame; whether it is filtered too
  is Decision 8.
- **HIPAA mode.** A dictated note and a spoken count are transcript-derived. With HIPAA mode on,
  capture messages are not sent and the capture actions are not declared to the model; the
  technician is told captures are off in this mode. Reading the snapshot (`parts_stock`) is
  local and stays available. Query/answer carries a part number the technician spoke, so it is
  refused under local-only by `MedicalEgressGuard` and falls back to the snapshot.
- **Agent Mode.** Nothing here runs unattended on the phone. Captures are sent only when the
  technician asks. Any later behaviour that would act on a readiness note or an answer without
  the technician (a proactive announcement, an automatic request) is gated behind
  `agentModeEnabled`, and is out of this plan.
- **Organisation policy.** A CT ceiling may turn captures off, or turn stock off entirely. Like
  every ceiling it only subtracts.
- **Accessibility.** Every state the stock surface shows is also spoken; no part of this is a
  paid extra beyond the organisation's existing licence.

### What cannot ride this

File sync cannot carry video. A real-time channel comes later, and live video from the glasses
to Office is out of scope here.

## Schema compatibility

Items, locations and movements are shaped to map cleanly onto the inventory model of the external
operations platform — stable item identifiers apart from display part numbers, typed locations,
movement kinds as a closed list, provenance on every row — so a firm that outgrows Office has an
upgrade path through Plan BL's bridge rather than a migration. The mapping table is a P0
deliverable in `Contracts/`, written against the contract's own field names; the platform's
schema is not reproduced in this repository.

## Phases (one PR each)

**P0 — Contracts, fixtures and verifiers (pure).** Schemas for all four kinds and their bodies in
`Contracts/`, fictional fixtures from the existing deterministic generator, and Swift verifiers
beside the existing ones: `OfficeStockSnapshot`, `OfficeStockCapture`, `OfficeJobReadiness`,
`OfficeStockQuery`, plus `OfficeStockBody` (closed body decoding with exact length and digest),
`StockHighWater` (pure decision over an injected state value) and `WorkRecordStockMapping`.
They reuse the closed-JSON and identifier checks the existing verifiers already share
(`OfficeManualAssignment.flatObject`, `safeIdentifier`); nothing is re-implemented. Tests:
`OfficeStockSnapshotTests`, `OfficeStockCaptureTests`,
`OfficeJobReadinessTests`, `OfficeStockQueryTests` (each: bad signature, wrong domain, foreign
recipient, expiry, rollback, same-sequence conflict, exact replay, duplicate or unknown key,
oversize, altered body), `OfficeStockBodyTests` (unknown quantity round-trips as unknown, never
zero), `WorkRecordStockMappingTests`. The portable contract runner gains the new cases.
*Owed:* the Go side agreeing on the same fixtures byte for byte; no device or Office check.

**P1 — Snapshot store, join and `parts_stock`.** `StockSnapshotStore` (durable, outside vault
content, atomic replace, previous snapshot kept until the new one is committed),
`StockPartsJoin` (pure over a snapshot and a `VaultPartsIndex`), `StockAnswerComposer` (the spoken
sentence, pure, with an injected clock), `PartsStockTool`, the `OfflineToolPolicy` entry, CT
ceiling key. Tests: `StockSnapshotStoreTests`, `StockPartsJoinTests` (the three join outcomes,
supersession both ways), `StockAnswerComposerTests` (as-of always present; unknown never a number;
stale wording; provenance wording), `PartsStockToolTests` (no snapshot; unverified number),
`OfflineToolPolicyTests` update. Until FX's delivery exists the store is filled only by tests and
a Developer-panel fixture import.
*Owed (device):* a spoken stock question with the phone in aeroplane mode; VoiceOver on the stock
row. *Owed (Office):* one real snapshot delivered over the managed connection once FX allows it.

**P2 — Capture message, queue and receipts.** `StockCaptureBuilder` (pure), a `QueuedOp` kind for
captures, the office sink path Plan T's header describes, receipt handling through FX's receipt
contract, the `PrivacyFilterScope` case and roster entry, capture voice actions, HIPAA and policy
gates, the pending/sent/receipted states on the sync screen. Tests: `StockCaptureBuilderTests`,
`StockCaptureQueueTests` (office asleep does not burn attempts; only a verified receipt marks
delivered; replay is safe), `StockCapturePrivacyTests` (`.unavailable` sends no attachment; HIPAA
mode sends nothing and declares nothing), `OutboundFrameConsumerTests` update.
*Owed (device):* photo, scan, note and count captures on LAN, cellular direct and relay; Stop and
relaunch mid-transfer; a capture taken offline and delivered later. *Owed (Office):* each capture
appearing as an inbox proposal, and the receipt returned only after commit.

**P3 — Readiness note on the job surface.** `JobReadinessStore` (pending until its job arrives,
bound by `jobSHA256`), a readiness section on the job screen and in the job read-back, the HUD
line when a display is present. Tests: `JobReadinessStoreTests` (note before job, job before note,
mismatched digest, expiry), `JobReadinessPresentationTests`.
*Owed (device):* a job and its note arriving in each order; read-back by voice. *Owed (Office):*
a note issued from the review for a real managed job.

**P4 — Query and answer.** `StockQueryService` with an injected transport and clock, the "check
now" action on `parts_stock`, snapshot fallback, late-answer handling. Tests:
`StockQueryServiceTests` (answer in time, timeout falls back and says so, late answer stored not
spoken, local-only refusal), `OfficeStockQueryTests` extended.
*Owed (device):* check-now on LAN and direct, and with Office asleep. *Owed (Office):* answering
within the time budget from the ledger.

## Risks

- **FX is the gate.** No production managed folder, durable high-water or receipt exists. P0 and
  P1 are useful without them (contracts agreed, tool testable); P2 onward is blocked until FX's
  next milestone passes on a physical device.
- **A stale count stated confidently is worse than no count.** The as-of rule, provenance wording
  and unknown-as-unknown are the defence, and they are tests rather than prompt instructions.
- **Part numbers differ between the book and the shelf.** Office's list may use supplier numbers
  the vault does not know. The join reports the mismatch instead of guessing; aliasing is Office's
  data-quality review, surfaced to the phone only as `supersededBy`.
- **Body size on a phone.** A whole-snapshot replace is simple and safe but large for a big
  stock list. The caps bound it; deltas are deliberately not in v1 (Decision 2).
- **Bulk starving small messages.** FX already flags that manuals must not starve jobs and
  receipts; snapshots and capture attachments join that queue-priority question.
- **Capture photos show more than stock.** The privacy filter covers faces; a docket can carry
  names and addresses. Captures go only to the organisation's own Office, which is why there is no
  other destination in the contract.
- **Price in a snapshot.** Optional in the schema so a firm can use it; a field a technician might
  read to a customer needs the organisation's say first.

## Decisions for Greig

1. Domain strings and kind names as tabled above, or fold query and answer into one domain with a
   `kind` discriminator? *Recommend separate domains, as the existing contracts do.*
2. Snapshot caps (4 MiB / 20,000 lines) and whole-replace only in v1, deltas later if a pilot
   needs them? *Recommend yes.*
3. Staleness threshold for the spoken warning: 24 hours, or set by the organisation profile?
   *Recommend 24 hours by default with a CT starting value.*
4. Price: carried but never spoken unless a CT key enables it? *Recommend yes.*
5. Should `parts_stock` be a separate tool, or an action on `parts_request`? *Recommend separate:
   one reads, one writes, and their offline classes differ.*
6. Capture from the glasses camera in v1, or phone camera and voice only until the device checks
   pass? *Recommend voice and phone first; glasses stills in the same phase only if the filtered
   still path proves reliable on device.*
7. Does a readiness note appear on the HUD unprompted when a job opens, or only on request?
   *Recommend on request, plus a single line on the job screen.*

8. A docket or note scanned with the phone's own camera: run it through the face filter as well,
   or send it as framed? *Recommend filtering it too; a document rarely has a face and the rule
   is then one rule.*

UI copy never names plan letters. The technician-facing words are "stock", "the office" and
"send to the office".

## Out of scope

The Office ledger, inbox, review, UI and persistence (private repository); ordering or reordering
anything; pricing logic, quoting and invoicing; barcode or label scanning; multi-site, cross-domain
or enterprise connectors (the external operations platform); supplier systems outside Office (a
signed add-on, Plans GF and HG); video or live streaming to Office; an Office HTTP listener; a
vendor-hosted server; snapshot deltas; and any change to how a recommendation is made.
