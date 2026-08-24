---
description: Swift patterns, async/await, naming conventions, key types for DAT SDK iOS development
---

# DAT SDK Conventions (iOS) — v0.9.0

## Architecture

The SDK is organized into modules:
- **MWDATCore**: Device discovery, registration, permissions, device selectors, `DeviceSession`, device state (`deviceStateStream` / `ThermalLevel`), `ListenerTokenBag`
- **MWDATCamera**: `Camera` (owns the hardware resource) → `Stream`, `VideoFrame`, `PhotoData`, photo capture
- **MWDATDisplay**: in-lens HUD — `Display` + view types (`FlexBox`, `Text`, `Button`, `ButtonGroup`, `Image`, `Icon`, `VideoPlayer`)
- **MWDATMockDevice**: `MockDeviceKit` for testing without hardware (UI-test oriented)

Minimum deployment target is **iOS 17.2** (bumped from 15.2 in 0.9.0).

## Swift Patterns

- Most SDK operations are `async/await`, **but** `Stream.start()/stop()`, `Camera.stop()` and
  `Display.start()/stop()` are **synchronous** (no `await`). `Display.send(_:)` /
  `Display.clearDisplay()` are async.
- Capabilities are managed through their `DeviceSession`: `addCamera(config:)` / `addDisplay()`.
  0.9.0 consolidated the camera: `addStream(config:)` is **removed** — `addCamera(config:)` returns
  a `Camera` whose `.stream` is the streaming session. `Camera.stop()` detaches the capability and
  cascades to its children; `stream.stop()` alone pauses streaming but keeps the capability attached.
- The camera capability is process-wide and frees only when the `Camera` finishes stopping
  (`CameraState.stopped`) — re-adding before then throws `capabilityAlreadyActive`.
- Observe streams via the `Announcer` publishers' `.listen {}` (`statePublisher`, `videoFramePublisher`,
  `photoDataPublisher`, `errorPublisher`); `Camera.statePublisher` reports the capability lifecycle.
  Aggregate listener tokens with `ListenerTokenBag` / `token.store(in:)` (0.9.0) to cancel together.
- `DeviceSession.stateStream()` / `errorStream()` **finish** once the session reaches `.stopped`
  (0.9.0); a stream created after stop finishes immediately — `for await` loops exit on their own.
- Annotate UI-updating code with `@MainActor`; never block the main thread with frame processing.
- All SDK errors conform to **`DatError`** (`LocalizedError`) with a consistent `description`.
  `capturePhoto(format:)` returns `Bool` (request accepted); the photo arrives on
  `photoDataPublisher` and stream errors on `errorPublisher` (`StreamError`).

## Naming Conventions

| Type | Convention | Example |
|------|-----------|---------|
| Entry point | `Wearables.shared` | `Wearables.shared.startRegistration()` |
| Sessions | `DeviceSession` | `Wearables.shared.createSession(deviceSelector:)` |
| Camera | `Camera` / `StreamConfiguration` | `deviceSession.addCamera(config:)` → `camera.stream` |
| Selectors | `*DeviceSelector` | `AutoDeviceSelector(wearables:filter:)`, `SpecificDeviceSelector` |
| Publishers | `*Publisher` (Announcer) | `statePublisher`, `videoFramePublisher`, `errorPublisher` |

## Imports

```swift
import MWDATCore    // Registration, devices, permissions, DeviceSession, device state
import MWDATCamera  // Camera, Stream, StreamConfiguration, VideoFrame, PhotoData, photo capture
import MWDATDisplay // Display + view types (FlexBox/Text/Button/ButtonGroup/Image/Icon/VideoPlayer)
```

For testing:
```swift
import MWDATMockDevice  // MockDeviceKit, MockGlasses, MockCameraKit; pairGlasses(model:)
```

## Key Types

- `Wearables` — SDK entry point. Call `Wearables.configure()` at launch, then use `Wearables.shared`.
  Device state via `Wearables.deviceStateStream(for:)` (`DeviceState.thermalLevel`); there is no
  `DeviceStateSession` (removed in 0.7.0).
- `DeviceSession` — owns the connection; create with a device selector, then `addCamera`/`addDisplay`.
- `Camera` — owns the camera hardware resource (0.9.0); `camera.stream` is the streaming session,
  `camera.state`/`statePublisher` report the capability lifecycle (`CameraState`), `stop()` is sync
  and cascades to the stream.
- `Stream` — camera streaming session (reached via `camera.stream`); `start()/stop()` are sync;
  `capturePhoto(format:) -> Bool`.
- `StreamConfiguration` — video codec, resolution, frame rate.
- `Display` — in-lens HUD; `send(_:)` replaces content (async), `clearDisplay()` blanks it (async),
  `start()/stop()` are sync. `ButtonGroup` (+ `ButtonGroupBuilder`/`ButtonGroupAlignment`) lays out
  button rows (0.9.0); the component result builder supports full if/else.
- `Device.supportsDisplay()` / `DeviceType.supportsDisplay` — capability gate; `AutoDeviceSelector(wearables:filter:)`
  can constrain selection (e.g. `filter: { $0.supportsDisplay() }`).
- `DeviceType` — `.rayBanMeta`, `.oakleyMetaHSTN`, `.oakleyMetaVanguard`, `.rayBanMetaOptics`, `.metaGlasses`.
- `ListenerTokenBag` — actor aggregating listener tokens; `insert(_:)`/`clear()` are nonisolated,
  `cancelAll()` is async; `AnyListenerToken.store(in:)` is the sugar.
- `MockDeviceKit` — `pairGlasses(model: GlassesModel)` (throws `MockDeviceKitError`, a `DatError`
  as of 0.9.0); `MockCameraKit.setCameraFeed(cameraFacing:)` is synchronous (0.9.0). Oriented at the
  UI-test process (`MockDeviceTestClient`), not headless unit tests (`Wearables` fatals there).
  0.9.0 aligned the mock's `Info.plist` link-availability checks with real devices — missing
  Bluetooth/Wi-Fi entries fail identically on mock and hardware.

## Error Handling

```swift
do {
    try Wearables.configure()
    try deviceSession.start()           // throwing, synchronous
} catch {
    // typed DatError: LocalizedError
}

// Camera errors arrive on the publisher (StreamError), not by throwing from capturePhoto:
stream.errorPublisher.listen { (error: StreamError) in /* map via CameraErrorPolicy */ }
```

Notes from the field:
- `CaptureError` was **removed** in 0.9.0 (it was declared but never emitted in 0.8.0). Photo-capture
  failure now arrives as `StreamError.photoCaptureFailed` on `errorPublisher`.
- `StreamError.hingesClosed` now also fires when the device is doffed (0.9.0) — previously that case
  collapsed into a generic pause.
- **WiFi transport** is transparent — no app-facing API; the SDK negotiates it.
- The DAT App Model (DAM) is always enabled as of 0.9.0 — the `MWDAT.DAMEnabled` Info.plist opt-out
  key is ignored. Crash-reporting opt-out: `MWDAT > CrashReporting > OptOut` (Bool, default `false`).
- **Data collection is opt-out, and this app opts out.** `MWDATCore` POSTs `ar_wearables_sdk_*`
  event batches (session, stream, permission, display, crash) to a hard-coded
  `api2.ar.meta.com/mwsdk/telemetry`. Both `MWDAT > Analytics > OptOut` and
  `MWDAT > CrashReporting > OptOut` are `YES` in `OpenGlasses/Info.plist` and must stay that way —
  absent or `NO` means opted **in**. `MetaTelemetryBlock` is the backstop: it registers a
  `URLProtocol` before `Wearables.configure()` that answers that endpoint locally and counts what
  it stopped. Attestation (`/wearables/attestation/challenge`) shares the host and is deliberately
  **not** blocked — it gates device access.

## Links

- [iOS API Reference](https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.9)
- [Developer Documentation](https://wearables.developer.meta.com/docs/develop/)
- [GitHub Repository](https://github.com/facebook/meta-wearables-dat-ios)
