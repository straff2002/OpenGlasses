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

> **M3 status: implemented (app-side).** `ExpertCallAudioCoordinator` is an idempotent begin/end
> state machine; the real side-effects (stop TTS + pause wake word on begin, resume on end) live
> behind `ExpertCallAudioControlling` (`AppExpertCallAudioControl`). `WebRTCPeerTransport` calls
> `beginCall()`/`endCall()` on start/stop, and AppState injects the adapter. Transition logic is
> unit-tested. **Precedence shipped:** `beginCall()` now returns a `StartResult` and refuses
> (`.blockedByRealtime`, pipeline untouched) when a Gemini/OpenAI realtime session owns the mic —
> `isRealtimeSessionActive` is injected by AppState and `WebRTCPeerTransport.start()` guards on it;
> unit-tested. **Still device-pending:** explicit `RTCAudioSession` category/echo-cancellation config
> and on-device echo/session-wedge testing — both need real hardware.

---

> **Deployment demoted (2026-07-10).** The meeting-link transport (zero-infra, recommended for
> remote) made deploying M1/TURN **on-demand, not next**: do it only for a customer with a
> compliance/self-host requirement. M1 (`docs/webrtc/signaling-server.js`) and M2
> (`docs/webrtc/expert-client.html`) stand as reference implementations until then.

> **Base server first (2026-09-25).** Plan [FU](FU-base-server.md) makes the organisation's base
> server the **MJPEG** relay for live support, so an organisation with a server needs neither M1
> nor TURN. When WebRTC is wanted after all, the base server is where M1 lives, and it issues the
> room token this plan's risk note makes a precondition — it already knows every phone (signed
> requests) and every administrator (console login).

## Build order (on-demand — triggered by a self-host customer, not by default)

1. **M1** signaling relay + deploy; point a test build's `expertSignalingURL` at it.
   **Gate: room-token auth first — see the risk note below.**
2. **M2** expert client; verify glasses→browser video over LAN (STUN only).
3. Add TURN; verify cross-network (cellular) via the relay.
4. **M3** audio-session coordination + wake-word/TTS gating; device test for echo / session wedging.
5. Two-way audio end-to-end; flip on for a pilot.

## Risk note — signaling protocol has no auth (flagged 2026-07-10, fix BEFORE any deploy)

The relay has no room auth, rate limiting, or peer cap. Room ids are 8 UUID hex chars
(`"openglasses-\(UUID().uuidString.prefix(8))"` in `WebRTCPeerTransport.start`), and `relay()`
forwards to *every other peer* (`signaling-server.js:40-47`) — a third joiner silently receives the
offer/candidates. Join-URL token auth was an open question; it is now a **precondition of
deployment**, and adding the token field to `SignalingMessage` is cheap *now* while a later
protocol change is breaking across app/server/client. (Verified clean otherwise: no hardcoded
secrets — TURN credential is Keychain-stored, STUN default is the disclosed public Google server;
the client accepts `ws://` if typed — the server header comment already says TLS in production.)

## Open questions

- Record the call into `SessionExport` (consent + storage)?
- Reconnect/renegotiation on network change (cellular↔wifi handoff)?

## Dependencies / prereqs

- Plan L (shipped, app-side). New: a hosted signaling server + TURN; a static expert page.
- Respect existing `WakeWordService` / `TextToSpeechService` audio-session ownership (M3).
