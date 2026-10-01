# Plan GZ — Expert Annotations on the Technician's View

**Status:** 📝 Drafted 2026-10-02 — nothing implemented.
**Track:** Field Assist (B2B). One of three gaps found when Field Assist was compared feature by
feature against industrial remote-assistance products (with [GX](GX-photo-checked-procedure-steps.md)
and [GY](GY-procedure-from-narrated-recording.md)).
**Depends on:** the live expert video phase of the Office plan (FX8) for the expert side and the
transport. This plan builds the **phone side** so that phase has something to talk to.
**Related:** Plan [K](K-integration-polish.md) K2 (expert bridge + notifier), Plan
[L](L-webrtc-expert-transport.md) (WebRTC transport), Plan [M](M-webrtc-infra-and-audio.md) M3
(expert-call audio), Plan [CP](CP-outbound-frame-privacy.md) / W04.1 (relay and roster), Plan
[CE](CE-frame-pinning.md) (a frozen frame as the shared referent), Plan
[X](X-interactive-hud-now-next-tasks.md) / [AH](even-display-backend.md) (HUD backends), Plan
[FX](FX-desktop-office-and-device-sync.md) (desktop office app).

---

## Trigger

When a technician escalates, the expert can see the view but can only *say* where to look:
"no — the other one, left of that, the red wire". Remote-assist products in this market let the
expert mark the picture. Most Ray-Ban Meta glasses have **no display**, so a drawn mark on its own
helps nobody wearing them; the mark has to become words, a phone overlay, and a HUD line where a
display exists.

## Outcome

- The expert marks a **frozen frame** of the technician's view — circle, arrow, box or point, with
  an optional short label.
- The technician **hears** where it is ("Upper left — the red terminal"), sees the frozen frame with
  the mark on the **phone** when they look at it, and gets a one-line cue on the **Meta Display HUD**
  where the glasses have one.
- The frame the phone shows is **the same filtered frame the expert saw** — never a fresh or raw one.
- Marks expire on their own, the expert can clear them, and the technician can say "clear the marks".
- Annotations are accepted only from the authenticated live session, rate-limited, bounded in size,
  and are **data only**: nothing in an annotation is executed, opened, followed or given to the
  model as an instruction.
- **Not in this plan:** marks anchored to the equipment that track as the camera moves.

## What exists today (verified against main @ build 447)

- **Bridge.** `Services/FieldAssist/ExpertBridge.swift` — `ExpertBridge` (`isConnected`, `roomURL`,
  `connect(sessionId:expertId:)`, `disconnect()`), `PendingExpertBridge`, notifiers (local
  notification, webhook). `EscalationCoordinator.swift` runs `idle → requested → awaitingExpert →
  expertConnected → resolved` and logs escalations to the session. AppState wires
  `EscalationCoordinator.shared.bridge = ExpertStreamBridge(streamer:framePublisher:
  outboundFrames.publisher)` — the expert view comes off the **filtered relay**.
- **Transports.** `ExpertStreamTransport.swift` — `MJPEGExpertTransport` over
  `WebRTCStreamingService` (one-way JPEG frames over a WebSocket to a **customer-hosted relay**; no
  relay ships, `Config.webRTCSignalingURL` defaults empty), `WebRTCPeerTransport` (real
  `RTCPeerConnection`, outbound video + mic, inbound expert audio, self-hosted signaling/TURN),
  `MeetingLinkTransport`. All three are `OutboundFrameConsumer` roster entries with scope
  `.expertStream`, tap `outboundRelay`.
- **Inbound channels that exist.** `WebRTCStreamingService.handleMessage` already decodes typed JSON
  from the relay (`viewer_count`, `viewer_joined`, …) on the same socket the frames go out on.
  `WebRTCPeerTransport` has **no data channel**: `peerConnection(_:didOpen:)` is an empty stub and
  none is created.
- **Frame identity.** Frames carry no id: the JSON path sends `{type:"frame", data, timestamp}`, the
  binary path (`WebRTC/WebRTCFrameEncoder.swift`) a `0x01` marker + JPEG. Nothing on the phone keeps
  the frames it sent.
- **Authentication.** The room id in the viewer URL is a bearer capability (the code says so); there
  is no per-viewer or per-expert identity, and the relay is not ours.
- **Audio during a call.** `ExpertCallAudioCoordinator` (Plan M3) **stops TTS and pauses the wake
  word** for a WebRTC call — the expert's voice owns the speaker. A spoken cue cannot simply be
  spoken over the expert.
- **HUD.** `GlassesDisplayService` — `showNotification(title:body:icon:duration:)`, `flash`,
  `deviceSupportsDisplay()`; `HUDIcon` has no arrows, and the HUD screen model has **no image type**
  (`ManualFigureCue` says the same and sends a text line, "…on your phone").
- **Speech.** `TextToSpeechService.speak(_:urgency:mirrorToHUD:)`.
- **Reference expert client.** `docs/webrtc/expert-client.html` + `signaling-server.js` (Plan M1/M2
  reference implementations) — not a product surface.
- **Hosted live expert video does not exist.** The L and M rows record that live support moved to
  the live expert video phase of the Office plan (FX8), taken after the job and manual path passes.

## Design

### The message (versioned, bounded, transport-agnostic)

```json
{ "type": "annotation", "v": 1, "id": "a7f3c2", "seq": 12,
  "frame_id": "f-000123", "shape": "circle",
  "points": [[0.62, 0.31], [0.70, 0.40]],
  "label": "red terminal", "expires_in": 20,
  "mac": "base64…" }
```

Also `{"type":"annotation_clear","v":1,"seq":13,"id":"a7f3c2"|null,"mac":…}` and, phone → expert,
`{"type":"annotation_ack","v":1,"id":…,"status":"shown"|"expired"|"rejected","reason":…}`.

| Field | Rule (`AnnotationValidator`) |
|---|---|
| message | ≤ 4 KB encoded; unknown `type` ignored; `v` ≠ 1 → rejected `unsupported_version` |
| `id` | 1–32 chars `[A-Za-z0-9_-]` |
| `seq` | strictly increasing per session (replay guard) |
| `frame_id` | must name a frame the phone sent in this session and still holds |
| `shape` | `point` (1 pt), `circle` (centre + edge), `rect` (2 corners), `arrow` (tail, head); `freehand` (≤ 64 pts) only if Decision 4 says so |
| `points` | each coordinate finite and within [0, 1] (normalized to the frozen frame, origin top-left) |
| `label` | optional, ≤ 60 chars after trimming, printable, no newlines, no URL schemes; rendered verbatim, never as Markdown or a link |
| `expires_in` | 3–120 s; default 20 |
| active marks | at most 3 per frame; a 4th replaces the oldest |

### Frames: the phone shows what the expert saw

- **Freeze handshake (recommended, Decision 1).** The expert's "freeze" request makes the phone send
  the current frame **from the relay** at full stream resolution as a `frozen_frame` message with a
  `frame_id`, and keep it in a `FrozenFrameStore` (last 5, 2 min). The expert annotates that frame;
  the phone renders on that frame. Same pixels, same filter, by construction.
- Alternative: tag every streamed frame with an id and keep a short `SentFrameRing`; it costs a
  protocol change to the frame message and memory on the phone, and the mapping on WebRTC video is
  inexact.
- A `frame_id` the phone no longer holds → the mark is **spoken and shown on the HUD only**, never
  drawn on a substitute frame, and acked `rejected: frame_expired`.
- Roster: `expertFrozenFrame` (owner `FrozenFrameStore`, tap `outboundRelay`, mechanism `relay`,
  scope `.expertStream`). It holds only relay output, so the blur (when on) has already run; when the
  relay is dropping frames (filter on but unavailable), there is no frame to freeze and the expert is
  told so.

### Who is allowed to annotate

`AnnotationGate` accepts a message only when **all** hold: an escalation is in `expertConnected`
with a streaming transport; it arrived on that session's inbound channel; `seq` is fresh; and the
`mac` verifies. The MAC is HMAC-SHA256 over the canonical message with a **per-session key the phone
generates and puts in the join link's fragment** (`…?room=…#k=…`) — browsers never send the fragment
to the server, so a customer-hosted relay can forward annotations but cannot forge them (Decision 2).
When the live expert video phase of the Office plan (FX8) brings authenticated sessions, its
identity replaces the fragment key behind the same `AnnotationAuthenticator` protocol.

Rate limit: token bucket, 1 per second sustained, burst 5, freezes 1 per 3 s (`AnnotationRateLimiter`,
injected clock). Over the limit → dropped, one aggregate ack per second. Every rejection is counted
by reason in the session log; content is not logged for rejected messages.

### What the technician gets — `AnnotationPresenter` (pure)

Input: the annotation, whether its frame is held, `deviceSupportsDisplay()`, whether an expert call
owns the audio (`ExpertCallAudioCoordinator.isCallActive`), whether the app is foreground. Output: a
`Presentation` — phone overlay yes/no, HUD line or none, spoken line or earcon, ack status.

| Situation | Phone | HUD (display glasses) | Audio |
|---|---|---|---|
| MJPEG view, no call audio | frozen frame + mark, banner if backgrounded | one line | spoken cue (TTS) |
| WebRTC call (expert talking) | frozen frame + mark | one line | short earcon only — the expert says it; TTS stays paused (M3) |
| frame not held | — | one line | spoken cue / earcon as above |
| phone locked | local notification "The expert marked your view" | one line | as above |

**Spoken cue — `AnnotationCuePhraser`.** The mark's anchor (circle/rect centre, arrow head, point)
is placed on a 3 × 3 grid of the frozen frame: "upper left", "top", "upper right", "left", "centre",
… With a label: "Upper left — the red terminal." Without: "The expert marked the upper left of your
view." Arrows add direction only when it helps: "Arrow pointing down, lower right." When the frame
is more than 3 s old the cue starts "In the picture from a moment ago, …" because the wearer's head
has moved. Never "click", "tap here", never coordinates, never plan letters. HUD line: the same
words, ≤ 40 chars, `.info` icon, duration `min(expires_in, 8)`.

**Phone overlay — `FrozenFrameOverlayView`.** The frozen frame aspect-fit, marks drawn in the AI
accent per the UI style rules, label chip beside the anchor, fading out at expiry; "Clear" button and
a "Save to job" button (Decision 3). The geometry mapping (normalized point → view point under
aspect-fit, letterboxing, rotation) is a pure `AnnotationGeometry`, tested headless.

### Record

`SessionLogger.Event.Kind.expertAnnotation` (`expert_annotation`): id, frame id, shape, label,
received/shown/expired times, presentation used. `expertAnnotationRejected` carries only the reason
and a count. The frozen frame is **not** filed unless the technician saves it, through
`attachPhoto(…, origin: .expertAnnotation)` with the mark burned in, so it joins the job's
evidence selection at close. Annotation labels are **not** added to the model's context in v1
(Decision 5): they are untrusted remote text.

### Transport adapters (later, behind one protocol)

`AnnotationChannel` — `incoming: AsyncStream<Data>`, `send(_: Data)`. The phone core only sees this.
Adapters, each a later PR once the live expert video phase of the Office plan (FX8) settles the
transport: the relay socket (a new `case "annotation"` / `"freeze"` in
`WebRTCStreamingService.handleMessage`), a WebRTC data channel created in `WebRTCPeerTransport`, and
whatever FX8 chooses. None of them is built in P0–P1.

## Phases (one PR each)

**P0 — Message, gate, presenter, phrasing (headless).** `ExpertAnnotation` + codec,
`AnnotationValidator`, `AnnotationRateLimiter`, `AnnotationAuthenticator` (HMAC; fixture key),
`AnnotationGate`, `AnnotationStore` (active set, expiry, cap 3, clear), `AnnotationPresenter`,
`AnnotationCuePhraser`, `AnnotationGeometry`. Fixture folder of valid and hostile messages
(oversize, NaN, out-of-range, 10 k-point freehand, control characters, `javascript:` label, replayed
`seq`, bad MAC, unknown version). Tests: `ExpertAnnotationCodecTests`, `AnnotationValidatorTests`,
`AnnotationRateLimiterTests`, `AnnotationAuthenticatorTests`, `AnnotationGateTests` (not connected →
rejected; wrong session → rejected), `AnnotationStoreTests`, `AnnotationPresenterTests` (every row
of the table), `AnnotationCuePhraserTests` (grid, labels, stale-frame prefix, length caps),
`AnnotationGeometryTests`.

**P1 — Phone surface, frozen frames, record.** `FrozenFrameStore` + roster entry,
`FrozenFrameOverlayView`, HUD line through `GlassesDisplayService`, spoken cue / earcon through an
injected speaker, local notification when locked, the voice phrase "clear the marks", session log
events, "Save to job", and a **Developer-panel injector** that feeds fixture annotations through an
in-memory `AnnotationChannel`, so the surface is checkable on a device with no expert side. Tests:
`FrozenFrameStoreTests` (only relay frames enter; eviction), `OutboundFrameConsumerTests`,
`ExpertAnnotationRecordTests` (log payloads; rejected events carry no label),
`AnnotationEndToEndTests` (in-memory channel → gate → store → presenter with fakes).

**P2 — Transport adapters (deferred; depends on FX8).** The `AnnotationChannel` conformers and the
join-link key, against the transport the live expert video phase of the Office plan (FX8) chooses.

**P3 — Expert side and device checks (deferred; depends on FX8).** The drawing tool belongs to the
expert's client in that phase. Device checks then: glasses with and without a display, MJPEG and a
call, phone locked, a stale frame, a burst from a misbehaving client.

## Risks

- **Stale referent.** The technician's head moves; a mark on a frozen frame can point at the wrong
  thing. The stale-frame prefix and the phone overlay are the mitigation; world anchoring is out of
  scope.
- **Audio clutter** during a call. Earcon-only while the expert is talking keeps TTS from fighting
  the call (M3's rule stays intact).
- **Building ahead of the transport.** P0–P1 are small and transport-free; P2 waits on purpose.

## Open decisions for Greig

1. **Frame identity: freeze handshake (recommended)** or an id on every streamed frame plus a ring.
2. **Authentication until FX8: HMAC key in the join link's fragment (recommended)**, or trust the
   session's transport and accept anything that arrives on it.
3. **Save the annotated frame to the job?** Recommended: only when the technician taps "Save to job";
   otherwise only metadata is logged.
4. **Freehand marks in v1?** Recommended no — point, circle, box, arrow only; freehand cannot be
   spoken.
5. **Tell the model about marks?** Recommended no in v1 (untrusted text); later, as quoted data
   ("The expert marked: «red terminal», upper left") if the AI is to follow the call.
6. **In-call audio cue:** earcon only (recommended) or a ducked TTS line.

## Out of scope

Marks anchored to equipment that track as the camera moves; drawing on the glasses' own display
beyond a text line; the expert's drawing tool; annotation of recorded clips; annotations from the
AI; several experts annotating at once; any transport or hosting work (FX8).
