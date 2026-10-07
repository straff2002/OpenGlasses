# Plan HS — The Four Decisions, Taken (storefront gate armed, Social mode for everyone, triage personal-only)

**Status:** 🚧 In progress 2026-10-07 — one PR.
**Origin:** The owner answered the four decisions in [docs/eu-ai-act-review-2026-10.md](../eu-ai-act-review-2026-10.md) §6 on 2026-10-07. This plan records the answers and builds what follows from them. Follows [HP](HP-eu-ai-act-first-tranche.md), [HQ](HQ-eu-ai-act-second-tranche.md), [HR](HR-social-mode-observe-only.md) (all merged) and the catalog sync (#686).
**Priority:** P0 for the record and the Social mode lift (they change copy that is live today); P1 for the storefront arming (the date is 2 December 2027, but a build that carries the date needs no coordinated release on the day).
**Surfaces:** `MarketAvailabilityPolicy` and its one consumer, `FaceRecognitionTool`/`EnrolledFacesView`, `AssistiveModePolicy` and `SocialModeCopy`, `VisionAssessTool` and the field tool profile, `AIFeatureRegistry`, `privacy.html`, the deployer sheet, the review.

---

## The decisions (2026-10-07)

1. **EU storefront facts.** Avenkin is available in every EU/EEA App Store storefront except France (the encryption declaration). The first EU availability date is not recorded; the Article 50(2) marking work in HQ was done without relying on the grace period, so the date no longer changes anything. Region-dependent behaviour is to be done by storefront gate.
2. **Face recognition in the EU after 2 December 2027.** Switch the dormant storefront gate on for EEA storefronts before that date, so face recognition is unavailable there from the day Annex III applies. No notified-body route.
3. **Social mode.** Lift the managed-phone and Field Assist refusals now that Social mode is observation-only.
4. **First-aid triage.** Keep camera triage for personal use; remove it from Field Assist editions. First-aid *coaching* (the spoken protocols) is unaffected.

## Verified current behaviour (origin/main @ 9612b168, 2026-10-07)

Paths are under `OpenGlasses/Sources/`.

- `MarketAvailabilityPolicy.availability(of:storefront:at:restrictions:)` (`Services/Privacy/MarketAvailabilityPolicy.swift:63`) is pure and tested; `restrictedInEEAFrom` (`:51`) has every capability `nil`; `eeaStorefronts` (`:38`) has the 30 codes. `StoreKitStorefrontReader.countryCode()` (`Services/Privacy/StorefrontReader.swift:25`) converts StoreKit's alpha-3 to alpha-2. The only consumer today is the support report's "App Store region" line. Nothing gates on it.
- `AssistiveModePolicy` (`Services/Accessibility/AssistiveModePolicy.swift`) refuses Social mode for `.organisationManaged` and `.fieldAssistEdition`; `SocialModeCopy.refusalLine` has copy for both; `privacy.html` and `docs/deployer-information-sheet.md` say Social mode is unavailable on managed phones and Field Assist editions.
- `VisionAssessTool` gates `first_aid_triage` on `AIFeatureGate.isEnabled(.firstAidAssist)` only; `FieldToolProfile.swift:21` lists `vision_assess` among the field tools with no kind restriction, so a Field Assist edition can run triage.

## P1 — Build

1. **Arm the storefront gate for face recognition.** `restrictedInEEAFrom[.faceRecognition]` becomes 2 December 2027 00:00 UTC (the day Annex III obligations apply; the Act's date, not a day earlier, so the record and the behaviour agree). Add `MarketAvailability` as a small `@MainActor` service that reads the storefront once per launch through `StoreKitStorefrontReader` (injectable), caches the alpha-2 code, and answers `availability(of:)` with today's date; a nil storefront stays `.available`, as the policy already says, because TestFlight sandboxes and signed-out devices report none and a legal gate must not fire on missing data. Consumers: `FaceRecognitionTool` refuses `remember`, `toggle`, `on` with the policy's reason string when unavailable (`forget`, `off`, `list` still work so a wearer can clear their data), `NativeToolRegistry` keeps the tool registered so the refusal is spoken rather than the tool silently vanishing, and `EnrolledFacesView` shows the switch disabled with the reason. **Ahead of the date**, from this build on, the Enrolled Faces screen on an EEA storefront shows a footer: "In EU and EEA App Store regions, face recognition will stop being available on 2 December 2027." Tests: policy at the day before and the day of; the service with a fake reader for an EEA code, a non-EEA code and nil; the tool's refusal per action; the footer condition.
2. **Lift the Social mode refusals.** Remove `.organisationManaged` and `.fieldAssistEdition` from `AssistiveModePolicy.Refusal` and `Facts`; keep `.turnedOff` and `.accessibilityTierOff`. Delete the two refusal strings from `SocialModeCopy`; the standing footer stays. Update the tests. Record in the HR plan that the follow-up was taken by owner decision on 2026-10-07 without the device run, and that the device run is still owed as evidence rather than as a gate.
3. **Triage personal-only.** `VisionAssessTool` refuses `kind == "first_aid_triage"` when a Field Assist edition is active (`Config.fieldAssistEnabled`) or the phone is organisation-managed (`PolicyEnvelope.isManaged`), with a one-line reason ("Camera triage isn't available in Field Assist editions; first-aid coaching still is."), and the kind is omitted from the tool's advertised list in that state so the model does not offer it. `AssessmentSchemaRegistry` stays as is; the restriction lives at the tool. `AIFeatureRegistry`'s `.firstAidAssist` note says so. Tests for both edition states.
4. **Copy and record.** `privacy.html`: Social mode paragraph drops the "not available on a phone managed by an organisation or in a Field Assist edition" sentence; first-aid paragraph says camera triage is for personal use and is not offered in Field Assist editions; a sentence under "Jurisdictions and legal basis" that face recognition will not be available in EU/EEA App Store regions from 2 December 2027. `docs/deployer-information-sheet.md`: the Art. 50(3) paragraph now says Social mode is available to staff and describes visible cues only; the records table notes camera triage is not in Field Assist editions; the profile table is unchanged. The review's §2 (storefront facts) and §6 (all four answers, dated) are updated, and §3.1's position line notes the gate is armed.

## Verification

Full `OpenGlassesTests` on the simulator, `-configuration Release` build, `Scripts/check-privacy-logging.sh`, the CI-form gitleaks scan, the `security-regression` classes. Device: on a phone whose Apple ID storefront is an EEA country, the Enrolled Faces footer shows; with a non-EEA storefront it does not. Owed after merge.

## Out of scope

Anything that changes behaviour for a non-EEA storefront today; the office-side recorded-session contract flag; human review of the machine translations.
