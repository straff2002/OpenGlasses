# Plan FA — Reading, Source and Memory Continuity

**Status: 📝 Drafted 2026-09-13 — no implementation or device validation completed under this plan.**

The outcome is a more dependable document-to-answer workflow and understandable personal memory.
An optional model-server experiment must demonstrate value before it adds product scope.

## Scope decisions

- A continuous reading → source → note → resume workflow over the existing reading companion and
  manual retrieval.
- Memory that is visible, attributed, correctable and forgettable over the existing memory stores.
- An optional experiment routing an external Apple-Silicon model server through the existing custom
  OpenAI-compatible endpoint, with no iPhone runtime replacement and no bundled dependency.
- Headset connect/disconnect scenarios added to the existing audio-recovery validation, with no
  companion-app hooks and no glasses-settings automation.

Downloading models, copying third-party code, changing licences and deploying a server are not
deliverables of this planning change. Write our own implementation; import no third-party code.

## Existing work to reuse

- [BT](BT-reading-companion.md): reading session, OCR, reference-copy alignment, grounded Q&A,
  recap and reading stats. `ReadingCompanionService`, `ReadingContextBuilder` and
  `ReadingSessionStore` remain the owners.
- [ED](ED-vault-manual-retrieval.md), [EJ](EJ-manual-retrieval-fidelity.md): manual ingestion,
  retrieval and citations; reuse `ManualLookupTool` and the existing manual page/figure surfaces.
- [DX](DX-private-memory-timeline.md), [EN](EN-memory-distillation-and-external-graph-memory.md),
  [DZ](DZ-local-gguf-and-durable-agent-runtime.md): memory presentation, provenance/distillation
  and runtime scheduling. Audit current implementation before assigning any missing work.
- [CW](CW-realtime-audio-rig-recovery.md), [EW](EW-session-resource-cleanup.md),
  [EX](EX-conversation-reset-across-backends.md): route recovery, resource ownership and context reset.
- [EE](EE-field-assist-commercial-licensing.md): solo StoreKit purchases do not grant the team
  manual-document/custom-vault/export capabilities. Use a valid team pilot licence for that journey;
  test solo IAP separately. This plan does not change entitlements.

## P0 — Establish one pilot and its baseline

Choose one technician workflow using an authorised OEM manual and a valid team pilot licence:

1. Install and connect glasses without developer assistance.
2. Import the manual, ask a real service question and inspect the cited source.
3. Save a useful note or work-record entry, then continue the task.
4. Interrupt the session, recover and export the work record.

Record build, phone/glasses/firmware, provider/model, licence tier, task outcome, assistance needed,
time to first useful answer and interruptions. Use synthetic or consented fixtures; exclude customer
identifiers from shared evidence. Recruit five external testers when the controlled baseline works.
Keep device-pending evidence explicitly pending; automated tests alone do not close the pilot.

## P1 — A continuous reading and source workflow

First trace the existing path: **explain this passage → open its source → save a note → resume**.
Record what already works and implement only missing connections, in one bounded PR if feasible.

- Carry the selected passage and its document/page identity through question answering and saving.
- Make a cited answer open the correct existing page/figure view. Label extracted-book positions
  honestly when they are not printed page numbers.
- Preserve reading position and active task when opening a source or saving a note.
- Reuse voice routing and note storage; prevent duplicate saves after retries or repeated callbacks.
- Preserve BT's read-so-far retrieval boundary and ED/EJ's insufficient-evidence response. An
  imported whole book must not expand the reading corpus beyond the permitted frontier.
- Respect existing licence gates and local-only routing. No new library, vector database or sync system.

**Acceptance:** a fixture question resolves to the expected document and page; a saved note retains
the passage/source association; opening and closing a source preserves position; a retry saves once;
unread passages stay outside retrieval; absent evidence produces an honest refusal. A device user
completes the sequence by voice with a source view available when wanted. Also exercise inaccessible
or deleted source files and failed note writes without announcing false success.

## P2 — Understand and correct memory

Audit DX/EN's current surfaces and storage contracts before adding UI. Extend the existing memory
surface to answer: **what is remembered, where did it come from, and how can I correct or forget it?**

- Show available source/date and distinguish explicit user statements from inferred memories.
  If provenance is missing, say so; never invent it.
- Offer correction and forgetting through existing stores, using the established confirmation and
  protected-data rules. State the scope: current memory, source conversation and exported files are
  different objects.
- Verify corrections and deletions propagate to retrieval, derived relationships and cached context.
  Ensure later distillation cannot silently resurrect a forgotten fact from an unchanged source;
  reuse EN/DX's mechanism or define the missing suppression contract there.
- Separate resetting the current conversation (EX) from deleting persistent memory.
- Show a concise memory-review result only when useful; do not add another notification stream.

**Acceptance:** seed an attributed fact and an inference; inspect both, correct one and forget the
other; subsequent retrieval uses the correction and excludes the forgotten fact after relaunch and
reprocessing. Missing provenance and missing source files render honestly. Verify each configured
backend's active-context invalidation before claiming an immediate forget; report unsupported
boundaries clearly. Add regression coverage at the actual store/retrieval boundaries.

Overnight consolidation is a follow-up owned by EN/DZ, only if their remaining work warrants it.
Use bounded, cancellable, local processing under existing power/privacy controls, with foreground
catch-up. Do not promise an exact nightly run on iOS or introduce background keep-alive tricks.

## P3 — Optional external model-server experiment

Run after the pilot baseline identifies a model quality, privacy or cost problem worth addressing.
Use the existing custom OpenAI-compatible endpoint; keep the current provider as the baseline.

1. Pin the server's commit, model/checkpoint and adapters; record model terms, download size, host
   requirements and configuration. The documented runtime is macOS/Python/MLX, not a supported
   drop-in Swift/iPhone engine.
2. Start with a mid-size checkpoint on a suitable Mac. Keep the server on a controlled network with appropriate
   access protection; do not publish its raw endpoint. A Mac endpoint is off-phone processing and
   must obey the app's existing medical/local-only network policy.
3. Check streaming text, Unicode, reasoning-text handling, cancellation/disconnect, model discovery,
   errors and timeouts. Test structured tool calls and images explicitly; unsupported capabilities
   must remain unavailable. The inspected server response code establishes text streaming, not
   complete assistant compatibility.
4. Compare the same 20 manual questions: 10 supported answers, five exact-code/table lookups and
   five deliberately unsupported questions. Record correctness, citation accuracy, unsupported
   claims, cold/warm time to first usable answer and first speech, and cancellation completion.
5. Measure process/system memory and cold/warm behaviour at realistic context lengths. Do not
   present MLX active-allocation figures as total RAM use. Record storage and network requirements.

**Decision gate:** retain as an optional endpoint only if it passes required compatibility checks,
does not weaken evidence/refusal behaviour, and offers a measured advantage over the baseline
without making median or p95 first-speech latency unacceptable for the pilot. Record the pilot's
latency target before running the comparison. Otherwise close the experiment with findings.
No dedicated provider UI, runtime rewrite or larger checkpoint rollout without that evidence.

## P4 — Headset transitions and complete-session proof

Extend CW/EW's device evidence with AirPods/headset connect and disconnect during capture, speech,
idle and screen lock. Include a phone-call interruption, glasses disconnect, and stop during warm-up.
Record intended and actual input/output route, audible outcome, interrupted output handling and
remaining microphone/camera claims after stop. Never restart a deliberately stopped session or
cancel another recording consumer's resource claim. Do not assume connecting a headset should pause
all glasses work; follow the selected mode and existing routing policy.

Failures become fixes under CW/EW, not another audio-session owner. Re-run the five-person pilot
after the workflow fixes, recording unassisted completion and voluntary use on a later job.

## Delivery order and completion

1. P0 baseline and P1 workflow gap audit; ship only demonstrated gaps.
2. P4 session validation alongside those fixes, through CW/EW.
3. P2 memory audit and focused improvements through DX/EN/EX.
4. P3 only when justified by the pilot baseline.

Each implementation PR links its owning plan, includes meaningful boundary tests and states device
evidence separately. Keep an evidence table here with phase, build/commit, fixture/device, result
and remaining gap as work proceeds. Finish when the selected workflows have recorded acceptance
evidence and the model-server experiment has an explicit adopt/defer/reject decision. No dependency import
or new feature count is itself a success criterion.
