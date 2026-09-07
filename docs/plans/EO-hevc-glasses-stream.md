# Plan EO — HEVC Glasses Stream (compressed frames, decoded on the phone)

**Status:** 📋 Planned 2026-09-07. Headless core first (P1); the numbers that decide the defaults
come from one device session (P2) and are to be written into **P2 findings** below before P3 is
touched.
**Origin:** The glasses stream is requested as **raw** pixels
(`MetaCameraBackend.ensureSession`, `videoCodec: .raw`) and every frame is turned into a `UIImage`
by the SDK's helper. A raw 720×1280 frame is ~1.4 MB; at any frame rate that is tens of megabits a
second, which the glasses link does not carry, so the SDK's automatic ladder steps the source down
to 504×896 and the delivered rate sags to a couple of frames a second no matter what was asked
for. Our own field note says the same thing from the other side: at `.raw/.low/15 fps` the video
rides the Bluetooth radio and starves the HFP voice link, which is why `StreamConfigPolicy` floors
"low" to "medium" whenever the glasses mic is live — the fix for a symptom whose cause is the
codec. The SDK vendor's own camera sample now streams **hvc1** and decodes on the phone, and our
tree already carries a `VideoDecoder` (`Services/VideoDecoder.swift`) that nothing calls — it was
orphaned by the 0.9 rewrite. HEVC is roughly 10–30× smaller per frame. The top resolution tier
should fit, the voice link should stop competing, and a decoder that lives in-process keeps
delivering pictures with the screen locked, which the hardware path does not.
**Priority:** P1 for everything vision does. Every model-facing frame, the live preview, recording,
broadcast and the expert stream all take what this stream delivers; a sharper, more current frame
raises all of them at once, and the voice-link contention is a bug users hit today.
**Surfaces:** One camera backend, one decoder, one policy file, one settings row. No SDK version
change, no new dependency, no schema. The frame contract to every consumer stays `UIImage`.

---

## Verified starting point

- **The request is raw.** `MetaCameraBackend.ensureSession` builds
  `StreamConfiguration(videoCodec: .raw, resolution:, frameRate:)` from `Config.cameraResolution`
  (default `high`) and `Config.cameraFrameRate` (default 15; the picker offers exactly the SDK's
  legal rungs 2/7/15/24/30). The frame listener calls `frame.makeUIImage()` and drops the frame
  silently when that returns nil. Nothing in the tree calls `CMSampleBufferGetImageBuffer` on a
  glasses frame or feeds a sample to a decoder.
- **The decoder exists and is unused.** `VideoDecoder` wraps a `VTDecompressionSession`
  (32BGRA output, IOSurface-backed), recreates the session when the format description changes,
  and reports decoded frames through a callback. It does **not** rebuild on an invalidated session
  (`kVTInvalidSessionErr`, -12903, which backgrounding produces), does not prefer the software
  decoder, does not hold a last-good frame across a rebuild, and has no test. Its only log event is
  `PrivacyLog.camera(.decoder, .configured, …)`.
- **The SDK exposes the tier sizes.** `StreamingResolution.videoFrameSize` returns the frame size
  each tier resolves to on this SDK and device. `StreamConfigPolicy.encodedSize(for:)` hardcodes
  360×640 / 504×896 / 720×1280 for the settings bitrate preview; the capability-created log line
  reports the *label*, so no log we have ever recorded what a tier actually was.
- **Liveness is measured at the wrong point for a decoder.** `lastFrameTime` is stamped when a
  *decoded image* lands on the main actor; `startStallDetection` rebuilds the stream after 1.5 s
  without one. With a decoder in the path, a link that is fine but a decoder that is waiting for a
  keyframe would look like a dead stream and provoke a teardown that makes it worse.
- **Consumers take `UIImage`.** `CameraService.framePublisher` is `PassthroughSubject<UIImage, Never>`;
  `OutboundFrameRelay` fans that out to recording, broadcast and expert streams (each converting
  back to a pixel buffer where it needs one); the model paths take `latestFrame`. Changing the
  codec on the wire changes nothing downstream as long as the backend keeps emitting images.
- **Background streaming is a product path.** With glasses connected, backgrounding keeps the
  camera up (`optimizeForBackground` only trims non-essential work); Direct mode explicitly keeps
  the camera running for background voice. Whether raw frames keep decoding with the screen locked
  has never been traced on our tree; the SDK vendor's sample assumes they do not and forces the
  software decoder for exactly that reason.
- **The Wi-Fi transport gate is already open.** `Info.plist` carries `bluetooth-central` and
  `external-accessory`, `NSLocalNetworkUsageDescription`, and a non-empty `NSBonjourServices`
  (`_http._tcp`, for self-hosted model discovery), which is all the SDK checks; the medium/24
  configuration is device-traced to ride Wi-Fi. The vendor's documented value is `_bonjour._tcp`;
  adding it beside ours is harmless and makes the plist match the docs.

## Product promise

"The glasses send the sharpest picture the link can carry, the picture keeps coming with the phone
in a pocket, and talking to the glasses never fights the camera for the radio."

## Design

**Codec on the wire: hvc1, with raw as the escape hatch.** `Config.cameraCodec` (`"hevc"` default,
`"raw"` for compatibility) feeds `StreamConfiguration.videoCodec`. The setting is visible under the
existing camera settings as *Video Codec* with a one-line explanation, because P2 may find a device
or firmware where hvc1 misbehaves and the wearer needs a way back that is not a reinstall.

**One frame path, two shapes of sample.** The listener asks the SDK helper first: if
`makeUIImage()` yields an image the frame is raw (or the SDK decoded it for us) and nothing changes.
If it yields nil and the sample carries a data buffer, the sample goes to the decoder; the decoded
pixel buffer becomes the `UIImage` the rest of the app expects. Which branch ran is logged once per
stream, not per frame. The decode happens on the SDK's listener thread, never on the main actor;
the main actor receives an image or nothing.

**A decoder that survives the lock screen.** `VideoDecoder` gains the vendor-sample behaviours,
each as a rule the tests can state:
- *Software first.* Create the session with
  `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false`; fall back to the
  default specification if that fails, and log which one was used. Hardware decode runs in a shared
  out-of-process service iOS tears down on backgrounding; software decode stays in-process.
- *Rebuild, don't die.* On `kVTInvalidSessionErr` or `kVTVideoDecoderMalfunctionErr`, invalidate,
  recreate for the same format description, and retry the frame once. After three consecutive
  failures of any status, invalidate so the next frame builds a fresh session.
- *Hold the last good frame until a keyframe.* After any (re)creation, non-keyframe samples do not
  reach the decoder and the last good image is what the app sees; the first keyframe clears the
  hold. No corrupt frame reaches a model, a recording or the lens.
- *Format change is a rebuild.* Already present; kept, and now covered by a test.

**Liveness that knows the difference between a dead link and a waiting decoder.** A small pure
type, `StreamLiveness`, is fed two clocks — *sample arrived* and *picture produced* — and answers
what the stall detector should do:
- no samples for 1.5 s → `linkStalled` (today's behaviour: rebuild the stream);
- samples arriving, no picture for 1.5 s → `decodeStalled` (rebuild the **decoder**, never the
  stream);
- a held last-good frame is **not** a picture produced; it must not refresh either clock.
`startStallDetection` consults it instead of `lastFrameTime` alone.

**Report what the tier really is.** At capability creation, log all three tiers'
`videoFrameSize` and the requested one, and log the decoded frame's dimensions on the first frame
and on every change — the first time we will have a record of what "high" delivers on a given
device rather than the label. `StreamConfigPolicy.encodedSize(for:)` keeps its table for the
settings preview but gains a comment saying the log is the truth.

**The voice-link floor stays until P2 says otherwise.** `StreamConfigPolicy.effectiveResolution`
keeps flooring "low" to "medium" during glasses voice. If P2 shows hvc1 at `.low` leaves the HFP mic
intact, the floor becomes codec-conditional in P3; it is not touched blind.

## Phases

### P1 — Headless core (one PR)

1. `Config.cameraCodec` + `setCameraCodec`; `StreamCodecPolicy.videoCodec(for:)` maps the string
   to `VideoCodec` (unknown → hvc1) and states the per-frame rule as data: `FrameShape`
   (`.picture` / `.compressed` / `.empty`) from whether the helper produced an image and whether the
   sample has a data buffer → `.emit` / `.decode` / `.drop`.
2. `VideoDecoder` hardening: software-first specification with fallback; rebuild-and-retry on the
   two session-dead statuses; three-failure invalidate; keyframe hold with last-good frame; the
   recovery rule extracted as `DecoderRecoveryPolicy.action(status:consecutiveFailures:)` so it is
   testable without VideoToolbox. Decoded frames reach the backend as `UIImage` via one reused
   `CIContext` on the decode thread.
3. `MetaCameraBackend`: pass the codec into `StreamConfiguration`; the two-shape listener; decode
   off-main; tier logging from `videoFrameSize`; `StreamLiveness` driving the stall detector, with
   `decodeStalled` rebuilding the decoder only.
4. Settings: *Video Codec* picker (HEVC / Raw) under the camera group, gated like the other camera
   rows; `_bonjour._tcp` added to `NSBonjourServices`.
5. PrivacyLog: `.decoder` events for `configured` (already), `rebuilt`, `softwareUnavailable`,
   `stalled`; `.glasses` event `tierResolved(width,height)`.

**Tests (all headless):**
- `StreamCodecPolicyTests` — mapping, default, escape hatch; the three frame shapes and their
  actions; a raw stream on a firmware that decodes for us still emits (no double-decode).
- `DecoderRecoveryPolicyTests` — -12903 and malfunction → rebuild-and-retry; other statuses count;
  third consecutive failure → invalidate; success resets.
- `StreamLivenessTests` — the three verdicts; a held frame refreshes nothing; a decoded picture
  refreshes both; a keyframe ends the hold.
- `VideoDecoderRoundTripTests` — encode a synthetic pixel buffer to HEVC with a
  `VTCompressionSession` in the simulator, decode it through `VideoDecoder`, assert dimensions;
  invalidate the session by hand between two frames and assert the second still decodes after the
  rebuild; a non-keyframe first sample yields the last-good (nil) image. Skips, with a named
  reason, if the simulator cannot create an hvc1 encoder.
- `TelemetryOptOutGuardTests` unaffected; `CameraStreamStatePolicyTests` unchanged.

**Gates:** full suite green, Release build green, `SWIFT_EMIT_LOC_STRINGS=NO` on headless builds,
build number bumped in all five spec pairs.

### P2 — Device session (findings only, no code beyond what the numbers force)

One wearing session on Ray-Ban Meta with the app in each of: Direct mode, Gemini Live, OpenAI
Realtime. Record, per configuration `{hvc1, raw} × {high, medium, low} × {15 fps}`:

| Measure | Where it is read |
|---|---|
| Tier the SDK resolved (`tierResolved`) vs decoded frame size | PrivacyLog camera events |
| Delivered fps over 60 s | `frameReceived` count |
| Decoder used (software/hardware) and rebuilds per session | `.decoder` events |
| HFP mic alive during streaming at `.low` | `WakeWordService` route events + a spoken turn |
| Locked-screen continuity: frames in the 60 s after lock, frames in the 10 s after unlock, stall/recovery events | camera events with app state |
| CPU and thermal over 10 min at hvc1/high/15 vs raw | Xcode energy gauge, `ThermalLevel` |
| Photo capture path unchanged (dimensions, latency) | `capturePhoto` events |
| Recording, broadcast, expert stream still receive frames | their own start/frame logs |

Decisions the numbers make: the default codec (hvc1 unless it regresses), whether the voice-link
floor is still needed under hvc1, whether 15 fps stays the default or 7 gives a sharper still at
the same tier, and whether the keyframe hold after a lock-screen rebuild is short enough to leave
alone. All of it goes in **P2 findings** with the raw numbers.

### P3 — What P2 unlocks (deferred, separate PR)

- Codec-conditional voice-link floor if hvc1 at `.low` keeps the HFP mic.
- Hand decoded pixel buffers straight to the recorder and broadcaster through the relay, skipping
  the image → pixel-buffer round trip each does today.
- Passthrough recording: write the compressed hvc1 samples to the file without decoding, which the
  vendor sample does and which would take the recorder's CPU cost to near zero — worth it only if
  P2 shows software decode at the chosen rate is a measurable drain.

## Out of scope, noted for their own PRs

- A `stopStreaming()` issued during the ~20 s warmup is lost: the guard on `isStreaming` returns
  early and `startStreaming` marks the stream running without re-checking
  `continuousStreamingIntent`. The camera button is disabled during start, so only programmatic
  stops reach it (backgrounding with no glasses, a live session ending). A start-generation token
  is the fix; it belongs with the existing reconnect follow-up (a failed stall recovery is also
  never picked up by the reconnect ladder), not here.
- The frame-rate ladder itself. The picker already offers the legal rungs; P2 may move the default,
  nothing else.

## Risks and how P1 answers them

- **The SDK helper may already decode hvc1.** Then the decoder never runs and the plan still
  delivers the bandwidth win; the two-shape rule makes that case a logged fact, not a mystery.
- **Software decode at 720p/15 fps may cost too much.** The vendor sample runs 24 fps at `.low`
  in software; P2 measures ours, and the codec setting plus the fps picker are the dials.
- **Keyframe interval sets the length of the freeze after a rebuild.** Unknown for the glasses
  encoder; P2 reads it off the lock/unlock trace. If it is long, P3 can request a keyframe by
  bouncing the stream (`stop()`/`start()` on the `Stream`, which keeps the capability).
- **A decoder stall misread as a link stall tears the stream down.** That is the
  `StreamLiveness` rule, and it is tested before any device sees it.

## Files

- `OpenGlasses/Sources/Services/VideoDecoder.swift` — hardened; `DecoderRecoveryPolicy` beside it.
- `OpenGlasses/Sources/Services/Camera/StreamCodecPolicy.swift` — new (codec mapping, frame shape,
  `StreamLiveness`).
- `OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift` — config, listener, liveness,
  tier logging.
- `OpenGlasses/Sources/Utils/Config.swift` — `cameraCodec`.
- `OpenGlasses/Sources/App/Views/ServicesSettingsView.swift` — *Video Codec* row.
- `OpenGlasses/Sources/Utils/PrivacyLog.swift` — new decoder and tier events.
- `OpenGlasses/Info.plist` — `_bonjour._tcp`.
- `OpenGlassesTests/StreamCodecPolicyTests.swift`, `DecoderRecoveryPolicyTests.swift`,
  `StreamLivenessTests.swift`, `VideoDecoderRoundTripTests.swift` — new.
