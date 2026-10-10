---
description: Swift patterns, async/await, naming conventions, key types for DAT SDK iOS development
---

# DAT SDK Conventions (iOS) — v1.0.0

## Architecture

The SDK is organized into modules:
- **MWDATCore**: Device discovery, registration, permissions, device selectors, `DeviceSession`, device state (`Device` accessors / `addDeviceStateListener`, `ThermalLevel`), `ListenerTokenBag`
- **MWDATCamera**: `Camera` (owns the hardware resource) → `Stream`, `VideoFrame`, `PhotoData`, photo capture
- **MWDATDisplay**: in-lens HUD — `Display` + view types (`FlexBox`, `Text`, `Button`, `ButtonGroup`, `Image`, `Icon`, `VideoPlayer`)
- **MWDATMockDevice**: `MockDeviceKit` for testing without hardware (UI-test oriented)

Minimum deployment target is **iOS 17.2** (bumped from 15.2 in 0.9.0; unchanged in 1.0.0).

**1.0.0 is semver — for the stable surface only.** Anything Meta labels **[Experimental]** may change
in any minor, and **apps that use it cannot be published**. In 1.0.0 that is the `MWDATInputs`,
`MWDATMotion` and `MWDATSpeech` modules, voice invocations in `MWDATCore` (`VoiceInvocationsStream`),
and in `MWDATCamera` standalone `Camera.photo` capture and camera audio
(`StreamConfiguration.audioCodec`, `Stream.audioFramePublisher`). **Do not link the experimental
modules or call the experimental APIs** — the Core/Camera ones ship inside modules we already link,
so nothing but review stops them. The package stays pinned exact in `project.base.yml` so a 1.y
is read and adopted deliberately.

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
  `Wearables.deviceStateStream(for:)` was **removed in 1.0.0** (as was `DeviceStateSession` in
  0.7.0): device state lives on `Device` — `Wearables.shared.deviceForIdentifier(_:)`, then the
  accessors `batteryLevel` (`Int?`), `chargingState`, `donState`, `hingeState`, `thermalLevel`, or
  `Device.addDeviceStateListener(_:)`, which delivers the full `DeviceState` (now also `linkState`
  and `compatibility`) immediately and on every change.
- **Connected means `linkState == .connected`, nothing else.** Registration (`registrationState`)
  and the device list (`addDevicesListener`) describe a pair that has been *added* — a pair in its
  case stays registered and listed for days. `WearablesGlassesLinkSource` is the only code that
  maps SDK state: it subscribes `Device.addDeviceStateListener(_:)` per listed device (link,
  battery, charging), hops to the main queue in order, and maps `LinkState`/`ChargingState` onto
  the app's own enums. `GlassesConnectionService` owns the subscriptions (one per device, cancelled
  when the device leaves the list or on `stopObserving()`) and folds everything through the pure
  `GlassesConnectionSnapshot` into `phase` (`noGlassesAdded` / `addedDisconnected` / `connecting`
  / `connected`); `isConnected`, `deviceName` and `batteryLevel` (only while connected — never a
  stale reading) derive from it. `AppState.isConnected`/`glassesPhase` mirror `phase` in
  `applyGlassesPhase(_:)`, their only writer — never set the flag from registration, the device
  list, a permission result or an audio-route event. `CameraService.isGlassesLinkUp` gates glasses
  capture on the same truth. `donState` (`.unknown`/`.doffed`/`.donned`, stable API) is mapped to
  `GlassesDeviceState.worn` (`Bool?`) and published as `GlassesConnectionService.isWorn` (only while
  connected); `GlassesSleepPolicy` uses it for the automatic stand-down (taken off → 30 s grace →
  stand down → put on → resume), only while the always-on wake word runs. `thermalLevel` and
  `compatibility` are mapped to `GlassesDeviceState.thermal` (`GlassesThermal?`, unknown → nil) and
  `.compatibility` (`GlassesCompatibility`) and published as `GlassesConnectionService.thermal` /
  `.compatibility` (only while connected): thermal feeds `PowerPolicyService`, and an update
  requirement is said once per process (`CompatibilityNoticePolicy`). The compatibility reading
  never stops the camera by itself; a session refused with `.insufficientSDKVersion` does, for the
  rest of the process (`SDKRefusalLatch`). `hingeState` is not read.
- **Not connected has a reason, and the reason is a reading.** `GlassesReachabilityDiagnosis`
  (pure) reads registration, each listed device's link and the Meta camera permission's last known
  status into `notAdded` / `awaitingApproval` / `permissionNeeded` / `noDeviceSeen` / `linkDown` /
  `linkComingUp` / `connected`. `GlassesConnectionService` publishes it inside `reachability`
  (mirrored by `AppState.glassesReachability`) and words `connectionStatus` from it; the session
  card, Devices & Privacy › Glasses, the connect failure message, the Developer panel and the
  support report read it. It never feeds the phase: a granted permission connects nothing.
- **The SDK lists a device only once a permission is granted in Meta AI, and asking for one leaves
  the app.** `Wearables.shared.checkPermissionStatus(.camera)` reads it and
  `requestPermission(.camera)` deep-links to Meta AI. Launch, a registration change and an emptied
  device list only ever read (`GlassesConnectionService.checkCameraPermission()`); the request
  belongs to something the wearer pressed (`requestCameraAccess()`: the Connect, and "Allow camera
  access in Meta AI"), one attempt per press. Both go through
  `MetaCameraBackend.cameraPermission(asking:)`, behind the `GlassesCameraPermissionSource` seam.
  `ensurePermission()`, on the way to a camera start, still checks and requests with three
  attempts, and reports how it ended as a `.cameraPermission` backend event. Do not call it from a
  listener or a launch path. Both calls throw `PermissionError` (`noDevice`,
  `noDeviceWithConnection`, `connectionError`, `metaAINotInstalled`, `requestInProgress`,
  `requestTimeout`, `internalError`; not frozen); it describes itself, so summarise it with
  `MetaCameraBackend.permissionSummary(of:)`, which keeps the case name.
- `DeviceSession` — owns the connection; create with a device selector, then `addCamera`/`addDisplay`.
  `DeviceSession.device` (1.0.0) is the live `Device?` snapshot for the session's device.
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

// Session errors (update-required, device conditions) arrive on the session, not the stream:
for await error in deviceSession.errorStream() { /* DATCompatibilityMessage, CameraErrorPolicy */ }
```

Notes from the field:
- **1.0.0 renamed `StreamError`'s device-condition cases** to match Android: `.thermalCritical` and
  `.thermalEmergency` → `.thermalHot`, `.peakPowerShutdown` → `.peakPowerLimit`, `.batteryCritical` →
  `.batteryLow`; and added `.audioStreamingError` (only reachable with the experimental camera audio,
  which we never enable). `DeviceSessionError` kept the **old** names — `.thermalCritical`,
  `.thermalEmergency`, `.peakPowerShutdown`, `.batteryCritical` are still its cases.
- **`DeviceSessionError` gained two cases in 1.0.0 with opposite meanings.**
  `.insufficientSDKVersion` is **terminal**: the glasses refuse an app built against this SDK, and
  only shipping a newer build fixes it — `CameraErrorPolicy` stops retrying and
  `DATCompatibilityMessage` says to update OpenGlasses. `.dwaOutOfStuRange` is a **nonblocking
  warning**: the session carries on. `DATCompatibilityMessage.isAdvisory(_:)` marks it so the
  camera's session-error watcher logs it and moves on, rather than recording it as the reason a
  healthy start failed; at most, a gentle update suggestion — never an announcement.
- **1.0.0 also broke API its changelog doesn't mention** (diff the `.swiftinterface`s, not the
  changelog): `RegistrationError.timeout` and `UnregistrationError.timeout` are gone;
  `DisplayError.deviceNotFound`/`.connectionNotAvailable` are gone; `WearablesError` gained
  `missingInfoDictionary`/`missingBundleIdentifier`/`missingAppName`/`missingAppVersion`/
  `missingBuildNumber` (`configure()` now validates those `Info.plist` basics); and
  `RegistrationError`, `UnregistrationError`, `WearablesError`, `WearablesHandleURLError`,
  `NavigationError` and `DeviceSessionError` are no longer `@frozen` — every switch over them needs
  `@unknown default` (or `default`). `DeviceState`'s memberwise init grew the new fields (all
  defaulted).
- `NavigationError` (MWDATCore, the error `openFirmwareUpdate()`/`openDATGlassesAppUpdate()` throw)
  conforms to `DatError` as of 1.0.0. The app has its own `NavigationError` in
  `WalkingRouteService.swift`; within the app module ours shadows the SDK's, so qualify the SDK one
  as `MWDATCore.NavigationError` if you ever need to name it.
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
  **not** blocked — it gates device access. Re-checked against the 1.0.0 binaries: same two URLs,
  same `ar_wearables_sdk_*` event names, same documented opt-out keys, no bundled privacy manifest. Repeat the
  `strings` diff on every bump.
- **Telemetry posture for any newly linked SDK: off by default, disclosed by exception, never
  silent.** Before a new third-party dependency ships, review what it sends home by default and
  either disable it or disclose it — in `PrivacyInfo.xcprivacy` *and* the in-app privacy copy, in
  the same PR. A vendor default is not consent, and an undisclosed egress contradicts the manifest's
  "no analytics, crash-reporting, or advertising SDK" claim the moment it starts. The pairing is
  enforced by `TelemetryOptOutGuardTests`, which also checks the `MWDAT` opt-out keys in the
  authored `Info.plist` and that `MetaTelemetryBlock.install()` still precedes
  `Wearables.configure()`.

## Links

- [iOS API Reference](https://wearables.developer.meta.com/docs/reference/ios_swift/dat/latest)
- [Developer Documentation](https://wearables.developer.meta.com/docs/develop/)
- [GitHub Repository](https://github.com/facebook/meta-wearables-dat-ios)
