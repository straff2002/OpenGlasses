# Plan CP — Outbound Frame Privacy Pipeline

**Status:** 📋 Planned
**Completes:** Plan CO Item 0, which covered model-facing egress and explicitly deferred this half
**Shape:** two pure cores (P1), the relay and its wiring (P2), device measurement (P3). One PR.

---

## What's still unprotected

CO Item 0 found the bystander blur had never been called at all, and wired it to the paths that
send frames to an AI provider. It deliberately stopped there, because those paths are throttled to
roughly 1 fps and the rest are not. So today, with "Blur Bystander Faces" switched on, five
consumers still receive unblurred frames — every one of them an egress:

| Consumer | Where the frame goes |
|---|---|
| `WebRTCStreamingService` | a **shareable browser URL** — the widest exposure in the app |
| `BroadcastService` | RTMP to YouTube/Twitch/Kick — public, and recorded by the platform |
| `WebRTCPeerTransport` | a remote expert, peer-to-peer |
| `MeetingLinkTransport` | a remote expert, via a third-party meeting tool |
| `VideoRecordingService` | disk, and from there wherever the user shares it |

The gap is the wrong way round. Someone who turns this setting on while walking through a public
space is *most* likely thinking about the recording and the broadcast — the artefacts that outlive
the moment and travel — and those are exactly what we don't cover. The Settings copy now says so
honestly, which is better than lying, but the honest statement is still a statement that the
feature doesn't do the thing its name implies.

## Why it wasn't just done in CO

Cost. `processFrame` runs a Vision face-detection pass and a Core Image composite synchronously on
the main actor. At ~1 fps that is fine. These consumers run at camera rate, several of them at once,
and the project's own rule is never to block the main thread with frame processing. Two structural
changes make it affordable, and both are the point of this plan.

### One pass, shared

Filtering per consumer would run the blur up to five times on the same frame. Instead a single
relay sits between `CameraService.framePublisher` and every outbound consumer, blurs once, and
republishes. Consumers already take a `PassthroughSubject<UIImage, Never>`, so each call site
changes by one argument.

This also fixes a subtler thing: today each consumer independently decides what it receives. After
this, "which consumers get filtered pixels" is one wiring decision in one place, visible in
`PrivacyFilterScope`, rather than five.

### Detection cadence ≠ blur cadence

Detection is the expensive half (tens of milliseconds); compositing a blur over known rectangles is
cheap. Running Vision on all 30 frames a second is neither necessary nor possible. The relay
detects on an interval and reuses the last known rectangles, expanded to tolerate head and camera
motion, for the frames in between.

**This has a real privacy cost and it must be stated plainly rather than buried:** a face that
newly enters frame is unblurred until the next detection — up to one detection interval, a handful
of frames. Mitigations are a short interval (target 200 ms), generous rect expansion, and rects
that persist briefly *after* a face is last seen rather than disappearing the instant detection
misses one. It is a genuine residual, not a solved problem, and the plan says so.

---

## P1 — Pure cores

### `FrameCoalescer`

At camera rate you must never queue. If a blur is in flight when the next frame arrives, queuing
builds an unbounded backlog and the stream drifts further behind real time with every frame — the
classic way this kind of pipeline fails, and it fails silently.

So: at most one frame in flight, at most one pending. A new arrival while busy *replaces* the
pending frame. The intermediate frames are dropped on purpose, and the drop count is observable so
the cost is measurable rather than invisible.

```
submit(frame)      -> .process(frame) | .madePending(dropped: Int)
finishedProcessing -> UIImage?        // the pending frame, if any
```

**Tests:** idle submit processes immediately; a submit while busy goes pending; a third submit
replaces the pending one and reports the drop; `finishedProcessing` returns the newest pending and
then nil; drop counter accumulates across a burst; the sequence never processes an older frame
after a newer one.

### `FaceRectCache`

Holds the last detection result with a timestamp, and answers two questions: *should I detect on
this frame?* and *what rectangles do I blur right now?*

- `shouldDetect(now:)` — true when the interval has elapsed, or nothing has been detected yet.
- `rects(now:)` — the cached rectangles, expanded by a motion margin, or empty once they age out.
- Rectangles outlive the detection that produced them by a grace period, so a face that Vision
  misses on one pass does not flash unblurred.

**Tests:** detects on the first frame; suppresses within the interval; detects again after it;
expansion applied and clamped to the frame; rects survive a missed detection within the grace
period and expire after it; an empty detection result clears rather than freezes the previous one
once grace elapses.

---

## P2 — The relay

`OutboundFrameRelay` owns a serial queue, the coalescer, the rect cache, and a reused `CIContext`
(one Metal pipeline for the process, not one per frame).

- **Filter off ⇒ true passthrough.** Forward on the spot: no queue hop, no copy, no added latency.
  A user who never turns this on must pay nothing for its existence.
- **Filter on ⇒** coalesce, hop to the serial queue, detect-or-reuse, composite, republish on main.
- **Suspended (background) ⇒** passthrough, matching the existing `suspend()`/`resume()` contract.

`PrivacyFilterScope` gains the truth: `recording`, `broadcast` and the expert transports become
filtered, and the test that currently asserts they are *not* covered flips — which is exactly why
that test was written the way it was.

Settings copy, README and CLAUDE.md drop the "does not yet cover recording or broadcasting"
carve-out, and gain the honest residual instead: a newly-entered face may be visible briefly before
the next detection.

---

## P3 — Device measurement (deferred, and this one genuinely gates the default)

Everything above can be built and tested headless, but the numbers that decide whether it is usable
cannot:

- Sustained frame rate through the relay while broadcasting, with detection at 200 ms.
- Drop count under real motion — the coalescer's counter is the instrument.
- Thermal behaviour over a long recording, and whether `PowerPolicyService` should widen the
  detection interval under thermal pressure.
- Whether 200 ms and the chosen expansion actually keep a walking bystander covered, which is the
  only question that matters and the only one a simulator cannot answer.

## Open questions

1. **Does recording deserve a stricter mode than streaming?** A recording is re-watchable and
   shareable; a live stream is gone. An argument exists for detecting every frame when recording
   and accepting the frame-rate hit. Needs the P3 numbers first.
2. **What happens under thermal pressure — degrade the interval, or stop the blur and tell the
   user?** Silently widening the interval weakens a privacy promise without saying so, which is the
   failure mode this whole line of work exists to correct. Leaning toward surfacing it.
3. **Should the preview show what is being sent?** The wearer currently has no way to confirm the
   blur is working on an outbound stream. The pinned card shows it for stills; streaming has no
   equivalent.
