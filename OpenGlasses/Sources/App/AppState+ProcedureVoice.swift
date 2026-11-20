import Foundation
import Speech

/// What the app knows that decides a procedure's run mode (Plan MN §4): the model settings, the
/// offline hand-off's on-device model, the organisation's ceiling and the person's choice. The
/// decision itself is `ProcedureRunMode.decide`'s.
@MainActor
enum ProcedureRunModeEnvironment {

    static func inputs(for procedure: Procedure, isOnline: Bool,
                       personChoice: ProcedureRunMode?) -> ProcedureRunMode.Inputs {
        let model = Config.activeModel
        // Apple's on-device model is saved on every phone but answers only where the system has it.
        let configured = model.map {
            ScenarioToolOffer.modelCanAnswer(provider: $0.llmProvider, apiKey: $0.apiKey, baseURL: $0.baseURL,
                                             accountConnected: ClaudeOAuthService.shared.isConnected
                                                 || XAIOAuthService.shared.isConnected)
                && ($0.llmProvider != .appleOnDevice || FirstRunDefaults.appleIntelligenceAvailable)
        } ?? false
        return ProcedureRunMode.Inputs(
            modelConfigured: configured,
            isOnline: isOnline,
            activeModelOnDevice: model.map { LLMService.isOnDeviceProvider($0.llmProvider) } ?? false,
            offlineHasOnDeviceModel: OfflineHandoffAvailability.current().hasAnyModel,
            procedureAsks: procedure.runsWithoutAssistant,
            organisationForces: Config.organizationRunsProceduresWithoutAssistant,
            personChoice: personChoice)
    }

    static func decision(for procedure: Procedure, isOnline: Bool,
                         personChoice: ProcedureRunMode?) -> ProcedureRunMode.Decision {
        ProcedureRunMode.decide(inputs(for: procedure, isOnline: isOnline, personChoice: personChoice))
    }

    /// The running procedure's mode, or nil when none is running.
    static func activeDecision(isOnline: Bool) -> ProcedureRunMode.Decision? {
        let sessions = FieldSessionService.shared
        guard let procedure = sessions.activeProcedure else { return nil }
        return decision(for: procedure, isOnline: isOnline, personChoice: sessions.procedureRunModeChoice)
    }

    /// Whether this locale's speech can be recognised on the phone.
    static var supportsOnDeviceRecognition: Bool {
        SFSpeechRecognizer(locale: SpeechLocaleResolver.current)?.supportsOnDeviceRecognition ?? false
    }
}

extension AppState {

    /// The no-model procedure voice, built once against the session.
    static let procedureVoiceLoop = ProcedureVoiceLoop(
        host: FieldSessionService.shared,
        supportsOnDeviceRecognition: { ProcedureRunModeEnvironment.supportsOnDeviceRecognition })

    /// Whether the running procedure runs with no model right now.
    var procedureRunsWithoutModel: Bool {
        ProcedureRunModeEnvironment.activeDecision(isOnline: reachability.isOnline)?.mode == .noModel
    }

    /// Plan MN §4: while a procedure runs with no model, every utterance is the procedure's — a
    /// step word, the step's answer, or the one fixed line — and nothing reaches a model. Said with
    /// the on-device voice. False with no procedure, or one running with the assistant: the words
    /// go on. The caller resumes listening.
    func answerProcedureWithoutModel(_ text: String) async -> Bool {
        guard procedureRunsWithoutModel,
              let line = Self.procedureVoiceLoop.handle(text, locale: SpeechLocaleResolver.current) else { return false }
        PrivacyLog.app(.voiceCommandHandled, detail: PrivacyToken("procedureNoModel"))
        _ = await speechService.speakReporting(line, source: .job, onDeviceOnly: true)
        return true
    }

    /// Say the running procedure's step with the on-device voice — the step screen's Read aloud.
    func speakProcedureStep() async {
        guard let line = Self.procedureVoiceLoop.stepLine() else { return }
        _ = await speechService.speakReporting(line, source: .job, onDeviceOnly: true)
    }

    /// Point the transcription service's on-device rule at the running procedure's mode.
    func installProcedureVoiceGate() {
        ProcedureVoiceGate.listensOnDevice = { [weak self] in self?.procedureRunsWithoutModel ?? false }
    }
}
