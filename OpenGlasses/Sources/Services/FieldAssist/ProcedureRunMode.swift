import Foundation

/// How a procedure runs (Plan MN §4, decision 5): with the assistant, as before, or with no model
/// at all — the phone step screen, the rules, the on-device voice and the lens buttons.
///
/// `.noModel` is chosen, in this order, when:
/// - an organisation profile forces it on its phones (`organizationRunsProceduresWithoutAssistant`);
/// - the procedure asks for it (`"runs": "without_assistant"`);
/// - no usable model is configured, or the phone is offline and the offline hand-off finds no
///   on-device model to hand to (Plan GE);
/// - the person chose it on the procedure screen.
///
/// Otherwise `.assistant`. Pure: the app reads its settings into `Inputs` and asks.
enum ProcedureRunMode: String, Equatable, Sendable {
    case assistant
    case noModel

    /// What the decision is made from. Every field is a fact the app already holds.
    struct Inputs: Equatable, Sendable {
        /// The active model can answer at all: a provider with its key, base URL or account
        /// (`ScenarioToolOffer.modelCanAnswer`).
        var modelConfigured: Bool
        /// The network is reachable.
        var isOnline: Bool
        /// The active model runs on this phone, so it answers offline.
        var activeModelOnDevice: Bool
        /// The offline hand-off has an on-device model to hand to (`OfflineBrainSelector.Available
        /// .hasAnyModel`).
        var offlineHasOnDeviceModel: Bool
        /// The procedure says `"runs": "without_assistant"`.
        var procedureAsks: Bool
        /// An organisation profile forces procedures to run without the assistant.
        var organisationForces: Bool
        /// The person's choice on the procedure screen, nil when they made none.
        var personChoice: ProcedureRunMode?

        init(modelConfigured: Bool = true, isOnline: Bool = true, activeModelOnDevice: Bool = false,
             offlineHasOnDeviceModel: Bool = false, procedureAsks: Bool = false,
             organisationForces: Bool = false, personChoice: ProcedureRunMode? = nil) {
            self.modelConfigured = modelConfigured
            self.isOnline = isOnline
            self.activeModelOnDevice = activeModelOnDevice
            self.offlineHasOnDeviceModel = offlineHasOnDeviceModel
            self.procedureAsks = procedureAsks
            self.organisationForces = organisationForces
            self.personChoice = personChoice
        }
    }

    /// Why the mode is what it is — what the step screen says under its title.
    enum Reason: String, Equatable, Sendable {
        case organisation
        case procedure
        case noModelConfigured
        case offlineNoOnDeviceModel
        case personChose
        /// `.assistant`: a model is usable and nothing asks otherwise.
        case modelAvailable
    }

    struct Decision: Equatable, Sendable {
        let mode: ProcedureRunMode
        let reason: Reason

        /// Whether the person may switch the mode on the screen: only when nothing but their own
        /// choice (or nothing at all) decided it. An organisation, the procedure or the lack of a
        /// model decides it for them.
        var personCanChoose: Bool { reason == .personChose || reason == .modelAvailable }

        /// One plain line for the step screen. No provider, plan or vendor named.
        var line: String {
            switch reason {
            case .organisation:
                return String(localized: "Running without the assistant: your organisation runs procedures this way.")
            case .procedure:
                return String(localized: "Running without the assistant: this procedure always runs this way.")
            case .noModelConfigured:
                return String(localized: "Running without the assistant: no AI model is set up on this phone.")
            case .offlineNoOnDeviceModel:
                return String(localized: "Running without the assistant: you're offline and there's no model on this phone.")
            case .personChose:
                return String(localized: "Running without the assistant, as you chose.")
            case .modelAvailable:
                return String(localized: "The assistant can help with this procedure.")
            }
        }
    }

    /// Whether a usable model answers right now: one is configured, and the network is up, or it
    /// runs on the phone, or the offline hand-off has one on the phone to take over.
    static func modelUsable(_ inputs: Inputs) -> Bool {
        guard inputs.modelConfigured else { return false }
        return inputs.isOnline || inputs.activeModelOnDevice || inputs.offlineHasOnDeviceModel
    }

    static func decide(_ inputs: Inputs) -> Decision {
        if inputs.organisationForces { return Decision(mode: .noModel, reason: .organisation) }
        if inputs.procedureAsks { return Decision(mode: .noModel, reason: .procedure) }
        if !inputs.modelConfigured { return Decision(mode: .noModel, reason: .noModelConfigured) }
        if !modelUsable(inputs) { return Decision(mode: .noModel, reason: .offlineNoOnDeviceModel) }
        if inputs.personChoice == .noModel { return Decision(mode: .noModel, reason: .personChose) }
        return Decision(mode: .assistant, reason: .modelAvailable)
    }
}
