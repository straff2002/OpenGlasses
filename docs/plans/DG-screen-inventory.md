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

## P3 — Settings ✅ shipped (2026-08-26) — with a remainder P5 closed

The hub, its category screens, and everything reachable from them. DE decides what is
visible and in what order; DG decides what it looks like.

**Correction recorded by P5 (2026-08-27).** P3 shipped the hub, the seven category
screens and the model-selection surfaces — which is what its prose describes and what
its PR contains — but this table also lists the ~29 screens reachable *from* those
categories, and those kept their stock system grey. Opening one flashed cool grey
against the warm hub: the plan's own complaint, one level down. P5 closed it as an area
of its own (`.ogFormStyle()`, one line each), listed at the foot of the P5 section. The
rows below are marked for what P3 landed; the sub-screens are marked in P5.

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

## P4 — The session surface ✅ shipped (2026-08-27)

Highest-traffic surface; done after the language is proven on P2/P3. The approved
signatures (capsule, status card, waveline) are polished within the language, not replaced.

| View | Idiom | Note |
|---|---|---|
| `MainView.swift` | ✅ custom, on tokens | Tab shell; owns the accent environment. Needed nothing beyond what it already did. |
| `VoiceTab.swift` | ✅ converted (DG P4) | The three-zone session screen. Recording badge onto `Token.badge`. |
| `StatusIndicator.swift` | ✅ converted (DG P4) | The approved status card with merged pills — same shape, measured numbers. Pills now carry a 44pt target inside the drawn capsule. |
| `BottomControlBar.swift` | ✅ converted (DG P4) | Capsule + dock tiles. Text styles + scaled metrics throughout; the disabled tile's blanket `.opacity(0.4)` removed. |
| `VoiceWaveline.swift` | ✅ no change needed | Waveline + ambience. A `Canvas`, hidden from the accessibility tree, already Reduce-Motion-aware as of P1; its fixed height is decoration and deliberately does not scale. |
| `TranscriptOverlay.swift` | ✅ converted (DG P4) | Cards and the detail sheet, incl. the accent-as-text path. |
| `AmbientCaptionOverlay.swift` | ✅ converted (DG P4) | Gained the measured scrim that makes its contrast assertable, and a 44pt speaker chip. |
| `QuickActionsOverlay.swift` | ✅ converted (DG P4) | **Currently unreferenced** — the dock absorbed its call sites. Kept because Plan Y cites it as the phone-mirror reference; removal is a P5 question. |
| `CircleButton.swift` | ✅ converted (DG P4) | Session-surface control primitive, on the media tokens. **Currently unreferenced**; absorbing it into OGDesign, or deleting it, is a P5 question. |

**Moved to P5** — the sheets and full-screen surfaces reached *from* the session surface rather
than the surface itself. Each is a screen of its own with its own composition, four of the six
were already property-swept by DF P3, and none is on the tab the accessibility gate stands in
front of; batching them with the long tail keeps the P4 change reviewable.

| View | Idiom | Note |
|---|---|---|
| `AssistiveModeToggleView.swift` | custom | → P5. |
| `SafetyAssessmentOverlay.swift` | custom | → P5. |
| `LivePreviewView.swift` | custom | Camera preview sheet. → P5. |
| `PhoneCameraView.swift` | custom | → P5. |
| `ModelPickerSheet.swift` | stock | → P5. |
| `PersonaPickerSheet.swift` | stock | ~800 lines. → P5. |

## P5 — The long tail ✅ shipped (2026-08-27)

Batched by area, one commit each. Mechanical, as P1 predicted it would be once the
components existed: 74 files, +318/−245 — a consistency pass, not a redesign.

**Chat** — 4 changed, 1 verified

| View | Idiom |
|---|---|
| `Chat/ChatListView.swift` | ✅ converted |
| `Chat/ChatThreadView.swift` | ✅ converted |
| `Chat/ChatComposer.swift` | ✅ verified, no change — already on tokens after DF P3 |
| `Chat/MessageBubble.swift` | ✅ converted — bubble fill from the palette |
| `Chat/MessageContentView.swift` | ✅ converted |

**Models, prompts & personas** — 5 changed, 3 verified

| View | Idiom |
|---|---|
| `AddModelView.swift` | ✅ verified, no change — converted with P3's model-selection slice |
| `ModelEditorView.swift` | ✅ verified, no change — as above |
| `ModelFormView.swift` | ✅ verified, no change — as above |
| `ModelPricingEditorView.swift` | ✅ converted |
| `LocalModelManagerView.swift` | ✅ converted |
| `PersonasView.swift` | ✅ converted |
| `PromptPresetsView.swift` | ✅ converted |
| `PromptInspectorView.swift` | ✅ converted |

**Tools, skills & integrations** — 10 changed

| View | Idiom |
|---|---|
| `CustomToolsView.swift` | ✅ converted |
| `VoiceSkillsManagerView.swift` | ✅ converted |
| `SuggestedSkillsView.swift` | ✅ converted |
| `ClawHubBrowserView.swift` | ✅ converted — stock list kept, canvas + status labels |
| `MCPCatalogView.swift` | ✅ converted |
| `MCPServersView.swift` | ✅ converted |
| `MCPServerTrustView.swift` | ✅ converted |
| `ScheduledTasksView.swift` | ✅ converted |
| `RemoteActionConsentView.swift` | ✅ converted — prominent accept, quiet decline |
| `RemoteInvokeAuditView.swift` | ✅ converted |

**Vaults, documents & records** — 8 changed

| View | Idiom |
|---|---|
| `VaultManagerView.swift` | ✅ converted |
| `VaultFilesEditorView.swift` | ✅ converted |
| `HealthVaultEditorView.swift` | ✅ converted |
| `DocumentsView.swift` | ✅ converted |
| `RecordingsView.swift` | ✅ converted |
| `MeetingRecordsView.swift` | ✅ converted |
| `Projects/ProjectDetailView.swift` | ✅ converted |
| `CaptureFlowAuthorView.swift` | ✅ converted |

**Learning** — 5 changed

| View | Idiom |
|---|---|
| `DeckListView.swift` | ✅ converted |
| `FlashcardView.swift` | ✅ converted — the card is `OGCard`, not a local material |
| `QuizView.swift` | ✅ converted |
| `ReadingStatsView.swift` | ✅ converted — numbers onto `OGStatTile` |
| `InsightsView.swift` | ✅ converted — as above |

**Assessment & medical** — 3 changed

| View | Idiom |
|---|---|
| `AssessmentCardView.swift` | ✅ converted |
| `SafetyAssessmentReportView.swift` | ✅ converted |
| `MedicalCompliancePaywallView.swift` | ✅ converted — the largest single diff in the phase |

**HUD & display** — 2 changed

| View | Idiom |
|---|---|
| `HUDPreviewView.swift` | ✅ converted — fixed lens geometry kept on purpose (see below) |
| `HUDMirrorView.swift` | ✅ converted — onto `Token.media` and the named media opacity roles |

**Developer & diagnostics** — 3 changed, 1 verified. Deliberately the cheapest
treatment in the sweep: owner-facing, so consistency only.

| View | Idiom |
|---|---|
| `DeveloperPanelView.swift` | ✅ converted (minimal) |
| `TurnTimelineDebugView.swift` | ✅ verified, no change — already on the primitives |
| `NetworkMonitorView.swift` | ✅ converted — form style + audited status labels |
| `DiagnosticsSupportView.swift` | ✅ converted (minimal) — not in P1's list; swept while here |

**Siri surfaces** — 1 changed

| View | Idiom |
|---|---|
| `SiriContentDetailView.swift` | ✅ converted |

**App shell** — 1 changed, 1 verified

| View | Idiom | Note |
|---|---|---|
| `LaunchScreen.swift` | ✅ converted | Fixed point sizes onto text styles; the glow and its Reduce Motion variant untouched. |
| `RootView.swift` | ✅ verified, no change | Shell only, as P1 expected. |

**The six sheets P4 moved here** — 4 changed, 2 verified

| View | Idiom |
|---|---|
| `AssistiveModeToggleView.swift` | ✅ converted |
| `SafetyAssessmentOverlay.swift` | ✅ verified, no change — already on tokens after DF P3 |
| `LivePreviewView.swift` | ✅ converted — media ground + named opacity roles |
| `PhoneCameraView.swift` | ✅ converted |
| `ModelPickerSheet.swift` | ✅ verified, no change — already wore `.ogFormStyle()` |
| `PersonaPickerSheet.swift` | ✅ converted — onto `OGSelectionRow`, matching the model picker |

**The settings sub-screens P3 left stock** — 28 changed, 1 verified. Not a P5 area in
P1's plan; see the correction below.

`AccessibilitySettingsView`, `AgentHarnessSettingsView`, `AgenticFeaturesView`,
`DiarizationSettingsView`, `DigestSettingsView`, `EvenDisplaySettingsView`,
`FieldAssistSettingsView`, `FingerspellingSettingsView`, `GatewaySettingsView`,
`HIPAASettingsView`, `LLMImageSettingsView`, `LanguageSettingsView`,
`LiveVisionSettingsView`, `MCPServerSettingsView`, `MedicalExportSettingsView`,
`NavigationSettingsView`, `PlaybooksSettingsView`, `QuickActionsSettingsView`,
`ServicesSettingsView`, `SkillPacksSettingsView`, `TeleprompterSettingsView`,
`ToolsSettingsView`, `TranslationSettingsView`, `WebHUDMirrorSettingsView`,
`SafetyRulesView`, `SiriExposureView`, `ShortcutTemplatesView`, `SyncStatusView`
— all ✅ `.ogFormStyle()`. `SceneNarrationToggleView` ✅ verified, no change (already
on the canvas).

## Not screens

`Intents/*` (App Intents and entities), `CarPlaySceneDelegate.swift`, `ShareSheet.swift`
(a `UIViewControllerRepresentable`), `RadialLayout.swift` (a `Layout`),
`Components/SecretInputField.swift` (a field primitive — folds into OGDesign in P3),
and `Components/OGDesign.swift` / `Components/OGDesignTokens.swift` (the library itself).

## Counts

As planned by P1, and as the phases actually landed:

| Phase | Planned | Landed |
|---|---|---|
| P2 onboarding | 5 | 5 |
| P3 settings | 33 | 4 (hub + categories + the model surfaces); 29 sub-screens fell to P5 |
| P4 session surface | 15 | 9; the 6 sheets moved to P5 |
| P5 long tail | 41 | 47 planned + 6 sheets + 29 settings sub-screens + `DiagnosticsSupportView` |

P5 totals: **74 files changed, 9 verified-no-change**, in nine commits. Every row in
this document is now accounted for.

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
