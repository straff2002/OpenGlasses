# Plan IK — A Store Build Without the Glasses SDK (phone and earbuds on the App Store, glasses on TestFlight)

**Status:** Resumed 2026-11-01 for App Store remediation. The phone-only compile variant and SDK-free dependency overlay are implemented on `codex/app-store-guidelines-audit`; distribution archive/device checks remain release gates. See [the build procedure](../app-store-phone-only-build.md). This replaces JE's receipt-based hardware availability rule because App Review also uses sandbox receipts. The historical investigation and proposals below remain for context.
**Track:** Distribution (both the consumer app and Field Assist).
**Related:** Plan [IL](IL-technician-app.md) (the licence-only technician app; since 2026-10-17 it
keeps the glasses, with the owner renewing the Meta registration if required, and uses this variant
only if Meta needs approval before a public listing), Plan [FY](FY-rename-to-avenkin.md) (the listing and the decision not to tie the name to the
hardware), Plan [CT](CT-org-configuration-profiles.md) (the restricted edition), Plan
[DQ](DQ-third-party-telemetry-opt-out.md) (the SDK's telemetry opt-out and its guard tests), Plan
[HX](HX-glasses-link-and-device-state.md) (the link seam this plan stubs), Plan
[AH](even-display-backend.md) (a display backend that is not Meta's), Plan
[IG](IG-heycyan-glasses-backend.md) (a second glasses family behind the same seams).
**Origin:** A partner, 2026-10-16. Publishing to the App Store waits on Meta approving the app for
its release channel. The partner's customers will try the app on the phone and earbuds they
already own first ("they're unlikely to buy glasses just for a trial"), and for a larger customer
rollout they want a standard App Store install, not TestFlight. Their suggestion: keep the
glasses-enabled build on TestFlight and put a build without it on the store.

---

## Outcome

One source tree produces two builds of the same app record:

- **Store build** — no Meta Wearables SDK in the binary at all, no Meta keys in its `Info.plist`,
  no glasses pairing in onboarding or Settings. Phone microphone, AirPods or any Bluetooth headset,
  phone camera, CarPlay, the watch and every Field Assist feature work as they do today. Submitted
  for App Review and released on the store.
- **Glasses build** — what ships today, unchanged, distributed on TestFlight. Testers who install it
  keep the glasses.

When Meta approves the release channel, the glasses build becomes the store build and this
variant is retired or kept for organisations that want no glasses code on their phones.

## Why compile-time, not a runtime switch

A switch that hides the glasses still ships the SDK, its `com.meta.ar.wearable` accessory
protocol, the `mwdat-` URL scheme and the Wi-Fi hotspot entitlements, and the SDK's own network
code. The thing awaiting Meta's approval is the published app *using the toolkit*; a binary that
links it but hides it is still that app. Only a build that does not link the SDK is clearly
outside the question. It is also what App Review sees: no accessory protocol for hardware the
reviewer cannot test, and no Bluetooth usage string that names glasses the app cannot use.

## Verified starting point (`main` @ `8d0266ae0`, 2026-10-16)

- **One target links the SDK.** `project.base.yml` pins `meta-wearables-dat-ios` exactly at 1.0.0
  and links `MWDATCore`, `MWDATCamera` and `MWDATDisplay` into the `OpenGlasses` target only. The
  widget, share extension and watch targets do not link it; the test targets reach it through
  `TEST_HOST`. The root `Package.swift` still lists the SDK at `from: "0.7.0"` without
  `MWDATDisplay`. It is stale and nothing builds from it.
- **Seventeen app files import the SDK.** Services: `GlassesConnectionService`,
  `GlassesLinkSource`, `WearablesBootstrap`, `RegistrationFlow`, `StreamRecoveryPolicy`,
  `CameraErrorPolicy`, `SafeErrorSummary`. Camera and display: `Camera/MetaCameraBackend`,
  `Camera/StreamCodecPolicy`, `Camera/GlassesFramePipeline`, `Camera/DeviceSessionFailureReason`,
  `Display/MetaDisplayBackend`, `Device/DeviceSessionCoordinator`. Views: `OpenGlassesApp.swift`,
  `OnboardingView.swift`, `SettingsView.swift`, `HUDPreviewView.swift`. Eleven test files import
  it too. About ten raw `Wearables.shared` call sites sit in `OpenGlassesApp.swift`,
  `OnboardingView.swift` and `SettingsView.swift`.
- **The seams already exist.** `GlassesLinkSource` (`WearablesGlassesLinkSource` is the default in
  `GlassesConnectionService`), `GlassesCameraPermissionSource`, `GlassesCameraBackend`
  (`MetaCameraBackend` is `CameraService.init`'s default), `GlassesDisplayBackend` (Meta and EVEN
  implementations), `DeviceSessionHandle` behind `DeviceSessionCoordinator`. The phase,
  reachability and tier types (`GlassesConnectionPhase`, `GlassesReachabilityDiagnosis`,
  `GlassesTierPolicy`) are SDK-free. `GlassesDisplayService` constructs `MetaDisplayBackend`
  directly, and `HUDPreviewView` renders `MWDATDisplay` view types directly. Those two are the
  only places a seam is skipped.
- **There is a variant precedent.** `project.office-transport.yml` is an overlay that adds sources,
  a framework and `SWIFT_ACTIVE_COMPILATION_CONDITIONS = AVENKIN_OFFICE_TRANSPORT`.
  `Scripts/generate-xcodeproj.sh` composes it when `OPENGLASSES_OFFICE_TRANSPORT=1`, the same way
  it handles `OPENGLASSES_SKIP_WATCH`. 44 Swift sites test the condition. Nothing like it exists
  for the glasses SDK, and no Swift file tests `canImport(MWDATCore)`.
- **XcodeGen merges dependencies additively.** An overlay can add a package product but cannot
  remove one that `project.base.yml` declares. So the SDK has to move *out* of the base spec into
  an overlay that the default generation includes.
- **The phone already stands alone.** Onboarding's "Add a device" page offers "Use this phone"
  with no glasses required (Plan FY P2). The phone camera path (`PhoneCameraSource`,
  `PhoneCapturePolicy`, Plan GV) and the phone-mic wake word (Plan GU) are the defaults with no
  glasses connected. `docs/testflight-description.md` already says "with or without smart glasses".
- **Guards that will notice.** `TelemetryOptOutGuardTests` (the `MWDAT` opt-out keys and
  `MetaTelemetryBlock.install()` before `Wearables.configure()`), `MWDATConfigCheckTests`,
  `WearablesBootstrapTests`, and `OutboundFrameConsumerTests`' roster scrape.
- **Build identity.** `AppBuildIdentity` prints the commit, install channel and bundle id at the top
  of every support report. It does not say which variant.

## Decisions proposed (owner to confirm)

1. **Same app record and bundle id, two variants.** TestFlight can carry glasses builds while a
   different build of the same app is in review or on sale. A tester keeps the glasses by staying
   on TestFlight. A second bundle id for the glasses beta would split testers' data and settings
   for no gain. *(If Meta's terms turn out to bar a TestFlight build of an app record whose store
   build differs, a `…beta` bundle id is the fallback. Check with Meta before P3.)*
2. **The condition is negative and the default build is unchanged.** `AVENKIN_GLASSES_SDK` is set
   by the overlay that links the SDK, and that overlay is included unless
   `OPENGLASSES_NO_GLASSES_SDK=1`. Every existing developer command, CI job and Xcode Cloud workflow
   keeps producing today's build. Only the store workflow sets the variable.
3. **Stubs report "no glasses supported in this build", not "no glasses found".** The stub link
   source publishes a fixed `notSupportedInThisBuild` reachability. Copy that would say "connect
   your glasses" says nothing instead, because there is nothing the wearer can do. A Meta-glasses
   owner who installs the store build sees one line in Settings › Devices: glasses are in the
   TestFlight build, with the TestFlight link.
4. **EVEN G2 stays in the store build.** It is CoreBluetooth with no third-party SDK and no
   pending approval. Its HUD remains reachable through the `GlassesDisplayBackend` seam. *(If the
   owner prefers the store build to have no glasses at all for the first review, it rides behind
   the existing developer flag instead. That is decision 4b.)*
5. **The variant is in every support report.** `AppBuildIdentity` gains `variant: store | glasses`,
   because "glasses don't connect" from a store install is not a bug.

## Phases (one PR each)

### P0 — Move the SDK into an overlay; nothing changes

- New `project.glasses-sdk.yml` holding the package, the three products,
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) AVENKIN_GLASSES_SDK`, the hotspot and Wi-Fi
  info entitlements, and the `MWDAT_*` build settings. `project.base.yml` loses them.
  `generate-xcodeproj.sh` includes the overlay unless `OPENGLASSES_NO_GLASSES_SDK=1`.
  `ci_scripts/ci_post_clone.sh` and `Scripts/setup-local-dev.sh` need no change because the default
  includes it.
- Delete the stale root `Package.swift` (or bring it to 1.0.0 with all three products, if anything
  still reads it; P0 checks).
- **Exit test:** the generated `project.pbxproj` for the default variant is identical to today's
  apart from ordering (`diff` of the sorted build settings and package products), and the full
  suite passes unchanged.

### P1 — Stubs behind the seams, and the imports fenced

- `#if AVENKIN_GLASSES_SDK` around the 17 importers' SDK code. Each seam gets a store-build stub in
  a `Glasses/Unsupported/` folder compiled only without the condition:
  `UnsupportedGlassesLinkSource`, `UnsupportedCameraPermissionSource`,
  `UnsupportedGlassesCameraBackend` (every start fails with a named
  `CameraError.glassesNotInThisBuild`, so the phone camera path takes over exactly as it does with
  glasses disconnected) and an empty `DeviceSessionHandle` factory.
- `GlassesDisplayService` picks its backend through a factory, not a direct `MetaDisplayBackend()`.
  `HUDPreviewView` renders through the DSL's own preview types, or it is fenced and the preview row
  hidden.
- The ten raw `Wearables.shared` sites move behind `WearablesBootstrap` (URL handling,
  registration, pairing buttons), which has a stub twin.
- `GlassesReachabilityDiagnosis` gains `notSupportedInThisBuild`. The session card, Devices &
  Privacy › Glasses, the connect failure message, the Developer panel and the support report read
  it like any other reachability.
- **Exit tests (both variants, headless):** with `OPENGLASSES_NO_GLASSES_SDK=1`, the app and the
  test target build, and `otool -L` plus `nm` on the built binary show no `MWDAT` symbol or
  framework. A new `GlassesSDKAbsenceTests`, compiled only in the store variant, asserts the stubs
  are what `GlassesConnectionService`, `CameraService` and `GlassesDisplayService` hold. The SDK
  test files are fenced so the store-variant suite still runs everything else. The default variant
  is green with no test removed.

### P2 — The store build's own Info.plist and copy

- `OpenGlasses/Info.store.plist`, committed, not a local override (Plan DQ's ITMS-90683 lesson:
  the plist that ships is the one in the repo). It has no `MWDAT` dictionary, no `mwdat-` URL
  scheme, no `com.meta.ar.wearable` accessory protocol, no `external-accessory` background mode,
  no `fb-viewapp` query scheme, and Bluetooth usage strings that name headsets and EVEN glasses
  only. The overlay swaps `INFOPLIST_FILE` for the store variant alone.
- `TelemetryOptOutGuardTests` learns the variant: in the glasses build it checks today's keys; in
  the store build it asserts the `MWDAT` dictionary is *absent* and that no telemetry block is
  installed because nothing could send.
- `PrivacyInfo.xcprivacy` is unchanged. It already claims no analytics SDK, and the store build
  makes that claim trivially true.
- Copy: onboarding's "Add a device" page shows the phone, a headset and EVEN glasses. Settings ›
  Devices shows the TestFlight line from decision 3. The words "Meta" and "Ray-Ban" appear nowhere
  in the store build's UI. A guard test scrapes the store-variant string catalogue keys reachable
  from fenced views.
- `AppBuildIdentity` adds the variant (decision 5).
- **Exit test:** a Release archive of the store variant passes `xcrun altool --validate-app` (or
  the App Store Connect validation step in Xcode) with no ITMS warning about usage strings, URL
  schemes or accessory protocols.

### P3 — The store workflow and the submission

- An Xcode Cloud workflow (or the owner's manual archive recipe, since shipped builds are uploaded
  by hand) that sets `OPENGLASSES_NO_GLASSES_SDK=1` before generation. Build numbers stay one
  sequence across both variants, so a support report's build number is unambiguous.
- `Scripts/release-dossier.sh` prints the variant and refuses a store-variant archive whose binary
  contains an `MWDAT` symbol.
- App Store listing text says "works with your phone and earbuds; smart-glasses support is in
  testing". The review notes say there is no hardware to test and give a Field Assist demo licence
  code (the fictional vault of Plan [FR](FR-fictional-example-vault.md) is what the reviewer sees).
- **Owed by the owner:** the submission itself, the listing text, and the check with Meta named in
  decision 1.

## Acceptance

- A store-variant build installed on a phone with no glasses passes the same hand checks as a
  glasses build with glasses switched off: wake word on the phone mic, a Field Assist job by voice
  with AirPods, a phone-camera photo on a job, CarPlay debrief.
- A Ray-Ban Meta owner who installs the store build is told once where glasses support lives, and
  never sees a connect button that cannot work.
- The default `./Scripts/generate-xcodeproj.sh` output is byte-for-byte today's project apart from
  ordering, and nothing in the glasses build changes behaviour.

## Open questions for the owner

1. Decision 1: is the same app record acceptable to Meta, or should the glasses beta move to its
   own bundle id?
2. Decision 4b: EVEN G2 in the first store build, or hidden until after first review?
3. Is this plan still needed? Since 2026-10-17 the technician app (Plan IL) keeps the glasses, with
   the owner renewing the Meta registration if required, so this variant matters only if Meta
   needs approval before a public listing, or if the paid consumer app should reach the store
   without glasses. If neither applies, it stays drafted and unscheduled.
