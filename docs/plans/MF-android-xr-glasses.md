# Plan MF — Google's Android XR Glasses (a headset on the iPhone now, an adapter slot for later)

**Status:** 📝 Drafted 2026-11-17 — nothing implemented. P0 is headless and can be built now; P1 needs a
pair (they ship in December); P2 is a watch with named triggers, not code; P3 is a decision about Plan
[BA](BA-android-port.md), not a build. 5 decisions open.
**Track:** every channel; P0 touches the phone-only store build as well as the glasses build.
**Builds on:**
- Plan [CQ](CQ-third-party-glasses-backends.md) P0/P1: `GlassesTier` + `GlassesTierPolicy`, the
  data-only `MicRoutePolicy.glassesNameMarkers`, and the `GlassesCameraBackend` seam.
- Plan [AH](even-display-backend.md)'s `GlassesDisplayBackend`, the seam a display adapter would use.
- Plans [CH](CH-media-button-trigger.md)/[GJ](GJ-remappable-temple-gestures.md): temple gestures as AVRCP media commands through `MPRemoteCommandCenter`, mapped by
  `TempleCalibration`.
- Plan [HX](HX-glasses-link-and-device-state.md): `GlassesReachabilityDiagnosis` and the rule that only
  the DAT link state says "connected".
- [Cross-vendor glasses research](../cross-vendor-ai-glasses-research.md) (2026-09-29), whose Android XR
  section this plan acts on.

---

## Trigger

The owner, 2026-11-17: what do we need to do to support Google's new glasses, which went on presale
this month?

## What shipped, and what a third-party app can reach

**The product.** The first Android XR glasses, sold as *Intelligent Eyewear*: Samsung hardware in
Warby Parker and Gentle Monster frames. Preorders opened 12 November 2026 and shipping is reported for
December. Reports put the price at $395 and up, but listings still disagree. This first wave is
**camera, speakers, mics and a side touchpad, with no display**. Supported phones: Pixel 7 or later,
Galaxy phones on One UI 9, and **iPhone 13 Pro or later**.

**The developer model is Android-only.** An app for these glasses is a *projected activity*: an
Android `Activity` in the phone app's own APK, declared with
`android:requiredDisplayCategory="android.hardware.display.category.XR_PROJECTED"` and the
`XR_PROJECTED_LAUNCHER` category, so the wearer can open it by name through Gemini. It is started with
`ProjectedContext.createProjectedActivityOptions(_:)`. Hardware comes through Jetpack Projected
(`ProjectedDeviceController` for capabilities, the projected context for camera, mic and speakers,
with their own permission prompts), and display UI through Jetpack Compose Glimmer. All of it is alpha
(`androidx.xr.projected:projected:1.0.0-alpha14`, `glimmer:1.0.0-alpha22`). Nothing runs on the
glasses. There is **no iOS SDK and no documented iOS host** for a projected app. There is **no
distribution channel** for glasses apps yet: Google's docs say to test on the emulator, with
distribution news to come.

**So, on the iPhone,** these glasses reach Avenkin as a Bluetooth audio device and nothing else. The
camera, the touchpad's own events and any future display belong to Google's app. Our wake word and
voice loop can run through the glasses' mic and speakers. The touchpad may or may not reach us as
AVRCP media commands. Nothing else is available until Google or Samsung publishes an iOS route.

## What the code does with them today

- **The glasses build, before we know their Bluetooth name.** `glassesNameMarkers` has no token for
  them, so they read as an ordinary headset. The Headset mic route picks them up and the Glasses route
  ignores them. `GlassesTierPolicy` returns nil, so Settings › Connected Glasses says nothing is
  connected while the wearer is talking through them.
- **The session card.** It reads `GlassesReachabilityDiagnosis`, which is DAT-only. A wearer with only
  these glasses sees "no glasses added" and a Connect button that can never succeed for them. Ray-Ban
  Meta Audio, the camera-less pair DAT never lists, has the same problem today.
- **The phone-only store build drops them if the name says "glasses".** That build's markers are just
  `["glasses"]` and it offers no Glasses mic route (`MicRoute.available`). The Headset route
  deliberately never takes a port that `looksLikeGlasses` (`preferredInputIndex`, so a Meta pair's
  hands-free link isn't opened by accident). So if the pair advertises a name containing "glasses",
  the store build has **no route that can choose their mic**. The App Store is the main channel and
  these glasses need no Meta SDK, so this matters more than the label.

## What changes

### P0 — audio-only glasses are a real state (headless, buildable now)

1. **A separate reading for audio glasses.** A pure `AudioGlassesPresence` takes the available
   Bluetooth input ports and the DAT phase. It answers `none`, or `audioOnly(portName:)` when a port
   looks like glasses and the DAT phase is not `.connected`. It **never** feeds `phase`,
   `isConnected` or the reachability diagnosis: the DAT rule stands that only the DAT link says
   connected. It is published beside them, read by `GlassesTierPolicy` (unchanged in shape) and by
   the support report (port name and type only).
2. **The session card says so.** With `audioOnly`, the glasses pill reads "‹name› — voice only" and the
   away hint stops offering Connect for that pair. Connect stays available, worded for camera
   glasses, for a wearer who also owns Meta glasses. Settings › Connected Glasses already words
   `audioOnly`, so that copy carries over.
3. **The store build can choose a glasses mic.** Decision 3 picks the shape. Recommended: in the
   phone-only build, the Headset route accepts a glasses-named port **only** when nothing else is
   there to take. That build has no DAT session whose hands-free link the rule protects. The glasses
   build keeps its rule unchanged.
4. **Room for the marker.** Add a one-line slot in `glassesNameMarkers` for the Android XR pair, with
   a comment that it is filled from P1's reading, never guessed. The false-positive corpus gains
   entries for common earbud names that share fragments with the eventual token.

Tests (`AudioGlassesPresenceTests` plus additions to the `MicRoutePolicy` and `GlassesTierPolicy`
suites):
- presence never flips the phase;
- DAT-connected wins over audio;
- a Meta pair connected over DAT with its HFP route up reads as `.camera`, not twice;
- the store-build fallback takes a glasses port only when it is alone;
- the glasses build's Headset route is unchanged;
- the false-positive corpus still passes;
- the support report line carries no more than name and port type.

### P1 — the device pass (needs a pair; decision 1)

Pair with an iPhone 13 Pro or later, then on the glasses build **and** the store build record:
- **Names.** The advertised HFP, LE and A2DP port names and types. Fill the P0 marker with the most
  distinctive token, never a bare "glasses" fragment.
- **Audio.** Wake word over HFP and over LE audio; the reply on A2DP and on HFP; the echo path
  (`hasNoEchoPath`); whether the Gemini app's own hotword or its hold on the mic interrupts ours, and
  what `WakeWordService` sees when it does.
- **Touchpad.** Does a tap, double tap or hold reach `MPRemoteCommandCenter` while we hold Now
  Playing, or does Google's app take it? If it reaches us, run `TempleCalibration` against it.
- **The camera button.** Confirm it does nothing for us, and that nothing in the app implies it
  could.
- **The known iPhone 17 / iOS 26 HFP issue,** on that model if one is to hand.

Write the results into this plan and the support doc's compatibility table. Until P1 passes,
no store copy, website or reply claims these glasses work beyond "as a Bluetooth headset".

### P2 — watch for an iOS route (no code)

The adapter slots exist (`GlassesCameraBackend`, `GlassesDisplayBackend`), so a published iOS route
becomes a plan of its own, sized then. Reopen this plan when any of these happens:
- **(a)** Google or Samsung publishes an iOS SDK, or an iOS host for projected activities: camera
  frames, display, touchpad events or a capture LED contract.
- **(b)** Google opens distribution for glasses apps on Play (this feeds P3).
- **(c)** A display model ships in this family (this feeds P3, and Glimmer becomes relevant).
- **(d)** Partners or customers ask for Android.

Check Google's developer release notes for Jetpack XR and Projected monthly, alongside the DAT bump
check.

### P3 — the Android question (a decision, not a build)

Full support for these glasses means an Android app, which is Plan [BA](BA-android-port.md). BA was
drafted in July around Meta's Android toolkit. Its estimate is 5–7 engineer-months to parity, or 7–10
weeks for the cloud-only first version. When a P2 trigger fires, BA gets a fresh code-verified pass
that accounts for the projected model:
- **Launch.** The wearer opens the app by name through Gemini, so Avenkin would be an app on the
  glasses, not the always-listening assistant it is on Meta glasses. That changes the wake-word
  product, not just the plumbing.
- **Hardware.** Camera, ASR and TTS come through the projected context, and display through Glimmer.
- **Shared pieces.** The `GlassesCameraBackend` capability vocabulary and the privacy-filter
  chokepoints are product rules to carry over, not code.
- **Policy.** Before anything is built, review Google's developer and acceptable-use terms for
  glasses (identification of people, bystander capture, the capture LED), as was done for Meta.

## Decisions open

1. **Buy a pair now?** Recommended: one pair on preorder, any frame. P1 can't happen without it, and
   no emulator stands in for iOS.
2. **Ship P0 before the pair arrives?** Recommended: yes. It fixes the "no glasses added" card for
   Ray-Ban Meta Audio owners today, and the marker slot stays empty until P1.
3. **The store-build mic fallback.** (a) Recommended: the Headset route takes a glasses-named port
   only when it is the only Bluetooth mic. (b) Offer the Glasses mic route in the phone-only build
   for non-Meta glasses. (c) Leave it, and wait to see whether the advertised name contains
   "glasses".
4. **Which build carries the Android XR marker?** Recommended: both. On the iPhone it is a plain
   Bluetooth device with no SDK and no ExternalAccessory, so nothing about it is a review risk.
5. **What we say publicly.** Recommended: nothing until P1. After it, only "works as a Bluetooth
   headset (voice only)" in the compatibility table, with Google's product names used only to state
   compatibility.

## Phases

- **P0** — audio-only presence, the session card, the store-build mic fallback, the marker slot.
  One PR, headless, with its strings synced in the catalog PR that follows.
- **P1** — device pass on a pair; fill the marker and the compatibility table.
- **P2** — watch; reopen on a trigger.
- **P3** — refresh Plan BA when a trigger fires; not scheduled.

## Sources

- [Augmented experiences for audio and display glasses](https://developer.android.com/develop/xr/explore/augmented)
- [Create your first activity for audio and display glasses](https://developer.android.com/develop/xr/jetpack-xr-sdk/glasses/first-activity)
- [Build for audio and display glasses](https://developer.android.com/develop/xr/jetpack-xr-sdk/ai-glasses/build)
