# Plan CZ — Independent Capture Audio

**Status: 🚧 Core shipped 2026-08-24** — P1 (`AudioSourceArbiter`, `AssistantAudioGate`), P2
(`StandaloneMicTapService`), P3 (`CaptureAudioRouter` + broadcast/recorder wiring) and P4 (setting +
copy) landed together. P5 device verification is owed: no hardware in this session, and the two
things that matter most here — whether the standalone engine actually comes up on a Bluetooth
glasses route, and whether the assistant is genuinely inaudible in the captured file — cannot be
asserted headlessly.

## Why

Broadcast and video-recording audio ride the always-on listener's microphone tap. That tap belongs
to `WakeWordService`, it is the only `AVAudioEngine` input tap in the app, and **it only exists
while wake-word listening is running**. `BroadcastService` said so in a comment and left it there:
streams were silent while listening was disabled, "documented limitation".

It is not really a limitation, it is a defect with a note attached. Turning listening off is a
completely reasonable thing to do while streaming — the wearer does not want the assistant waking up
on stage, or in a meeting, or in the middle of a piece to camera. Doing it produced a video-only
stream with no warning of any kind: no error, no banner, nothing spoken. The buffers just stopped,
and the failure was only discoverable by watching the finished recording. The same applied to video
recordings, which use the same tap.

The second defect is the mirror image of the first. When replies play out of the **phone speaker** —
which is what happens whenever the glasses are not connected, or the route has fallen back — the mic
hears them, and they are muxed straight into the outgoing stream and into recordings. Nothing gates
this. The wearer hears the assistant once and the audience hears it twice, over the top of whatever
the wearer was actually saying, offset by the capture latency. Replies rendered into the glasses
never reach the mic at all, so the fix has to be conditioned on the route rather than on "is TTS
speaking" — otherwise the common case gets its real audio blanked for nothing.

Both of these are one question underneath: **what is the microphone source for a capture, and who
decides?** Today the answer is "whatever the wake-word listener happens to be doing", which is why
neither defect had anywhere to live. This plan gives capture its own source and its own decision.

## Scope note — this is not the audio-session work again

- **`AudioSessionCoordinator` / the AO lease line** arbitrates *ownership* of the shared
  `AVAudioSession` between subsystems. CZ is downstream of that: it takes a lease like everybody
  else (a new `captureAudio` owner) and asks a different question — which *engine* feeds capture.
- **[CW](CW-realtime-audio-rig-recovery.md)** is about a realtime session's rig surviving a route
  change mid-reply. CZ does not touch `RealtimeAudioEngine`; the standalone engine here is a plain
  input tap with no playback side and no voice processing.
- **[CC](CC-duplex-live-audio.md)** established the duplex tier for live sessions. Untouched.

## P1 — Two pure cores ✅

Both live in `Sources/Services/AudioCapture/`, both are `AVFoundation`-free in their signatures, and
both are testable as tables.

**`AudioSourceArbiter`** — inputs `wakeListening: Bool` and `captureActive: Bool` (any broadcast or
recording wanting audio); output a `CaptureAudioSource` (`.none` / `.wakeTap` / `.standalone`) plus
the `CaptureAudioCommand` deltas needed to get there. Two rules, each a bug we are choosing not to
have:

- **The shared tap wins whenever it is running.** Two input taps on the same route is not a
  configuration iOS handles gracefully — one of them is silent or garbled and which one is not
  deterministic. So the standalone engine only ever runs in the gap.
- **Nothing runs when nothing is capturing.** An engine that outlives its recording holds the mic,
  and the recording indicator, for no reason.

Commands rather than a desired-state setter, because the ordering *is* the correctness condition: a
handover emits detach-then-attach, in that order, and a test walks every transition to assert an
attach is never emitted without its detach in front of it.

**`AssistantAudioGate`** — inputs `ttsSpeaking`, `ttsOnPhoneSpeaker`, `includeAssistantVoice`;
output `.pass` or `.silence`. Silence only when the assistant is genuinely audible to the mic and the
wearer has not opted in.

## P2 — `StandaloneMicTapService` ✅

A self-contained capture engine, started only by the router and only in the gap. It deliberately
mirrors the shared tap's discipline instead of inventing its own, because every one of those details
is a crash or a hang that was already paid for once:

- the input format is validated (`sampleRate > 0 && channelCount > 0`) **before** the tap is
  installed — a Bluetooth route that has gone away reports a zero format and installing a tap with
  it crashes rather than failing,
- the same 1024-frame buffer size,
- and the tap block touches nothing but a lock-guarded fan-out box (`CaptureAudioFanout`). No
  `@MainActor` state is read from the Core Audio render thread, ever.

Session handling: when the shared tap is down, nothing else has configured the session, so this does
— `.playAndRecord` with the same `MicRoutePolicy` options and the same preferred-input selection the
listener uses, so a handover back to the listener does not re-tune the route underneath the capture.
Ownership goes through `AudioSessionCoordinator` as a new `captureAudio` owner, which means stopping
deactivates *only* if nothing newer has taken the session in the meantime. `captureAudio` is
classified alongside `wakeWord` in `MediaTriggerPolicy` — it is the listener's session by another
name, and treating it as blocking would disable the temple tap for the whole of any recording.

`WakeWordService` is not modified. Its tap box was left alone rather than generalised; the new box is
a separate type with a different job (it carries the gate decision, and no recognition request).

## P3 — `CaptureAudioRouter` ✅

The composite provider that broadcast and recording actually talk to. It conforms to
`BroadcastAudioProviding` — the recorder's own `wakeWordService` reference was replaced with that
same seam, so there is now one protocol for "a source of mic buffers" and three adopters (the shared
tap, the standalone engine, the router).

- **It owns the consumer registry.** Downstream sources get exactly one registration from the router,
  whatever the consumer count.
- **Registering is what declares a capture live.** `captureActive` is simply "the registry is not
  empty", so `startBroadcast`/`startRecording` need no new call and the arbiter cannot drift out of
  sync with reality.
- **It applies the arbiter** against `WakeWordService.isListening` (observed in app bootstrap) and
  re-routes on handover. A consumer registered with the router never learns which source it is being
  fed from.
- **It applies the gate**, and while gated it **zero-fills** rather than dropping.
  `BroadcastService.appendAudio` derives its PTS from a running sample-count clock
  (`BroadcastAudioClock`), so a dropped buffer does not create a gap — it permanently shifts every
  later sample against the video. Silence of the same shape keeps the timeline honest. The silent
  buffer is freshly allocated rather than cached and reused, because consumers hold onto it past the
  call (the broadcast path hops to the main actor with it); the allocation only happens while the
  assistant is actually speaking out of the speaker.

**Wake-word recognition is not routed through any of this.** The recognizer keeps reading the
listener's own tap directly, so nothing here can gate, delay or silence wake-word detection.

## P4 — Setting and copy ✅

`Config.captureIncludesAssistantVoice`, default `false` — clean capture is what almost everyone
wants, and the wearer has already heard the reply. A streamer whose audience is following the
conversation turns it on. Toggle in the Live Streaming section of Settings, with a footer line that
says the audio behaviour plainly. The stale "streams are silent while listening is disabled"
comments in `BroadcastService` and in the [BS](BS-transcript-guard-and-broadcast-breadth.md) plan
doc are corrected rather than deleted, so the history stays legible.

## P5 — Device verification (partly done, 2026-08-27)

### What the device found

The mid-stream handover was run on hardware for the first time, and it broke the recording rather
than the audio. Repro: listening off → start a video recording from the UI → turn listening on
mid-recording → about a second later the recording ends.

Root cause, and it is one the headless suite could not have caught because both fakes pushed the
same format: **the two sources are two `AVAudioEngine`s, and each takes its tap format from
`inputNode.outputFormat(forBus: 0)` — whatever route that engine starts on.** A handover therefore
changes the sample format under the consumers. `VideoRecordingService` built a fresh
`CMAudioFormatDescription` per buffer and appended it, so the first buffer of the new format was
rejected by the audio input and moved the whole `AVAssetWriter` to `.failed` — which takes the
*video* track down with it. Not "the recording lost its audio": the recording died, `finishWriting`
had nothing to hand back, and nothing on that path checked `writer.status` or said a word.

That also explains the recording never appearing in Photos on those attempts: there was no file.

### What the fix is

- **`CaptureAudioNormalizer`** at the router boundary. The first buffer of a capture fixes the
  canonical format; every later buffer is converted into it with a per-source `AVAudioConverter`,
  and matching buffers (the whole steady state, and every capture that never sees a handover) pass
  through untouched. A conversion that fails yields silence of the same duration rather than `nil`,
  because dropping the slot would shift the broadcast's sample-count clock permanently. The format
  is released when a capture ends, so the next one adopts the route it actually starts on.
- **Recorder hardening**, as the second brace: the audio format description is built once and later
  buffers are checked against it and dropped if they disagree; both append paths bail when the
  writer is already `.failed`; a failed writer is reported on `lastSaveNote` instead of passing as a
  successful stop; and `stopRecording` files whatever reached disk even when it is torn down with no
  writer at all (Plan DA's "never delete before a persistent copy exists" applies to abnormal ends
  too, and that path used to return early and skip filing entirely).
- **Diagnostics.** Source handovers, the filer's per-destination outcome and the photo-library
  authorization status now reach the in-app debug log, not just `NSLog`. A field report of exactly
  this class arrived containing nothing but a launch trace, because none of these paths said
  anything a wearer could send.

Covered by new headless tests: sources pushing *different* formats across a handover in both
directions, no buffer dropped, one format out; a new capture adopting its own format; and the
normalizer's conversion, pass-through and reset behaviour directly.

### Still owed on hardware

- **A handover mid-stream, both directions** — now with the fix in place: toggle listening off and
  on during a live broadcast and a recording; assert the finished artefact plays end to end and has
  continuous audio across both switches, by listening to it rather than by counting buffers.
- The rest of the list below is unchanged and still unverified.

### Follow-up, deliberately not taken here

The in-app debug log is per-launch and in-memory, so a report filed after a relaunch misses the
window entirely. Persisting a small ring across launches is the obvious next step and is a separate
change from a bug fix.

Everything above is decision logic or engine construction, and only the first can be tested
headlessly. What cannot:

- **The standalone engine on a Bluetooth glasses route.** The format-validation guard exists exactly
  because that route reports a zero format when it is stale; whether it comes up cleanly from cold,
  with listening off, is the whole question.
- **A handover mid-stream, both directions.** Toggle listening off and on during a live broadcast
  and a recording; assert the finished artefact has continuous audio across both switches, by
  listening to it rather than by counting buffers.
- **The assistant genuinely inaudible.** Play a reply through the phone speaker mid-capture with the
  setting off and confirm the capture is silent there and un-clipped either side of it; then with it
  on, and confirm the reply is present.
- **Mic release.** No recording indicator left on after a capture ends with listening off — the
  standalone engine is the only thing holding the session in that state.
- **No regression to wake-word detection** while a standalone capture runs and after a handover.

## Out of scope

- **Acoustic echo cancellation / voice-processing IO.** The gate is a blunt instrument on purpose:
  it blanks the mic while the assistant speaks rather than trying to subtract it. Enabling voice
  processing on the capture engine would change the character of the captured audio for every wearer
  to solve a problem only the phone-speaker route has, and the listener's own echo behaviour stays
  exactly as it is.
- **Duplex-audio changes.** CC's tier decision is untouched.
- **Other consumers of the shared tap.** Ambient captions, memory rewind, the teleprompter and audio
  recording still register on `WakeWordService` directly. They are not capture, their silence when
  listening is off is expected behaviour rather than a defect, and moving them would be a much
  larger blast radius for no user-visible gain.
- **Warning the wearer that capture audio has changed source.** The point is that the handover is
  invisible. If P5 finds a route where the standalone engine cannot come up at all, *that* deserves
  an announcement, and it should be designed against what actually fails.
- **On-device verification.** No hardware in this session; P5 is deferred, not assumed.

## Testing

`OpenGlassesTests/CaptureAudioTests.swift`, all headless, no `AVAudioEngine` and no `.shared`
service:

- the arbiter as a transition table, including the invariant walk over every conditions pair that
  asserts two sources are never attached at once and detach always precedes attach;
- the gate over all eight input combinations, pinning that route and opt-in are both load-bearing;
- the silencer: same shape, zeroed samples, source buffer untouched, every channel;
- the router against a fake tap and a fake engine — handover in both directions with a consumer
  that must keep receiving, last-consumer-leaving teardown, a failed engine start detaching its own
  registration, and the gate's zero-fill asserted as *buffers still arrive, with no signal*.

## Open questions

- Should a capture that starts while listening is off and then *fails* to bring up the standalone
  engine say so out loud? Currently it logs and the capture is video-only, which is the old
  behaviour for the failure case. Leaning yes, but the wording depends on what P5 finds actually
  fails.
- The gate re-reads the output route when speaking starts, not continuously. A route change *during*
  a single reply therefore keeps the decision it started with. Worth a subscription only if P5 shows
  mid-reply route flips are common enough to hear.
- Should the standalone engine also cover the other shared-tap consumers when listening is off (a
  recording with auto-transcription currently gets no captions in that state)? That is a bigger
  question about what "listening off" means, and it should be answered deliberately rather than as a
  side effect of this plan.
