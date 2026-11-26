# Rokid RV101 — hardware validation checklist

Everything a person holding the RV101 and a Mac needs in order to turn the dark transports in
`Sources/Services/{Display,Camera,Microphone}/Rokid/` into working ones. Nothing here needs to
happen for CI: the unit tests are deterministic and run without hardware.

## Settled on hardware (reported 2026-11-21 to 2026-11-23)

A hardware run on a retail RV101, over the MFi route, answered most of the open questions below.
It has not been repeated on our own glasses yet. What it settled, and what this branch does about
each:

1. **The protocol.** The glasses advertise both `com.rokid.global.aiglasses` (EAP protocol id 195)
   and `com.rokid.aiglasses` (194), and `EASession` takes whichever the app asks for. A session on
   194 opens, but the CXR service never sends a byte on it. It answers only on 195, the one Rokid's
   own app opens. `RokidMFITransport.protocolStrings` now lists 195 first, and the transport
   reports the open session's id (`connectedProtocolID`) for the connect message.
2. **Framing: bare Caps, both ways.** iOS adds and strips the iAP2 link envelope. The glasses'
   session handler parses each payload as a Caps blob, which needs `0x05` at byte 4; a framed
   write has the link type `0x40` there. The parse fails and the glasses close the session, so
   later writes go nowhere. `RokidMFITransport` now writes `.rawCaps` by default, and splits what
   it reads with `RokidCapsDrain`, since a read is a bare blob too. The message and media decoders
   take either shape.
3. **Writes need a queue.** A full output stream takes nothing, which the transport used to treat
   as a failed write. Writes now join a `RokidWriteQueue` whole and leave on the stream thread only
   while the stream has room, so a long send cannot interleave with a command.
4. **A connect message is required, and it is where this route stops.** Right after the session
   opens, the client sends route `0x1004`: `(route, sequence, n, clientUUID, nanosecond clock,
   protocolID, "")` (tags `uuuSkuS`). The glasses answer on `0x1005` with
   `(route, sequence, n, status, phone Bluetooth address)` (tags `uuuiS`); status 1 means
   registered. The third member was 13 in one capture and 15 in this run; what it means is
   unknown. **Registration is keyed to the client UUID.** A newly made UUID got no answer, even on a
   fresh link; only the UUID Rokid's own app had already registered was answered. How a new client
   gets registered is not known. Presenting another app's identity is not something we ship or
   commit, so this branch does not send the connect message. Getting our own client registered,
   possibly through Rokid's own authorisation (Route B has an `authenticate` call), is the open
   question for Route A.
5. **Commands, once registered.** Requests go on `0x1001` as `uuSO`; replies come back on `0x1002`
   with the request's sequence; the glasses' own events and requests arrive on `0x1003` as `uSO`.
   Sequence numbers are per session and strictly increasing, not necessarily contiguous.
   `Dev_GetGlassInfo` was the first command answered.
6. **The lens shows text only inside the AI scene.** The wearer opens it with the wake word
   ("Hi Rokid"). The glasses then report `Ai_SceneStatus` and `KeyDown` and stream microphone
   audio. The phone answers in a paced order: a cloud status message, a heartbeat about every
   2 s, ASR partials building the question, ASR end, a short pause, then `TTS_Result` chunks, which
   are what the lens draws. A `TTS_Result` with no scene open draws nothing; heartbeats do not keep
   a scene open; `Sys/WordTips_AiContent` is a captions overlay tied to its own mode and does not
   draw on the home screen. So a Route A display is an answer to a question the wearer asked,
   not a HUD the app can put up on its own.
7. **Camera, microphone and speaker.** A photo arrives as a stream of media chunks; the run found
   the image's start by the JPEG start-of-image marker and took a short silence as its end. The
   microphone comes up as Ogg-Opus on the audio route, in clips that end on a pause or when the
   scene closes. Audio down (`playAudio`, MP3) plays only alongside a TTS answer; a bare audio
   stream is silent.
8. **What the glasses ask of their host.** Once connected they push `Dev_BatteryChanged`,
   `Dev_Screen_Status` and `Dev_GlassSound`, and ask the phone for weather and contacts
   (`Sys/Weather_GetData`, `Sys_sendContacts`). Phone notifications reach the lens over ANCS,
   whatever the app does.

## Prerequisites

| Need | Why |
| ---- | --- |
| Mac with Xcode 26+ / iOS 26 SDK | this repo's `project.base.yml` targets iOS 26 and `docs/BUILDING.md` pins Xcode 26 |
| iPhone 15 Pro Max (iOS 26+) | the phone half of the link |
| Rokid RV101 ("Rokid Glasses") | the device half |
| Apple developer team + a device provisioning profile | to install on hardware at all |
| *(optional, decisive)* Apple **Bluetooth logging profile** + PacketLogger | the only supported way to see GATT traffic on iOS |
| *(optional, decisive)* Rokid developer account with `appKey` / `appSecret` / `accessKey` | unlocks the AI-alliance iOS SDK instead of reverse engineering |

Add secrets to the **git-ignored** `project.local.yml` (the same file `MWDAT_META_APP_ID` uses);
never to a tracked file and never to a commit.

## Build and run

```bash
cp project.local.yml.example project.local.yml   # if not present already
./Scripts/install-xcodegen.sh
./Scripts/generate-xcodeproj.sh
open OpenGlasses.xcodeproj
```

Set the team in *Signing & Capabilities*, select the iPhone, run. Then:

1. **Settings → Display Backend → "Rokid RV101" → Scan for Glasses → Pair.** Note the peripheral
   UUID stored in `Config.rokidPeripheralID`.
2. **Settings → Advanced → Developer → Rokid Glasses → "Use the Rokid camera"** (read once at `CameraService` init — relaunch to apply).

## Per-surface pass criteria

### Display

- **Pass:** the transport reaches `connected`; a rendered card/notification appears on the glasses.
- **Expected today:** the backend is reachable and honest about its limits; with the placeholder
  UUIDs in `RokidBLETransport` it will not find the device. `GlassesDisplayError.noDisplay` surfaces
  in the HUD path rather than a hang.

### Camera

- **Pass:** `RokidCameraBackend.capturePhoto()` returns JPEG bytes and the image is the glasses
  camera's view.
- **Expected today:** `RokidCameraTransport.captureStill()` throws `.stillUnavailable`; the app
  falls back to the iPhone camera. `CameraFeatureGate` says so in Settings.

### Microphone

- **Pass (Bluetooth headset — works today):** the glasses appear as a Bluetooth input and an
  assistant turn transcribes from them. This needs no Rokid code at all.
- **Pass (native ARTC/Ai — not implemented):** `RokidMicrophoneBackend.startCapture()` throws
  `.streamUnavailable` until the envelope exists. That is the intended behaviour, not a bug.

## What the decompiled CXR-M SDK settles (and what it does not)

From a community write-up of `com.rokid.cxr:client-m` **1.0.8**:

- **BLE is only the handshake.** The SDK connects GATT, discovers services, requests the MTU,
  then *reads one characteristic whose value is the RFCOMM socket UUID*, and opens a classic
  Bluetooth socket with that UUID. iOS has no public RFCOMM API, so the equivalent channel has
  to carry the `CXRSocketProtocol` stream itself (BLE notify/write or MFi iAP2) — not merely
  hand over the UUID. That is the architectural reason an iOS port is not a recompile, and it
  is the most useful thing to confirm on the wire.
- **Payload is `Caps`** — ordered typed tuples (`V i u l k f d S B O`). **Recovered** and
  implemented: `(route, sequence, channel, object{method, payload})`, integers are LEB128,
  floats little-endian, strings `uleb128` + UTF-8. Full grammar and the two-direction
  vocabulary are in `docs/rokid-caps-encoding.md`.
- **Pairing re-verifies the serial number**: AES/CBC/PKCS5, key = `clientSecret` (dashes
  stripped), IV = its first 16 bytes, decrypting a stored blob that must contain the glasses
  `deviceId`. First pairing skips the check, then syncs time.
- **Also settled by capture:** the outer frame header is the iAP2 link frame
  (`ff 5a | u16 BE frameLength | 0x40 | u32 BE ts | 00 01 | Caps | u8 checksum`), the checksum
  being the two's complement of every preceding byte. It is **not** a `libcxr-sock-proto-jni`
  invention, and the `Caps` implementation itself is `libcaps.so` (a `DT_NEEDED` of
  `libcxr-service-jni.so`), not the JNI shim.

## Gap 2 (and gap 3) are settled by capture — done

The capture route needed no vendor account, and it has been executed:

1. ~~Install the logging profile, capture a `.pklg`.~~ Done; dissected with `tshark`.
2. ~~Export the ATT write/notify payloads.~~ **The commands are not on ATT at all.** They ride
   Classic BT → RFCOMM → iAP2 (`ff 5a`) on ACL handle 12, CID `0x0051` outbound and
   `0x0b08` inbound. The only ATT in the log is ten frames on handle `0x0016` of a different
   connection — nothing to do with Rokid commands.
3. Results, all in `docs/rokid-caps-encoding.md`: the **frame layout and checksum** (gap 2), the
   **Caps grammar**, the **route map** (`0x1001` request / `0x1002` reply / `0x1003`
   notification / `0x2001` event / `0x2002` photo chunk / `0x2003` binary chunk /
   `0x3001` audio play / `0x3002` audio data / `0x3003` audio stop), and the **command
   vocabulary in both directions** — validated on 3,216 frames, 3,215 of which re-encode
   byte-identically.
4. Gap 3 (UUIDs) was already closed from `cxr-service.json` and the GATT probe: service `9100`,
   write `9201`, notify `9202`.

What a capture could **not** settle, and what hardware still has to answer, is below.

## Order of work once real bytes exist

1. ~~UUIDs~~ → known **and already wired**: `RokidBLETransport` carries service `9100`,
   write `9201`, notify `9202`, and the two read-only characteristics `9300`
   (`IOS_CONNECTION_CHAR`) and `9301` (`RFCOMM_CONNECTION_CHAR`). Nothing to do here —
   but note these are a discovery bootstrap, not the command path (see item 3).
2. ~~Caps envelope~~ → done. `RokidCapsCodec.swift` encodes/decodes both directions;
   `RokidWireCodec` emits iAP2 frames.
3. Handshake → **`connect()` is now written, not just specified.** `RokidMFITransport`
   opens an `EASession` over `com.rokid.global.aiglasses` (see "Settled on hardware") and pumps
   its streams on a dedicated run-loop thread. Set
   `UserDefaults.standard.set(true, forKey: "rokidUsesMFI")` to select it; the BLE
   transport stays the default so nothing changes silently. The two protocol strings are
   **not** in the committed `Info.plist` — App Review rejects an undeclared MFi accessory
   protocol unless Rokid registers the app — so add them to `UISupportedExternalAccessoryProtocols`
   locally for the spike and do not commit that edit. **Settled since:** it opens, on 195, and
   the glasses then want a connect message keyed to a registered client (item 4 above).
   MFi identification and authentication themselves are done by iOS against the Apple
   Authentication Coprocessor, which the device has at
   `/sys/devices/platform/soc/988000.i2c/i2c-2/2-0010` (`acp_certificate`,
   `acp_challenge_data`, `acp_serial_number` all present). What hardware must settle is
   (a) whether iOS surfaces the accessory for our protocol at all, (b) whether Rokid's own
   app is hoarding the session — Classic MFi usually permits one, so force-quit it — and
   (c) the `.rawCaps` vs `.framed` question above (settled: `.rawCaps`).
4. Param schemas → validate `RokidCommand.notification` / `.customView` against the device.
   Neither appears anywhere in the capture, so their shapes are guesses and should be
   expected to be wrong.
5. Still capture → `Med` command + network fetch in `RokidCameraTransport.captureStill()`.
6. ARTC audio + live frames → `RokidAudioTransport` / `RokidCameraTransport`, then flip
   `MicrophoneCapabilities.streamsWearerAudio` / `CameraCapabilities.liveFrames` **only** when they
   actually deliver.

## If you take the official SDK instead

The public CocoaPods `RokidSDK` is 1.10.2 from **2019** and predates XCFramework and
arm64-simulator slices, so it will not link on iOS 26. The AI-alliance SDK from
`developer.rokid.com` is the usable one. Whatever its packaging:

1. Gate the dependency behind `#if canImport(RokidSDK)` (or a dedicated bridge target) so the
   simulator build — and therefore CI — keeps compiling without it.
2. Implement `RokidTransporting`, `RokidAudioTransporting` and `RokidCameraTransporting` over the
   SDK. All three protocols already exist and the backends already consume them, so this is a
   drop-in replacement for the placeholder transports.
3. Keep the capability flags honest: `streamsWearerAudio` and `liveFrames` stay `false` until the
   SDK path is observed delivering audio/frames on the device.
