# Plan HW: Glasses Stream Integrity (keyframes, raw frames under lock, the link we are really on)

**Status:** 🚧 P0 and P1 built 2026-10-10, both headless. P0: keyframes read from the bitstream,
the leading-picture rule, the hold's patience, three evidence log lines. P1: raw frames converted
on the CPU when the SDK's helper cannot draw them, a link-level probe with a support-report line,
one log line per stall episode. Nothing here has been verified on glasses: that is P2, a device
session still owed, which rides with Plan [EO](EO-hevc-glasses-stream.md) P2 and Plan
[HJ](HJ-camera-stream-end-recovery.md) P2.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (sections 3 and 5).
Outside field reports on DAT 1.0.0 exposed three places where our stream code rests on an
assumption nobody has checked on hardware: that the SDK marks non-keyframes, that a raw frame is
either a picture or nothing, and that video rides Wi-Fi. A fourth item, short stalls that heal on
their own, is evidence to collect before anyone changes the stall detector.
**Priority:** P1 for anything that streams with the phone locked. The keyframe item is a likely
correctness bug in shipped code (EO P1), not a refinement.
**Surfaces:** One new pure parser, one widened frame-shape rule, log events, one support-report
line. No SDK change, no experimental API, no new setting visible to the wearer.

Evidence paths are under `OpenGlasses/Sources/` and line numbers are as recorded by the review at
`7a0cc0e0` (build 480); they were re-read on `main` at `48bcae0c` for this plan and still match.

---

## Why

1. **The keyframe hold probably never holds.** `VideoDecoder.isKeyframe` reads
   `kCMSampleAttachmentKey_NotSync` and treats an absent attachment array, entry or key as a
   keyframe (`Services/VideoDecoder.swift:239-249`). Both hold gates depend on it (`:185` after a
   build, `:200` after a rebuild). A field report says the DAT stream never sets the attachment, so
   every sample reads as a keyframe, `KeyframeHold` (`Services/Camera/StreamCodecPolicy.swift:161`)
   admits the first sample after a rebuild, and a decoder rebuilt after the phone locks starts on a
   mid-GOP P-frame. Our round-trip tests cannot see this: they encode simulator clips with
   VideoToolbox, which does set `NotSync` (`OpenGlassesTests/VideoDecoderRoundTripTests.swift:71-87`).
   EO's own P1 findings state the absence rule as correct; it is correct for VideoToolbox and
   unverified for the glasses.
2. **Raw frames are dropped while locked.** The SDK's `makeUIImage()` helper renders on the GPU,
   which iOS denies a backgrounded app, so it returns nil. A raw frame carries an image buffer and
   no data buffer, so `StreamCodecPolicy.shape` classes it `.empty` and `action(for:)` maps that to
   `.drop` (`Services/Camera/StreamCodecPolicy.swift:46-56`; `Services/Camera/GlassesFramePipeline.swift:63-70`).
   With the raw escape hatch selected, the picture stops at lock even though the pixels arrive.
   The CPU conversion that would save it already exists: EO P1 replaced a `CIContext` with a
   `CGContext` laid over the locked base address for exactly this reason
   (`VideoDecoder.makeImage(from:)`, private, `Services/VideoDecoder.swift:144`).
3. **We are probably on Bluetooth Classic, not Wi-Fi.** We ship the ExternalAccessory keys
   (`OpenGlasses/Info.plist:298-309`) and neither entitlements file carries Hotspot Configuration or
   Wi-Fi info. Two independent field reports say the SDK picks its transport from configuration and
   that this configuration keeps it on Bluetooth Classic. Three documents assume Wi-Fi: EO
   (`docs/plans/EO-hevc-glasses-stream.md:58`), the `StreamConfigPolicy` premise comment
   (`Services/StreamRecoveryPolicy.swift:143-145`) and `.claude/rules/dat-conventions.md:164`. No log
   we keep records which link carried a session.
4. **Short stalls sometimes heal themselves.** The same field work saw brief stalls resume without
   a rebuild. Our detector rebuilds after 1.5 s without a sample (`StreamLiveness`, EO P1), and the
   first rebuild of an episode costs a cold start. Whether a grace period would help us is unknown,
   and the rebuild must not be changed on a hunch.

## Scope

**In:** bitstream keyframe detection for HEVC samples with the attachment as a fallback; dropping
leading RASL pictures after a CRA; a fourth frame shape for raw pixels routed through the existing
CPU conversion; a link-level diagnostic in the support report; log-only evidence about stall
self-healing; the device session that turns all of it into findings.

**Non-goals:**
- Turning Wi-Fi on. Adding the Hotspot Configuration entitlement or Wi-Fi keys costs about 10 s per
  session, a join prompt and the phone's Wi-Fi internet while connected. Bluetooth Classic was
  measured at 29 to 32 fps at 504x896 in the field. Whether to add Wi-Fi is a decision for after
  P2, with its own plan if the answer is yes.
- Correcting EO, the `StreamConfigPolicy` comment or `.claude/rules/dat-conventions.md` before a
  device confirms the link level. See P2.
- Changing the first-rebuild behaviour of the stall detector in this plan. P1 only records.
- The per-session codec rung under lock. That is Plan HJ P3 and stays there; this plan makes raw
  frames survive the lock, HJ decides whether raw should be used under lock at all.
- Any DAT **[Experimental]** API.

## Design

### 1 · `HEVCNALInspector` (pure)

*As built this is `NALUnitInspector`, and several details below were corrected while building it.
The text here is the design as drafted; the "Built 2026-10-10" note under P0 lists what changed.*

New file `Services/Camera/HEVCNALInspector.swift`. Input: the sample's data buffer bytes and the
NAL length-prefix size from the format description's `hvcC` (normally 4). Output:

```swift
enum HEVCNALInspector {
    enum PictureKind: Equatable {
        case randomAccess(nalType: UInt8)   // IRAP: 16...23 (BLA, IDR, CRA, reserved IRAP)
        case leadingSkipped(nalType: UInt8) // RASL: 8, 9
        case nonRandomAccess(nalType: UInt8)
        case unparseable
    }
    static func firstSliceKind(_ bytes: UnsafeRawBufferPointer, lengthSize: Int) -> PictureKind
    static func hasParameterSets(_ bytes: UnsafeRawBufferPointer, lengthSize: Int) -> Bool // VPS 32, SPS 33, PPS 34
}
```

- Walks length-prefixed NAL units, reads `nal_unit_type = (byte0 >> 1) & 0x3F`, skips parameter
  sets, SEI (39, 40), AUD (35) and other non-VCL units, and classifies the **first VCL NAL**
  (types 0 to 31). Never reads past a declared length; a length that overruns the buffer is
  `.unparseable`.
- `VideoDecoder.isKeyframe` becomes: parse first; `.randomAccess` is a keyframe;
  `.nonRandomAccess` and `.leadingSkipped` are not; only `.unparseable` falls back to the
  attachment rule as it stands today.
- **RASL after CRA.** After a hold is released by a CRA (type 21), leading RASL pictures reference
  frames the fresh decoder never saw. `KeyframeHold` gains a `releasedByCRA` flag; while it is set,
  `.leadingSkipped` samples are dropped (the last good frame stays), and the first non-RASL sample
  clears it. IDR and BLA release the hold without the flag.
- **Once-per-stream evidence.** The pipeline logs, once per stream, whether the first samples
  carried `NotSync` at all and whether the parser and the attachment agreed
  (`PrivacyLog.camera(.decoder, .keyframeSource, detail: parser|attachment|both|disagree)`). That
  single line answers the field report for our devices and feeds EO P2's findings. The review's
  field note reports a 45-frame GOP (3 s at 15 fps); P2 records ours from the interval between
  `.randomAccess` samples.

### 2 · `.rawPixels` frame shape

`StreamCodecPolicy.FrameShape` gains `.rawPixels`: no helper image, no data buffer, but an image
buffer (`CMSampleBufferGetImageBuffer != nil`). `shape(helperProducedImage:hasDataBuffer:hasImageBuffer:)`
takes the third observation; `action(for: .rawPixels)` is a new `.convert`. The CPU conversion in
`VideoDecoder.makeImage(from:)` moves to a small internal `PixelBufferImageConverter` (still a
`CGContext` over the locked base address, no GPU) that both the decoder and the pipeline call.
`GlassesFramePipeline.picture(for:)` handles `.convert` like `.emit` for liveness (a converted
picture is a picture produced). A pixel format the converter does not handle (anything other than
32BGRA, or the bi-planar YUV the SDK may hand over) is converted through vImage when it is a
known YUV format and otherwise stays `.drop` with a once-per-stream `unsupportedPixelFormat` log
line naming the four-character code, so P2 sees it rather than guessing.

This is the CPU path Plan HJ does not cover: HJ P3's codec rung decides whether a raw stream
should become hvc1 under lock; until then, and for anyone who chose raw, the frames that arrive
are shown.

### 3 · Link-level diagnostic (`GlassesTransportProbe`)

*The level names in this section are the wrong way round, the subsystem it reads was never
seen, and the "inference" was not built. The text is the design as drafted; the "Built
2026-10-10" note under P1 says what the SDK's binaries and the code corrected.*

The SDK exposes no transport API (`.claude/rules/dat-conventions.md`: Wi-Fi transport is
transparent). Two sources of evidence, both recorded, neither trusted alone:

- **The SDK's own log line.** MWDATCore logs a link level when a session comes up (`.medium` is
  Wi-Fi, `.low` is Bluetooth, per the field reports). The app can read its own process's entries
  through `OSLogStore(scope: .currentProcessIdentifier)`. `GlassesTransportProbe` reads entries
  from the MWDATCore subsystem written since the session started, and a pure
  `TransportLevelParser` maps a matching line to `.wifi`, `.bluetoothClassic` or `.unknown`. If
  the SDK's wording changes the result is `.unknown`, never a guess.
- **Inference.** The delivered frame size and rate over the first 30 s (already logged by EO P1's
  `tierResolved` and `frameReceived`). Recorded beside the parsed level, labelled as inference.

The result goes into the support report (`App/SupportReporting.swift`) as one line under the
glasses section: "Glasses video link: Bluetooth (from the glasses software's log)" or "…: not
known". It is also a `PrivacyLog.camera(.glasses, .transportLevel, …)` event with no identifiers.
Reading the process log store is local and adds no egress; the probe never reads another
process's logs. Strings in the support report carry no plan letters.

### 4 · Stall self-heal evidence (log-only)

In `MetaCameraBackend.startStallDetection` (`Services/Camera/MetaCameraBackend.swift:1302`, the
`.linkStalled` arm at `:1337`), record for every stall episode:

- seconds since the last sample at the verdict;
- whether any sample arrived on the old stream between the verdict and the rebuild's teardown
  (`StallEpisodeRecord.sampleBeforeTeardown`);
- the rebuild tier used and seconds to the first fresh picture after it.

A pure `StallEpisodeRecord` collects these and emits one log line per episode. Behaviour does not
change. P2 adds a Developer-panel switch (off by default, Debug and TestFlight only) that delays
the **first** rebuild of an episode by a grace of up to 3 s and records whether samples resumed
inside it. Only P2's numbers can justify a shipped grace; that change, if made, is a P3 PR.

## Phases

### P0: keyframes from the bitstream (one PR)

- `HEVCNALInspector` with `firstSliceKind` and `hasParameterSets`.
- `VideoDecoder.isKeyframe` uses it, with the attachment as fallback.
- `KeyframeHold` gains the RASL-after-CRA rule.
- Once-per-stream `keyframeSource` log line.

**Tests:** `HEVCNALInspectorTests` with hand-built byte fixtures: IDR_W_RADL (19), IDR_N_LP (20),
CRA (21), BLA (16), TRAIL_R (1), RASL_N (8), parameter sets before the slice, SEI before the
slice, a 3-byte and a 4-byte length prefix, a truncated length, an empty buffer. A
`VideoDecoderKeyframeTests` case that strips the `NotSync` attachment from a simulator-encoded
P-frame and asserts the hold still refuses it (the field failure reproduced headless).
`StreamLivenessTests` gains "a RASL after a CRA is held". Existing `VideoDecoderRoundTripTests`
stay green unchanged.

**Built 2026-10-10.** Headless only; no glasses were involved. What the code corrected in the
design above:

- **Line numbers**, re-read on `main` at build 491: `VideoDecoder.isKeyframe` was at
  `Services/VideoDecoder.swift:243-251`, not `:239-249`. The two hold gates were still at `:185`
  and `:200`, and `KeyframeHold` at `Services/Camera/StreamCodecPolicy.swift:161`.
- **The parser is `NALUnitInspector`** (`Services/Camera/NALUnitInspector.swift`), and it reads
  H.264 as well as HEVC. The SDK's `VideoCodec` offers only raw and hvc1 today, but `VideoDecoder`
  accepts H.264 and the parser is where a keyframe is defined. For H.264 only an IDR (type 5)
  counts; a stream that marks recovery points without sending an IDR is covered by the patience
  rule below.
- **`PictureKind` grew two things.** `leadingDecodable` for RADL pictures (types 6 and 7), which
  reference nothing from before their random-access point and so decode wherever the decoder
  started. And a `leadingMayBeUndecodable` marker on `randomAccess`, true for CRA (21) and
  BLA_W_LP (16), the two types that may be followed by RASL pictures.
- **The leading-picture rule follows that marker, not "CRA".** The plan said IDR and BLA release
  the hold without the flag. BLA_W_LP can carry RASL pictures too, so it sets it; BLA_W_RADL and
  BLA_N_LP do not. The rule applies only to a decoder that *starts* on such a picture: one that
  meets a CRA mid-stream has the references.
- **A RADL does not end the rule.** The plan said the first non-RASL sample clears the flag. RADL
  and RASL pictures may be interleaved, so a RADL passes and the rule stays; it ends at the first
  trailing picture or the next random-access picture. A sample the parser cannot read passes
  without ending it.
- **The parser refuses more than an overrunning length.** A truncated length field, a unit
  shorter than its header, a slice with no data after its header, a set forbidden bit, an HEVC
  header whose temporal id field is zero, a prefix size outside 1 to 4, an empty buffer and a
  sample with no slice in it are all `.unparseable`. The prefix size comes from the format
  description; if that cannot be read the sample is `.unparseable` rather than assumed to be 4.
- **Patience (new).** This change turns a hold that probably never held into one that holds for
  real. On a stream whose places to start the parser does not recognise (gradual refresh with no
  random-access picture, say) that would be a black camera, on hardware that cannot be tested at
  a desk. So the hold counts the readable samples it has refused, across rebuilds, and at
  `KeyframeHold.patience` (240: more than five of the field note's 45-sample GOPs, 8 s at 30 fps)
  it stops believing the parser and lets the attachment decide, which is the behaviour that
  shipped before. A random-access picture actually arriving restores the parser. The decoder logs
  `keyframeHoldAbandoned` when this happens; **seeing that line in P2 means the parser is wrong
  about the glasses stream** and needs another look before anything else.
- **`keyframeSource` is as designed, with one addition.** Its `detail` is one of the four words:
  `parser` (a non-keyframe the attachment would have passed: the field report confirmed), `both`,
  `disagree` (a random-access picture marked `NotSync`), `attachment` (30 unreadable samples: the
  fallback is what is in force). `state` says what the attachment on the deciding sample was
  (`notSyncAbsent`, `notSyncSet`, `notSyncClear`) and `count` how many samples had been seen. A
  random-access picture without `NotSync` settles nothing and is never the deciding sample.
- **`keyframeInterval` (new).** The P2 table read GOP length from a "decoder log" that nothing
  wrote. This line is written once per stream when the second random-access picture arrives:
  `count` is the samples since the first, `detail` the kind of picture (`idr`, `cra`, `bla`,
  `irap`), `state` whether it carried its own parameter sets (`parameterSetsInBand` or
  `parameterSetsOutOfBand`), which is what `hasParameterSets` is for.
- **Per stream means per stream.** The evidence starts again when a stream is torn down
  (`GlassesFramePipeline.reset()`), not when the decoder is rebuilt inside one. The hold's
  patience is not reset by either.

Tests as built: `NALUnitInspectorTests` (hand-built bytes, both codecs, every refusal above, and a
run of arbitrary bytes that must never take it past the end of a buffer), the hold's cases in
`StreamLivenessTests`, `KeyframeEvidenceTests`, and `VideoDecoderKeyframeTests`, which re-wraps
simulator-encoded samples with no attachments and drives the real decoder: a P-frame is refused,
a decoder rebuilt mid-GOP waits for the next keyframe, and the parser agrees with the encoder's
own marking on every sample of an HEVC and an H.264 clip. `VideoDecoderRoundTripTests` is
unchanged.

Checked while building, with the parser switched off so that only the attachment rule ran: the
round-trip tests all still passed, and the new decoder tests failed. In particular the P-frame
with no attachments went into a fresh session and came out as a 320x240 picture. VideoToolbox
does not refuse a frame whose references it never saw; it draws something. That is the field
failure, and it is why the hold has to be right rather than relying on the decoder to object.

### P1: raw pixels, link probe, stall evidence (one PR)

- `.rawPixels` shape and `.convert` action; `PixelBufferImageConverter` shared by decoder and
  pipeline.
- `GlassesTransportProbe` + `TransportLevelParser`; support-report line; log event.
- `StallEpisodeRecord` logging (no behaviour change).

**Tests:** `StreamCodecPolicyTests` for all four shapes (a raw frame with a helper image is still
`.picture`, so a foreground raw stream is unchanged); `PixelBufferImageConverterTests` (a 32BGRA
buffer converts with the right size, an unsupported format returns nil and logs once);
`TransportLevelParserTests` over fixture log lines (Wi-Fi, Bluetooth, a reworded line gives
`.unknown`); a new `SupportReportGlassesLineTests` beside `SupportReportRecipientTests`,
asserting the line is present and plan-letter free;
`StallEpisodeRecordTests` (fake clock). `OutboundFrameConsumerTests` unaffected: no new consumer.

**Built 2026-10-10.** Headless only; no glasses were involved. What the SDK's binaries and the
code corrected in the design above:

- **The link levels are the other way round.** Design §3 says `.medium` is Wi-Fi and `.low` is
  Bluetooth. The SDK's camera module contains the sentence "requires medium (BTC) or high (WiFi)
  bandwidth link", so `high` is Wi-Fi and `medium` is Bluetooth Classic. `low` is Bluetooth Low
  Energy by elimination: the SDK has those three transports and nothing in it ties the name to
  the radio, so the code marks that one as inferred. `GlassesTransportLevel` is `wifi`,
  `bluetoothClassic`, `bluetoothLowEnergy`, `unknown`.
- **The lines the parser reads.** The SDK's core module holds two format strings that name a
  level in use: "DeviceManager: Device … connected with … link, requesting firmware version" and
  "DeviceManager: .medium link unavailable (…), falling back to .low". The interpolated parts
  have not been seen. `TransportLevelParser` finds a whole-word `low`, `medium` or `high` between
  "connected with" and "link" (with or without a leading dot or a type in front), or after
  "falling back to". The latest line about the link wins. A connection line whose level it
  cannot read makes the answer `unknown` rather than leaving an older level standing, and a line
  that is not one of the two is ignored: the transports' own error lines, and "Neither .medium
  nor .low link levels are available", name no link in use.
- **The SDK keeps a log file in our container**, which the plan did not know:
  `Library/Caches/MetaWearablesDAT/Logs/MetaWearablesDAT.log`. On the one phone looked at it
  holds error-level lines only, each "[ARCLog] [error] [tid:N] [function] [File.swift:LINE]
  message", with no timestamps. Since August that copy has 161 mentions of the Bluetooth Classic
  transport (errors as the accessory disconnects), no Wi-Fi line at all, and none of the device
  manager's lines. That is suggestive and proves nothing about which link carried video: an
  errors-only log says which transport failed, and the device manager's lines are either below
  error level or were never written. Settling it stays P2's job.
- **Two sources, read by what the message says.** `GlassesTransportProbe` reads the process's
  own unified log (`OSLogStore(scope: .currentProcessIdentifier)`, narrowed by a predicate on
  `composedMessage` containing "DeviceManager:") and that file. The plan read "the MWDATCore
  subsystem"; nobody has seen which subsystem the SDK logs under, or whether those lines reach
  the unified log at all. Each source is parsed alone and the answer says which it came from
  (`processLog` first, because its entries carry dates; `sdkLogFile`; `none`).
- **Read back to the launch, not to the start of the stream.** A device connects when the
  glasses come into reach, which can be long before a stream, so the line that names the link is
  usually older than the stream it describes. The level in force when the stream starts is the
  session's starting point, and a different level after that is "changed during the session".
  The file has no timestamps, so its length is taken before the SDK is configured
  (`WearablesBootstrap`) to tell this launch's lines from an older one's, and again when a
  stream starts. Lengths come from `FileHandle`; no file date or attribute is read. A file
  shorter than its mark is read from the beginning, at most the last 256 KB is read, and a
  missing file is `unknown`.
- **Size and rate are facts, not a level.** The plan's "inference" from frame size and rate was
  not built. Nothing ties a size or a rate to a link: the one field measurement to hand had
  Bluetooth Classic at 29 to 32 fps at 504x896. `StreamDeliveryMeter` measures the pictures the
  app received in the first 30 s of a stream (size, and the rate from the first picture to the
  end of the window) and they are written beside the level in the log line and the support
  report.
- **The log line and the report line.** `transportLevel` is written once, 31 s into a stream
  that is still the current one: `detail` is the level, `state` the source, with `width`,
  `height` and `frameRate`. The support report always carries one line, for example "Glasses
  video link: Bluetooth Classic (from the glasses software's log); picture 504×896 at 30 fps",
  "…: not known; picture …" or "…: not known (no video since the app started)". Building a
  report reads the sources once more, so a change since the 31 s read shows. Starting and
  ending a stream only asks the file its length, because a photo starts and stops a stream too;
  a stream that has ended is read once, up to where it ended, the first time anyone asks.
- **Nothing to declare.** Both reads are inside the app's own sandbox, nothing is sent, and no
  line is kept: only the level leaves the parser. No required-reason API is used, so
  `PrivacyInfo.xcprivacy` and the privacy copy are unchanged.
- **What raw under lock really did.** The plan says the picture stops. The code shows more:
  a dropped `.empty` frame stamps neither liveness clock, so a raw stream under lock read as a
  link stall although every frame was arriving. The detector rebuilt the stream, the rebuilt
  stream delivered more frames nobody could draw, `waitForStreaming(requireFreshFrame:)` timed
  out each time, and `StallRecoveryBackoff` waited longer, stepped the tier down and after six
  frameless rebuilds stopped the camera with its notice. A `.rawPixels` frame is now converted,
  counts as a picture and stamps both clocks. This rests on the field claim that
  `makeUIImage()` returns nil in the background; if it does not, the helper's picture is used
  as before and nothing changes.
- **`PixelBufferImageConverter`** handles 32BGRA as before, and the two bi-planar 4:2:0 formats
  (`420v` video range, `420f` full range) through vImage on the CPU, with the matrix the buffer
  names (Rec. 601 when it says so, Rec. 709 otherwise). Anything else is dropped with
  `unsupportedPixelFormat`, once per stream, naming the four-character code (in hex when the
  code is not text). A format it does handle that still produces nothing writes
  `pixelConversionFailed` (new) instead, so the two are not confused. Neither stamps a clock.
- **`stallSelfRecovered` already covers part of §4.** Frames returning during the backoff wait
  before a *later* rebuild were already logged. The first rebuild of an episode has no wait, so
  its only window for self-healing is the teardown itself, and that is what `stallEpisode` adds.
  One line per `.linkStalled` verdict, written when the episode is over: `state` is how it ended
  (`recovered`, `noPicture`, `rebuildFailed`, `selfRecovered`, `gaveUp`, `cancelled`), `detail`
  the rebuild used, `silence` the seconds without a sample at the verdict (a new log field),
  `count` the samples that arrived from the old stream between the verdict and the end of its
  teardown, and `seconds` the time from the end of the teardown to the first fresh picture, good
  to a fifth of a second. The reconnect ladder shares `recoverFromStall()` and writes none. No
  call, delay, counter or existing log line moved.
- **Line numbers**, re-read at build 491: the accessory keys are at `OpenGlasses/Info.plist:315-326`,
  not `:298-309`; `startStallDetection` was at `MetaCameraBackend.swift:1429` and its
  `.linkStalled` arm at `:1464`, not `:1302` and `:1337`; `VideoDecoder.makeImage(from:)` was at
  `:152`, not `:144`; the Wi-Fi line in the DAT conventions is `:195`, not `:164`; the
  `StreamConfigPolicy` premise comment is `Services/StreamRecoveryPolicy.swift:143-148`, not
  `:143-145`. EO's paragraph is still at `:58`. There is one entitlements file for the app, not
  two, and it carries neither Hotspot Configuration nor Wi-Fi info.
- **Open questions, as answered here.** (1) Shipped in every build: the read is local and the
  support report is where a field problem is diagnosed. (2) No: the report does not state an
  inferred level, because there is nothing to infer one from; it states the size and rate as
  what they are. (3) Still open for a device, and no longer blocking: 32BGRA and both bi-planar
  formats are converted, and anything else is named in the log.

Tests as built: `StreamCodecPolicyTests` (four shapes), `PixelBufferImageConverterTests` (pixel
values for 32BGRA, colour within a tolerance for both ranges and both matrices, the unsupported
cases), `GlassesFramePipelineTests` (sample buffers made in the test, no SDK frame),
`TransportLevelParserTests`, `GlassesTransportProbeTests` (injected sources, the real file reader
against temporary files, and one test that writes a line to the unified log and reads it back
through the real reader), `StreamDeliveryMeterTests`, `SupportReportGlassesLineTests`,
`StallEpisodeRecordTests`.

**P2 must look at, first:** whether a `transportLevel` line ever names a source other than
`none`. If the device manager's lines do not reach the unified log (or arrive with the level
redacted, which reads as `unknown`) and the file stays errors only, this probe cannot answer and
the link has to be read another way, for example from a sysdiagnose taken during a stream.

**Gates (both PRs):** full suite and Release build green, `SWIFT_EMIT_LOC_STRINGS=NO` on headless
builds, privacy-logging gate, build number bumped on main after merge; this Status line and the
index row updated in the same PR.

### P2: device session (findings only)

Rides with EO P2 and HJ P2: one wearing session, Direct mode and Gemini Live, phone locked for part
of each run, `{hvc1, raw} × {high, medium}`.

| Measure | Read from |
|---|---|
| Whether DAT sets `NotSync`; parser and attachment agreement | `keyframeSource` |
| GOP length (samples between random-access pictures) | `keyframeInterval` |
| Whether the hold ever gave up on the parser (it should not) | `keyframeHoldAbandoned` |
| Frames shown after lock with raw selected, before and after P1 | `frameShape` (`rawPixels`), `frameReceived`, `unsupportedPixelFormat`, `pixelConversionFailed` |
| Link level per session, and whether it ever changes mid-session | `transportLevel`, the support report's "Glasses video link" line, the SDK's log file |
| The exact wording of the device manager's link lines, and where they are written | the unified log during a stream, the SDK's log file |
| Stall episodes: self-heal before teardown, with and without the grace switch | `stallEpisode` |

**Only after P2 confirms the link level on a device**, and in the same PR as the findings: correct
EO's "Wi-Fi transport gate" paragraph (`EO-hevc-glasses-stream.md:58`), the `StreamConfigPolicy`
comment (`Services/StreamRecoveryPolicy.swift:143-145`) and the Wi-Fi line in
`.claude/rules/dat-conventions.md:164`, quoting the observed level. (Line numbers as drafted; the
P1 note has them re-read.) If the device says Wi-Fi after
all, those documents stay and this plan records why the field reports did not apply to us.

### P3: what P2 justifies (separate PRs)

- A first-rebuild grace in the stall detector, if P2 shows stalls heal inside it often enough to
  beat a cold start.
- A Wi-Fi transport decision, as its own plan, if Bluetooth Classic proves too slow for a feature
  we want.

## Open questions

1. Is reading the process's own `OSLogStore` acceptable for a shipped diagnostic, or Debug and
   TestFlight only? Recommended: shipped, because the support report is where a field problem is
   diagnosed, and the read is local.
2. Should the support report state the inferred level when the log line is missing? Recommended:
   yes, labelled "estimated from picture size and rate".
3. Does the SDK ever deliver raw frames as bi-planar YUV? P2 answers it; P1 handles 32BGRA and
   logs anything else.

## Dependencies

- **EO** (🚧 P1 implemented, P2 owed): this plan corrects an EO P1 assumption and shares its device
  session.
- **HJ** (📋 Planned, nothing built, verified 2026-10-10: no `StreamEndRecoveryPolicy` in the tree):
  owns the codec rung under lock; shares P2.
- **BR** and **FD** (shipped): the stall detector and reconnect ladder this plan only observes.
