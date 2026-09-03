# Plan CN — Agent Vision Attachment (a delegated run can see)

**Status:** ✅ P1+P2 built (2026-08-08), full suite green. P3 (live gateway round-trip, device
smoke) deferred as planned. **Wire answered by Plan EH P1 (2026-09-03):** the gateway's `sessions.send`
schema carries the frame as `attachments: [{type, mimeType, fileName, content, sizeBytes}]` and
advertises its per-image ceiling in `hello-ok.policy.attachments.maxImageBytes`, so the attachment
setting now defaults **on** and oversize frames are dropped client-side before sending. The live
round trip itself is EF P4.
**Depends on:** Plan N (Remote Agent Harness), Plan CE (Frame Pinning), Plan CB (live-session vision detail)
**Shape:** deterministic core first (P1), seam widening + adapters (P2), live/device edge deferred (P3)

---

## The defect

A remote agent run is blind. [`AgentHarness.start(prompt:project:)`](../../OpenGlasses/Sources/Services/AgentHarness/AgentHarness.swift)
takes two strings and nothing else; `AgentSessionService.dispatch` passes them straight through; and
`AgentControlTool`'s schema has no image parameter. Nothing under `Services/AgentHarness/` touches a
frame at all.

So when the wearer is looking at a serial plate, a wiring label, a delivery docket or a form and says
*"get the agent to file this"*, what actually reaches the agent is the on-device model's one-sentence
paraphrase of the scene. Dense visual content is exactly where a paraphrase loses the most: digits
transpose, part numbers get normalised into plausible-looking neighbours, and small print vanishes.
The agent cannot recover any of it, because it has no route back to the camera.

This is a gap between two features we already shipped. Plan CE made "this" mean a specific frozen
frame, and Plan CB gave the live model a full-resolution look on demand — but both stop at the
on-device model. The moment work is handed to a harness, the referent is dropped.

The fix is narrow, because the hard parts already exist: `FramePin` holds the frozen frame,
`AppState.currentVisionFrameDataIfAvailable()` already encodes the pinned-over-live precedence, and
`LLMImagePreparer` already does bounded JPEG encoding with a degenerate-frame guard. What's missing
is a lane from those to the harness.

## Non-goals (v1)

- **The agent asking to look again.** A mid-run "send me a fresh frame" needs an inbound channel to a
  running task; our adapters are status-poll only (Plan N's live event stream is deferred). One frame
  at dispatch, then the run is on its own. Worth naming as the natural follow-up once N's stream lands.
- **Multi-frame or video attachment.** One still. Anything more needs a size and cost story we don't have.
- **Attaching to `status`/`cancel`/`confirm`.** Only `start` carries an image.

---

## P1 — Pure core (headless, no wiring)

### `AgentTaskAttachment`

A value type: JPEG `Data`, a `Source` (`.pinned(at: Date)` / `.live`), pixel dimensions, and byte
count. `Equatable`, no UIKit in the decision path. Provenance is not decoration — it drives the
prompt line below, and a pinned frame from four minutes ago is a different claim about the world than
a live one.

### `AgentAttachmentPolicy`

Pure decision function, table-tested:

```
decide(settingEnabled:, agentModeEnabled:, hipaaMode:, pinHeld:, pinAge:,
       cameraStreaming:, prompt:) -> Decision   // .attach(Source) | .skip(Reason)
```

Rules, each with a reason it exists:

| Rule | Behaviour |
|---|---|
| Setting off (**default**) | `.skip(.disabled)` — see *Consent* below |
| Agent Mode off | `.skip(.agentModeOff)` — dispatch itself is already blocked; belt and braces |
| HIPAA mode | `.skip(.hipaaMode)` — hard-disable, mirroring the Plan AQ precedent |
| Pin held | `.attach(.pinned)` — the pin *is* the aiming gesture; it beats a live frame |
| Pin older than `maxPinAge` | `.skip(.pinStale)` — a forgotten pin must not silently become the agent's view of "now" |
| No pin, camera streaming, prompt is visually referential | `.attach(.live)` |
| No pin, camera streaming, prompt is not referential | `.skip(.notReferential)` — "run the tests" doesn't need a photo |
| No pin, no stream | `.skip(.noFrame)` |

Referential detection is a small pure matcher over demonstratives and read-this constructions
("this", "that one", "here", "the label", "read the…", "what's on the…"). It must be
**demotable, never authoritative**: the tool gains an explicit `attach` boolean (below) that
overrides the matcher in both directions, because the model often knows something the matcher can't
see. Follow the Plan CD methodology on the false-positive corpus — a positive control proving the
naive predicate *did* fire, so a tightening that loses a real catch fails the suite.

### Encoding

No new image code. `LLMImagePreparer.prepared(_:)` (2576 px long edge, 4.5 MB ceiling under
Anthropic's 5 MB inline cap, quality ladder) and `LLMImagePreparer.isDegenerate(_:)` (the 1×1
placeholder failure mode). A degenerate frame is `.skip(.degenerateFrame)` — shipping a blank to a
remote agent is worse than shipping nothing, because the agent will describe the blank.

### Provenance line

`AgentAttachmentPhrasing.provenance(for:now:)` — one sentence appended to the dispatched prompt
telling the receiving agent what the image is and when it was taken ("the wearer's camera view,
captured 12 seconds ago"). Without it a remote agent has no way to know whether the attachment is the
current scene or a stock reference, and will hedge accordingly. Same lesson as `AsyncDeliveryPhrasing`:
the framing around the payload is load-bearing, so it lives in a pure, tested unit rather than being
interpolated at the call site.

### Config

- `agentVisionAttachmentEnabled` — **default off**.
- `agentVisionAttachmentMaxPinAge` — default 120 s.

**Tests** (`OpenGlassesTests/AgentAttachmentTests.swift`): full policy truth table walked by
`CaseIterable` over reasons; pinned-beats-live precedence; stale-pin skip at the boundary; HIPAA
hard-skip regardless of every other input; default-off; degenerate-frame rejection; provenance line
shape for both sources; referential-matcher corpus with positive controls.

---

## P2 — Seam and adapters

### Protocol widening, compatibly

```swift
func start(prompt: String, project: String?, attachment: AgentTaskAttachment?) async throws -> AgentRun
```

with a default-implementation shim in the existing `extension AgentHarness` forwarding to the
two-argument form, so adapters and the 56 Plan N tests compile untouched. `AgentSessionService.dispatch`
gains the same optional parameter and runs the policy; `AgentControlTool` gains an `attach` boolean in
its schema (documented as "attach what the camera is looking at — use for tasks about something
physically present").

The frame comes from the existing resolution path in AppState, not a new one, so pinning stays the
single aiming gesture across every model-facing surface.

### `OpenClawAgentHarness`

`image_base64` + `image_mime` alongside `prompt` in the `agent.start` params. Whether the gateway
accepts unknown params or rejects the call is unverified (see *Open questions*), which is the main
reason the setting ships off.

### `CustomAgentHarness`

A new `imageField` on `CustomHarnessConfig`, **empty by default** — an arbitrary user-configured
endpoint must never start receiving multi-megabyte bodies because a setting elsewhere got flipped.
Empty field = attachment silently dropped for that harness. Also raise `startRequest`'s
`timeoutInterval` when the body carries an image; 30 s is thin for a few MB on cellular, and a
timeout here surfaces as "couldn't start the agent", which sends the user looking in the wrong place.

### Consent

Sending a camera frame to a third-party endpoint is egress, and `agentModeEnabled` does not cover it.
The user granted "dispatch text tasks to my agent"; quietly upgrading that to "and ship frames from a
head-mounted camera to the same endpoint" is a scope expansion they didn't agree to. Hence the
distinct default-off setting, sited next to the other Agent Mode controls with copy that says plainly
what leaves the device.

**Tests:** custom-config omits the image when `imageField` is empty; OpenClaw param shape;
default-implementation shim keeps two-argument callers working; `dispatch` honours a policy `.skip`
without failing the run; prompt carries the provenance line iff an attachment is present.

---

## P3 — Deferred (live / device)

- **Live gateway round-trip.** Whether a real gateway accepts, ignores or 400s on the new params.
  Backend-pending, same gate as Plan N's live event stream and Plan AR's approval round-trip.
- **Device smoke.** Pin a real label → dispatch → confirm the agent's answer reflects detail the
  spoken description didn't contain. This is the whole point of the plan and it can't be proven
  headless.
- **Privacy-filter ordering.** See below — resolve on device before flipping the setting on.

---

## Resolved

1. **Filtered or raw frame? — Neither, and that became Plan CO Item 0.** Tracing this turned up that
   `PrivacyFilterService` had no call sites at all: every frame in the app was raw, and the Settings
   toggle promising bystander blur did nothing. CO Item 0 wires the filter at the model-facing
   chokepoints, `agentAttachment` among them. A pinned frame arrives already filtered (filtered once
   at pin time); a live frame is filtered here, before anything leaves the device. So the attachment
   path is covered, and it is covered by the same mechanism as every other egress rather than a
   private one of its own.

## Open questions

1. **Unknown-param behaviour on the gateway.** If it 400s rather than ignoring `image_base64`, we
   need either a capability probe or a retry-without-image fallback. Not built speculatively — find
   out against a live endpoint first. This is the main reason the setting ships off.
3. **Should a pin auto-attach even for non-referential prompts?** Argument for: taking a pin is itself
   a statement of intent. Argument against: pins persist across topics, so an hour-old workflow could
   attach a frame to an unrelated task. Currently resolved by `maxPinAge`; revisit if 120 s proves wrong.
4. **Cost visibility.** An attached frame is image tokens on someone else's bill. Plan AU tracks our
   own spend; a delegated run's cost is invisible to us. Probably just a docs note, but name it.
