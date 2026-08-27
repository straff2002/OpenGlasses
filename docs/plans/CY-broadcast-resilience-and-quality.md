# Plan CY — Broadcast Resilience & Stream Quality

**Status: 🚧 Core shipped 2026-08-24**
([#337](https://github.com/straff2002/OpenGlasses/pull/337)) — P1 (pure policy cores), P2 (edge wiring: status
observation, reconnection, adaptive bitrate, configurable encoding) and P3 (Settings + live health
readout) landed. P4 — device/network smoke against a real ingest — is deferred: it needs glasses,
an uplink that can be made to fail on demand, and a streaming account, none of which exist at a
desk.

Going live is the one feature where the failure is invisible to the person it happens to. The
wearer is looking at the world, not at the phone; the LIVE badge stays lit whether or not anything
is reaching the server. So a broadcast that quietly stops is not a degraded experience, it is a
**silent total loss** — and the code shipped up to now had three independent ways of producing one.

## Why

Verified against `BroadcastService.swift` at the time of writing:

1. **Nothing watched the connection.** `startBroadcast` connected once, published, and returned.
   `RTMPConnection` and `RTMPStream` both expose a status sequence; neither was consumed. A network
   flip, a server-side disconnect, or an idle timeout ended the stream while the frame subscription
   carried on appending to a dead mixer at full rate. The wearer's first evidence was a viewer
   telling them afterwards.

   The right shape for the fix was already in the repo — `TwitchChatClient.scheduleReconnect()`
   (attempt counter, capped exponential delay, cancellable task, `wantsConnection` guard) — applied
   to the chat socket but never to the thing chat is *about*.

2. **The frame rate was a literal 15.** `private let targetFPS: Double = 15` drove the bitrate
   derivation, the throttle interval, the frame pacing **and** the `CMTime` timescale. Those four
   agreed only because they read the same constant; the Settings frame-rate picker was never
   consulted by the broadcaster at all. Fifteen is visibly juddery on an ingest that would take 30,
   and the wearer had no way to say so.

3. **The bitrate was chosen once and never revisited.** `VideoBitratePolicy` derived a target at
   start, on the `.rtmp` profile, and that number stood for the whole broadcast. It is right exactly
   once: at start, on the network the wearer was standing on. Walk out of Wi-Fi onto a congested
   cell and the encoder keeps producing more than the link can carry, the send queue grows
   monotonically, and the ingest drops the stream — which is defect 1 again, now self-inflicted.

4. **Audio shipped on defaults nobody had looked at.** No `AudioCodecSettings` call existed anywhere
   in the codebase. The encoder default is 64 kbps AAC, which is audibly thin for anything but
   speech in a quiet room.

5. **Nothing was measurable.** `OutboundFrameRelay` publishes `droppedFrameCount` and no view read
   it. There was no connection state, no throughput, no achieved frame rate — so "it looks fine" and
   "it is dropping four frames in five" were the same picture.

## P1 — Pure policy cores ✅

`Sources/Services/BroadcastResilience.swift`. No HaishinKit, no `AVFoundation`, no network in any
signature. A broadcast drop is the one failure we cannot reproduce at a desk, so the logic that
handles it has to be exercisable without a stream at all.

### `BroadcastSessionState` / `BroadcastSessionMachine`

`idle → connecting → live → reconnecting(attempt:) → failed(reason)`, with the legal transitions as
a table and `apply` returning whether the event was legal *and* changed anything.

That return value is load-bearing, not tidiness: **a dropped connection is reported by both status
sequences**, and the second report must not restart a reconnect that is already running. Two other
rules earn their place the same way — a `connecting` session cannot `drop` (a failure before the
publish is a failed connect, not a lost stream, and routing it through the drop path would start a
reconnect for a stream that was never live), and `stop` is legal from everywhere, because stopping
is the one thing the wearer can always do.

`reconnecting` carries the attempt number because that is what the wearer is owed: "still trying"
reads very differently on attempt 1 than on attempt 7.

### `BroadcastReconnectPolicy`

Capped exponential backoff — 1, 2, 4 … 60 s — with `now` injected on every call. Two properties
that the backoff alone does not give you:

- **The cap.** Uncapped doubling reaches half an hour by attempt 12, at which point the stream is
  gone even though the network came back. A minute is the longest wait that is still a reconnect.
- **The attempt counter resets only after the stream has been *stable*** (60 s live), not the
  instant a connect succeeds. Resetting on connect turns a flapping link into a tight loop hammering
  the ingest every second; requiring a stable stretch means a stream that reconnects and immediately
  drops keeps backing off, while one that ran fine for a minute gets a fresh budget — and a fresh
  give-up horizon with it.
- **A give-up budget** measured from the first failure (5 min), so a long tail of doubling delays
  cannot leave a dead broadcast "reconnecting" for an hour.

### `AdaptiveBitratePolicy`

Takes `BroadcastPressureSample` — target bitrate, measured outbound bitrate, queued bytes, and the
transport's own insufficient-bandwidth verdict — and returns `.hold` / `.stepDown(to:)` /
`.stepUp(to:)`. All numbers; the policy never learns what a socket is.

The asymmetry is the design:

- **Down fast** — a quarter off per decision, floored at `VideoBitratePolicy.Profile.rtmp.minimum`.
  Backpressure is already a backlog; halving the rate at which the backlog grows is not enough.
- **Up slowly** — 10 % of the ceiling, and only after five consecutive healthy samples. A link that
  just recovered is the least trustworthy moment to push it, and an eager climb produces a sawtooth
  the viewer sees as repeated rebuffering.

One rule is there specifically to stop the policy sabotaging a healthy stream: **a zero throughput
measurement is a missing observation, not evidence of starvation.** The first sample of a session
and any stats hiccup both read as zero, and treating those as a starved link walks the bitrate to
the floor on a stream that was fine.

### `BroadcastFrameRateMeter` / `BroadcastHealth`

A rolling `(timestamp, frames since last sample)` meter, and the readout struct the UI binds to.
The configured frame rate is an intention; the achieved one is the outcome, and they diverge for
reasons worth seeing — the privacy blur coalescing frames, the glasses link stalling, thermal
throttling. "30 configured, 6 achieved" is a diagnosis; a lit LIVE badge is not.

## P2 — Edge wiring in `BroadcastService` ✅

- **Status observation.** Both `RTMPConnection.status` and `RTMPStream.status` are consumed for the
  life of a connection, because they report different halves of the same death and which one
  arrives depends on how the link died. The SDK never finishes those continuations on close, so the
  observation tasks are explicitly cancelled — a `for await` over them would otherwise outlive the
  connection it belongs to.

- **Not everything is worth retrying.** A rejected connect, an invalid app, or a stream key already
  publishing elsewhere are the server understanding us and saying no; those go straight to `failed`
  rather than spending the five-minute budget to report the same thing. Likewise the *first* connect
  of a broadcast still fails loudly instead of retrying: nothing is live yet, the wearer is looking
  at the button they just pressed, and a mistyped key should say so immediately.

- **Reconnect resumes the same broadcast.** A drop tears down only the connection objects. The frame
  subscription, the phone source, the mic tap and the source-switch state all stay attached, and the
  retry re-runs the *same* connect → configure → prime → publish method the initial go-live used —
  including the encoder priming, which a republish needs for exactly the reason the first publish
  did (a republish without it lands 0×0 metadata on the ingest). Sharing the method is what stops
  the reconnect path from quietly diverging from the path known to work.

- **Adaptive bitrate against real telemetry.** `BroadcastBitRateController` is an actor conforming
  to the SDK's bitrate-strategy protocol; the transport hands it outbound throughput and queue depth
  on its own ~1 Hz monitor, it translates that into a `BroadcastPressureSample`, and it applies
  whatever the pure policy decides. It holds no judgement of its own.

  **Mid-stream video-settings changes are supported** — verified in the package source: a
  bitrate-only change does not invalidate the compression session, it is applied to the live
  encoder. So adaptation takes effect immediately rather than waiting for a reconnect.

- **Configurable encoding.** `Config.broadcastFrameRate` (default 30; 15/24/30) replaces the literal
  everywhere it was used, timescale included. `Config.broadcastBitrateOverride` feeds
  `VideoBitratePolicy`'s existing `override:` parameter, and is the *ceiling* adaptation works below
  rather than a fixed rate. `Config.broadcastKeyframeIntervalSeconds` (default 2) drives
  `maxKeyFrameIntervalDuration`; `Config.broadcastAudioBitrate` (default 128 000) drives an explicit
  `AudioCodecSettings`.

- **Health accounting.** Session state and a `BroadcastHealth` value are published, refreshed on the
  existing one-second timer. Dropped frames combine two counts that mean the same thing to the
  wearer — frames the privacy relay discarded to keep up (handed over by `AppState` rather than
  reached for, so the service stays constructible without the vision stack), and frames dropped
  because there was no connection to push them to. The second is what makes a reconnect gap visible
  instead of silently shortening the stream.

## P3 — Settings and live readout ✅

- **Settings → Live Streaming → Advanced Encoding**, a disclosure because the defaults are the right
  answer for almost everyone; these exist for the wearer whose ingest or uplink has an opinion, not
  as a decision the rest have to make on the way to going live. Frame rate, video bitrate (Automatic
  previewing the number the policy will actually pick, plus explicit steps), keyframe interval,
  audio bitrate.
- **Live preview health bar** while broadcasting: state (Live / Reconnecting *n*), throughput,
  achieved frame rate, and dropped frames when there are any. Deliberately subtle and monospaced,
  matching the recording-duration capsule above it.

## P4 — Device/network verification (first hardware run, 2026-08-27)

Broadcast to an RTMP ingest on the same network was run on hardware. **The reconnect machinery
works** — the backoff grew exactly as designed, and the session-state machine behaved. What it was
faithfully reconnecting *from* is the finding: the ingest logged connection after connection
opening and timing out after ten seconds having received **zero bytes** — no handshake, no publish.
The initial publish never happened, and nothing in the app noticed or said so.

Two things were wrong on our side of that, independent of whatever the transport was doing:

- **The readout implied flow that did not exist.** `bitrateLabel` fell back to the *target* bitrate
  whenever the transport hadn't reported, so the health bar read "3.7 Mbps · 0 fps" for a connection
  the server never received a byte from. A target is an intention; printing it beside the
  measurement that disproves it is worse than printing nothing. `BroadcastHealth.hasSentAnything`
  now gates it, and the badge says "Nothing sent yet" rather than "Live".
- **Nothing watched for the silence.** `BroadcastStallPolicy` calls a connection stalled when it is
  past a grace period with nothing measured, and the tick reports it once, with copy that names
  iOS's local-network permission when the target is a private address (the most common cause with
  exactly this shape on a fresh install: the app believes it is connected and nothing arrives) and
  stays generic — stream key, server accepting a publish — when it isn't. It does not tear the
  session down; the reconnect may still succeed.

The `NSLocalNetworkUsageDescription` copy also only described discovering AI servers, so the prompt
made no sense in a streaming context; it now covers both.

### What the simulator ruled out

The permission theory was disproved on hardware: the wearer granted Local Network, force-restarted,
went live again, and two fresh attempts showed the identical signature — TCP opened, zero bytes,
server timeout at ten seconds.

So the connect sequence itself was put under a byte-level probe from the simulator: a listener that
records the first bytes of any connection, and two paths driven against it — a bare
`RTMPConnection().connect()`, and our exact order (stream created against the connection, video and
audio codec settings applied, mixer built and wired, then connect). **Both wrote the C0/C1
handshake, byte-identical in shape** (`03 00 00 00 00 …`). Driven against a real RTMP ingest the same
sequence went further still: connect returned, and the publish was accepted — the session went live.

So the publish path, never once proven against a live ingest in the original work, is now proven
from the simulator. It is not what fails.

That refutes the three obvious candidates for our side of it: no deadlock between the main actor
and the status-consumption tasks, no wrong-actor invocation, and no malformed connect URL. Our call
sequence is not what stops the handshake.

**The trigger is therefore device-specific, and the mechanism is most likely below us.** In
HaishinKit's `RTMPSocket`, `send(_:)` returns early when `connected` is false — silently, no throw,
no log:

```swift
func send(_ data: Data) {
    guard connected else { return }
    …
}
```

`RTMPConnection.connect` writes the handshake immediately after the socket reports ready. `connected`
is set true in `stateDidChange(.ready)`, but `viabilityUpdateHandler` runs through a *separate*,
unordered actor hop, and `viabilityDidChange(false)` calls `close()` — which clears `connected` and
`outputs`. A viability flap landing after ready leaves the socket TCP-open with the handshake write
discarded and the receive loop (`while connected`) exiting immediately: precisely the observed
signature, and precisely the kind of flap a phone's local-network machinery can produce and a
simulator never will.

This is **not** proven, and the fix does not depend on it being right.

### What the fix is

Detection, not diagnosis. `NetworkMonitorReport.totalBytesOut` — the transport's own cumulative
count of bytes written — is plumbed through the bitrate controller, per connection attempt. A
connection that has published and still written nothing past a grace period is treated as **dropped**
and routed into `handleConnectionLoss`, so the reconnect machinery gets its shot; if no attempt ever
comes up writable, the reconnect policy's give-up budget ends the session honestly. The per-second
measured bitrate cannot carry this — it legitimately reads zero between keyframes on a healthy
stream — which is why the cumulative count is the signal.

The guard is unconditional rather than gated on the mechanism above, so it holds whatever the real
trigger turns out to be. Nothing in the dependency is forked or patched; the upstream silent-drop is
noted for a report.

### Still owed on hardware

- **A successful publish to a LAN ingest**, once the cause is known.

Everything above is decision logic or wiring and is covered headlessly. What is not:

- **A real mid-stream drop.** Airplane mode on and off, Wi-Fi → cellular handoff, walking out of
  range. Assert the stream resumes on the *same* broadcast and that viewers see a gap rather than an
  end.
- **The reconnect actually republishes cleanly** — the ingest must accept the republish and not
  show 0×0 metadata or a stalled first segment.
- **Adaptation against a genuinely congested uplink**, which is the only place the step-down
  threshold can be tuned honestly. Watch for the sawtooth the slow-recovery rule exists to prevent.
- **30 fps end to end.** The bump from 15 is only worth having if the glasses link and the phone
  encoder sustain it; the achieved-vs-configured readout is the instrument for that.
- **The give-up budget.** Five minutes is a guess until somebody has watched a real outage.

## Out of scope

- **Stream overlays and burn-ins.** Compositing text or graphics into the broadcast is a different
  feature with its own encoder cost; the aspect-fit letterbox stays the only compositing here.
- **Per-destination encoding presets.** Platforms are prefilled with their ingest URL and nothing
  else. Baking each one's recommended ladder in is a maintenance burden that goes stale silently,
  and the derived bitrate plus adaptation already lands inside the bands they publish.
- **The recording path.** `VideoRecordingService` has its own bitrate profile and no network to
  adapt to; nothing here touches it.
- **Chat reconnection.** [CI](CI-broadcast-chat-readback.md) already has it.

## Open questions

- Should a give-up surface a *retry* affordance rather than just ending the broadcast? The wearer
  who walked into a lift wants one tap to resume, not to reconfigure. Left out for now because it
  needs a UI decision about where that lives while the glasses are on the face.
- Is 60 s the right stability window? It is long enough that a genuine flap keeps backing off and
  short enough that a wearer who moves between two good networks is not punished, but that is
  reasoning, not measurement.
- Should the frame throttle follow the *achieved* rate rather than the configured one when they
  diverge badly? Pushing 30 fps of intent into a link delivering 6 spends encoder time on frames
  that will never be sent — but it also hides the divergence the readout exists to show.
