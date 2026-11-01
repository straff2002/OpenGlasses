# Avenkin 2026.10 submission preparation

Prepared on 25 October 2026. App Store Connect app ID: 6760953562.

## Saved in App Store Connect

- Version 2026.10, subtitle, promotional text, description, keywords and review notes from `metadata.json`.
- Utilities primary category; Productivity secondary category.
- Support and privacy URLs use the current `avenkin.com` pages. Optional marketing URL is blank because the existing about page still promotes glasses and says there is no subscription.
- Content Rights declaration updated following the owner's confirmation. Imported manuals are user-provided; no manufacturer workshop PDFs are included.
- Mainland China excluded from distribution. France was already excluded and remains so; 173 territories are selected.
- Manual release retained. No build selected and nothing submitted for review.
- `avenkin-review-kit.zip` attached to App Review, containing two original fictional Markdown manuals and instructions.
- My Manuals monthly subscription review notes updated. Personal and Field Assist remain separate subscriptions.

## Uploaded screenshots

All uploads were verified by filename and count in App Store Connect. RGB PNGs have no alpha channel; UI pixels were not redesigned, stretched or composited.

| Device set | Uploaded assets | Dimensions |
| --- | --- | --- |
| iPhone medium Dynamic Island | Home, Apple app integrations, AI provider selection | 1206 × 2622 |
| iPad 13-inch | Workspace, Apple app integrations | 2752 × 2064 |
| Apple Watch Series 12 46mm | Connected companion controls | 416 × 496 |
| iPhone Duo | Closed cover display, fully open workspace | 1398 × 2034; 2853 × 2007 |

The upload sources are `screenshots/*-rgb.png`. Captures use a Debug simulator with the shipping App Store glasses policy explicitly selected; this does not grant subscriptions or fabricate provider responses. Apple Intelligence is shown as the configured model, without claiming a successful AI request on the simulator.

## Product page header

`header/avenkin-header-3840x1646.png` uses the existing Open Span brand mark, orange/ivory/charcoal colours and the listing's “Talk. Ask. Get things done.” message. The waveform and task/calendar/document artwork are original vectors; the header does not depict glasses or fabricate an app response. `header-art.svg` and `build-header.sh` retain editable artwork and a reproducible export.

The export is an opaque 8-bit RGB PNG at 3840 × 1646, one of Apple's accepted header sizes. It is uploaded as the selected product page header. Apple's loaded iPhone product-page preview was visually checked, including the top-control safe area; `header/app-store-header-preview.jpg` records the result. References: [creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications) and [asset best practices](https://developer.apple.com/app-store/asset-best-practices/).

## Search results creative

`search-results/avenkin-search-3840x2560.png` reflows the same brand artwork into a 3:2 search card. The headline is centred above the voice/action illustration for legibility at result-card sizes. It is an opaque 8-bit RGB PNG, with editable `search-art.svg` and a reproducible `build-search.sh` export. It is uploaded as the selected Search Results asset; Apple's loaded iPhone search preview was visually checked and saved as `search-results/app-store-search-preview.jpg`. This is a separate creative asset from the product-page header.

## Remaining before submission

1. Use the separate phone-only workflow (`OPENGLASSES_PHONE_ONLY=1`), assign a unique build number, and verify the signed archive with `Scripts/check-phone-only-artifact.py --require-signed`. Select that exact build for App Review. The glasses beta is a different archive/build number; installation receipts never enable hardware. Follow [the build procedure](../../docs/app-store-phone-only-build.md) and [remaining submission checklist](submission-checklist.md).
2. Retest the live My Manuals StoreKit catalogue after Apple's agreement/account changes propagate. Verify the displayed monthly price, eligible one-week trial, purchase, restore and separate service access. Capture the actual functioning paywall for the subscription's required review screenshot. Local StoreKit tests do not establish live catalogue availability.
3. Review and publish the saved App Privacy draft. It conservatively includes Health, Fitness, precise/coarse location, Contacts, photos/videos, audio, other user content and search history, used for App Functionality, linked to identity and not for tracking. The draft reflects optional third-party processing and has not been published or independently audited against every provider's retention practices. Reference: https://developer.apple.com/app-store/app-privacy-details/
4. Complete the final age-rating questionnaire audit and encryption questions for the selected build. Existing age rating was retained; no unverified accessibility claims were added.

## Duo simulator recovery — 26 October

After a computer restart, the iOS 27.2 Duo runtime image remained installed but its profile was not registered. `xcrun simctl runtime scan-and-mount` restored availability without downloading or deleting a runtime. The existing Duo then booted and its normal Open control successfully changed to the inner display. Exporting native display 3 produced a verified 2853 × 2007 image of the expanded workspace. Both open and closed images are uploaded; no iPhone or iPad capture was resized into a Duo asset. This verifies simulator layouts, not physical folding hardware.

Earlier direct screen-power switching produced SpringBoard display-configuration assertions and was reverted. Do not use independent display-power changes as a folding substitute; use Device Hub's posture controls after the runtime is properly mounted.

## Source polish and validation

The App Store settings hub now hides Display & HUD and removes glasses wording from its device subtitle and About footer when the existing glasses policy is disabled. Debug simulator launch support can select this policy and an initial tab for repeatable captures; Release and physical-device channel detection are unchanged.

The final iOS simulator build succeeded (`/private/tmp/avenkin-store-settings-build.log`). The additional settings presentation changes were compile-checked; live purchase acceptance remains outstanding. Unrelated working-tree changes and private Toyota PDFs were not included in this preparation.
