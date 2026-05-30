# Plan L — Real WebRTC Expert Transport

> **Status: app-side implemented.** The `WebRTC` SwiftPM dependency is added, `WebRTCPeerTransport`
> creates a real `RTCPeerConnection` (outbound glasses video via a custom capturer + mic audio,
> inbound expert audio, SDP/ICE over a WebSocket `ExpertSignalingClient`), `isAvailable` is true, and
> Settings expose signaling/STUN/TURN config. The user picks MJPEG or WebRTC in Field Assist settings.
> **Still external (not in-app):** a signaling relay server, a TURN server, and the expert-side web
> client. The live connection path is not unit-tested (needs two peers + servers); compile-correct
> and wired. Remaining items below are the server/infra + audio-session hardening.

**Builds on:** the transport seam shipped in Plan K. `ExpertStreamTransport` already abstracts the stream, `WebRTCPeerTransport` is a conformer with `isAvailable = false`, `ExpertStreamBridge` selects by `Config.expertStreamTransport`, and the Settings picker exists. This plan fills in `WebRTCPeerTransport` for a true peer-to-peer connection — **two-way A/V, low latency** — replacing the one-way MJPEG-to-browser path for the "Human+AI" Field Assist Pro tier.

**Strategic fit:** Unlocks genuine remote-expert collaboration (expert talks back, sub-second latency) — the headline capability of enterprise remote-assist products. Required to make Field Assist Phase 5 real.

**Effort:** ~1.5–2 weeks (library + signaling + TURN + audio + device testing). The bulk is infra/testing, not app glue — the seam is done.

---

## The hard parts (why this isn't just an app change)

A WebRTC peer connection needs three things the app doesn't have:

1. **A WebRTC implementation.** No pure-Swift option is production-grade; use a prebuilt binary. The `WebRTC` SwiftPM package (Apple-platform `WebRTC.xcframework`, ~tens of MB) is already declared in `Package.swift` — prefer the maintained SwiftPM xcframework over the unmaintained CocoaPods `GoogleWebRTC`. This is a large binary dependency; gate it behind the `webrtc` transport so MJPEG builds stay lean.

2. **A signaling server.** WebRTC needs an out-of-band channel to exchange SDP offer/answer + ICE candidates. The existing `WebRTCStreamingService` already runs a WebSocket to a signaling/relay endpoint (`connectWebSocket`) — extend that server (or stand up a small one) to relay SDP/ICE between glasses-app and expert browser, not just MJPEG frames.

3. **A TURN server.** Field techs are often on cellular/NAT'd networks; STUN alone won't connect. Need a TURN server (coturn, or a managed service like Twilio/Cloudflare) with credentials provisioned to both peers.

---

## App-side work (slots into the existing seam)

- **`Sources/Services/FieldAssist/WebRTCPeerTransport.swift`** — replace the stub body:
  - Create `RTCPeerConnectionFactory`, a peer connection with the TURN/STUN `iceServers`.
  - **Outbound video:** feed `CameraService.framePublisher` (UIImage) → `RTCVideoSource` via a custom capturer (convert `UIImage`/`CMSampleBuffer` → `RTCVideoFrame`). The frames already flow; this is the encode path.
  - **Outbound audio:** add the device mic track (`RTCAudioTrack`). Coordinate with `WakeWordService`/TTS audio-session ownership (the app already arbitrates the audio session — must not fight it).
  - **Inbound audio:** the expert's voice track → play out (route through the glasses/phone per the existing audio-session logic).
  - SDP offer/answer + ICE exchange over the signaling WebSocket.
  - `isAvailable = true`; `start()` returns the expert join URL; `stop()` closes the connection.
- **`Config`** — TURN/signaling endpoint + credential fields (Settings, alongside `expertWebhookURL`).
- **Expert-side client** — a web page that joins the room, shows the glasses video, and sends the expert's mic. Can extend the existing browser viewer used by the MJPEG path.

No changes needed to `ExpertStreamBridge`, `EscalationCoordinator`, `ExpertStreamTransport`, the Settings picker, or callers — the seam was built for exactly this swap.

## Audio-session coordination (the subtle risk)

OpenGlasses already juggles the `AVAudioSession` across wake word, transcription, TTS, and recording. A live WebRTC call wants the session in `.playAndRecord` with the right mode/options and owns mic + speaker for the call's duration. This must be sequenced with `WakeWordService`/`TextToSpeechService` (likely: pause wake word + suppress TTS while an expert call is connected, mirroring how realtime sessions already gate the pipeline). Get this wrong and you get no audio, echo, or a wedged session.

## Build order

1. Add the `WebRTC` SPM dep behind the `webrtc` transport; confirm a no-op peer connection constructs on-device.
2. Stand up signaling relay (extend the existing WebSocket server) + a TURN server with test credentials.
3. Outbound video capturer (UIImage → RTCVideoFrame) — expert sees the glasses feed.
4. Two-way audio + audio-session coordination with wake word/TTS.
5. Expert-side web client (join, view, talk).
6. Flip `WebRTCPeerTransport.isAvailable`; remove the "not available" Settings label.
7. On-device testing across Wi-Fi + cellular (TURN relay path).

## Testing reality

- The peer-connection/audio path **cannot be unit-tested** meaningfully — it needs two live endpoints + TURN. Plan for manual device-to-browser test matrices (same LAN, cross-network, cellular).
- Keep app-side glue (frame conversion, SDP/ICE message encoding, audio-session state transitions) in pure, testable helpers where possible.

## Open questions

- Managed TURN (Twilio/Cloudflare, per-minute cost) vs self-hosted coturn? *Recommendation: managed for MVP, self-host later for cost.*
- Record the expert call into the session audit (consent + storage)? Ties into `SessionExport`.
- Multi-party (more than one expert)? Out of scope for v1 — 1:1 tech↔expert.

## Dependencies / prereqs

- Plan K transport seam (shipped). New: WebRTC SPM dep, signaling relay, TURN server, expert web client.
- Existing audio-session arbitration in `WakeWordService` / `TextToSpeechService` must be respected.
