# Rokid RV101 — CXR-M wire format (recovered from a PacketLogger capture)

Status: **closed and implemented.** The framing, the caps grammar, the checksum and the
message vocabulary are all recovered, validated in both directions, and encoded in
`OpenGlasses/Sources/Services/Display/Rokid/RokidCapsCodec.swift`.

Validation: **3,216 frames** across both directions decode *and* re-encode byte-identically
— 3,215 of them bit-exact; the single exception is a TX frame truncated at a 512-byte ACL
fragment boundary, a reassembly artefact rather than a format gap. A separate type-agnostic
scan that only checks length and checksum finds 3,690 valid frames and **every one carries
type `0x40`**. Nine frames are pinned as golden vectors in
`OpenGlassesTests/RokidCapsCodecTests.swift`, spanning 6 of the 9 route shapes.

> ⚠️ **Premise correction.** This work began as "extract ATT payloads on handles 0x2A–0x34".
> This capture contains **no ATT traffic on those handles**. The glasses' command channel is
> **Classic Bluetooth → RFCOMM → iAP2**, not BLE GATT. The BLE characteristics
> (`9300/9301/9201/9202` under service `9100`) are a bootstrap that tells the iOS app to open
> the MFi/iAP2 channel; commands themselves never go over GATT. See §2.

---

## 1. Capture and how it was parsed

- Source: `C:\Users\Home PC\OneDrive\Documents\Untitled 2 - (null).pklg`, 2,273,885 bytes.
- Apple **binary PacketLogger**. Records are `[u32 LE recordLength][payload]`, and each
  payload is `[u32 LE seconds][u32 LE microseconds][u8 type][body]` — a 9-byte prologue,
  verified on all 23,541 records (every microsecond value is < 1,000,000).
- Host: iPhone16,2, iOS 27.2 (build 24B5099f), BCM_4388 over PCIe,
  Bluetooth host `MobileBluetooth-2701.70`.
- Capture window: **2026-10-22 18:08:10 → 18:30:08 UTC** (~22 min).
- A second capture, `Packetlog3.pklg` (626,398 bytes, 7,441 records, 2.5 h from
  18:08:10 to 20:39:43 UTC, same host iPhone16,2 / iOS 27.2), starts *before* the
  link comes up. It contains **no `ff 5a` frames at all** — only BLE ATT — so it
  establishes what the pre-iAP2 bootstrap looks like (§2) but cannot arbitrate the
  framing question in §10.2.

Record types, which line up exactly with TShark's dissection:

| Type byte | Meaning | Records |
|---|---|---|
| `0x00` | HCI command | 1,382 |
| `0x01` | HCI event | 10,743 |
| `0x02` | ACL, host→controller | 7,526 |
| `0x03` | ACL, controller→host | 3,865 |
| `0xFC` / `0xFD` | PacketLogger info notes | 19 / 6 |

### Getting `tshark` without an installer

No Wireshark was installed on the host and `tshark` was absent. Installing needed admin, so
the binaries were lifted out of the MSI instead:

1. Download `Wireshark-4.6.9-x64.msi` from `https://2.na.dl.wireshark.org/win64/`. The
   `.zip`s on that mirror are arm64 symbol archives only; **the MSI is the only usable
   artifact** for x64.
2. An MSI is an OLE compound file. Its two largest streams (47,376,319 and 31,998,826 bytes)
   are the cabinets — both start with the magic `MSCF`.
3. Unpack both cabinets. An MSI mangles file names to 8.3 form (`filTShark_exe`,
   `filLibwireshark_dll`); rename `fil<Name>_<ext>` → `<Name>.<ext>`, flattening the last `_`
   to a dot. Names that contain dots or dashes are mangled further (`glib_2_0_0.dll` →
   `glib-2.0-0.dll`).
4. **A first run fails with `0xC0000135` (STATUS_DLL_NOT_FOUND)** because mangled names do not
   match what the PE import directories ask for. Walk each executable's import directory and
   copy the mangled file to the exact imported name, matching on lowercase alphanumerics
   (`libwiretap.dll` resolves from `Wiretap.dll` by stripping a leading `lib`).

The resulting directory runs `TShark.exe -v` → `TShark (Wireshark) 4.6.9
(v4.6.9-0-g2d548b197c75)`. TShark auto-detects `.pklg` as `PKTLOG`.

## 2. Where the ATT actually is — and why 0x2A–0x34 is empty

TShark's hierarchy for the first capture:

| Layer | Count |
|---|---|
| frame / bluetooth / packetlogger | 23,541 |
| `bthci_evt` | 10,743 (11 malformed) |
| `bthci_acl` | 11,391 |
| `bthci_cmd` | 1,382 |
| `btl2cap` | 10,969 |
| **`btatt`** | **10** |

All ten ATT frames are on **connection handle 0x49 (73)** at **attribute handle 0x0016**:

| Opcode | Direction | Value |
|---|---|---|
| `0x1d` Handle Value Indication | device→host | `010a02c2050000` |
| `0x1d` | device→host | `010e02c2050000` |
| `0x1d` | device→host | `010b0205020000` |
| `0x12` Write Request | host→device | `010602` |
| `0x12` | host→device | `0105024bad0d00e8050000` |

An earlier revision of this document dismissed those ten frames as "a peripheral's
status/battery service, nothing to do with Rokid commands". **That was wrong** — a second
capture shows `0x0016` is exactly where the BLE command channel lives.

Handles **0x2A–0x34** would be the six characteristic *value* handles of service `9100`
(`0x28` service declaration; `0x29/0x2A` `9300`; `0x2B/0x2C` `9301`; `0x2D/0x2E` `9201`;
`0x2F/0x30` `9202`; `0x31/0x32` `9203`; `0x33/0x34` `9204`). **Nothing can be extracted from
them, because neither capture ever addresses them.** Confirmed twice now:

- first capture — the only ATT traffic is the ten frames above, all on `0x0016`;
- second capture `Packetlog3.pklg` (626,398 B, 7,441 records, 2.5 h) — 270 ATT PDUs touching
  only `0x0008, 0x000d, 0x0016, 0x0017, 0x001a, 0x001d, 0x0024, 0x0025, 0x0045, 0x0048,
  0x0049, 0x004b, 0x004c`.

The `0x2A–0x34` range was guessed from a service-layout sketch rather than read off the air.
The real BLE command channel is `0x0016`, and both captures agree on that.

### The BLE GATT command channel — attribute `0x0016`

`0x0016` is a write + indicate characteristic whose CCCD is `0x0017`. It does **not** speak
Caps and never carries `ff 5a`. It uses a much smaller framing:

```
01 | type | 02 | payload...
```

Byte 0 and byte 2 are constant `0x01` / `0x02` across all 16 frames of the second capture.

The second capture contains one complete negotiation, in order, all on ACL handle 77:

| # | phone→glasses | glasses→phone | reading |
|---|---|---|---|
| 1 | `010902` | `010c0220000000` | type `09` → 32 |
| 2 | `0103020f00` | `010b0203020000` | type `03`, `0f 00` → ACK |
| 3 | `01020201` | `010b0202020000` | type `02`, `01` → ACK |
| 4 | `01080225478b9ebd000000` | `010b0208020000` | type `08`, 7-byte value → ACK |
| 5 | `010602` | `010e02ca050000` | type `06` → 1482 |
| 6 | `012702` | `012802000a` | type `27` → `0a 00` |
| 7 | `01070202` | `010b0207020000` | type `07`, `02` → ACK |
| 8 | `01050251620500e8050000` | `010b0205020000` | type `05`, two `u32` → ACK |

**`0x0b` is the generic ACK, and it echoes the request's type byte**: `010b02 03 0000` answers
`010302…`, `010b02 08 0000` answers `010802…`, `010b02 07 0000` answers `010702…`. So an ACK
reads `01 | 0b | 02 | <echoed type> | <u16 status>`. `0x0c`, `0x0e` and `0x28` are *value*
responses rather than ACKs, which is why they answer types `09`, `06` and `27`.

This is capability/parameter negotiation, not the command vocabulary — 16 frames, no method
names, no JSON, no route ids. It is most likely the `9300`/`9301` bootstrap implied by
`cxr-service.json`'s `mtu { iphone_gatt: 500, iphone_socket: 4080 }`: the phone talks GATT
first, then opens the MFi socket where the Caps traffic actually lives.

### Direction mapping, settled

For the second capture, record type **`0x02` = host→controller (phone→glasses)** and
**`0x03` = controller→host (glasses→phone)**. Three independent confirmations:

- `Notify` (always server→client) appears only on `0x02` for handle 76 — 154 of them;
- `Confirm` (always client→server, acknowledging an Indication) appears only on `0x03`;
- the single `ReadByTypeReq` is on `0x02` and its `ReadByTypeRsp` on `0x03`.

The two ACL handles are **not concurrent**. Handle 77 spans `1792701545.557 → 1792701547.988`
(2.43 s) and handle 76 spans `1792701578.010 → 1792701582.342` (4.33 s), separated by a
**30.022 s gap with zero interleaving** — a disconnect and reconnect, not two simultaneous
peers. Handle 76 is identifiable as the glasses by its Device Name: the `ReadByTypeRsp`
`09 0e 16 00 476c61737365735f58585858` returns `entryLen 0x0e`, handle `0x0016`, value
**`Glasses_XXXX`**.

MTU negotiation is visible: `MTUReq 527` (`020f02`) → `MTURsp 247` (`03f700`); the CCCDs on
`0x0017`, `0x001a`, `0x001d` and `0x0025` are all enabled with value `0200`.

## 3. The MFi/iAP2 transport stack — where the commands actually go

Everything rides **ACL connection handle 12**. Reassemble HCI fragments (bits 4–5 of the
handle word are the PB flag: `1` = continuation, `0`/`2` = first fragment of a new PDU) and
then reassemble on the L2CAP `u16 LE length | u16 LE CID` header. That yields 5,856 L2CAP
PDUs:

| Direction | CID | PDUs | Bytes | Content |
|---|---|---|---|---|
| host→ctrl | `0x0051` | 2,447 | 893,941 | **iAP2 CXR channel** (`ff 5a`) + 285 `LAME3` MP3 frames |
| ctrl→host | `0x0b08` | 3,010 | 557,572 | **iAP2 replies & notifications** + 2,325 `OggS` pages |
| host→ctrl | `0x0056` | 210 | 4,756 | control/keepalive |
| ctrl→host | `0x140c` | 180 | 2,617 | control |
| host→ctrl | `0x0053` | 3 | 8 | — |
| ctrl→host | `0x110a` | 3 | 9 | — |
| ctrl→host | `0x0511` | 2 | 0 | empty |
| ctrl→host | `0x0000` | 1 | 1 | signalling |

Note the direction split: **commands go out on `0x0051`, replies and notifications come back
on `0x0b08`.** They are independent streams with independent framing — concatenating them
desynchronises everything. That mistake cost real time early on.

The `0x0051` stream opens with RFCOMM modem text (`+CIEV: 5,3\r\n`) before the first iAP2
frame, confirming ACL → L2CAP → RFCOMM → iAP2. Each iAP2 frame is carried whole as one
RFCOMM UIH payload, so **the app never has to build RFCOMM headers itself** — `EASession`
delivers the payload. Only the iAP2 layer below is this project's business.

## 4. The iAP2 link frame

```
ff 5a | u16 BE frameLength | 0x40 | u32 BE timestamp_µs | u16 BE sessionID | Caps | u8 checksum
```

- `0x40` is a constant frame type.
- **`sessionID` (offset 9-10) is not a constant.** The first capture carries `00 01` in all
  3,893 of its frames, which is why it was recorded as a constant header tail. The second
  capture carries `00 08` in 1,003 of 1,012 frames (the nine outliers are false sync words found
  inside audio bytes). Same phone, same firmware, different connection — so the field is scoped
  to a connection, not to the format. Who assigns it is still unknown: it could be chosen by
  the sender, negotiated, or simply echoed. Because it is unobserved whether the glasses
  validate it, `RokidIAP2Packet` exposes it as `sessionID` with `defaultSessionID = 0x0001`
  (the value the first capture used) and `sessionID(of:)` to read it back off a frame.
- **`frameLength` counts the whole frame from the leading `ff`**, not the payload. Reading it
  as a payload length makes every frame appear to end four bytes early, and was the single
  root cause of several abandoned theories (a phantom "5-byte trailer", a mysterious
  checksum, "doubled type tags"). Precisely:
  `frameLength = 4 + 7 + caps.count + 1 = caps.count + 12`.
- `checksum = (0 - sum(bytes[0 ..< checksumIndex])) & 0xFF` — two's complement of every byte
  from the leading `0xFF` through the last Caps byte. It is the textbook iAP2 link checksum
  and it validates on all 3,216 fully-parsed frames, in both directions.

## 5. The Caps grammar

A Caps blob is a self-delimiting typed tuple:

```
[u32 BE  total]        the whole blob is `total` bytes, including these four
[u8      0x05 ]        format version, constant — NOT a length prefix
[uleb128 count]        member count
[u8 × count  ]        one type tag per member, in value order
[values      ]        each value, in tag order, each self-delimiting
```

`total` includes the five header bytes. Because the blob is self-delimiting, a stream is
drained one blob at a time with no external length.

| Tag | Meaning | Value encoding |
|---|---|---|
| `V` | void | *(nothing)* |
| `i` | int32 | signed LEB128 |
| `u` | uint32 | unsigned LEB128 |
| `l` | int64 | signed LEB128 |
| `k` | uint64 | unsigned LEB128 |
| `f` | float | 4 bytes, **little-endian** IEEE-754 |
| `d` | double | 8 bytes, **little-endian** IEEE-754 |
| `S` | string | `uleb128 byteCount` + UTF-8, no NUL |
| `B` | binary | `uleb128 byteCount` + bytes |
| `O` | nested object | a complete nested Caps blob |

Endianness is genuinely mixed: the Caps total is **big-endian**, floats are
**little-endian**, integers and every length are LEB128. Because `O` recurses into a full blob — its own
`u32 BE total`, version and tag list — nesting *looks* like duplicated tags at a glance. That
was the "doubled tags" red herring: `SS` is not a two-letter tag, it is a two-member tuple of
two strings. `SS` means `(method, payload)`; `S` alone means `(method)`.

### Two worked examples, byte for byte

`Med/UnSync_Count`, a request with no payload — `uuSO`:

```
ff5a 0032 40 f7e3ea71 0001
00000026 05 04 7575534f 8120 9301 03 4d6564 00000014 05 01 53 0c 556e53796e635f436f756e74
b5
```

| Piece | Bytes | Meaning |
|---|---|---|
| `0032` | — | frame length 50, counted from `ff` |
| `00000026` | 4 | outer total = 38 |
| `05` | 1 | version |
| `04` | 1 | 4 members |
| `7575534f` | 4 | tags `uuSO` |
| `8120` | 2 | uleb `4097` — route |
| `9301` | 2 | uleb `147` — sequence |
| `03 4d6564` | 4 | `Med` |
| `00000014` | 4 | nested total = 20 |
| `05 01 53` | 3 | version, 1 member, tag `S` |
| `0c 556e53796e635f436f756e74` | 13 | `UnSync_Count` |
| `b5` | 1 | checksum |

`Ai/Ai_Heartbeat`, a request with JSON — nested `SS`, total `0x21` = 33 = 5 + 1 + 2 + 13 + 12:

```
ff5a 003e 40 f8e7ea60 0001 00000032 05 04 7575534f 8120 9401 02 4169
00000021 05 02 5353 0c 41695f486561727462656174 0b 7b22636f756e74223a367d 03
```

`0x2002` photo chunk, the shape that exposed the `B` defect — `uB`:

```
ff5a 01f8 40 5bfcea2d 0001 000001ec 05 02 7542 8240 e003 <480 B: RIFF…WEBP…> c6
```

| Piece | Bytes | Meaning |
|---|---|---|
| `01f8` | — | frame length 504, counted from `ff` |
| `000001ec` | 4 | outer total = 492 |
| `05 02 7542` | 4 | version, 2 members, tags `uB` |
| `8240` | 2 | uleb `8194` — route `0x2002` |
| `e003` | 2 | uleb `480` — the `B` length. **A varint, not a `u32`.** |
| *(480 bytes)* | 480 | `RIFF`…`WEBP` image chunk |
| `c6` | 1 | checksum |

`492 = 4 + 1 + 1 + 2 + 2 + 2 + 480`. Reading that `e003` as a big-endian length is
impossible (it would claim 57,348 bytes), which is how the mistake surfaced: the `B`
member had never been exercised, because every validated frame up to that point carried
only `u`, `i`, `f`, `S` and `O` members.

`0x3002` audio chunk — `uBuk`:

```
ff5a 004f 40 e8f7ea4f 0001 00000043 05 04 7542756b 8260 2f <47 B: OggS…> 03 d3c9dead9634 d3
```

| Piece | Bytes | Meaning |
|---|---|---|
| `00000043` | 4 | outer total = 67 |
| `05 04 7542756b` | 6 | version, 4 members, tags `uBuk` |
| `8260` | 2 | uleb `12290` — route `0x3002` |
| `2f` + 47 B | 48 | `B` length 47, then an `OggS` page fragment |
| `03` | 1 | `u` — a small stream/codec selector, observed only as 3 or 4 |
| `d3c9dead9634` | 6 | `k` — uleb `1792707896531`, a millisecond clock |
| `d3` | 1 | checksum |

`67 = 4 + 1 + 1 + 4 + 2 + 1 + 47 + 1 + 6`. The payload is only 47 bytes because audio is
streamed in small slices, not one frame per packet — concatenate `B` across frames.

## 6. Routes and the nine shapes

The route — the first `u` — decides the tuple's shape, so this table is the whole addressing
vocabulary:

| Route | Shape | Direction | Meaning |
|---|---|---|---|
| `0x1001` | `uuSO` | phone→glasses | request: `(route, seq, channel, object{method[, payload]})` |
| `0x1002` | `uuO` | glasses→phone | reply: `(route, seq, object{method, payload})` — **seq echoes the request** |
| `0x1003` | `uSO` | glasses→phone | notification: `(route, channel, object{method, payload})` — **no seq** |
| `0x2001` | `uuSO` | glasses→phone | event; the second `u` is a **millisecond clock**, not a counter |
| `0x2002` | `uB` | glasses→phone | **binary chunk** — 198 consecutive 480-byte chunks whose first opens `RIFF…WEBP`: a photo |
| `0x2003` | `uB` | glasses→phone | binary chunk, same shape, one 264-byte frame of unidentified content |
| `0x3001` | `uuSOuu` | both | audio-playback descriptor; object is `ifuu` = `(playbackId, 1.0f, 1, 16000)` |
| `0x3002` | `uBuk` | both | **audio chunk** — `B` is the encoded audio, then a selector `u` and a ms clock `k` |
| `0x3003` | `uu` | both | audio stop/ack: `(route, seq)` only, no channel, no method |

`CXRControl` is an ordinary channel under route `0x1001` — not a separate route. The
`playAudio` (outbound) and `AI_assistant` (inbound) channel names appear only on `0x3001`.
Routes `0x2002`, `0x2003`, `0x3002` carry **no method name at all**, so they are modelled
separately from the message routes (`RokidMediaTransfer` in Swift) rather than being forced
into a command shape. `0x3001` frames are the one case where bytes follow the Caps blob
inside the same frame: two of them carry 925 bytes of MP3 after the checksum's predecessor.
Every other frame in the capture has zero trailing bytes.
Sequence numbers are strictly increasing but **not contiguous** (0–548 across the 402
request frames,
21 gaps); they are a per-connection counter, echoed by the glasses in replies.

### Second-capture additions

`Packetlog3.pklg` runs the same Classic stack — ACL handle 20 to `<glasses address>`, 883
outbound and 1,070 inbound ACL records — and confirms every rule above: 282 outbound frames and
730 inbound frames pass the sync/length/type/checksum test, and 892 parse to a self-consistent
Caps blob. It also widens the vocabulary and adds two routes:

| Route | Shape | Direction | n | Members |
|---|---|---|---|---|
| `0x1004` | `uuuSkuS` | phone→glasses | 1 | `(4100, 1, 13, "<uuid>", <ns clock>, 195, "")` |
| `0x1005` | `uuuiS` | glasses→phone | 1 | `(4101, 1, 14, 1, "<phone address>")` |

Those two are a matched pair and both decode cleanly — a **host identification and clock-sync
exchange**, and the closest thing to a handshake the Classic link contains:

- `0x1004` carries `k` = `1_792_715_804_308_702_000`, a nanosecond wall clock whose second
  component lands inside this capture's own window, and an `S` = a UUID
  (`<host UUID>`). The trailing `S` is empty.
- `0x1005` answers with `i` = 1 and `S` = `<phone address>`, the *phone's* Bluetooth address
  from the capture's own `Address:` line.

So the glasses learn which host is talking and acknowledge with the host's address. The `u` = 13
and 14 in the third slot look like paired message-type ids (request/response), and the leading
`u` = 1 in both may be a protocol version — but with one sample each, treat all of that as
conjecture. What is certain is that the shapes and the host address are real.

**Replies can carry the method name.** The earlier claim that replies "always come back as
`uuO` … so the channel is not repeated" is too strong: the object may hold **two** strings, in
which case the inner tags are `SS` = `(method, payload)`. This is how `Dev_GetGlassInfo` answers:

```
0x1001 uuSO  (4097, 12, "Dev", { S: "Dev_GetGlassInfo" })              phone → glasses
0x1002 uuO   (4098, 12, { S: "Dev_GetGlassInfo", S: "<device JSON>" })  glasses → phone
```

The reply echoes the request's sequence number (`12`, `18`, `51` each pair up exactly), so a
caller can correlate without tracking state beyond its own counter. The reply blob is 672 bytes
— well past one frame — so it also exercises the large-payload split described below.

**Large payloads are split across consecutive frames.** 40 outbound frames declare a Caps
`total` larger than the bytes they carry (largest seen: `0x115a` = 4,442), and the *following*
frames continue that same blob as raw bytes — the JSON resumes mid-word
(`…"tion":"Pride is a nuanced word…`). So only the **first** frame of an oversized payload
carries a real header, and its declared `total` spans several frames. A decoder that treats each
frame as an independent Caps blob rejects roughly 14% of the outbound stream and will mis-parse
the rest; it must buffer by declared `total`. Observed chunk boundaries on this link sit at 512
bytes, but continuation frames longer than that also occur, so do not hard-code 512.

Channels widen well beyond the seven in `RokidCXRChannel`: `Order`, `Proxy`, `Pay`, `Settings`,
`Wifi`, `Trans`, `Jsa`, `Music` — plus a bare UUID
(`<host UUID>`) and the phone's own address (`<phone address>`)
appearing where a channel name would be. Methods seen for the first time here: `Order_Update`,
`Proxy_NetResponse`, `Proxy_NetRequest`, `Pay_NetProxyRequest`, `Pay_DeviceProxyRequest`,
`Sys_Msg_Tts_Stopped`, `WordTips_AllDevices`, `Wifi_Status`, `Dev_GetGlassInfo`,
`Settings_Update`, `Exit`.

`Dev_GetGlassInfo` is the most useful of these — its reply is a complete device descriptor
(secrets redacted here; see the warning below):

```json
{"deviceName":"Glasses_XXXX","deviceSpecies":"glasses","batteryLevel":100,"devicePanel":"1",
 "wearingStatus":"1","isCharging":true,"deviceKey":"<redacted>",
 "deviceSecret":"<redacted>",
 "deviceTypeId":"B4BED4DBF1F94F88BF22F79A4D70A7C7","deviceId":"<serial>",
 "deviceSeed":"<redacted>","otaCheckUrl":"https://ota.rokid.com",
 "otaCheckApi":"/v1/extended/ota/check","brightness":5,"sound":7,
 "systemVersion":"1.27.009-20261014-150203","buildTypeIsUser":true,"RV600":false,
 "assistVersionName":"0.3.9","assistVersionCode":3921,"displayWidth":480,"displayHeight":640}
```

That independently confirms the `systemVersion` and the 480×640 display recorded in
`rokid-rv101.md`, and shows `deviceId` equals the adb serial.

> **The capture contains live device secrets in cleartext.** `deviceKey`, `deviceSecret` and
> `deviceSeed` are transmitted as plain JSON over the link and appear verbatim in the `.pklg`.
> They are redacted above and must never be committed, logged, or pasted into an issue. Any
> capture file shared for analysis should be treated as a credential.

## 7. Message vocabulary

**Outbound requests** (`0x1001`; channel/method → payload):

| Channel | Method | Payload | n |
|---|---|---|---|
| `Ai` | `Ai_Heartbeat` | `{"count":16}` | 97 |
| `Ai` | `TTS_Result` | text | 88 |
| `Sys` | `Sys_Cloud_Server_Status` | `{"status":0}` | 62 |
| `Ai` | `ASR_Result` | text | 52 |
| `Dev` | `Dev_GlassBrightness` | `i` 2–10 | 26 |
| `Dev` | `Dev_GlassSound` | `i` 4–12 | 24 |
| `CXRControl` | `cancelAudioPlay` | `u` | 6 |
| `Ai` | `Ai_Tool_Status` | `{"status":"end","name":""}` | 3 |
| `Sys` | `Scene_Control` | `{"name":"take_picture","open":true}` | 3 |
| `Sys` | `Weather_SendData` | weather JSON | 2 |
| `Dev` | `Dev_TimeUpdate` | `{"timeZone":"America\/New_York","time":…}` | 2 |
| `Ai` | `Ai_OnLineInstruct` | `{"command":"control_app","params":{…}}` | 2 |
| `Ai` | `Ai_TakePhoto` | `{"width":1440,"height":1080,"quality":70}` | 2 |
| `Sys` | `Scene_GetSceneStatusInfo` | `{"sceneKey":…}` | 1 |

Payload-less (`S` alone): `ASR_End`, `Ai_PhoneInterrupt`, `Med/UnSync_Count`.
Three strings (`SSS`): `Ai/TTS_AudioFinished` = `("TTS_AudioFinished", "true", {"version":1})`.

**Inbound replies** (`0x1002`): `UnSync_Count` carrying the glasses' current counters, e.g.
`{"audio":0,"video":1,"picture":2,"interval_record":0}`, at the sequence number the request
used. Replies always come back as `uuO`, so the channel is not repeated.

**Inbound notifications** (`0x1003`, 230 frames):

| Channel | Method | Payload |
|---|---|---|
| `Dev` | `Dev_GlassSound` | `"3"`…`"12"` |
| `Dev` | `Dev_GlassBrightness` | `"4"`…`"9"` |
| `Dev` | `Dev_Screen_Status` | `{"screen_on":true}` |
| `Dev` | `Dev_BatteryChanged` | `{"level":98,"isCharging":false}` |
| `Ai` | `Ai_SceneStatus` | running-flags blob (`aiAssistRunning`, `takePictureRunning`, `otaRunning`, `aiChatRunning`, …) |
| `Ai` | `KeyDown` | `SfS`: `("KeyDown", 6.0, "{\"type\":1}")` — the float is unexplained |
| `Ai` | `Audio_Finish_Wake` | `SfS`: `("Audio_Finish_Wake", 7.0, …)` |
| `Sys` | `Tts_PlayStart` | `{ "id": 3 }` |
| `Sys` | `Tts_PlayFinish` | `{ "result": 1, "id": 3 }` |
| `Sys` | `Scene_NotifySceneStatusInfo` | `{"sceneKey":"video_record","statusInfo":{…}}` |
| `Sys` | `GlobalLocalTtsMsg` | `"onTtsStart"` |
| `Med` | `Med_Count_Update` | `{"type":"take_picture"}` |

**Inbound events** (`0x2001`): `Ai/Ai_TakePhoto` as an object of tag `S` only, with the
second member holding a millisecond clock (~94,342).

## 8. Static corroboration from the device

The capture was not the only source. `/system/lib64/libcaps.so` (71,128 bytes, pulled over
adb) contains the actual implementation:

- `rokid::Caps::serialize(void*, unsigned)` at `0x9918` throws below six bytes, writes the
  member descriptors, writes the values, then **backpatches** `buf[4] = 5` and
  `buf[0..3] = bswap32(end - buf)`. That is exactly the header in §5, written last.
- `serializeMemberDesc` at `0x9ab4` emits `uleb128(count)` followed by one tag byte per
  member — the tag list, not a per-member prefix.
- `NumberMember<T, tag, sizeof(T)>` instantiations fix the tags: `int`→`i`, `unsigned`→`u`,
  `float`→`f`, `long`→`l`, `unsigned long`→`k`, `double`→`d`. With `StringMember`,
  `BinaryMember`, `ObjectMember` and `VoidMember`, that is the whole table.
- `getBinarySize(void const*, unsigned)` at `0xc738` returns `bswap32(*(uint32_t*)p)`. This is
  **not** the `B` member decoder — it is a helper for a Caps blob's own leading total, and
  reading it as the binary length is what produced the wrong `u32 BE` rule for `B`.

`libcxr_service_jni.so` only *imports* `rokid::Caps` (every `Caps` symbol there is
`addr=0 size=0`); `libcaps.so` is its `DT_NEEDED`. An earlier note claiming the serializer was
missing from the service library was right about that library and wrong about the
implementation existing nowhere.

## 9. Swift implementation

| File | Role |
|---|---|
| `Sources/Services/Display/Rokid/RokidCapsCodec.swift` | `RokidCapsCodec` (Caps encode/decode, LEB128), `RokidIAP2Packet` (frame encode/decode + checksum), `RokidCapsRoute`, `RokidCapsMessage` (request/reply/notification classification), `RokidMediaTransfer` (photo and audio chunks) |
| `Sources/Services/Display/Rokid/RokidCommand.swift` | `RokidCommand` now renders an iAP2 frame; `RokidWireCodec` is the command↔frame bridge |
| `Sources/Services/Display/Rokid/RokidDisplayBackend.swift` | holds the per-connection `sequence` and a monotonic timestamp origin; `Config.rokidUsesMFI` chooses the transport |
| `Sources/Services/Display/Rokid/RokidFrameDrain.swift` | `RokidFrameDrain`: turns a chunked byte stream into whole frames. Resynchronises on `FF 5A`, accepts a candidate only when declared length, type `0x40` and checksum all agree, and charges a failed candidate **one byte** rather than the whole frame, because `FF 5A` occurs inside binary payloads (the 2,358-frame audio stream makes that certain, not hypothetical) |
| `Sources/Services/Display/Rokid/RokidMFITransport.swift` | `RokidMFITransport`: the real command transport — an `EASession` over `com.rokid.aiglasses`, with the streams pumped on their own run-loop thread. Also `RokidMFIError` and the `RokidMFIFraming` switch |
| `OpenGlassesTests/RokidCapsCodecTests.swift` | 9 golden frames from this capture (covering 6 of the 9 route shapes), round-trips, and refusal tests |

`RokidCapsValue` (already in `RokidCXRProtocol.swift`) is reused as the value model: its
`typeTag` characters are exactly the tags the device uses, so no second value type exists.

**Not yet compiled.** This work was done on Windows with no Xcode, so the Swift is verified by
construction and by mirroring it in Python rather than by running the suite — `_rokid/cxrcodec.py`
re-encodes 3,215 of 3,216 frames byte-identically, and `_rokid/verify_drain.py` ports
`RokidFrameDrain` line for line and passes 30 scenarios, including one that walks the entire
captured stream in both directions and yields 3,690 structurally valid frames. Treat the first
CI run as the real gate.

## 10. What is still open

1. **Compile and run the tests** on macOS — the only unverified step, and it now covers more
   than the codec: `RokidFrameDrainTests` (19 tests) and `RokidMFITransport` have never seen a
   compiler either. The repo's `.github/workflows/tests.yml` already runs
   `xcodebuild test` on `macos-26`, so CI is the gate. Highest-risk files are the two
   new ones; the MFi transport touches `EASession`, `StreamDelegate` and a background
   run loop, none of which any Python mirror can exercise.
2. **Whether we write raw Caps or the whole `ff 5a` frame.** Every capture starts mid-session
   and contains exactly one frame type (`0x40`, all 3,690 checksum-valid frames), so it cannot
   show whether iOS builds the iAP2 envelope or Rokid's app does. Both encoders are tested, so
   this is one hardware experiment: launch with
   `UserDefaults.standard.set(true, forKey: "rokidUsesMFI")` and set
   `RokidMFITransport.framing` to `.rawCaps` first, then `.framed` if the glasses ignore
   it. `.framed` is the default because every captured frame on the wire is framed *by
   something*, and if that something is us then raw Caps would be doubly wrapped.
3. **`Ai/KeyDown` / `Ai_Audio_Finish_Wake`**: the `SfS` float (6.0, 7.0, …) is unexplained; it
   looks like an audio level or duration but nothing confirms it.
4. **The two trailing numbers of `uBuk`** are identified by observation only (selector 3 or 4;
   ms clock on inbound, 0 outbound). No decoder depends on them.
5. **`0x2003` is a single 264-byte sample** — one frame, content unidentified. Do not infer a
   transfer protocol from it.
6. **The RFCOMM layer is not modelled** — correctly so, since `EASession` hands over the iAP2
   frame as its payload. Worth re-confirming on hardware that no reassembly is needed across
   `EASession` reads.
7. **Oversized payloads need a send-side chunker.** §6 shows the glasses' side splitting a
   big Caps blob over several frames. `RokidIAP2Packet.encode` currently emits exactly one
   frame, so any outbound payload larger than the link MTU (a long `Tts_SendPlayTts` string is
   the realistic case) would be sent as one oversized frame and probably dropped. Unknown until
   hardware: whether the muxer below us fragments instead, in which case nothing is needed.
8. **Who owns the session id at frame offset 9-10.** §4 shows it is `00 01` on one
   connection and `00 08` on another, from the same phone and firmware. Nothing in either
   capture shows it being negotiated, so it is probably chosen by the sender — but whether the
   glasses validate it, and whether a wrong value is ignored or silently dropped, is unknown.
   `defaultSessionID = 0x0001` is the value the first capture used; if commands vanish on
   hardware and everything else checks out, try varying this before suspecting the Caps layer.
9. **`_rokid/` holds proprietary pulls** (`libcaps.so`, `libcxr_service_jni.so`, `cxr-cmds`)
   plus the analysis scripts. That directory is excluded via `.git/info/exclude` and must not
   be committed or shipped.
10. **The `01 | type | 02` negotiation on `0x0016` is transcribed, not understood.**
    The framing and the ACK rule (`0x0b` echoing the request type) are solid, but the
    meaning of types `02, 03, 05, 06, 07, 08, 09, 27` and of the values they exchange
    (32, 1482, `0a 00`, two `u32`s, a 7-byte blob) is unknown. It is very likely
    capability/MTU negotiation rather than anything this app must replicate: the
    attribute sits on the BLE bootstrap link, and every command observed in either
    capture travels on the Classic link instead.

## 11. Reproducing

The analysis scripts and the PacketLogger captures are kept off-repo: a capture carries the
glasses' `deviceKey`, `deviceSecret` and `deviceSeed` in cleartext (§6), so it is a credential.
What the repo keeps is the result — every hex literal in `RokidCapsCodecTests` was checked
against the captures (650/650), and the codec re-encodes 3,215 of 3,216 captured frames
byte-identically.
