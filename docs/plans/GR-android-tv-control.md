# Plan GR — Android TV / Google TV Control over the Local Network

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Continues:** Plan [AF](siri-and-local-server.md) item #6 (the app's only Bonjour/Local Network use)
and the trust-on-first-use idea AF's review left unshipped.
**Related:** Plan [DO](DO-local-network-transport-hardening.md) (local-network transport rules),
`HomeAssistantTool` / `HomeKitTool`, `NetworkRouteRegistry`, Plan [GJ](GJ-remappable-temple-gestures.md).

---

## Trigger

"Turn on the TV", "pause", "volume down a bit", "open YouTube", "go back". A voice assistant on your
face is the ideal TV remote — it is never lost down the sofa — and most smart TVs sold today run
Android TV or Google TV, which ship a documented-by-reimplementation local remote protocol. No
cloud, no account, no hub.

## Outcome

- Find Android TV / Google TV devices on the home Wi-Fi; pair once with the code the TV shows.
- By voice: power on/off, D-pad and OK/back/home, play/pause/next/previous, volume up/down/mute,
  open an app by name, type a search into a focused text field, "is the TV on?".
- Works with the phone locked in a pocket once paired (see *Locked phone*).
- Home Assistant users who already run HA's Android TV Remote integration can route the same
  commands through HA instead.

## What exists today (verified 2026-10-01)

- No TV code. `HomeKitTool` handles lightbulb/switch/fan/outlet power and brightness only — no
  `HMServiceTypeTelevision`. `HomeAssistantTool.callService` posts only `{"entity_id": …}` (no
  service data), so HA's `media_player.turn_on/turn_off/volume_up/volume_down/media_play_pause` are
  reachable today but `remote.send_command` (needs `command`) and `remote.turn_on` with an `activity`
  are not.
- Local Network: `Info.plist` has `NSLocalNetworkUsageDescription` (worded for self-hosted AI servers
  and LAN video) and `NSBonjourServices` = `_http._tcp`, `_bonjour._tcp`. `LocalServerScanner`
  (Plan AF #6) uses `NWBrowser`; `LocalServerDiscovery` is its pure half.
- `NetworkRouteRegistry` scrapes for `URLSession`/`webSocketTask`/`NWConnection` owners — a new
  socket client must declare a route. `KeychainService` stores generic data items only (no key/
  certificate/identity helpers). `UIBackgroundModes`: `audio`, `bluetooth-central`,
  `external-accessory`.
- Existing Spotify/Netflix-style deep links live only in `OpenAppTool` (phone apps, not TVs).

## The protocol (Android TV Remote v2)

Verified 2026-10-01 against the Apache-2.0 reference implementation `androidtvremote2` (the library
Home Assistant's `androidtv_remote` integration uses) and HA's integration manifest and docs.
Anything marked **(unverified)** needs a device check in P3.

- **Discovery:** mDNS `_androidtvremote2._tcp` (HA manifest zeroconf entry). Requires the TV's
  "Android TV Remote Service" (present on most Android/Google TV devices; absent on Fire TV).
- **Ports — correction to the brief:** **pairing is 6467, the remote channel is 6466** (reference
  defaults `api_port = 6466`, `pair_port = 6467`). Both are TLS; the client presents its own
  self-signed certificate on both.
- **Framing:** every message is a protobuf prefixed by its byte length as a **varint**.
- **Pairing messages** (`polo.proto`, `OuterMessage` with `protocol_version` = 1 and `status`
  200/400/401/402): `pairing_request` (10: `service_name` = "atvremote", `client_name`) →
  `pairing_request_ack` (11) → `options` (20: input encoding HEXADECIMAL = 3, `symbol_length` 6,
  preferred role INPUT = 1) → `configuration` (30: the chosen encoding, `client_role` INPUT) →
  `configuration_ack` (31) → the TV shows a 6-character hex code → `secret` (40) → `secret_ack` (41).
- **Pairing secret:** SHA-256 over, in order, client RSA modulus, client exponent, server modulus,
  server exponent, then the **last four hex characters** of the code as 2 bytes. Modulus and exponent
  are their big-endian magnitude bytes (the reference hex-encodes each; the exponent 65537 becomes
  `01 00 01`). The code's **first byte is a checksum**: it must equal the digest's first byte, so a
  mistyped code is caught before anything is sent. The `secret` message carries the digest.
- **Remote messages** (`remotemessage.proto`, `RemoteMessage` field numbers): `remote_configure`
  1 (`code1` feature bitmask; `device_info` model/vendor/unknown1/unknown2/package_name/app_version),
  `remote_set_active` 2, `remote_error` 3, `remote_ping_request` 8 / `remote_ping_response` 9
  (`val1` echoed), `remote_key_inject` 10 (`key_code`, `direction` SHORT = 3, START_LONG = 1,
  END_LONG = 2), `remote_ime_key_inject` 20, `remote_ime_batch_edit` 21, `remote_start` 40 (power
  state), `remote_set_volume_level` 50, `remote_adjust_volume_level` 51,
  `remote_app_link_launch_request` 90 (`app_link`). Feature bits: PING 1, KEY 2, IME 4, VOICE 8,
  POWER 32, VOLUME 64, APP_LINK 512 (the reference advertises 622).
- **Session:** the TV sends `remote_configure`, the client answers with its own; then
  `remote_set_active` both ways; the TV pings about every 5 s and drops a session idle for ~16 s.
- **App links:** deep links are preferred (`https://www.youtube.com`, `vnd.youtube://`,
  `netflix://`, `https://www.netflix.com/title/<id>`, `plex://`, `twitch://home` per HA's docs);
  package-name launches are documented by HA as broken for many apps after a Play Store change.
- **Text:** `remote_ime_batch_edit` needs the `ime_counter`/`field_counter` the TV reports for the
  focused field **(unverified end to end)**.
- **Power on from standby** works only if the TV keeps the remote service reachable in standby
  ("network standby"/quick start) **(unverified per model)**; Wake-on-LAN is out of scope (it needs
  the restricted multicast entitlement).

## Design

**Pure core (no sockets):**
- `ProtoWire` — minimal protobuf writer/reader (varint, length-delimited, skip unknown fields); no
  SwiftProtobuf dependency for ~15 small messages.
- `VarintFrameCodec` — encode a frame; streaming decoder that accepts partial TLS reads and yields
  whole messages (bounded to 64 KB per message; larger → protocol error).
- `PoloMessages` / `RemoteMessages` — typed encode/decode for the messages above.
- `PairingSecret.compute(client:server:code:) -> Result<Data, PairingCodeError>` over
  `RSAPublicKeyComponents` (parsed from PKCS#1 DER by a tiny ASN.1 reader), checksum check,
  hex-case and whitespace tolerant.
- `SelfSignedCertificateBuilder` — DER for a minimal X.509 v3 certificate (RSA-2048, SHA-256 with
  RSA, 10-year validity, CN "OpenGlasses Remote"); signing is injected so tests use a fixed key.
- `TVSessionStateMachine` — pairing and remote handshakes as states and events (configure → active →
  ready; ping → pong; idle timeout; `remote_error` → failed), producing messages to send.
- `TVKeyMap` — spoken intents → key codes. From the reference proto: POWER 26, HOME 3, BACK 4,
  DPAD_UP/DOWN/LEFT/RIGHT/CENTER 19–23, VOLUME_UP/DOWN 24/25, VOLUME_MUTE 164, MEDIA_PLAY_PAUSE 85.
  Android `KeyEvent` values the proto mirrors, to confirm against the proto file in P0: MEDIA_NEXT 87,
  MEDIA_PREVIOUS 88, CHANNEL_UP/DOWN 166/167, MENU 82, SEARCH 84, digits 7–16, SETTINGS 176.
- `TVAppCatalog` — app names/synonyms → app links (the HA-documented ones first); unknown apps try
  `https://` search links only if the wearer confirms.

**Edge (sockets, Keychain):**
- `AndroidTVDiscovery` (`NWBrowser` for `_androidtvremote2._tcp`), results cached as
  `{name, host, port, lastSeen}`.
- `TVRemoteIdentityStore` — generates the client key with `SecKeyCreateRandomKey` (RSA 2048,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so it is usable while locked, never synced),
  stores the certificate, returns a `SecIdentity` for `sec_protocol_options_set_local_identity`.
  One client identity for all TVs. Each paired TV's server certificate SHA-256 is pinned; a
  mismatch stops and asks to re-pair (never silently trusts a new certificate).
- `AndroidTVPairingClient` / `AndroidTVRemoteClient` — `NWConnection` with TLS (verify block
  accepts the TV's self-signed certificate during pairing, then only the pinned one), connect per
  command burst and linger 30 s for follow-ups ("down, down, OK"), answering pings.
- New `NetworkRoute.androidTVRemote` (`.localNetwork`, data `.promptText` — key names, app links,
  typed text; `blockedWhenLocalOnly` like `homeAssistantCommand`, see Decisions).
- Info.plist: add `_androidtvremote2._tcp` to `NSBonjourServices`; reword
  `NSLocalNetworkUsageDescription` to cover TVs. No new background mode.

**`tv_control` tool contract** (one tool, `description` written for the model):
`action` ∈ `power_on | power_off | power_toggle | key | volume_up | volume_down | mute |
play_pause | next | previous | open_app | type_text | status | list_tvs`; optional `tv` (name; the
default TV otherwise), `key` (a `TVKeyMap` name), `repeat` (1–10, for "down three"), `app`
(name or link), `text`. Returns one short sentence ("Done.", "YouTube is opening on the Living Room
TV.", "The TV didn't answer — is it on and on this Wi-Fi?"). Effect class `.write`; not a
`HighImpactToolPolicy` action. Pairing is not a voice action: `pair` opens the phone sheet.

**Pairing UX (phone):** Settings → Services → TVs: discovered TVs, "Pair" → the TV shows a code →
type it (voice entry "A three F…" is a later nicety) → checksum validated locally → paired. Default
TV picker. Copy never names plan letters.

**Home Assistant route:** a `TVBackend` protocol with `.direct(AndroidTVRemoteClient)` and
`.homeAssistant(entityID)`. The HA backend needs `HomeAssistantTool`'s client to accept a service-
data dictionary (allowlisted keys: `command`, `activity`, `num_repeats`, `volume_level`), then maps
the same `tv_control` actions onto `remote.send_command`, `remote.turn_on`, `media_player.*`.

**Locked phone.** The app stays alive in the pocket while its audio session runs (the `audio`
background mode behind always-listening); an in-flight `NWConnection` to a LAN address works then.
Constraints: the Local Network permission prompt and pairing need the foreground once; Bonjour
browsing in the background is not relied on — the cached host/port is used, and a failed connect
triggers one quick re-browse and otherwise "open the app to find the TV again". The client key is
AfterFirstUnlock-accessible, so a locked phone can still complete TLS. **(Device-unverified.)**

**Modes.** Phone-only works (the phone is the remote). HIPAA: no captured content leaves; see
Decision 3. Not agentic — no Agent Mode gate. GJ can map a tap to "TV play/pause".

## Phases (one PR each)

**P0 — Pure protocol core.** `ProtoWire`, `VarintFrameCodec`, messages, `PairingSecret`,
`SelfSignedCertificateBuilder`, `TVSessionStateMachine`, `TVKeyMap`, `TVAppCatalog`. Test vectors are
**generated once offline** with the reference library from a fixed client key and a fixed TV
certificate and committed as fixtures (bytes of each encoded message, the secret for code
`"<xx>1A2B"`), so the Swift core is checked byte-for-byte. Tests: `ProtoWireTests`,
`VarintFrameCodecTests` (1-byte/2-byte/5-byte lengths, split reads, oversize), `PoloMessagesTests`,
`RemoteMessagesTests`, `PairingSecretTests` (fixture digest, checksum rejects a typo, leading-zero
modulus), `SelfSignedCertificateBuilderTests` (DER parses with `SecCertificateCreateWithData`),
`TVSessionStateMachineTests`, `TVKeyMapTests`, `TVAppCatalogTests`.

**P1 — Identity, discovery, clients, tool.** `TVRemoteIdentityStore`, discovery, pairing/remote
clients, pinning, `tv_control`, route + Info.plist keys, phone pairing sheet. Tests:
`TVRemoteIdentityStoreTests` (simulator Keychain), `AndroidTVRemoteClientTests` over a loopback
fake TV built on the pure core, `TVControlToolTests`, `NetworkRouteRegistryTests` update.

**P2 — Home Assistant backend.** Service-data support in the HA client, `TVBackend.homeAssistant`,
backend choice per TV. Tests: `HomeAssistantTVBackendTests` (request bodies), HA tool regression.

**P3 — Device pass (owed).** Pair with a Google TV and an Android TV set; every action; power-on from
standby; typing into YouTube search; phone locked in a pocket; TV IP change after router reboot;
re-pair after the TV forgets remotes.

## Risks

- **Unofficial protocol.** It is the one the TV maker's own phone app uses and has been stable for
  years, but it is not a published contract; a firmware update could change it. The HA route is the
  hedge.
- **Local Network prompt** confuses people; the prompt appears only when the wearer taps "Find TVs".
- **Standby power-on** varies by model and setting.

## Decisions for Greig

1. **Direct protocol first, HA backend second (recommended)**, or HA-only (no TLS/cert code, but
   only for HA users).
2. **Text input in v1** or deferred to P3 once verified on a device. *Recommend deferred.*
3. **Medical Local Only:** block like Home Assistant (current default) or allow as LAN-only. *Recommend
   allow, since the route never carries captured content — but typed text is dictated speech, so
   block `type_text` only.*
4. **Other TV platforms** (webOS, Tizen, Roku, Apple TV) as later plans or never.

## Out of scope

Wake-on-LAN, voice-search streaming to the TV (`remote_voice_*`), casting media, Fire TV, HomeKit
Television services, and TV control from the watch.
