# Plan FD — Camera Readiness and Durable Action Acceptance

**Status: 📝 Drafted 2026-09-13 — implementation and device validation not performed under this plan.**

Harden camera readiness and session lifecycle, and prove durable action semantics end to end.
Extend OpenGlasses' existing services and acceptance tests. Translation and proactive visual cues
are bounded follow-ups, not prerequisites for the Field Assist pilot.

## Scope

- Frame-based camera readiness with observable wait states and repeated-start backoff.
- End-to-end idempotency, approval, cancellation, recovery and provider-parity acceptance scenarios.
- An optional bounded-context local-LLM translation experiment.
- A gateway health and error-semantics check.

Implement from requirements using our owners; no wholesale merges or third-party dependency additions.

## P0 / PR1 — Unify camera readiness and wait-state presentation

Audit `CameraService`, `MetaCameraBackend`, `CameraStreamStatePolicy`, `StreamCodecPolicy`,
`GlassesFramePipeline`, previews and visual-session entry points. Reuse [BR](BR-realtime-and-stream-hardening.md),
[CM](CM-dat-0-9-0-unlocks.md), [EO](EO-hevc-glasses-stream.md) and
[EW](EW-session-resource-cleanup.md). Existing stale-frame and decoding recovery remain authoritative.

- Inventory each UI/tool consumer's definition of ready. Distinguish SDK state, received sample,
  successfully decoded fresh image and user intent to keep streaming.
- Expose a consistent readiness snapshot through the existing camera interface, with a monotonic
  freshness clock and session/generation identity. Do not add a competing camera-session owner.
- Show a truthful state: connecting, awaiting first frame, ready, paused, frames unavailable,
  decoding stalled where observed, or stopped. Clear readiness on disconnect/session replacement.
- Keep Start/Connect usable to initiate capture. Gate only actions that require fresh visual evidence;
  do not create a deadlock where frames require Start but Start requires frames. Audio-only paths
  stay usable. One-off capture follows its own bounded acquisition contract.
- A held preview may remain visible if clearly marked stale; it cannot count as current evidence
  or enable a visual operation. No permanent “live” indicator based only on the SDK state.
- Describe observations and permitted next steps. Do not infer another app's ownership, user wear
  state or a required power cycle from rapid start failures.

**Acceptance:** fake backend tests drive connected/no frames, sample/no decode, fresh image, aged
image, stream paused, disconnect and replacement. Assert readiness at the actual UI/tool boundary,
not just an enum. Verify start remains reachable, audio-only works and stale frames cannot be used
as a fresh visual answer. UI checks cover accessibility labels and persistent stale-preview copy.

## P1 / PR2 — Session start, pause and cancellation audit

Audit our existing paused-stream “nudge” behaviour against the pinned SDK's official lifecycle
contract and recorded device traces. The repository guidance prohibits competing restarts while
paused. Resolve the discrepancy explicitly; do not assume any retry recipe applies without that evidence.

- Keep the paused session/resources required for system resume; issue no competing start during
  pause. Verify any documented same-session resume API before using it.
- Retry only while the user still wants the session and observable state permits it. Reuse bounded
  backoff, distinguishing compatibility failures from transient startup failures.
- Serialise camera replacement and await the required stop boundary. Coalesce concurrent start
  requests; invalidate callbacks from previous generations.
- Stop during permission checks, warm-up, backoff, teardown and replacement must terminate owned
  work. A late successful start must not resurrect a stopped session.
- Preserve other consumers' valid camera/audio claims; never tear down an unrelated recording.

**Acceptance:** injected clock/backend tests cover repeated rapid failures, exhausted retries,
paused → resumed/stopped, simultaneous starts, stop at each await boundary and late callbacks.
Test actual ownership and acquisition/release effects. On glasses, reproduce cold start, folding,
removal, phone lock, disconnect, repeated start and stop during warm-up. Record SDK/firmware,
observed states and recovery result separately from headless evidence. No automatic loop remains
after stop, and pause does not create a second session.

## P2 / PR3 — Durable action and approval acceptance scenarios

Extend the existing tool router, approval/evidence contracts and durable runtime under
[DJ](DJ-composed-tool-safety-and-execution-outcomes.md) and
[DZ](DZ-local-gguf-and-durable-agent-runtime.md). Inventory which routes are actually durable before
claiming restart support. Missing production semantics stay in the owning plan; tests must not
substitute a parallel demonstration queue for the real implementation.

Use a recording external-service fixture and real persistence/dispatch boundaries to prove:

| Scenario | Required result |
|---|---|
| Same request ID and payload retried after reconnect | One action, with the recorded result reused |
| Same ID with changed recipient, parameters or payload | Rejected; prior approval cannot authorize changed work |
| Intentional second identical action with a new request | Allowed only through normal authorization; content equality alone must not suppress legitimate repetition |
| Approval revoked, expired or denied before execution | No new side effect |
| Cancellation while awaiting approval | Approval becomes unusable; no later callback starts work |
| Provider accepted action but reply was lost | Outcome unknown; reconcile before retry, never blindly repeat |
| Restart while queued, executing or awaiting approval | State restored honestly; uncertain actions require reconciliation; expired approvals are not revived |
| Cancellation after dispatch | Stop future work; do not claim to have undone an external action |
| Backend/provider selection changes mid-run | Existing run keeps its declared identity/policy, or fails explicitly; no silent weakening or rerouting |
| Reconnect or unrelated session access | Result/evidence remains scoped to the correct task, account and workspace where supported |
| Provider produces empty output or fails | No false completion or invented success artifact; other work can still proceed |

Bind authorization to the action actually executed and recheck at the side-effect boundary. Preserve
our existing permission defaults; importing these tests does not authorise new tools or payments.
Exercise configured local, OpenClaw and Hermes routes through their production adapters where
applicable. Tests use fixtures, never real messages, orders or charges. Mark unavailable external
protocol checks pending rather than claiming provider parity from common-interface tests alone.

**Acceptance:** one demonstrable UI/voice → request → approval → fixture action → durable result
journey, including reconnect, cancellation and crash/restart. Record external invocation count,
request/action identity, persisted state and evidence linkage. Fault injection covers the windows
before dispatch, after external acceptance and before local result commit.

## P3 — Audit bounded visual prompting; only fill demonstrated gaps

Separate temporal detection from the decision to interrupt. Inventory our proactive scene,
structured-vision and announcement policies before adding anything.

Where an existing opt-in feature lacks it, reuse or add a deterministic policy with consecutive
evidence requirements, per-target/global cooldowns, one active prompt, a finite interruption budget,
expiry and explicit rearming. Never carry a streak across stale frames, a replacement stream or a
new task. Distinguish detector confidence from proven object identity or user attention.

Test flicker, repeated observations of the same target, alternating targets, stale evidence,
simultaneous triggers, speech already active, failed delivery, stop and session restart. Defaults
remain conservative and configurable through the owning feature. Skip implementation if existing
policies already meet the requirement; record the evidence instead.

Do not wire visual detections into [FB](FB-scan-assist.md) as proof of neglect or successful scanning.
FB's user-selected side and deterministic reminders stay independent of camera inference. No new
always-on cloud scene watcher, recording archive or background lifetime is introduced here.

## P4 — Optional local-LLM translation experiment

Defer until the reliability work is complete and users identify a translation quality gap. Reuse
[BY](BY-live-translation-captions.md), `OnDeviceTranslationProvider`, its utterance segmentation,
and DZ's model/runtime owner. Retain Apple Translation as the baseline.

- Add a backend seam only if needed, with explicit user selection and model readiness checks.
- Pass a small bounded context of source/translated utterances for disambiguation, clearly separate
  from instructions. Translate only the current utterance; never treat spoken text as tool commands.
- Preserve utterance ordering; bound pending work and invalidate old output on stop or language
  change. Label original transcripts when translation fails rather than presenting them as translated.
- Confirm each stage is on-device before claiming offline operation. If recognition/models/language
  assets are unavailable, explain the requirement without silently enabling network processing.
- Respect shared inference residency, audio scheduling, battery/thermal policy and cancellation.
  Do not download a model or force an engine switch merely because this experiment exists.

Compare a fixed consented/synthetic corpus containing idioms, pronouns, technical terms, numbers,
negation, code-switching and adversarial spoken instructions. Human bilingual assessment measures
meaning preservation and additions/omissions; measure time to usable translation, queue growth,
memory, thermal effects and energy on the actual target phone. Include the no-context baseline to
check whether preceding erroneous translations propagate mistakes.

**Decision:** adopt an optional backend only with a measured quality benefit and acceptable device
latency/resource cost, with targets written before testing. Otherwise defer/reject and keep the
existing implementation. Do not assume any particular model is universally better.

## P5 — Small gateway semantics check

Our `OpenClawBridge` already checks HTTP 2xx. Verify that reachable, authenticated and operational
are not conflated by the selected probe; 401/403, unavailable endpoints and malformed responses
must surface safe, actionable status. Reuse current socket handshake/capability evidence where
available. Add missing regressions only; no slash-command override feature or prose-based success
detector. Close this item without implementation if current coverage is sufficient.

## Delivery and evidence

Priority: P0/P1 camera reliability, then P2 durable-action acceptance. P3/P5 are bounded gap audits;
P4 requires a demonstrated user need. Coordinate ownership with EW/BR/CM/EO and DJ/DZ rather than
creating overlapping implementation tracks. [FC](FC-local-model-remediation.md) still owns
model catalog and malformed local tool output; this plan does not duplicate it.

| Gate | Status |
|---|---|
| Camera consumers and readiness audit | Pending |
| SDK pause/retry contract resolved and service tests | Pending |
| Real-glasses lifecycle evidence | Pending |
| Durable-action failure-window tests | Pending |
| UI/voice approval/recovery journey | Pending |
| Visual prompting and gateway audit disposition | Pending |
| Translation adopt/defer/reject decision | Deferred until justified |

For each gate record commit/build, fixture or hardware/SDK, result and remaining gaps. Device and
external-protocol evidence must stay separate from headless checks. Completion requires the chosen
fixes and acceptance evidence plus an explicit disposition for optional work, not imported code or
feature count. No changes to app behaviour or dependencies are made by this planning change.
