# DG — Screen Inventory

**Produced by DG P1** (the tokens + components PR). This is the artefact that scopes
DG P2–P5: every view under `Sources/App/Views/` (plus the two app-level screens), the
idiom it is built in today, and the phase that converts it.

Idioms, as they appear below:

| Idiom | What it means |
|---|---|
| **OGDesign** | Built from the OGDesign primitives (`OGScrollPage`/`OGSection`/`OGRow`/…). Already on P1's foundation. |
| **stock + ogFormStyle** | A stock `Form`/`List` wearing the warm canvas and accent tint. Halfway there. |
| **stock** | Plain SwiftUI `Form`/`List`, system grey, no OGDesign contact. The bulk of the app. |
| **custom** | Hand-rolled layout with its own backgrounds, spacing and type. Where the app most looks like several apps. |

Phase targets: **P2** onboarding · **P3** settings · **P4** session surface · **P5** long tail ·
**—** not a screen (intents, delegates, layout primitives, the component library itself).

Judgement calls are noted inline. The classification is mechanical (which primitives a
file references); the phase assignment is not.

## P2 — Onboarding

| View | Idiom | Note |
|---|---|---|
| `OnboardingView.swift` | ✅ OGDesign + stock grouped lists | Converted in DG P2 (2026-08-25): grouped `List` pages on the warm canvas, `OGCard`/`OGRow` hero pages, accent buttons. |
| `OnboardingOverlay.swift` | custom | In-app coach marks over the session surface. |
| `OAuthSignInRows.swift` | ✅ / stock | The onboarding half converted in DG P2 (`OnboardingAccountSignInSection`, now a grouped `Section`); `OAuthSignInRows` is a stock form cluster and converts with Settings in P3. |
| `GoogleSignInRows.swift` | custom | As above. |
| `BiometricLockView.swift` | custom | First screen after a cold launch when the owner gate is on — reads as onboarding to the user even though it isn't. |

## P3 — Settings

The hub, its category screens, and everything reachable from them. DE decides what is
visible and in what order; DG decides what it looks like.

| View | Idiom | Note |
|---|---|---|
| `SettingsView.swift` | OGDesign | The hub. Reference implementation of the language. |
| `SettingsScreens.swift` | stock + ogFormStyle | Seven category screens; the largest single conversion in P3. |
| `HermesBridgeSettingsView.swift` | stock + ogFormStyle | |
| `AccessibilitySettingsView.swift` | stock | Named in DF P2 as critical-path — convert with, not after, the rest. |
| `AgentHarnessSettingsView.swift` | stock | |
| `AgenticFeaturesView.swift` | stock | |
| `DiarizationSettingsView.swift` | stock | |
| `DigestSettingsView.swift` | stock | |
| `EvenDisplaySettingsView.swift` | stock | |
| `FieldAssistSettingsView.swift` | stock | |
| `FingerspellingSettingsView.swift` | stock | |
| `GatewaySettingsView.swift` | stock | |
| `HIPAASettingsView.swift` | stock | |
| `LLMImageSettingsView.swift` | stock | |
| `LanguageSettingsView.swift` | stock | |
| `LiveVisionSettingsView.swift` | stock | |
| `MCPServerSettingsView.swift` | stock | |
| `MedicalExportSettingsView.swift` | stock | |
| `NavigationSettingsView.swift` | stock | |
| `PlaybooksSettingsView.swift` | stock | |
| `QuickActionsSettingsView.swift` | stock | ~1k lines; the long pole of the settings batch. |
| `SceneNarrationToggleView.swift` | stock | |
| `ServicesSettingsView.swift` | stock | |
| `SkillPacksSettingsView.swift` | stock | |
| `TeleprompterSettingsView.swift` | stock | |
| `ToolsSettingsView.swift` | stock | |
| `TranslationSettingsView.swift` | stock | |
| `WebHUDMirrorSettingsView.swift` | stock | |
| `SafetyRulesView.swift` | stock | |
| `SiriExposureView.swift` | stock | |
| `ShortcutTemplatesView.swift` | stock | |
| `SyncStatusView.swift` | stock | |
| `AttributionsView.swift` | OGDesign | Already converted. |

## P4 — The session surface

Highest-traffic surface; done after the language is proven on P2/P3. The approved
signatures (capsule, status card, waveline) are polished within the language, not replaced.

| View | Idiom | Note |
|---|---|---|
| `MainView.swift` | custom | Tab shell; owns the accent environment. |
| `VoiceTab.swift` | custom | The three-zone session screen. |
| `StatusIndicator.swift` | custom | The approved status card with merged pills. Signature — polish only. |
| `BottomControlBar.swift` | custom | Capsule + quick actions. Signature — polish only. |
| `VoiceWaveline.swift` | custom | Waveline + ambience. Signature; already Reduce-Motion-aware as of P1. |
| `TranscriptOverlay.swift` | custom | |
| `AmbientCaptionOverlay.swift` | custom | DF P2 also owns its Dynamic Type / live-region question. |
| `QuickActionsOverlay.swift` | custom | |
| `CircleButton.swift` | custom | Session-surface control primitive; a candidate to absorb into OGDesign in P4. |
| `AssistiveModeToggleView.swift` | custom | |
| `SafetyAssessmentOverlay.swift` | custom | |
| `LivePreviewView.swift` | custom | Camera preview sheet. |
| `PhoneCameraView.swift` | custom | |
| `ModelPickerSheet.swift` | stock | Reached from the session surface, so it converts with it. |
| `PersonaPickerSheet.swift` | stock | As above; ~800 lines. |

## P5 — The long tail

Batched by area. Each batch is mechanical once P1's components exist.

**Chat**

| View | Idiom |
|---|---|
| `Chat/ChatListView.swift` | stock |
| `Chat/ChatThreadView.swift` | custom |
| `Chat/ChatComposer.swift` | custom |
| `Chat/MessageBubble.swift` | custom |
| `Chat/MessageContentView.swift` | custom |

**Models, prompts & personas**

| View | Idiom |
|---|---|
| `AddModelView.swift` | stock |
| `ModelEditorView.swift` | stock |
| `ModelFormView.swift` | custom |
| `ModelPricingEditorView.swift` | stock |
| `LocalModelManagerView.swift` | stock |
| `PersonasView.swift` | stock |
| `PromptPresetsView.swift` | stock |
| `PromptInspectorView.swift` | stock |

**Tools, skills & integrations**

| View | Idiom |
|---|---|
| `CustomToolsView.swift` | stock |
| `VoiceSkillsManagerView.swift` | stock |
| `SuggestedSkillsView.swift` | stock |
| `ClawHubBrowserView.swift` | stock |
| `MCPCatalogView.swift` | stock |
| `MCPServersView.swift` | stock |
| `MCPServerTrustView.swift` | stock |
| `ScheduledTasksView.swift` | stock |
| `RemoteActionConsentView.swift` | custom |
| `RemoteInvokeAuditView.swift` | stock |

**Vaults, documents & records**

| View | Idiom |
|---|---|
| `VaultManagerView.swift` | stock |
| `VaultFilesEditorView.swift` | stock |
| `HealthVaultEditorView.swift` | custom |
| `DocumentsView.swift` | stock |
| `RecordingsView.swift` | stock |
| `MeetingRecordsView.swift` | stock |
| `Projects/ProjectDetailView.swift` | stock |
| `CaptureFlowAuthorView.swift` | stock |

**Learning**

| View | Idiom |
|---|---|
| `DeckListView.swift` | stock |
| `FlashcardView.swift` | custom |
| `QuizView.swift` | custom |
| `ReadingStatsView.swift` | stock |
| `InsightsView.swift` | stock |

**Assessment & medical**

| View | Idiom |
|---|---|
| `AssessmentCardView.swift` | custom |
| `SafetyAssessmentReportView.swift` | custom |
| `MedicalCompliancePaywallView.swift` | custom |

**HUD & display**

| View | Idiom |
|---|---|
| `HUDPreviewView.swift` | custom |
| `HUDMirrorView.swift` | custom |

**Developer & diagnostics**

| View | Idiom |
|---|---|
| `DeveloperPanelView.swift` | OGDesign |
| `TurnTimelineDebugView.swift` | OGDesign |
| `NetworkMonitorView.swift` | stock |

**Siri surfaces**

| View | Idiom |
|---|---|
| `SiriContentDetailView.swift` | custom |

**App shell**

| View | Idiom | Note |
|---|---|---|
| `LaunchScreen.swift` | custom | Fixed point sizes (`.system(size: 36)`) still to convert; Reduce Motion handled in P1. |
| `RootView.swift` | custom | Shell only. |

## Not screens

`Intents/*` (App Intents and entities), `CarPlaySceneDelegate.swift`, `ShareSheet.swift`
(a `UIViewControllerRepresentable`), `RadialLayout.swift` (a `Layout`),
`Components/SecretInputField.swift` (a field primitive — folds into OGDesign in P3),
and `Components/OGDesign.swift` / `Components/OGDesignTokens.swift` (the library itself).

## Counts

| Phase | Screens |
|---|---|
| P2 onboarding | 5 |
| P3 settings | 33 |
| P4 session surface | 15 |
| P5 long tail | 41 |

## Notes for the later phases

- **P5 batching** (the plan's open question): the areas above are navigation areas *and*
  component-usage clusters at once — the settings-shaped screens all want `OGSection`/`OGRow`,
  the media-shaped ones want cards and stat tiles. Batching by area, as listed, is the
  recommendation.
- **Watch and CarPlay**: no view files participate — CarPlay renders through templates and the
  watch app is its own target. Tokens can travel (the accent already does, via the shared
  accent colours); layout stays untouched, as the plan leans.
- **Left behind by P1** and worth folding into P3: the accent used as *text on a plain
  surface* is only guaranteed for the tinted-label path added here; a screen that paints
  `accent` straight onto a card without going through OGDesign is not covered.
