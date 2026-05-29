# Plan M — WebRTC Signaling, Expert Client & Audio-Session Coordination

**Builds on:** [Plan L](L-webrtc-expert-transport.md). The app side is done: `WebRTCPeerTransport`
creates the peer connection, the `ExpertSignalingClient` speaks a small JSON protocol over a
WebSocket, and Settings hold the signaling/STUN/TURN config. This plan delivers the three pieces L
flagged as external/unhardened so a live expert call actually connects: **a signaling relay**, **the
expert-side web client**, and **in-app audio-session coordination**.

**Effort:** ~3–5 days (server + client ~1–2 days; audio-session hardening ~1–2 days + device testing).

---

## M1. Signaling relay server

A tiny stateless WebSocket relay that rooms peers and forwards SDP/ICE. Must speak the exact protocol
the app already sends (`SignalingMessage` in `WebRTCPeerTransport.swift`):

```json
{ "type": "join|offer|answer|candidate|bye",
  "room": "openglasses-xxxxxxxx",
  "sdp": "...",            // offer/answer
  "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 }  // candidate
```

Behavior: on `join`, add the socket to `room`; forward every other message to the *other* member(s) of
the same room; drop the room on `bye`/disconnect. ~80 lines of Node (`ws`) or Python
(`websockets`). Deploy anywhere (Fly/Render/Cloudflare). **No media touches the server** — it only
relays signaling, so it's cheap and stateless.

*Deliverable:* `docs/webrtc/signaling-server.js` (reference) + deploy notes. The app's
`Config.expertSignalingURL` points at it (`wss://…`).

## M2. Expert-side web client

A single HTML/JS page the expert opens from the join URL (`{signalingURL}?room=…`). It:
1. Connects to the signaling server, sends `join` with the room from the query string.
2. On `offer`, creates an `RTCPeerConnection` (same STUN/TURN), `setRemoteDescription`, creates an
   `answer`, sends it back; trickles ICE.
3. Renders the inbound glasses video (`<video>`), and captures the expert's mic to send back.

Pure browser WebRTC — no framework needed. Can extend the existing MJPEG browser viewer page.

*Deliverable:* `docs/webrtc/expert-client.html`. Host it anywhere static (or serve from the signaling
host). The technician's app already produces the join URL and pages it to the expert (Plan K notifier).

## M3. In-app audio-session coordination (the hardening L deferred)

A live WebRTC call wants `AVAudioSession` in `.playAndRecord` and owns mic + speaker for the call.
OpenGlasses already arbitrates the session across `WakeWordService`, `TextToSpeechService`,
transcription, and recording. Wire the call into that the way realtime sessions already gate the
pipeline:

- On `WebRTCPeerTransport.start`: pause `WakeWordService` listening, suppress proactive TTS, and
  configure `RTCAudioSession` for the call (let WebRTC manage the session, or set category once and
  hand it over). Mirror the gate already used when a Gemini/OpenAI realtime session is active.
- On `stop`: restore the prior audio-session state and resume wake word.
- Guard against the escalation call fighting an in-progress realtime LLM session — only one may own
  the mic; decide precedence (recommend: an active expert call wins, pausing the AI voice loop).

This is in-app Swift and the one part of M that's unit-/integration-testable on device (state
transitions). Keep the transition logic in a small, testable coordinator rather than inline in
`start`/`stop`.

---

## Build order

1. **M1** signaling relay + deploy; point a test build's `expertSignalingURL` at it.
2. **M2** expert client; verify glasses→browser video over LAN (STUN only).
3. Add TURN; verify cross-network (cellular) via the relay.
4. **M3** audio-session coordination + wake-word/TTS gating; device test for echo / session wedging.
5. Two-way audio end-to-end; flip on for a pilot.

## Open questions

- Auth on the signaling room (token in the join URL) so a leaked URL can't snoop a session?
- Record the call into `SessionExport` (consent + storage)?
- Reconnect/renegotiation on network change (cellular↔wifi handoff)?

## Dependencies / prereqs

- Plan L (shipped, app-side). New: a hosted signaling server + TURN; a static expert page.
- Respect existing `WakeWordService` / `TextToSpeechService` audio-session ownership (M3).
