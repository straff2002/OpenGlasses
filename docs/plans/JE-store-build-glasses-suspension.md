# Plan JE — The Store Copy Suspends the Glasses

**Superseded 2026-11-01:** the separate compile-time phone-only variant in [Plan IK](IK-store-build-without-glasses-sdk.md) replaces this receipt-based rule. App Review also uses sandbox receipts, so the runtime distinction was not reliable. [Build and submission procedure](../app-store-phone-only-build.md). The historical decision below is retained as history; do not use its same-upload instructions for a new submission.

## Problem

Avenkin is ready for the App Store except for one thing it cannot fix on its own: Meta registers a
distributed app with a wearer's glasses only when that wearer is in the app's release channel, and
Meta's production channel is not open. A store user who tapped Connect would be sent to Meta AI,
refused with "Internal error", and land back on a Connect row that cannot work. That is a review
rejection and a one-star review, and it blocks the phone-only product that works today.

One upload serves both channels: the App Store build *is* the TestFlight build, promoted. So the
answer cannot be a build setting. It has to be the running copy deciding, from how it was
installed, whether it offers glasses at all.

## Decision (owner, 2026-10-18)

Suspend the glasses on the App Store copy and release. TestFlight testers keep the glasses on the
same upload. The Meta frameworks stay linked everywhere; the store copy just never configures the
SDK and shows none of the glasses surfaces. No remote switch: what App Review sees is what store
users get, and offering glasses on the store later is a one-line change shipped as an update.

## What was built

**The rule** — `GlassesSupportPolicy` (pure): `verdict(channel:)` is `.notInThisVersion` for
`AppBuildIdentity.Channel.appStore` and `.supported` for TestFlight, a development build and the
simulator. `current` reads the install channel once (the receipt's name, already read for the
support report). `unavailableReason(appName:)` is the one sentence any glasses path says.

**The choke point** — `WearablesBootstrap.ensureConfigured()` returns false before `configure()`
on a copy without glasses, with that sentence as `failureReason`. Every `Wearables.shared` access
already goes through it (about twenty sites), so on the store copy there is no Bluetooth prompt,
no attestation call to Meta, and every glasses path degrades to the "SDK unavailable" state it
already had. The Meta AI callback URL is dropped the same way. `AppState.glassesAdded` is false on
that copy, which is what the session card's pill and headline and the widget's phase read; the SDK
observers and the automatic connect are not started.

**Hidden surfaces** — the onboarding device step's "Smart glasses" section and the permissions
page's Bluetooth row; Devices & Privacy › Glasses; the session card's glasses pill (via
`glassesAdded`); the Home Screen widget's glasses line and card, which draws from a
`WidgetGlassesSupport` flag the app writes to the App Group when its services start (absent reads
as not offered, so a store widget never shows a line before the app has run). The Siri intents'
static metadata is worded for both copies; their spoken results name glasses only where there are
any. The support report carries a `Glasses:` line.

**A latent crash fixed on the way** — the onboarding device step read `Wearables.shared` behind
the page's own "configured" flag, which is set after a `configure()` that may have failed; an
unconfigured `Wearables.shared` is a fatalError. It now reads behind `WearablesBootstrap.isConfigured`.

**Tests** — `GlassesSupportPolicyTests` (the channel table, the copy, the override),
`WearablesBootstrapTests.testAStoreCopyNeverConfiguresTheSDK` (the one safe `ensureConfigured()`
call in that file), `OnboardingFlowTests` (the rows never open on a copy without glasses),
`WidgetGlassesPresentationTests` (the flag's default and round trip), `StorageIdentifierGuardTests`
(the new App Group key), and `GlassesSurfaceGateTests`, a source scrape pinning that each surface
above still consults the policy.

## Deliberately kept

- **Bluetooth audio.** Ray-Ban Meta glasses are also an ordinary Bluetooth headset; the store copy
  still hears and speaks through them like any earbuds, and the Glasses Mic route stays. Nothing
  there touches the Meta SDK.
- **Phone camera, Photo quick action, Watch photo/video rows.** All fall back to the phone's camera
  without glasses already.
- **The `NSBluetooth*UsageDescription` strings and the `MWDAT` Info.plist keys.** The linked
  frameworks reference CoreBluetooth, so the strings must stay; they are truthful.

## App Store review notes (paste into App Review Information › Notes)

> Smart-glasses support (Meta Ray-Ban via Meta's Wearables Device Access Toolkit) is in beta on
> TestFlight and is disabled in this App Store release: the Meta SDK is never initialised and no
> glasses UI is shown. The app is a complete phone-only assistant. The Bluetooth usage strings
> are present because the linked Meta frameworks reference CoreBluetooth; they are not exercised.

The App Store listing, screenshots and the website's store copy must not show glasses features;
TestFlight's description and What to Test may.

## Owed

- A store-channel pass once the first build is live: the onboarding device step shows only "This
  iPhone"; no Bluetooth prompt at any point; Devices & Privacy has no Glasses row; the widget shows
  the Listen toggle alone; the support report says "Glasses: not in this version (store copy)".
- Turning the store copy on: one line in `GlassesSupportPolicy.verdict(channel:)`, when Meta's
  production channel opens, shipped as an update with the review notes rewritten.
