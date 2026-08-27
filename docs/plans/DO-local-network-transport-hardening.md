# Plan DO — Local-Network Service Transport Hardening

**Status:** 📝 Drafted (2026-08-26)
**Origin:** 2026-08-26 adversarial review finding 6 (High).
**Priority:** Release blocker if LAN MCP/HUD modes are present in a production build.

This plan removes the assumption that a bearer token makes cleartext LAN HTTP safe. It separates
loopback development, paired native clients, and browser HUD sharing because they have different trust
and certificate constraints. The default production posture is no listener on a LAN interface.

---

## Problem and verified path

`MCPGlassesServer` creates a plain `NWListener` (`NWParameters.tcp`, no TLS) on port 8765, bound to
all interfaces, serving camera frames, context/status, and display/TTS operations. Its bearer auth is
actually sound — a 256-bit key in the Keychain, constant-time compared, 401 on mismatch — so the gap
is **not** missing authentication; it is that no TLS means the token itself and the JPEG camera frames
travel in cleartext on every request. `WebHUDMirrorServer` (plain TCP, port 8766, all interfaces)
takes care to keep the token out of the shared URL by carrying it in the fragment (`/#t=…`), but the
client JS then forwards it as a `?t=…` query parameter on every `hud.json` fetch — so the token is on
the cleartext wire regardless. Anyone able to observe or alter the local network path can capture
credentials/content, replay requests, inject HUD text/TTS, or consume camera-derived data. Long-lived
bearer tokens do not provide confidentiality, peer identity, forward secrecy, or robust replay
protection. One asymmetry to fix while here: `WebHUDMirrorServer` refuses to start under
`Config.hipaaMode`, but `MCPGlassesServer` has no HIPAA gate at all and stays reachable in HIPAA mode.

Neither server is `#if DEBUG`-gated; both ship in Release behind default-off `UserDefaults` toggles
(`mcpServerEnabled` + `agentModeEnabled`; `webHUD…` + `!hipaaMode`). Route/auth logic is unit-tested
(`SafetyGateTests`, `WebHUDMirrorTests`), but nothing exercises the live listener, so "binds loopback
only," "no TLS fallback," and connection-limit behavior have no coverage today.

Relevant seams:

- `OpenGlasses/Sources/Services/MCPServer/MCPGlassesServer.swift`
- `OpenGlasses/Sources/Services/Display/WebHUD/WebHUDMirrorServer.swift`
- local server settings and discovery UI
- gateway pairing and WebRTC/expert transport plans as reuse candidates
- MCP/WebHUD authorization tests under `OpenGlassesTests/`

## Product decisions

1. **Loopback developer mode:** HTTP is permitted only on `127.0.0.1`/`::1`, compiled for Debug or an
   explicit internal build. It is not LAN discoverable.
2. **Native paired MCP clients:** LAN access uses TLS 1.3 and a pairing-derived client identity. The
   client pins the phone certificate/fingerprint; the phone stores paired-client identity in Keychain.
3. **Browser HUD:** retire the raw LAN HTTP URL. Browser sharing uses the existing HTTPS-origin expert
   web client plus a WebRTC encrypted data channel (or another deployed TLS relay). Browsers cannot
   safely consume a self-signed LAN certificate through an embedded bearer URL without poor trust UX.
4. There is no production “allow insecure LAN” preference. Internal experiments are compile-time
   marked, foreground-only, visually badged, and cleared at restart.

## Security invariants

- Production listeners bind loopback unless an explicit, short-lived paired session is active.
- Tokens never appear in URLs, QR query strings, logs, screenshots, Bonjour TXT records, or referrers.
- Every LAN request has transport confidentiality, server authentication, client/session binding,
  expiration, replay resistance, and resource limits.
- Stopping, backgrounding, locking protected data, or expiring the session closes listeners and active
  connections and rotates ephemeral credentials.
- Read/camera operations and acting display/TTS operations have separate authorization scopes.

---

## P0 — Contain production exposure 🔴

1. Introduce `LocalServiceExposurePolicy` with build flavor, foreground state, protected-data state,
   pairing state, and requested service as explicit inputs. It returns bind scope or refusal.
2. Make both servers request an endpoint from this policy. Release defaults to loopback/no listener;
   LAN requires a future P1/P2 session. Do not bind `.any` and then filter requests.
3. Compile the current cleartext LAN toggle, token URL, and Bonjour advertisement out of Release.
4. Rotate existing access tokens and clear persisted/in-URL variants during migration. Show users that
   LAN sharing now requires re-pairing rather than silently preserving an insecure credential.
5. Add connection count, header size, body size, request rate, idle deadline, and total session limits
   even on loopback. Reject chunked/unbounded bodies unless a route explicitly needs them.
6. Gate camera, display, and TTS routes by capability; start with all LAN capabilities unavailable.

**Tests.** Release policy cannot return LAN; debug loopback resolves only loopback addresses; `.any`
is never requested in production composition; background/lock closes fake listeners; old tokens are
invalid; request/connection limits fail closed.

## P1 — TLS identity and pairing for native MCP clients 🔴

1. Generate a per-install P-256 identity in Secure Enclave/Keychain where available. Create a short-
   lived server certificate carrying no user/device name. Rotate on reinstall/reset and support an
   explicit “forget all clients.”
2. Start pairing only from an owner-confirmed foreground UI. Display/encode phone endpoint, certificate
   fingerprint/public key, one-time challenge, protocol version, expiry, and requested scopes. Do not
   include a reusable bearer secret.
3. Complete a challenge-response handshake over the pinned TLS channel. Store the paired client public
   key and granted scopes; derive session keys/tokens with HKDF and bind them to TLS transcript/session.
4. Require a monotonic nonce or signed request id plus timestamp/session counter for each mutating
   request. Keep a bounded replay window. A captured request cannot be replayed after use or session
   rotation.
5. Configure Network.framework TLS minimum 1.3, disable anonymous/plain TCP fallback, and fail closed on
   certificate/client mismatch. Surface the fingerprint in connection diagnostics.
6. LAN sessions expire (recommended 10 minutes idle, 60 minutes absolute), close on background unless a
   documented foreground mode is active, and require fresh owner confirmation to widen scopes.

**Tests.** Successful pin/pair; wrong certificate/client/challenge; expired one-time code; requested
scope downgrade; replayed mutating request; counter gap policy; session expiry; key rotation; forgotten
client; TLS configuration inspection. Headless crypto fixtures first, then two-device LAN smoke.

## P2 — Route authorization and abuse resistance 🟠

1. Define scopes such as `context.read`, `camera.snapshot`, `hud.write`, and `tts.speak`. Default pairing
   grants the minimum read-only scope; acting scopes require separate confirmation and prominent UI.
2. Put authorization at the service method as well as the HTTP route. An internal caller cannot bypass
   it by invoking a route handler directly.
3. Use Plan DJ's invocation/provenance and outcome model for HUD/TTS actions. Rate-limit by paired client,
   scope, and route; place strict text/byte/duration caps on rendered/spoken content.
4. Emit content-free audit events for pair, connect, denied scope, rate limit, and unpair. Never log
   request bodies, tokens, full endpoints, camera payloads, or HUD/TTS text.
5. Show active LAN session, client label, granted scopes, last activity, and a one-tap revoke control in
   the app. Activity indicator must not rely on color alone.

**Tests.** Each route/scoped role matrix; direct service call without grant; rate-limit boundaries;
oversize HUD/TTS body; revoke closes in-flight clients; audit canaries absent.

## P3 — Replace browser HUD LAN HTTP 🟠

1. Remove production `http://<phone>:port/?token=...` generation and the raw WebHUD LAN listener.
2. Extend the HTTPS-hosted expert viewer to negotiate a WebRTC data channel with the phone through the
   existing signaling/TURN deployment. Encrypting WebRTC protects LAN and remote paths while the HTTPS
   origin gives the browser a normal certificate trust model.
3. Pair the viewer with a short-lived code/QR that contains only relay room id, public fingerprint,
   requested read-only HUD scope, and expiry. Exchange secrets inside the authenticated handshake.
4. Make HUD mirror read-only. Any future browser-to-phone control is a separate reviewed capability,
   not an implicit consequence of the display channel.
5. Until the hosted path is deployed, production UI labels browser HUD unavailable rather than offering
   cleartext fallback. Loopback preview remains available for internal development.

**Tests.** No token in URL/referrer/history; wrong room/fingerprint rejected; expired code; relay cannot
read end-to-end payload; disconnect/background cleanup; browser reconnect requires a valid session.

---

## Rollout, rollback, and exit criteria

P0 is forward-safe and ships immediately. P1 can re-enable MCP LAN per paired client. P3 re-enables
browser HUD only after the hosted HTTPS/WebRTC edge exists. Rollback means loopback/off, never raw LAN
HTTP. Device/network verification should include trusted Wi-Fi, hostile peer/AP simulation, IPv4/IPv6,
network handoff, backgrounding, and packet capture proving no readable payload or reusable credential.

Complete when:

- Release cannot start either cleartext LAN server;
- native LAN MCP uses pinned TLS, scoped pairing, expiry, and replay defense;
- browser HUD uses an HTTPS trust origin plus encrypted channel or remains unavailable;
- credentials are absent from URLs, logs, discovery records, and screenshots;
- listeners close on revoke/background/lock and resource caps are tested; and
- headless security suites, Release build, packet-capture check, and device matrix are green.

Use [[DM-privacy-safe-production-logging]] for audit events and
[[DJ-composed-tool-safety-and-execution-outcomes]] for mutating route execution.
