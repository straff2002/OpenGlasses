# Plan FH — “Handle This” Visual Actions

**Status: 📝 Drafted 2026-09-16 — not scheduled; no implementation under this plan.**

Turn “<wake phrase>, handle this” (the assistant name is configurable since FE P6 and the wake phrase is a separate setting) into a dependable **see → understand → confirm → act** interaction.
Identify the likely job from a user-requested camera capture, propose one useful action, let the
wearer correct it, perform exactly the reviewed action, and offer undo where the destination supports
it. Voice is sufficient for the normal journey; the phone provides the same draft and richer editing.

This delivers the flagship interaction proposed in [the opportunity assessment](../opportunity-assessment.md).
It builds on the existing capture tools, with a deterministic, headless-testable core first and
separate device evidence. Deliver one PR per phase; independently gate each action family.

## Current position and ownership

Verified against the working tree on 2026-09-16 and re-checked against `main` at build 403 on 2026-09-17, after the FC/EW/FD/FE/EX/FB/FF phases merged that week. Existing components are foundations, not evidence
that this complete interaction has shipped.

| Existing component | What it does | Gap this plan closes |
|---|---|---|
| `SmartCaptureTool` / `CaptureParsers` | Requires a mode; OCRs cards, receipts and flyers; returns extracted fields and a prose suggestion | Automatic classification, typed drafts, validation and an enforced action lifecycle |
| `ContactsTool` (`lookup_contact`) | Looks up existing contacts | A confirmed native contact creation adapter and safe removal of an unchanged contact it created |
| `CalendarTool` / `EventKitDayStore` | Calendar reads and event creation | Reviewed dates/time zones, stable result identity, duplicate handling and undo |
| `DocumentScanTool`, translation tools, document stores | OCR, translation hints and separate document operations | One source-bound proposal, destination selection and a verified saved result |
| `BarcodeScannerTool` / `QRContextTool` | Decodes codes; QR context may fetch a decoded URL subject to network policy | Preview without fetching, then explicit approval to open; no safety verdict from decoding alone |
| `NativeToolRouter`, `ToolConfirmationCoordinator`, `ApprovalGrantStore`, `ToolExecutionOutcome` | Shared authorization, bound approval and execution outcomes | FH actions use these boundaries, including when Agent Mode is off |
| `FilteredStillProviding` / `OutboundFrameRelay` | Purpose-scoped image privacy boundary | Fresh source identity carried through extraction, review and execution |
| `CaptureFlow` / project services | Typed field workflows and existing project/context owners | Reuse suitable contracts without treating an everyday one-shot capture as a field procedure |


Shipped since the first draft, and to be reused rather than re-proposed (2026-09-17):

- `CaptureQualityReport` and `SharpStillCapture` (FF PR4) already carry capture time, camera and live-session identity, privacy scope, sharpness and luma, and refuse a stale still as `.noFreshView`; `VisualEvidence` wraps them.
- `CameraReadiness` (FD P0) and the start/listener generation guards (EW, FD P1) are the "fresh evidence is explicit" invariant; do not add a competing freshness clock.
- `ToolConfirmationCoordinator.requestTextAnswer` (FE P1) is the user-originated text-correction boundary the review step needs; `requestConfirmation` remains the approval boundary.
- `OperationJournal` bounded reads and the "never replay a side-effecting call" rule (FF PR5), and the `AgentDeliveryRecordStore` shape (FE P4), are the patterns for FH's action history and restart reconciliation.
- `ConversationResetCoordinator`'s generation (EX) is how a late proposal or approval from a retired conversation is rejected.

`ee94f559` (2026-05-29, “Capture → action glue (smart_capture)”) introduced the earlier glue.
`CaptureParsersTests` covers parsing examples, not the proposed end-to-end transaction.
There is no dedicated tracking-label save flow or structured expense destination in the inspected tools.

Coordinate with these plans rather than creating competing implementations:

- [DU — Eyes-Free Capture Confirmation](DU-eyes-free-capture-confirmation.md) owns stability cues,
  repeat-read barcode acceptance and badge payload extraction. Share its extraction and contact
  work; FH owns the common proposal/commit/undo contract. Decide one contact adapter owner in P0.
  Badge capture must not automatically enrol a face or create a second person record.
- [FD — Camera Readiness and Durable Action Acceptance](FD-camera-readiness-and-durable-actions.md)
  and [EW — Session Resource Cleanup](EW-session-resource-cleanup.md) own camera readiness and
  lifecycle. FH requires freshness/session identity at its boundary, but not completion of every phase.
- [DJ — Composed-Tool Safety and Uncertain Execution Outcomes](DJ-composed-tool-safety-and-execution-outcomes.md)
  and [DZ — Local GGUF and Durable Agent Runtime](DZ-local-gguf-and-durable-agent-runtime.md)
  own shared authorization/execution semantics. Extend those contracts where necessary.
- [U — Structured Capture Flows](U-structured-capture-flows.md) supplies relevant field/provenance
  patterns. Its automatic field-record queue is not permission to sync FH drafts.
- [FG — Workflow Vaults, Enterprise Authentication and Connected Tasks](FG-workflow-vaults-and-enterprise-auth.md)
  owns connected enterprise writes. FH's initial project action saves locally; external submissions
  remain separately reviewed FG actions.
- [FA — Reading, Source and Memory Continuity](FA-reading-source-and-memory-continuity.md) owns
  broader source/resume continuity; [FF — Blind Assistant Readiness](FF-blind-assistant-readiness.md)
  supplies non-visual validation expectations. Neither is a prerequisite for a narrow first release.

## User contract

1. The user explicitly starts capture by voice or the phone's **Handle this** action. Reuse current
   wake/listening behaviour; this plan does not introduce an always-on wake engine or scene watcher.
2. Acknowledge capture, obtain fresh evidence, and explain a failed capture with one recovery step.
3. Present **one recommended action**: “This looks like an event poster. Add the Spring Meetup on
   22 April at 6 pm to your Personal calendar?” Show the fields and destination on the phone.
4. Ask one focused question if the object, a required field or the destination is ambiguous. Do not
   force an arbitrary choice from several visible objects. “Something else” allows another intent.
5. Accept corrections, repeat the changed proposal, then accept explicit approval or cancellation.
   “Handle this” authorizes analysis and preparation, not a write or opening a URL.
6. Report the actual outcome: “Saved to Personal calendar. Say undo to remove it.” For an uncertain
   result, say it is being checked and prevent an automatic duplicate.

Support “change the date”, “read the details”, “try again”, “cancel”, “save it” and “undo that” through
the shared pending interaction. A bare “yes” applies only to the current delivered confirmation.
Recognition confidence, assistant speech and text printed in the scene cannot supply user approval.
An interruption before the proposal finishes must not leave an unheard approval actionable.

Translation, explanation and summarization are also offered as the one action. Their execution
returns a response; it does not silently save a note, search online or add something to a project.
Specific existing commands can keep their current fast paths, but any FH draft they enter follows
this contract. Do not globally add redundant confirmations to ordinary read-only conversation.

## Action coverage

| Scene | Proposed action and required review | Result and reversal | Phase |
|---|---|---|---|
| Business card | Create a contact; review name and captured phone/email/company, choose destination and show possible duplicates | Native contact ID; remove only an unchanged contact created by this action | P2 |
| Event poster | Create an event; review title, explicit date/year, start/end or confirmed all-day, time zone, location and calendar | Calendar event ID; remove only this unchanged event | P2 |
| Receipt | Save an expense; review merchant, decimal amount, currency, date and local destination | Typed local expense ID; delete that record and owned attachments | P3 |
| Tracking label | Save a tracking reference; review exact identifier, carrier if known and optional label | Typed local tracking ID; delete that record; no automatic carrier lookup | P3 |
| Menu or sign | Translate visible text into the chosen language | Translation linked to this capture; dismiss, with no durable save by default | P4 |
| Product label | Explain visible ingredients; compare only with another identified product/source | Source-linked answer; dismiss; no claim that absent/unreadable information was verified | P4 |
| Document | Recommend scan, summary or add to a named project based on explicit context; clarify if destination/intent is missing | Response or persisted document/project reference; remove only newly owned records and links | P4 |
| QR code | Show the decoded content and, for a web URL, the destination host before offering Open | System browser handoff after approval; opening cannot be undone | P4 |

Receipt saving is a local personal expense record, not reimbursement submission, tax classification
or accounting integration. Tracking saving is not shipment monitoring. Event creation does not add
attendees or send invitations. Contact merging/updating, payment/credential/Wi-Fi QR actions, bulk
capture, automatic purchases, background follow-ups and automatic external submissions are out of scope.

## Shared architecture and invariants

Proposed new types live under `OpenGlasses/Sources/Services/VisualActions/`; names are provisional.
Keep the reducer, validation and recommendation policy independent of camera hardware, UIKit and
provider clients. UI state updates use `@MainActor`; OCR/image work runs off the main thread.

| Contract | Minimum data and responsibility |
|---|---|
| `VisualEvidence` | Capture ID, camera source/session generation, capture time/freshness, privacy scope, OCR/code observations and field provenance; image lifetime is bounded |
| `VisualActionDraft` | Draft ID/revision, evidence reference, finite action kind, typed payload, missing/uncertain fields, destination identity and proposal expiry |
| `VisualActionPolicy` | Rank supported candidates; choose one or ask for clarification; reject invalid required fields; no model-generated tool names or arbitrary argument execution |
| `VisualActionCoordinator` | Own one pending draft, edits, cancellation and state transitions; obtain bound approval through the existing coordinator |
| Destination adapters | Prepare and validate without side effects; commit through the real router; return typed IDs/outcomes; reconcile and conditionally compensate where supported |
| Action history | Extend the existing protected execution/evidence store where suitable; retain request identity, draft revision/digest, destination, outcome and bounded undo metadata |

State progression:

```text
idle → capturing → analysing → clarifying (if needed) → proposed → awaitingApproval
     → executing → succeeded | failed | outcomeUnknown
succeeded → undoPending → undone | undoConflict | outcomeUnknown
```

Edits return to a new proposal revision. Cancel/expiry before execution revokes approval and ends
the draft. Cancellation after dispatch stops further work but cannot assert rollback. Restart or
lost-response cases reconcile persisted intent/result state before any repeat. An undone action
remains in minimal history until retention expiry; it must not be replayed on recovery.

Required invariants:

- **One evidence set, one proposal revision, one approved action.** Bind approval to the final
  payload, action, destination/account/project and revision. Material edits or destination changes
  invalidate approval. Switching providers cannot change a reviewed payload or weaken the gate.
- **Every effect passes the existing router.** Extend action classification and resolved-target
  authorization for new adapters. A generic `handle_this` wrapper must not disguise contact,
  calendar, record or browser effects. No direct `tool.execute` chain and no second approval prompt
  for the same already-bound action. Model-supplied `confirmed: true` is never an approval.
- **Fresh evidence is explicit.** A cached image without adequate freshness/generation cannot
  support “what I am looking at”. Capture again or ask; never silently use a previous session's
  frame. A deliberately frozen draft may be reviewed, but expire it under the configured policy.
- **Extraction is not truth.** Preserve uncertain characters and original text spans. Validate
  phone/email, dates and amounts; do not substitute today's date, a 60-minute event or a currency
  simply because a downstream tool has defaults. OCR and model output are untrusted input.
- **Capability checks precede the offer and repeat at commit.** Honour tool availability, permissions,
  local-only/network policy, current project and entitlements. Permission denial produces a truthful
  unsaved draft; it never redirects into another store without a new proposal.
- **Privacy follows the sink.** On-device OCR images cannot be reused unfiltered for a cloud model
  or persisted attachment. Use the existing purpose-specific capture/egress boundary for each sink.
  Local-only mode can clarify or decline if no qualified local model exists; it cannot silently upload.
- **Success has evidence.** Return a typed destination ID/acknowledgement and verified outcome;
  never decide success by searching tool prose for “saved”. Persist request identity before effects.
  A destination without an idempotency guarantee must reconcile or stop with an uncertain result.

## P0 — Contracts, fixtures and integration map

- [ ] Inventory actual registration, provider tool exposure, confirmation routing, destination stores
  and durable execution support. Record gaps and owners, especially DU contact capture and FD freshness.
- [ ] Define the finite action/payload schemas, destination capabilities, state reducer, validation,
  expiry rules and policy seams. Record initial freshness/proposal/approval durations as named,
  injected configuration values; calibrate them in P5, not hidden constants in prompt text.
- [ ] Build synthetic evidence fixtures for all eight classes, mixed scenes, no supported job,
  malicious printed instructions, unreadable fields, ambiguous dates/currency and duplicate candidates.
- [ ] Specify protected storage, source attachment ownership and undo/reconciliation capabilities
  per adapter. Map onto existing outcome/approval contracts; document any required shared extensions.

**Exit:** headless tests exercise the real planned reducer/validation contracts, including edits,
stale evidence, cancellation, delayed callbacks and one-proposal selection. No destination writes
and no claim of camera recognition quality from text fixtures.

## P1 — Capture, recommendation and review

- [ ] Add the voice/tool and phone entry points, wired for each supported conversation backend.
  The entry point prepares a draft and cannot commit merely because the model calls it.
- [ ] Acquire fresh evidence through the existing camera owner and privacy boundary. Use bounded
  acquisition/retry, reuse DU capture feedback where available, and release only this request's resources.
- [ ] Run on-device OCR/code detection first. Use a configured vision model where permitted and
  needed; decode into the finite schema and validate independently. Unsupported/ambiguous scenes
  ask a focused question. A model's self-reported confidence is not a correctness guarantee.
- [ ] Deliver one spoken proposal and the matching phone card, with details, edit, recapture and
  cancel. Voice and phone modify the same revision; handle interruption and competing confirmations.
- [ ] Feed the prepared action into the existing bound approval mechanism. During this phase,
  only fixture adapters can commit; real action families remain unavailable until their phase passes.

**Exit:** capture fixture → recommendation → correction → approval → recording adapter works
through the actual entry point/router. Printed “approve” text, stale yes, edited payload, cancelled
capture and late provider replies cause zero effects. With no supported destination, explain the
limitation rather than offering a save that cannot succeed.

## P2 — Contacts and calendar: first complete release slice

- [ ] Create the shared contact writer in coordination with DU, retaining `lookup_contact` for lookup.
  Search for potential duplicates only with permission; do not merge automatically. Return the native
  ID and a fingerprint of the created fields for conditional undo.
- [ ] Adapt calendar creation to consume validated reviewed fields and return a typed result. Resolve
  ambiguous numeric dates, year, time zone and all-day/duration before approval. Detect likely existing
  events and ask whether a separate event is intended; do not silently update one.
- [ ] Implement minimal protected action history and restart reconciliation for these two adapters
  before enabling writes. Test the crash window after system-store success and before journal update.
  If authoritative reconciliation is unavailable, preserve `outcomeUnknown` and require user resolution.
- [ ] Implement “undo that” through normal authorization: resolve the named recent action, re-read
  the exact record, and delete only if it still matches the created version. Changed, inaccessible,
  already deleted or wrong-account records must never trigger a broad search-and-delete.

**Exit:** both actions work on phone and glasses with review, denied permissions, duplicate input,
double approval, cancellation, error, restart and undo. Invocation counts prove one commit per
approved request. Agent Mode on/off and every enabled provider use the same gate. Ship this narrow
slice behind its feature gate once its own hardware checks pass; broader coverage remains partial.

## P3 — Structured expenses and tracking references

- [ ] Add versioned local record schemas and a small saved-captures list/detail surface. Expense fields
  include merchant, decimal amount, currency and purchase date, with optional reviewed category/note.
  Tracking fields include the exact string (preserve leading zeros), optional carrier and user label.
  Reuse protected persistence patterns; notes prose alone is not the record format.
- [ ] Improve receipt extraction to distinguish subtotal, total, tax, tip and multiple currencies.
  The current largest-amount fallback must be marked uncertain, not treated as verified expense data.
  Missing currency/date requires correction before final save; a saved draft remains visibly incomplete.
- [ ] Combine barcode/OCR observations for tracking, using DU repeat-read semantics. Unknown carrier
  remains unknown; conflicting candidates require a choice and long codes can be spelled back in chunks.
- [ ] Add duplicate warnings, typed commit results, scoped undo, retrieval/editing and deletion. Any
  intentional second save receives a new approved request identity; do not suppress by content alone.
- [ ] Integrate new stores and owned attachments with retention, erasure, export and diagnostics policy.
  No raw receipt, code, address or URL enters operational logs. Do not automatically queue records
  for remote sync. Persist source images only when included in the reviewed save.

**Exit:** complete create/reopen/correct/delete/undo journeys using persisted records, schema migration,
offline restart and lost-result recovery. Fixtures cover decimal separators, leading zeros, currency
ambiguity, line-item traps and unrelated barcodes. No hidden carrier requests or accounting writes.

## P4 — Translation, product/document actions and QR preview

- [ ] Offer translation with source and target language, preserving unreadable portions. Present
  explanation/summary as model output tied to the captured source, not quoted source text.
- [ ] Explain product labels from visible evidence. Comparison requires a second captured product or
  an explicitly selected source; otherwise request it. Additional web lookup is a separate opt-in
  action subject to existing network policy. Do not infer missing ingredient/allergen information.
- [ ] Route document OCR/summary and project saves through the common draft. Resolve the actual
  project/document store, not `project_note` by name alone: that tool currently targets an active
  Field Assist job. Preserve existing feature entitlements. Partial storage/index/link failures need
  rollback or an explicit partial result; undo removes only artifacts owned by this capture.
- [ ] Decode QR payloads locally without network access. Show payload type and readable URL host,
  expose the full URL on request/phone, and identify suspicious formatting without claiming “safe”.
  Preview must not invoke `qr_context`, link metadata fetch, analytics, redirects or a web view.
  Offer only supported HTTP(S) browser handoff after approval; non-web schemes stay inert.
- [ ] Apply the existing URL/network policies if content is subsequently fetched. A release policy
  that disables fetching stays disabled. Browser opening is reported as a handoff, never a verified
  page load, and is explicitly non-reversible. Scan errors or changed payloads require new review.

**Exit:** all remaining action families run through real adapters with fixture-backed provenance,
unavailable capability handling and cancellation. A network spy proves zero requests before QR
approval; malicious payloads cannot act. Project saves verify record/link ownership and scoped undo.

## P5 — Recovery, accessibility and device qualification

Each earlier phase includes its own recovery tests. This phase proves the combined feature across
destinations and devices; it is not permission to defer safe execution until after release.

- [ ] Exercise interruption, app background/lock, glasses removal/folding, network loss, camera
  replacement, provider change, process termination and permission revocation at each boundary.
  Do not restart a paused SDK session or consume callbacks from an old draft/session generation.
- [ ] Reconcile outstanding effects before offering retry; reject expired or changed approval after
  restart. Never auto-submit a persisted draft when the app opens or connectivity returns.
- [ ] Validate non-visual correction, cancellation, result readback and undo with users; check VoiceOver,
  large text and dynamic confirmation length on phone. HUD output is optional, never required to consent.
- [ ] Build an image corpus with expected object class, fields, uncertainty and next action; record
  recommendation accuracy, critical-field errors and inappropriate confident proposals separately.
  Include blur, glare, rotation, multilingual text, clutter, multiple objects and prompt injection.
- [ ] Record capture-to-proposal and approval-to-result latency (median/tail), correction frequency,
  duplicate effects and recovery outcomes per supported backend/device. Use content-free counters;
  do not introduce default image/transcript collection to measure quality.
- [ ] Select release thresholds before evaluating the held-out corpus. Any observed unapproved write,
  duplicate effect, wrong-record undo or false success blocks that action family. Ambiguous inputs
  must clarify or decline; recognition accuracy is reported with sample counts and limitations.
- [ ] Test physical glasses and the supported phone capture fallback; state which providers have
  fixture-only versus live evidence. Update capability/help docs only for enabled, proven action families.

**Exit:** end-to-end device evidence for each enabled family, recovery fault-injection results,
privacy/logging checks and an actionable rollback procedure. Disable new proposals/commits per family
without deleting history or disabling safe reconciliation/undo of earlier actions.

## Delivery and definition of done

### Priority update — 2026-09-16: demonstrate useful completed tasks

A public discussion of alternatives to the stock assistant on these glasses
raises processing choice and setup friction, while one commenter describes abandoning an alternative
because they did not use its features. Treat this as qualitative input: demonstrate one useful
completed task and measure actual usefulness with participants, not just the size of the tool list.

- **P1:** consume FF's shared readiness and processing summaries. Explain camera-unavailable and
  mixed local/cloud configurations before analysis; do not build a second onboarding or routing owner.
  Preview the destination relevant to the proposal, including any processing of extracted text.
- **P2:** produce short, reproducible contact and event demonstrations: capture → correction →
  confirmation → verified saved record → undo. Include one capture/permission failure and recovery.
  Test voice-only operation with blind participants under FF's task protocol before calling it
  independently usable. Do not make a simulated adapter appear to be a native saved result.
- **P3–P5:** ask participants whether the completed task was useful enough to repeat and which
  correction/setup steps prevented use. Record this separately from recognition accuracy and latency;
  no default telemetry or retention of their private captures is introduced.
- **Public status:** distinguish today's extraction tools from planned automatic recommendation,
  native contact creation, structured expense/tracking records and unified undo. Update both README
  languages and the capability guide per enabled family. Record build, model/provider, phone/glasses,
  permissions and any manual assistance alongside demos. Do not advertise the full flow after P2 alone.

The current documentation correction is part of this planning update; application changes and all
acceptance gates remain pending. Model choice is useful configuration, not the user outcome shown
in the demo. Preserve the existing source-available licence description and Meta setup requirements.

Sequence: **P0 → P1 → P2 → P3 → P4 → P5**, one PR per phase. P2 is the first usable flagship slice;
the full proposal is complete only after all eight rows and P5 are delivered. Extract prerequisite
fixes to their owning plans when needed, with explicit dependency notes rather than duplicating work.
No new third-party dependency is assumed; implementation should first use existing services and
Apple frameworks, and verify the pinned SDK/API contracts before changing platform calls.

| Gate | Required evidence | Status |
|---|---|---|
| P0 contracts and ownership | Reducer/validation tests; adapter and persistence map | Pending |
| P1 capture and review | Actual routed fixture journey; stale/edited/cancelled approval tests | Pending |
| P2 contact/event writes | Native IDs, recovery/undo tests, permission and device results | Pending |
| P3 expense/tracking records | Persisted typed records, migration, retrieval and erasure tests | Pending |
| P4 remaining actions | Source-linked answers, project ownership tests, zero-fetch QR preview | Pending |
| P5 release qualification | Held-out corpus, interruption matrix and non-visual/device evidence | Pending |

For each gate record the build/commit, test or device configuration, results and remaining gaps.
Existing parser tests and general AI responses do not count as end-to-end acceptance. The finished
experience lets a wearer say “handle this”, correct one intelligible proposal, approve it once,
hear a truthful result, and reverse the supported write without risking unrelated user data.
