# Plan HP — EU AI Act First Tranche (nothing taken away, everything disclosed, the boundary built dormant)

**Status:** 🚧 In progress 2026-10-06 — P1 (pure cores + gating fixes) and P2 (surfaces and copy) ship as one PR. P3 is a decision, not code.
**Origin:** [docs/eu-ai-act-review-2026-10.md](../eu-ai-act-review-2026-10.md) §5, tranche "before the next EU-visible release", with the owner's two constraints: a compliant build that does not impact users where possible, and an existing user who has a capability keeps it when its default changes.
**Priority:** P0. Article 50 has applied since 2 August 2026 and TestFlight with EU testers is real-world use, not pre-market testing (Art. 2(8)). The December 2027 items are not built here; the storefront boundary that will carry them is, dormant and tested.
**Surfaces:** `Config` defaults and one migration, `AIFeatureRegistry`, `AIDisclosureLedger`, `AssistiveModeService`, `VisionAssessTool`, `RecordingTranscriber`, `SettingKey`, `FaceRecognitionTool`, a new Settings screen for enrolled faces, `privacy.html`, `PrivacyInfo.xcprivacy`. One new pure policy file. No SDK change, no new dependency, no network change.

---

## Verified current behaviour (origin/main @ f3d90a0d, 2026-10-06)

Paths are under `OpenGlasses/Sources/`.

- `Config.faceRecognitionEnabled` (`Utils/Config.swift:4207`) defaults **true** and is bound to no view; the only user switch is Settings › Tools. Enrolment via `face_recognition remember` has no confirmation step (`ToolEffectClassification.swift:100` classes it `.localMutation`). The near-tie message tells the wearer to remove a face "in Settings" and no such screen exists. The tool description (`NativeTools/FaceRecognitionTool.swift:9`) says faces are recognised "automatically when the camera is active"; in fact matching starts only when the model calls `toggle`/`on` (`:71-79`) and only once a face is enrolled.
- `AssistiveRouter` Social mode (`Services/Accessibility/AssistiveRouter.swift:51-68`) asks the model for "the emotional state of the person they are looking at" with an urgency band. It is reachable whenever `Config.accessibilityModeEnabled` is on and the wearer starts Assistive Mode, including on a phone that is organisation-managed (`PolicyEnvelope.isManaged`) or running a Field Assist edition (`Config.fieldAssistEnabled`). It is absent from `AIFeatureRegistry`, `privacy.html` and the EV use-case register.
- `vision_assess kind:first_aid_triage` (`NativeTools/VisionAssessTool.swift:31-47`) consults no `AIFeatureGate`; the registry's `.firstAidAssist` entry claims to cover "camera triage" and does not.
- `RecordingTranscriber.transcribe` (`Services/RecordingTranscriber.swift:30`) uploads a saved recording to Deepgram whenever a key is present and HIPAA mode is off; it ignores `Config.diarizationEnabled`. The registry tags speaker identification `.biometric`; there is no voiceprint, only a typed name on a per-session cluster id (`Services/Diarization/SpeakerRegistry.swift`).
- `AIDisclosureLedger` (`Services/Provenance/AIDisclosureLedger.swift`) has one surface, `.assessment`, consumed only by `StructuredVisionService`. Direct voice turns, Gemini Live and OpenAI Realtime sessions and the translation modes say nothing at their first interaction.
- `LiveTranslationService.translate()` returns `"[src→tgt] text"` without translating.
- No code reads the App Store storefront; `grep Storefront` over `Sources` is empty. One binary ships to every territory.
- `SettingKey` (`Services/OrgProfile/SettingKey.swift`) cannot pin `faceRecognitionEnabled`.

## P1 — Pure cores and gating fixes (headless)

1. **`CapabilityDefaultMigration`** (new, `Services/Privacy/`). Input: whether `faceRecognitionEnabled` has ever been written, `hasCompletedOnboarding`, whether the face database is non-empty, and the migration's own done-marker. Output: `.seedOn`, `.seedOff` or `.leaveAlone`. Rule: an install that completed onboarding before this build, or that has enrolled faces, is an existing user and is seeded **on**; a fresh install is seeded **off**; a key already written is left alone. Run once at launch before any `AIFeatureGate` read. Tests: the four input corners and idempotence.
2. **`faceRecognitionEnabled` default → false** behind the migration above. `AIFeatureGate` already refuses the tool when off. Add `.faceRecognitionEnabled` to `SettingKey` as a ceiling an organisation can pin to false (never force on).
3. **`AssistiveModePolicy`** (new, pure). Inputs: organisation-managed, Field Assist edition active, accessibility tier on. Output: whether Social mode (emotional-state inference) is offered, and the reason copy key when not. Rule: Social mode is never offered on a managed phone or under a Field Assist edition; Scene mode is unaffected. `AssistiveModeService`/`AssistiveRouter` route Social to Scene when the policy refuses, and the UI says so. Register `.assistiveSocial` in `AIFeatureRegistry` with `sensitiveCategories: [.biometric]`, its own disable switch (default on for personal users; the migration does not touch it), and "nothing retained".
4. **First-aid triage gate.** `VisionAssessTool` refuses `kind == "first_aid_triage"` when `AIFeatureGate.isEnabled(.firstAidAssist)` is false, with the same refusal text shape the other gated tools use. Registry claim becomes true. Test: disabled flag → refusal; enabled → reaches the service seam.
5. **Deepgram batch honours the toggle.** `RecordingTranscriber.canUseDeepgram` also requires `Config.diarizationEnabled` (reuse `DiarizationConfig.isDiarizationConfigured` if it is the right shape). Registry: speaker identification's category becomes `.none` with a sentence saying why (cluster id, no voiceprint). Tests for both.
6. **`MarketAvailabilityPolicy`** (new, pure, `Services/Privacy/`). Inputs: storefront country code (ISO 3166-1 alpha-2, optional), a capability (`faceRecognition`, `emotionInference`, `firstAidTriageBusiness`), and the date. Output: `.available`, `.unavailableInRegion(reason)`. Data: the EU/EEA storefront list as a constant. **Dormant:** the policy ships with every capability `.available` everywhere (the per-capability "restricted from" date is `nil`) and a single table to fill in before 2 December 2027. A `StorefrontReader` seam over StoreKit's `Storefront.current` is wired but its result only feeds a diagnostics line in the support report. Tests: EEA list membership, nil storefront → available, a restricted-from date in the past → unavailable, in the future → available.
7. **`AIDisclosureLedger` surfaces** gain `.conversation` (Direct voice first turn and the two live modes) and `.translation`. Copy: conversation — "You're talking to an AI assistant. It can be wrong, so check anything important."; translation — "This is a live AI translation. It may be inaccurate." Tests: once per session per surface; reset on new conversation; strings resolve through the catalog.

## P2 — Surfaces and copy

8. **Enrolled Faces screen** under the glasses section of Settings (feedback: glasses-only settings live under the glasses section): the master switch bound to `Config.faceRecognitionEnabled`, opt-in copy ("Names people you've enrolled when they're in front of your glasses. The person isn't told. You're responsible for using this lawfully where you are."), a list of enrolled names with last-seen and swipe-to-delete calling `forget`, and "Forget everyone". The near-tie message's "in Settings" now points somewhere real.
9. **Enrolment confirmation.** `face_recognition remember` is classed so the existing bound-approval card asks "Remember this face as Maria? They won't be told." before enrolling. Tool description rewritten to match behaviour.
10. **Spoken disclosures.** Direct mode speaks `.conversation` once before the first answer of a session; Gemini Live and OpenAI Realtime speak it once at session start; `live_translate` and translated-captions start speak or show `.translation` once. The HUD mirrors the line where a HUD is attached.
11. **Social mode copy.** Accessibility settings footer and the Assistive toggle state that Social mode is not available on a managed phone or under a Field Assist edition and is not for use at work or school. `AccessibilitySettingsView:108` is the anchor.
12. **Privacy manifest and notice.** `PrivacyInfo.xcprivacy` declares the face feature prints under the biometric/other-user-content type with purpose AppFunctionality, Linked=false, Tracking=false. `privacy.html` gains three honest paragraphs: Social mode, first-aid triage, the Clinical Assistant persona; and a line that a pasted ElevenLabs voice is the wearer's choice.
13. **Translation stub.** `LiveTranslationService.translate()` either calls the on-device or Gemini translation provider already shipped under Plan BY, or the tool is removed from the registry until it does. Removing is acceptable for this PR; shipping a stub that speaks untranslated text to a third party is not.

## P3 — Decisions (not code)

The four decisions in the review §6, plus the date the `MarketAvailabilityPolicy` table is filled in. Nothing in this PR assumes an answer.

## Verification

Full `OpenGlassesTests` on the simulator, `-configuration Release` build, the privacy-logging gate, the CI-form gitleaks scan and the security-regression classes, per the standing pre-PR gate. `AIFeatureRegistryTests` must still pass with the new entry and the changed categories; `OutboundFrameConsumerTests` must still pass (no new frame consumer is added). Device: the migration on an upgraded TestFlight install keeps face recognition on; a fresh install starts off. That one needs a phone and is owed after merge.

## Out of scope

Observe-only redesign of Social mode (review §3.2, Decision 3), the Article 50(2) marking tranche (review §5 items 6–8), the storefront table being switched on, any removal of a capability for any user.
