# Cross-vendor AI glasses support from one iOS app

**Research date:** 26 August 2026

**Status:** Product and architecture recommendation; not an implementation commitment

Related: [OpenGlasses opportunity assessment](opportunity-assessment.md).

## Executive decision

OpenGlasses should remain one iOS product and add device adapters behind capability-based camera, microphone, display, input, and lifecycle ports. It should not become an Android app merely to support more glasses.

This can deliver a consistent OpenGlasses experience across Meta, Omi, Even Realities, and future vendors, but it cannot make every pair of Bluetooth glasses expose capabilities its maker keeps private. A device is supportable from iOS when at least one of these is available:

1. a maintained vendor iOS SDK;
2. a documented, permitted BLE/Wi-Fi protocol; or
3. a supported companion or on-glasses bridge with an authenticated OpenGlasses protocol.

The recommended order is:

1. finish the cross-device capability and conformance layer;
2. add Omi through its official open Swift/BLE surface;
3. move Even G2 production support to the official Even Hub route, keeping direct BLE explicitly experimental;
4. pursue Rokid's current iOS CXR partner package;
5. monitor Android XR for an iOS/OEM device-access surface; and
6. treat XREAL as a later display/spatial target rather than the first everyday AI-glasses integration.

`xg.glass` is a strong architectural and testing reference, particularly for Omi and Even. OpenGlasses should selectively adapt its patterns and Apache-licensed source, with attribution, rather than replace its existing integrations with the pre-1.0 binary package.

## The product being built

The goal is not “an app for glasses” in the singular. It is one assistant whose relationship, memory, safety policy, skills, and phone UI stay constant while the attached wearable changes.

For an everyday user, this should feel like:

- pair a supported device once;
- see exactly which features it provides;
- speak to the same assistant on any audio-capable glasses;
- add first-person vision only when the device exposes a camera;
- add glanceable or interactive content only when the device exposes a display and input;
- retain conversations, tasks, preferences, and privacy controls when changing hardware; and
- receive a specific explanation when a feature is unavailable, rather than a failed action or a misleading phone-camera fallback.

This “capability-degraded” product is more credible than promising one undifferentiated compatibility badge. Audio-only Omi, camera-first Meta, glance-display Even, and spatial XREAL hardware are different products even when they all use the word *glasses*.

## What is already transferable in OpenGlasses

OpenGlasses has most of the correct seams already:

- [`GlassesCameraBackend`](../OpenGlasses/Sources/Services/Camera/GlassesCameraBackend.swift) separates device camera sessions from feature-facing camera state.
- [`CameraCapabilities`](../OpenGlasses/Sources/Services/Camera/CameraCapabilities.swift) makes live frames, still capture, latency, microphone concurrency, and hardware events explicit.
- [`GlassesDisplayService`](../OpenGlasses/Sources/Services/GlassesDisplayService.swift) owns backend-neutral queuing, deduplication, text shaping, and interactive-state rules.
- [`GlassesDisplayBackend`](../OpenGlasses/Sources/Services/Display/MetaDisplayBackend.swift) separates display rendering and selection events from the Meta SDK.
- [`HUDScreen`](../OpenGlasses/Sources/Services/Display/HUDScreen.swift) is an SDK-free semantic display model.
- Camera, audio, and display can already be selected independently, which permits useful hybrids such as Meta vision with an Even display.

Consequently, most assistant behavior and feature orchestration is reusable. The non-transferable work is at the hardware edge: discovery, pairing, permissions, authentication, codecs, packet framing, transport recovery, firmware variance, and vendor-specific display/input models.

An indicative transfer assessment is:

| Layer | Reuse across vendors | Why |
|---|---:|---|
| Assistant, memory, skills, safety and phone UX | 85–100% | Independent of glasses transport |
| Feature gates and user-facing capability explanations | 75–95% | Existing camera precedent can expand to all modalities |
| HUD content and action semantics | 65–90% | Portable after closures become stable action identifiers |
| Camera/audio/display service orchestration | 60–85% | Ports exist, but audio and device lifecycle need widening |
| Device transport and protocol | 0–60% | Entirely dependent on each vendor's public surface |
| Android XR projected activity code | 0% on iOS | It is an Android host-app execution model |

These percentages are architectural estimates, not vendor guarantees.

## Vendor findings

### Meta: the reference full integration

Meta is the strongest current integration. The repository pins the iOS Device Access Toolkit at 0.9.0 and uses `MWDATCore`, `MWDATCamera`, and `MWDATDisplay`. The app already has registration, camera streaming/stills, device selection, display rendering, and model-dependent interactive controls. Meta should remain the reference adapter and conformance oracle.

Capability must still be reported per physical model. Ray-Ban Meta camera/audio glasses do not inherit a display simply because the SDK also supports Meta Ray-Ban Display. The existing runtime `supportsDisplay()` check is the correct pattern.

Sources: [Meta Wearables developer documentation](https://wearables.developer.meta.com/docs/develop/), [Meta iOS DAT repository](https://github.com/facebook/meta-wearables-dat-ios).

### Android XR: transferable product semantics, not transferable iOS transport

Android XR display-glasses experiences are **Projected Activities**. The application logic runs on a paired Android phone and is projected to the glasses; hardware access is obtained from the projected Android context. This is attractive for an Android build, but it is not a protocol that the OpenGlasses iOS app can call.

Google has announced consumer audio-glasses compatibility with both iOS and Android. That establishes phone compatibility, but it does not establish a public third-party iOS API for camera frames, display composition, gestures, or Android XR projected activities.

For the current iOS product, Android XR therefore means:

- generic Bluetooth call/media audio where the device exposes standard profiles;
- no promise of first-person camera, display, or input access;
- a future native adapter only if Google or an OEM publishes an iOS SDK; or
- a future supported bridge if the hardware can run one or the vendor companion exposes one.

Lightweight projected glasses generally do not run a third-party APK on the glasses themselves, so “put a bridge on the device” is not a safe assumption. A companion bridge would also introduce a second Android app, contradicting the present one-iOS-app product unless it is optional and vendor-managed.

Sources: [Build an Android XR projected activity](https://developer.android.com/develop/xr/jetpack-xr-sdk/glasses/first-activity), [access hardware from a projected context](https://developer.android.com/develop/xr/jetpack-xr-sdk/access-hardware-projected-context), [Compose Glimmer for display glasses](https://developer.android.com/agents/skills/xr/display-glasses-with-jetpack-compose-glimmer/skill), [Google I/O 2026 announcements](https://blog.google/innovation-and-ai/technology/ai/google-io-2026-all-our-announcements/).

### Rokid: promising hardware, but current iOS access must be obtained from Rokid

Rokid's current CXR model describes the right capabilities for OpenGlasses. CXR-L connects an application through the Rokid AI companion and exposes image, audio, display, and command channels; CXR-S supports apps on YodaOS-Sprite with a mobile communication layer. Rokid also ships an iOS consumer app, proving that its own iOS companion path exists.

The public iOS mobile SDK repository is older and is centred on provisioning, commands, skills, and device management. It is not sufficient evidence that today's camera/display CXR APIs are publicly available to an independent iOS app. The current Open Platform material is Android- and partner-oriented.

Recommended next action: ask Rokid for the current international iOS CXR-L/CXR-M SDK, commercial terms, App Store entitlement requirements, supported device/firmware matrix, and permission model. If access is granted, run a bounded spike for discovery, first-person still or stream, microphone frames, one HUD frame, one hardware command, background recovery, and disconnect cleanup before committing the product roadmap.

Do not base production support on reverse engineering a proprietary Rokid binary. Public headers, samples, documented protocols, and contractually supplied SDKs are acceptable integration inputs.

Sources: [Rokid Open Platform](https://open.rokid.com/), [Rokid iOS mobile SDK documentation repository](https://github.com/rokid/mobile-sdk-ios-docs), [Rokid consumer FAQ](https://global.rokid.com/pages/faq), [Rokid Glasses product page](https://global.rokid.com/products/rokid-glasses).

### XREAL: a later display/spatial target

XREAL's public developer route is primarily Android/Unity and its current product direction includes full Android XR spatial devices such as XREAL Aura. Existing XREAL products can act as an iPhone external display with the required adapter, but generic video output does not provide camera, head-pose, controller, or display-layout APIs to an iOS app.

This makes XREAL useful for a later “private large screen” or spatial OpenGlasses experience, not the quickest route to ordinary AI glasses. A first integration could mirror the existing web HUD or a dedicated iOS presentation to an external display. A richer adapter should wait for an official current iOS SDK or documented device protocol.

Sources: [XREAL SDK downloads](https://developer.xreal.com/download/), [XREAL Aura](https://www.xreal.com/aura).

### Even Realities G2: use the official product layer

Even's official G2 platform is substantially clearer now. The G2 provides a 576 × 288 display per eye, a 16-level green palette, BLE 5.2, four microphones exposed as a single 16 kHz PCM stream, temple touch input, and optional R1 ring input. It has no camera and no speaker. Even Hub hosts phone-side web plugins and provides the official SDK, simulator, templates, and publishing route.

The current OpenGlasses direct-BLE backend should not be treated as production-ready. Its own source correctly records that it:

- is a community protocol reconstruction that ships dark;
- omits the observed seven-packet authentication flow;
- does not know the temple-gesture event format;
- uses a placeholder render service identifier; and
- has not been validated on hardware.

There are two legitimate paths:

| Path | Recommendation | Consequence |
|---|---|---|
| Official Even Hub plugin plus authenticated OpenGlasses relay | Production default | Supported G2 SDK and store lifecycle, but the device code lives in Even's companion/plugin host rather than solely inside the OpenGlasses iOS process |
| Native direct BLE backend | Experimental only | Preserves direct one-app ownership, but requires protocol rights, authentication, firmware validation, pacing, input decoding, recovery, and ongoing maintenance |

The first path is recommended. It would use a deliberately small Even plugin as a device adapter and relay semantic HUD frames, microphone chunks, input actions, battery state, and acknowledgements to the OpenGlasses iOS app or its authenticated gateway. It must remain useful and privacy-safe during relay loss and must never expose a general remote-control surface.

The second path should stay behind an experimental flag until it passes a real-hardware validation ledger. Older G1 UUIDs, packet bytes, or LC3 assumptions must not be copied into G2 simply because another project supports “Even”.

Sources: [Even Hub](https://hub.evenrealities.com/), [Even Hub G2 documentation](https://hub.evenrealities.com/docs), [Even Hub quickstart](https://hub.evenrealities.com/docs/get-started/quickstart/index), [Even Realities GitHub organisation](https://github.com/even-realities).

### Omi: the easiest high-value next adapter

Omi is the best next integration because it publishes an MIT-licensed product repository, an official Swift SDK, and a documented direct-BLE protocol. The protocol covers discovery, battery and device information, audio characteristics, PCM/mu-law/Opus formats, packet headers, and iOS fragmentation behavior.

The first supported Omi capability set should be conservative:

- connection and reconnection;
- microphone audio using the officially reported codec;
- battery and device information;
- button events;
- audio/transcription routing into the existing assistant; and
- still capture only when current hardware and firmware discovery proves it, with no display or speaker claimed by default.

This immediately expands the everyday assistant and memory product without waiting for a display. It also forces the shared architecture to model an audio-first device honestly.

Sources: [Omi SDK overview](https://docs.omi.me/doc/developer/sdk/sdk), [Omi BLE protocol](https://docs.omi.me/doc/developer/Protocol), [Omi open-source repository](https://github.com/BasedHardware/omi), [Omi Glass documentation](https://docs.omi.me/onboarding/omi-glass), [Omi Glass hardware source](https://github.com/BasedHardware/omi/blob/main/docs/doc/hardware/omiGlass.mdx).

## What to take from xg.glass

The [xg.glass SDK](https://github.com/hkust-spark/xg-glass-sdk) is the closest public reference for the same problem. Its single `GlassesClient` presents camera, microphone, display, and audio adapters across Android and iOS. Its device-adapter guide distinguishes three important integration shapes: phone BLE, vendor SDK, and on-glasses runtime. Its support matrix is candid about transport feasibility and vendor gating.

OpenGlasses should borrow these ideas:

- capability discovery is dynamic and conservative;
- each adapter owns its transport lifecycle and resets capabilities after link loss;
- codecs and packet assemblers are pure code with golden-vector tests;
- notification subscription completes before a connection is declared ready;
- continuations have one owner, one completion, cancellation, and timeouts;
- malformed packets, gaps, drops, and backpressure are observable;
- hardware validation is tracked per device and firmware rather than inferred from compilation; and
- closed transports are labelled blocked instead of being “supported” through fragile guesses.

OpenGlasses should not adopt the package wholesale yet:

- it is pre-1.0 and several hardware paths remain unvalidated;
- its iOS distribution uses a binary `XgGlassKit`, adding another opaque compatibility boundary;
- its Meta path targets an older DAT release than OpenGlasses' current 0.9.0 integration;
- OpenGlasses already has richer Meta lifecycle, privacy, HUD, feature-gating, and product behavior; and
- abstraction code does not remove the need for vendor permission or a real iOS transport.

For Omi, use the official Swift SDK/protocol as the source of truth and xg.glass as a behavioral and test reference. For Even, use the current G2 Hub documentation as the source of truth and take only transport-independent lifecycle/testing patterns from xg.glass. Any adapted Apache-2.0 source must retain the required notices.

References: [xg.glass iOS device support](https://github.com/hkust-spark/xg-glass-sdk/blob/main/docs/ios-device-support.md), [adding a device adapter](https://github.com/hkust-spark/xg-glass-sdk/blob/main/docs/adding-a-device-adapter.md).

## Recommended architecture

Keep the existing independent camera and display ports, add equivalent microphone/audio and input ports, and put a thin device coordinator above them. Do not replace these with one giant vendor interface: hybrid devices and standard Bluetooth audio are valuable precisely because the modalities can come from different places.

```text
Assistant features / HUD router / camera features / audio loop
                         │
              capability and policy gates
                         │
               GlassesDeviceCoordinator
                identity + live lifecycle
                         │
       ┌──────────┬──────────┬──────────┬──────────┐
       │ camera   │ mic/audio│ display  │ input    │
       │ port     │ ports    │ port     │ port     │
       └──────────┴──────────┴──────────┴──────────┘
                         │
 Meta DAT | Omi BLE | Even Hub relay | generic BT audio
                         │
       future Rokid CXR / Android XR / XREAL adapters
```

### Shared device model

Add a stable identity and live capabilities, not a vendor enum scattered through feature code:

- identity: device ID, vendor, model, firmware, transport and adapter version;
- camera: none/still/stream, dimensions, latency, concurrency and privacy indicator;
- microphone: none/HFP/PCM/Opus/LC3, sample rates and simultaneous-use constraints;
- speaker: none/HFP/A2DP/vendor stream;
- display: none/glance/spatial, dimensions, color/palette, refresh and interaction support;
- input: tap, double tap, long press, swipe, ring, button, voice and selection IDs;
- state: battery, worn/folded, foreground/background availability, thermal and connectivity; and
- restrictions: permissions, session exclusivity, rate limits and relay requirements.

Capabilities must be live values. They become unavailable on disconnect, permission loss, incompatible firmware, or relay loss. A marketing model name must never be the sole capability test.

### Portable events and payloads

The core layer should progressively avoid `UIImage`, Combine subjects, and closure-bearing transport payloads. Device adapters can translate to:

- `AsyncStream` lifecycle/input/frame events;
- encoded image data plus dimensions, orientation, time and source identity;
- timestamped audio frames with explicit codec/sample format;
- semantic HUD frames; and
- stable action identifiers resolved by the phone-side router.

The existing `HUDItem.action` closure is fine inside the iOS process, but a relay-capable screen must cross a process or network boundary as data. Its action ID should be routed back to a locally registered handler rather than serializing behavior.

### Adapter admission rule

A new adapter is accepted only when it has a maintained vendor SDK, an open documented protocol, or a secure supported bridge. “It advertises over BLE” is not sufficient. BLE discovery does not reveal proprietary authentication, framing, codec, permission, safety, or display semantics.

## Conformance and hardware validation

Every adapter should pass the same contract suite before a product-support badge is shown:

1. connect, disconnect, stop, and teardown are idempotent;
2. capabilities are conservative and reset immediately after loss of access;
3. required notification descriptors are active before `ready` is emitted;
4. every continuation resumes once, with cancellation and bounded timeout behavior;
5. malformed packets, sequence gaps, fragmentation, reassembly, queue pressure, and dropped frames are tested;
6. the reported audio codec/sample format matches captured bytes;
7. no iPhone microphone or camera silently substitutes for expected glasses input;
8. permissions, backgrounding, interruption, reconnect, firmware mismatch, and battery loss are exercised;
9. unsupported features return a stable, device-specific reason; and
10. a hardware ledger records device revision, firmware, phone, iOS version, test date, and evidence for every claimed capability.

Pure codecs should use golden byte vectors. Device integration should also have packet captures or vendor sample comparisons where permitted. A mock proves application behavior; it does not prove a transport.

## Everyday features and commercial opportunities

The cross-vendor strategy creates opportunities larger than adding another settings picker:

### 1. A hardware-independent personal agent

Memory, preferences, tasks, and trusted contacts survive the glasses. Users can choose fashionable audio glasses for most of the day, Meta for visual assistance, or Even for silent glanceable prompts without rebuilding the assistant relationship.

### 2. Useful tiers instead of lowest-common-denominator design

- **Audio tier:** conversation, memory capture, reminders, translation, task creation, calls and notification digest.
- **Vision tier:** reading, scene questions, object/text capture, guided help and remote expert assistance.
- **Glance tier:** captions, navigation cues, task cards, discreet notifications and teleprompter content.
- **Interactive tier:** confirm/cancel, choose from short menus, acknowledge safety prompts and control the agent without a phone.

The same feature may combine tiers from different devices. OpenGlasses should select a source per modality and show that selection to the user.

### 3. Accessibility as a primary market

Cross-vendor audio, vision, captions, translation, navigation and discreet HUD prompts can serve blind, low-vision, Deaf/hard-of-hearing, cognitive-support and field-assistance users without tying them to one frame manufacturer. Honest degradation and predictable controls matter more here than maximum feature count.

### 4. An open adapter and bridge protocol

A small, documented OpenGlasses device protocol could let hardware makers or open-source communities provide adapters without exposing the assistant internals. It should carry typed capability descriptions, media frames, semantic display frames, input events, acknowledgements, backpressure, version negotiation and an explicit trust handshake.

This is a partnership surface, not an invitation to accept arbitrary untrusted device servers. Adapters need signing/trust, least privilege, rate limits, origin identity, privacy indicators, revocation and an auditable permission screen.

### 5. OEM and enterprise partnerships

Rokid, Even, Omi and emerging frame makers need differentiated everyday software. OpenGlasses can offer a reusable assistant and accessibility layer while allowing each manufacturer to retain pairing, firmware and hardware control. Enterprise field-assistance deployments are also more willing to adopt software when device replacement does not strand workflows and records.

### 6. Privacy as differentiation

The phone can perform capability gating, redaction, storage policy and some local inference before data reaches a cloud model. The UI should always identify which camera/microphone is active, whether an official companion or relay is involved, and where processing occurs. A device without an accessible camera should never lead the app to imply that it can see.

## Delivery roadmap

Assuming one experienced iOS/backend engineer and access to representative hardware:

| Phase | Deliverable | Indicative effort | Main dependency |
|---|---|---:|---|
| P0 | Device identity, dynamic cross-modal capabilities, audio/input ports and adapter conformance kit | 1–2 weeks | Repository-only |
| P1 | Omi BLE adapter: microphone, battery, button and honest capability UI | 1–3 weeks | Current Omi hardware/firmware |
| P2 | Even Hub plugin and authenticated semantic relay; reclassify direct BLE as experimental | 2–4 weeks | Even Hub publishing and relay decision |
| P3 | Rokid CXR iOS technical spike | 2–5 weeks after access | Current Rokid partner SDK and terms |
| P4 | Generic Bluetooth audio adapter/profile UX | 1–2 weeks | iOS audio-route behavior on devices |
| P5 | XREAL external-display prototype | 1–2 weeks | Target XREAL/iPhone hardware |
| Monitor | Android XR native iOS adapter | Not estimable | Google/OEM public iOS device-access API |

These are discovery ranges, not release estimates. Hardware certification, App Store review, vendor approval, accessibility testing, privacy review, and field stabilization are additional.

## Immediate repository decisions

1. Extend [Plan CQ](plans/CQ-third-party-glasses-backends.md) rather than create an “any BLE glasses” abstraction. Its capability-first, two-real-adapter-before-generalising principle remains sound.
2. Treat the current [Even backend plan](plans/even-display-backend.md) as an experimental direct-transport investigation and create a production Even Hub/relay plan if Even is prioritised.
3. Do not execute [the Android port plan](plans/BA-android-port.md) to satisfy this iOS cross-vendor goal. It answers a separate product question and its Android XR/Meta capability assumptions need a fresh review before reuse.
4. Implement Omi as the second fully validated physical device adapter. It is the fastest way to exercise an audio-first capability set with an official open protocol.
5. Open vendor conversations with Rokid now; access lead time, not Swift code, is the primary risk.

## Final recommendation

Build “OpenGlasses works with the capabilities your glasses safely expose,” not “OpenGlasses supports every device.” The former is achievable, testable, and useful today from one iOS app. The latter is impossible without vendor cooperation and will produce brittle integrations and disappointed users.

The practical first release beyond Meta is Omi for audio and device events, followed by Even G2 through its official Hub. Rokid is the best partnership target for a fuller camera/audio/display experience. Android XR and XREAL should remain watched, well-defined adapter slots until their current public iOS access is sufficient.
