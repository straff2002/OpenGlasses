import Foundation

/// Every text-keyed `ForEach` and `List(…, id:)` in a screen that has a list or a form, and why its
/// row ids cannot repeat.
///
/// Two rows of one loop with the same id make UIKit's list update assert, which is how build 688
/// crashed three times with no app frame in the trace. `RowIdentityGuardTests` scrapes
/// `OpenGlasses/Sources/App` for loops keyed by `\.self` or by a field (not `\.id`, `\.offset` or
/// `\.rawValue`, and not a shape that is distinct by construction: `allCases`, `indices`, a range or
/// a dictionary's keys) in a file with a list or a form, and fails on any site not listed here — so
/// a new text-keyed list has to be argued for in this file, not added quietly. A listed site that
/// no longer exists fails too, so the roster cannot rot.
///
/// A site is `file|collection|key path`, the collection with its whitespace collapsed; identical
/// loops in one file share an entry. Seeded 2026-11-26 by running the scrape and reading each site.
enum RowIdentityRoster {

    enum Verdict: Equatable {
        /// A literal or static list whose values are distinct.
        case constant
        /// Distinct by construction: a set, a dictionary's keys, ids a store keeps unique.
        case distinct
        /// Repeats are removed where the data is built; the reason cites where.
        case deduplicated
        /// The options of a picker or menu, not list rows; distinct.
        case picker
        /// Not inside a list or form row: a chip row, a stack, a scroll view.
        case notARow
        /// The options of a picker or menu can repeat. Not list rows, so not the crash this guards
        /// against; listed so the fact is written down.
        case menuOptionsMayRepeat
        /// Distinctness could not be shown from the code, so the screen runs `.uniqueRowsCheck()`
        /// on the data and logs `listRowsRepeated` if it ever repeats.
        case watched
    }

    struct Site: Equatable {
        let verdict: Verdict
        let reason: String
        init(_ verdict: Verdict, _ reason: String) {
            self.verdict = verdict
            self.reason = reason
        }
    }

    static let sites: [String: Site] = [
        #"AccessibilitySettingsView.swift|languageOptions|\.code"#:
            .init(.picker, #"Translate To Picker options; private literal array of 11 distinct language codes (AccessibilitySettingsView.swift:54)"#),
        #"ActiveJobView.swift|job.visitedUnits.dropFirst()|\.self"#:
            .init(.deduplicated, #"visitedUnitNames inserts each label into a seen Set before appending (JobTabModel.swift:495)"#),
        #"AddOnsSettingsView.swift|AddOnPermissionSummary.lines(for: addOn.manifest.permissions)|\.kind"#:
            .init(.distinct, #"each Kind appended at most once; reserved kinds come from iterating allCases (AddOnPermissionSummary.swift:31)"#),
        #"AddOnsSettingsView.swift|addOn.manifest.skills|\.name"#:
            .init(.deduplicated, #"validator refuses a manifest naming a skill twice, so no loaded add-on has one (RecipeAddOnValidator.swift:294)"#),
        #"AddOnsSettingsView.swift|badges(record, loaded: loaded)|\.self"#:
            .init(.distinct, #"at most one trust badge plus builtByAssistant and editedOnPhone, each a different fixed string (AddOnsSettingsView.swift:258)"#),
        #"AddOnsSettingsView.swift|model.badges|\.text"#:
            .init(.distinct, #"each Badge case appended at most once and every case has its own fixed text (AddOnSheetModel.swift:100)"#),
        #"AssistingHandoverView.swift|held.changes.lines|\.self"#:
            .init(.distinct, #"HandoverChanges.between notes each Section once with its own sentence (HeldHandover.swift:106)"#),
        #"DiarizationSettingsView.swift|models|\.self"#:
            .init(.picker, #"Model Picker options; literal [nova-3, nova-2, nova-2-meeting] (DiarizationSettingsView.swift:14)"#),
        #"DocumentsView.swift|groups|\.namespace"#:
            .init(.distinct, #"one group per key of Dictionary(grouping:by: namespace) (DocumentsView.swift:23)"#),
        #"DraftReviewView.swift|unparsed|\.line"#:
            .init(.distinct, #"parser appends at most one Unparsed per pasted line with its 1-based line number (LicenceIssuance VaultDrafts.swift:193)"#),
        #"EverydaySettingsScreen.swift|groups|\.self"#:
            .init(.distinct, #"SettingsGroupID.allCases or the single [only] id (EverydaySettingsScreen.swift:43)"#),
        #"FieldAssistExpertsView.swift|TimeZone.knownTimeZoneIdentifiers|\.self"#:
            .init(.picker, #"Time zone Picker options; system knownTimeZoneIdentifiers, unique identifiers"#),
        #"FieldAssistSettingsView.swift|row.parts|\.self"#:
            .init(.notARow, #"inside the expanded task Button label VStack; parts deduped by number in PartsVerifier.verify(all:) (PartsVerifier.swift:55)"#),
        #"GoalsView.swift|model.cadenceChoices(for: goalID)|\.codeValue"#:
            .init(.picker, #"Check in Picker; fixed cadences with distinct codeValues, current one added only if missing (GoalsScreenModel.swift:217)"#),
        #"HIPAASettingsView.swift|framework.coveredSafeguards|\.self"#:
            .init(.notARow, #"VStack inside a framework DisclosureGroup; per-framework literal enum lists with no repeats (HIPAASettingsView.swift:61)"#),
        #"HIPAASettingsView.swift|framework.organisationalRequirements(in: jurisdiction)|\.self"#:
            .init(.notARow, #"VStack inside a framework DisclosureGroup; per-framework literal sentence lists with no repeats, and the Canada entry's duties are distinct sentences (agreement, breach, PIA, user activity, PIPEDA) (CanadianHealthAct.swift)"#),
        #"HIPAASettingsView.swift|retentionChoices|\.self"#:
            .init(.picker, #"Auto-Purge Picker; literal [30, 60, 90, 180, 365, 0], with an organisation's figure added in front only when it is not among them (HIPAASettingsView.swift retentionChoices)"#),
        #"HealthVaultEditorView.swift|store.manifest.files|\.self"#:
            .init(.constant, #"built-in health vault manifest lists six distinct markdown files (VaultRegistry.swift:105)"#),
        #"HomeActionEditorSheet.swift|HomeActionIcons.curated|\.symbol"#:
            .init(.notARow, #"horizontal ScrollView HStack of icon buttons; static curated list of 30 distinct SF Symbol names (SpeedDialEditor.swift:54)"#),
        #"ImmunisationCheckSheet.swift|header|\.self"#:
            .init(.menuOptionsMayRepeat, #"Picker options from a user CSV header row; only blanks dropped (ImmunisationCheckSheet.swift:107), names can repeat"#),
        #"ImmunisationCheckSheet.swift|result.unmatchedVaccines|\.vaccine"#:
            .init(.distinct, #"built from the keys of the unmatched-vaccine dictionary (ImmunisationReconciliation.swift:197)"#),
        #"InsightsView.swift|report.topTools|\.name"#:
            .init(.distinct, #"rank() maps the keys of the toolCounts dictionary (InsightsAggregator.swift:63)"#),
        #"InsightsView.swift|report.topTopics|\.name"#:
            .init(.distinct, #"rank() maps the keys of the topicCounts dictionary (InsightsAggregator.swift:63)"#),
        #"InsightsView.swift|usage.perModel|\.model"#:
            .init(.distinct, #"one ModelTotal per key of the byModel dictionary (UsageModels.swift:113)"#),
        #"JobRecordingSection.swift|RecordingConsent.points()|\.self"#:
            .init(.constant, #"six fixed, different consent sentences (RecordingConsent.swift:33)"#),
        #"LanguageSettingsView.swift|LocalizationManager.bundledLanguageInfo|\.code"#:
            .init(.constant, #"static literal list of 19 distinct bundled language codes (LocalizationManager.swift:74)"#),
        #"LiveHintsSheet.swift|HintLanguageOptions.codes|\.self"#:
            .init(.picker, #"Hint language Picker; static literal list of 25 distinct codes (LiveHintsSessionChoices.swift:137)"#),
        #"LiveHintsSheet.swift|choices.keywords|\.self"#:
            .init(.deduplicated, #"addKeyword skips a keyword whose normalised form is already listed (LiveHintsSessionChoices.swift:118)"#),
        #"LiveHintsSheet.swift|service.heardSpeakers|\.self"#:
            .init(.notARow, #"chips in a PillFlowLayout inside one VStack row; ids appended only if not already present (LiveHintsService.swift:474)"#),
        #"MCPCatalogView.swift|entry.scopes|\.self"#:
            .init(.constant, #"scopes from the bundled mcp-catalog.json; no entry repeats a scope today, though the loader does not check"#),
        #"MusicSettingsView.swift|speakers.filter { !hiddenSpeakers.contains($0.entityId) }|\.entityId"#:
            .init(.picker, #"Default Speaker Picker; Home Assistant /api/states returns one state per entity_id (not deduped locally)"#),
        #"MusicSettingsView.swift|speakers|\.entityId"#:
            .init(.distinct, #"Home Assistant /api/states returns one state per entity_id, parsed as is (HomeAssistantMediaPlayer.swift:62)"#),
        #"MyManualsView.swift|library.unfinishedCaptures|\.metadata.key"#:
            .init(.constant, #"PersonalManualLibrary.unfinishedCaptures always returns an empty array (PersonalManualLibrary.swift:67)"#),
        #"NameplateModelSheet.swift|manifest?.documents ?? []|\.file"#:
            .init(.picker, #"Manual Picker; installed manifests pass VaultValidator, which refuses a document listed twice (VaultValidator.swift:69)"#),
        #"NameplateModelSheet.swift|tokens|\.self"#:
            .init(.deduplicated, #"tokens filtered through a seen Set on the normalised model key (NameplateModelRead.swift:19)"#),
        #"NavigationSettingsView.swift|Config.recentDestinations|\.self"#:
            .init(.deduplicated, #"addRecentDestination drops a case-insensitive match before inserting, the only writer (WalkingRouteService.swift:391)"#),
        #"OnboardingView.swift|choices|\.self"#:
            .init(.deduplicated, #"knownChoices keeps each provider once via a seen Set (ManagedOnboardingPlan.swift:75)"#),
        #"OnboardingView.swift|route|\.self"#:
            .init(.notARow, #"page-indicator dots in the header HStack; each route page appears once (OnboardingFlow.swift:27 and :34)"#),
        #"OrgProfileViews.swift|review.adminLines|\.self"#:
            .init(.distinct, #"edition line, distinct-prefixed lockdown lines and one credentials line (OrgProfileManager.swift:154)"#),
        #"OrgProfileViews.swift|review.aiModelLines|\.self"#:
            .init(.distinct, #"at most two lines with different prefixes, AI model and Prompts go to (OrgProfileManager.swift:178)"#),
        #"OrgProfileViews.swift|review.lockLines|\.self"#:
            .init(.distinct, #"one line per ceilings dictionary key; each key has its own ceilingDescription text (OrgProfileManager.swift:128)"#),
        #"OrgProfileViews.swift|review.organizationLines|\.self"#:
            .init(.distinct, #"one line per owned dictionary key; each key has its own ownedDescription text (OrgProfileManager.swift:139)"#),
        #"OrgProfileViews.swift|review.startingValueLines|\.self"#:
            .init(.distinct, #"one line per startingValues dictionary key; each key has its own sentence (OrgProfileManager.swift:133)"#),
        #"PastJobView.swift|job.visitedUnits|\.self"#:
            .init(.deduplicated, #"visitedUnitNames inserts each label into a seen Set before appending (JobTabModel.swift:495)"#),
        #"PersonaPickerSheet.swift|tools.prefix(20)|\.self"#:
            .init(.distinct, #"persona.allowedTools is never set by app code, so this is the registry tool dictionary keys (NativeToolRegistry.swift:481)"#),
        #"PersonaPickerSheet.swift|tools|\.self"#:
            .init(.constant, #"built-in templates never set allowedTools (Config.swift:1706), so this section never draws"#),
        #"PersonasView.swift|wakePhrasePresets|\.self"#:
            .init(.picker, #"Wake Phrase Picker; static literal presets plus hey gemini and hey gpt, all distinct (Config.swift:306)"#),
        #"PhotographedManualViews.swift|manuals|\.documentID"#:
            .init(.distinct, #"documentID is captured:id:revision, one per entry of the journal.current dictionary (CapturedManualStore.swift:296)"#),
        #"PhotographedManualViews.swift|unfinished|\.metadata.key"#:
            .init(.distinct, #"key is id:revision and each draft loads from its own staging folder named by it (CapturedManualStore.swift:169)"#),
        #"PlaybooksSettingsView.swift|["GET", "POST", "PUT", "PATCH", "DELETE"]|\.self"#:
            .init(.picker, #"segmented Method Picker; literal list of five distinct HTTP verbs"#),
        #"PlaybooksSettingsView.swift|availableVars|\.name"#:
            .init(.menuOptionsMayRepeat, #"Menu items from user-typed step outputVar names; two earlier steps can share one (PlaybooksSettingsView.swift:354)"#),
        #"PlaybooksSettingsView.swift|iconOptions|\.self"#:
            .init(.picker, #"Icon Picker; private literal array of 15 distinct SF Symbol names (PlaybooksSettingsView.swift:205)"#),
        #"PreparedCardSettingsView.swift|Self.jobKinds|\.self"#:
            .init(.constant, #"static literal list of five different PreparedCardKind cases (PreparedCardSettingsView.swift:21)"#),
        #"PreparedCardSettingsView.swift|Self.personalKinds|\.self"#:
            .init(.constant, #"static literal list of four different PreparedCardKind cases (PreparedCardSettingsView.swift:20)"#),
        #"PreparedCardViews.swift|model.laterOptions|\.self"#:
            .init(.picker, #"Menu items; PreparedCardLaterOption.allCases filtered (PreparedCardStore.swift:61)"#),
        #"ProcedureRulesView.swift|RuleDraft.ops(for: answer)|\.self"#:
            .init(.picker, #"Comparison Picker; fixed per-kind op lists plus outOfSpec and present, no repeats (ProcedureRuleEditing.swift:351)"#),
        #"ProcedureRulesView.swift|answers|\.recordAs"#:
            .init(.picker, #"Answer Picker; values of answersByName, keyed by recordAs (ProcedureRuleEditing.swift:25)"#),
        #"ProcedureRulesView.swift|blockers|\.stepId"#:
            .init(.distinct, #"one blocker per step; import and save refuse duplicate step ids (VaultValidator.swift:332, ProcedureAuthoring.swift:51)"#),
        #"QuickActionsSettingsView.swift|Self.commonServices|\.domain"#:
            .init(.picker, #"Domain Picker; static literal list of nine distinct Home Assistant domains (QuickActionsSettingsView.swift:335)"#),
        #"QuickActionsSettingsView.swift|domains|\.self"#:
            .init(.picker, #"Filter Picker; availableDomains is a sorted Set of entity domains (QuickActionsSettingsView.swift:723)"#),
        #"QuickActionsSettingsView.swift|iconOptions|\.symbol"#:
            .init(.notARow, #"horizontal ScrollView HStack of icon buttons; static curated list of distinct symbols (SpeedDialEditor.swift:54)"#),
        #"ReplySourcesView.swift|sources|\.url"#:
            .init(.deduplicated, #"addReplyWebSources skips a source whose url is already kept (LLMService.swift:3817)"#),
        #"RingSettingsView.swift|actionOptions|\.self"#:
            .init(.picker, #"A clench Picker; distinct builtIns, quick actions by unique id, trigger added only if missing (RingSettingsView.swift:264)"#),
        #"ServicesSettingsView.swift|CloudVoiceRequests.geminiVoices|\.self"#:
            .init(.picker, #"Gemini Voice Picker; static literal list of 30 distinct voice names (CloudVoiceRequests.swift:114)"#),
        #"ServicesSettingsView.swift|CloudVoiceRequests.openAIVoices|\.self"#:
            .init(.picker, #"OpenAI Voice Picker; static literal list of 13 distinct voice names (CloudVoiceRequests.swift:19)"#),
        #"ServicesSettingsView.swift|GoLiveGuide.phoneCameraNotes|\.self"#:
            .init(.notARow, #"inside a DisclosureGroup in one row; fixed per-build list of different sentences (GoLiveGuide.swift:56)"#),
        #"ServicesSettingsView.swift|iosVoices|\.identifier"#:
            .init(.picker, #"iOS Voice Picker; system speechVoices identifiers, saved voice added only if missing (TextToSpeechService.swift:1749)"#),
        #"SettingsHubRowScreen.swift|children|\.self"#:
            .init(.distinct, #"a row's fixed children list filtered to visible categories (SettingsHubRow.swift:168)"#),
        #"SettingsScreens.swift|Self.savedModelWarnings(model)|\.self"#:
            .init(.notARow, #"inside the model row HStack; at most a kind warning and a shutdown warning, different texts (SettingsScreens.swift:720)"#),
        #"SettingsScreens.swift|alsoShows|\.self"#:
            .init(.distinct, #"SettingsHubRowScreen children with devices and display removed (DisplaySettingsPlacement.swift:62)"#),
        #"SettingsView.swift|providers|\.provider"#:
            .init(.deduplicated, #"providers deduped on llmProvider via a seen Set (SettingsView.swift:465)"#),
        #"SiriExposureView.swift|availableToolNames|\.self"#:
            .init(.picker, #"Tool Picker; names of registry tools, stored in a dictionary keyed by name (NativeToolRegistry.swift:424)"#),
        #"SiriExposureView.swift|customToolNames|\.self"#:
            .init(.menuOptionsMayRepeat, #"Custom Tool Picker; two custom tools can share a name, the editor only blocks native names (CustomToolsView.swift:96)"#),
        #"SiriExposureView.swift|vaults|\.self"#:
            .init(.deduplicated, #"Array(Set(...)) of finished session vault ids, sorted (SiriExposureView.swift:178)"#),
        #"SkillPacksSettingsView.swift|declaration.options ?? []|\.self"#:
            .init(.menuOptionsMayRepeat, #"select Picker options from a skill pack manifest; SkillPackValidator does not check options for repeats"#),
        #"SkillPacksSettingsView.swift|declarations|\.key"#:
            .init(.deduplicated, #"SkillPackManifest drops a setting key declared twice while decoding (SkillPackManifest.swift:242)"#),
        #"StockReportView.swift|line.lots|\.lotID"#:
            .init(.distinct, #"lot ids minted fresh per lot by addLot (UUID or makeID) and listed once per lot (VanStockLedger.swift:98)"#),
        #"StockReportView.swift|report.wastedByReason|\.reason"#:
            .init(.distinct, #"WasteReason.allCases filtered to reasons with a total (StockPeriodReport.swift:158)"#),
        #"StockScanSheet.swift|choices|\.self"#:
            .init(.deduplicated, #"segmented Picker options; Choice.offered appends a choice only if missing (StockScanSheet.swift:379)"#),
        #"StockSystemPartsSendSheet.swift|lines|\.self"#:
            .init(.deduplicated, #"one line per reason code via seen list, plus distinct header lines (StockSystemPartsDelivery.swift:223)"#),
        #"StockSystemSettingsView.swift|StockSystemAdapterRegistry.all|\.connectorID"#:
            .init(.picker, #"System Picker; static registry holds one adapter, square (StockSystemAdapterRegistry.swift:26)"#),
        #"StockSystemSettingsView.swift|reasons|\.self"#:
            .init(.picker, #"Recorded as Picker; allCases filtered by a Set of kept reasons (PartsUsedWritePlan.swift:53)"#),
        #"TempleTapSettingsView.swift|options(for: gesture)|\.self"#:
            .init(.picker, #"per-gesture Picker; distinct builtIns, quick actions by unique id, current added if missing (TempleTapSettingsView.swift:99)"#),
        #"ToolsSettingsView.swift|filteredTools|\.name"#:
            .init(.distinct, #"registry tools come from a dictionary keyed by tool name (NativeToolRegistry.swift:476)"#),
        #"TranslationSettingsView.swift|TranslationLanguages.curated|\.code"#:
            .init(.picker, #"language Pickers; static literal list of 12 distinct codes (TranslationConfig.swift:96)"#),
        #"UpcomingJobViews.swift|brief.sections|\.kind"#:
            .init(.distinct, #"JobBrief.init always builds exactly SectionKind.allCases; job files set brief nil (JobBrief.swift:120)"#),
        #"VaultAuthoringView.swift|manifest?.documents ?? []|\.file"#:
            .init(.deduplicated, #"installed manifests pass VaultValidator refusing a repeated document (VaultValidator.swift:69); addManual avoids taken names"#),
        #"VaultAuthoringView.swift|procedures|\.file"#:
            .init(.watched, #"one entry per procedure id (ProcedureLibrary.swift:79); a bundle and an overlay file sharing a name could repeat, so it is checked at run time"#),
        #"VaultCheckView.swift|documents|\.file"#:
            .init(.picker, #"Manual Picker inside a question row; installed manifest documents, a repeat refused at import (VaultValidator.swift:69)"#),
        #"VaultCheckView.swift|manifest?.documents ?? []|\.file"#:
            .init(.picker, #"Manual Picker; installed manifest documents, a document listed twice is refused at import (VaultValidator.swift:69)"#),
        #"VaultCheckView.swift|template.checkQuestions|\.text"#:
            .init(.constant, #"TradeTemplate static templates each list different literal question texts (LicenceIssuance TradeTemplate.swift:136)"#),
        #"VaultLinkViews.swift|lines|\.self"#:
            .init(.notARow, #"VStack inside a warning block; static list of four different sentences (VaultLinkReview.swift:60)"#),
        #"VaultManagerView.swift|indexing.runs.values.sorted { $0.vaultId < $1.vaultId }|\.vaultId"#:
            .init(.distinct, #"values of the runs dictionary, each Run stored under its own vaultId (VaultIndexingMonitor.swift:89)"#),
        #"WorkizSettingsView.swift|TimeZone.knownTimeZoneIdentifiers|\.self"#:
            .init(.distinct, #"system knownTimeZoneIdentifiers, unique identifiers"#),
        #"WritingStyleSettingsView.swift|sent|\.self"#:
            .init(.constant, #"four or five fixed, different consent sentences (WritingStyleSettingsView.swift:75)"#),
    ]
}
