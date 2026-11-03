# Submission evidence still required

Source changes reduce identified risks; they do not guarantee App Review approval. Complete this checklist against the **exact phone-only archive and build number** selected for review. Do not submit the historical same-binary review notes.

## Build and first launch

- [ ] Complete export-compliance and territorial availability answers for the exact archive and its cryptography; an existing plist flag is not a substitute for that assessment.
- [ ] Configure the App Store workflow with `OPENGLASSES_PHONE_ONLY=1`, assign a unique build number and record its commit/archive path.
- [ ] Run the signed [artifact check](../../docs/app-store-phone-only-build.md), including watch and extensions. Confirm no SDK, Meta callback/accessory declarations or glasses Wi-Fi entitlements.
- [ ] Clean-install on a supported iPhone and iPad; decline microphone, camera and other optional permissions and finish onboarding. Check saved settings migrated from a beta cannot expose glasses controls.
- [ ] Confirm hardware-only Siri actions and silent media-button standby are absent, while phone audio, camera, supported headset routes and stop controls work.

## Sharing permissions and privacy answers

- [ ] Save a test provider key and confirm the permission question appears with the destination, purpose and data disclosure, including over an open sheet. Choose Not now: the key stays saved, a request sends nothing and is not silently rerouted, and relaunching does not ask again.
- [ ] Approve that destination, make a request, change provider and verify a separate prompt. Test explicit cloud voice, dictation, search and live microphone/camera independently.
- [ ] Withdraw permission in Settings > Devices & Privacy > Cloud AI Sharing during a stream. Confirm it stops and does not reconnect; approved local processing remains usable. Background first use must refuse rather than wait for hidden UI, say that permission is needed, and ask when the app is next opened.
- [ ] Review each enabled recipient's current retention, training and third-party sharing terms. A user-configured endpoint or approved credential is not proof that a service has acceptable terms or authorisation.
- [ ] Reconcile and publish the App Store Connect privacy answers. The manifest declares authenticated provider content as linked, app functionality, no tracking; it includes precise and reduced-precision location. This is not evidence that the live App Store Connect answers have been updated.
- [ ] Publish the revised privacy policy when these behaviors are in the release; the branch's policy draft must not describe unshipped behavior as already live.

## Purchases and complete reviewer access

| Service | New purchase products | Walkthrough |
|---|---|---|
| My Manuals Personal | `com.openglasses.my_manuals_monthly` | Settings > My Manuals; import the original fictional review-kit manuals, preview, subscribe, save/index, ask a cited question, open source, delete. |
| Field Assist Solo | `com.openglasses.field_assist_monthly` | Settings > Field Assist; inspect visible vault previews, subscribe, enable field workflow, run a fictional job/procedure and export its report. |
| Medical Compliance | `com.openglasses.medical_compliance_monthly`, `com.openglasses.medical_compliance_annual` | Settings > Devices & Privacy > Medical Compliance; subscribe, configure clinical privacy/retention, create fictional data, export, lock/reopen and delete. |

- [ ] Verify live product availability, localized prices/periods, eligibility and trial disclosures on device in Apple's sandbox. A local `.storekit` file cannot prove catalogue availability.
- [ ] Exercise purchase success, user cancellation, pending purchase, restore, renewal/expiration/revocation and failure without inappropriate access. Verify links to Privacy and the Apple standard EULA on every paywall.
- [ ] Confirm Personal, Solo and Medical grant only their stated capabilities, and grandfathered receipts restore without selling retired products.
- [ ] Establish the actual organisation sales/distribution model for 3.1.3(c). Document what the existing licence unlocks, who receives it and why the path qualifies; source comments cannot establish the commercial facts.
- [ ] Supply a real, valid reviewer organisation setup through App Store Connect's private review information if that route remains available. Include activation steps, sample configuration and any necessary reachable server/test hardware. Do not add a hidden premium bypass or embed private production credentials in the kit.

## Safety and remote features

- [ ] Supply intended use, source protocols/methodology and verification for first-aid coaching, advisory camera triage, medication tools and the clinical persona. Validate emergency wording and complete age-rating/medical-status answers for the actual capabilities. Copy edits do not replace this evidence.
- [ ] Validate local-only routing, file protection while locked, retention/deletion and generated export formats on device. Confirm the receiving clinical system's import requirements; exported formats are not a claim of a direct Epic/Cerner integration or legal certification.
- [ ] Provide a reviewer-accessible test gateway/MCP setup if needed, with visible permissions/confirmation and representative packs. Explain pack contents and prove they do not introduce unreviewed executable app functionality.
- [ ] Validate microphone/background recording indications, start/stop and power behavior. Document why each retained background mode serves the active feature.
- [ ] Confirm authorisation for third-party APIs, OAuth flows, model weights and distributed content; retain evidence for Apple's 5.2.2 requests.

Apple references: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [App privacy details](https://developer.apple.com/app-store/app-privacy-details/), [complete reviewer access](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/provide-app-review-information/).
