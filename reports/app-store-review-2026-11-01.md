# Avenkin / OpenGlasses App Store readiness review

Reviewed 1 November 2026 against source at `3b886bbe6`; the audit and app fixes now live in the isolated `codex/app-store-guidelines-audit` worktree based on `a18dba43b`. Other ongoing app changes were excluded from this branch. This is a source and submission-material review, with focused simulator validation recorded below. It is not an approval guarantee or an inspection of the build currently selected in App Store Connect. No app submission or App Store Connect changes were made.

**Recommendation: hold submission until the exact signed phone-only archive, live privacy answers, purchases and complete reviewer access are verified.** The initial distribution and AI-consent source findings have been remediated on this branch; the release evidence below is still required. The Reddit post is anecdotal; neither review-volume figures nor its author's outcome establish the likely outcome for this app.

## Policy reference

Apple's [current guidelines](https://developer.apple.com/app-store/review/guidelines/) identify hidden/dormant functionality under **2.5.19**, feature disclosure under **2.3.1**, and developer conduct under **5.6**. **4.3** concerns spam; **4.2** concerns minimum functionality. Relevant additional areas are completeness (**2.1**), payments (**3.1**), privacy (**5.1**), safety (**1.4**), background execution (**2.5.4**) and third-party rights (**5.2**).

The priorities and implementation recommendations below are this audit's assessment, not statements that Apple has rejected or approved these mechanisms.

## Remediation on the audit branch

- A compile-time phone-only build omits the Meta package products, SDK implementations, hardware Siri surfaces and silent media-button standby. Receipt classification is diagnostic only. The separate glasses-beta build retains hardware functionality. [Build procedure](../docs/app-store-phone-only-build.md).
- Recipient-and-purpose sharing approval now gates HTTP/SSE, live voice/camera, cloud transcription, cloud speech, web search, custom agents, MCP and gateway sockets. Permission is versioned and withdrawable. Requests without an available foreground prompt refuse; saving credentials does not approve sending content. Refusal stops model/search fallback, and a refused cloud voice falls back to the system voice.
- The privacy manifest now declares authenticated provider data as linked and includes reduced-precision location. Tracking remains false. This corrects source declarations; live App Store Connect answers and recipient terms still require verification.
- Review notes cover the separate binary, sharing permissions, Field Assist, organisation activation, Medical and non-obvious remote/background features. The Medical paywall now describes controls and export formats without claims of certification, secure erasure or direct integration with named clinical systems.
- The privacy-policy change is a branch draft for the release. It has not been published. About/Support corrections from the earlier audit were already published separately.

The remaining operational and owner evidence is listed in the [submission checklist](app-store-2026.10/submission-checklist.md). No live StoreKit purchase, organisation credential, clinical verification, third-party authorisation or signed distribution archive has been fabricated or treated as verified.

## Initial findings (before remediation)

The following evidence describes the initial audit baseline, not the current implementation. Read it alongside the remediation status above.

### 1. High — receipt-based glasses suspension cannot establish the review experience

Evidence: `OpenGlasses/Sources/Utils/AppBuildIdentity.swift:34` treats any embedded provisioning profile as development and otherwise treats the filename `sandboxReceipt` as TestFlight. `OpenGlasses/Sources/Services/GlassesSupportPolicy.swift:24` permits glasses for every channel except `.appStore`. `WearablesBootstrap.ensureConfigured()` relies on that verdict before configuring the SDK.

Apple [documents that App Review uses sandbox receipts](https://developer.apple.com/library/archive/technotes/tn2413/_index.html). That does not prove the exact receipt filename or packaging on a particular review device. It does invalidate the assumption that a sandbox receipt is sufficient proof of a TestFlight installation. A review environment classified as TestFlight or development would offer glasses; a missing receipt instead selects the phone-only path. `installed` is also cached for the process. The current tests assert the channel table; they do not prove Apple's review environment follows the assumed packaging.

The saved review notes promise a phone-only App Store installation, while the SDK, registration code, callbacks, accessory protocol and accessory background modes remain in the same binary. Disclosure is helpful and is already present. It does not by itself establish acceptance of this dormant functionality, nor Meta authorization for public distribution.

There are also ungated static Shortcuts surfaces: `App/Intents/CaptureIntents.swift` advertises "Capture Glasses Photo" and "Record Glasses Video", and both reject a phone-only user with "Connect your glasses first." `DisconnectGlassesIntent` is discoverable even when its operation returns unsupported. Hiding the Settings category does not remove these metadata surfaces. The phone-only archive must exclude or replace them with real phone actions; the current statement that no glasses controls are shown is too broad.

**Recommended change:** return to the compile-time separation outlined in Plan IK, updated for today's source. Produce separately numbered archives for the same app record: a phone-only candidate and a glasses beta. Select the phone-only candidate for review. Apple provides a [build-selection workflow](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/); promoting the particular glasses TestFlight binary is not mandatory.

The phone-only archive should exclude Meta products and glasses-only implementations/UI, Meta plist keys and URL scheme, `com.meta.ar.wearable`, accessory background modes and glasses-only entitlements. Decide Bluetooth declarations from the code actually retained; ordinary headset audio does not justify a Meta pairing implementation. Keep the phone camera, headset audio, watch and supported phone workflows. Verify the final linked artifact, including static SDK symbols, not only its Frameworks directory. Preserve TestFlight support through a different archive. A different bundle ID is not inherently required for this approach.

No receipt replacement, reviewer-device detection, secret unlock, region trick or remotely activated post-review feature should be added. The follow-up implementation now provides that separate build; workflow configuration and signed-archive verification remain outstanding.

### 2. High — explicit permission for third-party AI processing is not established

Evidence: `ModelEditorView` saves a provider/model with a normal Save action; `AddModelView` adds one similarly. `LLMService.sendMessage`, stateless completion and frame-analysis entry points resolve a model and can send content without a general recipient-scoped sharing-consent check in the inspected paths. The existing consent ledger is wired to remote/high-impact actions. `ProcessingSummaryView` describes destinations, and `AIDisclosureLedger` announces that the assistant is AI; neither is an explicit approval step for third-party data sharing.

`TextToSpeechService` also selects cloud voice engines from available credentials. Adding a model credential can therefore make speech synthesis available as well as inference. Health sharing and job recording have separate consent mechanisms; these are useful but do not cover every cloud conversation, image or voice route.

Before shipping, add and test a clear approval flow naming the actual provider/host and the data it receives. Cover chat/history/tool results, photo/manual passages, realtime audio, cloud dictation, cloud speech, automatic fallback and model roles. A change of destination or use needs appropriate renewed approval. Decline must leave supported local/text paths usable; withdrawal must stop subsequent sends. Test the network boundary, including Siri, Watch, background and retry paths, rather than only the presence of an alert. See **5.1.2(i)** in the [guidelines](https://developer.apple.com/app-store/review/guidelines/#privacy).

The absence of an Avenkin account and the user's possession of an API key do not, on their own, demonstrate this approval.

### 3. High — privacy manifest and saved App Privacy draft disagree

Evidence: every `NSPrivacyCollectedDataTypeLinked` in `OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy` is false. Its comment derives that from having no first-party account. `PrivacyManifestReconciliationTests.testTheNoTrackingClaimIsIntact` pins that assumption. The submission README says the saved App Privacy draft marks data linked to identity and includes coarse location, which the app manifest does not separately declare.

Apple's [privacy definitions](https://developer.apple.com/app-store/app-privacy-details/) include linkage by third-party partners and distinguish linkage from tracking. Requests here can use identifiable provider accounts/API credentials and can contain contacts, health information, voice or document content. Lack of an Avenkin account is insufficient evidence that retained data is unlinked.

Reconcile the manifest, tests, public policy and live App Privacy answers against each route's actual retention and identity handling. In particular, establish which recipients retain data beyond request servicing; that affects Apple's collection definition. Record justified exceptions instead of inferring all routes from one account flag. Do not claim tracking simply because data is linked. This audit leaves the collection/linkage declarations unchanged pending that route-level reconciliation. Separately, the required-reason API declarations were corrected as recorded below.

### 4. High — reviewer access and live purchases are incomplete in the preparation record

Evidence: `reports/app-store-2026.10/README.md` still records live catalogue/purchase testing, the subscription review screenshot, App Privacy publication, age rating and encryption answers as outstanding. The review kit exercises Personal manuals. `metadata.json` only briefly names Field Assist and Medical Compliance; it supplies no complete professional-service walkthrough or enterprise review setup.

Provide reproducible instructions and access for every submitted product and substantial workflow, including any reviewer-compatible enterprise licence/profile needed to inspect organisation-only features. Test live catalogue loading, correct price/duration, eligibility and trial conversion, purchase, cancellation, restore, relaunch, expiry and the independence of all three subscriptions. A local `.storekit` configuration does not prove the live products work. Apple Intelligence requires supported hardware; a reviewer should not need to purchase their own third-party AI service to inspect core advertised workflows. Supply a supported local route and a practical alternative when hardware/model support is absent.

Verify the actual App Store Connect state; the saved README is a dated preparation record, not live evidence.

### 5. Medium/high — organisation activation needs an explicit commercial explanation

Evidence: `LicenseService` verifies offline signed codes; `LiveFieldAssistEntitlementProvider` accepts them as organisation entitlements. Field Assist presents both an organisation activation field and a StoreKit solo plan. This is an intentional, visible access path, not an identified developer backdoor. The former `fieldAssistDeveloperUnlocked` preference is removed at launch and is not entitlement evidence; internal developer grants are fenced by `#if DEBUG`. Medical access requires a verified subscription.

Document that organisation codes are issued only for qualifying organisational sales, who receives them, what they unlock, and how a reviewer can inspect the result. Confirm sales practice matches that representation. A signature proves issuance, not eligibility for the enterprise-services payment exception. Individual/consumer purchases should continue through StoreKit. The current review notes do not adequately explain this route. Relevant sections: **3.1.1 / 3.1.3(c)**.

### 6. Medium/high — safety-sensitive features need their own submission evidence

Evidence: the consumer app includes enabled-by-default first-aid coaching and camera triage, a Clinical Assistant persona, medication-related tools and a Medical Compliance subscription. `FirstAidTool` uses structured emergency protocols and reminds users to call emergency services. Triage has advisory copy and is restricted from Field Assist editions. These mitigations help, but a review of clinical correctness and emergency behaviour was not performed here.

Give reviewers the precise entry points, sources/methodology, intended use and limitations. Verify emergency wording, local-only routing and deletion claims on the selected build. Substantiate marketing such as "HIPAA-grade" and "secure deletion" against the actual implementation and operating arrangements. Complete the medical-device/status and age-rating answers for the actual feature set. Do not assume omitting these features from the main description removes them from review scope. Relevant sections: **1.4.1 / 2.3 / 5.1.3**.

### 7. Medium — remote tools, packs and background behaviour need review coverage

Evidence: signed skill packs bind to prompts, existing native tools, procedures or remote gateway tasks; the inspected manifest does not implement arbitrary downloaded native code. The app nevertheless exposes MCP/gateway/agent integrations, remote action approval and local model downloads, while the current notes mostly describe Apple-app integrations and manuals.

List these capabilities, their configuration and their limits in review notes. Demonstrate what is data/configuration, what runs locally, and what runs on a user-controlled host. Inspect the final archive for Debug-only listeners using the existing release-listener check. Verify no remote pack/profile enables a glasses implementation in a phone-only archive. Relevant sections: **2.3.1 / 2.5.2 / 2.5.19**.

The temple-tap implementation uses a looping silent player to claim Now Playing (`MediaTriggerService.swift`, `SilentNowPlayingClaimer`). In the current source its policy depends on glasses presence, so the intended phone-only path should not claim it. Exclude this glasses-only mechanism from the phone-only archive and verify no silent keepalive is used there. Review actual wake-word audio, lock-screen recording indications, stop controls and background power behaviour under **2.5.4 / 2.5.14**.

### 8. Medium — third-party authorizations and public copy still need verification

Evidence: the app has provider subscription OAuth/sign-in routes as well as API-key routes. Imported manuals are user supplied and the review kit uses original fictional content. These are preferable to shipping unlicensed manufacturer PDFs, but provider sign-in permissions and model/content licences were not established in this audit.

Retain evidence that every service's intended access route is permitted, including subscription-backed OAuth use outside that provider's own client. Check downloadable model licences and imported/published pack rights. Relevant section: **5.2.2**. This is a verification item, not a finding that a particular service has prohibited the app.

The live [support page](https://avenkin.com/support.html) was checked during this review: it says conversations are never included in reports, despite `App/SupportReporting.swift` deliberately supporting conversation/day/job scopes. Its browser-streaming answer also starts with an affirmative answer about sending video to the developer before describing a user-configured relay. The live [about page](https://avenkin.com/about.html) still promises a purchase without subscriptions and presents Meta camera support without a channel distinction. The [privacy page](https://avenkin.com/privacy.html) is reachable and describes cloud destinations and support-report contents. Those pages are not interchangeable evidence of current app behaviour.

The owner subsequently authorized publication. The two corrected pages were committed alone as `a18dba43b` and published through the existing [GitHub Pages deployment](https://github.com/straff2002/OpenGlasses/actions/runs/41269172368). The deployment succeeded; fresh HTTP requests to both live pages returned 200 and contained the approved corrections. App fixes and this report were not part of that publication. Check screenshots, app/watch names and keywords against the selected archive.

## Fixes made during this review

| Issue | Change | Remaining verification |
| --- | --- | --- |
| Shared App Group defaults declared only the app-only UserDefaults reason | Add `1C8F.1` to the app and all three widget/watch manifests; retain `CA92.1` for app-only defaults | Parsed all four manifests and added a regression check |
| Microphone denial blocked onboarding despite typed conversations | Continue and Skip are usable without microphone access | Fresh-install denial walkthrough on a physical device |
| Cough/clap and volume controls were shown with no live detectors | Settings offers only the implemented shake detector; persisted enum values remain decodable | Confirm Settings copy/layout on device |
| EVEN BLE display could bypass the Meta bootstrap after a TestFlight-to-store upgrade | Display capability now consults the common glasses policy before resolving a backend | Regression test covers a saved EVEN pairing; real hardware not exercised |
| Store diagnostics showed glasses/HUD/Meta telemetry probes that could not work | Filter those probes under the existing store policy and use phone-appropriate Developer text | Simulator/device presentation check |
| Purchase entry points omitted directly accessible privacy/EULA links | Add links to Personal, Field Assist and Medical paywalls; Personal purchase controls also show renewal/offer wording | Actual functioning paywalls and StoreKit sheets on device |
| Live website copy contradicted subscriptions, report contents and the store glasses policy | Correct local About/Support copy, remove the unsupported business-card-to-contact claim | Published and verified on both live URLs |

The App Group correction follows Apple's [UserDefaults reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype): `CA92.1` covers app-only defaults; `1C8F.1` covers defaults shared within an App Group.

The first audit commit did not resolve the distribution architecture or general AI-sharing consent; the follow-up remediation above addresses the source implementation. The existing user edits were preserved.

## 4.3 and 5.6 assessment

This is one substantial native app with phone camera/audio, Apple framework integrations, local inference, manual citations, jobs, Watch and CarPlay. The inspected source does not suggest a collection of reskinned duplicate apps. There is no basis here to predict a 4.3 rejection solely because the app uses AI. Demonstrate its concrete native workflows and differentiated value; avoid submitting lightly differentiated companion listings. Apple's **4.2 / 4.3** judgement remains discretionary.

No reviewer-specific premium unlock was found in the inspected paths. The larger conduct risk is making promises about the submitted experience that the archive does not support. The appropriate response to the post is reproducible build evidence, accurate disclosure and ordinary reviewer access, not trying to recognise App Review devices.

## Submission acceptance checklist

- Select and record one exact candidate archive, build number, commit and release dossier. The dirty development tree is not a release provenance record.
- Build and test the phone-only candidate through TestFlight too; it must stay phone-only there. Keep the glasses-enabled beta on a different build number.
- Inspect linkage, symbols, embedded SDK manifests, plist, entitlements, extensions, App Intents and widget state. No Meta registration or glasses transport should be reachable, including via old preferences, setup imports, callbacks or remote configuration.
- Fresh install and upgrade from the glasses beta: deny optional permissions, type a question, use the phone camera, try local voice/inference, and verify no glasses pairing prompt or controls. Exercise iPhone, iPad and Watch; test CarPlay and background/locked-device entry points separately.
- Exercise consent decline, grant, provider switch, fallback, relaunch and withdrawal with captured network destinations.
- Complete all live purchase tests and attach genuine paywall screenshots; provide a walkthrough for every submitted service and organisation-only workflow.
- Reconcile and publish App Privacy; complete age rating, medical/status, export-compliance and rights questions against the candidate.
- Rewrite review notes for the actual archive, explicitly inventorying paid access, organisation activation, remote integrations and safety-sensitive features. Do not paste a claim that the SDK is absent until artifact inspection proves it.

## Validation completed

- The iOS Debug app and unit-test bundle build with Xcode 27.2. The test project was generated in the isolated worktree with `OPENGLASSES_SKIP_WATCH=1`; watch binaries were not built in this run.
- **55 tests passed, zero failures, zero skipped**, across GlassesSupportPolicy, GlassesDisplayInteractive, GlassesSurfaceGate, OnboardingFlow, AlternativeTriggerService, SubsystemTestRunner, PublicSiteGuard and PrivacyManifestReconciliation. The final execution used a dedicated iPhone 17 Pro simulator running iOS 27.0. Xcode's result summary reports no runtime warnings.
- The public-address source guard needed a test-only correction: normalize `/tmp` and `/private/tmp` aliases before comparing its path-specific allowlist. The corrected guard passed in the final run.
- All four edited privacy manifests parse, and the main app plus embedded iOS widget's built manifests contain `1C8F.1`.
- Website staging passed its allowlist check, all 18 page checks and the authentication-forwarding test. The approved two-page deployment succeeded, and both live pages returned HTTP 200 with the corrections.
- `git diff --check` passes.

Final test result bundle: `/private/tmp/avenkin-app-store-audit-verified-sim.xcresult`. Final execution log: `/private/tmp/avenkin-app-store-audit-verified-sim-tests.log`.

This is a focused test run, not the full test suite. Full signed archive validation, the actual App Store Connect state, live purchases, permission-denial UI walkthroughs and physical-device tests remain outside the evidence collected here. These limits and the open findings above prevent a release sign-off.


## Remediation verification — source commit `79eb874c2`

The fix set is committed on `codex/app-store-guidelines-audit`; the main worktree was not changed by this remediation. The final phone-only app was rebuilt as a fresh bundle and stamped with `79eb874c2`. Both complete simulator projects, including watch targets, built successfully. These are simulator artifacts, not distribution archives or App Store upload candidates.

- **Final phone-only run:** 394 focused tests passed; zero failures, skips, expected failures or runtime warnings. This includes consent grant/refusal, recipient/purpose isolation, persistence, cancellation, withdrawal of in-flight HTTP, redirect refusal, background refusal, unsaved-approval refusal, SDK-free factories, migrated EVEN state, saved Siri bindings, provider request/stream fixtures, MCP/agent fixtures and privacy reconciliation.
- **Glasses-beta compatibility run:** 538 focused tests passed; zero failures, skips or runtime warnings. This verified the retained SDK implementations and typed policies, alongside the common network tests. It preceded the last shared consent-storage failure handling and phone-only Siri metadata cleanup; those final changes were validated in the phone-only run. The beta-specific SDK implementations did not change after that run.
- **Packaging inspection:** the final phone-only artifact passed checks of its main metadata and signed app entitlements, plus linkage/symbol inspection across **20 Mach-O binaries**, including extensions/watch/test host components. Meta package products and SDK code were absent. Generated App Intents metadata contained none of the five unsupported hardware actions; the phone shortcut was **Start Listening**, with a microphone icon. No individual SDK files were stripped to obtain this result.
- **Positive control:** the completed glasses-beta artifact was correctly rejected by the same phone-only checker for its beta marker, hardware configuration/intents, SDK frameworks and linked SDK symbols.
- **Build tooling:** five Python metadata/derivation tests passed. Shell syntax, metadata JSON parsing and `git diff --check` passed.

The first unsigned broad run exposed missing simulator Keychain entitlements, an outdated telemetry expectation and a fixture acknowledgement still running after its test. The final simulator host was signed ad hoc for Keychain coverage; the telemetry test now checks SDK absence in the phone variant, and fixture teardown joins acknowledgement work. No tests were skipped to hide these failures. Simulator signing does not verify distribution signing, provisioning or device behavior.

Result bundles and evidence:

- Phone: `/private/tmp/avenkin-phone-only-final.xcresult`; summary `/private/tmp/avenkin-phone-only-final-summary.json`; execution `/private/tmp/avenkin-phone-only-final-tests.log`.
- Beta: `/private/tmp/avenkin-glasses-beta-verified.xcresult`; summary `/private/tmp/avenkin-glasses-beta-verified-summary.json`; execution `/private/tmp/avenkin-glasses-beta-verified-tests.log`.
- Final artifact check: `/private/tmp/avenkin-phone-only-final-artifact-check.log`; beta rejection control `/private/tmp/avenkin-glasses-beta-rejected-as-phone.log`.

A dedicated simulator was used and removed after verification. Existing simulators were left alone. Native UI inspection was unavailable because the Mac was locked. A physical-device/permission walkthrough, an exact signed distribution archive, App Store Connect workflow/build selection and privacy answers, live sandbox purchases, valid organisation review access, and safety/third-party-rights evidence remain outstanding in the [submission checklist](app-store-2026.10/submission-checklist.md). The revised privacy policy is a branch draft and was not published. No app was uploaded or submitted by this remediation.
