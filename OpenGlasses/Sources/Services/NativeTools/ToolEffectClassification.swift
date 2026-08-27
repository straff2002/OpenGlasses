import Foundation

// MARK: - Execution semantics for every registered tool
//
// One file rather than a line in each of a hundred tool types, because the security property here
// belongs to the *set*: what matters is that no acting tool is missing, that nothing has quietly
// drifted to a weaker class, and that the whole list can be read in one sitting during review.
// `ToolEffectClassificationTests` enumerates the live registry against this, so a tool added without
// a row fails the build rather than silently inheriting `conservativeDefault`.
//
// How to read a row:
//   .read       — leaves nothing behind; a timeout is an authoritative "it didn't happen"
//   .local      — writes on-device or user-store state
//   .external   — sends data off the device or changes a third-party service
//   .actuation  — changes physical device or real-world state
// The cancellation argument says whether asking the running work to stop is worth anything, and
// the idempotency argument whether repeating the identical call duplicates its effect. Both are
// judged from what `execute(args:)` actually does, not from what the tool is called.
//
// Where a tool has several actions, the row is the *strongest* one: a tool that can both read and
// write is classified by the write, because the classification is consulted before the arguments
// are known to be safe.

// MARK: Reads

extension WeatherTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension DateTimeTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension CalculatorTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension UnitConversionTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension CurrencyTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension NewsTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension WebSearchTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension WordDefinitionTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension TranslationTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension TranslateSignMenuTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension AskLocalPhraseTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension WhereAmITool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension LocationSearchTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension EmergencyInfoTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension AircraftOverheadTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension VehicleTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension DeviceInfoTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension PedometerTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension ContactsTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension ListNotesTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension ListSavedLocationsTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension SessionSearchTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension MemorySearchTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension MemoryRewindTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension ConversationSummaryTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension HealthSafetyTool { var executionSemantics: ToolExecutionSemantics { .read() } }
extension NetworkCalcTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension DomainCalcTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension FoodAnalysisTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension ShazamTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension DiscoverCapabilitiesTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension YieldToHumanTool { var executionSemantics: ToolExecutionSemantics { .read() } }
/// Reads an already-published frame rather than triggering the shutter, so no hardware moves.
extension BarcodeScannerTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension ColorIdentifierTool { var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) } }
extension QRContextTool { var executionSemantics: ToolExecutionSemantics { .read() } }
/// A model round trip over the current frame; slower than a local read, still a read.
extension VisionAssessTool {
    var executionSemantics: ToolExecutionSemantics { .read(timeout: .seconds(60)) }
}
/// Fans out to weather + news + datetime, so it inherits the slowest of them.
extension DailyBriefingTool {
    var executionSemantics: ToolExecutionSemantics { .read(timeout: .seconds(45)) }
}

// MARK: Local mutations

extension SaveNoteTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension NotesVaultTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension HealthVaultTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension ContextualNoteTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension ProjectNoteTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension PlaybookTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension MeetingSummaryTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension SocialContextTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension BrainTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension AgentDiaryTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension AgentDocumentTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension AgentScheduleTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension DocumentRAGTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension SaveLocationTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension GeofenceTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension CalendarTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension AppleRemindersTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension AlarmTool { var executionSemantics: ToolExecutionSemantics { .local(.bestEffort) } }
extension FaceRecognitionTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension FitnessCoachingTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension GolfModeTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension CaptureFlowTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension ProcedureRunnerTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension BadgeScanTool { var executionSemantics: ToolExecutionSemantics { .local() } }
extension LiveCoachTool {
    var executionSemantics: ToolExecutionSemantics { .local(idempotency: .intrinsic) }
}
extension TimerTool {
    var executionSemantics: ToolExecutionSemantics { .local(.cooperative, idempotency: .intrinsic) }
}
extension PomodoroTool {
    var executionSemantics: ToolExecutionSemantics { .local(.bestEffort, idempotency: .intrinsic) }
}
extension ClipboardTool {
    var executionSemantics: ToolExecutionSemantics { .local(idempotency: .intrinsic) }
}
extension ObjectMemoryTool {
    var executionSemantics: ToolExecutionSemantics { .local(idempotency: .intrinsic) }
}
extension VoiceSkillsTool {
    var executionSemantics: ToolExecutionSemantics { .local(idempotency: .intrinsic) }
}
extension PinFrameTool {
    var executionSemantics: ToolExecutionSemantics { .local(idempotency: .intrinsic) }
}
extension NewTopicTool {
    var executionSemantics: ToolExecutionSemantics { .local(idempotency: .intrinsic) }
}

// MARK: External mutations

extension SendMessageTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
extension MultiChannelMessageTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
extension PhoneCallTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
extension SiriShortcutsTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
extension EscalateToExpertTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
extension FieldSessionTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
extension FirstAidTool { var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) } }
/// Uploads clinical data. A server-side idempotency key would make a repeat safe; there is no wire
/// support for one today, so a repeat is a second export.
extension MedicalExportTool {
    var executionSemantics: ToolExecutionSemantics { .external(.bestEffort, timeout: .seconds(90)) }
}
/// Dispatches an arbitrary task to a remote coding agent — the same blast radius as the gateway.
extension AgentControlTool {
    var executionSemantics: ToolExecutionSemantics { .external(.bestEffort, timeout: .seconds(60)) }
}
extension OpenClawSkillsTool {
    var executionSemantics: ToolExecutionSemantics {
        .external(.cooperative, idempotency: .intrinsic, timeout: .seconds(60))
    }
}
/// Hands the user off to another app with a payload. Launching twice lands in one place.
extension OpenAppTool {
    var executionSemantics: ToolExecutionSemantics { .external(.bestEffort, idempotency: .intrinsic) }
}
extension DirectionsTool {
    var executionSemantics: ToolExecutionSemantics { .external(.bestEffort, idempotency: .intrinsic) }
}
extension ChineseAppsTool {
    var executionSemantics: ToolExecutionSemantics { .external(.bestEffort, idempotency: .intrinsic) }
}
extension AsianMessagingTool {
    var executionSemantics: ToolExecutionSemantics { .external(.bestEffort, idempotency: .intrinsic) }
}

// MARK: Physical actuation

extension HomeKitTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension HomeAssistantTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(.cooperative) }
}
extension QuickActionTool { var executionSemantics: ToolExecutionSemantics { .actuation(.bestEffort) } }
extension FlashlightTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension BrightnessTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension MusicControlTool { var executionSemantics: ToolExecutionSemantics { .actuation() } }
extension AudioRecordingTool { var executionSemantics: ToolExecutionSemantics { .actuation() } }
extension PhotoLogTool { var executionSemantics: ToolExecutionSemantics { .actuation() } }
extension SafetyAssessmentTool { var executionSemantics: ToolExecutionSemantics { .actuation() } }
extension StudyTool { var executionSemantics: ToolExecutionSemantics { .actuation() } }
extension TeleprompterTool { var executionSemantics: ToolExecutionSemantics { .actuation() } }
extension VideoRecordingTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension LiveTranslationTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension NavigationAssistTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension NavigateTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(.bestEffort, idempotency: .intrinsic) }
}
extension ReadingSessionTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(.bestEffort, idempotency: .intrinsic) }
}
// The shutter tools: each triggers a real capture on the glasses, then reads the result. Repeating
// one costs another frame but converges on the same answer.
extension CapturePhotoTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension DocumentScanTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension SmartCaptureTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension ReadingAccessibilityTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension MedicationIdentifierTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension MoneyIdentifierTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension EquipmentLookupTool {
    var executionSemantics: ToolExecutionSemantics { .actuation(idempotency: .intrinsic) }
}
extension LookCloselyTool {
    var executionSemantics: ToolExecutionSemantics {
        .actuation(.bestEffort, idempotency: .intrinsic, timeout: .seconds(45))
    }
}

// MARK: Deliberately unclassified

/// A user-authored HTTP call. Its target, method, and body are configuration, so there is nothing
/// here to inspect and no honest classification but the worst case. This is the intended answer for
/// this type, not outstanding debt — the migration test lists it as such.
extension CustomToolWrapper {
    var executionSemantics: ToolExecutionSemantics { .conservativeDefault }
}
