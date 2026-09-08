# Plan AT — Content-Aware Frame Gate (drop near-duplicate frames before the LLM)

**Status:** 🚧 Core shipped. `PerceptualHash` (pure dHash + Hamming) and `FrameGate` (pure decision:
threshold + EMA + heartbeat + `dedupRatio`) are built and wired into `FrameThrottler` behind
`Config.frameDedupEnabled` (default **off** → byte-for-byte today's behaviour). Settings UI for the
advanced threshold shipped 2026-06-30 (`LiveVisionSettingsView`, `fd59f82`). 21 tests green in
Release. No new SPM dependency. **2026-08-23 finding (`1b2947f`):** the ~20 s latency this plan
flagged as a device risk was traced to camera cold-start, not the dedup gate itself — fixed with
`FrameThrottler.requestFreshFrame()` (see [Plan CX](CX-live-session-vision-choice.md)). Deferred
(device-pending): flip the default on after on-device sanity-checking that motion still flows.

## The problem
`FrameThrottler` ([Sources/Services/GeminiLive/FrameThrottler.swift](../../OpenGlasses/Sources/Services/GeminiLive/FrameThrottler.swift))
is **purely time-based**: at the default 1 fps it forwards a frame every `interval` seconds **even
when the scene hasn't changed**. While the user sits still or stares at one object, Gemini Live (and
any frame-consuming vision path) receives a stream of near-identical frames — wasted upload
bandwidth, wasted input tokens, and a context window diluted with redundant images. A static minute
is 60 essentially-identical frames.

## What we build
A cheap **content gate** in front of the existing time throttle: after the time check passes, compute
a perceptual hash of the candidate frame and **skip it if it's visually indistinguishable from the
last frame we actually sent**. Plus two refinements so a long static scene still stays fresh:
- **Adaptive threshold** — an EMA of recent inter-frame change raises the similarity bar in static
  scenes (drop more) and lowers it in busy scenes (keep more).
- **Heartbeat / force-send** — after `N` seconds with nothing sent (everything deduped), send one
  frame anyway so the model's visual context can't go stale.

### The deterministic core
- **`PerceptualHash`** — 64-bit **dHash**: downscale the frame to 9×8 grayscale, set one bit per
  adjacent-pixel gradient, return a `UInt64`. Pure function of pixel bytes.
- **`FrameGate`** — holds the last sent hash + an EMA of recent Hamming distances, and returns a
  decision (`.send` / `.drop`) for each candidate given the configured threshold, adaptive factor,
  and heartbeat deadline. Pure, time injected (no `Date()` inside).

`FrameThrottler.submit` runs the time gate first (unchanged), then consults `FrameGate`; only `.send`
frames call `onThrottledFrame`. Diagnostics gain a `dedupRatio`.

## Scope
In:
- `Sources/Services/Vision/PerceptualHash.swift` (pure dHash + Hamming).
- `Sources/Services/Vision/FrameGate.swift` (pure decision: threshold + EMA + heartbeat).
- `Sources/Services/GeminiLive/FrameThrottler.swift` — consult the gate after the time check; expose
  `dedupRatio`.
- `Config` — `frameDedupEnabled` (default off initially), `frameDedupHammingThreshold`,
  `frameDedupHeartbeatSeconds`.

Out (deferred / not this plan):
- Semantic (embedding/cosine) gating — dHash is the cheap edge pass; an embedding tier is a later,
  heavier option only if dHash proves too coarse.
- The `analyzeFrame` / structured-vision single-shot paths — they already capture one deliberate
  frame; the gate targets the *streaming* path. Revisit if a burst mode lands there.

## Architecture — the seam
```swift
enum PerceptualHash {
    /// 64-bit dHash of a frame's luma. Pure; nil if the image can't be read.
    static func dhash(_ image: UIImage) -> UInt64?
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int  // popcount(a ^ b)
}

struct FrameGate {                       // value type, time injected
    enum Decision: Equatable { case send, drop }
    mutating func evaluate(hash: UInt64, now: TimeInterval) -> Decision
    var dedupRatio: Double { get }
}
```
`FrameThrottler` owns a `FrameGate` and calls `PerceptualHash.dhash` on the (already time-throttled)
frame; the gate's EMA + heartbeat live entirely in the value type. When `frameDedupEnabled == false`
the throttler bypasses the gate → byte-for-byte today's behaviour.

## Build order
1. **`PerceptualHash` + tests** — known images → known hashes/distances; identical vs shifted vs
   distinct. Pure.
2. **`FrameGate` + tests** — first frame always `.send`; near-duplicate `.drop`; distinct `.send`;
   heartbeat forces `.send` after the deadline; adaptive factor raises/lowers the effective
   threshold from the EMA. Time injected, fully deterministic.
3. **Wire into `FrameThrottler`** behind `frameDedupEnabled`; add `dedupRatio` to the existing
   diagnostics log.
4. **(Off→on)** flip the default after on-device sanity-checking that motion still flows at the
   expected rate.

## Tests
- `PerceptualHash.dhash`: a solid image and a 1px-shifted copy hash within a small Hamming distance;
  an inverted/distinct image is far. `hamming` is symmetric and `== popcount(xor)`.
- `FrameGate`: see build order — every branch (first/dup/distinct/heartbeat/adaptive) asserted with
  injected timestamps and hashes. No `UIImage` needed (operate on `UInt64`).

## Open questions / decisions needed
- **Threshold default** — dHash Hamming ≤ ~3–5 of 64 is "same scene"; pick a conservative default and
  expose it in Settings (advanced) so it can be tuned without a rebuild.
- **Heartbeat length** — long enough to actually save (e.g. 10–15 s) without letting the model lose
  the scene; tie loosely to `geminiLiveVideoFrameInterval`.
- **Where else** — once proven on Gemini Live, the same gate could front any future continuous
  frame→LLM path (live captions vision, agent vision loop). Keep it a reusable component.

## Why this matters
The streaming-vision path is the single biggest repeated cost in a live session, and most of those
frames are redundant. A <1 ms/frame perceptual-hash gate cuts the static-scene waste with zero model
involvement, keeps the context window full of *distinct* views instead of duplicates, and is a pure,
fully-tested value type with a flag so the happy path is unchanged until we choose to turn it on. It's
also the **keyframe source** the [Visual State Memory](visual-state-memory.md) plan builds on.
