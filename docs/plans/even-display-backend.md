# Plan AH — EVEN Realities G2 Display Backend (second HUD target)

**Status:** ✅ Steps 1–4 shipped + step 5 dark (2026-08-02). The widened `GlassesDisplayBackend`
seam is real: `MetaDisplayBackend` extracted as a pure refactor (render queue / interactive gate /
flash-then-restore stay backend-neutral in `GlassesDisplayService`; all pre-existing HUD tests
green untouched), `HUDIcon` + condensing moved next to the DSL (`HUDTextShaper`; nested typealias
keeps old references valid). EVEN stack: `EvenPacket` (CRC-16/CCITT-FALSE with published-vector
tests — no community bytes copied, per the licensing rider; framing, fragmentation, reassembly),
`EvenFrame`/`EvenScreenRenderer` (.lines v1; bitmap variant defined; all ten icons mapped;
emphasis → plain/indent/"· "; numbered items), `EvenDisplayBackend` over a mock transport
(decodable packet stream + selection round-trip tested), `EvenBLETransport` **ships dark**
(CoreBluetooth, dual-lens, foreground-only v1 — decisions named; auth handshake stubbed pending
capture logs). Input gap closed: spoken branch-label selection on decision cards
(`HUDRouter.handleVoiceCommand`, conservative exact/unique-substring). Hybrid decision resolved:
the backend choice governs the DISPLAY only — camera/audio services are untouched, so Meta camera
+ EVEN HUD works by construction and no camera-guard change was needed. Settings: backend picker +
dual-lens pairing; Info.plist BLE strings reworded. Device-pending: every byte-level protocol
claim (UUIDs, service ids, handshake), temple-gesture event format (Phase 2), L/R mirroring
validation.

Previously: Drafted, **revised 2026-07-10 after a code-verified review** (protocol
widened, BLE section added, renderer contract pinned, input story corrected). Speculative until
there's a device in hand — the protocol is a community reverse-engineered reconstruction, so treat
every byte-level claim as "validate against capture logs / hardware first."

## Why this might matter

The Ray-Ban Display path is gated behind Meta's DAT dev-mode permission flow (see
`reference_dat_glasses_gotchas` memory) — the single thing blocking real on-glasses testing. EVEN
Realities G2 has **no equivalent gate**: its display speaks an open BLE protocol that has been
reconstructed by the community (with capture logs), and the vendor ships an official JS SDK that
can serve as a reference oracle. Working community apps already render to it. So EVEN is a way to
put our HUD on *real shipping hardware today*.

The architectural bet: our HUD model (`HUDScreen`/`HUDLine`/`HUDItem`) is SDK-free plain data
(`HUDScreen.swift:1` imports Foundation only), and the render queue / interactive gate /
flash-then-restore logic in `GlassesDisplayService` is backend-neutral. **Honest framing
(corrected):** today there is exactly *one* `HUDScreen`→visual mapping and it goes through
MWDATDisplay types (`makeScreenView`, `GlassesDisplayService.swift:366-408`); `HUDPreviewView` is
not a second backend — it renders the *Meta FlexBox tree* (`HUDPreviewView.swift:26` imports
MWDATDisplay). EVEN would be the **first true second renderer** — this plan *creates* the proof of
backend-agnosticism, it doesn't stand on one.

## Hard scope limit (state up front)

**EVEN G2 has no camera.** It is a display + mic + temple-gesture device. So EVEN support lights up
only the HUD/text half of OpenGlasses:

- ✅ Works: AI-response HUD, ambient text, notifications, the Now/Next task cards and the launcher
  (`HUDRouter`/`HUDLauncher`), **and the Teleprompter** (`TeleprompterScreen` renders through the
  same DSL — a strong EVEN use case).
- ❌ Unavailable on EVEN: camera vision tools, RTMP, face recognition, privacy filter, ambient
  captions sourced from the glasses camera, memory-rewind video — anything needing `CameraService`
  frames.
- **Audio: display-only in v1 (claim cut).** The G2 mic streams PCM over the custom BLE protocol —
  the entire voice pipeline (WakeWord/Transcription/realtime) consumes the iOS audio-session mic,
  so G2-mic ingestion is a whole new audio path, and whether the G2 even has a speaker for TTS is
  unverified. In v1, voice in/out stays on the phone/earbuds; G2 audio is a separate future plan if
  ever.

The UI must degrade gracefully: with an EVEN device active, camera-dependent tools report "not
available on this device" rather than fall back to the iPhone camera silently — **subject to the
hybrid decision below** (in hybrid mode the camera guard must NOT fire).

## Architecture — the seam (widened 2026-07-10)

The original 4-method protocol was too narrow to survive contact with the build order. The Meta
path owns four more responsibilities that the backend must carry from day one:

```swift
protocol GlassesDisplayBackend: AnyObject {
    // Capability — replaces the deviceSupportsDisplay() gate
    // (GlassesDisplayService.swift:196/224 hard-guard on it today; the gate moves here).
    var isAvailable: Bool { get }

    // Lifecycle + error surface. ensureDisplay()'s 10s start-poll, shutdown(), and
    // handleRenderError's teardown-and-rebuild (:421-468, :216-219, :482-494) are
    // Meta-session-specific; a flaky RE'd BLE link makes reconnect semantics the HARD part.
    func start() async throws
    func shutdown() async
    var onTransportError: ((Error) -> Void)? { get set }

    // Content-level ambient frame — showText(String) alone drops title+icon;
    // showNotification/showNavigation (:175-183) need this shape to render on EVEN.
    func show(title: String?, body: String, icon: HUDIcon?) async throws
    func send(_ screen: HUDScreen) async throws
    func clear() async throws

    // Input events back to the service — on Meta, band selections arrive as SDK
    // Button.onClick closures baked into the FlexBox (:401-406). A one-directional
    // send() makes interactive screens fire-and-forget on any other backend.
    var onItemSelected: ((String) -> Void)? { get set }
}
```

- `MetaDisplayBackend` — wraps the current `MWDATDisplay` path. Pure refactor; no behaviour change;
  all existing HUD tests stay green (the `testRenderSink`/`testCapabilityOverride` seams capture
  above the backend, `GlassesDisplayService.swift:270-283` — verified).
- `EvenDisplayBackend` — `HUDScreen` → monochrome 576×288 frame → protocol packets over
  CoreBluetooth.

**Extraction riders (found in review — currently private, the plan needs them public/shared):**
- `condense` + `maxLength`/`maxTitleLength` are `private` inside `GlassesDisplayService`
  (`:125-127, :499-512`) — extract before "reuse the 120/40-char condensing" is real.
- `HUDIcon` lives inside the SDK-importing `GlassesDisplayService` (`HUDScreen.swift:28,43` type
  their fields with it) — move it next to the DSL so the DSL file's owner stops being an
  MWDAT-importing class.

`GlassesDisplayService` picks the active backend from `Config.displayBackend` (`.metaRayBan`
default / `.evenG2`) — **see the hybrid question below before hardening this either/or shape.**

## Input on EVEN — Phase 1 is mostly voice, and one real gap

**What already works with zero new code** (the original draft missed this): task cards accept
"done/next/skip/back" by voice (`HUDVoiceCommand`, `HUDRouter.handleVoiceCommand`, wired pre-LLM
at `OpenGlassesApp.swift:2328-2333`), and the launcher opens on "menu" and navigates by spoken
item labels (`HUDLauncher.handleVoiceSelection`). So EVEN Phase 1 is genuinely usable hands-free.

**The gap:** decision-step task cards render one button per branch (`choice:<id>`,
`HUDRouter.swift:190-196`) and there is **no voice path to select a branch** — `HUDVoiceCommand`
parses only complete/skip/back, and label selection fires only while the launcher menu is open.
On Meta the band covers it; on EVEN, decision workflows dead-end. Phase 1 must either add
branch-label voice selection (small: extend the voice grammar with the visible choice labels) or
carry an explicit "linear workflows only until Phase 2" scope note — and define how a stuck
interactive card is dismissed if voice fails.

**Phase 2:** temple-gesture events arrive on the notify characteristic; map to the same
`onItemSelected` channel the protocol now carries. Format TBD from capture logs.

## Bluetooth — first owned BLE stack in the app (new section)

There is **no first-party CoreBluetooth code anywhere in Sources today** — all glasses BLE lives
inside the DAT SDK. `EvenBLETransport` is greenfield: scanning, connect/reconnect, state
restoration, backgrounding are all new surface, not incremental. "No new SPM dependency" is true
and misleading — budget accordingly.

- **Pairing/settings UX (was missing from Files):** left/right lenses are *separate peripherals*
  (advertising `Even G2_*`) — a two-device pairing flow with a defined single-lens degraded state.
  New Settings surface: scan, select, persist both peripheral identifiers.
- **Info.plist:** `NSBluetoothAlwaysUsageDescription`/`NSBluetoothPeripheralUsageDescription`
  exist (`Info.plist:120-123`) but their strings say "Ray-Ban Meta smart glasses" — reword to
  cover both device families.
- **Background posture (decide):** `bluetooth-central` UIBackgroundModes +
  `CBCentralManagerOptionRestoreIdentifierKey` state restoration, or foreground-only v1 (simpler,
  consistent with the app's other lifecycle constraints). Name the choice in the PR.
- **Hybrid concurrent-radio decision (the big one):** the either/or `Config.displayBackend`
  forecloses the plausible best configuration — **Ray-Ban (non-Display) for camera/audio + EVEN G2
  for HUD**, DAT session and CoreBluetooth running concurrently. In that hybrid the "camera tools
  report unavailable on EVEN" guard is actively wrong. Decide: v1 either/or with hybrid as a named
  follow-up, or model the config as `cameraDevice`/`displayDevice` from the start (cheap now,
  annoying migration later).

## EVEN G2 protocol (community reconstruction — **verify before trusting**)

BLE (base UUID `00002760-08c2-11e1-9073-0e8ac72eXXXX`):
- Discover by advertising name `Even G2_*` (left/right are separate peripherals — pair both).
- Write commands: char `…5401` (handle `0x0842`), write-without-response.
- Notify responses/events: char `…5402` (handle `0x0844`), enable CCCD.
- Display rendering: char `…6402` (handle `0x0864`), 204-byte rendering packets.
- MTU 512; conn interval 7.5–30 ms; custom app-level auth handshake (not BLE pairing) — a
  7-packet handshake appears in the community capture logs.

Packet framing:
`[AA] [type] [seq] [len] [pktTotal] [pktSerial] [svcHi] [svcLo] [payload…] [crcLo] [crcHi]`
- `type`: `0x21` command / `0x12` response.
- `len` = payload length + 2 (CRC included).
- `pktTotal`/`pktSerial` for >MTU fragmentation (seq ID constant across a fragmented message).
- CRC-16/CCITT, init `0xFFFF`, poly `0x1021`, computed over **payload only** (skip the 8-byte
  header), emitted **little-endian**.

## Renderer contract (pinned 2026-07-10 — was under-specified)

The rendering payload format for `…6402` isn't fully documented, and that ambiguity was hiding the
renderer's *output type*. Pin it as a typed intermediate so steps 1–4 stay headless regardless of
which the wire wants:

- **`EvenFrame`** — the renderer's output: either `lines: [String]` (text/command wire) or a
  1-bit `[UInt8]` bitmap (framebuffer wire). Build the renderer against `EvenFrame`; only the
  packetizer cares which variant the device speaks. If bitmap: pick a fixed monospace glyph set +
  char-cell metrics up front (576 px ÷ advance = the *real* char budget — "wrap at 576px" and
  "120-char condensing" are not the same number), and name **golden-image fixtures**, not just
  string snapshots.
- **Mono mappings (decide, then test):** `HUDEmphasis` .primary/.secondary/.meta → e.g.
  normal / indent / prefix on 1-bit; `HUDButtonStyle` → numbered list entries (and the number
  grammar joins the voice-selection story above); the 10 semantic `HUDIcon`s → glyph substitutes
  (`[!]`, `→`, `•`) or dropped — enumerate all ten.
- **L/R frame policy (unanswered in draft):** same frame mirrored to both lenses, or split
  content? Affects transport and renderer; decide before the packetizer.

## Files

New (`OpenGlasses/Sources/Services/Display/Even/`):
- `EvenPacket.swift` — pure codec: header build/parse, CRC-16/CCITT, fragmentation. No I/O.
- `EvenFrame.swift` + `EvenScreenRenderer.swift` — pure `HUDScreen`/content → `EvenFrame`
  (mappings above; extracted `condense` reused).
- `EvenBLETransport.swift` — CoreBluetooth: scan, connect L+R, auth handshake, write, observe.
- `EvenDisplayBackend.swift` — renderer + transport behind `GlassesDisplayBackend`.

Modified:
- `GlassesDisplayService.swift` — extract the widened `GlassesDisplayBackend`; move the capability
  gate; route sends + selection events through the active backend.
- `HUDScreen.swift` / icon extraction; condense extraction.
- `Config.swift` — backend/device configuration (per the hybrid decision).
- Settings — EVEN pairing surface. `Info.plist` — reworded BLE strings.
- Camera-dependent tools — guard per the hybrid decision.

## Build order (deterministic core first, risky BLE last — per plan-delivery-rhythm)

1. `EvenPacket` codec + CRC, with **golden-vector tests** derived from community capture logs.
   **Licensing rider:** those logs come from an external project — confirm the license permits
   copying byte sequences into our test tree (ToS ≠ license); otherwise regenerate fixtures from
   the spec text by hand.
2. `EvenFrame` + `EvenScreenRenderer` + fixture tests (string or golden-image per the contract).
3. Backend extraction + `MetaDisplayBackend` (pure refactor; all existing HUD tests stay green).
4. `EvenDisplayBackend` over a **mock transport** (records packets) — full headless validation of
   render→packetize, including the notification/nav content path and a selection event round-trip.
5. `EvenBLETransport` (CoreBluetooth) behind the flag — the only device-gated part. Ships dark.

## Tests
- CRC vectors; framing + fragmentation round-trips (>512-byte payload → N packets, constant seq).
- `HUDScreen`/content → `EvenFrame`: title truncation, wrap at the real char budget, item
  numbering, emphasis/icon mono mappings, clear.
- Backend selection + regression: EVEN inactive → Meta path unchanged; capability gate routes
  through the backend; `show(title:body:icon:)` carries the ambient frame.
- Mock-transport capture: a task-card screen produces the expected packet stream; a synthetic
  selection event reaches `screenSelectionHandler`.
- Voice: decision-branch selection grammar (if chosen) resolves `choice:<id>` labels.

## Open questions / decisions needed
- **Hardware.** None on hand; steps 1–4 are fully headless, step 5 is not. "Tests are the gate."
- **Protocol fragility.** Community-reconstructed and partial; the vendor's official JS SDK is the
  reference oracle where the reconstruction is thin.
- **Legal/ToS + fixture licensing.** Shipping a reverse-engineered BLE protocol — confirm comfort;
  and see the build-order licensing rider.
- **Hybrid vs either/or** (Bluetooth section) — the highest-leverage open decision.
- **Gating.** A device-backend setting, not `agentModeEnabled` — not an autonomous/gateway feature.

## Dependencies / prereqs
- CoreBluetooth (system framework) — no new SPM dependency, but the app's first owned BLE stack.
- The community protocol reconstruction + capture logs as reference material (not a code
  dependency); the vendor's official JS SDK as an oracle.
- The `HUDScreen` DSL and `GlassesDisplayService` render queue already exist (Display Phases 1–4).

## Why this matters
A second, ungated display backend means we can demo and ship the HUD on real hardware without
waiting on Meta's permission flow — and it forces the HUD layer to become genuinely
backend-agnostic, which is good hygiene regardless of whether EVEN ever ships. Cost is bounded and
front-loaded into deterministic, testable code; the only hardware-gated piece (BLE transport) is
isolated behind a flag at the very end.
