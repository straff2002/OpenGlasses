# Phone-only App Store builds

The App Store submission and the glasses TestFlight beta use separate, uniquely numbered builds of the same app record. A receipt is not a feature switch: App Review can use sandbox receipts too. There is no remote setting, licence, shortcut or receipt that adds glasses support to the phone-only binary.

## Generate and archive

Set `OPENGLASSES_PHONE_ONLY=1` in the App Store Xcode Cloud workflow **before** `ci_post_clone.sh` runs. Leave it unset (or `0`) for the glasses beta workflow. Give each upload a unique build number, including when the source version is identical. Keep the phone-only setting in the workflow rather than editing the shared checkout's generated project while another build uses it.

For a local phone-only build:

```sh
OPENGLASSES_PHONE_ONLY=1 ./Scripts/generate-xcodeproj.sh
```

`project.glasses-sdk.yml` is omitted entirely. The final phone overlay sets `AVENKIN_PHONE_ONLY`, derives `.generated/Info.phone-only.plist` from the common metadata, and selects the generated entitlements without Meta Wi-Fi capabilities. It also overrides personal signing overlays. Phone microphone, camera, system headset audio and local/network privacy permissions remain. Meta callbacks, companion query schemes, accessory protocols and Bluetooth background modes are removed. The silent media-button standby implementation and hardware-only Siri intents do not compile into this variant. Saved beta hardware settings cannot re-enable it.

For the beta, regenerate with `OPENGLASSES_PHONE_ONLY=0`. The default remains the glasses beta for contributors. `OPENGLASSES_NO_GLASSES_SDK=1` is a compatibility alias. Do not set both variables to different values.

## Verify the exact archive

After an archive completes and before upload:

```sh
python3 Scripts/check-phone-only-artifact.py --require-signed /absolute/path/Avenkin.xcarchive
```

The check fails on a missing variant marker, Meta metadata, embedded SDK files, linked SDK framework names or Swift module symbols, or glasses Wi-Fi entitlements. It inspects all Mach-O binaries, including extensions, and also fails on Meta product or company text in any of them or in a compiled `.strings` table, naming the file and the term; `prepare-phone-only-build.py` keeps that text out of the catalogs by compiling filtered copies from `.generated/`. It never strips or edits the artifact. An unsigned simulator check is useful during development but does not verify signed entitlements or distribution behavior. Xcode Cloud's post-build hook runs the signed check for phone-only archives.

Use a fresh archive. When switching variants, an old local build product can retain a beta test plug-in; do not treat a contaminated product as release evidence or remove individual SDK files to make a check pass.

## Select the build and disclose it

In App Store Connect, select the **phone-only build number** for App Review. Keep the separately numbered glasses beta available to the intended TestFlight group. Assign exact builds to groups and prevent automatic distribution of a phone-only candidate to the glasses group. TestFlight notes must identify which variant a tester is installing. Update review notes from `reports/app-store-2026.10/metadata.json`; the old claim that one binary changes based on installation channel is obsolete.

Before submission, verify the complete signed archive (including watch and extensions), clean-install on a device, test optional-permission denial, review the AI sharing prompt and withdrawal, and complete the sandbox subscription and reviewer-access checklist in `reports/app-store-2026.10/submission-checklist.md`. Source and simulator checks alone cannot establish those facts.

References: [Apple build selection](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/), [sandbox receipts during App Review](https://developer.apple.com/library/archive/technotes/tn2413/_index.html), and [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
